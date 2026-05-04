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

/-! ## Canonicality enforcement (§8.8.6)

The decoder must reject *non-canonical* CBE map encodings — those
with unsorted or duplicate keys.  Without these rejections an
attacker could forge an alternative-but-equally-valid encoding of
the same logical state with a different signature input. -/

/-- Decoder rejects unsorted-key map. -/
def decoderRejectsUnsortedKeys : TestCase := {
  name := "decoder rejects unsorted-key map (canonicality)"
  body := do
    -- Build a CBE map manually with keys 5, 3 (unsorted).
    let mapHead := cborHeadEncode cbeTagMap 2
    let key5 := cborHeadEncode cbeTagUint 5
    let val100 := cborHeadEncode cbeTagUint 100
    let key3 := cborHeadEncode cbeTagUint 3
    let val200 := cborHeadEncode cbeTagUint 200
    let unsorted := mapHead ++ key5 ++ val100 ++ key3 ++ val200
    match BalanceMap.decode unsorted with
    | .ok _ =>
      throw <| IO.userError "BUG: decoder accepted unsorted-key map"
    | .error _ => pure ()
}

/-- Decoder rejects duplicate-key map. -/
def decoderRejectsDuplicateKeys : TestCase := {
  name := "decoder rejects duplicate-key map (canonicality)"
  body := do
    let mapHead := cborHeadEncode cbeTagMap 2
    let key5 := cborHeadEncode cbeTagUint 5
    let val100 := cborHeadEncode cbeTagUint 100
    let val200 := cborHeadEncode cbeTagUint 200
    let dup := mapHead ++ key5 ++ val100 ++ key5 ++ val200
    match BalanceMap.decode dup with
    | .ok _ =>
      throw <| IO.userError "BUG: decoder accepted duplicate-key map"
    | .error _ => pure ()
}

/-- Decoder accepts a canonical (sorted, distinct) map.  Sanity
    check that the canonicality enforcement doesn't reject valid
    inputs. -/
def decoderAcceptsCanonicalMap : TestCase := {
  name := "decoder accepts canonical (sorted, distinct) map"
  body := do
    let mapHead := cborHeadEncode cbeTagMap 2
    let key3 := cborHeadEncode cbeTagUint 3
    let val200 := cborHeadEncode cbeTagUint 200
    let key5 := cborHeadEncode cbeTagUint 5
    let val100 := cborHeadEncode cbeTagUint 100
    let canonical := mapHead ++ key3 ++ val200 ++ key5 ++ val100
    match BalanceMap.decode canonical with
    | .ok (bm, rest) =>
      assertEq (0 : Nat) rest.length "no residual"
      assertEq (200 : Amount) (bm[(3 : ActorId)]?.getD 0) "actor 3 balance"
      assertEq (100 : Amount) (bm[(5 : ActorId)]?.getD 0) "actor 5 balance"
    | .error e => throw <| IO.userError s!"Canonical map rejected: {repr e}"
}

/-- Encode-decode-encode idempotence: encoding a state, decoding it,
    and re-encoding the result must produce the original bytes.
    This is the operational form of the §8.8.3 canonicality
    requirement: the canonical bytes are a *fixed point* of the
    encode-after-decode operation. -/
def stateEncodeDecodeEncodeIdempotent : TestCase := {
  name := "encode-decode-encode is idempotent"
  body := do
    let s : LegalKernel.State :=
      LegalKernel.setBalance
        (LegalKernel.setBalance
          (LegalKernel.setBalance ({ balances := ∅ }) 1 2 100)
          2 3 200)
        1 7 999
    let bytes1 := Encodable.encode (T := LegalKernel.State) s
    match Encodable.decode (T := LegalKernel.State) bytes1 with
    | .ok (s', _) =>
      let bytes2 := Encodable.encode (T := LegalKernel.State) s'
      if bytes1 == bytes2 then pure ()
      else throw <| IO.userError "encode-decode-encode produced different bytes"
    | .error e => throw <| IO.userError s!"intermediate decode failed: {repr e}"
}

/-- All tests. -/
def tests : List TestCase :=
  [emptyStateBytes, emptyStateRoundtrip, stateEncodeDeterministic,
   stateEncodeOrderInvariant, stateRoundtripGetBalance, extendedStateRoundtrip,
   decoderRejectsUnsortedKeys, decoderRejectsDuplicateKeys, decoderAcceptsCanonicalMap,
   stateEncodeDecodeEncodeIdempotent,
   stateDeterministicAPI, extendedStateDeterministicAPI, balanceMapEquivAPI]

end StateTests
end LegalKernel.Test.Encoding
