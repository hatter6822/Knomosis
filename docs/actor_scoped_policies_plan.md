<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Actor-Scoped Policies (Workstream LP) — Engineering Plan

This document plans the engineering effort needed to add **per-actor,
on-chain, mutable policy filters** to Canon.  It is a roadmap, not a
specification; the formal design will be promoted into a Genesis-Plan
amendment once the work-unit set lands.

The motivating observation is that Canon's determinism contract makes
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
    `LP.1` … `LP.10` to disambiguate from the Genesis-Plan
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

## Cross-references

  * **Workstream PA — Parameterized Laws.**  Companion plan that
    builds on LP to add a deployment-wide, quorum-vote-mutable
    `Parameters` table.  Together LP and PA realise the
    "actors customise their own behaviour + the community votes
    on shared parameters" architecture.  PA depends on LP being
    landed (or merged into the same PR) per the dependency
    sketch in PA's §2.  See
    `docs/parameterized_laws_plan.md`.

---

**Document version:** v1, drafted by Claude on branch
`claude/add-law-voting-0jBAh`.  Subsequent edits track real
implementation decisions and are reflected in the in-tree
changelog (CLAUDE.md "Active development status").  This file is
informational; the canonical specification is the Genesis-Plan
amendment that LP.10 is charged with drafting.
