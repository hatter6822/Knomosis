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
import LegalKernel.Authority.Nonce
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

/-- Domain separation string prepended to every `signingInput`
    payload.  Matches `Encoding.signedActionDomain` exactly so
    that downstream Phase-4 sign-input bytes (with the additional
    deploymentId prefix) and the kernel's `signingInput` bytes
    use the same protocol-version family.  The string is encoded
    as a CBE byte string (length-prefixed) before being prepended;
    consumers therefore self-delimit the prefix from the action
    payload that follows. -/
def signedActionDomain : String := "legalkernel/v1/signedaction"

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

Each condition is independent and can be discharged at a different
time (Genesis Plan §8.2's "static vs dynamic" split), and the order
of failures is meaningful for diagnostics.

**Note on conjunct count.**  The §8.2 spec lists five admissibility
conditions, but the Lean encoding below has *four* top-level `∧`
connectives.  This is because conditions 1 (signer is registered)
and 3 (signature verifies under the registered key) share the
existential witness `pk` and are therefore most naturally combined
into a single conjunct of the form
`∃ pk, registry[signer]? = some pk ∧ Verify pk msg sig = true`.
This packing is *strictly stronger* than two independent existentials
would be — the Verify check is forced to use *the* registered key,
not any key — which is what §8.2 intends. -/

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
  (Action.compile st.action).transition.pre es.base

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
    pair. -/
theorem admissible_authorized
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    P.authorized st.signer st.action := h.1

/-- Extract condition 4: the signed nonce matches the actor's
    next-expected nonce.  (Renamed from `admissible_nonce_eq` for
    consistency with the other extractors; the old name is preserved
    as an alias below.) -/
theorem admissible_nonce
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    st.nonce = expectsNonce es st.signer := h.2.1

/-- Extract conditions 1 + 3: the signer is registered with some
    key `pk` and the signature verifies under that key (using the
    production `Verify` and the empty deploymentId — the back-compat
    default; see `AdmissibleWith`-version below for the parameterised
    form). -/
theorem admissible_signer_registered_and_signed
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    ∃ pk, es.registry[st.signer]? = some pk ∧
          Verify pk (signingInput st.action st.signer st.nonce ByteArray.empty)
            st.sig = true :=
  h.2.2.1

/-- Audit-3.3: the parameterised analogue.  Extract conditions 1 + 3
    from an `AdmissibleWith verify P d` witness. -/
theorem admissibleWith_signer_registered_and_signed
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : AdmissibleWith verify P d es st) :
    ∃ pk, es.registry[st.signer]? = some pk ∧
          verify pk (signingInput st.action st.signer st.nonce d) st.sig = true :=
  h.2.2.1

/-- Extract condition 5: the compiled transition's precondition holds
    in the base state. -/
theorem admissible_pre
    {P : AuthorityPolicy} {es : ExtendedState} {st : SignedAction}
    (h : Admissible P es st) :
    (Action.compile st.action).transition.pre es.base := h.2.2.2

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
  | _                              => kr

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
    and exercise the post-state. -/
def apply_admissible_with
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (_h : AdmissibleWith verify P d es st) :
    ExtendedState :=
  let t   := (Action.compile st.action).transition
  let s'  := t.apply_impl es.base
  let es' := { es with base := s' }
  let es'' := advanceNonce es' st.signer
  { es'' with registry := applyActionToRegistry es''.registry st.action }

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
    `apply_impl` applied to the pre-state's `base`.  Direct unfolding
    of `apply_admissible`; useful for downstream conservation
    arguments that need to compose `apply_admissible` with kernel
    invariant-preservation lemmas. -/
theorem apply_admissible_base
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    (apply_admissible P es st h).base =
    (Action.compile st.action).transition.apply_impl es.base := rfl

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
  unfold apply_admissible
  -- The registry update doesn't touch nonces; advanceNonce at the signer
  -- doesn't touch a' ≠ signer.
  show ((advanceNonce { es with base := _ } st.signer).nonces.next[a']?.getD 0)
    = es.nonces.next[a']?.getD 0
  rw [show
    (advanceNonce { es with base := _ } st.signer
      : ExtendedState).nonces.next[a']?.getD 0
    = expectsNonce { es with base := _ } a'
    from expectsNonce_advance_other _ st.signer a' hne]
  rfl

/-- The signer's expected nonce after `apply_admissible` is exactly
    one greater than before. -/
theorem expectsNonce_after_apply_admissible
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction) (h : Admissible P es st) :
    expectsNonce (apply_admissible P es st h) st.signer =
    expectsNonce es st.signer + 1 := by
  unfold apply_admissible
  -- The final registry-update step doesn't touch `nonces`, and
  -- changing `base` doesn't touch `nonces` either.  So
  -- `expectsNonce` after `apply_admissible` reduces to
  -- `expectsNonce` after `advanceNonce` on the base-modified ES.
  show expectsNonce
    { advanceNonce { es with base := _ } st.signer with
        registry := applyActionToRegistry _ st.action } st.signer
    = expectsNonce es st.signer + 1
  -- registry mutation doesn't change nonces; advanceNonce strict-mono
  -- gives the answer.
  show ((advanceNonce { es with base := _ } st.signer).nonces.next[st.signer]?.getD 0)
    = expectsNonce es st.signer + 1
  rw [show
    (advanceNonce { es with base :=
      ((Action.compile st.action).transition).apply_impl es.base } st.signer
      : ExtendedState).nonces.next[st.signer]?.getD 0
    = expectsNonce { es with base :=
      ((Action.compile st.action).transition).apply_impl es.base } st.signer + 1
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

end Authority
end LegalKernel
