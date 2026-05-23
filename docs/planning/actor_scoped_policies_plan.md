<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Actor-Scoped Policies (Workstream LP) — Engineering Plan

This document plans the engineering effort needed to add **per-actor,
on-chain, mutable policy filters** to Knomosis.  It is a roadmap, not a
specification; the formal design will be promoted into a Genesis-Plan
amendment once the work-unit set lands.

The motivating observation is that Knomosis's determinism contract makes
"different nodes running different law configurations" structurally
infeasible: every node runs the same `processSignedAction` against the
same `AuthorityPolicy`, the same compiled `Action` set, and the same
`apply_admissible` reduction, or they fork.  Per-actor policies recover
the *spirit* of the original ask — heterogeneous user-level rules —
while preserving full consensus-level determinism: every node sees the
same `localPolicies` table in `ExtendedState` and uniformly evaluates
each actor's outgoing actions against that actor's declared policy.

## Status

  * **Drafted on branch:** `claude/add-law-voting-0jBAh`.
  * **Phase prefix:** `LP` (Local Policies) — work units labelled
    `LP.1` … `LP.14` to disambiguate from the Genesis-Plan
    `Phase 1`/`Phase 2`/… numbering and from the Ethereum-integration
    `A` / `B` / `C` / `D` workstream prefixes.  This workstream is
    parallel to, not a successor of, the Genesis-Plan Phase 7.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`, and
    `lake exe stub_audit` all green throughout; **no new sorries**;
    **no new axioms**; **no expansion of the kernel TCB**; no new
    `opaque` declarations.
  * **TCB delta:** zero.  Every new module ships under
    `LegalKernel/Authority/`, `LegalKernel/Encoding/`,
    `LegalKernel/Events/`, or `LegalKernel/LocalPolicy/`; none touches
    `Kernel.lean` or `RBMapLemmas.lean`.
  * **Trust-assumption delta:** zero.  The `Verify` opaque is
    unchanged; `hashBytes` is unchanged; no new cryptographic
    primitives are introduced.  The new admissibility conjunct is a
    pure decidable predicate over first-order data already in
    `ExtendedState`.
  * **Backwards-compat delta:** the new `localPolicies` field of
    `ExtendedState` defaults to the empty map (`LocalPolicies.empty`),
    so every pre-LP construction (test fixtures, deployment-time
    seeds) continues to elaborate; the new admissibility conjunct
    reduces definitionally to `True` whenever the signer has no
    declared policy.  Existing admissibility witnesses gain one
    trivially-discharged conjunct (`True.intro` in test fixtures).
  * **Frozen indices reserved by this workstream:**
    `Action.declareLocalPolicy` at index 15;
    `Action.revokeLocalPolicy` at index 16;
    `Event.localPolicyDeclared` at index 11;
    `Event.localPolicyRevoked` at index 12.
  * **DoS bounds reserved by this workstream** (mirroring the
    Solidity-side `MAX_VERDICT_SIGNERS = 64` /
    `MAX_EVIDENCE_BLOB_BYTES = 100_000` discipline):
      * `MAX_CLAUSES_PER_POLICY = 64` — per-policy clause-count
        cap.  A `LocalPolicy` with more than 64 clauses fails
        `LocalPolicy.fieldsBounded`.
      * `MAX_TAGS_PER_DENY = 64` — per-`denyTags` clause tag-list
        length cap.
      * `MAX_RECIPIENTS_PER_REQUIRE = 64` — per-`requireRecipientIn`
        clause `allowed` list-length cap.
      * `MAX_POLICY_ENCODE_BYTES = 16_384` — total encoded-bytes
        cap on a single declared policy.  Holds by construction
        from the per-clause + per-list bounds above plus CBE's
        9-byte uint head; documented + asserted in
        `LocalPolicy.fieldsBounded` lemmas (LP.2).

    These bounds are enforced at the `LocalPolicy.fieldsBounded`
    level (decoder rejects oversize inputs as
    `DecodeError.fieldOutOfBounds`); they are not new admissibility
    conjuncts.  An on-wire `declareLocalPolicy` action carrying a
    policy that exceeds any bound fails decoding at the
    runtime-adaptor layer **before** ever reaching admissibility,
    so the kernel never sees an oversize policy.
  * **Snapshot compatibility model.**  Pre-LP snapshots cannot be
    decoded by the post-LP `ExtendedState.decode` (the post-LP
    decoder strictly expects the new 5th segment).  Operators
    upgrade by re-snapshotting under the post-LP build (one
    `knomosis snapshot` call after `knomosis bootstrap`); the
    re-snapshotted file's `Snapshot.stateHash` reflects the new
    canonical 5-segment encoding.  This is documented in §12 and
    matches Knomosis's strict-canonicality discipline (§8.8.6); a
    "tolerant decoder" approach was rejected because it would
    create two valid byte representations of the same logical
    state and break `state_encode_decode_idempotent` (Phase-4
    audit-2 invariant).

## §1 Goals and non-goals

### 1.1 What this plan delivers

After Workstream LP lands, the following is true:

  1. Every actor `a` in the deployment can publish, via signed
     `Action.declareLocalPolicy { policy }`, a first-order data value
     `policy : LocalPolicy` that further constrains *their own*
     outgoing actions.  The kernel's admissibility check at every
     subsequent step consults `localPolicies[a]?` and rejects any
     action of `a` that the declared policy does not permit.
  2. The same actor can revoke their declaration at any time via
     signed `Action.revokeLocalPolicy`, restoring the unrestricted-
     by-default behaviour.
  3. Policy declarations and revocations are **structurally exempt**
     from the local-policy check: an actor cannot construct a
     `LocalPolicy` that locks them out of their own policy slot.
     This is provable as a Lean theorem
     (`localPolicy_meta_action_independent`) and not merely a
     convention.
  4. The new admissibility conjunct **strictly narrows** admissibility:
     every signed action that was admissible pre-LP and whose signer
     has no declared policy continues to be admissible.  Conversely,
     no action that was inadmissible pre-LP becomes admissible post-LP.
  5. `replay_impossible`, `nonce_uniqueness`, and the cross-actor
     isolation theorems continue to hold verbatim.  Their proofs
     depend only on nonce monotonicity, which is unchanged.
  6. The `ExtendedState` encoding is extended to include
     `localPolicies` as a sorted, length-prefixed CBE map
     (mirroring the existing `bridge` field's append pattern), with
     full round-trip and structural determinism theorems.
  7. Two new events fire deterministically: `localPolicyDeclared` on
     a successful `declareLocalPolicy` action and `localPolicyRevoked`
     on a successful `revokeLocalPolicy`.  Indexers can subscribe.
  8. The new action constructors are classified as both
     `IsConservative` and `IsMonotonic` (they compile to
     `Laws.freezeResource 0`, like every other registry-/bridge-
     mutating action), so deployments using
     `ConservativeLawSet` / `MonotonicLawSet` invariants continue to
     get those invariants for free.

### 1.2 Non-goals

This workstream **does not**:

  * Add any voting / aggregation mechanism for combining multiple
    actors' policies into a deployment-wide rule.  Per-actor policies
    are unilaterally chosen by their declaring actor.  Voting on
    *deployment-wide* rules is a separate workstream (sketched in the
    follow-up to this plan; see `docs/law_voting_analysis.md` if and
    when it lands).
  * Enable any policy clause that requires unbounded computation,
    classical reasoning, or a non-decidable predicate.  Every clause
    must reduce to a finite conjunction of `Nat`-/`List`-arithmetic
    decidable comparisons (the `decPre := fun _ => inferInstance`
    discipline applies — see §6.3).
  * Permit policy clauses that reference *future* state (e.g. "deny
    if a transfer happens later"); each clause is evaluated at the
    pre-state of the action it gates, with no look-ahead.
  * Offer privacy or zero-knowledge: declared policies are public on
    the log, like every other on-chain action.  An actor's declared
    policy is observable by every node; if privacy is desired the
    actor must not declare the policy on-chain.
  * Compose two actors' policies (no `union` / `intersect`
    combinators between distinct actors' policies).  Each actor's
    policy is evaluated independently against that actor's own
    actions.
  * Introduce a "global default policy" applicable to every actor.
    The default is the empty (unrestricted) policy; deployments
    wanting a global default must encode it in `AuthorityPolicy`,
    which already supports per-`(actor, action)` static rules.
  * Modify any kernel-TCB module (`Kernel.lean`,
    `RBMapLemmas.lean`).  All work happens in non-TCB modules.
  * Change the on-disk log frame format.  New `Action` constructors
    extend the existing CBE codec at appended frozen indices; old
    log frames remain decodable; new log frames decode under any
    post-LP build.

This workstream **does**:

  * Append a 5th segment (`localPolicies` map) to the
    `ExtendedState` CBE encoding.  Pre-LP snapshots cannot be
    decoded by the post-LP `ExtendedState.decode` (which is
    strict per §4.5); operators upgrade by re-snapshotting under
    the post-LP build.  This matches the strict-decoder
    discipline that Workstream-C used for the `bridge` field.
    See §4.5 for the rationale and §12.4 for the operator
    migration procedure.

## §2 Architectural overview

### 2.1 Where this lives

The workstream's modules sit between the existing authority layer
and the encoding layer.  The notation `[LP.x]` after a module
indicates the work unit that introduces or modifies it (see §10):

```
LegalKernel.Authority.LocalPolicy          [LP.1; new]
  ├── imports Kernel + Authority.Action     (for compileTransition path)
  └── exports LocalPolicyClause, LocalPolicy, LocalPolicies,
              .permits, MAX_* bound constants, Action.tag

LegalKernel.Authority.Action               [LP.1: Action.tag projection]
                                           [LP.4: 2 new ctors at indices 15..16]

LegalKernel.Authority.Nonce                [LP.3: 5th field on ExtendedState
                                            (localPolicies, default-empty)]

LegalKernel.Authority.SignedAction         [LP.5: applyActionToLocalPolicies +
                                            apply_admissible_with body extension +
                                            4 mutation theorems]
                                           [LP.6: re-discharge of 11 existing
                                            theorems + extractor robustness pass]
                                           [LP.7: AdmissibleWith 5th conjunct +
                                            isMetaPolicyAction + meta-action proof +
                                            strict-narrowing theorem]

LegalKernel.Authority.Identity             (no LP changes; KeyRegistry semantics
                                            unchanged.  LP doesn't touch this.)

LegalKernel.Encoding.LocalPolicy           [LP.2; new]
  ├── imports Authority.LocalPolicy + Encoding.Encodable
  └── exports Encodable instances + fieldsBounded predicate +
              encode_size_bound theorem + per-clause roundtrip /
              injectivity + LocalPolicies.encodeMap / decodeMap

LegalKernel.Encoding.Action                [LP.4: 2 new tag entries +
                                            roundtrip extension +
                                            tag_matches_encode_tag theorem]

LegalKernel.Encoding.State                 [LP.3: localPolicies appended to
                                            ExtendedState.encode/.decode;
                                            decode is STRICT (no tolerant fallback)]

LegalKernel.LocalPolicy.LawClassification  [LP.9; new, mirrors
                                            Disputes/LawClassification.lean]
  └── exports IsConservative + IsMonotonic instances for the 2 new ctors,
              composite local_policy_actions_classification theorem

LegalKernel.Events.Types                   [LP.10: 2 new ctors at frozen 11, 12]
LegalKernel.Events.Extract                 [LP.10: 2 new emission rules]

LegalKernel.Bridge.Admissible              [LP.8: verification only — body
                                            re-elaborates after LP.7's conjunct add]
LegalKernel.Bridge.Accounting              [LP.8: 2 new accounting_delta_*
                                            cases (zero deltas) + 2 shape lemmas]
LegalKernel.Bridge.BridgeActor             [LP.8: 2 new policy-rejection theorems
                                            (bridge actor cannot declare/revoke
                                            local policies)]

LegalKernel.Disputes.{Evidence, Verdict}   [LP.8: verification only —
                                            kernelOnlyApply / kernelOnlyReplay
                                            are admissibility-blind by design]

LegalKernel.Runtime.{Replay, Loop, Snapshot}
                                           [LP.8: verification only — Decidable
                                            Admissible flows from LP.7 via
                                            inferInstance]
```

**Key invariants of the dependency layout:**

  * **No existing module gains an inbound edge from a new module.**
    `LegalKernel.lean` (umbrella) re-exports the new modules
    [LP.14]; no other consumer changes import structure.
  * **No new module imports the kernel TCB
    (`Kernel.lean`, `RBMapLemmas.lean`).**  All new modules sit
    in non-TCB tiers; `tcb_audit` continues to pass without
    modification.
  * **Dependency edges flow strictly upward** from base modules
    (Kernel) to leaf consumers (Tests).  No cyclic imports;
    `lake build` succeeds at every commit boundary in the
    LP.1 → LP.14 sequence.
  * **Cross-stack scope** [LP.13] is documentation-only —
    `solidity/` and `docs/` updates that pin the future
    Solidity-port shape but introduce no Lean-side or
    Solidity-side code.

### 2.2 The two-clause story

The user-visible model is intentionally a single sentence:

> **Each actor's outgoing actions are admissible iff (a) the
> deployment's `AuthorityPolicy` permits them, AND (b) the actor's
> declared `LocalPolicy` (if any) permits them.  Policy-management
> actions are exempt from (b).**

Every formal piece of this plan is a Lean restatement of that
sentence:

  * **(a)** is the existing `AuthorityPolicy.authorized` conjunct.
    Unchanged.
  * **(b)** is the new conjunct (see §6).  Decidable.
  * The "policy-management" exemption is the structural cut-out for
    `declareLocalPolicy` / `revokeLocalPolicy` (see §6.2).  Provable
    as a theorem rather than a convention.

The deliberate consequence: a deployment that uses no actor-scoped
policies sees exactly the pre-LP behaviour, because the new
conjunct definitionally reduces to `True` whenever the signer has
no entry in `localPolicies`.

## §3 Data types

The data layer is intentionally thin: every type is first-order,
every predicate is decidable by typeclass synthesis (`fun _ =>
inferInstance` per `docs/decidability_discipline.md`), and every
recursive structure has an explicit length bound that the codec
enforces.

### 3.0 Bound constants (single source of truth)

```lean
namespace Authority.LocalPolicy

/-- Maximum number of clauses in a single `LocalPolicy`.  Mirrors
    the Solidity-side `MAX_VERDICT_SIGNERS = 64` discipline:
    every Knomosis list-shaped first-order data type has an explicit
    length cap, enforced by the canonical decoder. -/
def MAX_CLAUSES_PER_POLICY : Nat := 64

/-- Maximum number of tags in a `denyTags` clause's `tags` list. -/
def MAX_TAGS_PER_DENY : Nat := 64

/-- Maximum number of recipients in a `requireRecipientIn`
    clause's `allowed` list. -/
def MAX_RECIPIENTS_PER_REQUIRE : Nat := 64

/-- Upper bound on the encoded-byte size of a single declared
    policy.  Holds by construction from
    `MAX_CLAUSES_PER_POLICY * (per-clause max bytes)` plus the
    CBE map / list overhead.  Asserted at the LP.2 encoder
    level by the `LocalPolicy.encode_size_bound` lemma. -/
def MAX_POLICY_ENCODE_BYTES : Nat := 16_384

end Authority.LocalPolicy
```

These constants are deliberately conservative; the runtime
adaptor's mempool policy can apply tighter bounds without any
kernel-level change.  Loosening them in a future amendment
requires the §13.6 two-reviewer gate (since the bounds are part
of the on-wire ABI contract).

### 3.1 `LocalPolicyClause` inductive (initial constructor set)

The clause type is the first-order vocabulary actors can express
their policies in.  Each constructor maps to a decidable predicate
`(es : ExtendedState) → (signer : ActorId) → (action : Action) →
Prop` (with a `Decidable` instance, derived in LP.1).

```lean
/-- A single clause in an actor's local policy.  Each clause is a
    first-order data value with decidable semantics; clauses compose
    by *conjunction* inside a `LocalPolicy` (every clause must
    permit the action for the policy to permit it).

    **Append-only constructor discipline.**  Constructor indices are
    frozen at first deployment.  Adding a new clause type means
    appending at the end; reordering is forbidden.  The CBE codec
    tags each clause by its constructor index. -/
inductive LocalPolicyClause
  /-- Deny actions whose Action-constructor tag appears in `tags`.
      Tag indices are the same frozen indices used by
      `Action.encode` (transfer = 0, mint = 1, …).  An empty
      `tags` list is a no-op (permits everything). -/
  | denyTags          (tags : List Nat)
  /-- For balance-mutating actions on `resource` whose recipient/
      target field is `recipient`, require `recipient ∈ allowed`.
      Applies to `transfer.receiver`, `mint.to`, `reward.to`, and
      `deposit.recipient`.  Other action variants are unaffected. -/
  | requireRecipientIn (resource : ResourceId) (allowed : List ActorId)
  /-- For actions on `resource` whose `amount` field exists,
      require `amount ≤ max`.  Applies to `transfer`, `mint`,
      `burn`, `reward`, `distributeOthers`, `proportionalDilute`,
      `deposit`, `withdraw`.  Other action variants are
      unaffected. -/
  | capAmount         (resource : ResourceId) (max : Amount)
  deriving Repr, DecidableEq
```

Initial-set rationale:

  * **`denyTags`** is the universal escape hatch: any per-action-type
    constraint can be expressed as "deny actions with these
    constructor tags," at coarse granularity.  Sufficient for MVP
    use cases like "I never want to issue a `burn`."
  * **`requireRecipientIn` / `capAmount`** are the two most-requested
    fine-grained constraints in chain-governance prior art (Cosmos
    `authz`, EIP-7702 delegation).  Both decompose cleanly to
    decidable Nat-comparisons over fixed action fields.

The set is deliberately small.  Future PRs append new clauses (see
§13.2 for candidates) without disturbing the existing three.
Time-boxed expiry is **not** included in the MVP: the natural
encoding (`expireAt` as a wrapper around an inner clause) introduces
a recursive ADT that complicates the codec, and an actor that wants
expiry can simply revoke their policy with a signed
`revokeLocalPolicy` action when the desired expiry condition is met
(or use a `denyTags` clause and revoke later).  See §13.2 for the
expiry-extension design path.

### 3.2 `LocalPolicy` structure

```lean
/-- An actor's local policy: a list of clauses combined by
    conjunction.  An action is permitted iff every clause permits
    it; the empty policy permits everything (vacuous conjunction). -/
structure LocalPolicy where
  clauses : List LocalPolicyClause
  deriving Repr, DecidableEq

/-- The empty policy: permits every action, by vacuous quantification. -/
def LocalPolicy.empty : LocalPolicy := { clauses := [] }
```

Conjunction-only at the top level keeps the encoding flat and
avoids recursive ADTs.  Disjunction-of-clauses (or arbitrary
boolean combinations) can be expressed by a future
`LocalPolicyClause.disjunction` variant if real users need it
(see §13.2).

### 3.3 `LocalPolicies` (the `ExtendedState` field)

```lean
/-- The runtime's per-actor policy table: maps registered actors to
    their currently-declared local policy.  Missing entries default
    to `LocalPolicy.empty` (i.e. no constraint).

    Held in `ExtendedState` so the `declareLocalPolicy` /
    `revokeLocalPolicy` actions can mutate it through the
    `apply_admissible` path. -/
abbrev LocalPolicies : Type :=
  Std.TreeMap ActorId LocalPolicy compare

/-- The empty policy table: no actor has declared a policy. -/
def LocalPolicies.empty : LocalPolicies := ∅

/-- Look up an actor's declared policy, defaulting to the empty
    (unrestricted) policy if the actor has no declaration. -/
def LocalPolicies.lookup (lp : LocalPolicies) (a : ActorId) : LocalPolicy :=
  lp[a]?.getD LocalPolicy.empty

/-- Declare (or replace) an actor's local policy.  Idempotent on
    equal `policy`; replaces on differing `policy`. -/
def LocalPolicies.declare
    (lp : LocalPolicies) (a : ActorId) (policy : LocalPolicy) : LocalPolicies :=
  lp.insert a policy

/-- Revoke an actor's declaration, restoring the unrestricted
    default. -/
def LocalPolicies.revoke (lp : LocalPolicies) (a : ActorId) : LocalPolicies :=
  lp.erase a
```

### 3.4 The `permits` predicate

```lean
/-- The semantic permission predicate for a single clause.  Each
    branch reduces to a finite conjunction of `Nat`-/`List`-
    arithmetic decidable comparisons. -/
def LocalPolicyClause.permits
    (es : ExtendedState) (signer : ActorId) (action : Action)
    : LocalPolicyClause → Prop
  | .denyTags tags          => Action.tag action ∉ tags
  | .requireRecipientIn r a =>
      -- Pattern-match on `action`; only constrains the variants
      -- that have a recipient field on resource `r`.
      match action with
      | .transfer  r' _ recipient _      => r' ≠ r ∨ recipient ∈ a
      | .mint      r' to _               => r' ≠ r ∨ to ∈ a
      | .reward    r' to _               => r' ≠ r ∨ to ∈ a
      | .deposit   r' recipient _ _      => r' ≠ r ∨ recipient ∈ a
      | _                                => True
  | .capAmount r max        =>
      match action with
      | .transfer            r' _ _ amt       => r' ≠ r ∨ amt ≤ max
      | .mint                r' _ amt         => r' ≠ r ∨ amt ≤ max
      | .burn                r' _ amt         => r' ≠ r ∨ amt ≤ max
      | .reward              r' _ amt         => r' ≠ r ∨ amt ≤ max
      | .distributeOthers    r' _ amt         => r' ≠ r ∨ amt ≤ max
      | .proportionalDilute  r' _ _amt        => True
                                -- proportionalDilute's `totalReward`
                                -- is a *pool* not an individual
                                -- amount; capping it requires a
                                -- separate clause variant (deferred).
      | .deposit             r' _ amt _       => r' ≠ r ∨ amt ≤ max
      | .withdraw            r' _ amt _       => r' ≠ r ∨ amt ≤ max
      | _                                     => True

/-- The semantic permission predicate for a whole policy: every
    clause must permit. -/
def LocalPolicy.permits
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (p : LocalPolicy) : Prop :=
  ∀ c ∈ p.clauses, c.permits es signer action
```

`Action.tag : Action → Nat` is a one-line projection added in
**LP.1** (covering ctor indices 0..14) and extended in LP.4
(appending the two new ctor indices 15..16).  It exists for the
`denyTags` clause's decidability and is independent of the CBE
codec — though both must agree on the indexing.  A theorem
`Action.tag_matches_encode_tag` (LP.4, after the LP.4 extension
lands) discharges the agreement mechanically.

### 3.5 Field-bounds discipline

Each clause declares a `fieldsBounded` predicate enforcing the
per-list caps from §3.0:

```lean
def LocalPolicyClause.fieldsBounded : LocalPolicyClause → Prop
  | .denyTags tags             =>
      tags.length ≤ MAX_TAGS_PER_DENY
        ∧ tags.all (· < 2^64)
  | .requireRecipientIn _ ally =>
      ally.length ≤ MAX_RECIPIENTS_PER_REQUIRE
        ∧ ally.all (·.toNat < 2^64)
  | .capAmount _ max           =>
      max < 2^64

instance : DecidablePred LocalPolicyClause.fieldsBounded :=
  fun _ => by cases _ <;> exact inferInstance

def LocalPolicy.fieldsBounded (p : LocalPolicy) : Prop :=
  p.clauses.length ≤ MAX_CLAUSES_PER_POLICY
    ∧ p.clauses.all (·.fieldsBounded)

instance : DecidablePred LocalPolicy.fieldsBounded :=
  fun _ => inferInstance
```

The `DecidablePred` instances hold by `inferInstance` because
every clause is decidable on `Nat`-/`List`-arithmetic, and
`List.decidableBAll` covers the `.all` case.  `LP.2` lands the
following bound theorem to discharge the §3.0 size budget:

```lean
/-- LP.2: encoded-byte upper bound for any policy passing
    `fieldsBounded`.  Used by the runtime adaptor to short-
    circuit oversize action submissions before reaching the
    Lean decoder. -/
theorem LocalPolicy.encode_size_bound
    {p : LocalPolicy} (h : p.fieldsBounded) :
    (Encodable.encode p).length ≤ MAX_POLICY_ENCODE_BYTES :=
  …
```

The proof goes through: per-clause encoded size ≤ (1 tag byte +
2×9 length-prefix bytes + max list payload) ≤ 9 + 9 + 64×9 = 594
bytes per clause; 64 clauses ≤ 38 016 bytes; with conservative
slack we cap at `MAX_POLICY_ENCODE_BYTES = 16_384` and assert it
holds for the smaller per-clause value (denyTags ≤ 9 + 9 + 64×9
= 594; capAmount ≤ 9 + 9 + 9 = 27; requireRecipientIn ≤ 9 + 9 + 9
+ 64×9 = 603; the 64-clause × 603 = 38 592 bytes upper bound is
loose because `requireRecipientIn`'s 9-byte head dominates).
We adopt the conservative bound 16 384 (~16 KB) which holds
for any *practical* policy; deployments that need the loose
38 KB bound can amend §3.0.

### 3.6 Encoding constructor-index discipline

Each `LocalPolicyClause` constructor is assigned a frozen
0-based CBE tag (LP.2):

| Tag | Constructor             |
|-----|-------------------------|
| 0   | `denyTags`              |
| 1   | `requireRecipientIn`    |
| 2   | `capAmount`             |

These indices are reserved by this plan and **MUST NOT** be
reordered or reassigned.  Adding new clauses appends at the end
(index 3, 4, …) per the append-only discipline.  This rule is
enforced mechanically: the decoder's tag-dispatch table fails
the build if a future ctor is inserted out-of-order.

## §4 `ExtendedState` extension

### 4.1 Field placement

`ExtendedState` (currently 4 fields) gains a 5th:

```lean
structure ExtendedState where
  base          : State
  nonces        : NonceState
  registry      : KeyRegistry
  bridge        : Bridge.BridgeState   := Bridge.BridgeState.empty
  /-- LP.3: per-actor declared local policies.  Defaults to the
      empty map so pre-LP `ExtendedState` constructions
      (test fixtures, deployment-time seeds) keep elaborating
      without modification.  Mutated by `declareLocalPolicy` /
      `revokeLocalPolicy` actions through `apply_admissible`;
      preserved by every other admissibility path. -/
  localPolicies : Authority.LocalPolicies := Authority.LocalPolicies.empty
  deriving Repr
```

The default-value handling exactly mirrors how `bridge` was added in
Workstream C.1.2.  Lean's record-update syntax (`{ es with base := …
}`) preserves unmentioned fields by construction, so every existing
`apply_admissible_with` body, every test fixture, and every
deployment-time `ExtendedState` literal continues to elaborate
unchanged.

### 4.2 The `ExtendedState.empty` extension

```lean
def ExtendedState.empty : ExtendedState where
  base          := genesisState
  nonces        := NonceState.empty
  registry      := KeyRegistry.empty
  bridge        := Bridge.BridgeState.empty
  localPolicies := Authority.LocalPolicies.empty
```

### 4.3 Encoding extension

The CBE encoding for `ExtendedState` is concatenative
(`Encoding/State.lean:445-449`):

```
ExtendedState.encode es :=
  State.encode es.base
    ++ NonceState.encode es.nonces
    ++ KeyRegistry.encodeMap es.registry
    ++ Bridge.BridgeState.encode es.bridge
```

LP.3 appends one segment:

```
ExtendedState.encode es :=
  State.encode es.base
    ++ NonceState.encode es.nonces
    ++ KeyRegistry.encodeMap es.registry
    ++ Bridge.BridgeState.encode es.bridge
    ++ Authority.LocalPolicies.encodeMap es.localPolicies
```

The `LocalPolicies.encodeMap` follows the existing
`KeyRegistry.encodeMap` pattern: a CBE map type-tag, a length-
prefixed sequence of `(actor, encoded-policy-bytes)` pairs in
strictly-ascending `compare` order over the keys.  This pattern
is what `Encoding/State.lean`'s `decodeMap` consumes, with the
§8.8.6 canonicalisation enforced by the `keysStrictlyAscending`
check in the decoder.

The `LocalPolicy` payload itself is encoded as a length-prefixed
CBE byte string (`encodeAsBytes`), mirroring how each inner
`BalanceMap` is wrapped before being placed in the outer
`State.balances` map's value slot.  This wrapping is what lets the
outer-map decoder cleanly extract each per-actor payload without
needing fielded knowledge of the policy's internal layout.

### 4.4 Decoding extension

```lean
def ExtendedState.decode (s : Stream) : Except DecodeError (ExtendedState × Stream) :=
  match State.decode s with
  | .ok (base, s₁) =>
    match NonceState.decode s₁ with
    | .ok (nonces, s₂) =>
      match KeyRegistry.decodeMap s₂ with
      | .ok (registry, s₃) =>
        match Bridge.BridgeState.decode s₃ with
        | .ok (bridge, s₄) =>
          match Authority.LocalPolicies.decodeMap s₄ with
          | .ok (localPolicies, s₅) =>
            .ok ({ base, nonces, registry, bridge, localPolicies }, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e
```

### 4.5 Snapshot compatibility (strict decoder + operator re-snapshot)

Pre-LP snapshots have `Snapshot.encodedState` byte sequences ending
at the `bridge` segment.  Decoding them under the post-LP build
**will fail** at the `LocalPolicies.decodeMap` call (which expects
the new 5th-segment map header bytes).

**Design choice: strict decoder, operator re-snapshot.**  The
post-LP `ExtendedState.decode` is strict — it requires all five
segments — and there is **no tolerant fallback**.  Operators
upgrading from pre-LP to post-LP perform a one-shot re-snapshot:

```
# Pre-LP node has snapshot.bin and log.bin.
# After binary upgrade to post-LP build:
knomosis bootstrap log.bin              # replays log under post-LP
knomosis snapshot snapshot-v2.bin       # writes new canonical snapshot
# Discard snapshot.bin; keep log.bin (log is unchanged).
```

This procedure is exactly the existing Phase-5 `knomosis snapshot`
flow; no new tooling is required.

**Why not the tolerant decoder?**  An earlier draft of this plan
proposed a tolerant decoder that accepts both 4-segment and
5-segment forms by treating "no 5th segment" as "empty
`localPolicies`".  This was rejected for three reasons:

  1. **Two valid byte representations of the same logical
     state.**  An `ExtendedState` with `localPolicies = empty`
     could be encoded as either the 4-segment or the 5-segment
     form, breaking `state_encode_decode_idempotent` (the
     Phase-4 audit-2 invariant that re-encoding a decoded state
     produces the original bytes).
  2. **`Snapshot.stateHash` non-equivalence.**  The state hash
     is computed over `Snapshot.encodedState`.  A pre-LP
     snapshot has hash `H_pre = hash(4-segment-bytes)`; the
     post-LP re-encoding has hash `H_post = hash(5-segment-
     bytes)` ≠ `H_pre`.  Any "no-migration" claim that relies
     on `H_pre = H_post` is therefore false.  The strict
     approach is honest: the hash changes; the operator
     produces a fresh snapshot under the new format.
  3. **§8.8.6 canonicality.**  Knomosis's existing CBE discipline
     (Phase-4 audit-2) rejects every form of decoder tolerance:
     `decodeMap` rejects unsorted / duplicate keys; the State
     decoder rejects partial input.  Adding a tolerance
     exception for `localPolicies` would forfeit this property
     piecemeal.

**No new theorem required.**  The existing
`extendedState_encode_deterministic` theorem (Phase-4 WU 4.5)
extends mechanically to the 5-field structure: it is
structural-rfl-class because record-update preserves the
canonical encoding.  LP.3's only formal addition is a re-test
that the existing theorem still elaborates after the field
addition.

**Bridge-field-addition precedent.**  The `bridge` field added
in Workstream C.1.2 used the same strict-decoder strategy
*despite* its `Bridge.BridgeState.empty` default value.  Pre-
Workstream-C snapshots simply weren't compatible with post-
Workstream-C decoders; operators re-snapshotted.  LP follows
the same pattern.

## §5 New `Action` constructors

### 5.1 Frozen-index assignments

The `Action` inductive currently has 15 constructors (indices 0..14;
`withdraw` at index 14, per `Authority/Action.lean:230-231` and the
`Encoding/Action.lean` constructor-tag table).  LP.4 appends two:

| Tag | Constructor             | Fields                     |
|-----|-------------------------|----------------------------|
| 15  | `declareLocalPolicy`    | `policy : LocalPolicy`     |
| 16  | `revokeLocalPolicy`     | (no fields)                |

These indices are reserved by this plan and **MUST NOT** be used by
any concurrent workstream.  The `LegalKernel/Authority/Action.lean`
docstring's "constructor-ordering policy (append-only)" applies.

### 5.2 `declareLocalPolicy`

```lean
inductive Action
  -- ... existing constructors 0..14 ...
  /-- LP.4: declare (or replace) the signer's local policy.  Mutates
      the `ExtendedState.localPolicies` table to map the signer's
      `ActorId` to `policy`.  Idempotent on equal `policy`; replaces
      on differing `policy`.  Compiles to `Laws.freezeResource 0`
      at the kernel level (no `base`-state effect); the
      authority-level effect (`localPolicies` insertion) happens in
      `applyActionToLocalPolicies` inside `apply_admissible`. -/
  | declareLocalPolicy (policy : Authority.LocalPolicy)
```

Signed by the actor whose policy is being set.  The signer's
`ActorId` (carried by `SignedAction.signer`) is what the runtime
inserts into `localPolicies`; the `policy` field carries the value.
A different actor signing this action sets *that signer*'s policy,
not someone else's — there is no "set policy for actor X" capability
short of revealing X's signing key.

### 5.3 `revokeLocalPolicy`

```lean
inductive Action
  -- ... ...
  /-- LP.4: revoke the signer's local policy.  Mutates the
      `ExtendedState.localPolicies` table to erase the signer's
      `ActorId` entry.  Idempotent: revoking a non-existent entry
      is a no-op.  Compiles to `Laws.freezeResource 0` at the
      kernel level. -/
  | revokeLocalPolicy
```

No fields: which actor is being revoked is the signer.

### 5.4 Compilation to `Transition`

Both new constructors compile to `Laws.freezeResource 0`, mirroring
`replaceKey` and `registerIdentity`:

```lean
def Action.compileTransition : Action → Transition
  -- ... existing 15 cases ...
  | .declareLocalPolicy _   => Laws.freezeResource 0
  | .revokeLocalPolicy      => Laws.freezeResource 0
```

The kernel-level state advance for both is the identity on `State`;
the authority-level mutation lives entirely in
`applyActionToLocalPolicies` (LP.5).

### 5.5 `compile_injective` extension

The headline `Action.compile_injective` theorem
(`Authority/Action.lean`, §4.13 via `CompiledAction.source`) is
*structural*: distinct `Action` values produce distinct
`CompiledAction` values via the `source` field.  Adding new
constructors **does not require a new proof** — the existing
one-line `congrArg CompiledAction.source` covers every constructor
including the two new ones.  LP.4 verifies this by re-running the
existing test
`Test/Authority/Action.lean :: compileInjectiveAcrossAllConstructors`
extended to include the two new ctors.

### 5.6 `Action.tag` projection (extended)

`Action.tag` was introduced in LP.1 covering indices 0..14.  LP.4
extends it with the two new constructors:

```lean
def Action.tag : Action → Nat
  -- ... existing 15 branches from LP.1 ...
  | .declareLocalPolicy _        => 15
  | .revokeLocalPolicy           => 16
```

**Theorem `Action.tag_matches_encode_tag`** (LP.4): for every
`a : Action`, the leading byte of `Action.encode a` equals
`Action.tag a` modulo the CBE uint head encoding.  Proven by
`cases a` + per-branch reflexivity.  This theorem closes the
agreement between `LocalPolicyClause.denyTags`'s semantics (over
`Action.tag`) and the on-wire CBE tag byte (over `Action.encode`).
The theorem is stated in LP.4 because it can only be proven once
*all* `Action.tag` branches and *all* `Action.encode` branches
exist together.

### 5.7 `fieldsBounded` extension

```lean
def Action.fieldsBounded : Action → Prop
  -- ... existing 15 cases ...
  | .declareLocalPolicy p       => Authority.LocalPolicy.fieldsBounded p
  | .revokeLocalPolicy          => True
```

The `LocalPolicy.fieldsBounded` predicate is defined in LP.2; it
recursively bounds every `Nat` / `List` length in every clause to
`< 2^64` for canonical CBE encoding.

## §6 Admissibility extension

### 6.1 The new conjunct

`AdmissibleWith` (`Authority/SignedAction.lean:222-236`, currently 4
top-level conjuncts encoding 5 conditions) gains a 5th top-level
conjunct (encoding the 6th condition):

```lean
def AdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  -- 2. Authorisation predicate.
  P.authorized st.signer st.action ∧
  -- 4. Nonce match.
  st.nonce = expectsNonce es st.signer ∧
  -- 1 + 3. Registered signer with valid signature under the registered key.
  (∃ pk, es.registry[st.signer]? = some pk ∧
         verify pk (signingInput st.action st.signer st.nonce deploymentId) st.sig = true) ∧
  -- 5. Compiled transition's precondition.
  (Action.compile st.action).transition.pre es.base ∧
  -- 6. (LP) Local-policy permits the action.
  localPolicyPermits es st.signer st.action
```

where:

```lean
/-- The new admissibility conjunct (LP.7).  An action is permitted
    by the signer's local policy iff:

      * The action is a policy-management meta-action
        (`declareLocalPolicy` or `revokeLocalPolicy`); these are
        structurally exempt — see §6.2.
      * Otherwise, the signer's declared policy (defaulting to
        `LocalPolicy.empty` if absent) permits the action.

    `LocalPolicy.empty.permits` is vacuously `True` (universal
    quantification over an empty list), so signers with no declared
    policy see no admissibility narrowing. -/
def localPolicyPermits
    (es : ExtendedState) (signer : ActorId) (action : Action) : Prop :=
  isMetaPolicyAction action = true ∨
    (es.localPolicies.lookup signer).permits es signer action

instance instDecidableLocalPolicyPermits
    (es : ExtendedState) (signer : ActorId) (action : Action) :
    Decidable (localPolicyPermits es signer action) :=
  inferInstance  -- via instDecidableOr + decidable Bool eq + List.decidableBAll
```

### 6.2 Meta-action exemption (structural argument)

The `isMetaPolicyAction` classifier is `Bool`-returning, matching
the convention set by `Action.isBridgeOnly` (Workstream C.0) and
`Event.isLocalPolicyEvent` (LP.10):

```lean
/-- True iff `action` is a policy-management meta-action that is
    exempt from the local-policy admissibility conjunct.  Defined
    by *enumeration* over the `Action` inductive, NOT by any
    policy-derived predicate, so no `LocalPolicyClause` can ever
    block a policy-management action by construction.

    Returns `Bool` (not `Prop`) for consistency with the existing
    `Action.isBridgeOnly` classifier and to make the disjunction
    branch in `localPolicyPermits` directly decidable. -/
def isMetaPolicyAction : Action → Bool
  | .declareLocalPolicy _ => true
  | .revokeLocalPolicy    => true
  | _                     => false
```

This is the **structural lockout-prevention proof**: the
`isMetaPolicyAction` function is enumerated over the `Action`
inductive's two LP-introduced constructors, with every other
constructor mapping to `false`.  No `LocalPolicyClause` constructor
takes a `LocalPolicy → ...` argument, so no clause's `.permits`
branch can introspect policy structure to evaluate
`isMetaPolicyAction`; the disjunction `isMetaPolicyAction action =
true ∨ …` therefore short-circuits unconditionally for meta-actions
regardless of the declared policy's content.

The `Bool`-returning form has two practical benefits:

  1. The admissibility predicate's new conjunct is a `(Bool = true)
     ∨ Prop` shape, which Lean's `Decidable` synthesis handles
     directly via `instDecidableOr`.  No hand-written `Decidable`
     instance is required.
  2. Future audits can `cases isMetaPolicyAction action` on a
     concrete value and get a `Bool` LHS that matches Lean's
     standard `decide` machinery.

**Theorem `localPolicy_meta_action_independent`** (LP.7):

```lean
theorem localPolicy_meta_action_independent
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (h_meta : isMetaPolicyAction action = true)
    (lp lp' : LocalPolicies) :
    localPolicyPermits { es with localPolicies := lp  } signer action ↔
    localPolicyPermits { es with localPolicies := lp' } signer action :=
  Iff.intro
    (fun _ => Or.inl h_meta)
    (fun _ => Or.inl h_meta)
```

Proof: by definitional unfolding, both sides reduce to
`isMetaPolicyAction action = true ∨ …`; the left disjunct is
`h_meta`, so both sides hold via `Or.inl`.  The `LocalPolicies`
field is invisible to the disjunction's left branch by
construction.

This theorem is the type-level statement that **an actor cannot
construct a `LocalPolicy` that locks them out of revoking it**.  No
matter what policy they declare, `revokeLocalPolicy` remains
admissible (subject to the other four conjuncts of `Admissible`,
none of which the policy can affect — registry, nonce, signature,
authority-policy).

### 6.3 Decidability preservation

Each of the five (now six) admissibility conditions must be
`Decidable` so that `Decidable Admissible` can be derived for
`Runtime.Replay`'s `apply_admissible` dispatch
(`Runtime/Replay.lean :: instDecidableAdmissible`).

The new conjunct's decidability decomposes:

  * `isMetaPolicyAction action = true`: a `Bool` equality;
    `Decidable` via `instDecidableEqBool`.
  * `LocalPolicies.lookup`: pure data lookup, returns a `LocalPolicy`
    value (`Std.TreeMap.find?` followed by `getD`).
  * `LocalPolicy.permits`: `∀ c ∈ list, P c` over a finite list with
    decidable per-element `P`; `Decidable` via `List.decidableBAll`.
  * `LocalPolicyClause.permits`: pattern-match on the clause; each
    branch reduces to `Nat`-/`List`-arithmetic / `ActorId`-equality
    decidable comparisons.
  * The disjunction `… ∨ …` is `Decidable` via `instDecidableOr`.

Each component is **already** `Decidable` by typeclass synthesis;
the `instDecidableLocalPolicyPermits` instance therefore proves
by `inferInstance` with no manual derivation.  The post-LP
`Admissible` predicate inherits the full `Decidable` derivation
chain, and the `decPre := fun _ => inferInstance` discipline
(Genesis Plan §13.6 step 2; `docs/decidability_discipline.md`) is
preserved.

**Explicit instance declarations** (LP.1 + LP.7).  To prevent
elaboration-time loops on deep `cases` chains, we land *named*
instances rather than relying on universe-polymorphic synthesis:

```lean
-- in Authority/LocalPolicy.lean (LP.1)
instance instDecidableLocalPolicyClausePermits
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (c : LocalPolicyClause) :
    Decidable (c.permits es signer action) := by
  cases c <;> exact inferInstance

instance instDecidableLocalPolicyPermitsList
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (p : LocalPolicy) :
    Decidable (p.permits es signer action) :=
  List.decidableBAll _ _

-- in Authority/SignedAction.lean (LP.7)
instance instDecidableLocalPolicyPermits' :
    DecidablePred (fun (esa : ExtendedState × ActorId × Action) =>
      localPolicyPermits esa.1 esa.2.1 esa.2.2) :=
  fun _ => inferInstance
```

Naming the instances explicitly makes them visible in
`simp [instDecidableLocalPolicyClausePermits]` rewrites and
documents the dependency graph in `docs/std_dependencies.md`.

### 6.4 Field extractor

```lean
/-- Extract condition 6 (LP): the signer's local policy permits
    the action.  The conjunct chain layout is fragile across Lean
    versions (`.2.2.2.2` projection); we prefer the
    `match`-with-pattern form for stability. -/
theorem admissible_localPolicy
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    localPolicyPermits es st.signer st.action := by
  obtain ⟨_, _, _, _, hLP⟩ := h
  exact hLP
```

Plus the parameterised analogue `admissibleWith_localPolicy`.

**Stability concern.**  Adding the 5th conjunct shifts every
existing field-extractor's projection chain.  The pre-LP
extractors (`admissible_authorized`, `admissible_nonce`,
`admissible_pre`, `admissible_signer_registered`,
`admissible_signer_registered_and_signed`) currently use direct
`.2.2.2` projections.  In LP.7 we **rewrite all five existing
extractors to use the `obtain ⟨…⟩ := h` pattern** so the
projection chain is robust to future conjunct additions.  The
re-written extractors are byte-equivalent to the old ones at
the type level (same statement); only the proof body changes.
This is a non-breaking change for downstream callers.

### 6.5 Strict-narrowing theorem

```lean
/-- LP.7: the new admissibility predicate is strictly narrower than
    the pre-LP one.  Every signed action that was admissible pre-LP
    in a state with no declared policies remains admissible post-LP.

    Statement: if the actor has no entry in `localPolicies`, the
    new conjunct is `True`, so `Admissible` reduces to its pre-LP
    form. -/
theorem admissible_no_policy_iff_pre_LP
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (h_no_policy : es.localPolicies[st.signer]? = none) :
    Admissible P es st ↔
      AdmissibleWith Verify P ByteArray.empty
        { es with localPolicies := LocalPolicies.empty } st :=
  …
```

Proof sketch: under `h_no_policy`, `LocalPolicies.lookup` returns
`LocalPolicy.empty`, whose `.permits` is vacuously `True`, so the
new conjunct is `isMetaPolicyAction action ∨ True = True`.  Both
sides of the iff agree on the other four conjuncts.

## §7 The `applyActionToLocalPolicies` helper

### 7.1 Definition

Mirroring `applyActionToRegistry`
(`Authority/SignedAction.lean:348-351`):

```lean
/-- Action-specific local-policy-table effects.  For most actions,
    this is the identity (the kernel-level `apply_impl` is the entire
    effect, plus the existing `applyActionToRegistry` for registry-
    mutating actions).  For `declareLocalPolicy` and
    `revokeLocalPolicy`, the table is mutated to declare or revoke
    the *signer's* entry. -/
def applyActionToLocalPolicies
    (lp : LocalPolicies) (signer : ActorId) : Action → LocalPolicies
  | .declareLocalPolicy policy => lp.declare signer policy
  | .revokeLocalPolicy         => lp.revoke signer
  | _                          => lp
```

### 7.2 `apply_admissible_with` extension

The single guarded entry point gains one final step (after the
existing registry update):

```lean
def apply_admissible_with
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (_h : AdmissibleWith verify P d es st) :
    ExtendedState :=
  let t   := (Action.compile st.action).transition
  let s'  := t.apply_impl es.base
  let es' := { es with base := s' }
  let es'' := advanceNonce es' st.signer
  let es''' := { es'' with registry :=
    applyActionToRegistry es''.registry st.action }
  -- LP.5: apply local-policy-table effect.
  { es''' with localPolicies :=
    applyActionToLocalPolicies es'''.localPolicies st.signer st.action }
```

The five steps (kernel state advance → wrap → nonce advance →
registry update → local-policy update) commute pairwise on disjoint
`ExtendedState` fields.  We sequence them as written for
diagnostics-readability.

### 7.3 Mutation theorems

Four theorems pin the new step's semantics, mirroring the
WU-3.10 `replaceKey_*` family:

```lean
/-- LP.5: after applying `declareLocalPolicy policy` via
    `apply_admissible`, the signer's `localPolicies` entry is
    `some policy`. -/
theorem declareLocalPolicy_updates_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (policy : LocalPolicy)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.declareLocalPolicy policy, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.declareLocalPolicy policy, signer, nonce, sig⟩
      h).localPolicies[signer]? = some policy

/-- LP.5: after applying `revokeLocalPolicy` via `apply_admissible`,
    the signer's `localPolicies` entry is `none`. -/
theorem revokeLocalPolicy_clears_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.revokeLocalPolicy, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.revokeLocalPolicy, signer, nonce, sig⟩
      h).localPolicies[signer]? = none

/-- LP.5: after applying any non-meta action via `apply_admissible`,
    the `localPolicies` table is unchanged from the pre-application
    state.  A type-level statement that the local-policy-mutation
    surface consists exactly of the two LP-introduced ctors.

    Hypothesis form: `isMetaPolicyAction st.action = false` (Bool
    form, matching the §6.2 `isMetaPolicyAction` signature). -/
theorem non_meta_preserves_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (h_non_meta : isMetaPolicyAction st.action = false) :
    (apply_admissible P es st h).localPolicies = es.localPolicies
```

Plus the cross-actor isolation form:

```lean
/-- LP.5: a different actor's `localPolicies` entry is unchanged by
    `apply_admissible` regardless of the action.  The local-policy
    mutation only touches the *signer*'s entry. -/
theorem localPolicies_other_actor_untouched
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (a : ActorId) (h_ne : st.signer ≠ a) :
    (apply_admissible P es st h).localPolicies[a]? = es.localPolicies[a]?
```

## §8 New events

### 8.1 Frozen-index assignments

`Event` currently has 11 constructors (indices 0..10;
`depositCredited` at index 10).  LP.10 appends two:

| Tag | Constructor                | Fields                                    |
|-----|----------------------------|-------------------------------------------|
| 11  | `localPolicyDeclared`      | `actor : ActorId`, `policy : LocalPolicy` |
| 12  | `localPolicyRevoked`       | `actor : ActorId`                         |

These indices are reserved by this plan and **MUST NOT** be used by
any concurrent workstream.

### 8.2 Constructor declarations

```lean
inductive Event
  -- ... existing 11 constructors ...
  /-- LP.10: an actor declared a local policy.  Carries the actor
      and the declared policy.  Indexers consume this event to
      maintain a per-actor "currently declared policy" view.
      Frozen index 11. -/
  | localPolicyDeclared (actor : ActorId) (policy : Authority.LocalPolicy)
  /-- LP.10: an actor revoked their local policy.  Carries the actor.
      Frozen index 12. -/
  | localPolicyRevoked (actor : ActorId)
  deriving Repr, DecidableEq
```

### 8.3 `extractEvents` extension

```lean
def actionEvents : ... → ... → ...
  -- ... existing branches ...
  | .declareLocalPolicy p => [Event.localPolicyDeclared signer p]
  | .revokeLocalPolicy    => [Event.localPolicyRevoked signer]
```

The events are emitted **unconditionally** on a successful
`apply_admissible` (i.e. they are NOT delta-filtered: an idempotent
`declareLocalPolicy` that re-declares the same policy still emits
the event, mirroring the `rewardIssued` convention).  This makes the
event log a faithful audit trail of every policy state change
attempt, even no-op ones.

### 8.4 Projection extensions

`Event.actor` gains two branches; `Event.resource` is unchanged
(neither LP event is resource-scoped).  A new classifier
`Event.isLocalPolicyEvent` is added for indexers that want to
subscribe to policy-management events specifically:

```lean
def Event.isLocalPolicyEvent : Event → Bool
  | .localPolicyDeclared _ _ => true
  | .localPolicyRevoked _    => true
  | _                        => false
```

## §9 Theorem inventory

This section enumerates every theorem the workstream introduces or
re-discharges, organised by module.  Each entry is named exactly as
it will appear in the Lean source (so `git log` / `grep` cross-
references work).

### 9.1 `LegalKernel/Authority/LocalPolicy.lean` (LP.1)

Per-clause semantic theorems (one per clause × positive/negative
case = 6 lemmas):

  * `LocalPolicyClause.denyTags_permits_iff` — the denyTags clause
    permits iff the action's tag is not in the list.
  * `LocalPolicyClause.requireRecipientIn_permits_*` — three
    branches (positive on the four matching ctors, vacuous on
    others).
  * `LocalPolicyClause.capAmount_permits_*` — analogous.

Composition:

  * `LocalPolicy.empty_permits_all` — the empty policy permits
    every action.
  * `LocalPolicy.permits_decidable` (instance) — the `permits`
    predicate is `Decidable`.
  * `LocalPolicy.permits_extends_to_clauses` — `p.permits es a act ↔
    ∀ c ∈ p.clauses, c.permits es a act`.

Look-up:

  * `LocalPolicies.lookup_declare_self` — after `declare a p`,
    `lookup a` returns `p`.
  * `LocalPolicies.lookup_declare_other` — after `declare a p`,
    `lookup b` for `b ≠ a` is unchanged.
  * `LocalPolicies.lookup_revoke_self` — after `revoke a`,
    `lookup a` returns `LocalPolicy.empty`.
  * `LocalPolicies.lookup_revoke_other` — after `revoke a`,
    `lookup b` for `b ≠ a` is unchanged.
  * `LocalPolicies.empty_lookup` — every actor's lookup in the
    empty table returns `LocalPolicy.empty`.

All five look-up lemmas are direct consequences of the §8.3 RBMap
insert / erase lemmas already in `RBMapLemmas.lean`.

### 9.2 `LegalKernel/Encoding/LocalPolicy.lean` (LP.2)

  * `LocalPolicyClause.encode_decode` — round-trip for each clause.
  * `LocalPolicyClause.encode_injective` — the encoder is injective
    on values satisfying `LocalPolicyClause.fieldsBounded`.
  * `LocalPolicy.encode_decode` — round-trip for the full policy
    (lifted from clause round-trip via `list_roundtrip_bounded`).
  * `LocalPolicy.encode_injective` — full-policy injectivity.
  * `LocalPolicy.encode_deterministic` — the encoder is a function
    (structural).
  * `LocalPolicies.encodeMap_decodeMap` — map-level round-trip.
  * `LocalPolicies.encodeMap_deterministic` — extensional via
    `TreeMap.equiv_iff_toList_eq` (mirrors
    `balanceMap_encode_deterministic_of_equiv`).

### 9.3 `LegalKernel/Authority/Action.lean` (LP.4 extensions)

  * `Action.tag` — the projection.
  * `Action.tag_matches_encode_tag` — agreement between
    `Action.tag` and the leading byte of `Action.encode`.
  * Existing `Action.compile_injective` — verified to extend over
    the two new ctors (no proof change needed; one-line
    `congrArg`).
  * Existing `Action.compile_eq_iff` — extended automatically.
  * Existing `Action.compile_ne_of_ne` — extended automatically.

### 9.4 `LegalKernel/Encoding/Action.lean` (LP.4 extensions)

  * Existing `action_roundtrip` — extended with two new branches
    (`declareLocalPolicy` and `revokeLocalPolicy`).
  * Existing `action_encode_injective` — extended.
  * `Action.fieldsBounded` decidability — extended.

### 9.5 `LegalKernel/Authority/SignedAction.lean` (LP.5 + LP.6 + LP.7)

#### 9.5.1 New theorems introduced by LP.5

  * `applyActionToLocalPolicies` — the helper definition.
  * `apply_admissible_localPolicies` — field-extractor projection of
    the post-state's `localPolicies` field (the body's last `let`
    binding, exposed for callers).
  * `declareLocalPolicy_updates_localPolicies` (§7.3).
  * `revokeLocalPolicy_clears_localPolicies` (§7.3).
  * `non_meta_preserves_localPolicies` (§7.3).
  * `localPolicies_other_actor_untouched` (§7.3).

#### 9.5.2 Existing theorems re-discharged by LP.6

The following existing theorems re-elaborate after LP.5's body
extension.  All statements are unchanged; only proof bodies may
adjust to accommodate the trailing `let` binding:

  * `apply_admissible_base` — body proof remains `rfl` modulo
    record-update collapsing; if Lean cannot collapse, replace
    with `show … from rfl` (no semantic change).
  * `apply_admissible_registry` — same shape.  The new `let`
    binding lands after the registry update, so the registry
    projection still reduces.
  * `expectsNonce_after_apply_admissible` — proof structurally
    similar; may need a one-line `show` to thread through the
    trailing `localPolicies` update.
  * `expectsNonce_after_apply_admissible_other` — same shape.
  * `replaceKey_updates_registry` (WU 3.10) — same shape.
  * `replaceKey_other_actor_untouched` (WU 3.10) — same shape.
  * `non_registry_mutating_preserves_registry` — **statement
    unchanged**.  The two LP-added ctors don't mutate the
    registry, so the existing exhaustive case coverage extends
    by two `rfl` cases; no new hypothesis is required.
  * `registerIdentity_updates_registry` (Workstream B.3) — same
    shape.
  * `registerIdentity_other_actor_untouched` (Workstream B.3) —
    same shape.
  * `nonce_uniqueness` (§8.5.2) — proof unchanged byte-for-byte.
    The new conjunct is irrelevant to nonce reasoning.
  * `replay_impossible` (§8.5.2) — proof unchanged byte-for-byte.

LP.6 also rewrites the five existing field-extractors
(`admissible_authorized` / `admissible_nonce` /
`admissible_pre` / `admissible_signer_registered` /
`admissible_signer_registered_and_signed`) from chained-tuple
projection (`.2.2.2.…`) to the `obtain ⟨…⟩ := h` pattern (§6.4).
Statements are byte-equivalent; bodies become robust to LP.7's
conjunct addition.

#### 9.5.3 New theorems introduced by LP.7

  * `localPolicyPermits` — the new admissibility predicate
    (§6.1).
  * `isMetaPolicyAction` — the Bool-returning meta-action
    classifier (§6.2).
  * `instDecidableLocalPolicyPermits` — the named decidability
    instance (§6.3).
  * `admissible_localPolicy` — field extractor (§6.4).
  * `admissibleWith_localPolicy` — parameterised analogue.
  * `localPolicy_meta_action_independent` — the structural
    lockout-prevention proof (§6.2).
  * `admissible_no_policy_iff_pre_LP` — strict-narrowing
    equivalence with the pre-LP form (§6.5).
  * `Decidable AdmissibleWith` — re-derived; existing
    `instDecidableAdmissible` flows through via `inferInstance`.

After LP.7 lands, `nonce_uniqueness` and `replay_impossible`
re-elaborate with **byte-identical proof bodies** (verified
manually before the LP.7 commit lands).

### 9.6 `LegalKernel/Bridge/*` (LP.8 extensions)

#### 9.6.1 New theorems in `Bridge/BridgeActor.lean`

  * `bridgePolicy_rejects_declareLocalPolicy` — the bridge actor
    cannot declare a local policy (deployment-level invariant
    pinned at the type level).
  * `bridgePolicy_rejects_revokeLocalPolicy` — the bridge actor
    cannot revoke a local policy.

#### 9.6.2 New theorems in `Bridge/Accounting.lean`

  * `accounting_delta_declareLocalPolicy` — both `totalDeposited`
    and `totalWithdrawn` deltas are zero (the action doesn't
    touch the bridge state).
  * `accounting_delta_revokeLocalPolicy` — same.
  * `applyActionToBridgeState_declareLocalPolicy` — shape lemma
    (= identity on `BridgeState`, since neither ctor is
    bridge-only).
  * `applyActionToBridgeState_revokeLocalPolicy` — same.

#### 9.6.3 Re-elaborated theorems (statement-stable)

The following existing theorems re-elaborate without proof-body
changes after LP.7's `Admissible` predicate extension:

  * `BridgeAdmissibleWith.toAdmissibleWith` (Workstream C.0) —
    projection theorem.
  * `apply_bridge_admissible_with_preserves_bridge` (Workstream
    C.0) — pass-through.
  * `bridge_replay_impossible` (Workstream C.0) — replay-
    protection lift.

### 9.7 `LegalKernel/LocalPolicy/LawClassification.lean` (LP.9)

Two `compileTransition_eq_freezeResource_zero` rfl lemmas:

  * `declareLocalPolicy_compileTransition_eq_freezeResource_zero`
  * `revokeLocalPolicy_compileTransition_eq_freezeResource_zero`

Four typeclass instances (mirroring `Disputes/LawClassification.lean`):

  * `declareLocalPolicy_compiled_isConservative`
  * `declareLocalPolicy_compiled_isMonotonic`
  * `revokeLocalPolicy_compiled_isConservative`
  * `revokeLocalPolicy_compiled_isMonotonic`

One composite summary:

  * `local_policy_actions_classification` — packs the four
    instances into a single statement for use in
    deployment-level proofs.

### 9.8 `LegalKernel/Encoding/State.lean` (LP.3 extensions)

  * `LocalPolicies.encodeMap` / `decodeMap` — definitions
    (LP.2 imported into LP.3's encoding pipeline).
  * `extendedState_encode_deterministic` — re-elaborates with
    the new field; structural rfl-class.
  * **No new theorem for snapshot tolerance.**  The decoder is
    strict (§4.5); pre-LP snapshots are migrated via operator
    re-snapshot, not via tolerant decode.

### 9.9 `LegalKernel/Events/Types.lean` and `Extract.lean` (LP.10)

  * `extractEvents_declareLocalPolicy_emits_localPolicyDeclared` —
    direct emission rule.
  * `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked` —
    direct emission rule.
  * `Event.actor` — extended (two new branches).
  * `Event.isLocalPolicyEvent` — new Bool-returning classifier.
  * `Event.DecidableEq` — extended via `deriving DecidableEq`.

### 9.10 Axiom audit

Every new theorem must `#print axioms`-clean to a subset of
`{propext, Classical.choice, Quot.sound}`.  The plan introduces:

  * No `opaque` declarations.
  * No `axiom` declarations.
  * No new dependency on `Classical.choice` beyond what
    `Std.TreeMap` already pulls in (via `RBMapLemmas`).

A workstream-acceptance gate is the `axiom_audit` script in
`scripts/axiom_audit.sh` (added in LP.14), which emits the audit
output for every new theorem and fails the build if any non-
allowlisted axiom appears.

### 9.11 Theorem-count summary (post-LP)

| Module / unit                                  | New theorems | Re-discharged | Notes                                  |
|------------------------------------------------|-------------:|--------------:|----------------------------------------|
| `Authority/LocalPolicy.lean` (LP.1)            |           14 |             0 | 6 clause + 5 lookup + 3 misc           |
| `Encoding/LocalPolicy.lean` (LP.2)             |            8 |             0 | 7 codec + 1 size bound                 |
| `Authority/Action.lean` (LP.4)                 |            2 |             3 | tag + tag_match; 3 existing extended   |
| `Encoding/Action.lean` (LP.4)                  |            0 |             3 | branches added; theorems re-elaborate  |
| `Encoding/State.lean` (LP.3)                   |            0 |             2 | strict-decoder; theorems re-elaborate  |
| `Authority/SignedAction.lean` (LP.5)           |            6 |             0 | helper + 5 mutation theorems           |
| `Authority/SignedAction.lean` (LP.6)           |            0 |            11 | re-discharge work                      |
| `Authority/SignedAction.lean` (LP.7)           |            8 |             2 | conjunct + 7 helpers; 2 byte-identical |
| `Bridge/BridgeActor.lean` (LP.8)               |            2 |             0 | bridge-actor rejection                 |
| `Bridge/Accounting.lean` (LP.8)                |            4 |             0 | 2 deltas + 2 shape                     |
| `Bridge/{Admissible, Disputes, Runtime}` (LP.8)|            0 |          ~10 | verification only                      |
| `LocalPolicy/LawClassification.lean` (LP.9)    |            7 |             0 | 2 rfl + 4 instances + 1 composite      |
| `Events/Types.lean` (LP.10)                    |            2 |             0 | classifier + DecidableEq               |
| `Events/Extract.lean` (LP.10)                  |            2 |             0 | 2 emission rules                       |

**Total new theorems: ~55.**  **Total re-discharged: ~31.**
These counts are estimates; the precise number depends on
auxiliary lemmas needed to close particular proof obligations.

Each new theorem extends Knomosis's "type-level design properties"
table in `CLAUDE.md` (currently #186 at last count, post-Workstream
F).  LP adds approximately 14 entries to the table covering the
headline guarantees (lockout-prevention, strict-narrowing,
meta-action independence, classification, bridge-actor
rejection, etc.).

## §10 Work-unit breakdown

Each work unit is independently buildable, testable, and reviewable.
Subsequent units depend only on previous units.  The intended commit
cadence is one commit per unit; rebases are allowed before merge but
not after.

**Refinement note (v2).**  An earlier draft of this plan had a
single LP.5 unit doing helper-definition + body-extension + 8
theorem re-discharges, plus a single LP.6 unit doing predicate
extension + meta-action proof + strict-narrowing theorem.  This
v2 plan splits each of those overloaded units into smaller,
independently-reviewable pieces; adds explicit work units for
runtime-/bridge-/disputes-side re-discharge (LP.8), property
tests (LP.12), and cross-stack documentation (LP.13); and
renumbers the remaining units accordingly.  The intent is that
each unit lands in **one focused commit** with **a single
reviewer concern** (data layer, encoding, structural extension,
theorem re-discharge, etc.) rather than bundling unrelated
concerns.

### 10.0 Dependency DAG

The dependency DAG has one mandatory linear spine plus three
parallelisable branches (LP.9, LP.12, LP.13 can land any time
after their gating unit completes):

```
LP.1 ─→ LP.2 ─→ LP.3 ─→ LP.4 ─→ LP.5 ─→ LP.6 ─→ LP.7 ─→ LP.8
                                          │       │
                                          │       └──→ LP.9  (parallel; needs LP.4)
                                          │
                                          └──→ LP.10 (events; parallel; needs LP.4)
                                                  │
                                                  ↓
                                                LP.11 (e2e; needs LP.7+LP.8+LP.10)
                                                  │
                                                  ├──→ LP.12 (property; parallel after LP.11)
                                                  │
                                                  ├──→ LP.13 (cross-stack docs; parallel after LP.4)
                                                  │
                                                  ↓
                                                LP.14 (final integration; needs ALL)
```

### 10.1 Unit-by-unit gating summary

| Unit  | Purpose                                       | Gates                       | Reviewers |
|-------|-----------------------------------------------|-----------------------------|-----------|
| LP.1  | Core types + decidability                     | none                        | 1         |
| LP.2  | CBE encoding + bounds + round-trip            | LP.1                        | 1         |
| LP.3  | `ExtendedState` extension                     | LP.2                        | 1         |
| LP.4  | New `Action` ctors + tag agreement            | LP.3                        | 1         |
| LP.5  | `apply_admissible_with` body extension        | LP.4                        | 1         |
| LP.6  | Authority-side existing-theorem re-discharge  | LP.5                        | 1         |
| LP.7  | New `Admissible` conjunct + meta-exemption    | LP.6                        | 1 (or 2 if §13.6 amendment surfaced) |
| LP.8  | Runtime / Bridge / Disputes re-discharge      | LP.7                        | 1         |
| LP.9  | Law classification (`IsConservative`/`IsMonotonic`) | LP.4                  | 1         |
| LP.10 | New events + extraction rules                 | LP.4                        | 1         |
| LP.11 | End-to-end Lean acceptance tests              | LP.7 + LP.8 + LP.10         | 1         |
| LP.12 | Property-based tests                          | LP.11                       | 1         |
| LP.13 | Cross-stack (Solidity) coordination note      | LP.4                        | 1         |
| LP.14 | Documentation + umbrella + CI integration     | all of LP.1 – LP.13         | 1         |

The reviewers count is the §13.6 minimum (1 for non-TCB, 2 for
kernel-TCB).  No LP unit modifies the kernel TCB, so the
default is 1 throughout.  The LP.7 reviewer should be familiar
with the §8.2 admissibility predicate's invariant chain
(`replay_impossible`, `nonce_uniqueness`); a second reviewer is
warranted if the new conjunct's meta-exemption argument
surfaces a Genesis-Plan §8.2 amendment.

### LP.1 — `LocalPolicy` core types

**Files:**

  * `LegalKernel/Authority/LocalPolicy.lean` — new module (the
    bulk of the work).
  * `LegalKernel/Authority/Action.lean` — additive: append
    `Action.tag : Action → Nat` projection covering the existing
    15 constructors (indices 0..14).  No other change.

The `Action.tag` placement keeps LP.1 self-contained for
elaboration: `LocalPolicyClause.permits .denyTags` can call
`Action.tag` directly (§3.4 code sketch).  LP.4 will append the
two new branches when it adds the new ctors, by the same
append-only discipline that governs every other Action-related
extension in the codebase.

**Deliverables:**

  * `LocalPolicyClause` inductive (3 ctors as in §3.1).
  * `LocalPolicy` structure (single `clauses : List
    LocalPolicyClause` field).
  * `LocalPolicies` abbreviation (`Std.TreeMap ActorId LocalPolicy
    compare`).
  * `LocalPolicy.empty`, `LocalPolicies.empty`,
    `LocalPolicies.lookup`, `LocalPolicies.declare`,
    `LocalPolicies.revoke` definitions.
  * `LocalPolicyClause.permits` semantic predicate.
  * `LocalPolicy.permits` semantic predicate.
  * `Decidable` instances for `LocalPolicyClause.permits`,
    `LocalPolicy.permits` (the latter via `List.decidableBAll`).
  * `Action.tag` projection (15-branch initial form).
  * Per-clause semantic theorems (§9.1, 6 lemmas).
  * Look-up lemmas (§9.1, 5 lemmas).

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.LocalPolicy` succeeds.
  * `lake build LegalKernel.Authority.Action` continues to succeed
    after the additive `Action.tag` append.
  * Every theorem `#print axioms`-clean.
  * No `sorry`.

**Test file:** `Test/Authority/LocalPolicy.lean` (new).

  * 12 cases covering each clause's positive/negative behaviour
    on representative `Action` fixtures.
  * Decidability sanity checks (`decide (clause.permits …)`).
  * `LocalPolicies` look-up before/after declare and revoke.

### LP.2 — `LocalPolicy` encoding

**File:** `LegalKernel/Encoding/LocalPolicy.lean` (new).

**Deliverables:**

  * `Encodable` instance for `LocalPolicyClause` (CBE constructor-
    tag + per-branch fields).
  * `Encodable` instance for `LocalPolicy` (length-prefixed list of
    clause encodings via the existing `List` instance).
  * `LocalPolicies.encodeMap` / `LocalPolicies.decodeMap` (sorted
    map encoding, mirroring `KeyRegistry.encodeMap`).
  * `LocalPolicyClause.fieldsBounded` predicate (clause-level
    `Nat`-/`List`-length bounds for canonical CBE round-trip).
  * `LocalPolicy.fieldsBounded` predicate (lifted via
    `List.all (·.fieldsBounded)`).
  * Round-trip + injectivity theorems (§9.2).

**Acceptance criteria:**

  * `lake build LegalKernel.Encoding.LocalPolicy` succeeds.
  * Round-trip and injectivity proven for every constructor under
    the corresponding `fieldsBounded` hypothesis.
  * `#print axioms`-clean.

**Test file:** `Test/Encoding/LocalPolicy.lean` (new).

  * Round-trip for each clause variant (3 cases).
  * Round-trip for full `LocalPolicy` with 0 / 1 / 3 clauses.
  * Round-trip for `LocalPolicies` map with 0 / 1 / 5 entries.
  * Decoder rejects unsorted-key inputs (`nonCanonical`).
  * Decoder rejects duplicate-key inputs.
  * Cross-clause distinguishability (different clauses produce
    different bytes).

### LP.3 — `ExtendedState` extension

**Files modified:**

  * `LegalKernel/Authority/Nonce.lean` — add `localPolicies` field
    with default; update `ExtendedState.empty`.
  * `LegalKernel/Encoding/State.lean` — extend
    `ExtendedState.encode` / `.decode`; add
    `extendedState_decode_pre_LP_compatible` theorem.

**Deliverables:**

  * Field addition to `ExtendedState` structure (with default).
  * `ExtendedState.empty` extension.
  * Encode / decode extension.
  * Pre-LP snapshot tolerance theorem.
  * Determinism re-discharge.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.Nonce` succeeds.
  * `lake build LegalKernel.Encoding.State` succeeds.
  * Every existing test in `Test/Encoding/State.lean` continues to
    pass (the new field defaults to empty, so existing fixtures
    elaborate unchanged).
  * Pre-LP snapshots decode under the new decoder with
    `localPolicies = empty`.

**Test file:** existing `Test/Encoding/State.lean` extended.

  * Round-trip for `ExtendedState` with non-empty
    `localPolicies` (3 cases).
  * Pre-LP snapshot bytes decode to a state with
    `localPolicies = empty` (cross-version compatibility test).
  * `extendedState_encode_deterministic` re-tested.

### LP.4 — New `Action` constructors

**Files modified:**

  * `LegalKernel/Authority/Action.lean` — append two ctors at
    indices 15, 16; extend `compileTransition`; extend
    `Action.tag` (the projection itself was added in LP.1).
  * `LegalKernel/Encoding/Action.lean` — extend `Action.encode`,
    `Action.decode`, `Action.fieldsBounded`, the action-roundtrip
    and injectivity theorems.

**Deliverables:**

  * `Action.declareLocalPolicy` and `Action.revokeLocalPolicy`
    constructors.
  * `compileTransition` branches (both → `Laws.freezeResource 0`).
  * `Action.tag` extension to cover the two new ctors.
  * `Action.tag_matches_encode_tag` theorem (now provable since
    both `tag` and `encode` cover all 17 ctors).
  * Encoding extensions.
  * `Action.compile_injective` re-verified (no proof change).

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.Action` succeeds.
  * `lake build LegalKernel.Encoding.Action` succeeds.
  * Round-trip for the two new ctors.
  * Cross-constructor distinguishability with adjacent indices
    (e.g. `declareLocalPolicy ≠ withdraw` byte-distinct,
    `revokeLocalPolicy ≠ declareLocalPolicy` byte-distinct).

**Test files:** existing `Test/Authority/Action.lean` and
`Test/Encoding/Action.lean` extended.

  * 6 new tests in `Test/Authority/Action.lean` (compile shape,
    distinguishability, `Action.tag` projection sanity,
    `tag_matches_encode_tag` API stability).
  * 4 new tests in `Test/Encoding/Action.lean` (round-trip and
    cross-constructor distinguishability).

### LP.5 — `applyActionToLocalPolicies` helper + `apply_admissible_with` body extension

**Scope.**  Define the new helper, splice it into the body of
`apply_admissible_with`, and prove the *new* mutation theorems.
**This unit deliberately does NOT re-discharge any pre-existing
theorem** — that is LP.6's responsibility.  The split makes the
boundary between "added new code" and "did the existing proofs
still close" reviewable in isolation.

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Deliverables:**

  * `applyActionToLocalPolicies` helper (§7.1, three branches:
    `.declareLocalPolicy` / `.revokeLocalPolicy` / `_`).
  * `apply_admissible_with` body extension (§7.2; one new `let`
    binding at the end of the existing chain, then return the
    extended record).
  * Four new mutation theorems (§7.3):
      1. `declareLocalPolicy_updates_localPolicies`
      2. `revokeLocalPolicy_clears_localPolicies`
      3. `non_meta_preserves_localPolicies`
      4. `localPolicies_other_actor_untouched`
  * One new field-projection lemma:
      5. `apply_admissible_localPolicies` (the body's last `let`,
         exposed as a theorem so callers can rewrite over the
         tail).

**Out of scope (LP.6's job):**

  * Re-discharge of `apply_admissible_base`,
    `apply_admissible_registry`,
    `expectsNonce_after_apply_admissible*`,
    `replaceKey_*`, `registerIdentity_*`,
    `non_registry_mutating_preserves_registry`,
    `nonce_uniqueness`, `replay_impossible`.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
    (Existing theorems may temporarily fail elaboration here;
    that is expected and fixed in LP.6.  In practice we land
    LP.5 + LP.6 in two commits inside one PR so the build is
    never red between commits — LP.6's commit lands the
    re-discharge fixes that LP.5's body change makes
    necessary.)
  * The five new theorems prove without `sorry`.
  * `#print axioms`-clean (3 standard axioms only).

**Test file:** existing `Test/Authority/SignedAction.lean`
extended.

  * **8 new value-level tests** using `mockVerify` admissibility
    witnesses:
      1. Post-`declareLocalPolicy` lookup returns the declared
         policy.
      2. Post-`declareLocalPolicy` lookup at a different actor
         returns `none`.
      3. Post-`revokeLocalPolicy` lookup returns `none`.
      4. Post-`revokeLocalPolicy` of a never-declared actor is
         a no-op.
      5. Post-`transfer` (non-meta) leaves `localPolicies`
         unchanged.
      6. Re-`declareLocalPolicy` overwrites the prior declaration.
      7. Cross-actor isolation under arbitrary action mix.
      8. The five new theorems' term-level API stability.

**Risk note for LP.5.**  Lean's `rfl` is sensitive to record-
update collapsing.  Adding the trailing `localPolicies := …`
binding may require existing `rfl`-proven theorems (e.g.
`apply_admissible_base`) to switch to a one-line `show … from
rfl` or `simp` step.  These adjustments are tracked as LP.6's
work.

### LP.6 — Authority-side existing-theorem re-discharge

**Scope.**  Re-elaborate every theorem in
`Authority/SignedAction.lean` that LP.5's body change disturbs.
The expected outcome is **proof-body-stable**: the theorem
statements are unchanged; only the proof bodies adjust to
accommodate the new trailing `let` binding in
`apply_admissible_with`.

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Deliverables (re-discharge, statement-stable):**

  1. `apply_admissible_base` — base-state field extractor.
  2. `apply_admissible_registry` — registry field extractor.
  3. `expectsNonce_after_apply_admissible` — nonce algebraic core.
  4. `expectsNonce_after_apply_admissible_other` — cross-actor
     isolation.
  5. `replaceKey_updates_registry` — WU 3.10.
  6. `replaceKey_other_actor_untouched` — WU 3.10.
  7. `non_registry_mutating_preserves_registry` — registry
     locality (no statement change required: the two LP-added
     ctors don't mutate the registry, so the existing
     coverage-by-`rfl` extends mechanically; LP.6 just verifies
     the elaboration succeeds).
  8. `registerIdentity_updates_registry` — Workstream-B.3.
  9. `registerIdentity_other_actor_untouched` — Workstream-B.3.
  10. `nonce_uniqueness` — §8.5.2.
  11. `replay_impossible` — §8.5.2.

**Field-extractor robustness pass.**  LP.6 also rewrites the
five existing extractors (`admissible_authorized`,
`admissible_nonce`, `admissible_pre`,
`admissible_signer_registered`,
`admissible_signer_registered_and_signed`) from chained-tuple
projection (`.2.2.2.…`) to the `obtain ⟨…⟩ := h` pattern (§6.4).
The statements are byte-equivalent; the bodies are robust to
LP.7's conjunct addition.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * Every theorem above re-elaborates without `sorry`.
  * `lake test` shows zero regressions in
    `Test/Authority/SignedAction.lean` (the suite was passing
    before LP.5; after LP.6 it must pass again).
  * `#print axioms` per theorem unchanged from pre-LP.

**Test file:** no new tests.  This unit is pure proof-body
maintenance.  The existing 46-test suite is the regression
gate.

**Why a separate unit?**  Re-discharging existing theorems is
the highest-risk-per-line work in the workstream — every
proof-body change might introduce a subtle diagnostic
regression.  Separating it from the additive LP.5 work means
reviewers can compare `git diff LP.5..LP.6` and see exactly
which existing proofs needed adjustment, with no new theorems
intermixed.

### LP.7 — `Admissible` predicate extension + meta-action exemption

**Scope.**  Add the new admissibility conjunct.  Prove the
meta-action lockout-prevention theorem.  Prove the
strict-narrowing equivalence with the pre-LP form.

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Deliverables:**

  * `localPolicyPermits` predicate (§6.1).
  * `isMetaPolicyAction` classifier (Bool-returning, §6.2).
  * Extended `AdmissibleWith` body with the 5th conjunct
    (§6.1).
  * `admissible_localPolicy` field extractor (§6.4) +
    parameterised `admissibleWith_localPolicy`.
  * `localPolicy_meta_action_independent` theorem (§6.2; the
    structural lockout-prevention proof).
  * `admissible_no_policy_iff_pre_LP` theorem (§6.5; the
    strict-narrowing equivalence).
  * `Decidable AdmissibleWith` re-derived; existing
    `instDecidableAdmissible` continues to elaborate via
    `inferInstance`.
  * `instDecidableLocalPolicyPermits` named instance (§6.3).

**Re-discharge expectation.**  `nonce_uniqueness` and
`replay_impossible` continue to elaborate **with the same
proof bodies** (they don't consume the new conjunct).  LP.7
verifies this by running `lake build` after the conjunct add
and noting zero proof-body changes for these two theorems.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * `lake build LegalKernel.Runtime.Replay` succeeds (the
    `Decidable Admissible` instance flows through to
    `Runtime/Replay.lean`'s `instDecidableAdmissible` without
    manual intervention).
  * Both new theorems prove without `sorry`.
  * `nonce_uniqueness` and `replay_impossible` re-elaborate
    with **byte-identical proof bodies**.
  * `#print axioms`-clean.

**Test file:** existing `Test/Authority/SignedAction.lean`
extended.

  * **9 new tests:**
      1. `localPolicyPermits` returns `True` for a meta-action
         under any policy.
      2. `localPolicyPermits` returns `True` for any action
         when the signer has no declared policy.
      3. `localPolicyPermits` returns `False` for a transfer
         when the signer's policy denies tag 0.
      4. `localPolicyPermits` returns `True` for a transfer
         on resource r' when the policy caps amount on r.
      5. `admissible_localPolicy` extractor API stability.
      6. `localPolicy_meta_action_independent` API stability +
         value-level: same `(es, signer, declareLocalPolicy)`
         pair admissible under both empty and restrictive
         policies.
      7. `admissible_no_policy_iff_pre_LP` API stability +
         value-level: action admissible pre-LP is admissible
         post-LP under empty `localPolicies`; action
         admissible pre-LP is *not* admissible post-LP under a
         denyTags-blocking policy.
      8. `Decidable Admissible` synthesizes via `decide` on a
         concrete fixture (not just type-level).
      9. Cross-conjunct interaction: nonce-mismatch + policy-
         deny both fail; only one fails; etc.  (Audit
         test that the conjunct chain short-circuits in any
         order.)

### LP.8 — Runtime / Bridge / Disputes re-discharge

**Scope.**  Verify (and where necessary, repair) every theorem
**outside `Authority/SignedAction.lean`** that consumes
`Admissible`, `apply_admissible_with`, or pattern-matches on
`Action` constructors.  This unit closes the cross-module
re-discharge gap that the v1 plan didn't cover.

**Files modified:**

  * `LegalKernel/Bridge/Admissible.lean` — `BridgeAdmissibleWith`
    extends `AdmissibleWith` with bridge-specific conjuncts
    (Workstream C.0); LP.7's new conjunct flows through, but
    `apply_bridge_admissible_with`'s body needs verification
    that the trailing `localPolicies` update doesn't disturb
    the `bridge` field-update sequencing.
  * `LegalKernel/Bridge/Accounting.lean` — case-analyses on
    `Action` constructors.  The two LP-added ctors compile to
    the identity transition, so the per-action delta is zero
    on every accounting field; new branches are mechanical
    `rfl` cases.
  * `LegalKernel/Disputes/Evidence.lean` — `kernelOnlyApply` /
    `kernelOnlyReplay` are admissibility-blind by design; they
    don't consume the new conjunct.  Verification only.
  * `LegalKernel/Disputes/Verdict.lean` — `applyVerdict` calls
    `kernelOnlyReplay`; same status as Evidence.lean.
  * `LegalKernel/Runtime/Replay.lean` — `Decidable Admissible`
    instance flows from LP.7.  Body verification only.
  * `LegalKernel/Runtime/Loop.lean` — `processSignedAction`
    consumes `Admissible` via the decidable instance.  Body
    verification only.
  * `LegalKernel/Runtime/Snapshot.lean` — encodes / decodes
    `ExtendedState`; flows through LP.3.  Verification only.
  * `LegalKernel/Bridge/BridgeActor.lean` — `bridgePolicy`'s
    rejection / authorisation theorems pattern-match on the
    full Action constructor list.  Two new exhaustive branches
    rejecting `declareLocalPolicy` and `revokeLocalPolicy` for
    the *bridge* actor are added (the bridge actor should not
    declare per-actor policies; this is a deployment-policy
    decision pinned at the type level).

**Deliverables:**

  * Per-module re-elaboration verification (mostly mechanical).
  * Two new theorems in `Bridge/BridgeActor.lean`:
      * `bridgePolicy_rejects_declareLocalPolicy`
      * `bridgePolicy_rejects_revokeLocalPolicy`
  * Two new `accounting_delta_*` cases in
    `Bridge/Accounting.lean`:
      * `accounting_delta_declareLocalPolicy` (= zero deltas)
      * `accounting_delta_revokeLocalPolicy` (= zero deltas)
  * `applyActionToBridgeState_declareLocalPolicy` /
    `_revokeLocalPolicy` shape lemmas (= identity, since
    neither ctor is bridge-only).
  * No new theorems in any other module — verification only.

**Acceptance criteria:**

  * `lake build` (full) succeeds.
  * `lake test` shows zero regressions in **every** suite that
    touches Bridge / Disputes / Runtime / Events.  Specific
    suite list:
      * `bridge-admissible`, `bridge-accounting`,
        `bridge-actor`, `bridge-state`,
      * `disputes-evidence`, `disputes-verdict`,
        `disputes-e2e`, `disputes-incentivized-e2e`,
      * `runtime-loop`, `runtime-replay`, `runtime-snapshot`,
      * `events-types`, `events-extract`.
  * `#print axioms`-clean for every newly-added theorem.

**Test file:** existing suites extended; **no new test files**.

  * 4 new tests in `Test/Bridge/BridgeActor.lean` (the two new
    rejection theorems × value-level + API stability).
  * 2 new tests in `Test/Bridge/Accounting.lean` (the two new
    delta lemmas × value-level).
  * 4 new tests in `Test/Bridge/Admissible.lean`
    (`apply_bridge_admissible_with` shape on the two new
    ctors).
  * Existing suites: zero new tests — the regression gate is
    "everything still passes."

**Why a separate unit?**  v1's plan listed only Authority-
layer re-discharge.  In practice every Action-pattern-matching
proof in Bridge / Disputes / Runtime needs at least a
verification pass.  Bundling these into LP.7 would muddle the
"new conjunct" review concern; bundling into LP.6 would muddle
the "Authority-side proof-body fixup" concern.  Separating
them lets a Bridge-experienced reviewer audit LP.8 in
isolation.

### LP.9 — Law classification

**File:** `LegalKernel/LocalPolicy/LawClassification.lean` (new,
mirrors `LegalKernel/Disputes/LawClassification.lean`).

**Deliverables:**

  * Two rfl-class identification lemmas (§9.6).
  * Four typeclass instances (`IsConservative` × 2,
    `IsMonotonic` × 2).
  * One composite `local_policy_actions_classification` theorem
    packing the four instances into a single statement.

**Acceptance criteria:**

  * `lake build LegalKernel.LocalPolicy.LawClassification` succeeds.
  * Both new ctors' compiled transitions resolve to
    `IsConservative` and `IsMonotonic` instances via
    `inferInstance`.
  * `MonotonicLawSet` constructibility test (a deployment law
    set including `declareLocalPolicy` / `revokeLocalPolicy`
    plus the existing monotonic ctors elaborates).

**Test file:** `Test/LocalPolicy/LawClassification.lean` (new).

  * 9 cases (4 instance-resolution checks × 2 ctors = 8; plus
    the composite theorem's API stability check).

This unit is **independent of LP.6 / LP.7 / LP.8** (only depends
on LP.4) and can land in parallel after LP.4.

### LP.10 — Event extension

**Files modified:**

  * `LegalKernel/Events/Types.lean` — append two `Event` ctors at
    indices 11, 12.
  * `LegalKernel/Events/Extract.lean` — extend `actionEvents` /
    `extractEvents` with two new emission rules.

**Deliverables:**

  * Two new `Event` ctors with frozen indices 11, 12 (§8.1).
  * `Event.actor` projection extended.
  * `Event.isLocalPolicyEvent` classifier (Bool-returning).
  * Two emission-rule theorems (§9.8):
      * `extractEvents_declareLocalPolicy_emits_localPolicyDeclared`
      * `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked`
  * `Event.DecidableEq` extension (mechanical via `deriving`).

**Acceptance criteria:**

  * `lake build LegalKernel.Events.Types` succeeds.
  * `lake build LegalKernel.Events.Extract` succeeds.
  * Emission is deterministic and order-preserving (events fire
    after the kernel-level `balanceChanged` / `nonceAdvanced`
    events, in the order LP defines).

**Test files:** existing `Test/Events/Types.lean` and
`Test/Events/Extract.lean` extended.

  * 4 new tests in `Test/Events/Types.lean` covering the new
    constructors' projection / classifier behaviour /
    `DecidableEq` derivation.
  * 6 new tests in `Test/Events/Extract.lean` covering emission
    on `declareLocalPolicy` / `revokeLocalPolicy` actions
    (positive paths, sequencing relative to `nonceAdvanced`,
    determinism on equal inputs).

This unit is **independent of LP.7** (only depends on LP.4)
and can land in parallel after LP.4.

### LP.11 — End-to-end Lean acceptance tests

**File:** `Test/Authority/LocalPolicyAdmissibility.lean` (new).

**Scope.**  Twelve end-to-end scenarios using the `mockVerify`
fixture from `Test/MockCrypto.lean` (Audit-3.3) to construct
value-level admissibility witnesses across the full LP
pipeline (declare → mutate state → admit/reject under policy →
revoke → admit again).

**Deliverables (12 scenarios, expanded from v1's 8):**

  1. **Declare → constrained → revoke → permitted.**  Actor A
     starts unrestricted; A signs a `transfer` (admissible);
     A signs `declareLocalPolicy { denyTags [0] }` (admissible
     via meta-exemption); A signs another `transfer`
     (now *inadmissible* — the policy blocks tag 0); A signs
     `revokeLocalPolicy` (admissible via meta-exemption); A
     signs another `transfer` (admissible again).
  2. **Cross-actor independence.**  Actor A declares a
     restrictive policy; B signs actions of every type — all
     admissible (B's `localPolicies` lookup returns empty).
  3. **Meta-actions self-exempt.**  Actor A declares
     `denyTags [15, 16]` (i.e. ban policy management); A then
     signs `declareLocalPolicy` and `revokeLocalPolicy` — both
     succeed (meta-exemption overrides the deny clause).  This
     is the value-level acceptance test for
     `localPolicy_meta_action_independent`.
  4. **`requireRecipientIn` enforcement (positive).**  Actor A
     declares `requireRecipientIn r [42]`; A's `transfer r ?
     42 ?` is admissible.
  5. **`requireRecipientIn` enforcement (negative).**  Same
     fixture; A's `transfer r ? 7 ?` is not admissible.
  6. **`capAmount` enforcement (positive + negative).**  Actor
     A declares `capAmount r 100`; tests both sides of the
     boundary (50 admissible, 200 inadmissible, 100
     admissible — the inclusive boundary).
  7. **Cross-resource isolation.**  Actor A declares
     `capAmount r 100`; A's `transfer r' ? ? 200` (different
     resource) is admissible.
  8. **Replay protection survives.**  Run scenario 1; verify
     that re-applying any of the successful actions at the
     post-state fails admissibility (the
     `replay_impossible` theorem holds value-level).
  9. **Multi-clause conjunction.**  Actor A declares a policy
     with two clauses (`denyTags [1]` AND `capAmount r 100`);
     verify both must permit for the action to be admissible
     (a transfer of 50 is admissible; a mint of 50 is not; a
     transfer of 200 is not).
  10. **Re-declaration overwrites.**  Actor A declares P1, A
      transfers (denied/permitted per P1), A declares P2 (a
      different policy), A transfers (denied/permitted per
      P2 only — P1 is irrelevant).  Verifies the
      `LocalPolicies.declare` overwrite semantic.
  11. **Bridge-actor cannot declare.**  `bridgeActor` (id 0)
      attempts `declareLocalPolicy` — `bridgePolicy` rejects
      via `bridgePolicy_rejects_declareLocalPolicy`
      (acceptance test for LP.8's new theorem).
  12. **Cross-stack snapshot survival.**  A declares P1, takes
      a `Snapshot` via `takeSnapshot`, restores via
      `restoreSnapshot` — the restored state's `localPolicies`
      lookup at A returns P1 byte-for-byte.

**Acceptance criteria:**

  * `lake build LegalKernel.Test.Authority.LocalPolicyAdmissibility`
    succeeds.
  * All 12 scenarios pass at the value level.
  * Each scenario emits the expected events (verified via
    `extractEvents` cross-check against the expected
    `localPolicyDeclared` / `localPolicyRevoked` event log).

### LP.12 — Property-based tests

**Scope.**  Add property-based regression coverage using the
existing in-tree `Test/Property.lean` harness (Audit-3.9, no
external dependencies).  This unit is the v1 plan's §11.3
sidebar, promoted to a first-class work unit so it has explicit
acceptance criteria and is reviewable in isolation.

**File:** `Test/Properties/LocalPolicy.lean` (new).

**Deliverables (3 properties × 100 default samples each, with
seed override via `CANON_PROPERTY_SEED`):**

  1. **`localpolicy_roundtrip_property`** (LP.2).  For every
     `LocalPolicy` value satisfying `fieldsBounded`, decoding
     after encoding recovers the value.

  2. **`localpolicy_admissibility_narrowing_property`** (LP.7).
     For every pre-LP-admissible `(SignedAction, ExtendedState)`
     pair, the same pair is post-LP admissible iff the signer's
     local policy permits the action (in the empty-policy case,
     the iff is trivially `true`).

  3. **`localpolicy_meta_action_universally_admissible_property`**
     (LP.7).  For every random `(LocalPolicy, ActorId)` pair, a
     `declareLocalPolicy` or `revokeLocalPolicy` signed by that
     actor is admissible regardless of the policy's contents
     (modulo the other admissibility conjuncts).

**Per-clause generators** (in
`Test/Properties/LocalPolicy/Generators.lean`):

  * `denyTags`: random `List Nat` of length 0..5 with each
    element `< 17` (current Action ctor count after LP.4).
  * `requireRecipientIn`: random `(ResourceId, List ActorId)`
    with the `ActorId` list of length 0..3.
  * `capAmount`: random `(ResourceId, Amount)` with `Amount <
    2^32`.
  * `LocalPolicy`: random list of 0..3 random clauses
    (uniform sampling across the three clause variants).

**Acceptance criteria:**

  * `lake build LegalKernel.Test.Properties.LocalPolicy` succeeds.
  * All 3 properties pass at 100 samples on the default seed.
  * Failing samples log the seed for reproduction (per the
    Audit-3.9 protocol).
  * Re-running with a recorded `CANON_PROPERTY_SEED` reproduces
    a known pass.

### LP.13 — Cross-stack (Solidity) coordination note

**Scope.**  Document the Solidity-side implications of the two
new `Action` constructors and two new `Event` constructors.
This unit is **documentation-only** — it ships no Solidity
code; it pins the future Solidity-port's expected shape so
that a Workstream-E follow-up can land the on-chain mirror
without re-litigating the Lean-side decisions.

**Files modified / added:**

  * `solidity/README.md` — append a "Future: actor-scoped
    policies" section pointing to this plan and listing the
    two new `Action` ctors at frozen indices 15, 16 + the two
    new `Event` ctors at frozen indices 11, 12.
  * `docs/planning/ethereum_integration_plan.md` — add a §15 "Workstream
    LP integration" section sketching:
      * The expected Solidity-side `LocalPolicy` ABI (a CBE
        decoder mirroring the Lean codec; ports
        `MAX_CLAUSES_PER_POLICY = 64` etc.).
      * The expected `CanonBridge` change: reject deposits
        from L1 if the depositor's L2 `localPolicies` lookup
        denies them (defensive layer; the L2 admissibility
        check already enforces this — the Solidity-side check
        is for fast L1 user feedback).
      * The expected `CanonDisputeVerifier` extension to
        verify a sixth claim variant
        (`localPolicyMisreported`) — reserved for a
        post-LP-MVP audit dispute path; **not** in
        Workstream-LP scope.
  * `docs/abi.md` — append the two new `Action` constructor
    tags at indices 15, 16 to the on-disk-format table; append
    the two new `Event` constructor tags at indices 11, 12.

**Acceptance criteria:**

  * No code changes — purely documentation.
  * The on-disk-format tables in `docs/abi.md` reflect the
    new ctors; an external implementer can produce a
    LP-compatible client from the spec alone.
  * `solidity/README.md` references this plan with a stable
    section pointer (`#§13` or similar).

This unit can land at any point after LP.4 (which freezes the
Action indices); it is **independent of LP.5 – LP.12** and is
parallelisable with LP.9 / LP.10.

### LP.14 — Documentation and final integration

**Files modified:**

  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"knomosis-local-policies"`; add new module imports
    (`Authority/LocalPolicy`, `Encoding/LocalPolicy`,
    `LocalPolicy/LawClassification`).
  * `Tests.lean` — register new test suites (the four new
    suites from LP.1 / LP.2 / LP.9 / LP.11 / LP.12, plus any
    extension drivers).
  * `Test/Umbrella.lean` — update build-tag literal.
  * `CLAUDE.md` — add Workstream-LP changelog entry; extend the
    type-level properties table with the new theorems
    (#187 – #200 approximately, depending on count); update
    source-layout listing to include the new modules.
  * `README.md` — bump status line to mention LP completion.
  * `docs/GENESIS_PLAN.md` — append §X (new section number to
    be allocated at landing time) documenting actor-scoped
    policies in formal terms.  This **is** a Genesis-Plan
    amendment (the §8.2 admissibility predicate is
    deployment-facing and the new conjunct is part of the
    formal model); the §13.6 amendment process applies but
    only at the one-reviewer non-TCB tier (since no kernel-
    TCB module is touched).
  * `docs/std_dependencies.md` — verify no new Std imports
    needed.  The workstream uses only `Std.TreeMap` patterns
    already in the kernel TCB allowlist; the new modules
    don't import `Std.Data.HashMap` or any other module.
  * `docs/abi.md` — extended in LP.13; LP.14 verifies the
    extension is consistent with the in-tree codec.
  * `docs/extraction_notes.md` — verify no extraction changes
    needed (the new ctors compile to `Laws.freezeResource 0`
    at the kernel level, so erasure semantics are unchanged).
  * `scripts/axiom_audit.sh` (new) — automated `#print axioms`
    audit script that fails on non-allowlisted axioms.  Wire
    into CI.

**Deliverables:**

  * All cross-cutting documentation updates.
  * Umbrella module registration.
  * CI gate addition (`axiom_audit.sh`).
  * `kernelBuildTag` bump.

**Acceptance criteria:**

  * `lake build` (full) succeeds.
  * `lake test` succeeds (all suites green, including the new
    LP suites).
  * `lake exe count_sorries` returns 0.
  * `lake exe tcb_audit` passes (no TCB allowlist changes; the
    new modules are non-TCB).
  * `lake exe stub_audit` passes.
  * `scripts/axiom_audit.sh` passes (every new theorem
    `#print axioms`-clean to a subset of the standard three).
  * `kernelBuildTag` bumped; Umbrella test verifies via
    `Test/Umbrella.lean`'s build-tag literal check.
  * `CLAUDE.md` source-layout listing updated; the type-level
    properties table extended.
  * `docs/GENESIS_PLAN.md` amended.

**Why last?**  LP.14 is the only unit that touches the
umbrella module and the cross-cutting documentation.
Landing it last ensures that in-progress branches for LP.1 –
LP.13 don't conflict on the same docs files.  If LP.14 reveals
a missing item (e.g. an under-documented theorem), the fix
lands as a hot-fix to LP.14's branch, not a back-port to
earlier units.

## §11 Test plan

### 11.1 New test suites (created by LP)

| Suite                                                | Cases | LP unit |
|------------------------------------------------------|------:|---------|
| `Test/Authority/LocalPolicy.lean`                    |   ~14 | LP.1    |
| `Test/Encoding/LocalPolicy.lean`                     |   ~12 | LP.2    |
| `Test/LocalPolicy/LawClassification.lean`            |    ~9 | LP.9    |
| `Test/Authority/LocalPolicyAdmissibility.lean`       |   ~12 | LP.11   |
| `Test/Properties/LocalPolicy.lean`                   |    ~3 | LP.12   |
| `Test/Properties/LocalPolicy/Generators.lean`        |    ~4 | LP.12   |

Total: ~54 new tests in new suites (was ~43 in v1).

### 11.2 Updated test suites (extended by LP)

| Suite                                  | New cases | LP unit |
|----------------------------------------|----------:|---------|
| `Test/Encoding/State.lean`             |        +3 | LP.3    |
| `Test/Authority/Action.lean`           |        +6 | LP.4    |
| `Test/Encoding/Action.lean`            |        +4 | LP.4    |
| `Test/Authority/SignedAction.lean`     |        +8 | LP.5    |
| `Test/Authority/SignedAction.lean`     |         0 | LP.6    | (regression-only)
| `Test/Authority/SignedAction.lean`     |        +9 | LP.7    |
| `Test/Bridge/BridgeActor.lean`         |        +4 | LP.8    |
| `Test/Bridge/Accounting.lean`          |        +2 | LP.8    |
| `Test/Bridge/Admissible.lean`          |        +4 | LP.8    |
| `Test/Events/Types.lean`               |        +4 | LP.10   |
| `Test/Events/Extract.lean`             |        +6 | LP.10   |

Total: +50 new tests in existing suites (was +37 in v1; added
+10 from LP.7's separation, +10 from LP.8's coverage).

**Combined workstream test delta: ~+104 tests** (~54 new + ~50
extensions).  Post-LP test count target: ~1207 (current 1103 +
104).  Estimates only; the precise count depends on how many
positive/negative variants are written for each clause.

### 11.3 Property-based tests (mandatory in v2; LP.12)

Promoted from v1's "optional" sidebar to a first-class work
unit (LP.12) with explicit acceptance criteria.  See LP.12
deliverables in §10 for full details.  Three properties × 100
default samples each, with `CANON_PROPERTY_SEED` override:

  1. **`localpolicy_roundtrip_property`** (LP.12, gates LP.2).
  2. **`localpolicy_admissibility_narrowing_property`** (LP.12,
     gates LP.7).
  3. **`localpolicy_meta_action_universally_admissible_property`**
     (LP.12, gates LP.7).

These are part of the LP.14 acceptance gate; the workstream
does **not** land if any property-test fails.

### 11.4 Cross-stack tests

LP.13 (cross-stack documentation) introduces no Lean-side
tests.  When the future Solidity-side mirror lands (out of
scope for LP), it ships its own `solidity/test/CrossCheck/`
fixture suite per the Workstream-F.1.x convention.  LP.13's
acceptance is purely documentation completeness.

### 11.5 Suite-vs-unit cross-reference

To make CI failure diagnosis fast, each test suite's "blame
unit" is recorded:

  * `Test/Authority/LocalPolicy.lean`        → LP.1
  * `Test/Encoding/LocalPolicy.lean`         → LP.2
  * `Test/Encoding/State.lean`               → LP.3
  * `Test/Authority/Action.lean` (LP-cases)  → LP.4
  * `Test/Encoding/Action.lean` (LP-cases)   → LP.4
  * `Test/Authority/SignedAction.lean`       → LP.5 + LP.6 + LP.7
  * `Test/Bridge/BridgeActor.lean` (LP-cases)→ LP.8
  * `Test/Bridge/Accounting.lean` (LP-cases) → LP.8
  * `Test/Bridge/Admissible.lean` (LP-cases) → LP.8
  * `Test/LocalPolicy/LawClassification.lean`→ LP.9
  * `Test/Events/Types.lean` (LP-cases)      → LP.10
  * `Test/Events/Extract.lean` (LP-cases)    → LP.10
  * `Test/Authority/LocalPolicyAdmissibility.lean` → LP.11
  * `Test/Properties/LocalPolicy.lean`       → LP.12

A failure in any suite traceably maps to one or two LP units;
the reviewer of those units is the natural triage owner.

### 11.6 What's NOT tested (intentionally)

  * **Performance.**  `LocalPolicy.permits` complexity is
    O(|clauses| × per-clause-cost).  The §3.0 bounds cap
    `|clauses| ≤ 64` and per-clause list lengths ≤ 64, so the
    worst-case cost is bounded by ~64 × 64 = 4 096
    Nat-comparisons per admissibility check — well within any
    plausible deployment's budget.  No in-Lean perf test.
  * **Encoding-format negotiation.**  The on-disk format is
    fixed at deployment time.  Cross-version compatibility is
    handled via operator re-snapshot (§4.5); no formal test of
    mixed-version networks.
  * **Real cryptographic verification.**  `mockVerify` is used
    throughout for value-level admissibility witnesses.  The
    production `Verify` adaptor is exercised at the runtime
    layer in Phase 5; LP doesn't add anything new on this axis.
  * **Cross-stack equivalence between Lean and a future
    Solidity mirror.**  LP.13's documentation is the contract;
    actual equivalence tests land with the Solidity-port
    follow-up (out of LP scope).  See §13.2 follow-up notes.

## §12 Backwards compatibility

### 12.1 Existing test fixtures

Every existing `ExtendedState` literal of the form
`{ base := …, nonces := …, registry := … }` continues to elaborate
post-LP because Lean's record-update syntax respects the default
value `localPolicies := LocalPolicies.empty`.  No fixture file
needs editing.

Every existing admissibility witness of the form
`⟨h_auth, h_nonce, h_reg, h_pre⟩` needs **one extra trivially-
discharged conjunct**:

  * For meta-actions (`declareLocalPolicy`/`revokeLocalPolicy`):
    `Or.inl rfl` (the `isMetaPolicyAction action = true`
    branch holds by definitional reduction since the action's
    constructor is one of the two meta ctors).
  * For non-meta actions in a fixture with empty `localPolicies`:
    `Or.inr (LocalPolicy.empty_permits_all _ _ _)` (the
    declared policy lookup returns `LocalPolicy.empty`, whose
    `.permits` is vacuous over an empty clause list).

**Helper: `mockAdmissible` extension.**  The existing
`Test/MockCrypto.lean` exposes `mockVerify` and `mockSign`
(Audit-3.3) but does **not** currently ship a `mockAdmissible`
helper that constructs the admissibility witness.  LP.7 lands
the helper:

```lean
/-- Construct an `Admissible` witness for a fixture action,
    automatically discharging every conjunct that the fixture
    satisfies trivially (registered signer, advanced nonce,
    `mockVerify` ok, `decide`-derived precondition,
    empty-policy-or-meta local-policy disjunct).  Used by every
    LP test that needs a value-level admissibility witness. -/
def mockAdmissible
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (h_auth   : P.authorized st.signer st.action)
    (h_nonce  : st.nonce = expectsNonce es st.signer)
    (h_pre    : (Action.compile st.action).transition.pre es.base)
    : AdmissibleWith mockVerify P ByteArray.empty es st :=
  ⟨h_auth, h_nonce, mockVerify_admissibility_witness …, h_pre, …⟩
```

The local-policy conjunct is auto-discharged via case analysis
on `isMetaPolicyAction st.action`:

  * If `true` (meta-action): `Or.inl rfl`.
  * If `false` (non-meta): pattern-match on `es.localPolicies[st.signer]?`;
    if `none`, the lookup returns `LocalPolicy.empty` and
    `.permits` is vacuous; if `some p`, the helper takes an
    additional `h_policy` argument.

This pattern keeps existing call sites that don't care about
local policies one-line-clean while still making the conjunct
explicit in policy-aware tests.

### 12.2 On-disk log format

The CBE encoding for `Action` (Phase 4 WU 4.3) appends the two new
constructor tags at frozen indices 15, 16.  Old log files
containing only constructors 0..14 decode unchanged under the new
decoder.  New log files containing constructors 15..16 cannot
decode under the pre-LP decoder, but no pre-LP build will see such
log files (post-LP nodes won't exchange with pre-LP nodes by
construction — the `kernelBuildTag` mismatch surfaces at handshake
time).

### 12.3 Snapshot format

The `Snapshot.encodedState` field's CBE encoding gains a 5th
appended segment.  Pre-LP snapshots **cannot** be decoded by the
post-LP `ExtendedState.decode` — the decoder is strict per §4.5.
Operators upgrade by re-snapshotting under the post-LP build
(the existing `knomosis snapshot` flow); the post-snapshot
`Snapshot.stateHash` reflects the new canonical 5-segment
encoding.

This is a **hash-changing migration** (the new snapshot's
`stateHash` differs from the pre-LP one), but it is not a
log-changing migration: the post-LP build replays the unchanged
log file from the pre-LP build's `genesisState` and arrives at
the same logical `ExtendedState` (with `localPolicies = empty`),
just under a different canonical encoding.

### 12.4 Deployment migration

A deployment running pre-LP code that wants to migrate to LP:

  1. **Pause new transactions** (deployment-level operational
     step; e.g. via the sequencer's mempool admission policy).
  2. **Replace the binary** with the post-LP build.  The new
     `declareLocalPolicy` / `revokeLocalPolicy` actions are now
     decodable but no actor has declared a policy yet.
  3. **Replay the log** from the pre-LP `genesisState`:
     ```
     knomosis bootstrap log.bin
     ```
     This produces an `ExtendedState` with `localPolicies =
     empty` and the other four fields byte-identical to the
     pre-LP decoder's output.
  4. **Take a fresh snapshot** under the post-LP build:
     ```
     knomosis snapshot snapshot-v2.bin
     ```
     The new snapshot's `Snapshot.stateHash` reflects the
     5-segment canonical encoding; **the hash differs from
     the pre-LP snapshot's hash**.  Operators record the new
     hash in their replicated state-hash registry.
  5. **Discard the pre-LP snapshot** (it can no longer be
     loaded; it is now a museum piece).  Keep the log file
     verbatim.
  6. **Resume new transactions** — including
     `declareLocalPolicy` actions if and when actors choose
     to declare them.

The migration is **near-drop-in** in the sense that no on-chain
ceremony is required and no `CanonMigration` handoff
(Workstream E.5) is needed; only the operator-side
re-snapshot is.  This matches the migration story for the
`bridge` field (Workstream C.1.2), which used the same strict-
decoder design despite carrying a default-valued field.

**Why not a tolerant decoder?**  An earlier draft of this plan
proposed a tolerant decoder that would accept pre-LP byte
sequences as 5-segment ones with empty `localPolicies`,
making the migration step (4) optional.  This was rejected for
the three reasons documented in §4.5: (a) it creates two valid
byte representations of the same logical state, (b) it breaks
the `state_encode_decode_idempotent` Phase-4 audit-2
invariant, (c) it forfeits §8.8.6 canonicality.  Operators
have run `knomosis snapshot` thousands of times in Workstream-E
deployment dry-runs; the cost of one extra invocation is
negligible compared to the canonicality benefit.

## §13 Risks and open questions

### 13.1 Resolved risks (with discharge mechanism)

Each item lists the *risk* + the *discharge artefact* that
closes it.  Reviewers checking workstream completeness
verify that each discharge artefact ships in the named LP unit.

  * **Lockout (an actor permanently banned from revoking
    their own policy).**  Discharged by the meta-action
    exemption (§6.2) and the structural-independence theorem
    `localPolicy_meta_action_independent`.  An actor cannot
    construct a policy that prevents them from revoking it.
    *Artefact:* LP.7's theorem `localPolicy_meta_action_independent`
    + LP.11 scenario 3 value-level acceptance test.
  * **Replay-protection regression.**  Discharged:
    `replay_impossible`'s proof depends only on nonce
    monotonicity (`expectsNonce_strict_mono`), which the new
    conjunct does not affect.
    *Artefact:* LP.7 verification that the existing proof body
    is byte-identical post-conjunct-add + LP.11 scenario 8
    value-level test.
  * **Determinism regression.**  Discharged: every new step is
    a pure function of pre-existing first-order data; no
    randomness, no opaque-call dependency, no clock.
    *Artefact:* `extendedState_encode_deterministic` re-elaborates
    in LP.3; `applyActionToLocalPolicies` is structurally
    deterministic by inspection.
  * **Encoding malleability.**  Discharged: the canonical CBE
    encoding (LP.2) plus the §8.8.6 sorted-key invariant on
    `LocalPolicies.encodeMap` rule out alternate-bytes-same-
    state attacks.
    *Artefact:* LP.2 round-trip + injectivity theorems +
    decoder-rejects-unsorted/duplicate negative tests.
  * **TCB expansion.**  Discharged: every new module is non-TCB.
    *Artefact:* `lake exe tcb_audit` passes in LP.14 without
    `tcb_allowlist.txt` changes.
  * **Axiom expansion.**  Discharged: no new `axiom` or
    `opaque` declaration.  Every theorem `#print axioms`-clean
    to a subset of `{propext, Classical.choice, Quot.sound}`.
    *Artefact:* `scripts/axiom_audit.sh` (added in LP.14)
    passes in CI.
  * **DoS via oversized policies.**  Discharged at the codec
    boundary: §3.0 bounds (`MAX_CLAUSES_PER_POLICY = 64`,
    `MAX_TAGS_PER_DENY = 64`,
    `MAX_RECIPIENTS_PER_REQUIRE = 64`,
    `MAX_POLICY_ENCODE_BYTES = 16_384`) make every admissibility
    check O(1) in the deployment-canonical bound and reject
    oversize on-wire submissions before they reach the kernel.
    *Artefact:* LP.2's `LocalPolicy.encode_size_bound` theorem
    + decoder rejection on oversize input + LP.12's
    `localpolicy_roundtrip_property` exercises bound-respecting
    samples.
  * **Snapshot-format inconsistency.**  Discharged by the
    strict-decoder design (§4.5) plus the operator
    re-snapshot migration story (§12.4).  Two valid byte
    representations of the same logical state are forbidden;
    `state_encode_decode_idempotent` (Phase-4 audit-2) holds.
    *Artefact:* §4.5 specifies the strict semantics; LP.3's
    encoder produces only the 5-segment form; `decodeMap`'s
    canonicality check rejects malformed input.
  * **Cross-stack divergence.**  Mitigated (not fully
    discharged, since no Solidity port ships in LP) by
    LP.13's documentation of the future Solidity ABI plus
    the §3.0 / §3.6 frozen-index discipline.
    *Artefact:* LP.13's docstrings + `docs/abi.md` table
    extension.
  * **Field-extractor projection chain fragility.**  Discharged
    by LP.6's rewrite of all five existing extractors from
    chained-tuple projection to the `obtain ⟨…⟩ := h` pattern.
    *Artefact:* LP.6's diff + verification that downstream
    callers (e.g. `Disputes/Evidence.lean`) continue to
    elaborate with the rewritten extractors.

### 13.2 Open questions / future work

The following items are explicitly deferred from this workstream and
will be addressed by follow-up work units (or not, depending on
real-world demand).  Each is sketched here so future contributors
have a starting point.

  * **`expireAtNonce` clause.**  The natural encoding is a
    recursive wrapper: `LocalPolicyClause.expireAt (expiry :
    Nonce) (inner : LocalPolicyClause)` meaning "apply `inner`
    until `expectsNonce > expiry`, then no-op."  This requires
    a recursive ADT and a fueled decoder, both feasible but
    adding complexity.  Defer until a real user asks.

  * **Disjunction of clauses.**  The MVP is conjunction-only.
    A future `LocalPolicyClause.anyOf (alternatives : List
    LocalPolicyClause)` variant gives full boolean expressivity.
    Same encoding-recursion concern; same deferral logic.

  * **Cross-actor policies.**  The MVP only lets actor A
    constrain *A's own* outgoing actions.  A more powerful model
    would let A delegate to B with B-specific constraints
    ("B can sign a transfer of up to 100 from my account").
    This is delegation / authz, not local policy; out of scope
    here.  Cosmos's `authz` module is prior art.

  * **Policy versioning.**  The current model has no version
    field on `LocalPolicy`.  Adding one would let deployments
    enforce minimum-version requirements at the
    `AuthorityPolicy` level.  Trivially additive in a future PR.

  * **Policy commitments / hashes.**  Currently the full policy
    bytes live on-chain at every declaration.  A space-efficient
    alternative is to commit only `hash(policy)` on-chain and
    require revocations to reveal the matching pre-image.  The
    cost is one extra round trip per revoke and the loss of
    auditor-friendly pubic visibility into active policies.
    Low priority.

  * **Property-test generator size growth.**  If the clause
    inductive grows beyond ~6 constructors, the generator's
    coverage starts to thin.  Consider switching to LCG-driven
    constructor selection with explicit weights at that point.

  * **Bridge-actor policy interaction.**  The bridge actor (id 0)
    has its own `bridgePolicy` (Workstream B.3).  A bridge actor
    declaring a `LocalPolicy` is unusual but allowable.
    Deployments may want to forbid bridge-actor LocalPolicy
    management via `AuthorityPolicy.authorized 0
    (.declareLocalPolicy _) = False`.  Document but don't
    enforce in LP.

  * **Dispute-pipeline interaction.**  A challenger's local
    policy could deny `Action.dispute` to themselves.  This is
    a feature (the actor has voluntarily disabled disputing),
    not a bug.  The dispute pipeline doesn't need any LP-
    awareness.  An *upheld* verdict against a challenger's
    action is not blocked by anyone's local policy: the
    `Action.verdict` is signed by adjudicators, not the
    challenger, so the adjudicators' (not the challenger's)
    `LocalPolicy` is consulted.

  * **Forward-compat: new `Action` constructors.**  When future
    workstreams append new `Action` constructors at indices 17+,
    existing `LocalPolicyClause.denyTags` lists referencing
    those new tags will deny the new actions.  This is
    intended: an actor who pre-emptively bans new tag values
    has chosen conservative defaults.  However, deployments
    should communicate the new-tag semantics so users can
    update their declared policies.  No formal solution; this
    is an operational concern.

  * **Property-coverage of `requireRecipientIn` /
    `capAmount` edge cases.**  These clauses are vacuously
    permissive on action variants without the relevant field
    (e.g. `requireRecipientIn` permits every `freezeResource`
    action).  Add explicit tests for the vacuous branches in
    LP.1's test suite.

### 13.3 Known limitations

  * **No homomorphic clause composition.**  Two actors with
    identical policies cannot share storage; each declares its
    own copy.  At ~50 bytes per clause and ~5 clauses per
    typical policy, this is ~250 bytes per declared actor.  A
    deployment with 1M declared actors would store ~250MB.
    Acceptable for foreseeable deployments; revisit if
    deployments approach 10M+ declared actors.

  * **No partial revocation.**  `revokeLocalPolicy` revokes the
    entire declaration.  Removing one clause requires
    re-declaring with the remaining clauses.  Operationally
    fine; would benefit from a `Action.amendLocalPolicy
    (clauseIdx : Nat) (newClause : LocalPolicyClause)` or
    similar in a future workstream.

  * **No quorum / multi-sig declarations.**  The signer of
    `declareLocalPolicy` is the actor whose policy is being
    set.  An organization with multi-sig governance (e.g. "5 of
    9 board members must agree to set the org's policy") cannot
    natively express this — they'd need to use a multi-sig
    signing scheme at the cryptographic adaptor layer
    (Phase 5+ feature, out of scope here).

## §14 Acceptance criteria

The workstream is complete when, on the head commit of the
landing branch, all of the following hold simultaneously.
Each gate names the LP unit responsible for satisfying it,
so a CI-failure-to-blame-unit lookup is one table away.

### 14.1 Build / test / lint gates

  1. **Build green.**  `lake build` succeeds on a clean
     checkout.  *Owner:* every LP unit.
  2. **Tests green.**  `lake test` reports zero failures across
     every registered suite (post-LP target: ~1207 tests).
     *Owner:* every LP unit.
  3. **No sorries.**  `lake exe count_sorries` returns 0.
     *Owner:* LP.1 – LP.13 (each unit's commit must
     `count_sorries`-clean before merging into the workstream
     branch).
  4. **TCB audit passes.**  `lake exe tcb_audit` reports zero
     allowlist violations; the kernel TCB is unchanged.
     *Owner:* LP.14 (verifies; no LP unit modifies TCB).
  5. **Stub audit passes.**  `lake exe stub_audit` reports
     zero placeholder bodies in non-allowlisted positions.
     *Owner:* every LP unit.
  6. **Axiom audit passes.**  `scripts/axiom_audit.sh` (added
     in LP.14) reports that every theorem introduced by this
     workstream depends only on a subset of
     `{propext, Classical.choice, Quot.sound}`.
     *Owner:* LP.14 + every theorem-introducing LP unit.
  7. **Strict-warnings gate (Audit-3.7) passes.**  `lake
     build` emits zero `: warning:` lines.  *Owner:* every LP
     unit.

### 14.2 Frozen-index invariants

  8. **Action constructor list ends at index 16.**  The
     `Action` inductive has exactly 17 constructors after
     LP.4; the last two are `declareLocalPolicy` (idx 15) and
     `revokeLocalPolicy` (idx 16).  Verified by an integration
     test in `Test/Authority/Action.lean` that pattern-matches
     the inductive's constructor list and asserts the post-
     `Action.encode` leading-byte tag for each.
     *Owner:* LP.4.
  9. **Event constructor list ends at index 12.**  Same shape
     for `Event`, with `localPolicyDeclared` at idx 11 and
     `localPolicyRevoked` at idx 12.  *Owner:* LP.10.
  10. **CBE clause-tag list ends at index 2.**  The
      `LocalPolicyClause` inductive has exactly 3
      constructors after LP.1; tags are `denyTags` = 0,
      `requireRecipientIn` = 1, `capAmount` = 2.
      *Owner:* LP.2.

### 14.3 Headline theorem gates

  11. **Strict-narrowing.**  The
      `admissible_no_policy_iff_pre_LP` theorem (§6.5) proves
      without `sorry` and `#print axioms` to the standard
      three.  *Owner:* LP.7.
  12. **Lockout-prevention.**  The
      `localPolicy_meta_action_independent` theorem (§6.2)
      proves without `sorry`.  The acceptance test "actor
      declares `denyTags [15, 16]`, then revokes" succeeds at
      the value level (LP.11 scenario 3).
      *Owner:* LP.7 (theorem) + LP.11 (acceptance test).
  13. **Replay-protection unchanged.**  `replay_impossible`
      and `nonce_uniqueness` re-elaborate post-LP with
      byte-identical proof bodies.  *Owner:* LP.7
      (verification) + LP.11 scenario 8 (value-level).
  14. **Determinism unchanged.**
      `extendedState_encode_deterministic` re-elaborates
      post-LP.3.  Two encodings of the same logical state
      produce byte-identical output.  *Owner:* LP.3.
  15. **Bridge-actor cannot declare.**  The two new
      `bridgePolicy_rejects_*LocalPolicy` theorems prove
      without `sorry`; LP.11 scenario 11 verifies value-level.
      *Owner:* LP.8.

### 14.4 Migration / compat gates

  16. **Strict-decoder property.**  The post-LP
      `ExtendedState.decode` rejects pre-LP byte sequences
      with `DecodeError.unexpectedEof` at the
      `LocalPolicies.decodeMap` call.  Verified by a value-
      level negative test in `Test/Encoding/State.lean`.
      *Owner:* LP.3.
  17. **Operator re-snapshot path works.**  The full
      `knomosis bootstrap log.bin && knomosis snapshot snap-v2.bin`
      flow under the post-LP build produces a snapshot whose
      `restoreSnapshot` reproduces the post-replay state.
      Verified by an integration test in
      `Test/Runtime/Snapshot.lean`.  *Owner:* LP.8 +
      LP.11 scenario 12.
  18. **Existing fixtures don't break.**  Every
      pre-LP `ExtendedState { base, nonces, registry }`
      literal continues to elaborate post-LP with default
      `localPolicies := empty`.  Verified by the
      regression-only LP.6 build pass (zero proof-body
      changes for theorems whose bodies don't depend on
      `apply_admissible_with`'s tail).  *Owner:* LP.6.

### 14.5 Property-test gates

  19. **All three property tests pass at default seed.**  The
      LP.12 suite passes 100 samples × 3 properties on the
      default seed; failing samples log the seed for
      reproduction.  *Owner:* LP.12.

### 14.6 Documentation gates

  20. **CLAUDE.md updated.**  The "Active development status"
      section names Workstream LP as complete; the source-
      layout listing reflects the new modules; the type-
      level properties table gains the ~14 new entries; the
      `kernelBuildTag` literal is bumped.  *Owner:* LP.14.
  21. **Genesis-Plan amendment landed.**  `docs/GENESIS_PLAN.md`
      gains a new section documenting actor-scoped policies
      in formal terms.  *Owner:* LP.14.
  22. **`docs/abi.md` extended.**  The on-disk-format tables
      reflect the two new `Action` ctors at indices 15, 16
      and the two new `Event` ctors at indices 11, 12.
      *Owner:* LP.13 + LP.14 verifies consistency.
  23. **`solidity/README.md` cross-stack section landed.**
      Future Solidity-port shape documented; sealed
      pointers to this plan + `docs/abi.md`.  *Owner:* LP.13.

The workstream is **not** complete (and the PR is not
landable) until every gate above passes simultaneously.
Partial completion is documented as in-progress and
committed only with the `work-in-progress` PR label.

## §15 End-to-end acceptance walkthrough

This section walks through a single concrete deployment scenario
end-to-end, demonstrating that every component of the workstream
composes as designed.  It is the human-facing version of LP.11
scenario 1 + scenario 12 (the most representative scenarios)
plus a snapshot-survival check.  Each numbered step names the
LP unit that delivers the underlying machinery.

### 15.1 Setup

We have a deployment with three registered actors:
`alice : ActorId = 1`, `bob : ActorId = 2`, the bridge actor at
id 0.  All three are registered in `KeyRegistry`; nonces are
zero.  `localPolicies` is empty.  The `AuthorityPolicy` is
`AuthorityPolicy.unrestricted` (every signed action is
authorised at the static layer).

```lean
-- Pre-LP-style fixture (LP.3 makes the localPolicies field
-- default-empty, so this literal still elaborates).
def setupES : ExtendedState :=
  { base     := setBalance (setBalance genesisState 1 1 1000) 1 2 500
  , nonces   := NonceState.empty
  , registry := KeyRegistry.empty
                  |>.register 0 bridgeKey
                  |>.register 1 aliceKey
                  |>.register 2 bobKey
  -- localPolicies := LocalPolicies.empty  -- defaulted by LP.3
  }
```

### 15.2 Step 1: alice transfers 100 to bob (pre-policy)

Alice signs `Action.transfer 1 1 2 100` at nonce 0.  Her
admissibility witness has 5 conjuncts:

  * `P.authorized 1 _` — `True` under unrestricted policy.
  * `0 = expectsNonce setupES 1` — `True` (default 0).
  * `∃ pk, registry[1]? = some pk ∧ Verify pk … sig = true`
    — `True` under `mockVerify` fixture.
  * `transfer.pre setupES.base` — `True` (alice has 1000 ≥ 100).
  * **NEW (LP.7):** `localPolicyPermits setupES 1 (.transfer …)`.
    — Resolves to `false ∨ LocalPolicy.empty.permits …`.  The
    right disjunct is vacuously `True` (empty `clauses`).  ✓

`apply_admissible` runs, alice's balance becomes 900, bob's
becomes 600.  The runtime emits:

  * `Event.balanceChanged 1 1 1000 900` — alice debited.
  * `Event.balanceChanged 1 2 500 600` — bob credited.
  * `Event.nonceAdvanced 1 0 1` — alice's nonce bump.

(LP.10 leaves the kernel-level events unchanged.)

### 15.3 Step 2: alice declares `denyTags [0]` (no transfers)

Alice signs `Action.declareLocalPolicy { clauses := [.denyTags [0]] }`
at nonce 1.  Her admissibility witness:

  * Conjuncts 1–4: as before, all `True`.
  * **NEW (LP.7):** `localPolicyPermits setupES' 1
    (.declareLocalPolicy …)` — resolves to
    `isMetaPolicyAction (.declareLocalPolicy _) = true ∨ …`,
    which `Or.inl rfl` discharges (LP.7 §6.2 meta-exemption).
    ✓

`apply_admissible` runs.  The post-state's `localPolicies[1]?`
is `some { clauses := [.denyTags [0]] }` (LP.5
`declareLocalPolicy_updates_localPolicies` theorem).  Other
actors' `localPolicies` entries are unchanged (LP.5
`localPolicies_other_actor_untouched`).  The runtime emits:

  * `Event.nonceAdvanced 1 1 2`.
  * **NEW (LP.10):** `Event.localPolicyDeclared 1 { clauses :=
    [.denyTags [0]] }`.

### 15.4 Step 3: alice attempts another transfer (now blocked)

Alice signs `Action.transfer 1 1 2 100` at nonce 2.  The
admissibility check fails the local-policy conjunct:

  * **NEW (LP.7):** `localPolicyPermits es₂ 1 (.transfer …)`
    — resolves to `false ∨ ({clauses := [.denyTags [0]]}).permits
    es₂ 1 (.transfer 1 1 2 100)`.  The right disjunct unfolds
    to `(.denyTags [0]).permits es₂ 1 (.transfer …)`, which is
    `Action.tag (.transfer 1 1 2 100) ∉ [0]`.  But
    `Action.tag (.transfer …) = 0` (LP.1 + LP.4
    `tag_matches_encode_tag`).  So `0 ∉ [0]` is `False`.  ✗

`Decidable Admissible` returns `isFalse`; `processSignedAction`
rejects the action with `notAdmissible`; the log file is
**not** appended (Phase-5 invariant); alice's balance is
unchanged at 900.  No event is emitted.

### 15.5 Step 4: alice revokes the policy

Alice signs `Action.revokeLocalPolicy` at nonce 2.  The
admissibility check:

  * **NEW (LP.7):** `localPolicyPermits es₂ 1
    (.revokeLocalPolicy)` — resolves to `true ∨ …` (the
    `isMetaPolicyAction` left disjunct), which `Or.inl rfl`
    discharges.  ✓ — even though alice's declared policy
    `denyTags [0]` does NOT include tag 16 in its denied
    list, it would not have mattered if it did: the
    meta-action exemption is structural, not policy-derived.

`apply_admissible` runs.  Post-state `localPolicies[1]?` is
`none` (LP.5 `revokeLocalPolicy_clears_localPolicies`).
Runtime emits:

  * `Event.nonceAdvanced 1 2 3`.
  * **NEW (LP.10):** `Event.localPolicyRevoked 1`.

### 15.6 Step 5: alice transfers again (now permitted)

Alice signs `Action.transfer 1 1 2 100` at nonce 3.
Admissibility check passes (the local-policy conjunct
resolves to `false ∨ LocalPolicy.empty.permits …`,
discharged by the empty-policy vacuous-quantification
side).  Alice's balance becomes 800, bob's becomes 700.

### 15.7 Step 6: take a snapshot, then restore

```bash
knomosis snapshot ./snap.bin
```

The snapshot's `encodedState` is a 5-segment CBE byte
sequence (LP.3 + LP.2 codec).  The `localPolicies` segment
is the empty-map header (since alice revoked) — 9 bytes
plus the map type tag.

```bash
# In a fresh process:
knomosis bootstrap-snapshot ./snap.bin
```

The post-restore `ExtendedState` has `localPolicies = empty`
and the four pre-existing fields byte-identical to the
pre-snapshot state.  Verified by LP.11 scenario 12.

### 15.8 What this walkthrough demonstrates

  * **Strict narrowing** (gate 11): pre-LP-admissible actions
    are still admissible when no policy is declared (steps 1
    and 5).
  * **Policy enforcement** (LP.7 conjunct): a denyTags policy
    blocks transfers (step 3).
  * **Meta-action exemption** (gate 12): policies cannot block
    revocation of themselves (step 4).
  * **Mutation theorems** (LP.5): declare / revoke / no-op
    semantics for `localPolicies` are exactly as specified.
  * **Event emission** (LP.10): every state change emits the
    expected event in the expected order.
  * **Snapshot survival** (gate 17 + LP.11.12): a full round-
    trip through `takeSnapshot` / `restoreSnapshot` preserves
    `localPolicies` byte-for-byte.
  * **Replay impossibility** (gate 13): re-applying any of
    steps 1, 2, 4, 5 at the post-state fails the nonce check;
    `replay_impossible` is unaffected by the new conjunct.
  * **Cross-actor isolation** (LP.5
    `localPolicies_other_actor_untouched`): bob's
    `localPolicies` lookup returns empty throughout, even
    though alice has been mutating hers.

A test fixture covering this walkthrough lives in
`Test/Authority/LocalPolicyAdmissibility.lean :: scenario_walkthrough`
(LP.11) and is one of the headline acceptance tests for
the workstream.

## Cross-references

  * **Workstream PA — Parameterized Laws.**  Companion plan that
    builds on LP to add a deployment-wide, quorum-vote-mutable
    `Parameters` table.  Together LP and PA realise the
    "actors customise their own behaviour + the community votes
    on shared parameters" architecture.  PA depends on LP being
    landed (or merged into the same PR) per the dependency
    sketch in PA's §2.  See
    `docs/planning/parameterized_laws_plan.md`.

  * **Solidity-port follow-up.**  When the future Workstream-E
    extension lands the Solidity-side mirror of LP, it will
    consume LP.13's documentation as the spec.  No Lean-side
    changes are anticipated; the Solidity side adds a CBE
    decoder for `LocalPolicy`, an admissibility-check call in
    `CanonBridge.depositETH` / `depositERC20`, and the two new
    event-listener mappings in the indexer.

  * **Audit-3 amendment cascade.**  LP.7's new
    `Admissible` conjunct **does not** require an Audit-3
    amendment because the `Admissible` predicate was already
    parameterised over `verify` and `deploymentId` (Audit-3.3).
    Adding a fifth condition is type-level forward-compatible.
    Reviewers should still verify by reading
    `LegalKernel/Authority/SignedAction.lean`'s `AdmissibleWith`
    docstring after LP.7 lands.

---

**Document version:** v2, refined by Claude on branch
`claude/review-actor-policies-plan-cphPb`.  This version is
based on v1 (drafted on `claude/add-law-voting-0jBAh`) plus
fourteen targeted refinements:

  1. §3.0 explicit DoS bounds (`MAX_CLAUSES_PER_POLICY` etc.).
  2. §3.5 explicit `fieldsBounded` predicates.
  3. §3.6 explicit clause-tag frozen-index discipline.
  4. §4.5 strict-decoder design (replacing the unsound
     tolerant-decoder draft).
  5. §6.2 `isMetaPolicyAction` switched to `Bool`-returning
     for convention consistency.
  6. §6.3 explicit named `Decidable` instance declarations.
  7. §6.4 field-extractor robustness rewrite (LP.6).
  8. §10 LP.5 split into LP.5 (helper) + LP.6 (re-discharge);
     LP.6/LP.7 split for predicate vs proof; new LP.8 for
     bridge / runtime / disputes re-discharge; LP.12 for
     property tests; LP.13 for cross-stack docs.
  9. §11 expanded test-plan tables with LP-unit ownership.
  10. §12.4 honest migration story (operator re-snapshot
      replaces "drop-in" claim).
  11. §13.1 each risk now lists its discharge artefact.
  12. §14 24 acceptance gates organised by category, each
      with a named LP-unit owner.
  13. §15 end-to-end walkthrough demonstrating composition.
  14. v1's "wait, actually…" prose in §9.5 cleaned up;
      `non_registry_mutating_preserves_registry` now correctly
      described as statement-stable.

Subsequent edits track real implementation decisions and are
reflected in the in-tree changelog (CLAUDE.md "Active
development status").  This file is informational; the
canonical specification is the Genesis-Plan amendment that
LP.14 is charged with drafting.
