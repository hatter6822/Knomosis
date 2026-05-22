/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Authority.SignedAction — SignedAction, Admissible,
apply_admissible, and the §8.5 replay-protection theorems.

Phase 3 WU 3.6, 3.7, 3.8, and 3.10.  Defines the runtime-facing
`SignedAction` (an `Action` plus signer / nonce / signature), the
five-condition `Admissible` predicate (§8.2), the single guarded
entry point `apply_admissible`, and the headline theorems
`nonce_uniqueness` and `replay_impossible`.  Also lands the
authority-layer effect of the `replaceKey` action: `apply_admissible`
post-processes a successful `replaceKey` by mutating the
`ExtendedState.registry` field.

Coverage map:

  * WU 3.6 — `SignedAction` structure, `Admissible` predicate.
  * WU 3.7 — `apply_admissible` entry point, `nonce_uniqueness`.
  * WU 3.8 — `replay_impossible` headline theorem.
  * WU 3.10 — `replaceKey` authority-layer effect via
              `apply_admissible_registry_update`.

This module is **not** part of the trusted computing base.  The
authority-layer guarantees (replay protection, registration check)
hold under the EUF-CMA assumption on the deployment-supplied
`Verify` adaptor; bugs in this file would weaken those guarantees
but cannot violate any kernel invariant.

The deployment-facing API exposed here:

  * `SignedAction` — what the network layer parses.
  * `Admissible P es st` — the §8.2 five-condition predicate.
  * `apply_admissible P es st h` — the only externally callable
    state-advance path; takes the admissibility witness as a
    dependent proof argument so that no admissibility check can be
    skipped.
  * `nonce_uniqueness` — two distinct admissible signed actions by
    the same signer cannot share a nonce.
  * `replay_impossible` — a successfully applied signed action is
    not admissible at the post-state.
-/

import LegalKernel.Kernel
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Action
import LegalKernel.Authority.Identity
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Authority.Nonce
import LegalKernel.Authority.ActorBudget
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Encoding.Action

open Std

namespace LegalKernel
namespace Authority

/-! ## SignedAction (§8.2 / WU 3.6) -/

/-- A signed action carries serialisable data only: an `Action`, the
    signer's `ActorId`, a per-actor `Nonce` for replay protection,
    and a signature over the canonical encoding of `(action, signer,
    nonce)` (Phase 4 supplies the encoding).

    `SignedAction` is the data network nodes exchange and that the
    log persists; the kernel's `apply_admissible` consumes one
    `SignedAction` per state advance. -/
structure SignedAction where
  /-- The action being signed.  Lives in `Action`-space (first-order
      data) so that the canonical encoding (Phase 4) is well-defined. -/
  action : Action
  /-- The signer's actor identifier.  Must match a registered
      identity in the `ExtendedState.registry` for admissibility
      condition 1 to hold. -/
  signer : ActorId
  /-- The signer's per-actor nonce.  Must equal `expectsNonce es
      signer` for admissibility condition 4 to hold. -/
  nonce  : Nonce
  /-- The signature over the canonical encoding of `(action, signer,
      nonce)` under the signer's registered public key. -/
  sig    : Signature
  deriving Repr

/-! ## The signing-input encoding (§8.8)

The `signingInput` function returns the canonical bytes that an
adjudicator's signature is computed over.  The function is content-
distinguishing: distinct `(action, signer, nonce)` triples produce
distinct byte sequences, by injectivity of the underlying CBE
encoding (the `Action` encoder of `LegalKernel.Encoding.Action` is
prefix-tagged + field-wise injective, plus the per-`Nat` round-trip
of the `Encodable` typeclass).

**Domain separation.**  The signing input is prefixed with the
ASCII-encoded domain string `"legalkernel/v1/signedaction"`
(length-prefixed via the standard CBE byte-string encoding).  This
prefix prevents *cross-protocol* signature replay: a signature on
a `SignedAction` cannot be re-interpreted as a signature on (e.g.)
a `Verdict` payload, because the verdict's signing input begins
with `"legalkernel/v1/verdict"`.

**Cross-deployment replay.**  The Genesis Plan §8.8.5 also calls
for a deployment-id (genesis-state hash) prefix to prevent the
same `(action, signer, nonce)` triple from being signed under one
deployment and replayed under another.  `Encoding.signInput`
(Phase 4 WU 4.8) provides the full canonical form including the
deploymentId.  The function below deliberately omits the
deploymentId because `Admissible` is parameterised only on
`ExtendedState`, not on a deployment identifier; in production
the runtime adaptor MUST scope `Verify` per-deployment (e.g. by
binding the public-key registry to a deployment-specific keyring)
so that signatures are deployment-unique even without an explicit
prefix.

Phase-history note.  Earlier revisions of this file shipped a
`ByteArray.empty` stub here while `Encoding/SignInput.lean` (Phase
4) was still under construction.  That stub left every `Verify`
call seeing identical bytes for every action — a deployment
correctness blocker.  The body below replaces the stub with a
domain-separated CBE encoding; the within-deployment + cross-
protocol uniqueness properties the `Admissible` predicate now
asserts at the value level match what the §8.8.5 spec requires
modulo the (deployment-scoped) deploymentId prefix. -/

/-! ## Shared domain-separation prefix

`signedActionDomain` and its `ByteArray` form are defined in
`LegalKernel/Authority/Crypto.lean`.  AR.1 / M-7 consolidates the
previous two duplicated string literals (here and in
`Encoding/SignInput.lean`) into one canonical source.  The string
is encoded as a CBE byte string (length-prefixed) before being
prepended to the per-action payload; consumers therefore
self-delimit the prefix from the action payload that follows. -/

/-- The canonical signing input bytes for a `(action, signer, nonce,
    deploymentId)` quadruple (Audit-3.4).

    Layout (concatenation of CBE encodings):

      * Domain prefix — the ASCII bytes of `signedActionDomain`
        (`"legalkernel/v1/signedaction"`), wrapped as a CBE byte
        string (1 type byte + 8-byte LE length + UTF-8 bytes).
        This prevents cross-protocol signature replay (see the
        section docstring).
      * `Encodable.encode (T := ByteArray) deploymentId` — the
        deployment-binding bytes (genesis-state hash; supplied by
        the runtime adaptor at bootstrap time, `ByteArray.empty`
        for tests / single-deployment runs).  Audit-3.4: makes
        cross-deployment-replay rejection a kernel-level guarantee;
        previously this was scoped only by the runtime adaptor's
        per-deployment `Verify` instance.
      * `Encodable.encode action` — the action constructor + fields,
        per `LegalKernel.Encoding.Action`.
      * `Encodable.encode signer.toNat` — the actor id as a CBE
        unsigned integer.
      * `Encodable.encode nonce` — the per-actor counter as a CBE
        unsigned integer.

    Each component is length-prefixed (for byte strings) or
    fixed-width (for unsigned integers), so the concatenation is
    self-delimiting and injective in `(action, signer, nonce,
    deploymentId)`.  Distinct quadruples therefore yield distinct
    signing inputs, which is the cross-deployment-replay-protection
    requirement for `Verify`. -/
def signingInput (action : Action) (signer : ActorId) (nonce : Nonce)
    (deploymentId : ByteArray) : SigningInput :=
  let domainBytes : Encoding.Stream :=
    -- CBE-encode the domain string as a byte string: tag + 8-byte
    -- LE length + UTF-8 payload.
    Encoding.cborHeadEncode Encoding.cbeTagBytes signedActionDomain.toUTF8.size ++
      signedActionDomain.toUTF8.data.toList
  ByteArray.mk
    (domainBytes ++
     Encoding.Encodable.encode (T := ByteArray) deploymentId ++
     Encoding.Encodable.encode (T := Action) action ++
     Encoding.Encodable.encode (T := Nat) signer.toNat ++
     Encoding.Encodable.encode (T := Nat) nonce).toArray

/-! ## Admissible (§8.2 / WU 3.6)

The five conditions of §8.2:

  1. The signer is registered (`registry.find? signer = some pk`).
  2. The policy permits this signer to issue this action
     (`P.authorized signer action`).
  3. The signature verifies under the registered key.
  4. The nonce matches the actor's next-expected nonce.
  5. The compiled transition's precondition holds in the base state.

LP.7 adds a sixth condition (top-level conjunct):

  6. The signer's local policy (defaulting to empty) permits the
     action, OR the action is a policy-management meta-action
     (`declareLocalPolicy` / `revokeLocalPolicy`), which are
     structurally exempt to prevent lockout.

Each condition is independent and can be discharged at a different
time (Genesis Plan §8.2's "static vs dynamic" split), and the order
of failures is meaningful for diagnostics.

**Note on conjunct count.**  The §8.2 spec lists five admissibility
conditions, but the Lean encoding below has *four* top-level `∧`
connectives (post-LP.7: *five* top-level conjuncts).  This is
because conditions 1 (signer is registered) and 3 (signature
verifies under the registered key) share the existential witness
`pk` and are therefore most naturally combined into a single
conjunct of the form
`∃ pk, registry[signer]? = some pk ∧ Verify pk msg sig = true`.
This packing is *strictly stronger* than two independent existentials
would be — the Verify check is forced to use *the* registered key,
not any key — which is what §8.2 intends. -/

/-! ## §6.2 Meta-action classifier (LP.7)

`isMetaPolicyAction` enumerates the policy-management actions
that are exempt from the local-policy admissibility conjunct.
Defined by *enumeration* over the `Action` inductive's two
LP-introduced constructors, NOT by any policy-derived predicate,
so no `LocalPolicyClause` can ever block a policy-management
action by construction (the structural lockout-prevention
proof). -/

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

/-! ## §6.1 Local-policy admissibility predicate (LP.7) -/

/-- The new admissibility conjunct (LP.7).  An action is permitted
    by the signer's local policy iff:

      * The action is a policy-management meta-action
        (`declareLocalPolicy` or `revokeLocalPolicy`); these are
        structurally exempt — see §6.2 of the actor-scoped
        policies plan.
      * Otherwise, the signer's declared policy (defaulting to
        `LocalPolicy.empty` if absent) permits the action.

    `LocalPolicy.empty.permits` is vacuously `True` (universal
    quantification over an empty list), so signers with no declared
    policy see no admissibility narrowing — the strict-narrowing
    property of LP.7. -/
def localPolicyPermits
    (es : ExtendedState) (signer : ActorId) (action : Action) : Prop :=
  isMetaPolicyAction action = true ∨
    (es.localPolicies.lookup signer).permits signer action

/-- Decidability of `localPolicyPermits`.  Decomposes:

      * `isMetaPolicyAction action = true`: `Bool` equality, decidable.
      * `LocalPolicies.lookup`: pure data lookup.
      * `LocalPolicy.permits`: decidable via
        `instDecidableLocalPolicyPermitsList` (`List.decidableBAll`).
      * The disjunction is decidable via `instDecidableOr`. -/
instance instDecidableLocalPolicyPermits
    (es : ExtendedState) (signer : ActorId) (action : Action) :
    Decidable (localPolicyPermits es signer action) := by
  unfold localPolicyPermits
  exact inferInstance

/-- Audit-3.3 + 3.4: the §8.2 admissibility predicate parameterized
    over the cryptographic verifier function and the deployment id.
    `Admissible` (below) is the back-compat default that uses the
    production `Verify` and `ByteArray.empty` for the deployment id.

    Test code that wants to construct value-level admissible
    witnesses (impossible under the production `Verify`, which is
    `opaque`) uses this parameterized form with a deterministic
    `mockVerify` from `LegalKernel/Test/MockCrypto.lean`.

    Production runtime code (Phase 5 + future BLAKE3 / Ed25519
    deployment) calls this with the linked `Verify` adaptor and
    the deployment's genesis-hash bytes. -/
def AdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  -- 2. Authorisation predicate.
  P.authorized st.signer st.action ∧
  -- 4. Nonce match.
  st.nonce = expectsNonce es st.signer ∧
  -- 1 + 3. Registered signer with valid signature under the registered key.
  --        The shared `pk` forces the Verify check to use *the* registered
  --        key, not an attacker-chosen one.
  (∃ pk, es.registry[st.signer]? = some pk ∧
         verify pk (signingInput st.action st.signer st.nonce deploymentId) st.sig = true) ∧
  -- 5. Compiled transition's precondition.
  (Action.compile st.action).transition.pre es.base ∧
  -- 6. (LP.7) Local-policy permits the action.
  --    Meta-actions (`declareLocalPolicy` / `revokeLocalPolicy`) are
  --    structurally exempt; non-meta actions must satisfy the signer's
  --    declared policy (defaulting to empty, which is vacuously
  --    permissive).  See `localPolicyPermits` and §6.2 of the
  --    actor-scoped policies plan.
  localPolicyPermits es st.signer st.action

/-- The §8.2 admissibility predicate: a signed action is admissible
    in policy `P` at extended state `es` exactly when all five
    Genesis-Plan conditions hold simultaneously (encoded as four
    top-level conjuncts because conditions 1 + 3 share `pk`; see
    the module docstring).

    This is the back-compat alias for
    `AdmissibleWith Verify P ByteArray.empty`: the production
    cryptographic verifier and the empty (single-deployment)
    deployment id.  Existing call sites use this; new code paths
    that need a deterministic test verifier or per-deployment
    binding use `AdmissibleWith` directly. -/
def Admissible
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction) : Prop :=
  AdmissibleWith Verify P ByteArray.empty es st

/-! ### `Admissible` field extractors

Pure projections from the conjunction.  Useful in proofs and tests
that need just one of the five conditions without unpacking the
whole `∧` chain. -/

/-- Extract condition 2: the policy authorises this `(signer, action)`
    pair.

    LP.6 robustness: rewritten to use `obtain ⟨...⟩ := h` rather than
    chained-tuple projection (`h.1`).  The statement is byte-equivalent;
    only the proof body changes.  The new form is robust to LP.7's
    addition of a fifth conjunct (the local-policy admissibility
    check). -/
theorem admissible_authorized
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    P.authorized st.signer st.action := by
  obtain ⟨hAuth, _, _, _, _⟩ := h
  exact hAuth

/-- Extract condition 4: the signed nonce matches the actor's
    next-expected nonce.

    LP.6 robustness: rewritten using `obtain`. -/
theorem admissible_nonce
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    st.nonce = expectsNonce es st.signer := by
  obtain ⟨_, hNonce, _, _, _⟩ := h
  exact hNonce

/-- Extract conditions 1 + 3: the signer is registered with some
    key `pk` and the signature verifies under that key (using the
    production `Verify` and the empty deploymentId — the back-compat
    default; see `AdmissibleWith`-version below for the parameterised
    form).

    LP.6 robustness: rewritten using `obtain`. -/
theorem admissible_signer_registered_and_signed
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    ∃ pk, es.registry[st.signer]? = some pk ∧
          Verify pk (signingInput st.action st.signer st.nonce ByteArray.empty)
            st.sig = true := by
  obtain ⟨_, _, hSig, _, _⟩ := h
  exact hSig

/-- Audit-3.3: the parameterised analogue.  Extract conditions 1 + 3
    from an `AdmissibleWith verify P d` witness.

    LP.6 robustness: rewritten using `obtain`. -/
theorem admissibleWith_signer_registered_and_signed
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : AdmissibleWith verify P d es st) :
    ∃ pk, es.registry[st.signer]? = some pk ∧
          verify pk (signingInput st.action st.signer st.nonce d) st.sig = true := by
  obtain ⟨_, _, hSig, _, _⟩ := h
  exact hSig

/-- GP.3.2: the parameterised analogue of `admissible_nonce`.
    Extract condition 4 (the nonce match) from an
    `AdmissibleWith verify P d` witness. -/
theorem admissibleWith_nonce
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : AdmissibleWith verify P d es st) :
    st.nonce = expectsNonce es st.signer := by
  obtain ⟨_, hNonce, _, _, _⟩ := h
  exact hNonce

/-- Extract condition 5: the compiled transition's precondition holds
    in the base state.

    LP.6 robustness: rewritten using `obtain`. -/
theorem admissible_pre
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    (Action.compile st.action).transition.pre es.base := by
  obtain ⟨_, _, _, hPre, _⟩ := h
  exact hPre

/-- LP.7: extract the new local-policy conjunct (condition 6).
    The signer's declared policy (defaulting to empty) permits the
    action, OR the action is a policy-management meta-action.  The
    `obtain` pattern is robust to future conjunct additions. -/
theorem admissible_localPolicy
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    localPolicyPermits es st.signer st.action := by
  obtain ⟨_, _, _, _, hLP⟩ := h
  exact hLP

/-- LP.7: parameterised analogue of `admissible_localPolicy` for
    `AdmissibleWith verify P d`. -/
theorem admissibleWith_localPolicy
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : AdmissibleWith verify P d es st) :
    localPolicyPermits es st.signer st.action := by
  obtain ⟨_, _, _, _, hLP⟩ := h
  exact hLP

/-- Extract condition 1 alone (signer registration), discarding the
    Verify clause.  Useful for callers that have already discharged
    Verify externally and only need the registration witness. -/
theorem admissible_signer_registered
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    ∃ pk, es.registry[st.signer]? = some pk := by
  obtain ⟨pk, hreg, _⟩ := admissible_signer_registered_and_signed h
  exact ⟨pk, hreg⟩

/-! ## The authority-layer effect of `replaceKey` (WU 3.10)

Most actions only mutate the kernel-level `base` state.  The
`replaceKey` action additionally mutates the `ExtendedState.registry`
field — re-pointing the actor's `PublicKey` entry to the new key.
We factor this into a separate function (`applyActionToRegistry`)
that `apply_admissible` invokes after the kernel-level state advance. -/

/-- Action-specific authority-layer effects.  For most actions, this
    is the identity (the kernel-level `apply_impl` is the entire
    effect).  For `replaceKey actor newKey` and the
    Workstream-B `registerIdentity actor pk`, the registry is
    updated to insert `actor → newKey/pk`.

    The Genesis Plan §8.2 spec does not specify this hook (because
    its sketch put the registry in `AuthorityPolicy`, not
    `ExtendedState`).  Phase 3's design moves the registry to
    `ExtendedState` so `replaceKey` can mutate it; this function
    encapsulates that mutation.

    Workstream B (Ethereum integration §6.3) introduces
    `registerIdentity` for first-time L1-derived identity events.
    Its registry semantics is the same `kr.insert actor key`
    operation that `replaceKey` uses; the distinction lives at the
    `Action` (and `AuthorityPolicy`) layer, where deployments can
    grant the bridge actor `registerIdentity` permission without
    granting general `replaceKey` permission.

    Future authority actions (e.g. `revokeKey`, `delegateAuthority`)
    would extend this function with new branches; `apply_admissible`
    is unchanged. -/
def applyActionToRegistry (kr : KeyRegistry) : Action → KeyRegistry
  | .replaceKey actor newKey       => kr.insert actor newKey
  | .registerIdentity actor pk     => kr.insert actor pk
  -- Workstream-LX (LX.19): codegen-managed Lex
  -- `applyActionToRegistry` arms land between the fence markers
  -- below, *before* the catch-all `_`.  Empty in M1.  M2 allows
  -- Lex laws to dispatch on specific constructors (e.g. a Lex-
  -- defined `replaceKey`-analogue) by inserting an arm here.
  -- BEGIN LEX-GENERATED (do not edit by hand)
  -- END LEX-GENERATED
  | _                              => kr

/-! ## Authority-layer local-policy update (Workstream LP / LP.5)

Most actions don't touch the `ExtendedState.localPolicies` table.
The two LP-introduced action constructors (`declareLocalPolicy` and
`revokeLocalPolicy`) DO mutate it: the signer's policy entry is
either set to a new value or erased.  We factor this into a
separate function `applyActionToLocalPolicies` that
`apply_admissible_with` invokes after the kernel-level state
advance. -/

/-- Action-specific local-policy-table effect.  For most actions,
    this is the identity (the table is unchanged).  For
    `declareLocalPolicy` and `revokeLocalPolicy`, the *signer*'s
    entry is updated.

    The signature takes both the table and the signer's `ActorId`
    because the affected entry is the signer's, not an attacker-
    chosen actor's.  This is the action-design layer guarantee
    that an attacker who signs as actor X can only set X's
    policy, never some other actor Y's: the LP-meta `Action`
    constructors deliberately do NOT take an actor parameter, so
    the signer's `ActorId` is the only actor whose policy can be
    affected.  Combined with the LP.7 admissibility-level
    meta-action exemption (`localPolicy_meta_action_independent`),
    this gives the structural lockout-prevention guarantee: an
    actor can always declare or revoke their *own* policy
    regardless of any prior declaration. -/
def applyActionToLocalPolicies
    (lp : LocalPolicies) (signer : ActorId) : Action → LocalPolicies
  | .declareLocalPolicy policy => lp.declare signer policy
  | .revokeLocalPolicy         => lp.revoke signer
  | _                          => lp

/-! ## apply_admissible (§8.2 / WU 3.7)

The single guarded entry point for state advance.  Takes the
admissibility witness as a dependent argument so that no caller can
skip the check; the resulting `ExtendedState` carries the
post-application state, the advanced nonce, and (for `replaceKey`)
the updated registry.

Order of operations:

  1. Compile the action to a kernel `Transition`.
  2. Apply the transition's `apply_impl` to `es.base`.
  3. Wrap the result in a new `ExtendedState`.
  4. Advance the signer's nonce.
  5. Apply the action-specific authority-layer effect (registry
     update for `replaceKey`).

Steps 4 and 5 commute (they touch disjoint fields of
`ExtendedState`); we order them as written for readability and to
mirror the §8.2 / §8.5 spec's structure. -/

/-- Audit-3.3 + 3.4: the parameterised state-advance.  Same body as
    `apply_admissible` (no behavioural difference), but takes the
    parameterised `AdmissibleWith` witness so that test code with a
    `mockVerify` can construct value-level admissibility witnesses
    and exercise the post-state.

    GP.2.3 (signer-aware transition for `topUpActionBudget`): the
    kernel step uses the signer-aware `Laws.topUpActionBudget
    signer gr ga bi pa` for `topUpActionBudget`, since the law's
    first parameter (the payer) MUST be the signer to produce the
    correct kernel-level balance debit/credit.  Every other action
    falls back to the signer-unaware `Action.compile a |>.transition`.
    Mirrored exactly by `kernelOnlyApply` (Disputes/Evidence.lean) so
    that the §8.4 dispute pipeline's prefix-replay remains
    byte-identical to the runtime path. -/
def apply_admissible_with
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (_h : AdmissibleWith verify P d es st) :
    ExtendedState :=
  -- GP.2.3: thread the signer through the kernel step via
  -- `Action.toTransition`.  For all actions except
  -- `topUpActionBudget`, this is identical to
  -- `(Action.compile st.action).transition`.  For
  -- `topUpActionBudget`, it threads `st.signer` into the law's
  -- payer parameter so the kernel-level balance debit targets
  -- the actual signer (rather than the placeholder bridgeActor).
  let t   := Action.toTransition st.action st.signer
  -- GP.2.3 safety: use `step_impl` (which gates on `t.pre`) rather
  -- than `t.apply_impl` directly.  For non-topUpActionBudget actions
  -- under the witness, the witness's precondition gives
  -- `t.pre es.base = True`, so `step_impl es.base t = t.apply_impl
  -- es.base` (the old behaviour).  For topUpActionBudget, the
  -- witness's precondition is vacuous (compile.transition is
  -- `Laws.freezeResource 0`, precondition `True`) but the signer-
  -- aware `Laws.topUpActionBudget signer ...`'s precondition
  -- (signer has ≥ gasAmount of gasResource) may NOT hold.  Using
  -- `step_impl` keeps the kernel-level effect a no-op on
  -- insufficient gas, preventing the `Nat`-subtraction-underflow
  -- non-conservation hazard.  The admission gate
  -- (`apply_admissible_with_budget`, GP.3.2) rejects the action
  -- earlier when the gas precondition fails, so the no-op branch
  -- is reachable only by callers that bypass the budget gate.
  let s'  := step_impl es.base t
  let es' := { es with base := s' }
  let es'' := advanceNonce es' st.signer
  let es''' : ExtendedState :=
    { es'' with registry := applyActionToRegistry es''.registry st.action }
  -- LP.5: apply the local-policy-table effect.  Uses the
  -- *signer*'s ActorId, not an attacker-chosen actor's, because
  -- `applyActionToLocalPolicies` only mutates the signer's entry
  -- — a structural guarantee that an actor cannot mutate someone
  -- else's local policy.
  { es''' with
    localPolicies := applyActionToLocalPolicies es'''.localPolicies st.signer st.action }

/-! ## GP.3.2 admission-gate helpers -/

/-- GP.3.2 signer-aware kernel precondition gate.

    Returns `true` iff the action can safely proceed to the budget
    gate WITHOUT exposing the budget-without-gas attack vectors:

    * For `topUpActionBudget gr ga bi pa`: the signer must have a
      *strictly positive* gas amount AND at least `ga` balance.
      - `ga > 0` defends against the **zero-gas attack**: signing
        `topUpActionBudget gr 0 huge pa` would otherwise pass the
        old `getBalance ≥ 0` check trivially, no-op the kernel
        step (debit 0 / credit 0), and STILL credit the signer's
        budget by `huge`.  Without this conjunct, free unbounded
        budget accumulation is possible.
      - `getBalance ≥ ga` defends against the **insufficient-gas
        attack**: signing `topUpActionBudget gr (balance + 1) bi
        pa` would otherwise pass an old-style `AdmissibleWith`
        (whose compile-transition precondition is the vacuous
        `Laws.freezeResource 0`'s `True`), no-op the kernel step
        (via `step_impl`'s underflow guard), and STILL credit
        `bi` to the signer.  Without this conjunct, free budget
        without paying gas is possible.

    * For every other action constructor: vacuously `true`.  The
      signer-aware transition coincides with the signer-unaware
      compile-transition (via
      `Action.toTransition_eq_compileTransition_of_ne_topUp`), and
      the `AdmissibleWith` witness's precondition establishes the
      check structurally.

    Defined as a named `def` (rather than an inline `let`) so the
    GP.3.2 admission theorems can `by_cases` on it cleanly via the
    `Decidable` instance for `Bool`.  -/
def topUpActionBudget_gasCheck (action : Action) (signer : ActorId)
    (es : ExtendedState) : Bool :=
  match action with
  | .topUpActionBudget gasResource gasAmount _ _ =>
      decide (gasAmount > 0 ∧ getBalance es.base gasResource signer ≥ gasAmount)
  | _ => true

/-- For every non-`topUpActionBudget` action, the gas check is
    trivially `true`.  Used by the GP.3.2 proofs to discharge the
    safety gate on non-topUp dispatch paths. -/
theorem topUpActionBudget_gasCheck_true_of_ne_topUp
    (action : Action) (signer : ActorId) (es : ExtendedState)
    (hne : ∀ gr ga bi pa, action ≠ .topUpActionBudget gr ga bi pa) :
    topUpActionBudget_gasCheck action signer es = true := by
  unfold topUpActionBudget_gasCheck
  cases hact : action with
  | topUpActionBudget gr ga bi pa => exact absurd hact (hne gr ga bi pa)
  | _ => rfl

/-- GP.3.2 admission entry-point with budget-policy integration.

    Behaviour (under `BudgetPolicy.bounded freeTier actionCost currentEpoch`):

    1. **bridgeActor exemption (GP.3.2.c, per OQ-GP-6).**  If
       `st.signer = Bridge.bridgeActor`, the consume step is skipped
       entirely.  The bridge actor's signed actions are L1-gas-gated
       upstream (every `depositWithFee` / `registerIdentity` /
       `deposit` originates from a real L1 transaction whose gas
       cost is paid by the user), so a separate budget gate would
       be redundant and could lock out legitimate bridge events.
       The exemption keeps the admission single-shape: the budget
       map passes through unchanged for bridgeActor-signed actions.

    2. **Non-bridge consume.**  For all other signers, attempt to
       consume `actionCost` units from the signer's epoch budget
       using `EpochBudgetState.consume`.  On success, apply the
       already-proven admissible action and persist the consumed
       budget map.  On insufficient budget, return `none` without
       applying the action.

    This function intentionally does not re-check admissibility: it
    consumes the existing dependent witness and only adds a budget gate
    around the application step.

    **WARNING (RB.3, 2026-05-22): this entry is NOT bridge-aware.**  It
    accepts only the kernel-level `AdmissibleWith` witness and applies
    via `apply_admissible_with`, which leaves the
    `ExtendedState.bridge` field unchanged — even for `deposit` and
    `withdraw` actions that should mutate it.  Production runtime
    paths (`processSignedActionWith`, `processPure`, `replayStepWith`)
    post-RB.3 dispatch on `BridgeAdmissibleWith` and apply via
    `Bridge.apply_bridge_admissible_with_budget`, which atomically
    advances both the kernel and bridge state.  The bridgeActor
    exemption is mirrored there so the production path enjoys the
    same property.  Use the bridge-aware entry for any new runtime
    call site.  This kernel-only variant is retained for back-compat
    with downstream callers that intentionally operate below the
    bridge layer (e.g. unit-level tests of the kernel-state
    transition, or deployments that do not enable the bridge
    subsystem). -/
def apply_admissible_with_budget
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st) :
    Option ExtendedState :=
  match es.budgetPolicy with
  | .bounded freeTier actionCost currentEpoch =>
      -- GP.3.2 safety gate: signer-aware kernel precondition check
      -- for `topUpActionBudget` (see `topUpActionBudget_gasCheck`
      -- docstring for the full security rationale).
      if ! topUpActionBudget_gasCheck st.action st.signer es then
        none
      else
      -- Per-action budget-grant helper (inlined `let`).  Captures
      -- `freeTier` and `currentEpoch` from the enclosing match
      -- so proofs can simp through cleanly.
      let applyGrant (ebs : EpochBudgetState) : EpochBudgetState :=
        match st.action with
        | .depositWithFee _ recipient _ _ _ budgetGrant _ =>
            ebs.topUp recipient currentEpoch freeTier budgetGrant
        | .topUpActionBudget _ _ budgetIncrement _ =>
            ebs.topUp st.signer currentEpoch freeTier budgetIncrement
        | _ => ebs
      if st.signer = Bridge.bridgeActor then
        -- GP.3.2.c: bridgeActor exemption (per OQ-GP-6).  Skip the
        -- consume step; bridge-signed actions are L1-gas-gated upstream.
        let applied := apply_admissible_with verify P d es st h
        some { applied with epochBudgets := applyGrant es.epochBudgets }
      else
        match EpochBudgetState.consume es.epochBudgets st.signer currentEpoch freeTier actionCost with
        | none => none
        | some ebs' =>
            let applied := apply_admissible_with verify P d es st h
            some { applied with epochBudgets := applyGrant ebs' }

/-- §8.2 / WU 3.7: the only externally callable state-advance path.
    The dependent `Admissible` witness ensures every call site has
    discharged the five-condition check before any state changes.

    Returns the post-application `ExtendedState` with `base` advanced
    via the compiled transition, `nonces` advanced by one for the
    signer, and `registry` updated for `replaceKey` actions
    (untouched otherwise).

    Audit-3.3 + 3.4: defined as `apply_admissible_with Verify
    ByteArray.empty` for back-compat with existing call sites. -/
def apply_admissible
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    ExtendedState :=
  apply_admissible_with Verify P ByteArray.empty es st h

/-! ## Properties of `apply_admissible`

These are mechanical observations that downstream theorems
(`nonce_uniqueness`, `replay_impossible`) consume. -/

/-- The post-application `base` state equals the kernel transition's
    `apply_impl` applied to the pre-state's `base`.  Holds for every
    non-topUpActionBudget action: the witness's precondition makes
    `step_impl` collapse to `apply_impl`.

    GP.2.3 note: for `topUpActionBudget`, the kernel step uses
    `Laws.topUpActionBudget signer ...` (signer-aware) rather than
    `Action.compile`'s signer-unaware result.  The precondition
    gate's `if` may collapse to either branch depending on the
    signer's gas balance; in production the admission gate
    (`apply_admissible_with_budget`) rejects insufficient-gas
    cases, so the no-op branch is unreachable when the gate is in
    use.  Use `apply_admissible_base_topUpActionBudget` below for
    the topUpActionBudget-specific form. -/
theorem apply_admissible_base
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (hne : ∀ gr ga bi pa, st.action ≠ .topUpActionBudget gr ga bi pa) :
    (apply_admissible P es st h).base =
    (Action.compile st.action).transition.apply_impl es.base := by
  have hPre : (Action.compile st.action).transition.pre es.base := by
    obtain ⟨_, _, _, hPre, _⟩ := h
    exact hPre
  -- Unfold apply_admissible to the underlying step_impl expression.
  show step_impl es.base
        (match st.action with
         | .topUpActionBudget gr ga bi pa =>
             Laws.topUpActionBudget st.signer gr ga bi pa
         | _ => (Action.compile st.action).transition) =
       (Action.compile st.action).transition.apply_impl es.base
  -- For non-topUpActionBudget, the match selects the `_` arm,
  -- giving `step_impl es.base (Action.compile st.action).transition`.
  -- Under hPre, this equals `(Action.compile st.action).transition.apply_impl es.base`.
  cases hact : st.action with
  | topUpActionBudget gr ga bi pa => exact absurd hact (hne gr ga bi pa)
  | transfer _ _ _ _              => simp_all [step_impl]
  | mint _ _ _                    => simp_all [step_impl]
  | burn _ _ _                    => simp_all [step_impl]
  | freezeResource _              => simp_all [step_impl]
  | replaceKey _ _                => simp_all [step_impl]
  | reward _ _ _                  => simp_all [step_impl]
  | distributeOthers _ _ _        => simp_all [step_impl]
  | proportionalDilute _ _ _      => simp_all [step_impl]
  | dispute _                     => simp_all [step_impl]
  | disputeWithdraw _             => simp_all [step_impl]
  | verdict _                     => simp_all [step_impl]
  | rollback _                    => simp_all [step_impl]
  | registerIdentity _ _          => simp_all [step_impl]
  | deposit _ _ _ _               => simp_all [step_impl]
  | withdraw _ _ _ _              => simp_all [step_impl]
  | declareLocalPolicy _          => simp_all [step_impl]
  | revokeLocalPolicy             => simp_all [step_impl]
  | faultProofChallenge _ _ _ _   => simp_all [step_impl]
  | faultProofResolution _ _ _ _  => simp_all [step_impl]
  | depositWithFee _ _ _ _ _ _ _  => simp_all [step_impl]

/-- The post-application `base` state for `topUpActionBudget`
    actions specifically.  The kernel step is signer-aware
    (uses `Laws.topUpActionBudget signer gasResource gasAmount
    budgetIncrement poolActor` rather than the signer-unaware
    `Action.compile (.topUpActionBudget …)` shape, which is the
    kernel-level no-op `Laws.freezeResource 0`).

    Wraps `step_impl` so the kernel-level effect is a no-op when
    the signer's gas balance is insufficient (insufficient-gas
    safety, GP.2.3). -/
theorem apply_admissible_base_topUpActionBudget
    (P : AuthorityPolicy) (es : ExtendedState)
    (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.topUpActionBudget gr ga bi pa, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.topUpActionBudget gr ga bi pa, signer, nonce, sig⟩ h).base =
    step_impl es.base (Laws.topUpActionBudget signer gr ga bi pa) := rfl

/-- The post-application registry equals
    `applyActionToRegistry es.registry st.action`.  Spells out the
    only registry-mutation path: deployments not running
    `replaceKey` see no registry change. -/
theorem apply_admissible_registry
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    (apply_admissible P es st h).registry =
    applyActionToRegistry es.registry st.action := rfl

/-- A different signer's expected nonce is unchanged by
    `apply_admissible`.  This is the cross-actor isolation property
    at the `apply_admissible` level: one actor's signed action
    cannot starve another actor's nonce slot.  Direct consequence of
    `expectsNonce_advance_other` (Nonce.lean) plus the fact that
    `apply_admissible` only advances the *signer*'s nonce. -/
theorem expectsNonce_after_apply_admissible_other
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (a' : ActorId) (hne : st.signer ≠ a') :
    expectsNonce (apply_admissible P es st h) a' = expectsNonce es a' := by
  unfold apply_admissible apply_admissible_with
  -- LP.5: the registry- and localPolicies-update steps don't touch
  -- nonces; advanceNonce at the signer doesn't touch a' ≠ signer.
  show ((advanceNonce { es with base := _ } st.signer).nonces.next[a']?.getD 0)
    = es.nonces.next[a']?.getD 0
  rw [show
    (advanceNonce { es with base := _ } st.signer
      : ExtendedState).nonces.next[a']?.getD 0
    = expectsNonce { es with base := _ } a'
    from expectsNonce_advance_other _ st.signer a' hne]
  rfl

/-- The signer's expected nonce after `apply_admissible` is exactly
    one greater than before.  Holds regardless of the action variant:
    `advanceNonce` is called on the (post-base-modified) state, and
    the nonce field is untouched by the `base`, `registry`, and
    `localPolicies` updates. -/
theorem expectsNonce_after_apply_admissible
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    expectsNonce (apply_admissible P es st h) st.signer =
    expectsNonce es st.signer + 1 := by
  unfold apply_admissible apply_admissible_with
  -- LP.5: the registry- and localPolicies-update steps don't touch
  -- `nonces`, and changing `base` doesn't touch `nonces` either.  So
  -- `expectsNonce` after `apply_admissible` reduces (via structure-eta
  -- projection) to `expectsNonce` after `advanceNonce` on the base-
  -- modified ES.  Abstracted via `_` so the post-base value can be
  -- any expression (covering both the legacy `apply_impl` path and
  -- the GP.2.3 `step_impl` path).
  show ((advanceNonce { es with base := _ } st.signer).nonces.next[st.signer]?.getD 0)
    = expectsNonce es st.signer + 1
  -- expectsNonce_strict_mono lifted via the structure-eta argument.
  rw [show
    (advanceNonce
        ({ base := _, nonces := es.nonces, registry := es.registry,
            bridge := es.bridge, localPolicies := es.localPolicies,
            epochBudgets := es.epochBudgets, budgetPolicy := es.budgetPolicy }
          : ExtendedState) st.signer).nonces.next[st.signer]?.getD 0
    = expectsNonce
        ({ base := _, nonces := es.nonces, registry := es.registry,
            bridge := es.bridge, localPolicies := es.localPolicies,
            epochBudgets := es.epochBudgets, budgetPolicy := es.budgetPolicy }
          : ExtendedState) st.signer + 1
    from expectsNonce_strict_mono _ st.signer]
  -- expectsNonce on a state with only `base` modified equals expectsNonce on the
  -- original state (nonces field unchanged).
  rfl

/-- An admissible action's nonce equals the pre-application
    `expectsNonce`.  Alias for `admissible_nonce`; kept for the
    older arity-explicit form used by the headline replay-protection
    proofs below. -/
theorem admissible_nonce_eq
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    st.nonce = expectsNonce es st.signer :=
  admissible_nonce h

/-! ## GP.3.2 admission-gate theorems (Workstream GP §15E v1.0)

The headline theorems characterising `apply_admissible_with_budget`'s
behaviour under bounded budget policy.  Each theorem captures one
slice of the gate's behaviour:

  * `admission_consumes_budget_on_success` — every non-bridge
    "ordinary" admitted action reduces the signer's `currentBudget`
    by `actionCost`.
  * `admission_rejected_when_budget_zero` — a non-bridge actor with
    `currentBudget < actionCost` is rejected at the budget gate.
  * `bridgeActor_budget_exempt` — every admitted bridgeActor-signed
    action leaves `bridgeActor`'s own budget slot unchanged.
  * `depositWithFee_grants_budget` — a successful `depositWithFee`
    admission credits the recipient's budget by `budgetGrant`.
  * `depositWithFee_budget_locality` — a successful `depositWithFee`
    admission does not change any actor's budget except the
    recipient's (and, for non-bridge-signed actions, the signer's
    via the consume step — but `depositWithFee` is only legitimately
    signed by `bridgeActor`, who is exempt; this corner is captured
    by `depositWithFee_signer_budget_unchanged_under_bridgeActor`).
  * `topUpActionBudget_net_budget_change` — a successful
    `topUpActionBudget` admission produces a net budget change of
    `budgetIncrement - actionCost` on the signer's slot
    (consume-then-topup).
  * `admission_locality_in_budget` — a non-deposit non-topup
    admission only mutates the signer's budget slot.
  * `replenishment_via_epoch_advance` — an actor with stale
    `lastSeenEpoch < currentEpoch` sees `currentBudget ≥ freeTier`,
    so a fresh epoch auto-replenishes (the budget normalisation
    floor).
  * `nonce_uniqueness_preserved` / `replay_impossible_preserved` —
    the existing `nonce_uniqueness` and `replay_impossible`
    theorems lift transparently across the budget gate (the budget
    gate is downstream of the nonce check).

All theorems are formulated against the kernel-only
`apply_admissible_with_budget`; parallel lemmas for the bridge-
aware `apply_bridge_admissible_with_budget` (Bridge/Admissible.lean)
follow the same shape and can be derived by a similar case-split.
-/

/-- Helper: a non-bridge actor's admission via `apply_admissible_with_budget`
    requires the consume step to succeed.  Symbolically: if the
    gate returns `some es'` and `signer ≠ bridgeActor`, then
    `EpochBudgetState.consume es.epochBudgets signer currentEpoch
    freeTier actionCost = some _`. -/
private theorem consume_some_of_admit_non_bridge
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {st : SignedAction} {h : AdmissibleWith verify P d es st}
    {freeTier actionCost currentEpoch : Nat}
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hne_topup : ∀ gr ga bi pa, st.action ≠ .topUpActionBudget gr ga bi pa)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es st h = some es') :
    ∃ ebs',
      EpochBudgetState.consume es.epochBudgets st.signer
        currentEpoch freeTier actionCost = some ebs' := by
  -- Establish: the gas check passes (vacuously) for non-topUp actions.
  have hgas : topUpActionBudget_gasCheck st.action st.signer es = true :=
    topUpActionBudget_gasCheck_true_of_ne_topUp st.action st.signer es hne_topup
  unfold apply_admissible_with_budget at hsuc
  rw [hpolicy] at hsuc
  simp [hgas, hne_bridge] at hsuc
  cases hopt : EpochBudgetState.consume es.epochBudgets st.signer
                  currentEpoch freeTier actionCost with
  | none =>
      rw [hopt] at hsuc
      simp at hsuc
  | some ebs' => exact ⟨ebs', rfl⟩

/-- §15E (v1.0) / GP.3.2.e — `admission_consumes_budget_on_success`.

    Every non-bridge, non-`depositWithFee`, non-`topUpActionBudget`
    action admitted under bounded budget policy reduces the
    signer's `currentBudget` by `actionCost`.

    The exclusion of `depositWithFee` and `topUpActionBudget`
    captures the budget-grant arm of GP.3.2.d: those actions
    additionally credit a recipient/signer budget slot, so the
    net change is not just `-actionCost`.  See
    `topUpActionBudget_net_budget_change` and
    `depositWithFee_grants_budget` for those cases. -/
theorem admission_consumes_budget_on_success
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {st : SignedAction} {h : AdmissibleWith verify P d es st}
    {freeTier actionCost currentEpoch : Nat}
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hne_dep : ∀ r recipient poolActor ua pa bg dep,
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg dep)
    (hne_topup : ∀ gr ga bi pa,
      st.action ≠ .topUpActionBudget gr ga bi pa)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es st h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets st.signer currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets st.signer currentEpoch freeTier - actionCost := by
  have ⟨ebs', hconsume⟩ :=
    consume_some_of_admit_non_bridge hpolicy hne_bridge hne_topup hsuc
  -- For non-deposit non-topup actions, the inline `applyGrant` helper
  -- in `apply_admissible_with_budget` falls through to `_ => ebs`,
  -- so es'.epochBudgets = ebs'.
  have hgas : topUpActionBudget_gasCheck st.action st.signer es = true :=
    topUpActionBudget_gasCheck_true_of_ne_topUp st.action st.signer es hne_topup
  have hgrant : es'.epochBudgets = ebs' := by
    unfold apply_admissible_with_budget at hsuc
    rw [hpolicy] at hsuc
    simp [hgas, hne_bridge, hconsume] at hsuc
    -- hsuc : { applied... epochBudgets := <match on st.action> } = es'
    cases hact : st.action with
    | depositWithFee r recipient poolActor ua pa bg dep =>
        exact absurd hact (hne_dep r recipient poolActor ua pa bg dep)
    | topUpActionBudget gr ga bi pa => exact absurd hact (hne_topup gr ga bi pa)
    | transfer _ _ _ _              => rw [← hsuc]
    | mint _ _ _                    => rw [← hsuc]
    | burn _ _ _                    => rw [← hsuc]
    | freezeResource _              => rw [← hsuc]
    | replaceKey _ _                => rw [← hsuc]
    | reward _ _ _                  => rw [← hsuc]
    | distributeOthers _ _ _        => rw [← hsuc]
    | proportionalDilute _ _ _      => rw [← hsuc]
    | dispute _                     => rw [← hsuc]
    | disputeWithdraw _             => rw [← hsuc]
    | verdict _                     => rw [← hsuc]
    | rollback _                    => rw [← hsuc]
    | registerIdentity _ _          => rw [← hsuc]
    | deposit _ _ _ _               => rw [← hsuc]
    | withdraw _ _ _ _              => rw [← hsuc]
    | declareLocalPolicy _          => rw [← hsuc]
    | revokeLocalPolicy             => rw [← hsuc]
    | faultProofChallenge _ _ _ _   => rw [← hsuc]
    | faultProofResolution _ _ _ _  => rw [← hsuc]
  rw [hgrant]
  exact EpochBudgetState.currentBudget_after_consume_self
    es.epochBudgets st.signer currentEpoch freeTier actionCost ebs' hconsume

/-- §15E (v1.0) / GP.3.2.f — `admission_rejected_when_budget_zero`.

    A non-bridge actor whose `currentBudget` is strictly less than
    `actionCost` cannot get any action admitted (the budget gate
    rejects).  Captures the type-level rejection guarantee: the
    gate returns `none` exactly when the consume step fails.

    Note: bridgeActor is exempt (covered by `bridgeActor_budget_exempt`). -/
theorem admission_rejected_when_budget_zero
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hbudget : EpochBudgetState.currentBudget es.epochBudgets st.signer currentEpoch freeTier
                  < actionCost) :
    apply_admissible_with_budget verify P d es st h = none := by
  unfold apply_admissible_with_budget
  rw [hpolicy]
  -- The new safety-gate adds an outer `if ! topUpActionBudget_gasCheck …`.
  -- Strategy: case-split on the Bool returned by the gas check.
  -- Both branches produce `none`:
  --   * `false` → outer `if !false then none` → none.
  --   * `true`  → falls to bridgeActor + consume; consume fails by hbudget.
  cases hgcp : topUpActionBudget_gasCheck st.action st.signer es with
  | false =>
      simp
  | true =>
      simp [hne_bridge]
      have hnone := (EpochBudgetState.consume_eq_none_iff
        es.epochBudgets st.signer currentEpoch freeTier actionCost).mpr hbudget
      rw [hnone]

/-- §15E (v1.0) / GP.3.2.g — `bridgeActor_budget_exempt`.

    Every admitted bridgeActor-signed action leaves bridgeActor's own
    budget slot unchanged.  Defence-in-depth against the corner case
    where bridgeActor's budget is accidentally populated (e.g., a
    misconfigured deployment): the exemption ensures bridge events
    don't consume the bridgeActor's slot.

    Excludes `depositWithFee` to bridgeActor as recipient and
    `topUpActionBudget` (neither sensible for a bridgeActor-signed
    action in production). -/
theorem bridgeActor_budget_exempt
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hbridge : st.signer = Bridge.bridgeActor)
    (hne_topup : ∀ gr ga bi pa,
      st.action ≠ .topUpActionBudget gr ga bi pa)
    (hne_dep_to_bridge : ∀ r recipient poolActor ua pa bg dep,
      st.action = .depositWithFee r recipient poolActor ua pa bg dep →
      recipient ≠ Bridge.bridgeActor)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es st h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets Bridge.bridgeActor currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets Bridge.bridgeActor currentEpoch freeTier := by
  -- The bridgeActor branch of apply_admissible_with_budget produces
  -- es'.epochBudgets = applyBudgetGrant es.epochBudgets.  For any
  -- non-topup action, applyBudgetGrant either preserves es.epochBudgets
  -- (no-grant actions) or credits the depositWithFee recipient
  -- (≠ bridgeActor by hypothesis).  Either way, bridgeActor's slot
  -- is unchanged.  We state the goal with `Bridge.bridgeActor` instead
  -- of `st.signer` (using `hbridge`) so the structure matches after
  -- `simp [hbridge]`.
  -- Gas check passes vacuously for non-topUp.  Computed with
  -- `Bridge.bridgeActor` as the signer so the form matches the
  -- simp-rewritten goal (where `st.signer` is substituted via
  -- `hbridge`).
  have hgas : topUpActionBudget_gasCheck st.action Bridge.bridgeActor es = true :=
    topUpActionBudget_gasCheck_true_of_ne_topUp st.action Bridge.bridgeActor es hne_topup
  have h_eb : es'.epochBudgets = match st.action with
    | .depositWithFee _ recipient _ _ _ budgetGrant _ =>
        es.epochBudgets.topUp recipient currentEpoch freeTier budgetGrant
    | .topUpActionBudget _ _ budgetIncrement _ =>
        es.epochBudgets.topUp Bridge.bridgeActor currentEpoch freeTier budgetIncrement
    | _ => es.epochBudgets := by
    unfold apply_admissible_with_budget at hsuc
    rw [hpolicy] at hsuc
    simp [hgas, hbridge] at hsuc
    rw [← hsuc]
  rw [h_eb]
  -- Now case-split on st.action; in every branch except depositWithFee,
  -- the match resolves to `es.epochBudgets` and we're done.  In
  -- depositWithFee, the topUp targets recipient ≠ bridgeActor.
  cases hact : st.action with
  | topUpActionBudget gr ga bi pa => exact absurd hact (hne_topup gr ga bi pa)
  | depositWithFee r recipient poolActor ua pa bg dep =>
      have hne_recip : recipient ≠ Bridge.bridgeActor :=
        hne_dep_to_bridge r recipient poolActor ua pa bg dep hact
      exact EpochBudgetState.currentBudget_after_topUp_other
        es.epochBudgets recipient Bridge.bridgeActor currentEpoch freeTier bg
        hne_recip
  | transfer _ _ _ _              => rfl
  | mint _ _ _                    => rfl
  | burn _ _ _                    => rfl
  | freezeResource _              => rfl
  | replaceKey _ _                => rfl
  | reward _ _ _                  => rfl
  | distributeOthers _ _ _        => rfl
  | proportionalDilute _ _ _      => rfl
  | dispute _                     => rfl
  | disputeWithdraw _             => rfl
  | verdict _                     => rfl
  | rollback _                    => rfl
  | registerIdentity _ _          => rfl
  | deposit _ _ _ _               => rfl
  | withdraw _ _ _ _              => rfl
  | declareLocalPolicy _          => rfl
  | revokeLocalPolicy             => rfl
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl

/-- §15E (v1.0) / GP.3.2.g — `depositWithFee_grants_budget`.

    A successfully admitted `depositWithFee` action with
    `budgetGrant = g` credits the *recipient*'s budget slot by
    exactly `g`.  Holds for both bridgeActor-signed (the production
    path) and non-bridgeActor-signed (corner cases / tests) inputs,
    since the budget-grant arm runs in both branches.  Excludes the
    case where the signer is the recipient (non-bridge path: the
    consume on signer interferes with the topUp on recipient when
    they're the same actor). -/
theorem depositWithFee_grants_budget
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : AdmissibleWith verify P d es
            ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                              budgetGrant depositId, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hbridge_or_ne_recipient :
      signer = Bridge.bridgeActor ∨ signer ≠ recipient)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es
              ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                                budgetGrant depositId, signer, nonce, sig⟩ h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets recipient currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets recipient currentEpoch freeTier + budgetGrant := by
  unfold apply_admissible_with_budget at hsuc
  rw [hpolicy] at hsuc
  -- The action is `.depositWithFee`, so the gas check arm is `_ => true`.
  -- simp evaluates `topUpActionBudget_gasCheck .depositWithFee … = true`
  -- after unfolding.
  unfold topUpActionBudget_gasCheck at hsuc
  by_cases hb : signer = Bridge.bridgeActor
  · simp [hb] at hsuc
    have heq : es'.epochBudgets =
        es.epochBudgets.topUp recipient currentEpoch freeTier budgetGrant := by
      rw [← hsuc]
    rw [heq]
    exact EpochBudgetState.currentBudget_after_topUp_self
      es.epochBudgets recipient currentEpoch freeTier budgetGrant
  · simp [hb] at hsuc
    cases hopt : EpochBudgetState.consume es.epochBudgets signer
                    currentEpoch freeTier actionCost with
    | none => rw [hopt] at hsuc; simp at hsuc
    | some ebs' =>
        rw [hopt] at hsuc
        simp at hsuc
        have heq : es'.epochBudgets =
            ebs'.topUp recipient currentEpoch freeTier budgetGrant := by
          rw [← hsuc]
        rw [heq]
        have hne_recip : signer ≠ recipient := by
          rcases hbridge_or_ne_recipient with hb' | hne
          · exact absurd hb' hb
          · exact hne
        rw [EpochBudgetState.currentBudget_after_topUp_self
              ebs' recipient currentEpoch freeTier budgetGrant]
        rw [EpochBudgetState.currentBudget_after_consume_other
              es.epochBudgets signer recipient currentEpoch freeTier
              actionCost ebs' hopt hne_recip]

/-- §15E (v1.0) / GP.3.2.g — `depositWithFee_budget_locality`.

    A successfully admitted `depositWithFee` action does not change
    the budget of any actor other than the recipient and (for
    non-bridge-signed paths only, where it is consumed) the signer.

    The hypothesis `hne_other` excludes the recipient.  The
    additional hypothesis `hne_signer_or_bridge` either excludes
    the signer (when the path was non-bridge) or asserts the signer
    was bridgeActor (whose budget is exempt anyway). -/
theorem depositWithFee_budget_locality
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : AdmissibleWith verify P d es
            ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                              budgetGrant depositId, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (other : ActorId) (hne_other : other ≠ recipient)
    (hne_signer_or_bridge : signer = Bridge.bridgeActor ∨ signer ≠ other)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es
              ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                                budgetGrant depositId, signer, nonce, sig⟩ h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets other currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets other currentEpoch freeTier := by
  unfold apply_admissible_with_budget at hsuc
  rw [hpolicy] at hsuc
  -- Unfold the gas check; for .depositWithFee, it evaluates to `true`.
  unfold topUpActionBudget_gasCheck at hsuc
  by_cases hb : signer = Bridge.bridgeActor
  · simp [hb] at hsuc
    have heq : es'.epochBudgets =
        es.epochBudgets.topUp recipient currentEpoch freeTier budgetGrant := by
      rw [← hsuc]
    rw [heq]
    exact EpochBudgetState.currentBudget_after_topUp_other
      es.epochBudgets recipient other currentEpoch freeTier budgetGrant (Ne.symm hne_other)
  · simp [hb] at hsuc
    cases hopt : EpochBudgetState.consume es.epochBudgets signer
                    currentEpoch freeTier actionCost with
    | none => rw [hopt] at hsuc; simp at hsuc
    | some ebs' =>
        rw [hopt] at hsuc
        simp at hsuc
        have heq : es'.epochBudgets =
            ebs'.topUp recipient currentEpoch freeTier budgetGrant := by
          rw [← hsuc]
        rw [heq]
        have hne_signer_other : signer ≠ other := by
          rcases hne_signer_or_bridge with hb' | hne
          · exact absurd hb' hb
          · exact hne
        rw [EpochBudgetState.currentBudget_after_topUp_other
              ebs' recipient other currentEpoch freeTier budgetGrant (Ne.symm hne_other)]
        rw [EpochBudgetState.currentBudget_after_consume_other
              es.epochBudgets signer other currentEpoch freeTier actionCost
              ebs' hopt hne_signer_other]

/-- §15E (v1.0) / GP.3.2.h — `topUpActionBudget_net_budget_change`.

    A successfully admitted `topUpActionBudget` action by a
    non-bridgeActor signer produces a net budget change on the
    signer's slot of `budgetIncrement - actionCost` (consume costs
    `actionCost`, the topUp adds `budgetIncrement`).

    Specifically, `currentBudget es' signer = currentBudget es signer
    - actionCost + budgetIncrement`.  Using `Nat` subtraction, the
    intermediate `(currentBudget - actionCost)` step is bounded
    below at 0 only when consume succeeded (which requires
    `currentBudget ≥ actionCost`); the combined expression is
    therefore `currentBudget + budgetIncrement - actionCost`
    (with `Nat` subtraction's saturation behaviour). -/
theorem topUpActionBudget_net_budget_change
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : AdmissibleWith verify P d es
            ⟨.topUpActionBudget gasResource gasAmount budgetIncrement poolActor,
              signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : signer ≠ Bridge.bridgeActor)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es
              ⟨.topUpActionBudget gasResource gasAmount budgetIncrement poolActor,
                signer, nonce, sig⟩ h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets signer currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets signer currentEpoch freeTier
      - actionCost + budgetIncrement := by
  unfold apply_admissible_with_budget at hsuc
  rw [hpolicy] at hsuc
  -- The action is `.topUpActionBudget`, so the gas check arm is
  -- `decide (ga > 0 ∧ getBalance es.base gr signer ≥ ga)`.  Unfold
  -- to expose the decide.  The success hypothesis `hsuc = some es'`
  -- implies the decide reduces to `true` (both conjuncts hold).
  unfold topUpActionBudget_gasCheck at hsuc
  by_cases hgas : gasAmount > 0 ∧ getBalance es.base gasResource signer ≥ gasAmount
  · -- gas check passes: gasCheckPasses simplifies to `true`.
    have hgas_eq : decide
        (gasAmount > 0 ∧ getBalance es.base gasResource signer ≥ gasAmount) = true := by
      simp [hgas]
    simp [hgas_eq, hne_bridge] at hsuc
    cases hopt : EpochBudgetState.consume es.epochBudgets signer
                    currentEpoch freeTier actionCost with
    | none => rw [hopt] at hsuc; simp at hsuc
    | some ebs' =>
        rw [hopt] at hsuc
        simp at hsuc
        have heq : es'.epochBudgets =
            ebs'.topUp signer currentEpoch freeTier budgetIncrement := by
          rw [← hsuc]
        rw [heq]
        rw [EpochBudgetState.currentBudget_after_topUp_self
              ebs' signer currentEpoch freeTier budgetIncrement]
        rw [EpochBudgetState.currentBudget_after_consume_self
              es.epochBudgets signer currentEpoch freeTier actionCost ebs' hopt]
  · -- gas check fails: hsuc would be `none = some es'`, contradiction.
    have hgas_eq : decide
        (gasAmount > 0 ∧ getBalance es.base gasResource signer ≥ gasAmount) = false := by
      simp [hgas]
    simp [hgas_eq] at hsuc

/-- §15E (v1.0) / GP.3.2.i — `admission_locality_in_budget`.

    A non-`depositWithFee`, non-`topUpActionBudget`, non-bridge
    admission only mutates the signer's budget slot.  Specifically,
    every other actor's `currentBudget` is unchanged. -/
theorem admission_locality_in_budget
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hne_dep : ∀ r recipient poolActor ua pa bg dep,
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg dep)
    (hne_topup : ∀ gr ga bi pa,
      st.action ≠ .topUpActionBudget gr ga bi pa)
    (other : ActorId) (hne : st.signer ≠ other)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es st h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets other currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets other currentEpoch freeTier := by
  have ⟨ebs', hconsume⟩ :=
    consume_some_of_admit_non_bridge hpolicy hne_bridge hne_topup hsuc
  have hgas : topUpActionBudget_gasCheck st.action st.signer es = true :=
    topUpActionBudget_gasCheck_true_of_ne_topUp st.action st.signer es hne_topup
  -- For non-deposit non-topup, es'.epochBudgets = ebs' (identity grant).
  have hgrant : es'.epochBudgets = ebs' := by
    unfold apply_admissible_with_budget at hsuc
    rw [hpolicy] at hsuc
    simp [hgas, hne_bridge, hconsume] at hsuc
    cases hact : st.action with
    | depositWithFee r recipient poolActor ua pa bg dep =>
        exact absurd hact (hne_dep r recipient poolActor ua pa bg dep)
    | topUpActionBudget gr ga bi pa =>
        exact absurd hact (hne_topup gr ga bi pa)
    | transfer _ _ _ _              => rw [← hsuc]
    | mint _ _ _                    => rw [← hsuc]
    | burn _ _ _                    => rw [← hsuc]
    | freezeResource _              => rw [← hsuc]
    | replaceKey _ _                => rw [← hsuc]
    | reward _ _ _                  => rw [← hsuc]
    | distributeOthers _ _ _        => rw [← hsuc]
    | proportionalDilute _ _ _      => rw [← hsuc]
    | dispute _                     => rw [← hsuc]
    | disputeWithdraw _             => rw [← hsuc]
    | verdict _                     => rw [← hsuc]
    | rollback _                    => rw [← hsuc]
    | registerIdentity _ _          => rw [← hsuc]
    | deposit _ _ _ _               => rw [← hsuc]
    | withdraw _ _ _ _              => rw [← hsuc]
    | declareLocalPolicy _          => rw [← hsuc]
    | revokeLocalPolicy             => rw [← hsuc]
    | faultProofChallenge _ _ _ _   => rw [← hsuc]
    | faultProofResolution _ _ _ _  => rw [← hsuc]
  rw [hgrant]
  exact EpochBudgetState.currentBudget_after_consume_other
    es.epochBudgets st.signer other currentEpoch freeTier actionCost
    ebs' hconsume hne

/-- §15E (v1.0) / GP.3.2.i — `replenishment_via_epoch_advance`.

    An actor whose `lastSeenEpoch < currentEpoch` sees their
    `currentBudget` floored at `freeTier`.  Captures the epoch-
    boundary auto-replenishment property: an actor whose budget
    was exhausted in a prior epoch automatically regains at least
    `freeTier` units in the new epoch.

    Doesn't reference the admission gate at all — it's a property of
    `currentBudget`'s normalisation step.  Stated here as the
    "headline mechanism" for admission-success after exhaustion.

    Concretely: if `freeTier ≥ actionCost`, the same actor can
    issue an action at any newer epoch even after exhausting their
    budget in a prior epoch. -/
theorem replenishment_via_epoch_advance
    (ebs : EpochBudgetState) (a : ActorId) (now ft : Nat)
    (h : (ebs[a]?.getD ActorBudget.empty).lastSeenEpoch < now) :
    ebs.currentBudget a now ft ≥ ft :=
  EpochBudgetState.currentBudget_floored_at_freeTier ebs a now ft h

/-- §15E (v1.0) / GP.3.2.j — `nonce_uniqueness_preserved`.

    The existing `nonce_uniqueness` theorem lifts transparently
    across the budget gate: the budget gate is downstream of the
    nonce check (admissibility's condition 4), so two distinct
    admissible actions by the same signer still cannot share a
    nonce.  Restated against the parameterised `AdmissibleWith`. -/
theorem nonce_uniqueness_preserved
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st₁ st₂ : SignedAction)
    (h₁ : AdmissibleWith verify P d es st₁)
    (h₂ : AdmissibleWith verify P d es st₂)
    (hsame : st₁.signer = st₂.signer) :
    st₁.nonce = st₂.nonce := by
  have h_n₁ : st₁.nonce = expectsNonce es st₁.signer := admissibleWith_nonce h₁
  have h_n₂ : st₂.nonce = expectsNonce es st₂.signer := admissibleWith_nonce h₂
  rw [hsame] at h_n₁
  exact h_n₁.trans h_n₂.symm

/-- §15E (v1.0) / GP.3.2.j — `replay_impossible_preserved`.

    The existing `replay_impossible` theorem lifts transparently
    across the budget gate: a successful admission advances the
    signer's nonce, so the same SignedAction cannot be admitted
    again at the post-state — regardless of budget state changes.

    The post-state is constructed by `apply_admissible_with_budget`
    (the budget-gated admission entry).  Its kernel-level effect
    on `nonces` is identical to `apply_admissible_with`'s (the
    budget gate doesn't touch the nonce ledger), so the
    `expectsNonce`-based proof carries through. -/
theorem replay_impossible_preserved
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es st h = some es') :
    ¬ AdmissibleWith verify P d es' st := by
  intro h'
  -- The post-budget-gate state's `nonces` field equals
  -- `(apply_admissible_with ...).nonces`, regardless of branch.
  -- That field has the signer's nonce advanced by exactly 1
  -- (via the standard apply_admissible_with body).
  have h_pre_nonce : st.nonce = expectsNonce es st.signer := admissibleWith_nonce h
  have h_post_nonce : st.nonce = expectsNonce es' st.signer := admissibleWith_nonce h'
  have h_nonces_eq : es'.nonces =
      (apply_admissible_with verify P d es st h).nonces := by
    unfold apply_admissible_with_budget at hsuc
    cases hpolicy : es.budgetPolicy with
    | bounded freeTier actionCost currentEpoch =>
        rw [hpolicy] at hsuc
        -- GP.3.2 safety gate: case-split on the named gas check.
        cases hgcp : topUpActionBudget_gasCheck st.action st.signer es with
        | false =>
            -- gas check fails: outer if returns none directly.
            simp [hgcp] at hsuc
        | true =>
            simp [hgcp] at hsuc
            by_cases hb : st.signer = Bridge.bridgeActor
            · simp [hb] at hsuc
              rw [← hsuc]
            · simp [hb] at hsuc
              cases hopt : EpochBudgetState.consume es.epochBudgets st.signer
                              currentEpoch freeTier actionCost with
              | none => rw [hopt] at hsuc; simp at hsuc
              | some ebs' =>
                  rw [hopt] at hsuc
                  simp at hsuc
                  rw [← hsuc]
  have h_advanced : expectsNonce es' st.signer = expectsNonce es st.signer + 1 := by
    show es'.nonces.next[st.signer]?.getD 0 = _
    rw [h_nonces_eq]
    -- Now reducing to `(apply_admissible_with ...).nonces.next[...] = ...`,
    -- which is the parameterised analogue of expectsNonce_after_apply_admissible.
    show (apply_admissible_with verify P d es st h).nonces.next[st.signer]?.getD 0 =
          expectsNonce es st.signer + 1
    unfold apply_admissible_with
    show ((advanceNonce { es with base := _ } st.signer).nonces.next[st.signer]?.getD 0)
          = expectsNonce es st.signer + 1
    rw [show
      (advanceNonce
          ({ base := _, nonces := es.nonces, registry := es.registry,
              bridge := es.bridge, localPolicies := es.localPolicies,
              epochBudgets := es.epochBudgets, budgetPolicy := es.budgetPolicy }
            : ExtendedState) st.signer).nonces.next[st.signer]?.getD 0
      = expectsNonce
          ({ base := _, nonces := es.nonces, registry := es.registry,
              bridge := es.bridge, localPolicies := es.localPolicies,
              epochBudgets := es.epochBudgets, budgetPolicy := es.budgetPolicy }
            : ExtendedState) st.signer + 1
      from expectsNonce_strict_mono _ st.signer]
    rfl
  rw [h_advanced, ← h_pre_nonce] at h_post_nonce
  exact absurd h_post_nonce (Nat.ne_of_lt (Nat.lt_succ_self _))

/-! ## Headline theorems (§8.5.2) -/

/-- §8.5.2 / WU 3.7: two distinct signed actions by the same signer
    cannot both be admissible at the same `ExtendedState`.

    Proof: condition 4 forces both actions' nonces to equal
    `expectsNonce es signer`, hence to equal each other. -/
theorem nonce_uniqueness
    (P : AuthorityPolicy) (es : ExtendedState)
    (st₁ st₂ : SignedAction)
    (h₁ : Admissible P es st₁)
    (h₂ : Admissible P es st₂)
    (hsame : st₁.signer = st₂.signer) :
    st₁.nonce = st₂.nonce := by
  have h_n₁ := admissible_nonce_eq P es st₁ h₁
  have h_n₂ := admissible_nonce_eq P es st₂ h₂
  rw [hsame] at h_n₁
  exact h_n₁.trans h_n₂.symm

/-- §8.5.2 / WU 3.8: a successfully applied signed action cannot be
    admissible again.  The headline replay-protection theorem.

    Proof: after `apply_admissible`, `expectsNonce es' signer` equals
    `expectsNonce es signer + 1`.  For `Admissible P es' st` to hold,
    condition 4 would require `st.nonce = expectsNonce es' signer =
    expectsNonce es signer + 1`.  But by `Admissible P es st` we have
    `st.nonce = expectsNonce es signer`, contradicting Nat
    successor injectivity (`expectsNonce es signer ≠ expectsNonce es
    signer + 1`). -/
theorem replay_impossible
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction)
    (h : Admissible P es st) :
    ¬ Admissible P (apply_admissible P es st h) st := by
  intro h'
  -- After application, expectsNonce (apply_admissible …) signer = st.nonce + 1.
  have h_post := expectsNonce_after_apply_admissible P es st h
  -- For h' to hold, st.nonce = expectsNonce post signer.
  have h_eq : st.nonce = expectsNonce (apply_admissible P es st h) st.signer :=
    admissible_nonce_eq P (apply_admissible P es st h) st h'
  -- And by h, st.nonce = expectsNonce es signer.
  have h_pre : st.nonce = expectsNonce es st.signer :=
    admissible_nonce_eq P es st h
  -- So expectsNonce es signer = expectsNonce post signer = expectsNonce es signer + 1.
  rw [h_post, ← h_pre] at h_eq
  -- h_eq : st.nonce = st.nonce + 1.  Contradiction.
  exact absurd h_eq (Nat.ne_of_lt (Nat.lt_succ_self _))

/-! ## Cross-actor independence

If two admissible actions are by *different* signers, neither's
nonce constraint blocks the other.  This is the type-level statement
that the nonce ledger isolates actors. -/

/-- An admissible action by signer `a` can still be admissible after
    an action by a different signer `a'`, provided the kernel-level
    pre-condition still holds and the registry / authorisation didn't
    change in a relevant way.  Phase 3 states the nonce-component
    isolation; full cross-actor admissibility composition is a
    deployment-level concern. -/
theorem nonce_isolation
    (es : ExtendedState) (a a' : ActorId) (h : a ≠ a') :
    expectsNonce (advanceNonce es a) a' = expectsNonce es a' :=
  expectsNonce_advance_other es a a' h

/-! ## Authority-layer registry update (WU 3.10) -/

/-- After applying a `replaceKey actor newKey` action via
    `apply_admissible`, the registry has `actor → newKey`.  This is
    the type-level statement that key rotation actually rotates the
    key. -/
theorem replaceKey_updates_registry
    (P : AuthorityPolicy) (es : ExtendedState)
    (actor : ActorId) (newKey : PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.replaceKey actor newKey, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.replaceKey actor newKey, signer, nonce, sig⟩ h).registry[actor]?
      = some newKey := by
  unfold apply_admissible apply_admissible_with applyActionToRegistry
  -- After the replacement, the registry has `actor → newKey`; the look-up at
  -- `actor` is `some newKey` via `RBMap.find?_insert_self`.
  show ((advanceNonce { es with base := _ } signer).registry.insert actor newKey)[actor]?
    = some newKey
  exact RBMap.find?_insert_self _ actor newKey

/-- After applying any registry-non-mutating action via
    `apply_admissible`, the registry is unchanged from the pre-
    application state.  A type-level statement that the kernel-
    facing registry-mutation surface consists exactly of `replaceKey`
    and (Workstream B) `registerIdentity`; every other action
    preserves the registry.

    The `hneReplace` hypothesis excludes `replaceKey`; the
    `hneRegister` hypothesis excludes `registerIdentity`.  Both
    must hold simultaneously for the conclusion to follow. -/
theorem non_registry_mutating_preserves_registry
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (hneReplace : ∀ actor newKey, st.action ≠ .replaceKey actor newKey)
    (hneRegister : ∀ actor pk, st.action ≠ .registerIdentity actor pk) :
    (apply_admissible P es st h).registry = es.registry := by
  unfold apply_admissible apply_admissible_with applyActionToRegistry
  -- The action is neither a `replaceKey` nor a `registerIdentity`,
  -- so `applyActionToRegistry` returns the registry unchanged.  Since
  -- `advanceNonce` and the `base` update don't touch the registry,
  -- the result is `es.registry`.
  cases hact : st.action with
  | transfer _ _ _ _              => rfl
  | mint _ _ _                    => rfl
  | burn _ _ _                    => rfl
  | freezeResource _              => rfl
  | replaceKey actor newKey       => exact absurd hact (hneReplace actor newKey)
  | reward _ _ _                  => rfl
  | distributeOthers _ _ _        => rfl
  | proportionalDilute _ _ _      => rfl
  | dispute _                     => rfl
  | disputeWithdraw _             => rfl
  | verdict _                     => rfl
  | rollback _                    => rfl
  | registerIdentity actor pk     => exact absurd hact (hneRegister actor pk)
  | deposit _ _ _ _               => rfl
  | withdraw _ _ _ _              => rfl
  | declareLocalPolicy _          => rfl
  | revokeLocalPolicy             => rfl
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl
  | depositWithFee _ _ _ _ _ _ _  => rfl
  | topUpActionBudget _ _ _ _     => rfl
  -- Workstream-LX (LX.19): codegen-managed Lex
  -- `non_registry_mutating_preserves_registry` proof arms land
  -- between the fence markers below.  Each Lex law that compiles
  -- to a non-replaceKey / non-registerIdentity action emits an
  -- `rfl`-shaped arm.  Empty in M1.
  -- BEGIN LEX-GENERATED (do not edit by hand)
  -- END LEX-GENERATED

/-- Backward-compatibility alias for the pre-Workstream-B name
    `non_replaceKey_preserves_registry`.  Now that `registerIdentity`
    also mutates the registry (Workstream B.3), the lemma's content
    name is `non_registry_mutating_preserves_registry`; the legacy
    name is preserved as an alias so existing test signatures continue
    to elaborate. -/
theorem non_replaceKey_preserves_registry
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (hneReplace : ∀ actor newKey, st.action ≠ .replaceKey actor newKey)
    (hneRegister : ∀ actor pk, st.action ≠ .registerIdentity actor pk) :
    (apply_admissible P es st h).registry = es.registry :=
  non_registry_mutating_preserves_registry P es st h hneReplace hneRegister

/-- After applying a `replaceKey actor₁ newKey` action via
    `apply_admissible`, *other* actors' registry entries are
    unchanged.  Cross-actor independence at the registry level. -/
theorem replaceKey_other_actor_untouched
    (P : AuthorityPolicy) (es : ExtendedState)
    (actor₁ : ActorId) (newKey : PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.replaceKey actor₁ newKey, signer, nonce, sig⟩)
    (actor₂ : ActorId) (hne : actor₁ ≠ actor₂) :
    (apply_admissible P es ⟨.replaceKey actor₁ newKey, signer, nonce, sig⟩ h).registry[actor₂]?
      = es.registry[actor₂]? := by
  unfold apply_admissible apply_admissible_with applyActionToRegistry
  show ((advanceNonce { es with base := _ } signer).registry.insert actor₁ newKey)[actor₂]?
    = es.registry[actor₂]?
  rw [RBMap.find?_insert_other _ actor₁ actor₂ _ hne]
  rfl

/-! ## Authority-layer registry update for `registerIdentity` (Workstream B) -/

/-- Workstream B.3 / §6.3 — after applying a `registerIdentity actor
    pk` action via `apply_admissible`, the registry has
    `actor → pk`.  The type-level statement that identity
    registration actually inserts the new key.  Mirrors
    `replaceKey_updates_registry`. -/
theorem registerIdentity_updates_registry
    (P : AuthorityPolicy) (es : ExtendedState)
    (actor : ActorId) (pk : PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.registerIdentity actor pk, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.registerIdentity actor pk, signer, nonce, sig⟩ h).registry[actor]?
      = some pk := by
  unfold apply_admissible apply_admissible_with applyActionToRegistry
  show ((advanceNonce { es with base := _ } signer).registry.insert actor pk)[actor]?
    = some pk
  exact RBMap.find?_insert_self _ actor pk

/-- After applying a `registerIdentity actor₁ pk` action via
    `apply_admissible`, *other* actors' registry entries are
    unchanged.  Cross-actor independence at the registry level for
    Workstream B's identity-registration flow.  Mirrors
    `replaceKey_other_actor_untouched`. -/
theorem registerIdentity_other_actor_untouched
    (P : AuthorityPolicy) (es : ExtendedState)
    (actor₁ : ActorId) (pk : PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.registerIdentity actor₁ pk, signer, nonce, sig⟩)
    (actor₂ : ActorId) (hne : actor₁ ≠ actor₂) :
    (apply_admissible P es ⟨.registerIdentity actor₁ pk, signer, nonce, sig⟩ h).registry[actor₂]?
      = es.registry[actor₂]? := by
  unfold apply_admissible apply_admissible_with applyActionToRegistry
  show ((advanceNonce { es with base := _ } signer).registry.insert actor₁ pk)[actor₂]?
    = es.registry[actor₂]?
  rw [RBMap.find?_insert_other _ actor₁ actor₂ _ hne]
  rfl

/-! ## LP.7 Headline theorems

Two security-relevant theorems land with LP.7:

  * `localPolicy_meta_action_independent` — the structural
    lockout-prevention proof.  No matter what local policy the
    signer has declared, `declareLocalPolicy` and
    `revokeLocalPolicy` actions remain admissible (subject to the
    other four conjuncts).

  * `admissible_no_policy_iff_pre_LP_with_no_policy` — the strict-
    narrowing equivalence.  An action signed by an actor with no
    declared policy is admissible post-LP iff it was admissible
    pre-LP (the new conjunct collapses to `True`).

Together these guarantee:

  1. Actors cannot lock themselves out (lockout-prevention).
  2. Pre-LP-admissible actions whose signers have no declared
     policy continue to be admissible post-LP (strict-narrowing).
-/

/-- LP.7 / §6.2: the structural lockout-prevention proof.

    For any meta-action (declareLocalPolicy / revokeLocalPolicy)
    and any pair of `LocalPolicies` tables, the local-policy
    admissibility conjunct is identical: meta-actions are exempt
    by *enumeration* over the `Action` inductive, not by any
    policy-derived predicate, so no `LocalPolicyClause` can
    block a policy-management action.

    This is the type-level statement that "an actor cannot
    construct a `LocalPolicy` that locks them out of revoking it"
    is provable as a Lean theorem, not just a convention. -/
theorem localPolicy_meta_action_independent
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (h_meta : isMetaPolicyAction action = true)
    (lp lp' : LocalPolicies) :
    localPolicyPermits { es with localPolicies := lp  } signer action ↔
    localPolicyPermits { es with localPolicies := lp' } signer action :=
  Iff.intro
    (fun _ => Or.inl h_meta)
    (fun _ => Or.inl h_meta)

/-- LP.7 / §6.5 (specialised form): when the signer has no entry
    in `localPolicies` and the action is non-meta, the new
    admissibility conjunct reduces to `True` (because
    `LocalPolicy.empty.permits` is vacuous).  In other words:
    actors with no declared policy see no admissibility narrowing
    from LP.7 — the strict-narrowing property at the new
    conjunct's level. -/
theorem localPolicyPermits_no_policy
    (es : ExtendedState) (signer : ActorId) (action : Action)
    (h_no_policy : es.localPolicies[signer]? = none) :
    localPolicyPermits es signer action := by
  -- localPolicies.lookup signer returns LocalPolicy.empty since the
  -- entry is absent.  LocalPolicy.empty permits every action via
  -- vacuous quantification.
  unfold localPolicyPermits LocalPolicies.lookup
  rw [h_no_policy]
  simp only [Option.getD_none]
  -- Goal: isMeta ∨ LocalPolicy.empty.permits signer action.
  -- The right disjunct holds vacuously.
  exact Or.inr (LocalPolicy.empty_permits_all signer action)

/-! ## Authority-layer local-policy mutation theorems (Workstream LP / LP.5)

The four theorems below pin the new step's semantics: declaring a
policy stores it under the signer's key, revoking erases the key,
non-meta actions don't touch the table, and cross-actor isolation
holds.  Mirror the WU 3.10 `replaceKey_*` family. -/

/-- LP.5: after applying `declareLocalPolicy policy` via
    `apply_admissible`, the signer's `localPolicies` entry equals
    `policy`. -/
theorem declareLocalPolicy_updates_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (policy : LocalPolicy)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.declareLocalPolicy policy, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.declareLocalPolicy policy, signer, nonce, sig⟩
      h).localPolicies.lookup signer = policy := by
  unfold apply_admissible apply_admissible_with applyActionToLocalPolicies
    applyActionToRegistry
  -- After the body chain, localPolicies = `(advanceNonce ...).localPolicies.declare signer policy`.
  -- The `advanceNonce` and `base`-update steps don't touch localPolicies, so it
  -- equals `es.localPolicies.declare signer policy`.  `lookup_declare_self` closes.
  show (es.localPolicies.declare signer policy).lookup signer = policy
  exact LocalPolicies.lookup_declare_self _ _ _

/-- LP.5: after applying `revokeLocalPolicy` via `apply_admissible`,
    the signer's `localPolicies` lookup returns `LocalPolicy.empty`
    (the unrestricted default — i.e. the entry has been erased). -/
theorem revokeLocalPolicy_clears_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : Admissible P es ⟨.revokeLocalPolicy, signer, nonce, sig⟩) :
    (apply_admissible P es ⟨.revokeLocalPolicy, signer, nonce, sig⟩
      h).localPolicies.lookup signer = LocalPolicy.empty := by
  unfold apply_admissible apply_admissible_with applyActionToLocalPolicies
    applyActionToRegistry
  show (es.localPolicies.revoke signer).lookup signer = LocalPolicy.empty
  exact LocalPolicies.lookup_revoke_self _ _

/-- LP.5: after applying any non-meta action via `apply_admissible`,
    the `localPolicies` table is unchanged from the pre-application
    state.  The two LP-introduced action constructors (declared
    here as a hypothesis) are excluded; every other action falls
    through to `_ => lp` in `applyActionToLocalPolicies`. -/
theorem non_meta_preserves_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (hneDeclare : ∀ p, st.action ≠ .declareLocalPolicy p)
    (hneRevoke : st.action ≠ .revokeLocalPolicy) :
    (apply_admissible P es st h).localPolicies = es.localPolicies := by
  unfold apply_admissible apply_admissible_with applyActionToLocalPolicies
  -- Case-split on the action; for every non-LP variant the helper falls through
  -- to `_ => lp`, leaving the localPolicies field unchanged.
  cases hact : st.action with
  | transfer _ _ _ _              => rfl
  | mint _ _ _                    => rfl
  | burn _ _ _                    => rfl
  | freezeResource _              => rfl
  | replaceKey _ _                => rfl
  | reward _ _ _                  => rfl
  | distributeOthers _ _ _        => rfl
  | proportionalDilute _ _ _      => rfl
  | dispute _                     => rfl
  | disputeWithdraw _             => rfl
  | verdict _                     => rfl
  | rollback _                    => rfl
  | registerIdentity _ _          => rfl
  | deposit _ _ _ _               => rfl
  | withdraw _ _ _ _              => rfl
  | declareLocalPolicy p          => exact absurd hact (hneDeclare p)
  | revokeLocalPolicy             => exact absurd hact hneRevoke
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl
  | depositWithFee _ _ _ _ _ _ _  => rfl
  | topUpActionBudget _ _ _ _     => rfl

/-- LP.5: a different actor's `localPolicies` entry is unchanged by
    `apply_admissible` regardless of the action.  The local-policy
    mutation only touches the *signer*'s entry. -/
theorem localPolicies_other_actor_untouched
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st)
    (a : ActorId) (h_ne : st.signer ≠ a) :
    (apply_admissible P es st h).localPolicies.lookup a =
    es.localPolicies.lookup a := by
  unfold apply_admissible apply_admissible_with applyActionToLocalPolicies
  -- For every action variant: `applyActionToLocalPolicies` either falls
  -- through to identity (non-LP actions) or mutates the *signer*'s
  -- entry (LP-meta actions).  In both cases, the lookup at `a ≠ signer`
  -- is unchanged.
  cases hact : st.action with
  | transfer _ _ _ _              => rfl
  | mint _ _ _                    => rfl
  | burn _ _ _                    => rfl
  | freezeResource _              => rfl
  | replaceKey _ _                => rfl
  | reward _ _ _                  => rfl
  | distributeOthers _ _ _        => rfl
  | proportionalDilute _ _ _      => rfl
  | dispute _                     => rfl
  | disputeWithdraw _             => rfl
  | verdict _                     => rfl
  | rollback _                    => rfl
  | registerIdentity _ _          => rfl
  | deposit _ _ _ _               => rfl
  | withdraw _ _ _ _              => rfl
  | declareLocalPolicy policy     =>
    -- After `declare st.signer policy`, lookup at `a ≠ signer` is unchanged.
    show (es.localPolicies.declare st.signer policy).lookup a = es.localPolicies.lookup a
    exact LocalPolicies.lookup_declare_other _ st.signer a policy h_ne
  | revokeLocalPolicy             =>
    -- After `revoke st.signer`, lookup at `a ≠ signer` is unchanged.
    show (es.localPolicies.revoke st.signer).lookup a = es.localPolicies.lookup a
    exact LocalPolicies.lookup_revoke_other _ st.signer a h_ne
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl
  | depositWithFee _ _ _ _ _ _ _  => rfl
  | topUpActionBudget _ _ _ _     => rfl

/-- LP.5: field-projection: the post-application `localPolicies`
    equals the result of `applyActionToLocalPolicies` applied to
    the pre-application table.  Direct unfolding; useful for
    downstream callers reasoning over the tail. -/
theorem apply_admissible_localPolicies
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    (apply_admissible P es st h).localPolicies =
    applyActionToLocalPolicies es.localPolicies st.signer st.action := rfl

/-! ## Workstream LX (LX.2 / LX.3) — `RegistryPreserving` typeclass
    + per-Action instances

The `RegistryPreserving` class classifies an `Action` constructor
as preserving `KeyRegistry` pointwise: applying the action's
authority-layer effect (`applyActionToRegistry`) returns the
registry unchanged.

Indexed by `Action`, not `Transition`.  `applyActionToRegistry`
dispatches on `Action`; multiple `Action` constructors compile to
definitionally-equal `Transition` values (e.g. `replaceKey`,
`dispute`, `disputeWithdraw`, `verdict`, `rollback`,
`registerIdentity`, `declareLocalPolicy`, `revokeLocalPolicy` all
compile to `Laws.freezeResource 0`); among those, `replaceKey` and
`registerIdentity` mutate the registry while the others do not.
A typeclass on `Transition` could not distinguish them; the
`Action`-indexed form can.

Lives in this module (rather than `Conservation.lean`) because
`Action` and `applyActionToRegistry` both live downstream of
`Conservation.lean`; importing them upstream would create a
circular dependency.  Logically the typeclass sits alongside
`LocalTo` / `FreezePreserving` (defined in `Conservation.lean`);
together they form the Lex synthesizer library's classification
surface. -/

/-- `RegistryPreserving a` — applying `a`'s authority-layer effect
    leaves the `KeyRegistry` unchanged pointwise.  Trivial for
    every `Action` constructor that does NOT mutate the registry —
    i.e. all but `replaceKey` and `registerIdentity`.

    `replaceKey` and `registerIdentity` are deliberately *not*
    instances (they would be false): `applyActionToRegistry kr
    (.replaceKey actor newKey) = kr.insert actor newKey`, which is
    not pointwise-equal to `kr` in general.  Lean's `inferInstance`
    fails for these by construction, serving as the negative
    witness. -/
class RegistryPreserving (a : Action) : Prop where
  /-- The registry-preservation obligation: for every key registry
      `kr`, applying `a`'s authority-layer effect to `kr` returns
      `kr` unchanged. -/
  preserves : ∀ (kr : KeyRegistry), applyActionToRegistry kr a = kr

/-! ### Per-action instances (LX.3)

Fifteen instances cover every kernel-built-in `Action`
constructor that does NOT mutate the registry.  Each reduces to
`rfl` via the catch-all `_ => kr` branch of
`applyActionToRegistry`.  The two deliberate absences
(`replaceKey`, `registerIdentity`) make Lean's `inferInstance`
fail for those constructors; downstream callers needing
"this action preserves the registry" automatically discover the
exclusion. -/

/-- `transfer` preserves the registry. -/
instance transfer_registryPreserving
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    RegistryPreserving (.transfer r sender receiver amount) where
  preserves := fun _ => rfl

/-- `mint` preserves the registry. -/
instance mint_registryPreserving
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    RegistryPreserving (.mint r to amount) where
  preserves := fun _ => rfl

/-- `burn` preserves the registry. -/
instance burn_registryPreserving
    (r : ResourceId) (fromActor : ActorId) (amount : Amount) :
    RegistryPreserving (.burn r fromActor amount) where
  preserves := fun _ => rfl

/-- `freezeResource` preserves the registry. -/
instance freezeResource_registryPreserving (r : ResourceId) :
    RegistryPreserving (.freezeResource r) where
  preserves := fun _ => rfl

/-- `reward` preserves the registry. -/
instance reward_registryPreserving
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    RegistryPreserving (.reward r to amount) where
  preserves := fun _ => rfl

/-- `distributeOthers` preserves the registry. -/
instance distributeOthers_registryPreserving
    (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    RegistryPreserving (.distributeOthers r excluded amount) where
  preserves := fun _ => rfl

/-- `proportionalDilute` preserves the registry. -/
instance proportionalDilute_registryPreserving
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    RegistryPreserving (.proportionalDilute r excluded totalReward) where
  preserves := fun _ => rfl

/-- `dispute` preserves the registry. -/
instance dispute_registryPreserving (d : Disputes.Dispute) :
    RegistryPreserving (.dispute d) where
  preserves := fun _ => rfl

/-- `disputeWithdraw` preserves the registry. -/
instance disputeWithdraw_registryPreserving (idx : Disputes.LogIndex) :
    RegistryPreserving (.disputeWithdraw idx) where
  preserves := fun _ => rfl

/-- `verdict` preserves the registry. -/
instance verdict_registryPreserving (v : Disputes.Verdict) :
    RegistryPreserving (.verdict v) where
  preserves := fun _ => rfl

/-- `rollback` preserves the registry. -/
instance rollback_registryPreserving (targetIdx : Disputes.LogIndex) :
    RegistryPreserving (.rollback targetIdx) where
  preserves := fun _ => rfl

/-- `deposit` preserves the registry. -/
instance deposit_registryPreserving
    (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (depositId : Bridge.DepositId) :
    RegistryPreserving (.deposit r recipient amount depositId) where
  preserves := fun _ => rfl

/-- `withdraw` preserves the registry. -/
instance withdraw_registryPreserving
    (r : ResourceId) (sender : ActorId)
    (amount : Amount) (recipientL1 : Bridge.EthAddress) :
    RegistryPreserving (.withdraw r sender amount recipientL1) where
  preserves := fun _ => rfl

/-- `declareLocalPolicy` preserves the registry.  (LP.5 mutates the
    `localPolicies` table, NOT the `KeyRegistry`.) -/
instance declareLocalPolicy_registryPreserving (policy : LocalPolicy) :
    RegistryPreserving (.declareLocalPolicy policy) where
  preserves := fun _ => rfl

/-- `revokeLocalPolicy` preserves the registry. -/
instance revokeLocalPolicy_registryPreserving :
    RegistryPreserving .revokeLocalPolicy where
  preserves := fun _ => rfl

/-- Workstream H: `faultProofChallenge` preserves the registry.
    The action compiles to `Laws.freezeResource 0` and has no
    authority-layer effect on the registry. -/
instance faultProofChallenge_registryPreserving
    (bh : ByteArray) (sIdx eIdx : Disputes.LogIndex) (cc : ByteArray) :
    RegistryPreserving (.faultProofChallenge bh sIdx eIdx cc) where
  preserves := fun _ => rfl

/-- Workstream H: `faultProofResolution` preserves the registry. -/
instance faultProofResolution_registryPreserving
    (bh : ByteArray) (gid : Nat) (winner : ActorId) (rfi : Disputes.LogIndex) :
    RegistryPreserving (.faultProofResolution bh gid winner rfi) where
  preserves := fun _ => rfl

/-- Workstream GP (v1.0): `depositWithFee` preserves the registry.
    The kernel-level effect (balance increments to recipient and
    poolActor) lives in `Laws.depositWithFee`; the budget-level
    effect (granting `budgetGrant` to `recipient`) lives in the
    admission gate.  Neither touches the `KeyRegistry`. -/
instance depositWithFee_registryPreserving
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId) :
    RegistryPreserving (.depositWithFee r recipient poolActor
                          userAmount poolAmount budgetGrant depositId) where
  preserves := fun _ => rfl

/-- Workstream GP (v1.0): `topUpActionBudget` preserves the registry.
    The signer-aware kernel effect (gas debit / credit) and the
    budget topup neither touch the `KeyRegistry`. -/
instance topUpActionBudget_registryPreserving
    (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    RegistryPreserving (.topUpActionBudget gasResource gasAmount
                          budgetIncrement poolActor) where
  preserves := fun _ => rfl

end Authority
end LegalKernel
