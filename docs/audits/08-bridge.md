# Audit 08: Bridge Modules (Workstreams A–D)

Scope: line-by-line audit of every file under
`/home/user/Knomosis/LegalKernel/Bridge/`. The Bridge layer is Workstreams
A (cryptographic adaptors), B (identity / ingest / address book),
C (deposit/withdraw ledger + admissibility + accounting), and D
(SMT withdrawal proofs + finalisation).

Files audited (12, total 5,474 lines):

| File                  | Lines | Workstream | Role                                    |
|-----------------------|-------|------------|-----------------------------------------|
| `AddressBook.lean`    |   640 | B.1        | L1 address ↔ Knomosis ActorId registry     |
| `State.lean`          |   234 | C.1        | BridgeState (consumed / pending / nextWdId) |
| `Eip712.lean`         |   741 | A.3        | EIP-712 typed-data envelope + injectivity |
| `HashAdaptor.lean`    |   210 | A.2        | keccak256 adaptor identifier + KATs     |
| `VerifyAdaptor.lean`  |   217 | A.1        | secp256k1 ECDSA adaptor constants       |
| `BridgeActor.lean`    |   376 | B.3        | bridgeActor = 0; bridgePolicy authority |
| `Admissible.lean`     |   467 | C.0        | BridgeAdmissibleWith + replay blocks    |
| `Accounting.lean`     |   513 | C.6        | totalDeposited / totalWithdrawn deltas  |
| `WithdrawalRoot.lean` | 1,088 | D.1        | Sparse Merkle Tree + verifier + soundness |
| `WithdrawalProof.lean`|   146 | D.2        | extractProof from a Snapshot            |
| `Finalisation.lean`   |   315 | D.3        | isFinalised + dispute-window monotonicity |
| `Ingest.lean`         |   527 | B.2        | L1Event → UnsignedBridgeAction          |

Headline finding: the Bridge layer's claimed properties — EIP-712 wrap
injectivity, deposit-replay-blocked, withdraw-bumps-nextWdId, SMT
completeness + soundness, finalisation monotonicity, ingest emits
bridge actor — all have real theorem-level witnesses in source. Trust
assumptions are explicit, hash collision-resistance is parameterised
as a `Prop` (not an axiom). Several caveats are flagged below; the
two most consequential are the L1 deposit-id projection collision
risk and the soundness theorem's reliance on caller-supplied size
hypotheses that the Lean side does not enforce.

---

## 1. `AddressBook.lean` (640 lines, Workstream B.1)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/AddressBook.lean`

### Imports (AddressBook.lean:80–82)

```
import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Authority.Crypto
```

Reasonable. Pulls in the kernel TCB modules (RBMap proof library) for
`find?_insert_*` lemmas plus the `PublicKey` type. No Mathlib /
batteries — Std core only.

### Type-level structure

* `ethAddressBound := 2 ^ 160` (line 103) and `EthAddress :=
  Fin ethAddressBound` (line 111). Width enforced at the type level
  (`Fin n` proves `i < n` constructively). `Repr` instance prints
  decimal Nat (line 129–130) — fine for diagnostics; the Rust
  adaptor handles hex serialisation at the wire boundary.
* `EthAddress.ofBytes` (line 153) returns `none` if the byte array is
  not exactly 20 bytes; otherwise BE-decodes via
  `foldl (fun acc b => acc * 256 + b.toNat) 0`.
* `EthAddress.toBytes` (line 165) BE-encodes with a private `go`
  recursion. `toBytes_size` (line 188) — output is exactly 20 bytes.
* `EthAddress.ofBytes_toBytes` (line 275) — full round-trip lemma
  proved via the bounded-input decoder lemma at lines 233–264. This
  is the audit-2 hardening that binds withdrawal signatures to the
  full 20-byte L1 recipient address rather than a truncated form.

### AddressBook structure (line 326–336)

Three plain fields: forward map (`EthAddress → ActorId`), reverse
map (`ActorId → EthAddress`), and `nextActorId`. The
`Consistent` predicate (line 348–350) is the bidirectional
inverse-pair invariant — not bundled into the struct (deliberate
design choice; see docstring lines 36–43 explaining the
"motive is not type correct" issue with bundled dependent invariants).

### Mutability and freshness

`assign` (line 393) is the only mutator. It performs `forward[addr]?`
first; on `some`, returns the book unchanged with the existing id;
on `none`, inserts at `(addr, nextActorId)` and `(nextActorId, addr)`
in both maps and bumps `nextActorId` by 1.

**Sharpness — freshness hypothesis is external (line 450–516).**
`assign_preserves_consistent` requires a hypothesis
`hFresh : b.reverse[b.nextActorId]? = none`. The runtime adaptor must
maintain this invariant by monotonic assignment from `1`. The
docstring at lines 41–63 explicitly carves this out as a runtime-
adaptor obligation, not a Lean-level theorem. There is no Lean-level
proof that any concrete construction satisfies freshness — it's an
inductive invariant on the runtime side.

**Sharpness — UInt64 overflow (line 570–588).** The
`assign_fresh_actorId_le` lemma requires an explicit hypothesis
`hNoOverflow : b.nextActorId.toNat + 1 < 2 ^ 64`. The kernel's
`ActorId : UInt64` opens the abstract possibility of an overflow that
would wrap `nextActorId` back into the bridge-actor slot (0). The
unconditional `assign_fresh_actorId` (line 547) sidesteps this with
the stronger `result.fst.nextActorId = b.nextActorId + 1` (UInt64
addition); the `≤`-form is only available under no-overflow.

### Key theorems (Workstream B.1)

* `empty_consistent` (line 431) — empty book is consistent.
* `assign_preserves_consistent` (line 450) — `assign` preserves
  consistency under freshness.
* `addressBook_invariant` (line 529) — bidirectional inverse for
  any consistent book.
* `assign_fresh_actorId` (line 547) — fresh address yields the
  current nextActorId; nextActorId bumps by exactly 1 (UInt64).
* `assign_idempotent_for_known` (line 592) — known address: book
  unchanged, prior id returned.
* `assign_other_address_untouched` (line 608) — per-address locality.
* `assign_other_id_untouched` (line 618) — per-actor-id locality.

### Documentation drift

None observed. Module docstring at lines 71–78 lists the §12.7
theorems; all four are present and named consistently.

---

## 2. `State.lean` (234 lines, Workstream C.1)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/State.lean`

### Imports (State.lean:65–67)

```
import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Bridge.AddressBook
```

Pulls in the kernel TCB + AddressBook (for `EthAddress`).

### Core type design

* `DepositId := Nat` (line 116) — deviation from the integration
  plan's `ByteArray` sketch. Docstring lines 88–115 explains: avoids
  needing a custom `byteArrayCompare` + `TransCmp` / `LawfulEqCmp`
  proofs.
* `WithdrawalId := Nat` (line 121) — monotonically-increasing
  per-bridge index.
* `DepositRecord` (line 134) — `{ resource, amount }`. Audit-2
  amendment: the original sketch used `Unit` for the value type,
  but the accounting theorem requires `(resource, amount)` metadata.
* `PendingWithdrawal` (line 144) — `{ resource, recipient :
  EthAddress, amount, l2LogIndex }`. The recipient is an
  `EthAddress` (not raw `ByteArray`), so canonicalisation is
  type-enforced.
* `BridgeState` (line 169) — three fields: `consumed`, `pending`,
  `nextWdId`. `BridgeState.empty` (line 183) sets `nextWdId := 0`.

**Sharpness — wire-encoding bound (DepositId: lines 88–115).** The
DepositId docstring carefully notes that the Phase-4 CBE encoder
encodes `Nat` as a 1-byte tag + 8-byte LE payload; values ≥ 2^64
are not roundtrip-safe. An `Action.deposit` carrying a full 32-byte
L1 receipt hash thus does **not** round-trip — the runtime adaptor
**must** project the L1 hash into a 64-bit deployment-canonical form
(suggestions: `keccak256(blockHash ‖ logIdx)[0:8]` or a sequential
counter). Injectivity of this projection is a **deployment
correctness obligation**, not enforced by Lean. A weak projection
would create the abstract possibility of two L1 deposits collapsing
onto the same Knomosis DepositId — the kernel-side conjunct 6
(deposit-id uniqueness against `consumed`) only protects against
collisions *within* the bridge lifetime once an id has been chosen.

### Helpers (line 207–229)

`markConsumed`, `appendWithdrawal`, `isConsumed`, `hasConsumed`.
`appendWithdrawal` inserts at `nextWdId` and increments — this is
the locus of replay protection on the withdraw side.

---

## 3. `Eip712.lean` (741 lines, Workstream A.3)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/Eip712.lean`

### Imports (Eip712.lean:110–111)

```
import LegalKernel.Encoding.SignInput
import LegalKernel.Runtime.Hash
```

Reasonable. Pulls in CBE sign-input (`signInput` formation) and the
`hashBytes` swap-point.

### Cryptographic adaptors — opaque vs. verified

* `hashBytes` (imported from `Runtime/Hash.lean`) is `opaque`, not
  `axiom`. Production deployments link keccak256 via `@[extern]`;
  the Lean-level fallback (FNV-1a-64 padded) is **not**
  collision-free in 64 bits.
* `CollisionFree` (line 133–134) is a `Prop` parameter:
  `∀ b₁ b₂, h b₁ = h b₂ → b₁ = b₂`. Stated for any
  `ByteArray → ByteArray` (composes with future adaptors). This is
  **not** a Lean axiom; the injectivity theorems take `hcf :
  CollisionFree hashBytes` as a hypothesis, so the conclusions are
  **conditional** on real-world keccak256 collision resistance.

### EIP-712 type strings (line 190–205)

* Domain type: `EIP712Domain(string name,string version,uint256
  chainId,uint256 rollupId,bytes verifyingContract)` — five fields.
  Notably `verifyingContract` is declared `bytes` (not the standard
  `address`) so the spec's hash-before-encoding rule applies and
  the Lean `hashBytes p.verifyingContract` matches what a
  spec-compliant wallet computes. Module docstring (lines 36–73)
  explicitly carves out this convention as a deliberate "hash-based
  canonicalisation" form.
* Action type: `KnomosisAction(bytes32 actionHash,uint64 signer,uint64
  nonce,bytes deploymentId)` — four fields.

### Struct hash encodes all four declared fields (line 376–405)

The module docstring at lines 75–87 documents a historical bug
that has been fixed: an earlier `eip712StructHash` committed only to
`actionHash` while the type string declared four fields — a real
interop bug. The current implementation
(`structPreHash`, line 376) concatenates `typeHash ‖ actionHash ‖
signer_BE ‖ nonce_BE ‖ hashBytes(depId)` — all four fields, in
EIP-712 order, totalling 5 × 32 = 160 bytes. Theorem
`structPreHash_size` (line 413) confirms 160-byte preimage.

### `encodeUint256BE` (line 236)

Composes `natToBytesLE n 32` + `List.reverse` + `toArray` to produce
32-byte BE encoding. `encodeUint256BE_injective` (line 248) is
conditional on `n < 256 ^ 32` (i.e. < 2^256). The convenience
wrapper `encodeUint256BE_injective_uint64` (line 288) lifts via
`pow_2_64_le_pow_256_32`.

### Headline theorem — `eip712Wrap_injective` (line 500)

```
theorem eip712Wrap_injective
    (hcf : CollisionFree hashBytes) :
    ∀ (m₁ m₂ : Eip712Message) (d : ByteArray),
      eip712Wrap m₁ d = eip712Wrap m₂ d →
      m₁.signInput = m₂.signInput
```

**Conclusion strength — strongest Lean-tractable form.** The
theorem concludes `m₁.signInput = m₂.signInput` (equal sign-input
bytes), not `m₁ = m₂` (equal messages). Lifting bytes-equality to
message-equality requires `signInput` injectivity in `(action,
signer, nonce, deploymentId)` — a separate CBE-encoding property
that the module explicitly leaves to FFI-layer field decomposition
(lines 482–499). Audit verdict: the theorem statement is honest
about what it does and does not prove; the "cryptographically
meaningful" content (no wrap collision under CR) is captured.

Proof structure (lines 505–573) is careful byte-level append
injectivity via the helper `byteArray_append_inj_of_size_left`
(line 156); peels typeHash ++ actionHash ++ signer ++ nonce ++
hashedDep one boundary at a time. Each size hypothesis is
discharged via `ByteArray.size_append` + per-field size lemmas.

### Theorem 25 — `eip712DomainSeparator_distinguishes` (line 677)

```
theorem eip712DomainSeparator_distinguishes
    (hcf : CollisionFree hashBytes)
    (p₁ p₂ : DomainParams)
    (hcb₁ : p₁.chainId < 256 ^ 32) (hcb₂ : p₂.chainId < 256 ^ 32)
    (hrb₁ : p₁.rollupId < 256 ^ 32) (hrb₂ : p₂.rollupId < 256 ^ 32)
    (h_neq : p₁ ≠ p₂) :
    eip712DomainSeparator p₁ ≠ eip712DomainSeparator p₂
```

Helper `domainPreHash_injective` (line 604) carries the per-field
peel chain (verifyingContract → rollupId → chainId → version →
name). Real-world bounded-input hypotheses (chainId, rollupId in
uint64 range) are well within the `< 256^32` requirement.

### Theorem 26 — `eip712Wrap_distinguishes` (line 711)

Composition. Given equal wraps with same-size domain separators,
concludes `d₁ = d₂ ∧ m₁.signInput = m₂.signInput`.

### Documentation drift

None observed. The "Struct hash encodes all four declared fields"
section (lines 75–87) is a model of honest disclosure of a
prior-version bug and its fix.

---

## 4. `HashAdaptor.lean` (210 lines, Workstream A.2)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/HashAdaptor.lean`

### Imports (HashAdaptor.lean:63)

```
import LegalKernel.Runtime.Hash
```

Reasonable.

### What this module is — documentation + KAT vectors

This module is **documentation, constants, and stability theorems**,
not a hash implementation. The actual keccak256 lives in a Rust
crate (`runtime/knomosis-hash-keccak256`) linked via `@[extern]`
against the opaque `hashBytes`.

* `keccak256AdaptorIdentifier` (line 81) — the 27-byte ASCII id
  `"keccak256/EVM-compatible/v1"`. The runtime introspects this at
  startup (per Audit-3.1) and fail-fasts if the production binding
  is not linked.
* `isKeccak256Linked` (line 90) — checks the runtime
  `hashImplementationIdentifier`. **At the Lean level this always
  returns `false`** — the fallback identifier is what
  `hashImplementationIdentifier` reports without `@[extern]`
  override. Production deployments override via the
  `knomosis_hash_identifier` C ABI symbol.
* KAT vectors (lines 104–138) — keccak256("") / "abc" /
  "Hello, World!" / 0x00. Each is 32 bytes. The size theorems
  (`kat_empty_size` etc., lines 195–204) lock the width.
* `expectedFallbackEmptyHash` (line 152) — FNV-1a-64 offset basis +
  24 zero pad. **Lean-side fallback** ; production never sees this.

### Trust assumptions surfaced

The module docstring (lines 40–44) is explicit:

> The collision-resistance assumption on the linked binding is a
> *trust assumption*, not a Lean axiom; the kernel's state-root
> guarantees hold for any `hashBytes` implementation that respects
> the `hashBytes_size` and `hashBytes_deterministic` contracts.

Stability theorems re-state `hashBytes_size` (`hashAdaptor_thirty_two_byte_output`, line 171) and `hashBytes_deterministic`
(`hashAdaptor_deterministic`, line 177) in the Bridge namespace as
forwarders.

### Sharpness

The §5.2 acceptance test ("32/32 goldens match against `geth`")
runs in the **Rust adaptor's test suite**, not at the Lean level
(line 55–60). At the Lean level only the interface contract is
exercised. Auditors verifying production deployments must
independently confirm the Rust crate's KAT correspondence — the
Lean test cannot do this because `isKeccak256Linked` is always
`false` at the Lean level.

---

## 5. `VerifyAdaptor.lean` (217 lines, Workstream A.1)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/VerifyAdaptor.lean`

### Imports (VerifyAdaptor.lean:58)

```
import LegalKernel.Authority.Crypto
```

Reasonable.

### Cryptographic adaptors — opaque vs. verified

`Verify : PublicKey → ByteArray → Signature → Bool` is opaque
(declared in `LegalKernel/Authority/Crypto.lean`). The Lean-level
fallback returns `false` for every input (line 137–139). Production
deployments wire `knomosis_verify` via `@[extern]`.

* `secp256k1Order` (line 90) — `0xFFFFFFFFFF…CD0364141`, the
  secp256k1 group order.
* `secp256k1HalfOrder` (line 95) — `secp256k1Order / 2`.
* `secp256k1OrderBytes` (line 101) — the 32-byte BE encoding of `n`.
* `ecdsaSignatureSize := 65` (line 112).
* `ecdsaPublicKeyCompressedSize := 33`,
  `ecdsaPublicKeyUncompressedSize := 65` (lines 118–123).
* `verifyAdaptorIdentifier := "ecdsa-secp256k1-low-s/EVM-compatible/v1"` (line 131).

### Low-s predicate (line 162)

`isLowS s := decide (s ≤ secp256k1HalfOrder)`. Stability theorems
`isLowS_zero`, `isLowS_at_threshold`, `isLowS_just_below_order`
(lines 196–215) lock the EIP-2 / BIP-62 threshold.

### Trust assumptions surfaced

Module docstring (lines 34–37):

> Bugs here are documentation drift; the kernel's authority guarantees
> hold for any `Verify` implementation, and the EUF-CMA assumption on
> the linked binding is a *trust assumption*, not a Lean axiom.

`Verify_deterministic` (line 182) is the only behavioural theorem —
proved by `rfl` since `Verify` is opaque. There is no Lean-level
proof of EUF-CMA security.

### Sharpness

The §5.1 acceptance ("100/100 signs round-trip; 0/100 random triples
accept") runs in the Rust adaptor's test suite (lines 49–55). The
Lean-level malleability mitigation is documentation-only:
`secp256k1Order` and `secp256k1HalfOrder` are reference constants
that the **Rust** adaptor uses to reject high-s signatures; the
Lean kernel proofs (`replay_impossible`, `nonce_uniqueness`) reason
about nonces, not signatures.

---

## 6. `BridgeActor.lean` (376 lines, Workstream B.3)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/BridgeActor.lean`

### Imports (BridgeActor.lean:80–81)

```
import LegalKernel.Authority.Action
import LegalKernel.Authority.Identity
```

Reasonable.

### Bridge-actor policy — only L1-derivable actions admitted

* `bridgeActor : ActorId := 0` (line 101). The reservation is by
  convention: `AddressBook.empty.nextActorId = 1` (at audit time), so
  assigned ids never collide.  *(Update — Workstream GP.7.1 advanced
  the genesis `nextActorId` to `3`, additionally reserving `ActorId 1`
  / `2` for `gasPoolActor` / `sequencerActor`; the same collision-free
  property holds, now pinned by `addressBook_empty_nextActorId` and
  `empty_assign_id_avoids_reserved`.  Line numbers in this audit are
  pre-GP and have since drifted.)*
* `bridgeAuthorizedAction` (line 119) — explicit allowlist:
    * `replaceKey` → `true`
    * `registerIdentity` → `true`
    * `deposit` → `true`
    * **all others (including `withdraw`)** → `false`.
* `bridgePolicy` (line 139) — authorizes iff signer = bridgeActor
  AND the action is in the allowlist.

### Headline theorems — bridgePolicy admits and rejects

**Admits (positive):**

* `bridgePolicy_authorizes_replaceKey` (line 244, §12.9 #35).
* `bridgePolicy_authorizes_registerIdentity` (line 253, §12.9 #36).
* `bridgePolicy_authorizes_deposit` (line 262, §12.9 #34).

**Rejects (negative):** the policy explicitly rejects
`transfer`, `mint`, `burn`, `freezeResource`, `reward`,
`distributeOthers`, `proportionalDilute`, `dispute`,
`disputeWithdraw`, `verdict`, `rollback`, `declareLocalPolicy`,
`revokeLocalPolicy`, `faultProofChallenge`, `faultProofResolution`,
**and `withdraw`** (lines 151–339). Each is a one-line
`unfold + intro + absurd + simp [bridgeAuthorizedAction]` proof.

**Sharpness — withdraw is intentionally rejected (line 285).**
The `bridgePolicy_rejects_withdraw` theorem and the audit-1
narrative at lines 122–129 + 269–289 carve out the design choice:
withdrawals are user-initiated; the bridge actor must NOT have the
ability to drain a user's L2 balance via a coordinated withdrawal
it could later forge an L1 redemption proof for. This closes a
coordinated-attack vector. The audit verdict: this is a real
defensive property and is mechanised, not just documented.

### Cross-actor rejection (line 350)

`bridgePolicy_rejects_non_bridge_signer` — even on otherwise-permitted
actions, a non-bridge signer is rejected. Sanity-check examples at
lines 359–373 confirm by `rfl` / `decide`.

---

## 7. `Admissible.lean` (467 lines, Workstream C.0)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/Admissible.lean`

### Imports (Admissible.lean:61–63)

```
import LegalKernel.Authority.SignedAction
import LegalKernel.Bridge.State
import LegalKernel.Bridge.BridgeActor
```

Reasonable.

### `Action.isBridgeOnly` (line 94)

```
def Action.isBridgeOnly : Action → Bool
  | .registerIdentity _ _ => true
  | .deposit _ _ _ _      => true
  | _                     => false
```

**Sharpness — `withdraw` is NOT bridge-only.** Lines 70–87 are
explicit: an earlier version classified `withdraw` as bridge-only,
which would have forced every withdrawal to be bridge-actor-signed,
contradicting the user-initiated flow. Workstream-C audit-1 removed
`withdraw` from this set. This is the same defensive property
mechanised in `BridgeActor.lean`'s `bridgePolicy_rejects_withdraw`.

### `applyActionToBridgeState` (line 110)

Per-action state-update helper. Identity for all non-bridge actions.
For `deposit`: `bs.markConsumed d ({ resource := r, amount := amount })`.
For `withdraw`: `bs.appendWithdrawal { resource, recipient, amount,
l2LogIndex }`. Note the smoke-check `applyActionToBridgeState_non_bridge`
(line 125) enumerates **every** Action constructor case-by-case via
`cases hact : action with | transfer ... | mint ... | ...` — explicit
listing exhausts the inductive (line 131–150). Any future action
constructor added to the `Action` inductive must be classified here
or build will break — an enforcement mechanism, not a hidden
catch-all.

### `BridgeAdmissibleWith` (line 175)

Conjunction of five existing kernel conjuncts + three new:

```
AdmissibleWith verify P deploymentId es st ∧
(∀ r recipient amount depositId,
  st.action = .deposit r recipient amount depositId →
  es.bridge.consumed.contains depositId = false) ∧             -- (6)
(∀ actor pk,
  st.action = .registerIdentity actor pk →
  es.registry[actor]? = none) ∧                                 -- (7)
(Action.isBridgeOnly st.action = true → st.signer = bridgeActor) -- (8)
```

Each new conjunct fires only on its respective action variant
(vacuous truth for others), so `BridgeAdmissibleWith` collapses to
`AdmissibleWith` on non-bridge actions.

### Projections (lines 194–232)

`toAdmissibleWith`, `depositIdFresh`, `registrationFresh`,
`bridgeOnlySigner`. Each is a single-line tuple projection.

### Deposit replay-prevention proofs

* `deposit_marks_consumed` (line 350) — after applying a deposit
  for id `d`, `consumed.contains d = true`. Direct application of
  `TreeMap.contains_insert_self`.
* `deposit_replay_blocked_by_consumed` (line 373) — direct
  contradiction form: after applying a deposit for `d`,
  `consumed.contains d` cannot be `false`. The second admissibility
  attempt fails conjunct (6).

### Withdraw nonce-bump proof

`withdraw_bumps_nextWdId` (line 391) — after applying a withdrawal,
post-state `nextWdId = pre-state nextWdId + 1`. Direct `rfl` after
unfolding `applyActionToBridgeState` and `appendWithdrawal`. The
proof is structural: distinct withdrawals get distinct ids by
construction, so no two withdrawal entries can ever share an index.

### Bridge-aware replay-impossible (line 415)

`bridge_replay_impossible` — composition of `replay_impossible`
(kernel) with the three per-field agreement theorems
(`apply_bridge_admissible_with_base_agrees`,
`_nonces_agrees`, `_registry_agrees` at lines 286–312). The
bridge-aware post-state agrees with the kernel-aware post-state on
`base`, `nonces`, `registry`, so kernel admissibility transfers.

### Sharpness

* The deposit-id-uniqueness conjunct (6) only protects against
  replay **within** the bridge lifetime once an id has been
  assigned. As noted in `State.lean`'s audit (above), the
  projection `L1 deposit hash → DepositId : Nat` must be injective
  — that obligation is on the runtime adaptor, not Lean.
* The `apply_admissible_with_preserves_bridge` theorem (line 268)
  is a `rfl` lemma — the kernel-level entry point never touches
  the new `bridge` field. This is the bridge-aware extension's
  structural cleanliness.

---

## 8. `Accounting.lean` (513 lines, Workstream C.6)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/Accounting.lean`

### Imports (Accounting.lean:39–44)

```
import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Bridge.State
import LegalKernel.Bridge.Admissible
import LegalKernel.Laws.Deposit
import LegalKernel.Laws.Withdraw
```

Reasonable. Pulls in Conservation (TotalSupply functional) and the
two new bridge laws.

### Quantity functionals (lines 53–84)

* `PendingWithdrawal.amountAt` / `DepositRecord.amountAt` (lines 59
  / 65) — per-resource projection.
* `totalWithdrawn` (line 74) — `es.bridge.pending.foldl ...`.
* `totalDeposited` (line 82) — `es.bridge.consumed.foldl ...`.

Genesis lemmas (lines 90, 105) establish zero deposit / withdrawal
at genesis via `TreeMap.isEmpty_toList`.

### Per-action accounting deltas

The cross-cutting lemma `accounting_delta_non_bridge` (line 186)
discharges every non-bridge action via
`apply_bridge_admissible_with_preserves_bridge_for_non_bridge` +
`*_unchanged_when_bridge_eq`. Then the per-constructor delta
lemmas (`accounting_delta_transfer`, `_freeze`, `_replaceKey`,
`_registerIdentity`, `_declareLocalPolicy`, `_revokeLocalPolicy`,
`_faultProofChallenge`, `_faultProofResolution`) each peel off the
constructor via `obtain ⟨...⟩ := hact` and forward to
`accounting_delta_non_bridge`.

For `deposit` / `withdraw`, helper lemmas
`applyActionToBridgeState_deposit` (line 409) and
`applyActionToBridgeState_withdraw` (line 435) unfold the
mutator to its `markConsumed` / `appendWithdrawal` form (`rfl`
proofs). These are the pivots for any future
`bridge_supply_account` chain proof.

### What is NOT shipped (line 241–263)

The module docstring is explicit about a deferral:

> The plan's headline `bridge_supply_account_general` (§7.6.4) and
> `bridge_supply_account` (§7.6.5) are stated over a
> `ReachableViaLaws`-style chain that closes under
> `apply_bridge_admissible_with`. Lifting `ReachableViaLaws` from
> `State` to `ExtendedState` requires a custom inductive predicate;
> Phase-3 / Phase-4-prelude / Phase-6 do not currently expose such a
> predicate.
>
> Workstream C ships the **per-action accounting deltas** here at
> the unit-step level...

The per-step deltas are complete. The inductive chain — `for all
reachable extended states, deposits + genesis = supply +
withdrawals` — is **not shipped at the Lean level**; the docstring
defers it to runtime cross-stack verification. This is an
**important caveat**: the headline §7.6 equation has per-step
witnesses but no top-level theorem. Auditors checking the
accounting picture should rely on the per-step deltas, the
unit-test acceptance criterion (4-step trace `[deposit, transfer,
withdraw, transfer]`), and the Solidity-side cross-stack
verification under Workstream F.

### Documentation drift

The CLAUDE.md status table claims "E-C: Complete (Lean side;
chain-level §7.6.4 / §7.6.5 follow-up)" — accurate.

---

## 9. `WithdrawalRoot.lean` (1,088 lines, Workstream D.1)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/WithdrawalRoot.lean`

This is the largest file in the Bridge layer. Audit in detail.

### Imports (WithdrawalRoot.lean:101–104)

```
import LegalKernel.Bridge.State
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Bridge.Eip712
import LegalKernel.Encoding.State
```

Reasonable. Pulls in HashAdaptor (for stability theorems), Eip712
(for the `CollisionFree` predicate), and Encoding.State (for
`zeroHash`, `Bridge.PendingWithdrawal.encode`).

### SMT shape (lines 113–168)

* `smtHeight := 64` (line 117). The fixed tree height — matches the
  `WithdrawalId < 2^64` encoding bound.
* `emptyLeafHash := zeroHash` (line 121). 32-byte all-zero
  sentinel (Audit-3.1 zero-hash convention).
* `defaultHash` (line 132) — bottom-up precomputed empty-subtree
  hash. `defaultHash 0 = emptyLeafHash`; `defaultHash (i+1) = H
  (defaultHash i ++ defaultHash i)`.
* `pathBitAtLevel idx level` (line 154) — LSB-up bit convention.
* `hashUp` (line 161) — sibling order: `right? ⇒ H (sib ++ cur)`;
  else `H (cur ++ sib)`.
* `leafBytes wd` (line 173) — canonical CBE encoding of
  `PendingWithdrawal`.

### `rangeRoot` (line 187)

Short-circuits empty entries to `defaultHash H level` (essential —
without this, computing the root of a sparse tree with N entries
would do `2^64 - O(N)` calls on empty subtrees). Sub-tree splits
via `entries.filter (pathBitAtLevel p.1 k = false/true)`.

### `WithdrawalProof` (line 258)

```
structure WithdrawalProof where
  leaf     : ByteArray
  index    : WithdrawalId
  siblings : Vector ByteArray smtHeight
```

Note `siblings : Vector ByteArray smtHeight` — length enforced at
type level.

### Verifier and constructor (lines 271–462)

* `verifyProofRec` (line 271) — recursive descent root-to-leaf.
* `verifyProof` (line 287) — outer wrapper using `decide` on
  ByteArray equality.
* `emptyProofSiblings` (line 301) — `defaultHash` siblings for
  empty subtrees.
* `constructProofAux` (line 329) — short-circuiting recursive
  proof construction.
* `constructProof` (line 454) — outer wrapper that packages the aux
  result into a `WithdrawalProof` with the size proof for the
  Vector.

Both `verifyProof` and `constructProof` mirror `rangeRoot`'s
recursion exactly — this is what makes the §8.1.3 completeness
theorem a structural induction.

### Headline theorem — `verifyProof_complete` (line 644)

```
theorem verifyProof_complete
    (H : ByteArray → ByteArray) (b : BridgeState)
    (idx : WithdrawalId) (wd : PendingWithdrawal)
    (_h : b.pending[idx]? = some wd) :
    verifyProof H (constructProof H b idx) (withdrawalRoot H b) = true
```

**Unconditional in H** — no `CollisionFree` hypothesis required.
Completeness is a structural recursion identity. Direct corollary of
`verifyProof_complete_any_index` (line 627), which in turn rests on
`verifyProofRec_eq_rangeRoot` (line 528) — a structural induction
on the recursion depth.

### Headline theorem — `verifyProof_sound` (line 1004)

```
theorem verifyProof_sound
    {H : ByteArray → ByteArray} (hCF : CollisionFree H)
    (h_uniform : UniformOutputSize H 32)
    (b : BridgeState) (proof : WithdrawalProof)
    (h_leaf_size :
      proof.leaf.size = (constructProof H b proof.index).leaf.size)
    (h_sibs_match :
      siblingsHaveMatchingSizes
        proof.siblings.toList
        (constructProof H b proof.index).siblings.toList)
    (hVerify : verifyProof H proof (withdrawalRoot H b) = true) :
    proof.leaf = (constructProof H b proof.index).leaf ∧
    proof.siblings = (constructProof H b proof.index).siblings
```

**Hash-conditional.** Soundness rests on:

1. `CollisionFree H` — `H x = H y → x = y`.
2. `UniformOutputSize H 32` — `∀ b, (H b).size = 32`.
3. `proof.leaf.size = canonical.leaf.size` (caller-supplied).
4. `siblingsHaveMatchingSizes` (caller-supplied) — element-wise size
   match between user-supplied and canonical sibling lists.

**Sharpness — runtime adaptor obligation (lines 977–990).** The
size hypotheses (3) and (4) are **deployment-correctness
obligations on the runtime adaptor**, not enforced by Lean. The
adaptor's documented proof-validation flow is:

1. Compute the canonical proof for `proof.index` (Lean-side).
2. Compare proof's and canonical's leaf sizes — reject on mismatch.
3. Element-wise compare proof's and canonical's sibling sizes —
   reject on mismatch.
4. Invoke the verifier — reject if it doesn't accept.

If the runtime adaptor fails to enforce the size-match guards, the
soundness theorem **does not apply** — a malformed proof could
verify against a valid root without being canonical. This is
disclosed but not enforced.

### Why the variable-size siblings? (lines 962–976)

The leaf-adjacent canonical sibling can be `leafBytes wd` (variable
size, ~56 bytes) when the OTHER leaf in the deepest pair is also
populated. For sequentially-assigned WithdrawalIds, ids 2k and 2k+1
always share a deepest pair, so for k > 0 the canonical
leaf-adjacent sibling is variable-sized whenever the peer id is
also mapped. The `siblingsHaveMatchingSizes` relaxation handles
this; a corollary `verifyProof_sound_all_32` (line 1070) supplies
the dense-32-byte form when applicable.

### Soundness conclusion strength

The theorem concludes `proof.leaf = canonical.leaf ∧ proof.siblings
= canonical.siblings`. The integration plan §8.1.4's existential
form (`∃ wd, b.pending[idx]? = some wd ∧ proof.leaf = encode wd`)
is **not** the theorem statement; the existential form is mentioned
as a corollary that follows by case analysis on `b.pending[idx]?`
plus the lemma `constructProofAux_leaf_singleton` (line 916). The
existential-form theorem is **not** present in this file as a
named theorem.

### Sharpness — WithdrawalId bound (lines 56–78)

The SMT consults `smtHeight = 64` bits of each WithdrawalId. Two
WithdrawalIds whose low 64 bits agree map to the same SMT
position. The runtime adaptor must enforce the < 2^64 bound at the
bridge boundary (typically by typing `nextWdId` as `UInt64`).
This module uses `Nat` for arithmetic flexibility but does not
enforce boundedness. Outside the bound, aliasing can occur. The
kernel-level theorems state claims at the ByteArray level, so
aliasing affects which WithdrawalId is 'pointed at' by a verifying
proof, not whether the proof itself verifies.

### Documentation drift

None observed. The proof structure ("parallel recursive descents")
in the module docstring matches the actual definitions.

---

## 10. `WithdrawalProof.lean` (146 lines, Workstream D.2)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/WithdrawalProof.lean`

### Imports (WithdrawalProof.lean:34–35)

```
import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Runtime.Snapshot
```

Reasonable.

### `Snapshot.bridgeWithdrawalRoot` (line 61)

Decodes `snap.encodedState` to an `ExtendedState`, then applies
`withdrawalRoot hashBytes` to the bridge field. On decode failure,
returns `withdrawalRoot hashBytes BridgeState.empty` (the
`defaultHash smtHeight` sentinel) — described as a
"deployment-correctness issue, not a redemption-validity issue".

**Sharpness — fallback on decode failure.** If the encoded state
fails to decode, the function returns the empty-tree sentinel. This
is a **silent** failure mode: an L1 contract consuming this root
would see the same value as a genesis state. The redemption
attempt would then fail (no withdrawal in pending), but the
auditor should note: there is no error path surfaced to the caller
beyond the sentinel. The caller `extractProof` (line 85) handles
this correctly (returns `none` on decode failure), but a different
caller using `bridgeWithdrawalRoot` directly might be surprised.

### `extractProof` (line 85)

Returns `none` if decode fails or `idx ∉ pending`; otherwise
returns `some (constructProof hashBytes es.bridge idx)`.

### `extractProof_consistent_with_root` (line 104)

Headline theorem: if `extractProof` returns a proof, that proof
verifies against the snapshot's withdrawal root. Proof: case-split
on decode + pending lookup; in the happy path, apply
`verifyProof_complete`.

### Determinism (lines 133–143)

`extractProof_deterministic`, `bridgeWithdrawalRoot_deterministic`
— both `rw [h]` proofs.

---

## 11. `Finalisation.lean` (315 lines, Workstream D.3)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/Finalisation.lean`

### Imports (Finalisation.lean:41–42)

```
import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Disputes.Filing
```

Reasonable.

### `FinalisableSnapshot` (line 68)

Wraps `Runtime.Snapshot` with:

* `submitL1Block` — L1 block at which the state root was submitted.
* `logIndexLow` / `logIndexHigh` — `[low, high)` range of log
  indices the snapshot covers.

### `hasUpheldInRange` (line 94)

Forward walk over the log range; returns `true` iff any index has
an upheld dispute. Has explicit fuel parameter (line 95) to assure
termination. The fuel is `toIdx - fromIdx`.

### `isFinalised` (line 112)

Two conjuncts:

1. `currentL1Block ≥ submitL1Block + disputeWindowBlocks`
2. `!hasUpheldInRange log fsnap.logIndexLow fsnap.logIndexHigh`

### Headline theorem — `isFinalised_monotonic_in_currentBlock` (line 124)

```
theorem isFinalised_monotonic_in_currentBlock
    (fsnap : FinalisableSnapshot) (b₁ b₂ : Nat) (w : Nat)
    (log : List LogEntry)
    (h_le : b₁ ≤ b₂)
    (h_fin : isFinalised fsnap b₁ w log = true) :
    isFinalised fsnap b₂ w log = true
```

Direct proof: split the `&&`, transitively extend the maturity
bound. The "no new upheld disputes" conjunct is automatically
preserved since `log` is the same.

**Sharpness — log argument is fixed (line 122–123).** The theorem
holds for **fixed log**. If the log accumulates new upheld
disputes between `b₁` and `b₂`, the predicate could flip
back to `false`. The theorem statement makes this explicit by
taking a single `log` argument; the docstring (lines 119–123) is
careful to flag the caveat.

### Second headline theorem — `isFinalised_implies_no_upheld_against` (line 220)

Hash-free Lean theorem: a finalised snapshot's covered log range
has no upheld disputes. Direct from `hasUpheldInRange_false_implies`
(line 141) via the induction-on-fuel argument at lines 152–215.

### `extractFinalisedProof` (line 262) and consistency

`extractFinalisedProof` combines finalisation gating with
`extractProof`. The composition theorem
`extractFinalisedProof_consistent_with_root` (line 276) lifts the
§8.2 consistency claim through the finalisation gate.

---

## 12. `Ingest.lean` (527 lines, Workstream B.2)

**Path:** `/home/user/Knomosis/LegalKernel/Bridge/Ingest.lean`

### Imports (Ingest.lean:79–82)

```
import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Authority.Action
import LegalKernel.Authority.Crypto
```

Reasonable.

### `L1Event` inductive (line 104)

Three constructors:

* `identityRegistered (addr : EthAddress) (pk : PublicKey) (blockNum logIdx : Nat)`
* `identityRevoked (addr : EthAddress) (blockNum logIdx : Nat)`
* `depositInitiated (addr : EthAddress) (resource : ResourceId) (amount : Amount) (receiptHash : ByteArray) (blockNum logIdx : Nat)`

`L1Event.address` (line 133) extracts the address — useful for the
per-address commutativity theorem.

### `UnsignedBridgeAction` (line 149)

`{ action : Action, signer : ActorId, nonce : Nonce }`. Signer is
always `bridgeActor` by construction.

### `ingest` (line 196) — total over `L1Event`

* `identityRegistered`: dispatches on `b.lookup addr`. `none` →
  `assign` and emit `Action.registerIdentity id pk`. `some id` →
  no AddressBook update; emit `Action.replaceKey id pk`.
* `identityRevoked` → `(b, none)` (revocation is a deployment-policy
  concern; no kernel-level "revoke" action).
* `depositInitiated` → `(b, none)` (reserved for Workstream C's
  `Action.deposit`).

**Sharpness — depositInitiated returns none (line 222–229).**
Despite the existence of `Action.deposit` and the
`bridgePolicy_authorizes_deposit` theorem, the **ingest function
itself does NOT emit a `deposit` action** for `depositInitiated`
events. The module docstring (lines 41–45) explains this is the
MVP boundary: the runtime adaptor routes deposit events through
this branch but the actual balance-credit semantics live in C.2 /
C.4, not in `ingest`. An auditor following the pipe end-to-end
should note this: the L1 → L2 deposit flow at the Lean level
**stops** at the address-book ingest; the bridge-side application of
`Action.deposit` happens via a separate runtime-adaptor path that
constructs the SignedAction directly. This is documented but is a
sharp surprise — the ingest module's name suggests a complete
pipeline.

### Headline theorems

* `ingest_emits_bridge_actor` (line 241) — when `ingest` returns
  `some ub`, then `ub.signer = bridgeActor`. Proof: cases on event;
  the two `identityRegistered` sub-cases construct the envelope
  with `signer := bridgeActor`; `identityRevoked` / `depositInitiated`
  return `none` (vacuous).
* `ingest_preserves_lookup_for_other_addresses` (line 274) — locality
  on the AddressBook for addresses other than the event's address.
* `ingest_lookup_isSome_pre_invariant` (line 314) — isSome status
  at any address depends only on pre-state isSome status + event
  variant.
* `ingest_lookup_equivalent_for_distinct_addresses` (line 387) — per-
  address value-level equivalence after two independent ingests
  at addresses NOT touching either event.
* `ingest_isSome_equivalent_for_distinct_addresses` (line 426) —
  full per-address isSome-equivalence after two independent
  ingests, including addresses that touch the events.

### `ingest_preserves_consistent` (line 491)

`ingest` preserves the AddressBook's `Consistent` invariant under
freshness. Only the `identityRegistered` fresh case mutates the
book (via `assign`), so this reduces to
`AddressBook.assign_preserves_consistent`.

### Ingest totality

`ingest` is total: every `L1Event` produces a well-typed
`AddressBook × Option UnsignedBridgeAction`. No partial functions,
no `IO`, no `Decidable`-by-classical-choice. Determinism is
automatic.

---

## Cross-cutting observations

### What is opaque vs. verified

| Symbol         | Status      | Trust assumption                              |
|----------------|-------------|------------------------------------------------|
| `hashBytes`    | `opaque`    | keccak256 (collision-resistant in production) |
| `Verify`       | `opaque`    | secp256k1 ECDSA (EUF-CMA in production)       |
| `CollisionFree`| `Prop`      | not an axiom; supplied as theorem hypothesis  |

The `#print axioms` discipline in CLAUDE.md applies: no custom
axioms are introduced. The opaque declarations do not show up in
`#print axioms` output for theorems that use them.

### What is enforced at the Lean level vs. runtime-adaptor obligation

| Property                                  | Lean-enforced | Runtime obligation |
|-------------------------------------------|:-------------:|:------------------:|
| EIP-712 wrap byte structure               |       Y       |          –         |
| EIP-712 wrap injectivity (under CR)       |       Y       |          –         |
| keccak256 collision-resistance            |       –       |    Y (via Rust)    |
| ECDSA secp256k1 EUF-CMA                   |       –       |    Y (via Rust)    |
| Low-s malleability rejection              |       –       |    Y (via Rust)    |
| DepositId projection injectivity          |       –       |          Y         |
| AddressBook freshness on `assign`         |       –       |          Y         |
| Bridge actor reservation at id 0          |       Y       |          –         |
| `bridgePolicy` rejects non-bridge actions |       Y       |          –         |
| `bridgePolicy_rejects_withdraw`           |       Y       |          –         |
| Deposit replay blocked by `consumed`      |       Y       |          –         |
| Withdraw bumps `nextWdId`                 |       Y       |          –         |
| SMT verifyProof completeness              |       Y       |          –         |
| SMT verifyProof soundness                 |  Conditional  |    Y (size check)  |
| Finalisation monotonicity                 |       Y       |          –         |
| WithdrawalId < 2^64 bound                 |       –       |          Y         |
| L1 attestation semantics                  |       –       |          Y         |

### Sharpest items to flag

1. **DepositId projection (State.lean:88–115).** The L1 receipt
   hash (~256 bits) must be projected to a 64-bit DepositId. Two
   suggested projections — keccak256 prefix or sequential
   contract-side counter — are both deployment-correctness
   obligations. A weak projection allows two L1 deposits to collide
   on Knomosis's DepositId; conjunct 6 (uniqueness in `consumed`) only
   protects within the chosen projection.
2. **`verifyProof_sound` size hypotheses (WithdrawalRoot.lean:1004).**
   Soundness conclusion requires caller-supplied `h_leaf_size` and
   `h_sibs_match` hypotheses. The runtime adaptor must enforce
   these by comparison against the canonical proof. Lean does not
   automatically enforce this.
3. **`Snapshot.bridgeWithdrawalRoot` decode-failure sentinel
   (WithdrawalProof.lean:61).** Silent fallback to the empty-tree
   root on decode failure. Acceptable because `extractProof` catches
   this, but direct callers of `bridgeWithdrawalRoot` would not see
   the failure.
4. **`ingest` does not emit `deposit` actions (Ingest.lean:222–229).**
   Despite `Action.deposit` existing and being authorised by
   `bridgePolicy`, the ingest function returns `none` for
   `depositInitiated`. The deposit flow at the Lean level relies on
   a separate runtime-adaptor path that constructs the SignedAction
   directly. The module docstring discloses this but it is a
   "name vs. behaviour" mismatch worth flagging.
5. **`bridge_supply_account_general` / `bridge_supply_account` not
   shipped (Accounting.lean:241–263).** The headline §7.6.4 / §7.6.5
   chain-level accounting theorems are deferred to runtime cross-
   stack verification. Per-step deltas are complete; the inductive
   chain is not at the Lean level.
6. **`isFinalised_monotonic_in_currentBlock` requires fixed log
   (Finalisation.lean:124).** Monotonicity is in `currentL1Block`,
   not in time generally. New upheld disputes appearing later could
   un-finalise a previously-finalised snapshot. The theorem
   statement is careful to take a single `log` argument.

### What is not explicitly asserted but should be

* **`UniformOutputSize hashBytes 32` is a hypothesis in
  `verifyProof_sound`, not a derived property.** The HashAdaptor
  module's `hashAdaptor_thirty_two_byte_output` theorem
  (HashAdaptor.lean:171) states that the output is 32 bytes, but
  this is via `hashBytes_size` — a property of the production
  binding that the Lean fallback respects. No Lean-level proof
  links the two; the user of `verifyProof_sound` must supply
  `UniformOutputSize hashBytes 32` as a hypothesis (which is
  trivially `fun _ => hashBytes_size _`).

### Documentation drift

CLAUDE.md status table claims Workstreams A–D, LP, LX, H are
complete (Lean side). For Bridge files specifically:

* E-A (cryptographic adaptors): complete (Lean side). Verified.
* E-B (identity and authority): complete (Lean side). Verified.
* E-C (bridge laws): complete (Lean side; chain-level §7.6.4 /
  §7.6.5 follow-up). Verified — per-step deltas in Accounting are
  complete; chain-level theorem is deferred as documented.
* E-D (withdrawal proofs): complete. Verified.

No drift observed. The module docstrings consistently match the
implementation; deferrals are explicit.

### Per-axiom check

The audit did not run `#print axioms` against each headline
theorem (this would be a build-time check); but the CLAUDE.md
status note "`#print axioms` on every kernel, Phase-2, Phase-3,
Phase-4, Phase-5, Phase-6, and Workstream-H theorem returns a
subset of `[propext, Classical.choice, Quot.sound]`" implicitly
covers the Bridge layer's headline theorems (which are all
admissibility / encoding / SMT theorems built on these foundations).
The `CollisionFree` and `UniformOutputSize` and size hypotheses
are function arguments, not axioms.
