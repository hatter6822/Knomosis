/-
  Canon  - A Societal Kernel
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

/-- All tests. -/
def tests : List TestCase :=
  [transferRT, mintRT, burnRT, freezeRT, replaceKeyRT, rewardRT,
   distributeOthersRT, proportionalDiluteRT, transferVsMintBytes,
   transferByteLength, actionRoundtripAPI, actionInjectiveAPI]

end ActionTests
end LegalKernel.Test.Encoding
