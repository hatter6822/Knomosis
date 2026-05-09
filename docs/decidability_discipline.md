<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Decidability discipline for `Transition.decPre`

This note records the **decidability discipline** for Canon law authors.
It is the deliverable for Phase 1 work unit 1.6 (Genesis Plan §12) and
is referenced by the security-review checklist (§14.8).

## Why `decPre` exists

A `Transition` (Genesis Plan §4.4) bundles:

- `pre : State → Prop` — the precondition, lifting *unrestricted*
  classical reasoning;
- `decPre : (s : State) → Decidable (pre s)` — a *constructive* decision
  procedure for the precondition;
- `apply_impl : State → State` — a total state transformer.

The kernel's executable `step_impl` (§4.5) uses `decPre` to pick the
`if`-branch:

```lean
def step_impl (s : State) (t : Transition) : State :=
  if t.pre s then t.apply_impl s else s
```

Without `decPre`, the `if` would have to fall back on
`Classical.dec`, which would inflate the kernel's axiom set beyond
the three Lean built-ins (`propext`, `Classical.choice`, `Quot.sound`)
that CLAUDE.md and §14 admit.  `decPre` is therefore the small piece
of plumbing that lets the kernel remain **executable without ambient
classical logic**.

## The discipline

> **Every law's `decPre` field MUST be definable as
> `fun _ => inferInstance` whenever the precondition is built from
> arithmetic comparisons, `Nat` operations, and finite conjunctions.**

Concretely:

1. Write the precondition `pre` using only:
   - decidable comparisons over `Nat` (`≥`, `>`, `≤`, `<`, `=`, `≠`);
   - decidable equality on `ActorId`, `ResourceId` (both `UInt64`);
   - finite conjunctions, disjunctions, negations of the above;
   - finite `∀` / `∃` over `List` / `Array` / decidable finite types.
2. Set `decPre := fun _ => inferInstance`.
3. Add a one-line decidability smoke-test to the law module, e.g.:
   ```lean
   example (...) (s : State) :
       Decidable ((myLaw ...).pre s) :=
     inferInstance
   ```

If `inferInstance` does **not** resolve, that is a *signal* — see the
"Hand-written `Decidable` derivations" section below.

## Worked example: `transfer` (§4.11)

```lean
def transfer (r : ResourceId)
    (sender receiver : ActorId) (amount : Amount) : Transition where
  pre        := fun s => getBalance s r sender ≥ amount ∧ amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s => …
```

The precondition is the conjunction of two `Nat`-arithmetic
comparisons.  Both comparisons have `Decidable` instances in Lean
core; conjunction of decidable propositions is itself decidable
(also Lean core); so `inferInstance` resolves with no work.

The `LegalKernel.Laws.Transfer` module records this with:

```lean
example (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (s : State) :
    Decidable ((transfer r sender receiver amount).pre s) :=
  inferInstance
```

If the underlying `Decidable` instance is ever lost (e.g. by an Std
breaking change), the smoke-test fails at compile time — CI catches
it before the law set degrades.

## Hand-written `Decidable` derivations

A precondition that does *not* resolve via `inferInstance` is a
correctness red flag.  Common reasons:

- **Unbounded quantifiers.**  `pre := fun s => ∀ a : ActorId, …`
  ranges over the entire `UInt64` domain.  Even though `UInt64` is
  finite, the resulting decision procedure is `2^64`-many predicates
  — not what you want at runtime.  Mitigation: bound the
  quantifier to a *list* of relevant actors (which becomes finite
  and decidable).
- **Non-computable predicates.**  Anything mentioning `Classical.choice`,
  unbounded existentials, or Mathlib-style abstract structures.  The
  kernel has no Mathlib dependency, so most of these will fail to
  elaborate; if a legitimate one slips through, derive `Decidable` by
  hand and document the derivation inline.
- **Recursive preconditions over non-decidable structures.**  If you
  catch yourself writing `Decidable.rec` by hand, stop and re-state
  the precondition using accessor functions that produce decidable
  outputs.

### Review obligation

Per Genesis Plan §13.6 step 2:

> Every `Transition.decPre` field should be definable as
> `fun _ => inferInstance` whenever the precondition is built from
> arithmetic comparisons, `Nat` operations, and finite conjunctions.
> If a law needs a hand-written `Decidable` derivation, that is a
> signal to security-review the law (§14.8): preconditions that
> resist `inferInstance` often hide an unbounded quantifier or a
> non-computable predicate that breaks the executable path.

Concretely, a hand-written `Decidable` derivation in any law module
**triggers an additional security review** before the law is
admitted into the deployed law set.

## Mechanical check

The Phase-1 `count_sorries` and `tcb_audit` tools do not (yet)
mechanise this discipline.  A manual scan suffices:

```bash
# A non-empty result is a discipline violation: every `decPre` should
# be a one-liner of `fun _ => inferInstance`.
grep -nE 'decPre\s*:=' LegalKernel/Laws/*.lean \
  | grep -v 'fun _ => inferInstance'
```

The §14.8 security-review template will fold this check into a
mandatory item as the law set grows.  As of the post-LX-M3
landing, the following laws all satisfy the discipline (every
`decPre` is `fun _ => inferInstance`).  Laws marked **kernel-
identity** have `pre := True` and a no-op `apply_impl` at the
kernel level — their action-layer effects (registry mutation,
local-policy mutation, dispute pipeline state, etc.) live OUTSIDE
the kernel `Transition` and are enforced at the admissibility
layer.

| Law                  | Module                                      | Precondition shape                                                     |
|----------------------|---------------------------------------------|------------------------------------------------------------------------|
| `transfer`           | `LegalKernel/Laws/Transfer.lean`            | `getBalance s r sender ≥ amount ∧ amount > 0`                          |
| `mint`               | `LegalKernel/Laws/Mint.lean`                | `amount > 0`                                                           |
| `burn`               | `LegalKernel/Laws/Burn.lean`                | `getBalance s r fromActor ≥ amount ∧ amount > 0`                       |
| `freezeResource`     | `LegalKernel/Laws/Freeze.lean`              | `True`                                                                 |
| `reward`             | `LegalKernel/Laws/Reward.lean`              | `amount > 0`                                                           |
| `distributeOthers`   | `LegalKernel/Laws/DistributeOthers.lean`    | `amount > 0`                                                           |
| `proportionalDilute` | `LegalKernel/Laws/ProportionalDilute.lean`  | `totalReward > 0 ∧ sumOthers s r excluded > 0`                         |
| `deposit`            | `LegalKernel/Laws/Deposit.lean`             | `True` (deposit-id uniqueness lives at the bridge admissibility layer) |
| `withdraw`           | `LegalKernel/Laws/Withdraw.lean`            | `getBalance s r sender ≥ amount`                                       |
| `replaceKey`         | `LegalKernel/Laws/ReplaceKey.lean`          | `True` (kernel-identity; registry mutation in `applyActionToRegistry`) |
| `registerIdentity`   | `LegalKernel/Laws/RegisterIdentity.lean`    | `True` (kernel-identity)                                               |
| `dispute` × 4        | `LegalKernel/Laws/Dispute.lean`             | `True` (kernel-identity; dispute pipeline runs outside `apply_admissible`) |
| `declareLocalPolicy` | `LegalKernel/Laws/LocalPolicy.lean`         | `True` (kernel-identity; LP mutation in `applyActionToLocalPolicies`)  |
| `revokeLocalPolicy`  | `LegalKernel/Laws/LocalPolicy.lean`         | `True` (kernel-identity)                                               |

Each module ships an `example : Decidable ((law …).pre s) :=
inferInstance` smoke-test that fails at compile time if the
underlying `Decidable` instance is ever lost.

The Lex-side `lexlaw` macro takes the discipline a step further:
clauses are parsed from a structured `lex_pre := <expr>` field, and
the macro emits `decPre := fun _ => inferInstance` automatically
in the elaborated `Transition`.  A user-supplied `lex_pre` that
fails to resolve `Decidable` triggers a Lean elaboration error
anchored at the offending clause; no runtime / review-time scan is
needed.  This means the discipline is *mechanically enforced* for
every law authored under the Lex surface.

## Cross-references

- Genesis Plan §4.4 — `Transition` structure including `decPre`.
- Genesis Plan §4.5 — the `step_impl` `if` that consumes `decPre`.
- Genesis Plan §13.6 — the broader law-authoring runbook.
- Genesis Plan §14.8 — security-review checklist (item: "decidability").
- `CLAUDE.md` "Decidability discipline" — engineering-conventions
  summary that mirrors this note.
