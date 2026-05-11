# Canon — Comprehensive Lean Module Audit

**Date:** 2026-05-11
**Branch:** `claude/comprehensive-lean-audit-gDXJa`
**Scope:** Every `.lean` source file in the Canon repository.
**Total source files audited:** 241
**Total lines (incl. tests):** ~73,166
**Total lines (excl. tests):** ~42,572

## Methodology

This audit was performed by line-by-line review of the source code,
without trusting documentation as a description of behavior.  For each
module the audit notes:

1. **Imports & TCB classification.**  Whether the module is in the
   trusted computing base (TCB) — i.e. `LegalKernel/Kernel.lean` or
   `LegalKernel/RBMapLemmas.lean`; in the "kernel-adjacent" no-sorry
   set (TCB + `Laws/Transfer.lean`); or deployment-facing infrastructure.

2. **Surface area.**  Every public declaration (definition, theorem,
   structure, instance) and what guarantee it makes.  Universal
   constructions ("for every state ...") receive heavier scrutiny
   than per-call-site instances.

3. **Proof posture.**  Whether each theorem is proved by structural
   computation, by induction on an explicit witness, by `decide` on a
   finite domain, or by appeal to `Decidable.decide` against an
   `opaque` declaration.  Proofs that reduce to `simp`-with-no-args
   are spot-checked against the actual lemma library; "termini" of
   `omega` and `decide` are not load-bearing in the kernel TCB.

4. **Hazards.**  Anything that looked sharp on first reading:
   non-obvious decidability instances, unchecked imports, partial
   functions hidden behind `Option`, missing test coverage, brittle
   string-encoded contracts (e.g. CBE-byte goldens), implicit
   `Decidable` resolution that may fail to elaborate under future
   Lean toolchain bumps, etc.

5. **Documentation drift.**  Where the docstring claims X but the
   code does Y, the auditor records it; the rule is "code first,
   documentation second", per the user's instruction not to trust
   documentation.

## Layout of this audit

The audit is split across multiple files so individual sections can
be re-read or re-issued without timing out on a single write.  Each
section is self-contained; the order below tracks dependency depth
(TCB first, then leaves).

| Path                                          | Scope                                                                       |
|-----------------------------------------------|-----------------------------------------------------------------------------|
| `00-comprehensive-lean-audit-index.md`        | This file: methodology, index, project-wide observations.                   |
| `01-tcb-core.md`                              | `LegalKernel/Kernel.lean` + `LegalKernel/RBMapLemmas.lean` (TCB).           |
| `02-conservation.md`                          | `LegalKernel/Conservation.lean` (non-TCB monotonicity/conservation infra).   |
| `03-laws.md`                                  | 13 modules under `LegalKernel/Laws/`.                                       |
| `04-authority.md`                             | 7 modules under `LegalKernel/Authority/`.                                   |
| `05-encoding.md`                              | 10 modules under `LegalKernel/Encoding/`.                                   |
| `06-runtime.md`                               | 6 modules under `LegalKernel/Runtime/`.                                     |
| `07-disputes.md`                              | 8 modules under `LegalKernel/Disputes/`.                                    |
| `08-bridge.md`                                | 12 modules under `LegalKernel/Bridge/`.                                     |
| `09-fault-proof.md`                           | 25 modules under `LegalKernel/FaultProof/`.                                 |
| `10-dsl.md`                                   | 2 modules under `LegalKernel/DSL/` + 8 modules under `Lex/DSL/`.            |
| `11-events.md`                                | 2 modules under `LegalKernel/Events/`.                                      |
| `12-localpolicy.md`                           | 1 module under `LegalKernel/LocalPolicy/`.                                  |
| `14-lex-tools.md`                             | Audit/code-gen tooling under `Lex/Tools/` and `Lex/Bin/`.                   |
| `15-tools.md`                                 | Non-Lex audit tooling under `Tools/` and the top-level wrappers.            |
| `16-executables.md`                           | `Main.lean`, `Replay.lean`, `LegalKernel.lean`, `Lex.lean`, etc.            |
| `17-deployments-examples.md`                  | `Deployments/Examples/UsdClearing.lean` and `Lex/Examples/`.                |
| `18-tests-overview.md`                        | Test infrastructure overview (lighter review since these aren't shipped).   |
| `19-findings-and-followups.md`                | Synthesis: cross-cutting findings, severity-ranked, and open follow-ups.    |

## Project-wide observations

The following observations apply at the project level and are not
repeated in individual module files.

### Strengths

* **Tight TCB.**  Only two files (`Kernel.lean` + `RBMapLemmas.lean`,
  ~440 lines total) are TCB-core.  Every other module is non-TCB
  deployment-facing infrastructure whose bugs are scoped to
  deployment-level claims, not kernel invariants.  The mechanical
  `tcb_audit` gate enforces this at every PR.

* **No custom axioms.**  Every theorem the kernel exports depends on
  `propext`, `Classical.choice`, and `Quot.sound` only — the three
  built-in Lean axioms.  Two non-Lean trust assumptions
  (`Authority.Crypto.Verify`, `Runtime.Hash.hashBytes`) are surfaced
  through `opaque` declarations rather than `axiom`s, which keeps
  the `#print axioms` output clean even when those declarations are
  reachable from a downstream theorem.

* **No `sorry`.**  `lake exe count_sorries` runs in CI and is gated
  to zero for the kernel-adjacent file set (`Kernel.lean`,
  `RBMapLemmas.lean`, `Laws/Transfer.lean`).  The detector masks
  `--` and `/- -/` comments and `"..."` string literals so the word
  "sorry" in prose is permitted; only the term in proof position is
  forbidden.  This rule is correctly enforced by
  `Tools/CountSorries.lean`.

* **Strict linters.**  `autoImplicit := false`,
  `relaxedAutoImplicit := false`, `linter.missingDocs := true`,
  `linter.unusedVariables := true`.  CI's strict-warnings gate
  fails the build on any `: warning:` line, so the lint posture is
  enforced rather than advisory.

* **Decidability discipline.**  Every `Transition.decPre` field
  reviewed in this audit is either `fun _ => inferInstance` (the
  common case, satisfied by Std-derived `Decidable` instances on
  arithmetic comparisons + finite conjunctions) or has a tightly
  scoped hand-written instance immediately adjacent to the law.  No
  decidability witness reaches into `Classical.dec` or
  `Decidable.decide` against unresolved opaques.

* **Naming hygiene.**  The "names describe content, never
  provenance" rule is enforced both by `naming_audit` (which the
  auditor confirmed actually scans, with masking of comments and
  strings, in `Tools/NamingAudit.lean`) and by a documented
  pre-commit `grep` pattern.  No instances of forbidden naming
  tokens (`wu`, `phase`, `audit`, `claude_`, `tmp`, `todo`, `v2`,
  `legacy`, etc.) were observed in declaration names in this pass.

### Risks / hazards observed (cross-cutting, low-medium severity)

The following items recur across multiple modules and are summarised
here rather than in each per-area file.  Severity is tagged in
square brackets; full discussion lives in `19-findings-and-followups.md`.

* **[INFO] Opaque dependence is correct but underdocumented at
  call sites.**  Many laws / encoders ultimately depend on
  `Runtime.Hash.hashBytes` (or its `BLAKE3` extern) for any
  collision-resistance argument.  Each individual theorem
  signature names the dependence (e.g. the explicit
  `CollisionFree hashBytes` premise), but a "where is the trust
  rooted?" pointer at the call site would help reviewers.

* **[INFO] Encoder canonicality is asserted at the byte level for
  primitive Encodable instances and at the structural level for
  map-backed sub-states, but the auditor could not locate a
  single-statement `*_encode_injective` lemma for every map-backed
  encoder (`State`, `NonceState`, `KeyRegistry`, `LocalPolicies`,
  `BridgeState`).  Round-trip lemmas exist; injectivity at the
  bytes-equal-implies-equal direction is shipped as a Workstream-H
  follow-up.  This is consistent with the CLAUDE.md footnote on
  Workstream H but worth keeping in mind when downstream theorems
  appeal to "bytes-equality of state implies state equality".

* **[INFO] CBE goldens.**  The cross-stack tests under
  `LegalKernel/Test/Bridge/CrossCheck/` and several Lex sidecar
  files lock in byte sequences that must agree with the Solidity
  mirror.  Any encoder change must update the goldens; the
  workflow exists (the sidecars are `input_file` build inputs in
  `lakefile.lean`), but a deliberate update of the encoder
  *without* refreshing goldens silently breaks cross-stack
  equivalence rather than failing the Lean side.  CI is supposed
  to catch this on the Forge side; reviewers should not rely on
  Lean alone.

* **[INFO] `Std.TreeMap` API surface.**  The kernel + RBMapLemmas
  rely on a handful of Std lemmas (`getElem?_insert_self`,
  `getElem?_insert`, `toList_insert_perm`, `foldl_eq_foldl_toList`,
  `getElem?_erase`, `mem_iff_isSome_getElem?`,
  `mem_toList_iff_getElem?_eq_some`, `Equiv.foldl_eq`,
  `DTreeMap.Equiv.of_forall_constGet?_eq`).  Each is a stable
  public name in Lean 4 v4.29.1; a future toolchain bump could in
  principle rename or restructure these, and the kernel proofs
  would need updates.  `docs/std_dependencies.md` is the
  canonical inventory.

* **[INFO] Two-reviewer rule is documented but not technically
  enforced.**  The §13.6 two-reviewer gate for TCB changes is a
  process rule; no CODEOWNERS file or branch-protection rule was
  observed in the repository.  CI's mechanical gates
  (`count_sorries`, `tcb_audit`, `stub_audit`, `naming_audit`)
  enforce *content* discipline, not *review* discipline.

* **[INFO] `Verify` and `hashBytes` return defaults at the Lean
  level.**  `Verify` is `opaque := fun _ _ _ => false` at the Lean
  level and `hashBytes` is `opaque := fun b => ...` with the FNV
  fallback; production binaries link a `@[extern]` adaptor that
  overrides both.  This means term-level admissibility witnesses
  cannot be constructed in Lean for Verify-gated paths — the test
  suite uses the `MockCrypto` adaptor (`mockVerify` always returns
  `true` in a controlled mode) to exercise happy-path coverage.
  This is correct, but a reviewer must understand that an
  `apply_certified` chain that exercises any signature check is
  only as sound as the production crypto adaptor.

### Acknowledgements

The audit was performed by an automated reviewer against the
state of the `claude/comprehensive-lean-audit-gDXJa` branch at
HEAD.  Process-flavoured remarks (which session produced what)
have been omitted per the CLAUDE.md naming policy.  Specific
findings and recommendations live in
`19-findings-and-followups.md`.
