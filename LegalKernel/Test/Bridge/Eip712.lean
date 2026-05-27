/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.Eip712 — Workstream A.3 stability + correctness tests.

The Lean-level acceptance contract for the EIP-712 wrap module
(see `LegalKernel/Bridge/Eip712.lean`).  Covers:

  * **Shape tests.**  The wrap begins with the EIP-712 magic bytes
    `0x19 0x01`; the domain separator and struct hash both produce
    32-byte outputs; the full wrap has the documented size formula.
  * **Determinism tests.**  The wrap is deterministic on equal inputs
    (trivially true; restated as a value-level test for forward
    protection).
  * **Cross-deployment / cross-action / cross-signer
    distinguishability.**  Distinct deployment IDs / chain IDs /
    actions / signers / nonces produce distinct wraps.  These are
    the value-level analogues of theorems #25 and #26.
  * **Cross-protocol distinguishability.**  An EIP-712-wrapped
    `signInput` produces bytes structurally distinct from a plain
    Knomosis `signedActionDomain`-prefixed `signInput` (Audit-2 cross-
    protocol property; A.3 §5.3 inherits this test).
  * **Term-level API stability** for theorems #24, #25, #26 plus
    auxiliary lemmas (encodeUint256BE_injective,
    domainPreHash_injective, etc.).

Note: theorems #24 and #25 are stated under the
`CollisionFree hashBytes` hypothesis.  At the Lean level this
hypothesis is *false* (the FNV-1a-64 fallback is not collision-free
in 64 bits), so we cannot exercise the headline implications at the
value level — we exercise the API stability instead.  The Rust
adaptor's tests check the implications under a real keccak256
binding.
-/

import LegalKernel
import LegalKernel.Bridge.Eip712
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace Eip712Tests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Runtime
open LegalKernel.Bridge
open LegalKernel.Test

/-! ## Test fixtures -/

/-- A canonical test domain.  Used as the default in fixture
    construction. -/
def testDomain : DomainParams := {
  name := ByteArray.mk "Knomosis".toUTF8.data
  version := ByteArray.mk "1".toUTF8.data
  chainId := 1  -- Ethereum mainnet
  rollupId := 42
  verifyingContract := ByteArray.mk #[
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00  -- 20-byte zero address
  ]
}

/-- An alternative domain (different chainId).  Used for cross-
    deployment distinguishability tests. -/
def altDomain : DomainParams :=
  { testDomain with chainId := 11155111 }  -- Sepolia

/-- A canonical test message. -/
def testMessage : Eip712Message := {
  action := .transfer 1 2 3 4
  signer := 5
  nonce := 7
  deploymentId := ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]
}

/-- An alternative test message (different action). -/
def altMessage : Eip712Message :=
  { testMessage with action := .mint 1 2 100 }

/-! ## Prefix-shape tests -/

/-- The EIP-712 prefix is exactly 2 bytes (0x19, 0x01). -/
def prefixIsTwoBytes : TestCase := {
  name := "eip712Prefix is 2 bytes"
  body := assertEq (expected := 2) (actual := eip712Prefix.size) "prefix size"
}

/-- The first byte of the prefix is 0x19. -/
def prefixFirstByte : TestCase := {
  name := "eip712Prefix[0] = 0x19"
  body := do
    match eip712Prefix.toList with
    | head :: _ => assertEq (expected := (0x19 : UInt8)) (actual := head) "prefix[0]"
    | [] => throw <| IO.userError "prefix empty"
}

/-- The second byte of the prefix is 0x01. -/
def prefixSecondByte : TestCase := {
  name := "eip712Prefix[1] = 0x01"
  body := do
    match eip712Prefix.toList with
    | _ :: second :: _ => assertEq (expected := (0x01 : UInt8)) (actual := second) "prefix[1]"
    | _ => throw <| IO.userError "prefix too short"
}

/-! ## Type-string sanity tests

The type strings declare each field's EIP-712 type (`bytes32`,
`uint256`, `bytes`, `string`, etc.).  A spec-compliant wallet
parses the type string and applies the per-field encoding rule.
These tests pin the type strings to the exact values the Lean
encoder agrees with — a future change that desyncs the type
string from the encoder would fail here. -/

/-- The EIP-712 domain type string declares the five fields in the
    expected order with the documented types.  Used by the wallet
    to determine encoding rules. -/
def domainTypeStringExact : TestCase := {
  name := "eip712DomainTypeString declares 5 fields in EIP-712 order"
  body := assertEq
    (expected := "EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)")
    (actual := eip712DomainTypeString) "domain type string"
}

/-- The Knomosis action type string declares the four fields in the
    order the struct hash encodes them.  Each field's type matches
    the encoding rule the Lean side applies (`bytes32` = verbatim,
    `uint64` = uint256-BE, `bytes` = keccak256-prefixed). -/
def actionTypeStringExact : TestCase := {
  name := "knomosisActionTypeString declares 4 fields matching the struct hash"
  body := assertEq
    (expected := "KnomosisAction(bytes32 actionHash,uint64 signer,uint64 nonce,bytes deploymentId)")
    (actual := knomosisActionTypeString) "action type string"
}

/-- The action type string declares `bytes deploymentId` (not
    `bytes32`) — matching our hash-based canonicalization.  A
    spec-compliant wallet parsing this declaration applies
    `keccak256` to the deploymentId bytes, producing the same
    32 bytes as our `hashBytes m.deploymentId`.

    The exact value comparison (`actionTypeStringExact`) above
    already pins this; this test exists as a focused regression
    catcher with a descriptive name. -/
def actionTypeStringDeploymentIsBytes : TestCase := {
  name := "knomosisActionTypeString declares bytes (not bytes32) for deploymentId"
  body := do
    -- The expected type string ends with "bytes deploymentId)".
    let expected := "KnomosisAction(bytes32 actionHash,uint64 signer,uint64 nonce,bytes deploymentId)"
    assertEq (expected := expected) (actual := knomosisActionTypeString) "deploymentId is bytes"
}

/-- The domain type string declares `bytes verifyingContract` (not
    `address`) — matching our hash-based canonicalization. -/
def domainTypeStringContractIsBytes : TestCase := {
  name := "eip712DomainTypeString declares bytes (not address) for verifyingContract"
  body := do
    let expected :=
      "EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)"
    assertEq (expected := expected) (actual := eip712DomainTypeString)
      "verifyingContract is bytes"
}

/-! ## Domain separator shape tests -/

/-- The domain separator is 32 bytes. -/
def domainSeparatorSize : TestCase := {
  name := "eip712DomainSeparator is 32 bytes"
  body := assertEq (expected := 32) (actual := (eip712DomainSeparator testDomain).size)
    "ds size"
}

/-- The domain pre-hash is 192 bytes (6 × 32). -/
def domainPreHashSize : TestCase := {
  name := "domainPreHash is 192 bytes"
  body := assertEq (expected := 192) (actual := (domainPreHash testDomain).size)
    "preHash size"
}

/-- The domain type hash is 32 bytes. -/
def domainTypeHashSize : TestCase := {
  name := "eip712DomainTypeHash is 32 bytes"
  body := assertEq (expected := 32) (actual := eip712DomainTypeHash.size) "size"
}

/-- The action type hash is 32 bytes. -/
def actionTypeHashSize : TestCase := {
  name := "knomosisActionTypeHash is 32 bytes"
  body := assertEq (expected := 32) (actual := knomosisActionTypeHash.size) "size"
}

/-! ## Wrap shape tests -/

/-- The wrap size matches the documented formula. -/
def wrapSize : TestCase := {
  name := "eip712Wrap size = 2 + domainSep.size + 32"
  body := do
    let ds := eip712DomainSeparator testDomain
    let wrap := eip712Wrap testMessage ds
    assertEq (expected := 2 + ds.size + 32) (actual := wrap.size) "wrap size"
}

/-- The wrap begins with the prefix. -/
def wrapBeginsWithPrefix : TestCase := {
  name := "eip712Wrap begins with eip712Prefix"
  body := do
    let ds := eip712DomainSeparator testDomain
    let wrap := eip712Wrap testMessage ds
    let wrapBytes := wrap.toList
    match wrapBytes with
    | b₀ :: b₁ :: _ =>
      assertEq (expected := (0x19 : UInt8)) (actual := b₀) "wrap[0]"
      assertEq (expected := (0x01 : UInt8)) (actual := b₁) "wrap[1]"
    | _ => throw <| IO.userError "wrap too short"
}

/-- The struct hash is 32 bytes. -/
def structHashSize : TestCase := {
  name := "eip712StructHash is 32 bytes"
  body := assertEq (expected := 32) (actual := (eip712StructHash testMessage).size)
    "struct hash size"
}

/-- The struct pre-hash is 5 × 32 = 160 bytes (typeHash + actionHash +
    signer_BE + nonce_BE + hashedDep), which is direct evidence that
    all four declared message fields are encoded — preventing a
    regression to the historical bug where only `actionHash` was
    encoded. -/
def structPreHashSize : TestCase := {
  name := "structPreHash is 160 bytes (5 × 32, all 4 fields encoded)"
  body := assertEq (expected := 160) (actual := (structPreHash testMessage).size)
    "structPreHash size"
}

/-- Distinct signer values produce distinct struct pre-hashes — direct
    evidence that the `signer` field is part of the struct hash
    encoding (and not just indirectly via `actionHash`).  Catches the
    regression where `eip712StructHash` only encoded `actionHash`
    (in which case the struct hash would still differ since
    `actionHash` depends on `signer` via `signInput`, but the
    structPreHash size would be 64 not 160). -/
def structPreHashContainsSigner : TestCase := {
  name := "structPreHash differs across signers"
  body := do
    let m1 := { testMessage with signer := 100 }
    let m2 := { testMessage with signer := 200 }
    let preBytes1 := structPreHash m1
    let preBytes2 := structPreHash m2
    if preBytes1.toList == preBytes2.toList then
      throw <| IO.userError "struct pre-hashes coincided across distinct signers"
    -- Both must be 160 bytes (the documented size).
    assertEq (expected := 160) (actual := preBytes1.size) "preBytes1 size"
    assertEq (expected := 160) (actual := preBytes2.size) "preBytes2 size"
}

/-- Verify the byte-layout of structPreHash directly: at byte
    position 95 (the LSB of `encodeUint256BE m.signer.toNat`,
    which lives at bytes [64, 96)), the byte equals
    `m.signer.toNat % 256`.  This is direct evidence of the
    32-byte BE signer field being at the documented position. -/
def structPreHashSignerLSBLayout : TestCase := {
  name := "structPreHash byte 95 = signer LSB (BE encoding at bytes 64..96)"
  body := do
    let m := { testMessage with signer := 0xABCD }
    let preBytes := structPreHash m
    let signerLSB : UInt8 := UInt8.ofNat (m.signer.toNat % 256)
    match preBytes.toList[95]? with
    | some b =>
      assertEq (expected := signerLSB) (actual := b) "byte 95 = signer LSB"
    | none => throw <| IO.userError "byte 95 out of range"
}

/-- Verify the byte-layout of structPreHash at byte position 127
    (the LSB of nonce BE, at bytes [96, 128)). -/
def structPreHashNonceLSBLayout : TestCase := {
  name := "structPreHash byte 127 = nonce LSB (BE encoding at bytes 96..128)"
  body := do
    let m := { testMessage with nonce := 0x1234 }
    let preBytes := structPreHash m
    let nonceLSB : UInt8 := UInt8.ofNat (m.nonce % 256)
    match preBytes.toList[127]? with
    | some b =>
      assertEq (expected := nonceLSB) (actual := b) "byte 127 = nonce LSB"
    | none => throw <| IO.userError "byte 127 out of range"
}

/-- The action hash is 32 bytes (it's `hashBytes signInput`). -/
def actionHashSize : TestCase := {
  name := "Eip712Message.actionHash is 32 bytes"
  body := assertEq (expected := 32) (actual := testMessage.actionHash.size) "ah size"
}

/-! ## Determinism tests -/

/-- The wrap is deterministic. -/
def wrapDeterministic : TestCase := {
  name := "eip712Wrap is deterministic"
  body := do
    let ds := eip712DomainSeparator testDomain
    let w1 := eip712Wrap testMessage ds
    let w2 := eip712Wrap testMessage ds
    if w1.toList == w2.toList then pure ()
    else throw <| IO.userError "non-deterministic eip712Wrap"
}

/-- The domain separator is deterministic. -/
def dsDeterministic : TestCase := {
  name := "eip712DomainSeparator is deterministic"
  body := do
    let ds1 := eip712DomainSeparator testDomain
    let ds2 := eip712DomainSeparator testDomain
    if ds1.toList == ds2.toList then pure ()
    else throw <| IO.userError "non-deterministic domain separator"
}

/-! ## Cross-deployment distinguishability (value-level §25 analogue) -/

/-- Distinct domain params (different chainId) produce distinct
    domain separators (assuming no hash collision in the FNV
    fallback's specific computation; this test exercises the
    expected behaviour). -/
def crossDomainsDistinguishable : TestCase := {
  name := "distinct DomainParams produce distinct domain separators"
  body := do
    let ds1 := eip712DomainSeparator testDomain
    let ds2 := eip712DomainSeparator altDomain
    if ds1.toList == ds2.toList then
      throw <| IO.userError
        "domain separators collided across distinct chainId — fallback hash collision OR bug"
    else pure ()
}

/-- Distinct messages produce distinct EIP-712 wraps under the same
    domain. -/
def crossMessagesDistinguishable : TestCase := {
  name := "distinct messages produce distinct wraps under same domain"
  body := do
    let ds := eip712DomainSeparator testDomain
    let w1 := eip712Wrap testMessage ds
    let w2 := eip712Wrap altMessage ds
    if w1.toList == w2.toList then
      throw <| IO.userError "wraps collided across distinct messages"
    else pure ()
}

/-- Distinct domains produce distinct wraps for the same message. -/
def crossDomainsWrapsDistinguishable : TestCase := {
  name := "distinct domains produce distinct wraps for same message"
  body := do
    let ds1 := eip712DomainSeparator testDomain
    let ds2 := eip712DomainSeparator altDomain
    let w1 := eip712Wrap testMessage ds1
    let w2 := eip712Wrap testMessage ds2
    if w1.toList == w2.toList then
      throw <| IO.userError "wraps collided across distinct domains"
    else pure ()
}

/-- Distinct nonces produce distinct wraps. -/
def crossNonceDistinguishable : TestCase := {
  name := "distinct nonces produce distinct wraps"
  body := do
    let ds := eip712DomainSeparator testDomain
    let m1 := { testMessage with nonce := 1 }
    let m2 := { testMessage with nonce := 2 }
    let w1 := eip712Wrap m1 ds
    let w2 := eip712Wrap m2 ds
    if w1.toList == w2.toList then
      throw <| IO.userError "wraps collided across distinct nonces"
    else pure ()
}

/-- Distinct signers produce distinct wraps. -/
def crossSignerDistinguishable : TestCase := {
  name := "distinct signers produce distinct wraps"
  body := do
    let ds := eip712DomainSeparator testDomain
    let m1 := { testMessage with signer := 5 }
    let m2 := { testMessage with signer := 6 }
    let w1 := eip712Wrap m1 ds
    let w2 := eip712Wrap m2 ds
    if w1.toList == w2.toList then
      throw <| IO.userError "wraps collided across distinct signers"
    else pure ()
}

/-- Distinct deployment IDs produce distinct wraps. -/
def crossDeploymentIdDistinguishable : TestCase := {
  name := "distinct deployment IDs produce distinct wraps"
  body := do
    let ds := eip712DomainSeparator testDomain
    let m1 := { testMessage with deploymentId := ByteArray.mk #[0x01] }
    let m2 := { testMessage with deploymentId := ByteArray.mk #[0x02] }
    let w1 := eip712Wrap m1 ds
    let w2 := eip712Wrap m2 ds
    if w1.toList == w2.toList then
      throw <| IO.userError "wraps collided across distinct deployment IDs"
    else pure ()
}

/-! ## Cross-protocol distinguishability (Audit-2-style)

A wrap of an EIP-712 message produces bytes structurally distinct
from a plain Knomosis-domain-prefixed `signInput`.  This is critical:
a signature on an EIP-712 wrap must NOT be re-interpretable as a
signature on a Knomosis-domain-prefixed input. -/

/-- The EIP-712 wrap and a plain Knomosis `signInput` differ in their
    leading bytes.  The wrap starts with `0x19 0x01`; the
    `signInput` starts with the CBE bytestring tag (`0x02`)
    followed by an 8-byte LE length.  Hence the leading byte
    differs (0x19 vs 0x02). -/
def crossProtocolDistinguishable : TestCase := {
  name := "EIP-712 wrap distinguished from Knomosis signInput by leading byte"
  body := do
    let ds := eip712DomainSeparator testDomain
    let wrap := eip712Wrap testMessage ds
    let knomosisSI := signInput testMessage.action testMessage.signer
                              testMessage.nonce testMessage.deploymentId
    -- Their leading bytes differ.
    match wrap.toList, knomosisSI.toList with
    | wb :: _, cb :: _ =>
      if wb == cb then
        throw <| IO.userError s!"leading bytes coincided: {wb} == {cb}"
      else pure ()
    | _, _ => throw <| IO.userError "wrap or signInput too short"
}

/-! ## encodeUint256BE tests -/

/-- `encodeUint256BE` produces 32 bytes for any input. -/
def encodeUintSize : TestCase := {
  name := "encodeUint256BE is always 32 bytes"
  body := do
    assertEq (expected := 32) (actual := (encodeUint256BE 0).size) "0"
    assertEq (expected := 32) (actual := (encodeUint256BE 1).size) "1"
    assertEq (expected := 32) (actual := (encodeUint256BE 0xCAFEBABE).size) "0xCAFEBABE"
}

/-- `encodeUint256BE 0` is 32 zero bytes. -/
def encodeUintZero : TestCase := {
  name := "encodeUint256BE 0 is all zeros"
  body := do
    let bs := (encodeUint256BE 0).toList
    -- All 32 bytes should be 0.
    for i in [0:32] do
      match bs[i]? with
      | some b =>
        if b ≠ 0 then
          throw <| IO.userError s!"byte {i} is {b}, expected 0"
      | none => throw <| IO.userError s!"index {i} out of range"
}

/-- `encodeUint256BE 1` has 31 zero bytes followed by a single
    `0x01` (the BE encoding of 1 in 32 bytes). -/
def encodeUintOne : TestCase := {
  name := "encodeUint256BE 1 is 31 zeros + 0x01"
  body := do
    let bs := (encodeUint256BE 1).toList
    -- Last byte should be 0x01; all others 0.
    match bs.getLast? with
    | some last => assertEq (expected := (0x01 : UInt8)) (actual := last) "last byte"
    | none => throw <| IO.userError "encoding empty"
    -- First 31 bytes should be 0.
    for i in [0:31] do
      match bs[i]? with
      | some b =>
        if b ≠ 0 then
          throw <| IO.userError s!"byte {i} is {b}, expected 0"
      | none => throw <| IO.userError s!"index {i} out of range"
}

/-- `encodeUint256BE` is injective on UInt64-bounded inputs. -/
def encodeUintInjectiveValueLevel : TestCase := {
  name := "encodeUint256BE 1 ≠ encodeUint256BE 2 (value-level)"
  body := do
    if (encodeUint256BE 1).toList == (encodeUint256BE 2).toList then
      throw <| IO.userError "encodings of 1 and 2 collided"
}

/-! ## Term-level API stability for the headline theorems -/

/-- Theorem #24 (`eip712Wrap_injective`) API stability. -/
def wrapInjectiveAPI : TestCase := {
  name := "eip712Wrap_injective API stability"
  body := do
    let _proof :
        ∀ (_hcf : CollisionFree hashBytes) (m₁ m₂ : Eip712Message) (d : ByteArray),
          eip712Wrap m₁ d = eip712Wrap m₂ d → m₁.signInput = m₂.signInput :=
      fun hcf => eip712Wrap_injective hcf
    pure ()
}

/-- Theorem #25 (`eip712DomainSeparator_distinguishes`) API stability. -/
def dsDistinguishesAPI : TestCase := {
  name := "eip712DomainSeparator_distinguishes API stability"
  body := do
    let _proof :
        ∀ (_hcf : CollisionFree hashBytes) (p₁ p₂ : DomainParams)
          (_hcb₁ : p₁.chainId < 256 ^ 32) (_hcb₂ : p₂.chainId < 256 ^ 32)
          (_hrb₁ : p₁.rollupId < 256 ^ 32) (_hrb₂ : p₂.rollupId < 256 ^ 32),
          p₁ ≠ p₂ →
          eip712DomainSeparator p₁ ≠ eip712DomainSeparator p₂ :=
      fun hcf p₁ p₂ hcb₁ hcb₂ hrb₁ hrb₂ =>
        eip712DomainSeparator_distinguishes hcf p₁ p₂ hcb₁ hcb₂ hrb₁ hrb₂
    pure ()
}

/-- Theorem #26 (`eip712Wrap_distinguishes`) API stability. -/
def wrapDistinguishesAPI : TestCase := {
  name := "eip712Wrap_distinguishes API stability"
  body := do
    let _proof :
        ∀ (_hcf : CollisionFree hashBytes) (m₁ m₂ : Eip712Message) (d₁ d₂ : ByteArray),
          d₁.size = d₂.size →
          eip712Wrap m₁ d₁ = eip712Wrap m₂ d₂ →
          d₁ = d₂ ∧ m₁.signInput = m₂.signInput :=
      fun hcf => eip712Wrap_distinguishes hcf
    pure ()
}

/-- `domainPreHash_injective` API stability. -/
def domainPreHashInjectiveAPI : TestCase := {
  name := "domainPreHash_injective API stability"
  body := do
    let _proof :
        ∀ (_hcf : CollisionFree hashBytes) (p₁ p₂ : DomainParams)
          (_hcb₁ : p₁.chainId < 256 ^ 32) (_hcb₂ : p₂.chainId < 256 ^ 32)
          (_hrb₁ : p₁.rollupId < 256 ^ 32) (_hrb₂ : p₂.rollupId < 256 ^ 32),
          domainPreHash p₁ = domainPreHash p₂ → p₁ = p₂ :=
      fun hcf p₁ p₂ => domainPreHash_injective hcf p₁ p₂
    pure ()
}

/-- `encodeUint256BE_injective` API stability. -/
def encodeUintInjectiveAPI : TestCase := {
  name := "encodeUint256BE_injective API stability"
  body := do
    let _proof :
        ∀ (n₁ n₂ : Nat), n₁ < 256 ^ 32 → n₂ < 256 ^ 32 →
          encodeUint256BE n₁ = encodeUint256BE n₂ → n₁ = n₂ :=
      encodeUint256BE_injective
    pure ()
}

/-- `encodeUint256BE_size` API stability. -/
def encodeUintSizeAPI : TestCase := {
  name := "encodeUint256BE_size API stability"
  body := do
    let _proof : ∀ (n : Nat), (encodeUint256BE n).size = 32 :=
      encodeUint256BE_size
    pure ()
}

/-- `eip712Wrap_size` API stability. -/
def wrapSizeAPI : TestCase := {
  name := "eip712Wrap_size API stability"
  body := do
    let _proof :
        ∀ (m : Eip712Message) (d : ByteArray),
          (eip712Wrap m d).size = 2 + d.size + 32 :=
      eip712Wrap_size
    pure ()
}

/-- `eip712Prefix_size` API stability. -/
def prefixSizeAPI : TestCase := {
  name := "eip712Prefix_size API stability"
  body := do
    let _proof : eip712Prefix.size = 2 := eip712Prefix_size
    pure ()
}

/-- `eip712StructHash_size` API stability. -/
def structHashSizeAPI : TestCase := {
  name := "eip712StructHash_size API stability"
  body := do
    let _proof : ∀ (m : Eip712Message), (eip712StructHash m).size = 32 :=
      eip712StructHash_size
    pure ()
}

/-- `eip712DomainSeparator_size` API stability. -/
def dsSizeAPI : TestCase := {
  name := "eip712DomainSeparator_size API stability"
  body := do
    let _proof : ∀ (p : DomainParams), (eip712DomainSeparator p).size = 32 :=
      eip712DomainSeparator_size
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [ -- Prefix shape (3)
    prefixIsTwoBytes, prefixFirstByte, prefixSecondByte,
    -- Type-string sanity (4)
    domainTypeStringExact, actionTypeStringExact,
    actionTypeStringDeploymentIsBytes, domainTypeStringContractIsBytes,
    -- Domain separator + type hash shapes (4)
    domainSeparatorSize, domainPreHashSize,
    domainTypeHashSize, actionTypeHashSize,
    -- Wrap and struct shapes (8 — added structPreHash + layout tests)
    wrapSize, wrapBeginsWithPrefix, structHashSize,
    structPreHashSize, structPreHashContainsSigner,
    structPreHashSignerLSBLayout, structPreHashNonceLSBLayout,
    actionHashSize,
    -- Determinism (2)
    wrapDeterministic, dsDeterministic,
    -- Cross-* distinguishability (6)
    crossDomainsDistinguishable, crossMessagesDistinguishable,
    crossDomainsWrapsDistinguishable, crossNonceDistinguishable,
    crossSignerDistinguishable, crossDeploymentIdDistinguishable,
    -- Cross-protocol distinguishability (1)
    crossProtocolDistinguishable,
    -- encodeUint256BE shape / value (4)
    encodeUintSize, encodeUintZero, encodeUintOne, encodeUintInjectiveValueLevel,
    -- Headline theorem APIs (3)
    wrapInjectiveAPI, dsDistinguishesAPI, wrapDistinguishesAPI,
    -- Auxiliary lemma APIs (5)
    domainPreHashInjectiveAPI, encodeUintInjectiveAPI, encodeUintSizeAPI,
    wrapSizeAPI, prefixSizeAPI,
    -- Stability size APIs (2)
    structHashSizeAPI, dsSizeAPI ]

end Eip712Tests
end LegalKernel.Test.Bridge
