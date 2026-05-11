# Synthesis — Cross-cutting findings and open follow-ups

This document aggregates the findings of every per-area audit
file into a single, severity-ranked list, with cross-references
back to the individual audit files where each finding was
documented in detail.

The findings are organised by severity tier.  Within each tier,
findings are grouped by theme.

* **Critical:** would invalidate a kernel-soundness claim or
  could allow a malicious actor to bypass an admissibility gate.
* **Major:** would invalidate a deployment-level claim or could
  produce misleading audit output.
* **Minor:** documentation drift, brittleness in tooling, or
  ergonomic issues that do not affect correctness.
* **Informational:** observations the auditor wants to surface
  without recommending action.

---

## Critical findings

**None observed.**

The kernel TCB (`Kernel.lean` + `RBMapLemmas.lean`) is sound.
Every theorem reviewed depends only on the three canonical Lean
built-in axioms (`propext`, `Classical.choice`, `Quot.sound`).
No `sorry` in proof position.  No custom axioms.  The proofs
are direct (induction or computation), and the case-trees in
the multi-case proofs (`getBalance_setBalance_other`,
`totalSupply_setBalance`) are exhaustive.

The Phase 3 admissibility predicate, the Phase 6 dispute
pipeline, and the Workstream H fault-proof migration each
extend the kernel-adjacent surface in a way that preserves
the type-level firewall.  No instance of "the kernel
silently admits a transition that should have been rejected"
was found.

---

## Major findings

### M-1 — Replay tool's deploymentId defaults to `ByteArray.empty`

**Where:** `LegalKernel/Runtime/Replay.lean:148`,
`LegalKernel/Runtime/Loop.lean:172-174` (Runtime audit
`06-runtime.md` finding "DeploymentId defaults to
`ByteArray.empty` in both replay and the runtime hot path").

**What:** Cross-deployment-replay protection (Audit-3.4)
relies on the `deploymentId` field of `SignInput` being a
deployment-specific constant.  Both the replay tool's main
entry point and the runtime hot path's `processSignedAction`
default the `deploymentId` parameter to `ByteArray.empty`.
This is opt-in — only callers of `processSignedActionWith`
get a non-empty `deploymentId`.  The replay tool exposes no
parameterised entry point at all.

**Impact:** Two log files from different deployments could
be replayed against each other without the cross-deployment
signature check firing, as long as the production runtime
binary uses the default `deploymentId`.  In practice, the
production runtime supplies a non-empty `deploymentId`, so
the operational binary is sound; the issue is that the
*Lean* infrastructure has the default that silently turns
the check off.

**Recommendation:** Either (a) require an explicit
`deploymentId` parameter at every entry point (no default),
or (b) document the `ByteArray.empty` default as a
deployment-specific "I am the test / dev deployment"
sentinel value rather than a hidden default.

### M-2 — `bootstrapFromSnapshot` does not verify the log prefix chains to the snapshot's seed hash

**Where:** `LegalKernel/Runtime/Loop.lean:267-297` (Runtime
audit finding).

**What:** When restoring from a snapshot, the runtime
`bootstrap` function drops the log prefix without verifying
that the dropped prefix actually chains to the snapshot's
seed hash.  Only the first post-snapshot entry's chain check
runs.

**Impact:** An operator who supplies a coherent-but-wrong
snapshot (e.g. one from a different deployment that happens
to have the same `logIndex`) over a long log will be told
only if the chain at `entries[baseIdx]` happens to fail.
Because the post-snapshot tail is a valid chain on its own,
the bootstrap could succeed despite the snapshot being for
the wrong starting state.

**Recommendation:** Add an explicit chain-anchor check
before dropping the log prefix.  `AttestedSnapshot` is the
documented partner that closes this gap, but it must be
*required* by the runtime CLI, not just available.

### M-3 — Map-backed sub-states ship `*_deterministic` only — no `*_encode_injective` or `*_roundtrip`

**Where:** `LegalKernel/Encoding/State.lean`,
`LegalKernel/Encoding/Encodable.lean`,
`LegalKernel/Encoding/Disputes.lean`,
`LegalKernel/Encoding/LocalPolicy.lean`
(Encoding audit `05-encoding.md` finding).

**What:** For `State`, `ExtendedState`, `BridgeState`,
`LocalPolicies`, `KeyRegistry`, `NonceState`, the audit
found only `*_encode_deterministic` lemmas — no
`*_encode_injective` (bytes-equal-implies-equal) and no
`*_roundtrip` (decode-encode-eq) at the structural level.

**Impact:** CLAUDE.md footnote 1 explicitly calls out this
chokepoint for Workstream H: "Lifting bytes-equality to
extensional state equality (`toList` equality) requires CBE
encoder canonicality for `State` / `NonceState` /
`KeyRegistry` / `LocalPolicies` / `BridgeState`, which is
shipped at the structural level (`*_encode_deterministic`
and round-trip lemmas) but not as a stand-alone
`*_encode_injective` lemma for the map-backed sub-states;
that's a Workstream-H follow-up."  The fault-proof
soundness chain depends on `commitExtendedState_subcommits_bytes_eq_under_collision_free`
giving bytes-equality; promoting that to state-equality
requires the encoder injectivity.

**Recommendation:** Ship `*_encode_injective` for each
map-backed sub-state as a Workstream-H follow-up.  This is
already on the documented roadmap; the auditor confirms it
as a load-bearing follow-up.

### M-4 — Encoder uses CBE major-type tags, not per-instance tags; type-collision is documented but not structurally prevented

**Where:** `LegalKernel/Encoding/Encodable.lean`,
`LegalKernel/Encoding/CBOR.lean` (Encoding audit finding).

**What:** Every `Encodable` instance starts with a CBE
major-type tag (uint / bytes / array / map), not a
per-instance tag.  This means `Bool true` and `Nat 1`
produce identical bytes.  An ambient decoder that doesn't
know the expected type will mis-decode.

**Impact:** The deployment's runtime adaptor is responsible
for the type context.  An attacker who can inject bytes
into a position where a decoder expects type A but the
attacker supplies bytes valid for type B could trigger an
unexpected decode.  This is mitigated by the encoder being
total (no decoder error path that an attacker could
exploit) and by the `Action` constructor index being
explicit.

**Recommendation:** This is fundamentally fine — CBE is
position-typed by spec — but a structural improvement would
be to prefix each `Encodable` instance with a per-type tag.
This is a TCB-adjacent change and would require care.

### M-5 — `checkSignatureInvalid` hardcodes `deploymentId := ByteArray.empty`

**Where:** `LegalKernel/Disputes/Evidence.lean:186`
(Disputes audit `07-disputes.md` finding).

**What:** The signature-invalid dispute claim verifier
hardcodes the `deploymentId` parameter to `ByteArray.empty`,
relying on a "back-compat path".  This means a verdict on
this claim cannot distinguish cross-deployment-signed
actions from same-deployment-signed actions.

**Impact:** Similar to M-1: in practice the production
runtime supplies a real `deploymentId`, so disputes filed
against production logs work correctly.  But the Lean
infrastructure has the same default-empty hazard.

**Recommendation:** Require the `deploymentId` at the
dispute filing site rather than hardcoding it at evidence
check.

### M-6 — `Lex/Tools/Diff.lean` parameter and proof-override comparators only compare names, not types/bodies

**Where:** `Lex/Tools/Diff.lean:172-175, 176-179` (Lex
Tools audit `14-lex-tools.md` finding).

**What:** `paramsDiff` compares parameter `.name` only,
silently missing type / kind changes.  `proofOverridesDiff`
compares `.property` only, missing tactic-body changes.

**Impact:** A semantic diff that misses a type change on
a parameter or a body change on a proof override could
mark a breaking change as compatible, weakening the
governance gate for Lex law updates.

**Recommendation:** Extend both comparators to compare the
full record, not just the name.  This is a Lex
tooling-only change; no Lean / kernel impact.

### M-7 — `signedActionDomain` constant duplicated as separate string literal

**Where:** `LegalKernel/Authority/SignedAction.lean:139`,
`LegalKernel/Encoding/SignInput.lean:63` (Authority audit
`04-authority.md` finding).

**What:** The `signedActionDomain` constant
(`"legalkernel/v1/signedaction"`) is defined as a string literal
at two locations.  No shared constant.

**Impact:** A refactor that changes the domain string in
one place but not the other would silently desynchronize the
kernel's `signingInput` from `Encoding.signInput`.  No
mechanical check catches this drift.

**Recommendation:** Extract to a single shared constant
(e.g. in `LegalKernel/Authority/Crypto.lean` or a new
`LegalKernel/Authority/Domains.lean`).  Low effort, high
defensive value.

### M-8 — `Action` tag indices: parallel enumerations not mechanically linked

**Where:** `LegalKernel/Authority/Action.lean`,
`LegalKernel/Encoding/Action.lean` (Authority + Encoding
audits).

**What:** Three parallel enumerations of `Action`'s 19
constructors:
* `Action.tag` (the integer projection function).
* The CBE encoder's tag byte.
* The LP.2 dispatch table.

Only 4 of 19 indices are pinned by smoke checks
(`transfer=0`, `withdraw=14`, `declareLocalPolicy=15`,
`revokeLocalPolicy=16`).

**Impact:** A future PR that reorders the `Action`
constructors must update all three enumerations in lockstep.
Lean's type system would catch some mismatches (the encoder
would still compile if `Action.tag` matched the
constructor order), but a "transposition" (swap indices 5
and 6) would silently break log-file compatibility with
the on-disk and on-the-wire format.

**Recommendation:** Add per-constructor index regression
tests that pin every tag to its specific integer value.
Mechanical, append-only, high defensive value.

### M-9 — `naming_audit` enforcement narrower than documented policy

**Where:** `Tools/NamingAudit.lean:79-119`,
`Deployments/Examples/UsdClearing.lean:111` (Tools +
Deployments audits).

**What:** CLAUDE.md says `v2` is a forbidden temporal
marker.  The `naming_audit` tool's `forbiddenTokens` list
(line 79) does NOT include `_v2` as a substring.  As a
result, `federation_transfer_policy_v2` evades the
mechanical check despite the documented policy.

**Impact:** Documentation-vs-enforcement drift.  Reviewers
relying on `naming_audit` to enforce the documented policy
could let `_v2`-suffixed identifiers slip through.

**Recommendation:** Either (a) add `_v2`, `_v3`, etc. to
the `forbiddenTokens` list, OR (b) update CLAUDE.md to
list only the tokens the mechanical check actually
enforces.

### M-10 — `MockCrypto` docstring claims stub_audit will catch production imports; it does not

**Where:** `LegalKernel/Test/MockCrypto.lean:39-40` (Tests
audit `18-tests-overview.md` finding).

**What:** The `MockCrypto.lean` module docstring asserts:
"This module is **test-only**.  It must NOT be imported
from any non-test module.  The `stub_audit` binary will
flag any production import."

The actual `stub_audit` tool flags placeholder *bodies*
(`:= ByteArray.empty`, etc.), not imports of the mock
module.  A production module that imports `MockCrypto` and
uses `mockVerify` would NOT be caught by any current audit
tool.

**Impact:** A future PR that accidentally imports
`MockCrypto` into a production module would not be caught
by automation.  The crypto adaptor's correctness is the
backstop.

**Recommendation:** Either (a) extend an audit tool to flag
imports of `Test.*` modules from non-test code, OR (b)
update the docstring to remove the incorrect claim.

---

## Minor findings

### m-1 — `tcb_audit` parser silently accepts unrecognised import forms

**Where:** `Tools/TcbAudit.lean:76-84`.  Does not handle
`prelude`, `import all`, `meta import`.  Documented as
"keeps the parser simple."

**Impact:** A future TCB amendment that adds one of these
forms to a TCB-core file would be silently accepted.
Reviewers must catch it manually.

### m-2 — `count_sorries` pattern set exhaustive for common patterns but not formally complete

**Where:** `Tools/CountSorries.lean:168-174`.  Four
patterns: `:= sorry`, `by sorry`, `exact sorry`, bare
`sorry` line.  Misses `refine sorry`, `apply sorry`,
`(sorry : T)`, etc.

**Impact:** A sufficiently obfuscated `sorry` could
escape.  Backstop is code review + the strict-warnings
gate + `#print axioms` discipline.

### m-3 — `stub_audit` 12-line docstring lookback is a magic number

**Where:** `Tools/StubAudit.lean:157-175`.  Scans upward
12 lines for a docstring.

**Impact:** A stub-flagged line with a 15-line docstring
above it would not match.  Currently safe.

### m-4 — `withdraw`'s precondition permits `amount = 0`

**Where:** `LegalKernel/Laws/Withdraw.lean` (Laws audit
`03-laws.md` finding).

**What:** Unlike `transfer` / `burn`, `withdraw`'s
precondition has no positivity clause.  A zero-amount
withdrawal is admissible at the kernel level; only the
bridge-level authorisation gates it.

**Impact:** A bug in the bridge actor's policy could
admit zero-amount withdrawals, which would advance the
nonce but produce no observable state change.  Operational
nuisance, not a soundness issue.

### m-5 — `deposit.pre := True`; deposit-id uniqueness deferred to runtime

**Where:** `LegalKernel/Laws/Deposit.lean` (Laws audit).

**What:** The `deposit` law's precondition is `True`;
uniqueness of deposit IDs is enforced entirely by
`applyActionToBridgeState`.

**Impact:** The kernel-level `deposit` is unconditionally
admissible.  The bridge-level gate is load-bearing.

### m-6 — `affectedActors` doesn't include actors who gained balance via the action

**Where:** `LegalKernel/Events/Extract.lean:100` (Events
audit `11-events.md` finding).

**What:** For `distributeOthers` and `proportionalDilute`,
the helper returns pre-state actors only.  A future law
that *introduces* new actors at a resource would not have
its new-actor `balanceChanged` event emitted.

**Impact:** No current law introduces new actors, so this
is theoretical.  Flagged for future extensibility.

### m-7 — `Event` constructor-index drift relies on encoder, not inductive declaration

**Where:** `LegalKernel/Events/Types.lean` (Events audit
finding).

**What:** The "frozen index" annotations are a contract
with indexers.  Re-ordering the constructors would compile
but break every off-chain indexer.  The encoder is the
canonical contract.

**Impact:** Documented in the source but not mechanically
enforced.

### m-8 — Lex codegen fence-marker contract is a string convention

**Where:** `LegalKernel/Events/Extract.lean:239-240`,
`Lex/Tools/Codegen.lean` (Events + Lex Tools audits).

**What:** `-- BEGIN LEX-GENERATED` / `-- END
LEX-GENERATED` are string markers consumed by the codegen
tool.  Moving or renaming them breaks codegen.

**Impact:** Documented in source; manual review during
refactors required.

### m-9 — `Lex/Tools/Common.lean` reverse-alphabetical JSON field order

**Where:** `Lex/Tools/Common.lean:711-723` (Lex Tools
audit).

**What:** `LawDecl.toCanonicalJson` produces JSON with
reverse-alphabetical field order (caused by
`Lean.Json.mkObj`'s internal RBNode iteration).
Deterministic but unintuitive.

**Impact:** Documented in source; field order is a
canonicality contract with the cross-stack JSON consumer.

### m-10 — `Lex/Tools/Codegen.lean` M1 emission policy is effectively no-op

**Where:** `Lex/Tools/Codegen.lean` (Lex Tools audit).

**What:** Every `requiresEmission` returns `false`, so all
6 renderers emit empty strings.  Deliberate-illegal
`M2_RENDERER_TODO_*` tokens act as forward-protection.

**Impact:** Codegen is currently disabled; M2 will turn it
on.  Reviewers should not expect lex-generated code in
the M1 release.

### m-11 — `synth_*` synthesizers emit placeholder *strings*, not real Lean terms

**Where:** `Lex/DSL/Property.lean` (DSL audit `10-dsl.md`
finding).

**What:** The six synthesizers (`synth_conservative`,
`synth_monotonic`, etc.) emit placeholder strings.
Documented as M1 skeletons but a reviewer expecting
actual instance emission would be misled.

**Impact:** M2 will replace placeholders with real
synthesis.  Current behaviour is documented but
counter-intuitive.

### m-12 — `Shim.stmtReferencesSignedBy` is a positionless substring match

**Where:** `Lex/DSL/Shim.lean` (DSL audit finding).

**What:** Both `flow ... from alice to a` and
`flow ... from a to alice` pass under `signed_by alice`
because the check is a positionless substring match.

**Impact:** A weak signer check; the actual
authorisation must come from the `AuthorityPolicy`.
Documented but worth knowing.

### m-13 — `lexlaw` `renderSyntax := toString` can drift from user source bytes

**Where:** `Lex/DSL/Law.lean` (DSL audit finding).

**What:** `lexlaw`'s JSON sidecar uses `toString` to
render the syntax, which is not byte-identical to the
user source.  `deployment` uses the reliable
`Syntax.reprint` instead.

**Impact:** A Lex law's JSON sidecar could drift from
the user source in whitespace / quoting.  Documented in
the DSL audit; reviewers should not expect byte
equivalence.

### m-14 — `kernelOnlyApply` in `Evidence.lean` uses non-exhaustive wildcard

**Where:** `LegalKernel/Disputes/Evidence.lean:89`
(Disputes audit finding).

**What:** `kernelOnlyApply` uses a `_ => s` wildcard for
unhandled `Action` constructors.  If `Action` grows, the
wildcard silently captures the new constructor.

**Impact:** The coherence theorem's exhaustive 19-arm
case split is the safety net.  Documented in source.

### m-15 — `ingest` returns `none` for `depositInitiated` events

**Where:** `LegalKernel/Bridge/Ingest.lean` (Bridge audit
`08-bridge.md` finding).

**What:** Despite `Action.deposit` existing, the
`ingest` function returns `none` for L1 `depositInitiated`
events.  The actual deposit flow at the Lean level
bypasses `ingest` entirely.

**Impact:** Documented but worth knowing; reviewers
looking at the `ingest` function might be surprised.

### m-16 — §7.6.4 / §7.6.5 chain-level accounting theorems deferred to runtime cross-stack verification

**Where:** `LegalKernel/Bridge/Accounting.lean` (Bridge
audit finding).

**What:** Per-step deltas are complete but no inductive
top-level theorem exists in `Accounting.lean`.

**Impact:** Documented; the cross-stack tests
(`solidity/make test-cross-stack`) ratify what would be
the inductive theorem.

### m-17 — `Verdict.encode` relies on `List.zip_unzip`

**Where:** `LegalKernel/Encoding/Disputes.lean` (Encoding
audit finding).

**What:** Fragile if the wire format lengths disagree.

**Impact:** A malformed `Verdict` bytes input that has
mismatched lengths could trigger a decode error rather
than a clean rejection.  Documented.

### m-18 — `Lex/Tools/Codegen.lean` non-deterministic load order under duplicate-index registries

**Where:** `Lex/Tools/Codegen.lean` (Lex Tools audit
finding).

**What:** `Array.qsort`-induced non-determinism when
codegen-input registry has duplicate indices.  Mitigated
in `emitCanonicalManifest` / `emitAutoGenLean` via an
explicit identifier tie-breaker, but not everywhere.

**Impact:** Operational; if a user produces a registry
with duplicates, the audit tool's output could drift
between runs.  Backstop is `lex_lint` which would have
flagged the duplicates.

### m-19 — Several stale docstring claims

**Where:**
* `Lex/Tools/Codegen.lean:55-62` still claims
  `--canonical` is unimplemented (it's the audit-3
  manifest-scaffold mode).
* `LegalKernel/Authority/Crypto.lean:16` says `Verify` is
  a "Lean `axiom`" but the file uses `opaque`.
* `LegalKernel/Runtime/LogFile.lean:109-112` says hashes
  are "8 bytes" while the module's own `padTo32`
  discipline emits 32 bytes.

**Impact:** Documentation drift only; no behavioural
issue.

---

## Informational observations

### i-1 — Two non-Lean trust assumptions, both surfaced via `opaque`

**Where:** `LegalKernel/Authority/Crypto.lean:138`
(`Verify`), `LegalKernel/Runtime/Hash.lean` (`hashBytes`),
`LegalKernel/FaultProof/Witness.lean:70-72`
(`l1FaultProofVerifier`).

The trust model is honest: each non-Lean assumption is an
`opaque` declaration, not an `axiom`.  This keeps
`#print axioms` clean for downstream theorems even when
those theorems' admissibility paths reach the opaque.  The
production-vs-Lean asymmetry (opaques return defaults at
the Lean level) means term-level admissibility witnesses
cannot be constructed without the `MockCrypto` adaptor.

### i-2 — `Std.TreeMap` API surface is stable

The kernel + RBMapLemmas rely on roughly 12 named `Std`
lemmas.  All verified to exist in Lean 4 v4.29.1.  Any
toolchain bump must re-verify them (the
`docs/std_dependencies.md` inventory exists for this).

### i-3 — No external Lake dependencies

The kernel imports `Std.Data.TreeMap` only.  No Mathlib, no
batteries, no third-party Lean packages.  This is the
strongest part of the project's threat-model posture.

### i-4 — Strict linters enforced as CI gates

`autoImplicit := false`, `relaxedAutoImplicit := false`,
`linter.unusedVariables := true`, `linter.missingDocs := true`.
CI's strict-warnings gate fails the build on any `: warning:`
line.

### i-5 — Five mechanical audit gates in CI

`tcb_audit`, `count_sorries`, `stub_audit`, `naming_audit`,
`deferral_audit`, plus the Lex-specific `lex_lint` and
`lex_codegen --check`.  All run on every PR.

### i-6 — Two-reviewer rule is a process rule, not technically enforced

No CODEOWNERS file or branch-protection rule observed.
CI's mechanical gates enforce content discipline; reviewer
discipline is enforced by the team.

### i-7 — Coherence-by-construction in FaultProof.Coherence

The headline `recomputeCommitment_coherent_with_kernelOnlyApply`
theorem is structurally `rfl` because
`applyCellWrites_to_state` is literally `kernelOnlyApply`.
The trust-model upgrade leans heavily on the
cross-stack corpus (WU H.10.1).

### i-8 — Commit-injectivity shipped at bytes level only

`commitExtendedState_subcommits_bytes_eq_under_collision_free`
gives byte equality; lifting to extensional state equality
requires the encoder-injectivity follow-up (M-3).  Honestly
documented.

### i-9 — `proportionalDilute` dust-bound proof has a brittle invariant

**Where:** `LegalKernel/Laws/ProportionalDilute.lean` (Laws audit).

The bound relies on `S := sumOthers` being captured *before*
the foldl plus `kv.2` reading the *pre-foldl snapshot*
balance.  A refactor swapping `kv.2` for
`getBalance s' r kv.1` would silently break the bound and
has no explicit guard comment.  Recommend adding a
guard-comment near the load-bearing lines.

### i-10 — Decidability discipline holds project-wide

Every `Transition.decPre` field reviewed in this audit is
either `fun _ => inferInstance` (the common case) or has a
tightly scoped hand-written instance immediately adjacent
to the law.  No decidability witness reaches into
`Classical.dec` or `Decidable.decide` against unresolved
opaques.

### i-11 — Reward / stake economics has sharp edges but is non-TCB

* `claimImpugnedAmount` (Rewards.lean:580) silently skips
  bridge actions.
* `proportionalChallengerReward` with `divisor=0` emits a
  zero-amount reward record rather than no reward.
* `stakeWeightedAdjudicatorRewards`'s sum-le-pool bound is
  in the docstring but not shipped as a theorem.
* `Staking.stakeResolutionActions`'s "rollback returns the
  stake on .upheld" is a runtime invariant, not proved.

All are deployment-level concerns, not kernel soundness.

---

## Open follow-ups (suggested priority order)

Pulling from the major findings and the most actionable
minor findings, the recommended follow-up backlog is:

1. **[M-3] Map-backed sub-state encoder injectivity**
   (Workstream H follow-up).  Promotes byte equality to
   state equality across the fault-proof chain.
2. **[M-1, M-5] DeploymentId default-empty cleanup.**
   Either require explicit `deploymentId` at every entry
   point or document the sentinel semantics.
3. **[M-2] Bootstrap-from-snapshot chain-anchor check.**
   Add an explicit chain-anchor verification when
   restoring from a snapshot.
4. **[M-8] Action-tag index regression tests.**  Pin every
   constructor's tag to its specific integer value via
   regression tests.
5. **[M-6] Lex Diff parameter / proof-override
   comparators.**  Extend to compare types / bodies, not
   just names.
6. **[M-7] `signedActionDomain` shared constant.**
   Eliminate the duplication.
7. **[M-9] `naming_audit` enforcement vs. CLAUDE.md
   policy.**  Choose one; align the other.
8. **[M-10] `MockCrypto` import-check audit tool.**  Or
   correct the docstring.
9. **[i-9] `proportionalDilute` guard comment** at the
   load-bearing snapshot-read line.

The auditor's recommendation is that none of these
findings are urgent for a research-stage codebase, but
all should land before any production deployment that
depends on the cross-deployment-replay or
snapshot-bootstrap guarantees.

---

## Closing notes

The audit reviewed ~73,000 lines of Lean across 241 files.
The kernel TCB is sound by construction; the deployment-facing
infrastructure is well-engineered and well-tested but has the
expected scattered minor issues that any large research-stage
codebase accumulates.

The mechanical audit suite (`tcb_audit`, `count_sorries`,
`stub_audit`, `naming_audit`, `deferral_audit`, `lex_lint`,
`lex_codegen --check`) is a strong forcing-function and
catches the historical regressions documented in the
project's history.

The two-reviewer rule for TCB changes is a documented
process rule, currently enforced by team discipline rather
than CODEOWNERS.  Combined with the mechanical gates, this
gives the project the right posture for its claimed phase
(research-stage with production-aspiration).

No critical findings.  Ten major findings, mostly
documentation-vs-enforcement drift or
non-TCB-but-could-be-tighter; each has a recommended fix
that does not require a TCB amendment.  ~30 minor and
informational findings, all bounded.

The project is in good shape.
