# Disputes — `LegalKernel/Disputes/` (8 files, ~3971 lines)

**Directory:** `/home/user/Canon/LegalKernel/Disputes/`
**TCB:** None of the eight files is in the TCB.  Bugs here weaken
deployment-level adjudication guarantees but cannot violate kernel
invariants (the kernel routes every state advance through
`apply_admissible`; the dispute pipeline is purely advisory + one
rollback path).

The four §8.4 pipeline stages map to files as follows:

  * Stage 1 (filing)             → `Filing.lean`
  * Stage 2 (evidence check)     → `Evidence.lean`
  * Stages 3 + 4 (verdict)       → `Verdict.lean`
  * Types + error vocabularies   → `Types.lean`
  * Phase-6 incentive amendment  → `LawClassification.lean`,
                                   `MonotonicDeployment.lean`,
                                   `Rewards.lean`,
                                   `Staking.lean`

---

## 1. `Types.lean` (509 lines)

**Imports:** `LegalKernel.Kernel`, `LegalKernel.Authority.Crypto`.
Reasonable — only TCB + Crypto opaque.

### Inductive types and structures

* `LogIndex := Nat` (line 68) — abbreviation alias.
* `DisputeClaim` (line 86) — five variants, **append-only ordering
  policy** documented in the module docstring (encoding indices are
  part of canonical encoding):
  * `preconditionFalse (idx)`
  * `signatureInvalid (idx)`
  * `nonceMismatch (idx)`
  * `oracleMisreported (idx, evidence : ByteArray)`
  * `doubleApply (idx₁ idx₂)`
  Derives `Repr, DecidableEq`.
* `EvidenceVerdict` (line 131) — three-state: `upheld`,
  `rejected`, `inconclusive`.  Derives `Repr, DecidableEq`.
* `Dispute` (line 173) — `challenger`, `claim`, `evidence`, `nonce`,
  `sig`.  Derives `Repr, DecidableEq`.
* `Verdict` (line 229) — `disputeId`, `outcome`, `rationale`,
  `signatures : List (ActorId × Signature)`.  Audit-3.5 collapsed
  the old parallel-list `(signers, sigs)` shape into a single
  `signatures` field; back-compat accessors `signers` /
  `sigs` (lines 279, 284) are derived via `List.map Prod.fst` /
  `Prod.snd`.
* `DisputeStatus` (line 321) — `open`, `withdrawn`, `decided
  (outcome)`.  Derives `Repr, DecidableEq`.
* `DisputeRecord` (line 341) — `dispute`, `idx`, `status`.
  Derives `Repr, DecidableEq`.
* `OraclePolicy` (line 368) — single field
  `verifier : LogIndex → ByteArray → EvidenceVerdict`.
* `FilingError` (line 416) — `malformedAction`, `unknownChallenger`,
  `indexOutOfRange (idx, logLen)`, `duplicateDispute (priorIdx)`.
* `VerdictError` (line 491) — `unknownDispute`, `quorumNotMet`,
  `outcomeMismatch`, `alreadyDecided`, `replayFailed`.

### Canonicality

`Verdict.canonical` (line 257) is `v.signatures.Pairwise (fun p q =>
p.fst < q.fst)`.  Decidable instance synthesised via
`inferInstance` (line 261).  Strictly ascending implies no duplicate
keys, which structurally eliminates the trivial-quorum-forgery
class for canonical inputs; the decoder is documented to reject
non-canonical bytes via `nonCanonical`.

### Two helper accessors

`Verdict.signers_length_eq_sigs_length` (line 289) and
`Verdict.signers_length_eq_signatures_length` (line 296): both
follow from `List.length_map`.

### Documentation drift / sharp edges

* **Status-blind duplicate detection** (line 405): explicit design
  choice — `duplicateDispute` is triggered even when the prior
  dispute is `withdrawn` or `decided`.  A deployment that wants
  re-filing of withdrawn disputes must construct a fresh `Dispute`
  with a different `claim` payload (e.g. by mutating the
  `oracleMisreported` evidence bytes).  This is deliberate, not a
  bug, but it is a foot-gun for deployments that assume "withdraw
  resets the slot".
* `FilingError.malformedAction` is documented (lines 396 + 419)
  as deliberately unused by `fileDispute` in-tree, exposed only
  for deployment-level wrappers.  No code currently produces
  this variant.  Unused variants in error enums are a maintenance
  hazard; the comment makes the intent explicit but mechanical
  enforcement is absent.
* `OraclePolicy.alwaysRejects` (line 379) and `alwaysUpheld`
  (line 385): the latter is documented purely as a test fixture.
  No assertion or pragma prevents it being used in production.
* No `Inhabited` instances on `Dispute` / `Verdict` /
  `DisputeStatus`.  Not necessarily required, but tests / fixtures
  may need to construct defaults manually.

---

## 2. `Filing.lean` (315 lines)

**Imports:** `LegalKernel.Authority.SignedAction`,
`LegalKernel.Disputes.Types`, `LegalKernel.Runtime.LogFile`.
Reasonable.

### Definitions

* `claimImpugnedIdx : DisputeClaim → LogIndex` (line 68) — total
  pattern match across all five variants.
* `claimSecondaryIdx : DisputeClaim → Option LogIndex` (line 78) —
  `some idx₂` only for `doubleApply`, `none` otherwise.
* `disputeMatchesEntry` (line 90) — pattern matches on
  `entry.signedAction.action`; returns `true` only when the entry
  is `.dispute d'` with matching `(challenger, claim)`.
* `findPriorDisputeIdx` (line 98) — internal recursive `go`,
  threading index; returns the *first* matching position.
  Termination guaranteed by structural recursion on the list.
* `fileDispute` (line 142) — Stage 1.  Performs three checks
  (challenger registered, primary idx in range, secondary idx in
  range, no prior duplicate).  Pure (Except).  Documented as
  not consuming nonce.

### Stage-1 logic order (lines 142–172)

The error ordering is fixed and tested by
`fileDispute_rejects_unknown_challenger` (line 267).  Note: the
**duplicate check is performed AFTER the in-range check** — a
duplicate dispute against an out-of-range index produces
`indexOutOfRange`, not `duplicateDispute`.  This is internally
consistent.

### Idempotency theorems

* `applyWithdraw` (line 190) — function: `.open → .withdrawn`,
  fixed point for `decided _` and `withdrawn`.
* `applyVerdictOutcome` (line 197) — `.open → .decided outcome`,
  fixed point for others.
* `applyWithdraw_decided_idempotent` (line 249) — `rfl`.
* `applyWithdraw_withdrawn_idempotent` (line 253) — `rfl`.
* `applyWithdraw_open` (line 257) — `rfl`.
* **`applyWithdraw_idempotent`** (line 260) — the headline
  property: `applyWithdraw (applyWithdraw s) = applyWithdraw s`.
  Proof: `cases s <;> rfl`.

### `disputeStatus` walk-the-log function (line 213)

Inner `scan` is a recursive helper with a manual termination metric
`log.length - i`.  At each step it consults
`entry.signedAction.action`; recognises only `disputeWithdraw idx`
and `verdict v` entries.  The `idx` filter on
`disputeWithdraw` compares the action's referenced index against the
dispute's filing index.

**Sharp edge:** the function uses `scan (disputeIdx + 1) .open` as
the starting accumulator (line 239), so a verdict written at the
*same* index as the dispute (which is structurally impossible) is
not considered.  Logically fine since the dispute action is itself
at `disputeIdx`.  The walk-the-log derivation does not stop after
the first verdict/withdraw — multiple subsequent withdraws after a
decision continue to feed `applyWithdraw`, but those are idempotent
on `.decided _`, so the result remains stable.

### `fileDispute_rejects_*` family

* `fileDispute_rejects_unknown_challenger` (line 267) — proven.
* `fileDispute_returns_open_status` (line 278) — walks the entire
  case tree (4 splits × 2-3 inner splits), discharging every
  error branch via `Except.ok.inj`.  Brittle to refactoring but
  currently sound.

**Missing rejects-* lemmas (documentation drift relative to the
top-level summary):** the CLAUDE.md table headline names
`fileDispute_rejects_*` (family); only the `unknown_challenger`
variant is proved.  Specific `_indexOutOfRange` and
`_duplicateDispute` rejection lemmas are not present in
`Filing.lean`.  The `_returns_open_status` lemma does provide
coverage of the success branch, and the error branches are
mechanically discharged in its body, but **individual rejection
lemmas for the `indexOutOfRange` and `duplicateDispute` cases are
not exposed**.

---

## 3. `Evidence.lean` (560 lines)

**Imports:** `LegalKernel.Authority.SignedAction`,
`LegalKernel.Disputes.Types`, `LegalKernel.Runtime.Replay`.
Reasonable.

### Replay primitives

* `kernelOnlyApply` (line 89) — admissibility-blind:  uses
  `step_impl es.base t` (which is `if t.pre then apply_impl else
  es.base`), advances the nonce via `advanceNonce`, and mutates
  the registry / localPolicies for the four registry- or
  policy-mutating actions (`replaceKey`, `registerIdentity`,
  `declareLocalPolicy`, `revokeLocalPolicy`).  The match list
  duplicates `applyActionToRegistry`'s logic — documented as
  intentional (TCB-import-surface independence).
* `kernelOnlyReplay` (line 123) — `entries.foldl kernelOnlyApply`.
* `replayPrefix` (line 133) — returns `none` when
  `idx > log.length`, else `kernelOnlyReplay genesis (log.take idx)`.

**Sharp observation:** the `kernelOnlyApply` match (line 103) is
NOT a wildcard catch-all — it covers four specific actions
explicitly + `_ => es''` for the rest.  If a new
registry-mutating action constructor is added, this function will
silently fail to mirror the runtime.  The coherence theorem
(`apply_admissible_with_eq_kernelOnlyApply` line 433) handles the
full 19-arm case split (line 456–475) — that one IS exhaustive
and will fail to typecheck if the `Action` inductive grows.

### Per-claim verifiers

* `checkPreconditionFalse` (line 146) — replays prefix, evaluates
  `(Action.compile entry.signedAction.action).transition.pre
  preState.base`.  `inconclusive` on out-of-range / replay
  failure.
* `checkSignatureInvalid` (line 186) — looks up current registry
  key; **hardcodes `deploymentId := ByteArray.empty`** (line 206).
  This is documented (lines 196–205) as an Audit-3.4 follow-up
  for deployments using non-empty deployment IDs — a parameterised
  `checkSignatureInvalidWith` variant is mentioned but not yet
  shipped.  Sharp.
* `checkNonceMismatch` (line 224) — replays prefix, compares
  `expectsNonce` to the entry's nonce.
* `checkOracleMisreported` (line 265) — **defensive index check**:
  returns `.inconclusive` if `log[idx]? = none` *before* calling
  the oracle's verifier (line 269).  This is load-bearing for
  `applyVerdict_under_witness_succeeds` (Verdict.lean line 911)
  — the in-range bound on the impugned index for `.upheld`
  evidence verdicts requires that ALL five verifiers refuse to
  return `.upheld` when the impugned index is out of range.
* `checkDoubleApply` (line 286) — `idx₁ = idx₂` ⇒ `.rejected`;
  both indices in-range, same signer + same nonce ⇒ `.upheld`;
  otherwise `.rejected`.  Missing-index cases produce
  `.inconclusive`.

### Headline checkEvidence and determinism

* `checkEvidence` (line 316) — single match dispatching on
  `rec.dispute.claim`.  Pure.
* **`checkEvidence_deterministic`** (line 338) — proof is
  `rw [h_es, h_g, h_l, h_r]` (essentially `rfl` after rewriting
  equalities).  This is the §8.4.3 headline property and it is
  trivially true because `checkEvidence` is a pure function.
* `checkPreconditionFalse_deterministic` (line 350) — same
  rewrite pattern.
* `checkOracleMisreported_returns_oracle_verdict` (line 362) —
  pass-through on in-range branch.
* `checkOracleMisreported_inconclusive_on_out_of_range`
  (line 376) — the defensive index check theorem.
* `checkDoubleApply_rejects_self` (line 385) — `simp`.

### Coherence theorem (Audit-3.6)

* `apply_admissible_with_eq_kernelOnlyApply` (line 433) — per-step
  coherence between runtime path (`apply_admissible_with`) and
  dispute-replay path (`kernelOnlyApply`).  Under admissibility
  witness `h`, the `if t.pre` branch in `step_impl` collapses to
  `apply_impl`, and the two functions agree on every action
  constructor (19-arm case split).
* `RuntimeAdmissibleWith` inductive (line 490) — chain-level
  admissibility predicate.
* `RuntimeAdmissibleWith.head` (line 535) — head extraction.
* `kernelOnlyApply_eq_apply_admissible_with_at_head` (line 550) —
  chain-level corollary via symmetry of the per-step lemma.

**Documentation drift / sharp edge:** the module docstring claims
the chain-level theorem is proved "by routine induction" (lines
522–530), but the **chain-level theorem is NOT shipped as a
stand-alone statement** — only the per-step lemma plus a head-
extraction corollary.  The text explicitly notes the chain-level
theorem is "left to per-callsite derivation" (line 525); this is
honest, but the headline-summary line in the surrounding plan
documentation can read as if the chain-level form is mechanised.

---

## 4. `Verdict.lean` (1102 lines)

**Imports:** `LegalKernel.Authority.SignedAction`,
`LegalKernel.Disputes.{Types, Filing, Evidence}`,
`LegalKernel.Runtime.Replay`.  Reasonable.

### Definitions

* `QuorumPolicy` (line 128) — `approvedAdjudicators : List
  ActorId`, `required : Nat`.
* `QuorumPolicy.singleton` (line 141), `QuorumPolicy.empty` (line
  154).
* `verdictDomain := "legalkernel/v1/verdict"` (line 189) —
  cross-protocol replay protection.
* `verdictSigningInput` (line 223) — CBE-encodes
  `(domainBytes ++ disputeId ++ outcome ++ rationale)`.  Does NOT
  include signatures (would create a circular dependency).  Uses
  `Encoding.cborHeadEncode` for the domain prefix.
* `countVerifiedSignatures` (line 249) — **per-signer
  deduplication** via `foldl` with `(count, seen)` accumulator.
  First-seen-wins discipline: a signer marked seen on a failing
  signature cannot retry with a duplicate entry later in the list.
  Quorum-forgery defence.

### Stake/signature counting

The dedup logic uses `seen : List ActorId` linearly, so worst-case
`countVerifiedSignatures` is O(n²) in the number of signatures.
For canonical verdicts (strictly ascending) the dedup is a no-op
but the cost still applies (the membership check is unconditional).
Performance impact bounded by the quorum size, which is small in
practice.

### Stage 3 (proposeVerdict)

`proposeVerdict` (line 297) — four checks in sequence:

  1. `log[v.disputeId]? = none` → `.unknownDispute`.
  2. Entry's action not `.dispute _` → `.unknownDispute` (note:
     reuses the same error variant as the first check).
  3. `disputeStatus` not `.open` → `.alreadyDecided`.
  4. `checkEvidence` recomputation `≠ v.outcome` → `.outcomeMismatch`.
  5. `countVerifiedSignatures < required` → `.quorumNotMet`.

Sharp: error variants `.unknownDispute` is used for BOTH "no log
entry" AND "log entry but not a dispute action".  Auditors expect
distinct errors; this is a deliberate collapse.

### Input-preservation bridge lemma

`proposeVerdict_ok_returns_input` (line 341) — proves that every
`.ok v'` return implies `v' = v`.  Proof walks the match tree
manually with `split at h` + `dsimp only` to push past the
intermediate `let` bindings (line 362).  The `dsimp only at h`
trick is load-bearing — `split` alone cannot dive through the
`let recomputed := …; let verified := …` bindings.

### Stage 4 (applyVerdict — 3 tiers)

1. **`applyVerdictUnchecked`** (line 492) — bypass form,
   documented "TESTING ONLY".  Matches `log[v.disputeId]?`,
   `entry.action`, `disputeStatus`, then on `.upheld` performs
   prefix replay via `replayPrefix`; on `.rejected` /
   `.inconclusive` returns `currentEs` unchanged.
2. **`VerdictPassedStage3`** (line 406) — propositional witness
   structure with single field `proposed : proposeVerdict ... =
   .ok v`.
3. **`applyVerdict`** (line 619) — witness-bearing form.  Reduces
   trivially to `applyVerdictUnchecked` via
   `applyVerdict_eq_unchecked` (line 632) (proof: `rfl`).
4. **`proposeAndApplyVerdict`** (line 1018) — default-safe
   combined form.

### Witness-extraction theorems

* `applyVerdict_log_in_range` (line 711) — `∃ entry, log[v.disputeId]?
  = some entry`.
* `applyVerdict_entry_is_dispute` (line 725) — `∃ d,
  entry.signedAction.action = .dispute d`.
* `applyVerdict_dispute_open` (line 838) — `disputeStatus log
  v.disputeId = some .open`.
* `applyVerdict_outcome_matches` (line 869) — `checkEvidence ...
  = v.outcome`.

### Headline strong-correctness theorem

* `claimImpugnedIdx_in_range_when_upheld` (line 769) — five-case
  split (one per `DisputeClaim` variant); each case uses the
  defensive index check (or, for `doubleApply`, the `idx ≠ idx`
  case) to establish that an `.upheld` evidence verdict implies
  `log[claimImpugnedIdx ...]? = some _`.
* **`applyVerdict_under_witness_succeeds`** (line 911) — the
  Phase 6 headline theorem.  Reduces to
  `applyVerdictUnchecked` via the trivial equivalence, then walks
  the match tree using all three witness-extraction theorems.
  Three sub-cases on `v.outcome`:
  - `.rejected` and `.inconclusive` → trivial `⟨currentEs, rfl⟩`.
  - `.upheld` → uses `applyVerdict_outcome_matches` +
    `claimImpugnedIdx_in_range_when_upheld` to derive the in-range
    bound, then proves `replayPrefix = some _`.

### Per-variant unreachable-error theorems

* `applyVerdict_unknownDispute_unreachable` (line 969).
* `applyVerdict_alreadyDecided_unreachable` (line 982).
* `applyVerdict_replayFailed_unreachable` (line 994).
  All three derive `False` from `applyVerdict_under_witness_succeeds`
  + the error-output assumption.

### Default-safe entry point

`proposeAndApplyVerdict` (line 1018) — calls `proposeVerdict`; on
`.ok v'`, uses `proposeVerdict_ok_returns_input` +
`of_proposeVerdict_ok_with_eq` to build the witness; then calls
`applyVerdict`.

* `proposeAndApplyVerdict_eq_applyVerdict_when_proposed_ok`
  (line 1037).
* `proposeAndApplyVerdict_proposeVerdict_error_path` (line 1058).
* `proposeAndApplyVerdict_deterministic` (line 1079).
* `proposeAndApplyVerdict_unknown_dispute` (line 1090).

### Sharp edges

* The `replayFailed` branch of `applyVerdictUnchecked` is
  unreachable under the witness, but the bypass form can still
  emit it.  Production deployments using the bypass form on
  forged input can therefore see `.replayFailed` and must handle
  it; the documentation steers callers to the default-safe form.
* `applyVerdictUnchecked` is intentionally exposed.  Its
  docstring carries strong warning language (lines 464–490) but
  Lean has no compile-time visibility restriction; a downstream
  module can import and call it freely.
* The witness construction `of_proposeVerdict_ok_with_eq` requires
  the bridge lemma to mediate between the pattern-bound `v'` and
  the input `v`.  The construction is sound but creates a
  non-trivial obligation for any downstream code that synthesises
  the witness from a different success-pattern shape.

### Documentation drift

* The module docstring's "WITHOUT Stage 3 validation" warning
  (line 33) for `applyVerdictUnchecked` could be stronger about
  the `quorumNotMet` and `outcomeMismatch` checks specifically
  being skipped — these are the security-critical checks.
* The opaque `Verify` cannot be reduced at the Lean level, so
  `countVerifiedSignatures` returns 0 at the Lean term level for
  any real signature.  Tests must use `mockVerify` (cf. CLAUDE.md
  test discipline).  Not a bug, but a structural restriction worth
  flagging.

---

## 5. `LawClassification.lean` (174 lines)

**Imports:** `LegalKernel.Authority.Action`,
`LegalKernel.Conservation`, `LegalKernel.Disputes.Types`,
`LegalKernel.Laws.Freeze`.  Reasonable.

### Identification lemmas (lines 63–82)

Four `rfl` lemmas asserting that each dispute action constructor's
`compileTransition` equals `Laws.freezeResource 0`:

* `dispute_compileTransition_eq_freezeResource_zero` (line 63).
* `disputeWithdraw_compileTransition_eq_freezeResource_zero`
  (line 67).
* `verdict_compileTransition_eq_freezeResource_zero` (line 72).
* `rollback_compileTransition_eq_freezeResource_zero` (line 81).

All four discharge via `rfl` — definitionally aligned with the
`compileTransition` table in `Authority/Action.lean`.

### Conservative and Monotonic instances

Four `IsConservative` instances (lines 92–113) and four
`IsMonotonic` instances (lines 120–141), each combining the
identification lemma with `freezeResource_isConservative 0` /
`freezeResource_isMonotonic 0` (Phase-2 / Phase-4-prelude
primitives).

### Composite summary

`dispute_pipeline_actions_classification` (line 155) — packages
all eight facts into a single conjunctive theorem.  Trivial proof
(named-instance lookups).

### Sharp edge

The Genesis-Plan classification firewall hinges on
**runtime-level** rollbacks happening OUTSIDE `apply_admissible`
(documented at lines 30–36, 75–80, and in `MonotonicDeployment.lean`).
The classification typeclasses cover only the kernel-level state
advance (which is a no-op for these four constructors).  An
unscoped reader could conclude that the rolled-back state inherits
monotonicity / conservation; it does not.  The comments warn but
this conceptual subtlety remains a source of confusion.

---

## 6. `MonotonicDeployment.lean` (152 lines)

**Imports:** `LegalKernel.Conservation`, `LegalKernel.Laws.{Transfer,
Mint, Reward, DistributeOthers, ProportionalDilute, Freeze}`.
Reasonable; deliberately does NOT import
`LawClassification` (lines 45–51) to avoid a cycle / to keep the
example self-contained.

### Definitions

* `disputableMonotonicLaws : List Transition` (line 82) — six laws
  parametrised at `0`:
  ```
  [ transfer 0 0 0 0, mint 0 0 0, reward 0 0 0,
    distributeOthers 0 0 0, proportionalDilute 0 0 0,
    freezeResource 0 ]
  ```
  The `0` placeholders are documented as "make the law-set's
  constructibility provable at the type level" — a real
  deployment parametrises differently.
* `disputableMonotonicLaws_isMonotonic` (line 94) — case-splits on
  list membership; dispatches each branch to the Phase-2 /
  Phase-4-prelude monotonicity lemma.
* `disputableMonotonicLawSet` (line 112) — packages into a
  `MonotonicLawSet`.

### Headline theorem

* **`disputable_monotonic_total_supply_nondecreasing`** (line 133)
  — applies `total_supply_globally_nondecreasing_via_law_set` to
  the example deployment.  States that for every resource `r₀` and
  every state `s` reachable from `genesisState` via the example
  law set's laws, `TotalSupply genesisState r₀ ≤ TotalSupply s r₀`.
* `disputable_monotonic_total_supply_nondecreasing_from` (line 144)
  — same theorem from an arbitrary `s0` (production deployments
  rarely start at `genesisState`).

### Sharp edges

* The example uses literal `0`s for every parameter.  This makes
  the example pedagogical, not deployment-ready.  A production
  deployment must instantiate parameters meaningfully — and
  re-prove the monotonicity lemma; the `0`-instance proof does
  NOT carry over generically (each `Laws.X` family has parametric
  `IsMonotonic` instances that take the arguments back).
* The boundary clarification (lines 30–34) reiterates that
  `applyVerdict (.upheld)` rollback is OUTSIDE the `Reachable`
  relation — this theorem makes no claim about post-rollback state.

---

## 7. `Rewards.lean` (869 lines)

**Imports:** `LegalKernel.Authority.Action`,
`LegalKernel.Disputes.{Types, Filing, Verdict}`,
`LegalKernel.Runtime.LogFile`.  Reasonable.

### Policy structure

`DisputeRewardPolicy` (line 68) — two fields:
* `challengerReward : List LogEntry → Dispute → EvidenceVerdict →
  Option (ResourceId × Amount)`.
* `adjudicatorReward : List LogEntry → Verdict → Option
  (ResourceId × Amount)`.

Pure deterministic functions.  Per-adjudicator reward is *uniform*
across the signer list (the policy returns one
`(resource, amount)`; the emission helper applies it once per
signer).

### Atomic constructors

* `empty` (line 85) — both fields return `none`.
* `flatChallengerReward (resource, amount)` (line 92) — `some
  (resource, amount)` for `.upheld`, `none` otherwise.
* `flatAdjudicatorReward (resource, amount)` (line 103) — `some
  (resource, amount)` for every verdict (paid for work, not just
  upheld).
* `union p₁ p₂` (line 116) — **left-biased fallthrough**: `p₁`'s
  `some` value wins; otherwise falls through to `p₂`.  Note: this
  is the field-wise OR, not the concatenation; for bundling
  multiple resource rewards use `disputeRewardActionsMulti`.

### Emission helper

`disputeRewardActions` (line 137) — concatenates:
* 0–1 challenger reward actions.
* 0–N adjudicator reward actions (one per signer if policy returns
  `some`).
All emitted actions are `Action.reward _ _ _`.

### Core theorems

* `disputeRewardActions_deterministic` (line 153) — trivial via
  `rw`.
* `disputeRewardActions_emits_only_rewards` (line 163) — case-
  split on `List.mem_append`; each branch matches on the policy's
  `some/none`; both `some` branches witness `Action.reward _ _ _`.
* `disputeRewardActions_length_bound` (line 192) — proves
  `length ≤ 1 + v.signers.length`.

### Constructor-specific theorems

Four `rfl`-level lemmas (lines 217–242) for `flat*` and `empty`:
`flatChallengerReward_rejected_no_reward` (217),
`flatChallengerReward_upheld_emits` (224),
`flatAdjudicatorReward_emits_for_every_verdict` (231),
`empty_no_actions` (238).
Four `union` lemmas (lines 246–300) covering left-bias success +
fallthrough for both challenger and adjudicator fields.

### Wrappers

* `applyVerdictWithRewardsUnchecked` (line 310) — bypass form.
  Matches on `log[v.disputeId]?` and `entry.action.dispute d`,
  then calls `applyVerdictUnchecked`.  Emits rewards on success.
* `disputeRewardActionsMulti` (line 331) — `foldr (++) []`
  across a list of policies.
* `applyVerdictWithRewardsMultiUnchecked` (line 338).
* `applyVerdictWithRewards` (line 364) — witness-bearing version,
  reduces by `rfl` to the unchecked form.
* `applyVerdictWithRewardsMulti` (line 374) — multi-policy
  witness-bearing version.
* `proposeAndApplyVerdictWithRewards` (line 390) — default-safe
  combined.
* `proposeAndApplyVerdictWithRewardsMulti` (line 409) — default-
  safe combined multi.

### Wrapper theorems

Determinism + unknown-dispute paths for the unchecked form,
trivial-equivalence theorems for the witness-bearing form,
proposed-ok reduction and error-path lemmas for the default-safe
form (lines 427–505).

### Multi-policy theorems

* `disputeRewardActionsMulti_concat` (line 511) — `rfl`.
* `disputeRewardActionsMulti_empty_no_actions` (line 518) —
  `rfl`.
* `disputeRewardActionsMulti_emits_only_rewards` (line 524) —
  inductive proof.
* `disputeRewardActionsMulti_length_bound` (line 543) — inductive
  proof using `Nat.succ_mul` and `omega`.

### Graduated reward policies

* `claimImpugnedAmount` (line 580) — extracts numeric amount from
  the impugned action; returns `none` for actions without one
  (freezeResource, replaceKey, dispute, verdict, rollback, deposit,
  withdraw, registerIdentity, faultProof*).  **Wait — missing
  cases:** the function explicitly matches `transfer`, `mint`,
  `burn`, `reward`, `distributeOthers`, `proportionalDilute`, and
  catches everything else with `_ => none`.  That means
  `deposit (r, _, _, amt)` and `withdraw (r, _, _, amt)` —
  WHICH DO HAVE AMOUNT FIELDS — return `none` from
  `claimImpugnedAmount`.  Whether this is intentional (bridge
  actions get a flat reward) or an omission is unclear from the
  source; no comment explains the choice.  **This is a sharp
  edge.**
* `proportionalDilute` is handled (line 591), with the amount
  pulled from the `tr` (total-reward) field.
* `byClaimVariant` (line 599) — five different reward amounts per
  claim variant.
* `proportionalChallengerReward` (line 631) — `factor * amt /
  divisor`.

  **Divisor-zero foot-gun:** the docstring (lines 619–630)
  explicitly notes that `Nat`'s `n / 0 = 0`, so a misconfigured
  policy with `divisor = 0` emits a zero-amount reward record
  PLUS a `rewardIssued` event.  Indexers may observe the policy
  emit a 0-value reward as a signal.  Deployments are pointed at
  `empty` or `union` for "no reward" semantics.

### Constructor-specific reward theorems

* `byClaimVariant_returns_none_on_rejected` (line 644) — `rfl`.
* `proportionalChallengerReward_returns_none_on_rejected` (line
  654) — `rfl`.
* `proportionalChallengerReward_value_correct` (line 663) —
  rewrites through the `match`.
* `proportionalChallengerReward_returns_none_on_amountless_impugned`
  (line 677) — same shape.

### Stake-weighted adjudicator rewards (WU 6.22)

* `totalSignerStake` (line 691) — fold-sum of balances.
* `stakeWeightedAdjudicatorRewards` (line 704) — `filterMap`-based:
  `pool * stake / totalStake` per signer, dropping zero-reward
  entries.  Edge cases: `totalStake = 0` → `[]`; `pool = 0` →
  every per-element value is 0 → `[]`.
* `stakeWeightedAdjudicatorRewards_zero_pool_no_actions` (line 719).
* `stakeWeightedAdjudicatorRewards_zero_total_stake_no_actions`
  (line 733).
* `stakeWeightedAdjudicatorRewards_emits_only_rewards` (line 742).
* **`foldl_balance_acc_le` (line 768)** — accumulator-monotonicity
  helper.
* **`getBalance_le_totalSignerStake` (line 781)** — each signer's
  stake ≤ total stake.  Proof generalises over the accumulator
  via the helper.  Strict accumulator induction with `subst h_eq`
  in the `inl` branch.
* **`stakeWeightedAdjudicatorRewards_each_le_pool` (line 820)** —
  per-element reward ≤ pool.  Uses `Nat.mul_div_cancel` against
  `Nat.pos_of_ne_zero h_zero` — sound provided `totalStake ≠ 0`,
  which is exactly the `if_neg` branch.

### Sharp / surprising

* **Stake accounting:** `stakeWeightedAdjudicatorRewards` returns
  `Amount` reward actions, never a "sum-le-pool" theorem at the
  collection level.  Per-element ≤ pool is proved, but the
  collection sum could in principle exceed pool (e.g. with rounding
  effects accumulating).  Actually, since each is `pool * stake /
  totalStake` and the floor-sum-of-floors property holds for
  proportional shares, the sum IS `≤ pool`, but the theorem is not
  stated.  **`disputeRewardActions_sum_le_pool` is absent.**
  (Documented at the WU 6.22 boundary as a "per-element + sum-le-
  pool dust-bound theorem" in the module docstring line 27, but
  the sum-le-pool lemma is not present.)
* **`claimImpugnedAmount` skips bridge actions** (deposit / withdraw)
  with explicit amounts.  Either intentional scoping (bridge
  actions don't enter the dispute pipeline in practice) or
  oversight — no comment.
* **All reward actions are `Action.reward _ _ _`** — positive-
  incentive only, no destruction.  Documented at the module
  docstring (line 33).

---

## 8. `Staking.lean` (290 lines)

**Imports:** `LegalKernel.Authority.Action`,
`LegalKernel.Disputes.{Types, Filing}`,
`LegalKernel.Runtime.LogFile`.  Reasonable.

### Structure

`StakingPolicy` (line 68) — `stakeResource`, `stakeAmount`,
`escrowActor`, `treasuryActor`.

`StakingPolicy.disabled` (line 83) — all four fields set to `0`.
**Sharp:** `escrowActor := 0` and `treasuryActor := 0` are both
`ActorId 0`.  A deployment that has a real actor with id 0 and
chooses to disable staking will trivially `canStake` (since
`stakeAmount = 0`) but emit nothing — safe in practice, but the
zero-actor collision is a documentation concern.

### Pre-filing check

`StakingPolicy.canStake` (line 94) — `decide (getBalance ≥
stakeAmount)`.  Returns `true` unconditionally when
`stakeAmount = 0`.

### Errors

`StakedFilingError` (line 103) — two variants:
* `filing (e : FilingError)` — wraps the underlying error.
* `insufficientStake (have_ : Amount) (need : Amount)` — records
  both balance and required stake (note: `have_` with trailing
  underscore — Lean reserved-word workaround).

Derives `Repr` only — no `DecidableEq`.  Tests that pattern-match
on this enum work via constructor matching, not equality.

### Filing-time staking actions

`stakeFilingActions` (line 119) — `[Action.transfer challenger →
escrow stakeAmount]` when enabled, `[]` when `stakeAmount = 0`.

### Resolution-time staking actions

`stakeResolutionActions` (line 138) — **per D1 of the plan**:
* `.upheld` → `[]` (rollback to pre-staking state implicitly
  returns the stake).
* `.rejected` / `.inconclusive` → `[Action.transfer escrow →
  treasury stakeAmount]` (forfeiture).

**Sharp edge:** the "rollback implicitly returns the stake"
guarantee is a *runtime invariant*, not proved here.  It depends
on the runtime appending the staking transfer BEFORE the dispute
SignedAction, so that `replayPrefix log impugnedIdx` lands BEFORE
the staking transfer.  If the runtime appends the staking transfer
AFTER the dispute SignedAction (or out-of-order), the rollback
does NOT return the stake.  The function's contract is
preconditional; auditors must verify the runtime obeys it.

### fileDisputeStaked wrapper

`fileDisputeStaked` (line 164) — composes `canStake` check with
`fileDispute`.  Returns `(DisputeRecord, [Action])`.

### Sanity theorems

* `stakeFilingActions_emits_only_transfers` (line 179) — proves
  every action is a `transfer`.
* `stakeResolutionActions_emits_only_transfers` (line 192) — same.
* `stakeFilingActions_disabled_no_actions` (line 215) — `rfl`-level.
* `stakeResolutionActions_disabled_no_actions` (line 221) —
  `rfl`-level.
* `stakeResolutionActions_upheld_no_actions` (line 228).
* `stakeResolutionActions_rejected_emits_treasury_transfer` (line
  237).
* `stakeResolutionActions_inconclusive_emits_treasury_transfer`
  (line 247).
* `fileDisputeStaked_rejects_underfunded` (line 263).
* `fileDisputeStaked_disabled_passthrough` (line 283).

### Sharp / surprising

* **Slashing is a transfer, not a burn** — the module docstring
  (lines 36–40) explicitly notes this preserves both conservation
  AND monotonicity.  The treasury actor can later recycle the
  forfeited tokens (e.g. as adjudicator-pool funding).  Sound design.
* **No proof that the runtime appends staking actions in the
  correct order.**  The runtime contract is documented (lines
  153–163, "Order of operations the runtime SHOULD follow") but
  not enforced by a Lean theorem.  A runtime that fails to follow
  the documented order can break the "rollback returns stake"
  invariant silently.
* **`canStake` uses `Nat ≥`** (line 96), so the check passes even
  when balance EQUALS stake.  Edge case is correct.
* **No protection against repeated filing**.  The `fileDispute`
  status-blind duplicate check is the only barrier; a challenger
  whose dispute is withdrawn can re-file with a different claim
  variant (or different evidence bytes for `oracleMisreported`)
  and pay stake again.  Whether this is intentional is unclear.

---

## Cross-file observations

### Headline theorem coverage vs. CLAUDE.md table

CLAUDE.md's headline-theorem table mentions:

* `fileDispute_rejects_*` family — only the `unknown_challenger`
  variant is shipped (Filing.lean:267); `_indexOutOfRange` and
  `_duplicateDispute` are not exposed.  The `_returns_open_status`
  lemma exercises the error branches mechanically but does not
  expose them as named rejection theorems.
* `applyWithdraw_idempotent` — shipped (Filing.lean:260).
* `checkEvidence_deterministic` — shipped (Evidence.lean:338),
  but trivially true (it's `rw [...]` after assuming all four
  inputs are equal — the result is just `rfl` modulo congruence).
  The substantive determinism property is that `checkEvidence` is
  a pure function, which Lean's type system enforces without a
  theorem.
* `applyVerdict_under_witness_succeeds` — shipped
  (Verdict.lean:911), with deep machinery: the helper
  `claimImpugnedIdx_in_range_when_upheld` is the load-bearing
  step.
* `disputable_monotonic_total_supply_nondecreasing` — shipped
  (MonotonicDeployment.lean:133).

### Subsystem-wide sharp edges

1. **`applyVerdictUnchecked` is exported.**  Production runtimes
   are documented not to call it directly, but Lean has no
   visibility restriction.  The witness-bearing form
   (`applyVerdict`) compiles to the same code via `rfl`.
2. **Reward sum-le-pool collection bound is missing for stake-
   weighted rewards.**  Per-element bound is proved; the dust-
   bound for the sum is mentioned in the module docstring but no
   lemma stating `(stakeWeightedAdjudicatorRewards ...).foldr +
   ≤ pool` is shipped.
3. **`claimImpugnedAmount` silently skips bridge actions
   (deposit / withdraw).**  No comment explains whether this is
   intentional scoping (bridge actions don't enter dispute
   pipeline) or an oversight.  A `proportionalChallengerReward`
   policy will return `none` for an `oracleMisreported` dispute
   against a bridge action, even though the bridge action HAS a
   numeric amount field.
4. **`kernelOnlyApply` is not exhaustive over Action**
   constructors.  Uses an explicit four-arm match + wildcard.  If
   a new registry-mutating action is added, `kernelOnlyApply`
   may drift from `applyActionToRegistry`.  The coherence theorem
   (`apply_admissible_with_eq_kernelOnlyApply`) uses an
   exhaustive 19-arm case split that WILL fail to typecheck if
   `Action` grows — that is the safety net.
5. **`checkSignatureInvalid` hardcodes empty deploymentId** —
   correctness depends on the runtime configuring `Verify` with
   `deploymentId := ByteArray.empty` (the back-compat path).
   Non-empty-deploymentId deployments need a parameterised
   variant which is not yet shipped (Audit-3.4 follow-up).
6. **`disputeStatus` walks the entire log from `disputeIdx + 1`.**
   For a long log with one dispute resolved early, every other
   dispute filed later still triggers a full-tail walk on each
   `disputeStatus` query.  No memoisation.  Performance impact
   bounded by log size.
7. **Status-blind duplicate detection in `fileDispute`** —
   `withdrawn`/`decided` disputes still trigger `duplicateDispute`.
   Deliberate, but a foot-gun for deployments expecting
   re-filing-after-withdraw to work.
8. **Trivial `*_deterministic` theorems** — many of the
   determinism theorems in this directory (`checkEvidence_*`,
   `proposeVerdict_*`, `applyVerdict_*`, `disputeRewardActions_*`,
   `applyVerdictUnchecked_*`) are trivially true via `rw` on
   equality hypotheses.  They serve as API-stability fixtures
   (Lean elaboration verifies the signatures still match) but
   carry no substantive content.
9. **No `Inhabited` / `Default` instances** — the various
   structures (`Dispute`, `Verdict`, `DisputeStatus`, etc.) cannot
   be `default`-constructed.  Each test fixture must build values
   manually.
10. **`countVerifiedSignatures` is O(n²)** in the signatures list
    length due to the linear-list `seen` membership check.  For
    typical quorum sizes (3–7) this is irrelevant, but a
    Pathological verdict with hundreds of duplicate signers would
    pay the quadratic cost.

### Documentation drift

* The module docstring of `Evidence.lean` (lines 522–530) describes
  a chain-level coherence theorem that is intentionally NOT
  shipped as a stand-alone statement.  Honest but easy to
  misread.
* The module docstring of `Rewards.lean` (lines 13–31) lists
  "sum-le-pool dust-bound theorems" but only the per-element
  bound is in the file.
* `FilingError.malformedAction` is documented (Types.lean:419) as
  intentionally unused by the in-tree `fileDispute`.  An auditor
  scanning the enum would assume coverage; the comment is
  load-bearing.
* The CLAUDE.md headline table cell `fileDispute_rejects_*`
  family implies multiple named rejection theorems; only one
  (`_unknown_challenger`) is exposed in `Filing.lean`.
