<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Parameterized Laws (Workstream PA) — Engineering Plan

This document plans the engineering effort needed to add a
**deployment-wide, quorum-vote-mutable `Parameters` table** to
Knomosis.  It is a roadmap, not a specification; the formal design
will be promoted into a Genesis-Plan amendment once the work-unit
set lands.

The motivating observation is that some kernel-level constants
(dispute window, dispute stake) and admissibility limits
(transfer / mint caps) should be community-tunable across a
deployment's lifetime without requiring a binary upgrade.
Parameterized laws give every node uniform access to the
*current* tuning values via a new `parameters : Parameters` field
in `ExtendedState`; mutation is gated by a quorum of governance-
signer signatures with a kernel-level validity safety net.

PA composes with **Workstream LP (Actor-Scoped Policies)** at the
admissibility layer: each action must satisfy *both* the actor's
declared `LocalPolicy` *and* the deployment-wide `Parameters`
constraints.  Together the two workstreams realise the
"actors customise their own behaviour + the community votes on
shared parameters" architecture recommended by the law-voting
analysis.

## Status

  * **Drafted on branch:** `claude/add-law-voting-0jBAh`.
  * **Phase prefix:** `PA` (Parameters) — work units labelled
    `PA.1` … `PA.10` to disambiguate from the Genesis-Plan
    `Phase 1`/`Phase 2`/… numbering, from the Ethereum-integration
    `A` / `B` / `C` / `D` workstream prefixes, and from the LP
    workstream prefix.  PA is parallel to, not a successor of,
    the Genesis-Plan Phase 7.
  * **Dependency on LP.**  PA strictly extends the post-LP state.
    PA.1's `Parameters` field appends to `ExtendedState` *after*
    LP's `localPolicies` field; PA's admissibility conjuncts
    extend LP's; PA's `Action.applyParameterChange` constructor
    is appended at frozen index 17 (after LP's 15, 16).  PA may
    land in a separate PR after LP, or in the same PR as LP; in
    either case LP must be merged before PA's tests can run
    green.  See `docs/planning/actor_scoped_policies_plan.md` for the LP
    plan.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`, and
    `lake exe stub_audit` all green throughout; **no new sorries**;
    **no new axioms**; **no expansion of the kernel TCB**; no new
    `opaque` declarations.
  * **TCB delta:** zero.  Every new module ships under
    `LegalKernel/Authority/`, `LegalKernel/Encoding/`,
    `LegalKernel/Events/`, `LegalKernel/Parameters/`, or as
    additive amendments to existing non-TCB modules
    (`Bridge/Finalisation.lean`, `Disputes/Staking.lean`); none
    touches `Kernel.lean` or `RBMapLemmas.lean`.
  * **Trust-assumption delta:** zero.  The `Verify` opaque is
    unchanged; `hashBytes` is unchanged; no new cryptographic
    primitives are introduced.  Every new admissibility conjunct
    is a pure decidable predicate over first-order data already
    in `ExtendedState`.
  * **Backwards-compat delta:** the new `parameters` field of
    `ExtendedState` defaults to `Parameters.empty`, so every
    pre-PA construction continues to elaborate.  The new
    admissibility conjuncts reduce definitionally to `True`
    whenever no relevant cap is set and the action is not
    `applyParameterChange`.  Existing admissibility witnesses
    gain trivially-discharged conjuncts.
  * **Frozen indices reserved by this workstream:**
    `Action.applyParameterChange` at index 17;
    `Event.parametersChanged` at index 13.

## §1 Goals and non-goals

### 1.1 What this plan delivers

After PA lands on top of LP, the following is true:

  1. `ExtendedState` carries a `parameters : Parameters` field —
     a structured record of deployment-wide tunable values
     (quorum threshold, governance signer set, optional
     transfer / mint caps, dispute window, dispute stake).
  2. The `parameters` field is mutated only via signed
     `Action.applyParameterChange { newParams, signers, sigs }`
     actions whose admissibility requires **both** (a) a quorum
     of governance-signer signatures over the proposed parameters
     **and** (b) the proposed parameters to satisfy a kernel-
     level validity predicate.  No other action ever touches
     `parameters`.
  3. Two new admissibility conjuncts (conjuncts 7 and 8 in the
     post-LP-post-PA `AdmissibleWith`) check parameter-driven
     constraints uniformly:

       * **Conjunct 7 (`parametersPermit`).**  Per-action surface
         constraints — e.g., `transfer.amount ≤
         parameters.maxTransferAmount` when the cap is set.
       * **Conjunct 8 (`parameterActionAdmissibleWith`).**
         Governance gate — for `applyParameterChange` actions,
         the quorum is met and the new parameters are valid;
         for other actions, vacuously `True`.

  4. Both conjuncts strictly **narrow** admissibility (they
     never admit an action that wasn't admissible pre-PA).  In a
     deployment with default `Parameters` (no caps set) and no
     `applyParameterChange` actions in the log, post-PA
     admissibility is byte-for-byte indistinguishable from the
     pre-PA admissibility predicate.
  5. The kernel-level validity predicate `Parameters.valid` is
     the safety net: even a colluding majority quorum cannot
     install a state with `quorumThreshold = 0`,
     `quorumThreshold > governanceSigners.length`,
     `disputeWindowBlocks = 0`, or duplicate
     `governanceSigners`.  These are rejected before
     `applyActionToParameters` can run.
  6. Replay protection survives unchanged: each
     `applyParameterChange` action carries a per-actor nonce in
     its `SignedAction` envelope; the existing
     `replay_impossible` theorem applies verbatim.
  7. `Parameters.encode` / `Parameters.decode` extend the CBE
     codec with full round-trip + injectivity proofs.  The
     `ExtendedState` encoding gains a 6th appended segment
     (after the LP `localPolicies` segment).
  8. A new `Event.parametersChanged (oldP newP : Parameters)`
     event fires deterministically on every successful
     parameter change.
  9. Two existing modules — `Bridge/Finalisation.lean`
     (Workstream D.3) and `Disputes/Staking.lean` (Phase-6
     incentive amendment) — gain parameter-aware helpers that
     read their respective tunables (`disputeWindowBlocks`,
     `disputeStake`) from `es.parameters` rather than from
     explicit function arguments, so on-chain parameter changes
     take immediate effect at the runtime layer.  The pre-PA
     forms are preserved as additive companions; no existing
     theorem signature changes.
  10. The new action constructor is classified as both
      `IsConservative` and `IsMonotonic` (it compiles to
      `Laws.freezeResource 0`, like every other registry-/
      bridge-/policy-mutating action), so deployments using
      `ConservativeLawSet` / `MonotonicLawSet` invariants
      continue to get those invariants for free.

### 1.2 Composition with LP (the "three-pillar story")

A deployment combines three independent admissibility mechanisms:

  1. **Static deployment policy (`AuthorityPolicy`).**  Set at
     deployment time; immutable.  Coarse-grained "who may issue
     what."  Existing.
  2. **Per-actor self-imposed restrictions (`LocalPolicy`).**
     Each actor's voluntary further-narrowing.  Introduced by
     LP.
  3. **Deployment-wide vote-mutable parameters (`Parameters`).**
     Quorum-governed shared rules that bind every actor.
     Introduced by **this workstream (PA)**.

Each pillar can independently reject any action.  An action is
admissible iff all three (plus the existing nonce / signature /
kernel-pre conjuncts) permit it.  Decidability is preserved:
every conjunct is independently decidable and `Decidable
Admissible` derives mechanically.

### 1.3 Non-goals

This workstream **does not**:

  * **Add quadratic / token-weighted voting.**  Quorum is
    counted by distinct approved signers (mirroring
    `Disputes/Verdict.countVerifiedSignatures`); each
    governance signer contributes 1.  Stake-weighted variants
    are deferred to a follow-up workstream.
  * **Add a timelock / delayed activation.**  An admissible
    `applyParameterChange` action takes effect immediately on
    the next state advance.  Time-locked parameter changes
    (effective-at-block) are deferred.
  * **Add a two-stage propose-then-apply pipeline.**  The
    proposer collects signatures off-chain, then submits one
    combined `applyParameterChange` action.  On-chain proposal
    / discussion / amendment is a follow-up workstream.
  * **Permit partial parameter updates.**  An
    `applyParameterChange` action specifies the *full* new
    `Parameters` record.  Delta-style updates are deferred (see
    §14.2).
  * **Auto-bootstrap governance.**  `Parameters.empty` has
    empty `governanceSigners` and is invalid by
    `Parameters.valid`; deployments must seed governance at
    genesis (off-chain `ExtendedState` construction).  No
    one-shot bootstrap exception is provided.
  * **Provide cross-deployment parameter portability.**  Each
    deployment maintains its own `Parameters`; parameter values
    do not inherit across forks / migrations beyond what
    `CanonMigration` (Workstream E.5) already supports.
  * **Provide vote-weighted governance signers.**  Each signer
    is equivalent to every other in the quorum count.
    Federated weight schemes are deferred.
  * **Modify any kernel-TCB module.**  All work happens in
    non-TCB modules (`Authority/`, `Encoding/`, `Events/`,
    `Parameters/`, plus additive amendments to
    `Bridge/Finalisation.lean` and `Disputes/Staking.lean`).
  * **Change the on-disk log frame format.**  The new
    `Action.applyParameterChange` constructor extends the
    existing CBE codec at appended frozen index 17; old log
    frames remain decodable; new log frames decode under any
    post-PA build.
  * **Change the snapshot format incompatibly.**  The
    `Snapshot.encodedState` field's CBE encoding gains a new
    appended `parameters` segment (defaulting to
    `Parameters.empty` on pre-PA snapshots, which Lean's
    default-field handling accommodates).
  * **Affect transition semantics.**  Parameters bind
    *admissibility*, not the kernel `Transition`'s
    `apply_impl`.  An admitted `transfer` produces the same
    state advance regardless of `Parameters`; the parameters
    only affect *whether* the transfer is admitted in the
    first place.  See §8.4 for the rationale.

## §2 Architectural overview

### 2.1 Where this lives

PA's modules sit alongside LP's, with a strict dependency on LP
being merged first:

```
LegalKernel.Authority.LocalPolicy          (LP; prerequisite)
                                            ↓
LegalKernel.Authority.Parameters           (PA.1; new)
  ├── imports Kernel + Authority.Action
  └── exports Parameters, Parameters.valid, Parameters.empty

LegalKernel.Authority.Action               (extended in PA.4: 1 new ctor)
LegalKernel.Authority.Nonce                (extended in PA.3: 1 new field on ExtendedState)
LegalKernel.Authority.SignedAction         (extended in PA.5+PA.6)
                                            - applyActionToParameters helper
                                            - 2 new admissibility conjuncts
                                            - field extractors + mutation theorems

LegalKernel.Encoding.Parameters            (PA.2; new)
  ├── imports Authority.Parameters + Encoding.Encodable
  └── exports Encodable instance + roundtrip + injectivity + fieldsBounded

LegalKernel.Encoding.Action                (extended in PA.4: 1 new tag)
LegalKernel.Encoding.State                 (extended in PA.3: parameters in encode/decode)

LegalKernel.Parameters.LawClassification   (PA.7; new, mirroring
                                            Disputes/LawClassification.lean and
                                            LocalPolicy/LawClassification.lean)
  └── exports IsConservative + IsMonotonic instances for the new ctor

LegalKernel.Events.Types                   (extended in PA.8: 1 new ctor at frozen 13)
LegalKernel.Events.Extract                 (extended in PA.8: 1 new emission rule)

LegalKernel.Bridge.Finalisation            (extended in PA.5: parameter-aware helpers)
LegalKernel.Disputes.Staking               (extended in PA.6: parameter-aware helpers)
```

Every dependency edge points downward toward existing modules; no
existing module gains an edge into a new module beyond what
`LegalKernel.lean` already does for umbrella re-exports.

### 2.2 The user-visible model

The user-visible model is a single sentence:

> **A `Parameters` value lives in `ExtendedState`; only quorum-
> approved, validity-checked changes update it; admissibility
> consults it on every action.**

Every formal piece of this plan is a Lean restatement of that
sentence:

  * *"A `Parameters` value lives in `ExtendedState`"* — §3.
  * *"Only quorum-approved, validity-checked changes update
    it"* — §4–§6.
  * *"Admissibility consults it on every action"* — §7–§8.

### 2.3 Strict-narrowing invariant (overview)

The two new admissibility conjuncts compose by conjunction with
the existing five (post-LP six).  Each new conjunct is **vacuous**
in a default-configuration deployment:

  * Conjunct 7 (`parametersPermit`) is `True` for every action in
    a state where no parameter caps are set
    (`maxTransferAmount = none`, `maxMintAmount = none`).
  * Conjunct 8 (`parameterActionAdmissibleWith`) is `True` for
    every action other than `applyParameterChange`.

Therefore, in a deployment that:

  * Has empty `localPolicies` (no LP narrowing), AND
  * Has default `Parameters.empty` (or any state with
    `maxTransferAmount = none ∧ maxMintAmount = none`), AND
  * Sees no `applyParameterChange` actions,

the post-PA admissibility predicate is **byte-for-byte identical**
to the pre-LP-pre-PA admissibility predicate.  The
`admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`
theorem (§7.5) certifies this in Lean.

## §3 The `Parameters` data type

### 3.1 Field set (MVP)

```lean
/-- Deployment-wide vote-mutable parameter table.  Mutated only by
    admissible `Action.applyParameterChange` actions through
    `apply_admissible`; preserved by every other action.

    **Append-only field discipline.**  Adding a new field is a
    backwards-compatible extension iff the new field has a
    canonical default value (so `Parameters.empty` extends
    cleanly).  Removing or reordering fields is a breaking-
    encoding change and forbidden after the workstream lands.
    The CBE codec serialises fields in declaration order;
    reordering would silently break every persisted state.

    **Validity discipline.**  Every field has a documented valid
    range; the `Parameters.valid` predicate (§3.2) is the
    conjunction of per-field validity checks.  An
    `applyParameterChange` whose `newParams` violates
    `Parameters.valid` is inadmissible — even if the quorum
    approves.  This is the kernel-level safety net against
    governance attacks. -/
structure Parameters where
  /-- Quorum threshold for `applyParameterChange` actions: the
      number of distinct approved-signer signatures required to
      authorise a parameter change.  `Parameters.valid` requires
      `quorumThreshold > 0 ∧ quorumThreshold ≤
      governanceSigners.length`. -/
  quorumThreshold     : Nat
  /-- The set of actor IDs whose signatures count toward the
      quorum on parameter-change proposals.  May be empty in the
      `Parameters.empty` default; deployments seed it at
      genesis (off-chain `ExtendedState` construction).  Stored
      as a `List ActorId`; the `countParameterChangeSignatures`
      helper performs O(|signers| × |governanceSigners|)
      membership checks at admissibility-decision time. -/
  governanceSigners   : List ActorId
  /-- Optional deployment-wide cap on `Action.transfer` amounts.
      `none` = no cap (every transfer is admissible regardless of
      amount).  `some max` = transfer's `amount` field must be
      `≤ max` for admissibility.  Consumed by conjunct 7. -/
  maxTransferAmount   : Option Amount
  /-- Optional deployment-wide cap on `Action.mint` amounts.
      Same shape as `maxTransferAmount`. -/
  maxMintAmount       : Option Amount
  /-- Dispute window in L1 blocks
      (Workstream-D `Bridge.Finalisation`).  Consumed by
      `isFinalisedFromES`; PA.5 adds parameter-aware helpers in
      `Bridge/Finalisation.lean` that read this field from
      `es.parameters` rather than taking it as an explicit
      function argument.  `Parameters.valid` requires
      `disputeWindowBlocks > 0`.  Default: 7200 (≈ 1 day at
      12 s blocks, matching Workstream-D's pre-PA default). -/
  disputeWindowBlocks : Nat
  /-- Stake amount required for filing disputes via the
      Phase-6 incentive amendment's `StakingPolicy` (resource
      0 by convention).  Consumed by
      `Disputes/Staking.fileDisputeStakedFromES`; PA.6 adds
      parameter-aware helpers that read this field.  Default: 0
      (no stake required, matching pre-PA staking-disabled
      behaviour). -/
  disputeStake        : Amount
  deriving Repr, DecidableEq
```

The MVP set is deliberately small (six fields).  Each field
captures a real Knomosis tunable that previously lived as a
hard-coded constant or a function argument.  Future PRs append
new fields under the same append-only discipline (see §14.2
for candidate additions).

### 3.2 The validity predicate

```lean
/-- The kernel-level validity check for a `Parameters` value.
    An `applyParameterChange` action whose `newParams` fails
    `Parameters.valid` is inadmissible regardless of quorum
    approval.

    The check is deliberately *minimal*: it captures only those
    constraints that, if violated, would render some other
    invariant unreachable.  Per-deployment policy checks (e.g.
    "we don't want `quorumThreshold` to drop below 3 in
    production") belong in the deployment's `AuthorityPolicy`,
    not here.

    **Invariants captured:**

      * `quorumThreshold > 0`.  Otherwise the next
        `applyParameterChange` would succeed with zero
        signatures, defeating governance entirely.
      * `quorumThreshold ≤ governanceSigners.length`.
        Otherwise no proposal can ever pass (unreachable
        target — soft-bricks governance).
      * `disputeWindowBlocks > 0`.  A zero dispute window
        skips `isFinalised`'s adversary-action window,
        breaking Workstream-D finalisation soundness.
      * `governanceSigners` has no duplicates.  A duplicate
        would silently weight that signer twice in the
        per-signer-deduplicated quorum count (per-signer
        dedup short-circuits on the first occurrence; a
        duplicate could allow malicious vote inflation if
        we ever change the dedup rule).

    Returns `Bool` rather than `Prop` so callers can `decide`
    without explicit `Decidable` instance synthesis. -/
def Parameters.valid (p : Parameters) : Bool :=
  decide (p.quorumThreshold > 0)                                &&
  decide (p.quorumThreshold ≤ p.governanceSigners.length)       &&
  decide (p.disputeWindowBlocks > 0)                            &&
  decide (p.governanceSigners.Nodup)
```

The `List.Nodup` check is decidable by `List.decidableNodup`
(Lean core).  All four checks are pure Nat / List arithmetic;
`decide` composes via `Bool.and`.

The predicate is **monotonic in disclosure**: if `Parameters.valid
p₁ = true` and `p₂` agrees with `p₁` on the four constrained
fields, then `Parameters.valid p₂ = true`.  This means a parameter
change that updates only the unconstrained fields
(`maxTransferAmount`, `maxMintAmount`, `disputeStake`) preserves
validity automatically.

### 3.3 Default value

```lean
/-- The default `Parameters` value: governance is empty, no caps
    are set, dispute window = 7200 blocks, no dispute stake.
    `Parameters.empty.valid = false` (because empty
    `governanceSigners` violates `quorumThreshold ≤
    governanceSigners.length` for `quorumThreshold = 1`); this
    is **intentional** — deployments must explicitly seed
    governance at genesis via off-chain `ExtendedState`
    construction. -/
def Parameters.empty : Parameters where
  quorumThreshold     := 1
  governanceSigners   := []
  maxTransferAmount   := none
  maxMintAmount       := none
  disputeWindowBlocks := 7200
  disputeStake        := 0
```

**Theorem `Parameters.empty_invalid`**: `Parameters.empty.valid =
false`.  Proof: `decide (1 ≤ 0) = false`; the conjunction
short-circuits.

This theorem is deliberately a *positive* result: it
mechanically certifies that a deployment which boots from the
empty default cannot accept any `applyParameterChange` action
without first seeding governance off-chain.  The "off-chain
seeding" is a one-time deployment ceremony: the operator
constructs `ExtendedState` with non-empty `governanceSigners`
and a matching `quorumThreshold`, computes the genesis state
hash, and distributes the genesis state to all nodes.  This
mirrors how every Knomosis deployment seeds `KeyRegistry` and
per-resource initial balances today.

### 3.4 `ExtendedState` extension

```lean
structure ExtendedState where
  base          : State
  nonces        : NonceState
  registry      : KeyRegistry
  bridge        : Bridge.BridgeState         := Bridge.BridgeState.empty
  localPolicies : Authority.LocalPolicies    := Authority.LocalPolicies.empty
  /-- PA.3: deployment-wide vote-mutable parameter table.
      Defaults to `Parameters.empty` so pre-PA constructions
      keep elaborating without modification.  Mutated only by
      admissible `Action.applyParameterChange` actions through
      `apply_admissible`; preserved by every other admissibility
      path. -/
  parameters    : Parameters                 := Parameters.empty
  deriving Repr
```

The default-value handling exactly mirrors the LP `localPolicies`
field's pattern (which itself mirrors Workstream-C's `bridge`
field).  Lean's record-update syntax preserves unmentioned fields
by construction.

`ExtendedState.empty` is updated:

```lean
def ExtendedState.empty : ExtendedState where
  base          := genesisState
  nonces        := NonceState.empty
  registry      := KeyRegistry.empty
  bridge        := Bridge.BridgeState.empty
  localPolicies := Authority.LocalPolicies.empty
  parameters    := Parameters.empty
```

### 3.5 Encoding extension

The CBE encoding for `ExtendedState` becomes (post-LP-post-PA):

```
ExtendedState.encode es :=
  State.encode es.base
    ++ NonceState.encode es.nonces
    ++ KeyRegistry.encodeMap es.registry
    ++ Bridge.BridgeState.encode es.bridge
    ++ Authority.LocalPolicies.encodeMap es.localPolicies
    ++ Parameters.encode es.parameters
```

`Parameters.encode` follows the existing flat-record pattern:

```
Parameters.encode p :=
  encode p.quorumThreshold ++          -- via Nat instance
  encode p.governanceSigners ++        -- via List Nat instance
  encode p.maxTransferAmount ++        -- via Option Nat instance
  encode p.maxMintAmount ++
  encode p.disputeWindowBlocks ++
  encode p.disputeStake
```

Round-trip (`Parameters.encode_decode`) and injectivity
(`Parameters.encode_injective`) follow from per-field
`Encodable` round-trip / injectivity instances + the standard
`List.append_inj` pattern (the same shape as Phase-3 / Phase-4
record-encoding proofs).  Determinism is structural (extensional
on `Repr`).

### 3.6 Pre-PA snapshot tolerance

The `ExtendedState.decode` function uses the same tolerant-tail
strategy as LP.3: a successful 5-segment decode followed by zero
or more remaining bytes triggers default-value fill-in for the
absent 6th segment.

**Theorem `extendedState_decode_pre_PA_compatible`**: decoding a
byte sequence produced by the post-LP-pre-PA encoder against the
post-PA decoder yields an `ExtendedState` whose `parameters` is
`Parameters.empty` and whose other five fields agree with the
pre-PA decoder's output.  Proven by induction on the five pre-PA
segments.

The combination of LP and PA tolerance gives a **graceful
upgrade staircase**: a pre-LP snapshot decodes under PA with
both `localPolicies = empty` and `parameters = empty`; a
post-LP-pre-PA snapshot decodes with `parameters = empty`; a
post-PA snapshot decodes verbatim.  Each upgrade is forward-
compatible with the prior wire format.

## §4 The `Action.applyParameterChange` constructor

### 4.1 Frozen-index assignment

`Action` (post-LP) ends with `revokeLocalPolicy` at index 16.  PA.4
appends one new constructor:

| Tag | Constructor              | Fields                                                      |
|-----|--------------------------|-------------------------------------------------------------|
| 17  | `applyParameterChange`   | `newParams : Parameters`, `signers : List ActorId`, `sigs : List Signature` |

This index is reserved by this plan and **MUST NOT** be used by
any concurrent workstream.  The `LegalKernel/Authority/Action.lean`
docstring's "constructor-ordering policy (append-only)" applies.

### 4.2 Constructor declaration

```lean
inductive Action
  -- ... existing constructors 0..16 (LP added 15, 16) ...
  /-- PA.4: apply a deployment-wide parameter change.  The
      action carries the full proposed `Parameters` record plus
      a parallel pair of approval signatures (signer IDs +
      signatures).  Admissibility (conjunct 8) requires:

        * `newParams.valid = true` (kernel-level safety net).
        * The count of distinct approved-signer verified
          signatures is ≥ `es.parameters.quorumThreshold`.
        * The signatures are over
          `signingInputForParameterChange newParams deploymentId`
          (a CBE-encoded canonical form domain-separated from
          `signingInput` and `verdictSigningInput`).

      Compiles to `Laws.freezeResource 0` (kernel-level no-op);
      the authority-level effect (`parameters` table replacement)
      happens in `applyActionToParameters` inside
      `apply_admissible`.

      Frozen index 17. -/
  | applyParameterChange (newParams : Parameters)
                         (signers   : List ActorId)
                         (sigs      : List Signature)
```

Signed by *some* proposer (the `SignedAction.signer` field), who
need not be a governance signer themselves — the proposer's role
is to bundle the off-chain-collected approval signatures into one
on-chain action.  The proposer's nonce is consumed normally; the
governance signatures are checked separately against
`es.parameters.governanceSigners`.

Note: the proposer's `LocalPolicy` (if any) is consulted via LP
conjunct 6.  An actor whose `LocalPolicy` denies tag 17 cannot
serve as a proposer; the deployment can encourage proposer
diversity by using `AuthorityPolicy.singleton` to authorise
specific proposers.

### 4.3 Compilation to `Transition`

The new constructor compiles to `Laws.freezeResource 0`,
mirroring `replaceKey`, `registerIdentity`,
`declareLocalPolicy`, and `revokeLocalPolicy`:

```lean
def Action.compileTransition : Action → Transition
  -- ... existing 17 cases (16 + LP's 2) ...
  | .applyParameterChange _ _ _ => Laws.freezeResource 0
```

The kernel-level state advance is the identity on `State`; the
authority-level mutation lives entirely in
`applyActionToParameters` (§6).

### 4.4 `compile_injective` extension

The headline `Action.compile_injective` theorem
(`Authority/Action.lean`, §4.13 via `CompiledAction.source`) is
*structural*: distinct `Action` values produce distinct
`CompiledAction` values via the `source` field.  Adding the new
constructor **does not require a new proof** — the existing
one-line `congrArg CompiledAction.source` covers every constructor
including the new one.  PA.4 verifies this by re-running the
existing test
`Test/Authority/Action.lean :: compileInjectiveAcrossAllConstructors`
extended to include `applyParameterChange`.

### 4.5 `Action.tag` extension

`Action.tag` (introduced in LP.1 covering indices 0..14, extended
in LP.4 to cover 15..16) gains one more branch in PA.4:

```lean
def Action.tag : Action → Nat
  -- ... existing 17 branches ...
  | .applyParameterChange _ _ _ => 17
```

**Theorem `Action.tag_matches_encode_tag`** continues to hold over
all 18 ctors.  Proven by `cases a` + per-branch reflexivity.

### 4.6 `fieldsBounded` extension

```lean
def Action.fieldsBounded : Action → Prop
  -- ... existing 17 cases ...
  | .applyParameterChange newParams signers sigs =>
      Parameters.fieldsBounded newParams ∧
      signers.length < 256 ^ 8 ∧
      sigs.length < 256 ^ 8 ∧
      (∀ s ∈ signers, s.toNat < 256 ^ 8)
```

The `Parameters.fieldsBounded` predicate is defined in PA.2; it
recursively bounds every `Nat` / `List` length in `Parameters` to
`< 2^64` for canonical CBE encoding.

### 4.7 Encoding extension

`Action.encode` and `Action.decode` extend with one new branch
each.  The encoded form is:

```
encode (.applyParameterChange newParams signers sigs) :=
  encode (17 : Nat) ++           -- constructor tag
  Parameters.encode newParams ++ -- via PA.2 instance
  encode signers ++              -- via List Nat instance
  encode sigs                    -- via List ByteArray instance
```

Round-trip (`action_roundtrip` extends with the new branch) and
injectivity (`action_encode_injective`) extend mechanically under
`fieldsBounded`.

## §5 Quorum signature counting

### 5.1 Domain-separated signing input

Governance signers sign a canonical byte sequence whose first
prefix bytes distinguish parameter-change votes from every
other signed payload in the system.  The mechanism mirrors
`Authority/SignedAction.lean`'s `signedActionDomain` and
`Disputes/Verdict.lean`'s `verdictDomain`.

```lean
/-- The domain-separation prefix prepended to every governance
    signature payload.  Distinct from `signedActionDomain` and
    `verdictDomain` so a signature on one cannot be re-
    interpreted as a signature on another (cross-protocol
    replay protection). -/
def parameterChangeDomain : String := "legalkernel/v1/paramchange"

/-- The canonical bytes governance signers sign for an
    `applyParameterChange` proposal.  Layout (concatenation of
    CBE encodings):

      * Domain prefix — ASCII bytes of `parameterChangeDomain`,
        wrapped as a CBE byte string (1 type tag + 8-byte LE
        length + UTF-8 payload).
      * `Encodable.encode (T := ByteArray) deploymentId` — the
        deployment-binding bytes (Audit-3.4-equivalent
        cross-deployment-replay rejection).
      * `Encodable.encode (T := Parameters) newParams` — the
        proposed parameter values.

    Each component is length-prefixed (for byte strings) or
    fixed-width (for unsigned integers), so the concatenation
    is self-delimiting and injective in `(newParams,
    deploymentId)`. -/
def signingInputForParameterChange
    (newParams : Parameters) (deploymentId : ByteArray) : ByteArray :=
  let domainBytes : Encoding.Stream :=
    Encoding.cborHeadEncode Encoding.cbeTagBytes
      parameterChangeDomain.toUTF8.size ++
      parameterChangeDomain.toUTF8.data.toList
  ByteArray.mk
    (domainBytes ++
     Encoding.Encodable.encode (T := ByteArray) deploymentId ++
     Encoding.Encodable.encode (T := Parameters) newParams).toArray
```

### 5.2 The quorum counter

```lean
/-- Count distinct, approved-signer, verified signatures over the
    parameter-change digest.  Mirrors
    `Disputes/Verdict.countVerifiedSignatures`'s shape exactly:

      * Walks `signers` and `sigs` in parallel via `List.zip`.
      * Maintains a "seen" list to deduplicate repeated signers
        (per-signer dedup, mirroring the post-audit
        `countVerifiedSignatures` fix; a single approved signer
        with one valid signature contributes at most 1 to the
        count regardless of list-length padding).
      * For each unique signer that's in
        `es.parameters.governanceSigners` AND whose registered
        public key (`es.registry[signer]?`) verifies the
        signature over the parameter-change digest, increment
        the count.

    Returns a `Nat`. -/
def countParameterChangeSignatures
    (verify : PublicKey → ByteArray → Signature → Bool)
    (deploymentId : ByteArray)
    (es : ExtendedState)
    (newParams : Parameters)
    (signers : List ActorId)
    (sigs : List Signature) : Nat :=
  let digest := signingInputForParameterChange newParams deploymentId
  let pairs  := signers.zip sigs
  pairs.foldl (init := (0, ([] : List ActorId)))
    (fun (count, seen) (s, σ) =>
      if s ∈ seen then
        (count, seen)
      else if s ∈ es.parameters.governanceSigners then
        match es.registry[s]? with
        | some pk =>
          if verify pk digest σ = true then
            (count + 1, s :: seen)
          else
            (count, s :: seen)
        | none => (count, s :: seen)
      else
        (count, s :: seen)
    ) |>.fst
```

### 5.3 Quorum dedup theorem

```lean
/-- PA.5: the quorum count is bounded by the number of distinct
    governance signers.  No matter how long the `signers` list,
    no signer counts more than once. -/
theorem countParameterChangeSignatures_le_governance_size
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray) (es : ExtendedState)
    (newParams : Parameters) (signers : List ActorId) (sigs : List Signature) :
    countParameterChangeSignatures verify d es newParams signers sigs
      ≤ es.parameters.governanceSigners.length
```

Proof: each successful increment adds the signer to `seen`; the
`s ∈ seen` short-circuit prevents double-counting; therefore the
count is bounded by the number of distinct governance signers
encountered, which is at most `governanceSigners.length`.

### 5.4 Empty-governance theorem

```lean
/-- PA.5: when the governance set is empty, every quorum count
    is 0 (every signer fails the membership check).  This is the
    operational form of the bootstrap-lockout property: in a
    deployment with `Parameters.empty`, no `applyParameterChange`
    can be admitted because no signature can count toward the
    quorum. -/
theorem countParameterChangeSignatures_zero_when_governance_empty
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray) (es : ExtendedState)
    (newParams : Parameters) (signers : List ActorId) (sigs : List Signature)
    (h_empty : es.parameters.governanceSigners = []) :
    countParameterChangeSignatures verify d es newParams signers sigs = 0
```

Proof: under `h_empty`, every `s ∈ es.parameters.governanceSigners`
check fails (membership in `[]` is `False`), so the count never
increments.

### 5.5 Stale-signer theorem

```lean
/-- PA.5: removing a governance signer immediately revokes their
    voting authority.  Their old signatures stop counting the
    moment they're no longer in `governanceSigners`.

    The hypothesis quantifies over a removed-but-otherwise-
    unchanged signer (key still in registry, signatures
    unchanged); the conclusion shows the count strictly
    decreases under the post-removal state. -/
theorem removed_governance_signer_loses_authority
    (verify : ...) (d : ByteArray) (es es' : ExtendedState)
    (newParams : Parameters)
    (signers : List ActorId) (sigs : List Signature)
    (h_diff : ∃ s ∈ signers,
              s ∈ es.parameters.governanceSigners ∧
              s ∉ es'.parameters.governanceSigners ∧
              es.registry[s]? = es'.registry[s]?)
    (h_other_unchanged :
      ∀ s' ∈ es.parameters.governanceSigners,
        s' ∈ es'.parameters.governanceSigners ∨ ∃ s ∈ signers, s = s') :
    countParameterChangeSignatures verify d es' newParams signers sigs <
    countParameterChangeSignatures verify d es  newParams signers sigs
```

Proof: by case-analysis on the `foldl` counting the removed
signer's contribution.  Pre-removal, that signer's first
signature successfully matches the membership check and the
`Verify` check, contributing 1.  Post-removal, the membership
check fails, contributing 0.  The other signers' contributions
agree under `h_other_unchanged`.

This theorem is the **type-level statement that governance is a
live capability, not a perpetual one**: kicked-out signers stop
mattering immediately, even if they've already collected
signatures.

### 5.6 Cross-protocol distinctness theorems

```lean
/-- PA.5: the `parameterChangeDomain` ASCII bytes do not equal
    the `signedActionDomain` ASCII bytes.  Direct consequence of
    the strings being literally distinct
    (`"legalkernel/v1/paramchange"` vs
    `"legalkernel/v1/signedaction"`).  Proven by
    `decide`-evaluation. -/
theorem parameterChangeDomain_distinct_from_signedActionDomain :
    parameterChangeDomain ≠ Authority.signedActionDomain

/-- PA.5: the `parameterChangeDomain` ASCII bytes do not equal
    the `verdictDomain` ASCII bytes
    (`"legalkernel/v1/paramchange"` vs
    `"legalkernel/v1/verdict"`). -/
theorem parameterChangeDomain_distinct_from_verdictDomain :
    parameterChangeDomain ≠ Disputes.verdictDomain
```

Both proofs reduce to `decide`-evaluation on string-byte
inequality.  The corresponding byte-level distinctness theorems
(`signingInputForParameterChange` does not produce the same
bytes as `signingInput` / `verdictSigningInput` under any input)
follow as straightforward corollaries because the length-
prefixed domain bytes are the leading prefix of every signed
payload.

## §6 The `applyActionToParameters` helper and `apply_admissible` extension

### 6.1 The mutation helper

Mirroring `applyActionToRegistry`, `applyActionToLocalPolicies`:

```lean
/-- Action-specific parameters-table effect.  For most actions
    (including the LP-introduced `declareLocalPolicy` /
    `revokeLocalPolicy` and every Phase-2/3/4/5/6 action), this
    is the identity.  Only `applyParameterChange` mutates
    `parameters`. -/
def applyActionToParameters
    (params : Parameters) : Action → Parameters
  | .applyParameterChange newParams _ _ => newParams
  | _                                   => params
```

For every action other than `applyParameterChange`, the
`parameters` field is unchanged.  For `applyParameterChange`, it
is replaced wholesale with `newParams`.  The validity check is
performed in admissibility (§7); the helper trusts its input
because admissibility has already discharged the validity check.

### 6.2 `apply_admissible_with` extension

The single guarded entry point gains a sixth final step (after
the LP `localPolicies` update):

```lean
def apply_admissible_with
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray)
    (es : ExtendedState) (st : SignedAction)
    (_h : AdmissibleWith verify P d es st) : ExtendedState :=
  let t   := (Action.compile st.action).transition
  let s'  := t.apply_impl es.base
  let es' := { es with base := s' }
  let es'' := advanceNonce es' st.signer
  let es''' := { es'' with registry :=
    applyActionToRegistry es''.registry st.action }
  let es'''' := { es''' with localPolicies :=
    applyActionToLocalPolicies es'''.localPolicies st.signer st.action }
  -- PA.5: apply parameters mutation.
  { es'''' with parameters :=
    applyActionToParameters es''''.parameters st.action }
```

The six steps (kernel state advance → wrap → nonce advance →
registry → localPolicies → parameters) commute pairwise on
disjoint `ExtendedState` fields.  We sequence them as written
for diagnostic readability and to reflect the order in which a
future auditor / runtime extension would naturally read them.

### 6.3 Mutation theorems

```lean
/-- PA.5: after applying `applyParameterChange newParams …` via
    `apply_admissible`, the post-state's `parameters` is exactly
    `newParams`. -/
theorem applyParameterChange_updates_parameters
    (P : AuthorityPolicy) (es : ExtendedState)
    (newParams : Parameters)
    (signers : List ActorId) (sigs : List Signature)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.applyParameterChange newParams signers sigs,
                          signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.applyParameterChange newParams signers sigs,
                            signer, nonce, sig⟩ h).parameters = newParams

/-- PA.5: after applying any non-`applyParameterChange` action via
    `apply_admissible`, the `parameters` field is unchanged.  A
    type-level statement that the parameters-mutation surface is
    exactly the one PA-introduced ctor. -/
theorem non_param_action_preserves_parameters
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (h_not_param : ∀ newParams signers sigs,
      st.action ≠ .applyParameterChange newParams signers sigs) :
    (apply_admissible P es st h).parameters = es.parameters
```

Both proofs reduce to definitional unfolding of
`apply_admissible_with` plus pattern-match on `st.action`.

### 6.4 Cross-actor isolation

`parameters` is a deployment-wide field, not per-actor, so
"cross-actor isolation" doesn't apply in the usual sense.  But
the analogous result is:

```lean
/-- PA.5: an `applyParameterChange` action by actor A doesn't
    affect actor B's `localPolicies` entry, nor any other
    actor's `nonces` entry except A's own.  Combined locality
    statement. -/
theorem applyParameterChange_other_fields_isolated
    (P : AuthorityPolicy) (es : ExtendedState)
    (newParams : Parameters)
    (signers : List ActorId) (sigs : List Signature)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.applyParameterChange newParams signers sigs,
                          signer, nonce, sig⟩)
    (b : ActorId) (h_ne : signer ≠ b) :
    let post := apply_admissible P es ⟨.applyParameterChange newParams signers sigs,
                                       signer, nonce, sig⟩ h
    expectsNonce post b = expectsNonce es b ∧
    post.localPolicies[b]? = es.localPolicies[b]? ∧
    post.registry[b]? = es.registry[b]?
```

By the existing `expectsNonce_after_apply_admissible_other`
(Phase 3) plus the fact that `applyParameterChange` neither
declares a local policy nor changes the registry.

## §7 Admissibility extensions for parameters

### 7.1 The two new conjuncts

`AdmissibleWith` (post-LP form has 5 top-level `∧` conjuncts
encoding 6 conditions) gains two more, encoding two more
conditions:

```lean
def AdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  -- 2. Authorisation predicate.
  P.authorized st.signer st.action ∧
  -- 4. Nonce match.
  st.nonce = expectsNonce es st.signer ∧
  -- 1 + 3. Registered signer with valid signature.
  (∃ pk, es.registry[st.signer]? = some pk ∧
         verify pk (signingInput st.action st.signer st.nonce deploymentId) st.sig = true) ∧
  -- 5. Compiled transition's precondition.
  (Action.compile st.action).transition.pre es.base ∧
  -- 6. (LP) Local-policy permits the action.
  localPolicyPermits es st.signer st.action ∧
  -- 7. (PA) Parameters permit the action's surface form.
  parametersPermit es.parameters st.action ∧
  -- 8. (PA) Parameter-action governance gate.
  parameterActionAdmissibleWith verify deploymentId es st
```

### 7.2 `parametersPermit` (per-action surface constraints)

```lean
/-- The PA conjunct 7 predicate: the deployment-wide parameter
    table permits the action's surface form.  Currently
    constrains:

      * `Action.transfer`'s `amount` field via
        `params.maxTransferAmount` (when set).
      * `Action.mint`'s `amount` field via
        `params.maxMintAmount` (when set).

    Other actions (and unset caps) reduce to `True`.  Future
    parameter additions extend this predicate with new branches
    under the same append-only discipline.

    Decidable: each branch reduces to `True` or a single Nat
    comparison. -/
def parametersPermit (params : Parameters) : Action → Prop
  | .transfer _ _ _ amount =>
    match params.maxTransferAmount with
    | none     => True
    | some max => amount ≤ max
  | .mint _ _ amount =>
    match params.maxMintAmount with
    | none     => True
    | some max => amount ≤ max
  -- Phase-4-prelude positive-incentive actions: not constrained
  -- by the MVP parameter set.
  | .reward _ _ _              => True
  | .distributeOthers _ _ _    => True
  | .proportionalDilute _ _ _  => True
  -- Workstream-C bridge actions: similarly uncapped in MVP.
  | .deposit _ _ _ _           => True
  | .withdraw _ _ _ _          => True
  -- All other actions (registry-mutating, dispute-pipeline,
  -- LP-meta, PA-self): vacuous.
  | _                          => True
```

**Decidability instance:**

```lean
instance parametersPermit_decidable
    (params : Parameters) (action : Action) :
    Decidable (parametersPermit params action) := by
  cases action <;> unfold parametersPermit <;>
    (try infer_instance) <;>
    (try (split <;> infer_instance))
```

### 7.3 `parameterActionAdmissibleWith` (governance gate)

```lean
/-- The PA conjunct 8 predicate: governance-gated admissibility for
    `Action.applyParameterChange`.  For other actions, vacuously
    `True` (so non-parameter-change actions are unaffected by the
    governance machinery).

    For `applyParameterChange newParams signers sigs`:
      * **Validity (kernel-level safety net).**  The proposed
        parameters satisfy `Parameters.valid`.
      * **Quorum.**  The deduplicated count of approved-signer
        verified signatures is at least the *current*
        `es.parameters.quorumThreshold`.

    The signature digest is `signingInputForParameterChange
    newParams deploymentId` (§5.1), domain-separated from
    `signingInput` and `verdictSigningInput` to prevent cross-
    protocol replay. -/
def parameterActionAdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  match st.action with
  | .applyParameterChange newParams signers sigs =>
    Parameters.valid newParams = true ∧
    countParameterChangeSignatures verify deploymentId es
        newParams signers sigs ≥ es.parameters.quorumThreshold
  | _ => True
```

**Decidability instance:**

```lean
instance parameterActionAdmissibleWith_decidable
    (verify : ...) (d : ByteArray)
    (es : ExtendedState) (st : SignedAction) :
    Decidable (parameterActionAdmissibleWith verify d es st) := by
  unfold parameterActionAdmissibleWith
  cases st.action <;> (try exact instDecidableTrue) <;>
    (apply instDecidableAnd <;> infer_instance)
```

### 7.4 Field extractors

```lean
/-- Extract conjunct 7: parameters permit the action. -/
theorem admissible_parametersPermit
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    parametersPermit es.parameters st.action :=
  h.2.2.2.2.2.1

/-- Extract conjunct 8: parameter-action governance gate. -/
theorem admissible_parameterActionAdmissible
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    parameterActionAdmissibleWith Verify ByteArray.empty es st :=
  h.2.2.2.2.2.2

/-- Specialisation: an admissible `applyParameterChange` action
    has valid `newParams`. -/
theorem applyParameterChange_admissible_implies_valid
    {P : AuthorityPolicy} {es : ExtendedState}
    {newParams : Parameters} {signers : List ActorId} {sigs : List Signature}
    {signer : ActorId} {nonce : Nonce} {sig : Signature}
    (h : Admissible P es ⟨.applyParameterChange newParams signers sigs,
                          signer, nonce, sig⟩) :
    Parameters.valid newParams = true := by
  have h_pa := admissible_parameterActionAdmissible h
  unfold parameterActionAdmissibleWith at h_pa
  exact h_pa.1

/-- Specialisation: an admissible `applyParameterChange` action
    has a met quorum. -/
theorem applyParameterChange_admissible_implies_quorum_met
    {P : AuthorityPolicy} {es : ExtendedState}
    {newParams : Parameters} {signers : List ActorId} {sigs : List Signature}
    {signer : ActorId} {nonce : Nonce} {sig : Signature}
    (h : Admissible P es ⟨.applyParameterChange newParams signers sigs,
                          signer, nonce, sig⟩) :
    countParameterChangeSignatures Verify ByteArray.empty es
        newParams signers sigs ≥ es.parameters.quorumThreshold := by
  have h_pa := admissible_parameterActionAdmissible h
  unfold parameterActionAdmissibleWith at h_pa
  exact h_pa.2
```

### 7.5 Strict-narrowing theorem

```lean
/-- PA.6 strict-narrowing (combined LP + PA): in a deployment with
    no `LocalPolicy` declared for the signer, no parameter caps
    set, and the action is not `applyParameterChange`, the
    post-PA admissibility predicate reduces to its pre-LP-pre-PA
    form. -/
theorem admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (h_no_policy   : es.localPolicies[st.signer]? = none)
    (h_no_max_xfer : es.parameters.maxTransferAmount = none)
    (h_no_max_mint : es.parameters.maxMintAmount = none)
    (h_not_param   : ∀ newParams signers sigs,
                     st.action ≠ .applyParameterChange newParams signers sigs) :
    Admissible P es st ↔
      AdmissibleWith Verify P ByteArray.empty
        { es with localPolicies := LocalPolicies.empty,
                  parameters    := Parameters.empty } st
```

Proof: under the four hypotheses, both new conjuncts (7 and 8)
reduce to `True`, and the LP conjunct (6) reduces to `True` per
LP's `admissible_no_policy_iff_pre_LP`.  The five remaining
conjuncts agree on the iff.

This theorem is the type-level statement that **PA + LP, in
their default-empty configurations, are byte-for-byte identical
to the pre-LP-pre-PA admissibility predicate.**  A deployment
that opts out of both pillars sees zero behavioural change.

### 7.6 Composition with LocalPolicy (formal)

```lean
/-- PA.6: LP and PA conjuncts compose by independent conjunction.
    An action is admissible iff every conjunct (including both
    LP and PA) permits it; either pillar can independently
    reject. -/
theorem admissible_lp_pa_compose
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction) :
    Admissible P es st →
      localPolicyPermits es st.signer st.action ∧
      parametersPermit es.parameters st.action ∧
      parameterActionAdmissibleWith Verify ByteArray.empty es st
```

Direct from the definitional structure of `AdmissibleWith`.

### 7.7 Replay protection survives

`replay_impossible` continues to hold: its proof depends only on
nonce monotonicity (`expectsNonce_strict_mono`).  PA does not
touch `nonces`; the new conjuncts do not affect the proof's
hypothesis chain.  Re-tested in PA.6.

For `applyParameterChange` specifically, the same theorem
applies: a successfully-applied parameter-change action's signer
has their nonce advanced by 1, so the same bytes cannot be
re-applied.  No additional theorem needed.

A separate concern is **stale-quorum replay**: an attacker who
collected approval signatures under an old governance set
attempts to replay them after the governance set has changed.
This is handled by the existing nonce mechanism (the proposer's
nonce is consumed once) plus the
`removed_governance_signer_loses_authority` theorem (§5.5):
governance-set membership is checked against the **current**
`es.parameters.governanceSigners`, not historical state.  A
removed signer's old signatures stop counting the moment they're
removed.

## §8 Parameter-aware law constraints (consumer integration)

### 8.1 Per-parameter consumer mapping

Each `Parameters` field has at least one consumer in the codebase.
PA.5 / PA.6 wire the consumers up:

| Parameter             | Consumer module                       | Pre-PA form                    | Post-PA form                            |
|-----------------------|---------------------------------------|--------------------------------|-----------------------------------------|
| `quorumThreshold`     | `Authority/SignedAction.lean`         | (n/a — PA introduces it)       | `parameterActionAdmissibleWith`         |
| `governanceSigners`   | `Authority/SignedAction.lean`         | (n/a)                          | `countParameterChangeSignatures`        |
| `maxTransferAmount`   | `Authority/SignedAction.lean`         | (n/a)                          | `parametersPermit` conjunct 7           |
| `maxMintAmount`       | `Authority/SignedAction.lean`         | (n/a)                          | `parametersPermit` conjunct 7           |
| `disputeWindowBlocks` | `Bridge/Finalisation.lean`            | function-arg in `isFinalised`  | `es.parameters.disputeWindowBlocks`     |
| `disputeStake`        | `Disputes/Staking.lean`               | structure-field in `StakingPolicy` | `es.parameters.disputeStake`        |

The first four consumers are admissibility-internal (live inside
`apply_admissible`'s decision); the last two are runtime-layer
(consumed outside `apply_admissible`, by deployment-facing
helpers).  PA.5 handles the runtime-layer consumers via additive
parameter-aware helpers.

### 8.2 `Bridge/Finalisation.lean` extension (PA.5)

The current `isFinalised` signature is:

```lean
def isFinalised
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (disputeWindowBlocks : Nat) (log : List LogEntry) : Prop
```

PA.5 adds two parameter-aware companions:

```lean
/-- Parameter-aware variant: read the dispute window from a
    supplied `Parameters` value.  Pure delegation. -/
def isFinalised'
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (params : Parameters) (log : List LogEntry) : Prop :=
  isFinalised fsnap currentL1Block params.disputeWindowBlocks log

/-- ExtendedState-aware variant: extract the parameters from
    `es`, then delegate to `isFinalised'`. -/
def isFinalisedFromES
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (es : ExtendedState) (log : List LogEntry) : Prop :=
  isFinalised' fsnap currentL1Block es.parameters log
```

The pre-PA `isFinalised` is preserved (callers may continue
passing the dispute window explicitly); the new helpers are
strict additions.  Workstream-D existing theorems
(`isFinalised_monotonic_in_currentBlock`,
`isFinalised_implies_no_upheld_against`) extend trivially via
unfold + delegation.

**Theorem `isFinalisedFromES_equiv`**: equivalent to the
pre-PA form under the substitution.

```lean
theorem isFinalisedFromES_equiv
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (es : ExtendedState) (log : List LogEntry) :
    isFinalisedFromES fsnap currentL1Block es log ↔
    isFinalised fsnap currentL1Block es.parameters.disputeWindowBlocks log
```

By definitional unfolding.  Establishes the compositional
bridge: runtime-layer callers can switch to the parameter-driven
form and their existing finalisation invariants continue to hold
modulo `disputeWindowBlocks ← es.parameters.disputeWindowBlocks`.

### 8.3 `Disputes/Staking.lean` extension (PA.6)

The current `StakingPolicy` structure is:

```lean
structure StakingPolicy where
  stakeAmount : Amount
  treasury    : ActorId
  -- ... ...
```

PA.6 adds a parameter-aware constructor:

```lean
/-- Lift a `Parameters` value to a `StakingPolicy` for use with
    the existing `fileDisputeStaked` helper.  The deployment
    supplies the `treasury` actor (which is not part of
    `Parameters`); the stake amount is read from
    `params.disputeStake`. -/
def stakingPolicyFromParameters
    (params : Parameters) (treasury : ActorId) : StakingPolicy where
  stakeAmount := params.disputeStake
  treasury    := treasury
  -- ... other fields default ...

/-- ExtendedState-aware variant of `fileDisputeStaked`. -/
def fileDisputeStakedFromES
    (es : ExtendedState) (treasury : ActorId)
    (filer : SignedAction) (claim : Disputes.Claim) :
    Except StakedFilingError ... :=
  let pol := stakingPolicyFromParameters es.parameters treasury
  fileDisputeStaked pol filer claim
```

The pre-PA `fileDisputeStaked` is preserved; the new helper is a
strict addition.

**Theorem `stakingPolicyFromParameters_stakeAmount_eq`**: the
constructed policy's `stakeAmount` equals the parameter's
`disputeStake`.  By rfl.

**Theorem `fileDisputeStakedFromES_equiv`**: the
ExtendedState-aware variant agrees with the pre-PA form under
the substitution.

```lean
theorem fileDisputeStakedFromES_equiv
    (es : ExtendedState) (treasury : ActorId)
    (filer : SignedAction) (claim : Disputes.Claim) :
    fileDisputeStakedFromES es treasury filer claim =
    fileDisputeStaked (stakingPolicyFromParameters es.parameters treasury)
                      filer claim
```

By rfl (definitional unfolding).

### 8.4 Why not change the kernel's `Transition` interface?

A natural alternative design: extend `Transition` to take an
`ExtendedState` (or a `Parameters`) input, so laws can read
parameters directly in their `pre` / `apply_impl`.  We
deliberately do **not** do this.  Reasons:

  1. **TCB expansion.**  Modifying `Transition` (a kernel-TCB
     type) would trigger the §13.6 two-reviewer gate, expand
     the TCB's surface, and require re-discharging every
     existing kernel theorem (`impl_refines_spec`,
     `apply_certified_eq_step_impl`,
     `invariant_preservation`, `invariants_compose`).  Out of
     scope for a deployment-facing feature.
  2. **Compositional clarity.**  Putting parameter checks at
     admissibility (not in transition pre / impl) cleanly
     separates *who-may-do-what* (admissibility) from
     *what-the-do-actually-does* (transition).  Deployments
     that swap law sets without changing parameters get the
     intended behaviour without surprising parameter
     interactions.
  3. **Backwards compatibility.**  Existing laws
     (`Laws/Transfer.lean` et al.) continue to work
     unchanged.  Their `pre` and `apply_impl` are pure
     functions of `State`, as designed.  No retrofit cost.
  4. **Determinism.**  The kernel's determinism guarantees
     (`step_impl` is a function on `(State, Transition)`) are
     preserved verbatim.  Parameters affect *what passes
     admissibility*, not *what step_impl computes given an
     admissible action*.

The cost of this design choice is mild: parameters cannot affect
the *semantics* of an admitted action, only whether it is
admitted.  For the MVP parameter set, this is exactly what we
want — caps gate admission, dispute window gates finalisation.
Future parameters that need to influence transition semantics
(e.g. dynamic fee schedules that change `transfer.amount`
mid-application) would require a different mechanism;
documented as deferred work in §14.2.

## §9 New events

### 9.1 Frozen-index assignment

`Event` (post-LP) ends with `localPolicyRevoked` at index 12.
PA.8 appends one new constructor:

| Tag | Constructor              | Fields                                      |
|-----|--------------------------|---------------------------------------------|
| 13  | `parametersChanged`      | `oldParams : Parameters`, `newParams : Parameters` |

This index is reserved by this plan and **MUST NOT** be used by
any concurrent workstream.

### 9.2 Constructor declaration

```lean
inductive Event
  -- ... existing 13 constructors (Phase-5 + Phase-6 + LP) ...
  /-- PA.8: a deployment-wide parameter change was applied.
      Carries the pre- and post-state `Parameters` values.
      Indexers consume this event to maintain a "current
      parameters" view + audit history.  Frozen index 13. -/
  | parametersChanged (oldParams : Parameters) (newParams : Parameters)
  deriving Repr, DecidableEq
```

### 9.3 `extractEvents` extension

```lean
def actionEvents : ... → ... → ...
  -- ... existing branches ...
  | .applyParameterChange newParams _ _ =>
    [Event.parametersChanged es.parameters newParams]
    -- emitted with es = pre-state
```

The event is emitted **unconditionally** on a successful
`apply_admissible` (mirroring the `rewardIssued` /
`localPolicyDeclared` conventions).  An idempotent change that
sets `newParams = es.parameters` still emits the event with
`oldParams = newParams`.

### 9.4 Projection extensions

`Event.actor` returns `none` for `parametersChanged` (it is a
deployment-wide event, not actor-scoped).  `Event.resource`
returns `none`.  A new classifier is added:

```lean
def Event.isParameterEvent : Event → Bool
  | .parametersChanged _ _ => true
  | _                      => false
```

### 9.5 Emission rule theorem

```lean
/-- PA.8: a successful `applyParameterChange` action emits exactly
    one `parametersChanged` event with the pre- and post-state
    parameters. -/
theorem extractEvents_applyParameterChange_emits_parametersChanged
    (P : AuthorityPolicy) (es : ExtendedState)
    (newParams : Parameters)
    (signers : List ActorId) (sigs : List Signature)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.applyParameterChange newParams signers sigs,
                          signer, nonce, sig⟩) :
    Event.parametersChanged es.parameters newParams ∈
      extractEvents es ⟨.applyParameterChange newParams signers sigs,
                        signer, nonce, sig⟩ h
```

By definitional unfolding of `extractEvents` + `actionEvents`'s
new branch.

## §10 Theorem inventory

This section enumerates every theorem the workstream introduces
or re-discharges, organised by module.  Each entry is named
exactly as it will appear in the Lean source (so `git log` /
`grep` cross-references work).

### 10.1 `LegalKernel/Authority/Parameters.lean` (PA.1)

  * `Parameters.empty_invalid` — `Parameters.empty.valid =
    false`.
  * `Parameters.valid_implies_governance_nonempty` — if
    `valid p = true`, then `p.governanceSigners.length ≥ 1`.
  * `Parameters.valid_implies_quorum_positive` — if
    `valid p = true`, then `p.quorumThreshold ≥ 1`.
  * `Parameters.valid_implies_quorum_le_signers` — if
    `valid p = true`, then `p.quorumThreshold ≤
    p.governanceSigners.length`.
  * `Parameters.valid_implies_window_positive` — if
    `valid p = true`, then `p.disputeWindowBlocks ≥ 1`.
  * `Parameters.valid_implies_signers_nodup` — if
    `valid p = true`, then `p.governanceSigners.Nodup`.
  * `Parameters.valid_decidable` (instance) — `Decidable
    (Parameters.valid p = true)` via `decide`.

### 10.2 `LegalKernel/Encoding/Parameters.lean` (PA.2)

  * `Parameters.fieldsBounded` — predicate.
  * `Parameters.fieldsBounded_decidable` (instance).
  * `Parameters.encode_decode` — round-trip under
    `fieldsBounded`.
  * `Parameters.encode_injective` — injectivity under
    `fieldsBounded`.
  * `Parameters.encode_deterministic` — structural equality.

### 10.3 `LegalKernel/Authority/Action.lean` (PA.4 extensions)

  * `Action.tag` extension to cover index 17 (one new branch).
  * `Action.tag_matches_encode_tag` extension (provable when
    PA.4 has landed; the agreement holds across all 18 ctors).
  * `Action.compile_injective` re-verified to extend over the
    new ctor (no proof change).
  * `Action.fieldsBounded_decidable` extension.

### 10.4 `LegalKernel/Encoding/Action.lean` (PA.4 extensions)

  * Existing `action_roundtrip` extended with the
    `applyParameterChange` branch.
  * Existing `action_encode_injective` extended.

### 10.5 `LegalKernel/Authority/SignedAction.lean` (PA.5 + PA.6)

New definitions:

  * `parameterChangeDomain` — domain-separation string.
  * `signingInputForParameterChange` — the canonical signed
    bytes.
  * `countParameterChangeSignatures` — quorum counter.
  * `parametersPermit` — conjunct 7 predicate.
  * `parameterActionAdmissibleWith` — conjunct 8 predicate.
  * `parametersPermit_decidable` (instance).
  * `parameterActionAdmissibleWith_decidable` (instance).
  * `applyActionToParameters` — mutation helper.

New theorems:

  * `applyParameterChange_updates_parameters` — §6.3.
  * `non_param_action_preserves_parameters` — §6.3.
  * `applyParameterChange_other_fields_isolated` — §6.4.
  * `admissible_parametersPermit` — §7.4.
  * `admissible_parameterActionAdmissible` — §7.4.
  * `applyParameterChange_admissible_implies_valid` — §7.4.
  * `applyParameterChange_admissible_implies_quorum_met` —
    §7.4.
  * `admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`
    — §7.5 strict-narrowing.
  * `admissible_lp_pa_compose` — §7.6 composition.
  * `countParameterChangeSignatures_le_governance_size` — §5.3
    dedup bound.
  * `countParameterChangeSignatures_zero_when_governance_empty`
    — §5.4.
  * `removed_governance_signer_loses_authority` — §5.5
    stale-signer protection.
  * `parameterChangeDomain_distinct_from_signedActionDomain` —
    §5.6 cross-protocol.
  * `parameterChangeDomain_distinct_from_verdictDomain` — §5.6
    cross-protocol.

Re-discharged theorems (existing theorems whose proofs are
unchanged but require re-elaboration in the post-PA structure):

  * `nonce_uniqueness` — re-tested; proof unchanged.
  * `replay_impossible` — re-tested; proof unchanged.
  * `apply_admissible_base` — re-tested.
  * `apply_admissible_registry` — re-tested.
  * `apply_admissible_localPolicies` — re-tested (LP-introduced;
    unchanged by PA).
  * `expectsNonce_after_apply_admissible` — re-tested.
  * `expectsNonce_after_apply_admissible_other` — re-tested.
  * `replaceKey_*` family — re-tested.
  * `registerIdentity_*` family — re-tested.
  * `non_registry_mutating_preserves_registry` — re-tested,
    extended with new exclusion (`applyParameterChange` doesn't
    touch registry).
  * `non_meta_preserves_localPolicies` (LP) — re-tested,
    extended with new exclusion (`applyParameterChange` doesn't
    touch localPolicies).
  * `localPolicy_meta_action_independent` (LP) — unchanged
    (PA-side operations are not LP meta-actions; this is correct
    behaviour: a LocalPolicy can deny `applyParameterChange`).

### 10.6 `LegalKernel/Encoding/State.lean` (PA.3 extensions)

  * Existing `extendedState_encode_deterministic` re-tested.
  * `extendedState_decode_pre_PA_compatible` — §3.6 tolerant
    decoder.
  * `extendedState_decode_pre_LP_pre_PA_compatible` —
    composition of LP.3 and PA.3 tolerance: a pre-LP-pre-PA
    snapshot decodes with both `localPolicies = empty` and
    `parameters = empty`.

### 10.7 `LegalKernel/Parameters/LawClassification.lean` (PA.7)

Mirrors `Disputes/LawClassification.lean` and
`LocalPolicy/LawClassification.lean`.

  * `applyParameterChange_compileTransition_eq_freezeResource_zero`
    — rfl identification lemma.
  * `applyParameterChange_compiled_isConservative` — instance.
  * `applyParameterChange_compiled_isMonotonic` — instance.
  * `parameter_action_classification` — composite summary.

### 10.8 `LegalKernel/Events/Types.lean` and `Extract.lean` (PA.8)

  * `Event.parametersChanged` constructor at frozen index 13.
  * `Event.actor` extension (returns `none`).
  * `Event.resource` extension (returns `none`).
  * `Event.isParameterEvent` classifier (new).
  * `extractEvents_applyParameterChange_emits_parametersChanged`
    — §9.5 emission rule.

### 10.9 `LegalKernel/Bridge/Finalisation.lean` (PA.5 extensions)

  * `isFinalised'` — parameter-aware variant.
  * `isFinalisedFromES` — ExtendedState-aware variant.
  * `isFinalisedFromES_equiv` — §8.2 equivalence theorem.
  * `isFinalisedFromES_monotonic_in_currentBlock` — lifted
    Workstream-D `isFinalised_monotonic_in_currentBlock`.
  * `isFinalisedFromES_implies_no_upheld_against` — lifted
    Workstream-D analogue.

### 10.10 `LegalKernel/Disputes/Staking.lean` (PA.6 extensions)

  * `stakingPolicyFromParameters` — constructor.
  * `fileDisputeStakedFromES` — ExtendedState-aware variant.
  * `stakingPolicyFromParameters_stakeAmount_eq` — rfl
    projection identity.
  * `fileDisputeStakedFromES_equiv` — §8.3 round-trip identity.

### 10.11 Axiom audit

Same gate as LP and earlier workstreams.  PA introduces:

  * No `opaque` declarations.
  * No `axiom` declarations.
  * No new dependency on `Classical.choice` beyond what
    `Std.TreeMap` already pulls in transitively.
  * The `scripts/axiom_audit.sh` script (added by LP.10)
    extends to cover PA's new theorems automatically (it
    enumerates every `theorem` / `def` declaration in the
    workstream's modules).

## §11 Work-unit breakdown

Each work unit is independently buildable, testable, and
reviewable.  PA.1 depends on LP.6 (LP must land first); PA.2 –
PA.10 follow PA.1's dependency chain mirroring LP's structure.

The dependency DAG:

```
LP.10 (LP complete; merged or in same PR)
   ↓
PA.1 → PA.2 → PA.3 → PA.4 → PA.5 → PA.6
                              ↓
                             PA.7 (independent of PA.6;
                                   can land in parallel)
                              ↓
                             PA.8
                              ↓
                             PA.9
                              ↓
                             PA.10
```

### PA.1 — `Parameters` core types

**Files:**

  * `LegalKernel/Authority/Parameters.lean` — new module.

**Deliverables:**

  * `Parameters` structure (6 fields per §3.1).
  * `Parameters.empty` (§3.3).
  * `Parameters.valid` (§3.2).
  * `Parameters.valid_decidable` instance.
  * Six validity-implication lemmas (§10.1).
  * `Parameters.empty_invalid` theorem.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.Parameters` succeeds.
  * Every theorem `#print axioms`-clean.
  * No `sorry`.

**Test file:** `Test/Authority/Parameters.lean` (new).

  * 8 cases covering `Parameters.valid`'s positive / negative
    paths on each constraint (quorum > 0, quorum ≤ signers,
    window > 0, signers nodup).
  * `Parameters.empty_invalid` value-level check.
  * Validity-implication lemma API stability.

### PA.2 — `Parameters` encoding

**Files:**

  * `LegalKernel/Encoding/Parameters.lean` — new module.

**Deliverables:**

  * `Parameters.fieldsBounded` predicate.
  * `Encodable Parameters` instance (encode + decode
    definitions).
  * Round-trip + injectivity + determinism theorems (§10.2).

**Acceptance criteria:**

  * `lake build LegalKernel.Encoding.Parameters` succeeds.
  * Round-trip and injectivity proven under `fieldsBounded`.
  * `#print axioms`-clean.

**Test file:** `Test/Encoding/Parameters.lean` (new).

  * Round-trip on `Parameters.empty`, on a typical-deployment
    fixture (quorum = 3, signers = [1,2,3,4,5], caps set), and
    on edge cases (empty caps, full caps).
  * Cross-value distinguishability (different parameters
    produce different bytes).
  * Field-bounded round-trip on `Parameters.empty` (it is
    bounded; only the `valid` predicate would reject it,
    not `fieldsBounded`).

### PA.3 — `ExtendedState` extension

**Files modified:**

  * `LegalKernel/Authority/Nonce.lean` — add `parameters` field
    with default; update `ExtendedState.empty`.
  * `LegalKernel/Encoding/State.lean` — extend
    `ExtendedState.encode` / `.decode`; add
    `extendedState_decode_pre_PA_compatible` and the combined
    LP+PA tolerance theorems.

**Deliverables:**

  * `ExtendedState.parameters` field.
  * `ExtendedState.empty` extension.
  * Encode / decode extension.
  * Pre-PA snapshot tolerance theorem.
  * Combined LP+PA tolerance theorem
    (`extendedState_decode_pre_LP_pre_PA_compatible`).
  * Determinism re-discharge.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.Nonce` and
    `LegalKernel.Encoding.State` succeed.
  * Every existing test continues to pass (default-value
    handling preserves elaboration).
  * Pre-PA and pre-LP-pre-PA snapshots decode to states with
    the appropriate empty defaults.

**Test file:** existing `Test/Encoding/State.lean` extended.

  * Round-trip for `ExtendedState` with non-empty `parameters`
    (3 cases).
  * Pre-PA snapshot bytes decode to a state with
    `parameters = Parameters.empty`.
  * Combined pre-LP-pre-PA snapshot decode test.
  * `extendedState_encode_deterministic` re-tested.

### PA.4 — `Action.applyParameterChange` constructor

**Files modified:**

  * `LegalKernel/Authority/Action.lean` — append ctor at index
    17; extend `compileTransition`; extend `Action.tag`.
  * `LegalKernel/Encoding/Action.lean` — extend `Action.encode`,
    `Action.decode`, `Action.fieldsBounded`, the action-
    roundtrip and injectivity theorems.

**Deliverables:**

  * `Action.applyParameterChange` constructor.
  * `compileTransition` branch (→ `Laws.freezeResource 0`).
  * `Action.tag` extension to cover index 17.
  * `Action.tag_matches_encode_tag` theorem update (covers
    index 17).
  * Encoding extensions.
  * `Action.compile_injective` re-verified.

**Acceptance criteria:**

  * `lake build` succeeds across the affected modules.
  * Round-trip for the new ctor.
  * Cross-constructor distinguishability with adjacent indices
    (revokeLocalPolicy ≠ applyParameterChange byte-distinct).

**Test files:** existing `Test/Authority/Action.lean` and
`Test/Encoding/Action.lean` extended.

  * 4 new tests in `Test/Authority/Action.lean` (compile shape,
    distinguishability, `Action.tag` projection sanity).
  * 3 new tests in `Test/Encoding/Action.lean` (round-trip and
    cross-constructor distinguishability).

### PA.5 — `applyActionToParameters` and `apply_admissible` extension; Bridge/Finalisation refactor

**Files modified:**

  * `LegalKernel/Authority/SignedAction.lean` — add helpers and
    extend `apply_admissible_with`.
  * `LegalKernel/Bridge/Finalisation.lean` — add parameter-aware
    helpers (§8.2).

**Deliverables:**

  * `applyActionToParameters` helper (§6.1).
  * `apply_admissible_with` body extension (§6.2).
  * Mutation theorems (§6.3, 2 theorems).
  * Cross-actor isolation theorem (§6.4).
  * `parameterChangeDomain` and `signingInputForParameterChange`
    definitions.
  * `countParameterChangeSignatures` definition + dedup theorem
    (§5.3) + empty-governance theorem (§5.4) + stale-signer
    theorem (§5.5).
  * Cross-protocol distinctness theorems (§5.6).
  * Re-discharge of every existing apply_admissible theorem.
  * `Bridge/Finalisation.lean`: `isFinalised'`,
    `isFinalisedFromES`, equivalence theorem, lifted
    monotonicity / no-upheld theorems.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * `lake build LegalKernel.Bridge.Finalisation` succeeds.
  * Every existing theorem in `SignedAction.lean` re-elaborates
    (with one-line `show` adjustments where the trailing-let
    chain confuses Lean's `rfl`).
  * The new mutation theorems prove without `sorry`.

**Test files:** existing `Test/Authority/SignedAction.lean`
extended (+~10 cases), plus `Test/Bridge/Finalisation.lean`
(+~3 cases).

### PA.6 — `Admissible` predicate extension; Disputes/Staking refactor

**Files modified:**

  * `LegalKernel/Authority/SignedAction.lean` — add admissibility
    conjuncts.
  * `LegalKernel/Disputes/Staking.lean` — add parameter-aware
    helpers (§8.3).

**Deliverables:**

  * `parametersPermit` predicate (§7.2) + decidability instance.
  * `parameterActionAdmissibleWith` predicate (§7.3) +
    decidability instance.
  * Extended `AdmissibleWith` body with conjuncts 7 + 8.
  * Field extractors (§7.4, 4 theorems).
  * Strict-narrowing theorem (§7.5).
  * Composition theorem (§7.6).
  * `Decidable AdmissibleWith` re-derivation.
  * `Disputes/Staking.lean`: `stakingPolicyFromParameters`,
    `fileDisputeStakedFromES`, equivalence theorem.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * `lake build LegalKernel.Disputes.Staking` succeeds.
  * `lake build LegalKernel.Runtime.Replay` succeeds (the
    `Decidable Admissible` instance flows through).
  * `nonce_uniqueness` and `replay_impossible` continue to
    elaborate.
  * The strict-narrowing and composition theorems prove
    without `sorry`.

**Test files:** existing `Test/Authority/SignedAction.lean`
extended (+~12 cases), plus `Test/Disputes/Staking.lean`
(+~3 cases).

### PA.7 — Parameters law classification

**File:** `LegalKernel/Parameters/LawClassification.lean` (new,
mirroring `LegalKernel/LocalPolicy/LawClassification.lean` and
`LegalKernel/Disputes/LawClassification.lean`).

**Deliverables:**

  * `applyParameterChange_compileTransition_eq_freezeResource_zero`
    rfl identification lemma.
  * Two typeclass instances (`IsConservative`, `IsMonotonic`).
  * One composite `parameter_action_classification` theorem.

**Acceptance criteria:**

  * `lake build LegalKernel.Parameters.LawClassification`
    succeeds.
  * The new ctor's compiled transition resolves to
    `IsConservative` and `IsMonotonic` instances via
    `inferInstance`.

**Test file:** `Test/Parameters/LawClassification.lean` (new).

  * 5 cases (2 instance-resolution checks × 2 properties +
    the composite theorem's API stability check).

PA.7 is **independent of PA.6** and may land in parallel.

### PA.8 — Event extension

**Files modified:**

  * `LegalKernel/Events/Types.lean` — append
    `parametersChanged` ctor at index 13; extend projections
    and the new classifier.
  * `LegalKernel/Events/Extract.lean` — extend `actionEvents` /
    `extractEvents` with the new emission rule.

**Deliverables:**

  * `Event.parametersChanged` constructor.
  * `Event.actor` extension (returns `none`).
  * `Event.resource` extension (returns `none`).
  * `Event.isParameterEvent` classifier.
  * Emission rule theorem (§9.5).

**Acceptance criteria:**

  * `lake build LegalKernel.Events.Types` succeeds.
  * `lake build LegalKernel.Events.Extract` succeeds.
  * Emission is deterministic; old + new params are recorded
    accurately.

**Test files:** existing `Test/Events/Types.lean` and
`Test/Events/Extract.lean` extended (+~6 cases).

### PA.9 — End-to-end tests

**File:** `Test/Authority/ParameterChangeAdmissibility.lean`
(new).

**Deliverables:**

End-to-end test scenarios using the `mockVerify` fixture from
`Test/MockCrypto.lean`:

  1. **Genesis-bootstrapped governance.**  Construct
     `ExtendedState` with non-empty `governanceSigners` at
     genesis time; submit an `applyParameterChange` with
     quorum-met signatures; verify the post-state's
     `parameters` equals the proposed value.
  2. **Empty-governance lockout.**  From `ExtendedState.empty`
     (which has empty `governanceSigners`), no
     `applyParameterChange` is admissible regardless of
     signatures.
  3. **Validity rejection.**  Submit
     `applyParameterChange { quorumThreshold := 0, … }` —
     fails admissibility despite quorum approval.
  4. **Quorum failure.**  Threshold = 3, but only 2 valid
     signatures provided — fails.
  5. **Quorum success after rotation.**  Initial governance =
     [A, B]; vote to add C; subsequent vote uses new
     threshold and new signer set.
  6. **Stale-signer rejection.**  Vote removes signer A;
     attempt to replay a proposal with A's signature
     post-removal — A's signature no longer counts.
  7. **Cross-protocol replay protection.**  A `Verdict`
     signature from the dispute pipeline cannot serve as a
     parameter-change quorum signature (domain prefixes
     differ).
  8. **Composition with LocalPolicy.**  Actor A declares
     `denyTags [17]` (deny applyParameterChange); A signs an
     `applyParameterChange` — fails (LP conjunct 6 rejects).
  9. **`maxTransferAmount` enforcement.**  Set
     `maxTransferAmount = some 100`; transfer 50 succeeds;
     transfer 200 fails.
  10. **`maxMintAmount` enforcement.**  Analogous to (9).
  11. **Default-deployment strict-narrowing.**  Default
      `Parameters` (no caps); pre-PA test fixture's transfer
      remains admissible post-PA.
  12. **Replay protection.**  An admissible
      `applyParameterChange` cannot be re-applied at the
      post-state.
  13. **Live parameter change effect.**  After
      `applyParameterChange { maxTransferAmount := some 50, …}`,
      the next transfer with amount 100 fails (the change is
      live).

**Plus** integration tests with LP at
`Test/Authority/LpPaIntegration.lean`:

  14. **Both pillars must permit.**  Actor A has
      `LocalPolicy { capAmount r 100 }`; deployment has
      `Parameters { maxTransferAmount := some 50 }`.
      A's `transfer r ? ? 30` succeeds (both permit);
      A's `transfer r ? ? 75` fails (PA caps at 50);
      A's `transfer r ? ? 200` fails (LP caps at 100).
  15. **LP-meta-exempt actions are still PA-checked.**
      Actor A declares `denyTags [16]` (deny
      revokeLocalPolicy); A signs `revokeLocalPolicy` —
      succeeds (LP meta-exempt).  But A's
      `applyParameterChange` is NOT LP-meta-exempt: A's
      LocalPolicy denying tag 17 would block it.
  16. **PA can set parameters that affect LP-bound actions.**
      Governance votes to set `maxTransferAmount := some 100`;
      subsequent transfers by an unrelated actor with amount
      200 fail despite that actor's empty `LocalPolicy`.
  17. **Strict-narrowing under defaults (combined).**  A
      pre-LP-pre-PA fixture's complete chain of transfers /
      mints / etc. is re-replayed against an `ExtendedState`
      with default `localPolicies` and `parameters`.  Every
      original action remains admissible byte-for-byte.

**Acceptance criteria:**

  * `lake build` succeeds across both new test modules.
  * All 17 scenarios pass at the value level.
  * Each scenario emits the expected events (verified via
    `extractEvents` cross-check).

### PA.10 — Documentation and integration

**Files modified:**

  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"knomosis-parameterized-laws"`; add new module imports.
  * `Tests.lean` — register new test suites.
  * `Test/Umbrella.lean` — update build-tag literal.
  * `CLAUDE.md` — add Workstream-PA changelog entry; extend
    the type-level properties table; update source-layout
    listing.
  * `README.md` — bump status line.
  * `docs/GENESIS_PLAN.md` — append a new section
    documenting parameterised laws (PA.10 deliverable).
  * `docs/std_dependencies.md` — verify no new Std imports
    needed.
  * `docs/abi.md` — append the new `Action` ctor (index 17)
    and `Event` ctor (index 13) to the on-disk-format
    listings.
  * `docs/extraction_notes.md` — verify no extraction changes
    needed.
  * `scripts/axiom_audit.sh` — verify it covers PA modules.

**Acceptance criteria:**

  * `lake build` (full) succeeds.
  * `lake test` succeeds (all suites green).
  * `lake exe count_sorries` returns 0.
  * `lake exe tcb_audit` passes (no TCB changes).
  * `lake exe stub_audit` passes.
  * `scripts/axiom_audit.sh` passes.
  * `kernelBuildTag` bumped; Umbrella test verifies.
  * `CLAUDE.md` source-layout listing updated.

## §12 Test plan

### 12.1 New test suites

| Suite                                                | Cases | PA unit |
|------------------------------------------------------|-------|---------|
| `Test/Authority/Parameters.lean`                     | ~10   | PA.1    |
| `Test/Encoding/Parameters.lean`                      | ~7    | PA.2    |
| `Test/Parameters/LawClassification.lean`             | ~5    | PA.7    |
| `Test/Authority/ParameterChangeAdmissibility.lean`   | ~13   | PA.9    |
| `Test/Authority/LpPaIntegration.lean`                | ~4    | PA.9    |

Total: ~39 new tests in new suites.

### 12.2 Updated test suites

| Suite                                  | Delta | PA unit  |
|----------------------------------------|-------|----------|
| `Test/Encoding/State.lean`             | +3    | PA.3     |
| `Test/Authority/Action.lean`           | +4    | PA.4     |
| `Test/Encoding/Action.lean`            | +3    | PA.4     |
| `Test/Authority/SignedAction.lean`     | +22   | PA.5+6   |
| `Test/Events/Types.lean`               | +2    | PA.8     |
| `Test/Events/Extract.lean`             | +4    | PA.8     |
| `Test/Bridge/Finalisation.lean`        | +3    | PA.5     |
| `Test/Disputes/Staking.lean`           | +3    | PA.6     |

Total: +44 new tests in existing suites.

**Combined PA test delta: ~+83 tests.**  Post-PA test count
target: ~1107 (post-LP + 83).

### 12.3 LP+PA integration scenarios

The four cases in `Test/Authority/LpPaIntegration.lean` exercise
the *interaction* between LP's per-actor pillar and PA's
deployment-wide pillar (covered in detail in §11 PA.9 above).
These tests cannot be covered by either workstream's individual
suite because they require fixtures combining LP-declared local
policies with PA-set parameters.

### 12.4 Property-based tests (recommended)

The Knomosis `Test/Property.lean` harness (Audit-3.9) supports
deterministic property tests at 100 default samples per property.
Two recommended PA properties:

  1. **`parameters_roundtrip_property`**: for every
     `Parameters` value satisfying `fieldsBounded`, decoding
     after encoding recovers the value.  Generator: random
     `Nat`, random `List Nat` of length 0..5, random
     `Option Nat`.
  2. **`quorum_dedup_property`**: for every `(signers, sigs,
     governanceSigners)` triple, the quorum count is
     ≤ |distinct signers ∩ governanceSigners|.

Property tests are recommended but not mandatory for PA
acceptance; if deferred, they become a follow-up hardening pass.

### 12.5 What's NOT tested (intentionally)

  * **Performance.**  `countParameterChangeSignatures` is
    O(|signers| × |governanceSigners|).  For a 100-signer
    governance with 100 collected signatures, that's 10 000
    comparisons — well within the per-block budget.  No
    formal perf test.
  * **Real cryptographic verification.**  `mockVerify` is used
    throughout for value-level admissibility witnesses.  The
    production `Verify` adaptor is exercised at the runtime
    layer in Phase 5; PA doesn't add anything new on this
    axis.
  * **Encoding-format negotiation.**  The on-disk format is
    fixed at deployment time.  Cross-version compatibility is
    bounded by the `extendedState_decode_pre_PA_compatible`
    theorem; no formal test of mixed-version networks.
  * **Multi-signer collusion modelling.**  The kernel cannot
    prevent k-of-n key compromise; this is the standard
    threshold-signature trust assumption.  Deployments must
    use AuthorityPolicy + governance signer diversity to
    mitigate.

## §13 Backwards compatibility

### 13.1 Existing test fixtures

Every existing `ExtendedState` literal of the form
`{ base := …, nonces := …, registry := … }` (or post-LP form
adding `localPolicies := …`) continues to elaborate post-PA
because Lean's record-update syntax respects the default value
`parameters := Parameters.empty`.  No fixture file needs editing.

Every existing admissibility witness gains one extra trivially-
discharged conjunct (`True.intro` for the new conjunct 7 when no
caps are set, plus `True.intro` for conjunct 8 on non-`apply
ParameterChange` actions).  Helper functions like `mockAdmissible`
in `Test/MockCrypto.lean` (added by Audit-3.3) bundle the
conjuncts; updating the helper transparently updates every
consumer.

### 13.2 Pre-PA snapshot tolerance

The `ExtendedState.decode` function uses the same tolerant-tail
strategy as LP.3: a successful 5-segment decode followed by zero
or more remaining bytes triggers default-value fill-in for the
absent 6th segment.  Pre-PA snapshots decode to states with
`parameters = Parameters.empty`.

Combined with LP.3's tolerance, the upgrade staircase is:

```
Pre-LP-pre-PA snapshot ───┬──► Post-LP build: tolerated, localPolicies = empty
                          └──► Post-PA build: tolerated, both = empty
Post-LP-pre-PA snapshot ──── ► Post-PA build: tolerated, parameters = empty
Post-PA snapshot         ──── ► Post-PA build: decoded verbatim
```

No pre-PA build can read a post-PA snapshot; this is acceptable
because `kernelBuildTag` mismatch at handshake prevents
mixed-version networks.

### 13.3 Genesis governance bootstrap

Per §3.3, `Parameters.empty` is invalid (empty governance set
breaks `Parameters.valid`).  This is by design: deployments must
explicitly seed `governanceSigners` at genesis.

The deployment-time procedure:

  1. Construct `ExtendedState` with
     `parameters := { quorumThreshold := T, governanceSigners
     := [s_1, …, s_n], … }` for chosen `T ∈ [1, n]` and
     governance signers `s_1, …, s_n`.
  2. Verify off-chain that
     `Parameters.valid es.parameters = true`
     (the deployment's setup script checks this).
  3. Compute `stateHash es` and distribute to all nodes.
  4. The chain starts; subsequent governance changes go through
     `applyParameterChange`.

A deployment that boots from `ExtendedState.empty` without
seeding governance has a **soft-bricked governance surface**:
non-`applyParameterChange` actions still work normally (the
default `Parameters` has no caps set, so admissibility is
unchanged), but no parameter change can ever be admitted.  The
deployment can continue indefinitely as an "ungoverned" chain.

This is intentional: a deployment that doesn't want runtime
governance can simply leave `governanceSigners = []` forever.
The strict-narrowing theorem
(`admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`)
guarantees such a deployment behaves identically to a
pre-LP-pre-PA deployment.

### 13.4 On-disk log format

The new `Action.applyParameterChange` constructor at index 17
extends the existing CBE codec.  Old log files containing only
constructors 0..16 decode unchanged.  New log files containing
the new constructor cannot decode under pre-PA builds, but
`kernelBuildTag` mismatch surfaces at handshake time.

### 13.5 Snapshot format

Same asymmetric-tolerance pattern as Workstream-C and LP.  See
§13.2 above.

### 13.6 Runtime adaptor compatibility

The Phase-5 runtime CLI (`knomosis` binary) and audit binary
(`knomosis-replay`) work unchanged.  Their input format
(`ExtendedState` snapshots + log frames) extends backwards-
compatibly per §13.2 / §13.4.  The CLI does not need a new
subcommand for parameter changes — they're submitted as ordinary
signed actions through the existing `process` subcommand.

## §14 Risks and open questions

### 14.1 Resolved risks

  * **Validity safety net.**  Resolved by `Parameters.valid` +
    admissibility conjunct 8.  No quorum, however large, can
    install invalid parameters.
  * **Quorum dedup.**  Resolved by per-signer dedup in
    `countParameterChangeSignatures`, mirroring the post-audit
    `Disputes/Verdict.countVerifiedSignatures` fix.
  * **Cross-protocol signature replay.**  Resolved by
    `parameterChangeDomain` distinct from
    `signedActionDomain` and `verdictDomain` (theorems
    `parameterChangeDomain_distinct_from_*`).
  * **Stale-signer replay.**  Resolved by the
    `removed_governance_signer_loses_authority` theorem:
    governance-set membership is checked against the
    *current* `es.parameters.governanceSigners`, not
    historical state.
  * **Bootstrap lockout.**  Resolved by deliberately invalid
    `Parameters.empty` (forces deployment-time seeding).
    The deployment procedure §13.3 documents the seeding
    step explicitly.
  * **TCB expansion.**  Resolved: every PA module is non-TCB.
    `tcb_audit` will pass without modification.
  * **Axiom expansion.**  Resolved: no new `axiom` or
    `opaque`.
  * **LP-PA composition correctness.**  Resolved by
    `admissible_lp_pa_compose` theorem.
  * **Replay-protection regression.**  Resolved:
    `replay_impossible` and `nonce_uniqueness` proofs depend
    only on nonce monotonicity, unchanged by PA.
  * **Encoding malleability.**  Resolved: the canonical CBE
    encoding plus the §8.8.6 sorted-key invariant on
    embedded maps rule out alternate-bytes-same-state attacks.

### 14.2 Open questions / future work

The following items are explicitly deferred from this
workstream and will be addressed by follow-up work units (or
not, depending on real-world demand).  Each is sketched here so
future contributors have a starting point.

  * **Token-/stake-weighted quorum.**  Each governance signer
    contributes 1 to the quorum count.  A future workstream
    could weight signers by their resource-0 balance (or
    another resource), with `Parameters` extended to carry the
    weighting resource.  This requires balance snapshotting
    at proposal time (otherwise quorum can be gamed by
    mid-vote transfers); design is non-trivial.

  * **Two-stage propose-then-apply pipeline.**  Adds an
    `Action.proposeParameterChange { proposal, rationale }`
    step prior to `applyParameterChange`.  Pros: on-chain
    proposal record; off-chain discussion / amendment;
    timelock-style activation delay.  Cons: doubles the
    on-chain action count; introduces a "live proposal"
    state requiring invalidation rules (e.g. on governance
    signer rotation).  Defer until real users demand it.

  * **Delta-style parameter updates.**  An
    `Action.applyParameterDeltas (deltas : List
    ParameterDelta)` constructor that applies a list of
    named field changes rather than full-record replacement.
    Saves on-chain bytes when only one field changes.
    Requires recursive ADT encoding (or flat list with
    explicit field tags).  Defer.

  * **Effective-at-block delayed activation.**  Add a
    `Parameters.pending : Option (Parameters × LogIndex)`
    field that stages a future parameter change until the
    named log-index is reached.  Provides timelock behaviour.
    Defer until demand justifies the complexity.

  * **Per-resource parameter caps.**  Currently
    `maxTransferAmount` is global across resources.  A
    deployment might want different caps per resource
    (`maxTransferAmount r₁ = 100`, `maxTransferAmount r₂ =
    none`).  Trivially additive: replace `Option Amount`
    with `TreeMap ResourceId Amount compare`.  Defer until a
    deployment asks.

  * **Governance-actor LocalPolicy interaction.**  A
    governance signer with a restrictive `LocalPolicy` could
    deny themselves participation in parameter votes.  This
    is correct per the design (LP scope =
    self-restriction); a deployment that wants to forbid
    governance signers from declaring LocalPolicies can do
    so via `AuthorityPolicy.authorized signer
    (.declareLocalPolicy _) = False` for each governance
    signer.  Document but don't enforce in the kernel.

  * **Dispute-pipeline interaction.**  An adjudicator's
    `Verdict` signature on a dispute is structurally
    distinct from a parameter-change quorum signature
    (different domain prefix, different digest contents).
    `Verdict.signers` and `Parameters.governanceSigners`
    are independent sets; deployments may overlap them by
    convention without any kernel-level constraint.

  * **Parameter migration across `CanonMigration`.**  When a
    chain forks via `CanonMigration` (Workstream E.5), the
    successor inherits the predecessor's `parameters`.
    Deployments wanting to reset parameters at fork time
    need a custom migration sequence (snapshot-edit +
    restart).  Document but don't automate.

  * **Concurrent LP and PA changes.**  Two governance
    signers submitting `applyParameterChange` and a regular
    actor declaring `LocalPolicy` can race; the chain
    resolves by the order log entries are appended
    (`processSignedAction` is sequential per node).  No
    additional theorem needed — the existing
    `replay_impossible` and `nonce_uniqueness` cover the
    race.

  * **Parameters that influence transition semantics.**  PA
    binds admissibility, not transition semantics (§8.4).  A
    parameter like a "current fee rate" that needs to be
    consumed by `transfer.apply_impl` would require the
    kernel-level `Transition` interface to take an
    `ExtendedState` input — a TCB change requiring the
    §13.6 two-reviewer gate.  Out of scope.

### 14.3 Known limitations

  * **No timelock.**  Parameter changes activate immediately
    on application.  A malicious quorum can install harmful
    parameters without notice.  Mitigation: deployments use
    `AuthorityPolicy` to restrict who can sign
    `applyParameterChange` (proposer-side); validators can
    exit via `CanonMigration` if governance behaves badly.

  * **Quorum gaming via key compromise.**  An attacker who
    compromises k governance signing keys (where k =
    quorumThreshold) can change parameters arbitrarily.
    The kernel cannot prevent key compromise; this is the
    standard threshold-signature trust assumption.

  * **No automatic governance rotation.**  If a governance
    signer disappears (dies, loses keys), they remain in the
    `governanceSigners` list (and can technically continue
    to "vote") until removed by an explicit
    `applyParameterChange`.  If too many signers disappear,
    the quorum may become unmeetable.  Deployments should
    plan for redundancy.

  * **No on-chain proposal record.**  An
    `applyParameterChange` that fails admissibility leaves no
    on-chain trace (it's rejected before the log append).
    Deployments wanting failed-proposal audit trails must
    collect that data off-chain.

  * **No partial revocation.**  Replacing one `Parameters`
    field requires submitting a full new `Parameters` value
    with the unchanged fields copied verbatim.

  * **MVP parameter set is small.**  Six fields cover the
    most common Knomosis tunables but leave many constants
    untouched (e.g. dispute-pipeline reward rates).  Future
    PRs append fields under the documented append-only
    discipline.

## §15 Acceptance criteria

The PA workstream is complete when, on the head commit of the
landing branch, all of the following hold:

  1. **Build green.**  `lake build` succeeds on a clean
     checkout.
  2. **Tests green.**  `lake test` reports zero failures
     across every registered suite (LP + PA + integration).
  3. **No sorries.**  `lake exe count_sorries` returns 0.
  4. **TCB audit passes.**  `lake exe tcb_audit` reports
     zero allowlist violations; the kernel TCB is unchanged.
  5. **Stub audit passes.**  `lake exe stub_audit` reports
     zero placeholder bodies in non-allowlisted positions.
  6. **Axiom audit passes.**  `scripts/axiom_audit.sh`
     reports that every theorem introduced by this
     workstream depends only on a subset of `{propext,
     Classical.choice, Quot.sound}`.
  7. **Frozen-index invariants preserved.**  `Action`'s
     constructor list ends with `applyParameterChange` at
     index 17 (after LP's ctors at 15, 16); `Event`'s ends
     with `parametersChanged` at index 13.  Verified by
     integration test.
  8. **Backward-compat.**  Loading a pre-PA snapshot on the
     post-PA build produces an `ExtendedState` with
     `parameters = Parameters.empty` and the other fields
     byte-identical.  Verified by value-level test.
  9. **Strict-narrowing.**  The
     `admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`
     theorem proves without `sorry` and depends only on the
     standard axioms.
  10. **Validity safety net.**  The
      `Parameters.empty_invalid` and
      `applyParameterChange_admissible_implies_valid`
      theorems prove without `sorry`.
  11. **Quorum dedup.**  The
      `countParameterChangeSignatures_le_governance_size`
      theorem proves without `sorry`.
  12. **Cross-protocol replay protection.**  The
      `parameterChangeDomain_distinct_from_signedActionDomain`
      and
      `parameterChangeDomain_distinct_from_verdictDomain`
      theorems prove without `sorry`.
  13. **Stale-signer protection.**  The
      `removed_governance_signer_loses_authority` theorem
      proves without `sorry`.
  14. **Replay-protection unchanged.**  `replay_impossible`
      and `nonce_uniqueness` are re-tested at API-stability
      and value-level.  Both pass.
  15. **LP-PA composition.**  The
      `admissible_lp_pa_compose` theorem proves without
      `sorry`.
  16. **Consumer integration (PA.5 + PA.6).**  The
      `isFinalisedFromES_equiv` and
      `fileDisputeStakedFromES_equiv` theorems prove without
      `sorry`.
  17. **Documentation updated.**  CLAUDE.md's "Active
      development status" section names PA as complete; the
      source-layout listing reflects the new modules; the
      type-level properties table gains the new entries; the
      `kernelBuildTag` literal is bumped to
      `"knomosis-parameterized-laws"`.

The workstream is **not** complete (and the PR is not
landable) until every gate above passes simultaneously.
Partial completion is documented as in-progress and committed
only with the `work-in-progress` PR label.

If PA lands in a separate PR after LP, the LP-merge commit's
acceptance criteria (per `docs/planning/actor_scoped_policies_plan.md`
§14) need not be re-discharged; only PA's gates above apply
at PA's merge commit.

## Cross-references

  * **Workstream LP — Actor-Scoped Policies.**  Companion
    plan that introduces per-actor `LocalPolicy` filters.  PA
    depends on LP (LP must merge first or land in the same
    PR).  See `docs/planning/actor_scoped_policies_plan.md`.

---

**Document version:** v1, drafted by Claude on branch
`claude/add-law-voting-0jBAh`.  Subsequent edits track real
implementation decisions and are reflected in the in-tree
changelog (CLAUDE.md "Active development status").  This file
is informational; the canonical specification is the
Genesis-Plan amendment that PA.10 is charged with drafting.
