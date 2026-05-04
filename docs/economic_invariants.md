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

`lake test` runs all 95 tests via the `Tests.lean` driver and exits
non-zero on any failure; CI runs the same driver.

## Axiom audit

`#print axioms` on every Phase-2 theorem returns exactly
`[propext, Classical.choice, Quot.sound]`.  No custom axioms.

## Cross-references

- Genesis Plan §4.11 — the `transfer` law with the self-transfer fix.
- Genesis Plan §5.3 — the `total_supply_global` claim.
- Genesis Plan §5.6 — per-resource conservation generalisation.
- Genesis Plan §8.1 — `TotalSupply` definition.
- Genesis Plan §8.3 — RBMap proof library that the master lemma
  builds on.
- Genesis Plan §12 Phase 2 — work-unit breakdown.
- `CLAUDE.md` "Type-level design properties" — table that includes
  every Phase-2 theorem.
- `docs/decidability_discipline.md` — `decPre` discipline for
  `mint`, `burn`, `freezeResource`.
- `docs/std_dependencies.md` — informational `Std` dependency notes
  for the Phase-2 modules.
