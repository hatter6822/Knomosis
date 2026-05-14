<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Ethereum Integration — Workstream G (Documentation + Amendment)

This document plans Workstream E-G, the documentation amendment
that ratifies Workstreams E-A through E-F (Ethereum integration)
into the project's canonical design documents.

E-G is currently the **only "Not started" workstream** in the
project's roadmap (per CLAUDE.md status table).  The Lean and
Solidity code shipped in E-A through E-F is complete; this
workstream's job is to surface that work in `GENESIS_PLAN.md`,
`README.md`, `CLAUDE.md`, `docs/abi.md`, `docs/extraction_notes.md`,
and `docs/std_dependencies.md`.

E-G is pure documentation; there are no code changes.  However,
because it amends `GENESIS_PLAN.md`, the **§14.4 two-reviewer
Genesis-Plan-amendment rule** applies.

## Status

  * **Workstream prefix:** `WG` (Workstream G).  Five sub-units:
    - **WG.1** GENESIS_PLAN amendment (new chapter §15).
    - **WG.2** README + CLAUDE.md status updates.
    - **WG.3** ABI document additions (new §12).
    - **WG.4** Extraction notes update (new §2 entries).
    - **WG.5** Std-dependency audit refresh.
  * **Effort estimate:** 8–14 engineer-days for one engineer
    familiar with the Ethereum workstream.
  * **Two-reviewer requirement:** WG.1 and WG.5 (anything that
    amends GENESIS_PLAN.md or `tcb_allowlist.txt` /
    `docs/std_dependencies.md`).
  * **Build-posture target:** all existing CI gates green.  No
    `.lean` or `.sol` source changes, so source builds are
    unchanged.  The `deferral_audit` may surface previously-
    invisible "deferred" claims if any sub-unit accidentally
    leaves a "deferred" phrase in its prose; the audit runs over
    docs/ only via its existing scope rule.

## Table of contents

  * §1 Goals and non-goals
  * §2 Background
  * §3 Work-unit dependencies
  * §4 Work-unit specifications (WG.1 – WG.5)
  * §5 Sequencing and PR structure
  * §6 Quality gates
  * §7 Risk register
  * §8 Acceptance criteria
  * §9 Out-of-scope items
  * §10 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Ratify the Ethereum integration into the Genesis Plan.**
    A new chapter §15 documents the deployment scenario, trust
    assumptions, action/event extensions, bridge accounting
    equation, dispute pipeline integration, and the full
    architecture.
  2. **Synchronise top-level documents.**  README, CLAUDE.md,
    `abi.md`, `extraction_notes.md`, and `std_dependencies.md`
    all carry references to the Ethereum surfaces; ensure they
    are consistent.
  3. **Document trust assumptions.**  EUF-CMA on secp256k1,
    collision-resistance of keccak256, L1 finality
    assumptions, Solidity-side soundness, EIP-1271 correctness
    — each gets a named entry in `extraction_notes.md`.
  4. **Audit `tcb_allowlist.txt`.**  The bridge modules added
    Std imports; WG.5 verifies the allowlist matches the
    realised import set and that `tcb_audit` is green.
  5. **Zero source change.**  No `.lean`, `.sol`, or `.rs` file
    changes (except possibly tiny docstring tweaks to cite the
    new GENESIS_PLAN sections).

### §1.2 Non-goals

  1. **No new theorems.**  The integration's correctness is
    already proven in E-A through E-F.  WG documents it.
  2. **No retroactive design change.**  The wire formats, ABI,
    and trust model are what they are; WG records them.
  3. **No Rust integration documentation.**  WG is about Lean +
    Solidity.  Rust ports are documented in the
    `rust_host_runtime_plan.md` follow-on.
  4. **No `solidity/README.md` rewrite.**  That document is
    operator-facing and lives separately; WG adds cross-references
    if needed but does not own its content.

### §1.3 Reading guide

  * **Implementer:** WG.1 first (the substantive amendment),
    then WG.3 (ABI), then WG.2 / WG.4 / WG.5 in any order.
  * **Reviewer:** check cross-document consistency at landing
    time.  The reviewer-checklist for each sub-unit lists
    specific consistency invariants.

### §1.4 Glossary

  * **Genesis Plan §X.**  A specific section of
    `docs/GENESIS_PLAN.md`.  WG.1 introduces a new chapter §15
    "Ethereum Integration" (distinct from the existing §15B
    "Fault-Proof Migration" — both numbered §15 but addressed by
    sub-section).  **NOTE for the implementer:** before landing
    WG.1, verify whether the existing §15B numbering must shift
    (e.g. rename §15B to §16) to make room for the new §15.
    The project's history may already accommodate the new §15;
    grep the document during WG.1's first-day audit.
  * **Trust assumption.**  A property of an external (non-Lean)
    component that some Lean theorem's conclusion depends on.
    Documented in `extraction_notes.md` §2.

## §2 Background

The Ethereum workstreams shipped:

  * **E-A** (cryptographic adaptors): ECDSA-secp256k1 +
    keccak256 swap-points (Lean side).
  * **E-B** (identity + authority): bridge actor signing,
    EIP-1271 verification.
  * **E-C** (bridge laws): `deposit` / `withdraw` admissibility
    laws with chain-level accounting deltas.
  * **E-D** (withdrawal proofs): sparse-Merkle-tree withdrawal
    proofs with `verifyProof_complete` / `verifyProof_sound`
    theorems.
  * **E-E** (Solidity contracts): 10 contracts, 5 libraries.
  * **E-F** (cross-stack verification): byte-equivalence
    fixture corpus.

Each workstream has its own plan and audit history.  WG ties
them together into a single coherent narrative in the project's
canonical documents.

## §3 Work-unit dependencies

```
WG.1 (GENESIS_PLAN §15) ──► WG.3 (abi.md §12)
                       └──► WG.4 (extraction_notes.md §2)
                       └──► WG.2 (README + CLAUDE.md)
                       └──► WG.5 (std_dependencies + tcb_allowlist)
```

WG.1 ships the substantive content.  WG.2 – WG.5 are
downstream consistency updates.

## §4 Work-unit specifications

---

### WG.1 — Genesis Plan amendment: new chapter §15 "Ethereum Integration"

**Finding map.**  E-G primary deliverable.

**Scope.**  `docs/GENESIS_PLAN.md` only.  Net additions
~1500–2500 lines.  The amendment requires two reviewers per
§14.4 of the existing Genesis Plan.

**WG.1 decomposes into thirteen sub-sub-units** (one per
§15 sub-section plus a numbering-audit + TOC update + final
review pass).  Each sub-sub-unit lands as a smaller-scope Edit
within the larger WG.1 PR (one logical change per Edit,
anchoring against context already present, per CLAUDE.md
large-file-edit rules).

  * **WG.1.a** — Pre-audit + numbering decision.
  * **WG.1.b** — §15.1 Deployment scenario.
  * **WG.1.c** — §15.2 Trust assumptions.
  * **WG.1.d** — §15.3 Action / Event extensions + frozen-
    index table.
  * **WG.1.e** — §15.4 Bridge state + accounting equation.
  * **WG.1.f** — §15.5 Withdrawal-proof scheme.
  * **WG.1.g** — §15.6 Dispute-pipeline integration.
  * **WG.1.h** — §15.7 EIP-712 signing surface.
  * **WG.1.i** — §15.8 Solidity contract surface.
  * **WG.1.j** — §15.9 Cross-stack verification corpus.
  * **WG.1.k** — §15.10 Non-goals + v2 deferrals.
  * **WG.1.l** — Table-of-contents update + cross-reference
    pass.
  * **WG.1.m** — Two-reviewer review pass + sign-off.

#### WG.1.a — Pre-audit + numbering decision

**Activity.**

  1. Read `docs/GENESIS_PLAN.md` end-to-end (~4200 lines; use
    chunked `Read` calls per CLAUDE.md "Reading large files").
  2. Inventory existing Ethereum-touching references via
    grep:
     ```bash
     grep -nE 'Ethereum|bridge|L1|secp256k1|keccak256|EIP-(1271|712)|withdrawal[- ]proof' \
       docs/GENESIS_PLAN.md
     ```
  3. Inventory existing §15-numbered sections via:
     ```bash
     grep -nE '^## §15\.|^## 15\.|^### §15B' docs/GENESIS_PLAN.md
     ```
  4. Numbering decision: prefer **append as §15** if no
    top-level chapter is already numbered §15.  If §15B is
    a top-level chapter (audit shows it is, per CLAUDE.md
    references to "GENESIS_PLAN §15B"), the choice is between:
     - **(a)** Renumber the existing §15B chapter to §16
       (Fault-Proof Migration); make new chapter §15
       (Ethereum Integration).  Disruptive: every §15B
       cross-reference must update.
     - **(b)** Name the new chapter §15A (Ethereum
       Integration); keep §15B (Fault-Proof Migration) as-is.
       Less disruptive but creates the §15A/§15B/§15C
       cluster, which is asymmetric.
    Recommend **(a)** for long-term clarity; budget a half
    day for the renumber pass in WG.1.l.
  5. Document the chosen numbering scheme in the PR
    description before any edits land.

**Output.**  A markdown checklist with each existing reference
mapped to a destination sub-section in the new §15.

**Effort.**  ~1 engineer-day.

#### WG.1.b — §15.1 Deployment scenario

**Content sketch.**

  * L1 + L2 + bridge model: single-sequencer L2 with
    cryptographic anchoring to L1.
  * Bridge model: actors deposit on L1 (locking funds in
    `CanonBridge` contract), L2 reflects deposit as a state
    transition, actors withdraw via proof-of-state on L1.
  * Off-chain observer: an honest party watches L1 for
    fault-proof claims, computes the canonical reply.
  * Dispute game: interactive bisection; cell proofs lift to
    L1; settlement is the L1-final state-root.

**Source references.**  Pull diagrams from
`docs/planning/ethereum_integration_plan.md` §1, §3.

**Effort.**  ~0.5 engineer-day.

#### WG.1.c — §15.2 Trust assumptions

**Content sketch.**

For each of the five Ethereum trust assumptions:

  1. **EUF-CMA secp256k1.**  Statement: "for any PPT
    adversary `A` and message space `M`, `A` cannot produce
    a forgery on a randomly-generated `(pk, sk)` pair except
    with negligible probability."  Used by `Verify`
    opaque (in deployments selecting secp256k1).  Lean
    theorems consuming: `replay_impossible`,
    `nonce_uniqueness`, `eip712Wrap_injective`.
  2. **keccak256 collision-resistance.**  Standard collision-
    resistance hypothesis.  Used by `hashBytes` opaque.
    Lean theorems: every `*_under_collision_free` lemma.
  3. **L1 finality.**  Statement: "L1 blocks at depth ≥ N
    do not reorder."  Default N = 12 (Ethereum mainnet
    convention).  Used by withdrawal-proof finalisation
    (`isFinalised_monotonic_in_currentBlock`).
  4. **Solidity correctness.**  Statement: "the deployed
    Solidity bytecode reflects the audited Solidity source."
    Cross-stack fixture corpus ratifies operationally.
  5. **EIP-1271 correctness.**  Statement: "smart-contract
    wallets' `isValidSignature` callback returns true iff
    the wallet's intent-set permits the signed message."
    Used by smart-contract wallet support; no Lean theorem
    consumes directly (deployment-level).

**Cross-reference.**  Each TA cross-references its
`extraction_notes.md` §2 entry (WG.4 ships these).

**Effort.**  ~0.5 engineer-day.

#### WG.1.d — §15.3 Action / Event extensions + frozen-index table

**Content sketch.**

  * Frozen-index table: every `Action` constructor with its
    integer index.  Pull from `Lex.IndexRegistry.txt` (the
    canonical registry).  Pre- and post-AR remediation
    columns documenting the AR.5 / AR.6 pinning history.
  * Per-constructor description: precondition, witnesses,
    state effect.
  * Same treatment for `Event` constructors.

**Cross-reference.**  AR.5 / AR.6 regression tests pin
indices mechanically; table here is descriptive only.

**Effort.**  ~1 engineer-day.

#### WG.1.e — §15.4 Bridge state + accounting equation

**Content sketch.**

  * `BridgeState` type definition (consumed deposits, pending
    withdrawals, escrow ledger model).
  * Per-action delta theorems (`deposit_delta_*`,
    `withdraw_delta_*`, etc.; cross-reference
    `LegalKernel/Bridge/Accounting.lean`).
  * Chain-level identities §7.6.4 / §7.6.5 with the
    `BridgeReachable` predicate (cross-reference
    `docs/planning/chain_level_accounting_plan.md` for the CA
    workstream that lifts these to inductive theorems).

**Effort.**  ~0.5 engineer-day.

#### WG.1.f — §15.5 Withdrawal-proof scheme

**Content sketch.**

  * SMT depth-64 construction (different from the SC
    workstream's depth-256 *cell* proofs; the withdrawal SMT
    is depth-64 because the `WithdrawalId` key space is
    64-bit).
  * `verifyProof_complete` and `verifyProof_sound` theorems.
  * L1 verifier (Solidity); cross-stack equivalence.

**Effort.**  ~0.5 engineer-day.

#### WG.1.g — §15.6 Dispute-pipeline integration

**Content sketch.**

  * Bridge actions appear in the dispute pipeline like any
    other action.
  * Verdict semantics for `disputeWithdraw`,
    `disputeBridgeRefund`, etc.
  * Cross-reference `LegalKernel/Disputes/` modules.

**Effort.**  ~0.5 engineer-day.

#### WG.1.h — §15.7 EIP-712 signing surface

**Content sketch.**

  * Domain separator definition (chainId, version, name,
    deploymentId).
  * Struct hash construction for each signed payload.
  * Signature normalisation (low-s convention).
  * `eip712Wrap_injective` theorem.

**Effort.**  ~0.5 engineer-day.

#### WG.1.i — §15.8 Solidity contract surface

**Content sketch.**

  * The 10 contracts + 5 libraries inventory (pull from
    `solidity/README.md`).
  * Immutability discipline: no proxies, no admin, no
    `Pausable`, all parameters `immutable`.
  * Two-reviewer policy for Solidity changes.

**Effort.**  ~0.5 engineer-day.

#### WG.1.j — §15.9 Cross-stack verification corpus

**Content sketch.**

  * Corpus structure: `(input, Lean output, Solidity output)`
    triples; CI gate runs both sides and asserts equality.
  * Workstream-F design: F.1.x equivalence suite.
  * Future extensions (SC SMT-cell-proof corpus, RH Rust
    crypto corpus).

**Effort.**  ~0.5 engineer-day.

#### WG.1.k — §15.10 Non-goals + v2 deferrals

**Content sketch.**

Inherit the 11 deferrals from
`ethereum_integration_plan.md` §2.2 verbatim, with cross-
references:

  1. ActorId widening to 20 bytes.
  2. ZK proofs of `apply_admissible` (cross-ref
    `phase_7_plan.md` P7.C).
  3. Bisection dispute games (partially closed by
    Workstream H).
  4. ERC-4337 account abstraction.
  5. Cross-rollup interop.
  6. Native ETH gas market.
  7. Sequencer decentralisation (cross-ref `open_questions.md`
    OQ-H-2).
  8. L1 escape hatch (`forceWithdraw`).
  9. `preconditionFalse` / `oracleMisreported` Solidity
    variants.
  10. Multi-resource bridges.
  11. DAO governance for tunable parameters (cross-ref
     `parameterized_laws_landing_plan.md`).

**Effort.**  ~0.5 engineer-day.

#### WG.1.l — TOC update + cross-reference pass

**Activity.**

  1. Update GENESIS_PLAN's top-of-document table of contents.
  2. If WG.1.a chose renumber-(a): walk every existing
    `§15B` cross-reference in source (CLAUDE.md, plans,
    audit docs, `.lean` files) and update to `§16`.  This is
    a substantial grep-and-replace pass.
  3. Validate: re-grep all cross-references; ensure every
    `§N.M` reference resolves.

**Effort.**  ~1 engineer-day (or ~2 days if renumber-(a)).

#### WG.1.m — Two-reviewer review pass

**Activity.**

  1. PR description names two reviewers explicitly per
    §14.4 Genesis-Plan amendment rule.
  2. Reviewers walk the entire amendment; each reviewer
    signs off.
  3. Address review comments via follow-up commits in the
    same PR (do not amend).

**Effort.**  ~1 engineer-day of author time; ~2 engineer-
days of review time (cross-charged to reviewers).

---

### WG.1 — Rolled-up

  * WG.1.a – WG.1.m all individually completed within the
    single WG.1 PR.
  * **Aggregate effort:** ~9 engineer-days (revised up from
    5–7; decomposition surfaced the cross-reference pass and
    review cycle).

**Acceptance criteria.**

  * §15 chapter lands; all 10 sub-sections present.
  * Two reviewers sign off.
  * No PR / session URL slip-throughs (CLAUDE.md
    "Pull-request authoring policy" applies in spirit to
    documentation prose too).
  * Every cross-reference resolves on a follow-up grep.

---

### WG.2 — README + CLAUDE.md status updates

**Finding map.**  E-G consistency deliverable.

**Scope.**  `README.md`, `CLAUDE.md`.

**Implementation steps.**

  1. **README.md updates:**
     - "Phase and workstream status" table: add explicit "E-G"
       row showing "Complete".
     - "How correctness is enforced" section: cite the new
       GENESIS_PLAN §15.
     - "Headline theorems" table: ensure every Ethereum
       headline theorem is listed (cross-check against the
       §15 amendment).
     - Bump README's build-tag display to match current
       `LegalKernel.lean:285`.  As of audit date, README shows
       `canon-fault-proof-migration` but the code has
       `canon-audit-remediation`; WG.2 must update this
       (separate from any future EI build-tag bump).
     - Update test count if drifted significantly.
  2. **CLAUDE.md updates:**
     - "Phase and workstream status" sub-table: E-G from "Not
       started" to "Complete".
     - "Documentation rules" section: keep canonical
       ownership pointing to GENESIS_PLAN.md §15.
     - Update "Current development status" if any new
       deferrals or open items were introduced (none expected;
       WG is a documentation pass).

**Acceptance criteria.**

  * README build-tag matches `LegalKernel.lean:285`.
  * CLAUDE.md E-G row says "Complete".
  * Both files reference GENESIS_PLAN §15.
  * No session URLs / process tokens in the prose.

**Reviewer checklist.**

  * Build tag in README equals `kernelBuildTag` in
    `LegalKernel.lean:285`.
  * CLAUDE.md phase table fully consistent with README.
  * No phantom references to closed deferrals.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

---

### WG.3 — ABI document: new §12 "Ethereum ABI surfaces"

**Finding map.**  E-G ABI documentation.

**Scope.**  `docs/abi.md`.

**Implementation steps.**

  1. Append §12 with sub-sections:
     - **§12.1 Action constructor encodings** (indices 12–14;
       confirm via `Encoding/Action.lean` and AR.5 regression
       tests).
     - **§12.2 Event constructor encodings** (indices 9–10).
     - **§12.3 BridgeState CBE.**
     - **§12.4 PendingWithdrawal CBE.**
     - **§12.5 WithdrawalProof CBE.**
     - **§12.6 Bridge-actor ActorId 0 reservation.**
     - **§12.7 keccak256 trailer format.**
     - **§12.8 Contract event ABIs** (Solidity-emitted events
       with their Lean `Event` translation).
  2. Cross-reference §12 from GENESIS_PLAN §15 and from
    `solidity/README.md`.

**Acceptance criteria.**

  * All Ethereum-relevant ABIs documented.
  * Constructor indices match the AR.5 / AR.6 regression
    fixtures.
  * Solidity event ABIs match `solidity/src/contracts/*.sol`.

**Reviewer checklist.**

  * Cross-stack equivalence implied by the ABI is reflected
    in the E-F fixture corpus.
  * No phantom constructors (every index has a corresponding
    `Action` / `Event` variant).

**Risk.**  Low.

**Effort.**  ~2 engineer-days.

---

### WG.4 — Extraction notes: new trust assumptions

**Finding map.**  E-G trust assumption catalogue.

**Scope.**  `docs/extraction_notes.md` §2.

**Implementation steps.**

  1. For each of the five Ethereum trust assumptions, add a
    `trust_assumption_X.Y` block:
     - **TA-2.1 EUF-CMA secp256k1.**  Used by `Verify` opaque
       in deployments that select secp256k1.  Runtime adaptor:
       `runtime/canon-verify-secp256k1`.
     - **TA-2.2 keccak256 collision-resistance.**  Used by
       `hashBytes` in Ethereum deployments.  Runtime adaptor:
       `runtime/canon-hash-keccak256`.
     - **TA-2.3 L1 finality.**  Used by withdrawal-proof
       finalisation (`isFinalised_monotonic_in_currentBlock`).
       12-block confirmation depth is the deployment default.
     - **TA-2.4 Solidity correctness.**  The cross-stack
       fixture corpus is the operational defence; pin the
       solidity compiler version.
     - **TA-2.5 EIP-1271 correctness.**  Used by smart-contract
       wallet support; the verifier delegates to the wallet's
       `isValidSignature` callback.
  2. Update the trust-assumption summary at the top of
    `extraction_notes.md`.

**Acceptance criteria.**

  * Five new TA entries.
  * Cross-references to the relevant Lean theorems and Rust
    adaptor crates.
  * Each TA names its specific Lean opaque / @[extern]
    swap-point.

**Reviewer checklist.**

  * No duplication with the existing §1 trust assumptions
    (Verify, hashBytes).
  * Each TA's deployment-scope is precise.

**Risk.**  Low.

**Effort.**  ~1–2 engineer-days.

---

### WG.5 — Std-dependency audit refresh + `tcb_allowlist.txt`

**Finding map.**  E-G TCB-import audit.

**Scope.**  `docs/std_dependencies.md`, `tcb_allowlist.txt`.

**Implementation steps.**

  1. Re-run `lake exe tcb_audit` and capture the import set.
  2. Compare against `tcb_allowlist.txt`.  Any bridge-module
    imports not on the allowlist must either:
     (a) be added to the allowlist (with reviewer sign-off; this
       expands the TCB surface), or
     (b) be replaced by a non-TCB equivalent.
  3. Update `docs/std_dependencies.md` with any new
    Std-library lemmas the bridge modules consume.
  4. Audit the `Tools.Common.tcbInternalImports` enumeration
    in `Tools/Common.lean`: each entry should still be a TCB-
    core module.

**Acceptance criteria.**

  * `lake exe tcb_audit` is green.
  * `docs/std_dependencies.md` lists every Std lemma the TCB
    consumes (no orphaned entries).
  * No new `tcb_allowlist.txt` entries unless reviewer-
    justified.

**Reviewer checklist.**

  * Each allowlist addition (if any) is documented in the PR
    body.
  * `std_dependencies.md` is byte-stable across re-audit (no
    drift due to formatting).
  * Two reviewers if `tcb_allowlist.txt` is changed.

**Risk.**  Low-medium.  An allowlist change is a TCB-touching
event and triggers the two-reviewer gate even though no `.lean`
file in the TCB-core is touched.

**Effort.**  ~1 engineer-day.

---

## §5 Sequencing and PR structure

```
PR-1 (WG.1)        Genesis Plan §15 amendment              (2 reviewers)
PR-2 (WG.3)        abi.md §12                              (1 reviewer)
PR-3 (WG.4)        extraction_notes §2                     (1 reviewer)
PR-4 (WG.2)        README + CLAUDE.md                      (1 reviewer)
PR-5 (WG.5)        tcb_allowlist + std_dependencies        (2 reviewers if allowlist changes)
```

WG.1 first (substantive content); the others reference it.

## §6 Quality gates

  * `lake build` and `lake test` remain green (no source
    change expected).
  * `lake exe tcb_audit` green (WG.5).
  * `lake exe deferral_audit` green (no new forbidden phrases
    introduced in `.lean` files; the audit doesn't scan `.md`
    files but `.lean` docstrings may be edited).
  * For WG.1 + WG.5: two reviewers per §14.4 / §13.6.

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GENESIS_PLAN §15 chapter conflicts with existing §15B label | High | Medium | Pre-audit (WG.1 step 1); explicitly choose append vs renumber |
| Cross-references to file:line drift after a future PR | Medium | Low | Use section identifiers (§15.5) instead of line numbers where possible |
| Two-reviewer rule slips for WG.1 | Low | High | PR title must say "Genesis Plan amendment"; CODEOWNERS will request the second reviewer |
| WG.5 surfaces an un-allowlisted bridge import | Medium | Medium | Either justify the addition or refactor; WG.5 is the right place to find this |
| WG.2 misses the stale README build-tag (separate from any later EI bump) | Medium | Low | Verification step: `grep kernelBuildTag README.md` matches `LegalKernel.lean:285` |

## §8 Acceptance criteria

WG is **complete** when:

  1. GENESIS_PLAN.md ships chapter §15 covering the eleven
    sub-sections of §15 above; two reviewers signed off.
  2. README.md and CLAUDE.md show "E-G | complete" in the phase
    status table.
  3. README.md build-tag matches `LegalKernel.lean:285`.
  4. `docs/abi.md` §12 is complete with all Ethereum surfaces.
  5. `docs/extraction_notes.md` §2 documents the five
    Ethereum trust assumptions.
  6. `docs/std_dependencies.md` is current; `tcb_allowlist.txt`
    is current; `lake exe tcb_audit` is green.
  7. The CLAUDE.md "Phase and workstream status" section moves
    E-G from "Not started" to "Complete".

## §9 Out-of-scope items

  * **Genesis Plan §15B "Fault-Proof Migration" rewrite.**
    Already shipped; WG does not re-audit.
  * **Rust integration documentation.**  Owned by
    `rust_host_runtime_plan.md`.
  * **`solidity/README.md` rewrite.**  Operator-facing
    documentation, owned separately.
  * **EIP-1271 v2 (recursive cross-contract auth).**  Out of
    scope for the v1 documentation; v2 specifics are a future
    workstream.
  * **Deployment runbooks for the bridge.**  Operator team.

## §10 References

  * `docs/planning/ethereum_integration_plan.md` — the per-workstream
    plan that E-A through E-F implemented.
  * `docs/audits/08-bridge.md` — audit notes for the bridge
    modules.
  * `LegalKernel/Bridge/*.lean` — Lean bridge surfaces.
  * `solidity/src/contracts/*.sol` — Solidity bridge surfaces.

---

**End of plan.**  Landing WG retires the project's only
"Not started" workstream and produces a single canonical
narrative for the Ethereum integration.
