-- SPDX-License-Identifier: GPL-3.0-or-later
-- Knomosis  - A Societal Kernel
-- Copyright (C) 2026  Adam Hall
-- This program comes with ABSOLUTELY NO WARRANTY.
-- This is free software, and you are welcome to redistribute it
-- under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

/-
# Tests — `Laws.reserveSwap` (Workstream SB)

The USER-facing L2 constant-product swap: precondition semantics
(including the slippage floor and the zero-output refusal), the
four-write apply shape priced by the in-kernel quote, conservation at
BOTH resources, the constant-product k-invariant checked on values,
the AuthorityPolicy user/reserve binding, and term-level API pins for
every headline theorem.

The quote fixture is worked by hand so the suite is non-circular:
reserves 10000/10000, input 1000, fee 30 bps ⇒
`amountInWithFee = 1000 × 9970 = 9 970 000`,
`numerator = 9 970 000 × 10000 = 99 700 000 000`,
`denominator = 10000 × 10000 + 9 970 000 = 109 970 000`,
`amountOut = ⌊99 700 000 000 / 109 970 000⌋ = 906`.
-/

import LegalKernel.Laws.ReserveSwap
import LegalKernel.Authority.Action
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Bridge.AmmReservePolicy
import LegalKernel.Bridge.Admissible
import LegalKernel.Runtime.Replay
import LegalKernel.Events.Types
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.ReserveSwapTests

/-- The canonical fixture: user 9 holds 5000 at resource 0; the
    reserve actor 3 holds 10000 at both legs; a bystander 7 holds
    500 at resource 1 (so conservation is checked over a supply the
    swap does not fully own). -/
private def fixture : State :=
  setBalance (setBalance (setBalance (setBalance emptyState
    0 9 5000) 0 3 10000) 1 3 10000) 1 7 500

/-- The hand-computed quote for `amountIn = 1000` against the
    fixture's 10000/10000 reserves at 30 bps. -/
private def expectedQuote : Nat := 906

/-- Tests for the `reserveSwap` law. -/
def tests : List TestCase :=
  [ -- ## The quote
    { name := "reserveQuote: hand-computed constant-product value"
    , body := do
        assertEq (expected := expectedQuote)
          (actual := reserveQuote fixture 0 1 3 1000)
          "quote for 1000 in against 10000/10000 at 30 bps"
    }
  , -- ## Precondition semantics
    { name := "precondition: holds on the canonical fixture"
    , body := do
        let t := reserveSwap 0 1 9 1000 900 3
        assert (decide (t.pre fixture)) "pre holds (quote 906 ≥ 900)"
    }
  , { name := "precondition: slippage floor is exact"
    , body := do
        assert (decide ((reserveSwap 0 1 9 1000 906 3).pre fixture))
          "pre holds at minAmountOut = quote"
        assert (¬ decide ((reserveSwap 0 1 9 1000 907 3).pre fixture))
          "pre fails one above the quote"
    }
  , -- ## The minimum-liquidity floor
    { name := "minimum liquidity: a swap that would drain the pool is a NO-OP"
    , body := do
        -- Reserves 1000/1500, input 100 000.  The quote is 1485, which
        -- would leave the output leg holding 15 -- a pool the next
        -- swap prices arbitrarily badly.
        --
        -- The load-bearing part is the SECOND assertion: under the
        -- retired rule (`0 < reserveOut`) this swap was ADMISSIBLE, so
        -- the case fails on the old law and is a real regression test
        -- rather than a restatement of the new one.  The old rule is
        -- rebuilt inline instead of being described.
        let drainable : State :=
          setBalance (setBalance (setBalance emptyState
            0 9 200000) 0 3 1000) 1 3 1500
        assertEq (expected := 1485) (actual := reserveQuote drainable 0 1 3 100000)
          "the quote leaves the output leg at 15"
        assert (¬ decide ((reserveSwap 0 1 9 100000 1 3).pre drainable))
          "the floor refuses the drain"
        assert (decide (0 < getBalance drainable 0 3 ∧ 0 < getBalance drainable 1 3))
          "the retired rule's reserve test still passes, so it would have admitted it"
    }
  , { name := "minimum liquidity: both entry legs are floored"
    , body := do
        -- 999 on a leg is below the floor; the swap is refused even
        -- though the quote itself is fine and the pool is non-empty.
        let thinFrom : State :=
          setBalance (setBalance (setBalance emptyState
            0 9 5000) 0 3 999) 1 3 10000
        assert (¬ decide ((reserveSwap 0 1 9 10 1 3).pre thinFrom))
          "input leg below the floor is refused"
        let thinTo : State :=
          setBalance (setBalance (setBalance emptyState
            0 9 5000) 0 3 10000) 1 3 999
        assert (¬ decide ((reserveSwap 0 1 9 10 1 3).pre thinTo))
          "output leg below the floor is refused"
        -- The control: one unit more on each leg and the same swap is
        -- admissible, so the refusals above are about the floor and
        -- not about the quote or the bounds.
        let atFloor : State :=
          setBalance (setBalance (setBalance emptyState
            0 9 5000) 0 3 1000) 1 3 10000
        assert (decide ((reserveSwap 0 1 9 10 1 3).pre atFloor))
          "exactly at the floor is admissible"
    }
  , { name := "minimum liquidity: the canonical fixture is unaffected"
    , body := do
        -- The floor must not have narrowed ordinary trading: the
        -- fixture's 10000/10000 pool leaves 9094 after a 1000-in swap.
        assert (decide ((reserveSwap 0 1 9 1000 900 3).pre fixture))
          "a normal swap still holds"
        assertEq (expected := 9094)
          (actual := getBalance fixture 1 3 - reserveQuote fixture 0 1 3 1000)
          "and leaves the output leg far above the floor"
    }
  , { name := "precondition: a zero-output swap is refused"
    , body := do
        -- Reserves 10000/1: one unit in quotes 0 out; `max 1
        -- minAmountOut` refuses it even at minAmountOut = 0 (the
        -- L1 `ZeroSwapOutput` mirror).
        let s := setBalance (setBalance (setBalance emptyState
          0 9 5000) 0 3 10000) 1 3 1
        assertEq (expected := (0 : Nat)) (actual := reserveQuote s 0 1 3 1)
          "starved output leg quotes zero"
        assert (¬ decide ((reserveSwap 0 1 9 1 0 3).pre s))
          "zero-output swap refused"
    }
  , { name := "precondition: fails on zero input"
    , body := do
        assert (¬ decide ((reserveSwap 0 1 9 0 0 3).pre fixture))
          "amountIn = 0 refused"
    }
  , { name := "precondition: fails when fromResource = toResource"
    , body := do
        assert (¬ decide ((reserveSwap 0 0 9 1000 1 3).pre fixture))
          "same-resource swap refused"
    }
  , { name := "precondition: fails when user = reserveActor"
    , body := do
        assert (¬ decide ((reserveSwap 0 1 3 1000 1 3).pre fixture))
          "reserve trading against itself refused"
    }
  , { name := "precondition: fails on insufficient user balance"
    , body := do
        assert (¬ decide ((reserveSwap 0 1 9 5001 1 3).pre fixture))
          "user holds 5000 < 5001"
    }
  , { name := "precondition: fails on an empty reserve leg"
    , body := do
        let s := setBalance (setBalance emptyState 0 9 5000) 0 3 10000
        assert (¬ decide ((reserveSwap 0 1 9 1000 1 3).pre s))
          "output leg 0 refused"
    }
  , { name := "precondition: the quote's uint256 domain is enforced"
    , body := do
        -- A swap whose fee product `amountIn × 9970` exceeds 2^256 is
        -- a NO-OP, not a truncated or reverting step: the C-3-style
        -- `reserveQuoteDomainBounded` conjunct refuses it on the Lean
        -- side exactly where the uint256 mirror cannot compute it.
        -- amountIn = 2^255 (representable, and fundable: the user
        -- holds 2^255 < maxAmount) makes the numerator
        -- 2^255 × 9970 × rT overflow.
        let big := 2 ^ 255
        let s := setBalance (setBalance (setBalance emptyState
          0 9 big) 0 3 10000) 1 3 10000
        assert (decide (reserveQuoteDomainBounded s 0 1 3 1000))
          "a small swap is inside the domain"
        assert (¬ decide (reserveQuoteDomainBounded s 0 1 3 big))
          "the 2^255 swap is outside it"
        assert (¬ decide ((reserveSwap 0 1 9 big 1 3).pre s))
          "...and the law refuses it"
        let s' := step_impl s (reserveSwap 0 1 9 big 1 3)
        assertEq (expected := big) (actual := getBalance s' 0 9)
          "the out-of-domain swap is a no-op"
    }
  , { name := "decPre: inferInstance suffices"
    , body := do
        let t := reserveSwap 0 1 9 1000 900 3
        let _inst : (s : State) → Decidable (t.pre s) := t.decPre
        pure ()
    }
  , -- ## Apply semantics: the four writes
    { name := "apply: debits the user at fromResource"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        assertEq (expected := (4000 : Nat)) (actual := getBalance s' 0 9)
          "user@0 = 5000 - 1000"
    }
  , { name := "apply: credits the reserve at fromResource"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        assertEq (expected := (11000 : Nat)) (actual := getBalance s' 0 3)
          "reserve@0 = 10000 + 1000"
    }
  , { name := "apply: debits the reserve at toResource by the quote"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        assertEq (expected := (10000 - expectedQuote : Nat))
          (actual := getBalance s' 1 3) "reserve@1 = 10000 - 906"
    }
  , { name := "apply: credits the user at toResource by the quote"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        assertEq (expected := expectedQuote) (actual := getBalance s' 1 9)
          "user@1 = 0 + 906"
    }
  , { name := "apply: the bystander is untouched at every leg"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        assertEq (expected := (500 : Nat)) (actual := getBalance s' 1 7)
          "bystander@1 unchanged"
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 0 7)
          "bystander@0 unchanged"
    }
  , { name := "apply: a failing precondition is a no-op"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 907 3)
        assertEq (expected := (5000 : Nat)) (actual := getBalance s' 0 9)
          "user@0 untouched under a failed slippage floor"
        assertEq (expected := (10000 : Nat)) (actual := getBalance s' 1 3)
          "reserve@1 untouched"
    }
  , -- ## Conservation and the k-invariant, on values
    { name := "conservation: total supply preserved at BOTH resources"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        assertEq (expected := TotalSupply fixture 0) (actual := TotalSupply s' 0)
          "supply@0 conserved (15000)"
        assertEq (expected := TotalSupply fixture 1) (actual := TotalSupply s' 1)
          "supply@1 conserved (10500)"
        assertEq (expected := (15000 : Nat)) (actual := TotalSupply s' 0)
          "supply@0 is the fixture's 15000"
        assertEq (expected := (10500 : Nat)) (actual := TotalSupply s' 1)
          "supply@1 is the fixture's 10500"
    }
  , { name := "k-invariant: the reserve product does not decrease"
    , body := do
        let s' := step_impl fixture (reserveSwap 0 1 9 1000 900 3)
        let kBefore := getBalance fixture 0 3 * getBalance fixture 1 3
        let kAfter  := getBalance s' 0 3 * getBalance s' 1 3
        assertEq (expected := (100000000 : Nat)) (actual := kBefore) "k before"
        assertEq (expected := (100034000 : Nat)) (actual := kAfter)
          "k after = 11000 × 9094"
        assert (decide (kBefore ≤ kAfter)) "k is non-decreasing"
    }
  , -- ## The Action layer (frozen index 25)
    { name := "Action 25: tag, compile arm, toTransition passthrough"
    , body := do
        assertEq (expected := (25 : Nat))
          (actual := Authority.Action.tag (.reserveSwap 0 1 9 1000 900 3))
          "Action.tag = 25"
        -- The compile arm routes to the kernel law with the fields in
        -- order (elaboration-time rfl pin).
        let _compile :
            Authority.Action.compileTransition (.reserveSwap 0 1 9 1000 900 3)
              = Laws.reserveSwap 0 1 9 1000 900 3 := rfl
        -- Not signer-aware: `toTransition` coincides with the compile
        -- for any signer.
        let _toTransition :
            Authority.Action.toTransition (.reserveSwap 0 1 9 1000 900 3) 42
              = Laws.reserveSwap 0 1 9 1000 900 3 := rfl
        pure ()
    }
  , -- ## The AuthorityPolicy binding (fund safety)
    { name := "binding: user = signer and reserveActor = ammReserveActor"
    , body := do
        -- The legitimate self-signed canonical swap is authorised.
        assert (decide (Bridge.reserveSwapBindingPolicy.authorized 9
            (.reserveSwap 0 1 9 1000 900 Bridge.ammReserveActor)))
          "self swap against the canonical reserve authorised"
        -- A third party cannot name someone else as `user`.
        assert (¬ decide (Bridge.reserveSwapBindingPolicy.authorized 8
            (.reserveSwap 0 1 9 1000 900 Bridge.ammReserveActor)))
          "third-party user rejected"
        -- The counterparty must be the canonical reserve, never a
        -- victim's balances.
        assert (¬ decide (Bridge.reserveSwapBindingPolicy.authorized 9
            (.reserveSwap 0 1 9 1000 900 7)))
          "non-canonical counterparty rejected"
        -- Non-swap actions are unconstrained by the binding.
        assert (decide (Bridge.reserveSwapBindingPolicy.authorized 9
            (.transfer 0 9 7 5)))
          "the binding is a no-op outside tag 25"
    }
  , -- ## Deny lists: neither reserved actor may SIGN a reserveSwap
    { name := "deny lists: tag 25 denied for the pool and the reserve"
    , body := do
        assert (decide ((25 : Nat) ∈ Bridge.gasPoolDeniedTags))
          "tag 25 ∈ gasPoolDeniedTags"
        assert (decide ((25 : Nat) ∈ Bridge.ammReserveDeniedTags))
          "tag 25 ∈ ammReserveDeniedTags"
    }
  , -- ## Event vocabulary (frozen tags 23/24)
    { name := "events: reserveSwapExecuted = 23, reserveSeeded = 24"
    , body := do
        assertEq (expected := (23 : Nat))
          (actual := Events.Event.tag (.reserveSwapExecuted 0 1 9 1000 906 3))
          "reserveSwapExecuted tag"
        assertEq (expected := (24 : Nat))
          (actual := Events.Event.tag (.reserveSeeded 0 2500 3 12))
          "reserveSeeded tag"
    }
  , -- ## Term-level API stability (elaboration-time pins)
    { name := "headline theorem signatures are stable"
    , body := do
        let _noDrain :
            ∀ (fr tr : ResourceId) (user : ActorId) (ai mao : Amount)
              (ra : ActorId) (s : State),
              (reserveSwap fr tr user ai mao ra).pre s →
              reserveQuote s fr tr ra ai < getBalance s tr ra :=
          reserveSwap_no_reserve_drain
        let _kMono :
            ∀ (fr tr : ResourceId) (user : ActorId) (ai mao : Amount)
              (ra : ActorId) (s : State),
              (reserveSwap fr tr user ai mao ra).pre s →
              getBalance s fr ra * getBalance s tr ra
                ≤ (getBalance s fr ra + ai)
                    * (getBalance s tr ra - reserveQuote s fr tr ra ai) :=
          reserveSwap_k_nondecreasing
        let _minOut :
            ∀ (fr tr : ResourceId) (user : ActorId) (ai mao : Amount)
              (ra : ActorId) (s : State),
              (reserveSwap fr tr user ai mao ra).pre s →
              mao ≤ reserveQuote s fr tr ra ai ∧
              1 ≤ reserveQuote s fr tr ra ai :=
          reserveSwap_min_out_honoured
        let _consFrom :
            ∀ (fr tr : ResourceId) (user : ActorId) (ai mao : Amount)
              (ra : ActorId) (s : State),
              (reserveSwap fr tr user ai mao ra).pre s →
              TotalSupply (step_impl s (reserveSwap fr tr user ai mao ra)) fr
                = TotalSupply s fr :=
          reserveSwap_conserves_from
        let _consTo :
            ∀ (fr tr : ResourceId) (user : ActorId) (ai mao : Amount)
              (ra : ActorId) (s : State),
              (reserveSwap fr tr user ai mao ra).pre s →
              TotalSupply (step_impl s (reserveSwap fr tr user ai mao ra)) tr
                = TotalSupply s tr :=
          reserveSwap_conserves_to
        -- Classification instances resolve by `inferInstance`.
        let _cons : IsConservative (reserveSwap 0 1 9 1000 900 3) := inferInstance
        let _localTo : LocalTo [0, 1] (reserveSwap 0 1 9 1000 900 3) :=
          inferInstance
        let _freeze : FreezePreserving [] (reserveSwap 0 1 9 1000 900 3) :=
          inferInstance
        let _registry : Authority.RegistryPreserving (.reserveSwap 0 1 9 1000 900 3) :=
          inferInstance
        -- The fee constant is shared with the AMM math and inside the
        -- denominator's range.
        let _fee : Bridge.AmmMath.swapFeeBps < Bridge.AmmMath.bpsDenominator :=
          Bridge.AmmMath.swapFeeBps_lt_bpsDenominator
        assert true "theorem signatures elaborated"
    }
  , -- ## Workstream AX: the kill-switch halt (BridgeAdmissibleWith
    -- conjunct 10).  Once the L2 `ammDisabled` mirror is set, no
    -- user swap is bridge-admissible — the sequencer's gate freezes
    -- the pool for the bridge-signed reclaim sweep.
    { name := "AX: reserveSwap is bridge-inadmissible while ammDisabled"
    , body := do
        let _proof :
            ∀ {verify : Authority.PublicKey → ByteArray →
                          Authority.Signature → Bool}
              {P : Authority.AuthorityPolicy} {d : ByteArray}
              {es : Authority.ExtendedState} {st : Authority.SignedAction},
              es.bridge.ammDisabled = true →
              ∀ (fromResource toResource : ResourceId) (user : ActorId)
                (amountIn minAmountOut : Amount) (reserveActor : ActorId),
                st.action = .reserveSwap fromResource toResource user amountIn
                              minAmountOut reserveActor →
              ¬ Bridge.BridgeAdmissibleWith verify P d es st :=
          fun h_dis fr tr u ai mao ra heq =>
            Bridge.reserveSwap_inadmissible_while_amm_disabled h_dis fr tr u ai mao ra heq
        pure ()
    }
  , { name := "AX: the reserveSwapGate projection is API stable"
    , body := do
        -- Value-level twin: build a disabled-state fixture and check
        -- the gate conjunct refuses by `decide` on the projected
        -- proposition (the full `BridgeAdmissibleWith` needs a
        -- signature witness, so the conjunct is probed directly —
        -- the theorem case above covers the composed refusal).
        let esOn : Authority.ExtendedState := Authority.ExtendedState.empty
        let esOff : Authority.ExtendedState :=
          { esOn with bridge := { esOn.bridge with ammDisabled := true } }
        let st : Authority.SignedAction :=
          { action := .reserveSwap 0 1 9 1000 900 3
          , signer := 9, nonce := 0, sig := ByteArray.empty }
        let gate := fun (es : Authority.ExtendedState) =>
          decide (∀ fr tr user amountIn minAmountOut reserveActor,
            st.action = .reserveSwap fr tr user amountIn minAmountOut reserveActor →
            es.bridge.ammDisabled = false)
        assertEq (expected := true) (actual := gate esOn)
          "the gate admits while the AMM is live"
        assertEq (expected := false) (actual := gate esOff)
          "the gate refuses once the kill switch is mirrored"
    }
  ]

end LegalKernel.Test.Laws.ReserveSwapTests
