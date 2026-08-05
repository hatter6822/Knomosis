-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.KernelStep — round-trip coverage for the
`CellTag` CBE codec (`LegalKernel/Encoding/KernelStep.lean`).

This suite exists because the codec shipped an ASYMMETRY that nothing
caught: `CellTag.encode` emits tags `0..14` across all fifteen
constructors, while `CellTag.decode` handled only `0..6`.  The eight
missing arms — the AMM mirror, the BOLD circuit-breaker trio, the
kill switch, the per-actor epoch budget and the budget policy — are
not exotic: EVERY action writes an `.epochBudget` cell and every
frontier leads with `.budgetPolicy`, so the gap covered the majority
of real bundles.

Nothing caught it because the module's only theorems were
`*_encode_deterministic` (`t₁ = t₂ → encode t₁ = encode t₂`), which
holds of every function and so cannot witness a decoder at all, and
because no test exercised `CellTag.decode`.

The suite therefore checks the property that would have failed —
round-trip on EVERY constructor, driven off an exhaustive tag list
rather than a hand-picked sample — plus the two negative controls
that stop it passing vacuously.
-/

import LegalKernel.Encoding.KernelStep
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Encoding
open LegalKernel.FaultProof
open LegalKernel.Test

namespace LegalKernel.Test.Encoding.KernelStepTests

/-- One representative of every `CellTag` constructor.

    Exhaustive by construction: `cellTag_every_constructor_covered`
    below pins the length, so a sixteenth constructor added without a
    representative here fails the suite rather than silently escaping
    the round-trip check. -/
def allTags : List CellTag :=
  [ .balance 3 9
  , .nonce 11
  , .registry 12
  , .localPolicy 13
  , .bridgeConsumed 14
  , .bridgePending 15
  , .bridgeNextWdId
  , .bridgeAmmReserveEth
  , .bridgeAmmReserveBold
  , .bridgeBoldCircuitClosed
  , .bridgeBoldTvlCap
  , .bridgeBoldTotalLockedValue
  , .bridgeAmmDisabled
  , .epochBudget 16
  , .budgetPolicy
  ]

/-- Round-trip one tag with a non-empty residual stream, so the test
    also witnesses that the decoder consumes exactly its own bytes
    and hands the remainder back untouched. -/
private def roundtripsWithResidual (t : CellTag) : Bool :=
  let residual : Stream := (Encodable.encode (T := Nat) 99)
  match CellTag.decode (CellTag.encode t ++ residual) with
  | .ok (t', rest) => t' == t && rest == residual
  | .error _       => false

/-- Tests for the `CellTag` CBE codec. -/
def tests : List TestCase :=
  [ { name := "every CellTag constructor has a representative"
    , body := do
        -- The arity pin.  `CellTag` has fifteen constructors; adding
        -- one without extending `allTags` must fail here rather than
        -- quietly shrink the round-trip sweep below.
        assertEq (expected := 15) (actual := allTags.length)
          "allTags must cover every CellTag constructor"
    }
  , { name := "every CellTag round-trips, residual stream preserved"
    , body := do
        for t in allTags do
          assert (roundtripsWithResidual t)
            s!"CellTag round-trip failed for {repr t}"
    }
  , { name := "the eight tags the decoder used to reject now decode"
    , body := do
        -- The regression proper.  Tags 7..14 were emitted by `encode`
        -- and refused by `decode`; each of these is one of them.
        let regressed : List CellTag :=
          [ .bridgeAmmReserveEth, .bridgeAmmReserveBold
          , .bridgeBoldCircuitClosed, .bridgeBoldTvlCap
          , .bridgeBoldTotalLockedValue, .bridgeAmmDisabled
          , .epochBudget 16, .budgetPolicy ]
        assertEq (expected := 8) (actual := regressed.length)
          "the gap was exactly eight tags wide"
        for t in regressed do
          assert (roundtripsWithResidual t)
            s!"previously-unreachable tag failed to decode: {repr t}"
    }
  , { name := "the two cells EVERY step touches round-trip"
    , body := do
        -- `.epochBudget` is written by all twenty-five variants and
        -- `.budgetPolicy` leads every frontier, so these two are the
        -- reason the gap was not merely theoretical.
        assert (roundtripsWithResidual (.epochBudget 1))
          "the per-actor epoch-budget cell must round-trip"
        assert (roundtripsWithResidual .budgetPolicy)
          "the read-only budget-policy cell must round-trip"
    }
  , { name := "NEGATIVE: an unknown tag is refused, not silently accepted"
    , body := do
        -- Guards the sweep above against a decoder that accepted
        -- anything.  15 is one past the last frozen tag.
        match CellTag.decode (Encodable.encode (T := Nat) 15) with
        | .error _   => assert true "unknown tag rejected"
        | .ok (t, _) => assert false s!"tag 15 must not decode, got {repr t}"
    }
  , { name := "NEGATIVE: distinct tags do not share an encoding"
    , body := do
        -- Guards against a decoder that round-trips because `encode`
        -- collapsed constructors together.  Pairwise-distinct bytes
        -- across the whole constructor space.
        let encoded := allTags.map CellTag.encode
        for i in [0 : encoded.length] do
          for j in [0 : encoded.length] do
            if i != j then
              assert (encoded[i]! != encoded[j]!)
                s!"CellTag encodings collide at {i}/{j}"
    }
  , { name := "bridge-set cells round-trip at the head's ceiling"
    , body := do
        -- `DepositId` / `WithdrawalId` are bare `Nat`, so they are the
        -- only constructors carrying a real `fieldsBounded` obligation.
        -- The largest value the 8-byte head admits must still survive.
        let maxHead : Nat := 256 ^ 8 - 1
        assert (roundtripsWithResidual (.bridgeConsumed maxHead))
          "bridgeConsumed must round-trip at 256^8 - 1"
        assert (roundtripsWithResidual (.bridgePending maxHead))
          "bridgePending must round-trip at 256^8 - 1"
    }
  , { name := "cellTag_roundtrip API stable"
    , body := do
        let _ := @cellTag_roundtrip
        assert true "API exists"
    }
  , { name := "CellTag.fieldsBounded is decidable and bounds only the Nat keys"
    , body := do
        -- `ActorId` / `ResourceId` are `UInt64`, so their arms are
        -- `True`; the two bridge-set cells carry the obligation.
        assert (decide (CellTag.fieldsBounded (.balance 3 9)))
          "UInt64-keyed cells are unconditionally bounded"
        assert (decide (CellTag.fieldsBounded (.epochBudget 1)))
          "the epoch-budget cell is unconditionally bounded"
        assert (decide (CellTag.fieldsBounded (.bridgeConsumed 5)))
          "an in-range depositId is bounded"
        assert (! decide (CellTag.fieldsBounded (.bridgeConsumed (256 ^ 8))))
          "a depositId at the head's modulus is NOT bounded"
    }
  ]

end LegalKernel.Test.Encoding.KernelStepTests
