/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.MonotonicDeployment — example
"monotonic disputable deployment".

Phase-6 incentive-integration amendment.  Constructs an explicit
`MonotonicLawSet` containing the four Phase-4-prelude monotonic
laws (`transfer`, `mint`, `reward`, `distributeOthers`,
`proportionalDilute`) plus `freezeResource 0` (which covers all
four dispute-pipeline action constructors via
`Action.compileTransition`).  Demonstrates that a deployment can
admit the dispute pipeline alongside `MonotonicLawSet` without
breaking the kernel-level monotonicity firewall.

The headline theorem
`disputable_monotonic_total_supply_nondecreasing` is the direct
application of
`total_supply_globally_nondecreasing_via_law_set` to this law set.

**Boundary clarification.**  The kernel-level monotonicity claim
covers the `Reachable` / `ReachableViaLaws` relation built from
`step_impl` over the deployed `Transition`s.  An upheld verdict's
runtime-level rollback (`applyVerdict`) replaces state OUTSIDE
this relation; deployments that need to reason about post-rollback
state should restart their reachability analysis from the rolled-
back state as a new "session".

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Reward
import LegalKernel.Laws.DistributeOthers
import LegalKernel.Laws.ProportionalDilute
import LegalKernel.Laws.Freeze
-- Note: `LawClassification` is NOT imported here.  This module
-- proves monotonicity of the deployment via the *underlying laws*
-- (`Laws.freezeResource`, etc.); the dispute-action ctor instances
-- in `LawClassification` are downstream of this module's claims.
-- A consumer module (e.g. a runtime adaptor) that wants both the
-- dispute-pipeline ctor instances AND the example deployment
-- imports both modules separately.

namespace LegalKernel
namespace Disputes

open LegalKernel.Laws

/-! ## The example deployment

Six representative monotonic transitions:

  * `Laws.transfer 0 0 0 0`           — transfer (parametrised)
  * `Laws.mint 0 0 0`                 — mint (parametrised)
  * `Laws.reward 0 0 0`               — reward (parametrised)
  * `Laws.distributeOthers 0 0 0`     — distributeOthers (parametrised)
  * `Laws.proportionalDilute 0 0 0`   — proportionalDilute (parametrised)
  * `Laws.freezeResource 0`           — freeze marker (covers all four
                                          dispute-pipeline action
                                          constructors via their
                                          shared `compileTransition`
                                          target)

A real deployment would parametrise each law over the actual
resources / actors / amounts it admits.  The example above uses
`0` placeholders to make the law-set's constructibility provable
at the type level. -/

/-- The example monotonic disputable deployment's law list.

    Indexed via `LegalKernel.Laws.*` to make `fin_cases` over the
    list dispatch into known `IsMonotonic` instances. -/
def disputableMonotonicLaws : List Transition :=
  [ Laws.transfer 0 0 0 0,
    Laws.mint 0 0 0,
    Laws.reward 0 0 0,
    Laws.distributeOthers 0 0 0,
    Laws.proportionalDilute 0 0 0,
    Laws.freezeResource 0 ]

/-- Per-element monotonicity proof for `disputableMonotonicLaws`:
    each entry has a known `IsMonotonic` instance from Phase-2 +
    Phase-4-prelude.  Discharged by case-splitting on list
    membership and applying `inferInstance` per branch. -/
theorem disputableMonotonicLaws_isMonotonic :
    ∀ t ∈ disputableMonotonicLaws, IsMonotonic t := by
  intro t ht
  -- ht : t ∈ [Laws.transfer .., Laws.mint .., ..., Laws.freezeResource 0]
  simp only [disputableMonotonicLaws, List.mem_cons, List.not_mem_nil, or_false] at ht
  rcases ht with h | h | h | h | h | h
  · subst h; exact transfer_isMonotonic 0 0 0 0
  · subst h; exact mint_isMonotonic 0 0 0
  · subst h; exact reward_isMonotonic 0 0 0
  · subst h; exact distributeOthers_isMonotonic 0 0 0
  · subst h; exact proportionalDilute_isMonotonic 0 0 0
  · subst h; exact freezeResource_isMonotonic 0

/-- The example "monotonic disputable deployment" packaged as a
    `MonotonicLawSet`.  Inhabits the firewall structure, so a
    deployment using these laws (modulo concrete parameter
    instantiation) gets the headline non-decrease theorem
    automatically. -/
def disputableMonotonicLawSet : MonotonicLawSet where
  laws        := disputableMonotonicLaws
  isMonotonic := disputableMonotonicLaws_isMonotonic

/-! ## Headline theorem

The application of `total_supply_globally_nondecreasing_via_law_set`
to the example deployment.  States: at every resource, every
state reachable from `genesisState` via the example deployment's
laws has `TotalSupply ≥ TotalSupply genesisState`.

Phase-2's `genesisState` has empty balances, so
`TotalSupply genesisState r₀ = 0` at every resource.  The theorem
therefore degenerates to `0 ≤ TotalSupply s r₀`, which is trivial
for any state — but the *general* form (which works against any
initial state, not just the empty genesis) is what makes this a
useful template for production deployments. -/

/-- Per-resource non-decrease across reachable states under the
    example monotonic disputable deployment.  Direct application
    of `total_supply_globally_nondecreasing_via_law_set`. -/
theorem disputable_monotonic_total_supply_nondecreasing
    (r₀ : ResourceId) (s : State)
    (hreach : ReachableViaLaws disputableMonotonicLawSet.laws genesisState s) :
    TotalSupply genesisState r₀ ≤ TotalSupply s r₀ :=
  total_supply_globally_nondecreasing_via_law_set
    r₀ genesisState disputableMonotonicLawSet s hreach

/-- The same theorem starting from an arbitrary initial state
    `s0`.  Production deployments rarely start at `genesisState`;
    this form supports a deployment whose initial state has actor
    balances pre-funded. -/
theorem disputable_monotonic_total_supply_nondecreasing_from
    (r₀ : ResourceId) (s0 s : State)
    (hreach : ReachableViaLaws disputableMonotonicLawSet.laws s0 s) :
    TotalSupply s0 r₀ ≤ TotalSupply s r₀ :=
  total_supply_globally_nondecreasing_via_law_set
    r₀ s0 disputableMonotonicLawSet s hreach

end Disputes
end LegalKernel
