-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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

/-! ## Workstream LP / LP.3 — ExtendedState with non-empty localPolicies -/

/-- `ExtendedState` round-trip with non-empty `localPolicies`: a
    declared policy survives encode-then-decode at the
    `LocalPolicies.lookup` level. -/
def extendedStateLocalPoliciesRoundtrip : TestCase := {
  name := "ExtendedState round-trip preserves declared policy"
  body := do
    let p : Authority.LocalPolicy :=
      { clauses := [.denyTags [0], .capAmount 1 100] }
    let lp := Authority.LocalPolicies.empty.declare 1 p
    let es : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := lp }
    let bytes := Encodable.encode (T := Authority.ExtendedState) es
    match Encodable.decode (T := Authority.ExtendedState) bytes with
    | .ok (es', _) =>
      assertEq p (es'.localPolicies.lookup 1) "policy survives encode/decode"
    | .error e =>
      throw <| IO.userError s!"ExtendedState decode failed: {repr e}"
}

/-- `ExtendedState` with multiple declared policies (different
    actors) round-trips correctly. -/
def extendedStateMultiActorPoliciesRoundtrip : TestCase := {
  name := "ExtendedState round-trip preserves multi-actor policies"
  body := do
    let p₁ : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
    let p₂ : Authority.LocalPolicy := { clauses := [.denyTags [1]] }
    let p₃ : Authority.LocalPolicy := { clauses := [.capAmount 1 50] }
    let lp := ((Authority.LocalPolicies.empty.declare 1 p₁).declare 2 p₂).declare 3 p₃
    let es : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := lp }
    let bytes := Encodable.encode (T := Authority.ExtendedState) es
    match Encodable.decode (T := Authority.ExtendedState) bytes with
    | .ok (es', _) =>
      assertEq p₁ (es'.localPolicies.lookup 1) "actor 1 policy"
      assertEq p₂ (es'.localPolicies.lookup 2) "actor 2 policy"
      assertEq p₃ (es'.localPolicies.lookup 3) "actor 3 policy"
      assertEq Authority.LocalPolicy.empty (es'.localPolicies.lookup 4)
        "unmapped actor returns empty"
    | .error e =>
      throw <| IO.userError s!"ExtendedState decode failed: {repr e}"
}

/-- `ExtendedState.encode` is deterministic: equal states produce
    equal bytes (regression for LP.3's 5-segment encoding). -/
def extendedStateLPDeterministic : TestCase := {
  name := "ExtendedState encode is deterministic with localPolicies"
  body := do
    let p : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
    let lp := Authority.LocalPolicies.empty.declare 1 p
    let es : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := lp }
    let b1 := Encodable.encode (T := Authority.ExtendedState) es
    let b2 := Encodable.encode (T := Authority.ExtendedState) es
    if b1 == b2 then pure ()
    else throw <| IO.userError "encoding non-deterministic"
}

/-! ## Workstream GP / GP.3.1 — ExtendedState budget fields -/

/-- `ExtendedState` round-trip preserves epoch budget entries and
    bounded `budgetPolicy`. -/
def extendedStateBudgetFieldsRoundtrip : TestCase := {
  name := "ExtendedState round-trip preserves epochBudgets and budgetPolicy"
  body := do
    let ebs := EpochBudgetState.topUp EpochBudgetState.empty 7 3 11 42
    let es : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := Authority.LocalPolicies.empty
      , epochBudgets := ebs
      , budgetPolicy := .bounded 11 5 3 }
    let bytes := Encodable.encode (T := Authority.ExtendedState) es
    match Encodable.decode (T := Authority.ExtendedState) bytes with
    | .ok (es', rest) =>
      assertEq (0 : Nat) rest.length "no residual"
      assertEq (EpochBudgetState.currentBudget es.epochBudgets 7 3 11)
        (EpochBudgetState.currentBudget es'.epochBudgets 7 3 11)
        "budget cell survives encode/decode"
      assertEq es.budgetPolicy es'.budgetPolicy "budgetPolicy survives encode/decode"
    | .error e =>
      throw <| IO.userError s!"ExtendedState decode failed: {repr e}"
}

/-- Decoder rejects an invalid `BudgetPolicy` tag in the final segment
    of `ExtendedState` encoding. -/
def extendedStateRejectsInvalidBudgetPolicyTag : TestCase := {
  name := "ExtendedState decode rejects invalid budgetPolicy tag"
  body := do
    let es : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := Authority.LocalPolicies.empty
      , epochBudgets := EpochBudgetState.empty
      , budgetPolicy := .bounded 0 1 0 }
    let good := Encodable.encode (T := Authority.ExtendedState) es
    -- Replace final budgetPolicy segment with invalid tag 2.
    let bad :=
      State.encode es.base ++
      NonceState.encode es.nonces ++
      KeyRegistry.encodeMap es.registry ++
      Bridge.BridgeState.encode es.bridge ++
      LocalPolicies.encodeMap es.localPolicies ++
      encodeSortedPairs (K := Nat) (V := ActorBudget)
        (es.epochBudgets.toList.map (fun (a, b) => (a.toNat, b))) ++
      Encodable.encode (T := Nat) 2
    -- sanity: ensure we actually changed bytes
    assert (good ≠ bad) "constructed malformed bytes must differ"
    match Encodable.decode (T := Authority.ExtendedState) bad with
    | .ok _ => throw <| IO.userError "BUG: invalid budgetPolicy tag was accepted"
    | .error _ => pure ()
}

/-- Decoder rejects bounded budget policy with zero actionCost:
    this would otherwise disable budget consumption in bounded mode. -/
def extendedStateRejectsZeroActionCostPolicy : TestCase := {
  name := "ExtendedState decode rejects budgetPolicy actionCost = 0"
  body := do
    let es : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := Authority.LocalPolicies.empty
      , epochBudgets := EpochBudgetState.empty
      , budgetPolicy := .bounded 0 1 0 }
    let bad :=
      State.encode es.base ++
      NonceState.encode es.nonces ++
      KeyRegistry.encodeMap es.registry ++
      Bridge.BridgeState.encode es.bridge ++
      LocalPolicies.encodeMap es.localPolicies ++
      encodeSortedPairs (K := Nat) (V := ActorBudget)
        (es.epochBudgets.toList.map (fun (a, b) => (a.toNat, b))) ++
      Encodable.encode (T := Nat) 0 ++ -- bounded tag
      Encodable.encode (T := Nat) 0 ++ -- freeTier
      Encodable.encode (T := Nat) 0 ++ -- actionCost (invalid)
      Encodable.encode (T := Nat) 0    -- currentEpoch
    match Encodable.decode (T := Authority.ExtendedState) bad with
    | .ok _ => throw <| IO.userError "BUG: zero actionCost policy was accepted"
    | .error _ => pure ()
}

/-! ## GP.3.1.d — `ActorBudget` and `BudgetPolicy` encoder injectivity -/

/-- `actorBudget_roundtrip` is term-level callable with the expected
    signature.  Pin so the GP.3.1.d theorem signature does not silently
    drift. -/
def actorBudgetRoundtripAPI : TestCase := {
  name := "actorBudget_roundtrip API stability"
  body := do
    let _proof :
        ∀ (b : ActorBudget) (rest : Stream),
          b.lastSeenEpoch < 256 ^ 8 →
          b.budgetBalance < 256 ^ 8 →
          ActorBudget.decode (ActorBudget.encode b ++ rest) = .ok (b, rest) :=
      actorBudget_roundtrip
    pure ()
}

/-- `actorBudget_encode_injective` is term-level callable.  Equal
    encoded bytes imply equal `ActorBudget` structures under
    canonical-encoding bounds. -/
def actorBudgetEncodeInjectiveAPI : TestCase := {
  name := "actorBudget_encode_injective API stability"
  body := do
    let _proof :
        ∀ (b₁ b₂ : ActorBudget),
          b₁.lastSeenEpoch < 256 ^ 8 →
          b₁.budgetBalance < 256 ^ 8 →
          b₂.lastSeenEpoch < 256 ^ 8 →
          b₂.budgetBalance < 256 ^ 8 →
          ActorBudget.encode b₁ = ActorBudget.encode b₂ →
          b₁ = b₂ :=
      actorBudget_encode_injective
    pure ()
}

/-- `budgetPolicy_bounded_roundtrip` is term-level callable.  Encode-
    then-decode reconstructs `.bounded` exactly under canonical
    bounds + `actionCost ≥ 1`. -/
def budgetPolicyRoundtripAPI : TestCase := {
  name := "budgetPolicy_bounded_roundtrip API stability"
  body := do
    let _proof :
        ∀ (freeTier actionCost currentEpoch : Nat) (rest : Stream),
          freeTier < 256 ^ 8 →
          actionCost < 256 ^ 8 →
          currentEpoch < 256 ^ 8 →
          1 ≤ actionCost →
          BudgetPolicy.decode
              (BudgetPolicy.encode (.bounded freeTier actionCost currentEpoch) ++ rest)
            = .ok (.bounded freeTier actionCost currentEpoch, rest) :=
      budgetPolicy_bounded_roundtrip
    pure ()
}

/-- `budgetPolicy_encode_injective` is term-level callable. -/
def budgetPolicyEncodeInjectiveAPI : TestCase := {
  name := "budgetPolicy_encode_injective API stability"
  body := do
    let _proof :
        ∀ (p₁ p₂ : BudgetPolicy),
          (∀ ft ac ce, p₁ = .bounded ft ac ce →
              ft < 256 ^ 8 ∧ ac < 256 ^ 8 ∧ ce < 256 ^ 8 ∧ 1 ≤ ac) →
          (∀ ft ac ce, p₂ = .bounded ft ac ce →
              ft < 256 ^ 8 ∧ ac < 256 ^ 8 ∧ ce < 256 ^ 8 ∧ 1 ≤ ac) →
          BudgetPolicy.encode p₁ = BudgetPolicy.encode p₂ →
          p₁ = p₂ :=
      budgetPolicy_encode_injective
    pure ()
}

/-- Distinct `ActorBudget`s encode to distinct bytes — the value-level
    consequence of the encoder-injectivity theorem.  Catches silent
    encoder-collapse regressions even when canonical bounds aren't
    available to discharge the theorem statement directly. -/
def actorBudgetEncodeDistinguishesFields : TestCase := {
  name := "ActorBudget.encode distinguishes lastSeenEpoch and budgetBalance"
  body := do
    let b1 : ActorBudget := { lastSeenEpoch := 3, budgetBalance := 5 }
    let b2 : ActorBudget := { lastSeenEpoch := 4, budgetBalance := 5 }
    let b3 : ActorBudget := { lastSeenEpoch := 3, budgetBalance := 6 }
    assert (ActorBudget.encode b1 ≠ ActorBudget.encode b2)
      "ActorBudget.encode must distinguish lastSeenEpoch"
    assert (ActorBudget.encode b1 ≠ ActorBudget.encode b3)
      "ActorBudget.encode must distinguish budgetBalance"
}

/-- Distinct `BudgetPolicy`s encode to distinct bytes.  Catches
    encoder-collapse regressions across all three fields. -/
def budgetPolicyEncodeDistinguishesFields : TestCase := {
  name := "BudgetPolicy.encode distinguishes freeTier, actionCost, currentEpoch"
  body := do
    let p1 : BudgetPolicy := .bounded 10 1 0
    let p2 : BudgetPolicy := .bounded 11 1 0
    let p3 : BudgetPolicy := .bounded 10 2 0
    let p4 : BudgetPolicy := .bounded 10 1 1
    assert (BudgetPolicy.encode p1 ≠ BudgetPolicy.encode p2)
      "BudgetPolicy.encode must distinguish freeTier"
    assert (BudgetPolicy.encode p1 ≠ BudgetPolicy.encode p3)
      "BudgetPolicy.encode must distinguish actionCost"
    assert (BudgetPolicy.encode p1 ≠ BudgetPolicy.encode p4)
      "BudgetPolicy.encode must distinguish currentEpoch"
}

/-- Round-trip smoke check: encoding then decoding an `ActorBudget`
    with non-trivial fields recovers the original. -/
def actorBudgetRoundtripSmoke : TestCase := {
  name := "ActorBudget round-trip recovers original (value-level)"
  body := do
    let b : ActorBudget := { lastSeenEpoch := 5, budgetBalance := 42 }
    let bytes := ActorBudget.encode b ++ ([] : Stream)
    match ActorBudget.decode bytes with
    | .ok (b', rest) =>
      assertEq b.lastSeenEpoch b'.lastSeenEpoch "lastSeenEpoch survives"
      assertEq b.budgetBalance b'.budgetBalance "budgetBalance survives"
      assertEq (0 : Nat) rest.length "no residual bytes"
    | .error e =>
      throw <| IO.userError s!"ActorBudget decode failed: {repr e}"
}

/-- Round-trip smoke check: encoding then decoding a `BudgetPolicy`
    with non-trivial fields recovers the original. -/
def budgetPolicyRoundtripSmoke : TestCase := {
  name := "BudgetPolicy round-trip recovers original (value-level)"
  body := do
    let p : BudgetPolicy := .bounded 7 3 11
    let bytes := BudgetPolicy.encode p ++ ([] : Stream)
    match BudgetPolicy.decode bytes with
    | .ok (p', rest) =>
      assertEq p p' "BudgetPolicy survives encode+decode"
      assertEq (0 : Nat) rest.length "no residual bytes"
    | .error e =>
      throw <| IO.userError s!"BudgetPolicy decode failed: {repr e}"
}

/-- `ExtendedState.encode` is sensitive to changes in the new
    GP.3.1 budget fields: two states differing only in
    `budgetPolicy` (or only in `epochBudgets`) must encode to
    distinct byte streams.  This is the value-level contrapositive
    of encoder injectivity for the new fields, and catches
    encoder-collapse regressions where someone might forget to
    include a field in the encoding. -/
def extendedStateEncodeSensitiveToBudgetFields : TestCase := {
  name := "ExtendedState.encode is sensitive to budgetPolicy and epochBudgets"
  body := do
    let esBase : Authority.ExtendedState :=
      { base := emptyState
      , nonces := Authority.NonceState.empty
      , registry := Authority.KeyRegistry.empty
      , localPolicies := Authority.LocalPolicies.empty
      , epochBudgets := EpochBudgetState.empty
      , budgetPolicy := .bounded 5 1 0 }
    -- Vary budgetPolicy: freeTier 5 → 6.
    let esOther1 : Authority.ExtendedState :=
      { esBase with budgetPolicy := .bounded 6 1 0 }
    -- Vary budgetPolicy: actionCost 1 → 2.
    let esOther2 : Authority.ExtendedState :=
      { esBase with budgetPolicy := .bounded 5 2 0 }
    -- Vary budgetPolicy: currentEpoch 0 → 7.
    let esOther3 : Authority.ExtendedState :=
      { esBase with budgetPolicy := .bounded 5 1 7 }
    -- Vary epochBudgets: insert an entry.
    let esOther4 : Authority.ExtendedState :=
      { esBase with
        epochBudgets := EpochBudgetState.topUp EpochBudgetState.empty 42 0 5 3 }
    let baseBytes := Encodable.encode (T := Authority.ExtendedState) esBase
    let b1 := Encodable.encode (T := Authority.ExtendedState) esOther1
    let b2 := Encodable.encode (T := Authority.ExtendedState) esOther2
    let b3 := Encodable.encode (T := Authority.ExtendedState) esOther3
    let b4 := Encodable.encode (T := Authority.ExtendedState) esOther4
    assert (baseBytes ≠ b1)
      "ExtendedState.encode must distinguish budgetPolicy.freeTier"
    assert (baseBytes ≠ b2)
      "ExtendedState.encode must distinguish budgetPolicy.actionCost"
    assert (baseBytes ≠ b3)
      "ExtendedState.encode must distinguish budgetPolicy.currentEpoch"
    assert (baseBytes ≠ b4)
      "ExtendedState.encode must distinguish epochBudgets entries"
}

/-! ### GP.6.2 — byte-exact cross-stack known vectors

These pin the EXACT CBE byte layout of `ActorBudget.encode`,
`BudgetPolicy.encode`, and the `encodeSortedPairs` map form embedded
in `ExtendedState.encode` for `epochBudgets`.  The
`knomosis-host::budget` Rust mirror pins the SAME hand-computed bytes
(`runtime/knomosis-host/src/budget.rs` known-vector tests), so the two
sides are byte-for-byte equivalent — the GP.6.2 "byte-equivalent CBE
encoding to the Lean side" deliverable.  The expected bytes are built
from a hand-rolled layout helper (NOT the production encoder), so the
check is non-circular. -/

/-- Hand-rolled CBE uint head (`cbeTagUint` + 8-byte LE value),
    independent of the production encoder.  Valid for `n < 256`
    (every value in the known vectors fits a single low byte). -/
private def kvUint (n : Nat) : List UInt8 :=
  [0x00, UInt8.ofNat n, 0, 0, 0, 0, 0, 0, 0]

/-- Hand-rolled CBE map head (`cbeTagMap` + 8-byte LE count),
    independent of the production encoder.  Valid for `count < 256`. -/
private def kvMapHead (count : Nat) : List UInt8 :=
  [0x05, UInt8.ofNat count, 0, 0, 0, 0, 0, 0, 0]

/-- `ActorBudget.encode { lastSeenEpoch := 1, budgetBalance := 2 }`
    is `lastSeenEpoch` uint ++ `budgetBalance` uint, byte-for-byte. -/
def actorBudgetEncodeKnownVector : TestCase := {
  name := "ActorBudget.encode byte-exact known vector (cross-stack)"
  body := do
    let b : ActorBudget := { lastSeenEpoch := 1, budgetBalance := 2 }
    assertEq (kvUint 1 ++ kvUint 2) (ActorBudget.encode b)
      "ActorBudget.encode {1,2} byte layout"
}

/-- Multi-byte cross-stack vector: `ActorBudget.encode` lays each
    `Nat` field as a full 8-byte little-endian head (not just the low
    byte).  Pinned against an EXPLICIT hand-computed LE literal for
    the same value the Rust `actor_budget_encode_multibyte_le` test
    pins, so the byte-equivalence covers the full 8-byte range. -/
def actorBudgetEncodeMultibyteKnownVector : TestCase := {
  name := "ActorBudget.encode multi-byte LE known vector (cross-stack)"
  body := do
    -- lastSeenEpoch = 0x0102030405060708, budgetBalance = 0x1122334455667788.
    let b : ActorBudget :=
      { lastSeenEpoch := 0x0102030405060708, budgetBalance := 0x1122334455667788 }
    let expected : List UInt8 :=
      [0x00, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
       0x00, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]
    assertEq expected (ActorBudget.encode b) "ActorBudget.encode multi-byte LE layout"
}

/-- `BudgetPolicy.encode (.bounded 10 1 1)` is the constructor tag 0
    followed by `freeTier`, `actionCost`, `currentEpoch` uints. -/
def budgetPolicyEncodeKnownVector : TestCase := {
  name := "BudgetPolicy.encode byte-exact known vector (cross-stack)"
  body := do
    let p : BudgetPolicy := .bounded 10 1 1
    assertEq (kvUint 0 ++ kvUint 10 ++ kvUint 1 ++ kvUint 1) (BudgetPolicy.encode p)
      "BudgetPolicy.encode (.bounded 10 1 1) byte layout"
}

/-- The `epochBudgets` map form embedded in `ExtendedState.encode`
    (`encodeSortedPairs` over the actor→cell pairs) is byte-exact: a
    map head (count 2) then each `(actorId, cell)` pair in ascending
    actor order.  Pinned against the Rust
    `epoch_budget_state_encode_known_vector` mirror. -/
def epochBudgetsMapEncodeKnownVector : TestCase := {
  name := "epochBudgets encodeSortedPairs byte-exact known vector (cross-stack)"
  body := do
    -- Insert out of order; the TreeMap stores ascending by key.
    let ebs : EpochBudgetState :=
      (EpochBudgetState.empty.insert (20 : ActorId)
            ({ lastSeenEpoch := 2, budgetBalance := 7 } : ActorBudget)).insert (10 : ActorId)
        ({ lastSeenEpoch := 1, budgetBalance := 5 } : ActorBudget)
    -- Exactly the expression `ExtendedState.encode` uses for the
    -- `epochBudgets` segment.
    let actual := encodeSortedPairs (ebs.toList.map (fun p => (p.1.toNat, p.2)))
    let expected : List UInt8 :=
      kvMapHead 2 ++
      (kvUint 10 ++ kvUint 1 ++ kvUint 5) ++
      (kvUint 20 ++ kvUint 2 ++ kvUint 7)
    assertEq expected actual "epochBudgets map byte layout"
}

/-- `EpochBudgetState` (a `TreeMap ActorId ActorBudget compare`)
    orders its keys UNSIGNED-ascending — the property the cross-stack
    map encoding relies on to match the Rust `BTreeMap<u64>` mirror.
    The `2^63` boundary distinguishes unsigned from signed ordering:
    under unsigned `1 < 2^63`; a signed comparison would treat `2^63`
    as negative and sort it first.  Paired with the Rust
    `epoch_budget_state_orders_keys_unsigned` test, this pins the
    cross-stack ordering contract for the full `UInt64` range. -/
def epochBudgetsLargeKeyOrdering : TestCase := {
  name := "EpochBudgetState orders UInt64 keys unsigned-ascending (cross-stack)"
  body := do
    let cell : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }
    -- 2^63 = 9223372036854775808.  Insert the large key first.
    let ebs : EpochBudgetState :=
      (EpochBudgetState.empty.insert (9223372036854775808 : ActorId) cell).insert
        (1 : ActorId) cell
    let keys := ebs.toList.map (fun p => p.1)
    assertEq [(1 : ActorId), (9223372036854775808 : ActorId)] keys
      "EpochBudgetState.toList must order UInt64 keys unsigned-ascending"
}

/-- All tests. -/
def tests : List TestCase :=
  [emptyStateBytes, emptyStateRoundtrip, stateEncodeDeterministic,
   stateEncodeOrderInvariant, stateRoundtripGetBalance, extendedStateRoundtrip,
   decoderRejectsUnsortedKeys, decoderRejectsDuplicateKeys, decoderAcceptsCanonicalMap,
   stateEncodeDecodeEncodeIdempotent,
   stateDeterministicAPI, extendedStateDeterministicAPI, balanceMapEquivAPI,
   -- LP.3:
   extendedStateLocalPoliciesRoundtrip,
   extendedStateMultiActorPoliciesRoundtrip,
   extendedStateLPDeterministic,
   -- GP.3.1:
   extendedStateBudgetFieldsRoundtrip,
   extendedStateRejectsInvalidBudgetPolicyTag,
   extendedStateRejectsZeroActionCostPolicy,
   -- GP.3.1.d (encoder injectivity for new fields):
   actorBudgetRoundtripAPI,
   actorBudgetEncodeInjectiveAPI,
   budgetPolicyRoundtripAPI,
   budgetPolicyEncodeInjectiveAPI,
   actorBudgetEncodeDistinguishesFields,
   budgetPolicyEncodeDistinguishesFields,
   actorBudgetRoundtripSmoke,
   budgetPolicyRoundtripSmoke,
   extendedStateEncodeSensitiveToBudgetFields,
   -- GP.6.2 (byte-exact cross-stack known vectors):
   actorBudgetEncodeKnownVector,
   actorBudgetEncodeMultibyteKnownVector,
   budgetPolicyEncodeKnownVector,
   epochBudgetsMapEncodeKnownVector,
   epochBudgetsLargeKeyOrdering]

end StateTests
end LegalKernel.Test.Encoding
