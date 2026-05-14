<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Economic invariants (Phase 2 design note)

This note records the **design and proof obligations** for Canon's
Phase-2 economic-invariants framework.  It is the deliverable for
Genesis Plan §12 Phase 2 (WU 2.1 – 2.9) and is referenced by the
security-review checklist (§14.8) and the deployment runbook (§13.7).

## Scope

Phase 2 adds a **non-TCB** layer above the kernel that classifies
laws by their effect on `TotalSupply` and proves the per-resource
conservation theorem the Genesis Plan §5.3 promises.  The phase is
intentionally additive: no kernel-TCB module is modified, and
`tcb_allowlist.txt` stays at one entry.

The new modules:

| Module                                   | Role                                                                       |
|------------------------------------------|----------------------------------------------------------------------------|
| `LegalKernel/Conservation.lean`          | `TotalSupply`, `IsConservative`, `ConservativeLawSet`, `total_supply_global` |
| `LegalKernel/Laws/Transfer.lean` (extended) | `transfer_conserves`, `transfer_isConservative` instance                |
| `LegalKernel/Laws/Mint.lean` (new)       | `mint` law + `mint_not_conservative`                                       |
| `LegalKernel/Laws/Burn.lean` (new)       | `burn` law + `burn_not_conservative`                                       |
| `LegalKernel/Laws/Freeze.lean` (new)     | `freezeResource` marker + `FrozenForResource` invariant                    |

## The master accounting lemma

Every per-law conservation argument in Phase 2 chains through:

```lean
theorem totalSupply_setBalance
    (s : State) (r : ResourceId) (a : ActorId) (v : Nat) :
    TotalSupply (setBalance s r a v) r + getBalance s r a =
    TotalSupply s r + v
```

The lemma states: `setBalance` shifts the per-resource sum by exactly
`v - getBalance s r a`, in additive form (sidestepping `Nat`
subtraction asymmetries).  Specialising:

- `v = old + delta` ⇒ "sum increases by delta" (mint).
- `v = old - delta` (under `delta ≤ old`) ⇒ "sum decreases by delta" (burn).
- Two writes (debit + credit at distinct actors, or write-then-rewrite
  at the same actor under the §4.11 sequencing fix) ⇒ "sum unchanged"
  (transfer).

The proof case-splits on the four combinations of *resource present /
absent* and *actor present / absent in the resource map*, deferring
the heavy lifting to the §8.3 `RBMap.sumValues_insert_*` lemmas.  See
`Conservation.lean:totalSupply_setBalance` for the full proof.

## `IsConservative` typeclass

```lean
class IsConservative (t : Transition) : Prop where
  conserves : ∀ (r : ResourceId) (s : State),
              t.pre s →
              TotalSupply (step_impl s t) r = TotalSupply s r
```

Why a typeclass rather than a plain predicate?  Two reasons:

1. **Automatic resolution.**  When constructing a `ConservativeLawSet`,
   the `isConservative` field is discharged by typeclass search:
   each conservative law (currently `transfer`) provides a single
   `instance`, and downstream deployments compose conservative law
   sets without re-stating the proof.

2. **Type-level firewall.**  Mint and burn cannot be promoted to
   `IsConservative` instances because no such instance exists, and
   `mint_not_conservative` / `burn_not_conservative` prove the
   negation explicitly.  A deployment that tries to add `mint …` to
   a `ConservativeLawSet` gets a typeclass-resolution failure at the
   call site.

## `ConservativeLawSet` and `total_supply_global`

```lean
structure ConservativeLawSet where
  laws            : List Transition
  isConservative  : ∀ t ∈ laws, IsConservative t

theorem total_supply_global
    (r₀ : ResourceId) (target : Nat)
    (s0 : State) (h_init : TotalSupplyEquals r₀ target s0)
    (laws : List Transition)
    (h_conservative :
      ∀ t ∈ laws, ∀ s, t.pre s →
        TotalSupply (step_impl s t) r₀ = TotalSupply s r₀) :
    ∀ s, ReachableViaLaws laws s0 s → TotalSupplyEquals r₀ target s
```

Two consumption paths:

- The **`total_supply_global`** form (above, §5.3 verbatim) takes the
  conservation hypothesis directly.  Useful when the deployment's
  law set is partially conservative — e.g., a mixed deployment with
  both transfer and mint, where conservation holds at *most*
  resources but not the minted one.
- The **`total_supply_global_via_law_set`** corollary takes a
  `ConservativeLawSet` and discharges the conservation hypothesis
  via the typeclass.  This is the form a §13.7 deployment proof
  typically uses.

## `transfer_conserves` proof structure

```lean
theorem transfer_conserves
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (s : State) (hpre : (transfer r sender receiver amount).pre s) :
    TotalSupply (step_impl s (transfer r sender receiver amount)) r =
    TotalSupply s r
```

The proof unfolds in four steps:

1. **Reduce `step_impl` to `apply_impl`** via the precondition: `if`
   reduces to the `apply_impl` branch.
2. **Unfold `transfer`** to expose the two-step debit/credit body.
3. **Apply the master accounting lemma twice** (once at the debit
   `setBalance`, once at the credit), producing two `Nat`-equation
   hypotheses.
4. **Solve the resulting linear `Nat`-arithmetic system** with `omega`
   via the private `transfer_arithmetic` helper, which abstracts the
   nested `TotalSupply (setBalance (setBalance …))` terms to plain
   `Nat` parameters.

The proof is **uniform over the distinct-actor and self-transfer
cases** — the §4.11 self-transfer fix in `transfer.apply_impl` (read
the receiver's balance from the post-debit state, not the original)
makes the case-split unnecessary at the conservation level.  See
`Laws/Transfer.lean:transfer_conserves` for the full proof.

### Why `transfer_arithmetic`?

`omega` in Lean 4.29.1 has trouble parsing deeply-nested
`TotalSupply (setBalance (setBalance …))` terms as atomic `Nat`
variables.  Lifting the proof to a pure-arithmetic helper that takes
six `Nat` parameters (`T0`, `T1`, `T2`, `B`, `R1`, `amount`) and
three `Nat`-equation hypotheses lets `omega` see a clean variable
system it solves trivially.  The `private` helpers
(`transfer_arithmetic` and `burn_arithmetic`) live in the same
modules as the lemmas they prop up; they are not part of the
deployment-facing API.

## Mint / burn non-conservation witnesses

Both witnesses have the same skeleton:

1. **Construct a state where the law's precondition holds.**  Mint
   uses `genesisState` (precondition `amount > 0` is independent of
   state).  Burn uses `setBalance genesisState r fromActor amount`,
   so `getBalance s r fromActor = amount ≥ amount`.
2. **Apply the conservation hypothesis** (assuming `IsConservative`)
   to get `TotalSupply (post) r = TotalSupply (pre) r`.
3. **Compute both sides.**  Mint: `TotalSupply (post) r = amount` and
   `TotalSupply (pre) r = 0`, so conservation forces `0 = amount`,
   contradicting `amount > 0`.  Burn: similar but with
   `amount + amount = amount`.
4. **Close with `Nat.pos_iff_ne_zero`** to get `False`.

See `Laws/Mint.lean:mint_not_conservative` and
`Laws/Burn.lean:burn_not_conservative` for the full proofs.

## Freeze invariant

```lean
def freezeResource (_r : ResourceId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s => s

def FrozenForResource (r : ResourceId) (snap : Option BalanceMap)
    (s : State) : Prop :=
  s.balances[r]? = snap
```

`freezeResource r` is a **no-op marker** at the kernel level.  The
freeze is a *deployment commitment*: by including `freezeResource r`
in the action log and excluding subsequent mutating laws at `r`, the
deployment guarantees `FrozenForResource r snap` by construction.

The `_r` underscore prefix on the kernel-level parameter is
**deliberate** — `freezeResource 1` and `freezeResource 2` are
*definitionally equal* `Transition` values (their `pre`, `decPre`,
and `apply_impl` are all independent of `r`).  Distinct freezes are
distinguished only at the action layer, where `Action.freezeResource
1` and `Action.freezeResource 2` are different constructors of the
`Action` inductive — and the action layer is a Phase-3 deliverable.
Until then, the kernel treats every `freezeResource` invocation as
the same Transition; the *deployment-level* tracking of which
resource was frozen is captured in the choice of
`FrozenForResource r snap` invariant the deployment proves.

The four preservation lemmas:

- `freezeResource_preserves_freeze`: trivially (identity transformer).
  The proof reduces to `hI` by definitional equality:
  `step_impl s (freezeResource _) = s` because `pre := True` collapses
  the `if` and `apply_impl := fun s => s`.
- `transfer_preserves_freeze`: conditional on `r ≠ r'` (the
  transferred resource).  Direct consequence of
  `transfer_other_resource_untouched` (§4.11.2 lifted to the
  state-level `BalanceMap`).
- `mint_preserves_freeze`: conditional on `r ≠ r'` (the minted
  resource).  Direct consequence of `mint_other_resource_untouched`,
  the symmetric helper added in `Laws/Mint.lean`.
- `burn_preserves_freeze`: symmetric to mint, via
  `burn_other_resource_untouched`.

### Why no kernel-level enforcement?

Kernel-level enforcement (rejecting mutating laws at frozen
resources) would require either:

- **TCB expansion**: adding a `frozen : List ResourceId` (or
  `Set ResourceId`) field to `State`, plus per-mutating-law
  precondition extensions.  Both invasive.
- **Per-law parameterisation**: every mutating law would carry a
  "frozen set" parameter.  Pollutes the law API.

The deployment-level approach (commit + restrict + audit) is
cleaner and parallels the conservation discipline (where mint/burn
are excluded by typing from `ConservativeLawSet`).  Phase 3's
authority layer will close the loop by adding the runtime check
that rejects actions targeting frozen resources before they reach
the kernel.

## Test coverage

- `LegalKernel/Test/ConservationTests.lean` (15 cases) — sanity for
  `TotalSupply`, `totalSupply_setBalance` value-level checks at four
  representative inputs, `TotalSupplyEquals` round-trip (positive
  and negative), two `transfer_conserves` witnesses, `IsConservative`
  typeclass resolution, `ConservativeLawSet` construction, runtime
  `total_supply_global` and `total_supply_global_via_law_set`,
  explicit `totalSupply_eq_zero_of_no_resource` runtime check.
- `LegalKernel/Test/Laws/Transfer.lean` (16 cases — Phase-0 base 11
  plus 5 Phase-2) — `transfer_conserves`,
  `transfer_does_not_touch_other_resources`,
  `transfer_conserves_other_resource`, `IsConservative` instance.
- `LegalKernel/Test/Laws/Mint.lean` (10 cases) — precondition
  decidability, value semantics, `totalSupply_after_mint`,
  `mint_not_conservative`, plus the three new mint cross-resource
  helpers (`mint_other_resource_untouched`,
  `mint_does_not_touch_other_resources`,
  `mint_conserves_other_resource`).
- `LegalKernel/Test/Laws/Burn.lean` (12 cases) — symmetric to mint
  with the "burn down to zero" edge case, plus the three burn
  cross-resource helpers.
- `LegalKernel/Test/Laws/Freeze.lean` (10 cases) —
  `FrozenForResource` reflexivity, all four preservation lemmas at
  runtime, freezeResource-is-identity, plus three negative
  regression tests (`mint`, `burn`, `transfer` applied at the
  *frozen* resource genuinely change a per-actor balance —
  witnessing the necessity of the disjointness hypothesis).

`lake test` runs every suite via the `Tests.lean` driver (1 596
total tests across 89 suites as of LX-M3 audit-5; the counts above
are the Phase-2 baselines, with Phase-4-prelude bumps documented in
the Phase-4-prelude section below) and exits non-zero on any
failure; CI runs the same driver.

## Axiom audit

`#print axioms` on every Phase-2 theorem returns exactly
`[propext, Classical.choice, Quot.sound]`.  No custom axioms.

## Phase-4 prelude: the monotonicity tier (Positive Incentives)

The Phase-4-prelude work (Genesis Plan §12 Phase-4-prelude WUs
R.1 – R.23) introduces the **monotonicity tier**: a strictly weaker
classification than `IsConservative` that captures laws whose
preconditions are sufficient to guarantee that `TotalSupply` does
not decrease at any resource.

### Tier hierarchy

```
                   IsConservative
                   (post = pre)
                         │
                         │  monotonic_of_conservative
                         │  (instance, low priority)
                         ▼
                    IsMonotonic
                    (pre ≤ post)
```

Every conservative law is automatically monotonic (equality is a
special case of `≤`); `monotonic_of_conservative` ships as a
low-priority instance to make this implicit in typeclass resolution
without overriding per-law explicit instances.

### New typeclass and lawset

| Definition                     | Mirror of                | Purpose                                    |
|--------------------------------|--------------------------|--------------------------------------------|
| `IsMonotonic`                  | `IsConservative`         | Per-law classification (supply non-decreasing). |
| `MonotonicLawSet`              | `ConservativeLawSet`     | Type-level firewall against value-destroying laws. |
| `total_supply_globally_nondecreasing[_via_law_set]` | `total_supply_global[_via_law_set]` | Headline guarantee: per-resource non-decrease across reachable states. |

### Three new positive-incentive laws

The monotonicity tier is populated with three new laws, all in
`LegalKernel/Laws/`, all classified `IsMonotonic` and *not*
`IsConservative`:

1. **`reward r to amount`** — single-recipient credit.
   Definitionally identical to `mint` at the kernel level, but
   distinct at the `Action` layer so that authority policies can
   grant `mint` and `reward` permissions independently.

2. **`distributeOthers r excluded amount`** — uniform credit of
   `+amount` to every actor present in `r`'s `BalanceMap` except
   `excluded`.  Substitute for "fining `excluded` by the equivalent
   of `amount * k`" without removing tokens from `excluded`.  Empty
   maps and excluded-only maps are no-ops.

3. **`proportionalDilute r excluded totalReward`** — proportional
   credit of `totalReward * v_k / sumOthers` (Nat floor; **dust
   discarded**) to each non-excluded actor `k` in proportion to their
   existing balance `v_k`.  Strongest analogue of "burning
   `excluded`'s balance share" available without removing tokens;
   non-excluded actors retain their relative wealth ranking.

The dust-bound theorem
`proportionalDilute_distributed_le_totalReward` formally pins the
floor-division dust loss: post-supply ≤ pre-supply + totalReward.
The proof goes through new filter-sum infrastructure in
`Conservation.lean` (`balanceMap_filter_sum_plus_lookup`,
`state_filter_sum_eq_sumOthers`), which uses
`Std.TreeMap.distinct_keys_toList` to bridge per-bm filter sums to
`sumOthers`.

### Burn's place under the firewall

`Laws/Burn.lean` remains in the codebase for deployments that
genuinely need supply contraction.  It cannot inhabit
`MonotonicLawSet`: `burn_not_monotonic` proves explicitly that no
`IsMonotonic (burn r f a)` instance exists when `a > 0`.  This is
the formal type-level firewall: a deployment that selects
`MonotonicLawSet` is type-checked against *ever* including burn,
catching the violation at compile time rather than at runtime.

### Economic motivation (recap)

Substituting `burn` ("fine A by N") with `reward`-family mechanisms
("reward all non-A actors") is **Pareto-superior for non-penalised
actors**: under burn, others stay flat nominally and gain only
relatively; under reward-others, others gain *both* nominally and
relatively.  The penalised actor's relative-wealth penalty is
identical between the two approaches.

In self-referential token systems (governance weight, pool shares,
reputation), there is no inflation cost to law-abiding actors,
because the new tokens are minted to *them* (their nominal balance
grows in lockstep with the supply growth).

### Headline theorem (deployment perspective)

A deployment that supplies a `MonotonicLawSet` gets, "for free":

```lean
total_supply_globally_nondecreasing_via_law_set :
    ∀ (r₀ : ResourceId) (s0 : State) (mls : MonotonicLawSet),
      ∀ s, ReachableViaLaws mls.laws s0 s →
           TotalSupply s0 r₀ ≤ TotalSupply s r₀
```

i.e., the per-resource supply at every reachable state is at least
the initial supply.  This is the value-conservation guarantee the
positive-incentive paradigm targets: deployments cannot lose value,
even though individual laws may grow it.

### Axiom audit (Phase-4 prelude)

`#print axioms` on every Phase-4-prelude theorem returns exactly
`[propext, Classical.choice, Quot.sound]`.  No custom axioms; no new
opaque declarations.

## Phase-6 incentive-integration amendment

The Phase-6 base implementation (WUs 6.1 – 6.12) lands the §8.4
four-stage dispute pipeline as a sibling to the kernel without
any incentive integration: every dispute action constructor
compiles to `Laws.freezeResource 0`, and verdict application
either rolls back state (upheld) or leaves it unchanged
(rejected/inconclusive).

The Phase-6 incentive-integration amendment (WUs 6.13 – 6.23)
extends the dispute pipeline to compose with the Phase-4-prelude
positive-incentive mechanisms.  Concretely:

### Type-level firewall composition

The four dispute action constructors (`dispute`,
`disputeWithdraw`, `verdict`, `rollback`) all compile to
`Laws.freezeResource 0`, which has both `IsConservative` and
`IsMonotonic` instances.  WU 6.13 materialises this as 8
typeclass instances + a composite summary theorem.  WU 6.14
constructs an explicit `disputableMonotonicLawSet` and proves
the headline non-decrease theorem applies to it.

**Boundary clarification.**  An upheld verdict's runtime-level
rollback (`applyVerdict`) replaces state OUTSIDE
`ReachableViaLaws`.  Within each "session" between rollbacks,
supply is non-decreasing; rollbacks introduce a sawtooth into the
cumulative supply trace.

### Bug-bounty + adjudicator-compensation rewards

`DisputeRewardPolicy` (`LegalKernel/Disputes/Rewards.lean`) is a
deployment-supplied structure with two pure deterministic fields
returning `Option (ResourceId × Amount)`.  Atomic constructors
(`empty`, `flatChallengerReward`, `flatAdjudicatorReward`,
`union`), graduated constructors (`byClaimVariant`,
`proportionalChallengerReward`), and stake-weighted distribution
(`stakeWeightedAdjudicatorRewards`) compose via
`disputeRewardActionsMulti` for cross-resource bundles.

All emitted actions use `Action.reward` (positive-incentive,
monotonic) — never `Action.burn`.  Kernel-level monotonicity is
preserved.

### Anti-fraud staking (WU 6.19)

`StakingPolicy` (`LegalKernel/Disputes/Staking.lean`) provides
*kernel-conservative* anti-fraud staking: the challenger
transfers `stakeAmount` to a deployment-supplied escrow at filing
time.  On upheld, the rollback implicitly returns the stake (per
design decision D1 — the rollback target is BEFORE the staking
transfer).  On rejected / inconclusive, the runtime emits an
explicit `escrow → treasury` transfer (forfeiture).

**Slashing is NOT burning.**  Total supply is preserved — every
staking action is an `Action.transfer`.

### Semantic event observability (WU 6.20)

`Event.rewardIssued (resource, recipient, amount)` (frozen index
8) is emitted by `actionEvents` for every `Action.reward _ _ _`,
in addition to the kernel-level `balanceChanged` event (which is
delta-filtered).  Indexers subscribe to either or both depending
on whether they want kernel-level deltas or deployment-level
reward semantics.

## Workstream-LX: classification-tier extensions

The Lex workstream (LX-M1, work unit LX.2) introduces three further
non-TCB classification typeclasses and one structure mirroring
`MonotonicLawSet`.  These are *strictly additive* — neither
modifies any kernel-TCB module nor any Phase-2 / Phase-4-prelude
theorem statement.

| Definition                       | Mirror of                        | Purpose                                                        |
|----------------------------------|----------------------------------|----------------------------------------------------------------|
| `LocalTo (S : List ResourceId) (t : Transition)` | `IsConservative` / `IsMonotonic` | Per-law locality: applying `t` mutates only resources in `S`. |
| `FreezePreserving (S : List ResourceId) (t : Transition)` | `LocalTo` | Per-law freeze-preservation: `t` preserves `s.balances[r]?` for every `r ∈ S`. |
| `FreezePreservingLawSet (S : List ResourceId)` | `MonotonicLawSet`        | Type-level firewall against laws that mutate frozen resources. |
| `RegistryPreserving (a : Action)` | (Action-indexed; no Transition mirror) | Action-level surface for "this `Action` does not mutate the `KeyRegistry`". |

The headline corollary `freeze_preservation_via_law_set` is the
typeclass-driven analogue of `total_supply_globally_nondecreasing_
via_law_set`: a deployment that supplies a `FreezePreservingLawSet
S` gets, for free, that the per-resource balance map at every
reachable state agrees with the genesis state on every `r ∈ S`.

Per-existing-law `LocalTo [r]` instances ship for all 8
balance-mutating laws (transfer, mint, burn, reward,
distributeOthers, proportionalDilute, deposit, withdraw); the
universal-in-`S` `freezeResource_localTo` /
`freezeResource_freezePreserving` instances ship for the
freeze-resource law.  15 `RegistryPreserving` instances ship for
every non-mutating `Action` constructor; the deliberately-absent
ones for `replaceKey` and `registerIdentity` serve as the negative
witnesses.

### Classification matrix (post-LX-M2)

The 17 kernel-built-in laws populate the classification tiers as
follows:

| Law                  | `IsConservative` | `IsMonotonic` | `LocalTo [r]` | `RegistryPreserving` |
|----------------------|------------------|---------------|---------------|----------------------|
| `transfer`           | yes              | yes           | yes           | yes                  |
| `mint`               | no (witnessed)   | yes           | yes           | yes                  |
| `burn`               | no (witnessed)   | no (witnessed)| yes           | yes                  |
| `freezeResource`     | yes              | yes           | universal     | yes                  |
| `reward`             | no               | yes           | yes           | yes                  |
| `distributeOthers`   | no               | yes           | yes           | yes                  |
| `proportionalDilute` | no               | yes           | yes           | yes                  |
| `deposit`            | no               | yes           | yes           | yes                  |
| `withdraw`           | no (witnessed)   | no (witnessed)| yes           | yes                  |
| `replaceKey`         | yes              | yes           | universal     | NO (Action mutates registry) |
| `registerIdentity`   | yes              | yes           | universal     | NO (Action mutates registry) |
| `dispute` × 4        | yes              | yes           | universal     | yes                  |
| `declareLocalPolicy` | yes              | yes           | universal     | yes                  |
| `revokeLocalPolicy`  | yes              | yes           | universal     | yes                  |

"Witnessed" means the codebase ships an explicit *negative* witness
(`mint_not_conservative`, `burn_not_conservative`,
`burn_not_monotonic`, `withdraw_not_conservative`,
`withdraw_not_monotonic`, `deposit_not_conservative`) that proves
no instance can exist.  These are what make the firewall sound: a
deployment that adds `burn` to a `MonotonicLawSet` fails typeclass
resolution at compile time, with the negative witness explaining
why.

## Cross-references

- Genesis Plan §4.11 — the `transfer` law with the self-transfer fix.
- Genesis Plan §5.3 — the `total_supply_global` claim.
- Genesis Plan §5.6 — per-resource conservation generalisation.
- Genesis Plan §8.1 — `TotalSupply` definition.
- Genesis Plan §8.3 — RBMap proof library that the master lemma
  builds on.
- Genesis Plan §12 Phase 2 — work-unit breakdown.
- Genesis Plan §12 Phase-4 prelude — the WU R.1 – R.23 amendment
  block covering this section's content.
- Genesis Plan §12 Phase-6 — base implementation (WUs 6.1 – 6.12).
- Genesis Plan §12 Phase-6 incentive-integration amendment —
  WUs 6.13 – 6.23.
- `docs/planning/lex_implementation_plan.md` §LX.2 / §LX.3 — the LocalTo /
  FreezePreserving / RegistryPreserving classification typeclasses
  and per-law instances (the section above).
- `docs/planning/actor_scoped_policies_plan.md` LP.9 — the LP-action
  classification (`declareLocalPolicy` / `revokeLocalPolicy` are
  both `IsConservative` and `IsMonotonic`).
- `CLAUDE.md` "Type-level design properties" — table that includes
  every Phase-2, Phase-3, Phase-4-prelude, Phase-6 base, Phase-6
  amendment, Audit-3 hardening, Ethereum Workstream A – D, LP, and
  LX theorem (#1 – #221 as of LX-M3).
- `docs/decidability_discipline.md` — `decPre` discipline for
  `mint`, `burn`, `freezeResource`, the three positive-incentive
  laws, and the bridge `deposit` / `withdraw` laws.
- `docs/std_dependencies.md` — informational `Std` dependency notes
  for the Phase-2 / Phase-4-prelude / Phase-6 / Workstream-A – D
  modules.
