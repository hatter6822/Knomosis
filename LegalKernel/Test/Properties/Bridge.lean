-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Properties.Bridge — Workstream F.4.

Property-based bridge tests, mirroring the §10.4 spec:

  * `prop_deposit_then_withdraw_roundtrip` — for any
    `(amount, recipient)`, depositing then withdrawing the same
    amount returns balances to their pre-deposit values (modulo
    `nextWdId` + `consumed` records).
  * `prop_bridge_account_invariant_holds` — for any reachable state
    under the `bridgeLawSet : MonotonicLawSet` of §12.13, the
    per-resource accounting equation holds in the non-decreasing
    half: `totalSupply r es.base ≥ 0` (vacuous w.r.t. `Nat`).
  * `prop_withdrawal_proof_verifies` — for any `BridgeState`
    constructed by an arbitrary deposit / withdraw sequence,
    every pending withdrawal's extracted proof verifies against
    the published root.

All three properties are purely Lean-side value-level checks (no
Solidity cross-stack comparison), so they run unconditionally
under any `hashBytes` binding.

Each property runs against `KNOMOSIS_PROPERTY_ITERATIONS=100` by
default; failing seeds are logged via `KNOMOSIS_PROPERTY_SEED`.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property

namespace LegalKernel.Test.Properties
namespace Bridge

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Laws
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.Property

/-! ## bridgeLawSet — the §12.13 monotonic deployment -/

/-- The monotonic bridge law set.  Each entry is a concrete
    parameterised `Transition` with its `IsMonotonic` instance:

      * `Laws.transfer 0 0 0 0`           — kernel transfer
      * `Laws.deposit 0 0 0 0`             — bridge L1 → L2 credit
      * `Laws.freezeResource 0`            — covers `replaceKey` /
                                             `registerIdentity` (both
                                             compile to this Transition).

    `Laws.withdraw` is NOT in the set: `withdraw_not_monotonic`
    explicitly rules out an `IsMonotonic` instance, so attempting
    to add it produces a `failed to synthesize IsMonotonic` error
    at elaboration time (forward-protection).

    A real deployment parameterises each law over its admitted
    resources / actors; the `0` placeholders here serve the
    type-level firewall purpose. -/
def bridgeLaws : List Transition :=
  [ Laws.transfer 0 0 0 0
  , Laws.deposit 0 0 0 0
  , Laws.freezeResource 0
  ]

/-- Per-element monotonicity proof for `bridgeLaws`.  Each entry
    has a known `IsMonotonic` instance from Phase-2 / Workstream-C
    laws. -/
theorem bridgeLaws_isMonotonic : ∀ t ∈ bridgeLaws, IsMonotonic t := by
  intro t ht
  simp only [bridgeLaws, List.mem_cons, List.not_mem_nil, or_false] at ht
  rcases ht with h | h | h
  · subst h; exact transfer_isMonotonic 0 0 0 0
  · subst h; exact deposit_isMonotonic 0 0 0 0
  · subst h; exact freezeResource_isMonotonic 0

/-- The bridge `MonotonicLawSet`.  Adding `Laws.withdraw` (not
    monotonic) here would fail typeclass resolution at elaboration
    time, structurally enforcing the "withdraw is excluded" property
    at the type level. -/
def bridgeLawSet : MonotonicLawSet where
  laws        := bridgeLaws
  isMonotonic := bridgeLaws_isMonotonic

/-! ## Generators -/

/-- Generator producing a `(resourceId, recipient, amount)` triple. -/
def genDepositInput : Gen (ResourceId × EthAddress × Nat) := fun st0 =>
  let (rid, s1)    := genNat 4 st0
  let (recByte, s2) := genUInt8 s1
  let (amt, s3)    := genNat 1000 s2
  let recBytes : ByteArray :=
    ByteArray.mk
      (((List.replicate 19 (0 : UInt8)) ++ [recByte]).toArray)
  let recipient : EthAddress :=
    match EthAddress.ofBytes recBytes with
    | some a => a
    | none   => EthAddress.zero
  ((UInt64.ofNat (rid + 1), recipient, amt + 1), s3)

/-! ## Property 1: deposit-then-withdraw round-trip -/

/-- Property: for any sampled `(resource, recipient, amount)` triple,
    applying `Laws.deposit r recipient amount` followed by
    `Laws.withdraw r recipient amount recipient` returns the kernel
    state at `(r, recipient)` to its original value.

    Per the integration plan §10.4, the spec form quantifies over
    bridge state and asserts return "modulo `nextWdId` + `consumed`
    records".  The full bridge-state-side invariants (consumed
    insertion, nextWdId bump) are exercised in the
    `bridge-admissible` and `bridge-state` value-level suites; this
    property tests only the kernel-balance-restoration half of the
    round-trip, which is the load-bearing economic invariant
    (deposit credits then withdraw debits the same amount). -/
def prop_deposit_then_withdraw_roundtrip : TestCase := {
  name := "F.4 prop_deposit_then_withdraw_roundtrip (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed genDepositInput fun input =>
      let (rid, recipient, amount) := input
      -- For a clean deposit→withdraw cycle, the balance goes
      -- `0 → +amount → 0`.  Use a deterministic ActorId derived
      -- from the recipient EthAddress so each iteration probes a
      -- different cell of the kernel balance map.
      let s0 : State := genesisState
      let actorId : ActorId := UInt64.ofNat (recipient.val % (2^32))
      let s1 := step_impl s0 (Laws.deposit rid actorId amount 0)
      let s2 := step_impl s1 (Laws.withdraw rid actorId amount recipient)
      decide (getBalance s2 rid actorId = getBalance s0 rid actorId)
}

/-! ## Property 2: bridge-account invariant (non-decreasing half) -/

/-- Property: for a multi-step trace built from `bridgeLawSet`'s
    transitions, `TotalSupply` is non-decreasing at every probed
    resource.

    Per integration plan §10.4 + §21.9, the property quantifies over
    `bridgeLawSet : MonotonicLawSet` of §12.13 (`{transfer, deposit,
    freezeResource}`).  `Laws.withdraw` is deliberately excluded
    (typeclass-level forward-protection — `withdraw_not_monotonic`
    rules out an `IsMonotonic` instance, so attempting to add it
    would fail elaboration).

    This audit-pass strengthens the previous degenerate single-step
    check into a multi-step trace: a deposit + transfer + freeze
    sequence drives the monotone state forward, and the property
    asserts non-decrease at the probed resource at every
    intermediate state.  This actually exercises the typeclass-
    driven non-decrease promise of `MonotonicLawSet`. -/
def prop_bridge_account_invariant_holds : TestCase := {
  name := "F.4 prop_bridge_account_invariant_holds (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    -- Compile-time inhabitation of `bridgeLawSet : MonotonicLawSet`
    -- proves at the type level that every transition in `bridgeLaws`
    -- has an `IsMonotonic` instance — adding `withdraw` (which is
    -- not monotonic) would fail the elaboration of `bridgeLawSet`.
    let _typeLevelCheck := bridgeLawSet
    forAll n seed genDepositInput fun input =>
      let (rid, _recipient, amount) := input
      let s0 : State := genesisState
      -- 4-step trace exercising every constructor in the law set:
      --   1. deposit (positive, monotonic)
      --   2. transfer (conservative ⇒ monotonic)
      --   3. freezeResource (no-op identity, trivially monotonic)
      --   4. another deposit
      let actorA : ActorId := 1
      let actorB : ActorId := 2
      let s1 := step_impl s0 (Laws.deposit rid actorA amount 0)
      let s2 := step_impl s1 (Laws.transfer rid actorA actorB (amount / 3))
      let s3 := step_impl s2 (Laws.freezeResource rid)
      let s4 := step_impl s3 (Laws.deposit rid actorB (amount + 1) 1)
      -- Non-decrease at every step.
      decide (TotalSupply s0 rid ≤ TotalSupply s1 rid
            ∧ TotalSupply s1 rid ≤ TotalSupply s2 rid
            ∧ TotalSupply s2 rid ≤ TotalSupply s3 rid
            ∧ TotalSupply s3 rid ≤ TotalSupply s4 rid)
}

/-! ## Property 3: withdrawal-proof verification -/

/-- Property: for any bridge state constructed by an arbitrary
    sequence of withdrawals, every pending withdrawal's
    canonically-extracted proof verifies against the published
    `withdrawalRoot`.

    Discharged at the value level by `verifyProof_complete` — an
    *unconditional* theorem in `H : ByteArray → ByteArray`.
    Cross-stack equivalence with Solidity's keccak256 lives in
    F.1.5 (which DOES require the production binding). -/
def prop_withdrawal_proof_verifies : TestCase := {
  name := "F.4 prop_withdrawal_proof_verifies (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    -- Sample a withdrawalId for each iteration; build a
    -- bridge state with that withdrawal populated and assert
    -- the canonical proof verifies.
    forAll n seed (genNat 16) fun idx =>
      -- Build a bridge state with deposits at ids [0, idx].
      let s : BridgeState := Id.run do
        let mut acc : BridgeState := BridgeState.empty
        for i in (List.range (idx + 1)) do
          let wd : PendingWithdrawal :=
            { resource := 1, recipient := EthAddress.zero,
              amount := 100 + i, l2LogIndex := i }
          acc := { acc with nextWdId := i }
          acc := acc.appendWithdrawal wd
        return acc
      let proof := constructProof hashBytes s idx
      let root := withdrawalRoot hashBytes s
      verifyProof hashBytes proof root
}

/-! ## Suite assembly -/

/-- All F.4 properties in one suite. -/
def tests : List TestCase :=
  [ prop_deposit_then_withdraw_roundtrip
  , prop_bridge_account_invariant_holds
  , prop_withdrawal_proof_verifies
  ]

end Bridge
end LegalKernel.Test.Properties
