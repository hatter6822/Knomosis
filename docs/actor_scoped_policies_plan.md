<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Actor-Scoped Policies and Parameterized Laws (Workstreams LP and PA) — Engineering Plan

This document plans two interlocking workstreams that together
deliver Canon's first runtime-mutable governance surface:

  * **Workstream LP (Local Policies, §1 – §14):** per-actor,
    on-chain, mutable policy filters that *narrow* admissibility for
    actions originated by a single declaring actor.
  * **Workstream PA (Parameters, §15 – §22):** deployment-wide,
    quorum-vote-mutable parameter table that further constrains
    admissibility *uniformly* across every actor.

Together they realise the design recommended in the law-voting
analysis: **"each actor customises their own behaviour (LP) + the
community votes on shared parameters (PA)."**  The two phases are
plan-coupled (combined acceptance criteria, combined test plan,
combined backwards-compatibility story) but engineering-decoupled
(LP can land first; PA strictly extends the post-LP state).

The motivating observation, restated: Canon's determinism contract
makes "different nodes running different law configurations"
structurally infeasible.  The two workstreams recover the *spirit*
of the original ask — heterogeneous user-level rules **plus**
deployment-level shared rules — while preserving full
consensus-level determinism: every node sees the same
`localPolicies` and `parameters` fields in `ExtendedState` and
uniformly evaluates each action against both.

It is a roadmap, not a specification; the formal design will be
promoted into a Genesis-Plan amendment once the work-unit set
lands.

## Status

  * **Drafted on branch:** `claude/add-law-voting-0jBAh`.
  * **Phase prefixes:** `LP` (Local Policies) and `PA` (Parameters),
    work units labelled `LP.1` … `LP.10` and `PA.1` … `PA.10` to
    disambiguate from the Genesis-Plan `Phase 1`/`Phase 2`/…
    numbering and from the Ethereum-integration `A` / `B` / `C` / `D`
    workstream prefixes.  Both workstreams are parallel to, not
    successors of, the Genesis-Plan Phase 7.  LP and PA may land
    in two PRs (LP first, PA second) or one combined PR; the
    plan-level coupling is reflected in §22 (combined acceptance
    criteria).
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`, and
    `lake exe stub_audit` all green throughout; **no new sorries**;
    **no new axioms**; **no expansion of the kernel TCB**; no new
    `opaque` declarations.
  * **TCB delta:** zero.  Every new module ships under
    `LegalKernel/Authority/`, `LegalKernel/Encoding/`,
    `LegalKernel/Events/`, `LegalKernel/LocalPolicy/`, or
    `LegalKernel/Parameters/`; none touches `Kernel.lean` or
    `RBMapLemmas.lean`.
  * **Trust-assumption delta:** zero.  The `Verify` opaque is
    unchanged; `hashBytes` is unchanged; no new cryptographic
    primitives are introduced.  Every new admissibility conjunct
    is a pure decidable predicate over first-order data already
    in `ExtendedState`.
  * **Backwards-compat delta:** the two new `ExtendedState` fields
    (`localPolicies`, `parameters`) default to empty values
    (`LocalPolicies.empty`, `Parameters.empty`), so every pre-LP
    construction (test fixtures, deployment-time seeds) continues
    to elaborate; the new admissibility conjuncts reduce
    definitionally to `True` whenever no relevant policy /
    parameter cap is in force.  Existing admissibility witnesses
    gain trivially-discharged conjuncts (`True.intro` in test
    fixtures).
  * **Frozen indices reserved by this plan:**
    `Action.declareLocalPolicy` at index 15;
    `Action.revokeLocalPolicy` at index 16;
    `Action.applyParameterChange` at index 17;
    `Event.localPolicyDeclared` at index 11;
    `Event.localPolicyRevoked` at index 12;
    `Event.parametersChanged` at index 13.

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
  * Change the snapshot format in any incompatible way.  The
    `Snapshot.encodedState` field's CBE encoding gains a new
    appended `localPolicies` segment (defaulting to the empty map
    on pre-LP snapshots, which Lean's default-field handling
    accommodates).

## §2 Architectural overview

### 2.1 Where this lives

The workstream's modules sit between the existing authority layer
and the encoding layer:

```
LegalKernel.Authority.LocalPolicy          (LP.1; new)
  ├── imports Kernel + Authority.Action    (for the .compileTransition path)
  └── exports LocalPolicyClause, LocalPolicy, LocalPolicies, .permits

LegalKernel.Authority.Identity             (extended in LP.6 only via re-export)
LegalKernel.Authority.Action               (extended in LP.4: 2 new ctors)
LegalKernel.Authority.Nonce                (extended in LP.3: 1 new field on ExtendedState)
LegalKernel.Authority.SignedAction         (extended in LP.5+LP.6)
                                            - applyActionToLocalPolicies helper
                                            - 5th conjunct in AdmissibleWith
                                            - field extractor + mutation theorems

LegalKernel.Encoding.LocalPolicy           (LP.2; new)
  ├── imports Authority.LocalPolicy + Encoding.Encodable
  └── exports Encodable instances + roundtrip + injectivity + fieldsBounded

LegalKernel.Encoding.Action                (extended in LP.4: 2 new tag entries)
LegalKernel.Encoding.State                 (extended in LP.3: localPolicies in encode/decode)

LegalKernel.LocalPolicy.LawClassification  (LP.7; new, mirroring Disputes/LawClassification.lean)
  └── exports IsConservative + IsMonotonic instances for the 2 new ctors

LegalKernel.Events.Types                   (extended in LP.8: 2 new ctors at frozen 11, 12)
LegalKernel.Events.Extract                 (extended in LP.8: 2 new emission rules)
```

Every dependency edge points downward toward existing modules; no
existing module gains an edge into a new module beyond what
`LegalKernel.lean` already does for umbrella re-exports.

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

### 3.1 `LocalPolicyClause` inductive (initial constructor set)

The clause type is the first-order vocabulary actors can express
their policies in.  Each constructor maps to a decidable predicate
`(es : ExtendedState) → (signer : ActorId) → (action : Action) →
Bool` (or equivalently `Prop` with a `Decidable` instance).

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

### 4.5 Snapshot compatibility

Pre-LP snapshots have `Snapshot.encodedState` byte sequences ending
at the `bridge` segment.  Decoding them under the post-LP build will
fail at the `LocalPolicies.decodeMap` call (which expects map header
bytes that aren't there).

**Mitigation: tolerant decoder.**  The post-LP `ExtendedState.decode`
treats a successful 4-segment decode followed by *any* remaining
bytes (including empty) as a pre-LP snapshot, defaulting
`localPolicies` to `LocalPolicies.empty`.  The same byte sequence
that worked pre-LP continues to decode post-LP; new-format byte
sequences (with the 5th segment) decode strictly.

**Theorem.** `ExtendedState.decode_pre_LP_compatible`: decoding a
byte sequence produced by the pre-LP encoder against the post-LP
decoder yields an `ExtendedState` whose `localPolicies` is empty
and whose other four fields agree with the pre-LP decoder's output.
Proven by induction on the four pre-LP segments.

This strategy is identical to how the `bridge` field was added in
Workstream C.1.2 (where pre-Workstream-C snapshots were similarly
tolerated by defaulting `bridge := Bridge.BridgeState.empty`).

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
/-- The new admissibility conjunct (LP.6).  An action is permitted
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
  isMetaPolicyAction action ∨
    (es.localPolicies.lookup signer).permits es signer action
```

### 6.2 Meta-action exemption (structural argument)

The `isMetaPolicyAction` classifier:

```lean
/-- True iff `action` is a policy-management meta-action that is
    exempt from the local-policy admissibility conjunct.  Defined
    by *enumeration*, not by any policy-derived predicate, so that
    no LocalPolicyClause can ever block a policy-management
    action by construction. -/
def isMetaPolicyAction : Action → Prop
  | .declareLocalPolicy _ => True
  | .revokeLocalPolicy    => True
  | _                     => False
```

This is the **structural lockout-prevention proof**: the
`isMetaPolicyAction` predicate is enumerated over the `Action`
inductive's two LP-introduced constructors, with every other
constructor mapping to `False`.  No `LocalPolicyClause` constructor
takes a `LocalPolicy → ...` argument, so no clause's `.permits`
branch can introspect policy structure to evaluate
`isMetaPolicyAction`; the disjunction `isMetaPolicyAction action ∨
…` therefore short-circuits unconditionally for meta-actions
regardless of the declared policy's content.

**Theorem `localPolicy_meta_action_independent`** (LP.6):

```lean
theorem localPolicy_meta_action_independent
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (h_meta : isMetaPolicyAction action)
    (lp lp' : LocalPolicies) :
    localPolicyPermits { es with localPolicies := lp  } signer action ↔
    localPolicyPermits { es with localPolicies := lp' } signer action
```

Proof: by definitional unfolding, both sides reduce to
`isMetaPolicyAction action ∨ …`; the left disjunct is `h_meta`, so
both sides are `True`.

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

  * `isMetaPolicyAction`: pattern-match on `action`; each branch is
    `True` or `False`; `Decidable` via `instDecidableTrue` /
    `instDecidableFalse`.
  * `LocalPolicies.lookup`: pure data lookup, returns a `LocalPolicy`
    value.
  * `LocalPolicy.permits`: `∀ c ∈ list, P c` over a finite list with
    decidable per-element `P`; `Decidable` via `List.decidableBAll`.
  * `LocalPolicyClause.permits`: pattern-match on the clause; each
    branch reduces to `Nat`-/`List`-arithmetic decidable
    comparisons.

Therefore `localPolicyPermits` is `Decidable` and the post-LP
`Admissible` predicate inherits the full `Decidable` derivation
chain.  The `decPre := fun _ => inferInstance` discipline (Genesis
Plan §13.6 step 2; `docs/decidability_discipline.md`) is preserved.

### 6.4 Field extractor

```lean
/-- Extract condition 6 (LP): the signer's local policy permits
    the action. -/
theorem admissible_localPolicy
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    localPolicyPermits es st.signer st.action :=
  h.2.2.2.2
```

Plus the parameterised analogue `admissibleWith_localPolicy`.

### 6.5 Strict-narrowing theorem

```lean
/-- LP.6: the new admissibility predicate is strictly narrower than
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

Three theorems pin the new step's semantics, mirroring the
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
    surface consists exactly of the two LP-introduced ctors. -/
theorem non_meta_preserves_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (h_non_meta : ¬ isMetaPolicyAction st.action) :
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
`depositCredited` at index 10).  LP.8 appends two:

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
  /-- LP.8: an actor declared a local policy.  Carries the actor
      and the declared policy.  Indexers consume this event to
      maintain a per-actor "currently declared policy" view.
      Frozen index 11. -/
  | localPolicyDeclared (actor : ActorId) (policy : Authority.LocalPolicy)
  /-- LP.8: an actor revoked their local policy.  Carries the actor.
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

### 9.5 `LegalKernel/Authority/SignedAction.lean` (LP.5 + LP.6)

New:

  * `applyActionToLocalPolicies` — the helper definition.
  * `declareLocalPolicy_updates_localPolicies` — §7.3.
  * `revokeLocalPolicy_clears_localPolicies` — §7.3.
  * `non_meta_preserves_localPolicies` — §7.3.
  * `localPolicies_other_actor_untouched` — §7.3.
  * `localPolicy_meta_action_independent` — §6.2.
  * `admissible_localPolicy` — §6.4.
  * `admissibleWith_localPolicy` — parameterised analogue.
  * `admissible_no_policy_iff_pre_LP` — §6.5.
  * `apply_admissible_localPolicies` — projection of the post-
    state's `localPolicies` field.

Re-discharged (existing theorems whose proofs change due to the
new conjunct or whose statements gain a hypothesis):

  * `nonce_uniqueness` — proof unchanged; the new conjunct is
    irrelevant to nonce reasoning.  Re-tested for elaboration.
  * `replay_impossible` — proof unchanged for the same reason.
    Re-tested.
  * `apply_admissible_base` — re-tested; the new step doesn't
    touch `base`, so the body's structure is the same but the
    de-sugaring sequence has one more `let`.  Proof should remain
    `rfl`.
  * `apply_admissible_registry` — re-tested.  The new step is
    placed *after* the registry update, so
    `applyActionToRegistry es.registry st.action` is the
    pre-final-step value.  Body proof stays `rfl` if Lean's
    record-update collapsing handles the trailing
    `localPolicies` field as expected; otherwise a one-step
    `simp` discharges.
  * `expectsNonce_after_apply_admissible` — re-tested; proof
    structurally similar but with one extra step.  Likely needs a
    one-line `show` to thread through the trailing
    `localPolicies` update.
  * `expectsNonce_after_apply_admissible_other` — re-tested.
  * `replaceKey_updates_registry` — re-tested.
  * `replaceKey_other_actor_untouched` — re-tested.
  * `non_registry_mutating_preserves_registry` — extended with two
    new exclusion hypotheses (the action is neither
    `declareLocalPolicy` nor `revokeLocalPolicy`).  Wait: actually,
    these two ctors **don't mutate the registry**, so
    `non_registry_mutating_preserves_registry` already holds for
    them without modification.  Re-test verifies; if Lean's case
    coverage gripes, the extension is mechanical.
  * `registerIdentity_updates_registry` — re-tested.
  * `registerIdentity_other_actor_untouched` — re-tested.

### 9.6 `LegalKernel/LocalPolicy/LawClassification.lean` (LP.7)

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

### 9.7 `LegalKernel/Encoding/State.lean` (LP.3 extensions)

  * `LocalPolicies.encodeMap` / `decodeMap` — definitions.
  * `extendedState_encode_deterministic` — re-tested with the new
    field; structural rfl-class.
  * `extendedState_decode_pre_LP_compatible` — §4.5; tolerant
    decoder theorem.

### 9.8 `LegalKernel/Events/Types.lean` and `Extract.lean` (LP.8)

  * `extractEvents_declareLocalPolicy_emits_localPolicyDeclared` —
    direct emission rule.
  * `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked` —
    direct emission rule.
  * `Event.actor` — extended.
  * `Event.isLocalPolicyEvent` — new classifier.

### 9.9 Axiom audit

Every new theorem must `#print axioms`-clean to a subset of
`{propext, Classical.choice, Quot.sound}`.  The plan introduces:

  * No `opaque` declarations.
  * No `axiom` declarations.
  * No new dependency on `Classical.choice` beyond what
    `Std.TreeMap` already pulls in (via `RBMapLemmas`).

A workstream-acceptance gate is the `axiom_audit` script in
`scripts/axiom_audit.sh` (added in this workstream; see LP.10), which
emits the audit output for every new theorem and fails the build if
any non-allowlisted axiom appears.

## §10 Work-unit breakdown

Each work unit is independently buildable, testable, and reviewable.
Subsequent units depend only on previous units.  The intended commit
cadence is one commit per unit; rebases are allowed before merge but
not after.

The dependency DAG is linear with one branch:

```
LP.1 → LP.2 → LP.3 → LP.4 → LP.5 → LP.6
                              ↓
                             LP.7 (independent of LP.6;
                                   can land in parallel)
                              ↓
                             LP.8
                              ↓
                             LP.9
                              ↓
                             LP.10
```

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

### LP.5 — `applyActionToLocalPolicies` and `apply_admissible` extension

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Deliverables:**

  * `applyActionToLocalPolicies` helper (§7.1).
  * `apply_admissible_with` body extension (§7.2).
  * Mutation theorems (§7.3, 4 theorems).
  * Re-discharge of every existing
    `expectsNonce_after_apply_admissible*`,
    `apply_admissible_base`,
    `apply_admissible_registry`,
    `replaceKey_*`,
    `registerIdentity_*`,
    `non_registry_mutating_preserves_registry`,
    `nonce_uniqueness`,
    `replay_impossible`.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * Every existing theorem in the file re-elaborates without
    proof changes (or with one-line `show`-based proof
    adjustments where the trailing-let chain confuses Lean's
    `rfl`).
  * The four new mutation theorems prove without `sorry`.

**Test file:** existing `Test/Authority/SignedAction.lean` extended.

  * 8 new tests covering the four new mutation theorems' API
    stability + value-level checks (e.g. `mockVerify`-based
    fixtures showing post-apply local-policy state).
  * Existing tests verified as unchanged (the new field defaults
    to empty, so the existing admissibility-witness construction
    pattern continues to work modulo one extra trivially-
    discharged conjunct).

### LP.6 — `Admissible` predicate extension

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Deliverables:**

  * `localPolicyPermits` predicate (§6.1).
  * `isMetaPolicyAction` classifier (§6.2).
  * Extended `AdmissibleWith` body with the 5th conjunct.
  * `admissible_localPolicy` and `admissibleWith_localPolicy`
    field extractors.
  * `localPolicy_meta_action_independent` theorem (§6.2).
  * `admissible_no_policy_iff_pre_LP` theorem (§6.5).
  * `Decidable AdmissibleWith` re-derived (the existing instance
    extends to the new conjunct mechanically).

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * `lake build LegalKernel.Runtime.Replay` succeeds (the
    `Decidable Admissible` instance flows through without manual
    intervention).
  * `nonce_uniqueness` and `replay_impossible` continue to
    elaborate; their proofs are unchanged because they don't
    consume the new conjunct.
  * The strict-narrowing theorem `admissible_no_policy_iff_pre_LP`
    proves without `sorry`.

**Test file:** existing `Test/Authority/SignedAction.lean`
extended (continued from LP.5).

  * 6 new tests covering the new conjunct's behaviour on
    fixtures with empty / non-empty `localPolicies`.
  * 2 tests verifying meta-action exemption (declare and revoke
    succeed even when the actor's policy bans those tags).
  * 1 test verifying strict-narrowing (action admissible pre-LP
    is admissible post-LP under empty `localPolicies`; action
    admissible pre-LP is *not* admissible post-LP under a
    `denyTags`-blocking policy).

### LP.7 — Law classification

**File:** `LegalKernel/LocalPolicy/LawClassification.lean` (new,
mirrors `LegalKernel/Disputes/LawClassification.lean`).

**Deliverables:**

  * Two rfl-class identification lemmas (§9.6).
  * Four typeclass instances (`IsConservative` × 2,
    `IsMonotonic` × 2).
  * One composite `local_policy_actions_classification` theorem.

**Acceptance criteria:**

  * `lake build LegalKernel.LocalPolicy.LawClassification` succeeds.
  * Both new ctors' compiled transitions resolve to
    `IsConservative` and `IsMonotonic` instances via
    `inferInstance`.

**Test file:** `Test/LocalPolicy/LawClassification.lean` (new).

  * 8 cases (4 instance-resolution checks × 2 ctors); plus the
    composite theorem's API stability check.

This unit is **independent of LP.6** and may land in parallel.

### LP.8 — Event extension

**Files modified:**

  * `LegalKernel/Events/Types.lean` — append two `Event` ctors at
    indices 11, 12.
  * `LegalKernel/Events/Extract.lean` — extend `actionEvents` /
    `extractEvents` with two new emission rules.

**Deliverables:**

  * Two new `Event` ctors with frozen indices.
  * `Event.actor` projection extended.
  * `Event.isLocalPolicyEvent` classifier.
  * Two emission-rule theorems (§9.8).

**Acceptance criteria:**

  * `lake build LegalKernel.Events.Types` succeeds.
  * `lake build LegalKernel.Events.Extract` succeeds.
  * Emission is deterministic and order-preserving (events fire
    after the kernel-level `balanceChanged` / `nonceAdvanced`
    events, in the order LP defines).

**Test files:** existing `Test/Events/Types.lean` and
`Test/Events/Extract.lean` extended.

  * 4 new tests in `Test/Events/Types.lean` covering the new
    constructors' projection / classifier behaviour.
  * 6 new tests in `Test/Events/Extract.lean` covering emission
    on `declareLocalPolicy` / `revokeLocalPolicy` actions
    (positive paths, sequencing relative to `nonceAdvanced`).

### LP.9 — End-to-end tests

**File:** `Test/Authority/LocalPolicyAdmissibility.lean` (new).

**Deliverables:**

End-to-end test scenarios using the `mockVerify` fixture from
`Test/MockCrypto.lean` (Audit-3.3) to construct value-level
admissibility witnesses:

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
     succeed (meta-exemption overrides the deny clause).
  4. **`requireRecipientIn` enforcement.**  Actor A declares
     `requireRecipientIn r [42]`; A's `transfer r ? 42 ?` is
     admissible; A's `transfer r ? 7 ?` is not.
  5. **`capAmount` enforcement.**  Actor A declares
     `capAmount r 100`; A's `transfer r ? ? 50` is admissible;
     A's `transfer r ? ? 200` is not.
  6. **Cross-resource isolation.**  Actor A declares
     `capAmount r 100`; A's `transfer r' ? ? 200` (different
     resource) is admissible.
  7. **Replay protection survives.**  Run scenario 1; verify
     that re-applying any of the successful actions at the
     post-state fails admissibility (replay_impossible holds).
  8. **Multi-clause conjunction.**  Actor A declares a policy
     with two clauses; verify both must permit for the action
     to be admissible.

**Acceptance criteria:**

  * `lake build LegalKernel.Test.Authority.LocalPolicyAdmissibility`
    succeeds.
  * All 8 scenarios pass at the value level.
  * Each scenario emits the expected events (verified via
    `extractEvents` cross-check).

### LP.10 — Documentation and integration

**Files modified:**

  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"canon-local-policies"`; add new module imports.
  * `Tests.lean` — register new test suites.
  * `Test/Umbrella.lean` — update build-tag literal.
  * `CLAUDE.md` — add Workstream-LP changelog entry; extend the
    type-level properties table; update source-layout listing.
  * `README.md` — bump status line.
  * `docs/GENESIS_PLAN.md` — append §X (new section number TBD)
    documenting actor-scoped policies in formal terms.
  * `docs/std_dependencies.md` — verify no new Std imports
    needed (the workstream uses only `Std.TreeMap` patterns
    already in the kernel TCB allowlist).
  * `docs/abi.md` — append the two new `Action` ctors and two
    new `Event` ctors to the on-disk-format listings.
  * `docs/extraction_notes.md` — verify no extraction changes
    needed.
  * `scripts/axiom_audit.sh` (new) — automated `#print axioms`
    audit script that fails on non-allowlisted axioms.

**Acceptance criteria:**

  * `lake build` (full) succeeds.
  * `lake test` succeeds (all suites green).
  * `lake exe count_sorries` returns 0.
  * `lake exe tcb_audit` passes (no TCB allowlist changes; the
    two new modules are non-TCB).
  * `lake exe stub_audit` passes.
  * `scripts/axiom_audit.sh` passes (every new theorem
    `#print axioms`-clean).
  * `kernelBuildTag` bumped; Umbrella test verifies.
  * `CLAUDE.md` source-layout listing updated.

## §11 Test plan

### 11.1 New test suites

| Suite                                            | Cases | LP unit |
|--------------------------------------------------|-------|---------|
| `Test/Authority/LocalPolicy.lean`                | ~14   | LP.1    |
| `Test/Encoding/LocalPolicy.lean`                 | ~12   | LP.2    |
| `Test/LocalPolicy/LawClassification.lean`        | ~9    | LP.7    |
| `Test/Authority/LocalPolicyAdmissibility.lean`   | ~8    | LP.9    |

Total: ~43 new tests in new suites.

### 11.2 Updated test suites

| Suite                                  | New cases | LP unit |
|----------------------------------------|-----------|---------|
| `Test/Encoding/State.lean`             | +3        | LP.3    |
| `Test/Authority/Action.lean`           | +6        | LP.4    |
| `Test/Encoding/Action.lean`            | +4        | LP.4    |
| `Test/Authority/SignedAction.lean`     | +14       | LP.5+6  |
| `Test/Events/Types.lean`               | +4        | LP.8    |
| `Test/Events/Extract.lean`             | +6        | LP.8    |

Total: +37 new tests in existing suites.

**Combined workstream test delta: ~+80 tests** (~43 new + ~37
extensions).  Post-LP test count target: ~1104 (current 1024 + 80).
Estimates only; the precise count depends on how many
positive/negative variants are written for each clause and on
whether property-based tests (§11.3) ship in this workstream or
a follow-up.

### 11.3 Property-based tests (optional, recommended)

The Canon `Test/Property.lean` harness (Audit-3.9) supports
deterministic property tests at 100 default samples per property.
Two recommended LP property tests:

  1. **`localpolicy_roundtrip_property`**: for every
     `LocalPolicy` value satisfying `fieldsBounded`, decoding
     after encoding recovers the value.  Generator: random list
     of 0..3 random clauses (per-clause generators below).
  2. **`localpolicy_admissibility_narrowing_property`**: for every
     pre-LP-admissible `(SignedAction, ExtendedState)` pair, the
     same pair is post-LP admissible iff the signer's local
     policy permits the action (in the empty-policy case, the
     iff is trivially `true`).

Per-clause generators:

  * `denyTags`: random `List Nat` of length 0..5 with each
    element `< 17` (current Action ctor count).
  * `requireRecipientIn`: random `(ResourceId, List ActorId)`
    with the `ActorId` list of length 0..3.
  * `capAmount`: random `(ResourceId, Amount)` with `Amount <
    2^32`.

Property tests are **strongly recommended but not
mandatory** for the workstream's acceptance.  They should land in
LP.9 if time permits; if deferred, they become a follow-up
hardening pass.

### 11.4 What's NOT tested (intentionally)

  * Performance: `LocalPolicy.permits` complexity is O(|clauses| ×
    per-clause-cost).  No deployment is expected to declare a
    policy with more than ~10 clauses; the runtime adaptor's
    sequencer can apply a max-length policy bound externally
    (mempool policy, not consensus rule).  No in-Lean perf test.
  * Encoding-format negotiation: the on-disk format is fixed at
    deployment time.  Cross-version compatibility is bounded by
    the `extendedState_decode_pre_LP_compatible` theorem; no
    formal test of mixed-version networks.
  * Real cryptographic verification: `mockVerify` is used
    throughout for value-level admissibility witnesses.  The
    production `Verify` adaptor is exercised at the runtime
    layer in Phase 5; LP doesn't add anything new on this axis.

## §12 Backwards compatibility

### 12.1 Existing test fixtures

Every existing `ExtendedState` literal of the form
`{ base := …, nonces := …, registry := … }` continues to elaborate
post-LP because Lean's record-update syntax respects the default
value `localPolicies := LocalPolicies.empty`.  No fixture file
needs editing.

Every existing admissibility witness of the form
`⟨h_auth, h_nonce, h_reg, h_pre⟩` needs one extra trivially-
discharged conjunct `Or.inl h_meta` (for meta-actions) or
`Or.inr h_empty_policy_permits` (for non-meta actions in fixtures
with empty `localPolicies`).  In practice the test suite uses
helper functions like `mockAdmissible` (in
`Test/MockCrypto.lean`) that bundle the conjuncts; updating the
helper transparently updates every consumer.

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
appended segment.  Pre-LP snapshots are explicitly tolerated by
the §4.5 decoder modification (`localPolicies` defaults to
empty); post-LP snapshots cannot be loaded by pre-LP builds.
This matches the asymmetric-tolerance pattern used for the
Workstream-C bridge field.

### 12.4 Deployment migration

A deployment running pre-LP code that wants to migrate to LP:

  1. Pause new transactions (deployment-level operational step).
  2. Take a snapshot of the pre-LP state.
  3. Verify the snapshot's `Snapshot.stateHash` matches the
     post-LP decoder's stateHash for the same bytes (will be the
     same — the `localPolicies` field defaults to empty, and the
     stateHash is computed from the canonical encoding which is
     deterministic over that empty default).  In practice, this
     means **no migration step is required**: a snapshot taken on
     the pre-LP build can be loaded by the post-LP build, and
     replay produces identical state.
  4. Restart with the LP build.  New `declareLocalPolicy` /
     `revokeLocalPolicy` actions are now accepted; existing
     actions continue to behave identically.

The migration is **drop-in**: no on-chain ceremony, no
`CanonMigration` handoff (Workstream E.5), no operator
coordination beyond the binary upgrade.

## §13 Risks and open questions

### 13.1 Resolved risks

  * **Lockout.**  Resolved by the meta-action exemption (§6.2)
    and the structural-independence theorem
    `localPolicy_meta_action_independent`.  An actor cannot
    construct a policy that prevents them from revoking it.
  * **Replay-protection regression.**  Resolved: `replay_impossible`'s
    proof depends only on nonce monotonicity (`expectsNonce_strict_mono`),
    which the new conjunct does not affect.  Re-tested in LP.5.
  * **Determinism regression.**  Resolved: every new step is a
    pure function of pre-existing first-order data; no
    randomness, no opaque-call dependency, no clock.
  * **Encoding malleability.**  Resolved: the canonical CBE
    encoding (LP.2) plus the §8.8.6 sorted-key invariant on
    `LocalPolicies.encodeMap` rule out alternate-bytes-same-
    state attacks.
  * **TCB expansion.**  Resolved: every new module is non-TCB.
    `tcb_audit` will pass without modification.
  * **Axiom expansion.**  Resolved: no new `axiom` or `opaque`.
    Every theorem `#print axioms`-clean to a subset of the
    standard three.

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
landing branch, all of the following hold:

  1. **Build green.**  `lake build` succeeds on a clean checkout.
  2. **Tests green.**  `lake test` reports zero failures across
     every registered suite.
  3. **No sorries.**  `lake exe count_sorries` returns 0.
  4. **TCB audit passes.**  `lake exe tcb_audit` reports zero
     allowlist violations; the kernel TCB is unchanged.
  5. **Stub audit passes.**  `lake exe stub_audit` reports zero
     placeholder bodies in non-allowlisted positions.
  6. **Axiom audit passes.**  `scripts/axiom_audit.sh` reports
     that every theorem introduced by this workstream depends
     only on a subset of `{propext, Classical.choice,
     Quot.sound}`.
  7. **Frozen-index invariants preserved.**  `Action`'s
     constructor list ends with the two new ctors at indices
     15, 16 (verified by an integration test that pattern-
     matches the inductive's `numCtors` and the post-encode
     leading-byte tag for each ctor).
  8. **Backward-compat.**  Loading a pre-LP snapshot on the
     post-LP build produces an `ExtendedState` with empty
     `localPolicies` and the other four fields byte-identical
     to the pre-LP decoder's output.  Verified by a value-level
     test in `Test/Encoding/State.lean`.
  9. **Strict-narrowing.**  The
     `admissible_no_policy_iff_pre_LP` theorem proves without
     `sorry` and depends only on the standard axioms.
  10. **Lockout-prevention.**  The
      `localPolicy_meta_action_independent` theorem proves
      without `sorry`.  The acceptance test "actor declares
      `denyTags [15, 16]`, then revokes" succeeds at the
      value level.
  11. **Replay-protection unchanged.**  `replay_impossible` and
      `nonce_uniqueness` are re-tested at API-stability and
      value-level.  Both pass.
  12. **Documentation updated.**  CLAUDE.md's "Active
      development status" section names Workstream LP as
      complete; the source-layout listing reflects the new
      modules; the type-level properties table gains the new
      entries; the `kernelBuildTag` literal is bumped.

The workstream is **not** complete (and the PR is not landable)
until every gate above passes simultaneously.  Partial completion
is documented as in-progress and committed only with the
`work-in-progress` PR label.

---

# Part II — Workstream PA (Parameters)

The remaining sections (§15 – §22) plan the **PA workstream**: a
deployment-wide, quorum-vote-mutable `Parameters` table that
extends the LP architecture with shared rules everyone must obey.
PA composes with LP at the admissibility layer: each action must
satisfy *both* the actor's declared `LocalPolicy` *and* the
deployment-wide `Parameters` constraints to be admissible.

PA introduces no new TCB modules, no new axioms, no new opaque
declarations, and no new trust assumptions beyond what LP already
ships.  The quorum signature mechanism reuses the `Verify` adaptor
and the `Disputes/Verdict.lean` per-signer-deduplication pattern.

## §15 Parameterized laws — overview

### 15.1 What PA delivers

After PA lands on top of LP, the following is true:

  1. `ExtendedState` carries a `parameters : Parameters` field —
     a structured record of deployment-wide tunable values
     (quorum threshold, governance signer set, optional
     transfer / mint caps, dispute window, dispute stake).
  2. The `parameters` field is mutated only via signed
     `Action.applyParameterChange { newParams, signers, sigs }`
     actions whose admissibility requires (a) a quorum of
     governance-signer signatures over the proposed parameters
     and (b) the proposed parameters to satisfy a kernel-level
     validity predicate.  No other action ever touches
     `parameters`.
  3. Two new admissibility conjuncts (conjuncts 7 and 8 in
     post-LP-post-PA `AdmissibleWith`) check parameter-driven
     constraints uniformly:

       * **Conjunct 7 (parametersPermit).**  Per-action surface
         constraints — e.g., `transfer.amount ≤
         parameters.maxTransferAmount` when the cap is set.
       * **Conjunct 8 (parameterActionAdmissible).**  Governance
         gate — for `applyParameterChange` actions, the quorum
         is met and the new parameters are valid; for other
         actions, vacuously `True`.

  4. Both conjuncts strictly **narrow** admissibility (they
     never admit an action that wasn't admissible pre-PA).
     In a deployment with default `Parameters` (no caps set)
     and no `applyParameterChange` actions, post-PA admissibility
     is byte-for-byte indistinguishable from pre-PA admissibility.
  5. The kernel-level validity predicate `Parameters.valid` is
     the safety net: even a colluding majority quorum cannot
     install a state with `quorumThreshold = 0`,
     `quorumThreshold > governanceSigners.length`, or
     `disputeWindowBlocks = 0`.  These are rejected before
     `applyActionToParameters` can run.
  6. Replay protection survives: each `applyParameterChange`
     action carries a per-actor nonce in its `SignedAction`
     envelope, and the existing `replay_impossible` theorem
     applies verbatim.
  7. `Parameters.encode` / `Parameters.decode` extend the CBE
     codec with full round-trip + injectivity proofs.  The
     `ExtendedState` encoding gains a 6th appended segment
     (after the LP `localPolicies` segment).
  8. A new `Event.parametersChanged (oldP newP : Parameters)`
     event fires deterministically on every successful
     parameter change.
  9. Two existing modules — `Bridge/Finalisation.lean`
     (Workstream D.3) and `Disputes/Staking.lean` (Phase-6
     incentive amendment) — are refactored to read their
     respective tunables (`disputeWindowBlocks`, `disputeStake`)
     from `es.parameters` rather than from explicit function
     arguments, so on-chain parameter changes take immediate
     effect at the runtime layer.

### 15.2 Composition with LP

LP (per-actor `LocalPolicy`) and PA (deployment-wide `Parameters`)
compose as conjunction at the admissibility layer.  An action by
actor A is admissible iff:

  * `AuthorityPolicy` permits the `(signer, action)` pair (existing
    Phase-3 conjunct 2).
  * The signer's nonce matches (conjunct 4).
  * The signer is registered with a verifying signature (conjuncts
    1 + 3, packed).
  * The compiled transition's pre holds (conjunct 5).
  * **The signer's `LocalPolicy` permits the action (LP conjunct 6).**
  * **`Parameters` permits the action's surface form (PA conjunct 7).**
  * **The action's parameter-governance gate passes
    (PA conjunct 8).**

The conjunction is order-independent (∧ is commutative and
associative), so the order shown above is for diagnostic clarity
only.  Decidability is preserved: every conjunct is independently
decidable and `Decidable Admissible` derives mechanically.

### 15.3 The "three-pillar story"

A deployment combines three mechanisms:

  1. **Static deployment policy (`AuthorityPolicy`).**  Set at
     deployment time; immutable.  Coarse-grained "who may issue
     what."  Existing.
  2. **Per-actor self-imposed restrictions (`LocalPolicy`).**
     Each actor's voluntary further-narrowing.  LP introduces this.
  3. **Deployment-wide vote-mutable parameters (`Parameters`).**
     Quorum-governed shared rules that bind every actor.  PA
     introduces this.

Each pillar can independently reject any action.  An action is
admissible iff all three (plus the existing nonce / signature /
pre conjuncts) permit it.

### 15.4 Non-goals (PA-specific)

  * **No quadratic / token-weighted voting.**  Quorum is
    counted by distinct approved signers (mirroring
    `Disputes/Verdict.countVerifiedSignatures`); each
    governance signer contributes 1.  Stake-weighted variants
    are deferred to a follow-up workstream.
  * **No timelock / delayed activation.**  An admissible
    `applyParameterChange` action takes effect immediately on
    the next state advance.  Time-locked parameter changes
    (effective-at-block) are deferred.
  * **No two-stage propose-then-apply pipeline.**  The proposer
    collects signatures off-chain, then submits one combined
    `applyParameterChange` action.  On-chain proposal /
    discussion / amendment is a follow-up workstream.
  * **No partial parameter updates.**  An `applyParameterChange`
    action specifies the *full* new `Parameters` record.
    Delta-style updates are deferred (see §22.2 future work).
  * **No automatic governance bootstrap.**  `Parameters.empty`
    has empty `governanceSigners` and is invalid by
    `Parameters.valid`; deployments must seed governance at
    genesis (off-chain `ExtendedState` construction).
  * **No cross-deployment parameter portability.**  Each
    deployment maintains its own `Parameters`; there is no
    mechanism for parameter values to inherit across forks /
    migrations beyond what the `CanonMigration` handoff
    (Workstream E.5) already supports.
  * **No vote-weighted governance signers.**  Each signer is
    equivalent to every other signer in the quorum count.
    Federated weight schemes are deferred.

## §16 The `Parameters` data type

### 16.1 Field set (MVP)

```lean
/-- Deployment-wide vote-mutable parameter table.  Mutated only by
    admissible `Action.applyParameterChange` actions through
    `apply_admissible`; preserved by every other action.

    **Append-only field discipline.**  Adding a new field is a
    backwards-compatible extension iff the new field has a
    canonical default value (so `Parameters.empty` extends
    cleanly).  Removing or reordering fields is a
    breaking-encoding change and forbidden after the workstream
    lands.  The CBE codec serialises fields in declaration
    order; reordering would silently break every persisted
    state.

    **Validity discipline.**  Every field has a documented valid
    range; the `Parameters.valid` predicate (§16.2) is the
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
      `isFinalised`; PA.5 refactors `Bridge/Finalisation.lean`
      to read this field from `es.parameters` rather than
      taking it as a function argument.  `Parameters.valid`
      requires `disputeWindowBlocks > 0`.  Default: 7200
      (≈ 1 day at 12 s blocks, matching Workstream-D's pre-PA
      default). -/
  disputeWindowBlocks : Nat
  /-- Stake amount required for filing disputes via the
      Phase-6 incentive amendment's `StakingPolicy` (resource
      0 by convention).  Consumed by
      `Disputes/Staking.fileDisputeStaked`; PA.6 refactors
      that helper to read this field.  Default: 0
      (no stake required, matching pre-PA staking-disabled
      behaviour). -/
  disputeStake        : Amount
  deriving Repr, DecidableEq
```

The MVP set is deliberately small (six fields).  Each field
captures a real Canon tunable that previously lived as a
hard-coded constant or a function argument.  Future PRs append
new fields under the same append-only discipline (see §22.2 for
candidate additions).

### 16.2 The validity predicate

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
      * `quorumThreshold ≤ governanceSigners.length`.  Otherwise
        no proposal can ever pass (unreachable target).
      * `disputeWindowBlocks > 0`.  A zero dispute window
        skips `isFinalised`'s adversary-action window,
        breaking Workstream-D finalisation soundness.
      * `governanceSigners` has no duplicates.  A duplicate
        would silently weight that signer twice in the
        per-signer-deduplicated quorum count.  (See §17.2 for
        the dedup mechanism.)

    Returns `Bool` rather than `Prop` so callers can `decide`
    without an explicit `Decidable` instance synthesis. -/
def Parameters.valid (p : Parameters) : Bool :=
  decide (p.quorumThreshold > 0)                                &&
  decide (p.quorumThreshold ≤ p.governanceSigners.length)       &&
  decide (p.disputeWindowBlocks > 0)                            &&
  decide (p.governanceSigners.Nodup)
```

The `List.Nodup` check is decidable by `List.decidableNodup` (Lean
core lemma).  All four checks are pure Nat / List arithmetic;
`decide` composes via `Bool.and`.

The predicate is **monotonic in disclosure**: if `Parameters.valid
p₁ = true` and `p₂` agrees with `p₁` on the four constrained
fields, then `Parameters.valid p₂ = true`.  This means a parameter
change that updates only the unconstrained fields
(`maxTransferAmount`, `maxMintAmount`, `disputeStake`) preserves
validity automatically.

### 16.3 Default value

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
mechanically certifies that a deployment that boots from the
empty default cannot accept any `applyParameterChange` action
without first seeding governance off-chain.  The "off-chain
seeding" is a one-time deployment ceremony: the operator
constructs `ExtendedState` with a non-empty
`governanceSigners` and a matching `quorumThreshold`, computes
the genesis state hash, distributes the genesis state to all
nodes.  This mirrors how every Canon deployment seeds
`KeyRegistry` and per-resource initial balances today.

### 16.4 `ExtendedState` extension (post-LP-post-PA)

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
field).  Lean's record-update syntax preserves unmentioned
fields by construction.

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

### 16.5 Encoding extension (post-LP-post-PA)

The CBE encoding for `ExtendedState` becomes:

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

### 16.6 Pre-PA snapshot tolerance

The `ExtendedState.decode` function uses the same tolerant-tail
strategy as LP.3: a successful 5-segment decode followed by zero
or more remaining bytes triggers default-value fill-in for the
absent 6th segment.

**Theorem `extendedState_decode_pre_PA_compatible`**: decoding a
byte sequence produced by the post-LP-pre-PA encoder against the
post-PA decoder yields an `ExtendedState` whose `parameters` is
`Parameters.empty` and whose other five fields agree with the
pre-PA decoder's output.

The combination of LP and PA tolerance gives a **graceful
upgrade staircase**: a pre-LP snapshot decodes under PA with
both `localPolicies = empty` and `parameters = empty`; a
post-LP-pre-PA snapshot decodes with `parameters = empty`; a
post-PA snapshot decodes verbatim.  Each upgrade is forward-
compatible with the prior wire format.

## §17 Parameter changes via quorum voting

### 17.1 The `Action.applyParameterChange` constructor

PA.4 appends one new `Action` constructor at frozen index 17:

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
        * The signatures are over `signingInputForParameterChange
          newParams es.deploymentId` (a CBE-encoded canonical
          form domain-separated from `signingInput`).

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

Note: the proposer's `LocalPolicy` (if any) is consulted via
LP conjunct 6.  An actor whose `LocalPolicy` denies tag 17 cannot
serve as a proposer; the deployment can encourage proposer
diversity by using `AuthorityPolicy.singleton` to authorise
specific proposers.

### 17.2 Quorum signature counting

```lean
/-- The canonical bytes governance signers sign for an
    `applyParameterChange` proposal.  Domain-separated with
    `parameterChangeDomain := "legalkernel/v1/paramchange"`
    so signatures cannot be cross-protocol replayed as
    `SignedAction` or `Verdict` signatures.

    Includes the deploymentId so a signature for one deployment
    cannot be replayed against another (Audit-3.4-equivalent). -/
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

/-- Count distinct, approved-signer, verified signatures over the
    parameter-change digest.  Mirrors
    `Disputes/Verdict.countVerifiedSignatures`'s shape exactly:

      * Walks `signers` and `sigs` in parallel via `List.zip`.
      * Maintains a "seen" list to deduplicate repeated signers
        (per-audit-1 fix; a single approved signer with one
        valid signature contributes at most 1 regardless of
        list-length padding).
      * For each unique signer that's in
        `es.parameters.governanceSigners` and whose registered
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
  pairs.foldl (init := (0, ([] : List ActorId))) (fun (count, seen) (s, σ) =>
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

**Per-signer dedup theorem**:

```lean
theorem countParameterChangeSignatures_le_governance_size
    (verify : ...) (d : ByteArray) (es : ExtendedState)
    (newParams : Parameters) (signers : List ActorId) (sigs : List Signature) :
    countParameterChangeSignatures verify d es newParams signers sigs
      ≤ es.parameters.governanceSigners.length
```

Proof: each successful increment adds the signer to `seen`; the
`s ∈ seen` short-circuit prevents double-counting; therefore the
count is bounded by the number of distinct governance signers
encountered, which is at most `governanceSigners.length`.

### 17.3 The `applyActionToParameters` helper

Mirrors `applyActionToRegistry` and `applyActionToLocalPolicies`:

```lean
def applyActionToParameters
    (params : Parameters) : Action → Parameters
  | .applyParameterChange newParams _ _ => newParams
  | _                                   => params
```

For every action other than `applyParameterChange`, the
`parameters` field is unchanged.  For `applyParameterChange`, it
is replaced wholesale with `newParams`.  The validity check is
performed in admissibility (conjunct 8); the helper trusts its
input.

### 17.4 `apply_admissible_with` extension (post-PA)

The state-advance entry point gains a sixth final step (after the
LP `localPolicies` update):

```lean
def apply_admissible_with
    (verify : ...) (P : AuthorityPolicy) (d : ByteArray)
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
for readability and to reflect the order in which a future
auditor / runtime extension would naturally read them.

### 17.5 Mutation theorems

```lean
/-- PA.5: after applying `applyParameterChange newParams …` via
    `apply_admissible`, the post-state's `parameters` is
    exactly `newParams`. -/
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
    `apply_admissible`, the `parameters` field is unchanged.
    A type-level statement that the parameters-mutation surface
    is exactly the one PA-introduced ctor. -/
theorem non_param_action_preserves_parameters
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (h_not_param : ∀ newParams signers sigs,
      st.action ≠ .applyParameterChange newParams signers sigs) :
    (apply_admissible P es st h).parameters = es.parameters
```

Both proofs reduce to definitional unfolding of
`apply_admissible_with` plus pattern-match on `st.action`.

## §18 Admissibility extensions for parameters

### 18.1 The two new conjuncts

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

### 18.2 `parametersPermit` (per-action surface constraints)

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
  -- by the MVP parameter set.  Future PRs may add caps for
  -- `reward`, `distributeOthers`, `proportionalDilute` if real
  -- deployment use cases motivate them.
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

### 18.3 `parameterActionAdmissibleWith` (governance gate)

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
    newParams deploymentId` (§17.2), domain-separated from
    `signingInput` to prevent cross-protocol replay. -/
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

### 18.4 Field extractors (PA conjuncts 7 + 8)

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

### 18.5 Strict-narrowing theorems

```lean
/-- PA.6 strict-narrowing (combined LP + PA): in a deployment with
    no `LocalPolicy` declared for the signer, no parameter caps
    set, and the action is not `applyParameterChange`, the
    post-PA admissibility predicate reduces to its pre-LP form. -/
theorem admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (h_no_policy : es.localPolicies[st.signer]? = none)
    (h_no_max_xfer : es.parameters.maxTransferAmount = none)
    (h_no_max_mint : es.parameters.maxMintAmount = none)
    (h_not_param  : ∀ newParams signers sigs,
                    st.action ≠ .applyParameterChange newParams signers sigs) :
    Admissible P es st ↔
      AdmissibleWith Verify P ByteArray.empty
        { es with localPolicies := LocalPolicies.empty,
                  parameters    := Parameters.empty } st
```

Proof: under the four hypotheses, both new conjuncts (7 and 8)
reduce to `True`, and the LP conjunct (6) reduces to `True` per
`admissible_no_policy_iff_pre_LP`.  All five remaining conjuncts
agree on the iff.

This theorem is the type-level statement that **PA + LP, in
their default-empty configurations, are byte-for-byte identical
to the pre-LP-pre-PA admissibility predicate.**  A deployment
that opts out of both pillars sees zero behavioural change.

### 18.6 Composition with LocalPolicy (formal)

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

### 18.7 Replay protection survives

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
attempting to replay them after the governance set has changed.
This is *also* handled by the existing nonce mechanism, with one
caveat: the proposer's nonce is consumed, but the underlying
governance signatures are not nonce-bound.  An attacker who
collected signatures from old governance signer S over
parameters P could attempt to submit `applyParameterChange P
[S] [σ]` after S has been removed from `governanceSigners`.

Resolution: `countParameterChangeSignatures` checks `s ∈
es.parameters.governanceSigners` against the **current** state,
not historical state.  A removed signer's old signatures stop
counting the moment they're removed.  This is the correct
behaviour: governance signers' approvals are scoped to their
tenure.

**Theorem `removed_governance_signer_loses_authority`**:

```lean
theorem removed_governance_signer_loses_authority
    (verify : ...) (d : ByteArray) (es es' : ExtendedState)
    (newParams : Parameters)
    (signers : List ActorId) (sigs : List Signature)
    (h_diff : ∃ s ∈ signers,
              s ∈ es.parameters.governanceSigners ∧
              s ∉ es'.parameters.governanceSigners ∧
              es.registry[s]? = es'.registry[s]?) :
    countParameterChangeSignatures verify d es' newParams signers sigs <
    countParameterChangeSignatures verify d es  newParams signers sigs
```

The hypothesis quantifies over a removed-but-otherwise-unchanged
signer; the conclusion shows the count strictly decreases under
the post-removal state.  Proven by case-analysis on the foldl
counting that signer's contribution.

## §19 Parameter-aware law constraints (consumer integration)

### 19.1 Per-parameter consumer mapping

Each `Parameters` field has at least one consumer in the codebase
that reads it.  PA.5 / PA.6 wire the consumers up:

| Parameter             | Consumer module                       | Pre-PA form                    | Post-PA form                            |
|-----------------------|---------------------------------------|--------------------------------|-----------------------------------------|
| `quorumThreshold`     | `Authority/SignedAction.lean`         | (n/a — PA introduces it)       | `parameterActionAdmissibleWith`         |
| `governanceSigners`   | `Authority/SignedAction.lean`         | (n/a)                          | `countParameterChangeSignatures`        |
| `maxTransferAmount`   | `Authority/SignedAction.lean`         | (n/a)                          | `parametersPermit` conjunct 7           |
| `maxMintAmount`       | `Authority/SignedAction.lean`         | (n/a)                          | `parametersPermit` conjunct 7           |
| `disputeWindowBlocks` | `Bridge/Finalisation.lean`            | function-arg in `isFinalised`  | `es.parameters.disputeWindowBlocks`     |
| `disputeStake`        | `Disputes/Staking.lean`               | structure-field in `StakingPolicy` | `es.parameters.disputeStake`        |

The first four consumers are admissibility-internal (live inside
`apply_admissible`'s decision).  The last two are runtime-layer
(consumed outside `apply_admissible`, by deployment-facing
helpers).  PA.5 handles the admissibility-internal consumers; PA.6
handles the runtime-layer consumers.

### 19.2 Bridging existing modules (PA.5 + PA.6)

**PA.5: `Bridge/Finalisation.lean` refactor.**  The current
`isFinalised` signature is:

```lean
def isFinalised
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (disputeWindowBlocks : Nat) (log : List LogEntry) : Prop
```

PA.5 adds a parallel form that reads the dispute window from a
supplied `Parameters`:

```lean
def isFinalised'
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (params : Parameters) (log : List LogEntry) : Prop :=
  isFinalised fsnap currentL1Block params.disputeWindowBlocks log
```

Plus a runtime-state-aware form for callers who already have
`ExtendedState`:

```lean
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

**PA.6: `Disputes/Staking.lean` refactor.**  The current
`StakingPolicy` structure is:

```lean
structure StakingPolicy where
  stakeAmount : Amount
  treasury    : ActorId
  -- ... ...
```

PA.6 adds a parallel `stakingPolicyFromParameters` constructor
that lifts a `Parameters` to a `StakingPolicy`:

```lean
def stakingPolicyFromParameters
    (params : Parameters) (treasury : ActorId) : StakingPolicy where
  stakeAmount := params.disputeStake
  treasury    := treasury
  -- ... ...
```

`fileDisputeStaked` gains an `ExtendedState`-aware variant:

```lean
def fileDisputeStakedFromES
    (es : ExtendedState) (treasury : ActorId) (...) : Except StakedFilingError ... :=
  let pol := stakingPolicyFromParameters es.parameters treasury
  fileDisputeStaked pol ...
```

The pre-PA `fileDisputeStaked` is preserved; the new helper is a
strict addition.

### 19.3 Compositional theorem: parameter-driven dispute window

```lean
/-- PA.5: an `isFinalisedFromES` claim under a state with
    parameters `p` is equivalent to the pre-PA `isFinalised`
    claim with `p.disputeWindowBlocks` as the explicit
    argument.  Round-trip identity. -/
theorem isFinalisedFromES_equiv
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (es : ExtendedState) (log : List LogEntry) :
    isFinalisedFromES fsnap currentL1Block es log ↔
    isFinalised fsnap currentL1Block es.parameters.disputeWindowBlocks log
```

By definitional unfolding.  Establishes the compositional bridge:
runtime-layer callers can switch to the parameter-driven form and
their existing finalisation invariants continue to hold modulo
the substitution `disputeWindowBlocks ← es.parameters.disputeWindowBlocks`.

### 19.4 Why not change the kernel's `Transition` interface?

A natural alternative design: extend `Transition` to take an
`ExtendedState` (or a `Parameters`) input, so laws can read
parameters directly in their `pre` / `apply_impl`.  We
deliberately do **not** do this.  Reasons:

  1. **TCB expansion.**  Modifying `Transition` (a kernel-TCB
     type) would trigger the §13.6 two-reviewer gate, expand
     the TCB's surface, and require re-discharging every
     existing kernel theorem (`impl_refines_spec`,
     `apply_certified_eq_step_impl`, `invariant_preservation`,
     `invariants_compose`).  Out of scope for a deployment-
     facing feature.
  2. **Compositional clarity.**  Putting parameter checks at
     admissibility (not in transition pre / impl) cleanly
     separates *who-may-do-what* (admissibility) from
     *what-the-do-actually-does* (transition).  Deployments
     that swap law sets without changing parameters get the
     intended behaviour without surprising parameter
     interactions.
  3. **Backwards compatibility.**  Existing laws
     (`Laws/Transfer.lean` et al.) continue to work unchanged.
     Their `pre` and `apply_impl` are pure functions of `State`,
     as designed.  No retrofit cost.
  4. **Determinism.**  The kernel's determinism guarantees
     (`step_impl` is a function on `(State, Transition)`) are
     preserved verbatim.  Parameters affect *what passes
     admissibility*, not *what step_impl computes given an
     admissible action*.

The cost of this design choice is mild: parameters cannot affect
the *semantics* of an admitted action, only whether it is
admitted.  For the MVP parameter set, this is exactly what we
want — caps gate admission, dispute window gates finalisation
(both at pre-`apply_impl` checks).  Future parameters that need
to influence transition semantics (e.g. dynamic fee schedules
that change `transfer.amount` mid-application) would require a
different mechanism; that's documented as deferred work in
§22.2.

## §20 PA theorem inventory

Mirrors §9's structure for LP.  Each entry is named exactly as it
will appear in the Lean source.

### 20.1 `LegalKernel/Authority/Parameters.lean` (PA.1)

  * `Parameters.empty_invalid` — `Parameters.empty.valid = false`.
  * `Parameters.valid_implies_governance_nonempty` — if
    `valid p = true`, then `p.governanceSigners.length ≥ 1`.
  * `Parameters.valid_implies_quorum_positive` — if `valid p =
    true`, then `p.quorumThreshold ≥ 1`.
  * `Parameters.valid_implies_quorum_le_signers` — if `valid p =
    true`, then `p.quorumThreshold ≤ p.governanceSigners.length`.
  * `Parameters.valid_implies_window_positive` — if `valid p =
    true`, then `p.disputeWindowBlocks ≥ 1`.
  * `Parameters.valid_implies_signers_nodup` — if `valid p =
    true`, then `p.governanceSigners.Nodup`.
  * `Parameters.valid_decidable` (instance) — `Decidable
    (Parameters.valid p = true)` via `decide`.

### 20.2 `LegalKernel/Encoding/Parameters.lean` (PA.2)

  * `Parameters.encode_decode` — round-trip under `fieldsBounded`.
  * `Parameters.encode_injective` — injectivity under
    `fieldsBounded`.
  * `Parameters.encode_deterministic` — structural equality.
  * `Parameters.fieldsBounded_decidable` (instance).

### 20.3 `LegalKernel/Authority/Action.lean` (PA.4 extensions)

  * `Action.tag` extension to cover index 17.
  * `Action.tag_matches_encode_tag` extension (provable when both
    LP.4 and PA.4 have landed).
  * `Action.compile_injective` re-verified to extend over the
    new ctor (no proof change).
  * `Action.fieldsBounded_decidable` extension.

### 20.4 `LegalKernel/Encoding/Action.lean` (PA.4 extensions)

  * Existing `action_roundtrip` extended with the
    `applyParameterChange` branch.
  * Existing `action_encode_injective` extended.

### 20.5 `LegalKernel/Authority/SignedAction.lean` (PA.5 + PA.6)

New definitions:

  * `parameterChangeDomain` — domain-separation string.
  * `signingInputForParameterChange` — the canonical signed bytes.
  * `countParameterChangeSignatures` — quorum counter.
  * `parametersPermit` — conjunct 7 predicate.
  * `parameterActionAdmissibleWith` — conjunct 8 predicate.
  * `parametersPermit_decidable` (instance).
  * `parameterActionAdmissibleWith_decidable` (instance).
  * `applyActionToParameters` — mutation helper.

New theorems:

  * `applyParameterChange_updates_parameters` — §17.5.
  * `non_param_action_preserves_parameters` — §17.5.
  * `admissible_parametersPermit` — §18.4.
  * `admissible_parameterActionAdmissible` — §18.4.
  * `applyParameterChange_admissible_implies_valid` — §18.4.
  * `applyParameterChange_admissible_implies_quorum_met` —
    §18.4.
  * `admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA` —
    §18.5 strict-narrowing.
  * `admissible_lp_pa_compose` — §18.6 composition.
  * `countParameterChangeSignatures_le_governance_size` — §17.2
    dedup bound.
  * `countParameterChangeSignatures_zero_when_governance_empty`
    — every count is 0 when `governanceSigners = []`.
  * `removed_governance_signer_loses_authority` — §18.7
    stale-signer protection.
  * `parameterChangeDomain_distinct_from_signedActionDomain` —
    cross-protocol replay protection at the domain-prefix level.
  * `parameterChangeDomain_distinct_from_verdictDomain` —
    cross-protocol replay protection at the domain-prefix level.

Re-discharged theorems:

  * `nonce_uniqueness` — re-tested; proof unchanged.
  * `replay_impossible` — re-tested; proof unchanged.
  * `apply_admissible_base` — re-tested.
  * `apply_admissible_registry` — re-tested.
  * `apply_admissible_localPolicies` — re-tested (unchanged from
    LP).
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
  * `localPolicy_meta_action_independent` — unchanged (PA-side
    operations are not LP meta-actions; this is correct
    behaviour: a LocalPolicy can deny `applyParameterChange`).

### 20.6 `LegalKernel/Encoding/State.lean` (PA.3 extensions)

  * Existing `extendedState_encode_deterministic` re-tested.
  * `extendedState_decode_pre_PA_compatible` — §16.6 tolerant
    decoder.
  * `extendedState_decode_pre_LP_pre_PA_compatible` — composition
    of LP.3 and PA.3 tolerance: a pre-LP-pre-PA snapshot decodes
    with both `localPolicies = empty` and `parameters = empty`.

### 20.7 `LegalKernel/Parameters/LawClassification.lean` (PA.7)

Mirrors `Disputes/LawClassification.lean` and
`LocalPolicy/LawClassification.lean`.

  * `applyParameterChange_compileTransition_eq_freezeResource_zero` —
    rfl identification lemma.
  * `applyParameterChange_compiled_isConservative` — instance.
  * `applyParameterChange_compiled_isMonotonic` — instance.
  * `parameter_action_classification` — composite summary.

### 20.8 `LegalKernel/Events/Types.lean` and `Extract.lean` (PA.8)

  * `Event.parametersChanged` constructor at frozen index 13.
  * `Event.actor` extension (returns `none` for
    `parametersChanged` since it is a deployment-wide event,
    not actor-scoped).
  * `Event.isParameterEvent` classifier (new).
  * `extractEvents_applyParameterChange_emits_parametersChanged`
    — emission rule theorem.

### 20.9 Consumer-integration theorems (PA.5 + PA.6)

`Bridge/Finalisation.lean`:

  * `isFinalisedFromES_equiv` — §19.3.
  * `isFinalisedFromES_monotonic_in_currentBlock` — lifted
    Workstream-D `isFinalised_monotonic_in_currentBlock`.
  * `isFinalisedFromES_implies_no_upheld_against` — lifted
    Workstream-D analogue.

`Disputes/Staking.lean`:

  * `stakingPolicyFromParameters_stakeAmount_eq` — rfl projection
    identity.
  * `fileDisputeStakedFromES_equiv` — round-trip identity with
    the pre-PA `fileDisputeStaked` under the substitution
    `pol := stakingPolicyFromParameters es.parameters treasury`.

### 20.10 Axiom audit

Same gate as LP (§9.9).  PA introduces:

  * No `opaque` declarations.
  * No `axiom` declarations.
  * No new dependency on `Classical.choice` beyond what
    `Std.TreeMap` already pulls in transitively.
  * The same `scripts/axiom_audit.sh` script (added in LP.10)
    extends to cover PA's new theorems automatically (it
    enumerates every `theorem` / `def` declaration in the
    workstream's modules).

## §21 PA work-unit breakdown

Each work unit is independently buildable, testable, and
reviewable.  PA.1 depends on LP.6 (LP must land first); PA.2 –
PA.10 follow PA.1's dependency chain mirroring LP's structure.

The dependency DAG:

```
LP.10 (LP complete)
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

  * `Parameters` structure (6 fields per §16.1).
  * `Parameters.empty` (§16.3).
  * `Parameters.valid` (§16.2).
  * `Parameters.valid_decidable` instance.
  * Six validity-implication lemmas (§20.1).
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
  * `Encodable Parameters` instance (encode + decode definitions).
  * Round-trip + injectivity + determinism theorems (§20.2).

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
    `extendedState_decode_pre_PA_compatible` theorem.

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
    `Action.decode`, `Action.fieldsBounded`, the action-roundtrip
    and injectivity theorems.

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

### PA.5 — `applyActionToParameters` and `apply_admissible` extension

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Also modified:** `LegalKernel/Bridge/Finalisation.lean` to add
the parameter-driven helpers (§19.2).

**Deliverables:**

  * `applyActionToParameters` helper (§17.3).
  * `apply_admissible_with` body extension (§17.4).
  * Mutation theorems (§17.5).
  * `parameterChangeDomain` and `signingInputForParameterChange`
    definitions.
  * `countParameterChangeSignatures` definition + dedup theorem.
  * Cross-protocol distinctness theorems for the domain prefix.
  * Re-discharge of every existing apply_admissible theorem.
  * `Bridge/Finalisation.lean`: `isFinalised'`,
    `isFinalisedFromES`, equivalence theorem.

**Acceptance criteria:**

  * `lake build LegalKernel.Authority.SignedAction` succeeds.
  * `lake build LegalKernel.Bridge.Finalisation` succeeds.
  * Every existing theorem in `SignedAction.lean` re-elaborates
    (with one-line `show` adjustments where the trailing-let
    chain confuses Lean's `rfl`).
  * The two new mutation theorems prove without `sorry`.

**Test file:** existing `Test/Authority/SignedAction.lean`
extended with ~10 new tests covering:

  * `applyActionToParameters` mutation behaviour.
  * `countParameterChangeSignatures` dedup property.
  * `signingInputForParameterChange` byte-stability and
    cross-protocol distinguishability.
  * Domain-prefix presence verification.

Plus extensions to `Test/Bridge/Finalisation.lean` (~3 cases)
covering the parameter-driven `isFinalisedFromES` form.

### PA.6 — `Admissible` predicate extension + Staking refactor

**File modified:** `LegalKernel/Authority/SignedAction.lean`.

**Also modified:** `LegalKernel/Disputes/Staking.lean` to add the
parameter-driven helpers (§19.2).

**Deliverables:**

  * `parametersPermit` predicate (§18.2) + decidability instance.
  * `parameterActionAdmissibleWith` predicate (§18.3) +
    decidability instance.
  * Extended `AdmissibleWith` body with conjuncts 7 + 8.
  * Field extractors (§18.4, 4 theorems).
  * Strict-narrowing theorem
    (`admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`).
  * Composition theorem (`admissible_lp_pa_compose`).
  * Stale-signer theorem
    (`removed_governance_signer_loses_authority`).
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

**Test file:** existing `Test/Authority/SignedAction.lean`
extended with ~12 new tests covering:

  * Per-action `parametersPermit` behaviour
    (`maxTransferAmount` cap enforcement; `maxMintAmount` cap
    enforcement; vacuous on uncapped actions).
  * `parameterActionAdmissibleWith` quorum success / failure
    paths.
  * Validity rejection of invalid `newParams`
    (zero-quorum, etc.).
  * Cross-actor independence: an `applyParameterChange` by
    actor A is admissible regardless of actor B's local
    policy.
  * Strict-narrowing value-level check
    (default `Parameters` ⇒ same admissibility as pre-PA).
  * `removed_governance_signer_loses_authority` value-level
    test.

Plus extensions to `Test/Disputes/Staking.lean` (~3 cases)
covering the parameter-driven `fileDisputeStakedFromES` form.

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

  * `lake build LegalKernel.Parameters.LawClassification` succeeds.
  * The new ctor's compiled transition resolves to
    `IsConservative` and `IsMonotonic` instances via
    `inferInstance`.

**Test file:** `Test/Parameters/LawClassification.lean` (new).

  * 4 cases (2 instance-resolution checks × 2 properties);
    plus the composite theorem's API stability check.

PA.7 is **independent of PA.6** and may land in parallel.

### PA.8 — Event extension

**Files modified:**

  * `LegalKernel/Events/Types.lean` — append `parametersChanged`
    ctor at index 13; extend projections.
  * `LegalKernel/Events/Extract.lean` — extend `actionEvents` /
    `extractEvents` with the new emission rule.

**Deliverables:**

  * `Event.parametersChanged` constructor.
  * `Event.actor` extension (returns `none`).
  * `Event.isParameterEvent` classifier.
  * Emission rule theorem (§20.8).

**Acceptance criteria:**

  * `lake build LegalKernel.Events.Types` succeeds.
  * `lake build LegalKernel.Events.Extract` succeeds.
  * Emission is deterministic; old + new params are recorded
    accurately.

**Test files:** existing `Test/Events/Types.lean` and
`Test/Events/Extract.lean` extended with ~6 new cases covering
projections, classifier, and emission on `applyParameterChange`.

### PA.9 — End-to-end tests

**File:** `Test/Authority/ParameterChangeAdmissibility.lean` (new).

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
     [A, B]; vote to add C; subsequent vote uses new threshold
     and new signer set.
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

**Acceptance criteria:**

  * `lake build LegalKernel.Test.Authority.ParameterChangeAdmissibility`
    succeeds.
  * All 13 scenarios pass at the value level.
  * Each scenario emits the expected events (verified via
    `extractEvents` cross-check).

### PA.10 — Documentation and integration

**Files modified:**

  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"canon-actor-policies-and-parameters"`; add new module
    imports.
  * `Tests.lean` — register new test suites.
  * `Test/Umbrella.lean` — update build-tag literal.
  * `CLAUDE.md` — add Workstream-PA changelog entry; extend
    the type-level properties table; update source-layout
    listing.
  * `README.md` — bump status line.
  * `docs/GENESIS_PLAN.md` — append to the §X (LP section)
    a §X.bis subsection documenting parameterised laws.
  * `docs/std_dependencies.md` — verify no new Std imports
    needed.
  * `docs/abi.md` — append the new `Action` ctor (index 17)
    and `Event` ctor (index 13) to the on-disk-format
    listings.
  * `docs/extraction_notes.md` — verify no extraction
    changes needed.
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

---

# Part III — Combined LP + PA: tests, risks, acceptance

## §22 Combined plan summary

### 22.1 Combined test count

| Workstream | New suites | New cases | Extended suites    | Extension cases | Total  |
|------------|------------|-----------|--------------------|-----------------|--------|
| LP         | 4          | ~43       | 6                  | ~37             | ~80    |
| PA         | 4          | ~35       | 8                  | ~44             | ~79    |
| **Total**  | **8**      | **~78**   | **8 (3 shared)**   | **~81**         | **~159** |

Post-LP+PA test count target: ~1183 (current 1024 + 159).
Estimates only; final counts depend on per-clause positive/
negative variant choices and on whether property-based tests
(§11.3, §22.4) ship in this workstream or a follow-up.

### 22.2 PA test suites and extensions

**New suites:**

| Suite                                                | Cases | PA unit |
|------------------------------------------------------|-------|---------|
| `Test/Authority/Parameters.lean`                     | ~10   | PA.1    |
| `Test/Encoding/Parameters.lean`                      | ~7    | PA.2    |
| `Test/Parameters/LawClassification.lean`             | ~5    | PA.7    |
| `Test/Authority/ParameterChangeAdmissibility.lean`   | ~13   | PA.9    |

**Extended suites (delta-only):**

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

### 22.3 LP+PA integration test scenarios

These tests exercise the *interaction* between LP and PA, which
neither workstream's individual test suite covers in isolation.
They go in `Test/Authority/LpPaIntegration.lean` (new in PA.9):

  1. **Both pillars must permit.**  Actor A has
     `LocalPolicy { capAmount r 100 }`; deployment has
     `Parameters { maxTransferAmount := some 50 }`.
     A's `transfer r ? ? 30` succeeds (both permit);
     A's `transfer r ? ? 75` fails (PA caps at 50);
     A's `transfer r ? ? 200` fails (LP caps at 100).
  2. **LP-meta-exempt actions are still PA-checked.**  Actor A
     declares `denyTags [16]` (deny revokeLocalPolicy); A signs
     `revokeLocalPolicy` — succeeds (LP meta-exempt).  But A's
     `applyParameterChange` is NOT LP-meta-exempt: A's
     LocalPolicy denying tag 17 would block it.  Verifies the
     meta-exemption is scoped to LP's two ctors only.
  3. **PA can set parameters that affect LP-bound actions.**
     Governance votes to set `maxTransferAmount := some 100`;
     subsequent transfers by an unrelated actor with amount
     200 fail despite that actor's empty `LocalPolicy`.
  4. **Parameter change without governance is impossible.**  In
     `ExtendedState.empty` (empty `governanceSigners`), even
     under `AuthorityPolicy.unrestricted`, no
     `applyParameterChange` is admissible.  Demonstrates the
     bootstrap requirement.
  5. **Strict-narrowing under defaults.**  A pre-LP-pre-PA
     fixture's complete chain of transfers / mints / etc. is
     re-replayed against an `ExtendedState` with default
     `localPolicies` and `parameters`.  Every original action
     remains admissible byte-for-byte.
  6. **LP+PA event ordering.**  When an `applyParameterChange`
     is applied, the emitted events are in the order
     `[balanceChanged?, nonceAdvanced, parametersChanged]`.
     When a `declareLocalPolicy` is applied,
     `[nonceAdvanced, localPolicyDeclared]`.  The two event
     streams are distinct.

### 22.4 Property-based tests (combined)

Beyond the LP property tests in §11.3, PA adds two more:

  3. **`parameters_roundtrip_property`**: for every
     `Parameters` value satisfying `fieldsBounded`, decoding
     after encoding recovers the value.  Generator: random
     `Nat`, random `List Nat` of length 0..5, random
     `Option Nat`.
  4. **`quorum_dedup_property`**: for every signers /
     sigs / governanceSigners triple, the quorum count is
     ≤ |distinct signers ∩ governanceSigners|.

Property tests are recommended but not mandatory.

## §23 Combined backwards compatibility

### 23.1 Pre-LP-pre-PA snapshot tolerance

Each workstream's `ExtendedState.decode` extension uses the
tolerant-tail strategy.  Combined effect:

  * Pre-LP snapshot decoded under post-LP-pre-PA build:
    `localPolicies = empty` (LP.3 tolerance).
  * Pre-LP snapshot decoded under post-PA build:
    `localPolicies = empty` AND `parameters = empty`
    (LP.3 + PA.3 tolerance composed).
  * Post-LP-pre-PA snapshot decoded under post-PA build:
    `parameters = empty` (PA.3 tolerance).

The combined-tolerance theorem
(`extendedState_decode_pre_LP_pre_PA_compatible`, PA.3)
certifies this composition holds in Lean.

### 23.2 Genesis governance bootstrap

Per §16.3, `Parameters.empty` is invalid (empty governance set
breaks `Parameters.valid`).  This is by design: deployments
must explicitly seed `governanceSigners` at genesis.

The deployment-time procedure:

  1. Construct `ExtendedState` with
     `parameters := { quorumThreshold := T, governanceSigners
     := [s_1, …, s_n], … }` for chosen `T ∈ [1, n]` and
     governance signers `s_1, …, s_n`.
  2. Verify off-chain that
     `Parameters.valid es.parameters = true`.
  3. Compute `stateHash es` and distribute to all nodes.
  4. The chain starts; subsequent governance changes go
     through `applyParameterChange`.

A deployment that boots from `ExtendedState.empty` without
seeding governance has a **soft-bricked governance surface**:
non-`applyParameterChange` actions still work normally, but no
parameter change can ever be admitted.  The deployment can
continue indefinitely as an "ungoverned" chain — this is
intentional, and the strict-narrowing theorem
(`admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`)
guarantees identical behaviour to a pre-LP-pre-PA deployment.

### 23.3 On-disk log format

The three new `Action` constructors at indices 15, 16, 17
extend the existing CBE codec.  Old log files containing only
constructors 0..14 decode unchanged.  New log files containing
new constructors cannot decode under pre-LP-pre-PA builds, but
`kernelBuildTag` mismatch surfaces at handshake time.

### 23.4 Snapshot format (combined)

Each upgrade is forward-compatible:

```
Pre-LP-pre-PA snapshot ───┬──► Post-LP build: tolerated, localPolicies = empty
                          └──► Post-PA build: tolerated, both = empty
Post-LP-pre-PA snapshot ──── ► Post-PA build: tolerated, parameters = empty
Post-PA snapshot         ──── ► Post-PA build: decoded verbatim
```

No pre-PA build can read a post-PA snapshot;
`kernelBuildTag` mismatch at handshake prevents mixed-version
networks.

### 23.5 Runtime adaptor compatibility

The Phase-5 runtime CLI (`canon` binary) and audit binary
(`canon-replay`) work unchanged.  Their input format extends
backwards-compatibly per §23.1 / §23.3.  No new subcommand for
parameter changes — they're submitted as ordinary signed
actions through the existing `process` subcommand.

## §24 Combined risks and open questions

### 24.1 Resolved risks (combined)

LP-side risks (§13.1) carry through unchanged.  PA-side risks
resolved:

  * **Validity safety net.**  Resolved by `Parameters.valid` +
    admissibility conjunct 8.  No quorum, however large, can
    install invalid parameters.
  * **Quorum dedup.**  Resolved by per-signer dedup in
    `countParameterChangeSignatures`, mirroring the post-audit
    `Disputes/Verdict.countVerifiedSignatures` fix.
  * **Cross-protocol signature replay.**  Resolved by
    `parameterChangeDomain` distinct from `signedActionDomain`
    and `verdictDomain` (theorems
    `parameterChangeDomain_distinct_from_*`).
  * **Stale-signer replay.**  Resolved by the
    `removed_governance_signer_loses_authority` theorem.
  * **Bootstrap lockout.**  Resolved by deliberately invalid
    `Parameters.empty`.
  * **TCB expansion.**  Resolved: every PA module is non-TCB.
  * **Axiom expansion.**  Resolved: no new `axiom` or
    `opaque`.
  * **LP-PA composition correctness.**  Resolved by
    `admissible_lp_pa_compose` theorem.
  * **Replay-protection regression.**  Resolved: proofs depend
    only on nonce monotonicity, unchanged by PA.

### 24.2 Open questions / future work

LP-side open questions (§13.2) carry through unchanged.
PA-side open questions:

  * **Token-/stake-weighted quorum.**  Each governance signer
    contributes 1.  A future workstream could weight by
    resource-0 balance, requiring snapshot-at-proposal-time
    semantics to prevent mid-vote balance manipulation.

  * **Two-stage propose-then-apply pipeline.**  Adds an
    `Action.proposeParameterChange` step prior to
    `applyParameterChange`.  Pros: on-chain proposal record;
    timelock-style activation delay.  Cons: doubles the
    on-chain action count; introduces "live proposal" state
    requiring invalidation rules on signer rotation.

  * **Delta-style parameter updates.**  An action that applies
    a list of named field changes rather than full-record
    replacement.  Saves on-chain bytes when only one field
    changes.  Requires recursive ADT encoding.

  * **Effective-at-block delayed activation.**  Add a
    `Parameters.pending : Option (Parameters × LogIndex)` field.
    Provides timelock behaviour.  Defer until demand justifies.

  * **Per-resource parameter caps.**  `maxTransferAmount` is
    currently global.  Replacing `Option Amount` with
    `TreeMap ResourceId Amount compare` is trivially additive.

  * **Governance-actor LocalPolicy interaction.**  A governance
    signer could decline themselves participation via LP.
    Correct per the design; deployments wanting to forbid
    governance-LP can do so via `AuthorityPolicy`.

  * **Parameter migration across `CanonMigration`.**  When a
    chain forks via `CanonMigration` (Workstream E.5), the
    successor inherits the predecessor's `parameters`.
    Deployments wanting to reset parameters at fork time need
    a custom migration sequence.  Document but don't
    automate.

### 24.3 Known limitations (combined)

  * **No timelock.**  Parameter changes activate immediately.
    A malicious quorum can install harmful parameters
    without notice.  Mitigation: deployments restrict
    `applyParameterChange` proposers via `AuthorityPolicy`;
    validators may exit via `CanonMigration` if governance
    behaves badly.

  * **Quorum gaming via key compromise.**  An attacker who
    compromises k governance keys (where k = quorumThreshold)
    can change parameters arbitrarily.  Standard
    threshold-signature trust assumption.

  * **No automatic governance rotation.**  Disappeared signers
    remain in `governanceSigners` until removed by an explicit
    `applyParameterChange`.  If too many disappear, the
    quorum may become unmeetable.  Deployments should plan
    for redundancy.

  * **No on-chain failed-proposal record.**  An
    `applyParameterChange` that fails admissibility leaves no
    on-chain trace.  Deployments wanting failed-proposal
    audit trails must collect that data off-chain.

  * **No partial parameter revocation.**  Same as LP §13.3 —
    replacing one field requires submitting a full new
    `Parameters` value.

## §25 Combined acceptance criteria

The combined LP + PA workstream is complete when, on the head
commit of the landing branch, all of the following hold:

### 25.1 Build and test gates

  1. **LP gates.**  All §14 acceptance criteria (12 gates)
     pass.
  2. **PA gates.**  PA-side analogs:
     a. `lake build` succeeds on a clean checkout.
     b. `lake test` reports zero failures across every
        registered suite (LP + PA + integration).
     c. `lake exe count_sorries` returns 0.
     d. `lake exe tcb_audit` passes (no TCB allowlist
        violations).
     e. `lake exe stub_audit` passes.
     f. `scripts/axiom_audit.sh` passes for every PA-introduced
        theorem.

### 25.2 PA-specific theorem gates

  3. **Frozen-index invariants.**  `Action`'s constructor list
     ends with `applyParameterChange` at index 17 (after LP's
     ctors at 15, 16); `Event`'s ends with `parametersChanged`
     at index 13.  Verified by integration test.
  4. **Backward-compat (PA).**  Loading a pre-PA snapshot on
     the post-PA build produces an `ExtendedState` with
     `parameters = Parameters.empty` and the other fields
     byte-identical.  Verified by value-level test.
  5. **Strict-narrowing (combined).**  The
     `admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`
     theorem proves without `sorry` and depends only on the
     standard axioms.
  6. **Validity safety net.**  The
     `Parameters.empty_invalid` and
     `applyParameterChange_admissible_implies_valid` theorems
     prove without `sorry`.
  7. **Quorum dedup.**  The
     `countParameterChangeSignatures_le_governance_size`
     theorem proves without `sorry`.
  8. **Cross-protocol replay protection.**  The
     `parameterChangeDomain_distinct_from_signedActionDomain`
     and `parameterChangeDomain_distinct_from_verdictDomain`
     theorems prove without `sorry`.
  9. **Stale-signer protection.**  The
     `removed_governance_signer_loses_authority` theorem
     proves without `sorry`.
  10. **Replay-protection unchanged.**  `replay_impossible` and
      `nonce_uniqueness` re-test (API stability + value
      level).  Both pass.
  11. **LP-PA composition.**  The `admissible_lp_pa_compose`
      theorem proves without `sorry`.
  12. **Consumer integration (PA.5 + PA.6).**  The
      `isFinalisedFromES_equiv` and
      `fileDisputeStakedFromES_equiv` theorems prove without
      `sorry`.

### 25.3 Documentation gates

  13. **`kernelBuildTag` bumped** to
      `"canon-actor-policies-and-parameters"`; Umbrella test
      verifies the new value.
  14. **CLAUDE.md** "Active development status" section names
      both LP and PA as complete; the source-layout listing
      reflects both new module trees; the type-level
      properties table gains the new entries (LP + PA).
  15. **Genesis-Plan amendment** drafted (PA.10 deliverable);
      formal specification of LP and PA included in
      `docs/GENESIS_PLAN.md`.
  16. **`docs/abi.md`** updated with the new action and event
      constructor indices.
  17. **`docs/std_dependencies.md`** verified to require no new
      Std imports.

The workstream is **not** complete (and the PR is not landable)
until every gate above passes simultaneously.  Partial
completion is documented as in-progress and committed only with
the `work-in-progress` PR label.

Per the dependency DAG (§21), LP may land in a separate PR
ahead of PA.  In that case, the LP-only PR requires the §14
acceptance criteria; the subsequent PA PR requires the §25
acceptance criteria but only the §25.2 / §25.3 PA-specific
gates need re-discharging (the §25.1 LP gates were already
verified at LP-merge time).

---

**Document version:** v2 (LP + PA), drafted by Claude on branch
`claude/add-law-voting-0jBAh`.  The original v1 covered LP only;
v2 extends to the combined LP + PA plan per the law-voting
analysis recommendation.  Subsequent edits track real
implementation decisions and are reflected in the in-tree
changelog (CLAUDE.md "Active development status").  This file is
informational; the canonical specification is the Genesis-Plan
amendment that PA.10 is charged with drafting.
