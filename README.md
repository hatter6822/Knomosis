<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon — A Societal Kernel

**Version:** v0.1.0 &nbsp;·&nbsp; **Build tag:** `canon-lex-m3-manifests`
&nbsp;·&nbsp; **License:** GPL-3.0

Canon is a **proof-carrying state-transition system** built in Lean 4.
The kernel does not say *what* is legal; it defines *what it means*
for a state change to be legal, and the build mechanically rejects
everything else. Specific rules — transfers, mints, rewards, signed
actions, deposits, withdrawals, disputes, actor-scoped policies — are
first-class values that compose with proof obligations the type
checker will not accept without discharge.

The result is a tiny, parametric core that gives every deployment
four type-level guarantees by construction: **determinism**, **no
silent illegality**, **refinement of executable to specification**,
and **inductive preservation of any invariant** proved against the
abstract transition interface. On top of that core, Canon ships an
authority layer with replay-impossible signed actions, a canonical
binary encoding, a crash-consistent persistent log with byte-identical
replay auditor, a four-stage dispute pipeline with type-level Stage-3
enforcement, an Ethereum-anchored bridge with sparse-Merkle-tree
withdrawal proofs, actor-scoped local policies, and a full law-
declaration language ("Lex") with deployment manifests, semantic-
diff tooling, and codegen.

The full architectural and mathematical blueprint is
[`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md). Start there for the
formal model, threat model, and phased roadmap.

## Status at a glance

| Metric                                | Value                                                                  |
|---------------------------------------|------------------------------------------------------------------------|
| Project version                       | **v0.1.0**                                                             |
| Lean toolchain                        | `leanprover/lean4:v4.29.1` (pinned in `lean-toolchain`)                |
| Trusted core (TCB)                    | `LegalKernel/Kernel.lean` + `LegalKernel/RBMapLemmas.lean`             |
| Custom axioms                         | **0** — every theorem `#print axioms` to the three Lean built-ins      |
| `sorry` in TCB                        | **0**, mechanically enforced (`lake exe count_sorries`)                |
| External Lake dependencies            | **0** — Lean core only, no Mathlib, no batteries                       |
| Lean tests                            | **1 596** across **89** suites (`lake test`)                           |
| Solidity tests                        | **191 passing + 8 conditionally-skipped** across **16** suites         |
| Type-level guarantees catalogued      | **221** theorems (full table in [`CLAUDE.md`](CLAUDE.md))              |
| Build tag (in `LegalKernel.lean`)     | `canon-lex-m3-manifests`                                               |
| Audit binaries (CI-gating)            | `count_sorries`, `tcb_audit`, `stub_audit`, `lex_lint`, `lex_codegen`  |

A green CI run on `lake build`, `lake test`, and the audit binaries
above is the authoritative signal that all phase-acceptance criteria
still hold. The two trusted-core files require **two reviewers** per
PR (Genesis Plan §13.6); non-TCB modules require one.

## Novel design properties

Canon's distinguishing commitments — what the build mechanically
enforces that comparable systems leave to convention or audit. Every
item below is grounded in a Lean theorem the build will not accept
with a `sorry`; see [Headline theorems](#headline-theorems) for direct
references.

1. **Legality is a type, not a convention.** A `Transition` carries
   a `Prop`-valued precondition, a constructive `Decidable`
   witness, and a total state transformer. `step_impl` only
   advances state when the witness resolves; reading the kernel
   never depends on classical logic.
2. **Tiny TCB, three-axiom proof discipline.** The trusted core is
   two modules. Every kernel theorem `#print axioms` reduces to
   exactly `[propext, Classical.choice, Quot.sound]`. The only
   `opaque` declarations (`Verify`, `signingInput`) model
   deployment-supplied cryptography and surface as trust
   assumptions, not Lean axioms.
3. **Type-level economic firewalls.** `IsConservative` and
   `IsMonotonic` are typeclasses. A `ConservativeLawSet` or
   `MonotonicLawSet` deployment will not elaborate if a non-
   conservative or supply-destroying law is on its list, because
   no instance exists. `mint_not_conservative`,
   `burn_not_conservative`, and `burn_not_monotonic` ship as the
   **negative witnesses** that make the firewall sound.
4. **Replay protection as a Lean theorem.** `replay_impossible`
   proves that a successfully applied signed action is no longer
   admissible at the post-state; `nonce_uniqueness` proves no two
   distinct admissible actions by the same signer share a nonce.
   Both follow from `expectsNonce_strict_mono` over a per-actor
   monotone nonce ledger.
5. **Canonical, injective serialisation with domain separation.**
   Every `Action`, `SignedAction`, `State`, and `ExtendedState`
   has a strictly canonical CBE (Canon Binary Encoding) byte form
   with mechanically-proved round-trip and injectivity. The
   decoder rejects non-canonical inputs (unsorted / duplicate map
   keys). `signInput` prefixes a deployment-ID hash so signatures
   cannot replay across deployments.
6. **Crash-consistent log + byte-identical replay.** The on-disk
   log is an append-only frame stream with a per-frame integrity
   trailer. On startup the runtime walks the log frame-by-frame
   and truncates the partial tail of any torn write. The
   standalone `canon-replay` binary reproduces the runtime's
   `StateHash` byte-for-byte from the same log on a separate
   machine with no shared state.
7. **Pure dispute pipeline with type-level Stage-3 enforcement.**
   The four-stage pipeline (`fileDispute → checkEvidence →
   proposeVerdict → applyVerdict`) consists entirely of pure Lean
   functions over a closed inductive of five claim variants.
   Different adjudicators reach the same verdict on the same log.
   The safe `applyVerdict` entry point requires a
   `VerdictPassedStage3` propositional witness; every error path
   is mechanically unreachable, certified by three corollary
   theorems.
8. **Ethereum bridge with proven-correct withdrawal proofs.** A
   height-64 sparse Merkle tree over `BridgeState.pending`
   produces a 32-byte withdrawal root. `verifyProof_complete` is
   unconditional; `verifyProof_sound` holds under
   collision-resistance and uniform-output-size hypotheses on the
   hash function. The L1 contracts (`solidity/`) port the same
   verifier line-for-line and ship deployment-immutable (no
   proxies, no admin, no `Pausable`); recovery uses the dispute
   pipeline plus an attested-handoff `CanonMigration.sol`
   mechanism.
9. **Actor-scoped policies (Workstream LP).** Each actor can
   declare a `LocalPolicy` (deny tags / require recipient ∈ set /
   cap amount) constraining their *own* outgoing actions, with a
   structural meta-action exemption that prevents lockout. The
   sixth admissibility conjunct enforces it; the
   `localPolicy_meta_action_independent` theorem certifies the
   exemption mechanically.
10. **Lex law-declaration language with deployment manifests.**
    A high-level surface (`lexlaw`) elaborates law declarations
    into Lean `Transition`s; the `deployment` macro emits
    deterministic manifest hashes. Governance tooling (`lex_diff`
    classifies version bumps as `patch` / `minor` / `major` and
    enforces refinement-proof discipline; `lex_format`
    canonicalises clause order). All 17 kernel-built-in laws ship
    a Lex re-expression that is byte-equivalent to the hand-
    written form (verified at elaboration time via `rfl`).

## Performance and engineering posture

Canon is research-stage software. The build mechanically guarantees
the following on every commit:

| Posture                                       | Mechanism                                       |
|-----------------------------------------------|-------------------------------------------------|
| 1 596 Lean tests across 89 suites pass        | `lake test` (`Tests.lean` driver)               |
| 191 Solidity tests across 16 suites pass      | `forge test` (in `solidity/`)                   |
| Zero `sorry` in any kernel-TCB module         | `lake exe count_sorries`                        |
| TCB imports stay on the allowlist             | `lake exe tcb_audit`                            |
| Stub / placeholder bodies flagged             | `lake exe stub_audit`                           |
| Lex registry well-formed + sidecars consistent| `lake exe lex_lint`                             |
| Generated codegen is byte-stable              | `lake exe lex_codegen --check`                  |
| Auto-generated property tests stay in sync    | `lake exe lex_codegen --gen-property-tests --check` |
| Every public surface has a `/-- … -/` doc     | `linter.missingDocs := true` (lakefile)         |
| No silent universe / type-variable creation   | `autoImplicit := false` (lakefile)              |
| No dead bindings                              | `linter.unusedVariables := true`                |
| No build warnings                             | CI strict-warnings gate (Audit-3.7)             |
| Build, tests, and audits run on every PR      | `.github/workflows/ci.yml`                      |

CI blocks merges on any of the gates above. Every phase post-
implementation has been hardened by one or more dedicated audit
passes; see [`CLAUDE.md`](CLAUDE.md) for the full per-audit
changelog.

### Determinism and decidability

Canon's runtime guarantees are stated as **byte-identical**, not
"semantically equivalent". `replay_deterministic`,
`hashBytes_deterministic`, `state_encode_deterministic`, and
`signInput_deterministic` together imply: any two replicas given
the same `(genesis, log)` produce the same final state hash, the
same encoded state bytes, the same per-action sign-input bytes,
and the same content-hash bytes — across architectures.

### Hash-function swap-point

The Lean fallback is FNV-1a-64 (deterministic, 32-byte output via
zero-padding for forward compatibility with the production
BLAKE3 / keccak256 swap). The fallback is **fail-fast** at the CLI
boundary: `canon-replay` aborts with `SNAPSHOT_DECODE_ERROR` rather
than silently proceeding when the linked hash function is the
fallback (`--allow-fallback-hash` to opt in for testing). See
[`docs/abi.md`](docs/abi.md) §11.

### Trust assumptions

Canon's authority and bridge guarantees are conditional on two
deployment-supplied opaque declarations:

1. **`Verify` is EUF-CMA secure** (Phase 3 WU 3.4). The kernel's
   `replay_impossible` and `nonce_uniqueness` theorems hold against
   any deployment-supplied signature scheme that satisfies EUF-CMA;
   the runtime adaptor (Rust crate `canon-verify-secp256k1`,
   deferred follow-up) supplies the production binding.
2. **The hash function is collision-resistant** (Phase 5 WU 5.1 +
   Workstream-D). `verifyProof_sound` and `eip712Wrap_injective`
   hold under `CollisionFree H`; the production keccak256 binding
   (Rust crate `canon-hash-keccak256`, deferred follow-up) supplies
   the witness.

These are *trust assumptions*, not Lean axioms. `#print axioms` on
every kernel theorem returns exactly the three Lean built-ins.

## Phase status

| Phase / Workstream | Title                                | Status                                  |
|--------------------|--------------------------------------|-----------------------------------------|
| 0                  | Foundations (kernel skeleton + CI)   | Complete                                |
| 1                  | Kernel completion (RBMap, §4.3, §4.9)| Complete                                |
| 2                  | Economic invariants (conservation)   | Complete                                |
| 3                  | Authority layer (signed actions)     | Complete                                |
| 4-prelude          | Positive-incentive mechanisms        | Complete                                |
| 4                  | DSL and serialisation (CBE)          | Complete                                |
| 5                  | Runtime and extraction (Lean side)   | Complete (Rust host deferred)           |
| 6                  | Disputes and adjudication            | Complete                                |
| 6-amend            | Phase-6 incentive integration        | Complete                                |
| Audit-3            | Cross-cutting hardening pass         | Complete                                |
| E-A                | Ethereum: cryptographic adaptors     | Complete (Lean side; Rust crate deferred)|
| E-B                | Ethereum: identity and authority     | Complete (Lean side; Rust ingestor deferred)|
| E-C                | Ethereum: bridge laws                | Complete (Lean side)                    |
| E-D                | Ethereum: withdrawal proofs          | Complete (Lean side; CLI ships)         |
| E-E                | Ethereum: Solidity contracts         | Complete (191 forge tests)              |
| E-F                | Ethereum: cross-stack verification   | Complete (656 fixtures + goldens + testnet script + props) |
| LP                 | Actor-scoped policies                | Complete (Lean side; Solidity mirror future) |
| LX-M1              | Lex: macro skeleton + synthesizer    | Complete                                |
| LX-M2              | Lex: re-express 17 kernel laws       | Complete (byte-equivalent at `rfl`)     |
| LX-M3              | Lex: deployment manifests + governance| Complete (`lex_diff`, `lex_format`, autogen) |
| E-G                | Ethereum: docs + amendment           | Not started                             |
| 7                  | Advanced capabilities                | Not started                             |

A full per-WU changelog (every audit, deviation, and amendment) lives
in [`CLAUDE.md`](CLAUDE.md). The canonical phase scoping lives in
[`docs/GENESIS_PLAN.md` §12](docs/GENESIS_PLAN.md). The Ethereum
workstream scoping lives in
[`docs/ethereum_integration_plan.md`](docs/ethereum_integration_plan.md).
The Lex implementation plan lives in
[`docs/lex_implementation_plan.md`](docs/lex_implementation_plan.md).

## Quickstart

Canon depends only on a pinned Lean 4 toolchain — no Mathlib, no
external Lake packages. The toolchain version is read from
`lean-toolchain` (currently `leanprover/lean4:v4.29.1`).

```bash
# Recommended: SHA-256-verified setup script.
./scripts/setup.sh           # idempotent; pins toolchain integrity
./scripts/setup.sh --build   # ... and runs `lake build` after setup

# Manual alternative (skips integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands (after setup):
source ~/.elan/env
lake build              # full project (default target)
lake test               # 1 596 tests across 89 suites

# Audit / CI gates (each is a separate `lake exe` binary):
lake exe count_sorries          # zero-sorry TCB gate
lake exe tcb_audit              # TCB allowlist gate
lake exe stub_audit             # placeholder-stub detection gate
lake exe lex_lint               # Lex registry + sidecar consistency
lake exe lex_codegen --check    # Lex codegen byte-stability gate

# Phase-5 runtime CLI smoke test:
.lake/build/bin/canon info                       # build tag + phase
.lake/build/bin/canon bootstrap /tmp/test.log    # init an empty log
.lake/build/bin/canon-replay /tmp/test.log       # reproduce state hash

# Workstream-D withdrawal-proof CLI:
.lake/build/bin/canon withdrawal-proof SNAP_PATH WITHDRAWAL_ID

# Lex governance tooling (LX-M3):
.lake/build/bin/lex_diff <git-ref-a> <git-ref-b>   # semantic diff + bump classify
.lake/build/bin/lex_diff --git HEAD~1 HEAD          # ... using git refs directly
.lake/build/bin/lex_format <file.lean>              # pretty-print + canonicalise

# Workstream E (Solidity contracts) — see solidity/README.md
cd solidity && ./scripts/vendor-deps.sh   # one-time: vendor OZ + forge-std
cd solidity && forge build                # compile via_ir + solc 0.8.20
cd solidity && forge test                 # 191 tests + 8 conditionally-skipped
cd solidity && make testnet-acceptance-dryrun  # Workstream F.3 local fork dry-run
```

### Targeted module builds

For fast feedback while developing in a single layer, build that
layer alone rather than the full project:

```bash
lake build LegalKernel.Kernel              # TCB core
lake build LegalKernel.RBMapLemmas         # §8.3 fold lemmas
lake build LegalKernel.Conservation        # economic-invariants framework
lake build LegalKernel.Laws.Transfer       # one law (hand-written + Lex)
lake build LegalKernel.Authority.SignedAction
lake build LegalKernel.Encoding.State
lake build LegalKernel.Runtime.Loop
lake build LegalKernel.Disputes.Verdict
lake build LegalKernel.Bridge.WithdrawalRoot
lake build Lex.DSL.Law                     # Lex `lexlaw` macro
lake build Lex.DSL.Deployment              # Lex `deployment` macro
lake build Lex                             # Lex umbrella (all DSL surface)
lake build Deployments.Examples.UsdClearing  # LX-M3 worked example
```

## Repository layout

```
canon/
├── LegalKernel.lean        — umbrella import; downstream consumers use this.
├── LegalKernel/
│   ├── Kernel.lean         — §4.12 trusted core (TCB).
│   ├── RBMapLemmas.lean    — §8.3 RBMap proof library (TCB).
│   ├── Conservation.lean   — TotalSupply, IsConservative, IsMonotonic,
│   │                          ConservativeLawSet / MonotonicLawSet,
│   │                          plus Lex-tier classification typeclasses
│   │                          (LocalTo, FreezePreserving, FreezePreservingLawSet).
│   ├── Laws/               — one file per deployable law (hand-written
│   │                          form + co-located Lex re-expression):
│   │                          Transfer, Mint, Burn, Freeze, Reward,
│   │                          DistributeOthers, ProportionalDilute,
│   │                          Deposit, Withdraw; plus 7 Lex-only laws
│   │                          (ReplaceKey, RegisterIdentity, Dispute
│   │                          pipeline ×4, LocalPolicy ×2).  The Lex
│   │                          M1 demonstration law (ExampleLex) lives
│   │                          under `Lex/Examples/`.
│   ├── Authority/          — Phase-3 signed-action layer:
│   │                          Crypto (Verify), Action,
│   │                          Identity (KeyRegistry + AuthorityPolicy),
│   │                          Nonce, SignedAction (Admissible, with
│   │                          replay_impossible);  LocalPolicy + LocalPolicy
│   │                          Semantics (Workstream LP).
│   ├── Encoding/           — Phase-4 CBE byte codec:
│   │                          CBOR (head pair), Encodable (typeclass +
│   │                          primitives), Action, SignedAction, State,
│   │                          SignInput (domain separation), Disputes,
│   │                          LocalPolicy.
│   ├── DSL/                — base law DSL: Law (Phase-4 `Law.mk`),
│   │                          LawSyntax (legacy `law` macro).  The Lex
│   │                          DSL extension (`lexlaw`, `lex_*` clauses,
│   │                          properties, deployments, impl calculus)
│   │                          lives under the top-level `Lex/DSL/`.
│   ├── Events/             — Phase-5 deployment-facing event log:
│   │                          Types (13 ctors incl. Phase-6, Workstream-C,
│   │                          Workstream-LP), Extract (deterministic emission).
│   ├── Runtime/            — Phase-5 runtime infrastructure:
│   │                          Hash (FNV-1a-64 / swap-point), LogFile,
│   │                          Replay, Snapshot, AttestedSnapshot, Loop.
│   ├── Disputes/           — Phase-6 §8.4 dispute pipeline:
│   │                          Types, Filing, Evidence, Verdict;
│   │                          incentive amendment: LawClassification,
│   │                          MonotonicDeployment, Rewards, Staking.
│   ├── LocalPolicy/        — Workstream-LP classification:
│   │                          LawClassification (IsConservative + IsMonotonic
│   │                          for declareLocalPolicy / revokeLocalPolicy).
│   └── Bridge/             — Ethereum integration (Workstreams A – D):
│                              VerifyAdaptor, HashAdaptor, Eip712 (A);
│                              AddressBook, BridgeActor, Ingest (B);
│                              State, Admissible, Accounting (C);
│                              WithdrawalRoot, WithdrawalProof,
│                              Finalisation (D).
├── LegalKernel/Test/       — 89 test suites mirroring the source layout
│                              (1 596 tests total; see CLAUDE.md for the
│                              per-suite breakdown).
├── Deployments/Examples/   — LX-M3 worked-example deployments:
│                              UsdClearing (parameterless wrappers + the
│                              `monotonic_law_set [all_laws]` claim).
├── Tools/                  — non-Lex audit binaries (lake exe …):
│   ├── Common.lean         — shared TCB constants.
│   ├── TcbAudit.lean       — enforces tcb_allowlist.txt (WU 1.11).
│   ├── CountSorries.lean   — enforces zero `sorry` in TCB (WU 1.12).
│   ├── StubAudit.lean      — enforces no placeholder stubs (Audit-3.8).
│   ├── NamingAudit.lean    — enforces content-name discipline.
│   └── DeferralAudit.lean  — enforces no-deferrals policy.
├── Lex/                    — Workstream LX: the Lex programming language.
│   ├── IndexRegistry.txt   — frozen action-index registry (LX.1).
│   ├── DSL/                — Lex DSL macros (`lex_law`, `lexlaw`, properties,
│   │                          deployments): PreGrammar, ImplCalculus,
│   │                          ImplLowering, Events, Shim, Law, Property,
│   │                          Deployment.
│   ├── Tools/              — Lex audit-binary libraries (Common, Lint,
│   │                          Codegen, Diff, Format).
│   ├── Bin/                — Lake `lean_exe` entry-point wrappers (Lint,
│   │                          Codegen, Diff, Format).
│   ├── Inputs/             — codegen-input JSON sidecars + canonical
│   │                          manifest + property-test coverage file.
│   ├── Examples/           — Lex-only demonstration laws (ExampleLex).
│   └── Test/               — Lex test modules (DSL, Tools, Properties,
│                              AutoGenProperties, ExampleLex, M2).
├── Lex.lean                — umbrella module for the Lex language.
├── Main.lean               — Phase-5 `canon` runtime CLI.
├── Replay.lean             — Phase-5 `canon-replay` audit binary.
├── Tests.lean              — @[test_driver]; entry point for `lake test`.
├── lakefile.lean           — Lake config + strict lean options.
├── lean-toolchain          — pinned Lean version.
├── tcb_allowlist.txt       — TCB import allowlist (WU 1.11).
├── tools/
│   └── stub_allowlist.txt  — Audit-3.8 stub allowlist.
├── scripts/
│   └── setup.sh            — SHA-256-verified toolchain installer.
├── .github/workflows/
│   └── ci.yml              — CI gates (build, test, audits, no-warnings).
├── solidity/               — Workstream E: L1 contracts (immutable, no
│   │                          proxies, no admin, no `Pausable`).
│   ├── foundry.toml        — solc 0.8.20, via_ir, OZ remappings.
│   ├── src/contracts/      — 5 contracts: CanonBridge,
│   │                          CanonDisputeVerifier, CanonIdentityRegistry,
│   │                          CanonSequencerStake, CanonMigration.
│   ├── src/interfaces/     — matching interface files.
│   ├── src/lib/            — 4 cross-cutting libs: CBEDecode, SmtVerifier,
│   │                          CanonEip712, CREATE3.
│   ├── test/               — 191 forge tests + 8 conditionally-skipped
│   │                          across 16 suites (incl. F.1 cross-stack).
│   └── README.md           — day-to-day Solidity developer guide.
├── docs/                   — see Documentation map below.
├── CLAUDE.md               — engineering conventions (per-WU changelog,
│                              naming rules, audit history, contributor
│                              guidance for AI and human collaborators).
├── README.md               — this file.
└── LICENSE                 — GPL-3.0.
```

## Documentation map

The repository's design and engineering documentation lives in
[`docs/`](docs/). Each document has a single, sharp scope:

### Canonical design

| Document                                                                  | Scope                                                                               |
|---------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md)                             | **Canonical design.** Formal model, threat model, phased roadmap.                  |
| [`docs/ethereum_integration_plan.md`](docs/ethereum_integration_plan.md)   | Workstream plan for Workstreams A – G of the Ethereum integration.                 |
| [`docs/law_language_design.md`](docs/law_language_design.md)               | Design of the high-level law-authoring surface ("Lex").                            |
| [`docs/lex_implementation_plan.md`](docs/lex_implementation_plan.md)       | Engineering plan for Lex M1 / M2 / M3 milestones.                                  |
| [`docs/actor_scoped_policies_plan.md`](docs/actor_scoped_policies_plan.md) | Engineering plan for Workstream LP (`LocalPolicy`).                                |
| [`docs/parameterized_laws_plan.md`](docs/parameterized_laws_plan.md)       | Engineering plan for parameterised-law refinements.                                |
| [`docs/fault_proof_migration_plan.md`](docs/fault_proof_migration_plan.md) | Forward-looking plan for fault-proof / migration evolution.                        |

### Engineering reference

| Document                                                                  | Scope                                                                               |
|---------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| [`docs/economic_invariants.md`](docs/economic_invariants.md)              | Phase-2 + Phase-4-prelude design note: conservation, monotonicity, the firewalls.  |
| [`docs/decidability_discipline.md`](docs/decidability_discipline.md)      | The `decPre := fun _ => inferInstance` discipline (WU 1.6).                        |
| [`docs/std_dependencies.md`](docs/std_dependencies.md)                    | Per-toolchain-bump audit of every Lean-core lemma the TCB invokes (WU 1.13).       |
| [`docs/extraction_notes.md`](docs/extraction_notes.md)                    | What survives Lean's compilation pipeline into the runtime binary (WU 5.9).        |
| [`docs/abi.md`](docs/abi.md)                                              | On-disk frame format, hash trailer, CLI ABI (WU 5.10 + Phase-6 / LP / Bridge).     |
| [`docs/lex_amendment_walkthrough.md`](docs/lex_amendment_walkthrough.md)  | LX-M3: walked-through example of bumping a law version in the USD-clearing demo.   |
| [`solidity/README.md`](solidity/README.md)                                | Day-to-day developer guide for the L1 contracts.                                   |
| [`CLAUDE.md`](CLAUDE.md)                                                  | Engineering conventions, per-WU changelog, audit history, contributor rules.       |

When facts disagree across docs, the precedence is
**`GENESIS_PLAN.md` > workstream plans (Ethereum / Lex / LP) >
module docstrings > `CLAUDE.md` > `README.md` > everything else.**
Any PR that changes behaviour, theorems, or formalisation status
must update the canonical doc in the same PR (see CLAUDE.md
"Documentation rules").

## Reading order for new contributors

1. **Skim** [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md) §1 – §4
   for the formal model.
2. **Read** `LegalKernel/Kernel.lean` end-to-end — it is the §4.12
   listing in literal form, ~200 lines. Every kernel theorem in
   the [Headline theorems](#headline-theorems) table lives here.
3. **Pick a law** under `LegalKernel/Laws/` and read its
   precondition, `apply_impl`, and `IsConservative` /
   `IsMonotonic` instance to see how the typeclass firewalls
   compose. Then read its co-located `lexlaw` declaration to see
   the high-level surface.
4. **Pick a Bridge module** under `LegalKernel/Bridge/` to see how
   non-kernel infrastructure consumes the same proof discipline.
5. **Run** `lake test`; the test files under `LegalKernel/Test/`
   double as worked examples for every theorem.
6. **Read** `Deployments/Examples/UsdClearing.lean` and
   [`docs/lex_amendment_walkthrough.md`](docs/lex_amendment_walkthrough.md)
   for an end-to-end view of an actual deployment under the Lex
   surface plus the governance workflow.
7. **Read** [`CLAUDE.md`](CLAUDE.md) before making any change —
   it owns the engineering conventions, naming rules, and the
   two-reviewer gate for kernel-touching work.

## Headline theorems

The build will not accept any of these with a `sorry`, and `#print
axioms` on each returns only the three Lean built-ins. The full
table of **221 type-level guarantees** lives in
[`CLAUDE.md`](CLAUDE.md) ("Type-level design properties enforced");
this list is a curated subset.

| Theorem                                              | What it proves                                                | Where                                              |
|------------------------------------------------------|---------------------------------------------------------------|----------------------------------------------------|
| `impl_refines_spec`                                  | every executed step satisfies its relational spec             | `LegalKernel/Kernel.lean`                          |
| `impl_noop_if_not_pre`                               | failing the precondition leaves state unchanged               | `LegalKernel/Kernel.lean`                          |
| `invariant_preservation[_via_laws]`                  | inductive invariants hold across reachable states             | `LegalKernel/Kernel.lean`                          |
| `transfer_conserves`                                 | transfer preserves per-resource total supply (§4.11.1)        | `LegalKernel/Laws/Transfer.lean`                   |
| `total_supply_global[_via_law_set]`                  | per-resource conservation across reachable states (§5.3)      | `LegalKernel/Conservation.lean`                    |
| `total_supply_globally_nondecreasing`                | monotonic-law-set deployments cannot lose value               | `LegalKernel/Conservation.lean`                    |
| `proportionalDilute_distributed_le_totalReward`      | floor-division dust bound for proportional reward             | `LegalKernel/Laws/ProportionalDilute.lean`         |
| `Action.compile_injective`                           | distinct serialised actions are distinct compiled values      | `LegalKernel/Authority/Action.lean`                |
| `expectsNonce_strict_mono`                           | per-actor expected nonce strictly increases on advance        | `LegalKernel/Authority/Nonce.lean`                 |
| `nonce_uniqueness`                                   | no two admissible actions by the same signer share a nonce    | `LegalKernel/Authority/SignedAction.lean`          |
| `replay_impossible`                                  | a successfully applied signed action is not re-admissible     | `LegalKernel/Authority/SignedAction.lean`          |
| `localPolicy_meta_action_independent`                | LP meta-actions exempt from the actor's own policy (no lockout)| `LegalKernel/Authority/SignedAction.lean`         |
| `action_roundtrip`                                   | every Action's CBE encoding decodes back to itself            | `LegalKernel/Encoding/Action.lean`                 |
| `state_encode_deterministic`                         | equal `State` values produce equal canonical bytes            | `LegalKernel/Encoding/State.lean`                  |
| `signInput_deterministic`                            | equal sign-input args produce equal sign-input bytes (§8.8.5) | `LegalKernel/Encoding/SignInput.lean`              |
| `replay_deterministic`                               | equal `(genesis, log)` pairs produce equal replay outputs     | `LegalKernel/Runtime/Replay.lean`                  |
| `applyWithdraw_idempotent`                           | dispute withdrawal is idempotent on every status              | `LegalKernel/Disputes/Filing.lean`                 |
| `applyVerdict_under_witness_succeeds`                | safe `applyVerdict` is provably total under Stage-3 witness   | `LegalKernel/Disputes/Verdict.lean`                |
| `verifyProof_complete`                               | every populated withdrawal's canonical proof verifies (D.1.3) | `LegalKernel/Bridge/WithdrawalRoot.lean`           |
| `verifyProof_sound`                                  | a verifying proof matches the canonical construction (D.1.4)  | `LegalKernel/Bridge/WithdrawalRoot.lean`           |
| `eip712Wrap_injective`                               | EIP-712 wrap is injective under collision-freedom             | `LegalKernel/Bridge/Eip712.lean`                   |
| `bridgePolicy_rejects_withdraw`                      | the bridge actor cannot sign user withdrawals (§12.9 #33)     | `LegalKernel/Bridge/BridgeActor.lean`              |
| `disputable_monotonic_total_supply_nondecreasing`    | dispute-enabled monotonic deployments preserve non-decrease   | `LegalKernel/Disputes/MonotonicDeployment.lean`    |

## Contributing

Read [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md) end-to-end first.
Every change beyond the trivial must reference a work unit
(`WU x.y`) and follow the runbooks in §13.6 – §13.9. Kernel-touching
work units require **two reviewers**; deployment-infrastructure work
units (laws, authority, conservation, bridge, dispute pipeline,
local policies, Lex tooling) require one. See
[`CLAUDE.md`](CLAUDE.md) for the engineering conventions any human
or AI contributor must follow.

### Reporting issues

Canon is research-stage software. If you discover a logic bug in
the kernel module (e.g. a counterexample to `impl_noop_if_not_pre`,
or a state advance that bypasses the `if` in `step_impl`), open an
issue with the `kernel-soundness` label. Such reports gate any
in-flight PR; the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.

## License

Canon is released under the GNU General Public License, version 3.
See [LICENSE](LICENSE) for the full text.
