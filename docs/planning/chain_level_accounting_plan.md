<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Chain-Level Bridge Accounting (§7.6.4 / §7.6.5) — Engineering Plan

This document plans the work that closes audit finding **m-16**
(the only "Defer / n/a" entry in the AR triage table): promoting
the per-action bridge accounting deltas to a single inductive
theorem over a custom `BridgeReachable` predicate, mechanising
the §7.6.4 and §7.6.5 chain-level identities currently ratified
by the cross-stack fixture corpus only.

This is the smallest of the major Lean-proof workstreams: it
requires defining one new reachability predicate, proving one
structural induction theorem, and lifting two chain-level
identities.  It does **not** touch the TCB.

## Status

  * **Workstream prefix:** `CA` (Chain Accounting).  Three
    sub-units:
    - **CA.1** `BridgeReachable` predicate + induction principle.
    - **CA.2** Chain-level supply-preservation theorem.
    - **CA.3** Chain-level escrow-equation theorem.
  * **Effort estimate:** 5–8 engineer-days for one Lean
    contributor.
  * **Build-posture target:** Lean side passes all existing
    gates; two new theorems land in `LegalKernel/Bridge/`.
  * **TCB delta:** zero.  New theorems live under `Bridge/`,
    which is non-TCB.
  * **Trust-assumption delta:** zero.  Theorems depend only on
    the existing per-action bridge deltas (E-C); no new opaques
    or axioms.

## Table of contents

  * §1 Goals and non-goals
  * §2 Mathematical background
  * §3 Work-unit dependencies
  * §4 Work-unit specifications (CA.1 – CA.3)
  * §5 Sequencing and PR structure
  * §6 Quality gates
  * §7 Risk register
  * §8 Acceptance criteria
  * §9 Out-of-scope items
  * §10 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Ship `BridgeReachable`**, a reachability predicate
    restricted to admissible kernel transitions and to bridge-
    relevant actions (`deposit`, `withdraw`,
    `bridgeRegisterIdentity`, etc.).  Inductive structure with
    `refl` and `trans` constructors mirroring `Reachable`.
  2. **Ship `bridge_chain_supply_preserved`**: across any
    `BridgeReachable` chain, the sum of L1-locked balances
    plus L2-issued balances is conserved (modulo any explicit
    mint/burn allowed by the deployment law set, captured as a
    delta term).
  3. **Ship `bridge_chain_escrow_invariant`**: across any
    `BridgeReachable` chain, the L1-side escrow ledger and the
    L2-side bridge pending/consumed sets satisfy the
    §7.6.5 identity.
  4. **Retire m-16.**  Update the AR plan, the audit synthesis
    doc, and the bridge module's comment at
    `LegalKernel/Bridge/Accounting.lean:255`.

### §1.2 Non-goals

  1. **No change to the kernel TCB.**  All work is in
    `Bridge/`.
  2. **No change to per-action bridge deltas.**  E-C already
    ships these (`deposit_delta_*`, `withdraw_delta_*`,
    etc.).  CA composes them.
  3. **No new wire format.**  `BridgeReachable` is a Lean-level
    proof artefact; nothing serialises.
  4. **No off-chain replication of the cross-stack corpus.**
    The corpus continues to ratify operationally; CA adds the
    inductive theorem alongside it.
  5. **No encoder injectivity for `BridgeState` sub-trees.**
    EI.6 / EI.7 (see `docs/planning/encoder_injectivity_plan.md`)
    own the injectivity lemmas for `BridgeState.consumed` and
    `BridgeState.pending`.  CA *consumes* those lemmas
    indirectly via its `l1EscrowMatchesL2` invariant and via
    the composition theorem of EI.8; CA does not re-prove them.
    CA may land before, after, or in parallel with EI; the
    only sub-unit dependency is that CA.3's strongest-form
    statement (extensional equality of bridge sub-states across
    a chain) presumes EI.8.  Pre-EI, CA.3 ships with the
    weaker bytes-equality form (still sound, just less
    propagating-friendly).

### §1.3 Reading guide

  * **Implementer:** read §2 then §4.  CA.1 is the structural
    setup; CA.2 and CA.3 instantiate it.
  * **Reviewer:** check the `BridgeReachable` definition
    against the existing `Reachable` shape; check the per-action
    deltas are correctly composed.

### §1.4 Glossary

  * **`Reachable s s'`.**  Kernel's existing predicate: `s'` is
    reachable from `s` via a sequence of admissible kernel
    transitions.  Reflexive-transitive closure of
    `∃ t hpre, step_impl t hpre s = .ok s'`.  Lives in
    `LegalKernel/Kernel.lean`.
  * **`BridgeReachable s s'`.**  CA's new predicate: same as
    `Reachable` but restricted to bridge-relevant transitions
    (a finite set of `Action` constructors).
  * **Per-action delta.**  A lemma asserting how a single action
    application changes the relevant accounting sums.  Already
    shipped in `LegalKernel/Bridge/Accounting.lean` for each
    bridge action.

## §2 Mathematical background

### §2.1 What §7.6.4 and §7.6.5 say

GENESIS_PLAN.md §7.6.4 (supply preservation under bridge):

> The sum of L1-locked balances plus L2-issued balances is
> preserved across any sequence of bridge transitions, modulo
> the explicit mint / burn rebates allowed by the deployment law
> set.

GENESIS_PLAN.md §7.6.5 (escrow consistency):

> For every withdrawal w pending on L2, the corresponding L1
> escrow entry exists and has not been consumed.  For every
> withdrawal w consumed on L2, the corresponding L1 escrow
> entry has been claimed.

Both identities are *chain-level*: they quantify over a sequence
of states linked by admissible bridge transitions.  Today, the
per-action deltas hold (verified per-step) but the chain-level
identity is ratified by the cross-stack corpus (which exhibits
the identity holding across recorded chains, not by Lean
theorem).

### §2.2 Why this needs a custom reachability predicate

The kernel's existing `Reachable` predicate quantifies over
*any* admissible transition.  A `Reachable s s'` chain may
include actions that are not bridge-relevant (e.g. pure
intra-L2 transfers) and which do not affect L1 escrow.  The
supply/escrow identities still hold for arbitrary `Reachable`
chains, but the proof would require case-splitting on every
action constructor (~30 cases including all the kernel laws).

`BridgeReachable` restricts to the bridge-relevant subset (~6
constructors).  Case-splits are tractable; reviewers can audit
each arm; the resulting theorem is structurally clean.

### §2.3 The induction principle

```lean
inductive BridgeReachable : ExtendedState → ExtendedState → Prop where
  | refl : ∀ s, BridgeReachable s s
  | step : ∀ {s s' s''} (action : BridgeAction)
              (hpre : action.pre s) (hstep : step_impl action.toTransition hpre s = .ok s'),
              BridgeReachable s' s'' → BridgeReachable s s''
```

where `BridgeAction` is an inductive enumeration of bridge-
relevant `Action` constructors (a Lean-level type, not a wire
extension):

```lean
inductive BridgeAction where
  | deposit (params : DepositParams)
  | withdraw (params : WithdrawParams)
  | bridgeRegisterIdentity (params : RegisterParams)
  | bridgeReplaceKey (params : ReplaceParams)
  | bridgeReward (params : RewardParams)
  | bridgeRefund (params : RefundParams)
```

(Exact list depends on the action set; CA.1 enumerates by
reading `LegalKernel/Authority/Action.lean` and selecting
every constructor whose admissibility predicate touches
`BridgeState`.)

The standard induction principle is generated by Lean's `derive`
machinery.  Inversion lemmas:
  - `bridge_reachable_inv_refl : BridgeReachable s s → True`
    (trivial; `refl` is one constructor).
  - `bridge_reachable_inv_step : BridgeReachable s s'' →
    s = s'' ∨ ∃ s' action hpre hstep r, …`.

### §2.4 The chain-supply identity

```lean
def bridgeSupplySum (s : ExtendedState) : Nat :=
  s.bridge.l1Escrow.totalLocked + s.state.balances.totalSupply

theorem bridge_chain_supply_preserved
    (h : BridgeReachable s s') :
  bridgeSupplySum s = bridgeSupplySum s' + bridgeRebates s s'
```

where `bridgeRebates s s'` is the cumulative mint/burn delta
from the deployment law set's explicit rebate machinery
(zero if the deployment has no rebate laws).

Proof: induction on `BridgeReachable`.
  - Base case (`refl`): `bridgeRebates s s = 0` (also a small
    lemma); LHS = RHS.
  - Inductive step: by `bridge_action_delta_supply` (the per-
    action lemma for the specific `BridgeAction`), the supply
    changes by exactly the rebate delta for that action; sum
    accumulates across the chain.

### §2.5 The escrow-consistency identity

```lean
def l1EscrowMatchesL2 (s : ExtendedState) : Prop :=
  (∀ w ∈ s.bridge.pending,
     ∃ e ∈ s.bridge.l1Escrow.entries,
       e.withdrawalId = w.id ∧ ¬ e.claimed) ∧
  (∀ d ∈ s.bridge.consumed,
     ∃ e ∈ s.bridge.l1Escrow.entries,
       e.depositId = d ∧ e.claimed)

theorem bridge_chain_escrow_invariant
    (h_init : l1EscrowMatchesL2 s)
    (h_chain : BridgeReachable s s') :
  l1EscrowMatchesL2 s'
```

Read: the L1-L2 escrow invariant is preserved across any
`BridgeReachable` chain.  Initial assumption `h_init` requires
the genesis state satisfy the invariant; deployment-level
proof obligation.

Proof: induction on `BridgeReachable`.  Each per-action delta
lemma either:
  - Adds a `pending` entry and a corresponding non-claimed
    `l1Escrow` entry (the deposit-/withdraw-initiate cases).
  - Moves a `pending` entry to `consumed` and marks the
    `l1Escrow` entry claimed (the deposit-/withdraw-finalise
    cases).
  - Leaves both unchanged (the register-identity / replace-key
    cases).

The invariant is preserved arm-by-arm.

## §3 Work-unit dependencies

```
CA.1 (BridgeReachable + BridgeAction)
   │
   ├──► CA.2 (supply-preservation theorem)
   │
   └──► CA.3 (escrow-consistency theorem)
```

CA.1 is the structural setup; CA.2 and CA.3 may land in either
order or in parallel after CA.1.

## §4 Work-unit specifications

---

### CA.1 — `BridgeReachable` predicate and `BridgeAction` enumeration

**Finding map.**  m-16 prerequisite.

**Scope.**  `LegalKernel/Bridge/Reachable.lean` (new).

**CA.1 decomposes into four sub-sub-units:**

  * **CA.1.a** — Bridge-action enumeration audit + `BridgeAction`
    inductive.
  * **CA.1.b** — `BridgeReachable` predicate + auto-generated
    induction principle.
  * **CA.1.c** — Ergonomic lemmas (`refl`, `trans`,
    `BridgeAction.toAction_injective`).
  * **CA.1.d** — `BridgeReachable_implies_Reachable` embedding
    lemma.

#### CA.1.a — Bridge-action enumeration

**Activity.**

  1. Read `LegalKernel/Authority/Action.lean` exhaustively.
    For each `Action` constructor, decide whether it
    touches `BridgeState` (consumed / pending / escrow).
  2. Catalogue:
     - **Bridge-relevant** (target enumeration): `deposit`,
       `withdraw`, `bridgeRegisterIdentity`,
       `bridgeReplaceKey`, `bridgeReward`, `bridgeRefund`.
       (The exact list depends on the action set; the
       canonical reference is the AR.5 regression-pin table
       in `LegalKernel/Test/Authority/Action.lean`.)
     - **Non-bridge** (out of enumeration): `transfer`,
       `mint`, `burn`, `freeze`, etc.
  3. For each *bridge-relevant* constructor, confirm via
    inspection that its `apply` body writes only to
    `BridgeState` and possibly `state.balances` (the L2 reflection of an
    escrow change).
  4. Document the catalogue in `Reachable.lean`'s module
    docstring so future reviewers can re-audit cheaply when
    new actions land.

**Acceptance criteria.**

  * Catalogue documented.
  * No false negatives (every bridge-touching action is in
    `BridgeAction`).

**Risk.**  Medium.  False negatives are the load-bearing
risk: if a bridge-touching action is omitted from
`BridgeAction`, the `BridgeReachable` quantification is too
narrow and the chain-level theorem becomes vacuously stronger
(false-secure).  Mitigation: reviewer must re-audit the
catalogue.

**Effort.**  ~0.5 engineer-day.

#### CA.1.b — `BridgeReachable` predicate

**Math.**

```lean
inductive BridgeAction where
  | deposit             (params : DepositParams)
  | withdraw            (params : WithdrawParams)
  | bridgeRegisterIdentity (params : RegisterParams)
  | bridgeReplaceKey    (params : ReplaceKeyParams)
  | bridgeReward        (params : RewardParams)
  | bridgeRefund        (params : RefundParams)
  deriving Repr

def BridgeAction.toAction : BridgeAction → Action
  | .deposit p            => Action.deposit p
  | .withdraw p           => Action.withdraw p
  | .bridgeRegisterIdentity p => Action.bridgeRegisterIdentity p
  | .bridgeReplaceKey p   => Action.bridgeReplaceKey p
  | .bridgeReward p       => Action.bridgeReward p
  | .bridgeRefund p       => Action.bridgeRefund p

def BridgeAction.pre (a : BridgeAction) (s : ExtendedState) : Prop :=
  a.toAction.pre s

inductive BridgeReachable : ExtendedState → ExtendedState → Prop where
  | refl  : ∀ s, BridgeReachable s s
  | step  : ∀ {s s' s''} (a : BridgeAction)
              (hpre : a.pre s)
              (hstep : step_impl (a.toAction.toTransition) hpre s = .ok s'),
              BridgeReachable s' s'' → BridgeReachable s s''
```

**Implementation steps.**

  1. Create `LegalKernel/Bridge/Reachable.lean`.
  2. Define `BridgeAction`, `toAction`, `pre`, `BridgeReachable`.
  3. Lean auto-generates the induction principle.

**Acceptance criteria.**

  * Module builds.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### CA.1.c — Ergonomic lemmas

**Implementation steps.**

  1. `BridgeAction.toAction_injective`: trivially proved by
    `cases` on both `BridgeAction`s; 6 × 6 = 36 cases (30
    via constructor-tag mismatch, 6 via param injectivity).
  2. `BridgeReachable.trans`: induction on the second
    `BridgeReachable`.
  3. The `refl` constructor is already in the inductive.

**Acceptance criteria.**

  * All three lemmas ship.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### CA.1.d — `BridgeReachable_implies_Reachable`

**Math.**

```lean
theorem BridgeReachable_implies_Reachable :
  ∀ {s s'}, BridgeReachable s s' → Reachable s s'
```

**Proof structure.**  Induction on `BridgeReachable`:
  - Base case: `refl s` lifts to `Reachable.refl s`.
  - Inductive step: a `BridgeAction.step` is also a `Reachable.step`
    (the embedding is along `BridgeAction.toAction`).

**Acceptance criteria.**

  * Theorem ships; `#print axioms` clean.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

---

### CA.1 — Rolled-up

  * CA.1.a – CA.1.d all individually accepted.
  * **Aggregate effort:** ~2 engineer-days (matches prior).

---

### CA.2 — `bridge_chain_supply_preserved`

**Finding map.**  Closes §7.6.4 chain-level identity (m-16).

**Scope.**  `LegalKernel/Bridge/Accounting.lean`.

**CA.2 decomposes into four sub-sub-units:**

  * **CA.2.a** — `bridgeSupplySum` definition + arithmetic
    properties.
  * **CA.2.b** — `bridgeRebates` definition + base-case lemma.
  * **CA.2.c** — Headline theorem (induction over `BridgeReachable`).
  * **CA.2.d** — Docstring update + `Accounting.lean:255`
    comment retirement.

#### CA.2.a — `bridgeSupplySum`

**Math.**

```lean
def bridgeSupplySum (s : ExtendedState) : Nat :=
  s.bridge.l1Escrow.totalLocked + s.state.balances.totalSupply
```

The first summand is the total of L1-locked funds (escrow
side); the second is the total of L2-issued balances.  The
sum is the conserved quantity (modulo explicit
mint/burn rebates).

**Implementation steps.**

  1. Define `bridgeSupplySum`.
  2. Prove `bridgeSupplySum_nonneg` (trivial; both summands
    are `Nat`).
  3. Prove `bridgeSupplySum_setBalance` (the change-on-setBalance
    lemma; standard structural lemma).

**Acceptance criteria.**

  * Definition + auxiliary lemmas ship.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### CA.2.b — `bridgeRebates`

**Math.**

```lean
def bridgeRebates (s s' : ExtendedState) : Int := …
```

`bridgeRebates s s'` accounts for any explicit mint/burn
delta authorised by the deployment law set's rebate
machinery.  For a zero-rebate deployment, `bridgeRebates s s' = 0`
for all pairs.

**Implementation steps.**

  1. Define `bridgeRebates` recursively over a `BridgeReachable`
    chain.  Alternative: define as a "ghost" sum that the
    chain-induction accumulates explicitly.  Both work; the
    recursive form is cleaner.
  2. `bridgeRebates_refl : bridgeRebates s s = 0`.
  3. `bridgeRebates_trans : bridgeRebates s s' + bridgeRebates s' s'' = bridgeRebates s s''`
    (under associated chains).

**Acceptance criteria.**

  * Definition + auxiliary lemmas ship.

**Risk.**  Medium.  Rebate accounting must match the
deployment law set's actual semantics — a sloppy definition
would let the theorem prove a false claim (e.g. a deployment
with hidden rebates passes when it shouldn't).

**Effort.**  ~1 engineer-day.

#### CA.2.c — Headline theorem

**Math.**

```lean
theorem bridge_chain_supply_preserved
    {s s' : ExtendedState}
    (h_chain : BridgeReachable s s') :
  bridgeSupplySum s = bridgeSupplySum s' + bridgeRebates s s'
```

**Proof structure.**

  * **Base case** (`refl`): `bridgeRebates s s = 0` (by CA.2.b),
    so `bridgeSupplySum s = bridgeSupplySum s + 0` trivially.
  * **Inductive step** (`step a hpre hstep h_rest`):
    1. By the per-action delta lemma for `a` (already
      shipped in `Accounting.lean`), `bridgeSupplySum s' =
      bridgeSupplySum s + bridgeRebateDelta a`.
    2. By induction hypothesis on `h_rest`,
      `bridgeSupplySum s' = bridgeSupplySum s'' +
      bridgeRebates s' s''`.
    3. Sum: `bridgeSupplySum s = bridgeSupplySum s'' +
      bridgeRebates s' s'' - bridgeRebateDelta a`.
    4. By definition of `bridgeRebates s s''` (its recursive
      definition unfolds to `bridgeRebateDelta a +
      bridgeRebates s' s''`), substitute to conclude.

**Implementation steps.**

  1. State the theorem.
  2. `induction h_chain`.
  3. **Inductive case-split.**  In the step case, case-split
    on the `BridgeAction` to invoke the right per-action
    delta lemma (`deposit_delta`, `withdraw_delta`, etc.).

**Reviewer checklist.**

  * Inductive case-split is *exhaustive* (every `BridgeAction`
    constructor handled — six arms).
  * Per-action delta lemmas cited by name in each arm.

**Effort.**  ~1.5 engineer-days.

#### CA.2.d — Docstring + comment retirement

**Implementation steps.**

  1. Update `Bridge/Accounting.lean`'s module docstring to
    cite the new theorem.
  2. Remove the comment at line 255 ("plan's existing
    'deferred' provisions for cross-stack verification") and
    replace with a content-describing line referencing the
    theorem.
  3. Update CLAUDE.md "Workstream E-C" status to remove the
    "chain-level §7.6.4 follow-up" note.

**Acceptance criteria.**

  * Line 255 deferral comment removed.
  * Cross-references resolved.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

---

### CA.2 — Rolled-up

  * CA.2.a – CA.2.d all individually accepted.
  * **Aggregate effort:** ~3.5 engineer-days (revised up from
    2; the rebate-accounting design surfaced more scope than
    the original lump estimate).

---

### CA.3 — `bridge_chain_escrow_invariant`

**Finding map.**  Closes §7.6.5 chain-level identity (m-16).

**Scope.**  `LegalKernel/Bridge/Accounting.lean`,
`LegalKernel/Bridge/L1Escrow.lean` (may need creation if the
type doesn't exist).

**CA.3 decomposes into five sub-sub-units:**

  * **CA.3.a** — `L1EscrowLedger` type (audit if existing).
  * **CA.3.b** — `l1EscrowMatchesL2` predicate.
  * **CA.3.c** — Per-action preservation lemmas.
  * **CA.3.d** — Headline theorem (induction).
  * **CA.3.e** — `genesis_satisfies_escrow` + integration
    docs.

#### CA.3.a — `L1EscrowLedger` audit

**Activity.**

  1. Grep the codebase for an existing `L1EscrowLedger`
    type:
     ```bash
     grep -rn "L1EscrowLedger\|l1Escrow" LegalKernel/
     ```
  2. If the type is already shipped under
    `LegalKernel/Bridge/`, audit its fields and constructor
    set.  Likely fields: `entries : List EscrowEntry`,
    `totalLocked : Nat`.
  3. If absent, create
    `LegalKernel/Bridge/L1Escrow.lean` with a minimal
    deployment-supplied witness shape:
     ```lean
     structure EscrowEntry where
       depositId    : DepositId
       withdrawalId : Option WithdrawalId
       amount       : Amount
       claimed      : Bool
       deriving Repr, DecidableEq

     structure L1EscrowLedger where
       entries     : List EscrowEntry
       totalLocked : Nat
       deriving Repr
     ```
     plus a structural invariant
     `(∀ e ∈ entries, e.claimed → e.amount ≤ totalLocked)`.
  4. **Note:** this is *deployment-supplied semantics*, not a
    new opaque.  The kernel does not interpret L1 state; the
    type captures what the bridge contract maintains.

**Acceptance criteria.**

  * Type definition stable (existing or new).
  * No new opaque introduced.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### CA.3.b — `l1EscrowMatchesL2`

**Math.**

```lean
def l1EscrowMatchesL2 (s : ExtendedState) : Prop :=
  -- Every pending L2 withdrawal corresponds to an unclaimed
  -- L1 escrow entry.
  (∀ w ∈ s.bridge.pending,
     ∃ e ∈ s.bridge.l1Escrow.entries,
       e.withdrawalId = some w.id ∧ ¬ e.claimed)
  ∧
  -- Every consumed L2 deposit corresponds to a claimed
  -- L1 escrow entry.
  (∀ d ∈ s.bridge.consumed,
     ∃ e ∈ s.bridge.l1Escrow.entries,
       e.depositId = d ∧ e.claimed)
```

**Implementation steps.**

  1. Define `l1EscrowMatchesL2`.
  2. Prove auxiliary lemmas: `l1EscrowMatchesL2_decidable`
    (the predicate is decidable for any concrete state because
    `bridge.pending`/`bridge.consumed` are finite).

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### CA.3.c — Per-action preservation lemmas

**Math.**  For each `BridgeAction` constructor, prove a
preservation lemma:

```lean
theorem bridge_action_preserves_escrow
    (a : BridgeAction) (s s' : ExtendedState)
    (hpre : a.pre s) (hstep : step_impl a.toAction.toTransition hpre s = .ok s')
    (h_inv : l1EscrowMatchesL2 s) :
  l1EscrowMatchesL2 s'
```

**Per-action discharge.**

  * **`deposit`**: adds a `consumed` entry; corresponding
    `EscrowEntry` already exists with `claimed = false` (the
    L1 side locked funds); update to `claimed = true`.
    Preserves both conjuncts.
  * **`withdraw`** (initiate): adds a `pending` entry; the
    L1 side creates a new `EscrowEntry` with
    `withdrawalId = some w.id, claimed = false`.  Preserves
    both conjuncts.
  * **`withdraw`** (finalise): moves a `pending` entry to
    "consumed-via-withdrawal"; L1 marks the corresponding
    entry `claimed = true`.  Preserves.
  * **`bridgeRegisterIdentity` / `bridgeReplaceKey`** : do
    not touch `bridge.pending` / `bridge.consumed` /
    `l1Escrow`.  Vacuously preserve.
  * **`bridgeReward` / `bridgeRefund`** : refund moves an
    L1 escrow entry back to `claimed = false`; reward is a
    no-op on escrow.  Both preserve.

**Implementation steps.**

  1. State and prove each per-action preservation lemma.
  2. Each proof is a structural case-split over the action's
    `apply` body.

**Reviewer checklist.**

  * Every `BridgeAction` arm has a corresponding preservation
    lemma.
  * Each lemma's proof unfolds the action's `apply` body
    explicitly.

**Risk.**  Medium.  This is where the proof effort
concentrates.

**Effort.**  ~1.5 engineer-days.

#### CA.3.d — Headline theorem

**Math.**

```lean
theorem bridge_chain_escrow_invariant
    (h_init : l1EscrowMatchesL2 s)
    (h_chain : BridgeReachable s s') :
  l1EscrowMatchesL2 s'
```

**Proof.**  Induction on `h_chain`:
  * Base case (`refl`): `h_init` directly.
  * Inductive step: by CA.3.c per-action preservation +
    induction hypothesis.

**Effort.**  ~0.5 engineer-day.

#### CA.3.e — `genesis_satisfies_escrow` + integration

**Math.**

```lean
theorem genesis_satisfies_escrow (s : ExtendedState)
    (h_genesis : isGenesis s) :
  l1EscrowMatchesL2 s
```

**Proof.**  At genesis, both `bridge.pending = ∅` and
`bridge.consumed = ∅`, so the universal quantifiers are
vacuously true.

**Implementation steps.**

  1. State and prove the lemma.
  2. Add a CLAUDE.md / GENESIS_PLAN.md update note for §7.6.5.
  3. Update `audit_remediation_plan.md` m-16 status.
  4. Update `docs/audits/19-findings-and-followups.md` "Open
    follow-ups".

**Effort.**  ~0.5 engineer-day.

---

### CA.3 — Rolled-up

  * CA.3.a – CA.3.e all individually accepted.
  * **Aggregate effort:** ~3.5 engineer-days (revised up from
    3; the per-action discharge step is where the actual work
    sits).

---

## §5 Sequencing and PR structure

```
PR-1: CA.1     BridgeReachable predicate + embedding lemma
PR-2: CA.2     Supply-preservation theorem
PR-3: CA.3     Escrow-consistency theorem + m-16 closure
```

CA.1 first.  CA.2 and CA.3 parallel.  The last PR to land
should also:
  - Update `docs/planning/audit_remediation_plan.md` §2 to mark m-16
    "Remediated under workstream CA".
  - Update `docs/audits/19-findings-and-followups.md` "Open
    follow-ups" to remove m-16.
  - Update CLAUDE.md status note for Workstream E-C from
    "chain-level §7.6.4 / §7.6.5 follow-up" to "Complete".

## §6 Quality gates

  * `lake build LegalKernel.Bridge.*`
  * `lake test`
  * `lake exe count_sorries`
  * `lake exe tcb_audit`
  * `lake exe deferral_audit` (the
    `Accounting.lean:255` comment removal must not introduce
    a new forbidden phrase)

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Bridge action set incomplete in CA.1 | Medium | High | Read every `Action` constructor; add a one-line comment per skipped non-bridge action documenting why it's skipped |
| `bridgeRebates` definition admits unsoundness if the deployment law set has unexpected rebate semantics | Low | High | Default zero-rebate; document the deployment-level proof obligation |
| `L1EscrowLedger` shape not yet defined as a Lean type | Medium | Medium | CA.3 introduces a deployment-supplied witness shape under `Bridge/L1Escrow.lean`; cross-stack corpus validates the shape |
| Theorem statements drift from the GENESIS_PLAN §7.6.4 / §7.6.5 wording | Medium | Low | Reviewer cross-checks the statement against the GENESIS_PLAN section text |

## §8 Acceptance criteria

CA is **complete** when:

  1. `BridgeReachable`, `BridgeAction`, and the embedding
    lemma ship in `Bridge/Reachable.lean`.
  2. `bridge_chain_supply_preserved` ships in
    `Bridge/Accounting.lean`.
  3. `bridge_chain_escrow_invariant` ships in
    `Bridge/Accounting.lean`.
  4. m-16 retired across:
     - `docs/planning/audit_remediation_plan.md` §2 triage table
     - `docs/audits/19-findings-and-followups.md` open follow-
       ups list
     - `LegalKernel/Bridge/Accounting.lean:255` comment
     - CLAUDE.md "Workstream E-C" status (drop the "chain-level
       §7.6.4 / §7.6.5 follow-up" note)
  5. `#print axioms` on each new theorem prints a subset of
    `[propext, Classical.choice, Quot.sound]`.
  6. CLAUDE.md "Headline theorems" table adds two rows
    for the new theorems.

## §9 Out-of-scope items

  * **Cross-actor escrow accounting** (multiple withdrawing
    actors sharing a single L1 escrow entry).  v2 concern;
    current MVP is one-actor-per-entry.
  * **Multi-resource escrow accounting** (a single L1 escrow
    locking multiple ResourceIds).  MVP is one resource per
    entry.
  * **L1-side proof of the escrow identity.**  CA proves the
    Lean side; the Solidity bridge contract is responsible
    for the L1 side and is validated by the cross-stack corpus.
  * **`Reachable`-level theorem variants** (i.e. the same
    identities for arbitrary `Reachable` chains).  CA's
    `BridgeReachable_implies_Reachable` lift is sufficient
    for any downstream consumer that wants the broader
    quantification.

## §10 References

  * `docs/GENESIS_PLAN.md` §7.6.4 and §7.6.5 (the identities
    CA mechanises).
  * `docs/planning/ethereum_integration_plan.md` §C (per-action bridge
    deltas).
  * `docs/planning/audit_remediation_plan.md` §2 (m-16 triage).
  * `docs/audits/19-findings-and-followups.md` (m-16 description).
  * `LegalKernel/Bridge/Accounting.lean` — current per-action
    deltas.
  * `LegalKernel/Bridge/Admissible.lean` — per-action
    admissibility lemmas.
  * `LegalKernel/Kernel.lean` §4.9 — existing `Reachable`
    predicate.

---

**End of plan.**  Landing CA retires the only "Defer / n/a"
entry in the AR triage table.
