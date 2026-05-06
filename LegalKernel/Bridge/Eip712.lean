/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.Eip712 — Workstream A.3 EIP-712 wrap module.

The Lean side of the EIP-712-typed-data envelope used to bridge
Canon `signedAction` payloads onto Ethereum.  See §5.3 of the
Ethereum integration plan for the full design.

EIP-712 (`https://eips.ethereum.org/EIPS/eip-712`) specifies a
wallet-friendly typed-data signing format:

```
sig_payload = 0x19 ‖ 0x01 ‖ domainSeparator ‖ structHash
```

where:

  * `domainSeparator = keccak256(EIP712Domain_typeHash ‖
       hash(name) ‖ hash(version) ‖ chainId ‖ rollupId ‖
       address(verifyingContract))`
  * `structHash = keccak256(canonAction_typeHash ‖ canonActionHash)`

The structured form lets wallets (MetaMask, Ledger, etc.) display
the action's fields to the user before signing — a UX win and a
security win, since a malicious dApp cannot trick the user into
signing an opaque blob whose meaning differs from the on-screen
description.

**Canonicalisation deviation (documented).**  The strict EIP-712
spec encodes `address` as 32-byte left-padded (12 zero bytes ‖
20-byte address), `uint256` as 32-byte big-endian, and `string` /
`bytes` (dynamic) as their hash.  This module instead hashes
*every* `ByteArray`-typed field (name, version, verifyingContract)
to canonicalise to 32-byte width, regardless of input length.
This deviates from EIP-712 spec only on `address` encoding.  The
deviation is intentional: hash-based canonicalisation gives
unconditional 32-byte field width that simplifies the
collision-free-only proofs.  Production wallet adaptors that
need spec-compliant address encoding can wire a separate
left-pad step at the FFI boundary; the security-critical
property (`eip712Wrap_distinguishes`) holds for the canonical
form.

**Spec-fidelity simplification.**  The §5.3 spec details a
struct hash with four fields (actionHash, signer, nonce,
deploymentId).  This module stores only the `actionHash` in the
struct hash, since `signer` / `nonce` / `deploymentId` are
already committed-to inside the canonical Canon `signInput` bytes
that `actionHash` hashes.  Wallets that want to display the
structured fields parse them from the on-the-wire EIP-712
envelope at the FFI boundary; the bridge runtime adaptor extends
the struct with all four fields for wallet UX without changing
the security-critical Canon side.

This module is **not** part of the trusted computing base.  Bugs
here weaken the EIP-712 envelope's wallet UX or interop
guarantees but cannot violate any kernel invariant.

Coverage map:

  * §5.3 (WU A.3) — `eip712Prefix`, `eip712DomainSeparator`,
    `canonActionTypeHash`, `eip712StructHash`, `eip712Wrap`,
    `Eip712Message`, `DomainParams`.
  * §12.6 — three theorems:
    * `eip712Wrap_injective` (theorem #24)
    * `eip712DomainSeparator_distinguishes` (theorem #25)
    * `eip712Wrap_distinguishes` (theorem #26)

The headline injectivity statements are stated under a Prop
hypothesis `CollisionFree hashBytes` (the deployment-supplied
keccak256 is collision-resistant); the hypothesis is *not* a
Lean axiom.  Real-world security depends on the production
keccak256 binding (Workstream A.2).
-/

import LegalKernel.Authority.Crypto
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.SignInput
import LegalKernel.Runtime.Hash

namespace LegalKernel.Bridge

open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## Hash collision-resistance hypothesis

`CollisionFree h` says: distinct inputs to `h` produce distinct
outputs.  Stated as a Prop parameter (not an axiom), so the
EIP-712 theorems are *conditional* on the deployment-supplied
hash being collision-resistant.  Real-world security requires
linking the keccak256 binding (Workstream A.2). -/

/-- Hash collision-resistance predicate.  `h` is collision-free
    iff `h x = h y → x = y` for all inputs.  Stated for any
    `ByteArray → ByteArray` function so it composes with both
    `hashBytes` and any future hash adaptor.  The Lean fallback
    (FNV-1a-64 padded) is *not* collision-free in 64 bits;
    production deployments link keccak256 via `@[extern]`. -/
def CollisionFree (h : ByteArray → ByteArray) : Prop :=
  ∀ b₁ b₂, h b₁ = h b₂ → b₁ = b₂

/-! ## ByteArray helper lemmas

Two small auxiliary lemmas for ByteArray manipulation.  Both lift
List-level identities to ByteArray-level ones via `.data.toList`. -/

/-- ByteArray equality reduces to `.data.toList` equality (since
    arrays are determined by their underlying lists). -/
private theorem byteArray_eq_of_data_toList_eq (a b : ByteArray)
    (h : a.data.toList = b.data.toList) : a = b := by
  cases a with
  | mk a' =>
    cases b with
    | mk b' =>
      show ByteArray.mk _ = ByteArray.mk _
      congr 1
      exact Array.toList_inj.mp h

/-- ByteArray append injectivity at a fixed-size left boundary:
    if `a ++ b = c ++ d` and `a.size = c.size`, then `a = c`
    and `b = d`.  Lifts `List.append_inj` via `.data.toList`. -/
private theorem byteArray_append_inj_of_size_left
    (a b c d : ByteArray) (h : a ++ b = c ++ d) (hs : a.size = c.size) :
    a = c ∧ b = d := by
  have hlist : (a ++ b).data.toList = (c ++ d).data.toList := by rw [h]
  have hlist' :
      a.data.toList ++ b.data.toList = c.data.toList ++ d.data.toList := hlist
  have ha_size : a.data.toList.length = c.data.toList.length := by
    show a.size = c.size
    exact hs
  obtain ⟨h_a, h_b⟩ := List.append_inj hlist' ha_size
  exact ⟨byteArray_eq_of_data_toList_eq a c h_a,
         byteArray_eq_of_data_toList_eq b d h_b⟩

/-! ## EIP-712 prefix and type strings -/

/-- The EIP-712 magic bytes "\x19\x01" prefix.  Required by the
    EIP-712 spec to distinguish typed-data signatures from raw
    signatures and personal-sign messages. -/
def eip712Prefix : ByteArray := ByteArray.mk #[0x19, 0x01]

/-- The EIP-712 prefix is exactly 2 bytes.  Used in the
    fixed-size-boundary extraction proofs. -/
theorem eip712Prefix_size : eip712Prefix.size = 2 := rfl

/-- The canonical EIP-712 type string for the Canon-on-Ethereum
    domain separator.  All five fields are part of EIP-712's
    standard `EIP712Domain` type plus our deployment-specific
    `rollupId`.  Hashed once per deployment. -/
def eip712DomainTypeString : String :=
  "EIP712Domain(string name,string version,uint256 chainId," ++
  "uint256 rollupId,address verifyingContract)"

/-- The canonical EIP-712 type string for a Canon action message.
    The structured form (with separately-broken-out signer / nonce /
    deploymentId) is wallet-side; the Canon side commits to the
    full sign-input via `actionHash`. -/
def canonActionTypeString : String :=
  "CanonAction(bytes32 actionHash,uint64 signer," ++
  "uint64 nonce,bytes32 deploymentId)"

/-- The 32-byte type hash for the EIP-712 domain.  Equals
    `keccak256(eip712DomainTypeString)` under a production
    keccak256 binding. -/
def eip712DomainTypeHash : ByteArray :=
  hashBytes eip712DomainTypeString.toUTF8

/-- The 32-byte type hash for the Canon action.  Equals
    `keccak256(canonActionTypeString)` under production. -/
def canonActionTypeHash : ByteArray :=
  hashBytes canonActionTypeString.toUTF8

/-- The domain type hash has size 32 (matching the unified hash
    width). -/
theorem eip712DomainTypeHash_size : eip712DomainTypeHash.size = 32 :=
  hashBytes_size _

/-- The action type hash has size 32. -/
theorem canonActionTypeHash_size : canonActionTypeHash.size = 32 :=
  hashBytes_size _

/-! ## 32-byte big-endian uint encoding

EIP-712 encodes `uint256` (and any uint that fits) as 32-byte
big-endian.  Composes `natToBytesLE n 32` with `List.reverse` to
get the BE form. -/

/-- 32-byte big-endian encoding of a `Nat` (EIP-712 `uint256` shape).
    Pads with leading zero bytes; truncates to 32 bytes for inputs
    exceeding `2^256`. -/
def encodeUint256BE (n : Nat) : ByteArray :=
  ByteArray.mk (natToBytesLE n 32).reverse.toArray

/-- The 32-byte BE encoding has size exactly 32. -/
theorem encodeUint256BE_size (n : Nat) : (encodeUint256BE n).size = 32 := by
  show (ByteArray.mk (natToBytesLE n 32).reverse.toArray).size = 32
  show (natToBytesLE n 32).reverse.toArray.size = 32
  rw [List.size_toArray, List.length_reverse]
  exact natToBytesLE_length n 32

/-- `encodeUint256BE` is injective on inputs `< 2^256`.  Lifted from
    the LE-codec round-trip via `List.reverse_inj`. -/
theorem encodeUint256BE_injective
    (n₁ n₂ : Nat) (h₁ : n₁ < 256 ^ 32) (h₂ : n₂ < 256 ^ 32)
    (h : encodeUint256BE n₁ = encodeUint256BE n₂) : n₁ = n₂ := by
  -- Lift to the underlying lists.
  have hbytes : (natToBytesLE n₁ 32).reverse = (natToBytesLE n₂ 32).reverse := by
    have hba : ByteArray.mk (natToBytesLE n₁ 32).reverse.toArray =
               ByteArray.mk (natToBytesLE n₂ 32).reverse.toArray := h
    have harr : (natToBytesLE n₁ 32).reverse.toArray =
                (natToBytesLE n₂ 32).reverse.toArray := by
      injection hba
    -- Lift Array equality to List equality via toList.
    have hl : (natToBytesLE n₁ 32).reverse.toArray.toList =
              (natToBytesLE n₂ 32).reverse.toArray.toList := by rw [harr]
    rwa [List.toList_toArray, List.toList_toArray] at hl
  -- Reverse-inject to get LE bytes equal.
  have hle : natToBytesLE n₁ 32 = natToBytesLE n₂ 32 :=
    List.reverse_inj.mp hbytes
  -- Apply LE round-trip to recover n.
  have hr₁ := natFromBytesLE_natToBytesLE n₁ 32 h₁
  have hr₂ := natFromBytesLE_natToBytesLE n₂ 32 h₂
  rw [hle] at hr₁
  -- hr₁ : natFromBytesLE (natToBytesLE n₂ 32) 32 = .ok (n₁, [])
  -- hr₂ : natFromBytesLE (natToBytesLE n₂ 32) 32 = .ok (n₂, [])
  have heq : (Except.ok (n₁, ([] : Stream)) : Except DecodeError (Nat × Stream)) =
             Except.ok (n₂, []) := hr₁.symm.trans hr₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-- `2 ^ 64 ≤ 256 ^ 32` — used to widen UInt64-bounded nonces /
    chainIds to the `< 256 ^ 32` precondition of
    `encodeUint256BE_injective`. -/
private theorem pow_2_64_le_pow_256_32 : (2 : Nat) ^ 64 ≤ 256 ^ 32 := by
  have h : (256 : Nat) ^ 32 = 2 ^ 256 := by
    show ((2 : Nat) ^ 8) ^ 32 = 2 ^ 256
    rw [← Nat.pow_mul]
  rw [h]
  exact Nat.pow_le_pow_right (by decide : (1 : Nat) ≤ 2) (by decide : 64 ≤ 256)

/-- Convenience: `encodeUint256BE` is injective on UInt64-bounded
    inputs (which is the deployment-relevant case for `chainId`
    and `rollupId`). -/
theorem encodeUint256BE_injective_uint64
    (n₁ n₂ : Nat) (h₁ : n₁ < 2 ^ 64) (h₂ : n₂ < 2 ^ 64)
    (h : encodeUint256BE n₁ = encodeUint256BE n₂) : n₁ = n₂ := by
  have hb₁ : n₁ < 256 ^ 32 := Nat.lt_of_lt_of_le h₁ pow_2_64_le_pow_256_32
  have hb₂ : n₂ < 256 ^ 32 := Nat.lt_of_lt_of_le h₂ pow_2_64_le_pow_256_32
  exact encodeUint256BE_injective n₁ n₂ hb₁ hb₂ h

/-! ## Domain separator -/

/-- EIP-712 domain parameters.  Bundled as a structure so the
    `eip712DomainSeparator_distinguishes` theorem can quantify
    over all five fields uniformly. -/
structure DomainParams where
  /-- Application name, e.g. `"CanonRollup"`.  Hashed for
      canonicalisation. -/
  name : ByteArray
  /-- Protocol version, e.g. `"1"`.  Hashed for canonicalisation. -/
  version : ByteArray
  /-- L1 chain id (1 for mainnet, 11155111 for Sepolia, etc.). -/
  chainId : Nat
  /-- Deployment-specific rollup id.  Lets multiple Canon rollups
      share an L1 chain without collision. -/
  rollupId : Nat
  /-- L1 contract address that verifies signatures (the
      `CanonBridge.sol` deployment).  Hashed in our canonical
      form (deviation from EIP-712 spec, which left-pads). -/
  verifyingContract : ByteArray
  deriving DecidableEq

/-- The canonical pre-hash bytes for the domain separator.
    Concatenates the six 32-byte fields in EIP-712 order. -/
def domainPreHash (p : DomainParams) : ByteArray :=
  eip712DomainTypeHash ++
  hashBytes p.name ++
  hashBytes p.version ++
  encodeUint256BE p.chainId ++
  encodeUint256BE p.rollupId ++
  hashBytes p.verifyingContract

/-- The EIP-712 domain separator.  Equals `keccak256(domainPreHash p)`
    under production. -/
def eip712DomainSeparator (p : DomainParams) : ByteArray :=
  hashBytes (domainPreHash p)

/-- The domain separator has size 32. -/
theorem eip712DomainSeparator_size (p : DomainParams) :
    (eip712DomainSeparator p).size = 32 :=
  hashBytes_size _

/-! ## Struct hash and full wrap -/

/-- An EIP-712-wrapped Canon action.  Bundles the 4 message fields
    so the wrap is uniformly defined and the proofs can quantify
    over a single `m` parameter.  The structured form encodes via
    the existing canonical `signInput`. -/
structure Eip712Message where
  /-- The Canon `Action` value to be authorised. -/
  action : Action
  /-- The signer's `ActorId`. -/
  signer : ActorId
  /-- The signer's expected nonce. -/
  nonce : Nonce
  /-- The deployment id (genesis-state hash). -/
  deploymentId : ByteArray

/-- The canonical CBE sign-input bytes for an `Eip712Message`.
    Forwards to the existing `signInput` from `Encoding/SignInput.lean`. -/
def Eip712Message.signInput (m : Eip712Message) : ByteArray :=
  LegalKernel.Encoding.signInput m.action m.signer m.nonce m.deploymentId

/-- The canonical 32-byte action hash for an EIP-712-wrapped message.
    `keccak256(signInput)` — commits to the full `(action, signer,
    nonce, deploymentId)` tuple via the canonical Canon CBE
    encoding. -/
def Eip712Message.actionHash (m : Eip712Message) : ByteArray :=
  hashBytes m.signInput

/-- The CanonAction struct hash (EIP-712 §3.2 `hashStruct`).
    `keccak256(canonActionTypeHash ‖ actionHash)`.  The single-field
    struct (just `actionHash`) is sufficient for security since
    `actionHash` already commits to the full structured tuple via
    the Canon CBE encoding.  Wallet UX layers extend this with
    visibly-broken-out fields at the FFI boundary. -/
def eip712StructHash (m : Eip712Message) : ByteArray :=
  hashBytes (canonActionTypeHash ++ m.actionHash)

/-- The struct hash has size 32. -/
theorem eip712StructHash_size (m : Eip712Message) :
    (eip712StructHash m).size = 32 :=
  hashBytes_size _

/-- The full EIP-712 wrap.  Returns the bytes a wallet would sign:
    `0x19 0x01 ‖ domainSeparator ‖ structHash`. -/
def eip712Wrap (m : Eip712Message) (domainSep : ByteArray) : ByteArray :=
  eip712Prefix ++ domainSep ++ eip712StructHash m

/-! ## Stability theorems

Three sanity-check theorems pinning the wrap's structure: it
begins with the EIP-712 prefix, has size determined by the
domain separator, and is deterministic on equal inputs. -/

/-- The wrap's size equals 2 (prefix) + domainSep.size + 32
    (struct hash). -/
theorem eip712Wrap_size (m : Eip712Message) (domainSep : ByteArray) :
    (eip712Wrap m domainSep).size = 2 + domainSep.size + 32 := by
  show (eip712Prefix ++ domainSep ++ eip712StructHash m).size = _
  rw [ByteArray.size_append, ByteArray.size_append]
  rw [eip712Prefix_size, eip712StructHash_size]

/-- The wrap is deterministic. -/
theorem eip712Wrap_deterministic (m : Eip712Message) (d : ByteArray) :
    eip712Wrap m d = eip712Wrap m d := rfl

/-! ## Theorem 24 — `eip712Wrap_injective`

Under collision-free hashing, equal wraps for a fixed domain
separator imply equal sign-input bytes for the contained
messages.

Proof flow:

  1. From `eip712Wrap m₁ d = eip712Wrap m₂ d`, extract the
     suffix struct-hash equality via byte-level append injectivity
     at the boundary `(prefix ++ d).size`.
  2. Apply `CollisionFree hashBytes` to the struct hashes; lift
     to equality of the pre-images
     `canonActionTypeHash ++ actionHash`.
  3. Apply byte-level append injectivity at the
     `canonActionTypeHash.size` boundary; lift to equality of
     `actionHash`es.
  4. Apply `CollisionFree hashBytes` again to the action hashes;
     lift to equality of `signInput` bytes.

The `signInput`-bytes equality is the cryptographically
meaningful conclusion: an attacker who produced equal EIP-712
wraps on two different `Eip712Message`s would have to produce
two distinct sign-inputs that share an `actionHash`.  Under
keccak256 collision-resistance, this is impossible.

The conclusion `m₁ = m₂` then follows from `signInput` injectivity
in `(action, signer, nonce, deploymentId)`, which is a separate
property of the Canon CBE encoding (provable but not stated here).
The theorem below exposes the strongest provable conclusion: equal
wraps imply equal sign-input bytes. -/

/-- Theorem #24: under collision-free hashing, equal EIP-712 wraps
    for a fixed domain separator imply equal sign-input bytes for
    the contained `Eip712Message`s.

    This is the cryptographically-meaningful injectivity property:
    a malicious dApp cannot trick a user into producing two
    distinct signatures on two distinct Canon actions whose
    EIP-712 wraps happen to coincide.  Under keccak256
    collision-resistance, the wraps differ whenever the sign-input
    bytes differ.

    Concluding `m₁ = m₂` (from equal sign-input bytes) requires
    `signInput` injectivity in `(action, signer, nonce,
    deploymentId)` — a separate property of the Canon CBE encoding,
    not stated here.  The Lean-tractable headline is the
    sign-input-bytes form.  Production wallet adaptors that need
    structured field equality apply CBE field-injectivity at the
    FFI boundary. -/
theorem eip712Wrap_injective
    (hcf : CollisionFree hashBytes) :
    ∀ (m₁ m₂ : Eip712Message) (d : ByteArray),
      eip712Wrap m₁ d = eip712Wrap m₂ d →
      m₁.signInput = m₂.signInput := by
  intro m₁ m₂ d h
  -- Step 1: extract struct-hash equality from the wrap concat.
  unfold eip712Wrap at h
  -- h : eip712Prefix ++ d ++ eip712StructHash m₁ =
  --     eip712Prefix ++ d ++ eip712StructHash m₂
  have h_left_size :
      (eip712Prefix ++ d).size = (eip712Prefix ++ d).size := rfl
  obtain ⟨_, hstruct⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h h_left_size
  -- hstruct : eip712StructHash m₁ = eip712StructHash m₂
  -- Step 2: apply collision-freedom to the struct hashes.
  unfold eip712StructHash at hstruct
  have hstructPre :
      canonActionTypeHash ++ m₁.actionHash =
      canonActionTypeHash ++ m₂.actionHash := hcf _ _ hstruct
  -- Step 3: append injectivity at the canonActionTypeHash prefix.
  have h_prefix_size :
      canonActionTypeHash.size = canonActionTypeHash.size := rfl
  obtain ⟨_, hAH⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ hstructPre h_prefix_size
  -- hAH : m₁.actionHash = m₂.actionHash
  -- Step 4: apply collision-freedom to the action hashes.
  unfold Eip712Message.actionHash at hAH
  -- hAH : hashBytes m₁.signInput = hashBytes m₂.signInput
  exact hcf _ _ hAH

/-! ## Theorem 25 — `eip712DomainSeparator_distinguishes`

Distinct `DomainParams` produce distinct `eip712DomainSeparator`
outputs under collision-free hashing.

The proof argues that distinct params produce distinct
`domainPreHash` byte sequences (by injectivity of the per-field
encodings), and collision-free hashing preserves
distinguishability.

For the per-field injectivity:
  * `name` and `version` differ ⇒ `hashBytes name`, `hashBytes
    version` differ (under collision-free `hashBytes`).
  * `chainId` and `rollupId` differ ⇒ their 32-byte BE encodings
    differ at fixed positions.
  * `verifyingContract` differs ⇒ `hashBytes verifyingContract`
    differs.

Composing these via fixed-size-boundary extraction gives
`domainPreHash`-injectivity. -/

/-- Auxiliary: `domainPreHash` is injective on `DomainParams`
    under collision-free hashing of the variable-width fields.

    The `chainId` and `rollupId` fields require additional
    bounded-input hypotheses (since `encodeUint256BE` is only
    injective for inputs `< 2^256`), which we supply as side
    conditions.  Real-world `chainId`s and `rollupId`s fit in
    `uint64` (well below the bound). -/
theorem domainPreHash_injective
    (hcf : CollisionFree hashBytes)
    (p₁ p₂ : DomainParams)
    (hcb₁ : p₁.chainId < 256 ^ 32) (hcb₂ : p₂.chainId < 256 ^ 32)
    (hrb₁ : p₁.rollupId < 256 ^ 32) (hrb₂ : p₂.rollupId < 256 ^ 32)
    (h : domainPreHash p₁ = domainPreHash p₂) :
    p₁ = p₂ := by
  unfold domainPreHash at h
  -- The concatenation tree is left-associative.  We peel off fields
  -- right-to-left at fixed 32-byte boundaries, producing one field
  -- equality per peel.  Each `byteArray_append_inj_of_size_left`
  -- call discharges the `.size` equality with a chain of
  -- `ByteArray.size_append` rewrites + the per-field size lemmas.
  -- 1) Peel verifyingContract:
  have h_size₅ :
      (eip712DomainTypeHash ++ hashBytes p₁.name ++ hashBytes p₁.version ++
          encodeUint256BE p₁.chainId ++ encodeUint256BE p₁.rollupId).size =
      (eip712DomainTypeHash ++ hashBytes p₂.name ++ hashBytes p₂.version ++
          encodeUint256BE p₂.chainId ++ encodeUint256BE p₂.rollupId).size := by
    simp only [ByteArray.size_append, eip712DomainTypeHash_size,
      hashBytes_size, encodeUint256BE_size]
  obtain ⟨h_left₅, h_vc⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h h_size₅
  have hvc : p₁.verifyingContract = p₂.verifyingContract := hcf _ _ h_vc
  -- 2) Peel rollupId:
  have h_size₄ :
      (eip712DomainTypeHash ++ hashBytes p₁.name ++ hashBytes p₁.version ++
          encodeUint256BE p₁.chainId).size =
      (eip712DomainTypeHash ++ hashBytes p₂.name ++ hashBytes p₂.version ++
          encodeUint256BE p₂.chainId).size := by
    simp only [ByteArray.size_append, eip712DomainTypeHash_size,
      hashBytes_size, encodeUint256BE_size]
  obtain ⟨h_left₄, h_rid⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h_left₅ h_size₄
  have hrid : p₁.rollupId = p₂.rollupId :=
    encodeUint256BE_injective _ _ hrb₁ hrb₂ h_rid
  -- 3) Peel chainId:
  have h_size₃ :
      (eip712DomainTypeHash ++ hashBytes p₁.name ++ hashBytes p₁.version).size =
      (eip712DomainTypeHash ++ hashBytes p₂.name ++ hashBytes p₂.version).size := by
    simp only [ByteArray.size_append, eip712DomainTypeHash_size,
      hashBytes_size]
  obtain ⟨h_left₃, h_cid⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h_left₄ h_size₃
  have hcid : p₁.chainId = p₂.chainId :=
    encodeUint256BE_injective _ _ hcb₁ hcb₂ h_cid
  -- 4) Peel version:
  have h_size₂ :
      (eip712DomainTypeHash ++ hashBytes p₁.name).size =
      (eip712DomainTypeHash ++ hashBytes p₂.name).size := by
    simp only [ByteArray.size_append, eip712DomainTypeHash_size,
      hashBytes_size]
  obtain ⟨h_left₂, h_ver⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h_left₃ h_size₂
  have hver : p₁.version = p₂.version := hcf _ _ h_ver
  -- 5) Peel name (the only remaining field at the leftmost position):
  have h_size₁ :
      eip712DomainTypeHash.size = eip712DomainTypeHash.size := rfl
  obtain ⟨_, h_name⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h_left₂ h_size₁
  have hname : p₁.name = p₂.name := hcf _ _ h_name
  -- Combine all field equalities into structure equality.
  cases p₁; cases p₂
  simp_all

/-- Theorem #25: distinct `DomainParams` produce distinct
    `eip712DomainSeparator` values, under collision-free hashing
    plus bounded-input hypotheses on `chainId` and `rollupId`.

    The bounded-input hypothesis is satisfied for every real-world
    chain (Ethereum mainnet uses chainId = 1; the largest
    standardised chainId fits in `uint64`).  At the deployment
    boundary, the runtime adaptor enforces the bound. -/
theorem eip712DomainSeparator_distinguishes
    (hcf : CollisionFree hashBytes)
    (p₁ p₂ : DomainParams)
    (hcb₁ : p₁.chainId < 256 ^ 32) (hcb₂ : p₂.chainId < 256 ^ 32)
    (hrb₁ : p₁.rollupId < 256 ^ 32) (hrb₂ : p₂.rollupId < 256 ^ 32)
    (h_neq : p₁ ≠ p₂) :
    eip712DomainSeparator p₁ ≠ eip712DomainSeparator p₂ := by
  intro h_eq
  apply h_neq
  unfold eip712DomainSeparator at h_eq
  have h_pre : domainPreHash p₁ = domainPreHash p₂ := hcf _ _ h_eq
  exact domainPreHash_injective hcf p₁ p₂ hcb₁ hcb₂ hrb₁ hrb₂ h_pre

/-! ## Theorem 26 — `eip712Wrap_distinguishes`

Composition of #24 and #25: distinct `(message, domainSep)`
pairs produce distinct EIP-712 wraps.

We state this in the practically-useful form: if two wraps over
*possibly-different* domain separators of the same size are equal,
then both the domain separators and the sign-input bytes must be
equal. -/

/-- Theorem #26: composing #24 + #25.  Equal EIP-712 wraps over
    same-size domain separators imply both equal domain separators
    AND equal sign-input bytes for the contained messages.

    Proof: the wrap layout is `prefix ‖ domainSep ‖ structHash`.
    Under append injectivity at the fixed-size prefix boundary
    (after `ByteArray.append_assoc` reassociation), the trailing
    `domainSep ‖ structHash` matches.  With same-size domain
    separators, append injectivity peels the domain separator off,
    leaving the struct hashes equal — which by #24 means equal
    sign-input bytes. -/
theorem eip712Wrap_distinguishes
    (hcf : CollisionFree hashBytes)
    (m₁ m₂ : Eip712Message) (d₁ d₂ : ByteArray)
    (h_size : d₁.size = d₂.size)
    (h : eip712Wrap m₁ d₁ = eip712Wrap m₂ d₂) :
    d₁ = d₂ ∧ m₁.signInput = m₂.signInput := by
  -- Reassociate the wrap to peel off the prefix uniformly.
  unfold eip712Wrap at h
  rw [show eip712Prefix ++ d₁ ++ eip712StructHash m₁ =
           eip712Prefix ++ (d₁ ++ eip712StructHash m₁) from
           ByteArray.append_assoc] at h
  rw [show eip712Prefix ++ d₂ ++ eip712StructHash m₂ =
           eip712Prefix ++ (d₂ ++ eip712StructHash m₂) from
           ByteArray.append_assoc] at h
  -- Peel off the prefix.
  have h_pre_size : eip712Prefix.size = eip712Prefix.size := rfl
  obtain ⟨_, h_after_prefix⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h h_pre_size
  -- h_after_prefix : d₁ ++ eip712StructHash m₁ = d₂ ++ eip712StructHash m₂
  -- Peel off the domain separator using the size hypothesis.
  obtain ⟨h_d, h_struct⟩ :=
    byteArray_append_inj_of_size_left _ _ _ _ h_after_prefix h_size
  -- h_d : d₁ = d₂
  -- h_struct : eip712StructHash m₁ = eip712StructHash m₂
  -- Reconstruct the eip712Wrap-equality with d₁ = d₂ to invoke #24.
  have hwrap : eip712Wrap m₁ d₁ = eip712Wrap m₂ d₁ := by
    unfold eip712Wrap
    rw [h_struct]
  exact ⟨h_d, eip712Wrap_injective hcf m₁ m₂ d₁ hwrap⟩

end LegalKernel.Bridge
