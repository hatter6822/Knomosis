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

/-- All tests. -/
def tests : List TestCase :=
  [transferRT, mintRT, burnRT, freezeRT, replaceKeyRT, rewardRT,
   distributeOthersRT, proportionalDiluteRT, registerIdentityRT,
   registerIdentityVsReplaceKeyBytes, transferVsMintBytes,
   transferByteLength, actionRoundtripAPI, actionInjectiveAPI,
   depositRT, withdrawRT, depositVsMintBytes, withdrawVsBurnBytes]

end ActionTests
end LegalKernel.Test.Encoding
