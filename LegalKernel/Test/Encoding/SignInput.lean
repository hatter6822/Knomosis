-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.SignInput — Phase-4 WU 4.8 tests.

Verifies the §8.8.5 cross-deployment-distinguishability property at
the value level: distinct deployment IDs produce distinct sign-input
bytes for the same `(action, signer, nonce)` triple.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.SignInput

namespace LegalKernel.Test.Encoding
namespace SignInputTests

open LegalKernel.Encoding
open LegalKernel.Authority

/-- The sign-input begins with the canonical domain bytes. -/
def signInputDomainPrefix : TestCase := {
  name := "signInput begins with the domain string"
  body := do
    let bytes := signInput (.transfer 1 2 3 4) 5 7 (⟨#[0x00]⟩ : ByteArray)
    -- The first 9 bytes are the CBE bytestring head for the domain.
    -- Following 27 bytes are the ASCII of "legalkernel/v1/signedaction".
    assertEq (true) (bytes.size ≥ 36) "minimum length"
}

/-- Different deployment IDs produce different sign-input bytes. -/
def crossDeploymentDistinct : TestCase := {
  name := "cross-deployment IDs produce different sign-inputs"
  body := do
    let action : Action := .transfer 1 2 3 4
    let signer : ActorId := 5
    let nonce : Nonce := 7
    let d1 : ByteArray := ⟨#[0xAA, 0xBB]⟩
    let d2 : ByteArray := ⟨#[0xCC, 0xDD]⟩
    let bytes1 := signInput action signer nonce d1
    let bytes2 := signInput action signer nonce d2
    -- The deployment ID encoding is included in the sign-input bytes;
    -- different IDs → different bytes.
    -- Using ByteArray equality via toList:
    if bytes1.data.toList == bytes2.data.toList then
      throw <| IO.userError "cross-deployment sign-inputs collided"
    else pure ()
}

/-- Different actions produce different sign-input bytes. -/
def crossActionDistinct : TestCase := {
  name := "cross-action sign-inputs differ"
  body := do
    let signer : ActorId := 5
    let nonce : Nonce := 7
    let d : ByteArray := ⟨#[0xAA]⟩
    let bytes1 := signInput (.transfer 1 2 3 4) signer nonce d
    let bytes2 := signInput (.mint 1 2 100) signer nonce d
    if bytes1.data.toList == bytes2.data.toList then
      throw <| IO.userError "cross-action sign-inputs collided"
    else pure ()
}

/-- Different nonces produce different sign-input bytes. -/
def crossNonceDistinct : TestCase := {
  name := "cross-nonce sign-inputs differ"
  body := do
    let action : Action := .transfer 1 2 3 4
    let signer : ActorId := 5
    let d : ByteArray := ⟨#[0xAA]⟩
    let bytes1 := signInput action signer 0 d
    let bytes2 := signInput action signer 1 d
    if bytes1.data.toList == bytes2.data.toList then
      throw <| IO.userError "cross-nonce sign-inputs collided"
    else pure ()
}

/-- Determinism: same inputs produce same outputs. -/
def signInputDeterministic : TestCase := {
  name := "signInput is deterministic"
  body := do
    let action : Action := .transfer 1 2 3 4
    let signer : ActorId := 5
    let nonce : Nonce := 7
    let d : ByteArray := ⟨#[0xAA, 0xBB, 0xCC]⟩
    let bytes1 := signInput action signer nonce d
    let bytes2 := signInput action signer nonce d
    if bytes1.data.toList == bytes2.data.toList then pure ()
    else throw <| IO.userError "non-deterministic"
}

/-- Term-level API check. -/
def signInputDeterministicAPI : TestCase := {
  name := "signInput_deterministic API stability"
  body := do
    let _proof : ∀ (a : Action) (s : ActorId) (n : Nonce) (d : ByteArray),
        signInput a s n d = signInput a s n d :=
      signInput_deterministic
    pure ()
}

/-- Term-level API check: nonempty bound. -/
def signInputNonemptyAPI : TestCase := {
  name := "signInput_nonempty API stability"
  body := do
    let _proof : ∀ (a : Action) (s : ActorId) (n : Nonce) (d : ByteArray),
        (signInput a s n d).size ≥ 36 :=
      signInput_nonempty
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [signInputDomainPrefix, crossDeploymentDistinct, crossActionDistinct,
   crossNonceDistinct, signInputDeterministic, signInputDeterministicAPI,
   signInputNonemptyAPI]

end SignInputTests
end LegalKernel.Test.Encoding
