/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.Action — Phase-4 WU 4.3 / WU 4.6 / WU 4.7
tests for the `Action` encoder.

Value-level round-trip checks for every `Action` constructor; term-
level API stability for the headline round-trip and injectivity
theorems.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.Action

namespace LegalKernel.Test.Encoding
namespace ActionTests

open LegalKernel.Encoding
open LegalKernel.Authority

/-- Round-trip of `Action.transfer 1 2 3 4`. -/
def transferRT : TestCase := {
  name := "Action.transfer roundtrip"
  body := do
    let a : Action := .transfer 1 2 3 4
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', rest) =>
      assertEq a a' "decoded action"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.mint 1 2 100`. -/
def mintRT : TestCase := {
  name := "Action.mint roundtrip"
  body := do
    let a : Action := .mint 1 2 100
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) => assertEq a a' "decoded action"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.burn 1 2 50`. -/
def burnRT : TestCase := {
  name := "Action.burn roundtrip"
  body := do
    let a : Action := .burn 1 2 50
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) => assertEq a a' "decoded action"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.freezeResource 7`. -/
def freezeRT : TestCase := {
  name := "Action.freezeResource roundtrip"
  body := do
    let a : Action := .freezeResource 7
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) => assertEq a a' "decoded action"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.replaceKey 5 <bytes>`. -/
def replaceKeyRT : TestCase := {
  name := "Action.replaceKey roundtrip"
  body := do
    let key : PublicKey := ⟨#[0xAB, 0xCD, 0xEF]⟩
    let a : Action := .replaceKey 5 key
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) =>
      match a' with
      | .replaceKey actor newKey =>
        assertEq (5 : UInt64) actor "decoded actor"
        assertEq key.size newKey.size "decoded key size"
      | _ => throw <| IO.userError "wrong constructor"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.reward 1 2 100`. -/
def rewardRT : TestCase := {
  name := "Action.reward roundtrip"
  body := do
    let a : Action := .reward 1 2 100
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) => assertEq a a' "decoded action"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.distributeOthers 1 2 50`. -/
def distributeOthersRT : TestCase := {
  name := "Action.distributeOthers roundtrip"
  body := do
    let a : Action := .distributeOthers 1 2 50
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) => assertEq a a' "decoded action"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.proportionalDilute 1 2 100`. -/
def proportionalDiluteRT : TestCase := {
  name := "Action.proportionalDilute roundtrip"
  body := do
    let a : Action := .proportionalDilute 1 2 100
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) => assertEq a a' "decoded action"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.registerIdentity 7 <bytes>` (Workstream B.3).
    Mirrors `replaceKeyRT`: the registerIdentity constructor encodes
    as `tag 12 ++ encode actor ++ encode pk` and round-trips through
    the same machinery. -/
def registerIdentityRT : TestCase := {
  name := "Action.registerIdentity roundtrip"
  body := do
    let key : PublicKey := ⟨#[0xDE, 0xAD, 0xBE, 0xEF]⟩
    let a : Action := .registerIdentity 7 key
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) =>
      match a' with
      | .registerIdentity actor newKey =>
        assertEq (7 : UInt64) actor "decoded actor"
        assertEq key.size newKey.size "decoded key size"
      | _ => throw <| IO.userError "wrong constructor"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- `Action.registerIdentity` and `Action.replaceKey` produce
    different encoded bytes despite the same field shape (both have
    actor + key).  Catches a future bug where the constructor tags
    accidentally collide. -/
def registerIdentityVsReplaceKeyBytes : TestCase := {
  name := "registerIdentity vs replaceKey bytes differ"
  body := do
    let key : PublicKey := ⟨#[0xAA, 0xBB]⟩
    let bytes_reg := Encodable.encode (T := Action) (.registerIdentity 5 key)
    let bytes_rep := Encodable.encode (T := Action) (.replaceKey 5 key)
    if bytes_reg == bytes_rep then
      throw <| IO.userError "registerIdentity / replaceKey encodings collided"
    else pure ()
}

/-- Different actions encode to different bytes. -/
def transferVsMintBytes : TestCase := {
  name := "transfer vs mint produce different bytes"
  body := do
    let bytes_t := Encodable.encode (T := Action) (.transfer 1 2 3 4)
    let bytes_m := Encodable.encode (T := Action) (.mint 1 2 4)
    -- Constructor tags differ (0 vs 1), so the first byte's value
    -- differs (cborHeadEncode encodes the tag as the second byte
    -- of the head, since the first byte is the type tag).
    if bytes_t == bytes_m then
      throw <| IO.userError "encodings collided"
    else pure ()
}

/-- Spot-check: encoded byte length for transfer (5 nat fields × 9 bytes
    each = 45 bytes). -/
def transferByteLength : TestCase := {
  name := "Action.transfer encoded length"
  body := do
    let bytes := Encodable.encode (T := Action) (.transfer 1 2 3 4)
    -- 5 Nat fields × 9 bytes each = 45 bytes total.
    assertEq (45 : Nat) bytes.length "encoded length"
}

/-- Term-level API check: `action_roundtrip` signature. -/
def actionRoundtripAPI : TestCase := {
  name := "action_roundtrip API stability"
  body := do
    let _proof : ∀ (a : Action) (rest : Stream), Action.fieldsBounded a →
      Encodable.decode (T := Action) (Encodable.encode a ++ rest) = .ok (a, rest) :=
      action_roundtrip
    pure ()
}

/-- Term-level API check: `action_encode_injective` signature. -/
def actionInjectiveAPI : TestCase := {
  name := "action_encode_injective API stability"
  body := do
    let _proof : ∀ (a₁ a₂ : Action),
        Action.fieldsBounded a₁ → Action.fieldsBounded a₂ →
        Encodable.encode (T := Action) a₁ = Encodable.encode (T := Action) a₂ → a₁ = a₂ :=
      action_encode_injective
    pure ()
}

/-! ## Workstream C.4 — deposit / withdraw round-trip tests -/

/-- `Action.deposit` round-trip test case. -/
def depositRT : TestCase := {
  name := "Action.deposit roundtrip"
  body := do
    let a : Action := .deposit 1 10 100 42
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) =>
      match a' with
      | .deposit r recipient amount d =>
        assertEq (1 : UInt64) r "decoded resource"
        assertEq (10 : UInt64) recipient "decoded recipient"
        assertEq (100 : Nat) amount "decoded amount"
        assertEq (42 : Nat) d "decoded depositId"
      | _ => throw <| IO.userError "wrong constructor"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- `Action.withdraw` round-trip test case. -/
def withdrawRT : TestCase := {
  name := "Action.withdraw roundtrip"
  body := do
    let rcp : LegalKernel.Bridge.EthAddress := ⟨123, by decide⟩
    let a : Action := .withdraw 1 10 50 rcp
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', _) =>
      match a' with
      | .withdraw r sender amount rcp' =>
        assertEq (1 : UInt64) r "decoded resource"
        assertEq (10 : UInt64) sender "decoded sender"
        assertEq (50 : Nat) amount "decoded amount"
        assertEq (123 : Nat) rcp'.val "decoded recipient L1"
      | _ => throw <| IO.userError "wrong constructor"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- `Action.deposit` and `Action.mint` (same shape r/to/amount) produce
    different encoded bytes thanks to distinct constructor tags. -/
def depositVsMintBytes : TestCase := {
  name := "deposit vs mint produce different bytes"
  body := do
    let bytes_dep := Encodable.encode (T := Action) (.deposit 1 10 100 0)
    let bytes_mint := Encodable.encode (T := Action) (.mint 1 10 100)
    if bytes_dep == bytes_mint then
      throw <| IO.userError "deposit / mint encodings collided"
    else pure ()
}

/-- `Action.withdraw` and `Action.burn` produce different encoded bytes. -/
def withdrawVsBurnBytes : TestCase := {
  name := "withdraw vs burn produce different bytes"
  body := do
    let bytes_wd := Encodable.encode (T := Action)
      (.withdraw 1 10 50 LegalKernel.Bridge.EthAddress.zero)
    let bytes_burn := Encodable.encode (T := Action) (.burn 1 10 50)
    if bytes_wd == bytes_burn then
      throw <| IO.userError "withdraw / burn encodings collided"
    else pure ()
}

/-! ### Audit-2 security regressions

Two distinct `EthAddress` values sharing low 64 bits MUST encode to
distinct bytes.  The pre-audit `Action.withdraw` encoder truncated
to 64 bits, allowing signature replay between addresses sharing
low 64 bits.  The audit-2 fix encodes `recipientL1` as a 20-byte
ByteArray (lossless).  These regressions catch any future revert. -/

/-- High-bit EthAddresses are NOT collapsed by the encoder. -/
def withdrawHighBitDistinguishability : TestCase := {
  name := "withdraw recipient: high-bit EthAddresses encode distinctly (audit-2)"
  body := do
    -- Two EthAddresses that share low 64 bits but differ in high bits.
    let lowMask : Nat := 18446744073709551615  -- 2^64 - 1
    -- Address A: high bits = 1, low bits = 42.
    let addrA : LegalKernel.Bridge.EthAddress :=
      ⟨18446744073709551616 + 42, by decide⟩
    -- Address B: high bits = 2, low bits = 42.
    let addrB : LegalKernel.Bridge.EthAddress :=
      ⟨2 * 18446744073709551616 + 42, by decide⟩
    -- They share the low 64 bits.
    assertEq (expected := addrA.val % 18446744073709551616)
             (actual := addrB.val % 18446744073709551616)
             "low 64 bits match"
    let _ := lowMask
    -- The encoded bytes MUST differ.
    let bytesA := Encodable.encode (T := Action)
                    (.withdraw 1 10 50 addrA)
    let bytesB := Encodable.encode (T := Action)
                    (.withdraw 1 10 50 addrB)
    if bytesA == bytesB then
      throw <| IO.userError
        "audit-2 regression: withdraw encodings collided on shared low 64 bits"
    else pure ()
}

/-- Round-trip for a high-bit EthAddress recipient. -/
def withdrawHighBitRoundtrip : TestCase := {
  name := "withdraw with 160-bit recipient round-trips (audit-2)"
  body := do
    -- An EthAddress that requires more than 64 bits (high bits non-zero).
    let addr : LegalKernel.Bridge.EthAddress :=
      ⟨18446744073709551616 + 1, by decide⟩
    let action : Action := .withdraw 1 10 50 addr
    match Encodable.decode (T := Action) (Encodable.encode action) with
    | .ok (a', _) =>
      match a' with
      | .withdraw r' sender' amount' rcp' =>
        assertEq (expected := (1 : UInt64)) (actual := r') "resource"
        assertEq (expected := (10 : UInt64)) (actual := sender') "sender"
        assertEq (expected := (50 : Nat)) (actual := amount') "amount"
        assertEq (expected := addr.val) (actual := rcp'.val) "rcp value"
      | _ => throw <| IO.userError "wrong constructor"
    | .error _ => throw <| IO.userError "decode failed"
}

/-! ## Workstream LP / LP.4 — declareLocalPolicy / revokeLocalPolicy
    encoding tests. -/

/-- Round-trip for `declareLocalPolicy` with an empty policy. -/
def declareLocalPolicyEmptyRT : TestCase := {
  name := "declareLocalPolicy (empty) round-trips"
  body := do
    let p : Authority.LocalPolicy := { clauses := [] }
    let a : Action := .declareLocalPolicy p
    let bytes := Encodable.encode (T := Action) a
    match Encodable.decode (T := Action) bytes with
    | .ok (a', []) =>
      if a == a' then pure ()
      else throw <| IO.userError "declareLocalPolicy roundtrip mismatch"
    | _ => throw <| IO.userError "declareLocalPolicy decode failed"
}

/-- Round-trip for `declareLocalPolicy` with a 3-clause policy. -/
def declareLocalPolicyMultiRT : TestCase := {
  name := "declareLocalPolicy (3 clauses) round-trips"
  body := do
    let p : Authority.LocalPolicy :=
      { clauses := [.denyTags [0, 1], .requireRecipientIn 2 [3, 4],
                    .capAmount 1 100] }
    let a : Action := .declareLocalPolicy p
    let bytes := Encodable.encode (T := Action) a
    match Encodable.decode (T := Action) bytes with
    | .ok (a', []) =>
      if a == a' then pure ()
      else throw <| IO.userError "declareLocalPolicy multi-clause mismatch"
    | _ => throw <| IO.userError "declareLocalPolicy multi decode failed"
}

/-- Round-trip for `revokeLocalPolicy`. -/
def revokeLocalPolicyRT : TestCase := {
  name := "revokeLocalPolicy round-trips"
  body := do
    let a : Action := .revokeLocalPolicy
    let bytes := Encodable.encode (T := Action) a
    match Encodable.decode (T := Action) bytes with
    | .ok (a', []) =>
      if a == a' then pure ()
      else throw <| IO.userError "revokeLocalPolicy roundtrip mismatch"
    | _ => throw <| IO.userError "revokeLocalPolicy decode failed"
}

/-- `declareLocalPolicy` and `revokeLocalPolicy` produce distinct
    encodings (cross-constructor distinguishability). -/
def lpCtorDistinguishability : TestCase := {
  name := "declareLocalPolicy vs revokeLocalPolicy bytes differ"
  body := do
    let p : Authority.LocalPolicy := { clauses := [] }
    let bytes_d := Encodable.encode (T := Action) (.declareLocalPolicy p)
    let bytes_r := Encodable.encode (T := Action) (.revokeLocalPolicy)
    if bytes_d == bytes_r then
      throw <| IO.userError "LP ctor encodings collided"
    else pure ()
}

/-- `declareLocalPolicy p₁` ≠ `declareLocalPolicy p₂` when policies
    differ. -/
def declareLocalPolicyDistinguishesPolicy : TestCase := {
  name := "declareLocalPolicy with distinct policies → distinct bytes"
  body := do
    let p₁ : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
    let p₂ : Authority.LocalPolicy := { clauses := [.denyTags [1]] }
    let b₁ := Encodable.encode (T := Action) (.declareLocalPolicy p₁)
    let b₂ := Encodable.encode (T := Action) (.declareLocalPolicy p₂)
    if b₁ == b₂ then
      throw <| IO.userError "Distinct policies encoded identically"
    else pure ()
}

/-- The leading byte of `Action.encode .revokeLocalPolicy` matches
    the constructor index 16 (LP.4 frozen index).  Pins the
    `Action.tag_matches_encode_tag` agreement at the value level. -/
def revokeLocalPolicyTagAgreement : TestCase := {
  name := "Action.tag .revokeLocalPolicy matches encode tag"
  body := do
    let bytes := Encodable.encode (T := Action) .revokeLocalPolicy
    -- The encode begins with `Encodable.encode (T := Nat) 16` which is
    -- 9 bytes: tag-byte cbeTagUint, then 8 bytes LE for the value 16.
    -- The 0th byte is the cbeTagUint (a constant).  The next 8 bytes
    -- encode the Nat 16 in LE; the 1st byte (index 1 of the stream)
    -- is the LSB of the value, which is 16.
    if bytes.length < 9 then
      throw <| IO.userError "encoding too short"
    else if bytes[1]? = some 16 then pure ()
    else throw <| IO.userError s!"expected tag byte 16 at position 1, got {bytes[1]?}"
}

/-- Term-level API stability for `Action.tag_matches_encode_tag`. -/
def tagMatchesEncodeTagAPI : TestCase := {
  name := "Action.tag_matches_encode_tag API stability"
  body := do
    let _proof : ∀ (a : Action),
                  ∃ tail : Stream,
                    Encodable.encode (T := Action) a =
                    Encodable.encode (T := Nat) (Action.tag a) ++ tail :=
      Action.tag_matches_encode_tag
    pure ()
}

/-! ## GP.2.3 — depositWithFee + topUpActionBudget encoding -/

/-- Round-trip of `Action.depositWithFee 1 10 99 50 50 200 42`. -/
def depositWithFeeRT : TestCase := {
  name := "Action.depositWithFee roundtrip"
  body := do
    let a : Action := .depositWithFee 1 10 99 50 50 200 42
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', rest) =>
      assertEq a a' "decoded action"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `Action.topUpActionBudget 1 5 100 99`. -/
def topUpActionBudgetRT : TestCase := {
  name := "Action.topUpActionBudget roundtrip"
  body := do
    let a : Action := .topUpActionBudget 1 5 100 99
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', rest) =>
      assertEq a a' "decoded action"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- `Action.depositWithFee` and `Action.deposit` produce distinct
    encodings (different constructor tags 19 vs 13). -/
def depositWithFeeVsDepositBytes : TestCase := {
  name := "Action.depositWithFee ≠ Action.deposit (distinct tags)"
  body := do
    let b1 := Encodable.encode (T := Action) (.depositWithFee 1 2 3 4 5 6 7)
    let b2 := Encodable.encode (T := Action) (.deposit 1 2 4 7)
    if b1 == b2 then
      throw <| IO.userError "depositWithFee and deposit encoded identically"
    else pure ()
}

/-- `Action.topUpActionBudget` and `Action.transfer` produce distinct
    encodings. -/
def topUpActionBudgetVsTransferBytes : TestCase := {
  name := "Action.topUpActionBudget ≠ Action.transfer (distinct tags)"
  body := do
    let b1 := Encodable.encode (T := Action) (.topUpActionBudget 1 5 100 99)
    let b2 := Encodable.encode (T := Action) (.transfer 1 5 99 100)
    if b1 == b2 then
      throw <| IO.userError "topUpActionBudget and transfer encoded identically"
    else pure ()
}

/-- `Action.tag` for `depositWithFee` is 19 (frozen). -/
def depositWithFeeTagPin : TestCase := {
  name := "Action.tag depositWithFee = 19 (frozen)"
  body := do
    assertEq (expected := 19) (actual := Action.tag (.depositWithFee 1 2 3 4 5 6 7))
      "depositWithFee tag"
}

/-- `Action.tag` for `topUpActionBudget` is 20 (frozen). -/
def topUpActionBudgetTagPin : TestCase := {
  name := "Action.tag topUpActionBudget = 20 (frozen)"
  body := do
    assertEq (expected := 20) (actual := Action.tag (.topUpActionBudget 1 2 3 4))
      "topUpActionBudget tag"
}

/-- Distinct depositWithFee actions encode differently (per-field
    injectivity). -/
def depositWithFeeFieldInjective : TestCase := {
  name := "Action.depositWithFee per-field injectivity (budgetGrant distinguished)"
  body := do
    let b1 := Encodable.encode (T := Action) (.depositWithFee 1 2 3 4 5 100 7)
    let b2 := Encodable.encode (T := Action) (.depositWithFee 1 2 3 4 5 200 7)
    if b1 == b2 then
      throw <| IO.userError "depositWithFee with distinct budgetGrant encoded identically"
    else pure ()
}

/-- Distinct topUpActionBudget actions encode differently. -/
def topUpActionBudgetFieldInjective : TestCase := {
  name := "Action.topUpActionBudget per-field injectivity (budgetIncrement)"
  body := do
    let b1 := Encodable.encode (T := Action) (.topUpActionBudget 1 5 100 99)
    let b2 := Encodable.encode (T := Action) (.topUpActionBudget 1 5 200 99)
    if b1 == b2 then
      throw <| IO.userError "topUpActionBudget with distinct budgetIncrement encoded identically"
    else pure ()
}

/-! ## GP.3.4 — topUpActionBudgetFor (delegated) encoding -/

/-- Round-trip of `Action.topUpActionBudgetFor 20 1 5 100 99`. -/
def topUpActionBudgetForRT : TestCase := {
  name := "Action.topUpActionBudgetFor roundtrip"
  body := do
    let a : Action := .topUpActionBudgetFor 20 1 5 100 99
    match Encodable.decode (T := Action) (Encodable.encode a) with
    | .ok (a', rest) =>
      assertEq a a' "decoded action"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- `Action.topUpActionBudgetFor` and its closest sibling
    `Action.topUpActionBudget` produce distinct encodings (different
    constructor tags 21 vs 20, and the delegated form carries an
    extra leading `recipient` field). -/
def topUpActionBudgetForVsTopUpActionBudgetBytes : TestCase := {
  name := "Action.topUpActionBudgetFor ≠ Action.topUpActionBudget (distinct tags)"
  body := do
    let b1 := Encodable.encode (T := Action) (.topUpActionBudgetFor 20 1 5 100 99)
    let b2 := Encodable.encode (T := Action) (.topUpActionBudget 1 5 100 99)
    if b1 == b2 then
      throw <| IO.userError "topUpActionBudgetFor and topUpActionBudget encoded identically"
    else pure ()
}

/-- `Action.tag` for `topUpActionBudgetFor` is 21 (frozen). -/
def topUpActionBudgetForTagPin : TestCase := {
  name := "Action.tag topUpActionBudgetFor = 21 (frozen)"
  body := do
    assertEq (expected := 21) (actual := Action.tag (.topUpActionBudgetFor 20 1 2 3 4))
      "topUpActionBudgetFor tag"
}

/-- Distinct `topUpActionBudgetFor` actions encode differently — in
    particular the *recipient* (the new leading field vs
    `topUpActionBudget`) is encoded, so two delegated top-ups that
    differ only in recipient are distinguishable. -/
def topUpActionBudgetForFieldInjective : TestCase := {
  name := "Action.topUpActionBudgetFor per-field injectivity (recipient distinguished)"
  body := do
    let b1 := Encodable.encode (T := Action) (.topUpActionBudgetFor 20 1 5 100 99)
    let b2 := Encodable.encode (T := Action) (.topUpActionBudgetFor 30 1 5 100 99)
    if b1 == b2 then
      throw <| IO.userError "topUpActionBudgetFor with distinct recipient encoded identically"
    else pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [transferRT, mintRT, burnRT, freezeRT, replaceKeyRT, rewardRT,
   distributeOthersRT, proportionalDiluteRT, registerIdentityRT,
   registerIdentityVsReplaceKeyBytes, transferVsMintBytes,
   transferByteLength, actionRoundtripAPI, actionInjectiveAPI,
   depositRT, withdrawRT, depositVsMintBytes, withdrawVsBurnBytes,
   withdrawHighBitDistinguishability, withdrawHighBitRoundtrip,
   -- LP.4:
   declareLocalPolicyEmptyRT, declareLocalPolicyMultiRT,
   revokeLocalPolicyRT, lpCtorDistinguishability,
   declareLocalPolicyDistinguishesPolicy,
   revokeLocalPolicyTagAgreement, tagMatchesEncodeTagAPI,
   -- GP.2.3:
   depositWithFeeRT, topUpActionBudgetRT,
   depositWithFeeVsDepositBytes, topUpActionBudgetVsTransferBytes,
   depositWithFeeTagPin, topUpActionBudgetTagPin,
   depositWithFeeFieldInjective, topUpActionBudgetFieldInjective,
   -- GP.3.4:
   topUpActionBudgetForRT, topUpActionBudgetForVsTopUpActionBudgetBytes,
   topUpActionBudgetForTagPin, topUpActionBudgetForFieldInjective]

end ActionTests
end LegalKernel.Test.Encoding
