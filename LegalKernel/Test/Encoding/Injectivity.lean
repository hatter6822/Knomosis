/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.Injectivity — Workstream EI scaffolding
(`docs/planning/encoder_injectivity_plan.md` §4.0 EI.0.c).

This module is the home for every Workstream-EI test case.  It is
seeded with four shared-fixture smoke checks at the EI.0.c
landing: no per-theorem coverage has shipped yet because the
per-theorem proofs (EI.1 onwards) have not landed.  Each
subsequent EI sub-sub-unit adds its own `TestCase` values (term-
level API-stability checks plus value-level fixture-pair
assertions) and appends them to `tests` here.

The module also houses *shared fixtures* used by EI.1 – EI.7's
per-sub-state test bundles.  Hoisting these helpers up here keeps
each EI sub-unit's PR scoped to a single new theorem plus a small
`TestCase` block, with no duplicated fixture machinery.

Wiring:
  * Imported by `Tests.lean` so the umbrella driver picks the
    suite up.
  * Registered in the umbrella `main` under the
    `"encoding-injectivity"` suite name.
  * `lake test` runs the suite alongside every other test
    module.

Per CLAUDE.md "Background-agent file-change protection" §, this
file is owned by Workstream EI and should not be edited by any
non-EI workstream.

Reference: §3 of the encoder-injectivity plan (dependency DAG)
and Appendix A (theorem-to-test cross-reference matrix).
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.State

namespace LegalKernel.Test.Encoding
namespace InjectivityTests

open Std
open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## Shared fixtures

A `genTreeMap` helper that produces representative
`Std.TreeMap ActorId Amount compare` fixtures in three sizes
(empty, singleton, three-element).  Hoisted here so that EI.2 –
EI.7's per-sub-state tests share a single source of test maps,
keeping the fixture surface easy to extend (the `BalanceMap`
abbrev is `TreeMap ActorId Amount compare`, which is the most
common shape used by EI's per-sub-state proofs). -/

/-- Fixture size knob — the three canonical shapes used by EI
    per-sub-state tests.  Adding a new size variant (e.g. a
    sixteen-element stress case) only needs an `EI.size` extension
    here, not a per-test rewrite. -/
inductive FixtureSize
  /-- The empty map.  Exercises the "0-pair" branch of every
      sub-state's encoder. -/
  | empty
  /-- A singleton map (one `(key, value)` pair).  Exercises the
      head-only branch. -/
  | singleton
  /-- A three-element map.  Exercises the inductive case at the
      smallest non-trivial size.  Test bodies that need a larger
      fixture should grow the inductive `FixtureSize` rather than
      bypass it ad hoc. -/
  | three
deriving DecidableEq, Repr

/-- Shared `BalanceMap` fixture generator.  Produces empty / one /
    three-pair maps using deterministic keys and values so the
    encoded bytes are reproducible across runs.

    The chosen `(key, value)` pairs avoid clashing with any
    invariant the inner balance map enforces (no zero amounts:
    every `Amount` is positive, exercising the "kept after
    `setBalance`" path).  Sub-states that key on `ActorId =
    UInt64` (the dominant case) use this fixture verbatim; sub-
    states keyed on other types (`ResourceId`, `WithdrawalId`,
    `DepositId`) ship a thin per-type adaptor in the same shape
    (added when the per-sub-state test bundle lands). -/
def genTreeMap : FixtureSize → BalanceMap
  | .empty     => (∅ : BalanceMap)
  | .singleton => (∅ : BalanceMap).insert (5 : ActorId) (100 : Amount)
  | .three     =>
      (((∅ : BalanceMap).insert (3 : ActorId) (10   : Amount)
                         ).insert (5 : ActorId) (100  : Amount)
                          ).insert (7 : ActorId) (1000 : Amount)

/-! ## Smoke checks for the shared fixtures

Four minimal sanity tests that exercise the `genTreeMap` shared
fixture before any EI.1+ tests use it.  These keep the suite
from being literally empty — `lake test` running zero cases
under this suite name would be a silent regression if a future
edit accidentally cleared `tests`.

Each is **fixture-only** (no per-theorem coverage); they verify
that the helper produces the documented shape and that
deterministic encoding holds on the chosen fixtures (a property
already shipped by `state_encode_deterministic`, but re-asserted
here on the EI fixtures to detect drift in the generator). -/

/-- `genTreeMap .empty` is the canonical empty map: no key is
    present.  Catches a future regression where someone "fills in"
    the empty case with a default-key trick. -/
def fixtureEmptyShape : TestCase := {
  name := "genTreeMap .empty is the empty map"
  body := do
    let bm := genTreeMap .empty
    -- The empty map has no entries; `[k]?` returns `none` for any k.
    assertEq (none : Option Amount) bm[(5 : ActorId)]? "lookup in empty"
    assertEq (none : Option Amount) bm[(0 : ActorId)]? "lookup at 0 in empty"
}

/-- `genTreeMap .singleton` has exactly the documented one pair.
    Catches a regression where the singleton shape grows extra
    entries. -/
def fixtureSingletonShape : TestCase := {
  name := "genTreeMap .singleton has exactly (5, 100)"
  body := do
    let bm := genTreeMap .singleton
    assertEq (some (100 : Amount)) bm[(5 : ActorId)]? "lookup at 5"
    assertEq (none : Option Amount) bm[(3 : ActorId)]? "lookup at 3"
    assertEq (none : Option Amount) bm[(7 : ActorId)]? "lookup at 7"
}

/-- `genTreeMap .three` has exactly three pairs at keys 3, 5, 7. -/
def fixtureThreeShape : TestCase := {
  name := "genTreeMap .three has (3,10), (5,100), (7,1000)"
  body := do
    let bm := genTreeMap .three
    assertEq (some (10   : Amount)) bm[(3 : ActorId)]? "lookup at 3"
    assertEq (some (100  : Amount)) bm[(5 : ActorId)]? "lookup at 5"
    assertEq (some (1000 : Amount)) bm[(7 : ActorId)]? "lookup at 7"
    assertEq (none : Option Amount) bm[(1 : ActorId)]? "lookup at 1"
}

/-- Encoding the shared `BalanceMap` fixtures is deterministic
    (`BalanceMap.encode` is referentially transparent).  Sanity
    check on the fixture; the per-sub-state injectivity proofs that
    EI.1 – EI.7 ship use `BalanceMap.encode` directly on these
    same fixtures. -/
def fixtureEncodeDeterministic : TestCase := {
  name := "genTreeMap fixtures encode deterministically"
  body := do
    for sz in [FixtureSize.empty, .singleton, .three] do
      let bm := genTreeMap sz
      let b1 := BalanceMap.encode bm
      let b2 := BalanceMap.encode bm
      assert (b1 == b2) s!"BalanceMap.encode non-deterministic at size {repr sz}"
}

/-! ## EI.1 — Helper / atomic-injectivity foundation

The tests below cover the EI.1 sub-units shipped by Workstream EI:

  * EI.1.b — `Encodable_via_decode_inj` + `_append` variant
  * EI.1.c — `cborHeadEncode_injective`
  * EI.1.d — `encodeAsBytes_*_injective_of_encode_*_injective` (Eq + Equiv)
  * EI.1.e — `encodeSortedPairs_injective`
  * EI.1.f — `uIntN_encode_injective` quartet
  * EI.1.g — Project-wrapper injectivity (ActorId, ResourceId, Amount,
              Nonce, DepositId, WithdrawalId, PublicKey)
  * EI.1.h — `list_encode_injective` / `option_encode_injective`
  * EI.1.i — `HasInjective` ergonomic class

Each lemma gets a term-level API-stability test (catches signature
drift at elaboration time, before the `IO Unit` body runs) and a
value-level contrapositive test (catches semantic regressions at
runtime by checking that distinct inputs produce distinct
encodings). -/

/-! ### EI.1.b — `Encodable_via_decode_inj` API stability -/

/-- Term-level API stability for the `Encodable_via_decode_inj`
    polymorphic helper (empty-suffix form). -/
def test_encodable_via_decode_inj_api : TestCase := {
  name := "Encodable_via_decode_inj API stability"
  body := do
    let _proof : ∀ {T : Type} [Encodable T],
        (∀ (v : T), Encodable.decode (T := T) (Encodable.encode v) = .ok (v, [])) →
        ∀ {v₁ v₂ : T},
          Encodable.encode v₁ = Encodable.encode v₂ → v₁ = v₂ :=
      @Encodable.Encodable_via_decode_inj
    pure ()
}

/-- Term-level API stability for the residual-suffix variant. -/
def test_encodable_via_decode_inj_append_api : TestCase := {
  name := "Encodable_via_decode_inj_append API stability"
  body := do
    let _proof : ∀ {T : Type} [Encodable T],
        (∀ (v : T) (rest : Stream),
          Encodable.decode (T := T) (Encodable.encode v ++ rest) = .ok (v, rest)) →
        ∀ {v₁ v₂ : T},
          Encodable.encode v₁ = Encodable.encode v₂ → v₁ = v₂ :=
      @Encodable.Encodable_via_decode_inj_append
    pure ()
}

/-! ### EI.1.c — `cborHeadEncode_injective` -/

/-- Term-level API stability for `cborHeadEncode_injective`. -/
def test_cborHeadEncode_injective_api : TestCase := {
  name := "cborHeadEncode_injective API stability"
  body := do
    let _proof : ∀ {major₁ major₂ : UInt8} {n₁ n₂ : Nat},
        n₁ < 256 ^ 8 → n₂ < 256 ^ 8 →
        cborHeadEncode major₁ n₁ = cborHeadEncode major₂ n₂ →
        major₁ = major₂ ∧ n₁ = n₂ :=
      @cborHeadEncode_injective
    pure ()
}

/-- Value-level (contrapositive): two `cborHeadEncode` invocations with
    differing major tags produce differing bytes. -/
def test_cborHeadEncode_distinguishes_major : TestCase := {
  name := "cborHeadEncode distinguishes distinct major tags"
  body := do
    let e1 := cborHeadEncode cbeTagUint 0
    let e2 := cborHeadEncode cbeTagBytes 0
    assert (e1 != e2) "cborHeadEncode collided on different major tags"
}

/-- Value-level (contrapositive): two `cborHeadEncode` invocations with
    differing payloads (both `< 2^64`) produce differing bytes. -/
def test_cborHeadEncode_distinguishes_payload : TestCase := {
  name := "cborHeadEncode distinguishes distinct payloads"
  body := do
    let e1 := cborHeadEncode cbeTagUint 0
    let e2 := cborHeadEncode cbeTagUint 1
    assert (e1 != e2) "cborHeadEncode collided on payloads 0 vs 1"
    let e3 := cborHeadEncode cbeTagUint 256
    assert (e1 != e3) "cborHeadEncode collided on payloads 0 vs 256"
    let e4 := cborHeadEncode cbeTagUint 65535
    assert (e3 != e4) "cborHeadEncode collided on payloads 256 vs 65535"
}

/-! ### EI.1.d — `encodeAsBytes` framing injectivity -/

/-- Term-level API stability for the `Eq`-flavoured framing helper. -/
def test_encodeAsBytes_eq_injective_api : TestCase := {
  name := "encodeAsBytes_eq_injective_of_encode_eq_injective API stability"
  body := do
    let _proof : ∀ {Inner : Type} (encode : Inner → Stream),
        (∀ {x y : Inner}, encode x = encode y → x = y) →
        ∀ {x y : Inner},
          ByteArray.mk (encode x).toArray = ByteArray.mk (encode y).toArray →
          x = y :=
      @encodeAsBytes_eq_injective_of_encode_eq_injective
    pure ()
}

/-- Term-level API stability for the `Equiv`-flavoured framing helper. -/
def test_encodeAsBytes_equiv_injective_api : TestCase := {
  name := "encodeAsBytes_equiv_injective_of_encode_equiv_injective API stability"
  body := do
    let _proof : ∀ {α β : Type} {cmp : α → α → Ordering}
        (encode : Std.TreeMap α β cmp → Stream),
        (∀ {m₁ m₂ : Std.TreeMap α β cmp}, encode m₁ = encode m₂ → m₁.Equiv m₂) →
        ∀ {m₁ m₂ : Std.TreeMap α β cmp},
          ByteArray.mk (encode m₁).toArray = ByteArray.mk (encode m₂).toArray →
          m₁.Equiv m₂ :=
      @encodeAsBytes_equiv_injective_of_encode_equiv_injective
    pure ()
}

/-- Value-level (contrapositive): the framing wrapper preserves
    byte distinction.  Uses `BalanceMap.encode`-shaped bytes since
    that's the actual call site. -/
def test_encodeAsBytes_distinguishes : TestCase := {
  name := "encodeAsBytes-style framing distinguishes distinct inputs"
  body := do
    -- Construct two distinct streams; their framed ByteArrays must differ.
    let s1 : Stream := [0, 0, 0]
    let s2 : Stream := [0, 0, 1]
    let b1 : ByteArray := ByteArray.mk s1.toArray
    let b2 : ByteArray := ByteArray.mk s2.toArray
    assert (b1 != b2) "framing collided on distinct streams"
}

/-! ### EI.1.e — `encodeSortedPairs_injective` -/

/-- Term-level API stability for `encodeSortedPairs_injective`. -/
def test_encodeSortedPairs_injective_api : TestCase := {
  name := "encodeSortedPairs_injective API stability"
  body := do
    let _proof : ∀ {K V : Type} [Encodable K] [Encodable V],
        ElemRoundtrip K → ElemRoundtrip V →
        ∀ (pairs₁ pairs₂ : List (K × V)),
          pairs₁.length < 256 ^ 8 → pairs₂.length < 256 ^ 8 →
          encodeSortedPairs pairs₁ = encodeSortedPairs pairs₂ →
          pairs₁ = pairs₂ :=
      fun {_ _ _ _} hK hV p₁ p₂ h₁ h₂ h =>
        encodeSortedPairs_injective hK hV p₁ p₂ h₁ h₂ h
    pure ()
}

/-- Value-level: `encodeSortedPairs` is deterministic on the empty
    pair list (sanity smoke check before the contrapositive tests). -/
def test_encodeSortedPairs_empty_deterministic : TestCase := {
  name := "encodeSortedPairs empty list is deterministic"
  body := do
    let pairs : List (Nat × Nat) := []
    let e1 := encodeSortedPairs pairs
    let e2 := encodeSortedPairs pairs
    assertEq e1 e2 "encodeSortedPairs not deterministic on []"
}

/-- Value-level (contrapositive): two pair lists differing on a value
    produce differing encoded byte streams.  This is the test the
    `encodeSortedPairs_injective` theorem mechanises. -/
def test_encodeSortedPairs_distinguishes_value : TestCase := {
  name := "encodeSortedPairs distinguishes pair lists with distinct values"
  body := do
    let pairs1 : List (Nat × Nat) := [(1, 10)]
    let pairs2 : List (Nat × Nat) := [(1, 20)]
    let e1 := encodeSortedPairs pairs1
    let e2 := encodeSortedPairs pairs2
    assert (e1 != e2) "encodeSortedPairs collided on distinct values"
}

/-- Value-level (contrapositive): two pair lists differing on a key
    produce differing encoded byte streams. -/
def test_encodeSortedPairs_distinguishes_key : TestCase := {
  name := "encodeSortedPairs distinguishes pair lists with distinct keys"
  body := do
    let pairs1 : List (Nat × Nat) := [(1, 10)]
    let pairs2 : List (Nat × Nat) := [(2, 10)]
    let e1 := encodeSortedPairs pairs1
    let e2 := encodeSortedPairs pairs2
    assert (e1 != e2) "encodeSortedPairs collided on distinct keys"
}

/-- Value-level (contrapositive): two pair lists of differing length
    produce differing encoded byte streams (the CBE head's pair-count
    byte differs). -/
def test_encodeSortedPairs_distinguishes_length : TestCase := {
  name := "encodeSortedPairs distinguishes pair lists of distinct length"
  body := do
    let pairs1 : List (Nat × Nat) := [(1, 10)]
    let pairs2 : List (Nat × Nat) := [(1, 10), (2, 20)]
    let e1 := encodeSortedPairs pairs1
    let e2 := encodeSortedPairs pairs2
    assert (e1 != e2) "encodeSortedPairs collided on distinct lengths"
}

/-- Term-level API stability for the bounded variant
    `encodeSortedPairs_injective_bounded`.  This is the variant EI.2+
    per-sub-state proofs actually use, because their inner pair
    lists key on `Nat` (via `.toNat`) and `Nat`'s round-trip is
    conditional on `< 2^64`. -/
def test_encodeSortedPairs_injective_bounded_api : TestCase := {
  name := "encodeSortedPairs_injective_bounded API stability"
  body := do
    let _proof : ∀ {K V : Type} [Encodable K] [Encodable V]
        (pairs₁ pairs₂ : List (K × V)),
        pairs₁.length < 256 ^ 8 → pairs₂.length < 256 ^ 8 →
        (∀ p ∈ pairs₁, ∀ (rest : Stream),
          Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) =
            .ok (p.1, rest)) →
        (∀ p ∈ pairs₁, ∀ (rest : Stream),
          Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) =
            .ok (p.2, rest)) →
        (∀ p ∈ pairs₂, ∀ (rest : Stream),
          Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) =
            .ok (p.1, rest)) →
        (∀ p ∈ pairs₂, ∀ (rest : Stream),
          Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) =
            .ok (p.2, rest)) →
        encodeSortedPairs pairs₁ = encodeSortedPairs pairs₂ →
        pairs₁ = pairs₂ :=
      @encodeSortedPairs_injective_bounded
    pure ()
}

/-- Value-level: verify `encodeSortedPairs_injective_bounded` is
    actually applicable on the per-sub-state shape EI.2+ uses
    (i.e. `List (Nat × Nat)` with bounded entries).  Witnesses
    that the lemma can be invoked end-to-end on a concrete bounded
    pair list pair. -/
def test_encodeSortedPairs_injective_bounded_applicable : TestCase := {
  name := "encodeSortedPairs_injective_bounded applies to bounded Nat pair lists"
  body := do
    let _proof :
      ∀ (pairs₁ pairs₂ : List (Nat × Nat)),
        pairs₁.length < 256 ^ 8 → pairs₂.length < 256 ^ 8 →
        (∀ p ∈ pairs₁, p.1 < 256 ^ 8) → (∀ p ∈ pairs₁, p.2 < 256 ^ 8) →
        (∀ p ∈ pairs₂, p.1 < 256 ^ 8) → (∀ p ∈ pairs₂, p.2 < 256 ^ 8) →
        encodeSortedPairs pairs₁ = encodeSortedPairs pairs₂ →
        pairs₁ = pairs₂ :=
      fun pairs₁ pairs₂ h_len₁ h_len₂ hK₁ hV₁ hK₂ hV₂ h =>
        encodeSortedPairs_injective_bounded pairs₁ pairs₂ h_len₁ h_len₂
          (fun p hp_mem rest => nat_roundtrip p.1 rest (hK₁ p hp_mem))
          (fun p hp_mem rest => nat_roundtrip p.2 rest (hV₁ p hp_mem))
          (fun p hp_mem rest => nat_roundtrip p.1 rest (hK₂ p hp_mem))
          (fun p hp_mem rest => nat_roundtrip p.2 rest (hV₂ p hp_mem))
          h
    pure ()
}

/-! ### EI.1.f — UIntN injectivity quartet -/

/-- Term-level API stability for `uInt8_encode_injective`. -/
def test_uInt8_encode_injective_api : TestCase := {
  name := "uInt8_encode_injective API stability"
  body := do
    let _proof : Function.Injective (Encodable.encode : UInt8 → Stream) :=
      uInt8_encode_injective
    pure ()
}

/-- Term-level API stability for `uInt16_encode_injective`. -/
def test_uInt16_encode_injective_api : TestCase := {
  name := "uInt16_encode_injective API stability"
  body := do
    let _proof : Function.Injective (Encodable.encode : UInt16 → Stream) :=
      uInt16_encode_injective
    pure ()
}

/-- Term-level API stability for `uInt32_encode_injective`. -/
def test_uInt32_encode_injective_api : TestCase := {
  name := "uInt32_encode_injective API stability"
  body := do
    let _proof : Function.Injective (Encodable.encode : UInt32 → Stream) :=
      uInt32_encode_injective
    pure ()
}

/-- Term-level API stability for `uInt64_encode_injective`. -/
def test_uInt64_encode_injective_api : TestCase := {
  name := "uInt64_encode_injective API stability"
  body := do
    let _proof : Function.Injective (Encodable.encode : UInt64 → Stream) :=
      uInt64_encode_injective
    pure ()
}

/-- Value-level: each UIntN encoder produces distinct bytes for
    distinct inputs.  Smokes the UInt8 / UInt16 / UInt32 / UInt64
    encoders at small boundary values. -/
def test_uIntN_distinguishes : TestCase := {
  name := "UIntN encoders distinguish distinct inputs"
  body := do
    assert (Encodable.encode (T := UInt8)  0 != Encodable.encode (T := UInt8)  1)
      "UInt8 encoder collided on 0 vs 1"
    assert (Encodable.encode (T := UInt8)  0 != Encodable.encode (T := UInt8)  255)
      "UInt8 encoder collided on 0 vs 255"
    assert (Encodable.encode (T := UInt16) 0 != Encodable.encode (T := UInt16) 1)
      "UInt16 encoder collided on 0 vs 1"
    assert (Encodable.encode (T := UInt16) 256 != Encodable.encode (T := UInt16) 257)
      "UInt16 encoder collided on 256 vs 257"
    assert (Encodable.encode (T := UInt32) 0 != Encodable.encode (T := UInt32) 1)
      "UInt32 encoder collided on 0 vs 1"
    assert (Encodable.encode (T := UInt64) 0 != Encodable.encode (T := UInt64) 1)
      "UInt64 encoder collided on 0 vs 1"
    assert (Encodable.encode (T := UInt64) 0 !=
            Encodable.encode (T := UInt64) 18446744073709551615)
      "UInt64 encoder collided on 0 vs UInt64.max"
}

/-! ### EI.1.g — Project-wrapper injectivity -/

/-- Term-level API stability for the seven project-wrapper
    injectivity lemmas (`ActorId`, `ResourceId`, `Amount`, `Nonce`,
    `DepositId`, `WithdrawalId`, `PublicKey`). -/
def test_project_wrapper_injectivity_api : TestCase := {
  name := "project-wrapper injectivity API stability"
  body := do
    let _p1 : Function.Injective (Encodable.encode : ActorId → Stream) :=
      actorId_encode_injective
    let _p2 : Function.Injective (Encodable.encode : ResourceId → Stream) :=
      resourceId_encode_injective
    let _p3 : ∀ (a₁ a₂ : Amount),
        a₁ < 256 ^ 8 → a₂ < 256 ^ 8 →
        Encodable.encode (T := Amount) a₁ = Encodable.encode (T := Amount) a₂ →
        a₁ = a₂ :=
      fun a₁ a₂ h₁ h₂ h => amount_encode_injective a₁ a₂ h₁ h₂ h
    let _p4 : ∀ (n₁ n₂ : Nonce),
        n₁ < 256 ^ 8 → n₂ < 256 ^ 8 →
        Encodable.encode (T := Nonce) n₁ = Encodable.encode (T := Nonce) n₂ →
        n₁ = n₂ :=
      fun n₁ n₂ h₁ h₂ h => nonce_encode_injective n₁ n₂ h₁ h₂ h
    let _p5 : ∀ (d₁ d₂ : Bridge.DepositId),
        d₁ < 256 ^ 8 → d₂ < 256 ^ 8 →
        Encodable.encode (T := Bridge.DepositId) d₁ =
        Encodable.encode (T := Bridge.DepositId) d₂ → d₁ = d₂ :=
      fun d₁ d₂ h₁ h₂ h => depositId_encode_injective d₁ d₂ h₁ h₂ h
    let _p6 : ∀ (w₁ w₂ : Bridge.WithdrawalId),
        w₁ < 256 ^ 8 → w₂ < 256 ^ 8 →
        Encodable.encode (T := Bridge.WithdrawalId) w₁ =
        Encodable.encode (T := Bridge.WithdrawalId) w₂ → w₁ = w₂ :=
      fun w₁ w₂ h₁ h₂ h => withdrawalId_encode_injective w₁ w₂ h₁ h₂ h
    let _p7 : ∀ (p₁ p₂ : PublicKey),
        p₁.size < 256 ^ 8 → p₂.size < 256 ^ 8 →
        Encodable.encode (T := PublicKey) p₁ =
        Encodable.encode (T := PublicKey) p₂ → p₁ = p₂ :=
      fun p₁ p₂ h₁ h₂ h => publicKey_encode_injective p₁ p₂ h₁ h₂ h
    pure ()
}

/-- Value-level: each project wrapper's encoder distinguishes
    distinct inputs (sanity smoke check). -/
def test_project_wrapper_distinguishes : TestCase := {
  name := "project-wrapper encoders distinguish distinct inputs"
  body := do
    -- ActorId / ResourceId (UInt64).
    assert (Encodable.encode (T := ActorId)    0 !=
            Encodable.encode (T := ActorId)    1)
      "ActorId encoder collided"
    assert (Encodable.encode (T := ResourceId) 0 !=
            Encodable.encode (T := ResourceId) 1)
      "ResourceId encoder collided"
    -- Amount / Nonce / DepositId / WithdrawalId (Nat).
    assert (Encodable.encode (T := Amount)     0 !=
            Encodable.encode (T := Amount)     1)
      "Amount encoder collided"
    assert (Encodable.encode (T := Nonce)      0 !=
            Encodable.encode (T := Nonce)      1)
      "Nonce encoder collided"
    assert (Encodable.encode (T := Bridge.DepositId)    0 !=
            Encodable.encode (T := Bridge.DepositId)    1)
      "DepositId encoder collided"
    assert (Encodable.encode (T := Bridge.WithdrawalId) 0 !=
            Encodable.encode (T := Bridge.WithdrawalId) 1)
      "WithdrawalId encoder collided"
    -- PublicKey (ByteArray).
    let k1 : PublicKey := ByteArray.mk #[0xAA, 0xBB]
    let k2 : PublicKey := ByteArray.mk #[0xAA, 0xCC]
    assert (Encodable.encode (T := PublicKey) k1 !=
            Encodable.encode (T := PublicKey) k2)
      "PublicKey encoder collided"
}

/-! ### EI.1.h — `List α` / `Option α` injectivity -/

/-- Term-level API stability for `list_encode_injective`. -/
def test_list_encode_injective_api : TestCase := {
  name := "list_encode_injective API stability"
  body := do
    let _proof : ∀ {α : Type} [Encodable α],
        ElemRoundtrip α →
        ∀ {xs₁ xs₂ : List α},
          xs₁.length < 256 ^ 8 → xs₂.length < 256 ^ 8 →
          Encodable.encode (T := List α) xs₁ = Encodable.encode (T := List α) xs₂ →
          xs₁ = xs₂ :=
      @list_encode_injective
    pure ()
}

/-- Term-level API stability for `option_encode_injective`. -/
def test_option_encode_injective_api : TestCase := {
  name := "option_encode_injective API stability"
  body := do
    let _proof : ∀ {α : Type} [Encodable α],
        ElemRoundtrip α →
        ∀ {o₁ o₂ : Option α},
          Encodable.encode (T := Option α) o₁ =
          Encodable.encode (T := Option α) o₂ → o₁ = o₂ :=
      @option_encode_injective
    pure ()
}

/-- Value-level (contrapositive): list encoder distinguishes lists
    that differ on at least one element. -/
def test_list_encode_distinguishes : TestCase := {
  name := "list_encode distinguishes lists with distinct elements"
  body := do
    let xs1 : List Bool := [true]
    let xs2 : List Bool := [false]
    assert (Encodable.encode (T := List Bool) xs1 !=
            Encodable.encode (T := List Bool) xs2)
      "list encoder collided on [true] vs [false]"
    let ys1 : List Bool := [true, false]
    let ys2 : List Bool := [true, true]
    assert (Encodable.encode (T := List Bool) ys1 !=
            Encodable.encode (T := List Bool) ys2)
      "list encoder collided on [true,false] vs [true,true]"
    let zs1 : List Bool := [true]
    let zs2 : List Bool := [true, true]
    assert (Encodable.encode (T := List Bool) zs1 !=
            Encodable.encode (T := List Bool) zs2)
      "list encoder collided on distinct lengths"
}

/-- Value-level (contrapositive): option encoder distinguishes
    `none` from `some _` and different `some _` payloads. -/
def test_option_encode_distinguishes : TestCase := {
  name := "option_encode distinguishes distinct Options"
  body := do
    let o_none : Option Bool := none
    let o_t    : Option Bool := some true
    let o_f    : Option Bool := some false
    assert (Encodable.encode (T := Option Bool) o_none !=
            Encodable.encode (T := Option Bool) o_t)
      "option encoder collided on none vs some true"
    assert (Encodable.encode (T := Option Bool) o_t !=
            Encodable.encode (T := Option Bool) o_f)
      "option encoder collided on some true vs some false"
}

/-! ### EI.1.i — `HasInjective` class instances -/

/-- Term-level API stability + instance-search smoke check for the
    `HasInjective` ergonomic class.  Verifies that the instances
    shipped by EI.1.i resolve via instance search for every
    unconditional atomic carrier. -/
def test_HasInjective_instances : TestCase := {
  name := "HasInjective instance search"
  body := do
    let _i1 : Encodable.HasInjective Bool        := inferInstance
    let _i2 : Encodable.HasInjective BoundedNat  := inferInstance
    let _i3 : Encodable.HasInjective UInt8       := inferInstance
    let _i4 : Encodable.HasInjective UInt16      := inferInstance
    let _i5 : Encodable.HasInjective UInt32      := inferInstance
    let _i6 : Encodable.HasInjective UInt64      := inferInstance
    -- `ActorId` / `ResourceId` resolve via the `UInt64` instance
    -- (since they are `abbrev`-aliased).
    let _i7 : Encodable.HasInjective ActorId     := inferInstance
    let _i8 : Encodable.HasInjective ResourceId  := inferInstance
    pure ()
}

/-! ## Suite registration

`tests` accumulates all EI sub-unit test cases.  The four
fixture-smoke checks from EI.0.c stay at the head as shared-machinery
regressions; EI.1's per-lemma coverage follows.  EI.2 onwards will
each append their per-sub-state tests when those PRs land. -/

/-- Workstream EI's test cases.  Includes the four EI.0.c fixture
    smoke checks and the EI.1 per-lemma coverage. -/
def tests : List TestCase :=
  [ -- EI.0.c — Shared-fixture smoke checks.
    fixtureEmptyShape
  , fixtureSingletonShape
  , fixtureThreeShape
  , fixtureEncodeDeterministic
    -- EI.1.b — Encodable_via_decode_inj.
  , test_encodable_via_decode_inj_api
  , test_encodable_via_decode_inj_append_api
    -- EI.1.c — cborHeadEncode_injective.
  , test_cborHeadEncode_injective_api
  , test_cborHeadEncode_distinguishes_major
  , test_cborHeadEncode_distinguishes_payload
    -- EI.1.d — encodeAsBytes framing injectivity.
  , test_encodeAsBytes_eq_injective_api
  , test_encodeAsBytes_equiv_injective_api
  , test_encodeAsBytes_distinguishes
    -- EI.1.e — encodeSortedPairs_injective + _bounded variant.
  , test_encodeSortedPairs_injective_api
  , test_encodeSortedPairs_injective_bounded_api
  , test_encodeSortedPairs_injective_bounded_applicable
  , test_encodeSortedPairs_empty_deterministic
  , test_encodeSortedPairs_distinguishes_value
  , test_encodeSortedPairs_distinguishes_key
  , test_encodeSortedPairs_distinguishes_length
    -- EI.1.f — UIntN injectivity quartet.
  , test_uInt8_encode_injective_api
  , test_uInt16_encode_injective_api
  , test_uInt32_encode_injective_api
  , test_uInt64_encode_injective_api
  , test_uIntN_distinguishes
    -- EI.1.g — Project-wrapper injectivity.
  , test_project_wrapper_injectivity_api
  , test_project_wrapper_distinguishes
    -- EI.1.h — List / Option injectivity.
  , test_list_encode_injective_api
  , test_option_encode_injective_api
  , test_list_encode_distinguishes
  , test_option_encode_distinguishes
    -- EI.1.i — HasInjective class.
  , test_HasInjective_instances
  ]

end InjectivityTests
end LegalKernel.Test.Encoding
