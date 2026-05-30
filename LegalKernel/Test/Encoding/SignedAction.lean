-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.SignedAction — Phase-4 WU 4.4 / WU 4.6 /
WU 4.7 tests for the `SignedAction` encoder.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.SignedAction

namespace LegalKernel.Test.Encoding
namespace SignedActionTests

open LegalKernel.Encoding
open LegalKernel.Authority

/-- Round-trip of a signed transfer. -/
def signedTransferRT : TestCase := {
  name := "SignedAction with transfer roundtrip"
  body := do
    let st : SignedAction := {
      action := .transfer 1 2 3 4,
      signer := 5,
      nonce  := 7,
      sig    := ⟨#[0xAA, 0xBB, 0xCC]⟩
    }
    match Encodable.decode (T := SignedAction) (Encodable.encode st) with
    | .ok (st', rest) =>
      assertEq st.signer st'.signer "decoded signer"
      assertEq st.nonce st'.nonce "decoded nonce"
      assertEq st.sig.size st'.sig.size "decoded sig size"
      assertEq st.action st'.action "decoded action"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of a signed replaceKey. -/
def signedReplaceKeyRT : TestCase := {
  name := "SignedAction with replaceKey roundtrip"
  body := do
    let pk : PublicKey := ⟨#[0x11, 0x22, 0x33, 0x44]⟩
    let sig : Signature := ⟨#[0xAA, 0xBB]⟩
    let st : SignedAction := {
      action := .replaceKey 10 pk,
      signer := 10,
      nonce  := 0,
      sig    := sig
    }
    match Encodable.decode (T := SignedAction) (Encodable.encode st) with
    | .ok (st', _) =>
      assertEq st.signer st'.signer "decoded signer"
      assertEq st.nonce st'.nonce "decoded nonce"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Term-level API check: `signedAction_roundtrip` signature. -/
def signedActionRoundtripAPI : TestCase := {
  name := "signedAction_roundtrip API stability"
  body := do
    let _proof : ∀ (st : SignedAction) (rest : Stream),
        SignedAction.fieldsBounded st →
        Encodable.decode (T := SignedAction) (Encodable.encode st ++ rest)
          = .ok (st, rest) :=
      signedAction_roundtrip
    pure ()
}

/-- Term-level API check: `signedAction_encode_injective` signature. -/
def signedActionInjectiveAPI : TestCase := {
  name := "signedAction_encode_injective API stability"
  body := do
    let _proof : ∀ (st₁ st₂ : SignedAction),
        SignedAction.fieldsBounded st₁ → SignedAction.fieldsBounded st₂ →
        Encodable.encode (T := SignedAction) st₁ =
        Encodable.encode (T := SignedAction) st₂ → st₁ = st₂ :=
      signedAction_encode_injective
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [signedTransferRT, signedReplaceKeyRT, signedActionRoundtripAPI,
   signedActionInjectiveAPI]

end SignedActionTests
end LegalKernel.Test.Encoding
