/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.State — Phase-4 WU 4.5 / WU 4.6 / WU 4.7
tests for the `State` and `ExtendedState` encoders.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.State

namespace LegalKernel.Test.Encoding
namespace StateTests

open LegalKernel.Encoding
open LegalKernel.Authority

/-- Encoding the empty state produces a known fixed byte sequence
    (one CBE map head with count 0 = 9 bytes). -/
def emptyStateBytes : TestCase := {
  name := "encode empty state has 9-byte head"
  body := do
    let s : LegalKernel.State := { balances := ∅ }
    let bytes := Encodable.encode (T := LegalKernel.State) s
    -- One outer map head with count 0 = 9 bytes.
    assertEq (9 : Nat) bytes.length "empty state encoding length"
}

/-- Determinism: encoding a state twice produces the same bytes. -/
def stateEncodeDeterministic : TestCase := {
  name := "state encode is deterministic"
  body := do
    let s : LegalKernel.State :=
      LegalKernel.setBalance ({ balances := ∅ }) 1 2 100
    let bytes1 := Encodable.encode (T := LegalKernel.State) s
    let bytes2 := Encodable.encode (T := LegalKernel.State) s
    assertEq bytes1.length bytes2.length "encoded lengths"
    if bytes1 == bytes2 then pure () else throw <| IO.userError "non-deterministic"
}

/-- Determinism across insertion order: two states built from
    different insert sequences but with the same final extensional
    content should produce the same bytes (because TreeMap maintains
    canonical RB shape under TransCmp).  Note: this property holds
    structurally for TreeMap, not just extensionally. -/
def stateEncodeOrderInvariant : TestCase := {
  name := "state encoding is order-invariant"
  body := do
    let s1 : LegalKernel.State :=
      LegalKernel.setBalance
        (LegalKernel.setBalance ({ balances := ∅ }) 1 2 100)
        1 3 200
    let s2 : LegalKernel.State :=
      LegalKernel.setBalance
        (LegalKernel.setBalance ({ balances := ∅ }) 1 3 200)
        1 2 100
    let bytes1 := Encodable.encode (T := LegalKernel.State) s1
    let bytes2 := Encodable.encode (T := LegalKernel.State) s2
    if bytes1 == bytes2 then pure ()
    else throw <| IO.userError "different insertion orders produced different bytes"
}

/-- Term-level API check: `state_encode_deterministic`. -/
def stateDeterministicAPI : TestCase := {
  name := "state_encode_deterministic API stability"
  body := do
    let _proof : ∀ (s₁ s₂ : LegalKernel.State), s₁ = s₂ →
      Encodable.encode (T := LegalKernel.State) s₁ =
      Encodable.encode (T := LegalKernel.State) s₂ :=
      state_encode_deterministic
    pure ()
}

/-- Term-level API check: `extendedState_encode_deterministic`. -/
def extendedStateDeterministicAPI : TestCase := {
  name := "extendedState_encode_deterministic API stability"
  body := do
    let _proof : ∀ (es₁ es₂ : ExtendedState), es₁ = es₂ →
      Encodable.encode (T := ExtendedState) es₁ =
      Encodable.encode (T := ExtendedState) es₂ :=
      extendedState_encode_deterministic
    pure ()
}

/-- Term-level API check: `balanceMap_encode_deterministic_of_equiv`. -/
def balanceMapEquivAPI : TestCase := {
  name := "balanceMap_encode_deterministic_of_equiv API stability"
  body := do
    let _proof : ∀ (bm₁ bm₂ : LegalKernel.BalanceMap), bm₁.Equiv bm₂ →
      BalanceMap.encode bm₁ = BalanceMap.encode bm₂ :=
      balanceMap_encode_deterministic_of_equiv
    pure ()
}

/-- Real round-trip: encode then decode a non-empty state, verify
    the decoded state agrees with the original at every probed
    `(resource, actor)` cell. -/
def stateRoundtripGetBalance : TestCase := {
  name := "state encode-then-decode preserves getBalance"
  body := do
    let s : LegalKernel.State :=
      LegalKernel.setBalance
        (LegalKernel.setBalance ({ balances := ∅ }) 1 2 100)
        2 3 200
    let bytes := Encodable.encode (T := LegalKernel.State) s
    match Encodable.decode (T := LegalKernel.State) bytes with
    | .ok (s', rest) =>
      assertEq (0 : Nat) rest.length "no residual"
      assertEq (LegalKernel.getBalance s 1 2) (LegalKernel.getBalance s' 1 2) "(1,2)"
      assertEq (LegalKernel.getBalance s 2 3) (LegalKernel.getBalance s' 2 3) "(2,3)"
      assertEq (LegalKernel.getBalance s 1 3) (LegalKernel.getBalance s' 1 3) "(1,3)"
      assertEq (LegalKernel.getBalance s 5 5) (LegalKernel.getBalance s' 5 5) "(5,5)"
    | .error e => throw <| IO.userError s!"State round-trip decode failed: {repr e}"
}

/-- Empty-state round-trip: ensures the trivial path also works. -/
def emptyStateRoundtrip : TestCase := {
  name := "empty state encode-then-decode is empty state"
  body := do
    let s : LegalKernel.State := { balances := ∅ }
    let bytes := Encodable.encode (T := LegalKernel.State) s
    match Encodable.decode (T := LegalKernel.State) bytes with
    | .ok (s', rest) =>
      assertEq (0 : Nat) rest.length "no residual"
      assertEq (0 : Amount) (LegalKernel.getBalance s' 0 0) "default balance"
    | .error e => throw <| IO.userError s!"Empty State round-trip failed: {repr e}"
}

/-- ExtendedState round-trip: verify base, nonces, and registry all
    survive an encode-then-decode pass. -/
def extendedStateRoundtrip : TestCase := {
  name := "ExtendedState encode-then-decode preserves fields"
  body := do
    let pk : PublicKey := ⟨#[0x11, 0x22, 0x33]⟩
    let es : ExtendedState :=
      { base    := LegalKernel.setBalance ({ balances := ∅ }) 1 2 100
      , nonces  := { next := (∅ : Std.TreeMap _ _ _).insert 5 7 }
      , registry := KeyRegistry.empty.register 5 pk }
    let bytes := Encodable.encode (T := ExtendedState) es
    match Encodable.decode (T := ExtendedState) bytes with
    | .ok (es', rest) =>
      assertEq (0 : Nat) rest.length "no residual"
      assertEq (LegalKernel.getBalance es.base 1 2) (LegalKernel.getBalance es'.base 1 2)
        "base balance"
      assertEq (expectsNonce es 5) (expectsNonce es' 5) "nonce for actor 5"
      assertEq (es.registry.lookup 5).isSome (es'.registry.lookup 5).isSome
        "registry lookup for actor 5"
    | .error e => throw <| IO.userError s!"ExtendedState round-trip failed: {repr e}"
}

/-- All tests. -/
def tests : List TestCase :=
  [emptyStateBytes, emptyStateRoundtrip, stateEncodeDeterministic,
   stateEncodeOrderInvariant, stateRoundtripGetBalance, extendedStateRoundtrip,
   stateDeterministicAPI, extendedStateDeterministicAPI, balanceMapEquivAPI]

end StateTests
end LegalKernel.Test.Encoding
