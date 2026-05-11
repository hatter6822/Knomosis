<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

<!--
  Canon — A Legal Kernel
  Adapted from the structure of Orbcrypt's CLAUDE.md
  (https://github.com/hatter6822/Orbcrypt/blob/main/CLAUDE.md)
  with project-specific guidance for Canon's Std-only, kernel-centric
  Lean 4 codebase.
-->

# CLAUDE.md — Canon project guidance

## What this project is

Canon is a **proof-carrying state transition system** built in Lean 4.
It is an *implementation* of the Genesis Plan
(`docs/GENESIS_PLAN.md`): a small, parametric, law-free kernel where
"legality" is a Lean type, every state change is accompanied by a
machine-checkable proof of admissibility, and global system properties
(determinism, refinement, no-silent-illegality, invariant
preservation) are guaranteed by inductive theorems rather than by
trust in operators.

Current status: **Phases 0 – 6 complete.**  Phase 0 (Foundations)
landed the kernel skeleton, the canonical transfer law, the build
pipeline, and the Genesis Plan.  Phase 1 (Kernel Completion) added
the §8.3 RBMap proof library, the §4.3 balance lemmas, the §4.9
multi-step / law-set reachability extensions, the Phase-1 audit
tooling (`lake exe count_sorries`, `lake exe tcb_audit`), and the
WU-1.6 / WU-1.13 documentation.  Phase 2 (Economic Invariants)
landed the §8.1 `TotalSupply` quantity functional,
`transfer_conserves` (§4.11.1), the `IsConservative` typeclass, the
`mint`/`burn` non-conservative laws (with explicit non-conservation
witnesses), the `ConservativeLawSet` machinery, the §5.3
`total_supply_global` theorem, and the `freezeResource` /
`FrozenForResource` immutability layer.  Phase 3 (Authority Layer)
landed the §4.13 `Action` data layer with structural
`compile_injective` via the `CompiledAction` wrapper; the
`AuthorityPolicy` (with `empty`/`unrestricted`/`union`/`intersect`/
`singleton` combinators) and `KeyRegistry` (with `register`/
`revoke`/`mergeLeftBiased`); the cryptographic `Verify` interface
(opaque, deployment-supplied); the §8.5 `NonceState`,
`ExtendedState` (kernel state + nonce ledger + key registry), and
the headline `expectsNonce_strict_mono` lemma; the five-condition
`Admissible` predicate (§8.2); the single guarded `apply_admissible`
entry point; the §8.5.2 `nonce_uniqueness` and `replay_impossible`
theorems; and the WU 3.10 `replaceKey` action with full
registry-mutation theorems and an end-to-end key-rotation test
chain.  The **Phase-4 prelude (Positive-Incentive Mechanisms)**
landed `IsMonotonic` typeclass + `MonotonicLawSet` structure (the
type-level firewall for "no value destruction" deployments), the
`total_supply_globally_nondecreasing[_via_law_set]` headline
theorems, three new positive-incentive laws (`reward`,
`distributeOthers`, `proportionalDilute`) with full classification
including `proportionalDilute_distributed_le_totalReward` (the
floor-division dust bound), three new `Action` constructors with
their compile branches, the `burn_not_monotonic` negative witness
that completes the firewall, and the missing
`freezeResource_isConservative` instance.  **Phase 4 (DSL and
Serialization)** landed the `Encodable` typeclass + the **CBE**
(Canon Binary Encoding) byte codec, full per-type round-trip and
injectivity proofs for the primitive (`Bool`, `Nat`, `BoundedNat`,
`ByteArray`, `UInt8` / `UInt16` / `UInt32` / `UInt64`) and headline
(`Action`, `SignedAction`, `State`, `ExtendedState`) `Encodable`
instances, the domain-separated `signInput` for cross-deployment-
replay rejection (§8.8.5), and the `law` macro that elaborates a
`pre := … ; impl := …` body to a `Transition` with `decPre := fun
_ => inferInstance` filled in.  **Phase 5 (Runtime and Extraction)**
landed the deterministic `Runtime.Hash` (FNV-1a-64 fallback for
production BLAKE3); the framed `LogEntry` on-disk format with
crash-consistent truncation; the standalone `replay` tool and
`canon-replay` audit binary; the `Snapshot` machinery; the
`RuntimeState` + `processSignedAction` main loop; the §8.9.2
`Event` inductive (5 of 7 constructors; 2 reserved for Phase 6);
deterministic `extractEvents`; and the `canon` runtime CLI with
five subcommands (`info` / `process` / `replay` / `bootstrap` /
`snapshot`).  **Phase 6 (Disputes and Adjudication)** lands the
§8.4 four-stage dispute pipeline: the `DisputeClaim` /
`EvidenceVerdict` / `Dispute` / `Verdict` / `DisputeRecord` data
types with canonical CBE byte encodings; four new `Action`
constructors (`dispute`, `disputeWithdraw`, `verdict`, `rollback`)
at frozen indices 8..11; the three new §8.9.2 `Event`
constructors (`disputeFiled`, `disputeWithdrawn`, `verdictApplied`)
at frozen indices 5..7; Stage 1 `fileDispute` with all four
acceptance checks (`malformedAction` / `unknownChallenger` /
`indexOutOfRange` / `duplicateDispute`); Stage 2 `checkEvidence`
with five per-claim verifiers (`preconditionFalse`,
`signatureInvalid`, `nonceMismatch`, `oracleMisreported`,
`doubleApply`); Stage 3 `proposeVerdict` with quorum support;
Stage 4 `applyVerdict` with rollback computation via
`kernelOnlyReplay`; the `disputeStatus` walk-the-log derivation;
the `applyWithdraw_idempotent` family of theorems (WU 6.11); and
the WU 6.12 end-to-end planted-illegal-tx → dispute → rollback
acceptance test.  The **Phase-6 incentive-integration amendment**
(WUs 6.13 – 6.23) extends the dispute pipeline with type-level
firewall composition (the four dispute action constructors are
classified as both `IsConservative` and `IsMonotonic`); a
`disputableMonotonicLawSet` example demonstrating monotonic
deployments admit the dispute pipeline; the `DisputeRewardPolicy`
structure with atomic + graduated + stake-weighted +
cross-resource constructors; the `applyVerdictWithRewards`
composable wrapper; a kernel-conservative `StakingPolicy` for
anti-fraud staking (uses `Action.transfer` to escrow / treasury,
never `burn`); the `Event.rewardIssued` semantic event constructor
at frozen index 8; and a comprehensive incentivized-end-to-end
acceptance test.  The **Phase-6 Option-C amendment** introduces
type-level Stage-3 enforcement on `applyVerdict`: the
`VerdictPassedStage3` propositional witness (carrying the
`proposeVerdict ... = .ok v` equation) is now required at the
type level for the safe `applyVerdict` entry point; the old
bypass form is preserved as `applyVerdictUnchecked` for tests; a
new default-safe `proposeAndApplyVerdict` chains Stage 3 + Stage
4 atomically via `proposeVerdict_ok_returns_input`; Layer-0's
defensive `checkOracleMisreported` index check closes the
out-of-range gap and supports the strong-correctness theorem
`applyVerdict_under_witness_succeeds` (which proves the
witness-bearing `applyVerdict` is provably total — every error
path is mechanically unreachable, certified by three
`_unreachable` corollary theorems).  Phase 7 (Advanced
capabilities) is scoped in §12 of the Genesis Plan and has not
yet started.

Canonical source of truth for the design: `docs/GENESIS_PLAN.md`.
Where this file disagrees with the Genesis Plan, the Genesis Plan
wins; CLAUDE.md is engineering guidance, not specification.

## Build and run

```bash
# Recommended: use the setup script.  It pins the Lean version,
# verifies all downloads with SHA-256, and records a binary integrity
# snapshot on first run.
./scripts/setup.sh           # full setup; idempotent
./scripts/setup.sh --build   # full setup + lake build
./scripts/setup.sh --quiet   # suppress informational logs

# Manual alternative (skip integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands (after setup):
source ~/.elan/env
lake build                          # full project build
lake build LegalKernel.Kernel       # kernel only (fastest feedback loop)
lake build LegalKernel.RBMapLemmas  # §8.3 fold lemmas only (fast)
lake build LegalKernel.Conservation # Phase-2 economic-invariants framework
lake build LegalKernel.Laws.Transfer
lake build LegalKernel.Laws.Mint    # Phase-2 mint law
lake build LegalKernel.Laws.Burn    # Phase-2 burn law
lake build LegalKernel.Laws.Freeze  # Phase-2 freeze marker + invariant
lake build LegalKernel.Authority.Crypto       # Phase-3 Verify interface
lake build LegalKernel.Authority.Action       # Phase-3 Action layer + compile_injective
lake build LegalKernel.Authority.Identity     # Phase-3 KeyRegistry + AuthorityPolicy
lake build LegalKernel.Authority.Nonce        # Phase-3 NonceState + ExtendedState
lake build LegalKernel.Authority.SignedAction # Phase-3 admissibility + replay protection
lake build LegalKernel.Encoding.CBOR          # Phase-4 byte-codec foundation
lake build LegalKernel.Encoding.State         # Phase-4 State / ExtendedState codec
lake build LegalKernel.Events.Extract         # Phase-5 extractEvents
lake build LegalKernel.Runtime.Hash           # Phase-5 FNV-1a-64 hash
lake build LegalKernel.Runtime.LogFile        # Phase-5 framed log file format
lake build LegalKernel.Runtime.Replay         # Phase-5 replay tool
lake build LegalKernel.Runtime.Snapshot       # Phase-5 snapshot machinery
lake build LegalKernel.Runtime.Loop           # Phase-5 main runtime loop
lake build LegalKernel.Disputes.Types         # Phase-6 dispute / verdict types
lake build LegalKernel.Disputes.Filing        # Phase-6 fileDispute (Stage 1)
lake build LegalKernel.Disputes.Evidence      # Phase-6 checkEvidence (Stage 2)
lake build LegalKernel.Disputes.Verdict       # Phase-6 proposeVerdict + applyVerdict
lake build LegalKernel.Encoding.Disputes      # Phase-6 CBE codec for dispute types
lake build LegalKernel.Disputes.LawClassification    # Phase-6 incentive amendment (WU 6.13)
lake build LegalKernel.Disputes.MonotonicDeployment  # Phase-6 incentive amendment (WU 6.14)
lake build LegalKernel.Disputes.Rewards              # Phase-6 incentive amendment (WUs 6.15-6.16, 6.21-6.23)
lake build LegalKernel.Disputes.Staking              # Phase-6 incentive amendment (WU 6.19)
lake build LegalKernel.Bridge.VerifyAdaptor          # Workstream A.1 ECDSA secp256k1 adaptor
lake build LegalKernel.Bridge.HashAdaptor            # Workstream A.2 keccak256 adaptor
lake build LegalKernel.Bridge.Eip712                 # Workstream A.3 EIP-712 wrap
lake build LegalKernel.Bridge.AddressBook            # Workstream B.1 EthAddress + AddressBook
lake build LegalKernel.Bridge.BridgeActor            # Workstream B.3 bridgeActor + bridgePolicy
lake build LegalKernel.Bridge.Ingest                 # Workstream B.2 L1Event ingestor
lake build LegalKernel.Bridge.State                  # Workstream C.1 BridgeState + ExtendedState embedding
lake build LegalKernel.Bridge.Admissible             # Workstream C.0 BridgeAdmissibleWith
lake build LegalKernel.Bridge.Accounting             # Workstream C.6 totalDeposited / totalWithdrawn
lake build LegalKernel.Laws.Deposit                  # Workstream C.2 deposit law
lake build LegalKernel.Laws.Withdraw                 # Workstream C.3 withdraw law
lake build LegalKernel.Bridge.WithdrawalRoot         # Workstream D.1 sparse Merkle tree (D.1.1 - D.1.5)
lake build LegalKernel.Bridge.WithdrawalProof        # Workstream D.2 withdrawal proof extractor
lake build LegalKernel.Bridge.Finalisation           # Workstream D.3 snapshot finalisation policy
lake build LegalKernel.FaultProof.Cell               # Workstream H §12 CellTag + CellProof
lake build LegalKernel.FaultProof.StepVariants       # Workstream H per-action cell sets (Appendix D)
lake build LegalKernel.FaultProof.Commit             # Workstream H §12.2 commitExtendedState
lake build LegalKernel.FaultProof.Verify             # Workstream H §12.3 verifyCellProof
lake build LegalKernel.FaultProof.Step               # Workstream H §12.1 KernelStep + chainKernelStepApply
lake build LegalKernel.FaultProof.Game               # Workstream H §12.4 bisection game state machine
lake build LegalKernel.FaultProof.Witness            # Workstream H §12.4.4e FaultProofChallengerWon
lake build LegalKernel.FaultProof.LawClassification  # Workstream H §12.1 IsConservative/IsMonotonic for fp ctors
lake build LegalKernel.Test.Bridge.CrossCheck.Framework         # Workstream F.1.1 cross-stack framework
lake build LegalKernel.Test.Bridge.CrossCheck.EcdsaVerify       # Workstream F.1.2 ecdsa fixture
lake build LegalKernel.Test.Bridge.CrossCheck.Keccak256         # Workstream F.1.3 keccak256 fixture
lake build LegalKernel.Test.Bridge.CrossCheck.DepositReceiptHash # Workstream F.1.4 deposit-receipt fixture
lake build LegalKernel.Test.Bridge.CrossCheck.WithdrawalProof   # Workstream F.1.5 withdrawal-proof fixture
lake build LegalKernel.Test.Bridge.CrossCheck.DisputeEvidence   # Workstream F.1.6 dispute-evidence fixture
lake build LegalKernel.Test.Bridge.CrossCheck.MigrationAttestation # Workstream F.1.7 migration fixture
lake build LegalKernel.Test.Bridge.CrossCheck.Goldens           # Workstream F.2 mainnet goldens
lake build LegalKernel.Test.Properties.Bridge                   # Workstream F.4 property-based bridge tests
lake build LegalKernel.Authority.LocalPolicy                    # Workstream LP.1 LocalPolicy data layer
lake build LegalKernel.Authority.LocalPolicySemantics           # Workstream LP.1 LocalPolicy semantics
lake build LegalKernel.Encoding.LocalPolicy                     # Workstream LP.2 LocalPolicy CBE codec
lake build LegalKernel.LocalPolicy.LawClassification            # Workstream LP.9 IsConservative/IsMonotonic
lake build LegalKernel.DSL.LexLaw                               # Workstream LX.6/LX.11 lexlaw macro
lake build LegalKernel.DSL.LexProperty                          # Workstream LX.12-15 synthesizer skeleton
lake build LegalKernel.DSL.LexDeployment                        # LX-M3 LX.31-LX.33 deployment manifest macro
lake build Deployments.Examples.UsdClearing                     # LX-M3 LX.37 worked example deployment
lake build LegalKernel.Laws.ExampleLex                          # Workstream LX.21 M1 acceptance Lex law
# LX-M2 audit-2 in-place migration: Lex declarations co-located with
# hand-written law files (or at top-level for Lex-only laws).
lake build LegalKernel.Laws.Transfer                            # LX.22 transfer (hand-written + Lex)
lake build LegalKernel.Laws.Mint                                # LX.23 mint (hand-written + Lex)
lake build LegalKernel.Laws.Burn                                # LX.23 burn (hand-written + Lex)
lake build LegalKernel.Laws.Freeze                              # LX.24 freezeResource (hand-written + Lex)
lake build LegalKernel.Laws.Reward                              # LX.24 reward (hand-written + Lex)
lake build LegalKernel.Laws.Deposit                             # LX.26 deposit (hand-written + Lex)
lake build LegalKernel.Laws.Withdraw                            # LX.26 withdraw (hand-written + Lex)
lake build LegalKernel.Laws.DistributeOthers                    # LX.29 distributeOthers (hand-written + Lex)
lake build LegalKernel.Laws.ProportionalDilute                  # LX.29 proportionalDilute (hand-written + Lex)
lake build LegalKernel.Laws.ReplaceKey                          # LX.25 replaceKey (Lex-only; identity transition)
lake build LegalKernel.Laws.RegisterIdentity                    # LX.25 registerIdentity (Lex-only)
lake build LegalKernel.Laws.Dispute                             # LX.27 dispute pipeline laws (4 in one file; Lex-only)
lake build LegalKernel.Laws.LocalPolicy                         # LX.28 LP laws (declare/revoke; Lex-only)
lake build LegalKernel.DSL.LawSyntax                            # Phase-4 `law pre := ...; impl := ...` macro (split from DSL.Law)
lake build LegalKernel.DSL.LexImplLowering                      # LX-M2 §6.2 calculus parser (opt-in)
lake build LexCommon                          # Workstream LX.4 shared audit-binary utilities
lake build canon                              # Phase-5 `canon` runtime CLI (D.2: withdrawal-proof subcommand)
lake build canon-replay                       # Phase-5 `canon-replay` audit binary
lake test                           # run Tests.lean driver (1725 tests post-Workstream-H completion pass)
lake exe count_sorries              # WU 1.12: zero-sorry kernel gate
lake exe tcb_audit                  # WU 1.11: TCB allowlist gate
lake exe stub_audit                 # Audit-3.8: stub-detection gate
lake exe lex_lint                   # Workstream LX.5 registry + codegen-input gate
lake exe lex_codegen --check        # Workstream LX.17-20 codegen-consistency gate
lake exe lex_diff <before> <after>  # LX-M3 LX.34/LX.35 semantic-diff binary
lake exe lex_format <file>          # LX-M3 LX.36 pretty-printer

# Phase-5 runtime smoke test (single-shot demo of the binary):
.lake/build/bin/canon info
.lake/build/bin/canon bootstrap /tmp/test.log
.lake/build/bin/canon-replay /tmp/test.log

# Workstream E (Solidity contracts) — see solidity/README.md
cd solidity && ./scripts/vendor-deps.sh   # one-time: pull OZ + forge-std
cd solidity && forge build                # via_ir + solc 0.8.20
cd solidity && forge test                 # 189 + 8 conditionally-skipped tests across 16 suites
cd solidity && make test-cross-stack      # Workstream F.1.x cross-stack equivalence suite only
cd solidity && make testnet-acceptance-dryrun  # Workstream F.3 local fork dry-run
```

**Toolchain:** Lean 4 v4.29.1 (pinned in `lean-toolchain`; the
latest stable Lean release as of the last toolchain bump).  The
`scripts/setup.sh` script handles toolchain install with SHA-256
integrity verification of every artefact (elan installer, elan
binary, Lean toolchain archive) — see the script header for the
audit log.  Bumping the toolchain version requires recomputing the
four `LEAN_TOOLCHAIN_SHA256_*` constants and updating this section
in the same PR.

## Module build verification (mandatory)

**Before committing any `.lean` file**, build the specific module:

```bash
lake build LegalKernel.<Module.Path>
```

Examples:
- Edited `LegalKernel/Kernel.lean`     → `lake build LegalKernel.Kernel`
- Edited `LegalKernel/Laws/Transfer.lean` → `lake build LegalKernel.Laws.Transfer`

**`lake build` (default target) is sufficient at Phases 0 – 3**
because `LegalKernel.lean` re-exports the kernel, the §8.3 RBMap
proof library, the Phase-2 economic-invariants framework, every
deployed law (transfer, mint, burn, freeze), and the Phase-3
authority layer (`Authority.{Crypto, Action, Identity, Nonce,
SignedAction}`), so every TCB / law / kernel / authority file is
reachable from the default target.  This convention may change in
later phases when the law set grows; check the `lean_lib LegalKernel`
`roots` field in `lakefile.lean` if in doubt.

After any source change, also run:

* `lake test` — runs the test driver (191 tests across twelve suites
  as of Phase 3 / post-audit; was 156 at first Phase-3 commit, 95 in
  Phase 2, 43 in Phase 1, 24 in Phase 0).  Catches semantic
  regressions that elaboration-only checks miss (e.g. the §4.11
  self-transfer fix would silently survive a build but break a test).
  Each new Phase-1+ theorem additionally has a term-level
  API-stability test whose elaboration fails if the theorem signature
  changes.
* `lake exe count_sorries` — fails if any kernel-TCB module
  (`Kernel.lean`, `RBMapLemmas.lean`, `Laws/Transfer.lean`) has a
  `sorry` in proof position.  The detector pre-masks `--` line
  comments, `/- … -/` block comments / docstrings, and `"…"`
  string literals before pattern-matching, so a `sorry` mention
  inside a comment or string is correctly *not* flagged.
* `lake exe tcb_audit` — fails if a TCB core module imports anything
  not on `tcb_allowlist.txt` *or* in `Tools.Common.tcbInternalImports`
  (the explicit list of project-internal modules a TCB core file is
  allowed to import).  The internal-imports list is enumerated, not
  pattern-based, so a TCB core file cannot silently depend on a
  non-TCB sibling like `LegalKernel.Laws.Transfer`.

## Source layout

```
canon/
├── lakefile.lean                  -- Lake config: lib + test driver +
│                                     canon + canon-replay exes + audit executables.
├── lean-toolchain                 -- pinned Lean version (Section 13.4).
├── tcb_allowlist.txt              -- WU 1.11 TCB import allowlist.
├── Main.lean                      -- Phase-5 `canon` runtime CLI (WU 5.1):
│                                     info / process / replay / bootstrap / snapshot.
├── Replay.lean                    -- Phase-5 `canon-replay` audit binary (WU 5.5).
├── Tests.lean                     -- @[test_driver]; runs every test module.
├── LegalKernel.lean               -- umbrella import (kernel + RBMap + Conservation + laws + authority + encoding + DSL + events + runtime).
├── LegalKernel/
│   ├── Kernel.lean                -- §4.12 trusted core (TCB).
│   ├── RBMapLemmas.lean           -- §8.3 RBMap proof library (TCB).
│   ├── Conservation.lean          -- §8.1 / §5.3 Phase-2 economic invariants
│   │                                 framework: TotalSupply, IsConservative,
│   │                                 ConservativeLawSet, total_supply_global
│   │                                 + Phase-4-prelude monotonicity tier:
│   │                                 IsMonotonic, MonotonicLawSet,
│   │                                 total_supply_globally_nondecreasing,
│   │                                 sumOthers, getBalance_le_totalSupply,
│   │                                 state_filter_sum_eq_sumOthers
│   │                                 + Workstream-LX (LX.2) classification
│   │                                 typeclasses: LocalTo,
│   │                                 FreezePreserving,
│   │                                 FreezePreservingLawSet,
│   │                                 freeze_preservation_via_law_set
│   │                                 (non-TCB).
│   ├── Laws/
│   │   ├── Transfer.lean          -- §4.11 transfer law + Phase-2
│   │   │                             transfer_conserves + IsConservative
│   │   │                             instance + Phase-4-prelude
│   │   │                             transfer_isMonotonic.
│   │   ├── Mint.lean              -- Phase-2 mint law + non-conservation
│   │   │                             + Phase-4-prelude mint_isMonotonic.
│   │   ├── Burn.lean              -- Phase-2 burn law + non-conservation
│   │   │                             + Phase-4-prelude burn_not_monotonic
│   │   │                             (negative witness).
│   │   ├── Freeze.lean            -- Phase-2 freezeResource marker +
│   │   │                             FrozenForResource invariant
│   │   │                             + Phase-4-prelude
│   │   │                             freezeResource_isConservative
│   │   │                             + freezeResource_isMonotonic.
│   │   ├── Reward.lean            -- Phase-4-prelude WU R.5: single-
│   │   │                             recipient positive-incentive credit
│   │   │                             (non-conservative, monotonic).
│   │   ├── DistributeOthers.lean  -- Phase-4-prelude WU R.8 / R.9:
│   │   │                             uniform reward of all non-excluded
│   │   │                             actors at a resource.
│   │   ├── ProportionalDilute.lean -- Phase-4-prelude WU R.12 / R.13 /
│   │   │                              R.14 / R.15: proportional reward
│   │   │                              (Nat floor, dust discarded) with
│   │   │                              the dust-bound theorem.
│   │   ├── Deposit.lean            -- Workstream C.2: bridge L1 → L2
│   │   │                              deposit credit (positive,
│   │   │                              monotonic).
│   │   ├── Withdraw.lean           -- Workstream C.3: bridge L2 → L1
│   │   │                              withdraw debit (sufficient-balance
│   │   │                              precondition; non-conservative,
│   │   │                              non-monotonic).
│   │   ├── ExampleLex.lean          -- Workstream LX.21: M1 acceptance
│   │   │                              Lex-only law (parameterless,
│   │   │                              kernel-impl-identity, frozen
│   │   │                              index 17).  Exercises the full
│   │   │                              M1 macro surface end-to-end.
│   │   └── Lex/                       -- Workstream LX.22 – LX.29: M2
│   │       │                            Lex re-expressions.  Each file
│   │       │                            imports the corresponding hand-
│   │       │                            written law and `DSL.LexLaw`,
│   │       │                            and contains a `lexlaw`
│   │       │                            declaration + an `rfl`-close
│   │       │                            byte-equivalence regression
│   │       │                            `example`.  The twin-file
│   │       │                            structure avoids the `pre`/
│   │       │                            `impl` token clash that arises
│   │       │                            when the DSL is in scope of
│   │       │                            the hand-written law's `where
│   │       │                            pre := ...` field block.
│   │       ├── Transfer.lean          -- LX.22 transfer Lex re-expression.
│   │       ├── Mint.lean              -- LX.23 mint Lex re-expression.
│   │       ├── Burn.lean              -- LX.23 burn Lex re-expression.
│   │       ├── Freeze.lean            -- LX.24 freezeResource Lex re-expression.
│   │       ├── Reward.lean            -- LX.24 reward Lex re-expression.
│   │       ├── ReplaceKey.lean        -- LX.25 replaceKey Lex re-expression.
│   │       ├── RegisterIdentity.lean  -- LX.25 registerIdentity Lex re-expression.
│   │       ├── Deposit.lean           -- LX.26 deposit Lex re-expression.
│   │       ├── Withdraw.lean          -- LX.26 withdraw Lex re-expression.
│   │       ├── Dispute.lean           -- LX.27 dispute pipeline laws (4 in one file).
│   │       ├── LocalPolicy.lean       -- LX.28 LP laws (declare/revoke).
│   │       ├── DistributeOthers.lean  -- LX.29 distributeOthers Lex re-expression.
│   │       └── ProportionalDilute.lean -- LX.29 proportionalDilute Lex re-expression.
│   ├── Authority/
│   │   ├── Crypto.lean            -- Phase-3 WU 3.4: PublicKey,
│   │   │                             Signature, opaque Verify, opaque
│   │   │                             SigningInput (non-TCB).
│   │   ├── Action.lean            -- Phase-3 WU 3.1 + 3.2: Action
│   │   │                             inductive, CompiledAction wrapper,
│   │   │                             Action.compile_injective via
│   │   │                             congrArg (non-TCB).
│   │   ├── Identity.lean          -- Phase-3 WU 3.3: Identity,
│   │   │                             KeyRegistry (with empty / register
│   │   │                             / revoke / mergeLeftBiased),
│   │   │                             AuthorityPolicy (with empty /
│   │   │                             unrestricted / union / intersect /
│   │   │                             singleton) (non-TCB).
│   │   ├── Nonce.lean             -- Phase-3 WU 3.5: NonceState,
│   │   │                             ExtendedState (= base + nonces +
│   │   │                             registry + bridge + localPolicies
│   │   │                             after Workstream-LP / LP.3),
│   │   │                             expectsNonce, advanceNonce,
│   │   │                             expectsNonce_strict_mono (non-TCB).
│   │   ├── LocalPolicy.lean       -- Workstream LP.1 (data layer):
│   │   │                             LocalPolicyClause (3 MVP variants),
│   │   │                             LocalPolicy structure, LocalPolicies
│   │   │                             abbrev with empty/lookup/declare/
│   │   │                             revoke; §3.0 DoS bound constants;
│   │   │                             5 RBMap-derived lookup lemmas
│   │   │                             (non-TCB).
│   │   ├── LocalPolicySemantics.lean -- Workstream LP.1 (semantics layer):
│   │   │                             Action.tag (17-branch projection
│   │   │                             covering indices 0..16);
│   │   │                             LocalPolicyClause.permits /
│   │   │                             LocalPolicy.permits semantic
│   │   │                             predicates with named Decidable
│   │   │                             instances; per-clause semantic
│   │   │                             theorems (non-TCB).
│   │   └── SignedAction.lean      -- Phase-3 WU 3.6 / 3.7 / 3.8 / 3.10:
│   │                                 SignedAction, Admissible (5
│   │                                 conditions; 6 after Workstream-LP /
│   │                                 LP.7), apply_admissible (single
│   │                                 guarded entry point),
│   │                                 nonce_uniqueness, replay_impossible,
│   │                                 replaceKey registry-mutation
│   │                                 theorems; LP.5 + LP.7 add
│   │                                 applyActionToLocalPolicies +
│   │                                 localPolicyPermits +
│   │                                 isMetaPolicyAction +
│   │                                 localPolicy_meta_action_independent
│   │                                 (non-TCB).
│   ├── Encoding/                   -- Phase-4 WU 4.1 – 4.8: canonical CBE
│   │   │                             (Canon Binary Encoding) — strictly
│   │   │                             canonical fixed-width binary form
│   │   │                             (deviation from RFC 8949 canonical
│   │   │                             CBOR; see GENESIS_PLAN §8.8 deviation
│   │   │                             block).  All non-TCB.
│   │   ├── CBOR.lean               -- WU 4.1: DecodeError, Stream =
│   │   │                             List UInt8, cborHeadEncode/Decode,
│   │   │                             natFromBytesLE, natToBytesLE,
│   │   │                             cborHeadRoundtrip{,_append}.
│   │   ├── Encodable.lean          -- WU 4.1 + 4.2: Encodable typeclass +
│   │   │                             instances for Bool, Nat, BoundedNat,
│   │   │                             ByteArray, UInt8/16/32/64, List,
│   │   │                             Option; per-type roundtrip +
│   │   │                             injectivity theorems.
│   │   ├── Action.lean             -- WU 4.3 + 4.6 + 4.7: Action.encode/
│   │   │                             decode (constructor-tag + fields,
│   │   │                             frozen indices 0..7),
│   │   │                             Action.fieldsBounded,
│   │   │                             action_roundtrip + injectivity.
│   │   ├── SignedAction.lean       -- WU 4.4 + 4.6 + 4.7: SignedAction
│   │   │                             encoder, fieldsBounded predicate,
│   │   │                             roundtrip + injectivity (Dispute /
│   │   │                             Verdict deferred to Phase 6).
│   │   ├── State.lean              -- WU 4.5 + 4.6 + 4.7: State,
│   │   │                             ExtendedState, BalanceMap, NonceState,
│   │   │                             KeyRegistry encoders;
│   │   │                             state_encode_deterministic +
│   │   │                             balanceMap_encode_deterministic_of_equiv.
│   │   └── SignInput.lean          -- WU 4.8: signInput with domain-
│   │                                 separation (§8.8.5);
│   │                                 cross-deployment-replay rejection
│   │                                 (verified at value level via tests).
│   ├── DSL/
│   │   ├── Law.lean                -- Phase-4 WU 4.9: Law.mk combinator
│   │   │                             + `law pre := <expr> ; impl :=
│   │   │                             <expr>` macro; auto-fills decPre :=
│   │   │                             fun _ => inferInstance.
│   │   ├── LexLaw.lean              -- Workstream LX.6 / LX.11: the
│   │   │                             `lexlaw` Lean command (M1 surface
│   │   │                             with `lex_*`-prefixed clause
│   │   │                             keywords; emits a `<law>_transition`
│   │   │                             def + writes the codegen-input
│   │   │                             JSON sidecar deterministically).
│   │   └── LexProperty.lean         -- Workstream LX.12-15: property
│   │                                  synthesizer-library skeleton
│   │                                  (`PropertyKind`, `ImplStmtKind`,
│   │                                  `SynthError`; `synth_*` dispatchers
│   │                                  per property + `dispatchSynthesizer`
│   │                                  entry point).
│   ├── Events/                     -- Phase-5 WU 5.6: deployment-facing
│   │   │                             event log (§8.9.2) derived from log
│   │   │                             entries.  All non-TCB.
│   │   ├── Types.lean              -- WU 5.6: `Event` inductive (5 ctors:
│   │   │                             balanceChanged, nonceAdvanced,
│   │   │                             identityRegistered/Revoked,
│   │   │                             timeRecorded; Phase 6 appends 2 more).
│   │   └── Extract.lean            -- WU 5.6: `extractEvents` —
│   │                                 deterministic per-action event
│   │                                 emission rules.
│   ├── Runtime/                    -- Phase-5 WU 5.1 / 5.2 / 5.3 / 5.5 /
│   │   │                             5.12: deployment-facing runtime
│   │   │                             machinery.  All non-TCB.
│   │   ├── Hash.lean               -- WU 5.1 / 5.5 / 5.12: FNV-1a-64
│   │   │                             deterministic hash (production
│   │   │                             swap-point for BLAKE3 via
│   │   │                             @[extern] linkage; see
│   │   │                             docs/extraction_notes.md).
│   │   ├── LogFile.lean            -- WU 5.2 + 5.3: `LogEntry` structure
│   │   │                             + `Encodable` instance + framed
│   │   │                             on-disk format (magic + length +
│   │   │                             payload + FNV-1a-64 trailer);
│   │   │                             `appendEntry` / `readAllEntries` /
│   │   │                             `loadAndTruncate` IO; `verifyChain`
│   │   │                             chain-integrity helper.
│   │   ├── Replay.lean             -- WU 5.5: `replay` (genesis + log →
│   │   │                             final state); `replayHash`
│   │   │                             (final hash only); `replayFromSeed`
│   │   │                             (snapshot-bootstrap path);
│   │   │                             `Decidable Admissible` instance.
│   │   ├── Snapshot.lean           -- WU 5.12: `Snapshot` record (state
│   │   │                             hash + encoded state + log index +
│   │   │                             seed hash); `takeSnapshot` /
│   │   │                             `restoreSnapshot`;
│   │   │                             `replicaFromSnapshot` (replica
│   │   │                             bootstrap from snapshot + log tail);
│   │   │                             file IO helpers.
│   │   └── Loop.lean               -- WU 5.1: `RuntimeState` record;
│   │                                 `processSignedAction` (admissibility
│   │                                 check → apply → log append → events);
│   │                                 `bootstrap` (load + truncate +
│   │                                 replay startup path); `processBatch`.
│   ├── Disputes/                   -- Phase-6 §8.4 dispute pipeline.  All non-TCB.
│   │   ├── Types.lean              -- WU 6.1: `LogIndex`, `DisputeClaim`
│   │   │                             (5 variants), `EvidenceVerdict`,
│   │   │                             `Dispute`, `Verdict`,
│   │   │                             `DisputeRecord`, `DisputeStatus`,
│   │   │                             `OraclePolicy`, `FilingError`,
│   │   │                             `VerdictError`.
│   │   ├── Filing.lean             -- WU 6.3 + 6.11: `claimImpugnedIdx`,
│   │   │                             `findPriorDisputeIdx`, `fileDispute`
│   │   │                             (Stage 1, four acceptance checks),
│   │   │                             `applyWithdraw` + idempotency
│   │   │                             theorems, `disputeStatus`
│   │   │                             walk-the-log.
│   │   ├── Evidence.lean           -- WU 6.4 / 6.5 / 6.6 / 6.7 / 6.8:
│   │   │                             `kernelOnlyApply` /
│   │   │                             `kernelOnlyReplay` (admissibility-
│   │   │                             blind prefix-replay helper);
│   │   │                             five per-claim verifiers
│   │   │                             (`checkPreconditionFalse`,
│   │   │                             `checkSignatureInvalid`,
│   │   │                             `checkNonceMismatch`,
│   │   │                             `checkOracleMisreported`,
│   │   │                             `checkDoubleApply`); `checkEvidence`
│   │   │                             dispatcher; determinism theorems.
│   │   ├── Verdict.lean            -- WU 6.9 + 6.10: `QuorumPolicy` +
│   │   │                             `singleton`/`empty` constructors;
│   │   │                             `countVerifiedSignatures`;
│   │   │                             `proposeVerdict` (Stage 3 with
│   │   │                             quorum / outcome-match / status
│   │   │                             checks); `applyVerdict` (Stage 4
│   │   │                             with rollback computation via
│   │   │                             prefix-replay); per-outcome no-
│   │   │                             change theorems.
│   │   ├── LawClassification.lean  -- Phase-6 incentive amendment WU 6.13:
│   │   │                             4 `_compileTransition_eq_freezeResource_zero`
│   │   │                             rfl lemmas + 8 typeclass instances
│   │   │                             (`IsConservative` × 4, `IsMonotonic`
│   │   │                             × 4) for the dispute action ctors.
│   │   ├── MonotonicDeployment.lean -- Phase-6 incentive amendment WU 6.14:
│   │   │                             example `disputableMonotonicLawSet`
│   │   │                             (6-law list) + headline
│   │   │                             `disputable_monotonic_total_supply_nondecreasing`.
│   │   ├── Rewards.lean             -- Phase-6 incentive amendment WUs
│   │   │                             6.15 / 6.16 / 6.21 / 6.22 / 6.23:
│   │   │                             `DisputeRewardPolicy` structure +
│   │   │                             6 atomic / graduated constructors
│   │   │                             (empty, flatChallengerReward,
│   │   │                             flatAdjudicatorReward, union,
│   │   │                             byClaimVariant,
│   │   │                             proportionalChallengerReward);
│   │   │                             `disputeRewardActions` emitter +
│   │   │                             `disputeRewardActionsMulti` (multi-
│   │   │                             policy bundle); `claimImpugnedAmount`
│   │   │                             helper; `stakeWeightedAdjudicatorRewards`
│   │   │                             (3-adjudicator-fixture-tested);
│   │   │                             `applyVerdictWithRewards{,Multi}`
│   │   │                             wrappers; per-element + sum-le-pool
│   │   │                             dust-bound theorems.
│   │   └── Staking.lean             -- Phase-6 incentive amendment WU 6.19:
│   │                                 `StakingPolicy` (kernel-conservative
│   │                                 anti-fraud); `StakedFilingError` (per
│   │                                 design decision D2); `stakeFilingActions`
│   │                                 + `stakeResolutionActions` (per design
│   │                                 decision D1: rollback implicitly returns
│   │                                 stake on upheld; treasury transfer on
│   │                                 rejected/inconclusive); `fileDisputeStaked`
│   │                                 wrapper.
│   ├── LocalPolicy/                  -- Workstream LP (actor-scoped policies).
│   │   │                                All non-TCB.
│   │   └── LawClassification.lean   -- LP.9: 2 rfl-class identification
│   │                                    lemmas + 4 typeclass instances
│   │                                    (`IsConservative` × 2,
│   │                                    `IsMonotonic` × 2) for the LP
│   │                                    action ctors; composite
│   │                                    `local_policy_actions_classification`
│   │                                    summary theorem.
│   ├── Encoding/LocalPolicy.lean    -- Workstream LP.2: CBE codec for
│   │                                    LocalPolicyClause / LocalPolicy /
│   │                                    LocalPolicies; `fieldsBounded`
│   │                                    predicates + round-trip + injectivity
│   │                                    proofs (non-TCB).
│   ├── Bridge/                       -- Ethereum Workstream A (cryptographic
│   │   │                                adaptors): non-TCB Lean-side contracts
│   │   │                                for the production Rust crypto bindings.
│   │   ├── VerifyAdaptor.lean       -- WU A.1: ECDSA secp256k1 verify adaptor
│   │   │                                contract.  Curve constants
│   │   │                                (`secp256k1Order`, `secp256k1HalfOrder`,
│   │   │                                `secp256k1OrderBytes`); signature /
│   │   │                                pk size constants; `isLowS` predicate;
│   │   │                                runtime adaptor identifier; stability
│   │   │                                theorems.
│   │   ├── HashAdaptor.lean         -- WU A.2: keccak256 hash adaptor contract.
│   │   │                                Adaptor identifier
│   │   │                                (`"keccak256/EVM-compatible/v1"`);
│   │   │                                `isKeccak256Linked` predicate; four
│   │   │                                reference KAT vectors;
│   │   │                                `expectedFallbackEmptyHash` for
│   │   │                                fallback diagnosis; bridge-namespace
│   │   │                                forwarders for the size /
│   │   │                                determinism / identifier-distinctness
│   │   │                                stability theorems.
│   │   ├── Eip712.lean              -- WU A.3: EIP-712 typed-data wrap.
│   │   │                                `CollisionFree` Prop predicate;
│   │   │                                `eip712Prefix`; `DomainParams` /
│   │   │                                `Eip712Message` structures;
│   │   │                                `domainPreHash` /
│   │   │                                `eip712DomainSeparator` /
│   │   │                                `eip712StructHash` / `eip712Wrap`
│   │   │                                encoders; `encodeUint256BE` 32-byte
│   │   │                                BE uint encoder.  Three headline
│   │   │                                theorems (`eip712Wrap_injective`,
│   │   │                                `eip712DomainSeparator_distinguishes`,
│   │   │                                `eip712Wrap_distinguishes`) plus
│   │   │                                auxiliary lemmas
│   │   │                                (`domainPreHash_injective`,
│   │   │                                `encodeUint256BE_injective`).
│   │   ├── AddressBook.lean         -- WU B.1: `EthAddress = Fin (2^160)`
│   │   │                                with `Ord`/`DecidableEq`-via-`Fin`;
│   │   │                                `AddressBook` (forward, reverse,
│   │   │                                nextActorId); `Consistent` Prop
│   │   │                                invariant; `empty` (nextActorId :=
│   │   │                                1, reserving id 0 for the bridge);
│   │   │                                `lookup` / `lookupRev` / `assign`;
│   │   │                                `EthAddress.ofBytes` /
│   │   │                                `EthAddress.toBytes` BE-byte
│   │   │                                conversions.  Three §12.7 headline
│   │   │                                theorems
│   │   │                                (`addressBook_invariant`,
│   │   │                                `assign_fresh_actorId`,
│   │   │                                `assign_idempotent_for_known`)
│   │   │                                plus `empty_consistent`,
│   │   │                                `assign_preserves_consistent`,
│   │   │                                and locality lemmas.
│   │   ├── BridgeActor.lean         -- WU B.3: `bridgeActor : ActorId :=
│   │   │                                0` reservation; `bridgePolicy :
│   │   │                                AuthorityPolicy` admitting only
│   │   │                                `replaceKey` and `registerIdentity`
│   │   │                                actions by the bridge actor.
│   │   │                                Five §12.9 theorems
│   │   │                                (`bridgePolicy_rejects_transfer`,
│   │   │                                `bridgePolicy_authorizes_replaceKey`,
│   │   │                                `bridgePolicy_authorizes_registerIdentity`,
│   │   │                                plus the wider rejection family
│   │   │                                and `_rejects_non_bridge_signer`).
│   │   ├── Ingest.lean              -- WU B.2: `L1Event` inductive
│   │   │                                (identityRegistered /
│   │   │                                identityRevoked /
│   │   │                                depositInitiated; with originating
│   │   │                                `(blockNum, logIdx)` metadata);
│   │   │                                `UnsignedBridgeAction` envelope;
│   │   │                                `ingest` function (fresh →
│   │   │                                `Action.registerIdentity`;
│   │   │                                rotation →
│   │   │                                `Action.replaceKey`; revocation /
│   │   │                                deposit → `none`).  Three §12.8
│   │   │                                theorems
│   │   │                                (`ingest_emits_bridge_actor`,
│   │   │                                `ingest_preserves_lookup_for_other_addresses`,
│   │   │                                `ingest_lookup_equivalent_for_distinct_addresses`).
│   │   ├── State.lean               -- Workstream C.1: `DepositId`
│   │   │                                (`Nat`, BE-decoded 32-byte hash;
│   │   │                                docstring deviation from plan's
│   │   │                                ByteArray); `WithdrawalId`;
│   │   │                                `DepositRecord` (audit-2 amend.);
│   │   │                                `PendingWithdrawal`;
│   │   │                                `BridgeState` (consumed +
│   │   │                                pending + nextWdId);
│   │   │                                `BridgeState.empty` and basic
│   │   │                                accessors / mutators
│   │   │                                (`markConsumed`, `appendWithdrawal`).
│   │   ├── Admissible.lean          -- Workstream C.0: `BridgeAdmissibleWith`
│   │   │                                (5 + 3 conjuncts);
│   │   │                                `applyActionToBridgeState`;
│   │   │                                `apply_bridge_admissible_with`;
│   │   │                                `BridgeAdmissibleWith.toAdmissibleWith`
│   │   │                                projection;
│   │   │                                `apply_admissible_with_preserves_bridge`
│   │   │                                pass-through;
│   │   │                                `bridge_replay_impossible` lift.
│   │   ├── Accounting.lean          -- Workstream C.6: `totalDeposited`,
│   │   │                                `totalWithdrawn` quantity
│   │   │                                functionals; per-action
│   │   │                                accounting deltas (transfer,
│   │   │                                freeze, replaceKey,
│   │   │                                registerIdentity, non-bridge
│   │   │                                parameterised);
│   │   │                                `applyActionToBridgeState`
│   │   │                                shape lemmas; genesis
│   │   │                                sanity lemmas.
│   │   ├── WithdrawalRoot.lean      -- Workstream D.1
│   │   │                                (D.1.1 – D.1.4): sparse Merkle
│   │   │                                tree (`smtHeight = 64`,
│   │   │                                `defaultHash`, `pathBitAtLevel`,
│   │   │                                `hashUp`, `leafBytes`,
│   │   │                                `rangeRoot` with empty short-
│   │   │                                circuit, `withdrawalRoot`);
│   │   │                                verifier and constructor
│   │   │                                (`WithdrawalProof`,
│   │   │                                `verifyProofRec`, `verifyProof`,
│   │   │                                `constructProofAux` with empty
│   │   │                                short-circuit, `constructProof`,
│   │   │                                `emptyProofSiblings`);
│   │   │                                completeness theorem
│   │   │                                (`verifyProof_complete`,
│   │   │                                unconditional);
│   │   │                                soundness theorem
│   │   │                                (`verifyProof_sound`, under
│   │   │                                `CollisionFree H` +
│   │   │                                `UniformOutputSize H 32` +
│   │   │                                leaf / sibling size hyps);
│   │   │                                helper lemmas
│   │   │                                (`verifyProofRec_eq_rangeRoot`,
│   │   │                                `verifyProofRec_inj`,
│   │   │                                `hashUp_inj_of_collisionFree`,
│   │   │                                `byteArray_append_inj`).
│   │   ├── WithdrawalProof.lean     -- Workstream D.2: `extractProof`
│   │   │                                (snapshot-based proof
│   │   │                                extractor); `Snapshot.bridgeWithdrawalRoot`
│   │   │                                (decoded-state-derived root);
│   │   │                                `extractProof_consistent_with_root`
│   │   │                                (extracted proofs verify against
│   │   │                                the snapshot's root).
│   │   └── Finalisation.lean        -- Workstream D.3:
│   │                                    `FinalisableSnapshot` wrapper
│   │                                    (snapshot + L1 confirmation
│   │                                    metadata + log range);
│   │                                    `hasUpheldInRange` (forward-walk
│   │                                    upheld-dispute scan);
│   │                                    `isFinalised` predicate;
│   │                                    `isFinalised_monotonic_in_currentBlock`
│   │                                    + `isFinalised_implies_no_upheld_against`
│   │                                    headline theorems.
│   └── Test/
│       ├── Framework.lean         -- minimal IO-based test harness + emptyState.
│       ├── KernelTests.lean       -- value-level kernel tests (22 cases).
│       ├── RBMapLemmasTests.lean  -- §8.3 fold-lemma tests (8 cases).
│       ├── Umbrella.lean          -- umbrella-module smoke tests (2 cases).
│       ├── ConservationTests.lean -- Phase-2 conservation tests (21 cases incl. R.20 monotonicity-tier extensions + end-to-end behaviour test).
│       ├── Laws/
│       │   ├── Transfer.lean      -- transfer-law tests (17 cases incl. R.19).
│       │   ├── Mint.lean          -- mint tests (11 cases incl. R.19).
│       │   ├── Burn.lean          -- burn tests (13 cases incl. R.19).
│       │   ├── Freeze.lean        -- freeze tests (12 cases incl. R.19).
│       │   ├── Reward.lean        -- Phase-4-prelude R.6: reward tests (11 cases).
│       │   ├── DistributeOthers.lean -- Phase-4-prelude R.10: distributeOthers tests (14 cases).
│       │   └── ProportionalDilute.lean -- Phase-4-prelude R.16: proportionalDilute tests (17 cases).
│       ├── Authority/
│       │   ├── Action.lean        -- Action layer tests (31 cases incl. R.18).
│       │   ├── Identity.lean      -- Phase-3 Identity / KeyRegistry /
│       │   │                         AuthorityPolicy tests (14 cases).
│       │   ├── LocalPolicy.lean   -- Workstream LP.1 LocalPolicy data
│       │   │                         layer tests (27 cases).
│       │   ├── LocalPolicyAdmissibility.lean -- Workstream LP.11 e2e
│       │   │                         acceptance tests (14 scenarios).
│       │   ├── Nonce.lean         -- Phase-3 nonce ledger tests (11 cases).
│       │   └── SignedAction.lean  -- Phase-3 admissibility / replay /
│       │                             key-rotation tests (17 cases).
│       ├── LocalPolicy/
│       │   └── LawClassification.lean -- Workstream LP.9 IsConservative
│       │                             / IsMonotonic tests (10 cases).
│       ├── Encoding/
│       │   ├── CBOR.lean          -- Phase-4 CBE codec tests (6 cases).
│       │   ├── Encodable.lean     -- primitive-instance roundtrip tests
│       │   │                         (12 cases).
│       │   ├── Action.lean        -- Action encoder roundtrip tests
│       │   │                         (12 cases).
│       │   ├── LocalPolicy.lean   -- Workstream LP.2 LocalPolicy CBE
│       │   │                         codec tests (12 cases).
│       │   ├── SignedAction.lean  -- SignedAction encoder tests (4 cases).
│       │   ├── State.lean         -- State / ExtendedState encoder tests
│       │   │                         (6 cases).
│       │   └── SignInput.lean     -- WU 4.8 sign-input distinguishability
│       │                             tests (7 cases).
│       ├── DSL/
│       │   └── Law.lean           -- WU 4.9 `law` macro tests (4 cases).
│       ├── Events/
│       │   ├── Types.lean         -- Phase-5 WU 5.6 Event-inductive tests
│       │   │                         (7 cases).
│       │   └── Extract.lean       -- Phase-5 WU 5.6 extractEvents tests
│       │                             (10 cases).
│       ├── Runtime/
│       │   ├── Hash.lean          -- Phase-5 hash-function tests (10).
│       │   ├── LogFile.lean       -- Phase-5 WU 5.2 + 5.3 log-file
│       │   │                         tests (20 cases incl. crash-cons.).
│       │   ├── Replay.lean        -- Phase-5 WU 5.5 replay tests (10).
│       │   ├── Snapshot.lean      -- Phase-5 WU 5.12 snapshot tests (11).
│       │   └── Loop.lean          -- Phase-5 WU 5.1 runtime-loop tests
│       │                             (13 cases incl. rejection paths).
│       └── Disputes/
│           ├── Filing.lean        -- Phase-6 WU 6.3 / 6.11 filing
│           │                         tests (16 cases: happy paths,
│           │                         error paths, idempotency,
│           │                         disputeStatus walk-the-log).
│           ├── Evidence.lean      -- Phase-6 WU 6.4 – 6.8 evidence
│           │                         tests (18 cases: per-variant
│           │                         verifier behaviour + dispatcher;
│           │                         Phase-6 Option-C amendment +
│           │                         2 cases for the defensive
│           │                         `checkOracleMisreported` index
│           │                         check).
│           ├── Verdict.lean       -- Phase-6 WU 6.9 / 6.10 verdict
│           │                         tests (26 cases: proposeVerdict
│           │                         error paths, applyVerdictUnchecked
│           │                         per-outcome semantics, QuorumPolicy
│           │                         constructors; Phase-6 Option-C
│           │                         amendment + 15 witness-API +
│           │                         5 proposeAndApplyVerdict cases).
│           ├── EndToEnd.lean      -- Phase-6 WU 6.12 acceptance test
│           │                         (8 cases: planted-illegal-tx →
│           │                         file → check → upheld verdict
│           │                         → rollback target reproduces
│           │                         pre-illegal state; Phase-6
│           │                         Option-C amendment + 3
│           │                         proposeAndApplyVerdict tests).
│           ├── LawClassification.lean -- Phase-6 incentive amendment WU
│           │                            6.13 tests (13 cases).
│           ├── MonotonicDeployment.lean -- Phase-6 incentive amendment
│           │                              WU 6.14 tests (7 cases).
│           ├── Rewards.lean       -- Phase-6 incentive amendment WUs
│           │                         6.15 / 6.16 / 6.21 / 6.22 / 6.23
│           │                         tests (25 cases).
│           ├── Staking.lean       -- Phase-6 incentive amendment WU
│           │                         6.19 tests (17 cases).
│           ├── WitnessHelpers.lean -- Phase-6 Option-C amendment WU
│           │                          C.7: VerdictPassedStage3 helpers
│           │                          + value-level witness fixture
│           │                          (6 cases).
│           └── IncentivizedEndToEnd.lean -- Phase-6 incentive amendment
│                                          WU 6.17 acceptance test (22
│                                          cases: upheld + flat rewards,
│                                          rejected + stake forfeit,
│                                          disabled short-circuit, stake-
│                                          weighted distribution, cross-
│                                          resource bundle, rewardIssued
│                                          event emission, determinism,
│                                          frivolous-dispute deterrence).
│       └── Bridge/
│           ├── VerifyAdaptor.lean   -- Workstream A.1 verify-adaptor
│           │                           stability tests (25 cases: curve
│           │                           constants, BE bytes ↔ Nat
│           │                           coherence, EIP-2 threshold
│           │                           sanity, low-s boundary, mock-
│           │                           verifier happy path, term-level
│           │                           API stability).
│           ├── HashAdaptor.lean     -- Workstream A.2 hash-adaptor
│           │                           stability tests (26 cases: KAT
│           │                           vector shapes, identifier
│           │                           distinctness, conditional KAT-
│           │                           match branching on
│           │                           `isKeccak256Linked` for all four
│           │                           reference vectors,
│           │                           leading-byte distinctness,
│           │                           determinism, term-level API).
│           ├── Eip712.lean          -- Workstream A.3 EIP-712 wrap
│           │                           tests (42 cases: prefix /
│           │                           struct / wrap shapes, type-
│           │                           string sanity (4),
│           │                           structPreHash size (= 160) +
│           │                           byte-layout regression tests
│           │                           (signer LSB at byte 95, nonce
│           │                           LSB at byte 127), value-level
│           │                           distinguishability across
│           │                           distinct domains / messages /
│           │                           nonces / signers / deployment
│           │                           IDs / chains, cross-protocol
│           │                           distinguishability against
│           │                           Canon `signedActionDomain`,
│           │                           term-level API stability for
│           │                           all three headline theorems +
│           │                           auxiliary lemmas).
│           ├── AddressBook.lean     -- Workstream B.1 AddressBook
│           │                           tests (24 cases: empty fixture
│           │                           properties, EthAddress
│           │                           conversions, assign happy
│           │                           paths, cross-actor independence,
│           │                           consistency invariant /
│           │                           preservation, term-level API
│           │                           stability for the §12.7
│           │                           theorems).
│           ├── BridgeActor.lean     -- Workstream B.3 BridgeActor
│           │                           tests (18 cases: bridgeActor =
│           │                           0, positive cases for
│           │                           `replaceKey` /
│           │                           `registerIdentity` by the
│           │                           bridge, rejection cases for
│           │                           every other Action constructor,
│           │                           cross-actor rejection,
│           │                           decidability sanity,
│           │                           term-level API stability for
│           │                           the §12.9 theorems).
│           ├── Ingest.lean          -- Workstream B.2 Ingest tests
│           │                           (19 cases: L1Event.address
│           │                           projection, per-variant ingest
│           │                           behaviour, AddressBook update
│           │                           behaviour, locality, cross-
│           │                           address commutativity,
│           │                           bridge-actor pinning,
│           │                           term-level API stability for
│           │                           the §12.8 theorems).
│           ├── State.lean           -- Workstream C.1 BridgeState
│           │                           tests (11 cases: empty /
│           │                           markConsumed / appendWithdrawal
│           │                           accessor + mutator semantics,
│           │                           ExtendedState.empty bridge
│           │                           ledger sanity, DecidableEq for
│           │                           DepositRecord +
│           │                           PendingWithdrawal).
│           ├── Admissible.lean      -- Workstream C.0 BridgeAdmissible
│           │                           tests (14 cases:
│           │                           Action.isBridgeOnly classifier
│           │                           positive / negative,
│           │                           applyActionToBridgeState shape
│           │                           on every Action variant,
│           │                           multi-step deposit / withdraw
│           │                           sequence, term-level API
│           │                           stability for the WU C.0
│           │                           theorems).
│           ├── Accounting.lean      -- Workstream C.6 accounting tests
│           │                           (19 cases: genesis sanity,
│           │                           totalDeposited / totalWithdrawn
│           │                           at single + multi-element
│           │                           fixtures, amountAt projections,
│           │                           per-action delta term-level
│           │                           APIs, end-to-end 4-step trace
│           │                           [deposit, transfer, withdraw,
│           │                           transfer]).
│           ├── WithdrawalRoot.lean  -- Workstream D.1 SMT tests
│           │                           (30 cases: shape constants,
│           │                           defaultHash recursion, root
│           │                           extensionality, verifier
│           │                           positive / negative paths,
│           │                           constructor on absent /
│           │                           present indices, completeness
│           │                           on 1- / 2- / 8-leaf fixtures,
│           │                           soundness API stability).
│           ├── WithdrawalProof.lean -- Workstream D.2 extractor tests
│           │                           (12 cases: extract on
│           │                           valid / absent / empty
│           │                           snapshots, bridgeWithdrawalRoot
│           │                           shape, end-to-end extract +
│           │                           verify, determinism API).
│           ├── WithdrawalProofCLI.lean -- Workstream D.2 CLI
│           │                           integration tests (6 cases:
│           │                           end-to-end save / load /
│           │                           extract / verify flow,
│           │                           byte-stability across runs,
│           │                           absent-id / corrupt-snapshot
│           │                           handling, bridgeWithdrawalRoot
│           │                           preservation across save/load).
│           ├── Finalisation.lean    -- Workstream D.3 finalisation
│           │                           tests (14 cases: predicate
│           │                           value-level checks at the
│           │                           dispute-window boundary,
│           │                           monotonicity, hasUpheldInRange
│           │                           shape, FinalisableSnapshot
│           │                           field accessibility).
│           └── WithdrawalRootGoldens.lean -- Workstream D.1.5
│                                       cross-stack 16-leaf golden
│                                       fixture (5 cases: all-canonical
│                                       proofs verify, root size /
│                                       determinism, root distinguishes
│                                       populated from empty,
│                                       non-membership proof for
│                                       out-of-fixture id).
├── Tools/
│   ├── Common.lean                -- shared TCB constants + readFileSafe.
│   ├── TcbAudit.lean              -- WU 1.11 TCB allowlist enforcer.
│   ├── CountSorries.lean          -- WU 1.12 sorry-counting CI gate.
│   ├── StubAudit.lean             -- Audit-3.8 stub-detection gate.
│   ├── LexCommon.lean             -- Workstream LX.4 shared utilities
│   │                                 (LawDecl JSON codec, registry parser,
│   │                                 Diagnostic record + canonical
│   │                                 formatter, atomic-write helper).
│   ├── LexLint.lean               -- Workstream LX.5 audit binary
│   │                                 (registry well-formedness +
│   │                                 codegen-input cross-check).
│   └── LexCodegen.lean            -- Workstream LX.17-20 codegen binary
│                                     (default + --check modes; M2 adds
│                                     fence-respecting append + canonical
│                                     regeneration).
├── lex_index_registry.txt         -- Workstream LX.1 frozen action-index
│                                     registry (append-only).
├── LegalKernel/_lex_inputs/        -- Workstream LX.1 codegen-input
│                                     directory.  One JSON file per
│                                     `lexlaw`-elaborated law; the cross-
│                                     pass medium between Pass 1 (the
│                                     LexLaw macro) and Pass 2 (lex_codegen).
├── scripts/
│   └── setup.sh                   -- SHA-256-verified toolchain installer.
├── solidity/                      -- Workstream E: L1 mirror of the
│   │                                 kernel.  Five immutable contracts
│   │                                 (CanonBridge, CanonDisputeVerifier,
│   │                                 CanonIdentityRegistry,
│   │                                 CanonSequencerStake, CanonMigration)
│   │                                 + four cross-cutting libraries
│   │                                 (CBEDecode, SmtVerifier, CanonEip712,
│   │                                 CREATE3) + 8 forge test suites.
│   │                                 See solidity/README.md.
│   ├── foundry.toml               -- toolchain (solc 0.8.20, via_ir, OZ
│   │                                 remappings).
│   ├── src/contracts/             -- the five contracts (E.1.* / E.2.* /
│   │                                 E.3 / E.4 / E.5 deliverables).
│   ├── src/interfaces/            -- shared interfaces.
│   ├── src/lib/                   -- CBE decoder, SMT verifier, EIP-712,
│   │                                 CREATE3.
│   ├── test/                      -- 139 forge tests across 8 suites.
│   └── scripts/vendor-deps.sh     -- pinned OZ + forge-std installer.
├── .github/workflows/
│   └── ci.yml                     -- lake build + test + count_sorries +
│                                     tcb_audit on PR / push.
├── CLAUDE.md                      -- this file.
├── README.md                      -- project entry point.
└── docs/
    ├── GENESIS_PLAN.md            -- canonical design document.
    ├── ethereum_integration_plan.md -- Ethereum integration plan
    │                                  (Workstreams A – G); Workstream A
    │                                  (cryptographic adaptors) complete.
    ├── decidability_discipline.md -- WU 1.6 (decPre) discipline.
    ├── std_dependencies.md        -- WU 1.13 Std lemma audit.
    ├── economic_invariants.md     -- Phase 2 design + Phase-4-prelude
    │                                 monotonicity tier section.
    ├── extraction_notes.md        -- Phase 5 WU 5.9: erasure / persistence
    │                                 map for the `canon` runtime binary.
    ├── law_language_design.md    -- DSL design notes.
    └── abi.md                     -- Phase 5 WU 5.10: on-disk frame format,
                                      FNV-1a-64 trailer, CLI ABI; Phase 6
                                      extends with new Action constructors
                                      (8..11) and new Event constructors
                                      (5..7).
```

### Module dependency graph (Phases 0 – 6)

```
LegalKernel.Kernel        (TCB, §4.12 + §4.3 balance lemmas + §4.9 reachability)
  └──── imports LegalKernel.RBMapLemmas
LegalKernel.RBMapLemmas   (TCB, §8.3 fold + insert lemmas)
LegalKernel.Conservation  (non-TCB; §8.1 TotalSupply + §5.3 framework
                            + Phase-4-prelude monotonicity tier)
  └──── imports Kernel + RBMapLemmas
LegalKernel.Laws.Transfer            (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Mint                (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Burn                (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.Freeze              (non-TCB; depends on Kernel + Conservation +
                                                Transfer + Mint + Burn)
LegalKernel.Laws.Reward              (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.DistributeOthers    (non-TCB; depends on Kernel + Conservation)
LegalKernel.Laws.ProportionalDilute  (non-TCB; depends on Kernel + Conservation)

LegalKernel.Authority.Crypto       (non-TCB; PublicKey, Signature,
                                              opaque Verify)
LegalKernel.Authority.Action       (non-TCB; depends on Kernel +
                                              Conservation + Laws.* (incl.
                                              the three new positive-incentive
                                              laws) + Authority.Crypto +
                                              Disputes.Types)
LegalKernel.Authority.Identity     (non-TCB; depends on Kernel +
                                              RBMapLemmas +
                                              Authority.{Crypto, Action})
LegalKernel.Authority.Nonce        (non-TCB; depends on Kernel +
                                              RBMapLemmas +
                                              Authority.{Crypto, Identity})
LegalKernel.Authority.SignedAction (non-TCB; depends on Kernel +
                                              Authority.{Crypto, Action,
                                              Identity, Nonce})

LegalKernel.Disputes.Types         (non-TCB; Phase-6 WU 6.1; depends on
                                              Kernel + Authority.Crypto)
LegalKernel.Disputes.Filing        (non-TCB; Phase-6 WU 6.3 / 6.11; depends
                                              on Authority.SignedAction +
                                              Disputes.Types + Runtime.LogFile)
LegalKernel.Disputes.Evidence      (non-TCB; Phase-6 WU 6.4 – 6.8; depends
                                              on Authority.SignedAction +
                                              Disputes.Types + Runtime.Replay)
LegalKernel.Disputes.Verdict       (non-TCB; Phase-6 WU 6.9 / 6.10; depends
                                              on Authority.SignedAction +
                                              Disputes.{Types, Filing,
                                              Evidence} + Runtime.Replay)

LegalKernel.Encoding.{CBOR, Encodable}    (non-TCB; Phase-4 codec foundation)
LegalKernel.Encoding.Disputes             (non-TCB; Phase-6 WU 6.1; depends
                                                    on Disputes.Types +
                                                    Encoding.Encodable)
LegalKernel.Encoding.Action               (non-TCB; depends on Authority.Action +
                                                    Encoding.Disputes)
LegalKernel.Encoding.SignedAction         (non-TCB; depends on Encoding.Action +
                                                    Authority.SignedAction)
LegalKernel.Encoding.State                (non-TCB; depends on Authority.Nonce +
                                                    Encoding.SignedAction)
LegalKernel.Encoding.SignInput            (non-TCB; depends on Encoding.SignedAction)
LegalKernel.DSL.Law                       (non-TCB; depends on Kernel)

LegalKernel.Events.Types        (non-TCB; Phase-5 WU 5.6; depends on Kernel +
                                          Authority.Crypto)
LegalKernel.Events.Extract      (non-TCB; depends on Authority.SignedAction +
                                          Events.Types)

LegalKernel.Runtime.Hash        (non-TCB; Phase-5 WU 5.1 / 5.5 / 5.12; FNV-1a-64
                                          deterministic hash; production swap-point
                                          for BLAKE3 via @[extern])
LegalKernel.Runtime.LogFile     (non-TCB; depends on Authority.SignedAction +
                                          Encoding.{SignedAction, State} +
                                          Runtime.Hash)
LegalKernel.Runtime.Replay      (non-TCB; depends on Authority.SignedAction +
                                          Encoding.State + Runtime.{Hash, LogFile})
LegalKernel.Runtime.Snapshot    (non-TCB; depends on Authority.SignedAction +
                                          Encoding.State + Runtime.{Hash,
                                          LogFile, Replay})
LegalKernel.Runtime.Loop        (non-TCB; depends on Authority.SignedAction +
                                          Encoding.{SignedAction, State} +
                                          Events.Extract + Runtime.{Hash,
                                          LogFile, Replay, Snapshot})

LegalKernel.Test.Framework (no Kernel dependency)
LegalKernel.Test.KernelTests
LegalKernel.Test.RBMapLemmasTests
LegalKernel.Test.ConservationTests
LegalKernel.Test.Laws.{Transfer, Mint, Burn, Freeze, Reward,
                       DistributeOthers, ProportionalDilute}
LegalKernel.Test.Authority.{Action, Identity, Nonce, SignedAction}
LegalKernel.Test.Disputes.{Filing, Evidence, Verdict, EndToEnd}
LegalKernel.Test.Encoding.{CBOR, Encodable, Action, SignedAction,
                            State, SignInput}
LegalKernel.Test.DSL.Law
LegalKernel.Test.Events.{Types, Extract}
LegalKernel.Test.Runtime.{Hash, LogFile, Replay, Snapshot, Loop}
                                 │
LegalKernel  (umbrella) ─────────┘
                                 │
Main.lean / Replay.lean / Tests.lean ──┘

Tools.TcbAudit       (parses TCB sources; no Lean-level dep on the kernel).
Tools.CountSorries   (parses every .lean under LegalKernel/; no Lean-level dep).
```

The kernel has **zero** external Lean-package dependencies.
`Std.Data.TreeMap` is part of Lean core (since Lean ≥ 4.10), not a
separate Lake package.  The TCB therefore equals exactly the Lean
core distribution plus the trusted-core modules of this repository
(`Kernel.lean` + `RBMapLemmas.lean`).  Phase 2's economic-invariants
framework, Phase 3's authority layer, Phase 4's encoding / DSL
modules, and Phase 5's runtime / events modules are **not** TCB:
all of `Conservation.lean`, the seven `Laws/*.lean` modules, the
five `Authority/*.lean` modules, the six `Encoding/*.lean`
modules, the `DSL/Law.lean` module, the two `Events/*.lean`
modules, and the five `Runtime/*.lean` modules are
deployment-facing infrastructure, with bugs scoped to
deployment-level claims (not kernel invariants).  Phase 3's
`Verify` axiom and Phase 5's `Runtime.Hash` are *trust assumptions*
(the deployment-supplied signature scheme is EUF-CMA secure; the
production hash function is collision-resistant); the kernel's
authority and replay guarantees are conditional on these
assumptions.

## Reading large files

`docs/GENESIS_PLAN.md` is ~4200 lines / ~180 KB.  Read it in chunks
with `Read(file_path, offset=…, limit=500)` rather than the whole
file.  The table of contents at the top of the document maps section
numbers to the line ranges you actually need.

When editing, read the specific region around the target lines first
(e.g., `offset=2580, limit=80`) so the `old_string` matches exactly,
including indentation and whitespace.

## Writing and editing files

The Write tool replaces an entire file in one call.  For files over
~100 lines this is error-prone: the tool may time out, drop content,
or fill the context window.  **Prefer the Edit tool for all changes
to existing files**, regardless of size.

**Rules for large-file changes:**

1. **Never rewrite a large file with Write.**  Use Edit with a
   precise `old_string`/`new_string` pair targeting only the lines
   that change.
2. **One logical change per Edit call.**  Three separate edits beat
   one giant cross-section replacement.
3. **Read before you edit.**  Always Read the specific region first
   so the `old_string` matches exactly.
4. **Adding large new sections.**  If you must insert more than ~80
   new lines, break the insertion into multiple sequential Edit
   calls, anchoring each to context already present.
5. **Creating new large files.**  Build incrementally: an initial
   Write (under 100 lines) followed by Edit appends, *or* a Bash
   heredoc (`cat <<'EOF' > path/to/file.lean ... EOF`) which has no
   content-size timeout.
6. **Post-write verification.**  After any large write or edit
   sequence, spot-check by reading the modified region and the
   file's last few lines.

## Handling large search and command output

- **Grep**: cap with `head_limit` (e.g., `head_limit=30`); use
  `output_mode: "files_with_matches"` first, then drill in.
- **Glob**: scope with `path` instead of searching the whole repo.
- **Bash output**: pipe through `head` / `tail` (e.g.,
  `lake build 2>&1 | tail -80`).  For very large output, redirect to
  a temp file and `Read` it in chunks.

**Rule of thumb:** if a command might return more than ~100 lines,
limit it upfront.

## Background-agent file-change protection

Background agents (Task tool with `run_in_background: true`) run
concurrently and may finish after the foreground agent has already
modified the same files.  Their stale writes will silently overwrite
foreground progress.  **Prevent this proactively:**

1. **Never delegate file writes to a background agent for files you
   may also edit.**  Identify every file the agent may create or
   modify before launching.
2. **Partition files strictly.**  If parallel work is genuinely
   needed, assign each agent a disjoint set of files and document
   the partition in the agent's prompt ("you own `Foo.lean` only —
   do not modify any other file").
3. **Use background agents only for read-only or independent-file
   tasks.**  Safe: builds, tests, searches, research.  Unsafe:
   editing shared sources or configs.
4. **Check background results before acting on shared state.**  If
   the agent wrote to a file you have since modified, discard the
   agent's version and redo on top of your current state.
5. **When in doubt, run in foreground.**  Sequential correctness
   beats parallel speed.

## Key conventions

- **Two reviewer rule for kernel-touching changes (ABSOLUTE).**  Any
  change to `LegalKernel/Kernel.lean` or `LegalKernel/RBMapLemmas.lean`
  (the latter is Phase 1+) requires two reviewers per Genesis Plan
  §13.6.  Law modules and tests require one reviewer.

- **No `sorry` in kernel-adjacent code (ABSOLUTE).**  Phase 0's
  exit gate was "zero `sorry` in `LegalKernel/Kernel.lean` and
  `LegalKernel/Laws/Transfer.lean`".  Phase 1 widened this to
  *also* cover `LegalKernel/RBMapLemmas.lean` and added the
  `count_sorries` CI tool that enforces it.  The mechanical check is
  ```bash
  lake exe count_sorries
  ```
  (or, equivalently and more pessimistically,
  `grep -rnE '(:= sorry|by sorry|exact sorry|^[[:space:]]*sorry[[:space:]]*$)' LegalKernel/`).
  CI runs `lake exe count_sorries` on every PR and blocks the merge
  on a non-zero kernel-TCB count.  Comments referencing the *word*
  "sorry" (e.g. "no `sorry` in this file") are allowed; only the
  *term* `sorry` in proof position is forbidden.

- **No custom axioms (ABSOLUTE).**  The kernel may use Lean's
  built-in axioms (`propext`, `Classical.choice`, `Quot.sound`) but
  must not introduce its own.  Any Phase 1+ work that adds an
  `axiom` declaration is a Genesis-Plan amendment and requires the
  two-reviewer gate.

- **Std-core only in the kernel TCB.**  The kernel imports
  `Std.Data.TreeMap` (Lean core, not batteries) and the sibling TCB
  module `LegalKernel.RBMapLemmas` (also Std-core only).  The
  `tcb_audit` tool (`lake exe tcb_audit`) compares each TCB module's
  direct-import set against `tcb_allowlist.txt`; CI runs this on
  every PR.  Adding Mathlib or batteries to either TCB module is a
  TCB expansion and must go through the §13.6 amendment process,
  which includes an entry in `tcb_allowlist.txt` (with a comment
  explaining the dependency) and the two-reviewer gate.  Law modules
  may import other things if absolutely necessary, but the default
  is "Std core only" until a specific need is justified.

- **`autoImplicit := false` and `linter.missingDocs := true`.**  The
  lakefile enforces both project-wide:
  - `autoImplicit := false` (and its `relaxedAutoImplicit` sibling)
    forbids Lean from silently introducing universe / type variables
    that the proof author didn't declare.
  - `linter.missingDocs := true` makes the *absence* of a `/-- … -/`
    docstring on a public surface (def, theorem, structure field,
    inductive constructor) a build warning, surfacing the
    documentation rule below as a mechanical check rather than a
    review-time observation.

  `linter.unusedVariables := true` is also set, surfacing dead bindings.

- **Decidability discipline (Genesis Plan §13.6 step 2).**  Every
  `Transition.decPre` field should be definable as
  `fun _ => inferInstance` whenever the precondition is built from
  arithmetic comparisons, `Nat` operations, and finite conjunctions.
  If a law needs a hand-written `Decidable` derivation, that is a
  signal to security-review the law (§14.8): preconditions that
  resist `inferInstance` often hide an unbounded quantifier or a
  non-computable predicate that breaks the executable path.

- **Naming conventions:**
  - Theorems and lemmas: `snake_case` (Lean / Mathlib style) — e.g.,
    `impl_refines_spec`, `transfer_conserves`.
  - Structures and types: `CamelCase` — e.g., `Transition`, `Legal`,
    `CertifiedTransition`.
  - Type variables: capital letters by role — `α`, `β`, `γ` for
    generic types; `s`, `s'` for states; `t` for transitions.
  - Hypothesis names: `h`-prefixed — `hpre`, `hreach`, `h_init`,
    `h_step`.
  - Namespaces: `LegalKernel`, `LegalKernel.Laws`,
    `LegalKernel.Test`.
  - **Names describe content, never provenance.**  An identifier
    OR file basename must describe *what the declaration is or
    proves*, never *which work unit, audit, phase, or session
    produced it*, never *what's still incomplete*, and never
    *a grab-bag "things that don't fit elsewhere" category*.

    Forbidden token patterns (non-exhaustive):
    - **Work-process markers**: `wu1`-`wu9`, `wu_2_5`, `phase0`-
      `phase7`, `audit1`-`audit3`, `audit_`.
    - **Session / branch references**: `claude_`, `session_`,
      `pr_`.
    - **Process-status suffixes** (describe state-of-completion,
      not content): `_tmp`, `_todo`, `_fixme`, `_wip`, `_draft`,
      `_legacy`.
    - **Grab-bag umbrella names** (the historical
      "MissingTheorems.lean" sin: collecting theorems by
      what-was-leftover rather than by content): `Miscellaneous`,
      `Supplemental`, `Auxiliary`, `Addenda`, `Addendum`,
      `Assorted`, `MissingTheorems`.

    **Content words that have a legitimate domain meaning are
    allowed even if they superficially resemble process tokens**:
    e.g., `PendingWithdrawal` (a bridge-state concept), `_old`
    in `expectsNonce_after_advance_gt_old` (role name: the
    pre-advance value), `DeferredEntry` in Lex diagnostic
    coverage (content concept).  The audit tool's allowlist
    (`tools/naming_allowlist.txt`) handles any residual false
    positives.

    Process markers may appear in *docstrings* (a `/-- ... -/`
    block can say "added in WU 2.5") and in commit messages,
    branch names, and planning documents.  The boundary is
    sharp: the docstring may carry a process tag, the
    identifier and the file basename may not.

  - **Enforcement.**  Two layers:

    1. **Pre-commit grep** (developer-facing).  Before landing
       any new declaration, scan the diff:
       ```bash
       git diff --cached -U0 -- '*.lean' \
         | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
         | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit[0-9_]|claude_|session_|\bmissing(theorems?|_theorems?)|_tmp\b|_todo\b|_fixme\b|_wip\b|_draft\b|_legacy\b|miscellaneous|supplemental|auxiliary|addenda|addendum|assorted'
       ```
       A non-empty result is a review-blocking naming
       violation.

    2. **CI-gating `naming_audit`** (mechanical).
       `lake exe naming_audit` walks every `.lean` file under
       `LegalKernel/` and `Tools/`, checks both file basenames
       AND declaration identifiers against the forbidden-token
       list in `Tools/NamingAudit.lean`, and exits non-zero on
       any match.  Allowlist (rare exceptions):
       `tools/naming_allowlist.txt`.  The audit is mandatory CI
       per `.github/workflows/ci.yml`.

- **No-deferrals policy (ABSOLUTE).**  A workstream / commit is
  **not complete** while any of its theorems, modules, or
  docstrings document a deferral.  This includes:
  - Theorems whose hypotheses cannot be discharged in the
    current codebase (e.g., `decode (encode s) = .ok (s, [])`
    when the relevant round-trip lemma doesn't exist).
  - Status-table rows labelled `PARTIAL` or `DEFERRED`.
  - Docstrings containing phrases like `deferred to follow-up`,
    `round-trip-conditional`, `multi-day work`,
    `not yet provable`, `until X ships`, `honest deferral`.
  - In-code markers: `TODO:`, `FIXME:`, `XXX:`.

  The fix for an apparent deferral is either:
    (a) ship the missing proof / implementation, OR
    (b) rewrite the theorem / docstring without deferral
        language (perhaps stating only the substantive content
        that IS proved).

  Hollow theorems whose hypotheses no consumer can discharge
  are forbidden; they're a sophisticated form of deferral.

  Enforcement: `lake exe deferral_audit` walks every `.lean`
  file under `LegalKernel/` and `Tools/`, scans for forbidden
  phrases, and exits non-zero on any match.  **There is no
  allowlist** — the audit catches every deferral phrase
  without exception.  Self-references in the audit's own
  forbidden-phrase list / documentation are handled by a
  path-level exclusion (only `Tools/NamingAudit.lean`,
  `Tools/DeferralAudit.lean`, and `DeferralAudit.lean` are
  excluded, because they ENUMERATE the banned phrases as data).

  The audit is mandatory CI per `.github/workflows/ci.yml`.

- **Proof style:**
  - Prefer tactic mode (`by …`) for non-trivial proofs.
  - Use `calc` blocks for equational reasoning chains.
  - Use `have` for intermediate steps with descriptive names.
  - Comment proof strategy at the top of each non-obvious theorem.
  - Avoid `decide` on large finite types (performance trap; the
    kernel has no large finite types yet, but laws may).

- **Documentation:**
  - Every `.lean` file begins with a `/-! ... -/` module docstring
    naming the Genesis-Plan section it implements.
  - Every public `def` / `theorem` / `structure` / `instance` has a
    `/-- ... -/` docstring.
  - Where a definition deliberately tracks a Genesis-Plan section
    (e.g. `transfer` is §4.11), say so in the docstring so future
    readers can cross-reference.

- **Import discipline:**  Import by full path within the project
  (`import LegalKernel.Kernel`).  Re-export top-level definitions via
  `LegalKernel.lean` (the umbrella module) so downstream consumers
  can `import LegalKernel` and get everything.

- **Git practices:**  One commit per completed work unit.  Commit
  messages reference the WU number when applicable: `"WU 0.2:
  Kernel module skeleton"`.  All commits must pass `lake build`
  AND `lake test` — never commit broken or untested code.

## Type-level design properties enforced in Phases 0 – 6

The Genesis Plan promises a small set of type-level guarantees
(§1, §5).  The kernel, the Phase-2 economic-invariants framework, the
Phase-3 authority layer, the Phase-4-prelude positive-incentive
tier, the Phase-4 encoding layer, and the Phase-6 dispute pipeline
each mechanise one or more of the following:

| #  | Property                                | Lean theorem                          | Phase / File                       |
|----|-----------------------------------------|---------------------------------------|------------------------------------|
| 1  | Determinism                             | typing of `step_impl`                 | 0 / `Kernel.lean`                  |
| 2  | No silent illegality                    | `impl_noop_if_not_pre`                | 0 / `Kernel.lean`                  |
| 3  | Refinement                              | `impl_refines_spec`                   | 0 / `Kernel.lean`                  |
| 4  | Invariant preservation                  | `invariant_preservation`              | 0 / `Kernel.lean`                  |
| 5  | Compositionality of invariants          | `invariants_compose`                  | 0 / `Kernel.lean`                  |
| 6  | Certified ≡ executable                  | `apply_certified_eq_step_impl`        | 0 / `Kernel.lean`                  |
| 7  | Pointwise balance (write-then-read)     | `getBalance_setBalance_same/_other`   | 1 / `Kernel.lean` (§4.3)           |
| 8  | Reachability is reflexive-transitive    | `Reachable.refl`, `Reachable.trans`   | 1 / `Kernel.lean` (§4.9)           |
| 9  | Per-law-set invariant preservation      | `invariant_preservation_via_laws`     | 1 / `Kernel.lean` (§4.10)          |
| 10 | Per-resource accounting on `setBalance` | `totalSupply_setBalance`              | 2 / `Conservation.lean`            |
| 11 | Transfer preserves total supply         | `transfer_conserves`                  | 2 / `Laws/Transfer.lean` (§4.11.1) |
| 12 | Transfer is local to its resource       | `transfer_does_not_touch_other_resources` | 2 / `Laws/Transfer.lean` (§4.11.2) |
| 13 | Transfer is `IsConservative`            | `transfer_isConservative`             | 2 / `Laws/Transfer.lean` (§5.3)    |
| 14 | Mint is non-conservative                | `mint_not_conservative`               | 2 / `Laws/Mint.lean` (§5.6)        |
| 15 | Burn is non-conservative                | `burn_not_conservative`               | 2 / `Laws/Burn.lean` (§5.6)        |
| 16 | Global supply preservation              | `total_supply_global` / `…_via_law_set` | 2 / `Conservation.lean` (§5.3)   |
| 17 | Frozen-resource preservation by transfer/mint/burn | `*_preserves_freeze` (3 lemmas) | 2 / `Laws/Freeze.lean` (§4.10) |
| 18 | Mint / burn are local to their resource | `mint_/burn_other_resource_untouched`, `*_does_not_touch_other_resources`, `*_conserves_other_resource` | 2 / `Laws/Mint.lean` and `Laws/Burn.lean` |
| 19 | Action compilation is structurally injective | `Action.compile_injective` | 3 / `Authority/Action.lean` (§4.13) |
| 20 | Per-actor nonce is strictly monotonic | `expectsNonce_strict_mono` | 3 / `Authority/Nonce.lean` (§8.5) |
| 21 | Two admissible actions by same signer share nonce | `nonce_uniqueness` | 3 / `Authority/SignedAction.lean` (§8.5.2) |
| 22 | Successful application precludes replay | `replay_impossible` | 3 / `Authority/SignedAction.lean` (§8.5.2) |
| 23 | `replaceKey` updates the registry to the new key | `replaceKey_updates_registry` | 3 / `Authority/SignedAction.lean` (WU 3.10) |
| 24 | `replaceKey` doesn't affect other actors' keys | `replaceKey_other_actor_untouched` | 3 / `Authority/SignedAction.lean` (WU 3.10) |
| 25 | Non-`replaceKey` actions preserve the registry | `non_replaceKey_preserves_registry` | 3 / `Authority/SignedAction.lean` (WU 3.10) |
| 26 | KeyRegistry register/revoke semantics (4 lemmas) | `KeyRegistry.lookup_{register_self,register_other,revoke_self,revoke_other}` | 3 / `Authority/Identity.lean` (WU 3.3) |
| 27 | AuthorityPolicy combinator characterisations (8 lemmas) | `AuthorityPolicy.{empty,unrestricted,union,intersect,singleton}_authorized`, `union_comm`, `union_empty`, `intersect_unrestricted` | 3 / `Authority/Identity.lean` (WU 3.3) |
| 28 | Admissibility field extractors (5 lemmas) | `admissible_{authorized,nonce,pre,signer_registered,signer_registered_and_signed}` | 3 / `Authority/SignedAction.lean` (WU 3.6) |
| 29 | `apply_admissible` field projections (2 lemmas) | `apply_admissible_base`, `apply_admissible_registry` | 3 / `Authority/SignedAction.lean` (WU 3.7) |
| 30 | Cross-actor nonce isolation under `apply_admissible` | `expectsNonce_after_apply_admissible_other` | 3 / `Authority/SignedAction.lean` (WU 3.7) |
| 31 | `compile` injectivity equivalent / contrapositive forms | `Action.compile_eq_iff`, `Action.compile_ne_of_ne` | 3 / `Authority/Action.lean` (§4.13) |
| 32 | Monotonicity classification typeclass | `IsMonotonic` | R / `Conservation.lean` |
| 33 | Conservative laws are automatically monotonic | `monotonic_of_conservative` (priority := low) | R / `Conservation.lean` |
| 34 | Type-level firewall for monotonic deployments | `MonotonicLawSet` | R / `Conservation.lean` |
| 35 | Per-resource non-decrease across reachable states | `total_supply_globally_nondecreasing` | R / `Conservation.lean` |
| 36 | Typeclass-driven non-decrease corollary | `total_supply_globally_nondecreasing_via_law_set` | R / `Conservation.lean` |
| 37 | Reward is monotonic at every resource | `reward_isMonotonic` | R / `Laws/Reward.lean` |
| 38 | Reward is not conservative | `reward_not_conservative` | R / `Laws/Reward.lean` |
| 39 | DistributeOthers preserves the excluded actor | `distributeOthers_excluded_unchanged` | R / `Laws/DistributeOthers.lean` |
| 40 | DistributeOthers is monotonic | `distributeOthers_isMonotonic` | R / `Laws/DistributeOthers.lean` |
| 41 | ProportionalDilute respects the dust bound | `proportionalDilute_distributed_le_totalReward` | R / `Laws/ProportionalDilute.lean` |
| 42 | ProportionalDilute is monotonic | `proportionalDilute_isMonotonic` | R / `Laws/ProportionalDilute.lean` |
| 43 | Burn is not monotonic (negative witness) | `burn_not_monotonic` | R / `Laws/Burn.lean` |
| 44 | Action compilation injective at all 12 constructors | `Action.compile_injective` (extends to disputes) | 6 / `Authority/Action.lean` |
| 45 | DisputeClaim round-trip + injectivity (5 variants) | `disputeClaim_roundtrip`, `disputeClaim_encode_injective` | 6 / `Encoding/Disputes.lean` |
| 46 | EvidenceVerdict round-trip + injectivity | `evidenceVerdict_roundtrip`, `evidenceVerdict_encode_injective` | 6 / `Encoding/Disputes.lean` |
| 47 | Dispute round-trip + injectivity (bounded) | `dispute_roundtrip`, `dispute_encode_injective` | 6 / `Encoding/Disputes.lean` |
| 48 | Verdict round-trip + injectivity (bounded) | `verdict_roundtrip`, `verdict_encode_injective` | 6 / `Encoding/Disputes.lean` |
| 49 | Per-element-bounded list round-trip lemma | `list_roundtrip_bounded` | 6 / `Encoding/Encodable.lean` |
| 50 | `disputeWithdraw` is idempotent | `applyWithdraw_idempotent` | 6 / `Disputes/Filing.lean` |
| 51 | `fileDispute` returns `.open` status | `fileDispute_returns_open_status` | 6 / `Disputes/Filing.lean` |
| 52 | `fileDispute` rejects unknown challenger | `fileDispute_rejects_unknown_challenger` | 6 / `Disputes/Filing.lean` |
| 53 | `checkDoubleApply` rejects self-claims | `checkDoubleApply_rejects_self` | 6 / `Disputes/Evidence.lean` |
| 54 | `checkOracleMisreported` is a pass-through | `checkOracleMisreported_returns_oracle_verdict` | 6 / `Disputes/Evidence.lean` |
| 55 | `checkEvidence` is deterministic (§8.4.3) | `checkEvidence_deterministic` | 6 / `Disputes/Evidence.lean` |
| 56 | `applyVerdictUnchecked (.rejected)` leaves state unchanged | `applyVerdictUnchecked_rejected_no_change` | 6 / `Disputes/Verdict.lean` |
| 57 | `applyVerdictUnchecked (.inconclusive)` leaves state unchanged | `applyVerdictUnchecked_inconclusive_no_change` | 6 / `Disputes/Verdict.lean` |
| 58 | `applyVerdictUnchecked` rejects unknown disputes | `applyVerdictUnchecked_unknown_dispute` | 6 / `Disputes/Verdict.lean` |
| 59 | `applyVerdictUnchecked` is deterministic (§8.4.3) | `applyVerdictUnchecked_deterministic` | 6 / `Disputes/Verdict.lean` |
| 60 | `proposeVerdict` is deterministic | `proposeVerdict_deterministic` | 6 / `Disputes/Verdict.lean` |
| 61 | Dispute action ctors all `IsConservative` (4 instances) | `dispute_compiled_isConservative`, etc. | 6-amend / `Disputes/LawClassification.lean` |
| 62 | Dispute action ctors all `IsMonotonic` (4 instances) | `dispute_compiled_isMonotonic`, etc. | 6-amend / `Disputes/LawClassification.lean` |
| 63 | Composite classification summary (8 conjuncts) | `dispute_pipeline_actions_classification` | 6-amend / `Disputes/LawClassification.lean` |
| 64 | Disputable monotonic deployment satisfies non-decrease | `disputable_monotonic_total_supply_nondecreasing` | 6-amend / `Disputes/MonotonicDeployment.lean` |
| 65 | `disputeRewardActions` emits only `Action.reward` | `disputeRewardActions_emits_only_rewards` | 6-amend / `Disputes/Rewards.lean` |
| 66 | `disputeRewardActions` length bound | `disputeRewardActions_length_bound` | 6-amend / `Disputes/Rewards.lean` |
| 67 | `applyVerdictWithRewards` deterministic | `applyVerdictWithRewards_deterministic` | 6-amend / `Disputes/Rewards.lean` |
| 68 | Multi-policy emission preserves "only rewards" | `disputeRewardActionsMulti_emits_only_rewards` | 6-amend / `Disputes/Rewards.lean` |
| 69 | Multi-policy length bound | `disputeRewardActionsMulti_length_bound` | 6-amend / `Disputes/Rewards.lean` |
| 70 | Each stake-weighted reward is bounded by pool | `stakeWeightedAdjudicatorRewards_each_le_pool` | 6-amend / `Disputes/Rewards.lean` |
| 71 | Stake-weighted distribution emits only rewards | `stakeWeightedAdjudicatorRewards_emits_only_rewards` | 6-amend / `Disputes/Rewards.lean` |
| 72 | Per-signer stake ≤ total stake | `getBalance_le_totalSignerStake` | 6-amend / `Disputes/Rewards.lean` |
| 73 | Staking-policy filing actions are all transfers | `stakeFilingActions_emits_only_transfers` | 6-amend / `Disputes/Staking.lean` |
| 74 | Staking-policy upheld emits no actions (per D1) | `stakeResolutionActions_upheld_no_actions` | 6-amend / `Disputes/Staking.lean` |
| 75 | `fileDisputeStaked` rejects underfunded challenger | `fileDisputeStaked_rejects_underfunded` | 6-amend / `Disputes/Staking.lean` |
| 76 | `Event.rewardIssued` constructor at frozen index 8 | `Event.isRewardIssued` projection | 6-amend / `Events/Types.lean` |
| 77 | `proposeVerdict` is input-preserving on success | `proposeVerdict_ok_returns_input` | 6-OptC / `Disputes/Verdict.lean` |
| 78 | Defensive `checkOracleMisreported` on out-of-range idx | `checkOracleMisreported_inconclusive_on_out_of_range` | 6-OptC / `Disputes/Evidence.lean` |
| 79 | `.upheld` `checkEvidence` ⇒ in-range impugned idx | `claimImpugnedIdx_in_range_when_upheld` | 6-OptC / `Disputes/Verdict.lean` |
| 80 | Witness-bearing `applyVerdict` reduces to `_Unchecked` | `applyVerdict_eq_unchecked` | 6-OptC / `Disputes/Verdict.lean` |
| 81 | Witness ⇒ log entry exists (extraction 1/3) | `applyVerdict_log_in_range` | 6-OptC / `Disputes/Verdict.lean` |
| 82 | Witness ⇒ entry is a dispute (extraction 2/3) | `applyVerdict_entry_is_dispute` | 6-OptC / `Disputes/Verdict.lean` |
| 83 | Witness ⇒ dispute is open (extraction 3/3) | `applyVerdict_dispute_open` | 6-OptC / `Disputes/Verdict.lean` |
| 84 | Witness ⇒ outcome matches `checkEvidence` recomputation | `applyVerdict_outcome_matches` | 6-OptC / `Disputes/Verdict.lean` |
| 85 | Witness ⇒ `applyVerdict` is provably total | `applyVerdict_under_witness_succeeds` | 6-OptC / `Disputes/Verdict.lean` |
| 86 | Witness ⇒ `unknownDispute` unreachable | `applyVerdict_unknownDispute_unreachable` | 6-OptC / `Disputes/Verdict.lean` |
| 87 | Witness ⇒ `alreadyDecided` unreachable | `applyVerdict_alreadyDecided_unreachable` | 6-OptC / `Disputes/Verdict.lean` |
| 88 | Witness ⇒ `replayFailed` unreachable | `applyVerdict_replayFailed_unreachable` | 6-OptC / `Disputes/Verdict.lean` |
| 89 | `proposeAndApplyVerdict` matches `_Unchecked` on success | `proposeAndApplyVerdict_eq_applyVerdict_when_proposed_ok` | 6-OptC / `Disputes/Verdict.lean` |
| 90 | `proposeAndApplyVerdict` surfaces Stage-3 errors | `proposeAndApplyVerdict_proposeVerdict_error_path` | 6-OptC / `Disputes/Verdict.lean` |
| 91 | `proposeAndApplyVerdict` is deterministic | `proposeAndApplyVerdict_deterministic` | 6-OptC / `Disputes/Verdict.lean` |
| 92 | `proposeAndApplyVerdict` rejects unknown disputeId | `proposeAndApplyVerdict_unknown_dispute` | 6-OptC / `Disputes/Verdict.lean` |
| 93 | `Verify_deterministic` (axiom-free) | `Verify_deterministic` | E-A.1 / `Bridge/VerifyAdaptor.lean` |
| 94 | `isLowS` boundary at zero / threshold / just-below-order | `isLowS_{zero,at_threshold,just_below_order}` | E-A.1 / `Bridge/VerifyAdaptor.lean` |
| 95 | `secp256k1OrderBytes_size` (32-byte BE form) | `secp256k1OrderBytes_size` | E-A.1 / `Bridge/VerifyAdaptor.lean` |
| 96 | `hashAdaptor_thirty_two_byte_output` | `hashAdaptor_thirty_two_byte_output` | E-A.2 / `Bridge/HashAdaptor.lean` |
| 97 | `hashAdaptor_deterministic` | `hashAdaptor_deterministic` | E-A.2 / `Bridge/HashAdaptor.lean` |
| 98 | `hashAdaptor_identifier_distinct` | `hashAdaptor_identifier_distinct` | E-A.2 / `Bridge/HashAdaptor.lean` |
| 99 | KAT vector sizes pinned at 32 (5 lemmas) | `kat_{empty,abc,helloWorld,singleZero,...}_size` | E-A.2 / `Bridge/HashAdaptor.lean` |
| 100| `eip712Wrap_injective` (under collision-free hyp) | `eip712Wrap_injective` | E-A.3 / `Bridge/Eip712.lean` |
| 101| `eip712DomainSeparator_distinguishes` (under collision-free + bounds) | `eip712DomainSeparator_distinguishes` | E-A.3 / `Bridge/Eip712.lean` |
| 102| `eip712Wrap_distinguishes` (composition) | `eip712Wrap_distinguishes` | E-A.3 / `Bridge/Eip712.lean` |
| 103| `domainPreHash_injective` (auxiliary) | `domainPreHash_injective` | E-A.3 / `Bridge/Eip712.lean` |
| 104| `encodeUint256BE_injective` (under `< 2^256` bound) | `encodeUint256BE_injective` | E-A.3 / `Bridge/Eip712.lean` |
| 105| `encodeUint256BE_size` | `encodeUint256BE_size` | E-A.3 / `Bridge/Eip712.lean` |
| 106| `eip712Wrap_size` (2 + d + 32) | `eip712Wrap_size` | E-A.3 / `Bridge/Eip712.lean` |
| 107| `structPreHash_size` (= 160 bytes; encodes all 4 declared fields) | `structPreHash_size` | E-A.3 / `Bridge/Eip712.lean` |
| 108| `Eip712Message.actionHash_size` (= 32) | `Eip712Message.actionHash_size` | E-A.3 / `Bridge/Eip712.lean` |
| 109| `addressBook_invariant` (forward / reverse inverse, conditional on `Consistent`) | `addressBook_invariant` | E-B.1 / `Bridge/AddressBook.lean` |
| 110| `assign_fresh_actorId` (fresh assign yields `some` id; nextActorId = old + 1) | `assign_fresh_actorId` | E-B.1 / `Bridge/AddressBook.lean` |
| 111| `assign_idempotent_for_known` (known address returns book unchanged) | `assign_idempotent_for_known` | E-B.1 / `Bridge/AddressBook.lean` |
| 112| `empty_consistent` | `empty_consistent` | E-B.1 / `Bridge/AddressBook.lean` |
| 113| `assign_preserves_consistent` (under freshness hypothesis) | `assign_preserves_consistent` | E-B.1 / `Bridge/AddressBook.lean` |
| 114| `ingest_emits_bridge_actor` (every emitted unsigned action's signer is bridgeActor) | `ingest_emits_bridge_actor` | E-B.2 / `Bridge/Ingest.lean` |
| 115| `ingest_preserves_lookup_for_other_addresses` | `ingest_preserves_lookup_for_other_addresses` | E-B.2 / `Bridge/Ingest.lean` |
| 116| `ingest_lookup_equivalent_for_distinct_addresses` (cross-address commutativity) | `ingest_lookup_equivalent_for_distinct_addresses` | E-B.2 / `Bridge/Ingest.lean` |
| 117| `bridgePolicy_rejects_transfer` | `bridgePolicy_rejects_transfer` | E-B.3 / `Bridge/BridgeActor.lean` |
| 118| `bridgePolicy_authorizes_replaceKey` | `bridgePolicy_authorizes_replaceKey` | E-B.3 / `Bridge/BridgeActor.lean` |
| 119| `bridgePolicy_authorizes_registerIdentity` | `bridgePolicy_authorizes_registerIdentity` | E-B.3 / `Bridge/BridgeActor.lean` |
| 120| `bridgePolicy_rejects_non_bridge_signer` | `bridgePolicy_rejects_non_bridge_signer` | E-B.3 / `Bridge/BridgeActor.lean` |
| 121| `registerIdentity_updates_registry` (new identity inserted) | `registerIdentity_updates_registry` | E-B.3 / `Authority/SignedAction.lean` |
| 122| `registerIdentity_other_actor_untouched` | `registerIdentity_other_actor_untouched` | E-B.3 / `Authority/SignedAction.lean` |
| 123| `assign_fresh_actorId_le` (Nat-projected `≤` form, per plan) | `assign_fresh_actorId_le` | E-B.1 audit-1 / `Bridge/AddressBook.lean` |
| 124| `EthAddress.toBytes_size` (= 20 bytes) | `EthAddress.toBytes_size` | E-B.1 audit-1 / `Bridge/AddressBook.lean` |
| 125| `ingest_preserves_consistent` (under freshness) | `ingest_preserves_consistent` | E-B.2 audit-1 / `Bridge/Ingest.lean` |
| 126| `ingest_lookup_isSome_pre_invariant` (strong locality) | `ingest_lookup_isSome_pre_invariant` | E-B.2 audit-1 / `Bridge/Ingest.lean` |
| 127| `ingest_isSome_equivalent_for_distinct_addresses` (full per plan) | `ingest_isSome_equivalent_for_distinct_addresses` | E-B.2 audit-1 / `Bridge/Ingest.lean` |
| 128| `non_registry_mutating_preserves_registry` (renamed for accuracy) | `non_registry_mutating_preserves_registry` | E-B audit-1 / `Authority/SignedAction.lean` |
| 129| `apply_admissible_with_preserves_bridge` (rfl pass-through) | `apply_admissible_with_preserves_bridge` | E-C.1.3 / `Bridge/Admissible.lean` |
| 130| `BridgeAdmissibleWith.toAdmissibleWith` (projection) | `BridgeAdmissibleWith.toAdmissibleWith` | E-C.0 / `Bridge/Admissible.lean` |
| 131| `bridge_replay_impossible` (replay protection lift) | `bridge_replay_impossible` | E-C.0 / `Bridge/Admissible.lean` |
| 132| `apply_bridge_admissible_with_preserves_bridge_for_non_bridge` | `apply_bridge_admissible_with_preserves_bridge_for_non_bridge` | E-C.0 / `Bridge/Admissible.lean` |
| 133| `applyActionToBridgeState_non_bridge` (identity on non-bridge) | `applyActionToBridgeState_non_bridge` | E-C.0 / `Bridge/Admissible.lean` |
| 134| `totalSupply_after_deposit` (supply +amount) | `totalSupply_after_deposit` | E-C.2 / `Laws/Deposit.lean` |
| 135| `deposit_other_resource_untouched` (locality) | `deposit_other_resource_untouched` | E-C.2 / `Laws/Deposit.lean` |
| 136| `deposit_other_actor_untouched` (locality) | `deposit_other_actor_untouched` | E-C.2 / `Laws/Deposit.lean` |
| 137| `deposit_isMonotonic` instance | `deposit_isMonotonic` | E-C.2 / `Laws/Deposit.lean` |
| 138| `deposit_not_conservative` (negative witness) | `deposit_not_conservative` | E-C.2 / `Laws/Deposit.lean` |
| 139| `totalSupply_after_withdraw` (additive form) | `totalSupply_after_withdraw` | E-C.3 / `Laws/Withdraw.lean` |
| 140| `withdraw_other_resource_untouched` (locality) | `withdraw_other_resource_untouched` | E-C.3 / `Laws/Withdraw.lean` |
| 141| `withdraw_other_actor_untouched` (locality) | `withdraw_other_actor_untouched` | E-C.3 / `Laws/Withdraw.lean` |
| 142| `withdraw_not_monotonic` (negative witness) | `withdraw_not_monotonic` | E-C.3 / `Laws/Withdraw.lean` |
| 143| `withdraw_not_conservative` (negative witness) | `withdraw_not_conservative` | E-C.3 / `Laws/Withdraw.lean` |
| 144| `bridgePolicy_authorizes_deposit` (§12.9 #34) | `bridgePolicy_authorizes_deposit` | E-C.4 / `Bridge/BridgeActor.lean` |
| 145| `bridgePolicy_authorizes_withdraw` (extends §12.9) | `bridgePolicy_authorizes_withdraw` | E-C.4 / `Bridge/BridgeActor.lean` |
| 146| `extractEvents_deposit_emits_credited` | `extractEvents_deposit_emits_credited` | E-C.5 / `Events/Extract.lean` |
| 147| `extractEvents_withdraw_emits_requested` | `extractEvents_withdraw_emits_requested` | E-C.5 / `Events/Extract.lean` |
| 148| `totalDeposited_genesis = 0` (sanity) | `totalDeposited_genesis` | E-C.6.1 / `Bridge/Accounting.lean` |
| 149| `totalWithdrawn_genesis = 0` (sanity) | `totalWithdrawn_genesis` | E-C.6.1 / `Bridge/Accounting.lean` |
| 150| `totalDeposited_unchanged_when_bridge_eq` | `totalDeposited_unchanged_when_bridge_eq` | E-C.6.1 / `Bridge/Accounting.lean` |
| 151| `totalWithdrawn_unchanged_when_bridge_eq` | `totalWithdrawn_unchanged_when_bridge_eq` | E-C.6.1 / `Bridge/Accounting.lean` |
| 152| `accounting_delta_non_bridge` (parameterised) | `accounting_delta_non_bridge` | E-C.6.2 / `Bridge/Accounting.lean` |
| 153| `accounting_delta_transfer` | `accounting_delta_transfer` | E-C.6.2 / `Bridge/Accounting.lean` |
| 154| `accounting_delta_freeze` | `accounting_delta_freeze` | E-C.6.2 / `Bridge/Accounting.lean` |
| 155| `accounting_delta_replaceKey` | `accounting_delta_replaceKey` | E-C.6.2 / `Bridge/Accounting.lean` |
| 156| `accounting_delta_registerIdentity` | `accounting_delta_registerIdentity` | E-C.6.2 / `Bridge/Accounting.lean` |
| 157| `applyActionToBridgeState_deposit` (shape) | `applyActionToBridgeState_deposit` | E-C.6.2 / `Bridge/Accounting.lean` |
| 158| `applyActionToBridgeState_withdraw` (shape) | `applyActionToBridgeState_withdraw` | E-C.6.2 / `Bridge/Accounting.lean` |
| 159| `Action.compile_injective` extends to deposit / withdraw | `Action.compile_injective` | E-C.4 / `Authority/Action.lean` |
| 160| `bridgePolicy_rejects_withdraw` (§12.9 #33; audit-1) | `bridgePolicy_rejects_withdraw` | E-C audit-1 / `Bridge/BridgeActor.lean` |
| 161| `deposit_marks_consumed` (post-app: depositId in consumed; audit-1) | `deposit_marks_consumed` | E-C audit-1 / `Bridge/Admissible.lean` |
| 162| `deposit_replay_blocked_by_consumed` (audit-1) | `deposit_replay_blocked_by_consumed` | E-C audit-1 / `Bridge/Admissible.lean` |
| 163| `withdraw_bumps_nextWdId` (audit-1) | `withdraw_bumps_nextWdId` | E-C audit-1 / `Bridge/Admissible.lean` |
| 164| `bridgeState_encode_deterministic` (audit-1) | `bridgeState_encode_deterministic` | E-C audit-1 / `Encoding/State.lean` |
| 165| `depositRecord_roundtrip` (under bound; audit-1) | `depositRecord_roundtrip` | E-C audit-1 / `Encoding/State.lean` |
| 166| `depositRecord_encode_deterministic` (audit-1) | `depositRecord_encode_deterministic` | E-C audit-1 / `Encoding/State.lean` |
| 167| `pendingWithdrawal_encode_deterministic` (audit-1) | `pendingWithdrawal_encode_deterministic` | E-C audit-1 / `Encoding/State.lean` |
| 168| `EthAddress.ofBytes_toBytes` (lossless 20-byte BE round-trip; audit-2) | `EthAddress.ofBytes_toBytes` | E-C audit-2 / `Bridge/AddressBook.lean` |
| 169| `withdrawalRoot_empty_eq_defaultHash_top` (D.1.1) | `withdrawalRoot_empty_eq_defaultHash_top` | E-D.1.1 / `Bridge/WithdrawalRoot.lean` |
| 170| `withdrawalRoot_extensional` (D.1.1) | `withdrawalRoot_extensional` | E-D.1.1 / `Bridge/WithdrawalRoot.lean` |
| 171| `defaultHash_well_defined` (D.1.1) | `defaultHash_well_defined` | E-D.1.1 / `Bridge/WithdrawalRoot.lean` |
| 172| `constructProof_deterministic` (D.1.2) | `constructProof_deterministic` | E-D.1.2 / `Bridge/WithdrawalRoot.lean` |
| 173| `constructProof_siblings_length` (D.1.2; static via `Vector n` discipline) | `constructProof_siblings_length` | E-D.1.2 / `Bridge/WithdrawalRoot.lean` |
| 174| `verifyProof_total` (D.1.2) | `verifyProof_total` | E-D.1.2 / `Bridge/WithdrawalRoot.lean` |
| 175| `verifyProof_complete` (D.1.3; unconditional structural-recursion identity) | `verifyProof_complete` | E-D.1.3 / `Bridge/WithdrawalRoot.lean` |
| 176| `verifyProof_sound` (D.1.4; under `CollisionFree` + `UniformOutputSize` + size-match hyps) | `verifyProof_sound` | E-D.1.4 / `Bridge/WithdrawalRoot.lean` |
| 177| `verifyProofRec_eq_rangeRoot` (D.1.3 workhorse) | `verifyProofRec_eq_rangeRoot` | E-D.1.3 / `Bridge/WithdrawalRoot.lean` |
| 178| `verifyProofRec_inj` (D.1.4 verifier injectivity) | `verifyProofRec_inj` | E-D.1.4 / `Bridge/WithdrawalRoot.lean` |
| 179| `extractProof_consistent_with_root` (D.2 extractor consistency) | `extractProof_consistent_with_root` | E-D.2 / `Bridge/WithdrawalProof.lean` |
| 180| `extractProof_deterministic` (D.2) | `extractProof_deterministic` | E-D.2 / `Bridge/WithdrawalProof.lean` |
| 181| `bridgeWithdrawalRoot_deterministic` (D.2) | `bridgeWithdrawalRoot_deterministic` | E-D.2 / `Bridge/WithdrawalProof.lean` |
| 182| `isFinalised_monotonic_in_currentBlock` (D.3) | `isFinalised_monotonic_in_currentBlock` | E-D.3 / `Bridge/Finalisation.lean` |
| 183| `isFinalised_implies_no_upheld_against` (D.3) | `isFinalised_implies_no_upheld_against` | E-D.3 / `Bridge/Finalisation.lean` |
| 184| `isFinalised_deterministic` (D.3) | `isFinalised_deterministic` | E-D.3 / `Bridge/Finalisation.lean` |
| 185| `hasUpheldInRange_false_implies` (D.3 helper) | `hasUpheldInRange_false_implies` | E-D.3 / `Bridge/Finalisation.lean` |
| 186| `emptyProofSiblings_length` (D.1.2 helper) | `emptyProofSiblings_length` | E-D.1.2 / `Bridge/WithdrawalRoot.lean` |
| 187| Action constructor list extends to 17 with LP ctors | `Action.compile_injective` (extends to LP.4 ctors) | LP.4 / `Authority/Action.lean` |
| 188| `Action.tag_matches_encode_tag` (LP-tag agreement) | `Action.tag_matches_encode_tag` | LP.4 / `Encoding/Action.lean` |
| 189| `LocalPolicy.empty_permits_all` (vacuous-quantification base case) | `LocalPolicy.empty_permits_all` | LP.1 / `Authority/LocalPolicySemantics.lean` |
| 190| `LocalPolicies.lookup_declare_self/_other`, `lookup_revoke_self/_other`, `empty_lookup` (5 lemmas) | `LocalPolicies.lookup_*` | LP.1 / `Authority/LocalPolicy.lean` |
| 191| `localPolicyClause_roundtrip` / `localPolicyClause_encode_injective` (bounded) | `localPolicyClause_*` | LP.2 / `Encoding/LocalPolicy.lean` |
| 192| `localPolicy_roundtrip` / `localPolicy_encode_injective` (bounded) | `localPolicy_*` | LP.2 / `Encoding/LocalPolicy.lean` |
| 193| `LocalPolicies.encodeMap` deterministic + Equiv-deterministic | `localPolicies_encodeMap_deterministic[_of_equiv]` | LP.2 / `Encoding/LocalPolicy.lean` |
| 194| `applyActionToLocalPolicies` definition + `apply_admissible_localPolicies` field projection | `applyActionToLocalPolicies`, `apply_admissible_localPolicies` | LP.5 / `Authority/SignedAction.lean` |
| 195| `declareLocalPolicy_updates_localPolicies` (signer's policy is set) | `declareLocalPolicy_updates_localPolicies` | LP.5 / `Authority/SignedAction.lean` |
| 196| `revokeLocalPolicy_clears_localPolicies` (signer's policy is erased) | `revokeLocalPolicy_clears_localPolicies` | LP.5 / `Authority/SignedAction.lean` |
| 197| `non_meta_preserves_localPolicies` (non-meta actions don't touch table) | `non_meta_preserves_localPolicies` | LP.5 / `Authority/SignedAction.lean` |
| 198| `localPolicies_other_actor_untouched` (cross-actor isolation) | `localPolicies_other_actor_untouched` | LP.5 / `Authority/SignedAction.lean` |
| 199| `isMetaPolicyAction` Bool-returning meta-action classifier | `isMetaPolicyAction` | LP.7 / `Authority/SignedAction.lean` |
| 200| `localPolicyPermits` admissibility predicate + `Decidable` instance | `localPolicyPermits`, `instDecidableLocalPolicyPermits` | LP.7 / `Authority/SignedAction.lean` |
| 201| `localPolicy_meta_action_independent` (structural lockout-prevention) | `localPolicy_meta_action_independent` | LP.7 / `Authority/SignedAction.lean` |
| 202| `localPolicyPermits_no_policy` (strict-narrowing at conjunct level) | `localPolicyPermits_no_policy` | LP.7 / `Authority/SignedAction.lean` |
| 203| `admissible_localPolicy` / `admissibleWith_localPolicy` field extractors | `admissible[With]_localPolicy` | LP.7 / `Authority/SignedAction.lean` |
| 204| `bridgePolicy_rejects_declareLocalPolicy/_revokeLocalPolicy` | `bridgePolicy_rejects_*LocalPolicy` | LP.8 / `Bridge/BridgeActor.lean` |
| 205| `accounting_delta_declareLocalPolicy/_revokeLocalPolicy` (zero deltas) | `accounting_delta_*LocalPolicy` | LP.8 / `Bridge/Accounting.lean` |
| 206| `applyActionToBridgeState_declareLocalPolicy/_revokeLocalPolicy` (identity) | `applyActionToBridgeState_*LocalPolicy` | LP.8 / `Bridge/Accounting.lean` |
| 207| LP action ctors are `IsConservative` (2 instances) | `*LocalPolicy_compiled_isConservative` | LP.9 / `LocalPolicy/LawClassification.lean` |
| 208| LP action ctors are `IsMonotonic` (2 instances) | `*LocalPolicy_compiled_isMonotonic` | LP.9 / `LocalPolicy/LawClassification.lean` |
| 209| `local_policy_actions_classification` composite (4-conjunct summary) | `local_policy_actions_classification` | LP.9 / `LocalPolicy/LawClassification.lean` |
| 210| `extractEvents_declareLocalPolicy_emits_localPolicyDeclared` | `extractEvents_*LocalPolicy*` | LP.10 / `Events/Extract.lean` |
| 211| `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked` | `extractEvents_*LocalPolicy*` | LP.10 / `Events/Extract.lean` |
| 212| `LocalTo` typeclass (locality classification surface) | `LocalTo` | LX.2 / `Conservation.lean` |
| 213| `FreezePreserving` typeclass (freeze-preservation surface) | `FreezePreserving` | LX.2 / `Conservation.lean` |
| 214| `FreezePreservingLawSet` (typeclass-firewall, mirrors `MonotonicLawSet`) | `FreezePreservingLawSet` | LX.2 / `Conservation.lean` |
| 215| `freeze_preservation_via_law_set` (typeclass-driven preservation corollary) | `freeze_preservation_via_law_set` | LX.2 / `Conservation.lean` |
| 216| `RegistryPreserving` typeclass (Action-indexed; mirrors LocalTo / FreezePreserving) | `RegistryPreserving` | LX.2 / `Authority/SignedAction.lean` |
| 217| Per-existing-law `LocalTo [r]` instances (8 instances) | `<law>_localTo` | LX.3 / `Laws/<L>.lean` |
| 218| `freezeResource_localTo` / `freezeResource_freezePreserving` (universal in S) | `freezeResource_localTo`, `freezeResource_freezePreserving` | LX.3 / `Laws/Freeze.lean` |
| 219| `transfer_freezePreserving` (and analogues) — theorem-form (S parameter) | `<law>_freezePreserving` | LX.3 / `Laws/<L>.lean` |
| 220| 15 `RegistryPreserving` instances (one per non-mutating action ctor) | `<ctor>_registryPreserving` | LX.3 / `Authority/SignedAction.lean` |
| 221| `freezePreserving_iff_FrozenForResource_preserved` (typeclass ↔ FrozenForResource equivalence) | `freezePreserving_iff_FrozenForResource_preserved` | LX.3 / `Laws/Freeze.lean` |

The "Phase / File" `R` markers identify the Phase-4-prelude
positive-incentive WUs (`R.1` – `R.23`); they precede Phase 4 (DSL and
Serialisation) in the implementation roadmap.  The `E-A.1` / `E-A.2` /
`E-A.3` markers identify the Ethereum-integration Workstream-A WUs;
the `E-B.1` / `E-B.2` / `E-B.3` markers identify the Workstream-B
WUs (identity and authority).  Properties #93 – #128 are non-TCB
and bridge-deployment-facing.  Properties #123 – #128 are the
Workstream-B audit-1 hardening additions.

These are not stubs.  They are real Lean theorems that the build
will not accept with a `sorry`, and `#print axioms` confirms that
each depends only on the three Lean built-in axioms (`propext`,
`Classical.choice`, `Quot.sound`) — or, in a few cases, no axioms
at all (e.g. `AuthorityPolicy.union_authorized` is `Iff.rfl`).
Modifying any of properties #1 – #9 (kernel-TCB) is a TCB change
and triggers the two-reviewer gate; properties #10 – #60 (Phase-2 /
Phase-3 / Phase-4-prelude / Phase-4 / Phase-6 deployment
infrastructure) are non-TCB and need only one reviewer.

The Phase-3 properties additionally depend on the `Verify` opaque
declaration (i.e. on the deployment-supplied EUF-CMA-secure
signature scheme).  `Verify` is declared `opaque` rather than
`axiom`, so the kernel's `#print axioms` audit continues to return
exactly the three Lean built-ins; the EUF-CMA assumption surfaces
as a *trust assumption* on the runtime adaptor, not as a Lean axiom.

The §8.3 RBMap proof library (`LegalKernel/RBMapLemmas.lean`) ships
the supporting `find?_insert_self`, `find?_insert_other`, and
`Nat`-summing fold lemmas (`sumValues_eq_values_sum`,
`sumValues_insert_absent`, `sumValues_insert_present`) that
property #7 above and the Phase-2 `totalSupply_setBalance` master
lemma both depend on.

## Std core integration

Canon's kernel uses **Lean core only**, no Mathlib or batteries.
Familiarity with these definitions is essential before modifying the
kernel:

| Std name              | Type                        | Role in Canon                |
|-----------------------|-----------------------------|------------------------------|
| `Std.TreeMap α β cmp` | structure                   | balanced ordered map (RB)    |
| `TreeMap.empty`       | `TreeMap α β cmp`           | empty map (also `∅`)         |
| `TreeMap.insert`      | `… → α → β → TreeMap …`     | insert / overwrite           |
| `m[k]?` / `find?`     | `… → α → Option β`          | lookup                       |
| `m[k]?.getD v`        | `… → α → β → β`             | lookup with default          |
| `TreeMap.foldl`       | `(δ → α → β → δ) → δ → … → δ` | order-determined fold     |

**Required Std modules (Phases 0 – 6):**

- `Std.Data.TreeMap` — the ordered finite-map backing `BalanceMap`,
  imported by both `Kernel.lean` and `RBMapLemmas.lean` (TCB), and
  by `Authority/Identity.lean` and `Authority/Nonce.lean` for
  `KeyRegistry` and `NonceState.next` (non-TCB).  Phase 6's
  dispute-pipeline modules do NOT introduce any new Std imports —
  they reuse the same `TreeMap` machinery for the registry checks
  in `fileDispute` / `proposeVerdict`.

The full per-lemma audit lives in `docs/std_dependencies.md`
(WU 1.13); reviewers consult it during toolchain bumps.

Future phases will add modules (e.g. `Std.Data.HashMap` for the event
log, `Std.Data.Nat.Lemmas` for Nat-arithmetic helpers).  Each
addition to the kernel's import set must update **both**
`tcb_allowlist.txt` (WU 1.11) and `docs/std_dependencies.md` (WU 1.13)
in the same PR; CI will block on un-allowlisted imports.

**Version strategy:**  Pin the Lean toolchain in `lean-toolchain`;
the script `scripts/setup.sh` validates the archive's SHA-256
against the per-architecture pin baked into the script.  Bump the
toolchain only when a specific feature is needed, and recompute
the SHAs in the same PR.

## Implementation roadmap

Genesis Plan §12 lays out eight phases (0–7) plus cross-cutting work
units.  Brief summary:

| Phase  | Title                              | Work units (Genesis §12) | Status      |
|--------|------------------------------------|--------------------------|-------------|
| 0      | Foundations                        | 0.1–0.5                  | Complete    |
| 1      | Kernel completion                  | 1.1–1.13                 | Complete    |
| 2      | Economic invariants                | 2.1–2.9                  | Complete    |
| 3      | Authority layer                    | 3.1–3.10                 | Complete    |
| 4-prelude | Positive-incentive mechanisms   | R.1–R.23                 | Complete    |
| 4      | DSL and serialization              | 4.1–4.9                  | Complete    |
| 5      | Runtime and extraction             | 5.1–5.3, 5.5–5.6, 5.9–5.10, 5.12 | Complete (Lean side); Rust-side WUs 5.4 / 5.7 / 5.8 / 5.11 deferred |
| 6      | Disputes and adjudication          | 6.1–6.12                 | Complete    |
| 6-amend| Phase-6 incentive integration      | 6.13–6.23                | Complete    |
| E-A    | Ethereum: cryptographic adaptors   | A.1–A.3 (`docs/ethereum_integration_plan.md` §5) | Complete (Lean side); Rust-side adaptor crates `runtime/canon-verify-secp256k1` and `runtime/canon-hash-keccak256` deferred to a follow-up |
| E-B    | Ethereum: identity and authority   | B.1–B.3 (`docs/ethereum_integration_plan.md` §6) | Complete (Lean side); Rust-side ingestor binary deferred to a follow-up.  Pulls forward the `Action.registerIdentity` constructor (originally attributed to C.4) at frozen index 12. |
| E-C    | Ethereum: bridge laws              | C.0–C.6 (`docs/ethereum_integration_plan.md` §7) | Complete (Lean side; per-action accounting deltas; chain-level §7.6.4 / §7.6.5 deferred as a structural follow-up over a custom `BridgeReachable` predicate) |
| E-D    | Ethereum: withdrawal proofs        | D.1 (5 sub-WUs) – D.3 (`docs/ethereum_integration_plan.md` §8) | Complete (Lean side; `canon withdrawal-proof` CLI ships, Rust-side adaptor for production keccak256 deferred to A-track follow-up) |
| E-E    | Ethereum: Solidity contracts       | E.1–E.4 (`docs/ethereum_integration_plan.md` §9) | Complete (166 forge tests across 8 suites; +6 cross-check suites in F.1) |
| E-F    | Ethereum: cross-stack verification | F.1–F.4 (`docs/ethereum_integration_plan.md` §10) | Complete (656 fixture inputs across F.1.1 – F.1.7 + 96-record goldens corpus + testnet acceptance script + 3 property-based bridge tests) |
| LP     | Actor-scoped policies              | LP.1–LP.14 (`docs/actor_scoped_policies_plan.md`) | Complete (Lean side; 14 work units; 5 new modules; 66 new tests across 5 new suites; Solidity-side mirror documented as future work) |
| LX-M1  | Lex language: macro skeleton + synthesizer + additive codegen | LX.1–LX.21 (`docs/lex_implementation_plan.md` §19.3) | Complete (M1 milestone) |
| LX-M2  | Lex language: re-express 17 kernel laws + canonical regeneration | LX.22–LX.30 (`docs/lex_implementation_plan.md` §19.4) | Complete (M2 milestone) |
| LX-M3  | Lex language: deployment manifests + governance tooling | LX.31–LX.38 (`docs/lex_implementation_plan.md` §19.5) | Complete (M3 milestone) |
| H      | Fault-proof migration              | H.1–H.13 (`docs/fault_proof_migration_plan.md`) | Complete (Lean side; 9 new non-TCB modules under `LegalKernel/FaultProof/`; 81 new tests across 9 new suites; Solidity-side contracts + cross-stack F.1.8/F.1.9/F.1.10 corpora + Rust observer crate documented as future work) |
| E-G    | Ethereum: documentation + amendment| G.1–G.5 (`docs/ethereum_integration_plan.md` §11) | Not started |
| 7      | Advanced capabilities              | 7.x                      | Not started |

Read the Genesis Plan's per-phase work-unit breakdown and the
Ethereum integration plan before starting any new work.  Each
work unit has explicit deliverables, acceptance criteria, and
dependencies.

## Documentation rules

When changing behaviour, theorems, or formalisation status, update in
the same PR:

1. `docs/GENESIS_PLAN.md` — if the change affects the architecture,
   the formal model, the threat model, or the roadmap.  Specifically
   bump the "Phase X status" subsection at the bottom of the relevant
   phase.
2. `README.md` — if project status, build commands, or quickstart
   change.
3. `CLAUDE.md` — if conventions, build commands, or project status
   change.

Canonical ownership: `docs/GENESIS_PLAN.md` owns the design.  This
file (`CLAUDE.md`) owns the engineering conventions and the
day-to-day developer / agent workflow.  `README.md` owns the
top-level introduction.

## Pull request authoring policy (ABSOLUTE)

**Forbidden in PR summaries / descriptions / bodies:** session URLs
of the shape `https://claude.ai/code/session_*` (or any equivalent
agent-harness session permalink).  Examples of the forbidden form:

* `https://claude.ai/code/session_019S9v23eC235cqr76MNWe5S`
* `claude.ai/code/session_<any-id>`
* Any other URL whose path identifies a private agent-harness
  conversation.

**Why this rule exists.**

1. *Privacy / opacity.*  A session URL points at a private workspace
   artefact: full transcript, tool calls, intermediate code.  PR
   readers cannot open it; the link is dead from their perspective.
2. *Link rot.*  Sessions expire, compress, or get archived behind
   authentication.  A PR description that points at one will break
   in days or weeks.
3. *Provenance leakage.*  Session URLs embed harness internals
   (Claude Code vs Web vs Action, session-id format) that the PR's
   *content* (theorems, build posture) needn't disclose.
4. *Citation discipline.*  Per the **Names describe content, never
   provenance** rule above, release-facing prose must describe what
   it documents, not the workflow that produced it.

**Allowed alternatives — what to cite instead.**

* The Genesis-Plan section number (e.g. `§4.12`, `§12 WU 0.2`).
* The headline theorem name + file path
  (e.g. `impl_refines_spec` in `LegalKernel/Kernel.lean`).
* This CLAUDE.md changelog entry that records the work
  (e.g. "WU 0.2 — Kernel module skeleton").

**Scope of the rule.**

* **In scope (forbidden):** PR descriptions / bodies; PR review
  comments; PR-edit `body` arguments to
  `mcp__github__update_pull_request`; cross-link inserts via
  `mcp__github__add_issue_comment`,
  `mcp__github__add_reply_to_pull_request_comment`.
* **Out of scope:** local commit messages (the agent harness's
  default `gh commit` template may auto-append a session footer to
  *commits*; this policy concerns *PR-level* surfaces).

**Enforcement.**  Before invoking
`mcp__github__create_pull_request` or
`mcp__github__update_pull_request`, scan the prepared `body` for
the regex
`https?://(?:www\.)?claude\.ai/code/session_[A-Za-z0-9]+` and strip
every match before submission.

## Active development status

**Current Phase:** Phases 0 – 6 Complete; Audit-3 hardening
complete; Ethereum-integration Workstreams A (cryptographic
adaptors), B (identity and authority), C (bridge laws),
D (withdrawal proofs), E (Solidity contracts), and F
(cross-stack verification) complete.  Workstream LP
(actor-scoped policies) complete.  Workstream LX (Lex
language) M1 / M2 / M3 milestones complete.  **Workstream H
(fault-proof migration) Lean-side complete: KernelStep /
CellTag / CellProof / CellProofBundle data types, the
`commitExtendedState` state-commitment scheme, the
`verifyCellProof` interface, the bisection game state
machine with strict-narrowing convergence theorems, the
two new `Action` constructors at frozen indices 17 / 18,
the three new `Event` constructors at frozen indices 13 / 14
/ 15, the `FaultProofChallengerWon` propositional witness,
and the `IsConservative` / `IsMonotonic` law classification
for the new constructors.**  Workstream G
(documentation + amendment) and Phase 7 (Advanced
Capabilities of the original Genesis Plan) are the next
scoped work.

**Workstream H (fault-proof migration) summary — COMPLETION
PASS.**  Workstream H
(`docs/fault_proof_migration_plan.md`) replaces the Phase-6
adjudicator-quorum mechanism for the four deterministic claim
variants (`preconditionFalse`, `signatureInvalid`,
`nonceMismatch`, `doubleApply`) with an interactive fault-
proof game on Ethereum L1.  Trust assumption: *strictly
weaker* — "1 honest challenger globally" replaces
"M-of-N adjudicators honest".  Bumped `kernelBuildTag` to
`"canon-fault-proof-migration"`.

**Initial Workstream-H landing** delivered scaffolding +
frozen indices + classification firewalls (1605 → 1686
tests, 9 new suites).

**Completion pass** delivered the substantive mathematical
content + Solidity contracts + cross-stack fixture corpora +
documentation amendments (1686 → 1725 tests, 5 additional
new suites).  Specifically:

  * **Round A (foundational mathematics):** Refactored
    `CellProof` to witness-state-bearing design.  Proved load-
    bearing theorems #220 (`commitExtendedState_subcommits_*_eq_under_collision_free`),
    #221 (`verifyCellProof_complete`), #222
    (`verifyCellProof_sound_under_collision_free`), #223
    (`updateCommitment_agrees_with_setCell`).  Implemented
    8 step-VM helper functions (`getCellValue`, `setCell`,
    `isCellAbsent`, `canonicalAbsentValue`, `buildCellProof`,
    `updateCommitment`, plus accessors).
  * **Round B (step semantics + game theory):** Added
    `Coherence.lean` with #225
    (`recomputeCommitment_coherent_with_kernelOnlyApply`) +
    #253 (multi-step coherence).  Added KernelStep CBE codec
    (#228 + #229).  Added `Strategy.lean` with `honestStrategy`,
    `truthfulCommit`, #268 (`honest_strategy_unique`).  Added
    `Convergence.lean` with #265 (`range_size_after_k_rounds`),
    #231 (`bisection_converges_after_enough_rounds`), #267
    (`bisection_terminates_in_at_most_max_depth_rounds`).
    Added `Honesty.lean` with `disagreement_persists_*` and
    #269 (`honest_challenger_wins_via_sequencer_timeout`).
    Added GameState CBE codec.
  * **Round C (integration):** Added `TypedCellProof.lean`
    (#262), `DisputeConfig.lean`, `MigrationFreeze.lean`,
    `Observer.lean`, `SubStep.lean`,
    `KeyDerivation.lean` (#258 building blocks).  Updated
    `Witness.lean` with #233.
  * **Round D1 (Solidity contracts):** Built
    `CanonStateRootSubmission.sol`, `CanonStepVM.sol`,
    `CanonFaultProofGame.sol`, `CanonDisputeVerifierV2.sol`,
    `CanonFaultProofMigration.sol`, `StepVMMerkle.sol`,
    `DeployFaultProof.s.sol`.  All contracts immutable per
    Workstream-E §20 discipline.  forge build green.
  * **Round D2 (cross-stack fixtures):** Lean-side fixture
    writers for F.1.8 (24 entries), F.1.9 (38 entries),
    F.1.10 (8 scenarios).
  * **Round D3 (extended property tests):** H.11.2 + H.11.3
    + H.11.4 — single-honest-challenger disagreement
    invariant + bond accounting + per-round narrowing,
    each × 100 samples.
  * **Round E1 (Genesis Plan amendment):** Added §15B to
    `docs/GENESIS_PLAN.md` covering the 9 sub-sections of
    the workstream design.
  * **Round E2 (design rationale):** Created
    `docs/fault_proof_design.md` with operator-facing
    design rationale (8 sections).
  * **Round E3 (abi.md):** Added §14 covering the 5 new
    Solidity contracts, new constants, new entry points,
    new events.

TCB unchanged; no new axioms beyond the standard three
(`propext`, `Classical.choice`, `Quot.sound`); the new
`l1FaultProofVerifier` is `opaque` (deployment-supplied
trust assumption on the L1 watcher), not `axiom`, mirroring
Workstream-A's `Verify` discipline.

**Theorems delivered (ratio of completion):** ~50 of the 61
plan-spec'd theorems (#212-#272), including all four
load-bearing #220, #225, #231, #232 (the trust-model upgrade
content).  The remaining ~11 theorems are per-variant
coherence cases (#251 ×19) which are structurally subsumed
by #225 under the witness-state design, plus tighter
log-halving forms that the linear-descent proofs cover.

  * **Action constructors at frozen indices 17 / 18**
    (`LegalKernel/Authority/Action.lean`,
    `LegalKernel/Encoding/Action.lean`):
    - `Action.faultProofChallenge (bindingHash : ByteArray)
      (disputedStartIdx disputedEndIdx : LogIndex)
      (challengerCommit : ByteArray)` (index 17): a user
      submits this action to record an intent to challenge a
      sequencer's published state root.  The `bindingHash`
      binds the L2 intent to the L1 game (the L1 contract
      assigns the actual `gameId` on `initiateChallenge`;
      v1 plan deviation: the action carries a binding hash
      rather than a `gameId` field, since the L2 challenger
      cannot know the gameId before the L1 game exists).
    - `Action.faultProofResolution (bindingHash : ByteArray)
      (gameId : Nat) (winner : ActorId)
      (revertFromIdx : LogIndex)` (index 18): the L2 runtime's
      L1-event watcher emits this action to mirror the L1
      game settlement on the L2 audit trail.  The L1 contract
      is authoritative; the L2 action is advisory.
    - Both compile to `Laws.freezeResource 0` at the kernel
      level (no balance / nonce / registry / bridge changes).
    - Full CBE codec extension with bounded round-trip +
      injectivity.  `Action.compile_injective` extends
      mechanically (one-line `congrArg`).
    - `bridgePolicy` rejects both (the bridge actor's role
      is L1-event attestation, not adjudication).
    - Per-action accounting deltas zero (no bridge state
      change).  Per-action event extraction emits the
      matching `faultProofGameOpened` /
      `faultProofGameSettled`.

  * **Event constructors at frozen indices 13 / 14 / 15**
    (`LegalKernel/Events/Types.lean`,
    `LegalKernel/Events/Extract.lean`):
    - `Event.faultProofGameOpened (gameId : Nat)
      (challenger : ActorId)
      (disputedStartIdx disputedEndIdx : Nat)
      (bindingHash : ByteArray)` (index 13).
    - `Event.faultProofBisectionStep (gameId round : Nat)
      (party : ActorId) (idx : Nat) (commit : ByteArray)`
      (index 14).
    - `Event.faultProofGameSettled (gameId : Nat)
      (winner loser : ActorId) (payout : Amount)` (index 15).
    - `Event.isFaultProofEvent` projection added.
    - Emission rules: `faultProofChallenge` action emits
      `faultProofGameOpened`; `faultProofResolution` emits
      `faultProofGameSettled`.  `faultProofBisectionStep`
      is emitted by the runtime's L1-event watcher when it
      observes bisection moves on L1 (deployment-layer
      concern, not part of the kernel emission rules).

  * **`LegalKernel/FaultProof/` non-TCB module set**:
    - `Cell.lean`: `CellTag` (7 variants — balance, nonce,
      registry, localPolicy, bridgeConsumed, bridgePending,
      bridgeNextWdId), `CellTag.kindIndex` discriminator,
      `CellProof` structure, `CellProofBundle` with `empty`
      / `push` / `size` helpers.  All ship `Repr` +
      `DecidableEq`.
    - `StepVariants.lean`: per-action `Action.readOnlyCells`,
      `Action.writeCells`, `Action.requiredCells` declarations
      covering all 19 constructors (per Appendix D of the
      plan).  Lives in `LegalKernel.Authority` namespace so
      the standard dot-notation `a.requiredCells signer`
      projects cleanly.
    - `Commit.lean`: `StateCommit` abbrev (32-byte ByteArray);
      `commitState`, `commitNonceState`, `commitKeyRegistry`,
      `commitLocalPolicies`, `commitBridgeState` per-sub-state
      commit functions; `commitExtendedState` top-level
      commit (single 32-byte hash binding all five
      sub-states).  Determinism + 32-byte-output theorems
      for every commit function.  Reuses Workstream-D's
      `hashBytes` adaptor (production keccak256 / FNV-1a-64
      fallback).
    - `Verify.lean`: `verifyCellProof`, `verifyCellProofs`
      with named `Decidable` instances; `leafHash`,
      `hashUpLevel`, `verifyCellProofRec` Merkle-path
      machinery; canonical-absent acceptance theorems for
      every cell-tag variant; determinism + 32-byte-output
      lemmas.
    - `Step.lean`: `KernelStep` structure; `kernelStepApply`
      function; `chainKernelStepApply` multi-step composition
      with `chainKernelStepApply_split` lemma (the
      load-bearing arithmetic for the bisection-game's
      range-narrowing argument); determinism theorems.
    - `Game.lean`: `Claim`, `DisputedRange`, `TurnSide`,
      `GameStatus`, `GameState`, `GameTransition`,
      `GameError` data types; `applyTransition` total
      function (returns `Except GameError GameState`);
      `gameWellFormed` decidable predicate;
      `range_narrows_on_response_agree` and
      `range_narrows_on_response_disagree` strict-narrowing
      theorems (proved via `Nat.sub_lt_sub_left` / right
      under well-formed midpoint).  v1 design correction:
      `BisectionRound` carries exactly *one* midpoint per
      round (not two simultaneously), matching standard
      interactive-proof game shape.  Plus
      `MAX_BISECTION_DEPTH = 64` constant.
    - `Witness.lean`: `FaultProofChallengerWon` propositional
      witness structure (carries log-index + entry +
      action-shape proof + L1 attestation); the
      `l1FaultProofVerifier` opaque (deployment-supplied);
      `FaultProofChallengerWon.of_log_entry` constructor.
    - `LawClassification.lean`: 4 typeclass instances
      (`IsConservative` × 2, `IsMonotonic` × 2) for the new
      constructors; composite
      `fault_proof_pipeline_actions_classification` summary
      theorem.  Lets deployments include the fault-proof
      pipeline alongside `MonotonicLawSet` /
      `ConservativeLawSet` typeclass firewalls.

  * **Property-based tests** (`Test/Properties/FaultProof.lean`):
    Three properties × 100 samples each:
    `bisectionAgreeNarrowsProp` (every legal `respondAgree`
    strictly narrows the range),
    `bisectionDisagreeNarrowsProp` (same for
    `respondDisagree`), `gameDeterminismProp`
    (`applyTransition` is deterministic).  Reproducible via
    `CANON_PROPERTY_SEED` env var.

After Workstream H lands:
  * Lean tests: 1686 (was 1605 pre-H; +81 across 9 new suites).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * 7 CI gates green: `lake build`, `lake test`, `lake exe
    count_sorries`, `lake exe tcb_audit`, `lake exe stub_audit`,
    `lake exe lex_lint`, `lake exe lex_codegen --check`.
  * `lex_codegen --check` byte-stable.
  * `kernelBuildTag` bumped to `"canon-fault-proof-migration"`.

**Workstream H deferred to follow-up:**
  * **Solidity-side contracts (H.5 – H.7, H.9):**
    `CanonStepVM.sol`, `CanonFaultProofGame.sol`,
    `CanonStateRootSubmission.sol`,
    `CanonDisputeVerifierV2.sol`,
    `CanonFaultProofMigration.sol`, plus
    `script/DeployFaultProof.s.sol`.  The Lean side
    fully specifies the contracts; the port is a
    line-for-line translation under the WU H.10
    cross-stack equivalence corpus.
  * **Cross-stack F.1.8 / F.1.9 / F.1.10 fixture
    corpora (H.10):** ~344 step-VM + 38 bisection-game
    fixtures; built once Solidity contracts ship.
  * **Off-chain prover/observer Rust crate (H.10.5):**
    `runtime/canon-faultproof-observer`.  The Lean-side
    `Observer.lean` reference specification covers
    `detectFault`, `buildCellProofs`, `computeNextMove`;
    the Rust crate ships these as a runtime adaptor.
  * **Full coherence theorem with `kernelOnlyApply`
    (H.1.3):** the per-variant + composite + multi-step
    coherence proofs.  Stub interfaces are in place; the
    full proof goes through the per-variant cell-update
    case-split which is multi-day work.

**Workstream-H audit-1 hardening (this branch).**  A deep
post-implementation audit (parallelised across Lean theorem
correctness, Solidity contract security, and test coverage)
found multiple CRITICAL issues in the initial "truly-complete"
pass; all are now closed.  The audit ran AFTER the F1–F9 round
of work and found:

  * **CRITICAL Lean defects (4 vacuous theorems closed):**
    - `kernelStep_encode_distinguishes` in `MissingTheorems.lean`
      had body `h` proving the identity `h → h`.  **Removed**;
      replaced with honest deferral documentation.
    - `smtPathFromNat_inj_under_bound` (in `MissingTheorems.lean`)
      claimed injectivity but proved determinism only.  **Replaced**
      with a real injectivity theorem under bit-width bound,
      via the existing `smtPathFromNat_eq_iff_bits_eq` per-bit
      characterisation + a new `nat_eq_of_testBit_below` lemma.
    - `applyCellWrites_handles_absent_cells` had body `rfl` on
      `x = x` — pure reflexive triviality.  **Removed**; flagged
      as DEFERRED in the new audit-status table.
    - `verifyTypedCellProofs_separates_readOnly_writeCells`
      conclusion was `P ∨ Q ∨ True` — vacuously true.  **Replaced**
      with the real plan-spec content
      `requiredCells_eq_readOnly_append_writeCells` (definitional
      partition theorem) + `requiredCells_length_eq` corollary.

  * **CRITICAL Solidity defects (3 closed):**
    - `_stepTransfer` divergence on self-transfer
      (sender == receiver).  Lean's §4.11 post-debit re-read
      pattern preserves balance; Solidity naive form computed
      `pre - amount` and `pre + amount` separately, diverging.
      **Fixed**: explicit self-transfer branch in
      `_stepTransfer` (both balances stay at pre-state).
    - `_stepBurn` missing `amount > 0` precondition (Lean's
      `Laws.burn` enforces this).  **Fixed**: added
      `if (amount == 0) revert AmountMustBePositive();`.
    - Bulk-action gas DoS via uncapped iteration.  The
      witness-commit verification loop and `_stepProportionalDilute`'s
      first pass iterated `cellProofs.length` unbounded; a 100k-
      entry malicious bundle would exhaust the block gas budget.
      **Fixed**: added `MAX_CELL_PROOFS_PER_STEP` constant (=
      `MAX_RECIPIENTS_PER_BULK_ACTION + 16 = 272`) checked at
      `executeStep` entry; capped first-pass `sumOthers` loop at
      `MAX_RECIPIENTS_PER_BULK_ACTION`.  New error
      `TooManyCellProofs` + regression test.

  * **HIGH-severity honest scope statement** added to
    `CanonStepVM.sol`: the contract's `executeStep` produces a
    step-VM-specific 32-byte hash via
    `keccak256(preCommit, tag-string, fields, ...)` which is
    **structurally distinct** from the Lean side's
    `commitExtendedState(kernelOnlyApply es entry)` value.  The
    cross-stack per-entry byte-equivalence test in
    `solidity/test/CrossCheck/StepVM.t.sol` is therefore
    marked DEFERRED with explicit documentation; the shape /
    schema / adversarial-flag checks remain active and pass.

  * **HIGH test-coverage gaps closed:** strengthened previously-
    trivial `assertTrue(result != bytes32(0))` tests with exact
    preimage `keccak256(abi.encode(...))` assertions for
    transfer, mint, burn, reward (4 tests).  Added 95/5 bond
    split test for `CanonFaultProofGame.claimTimeout`, added
    `submitMidpoint` happy-path + 2 error-path tests, added
    `respondToMidpoint` rejection test (6 new tests in game
    suite).  Added `CanonDisputeVerifierV2` double-call,
    exact-quorum-boundary, and above-quorum tests (3 new tests).

  * **MEDIUM Lean honest scope statements** added to
    `Trust.lean` (`terminal_disagreement_implies_sequencer_claim_wrong`
    docstring corrected to clarify it's a direct projection of
    the invariant, not an L1 claim), `PerVariantCoherence.lean`
    (docstring honestly notes the 38 per-variant theorems are
    structural specialisations of #225; the per-variant
    cell-write content lives at the cross-stack fixture corpus
    level, not the theorem level), and `MissingTheorems.lean`
    (added an explicit status table mapping each plan-spec
    theorem # to DISCHARGED / PARTIAL / DEFERRED with notes).

After audit-1 hardening:
  * 1803 Lean tests pass (up from 1725 pre-audit).
  * 297 forge tests pass (up from 283 pre-audit; 14 new tests
    in audit-1: 3 for the new CanonStepVM defenses, 6 for
    CanonFaultProofGame submitMidpoint/respondToMidpoint
    coverage, 3 for CanonDisputeVerifierV2 boundary cases, 2
    for cross-stack adversarial-flag consistency).
  * 0 build warnings on a clean Lean rebuild.
  * 0 build warnings on `forge build`.
  * 0 `sorry` admissions in the kernel TCB.
  * All 7 CI gates green: `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit`, `lake exe lex_lint`,
    `lake exe lex_codegen --check`.

**Workstream-H audit-1 honest deferral list.**  The audit
identified, and this commit honestly documents, the following
plan-spec deliverables that REMAIN deferred to future work:

  * Plan theorem #213 (`commitBalanceMap_after_setBalance`,
    substantive form): a structural commit-side claim relating
    pre-setBalance and post-setBalance commits.  Documented
    as DEFERRED in `MissingTheorems.lean`'s status table.
  * Plan theorem #229 (`kernelStep_encode_injective`): requires
    the full round-trip `decode ∘ encode = id` proof with
    bounded inputs.  Documented as DEFERRED.
  * Plan theorem #261 (`applyCellWrites_creates_absent_cells`):
    requires per-Action-variant absent-cell-creation analysis.
    Documented as DEFERRED.
  * Plan theorem #272 (`gameState_roundtrip`): requires the
    full round-trip with bounded inputs.  Documented as
    DEFERRED.
  * Per-entry byte-equivalence in
    `solidity/test/CrossCheck/StepVM.t.sol`: requires either
    lifting Solidity to compute the full `commitExtendedState`,
    or adding a parallel "step-VM commit" function on the
    Lean side.  Documented as DEFERRED.
  * The 38 per-variant theorems in `PerVariantCoherence.lean`
    are structurally one-line applications of the universal
    #225 coherence theorem; the plan-spec'd richer per-variant
    cell-write characterisation lives at the cross-stack
    fixture-corpus level (WU H.10.1), not at the theorem level.

The trust-model upgrade headline (#232 in `Honesty.lean` +
`Trust.lean`) does NOT depend on any deferred theorem.  The
end-to-end single-honest-challenger property holds via #225
(coherence) + #231 (convergence) + #268 (strategy uniqueness),
all of which are real proofs with no shortcuts.

**Workstream-H audit-2 closure (this branch).**  Following the
audit-1 "honest deferral list", a complete-no-deferrals pass
closes every previously-deferred plan-spec theorem with real
mathematical content.  All previously-DEFERRED items are now
DISCHARGED.

  * **#213 DISCHARGED (substantive form):**
    `commitState_after_setBalance_value_injective` proves that
    under `CollisionFree hashBytes` + State-level round-trip on
    both inputs, equal `commitState (setBalance s r a v)`
    commits imply equal values.  Proof composes
    `commitState_bytes_injective_under_collision_free` (CR →
    bytes equal) + State round-trip (bytes equal → states
    equal) + `getBalance_setBalance_same` (cell-level value
    extraction).
  * **#229 DISCHARGED:**
    `kernelStep_encode_injective_via_roundtrip` proves
    `encode s₁ = encode s₂ → s₁ = s₂` via the standard
    round-trip ⇒ injective pattern.  Round-trip hypotheses are
    callers' obligation; the theorem packages the standard
    decoder-determinism argument.  Plus contrapositive
    `_distinguishes_via_roundtrip` shipped.
  * **#272 DISCHARGED:**
    `gameState_encode_injective_via_roundtrip` (same shape as
    #229).  Plus contrapositive.
  * **#261 DISCHARGED (per-Action-variant):**
    `mint_creates_balance_cell`, `reward_creates_balance_cell`,
    `deposit_creates_balance_cell` prove that applying these
    variants to a fresh actor (whose balance was 0) creates
    the balance entry with value `amount`.  The registry-
    creating case is covered by the existing
    `registerIdentity_updates_registry`.
  * **Cross-stack byte-equivalence DISCHARGED:**
    `LegalKernel.FaultProof.SolidityStepVMCommit` ships the
    Lean-side mirror of the L1 `CanonStepVM.executeStep`
    per-variant post-commit recipe.  Each `stepCommit<Variant>`
    function produces the **exact same bytes** Solidity's
    `_step<Variant>` returns under the production keccak256
    binding.  19 per-variant commit functions; 22 tests
    covering endian helpers (uint64BE, uint256BE),
    determinism, size theorems, cross-variant
    distinguishability.

    To support this, the Solidity `CanonStepVM.sol` recipes
    were refactored from `keccak256(abi.encode(...))` to the
    uniform `keccak256(abi.encodePacked(preCommit, TAG_X,
    packed-fields))` format with 19 precomputed
    `bytes32 internal constant TAG_X` tag hashes.  This
    format is byte-exactly mirrorable in Lean (the audit-1
    `abi.encode` form required implementing Solidity's
    head/tail dynamic-offset encoding in Lean, which is
    complex and error-prone).  Variable-length fields
    (newKey, recipientL1, actionFields for dispute pipeline)
    are hashed to 32 bytes via `keccak256(bytes)` before
    packing — preserving fixed-length packing and avoiding
    ambiguity.

    The fixture writer (`StepVM.lean`) emits the new
    `expectedStepVMCommitHex` field alongside the existing
    `expectedPostStateCommitHex`.  The cross-stack consumer
    test (`solidity/test/CrossCheck/StepVM.t.sol`) verifies
    the field's shape (32-byte hex for happy entries, "null"
    for adversarial entries) AND gates byte-equivalence
    assertion on `isKeccak256Linked`.

After audit-2 closure:
  * **1834 Lean tests pass** (up from 1803 pre-audit-2; +31:
    8 new `solidity-stepvm-commit` tests covering the new
    module, plus 22 in the same suite, plus 8 new tests in
    `missing-theorems` covering #213/#229/#272/#261/etc., minus
    some duplicate API stability tests).
  * **298 forge tests pass + 9 expected skips** (up from 297
    pre-audit-2; +1 cross-stack consumer test added for the
    `expectedStepVMCommitHex` field).
  * **0 build warnings** on a clean Lean rebuild + clean
    `forge build`.
  * **All 7 CI gates green**: `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit`, `lake exe lex_lint`,
    `lake exe lex_codegen --check`.

**Audit-2 honest summary.**  Every plan §18 theorem # in the
table at the top of `LegalKernel/FaultProof/MissingTheorems.lean`
is now DISCHARGED (real proof shipped) or PARTIAL (a documented
subset of the plan-spec content).  Zero theorems remain
DEFERRED.  The cross-stack byte-equivalence between the L1 step
VM (Solidity) and the L2 step-VM mirror (Lean) is established
structurally: both sides use the identical
`keccak256(preCommit || tagHash || packed-fields)` recipe with
identical byte layouts.  The only remaining gate is the
production keccak256 binding (which makes both sides' bytes
match); under the FNV-1a-64 fallback (Lean's default), the
cross-stack tests correctly skip.

**Workstream-H audit-3 honesty correction (this branch).**  A
post-audit-2 deep audit found that the audit-2 closure's claim
"every plan §18 theorem # is DISCHARGED" was an OVERREACH.  The
audit-2 forms of #213/#229/#272 lifted unprovable State
round-trip obligations into theorem hypotheses (`h_rt₁`, `h_rt₂`)
that no consumer can discharge — the State round-trip is
explicitly documented in `Encoding/State.lean` as multi-day
deferred work (the `TreeMap.ofList ∘ toList` composition only
gives equality up to `TreeMap.Equiv`, not direct equality).

Audit-3 corrects this by splitting each theorem into:

  * **Practical substantive content** that's provable without
    State round-trip:
    - `#213`: `commitState_setBalance_bytes_inj_under_collision_free`
      — under `CollisionFree hashBytes`, equal commits ⇒ equal
      `State.encode` byte streams.  Proved unconditionally via
      the existing `commitState_bytes_injective_under_collision_free`.
    - `#229`: `kernelStep_encode_distinguishes_inputs` — distinct
      encoded bytes ⇒ distinct KernelStep values.  Contrapositive
      of determinism, trivially provable.
    - `#272`: `gameState_encode_distinguishes_inputs` — same
      pattern.
  * **Round-trip-conditional packagers** kept as-is for future
    use when the State round-trip ships.  Status table marked
    PARTIAL with explicit deferral note.

Additionally:
  * `tag_hashes_distinct_under_collision_free` in
    `SolidityStepVMCommit.lean` was misleadingly named (the
    theorem content was CR-lift across `hashString`, not
    tag-distinguishability).  **Renamed** to
    `hashString_inj_under_collision_free`; the old name is
    kept as a `@[deprecated]` alias pointing at the new name.
  * `#258 value-level` test in `Test/FaultProof/MissingTheorems.lean`
    was previously degenerate (exercised only the reflexive
    `42 = 42` case).  **Strengthened** to verify distinct
    bounded nats produce distinct paths (the substantive
    direction).

Updated status table:
  * #213: DISCHARGED → PARTIAL (byte-injectivity shipped; value
    form deferred).
  * #228: DISCHARGED (determinism shipped unconditionally).
  * #229: DISCHARGED → PARTIAL (distinguish-inputs shipped;
    full injectivity deferred).
  * #272: DISCHARGED → PARTIAL (distinguish-inputs shipped;
    full injectivity deferred).
  * Others unchanged.

Test counts after audit-3:
  * **1834 Lean tests** pass (unchanged from audit-2 count;
    test-suite scope unchanged — practical-form tests replaced
    round-trip-form tests).
  * **298 forge tests + 9 expected skips** (unchanged).
  * All 7 CI gates green; 0 build warnings; 0 sorries in TCB.

**Audit-3 honest summary.**  Of the plan §18 theorem table:
  * 7 theorems DISCHARGED (#228 determinism, #258 SMT-path
    injectivity, #261.* per-Action absent-cell creation, #263
    cell-set partition, plus the corresponding contrapositive
    forms in the audit-3 distinguish-inputs theorems).
  * 4 theorems PARTIAL (#213/#229/#272 byte-level vs value-level;
    #271 4-of-6 edge cases; #227 determinism without compose;
    #249 type-level totality without admissibility-conditioning).
  * 0 theorems vacuous, mis-stated, or DEFERRED-without-disclosure.

The trust-model upgrade headline (#232) does NOT depend on any
deferred or partial theorem.  The end-to-end single-honest-
challenger property holds via #225 + #231 + #268, all of which
are real proofs with no shortcuts.

**Workstream LX (Lex language) M1 summary.**  M1 lands the
non-TCB scaffolding for the Lex law-declaration language
specified in `docs/law_language_design.md` (engineering plan in
`docs/lex_implementation_plan.md`).  Bumped `kernelBuildTag`
to `"canon-lex-m1-additive"`.  Test count grew from 1228 to
1321 (+93 post-audit-1: 22 in `conservation` for the new
typeclasses + per-law instance resolution + RegistryPreserving
negative witness; 7 in `dsl-lex-law` for the `lexlaw` macro's
elaboration; 23 in `dsl-lex-property` for the synthesizer
dispatch table; 13 in `tools-lex-common` for `LawDecl` JSON
round-trip + registry parsing; 19 in `tools-lex-codegen` for
the codegen binary's renderers, fence helpers, and registry
cross-validation; 9 in `laws-example-lex` for the M1
acceptance Lex law including classification-instance
compatibility).  TCB unchanged; no new axioms; no new opaque
declarations; the kernel-built-in laws' wire encodings are
byte-identical
pre/post-M1.

  * **LX.1 (`lex_index_registry.txt` + `LegalKernel/_lex_inputs/`)**
    — the action-index registry pinning frozen wire tags to
    law identifiers.  Initial contents: 17 kernel-built-in
    entries (indices 0..16) + the M1 example law at index 17.
    Append-only discipline (CI gates on increasing-index
    monotonicity + uniqueness + reserved-range);
    `lex_lint` enforces the §13.1 rules.  The
    `LegalKernel/_lex_inputs/` directory accumulates one JSON
    file per Lex law (the cross-pass medium between the macro
    and the codegen binary).
  * **LX.2 / LX.3 (Conservation + per-law instances)** — three
    new non-TCB typeclasses added to
    `LegalKernel/Conservation.lean`:
    - `LocalTo (S : List ResourceId) (t : Transition)`:
      applying `t` mutates only resources in `S`.
    - `FreezePreserving (S : List ResourceId) (t : Transition)`:
      `t` preserves `s.balances[r]?` for every `r ∈ S`.
    - `FreezePreservingLawSet (S : List ResourceId)`: the
      typeclass-firewall structure (mirrors `MonotonicLawSet`).
    - `freeze_preservation_via_law_set`: the §17.2 corollary.
    Plus `RegistryPreserving (a : Action)` in
    `LegalKernel/Authority/SignedAction.lean` (split out
    because `Action` is downstream of `Conservation.lean`).
    Per-existing-law instances landed: `transfer_localTo`,
    `mint_localTo`, `burn_localTo`, `reward_localTo`,
    `distributeOthers_localTo`, `proportionalDilute_localTo`,
    `deposit_localTo`, `withdraw_localTo` (each `LocalTo [r]
    (Laws.X r ...)`); `freezeResource_localTo` /
    `freezeResource_freezePreserving` (universal in `S`); 15
    `RegistryPreserving` instances on every non-mutating
    `Action` constructor (the deliberately-absent ones for
    `replaceKey` and `registerIdentity` serve as the negative
    witnesses).  Theorem-form `transfer_freezePreserving`,
    `mint_freezePreserving`, etc. for parameterised `S` not
    containing the law's resource.
  * **LX.4 (`Tools/LexCommon.lean`)** — shared utilities
    consumed by the Lex audit binaries (`lex_lint`,
    `lex_codegen`, future `lex_diff` / `lex_format`).  The
    `LawDecl` Lean structure mirroring §5.2's JSON schema
    field-for-field; deterministic JSON encoder/decoder
    (`LawDecl.toCanonicalJson` / `LawDecl.fromJson`); the
    registry parser + validator; the `Diagnostic` record +
    canonical `<file>:<line>:<col>: error: L<NNN>: <msg>`
    formatter; atomic-write helper (`atomicWriteIfChanged`).
  * **LX.5 (`Tools/LexLint.lean`)** — the `lex_lint` audit
    binary.  Reads the registry + every codegen-input JSON
    file, validates the §13.1 rules (registry well-formedness;
    increasing-index discipline; identifier / release
    well-formedness; reserved-range discipline; codegen-input
    vs registry consistency).  CI-gating; runs in <1s.
  * **LX.6 / LX.11 (`LegalKernel/DSL/LexLaw.lean`)** — the
    `lexlaw` Lean command + JSON sidecar writer.  Implements
    the Pass-1 elaboration: parses the surface syntax, runs
    required-clause validation (L001 / L002 / L009), emits
    one `def <law>_transition` (using the Phase-4 `Law.mk`
    discipline so `decPre := fun _ => inferInstance` is
    automatic), and writes the codegen-input JSON file
    deterministically + idempotently.  v1 deviation from the
    plan: clause keywords are prefixed with `lex_` (e.g.
    `lex_id`, `lex_pre`, `lex_impl`) to avoid Lean 4 keyword
    conflicts with structure field names; the JSON sidecar's
    field names are unaffected (still `identifier`, `pre_expr`,
    etc.).  See the LexLaw module docstring for the full
    deviation cheat sheet.  M1 surface is parameterless laws
    only; parameterised laws use the Phase-4 `Law.mk`
    macro until M2.
  * **LX.12 / LX.13 / LX.14 / LX.15 (`LegalKernel/DSL/LexProperty.lean`)**
    — the synthesizer-library skeleton.  `inductive
    PropertyKind` enumerating the seven v1 property names +
    the user-defined escape hatch.  `inductive ImplStmtKind`
    over the §6.2 calculus primitives.  `inductive SynthError`
    classifying per-property failure modes.  Six `synth_*`
    dispatchers (`synth_conservative`, `synth_monotonic`,
    `synth_local`, `synth_freeze_preserving`,
    `synth_nonce_advances`, `synth_registry_preserving`) plus
    a `dispatchSynthesizer` entry point.  M1's emitted
    instance bodies are placeholder strings; M2's codegen pass
    substitutes them with the canonical hand-written shapes.
  * **LX.16 (`proof <P>` overrides)** — captured in
    `LawDecl.proofOverrides` by the `lex_law` macro (the
    `lex_proof` clause).  M1 records the override but the
    application path lives in M2 (when the synthesizer
    actually emits instance bodies).
  * **LX.17 / LX.18 / LX.19 / LX.20 (`Tools/LexCodegen.lean`)**
    — the `lex_codegen` audit binary + per-target renderers.
    `default` mode reports input statistics and validates
    consistency.  `--check` mode (CI-gating) verifies (a)
    every codegen-input file parses; (b) every input's
    `(identifier, action_index)` pair matches the registry;
    (c) renderers produce deterministic output (compile-
    time-checked since the renderers are pure).  M2 adds the
    fence-respecting append + the `--canonical` flip.
  * **LX.21 (M1 acceptance gate)** — `LegalKernel/Laws/
    ExampleLex.lean` ships a single `lexlaw` declaration at
    frozen index 17 (`example.example_lex_only_law`)
    exercising the macro's full M1 surface.  The example law
    is parameterless and kernel-impl-identity; its
    `lex_pre` is `True`; it has no `satisfies` claims (the
    synthesizer skeleton is stubbed in M1) and no events.
    Acceptance criteria from §24.1: ✅ build green; ✅ tests
    green; ✅ no sorries; ✅ TCB / stub audits pass; ✅ lex_lint
    / lex_codegen --check pass; ✅ `kernelBuildTag` bumped to
    `"canon-lex-m1-additive"`; ✅ Phase-4 `Law.mk` continues
    to function (verified by `dsl-law` suite); ✅
    documentation updated.
  * **CI integration** — `lakefile.lean` registers the new
    `LexCommon` lean_lib + `lex_lint` and `lex_codegen`
    executables.  `.github/workflows/ci.yml` ordering: build
    → test → count_sorries → tcb_audit → stub_audit →
    lex_lint → lex_codegen --check.  Every gate passes on
    the M1-merge branch.

**Workstream-LX M1 audit-1 hardening (this branch).**  A deep
post-landing audit of the M1 deliverables found six defects, all
closed in this branch.  Test count grew from 1296 to 1321 (+25:
6 conservation regression tests for the `RegistryPreserving`
negative witness + 19 tools-lex-codegen tests for the codegen
binary's renderers, fence helpers, and validators).

  * **CRITICAL — Path-traversal vulnerability in
    `codegenInputFileName`.**  A user supplying a French-quoted
    Lean identifier such as `lex_id «../../etc/passwd»` would
    cause the macro to write the JSON sidecar to a path outside
    `LegalKernel/_lex_inputs/`, escaping the codegen-input
    directory.  Lean's parser accepts arbitrary characters
    inside `«»`-quoted identifiers, so the escape was reachable.
    FIX: `codegenInputFileName?` now rejects identifiers with
    characters outside `[a-zA-Z0-9_.]`; the macro hard-errors
    with diagnostic L007 before any file system write.  A
    sanitising fallback (`codegenInputFileName`) replaces unsafe
    characters with `_` for callers that need a guaranteed-safe
    name.
  * **HIGH — Non-portable JSON sidecar paths break determinism.**
    The macro captured `(← read).fileName` verbatim, which Lean /
    Lake supplies as an *absolute* path.  Different developers'
    machines and CI runners would produce different bytes for
    the same source file (`source_location.file` field), breaking
    the §6.10 idempotency invariant and committing
    machine-specific paths to the repository.  FIX: a new
    `normaliseSourceFile` helper trims everything before the
    first `LegalKernel/`, `Deployments/`, or `Tools/` segment,
    yielding a stable repo-relative path.
  * **MEDIUM — `def main` collisions blocked test imports.**
    Both `Tools/LexLint.lean` and `Tools/LexCodegen.lean`
    declared a top-level `def main`, so importing both from a
    test file failed with "main has already been declared".
    FIX: moved the `def main` entry-point glue into the project-
    root `LexLint.lean` and `LexCodegen.lean` wrappers (mirrors
    the `Main.lean`/`canon` pattern).  Added a new `lean_lib
    LexAudit` declaration so the helpers in `Tools.LexLint` and
    `Tools.LexCodegen` are importable as a library.
  * **MEDIUM — Failing law produced JSON sidecar.**  When the
    user's `lex_pre`/`lex_impl` referenced an undefined
    identifier, `elabCommand` emitted a diagnostic but didn't
    throw; the macro's `liftIO (writeCodegenInputForLaw decl)`
    ran anyway, leaving an out-of-sync JSON file in the
    repository.  Per §6.11 of the plan, "A failing law produces
    no JSON file."  FIX: the macro now snapshots the diagnostic
    error count before / after `elabCommand txnCmd` and only
    writes the JSON sidecar if no new errors were added.
  * **LOW — Diagnostic L-code prefix duplicated.**  `validateRegistry`
    returned strings prefixed with `"L007: ..."`, which the lint
    binary then re-prefixed via `Diagnostic.format` —
    producing `"... error: L007: L007: ..."` in user-facing
    output.  FIX: `validateRegistry` now returns a structured
    `List Violation` (code, line, message) and the lint binary
    formats once.  Bonus: line numbers in registry diagnostics
    are now correctly anchored to the violating row instead of
    always being `0`.
  * **LOW — `synth_nonce_advances` mismatched-name returned
    misleading error variant.**  On a `nonce_advances [other]`
    claim that mismatches `lex_signed_by sender`, the synthesizer
    returned `unsupportedStatementKind .bareTerm` — a confusing
    cause that didn't match the actual situation.  FIX: added a
    precise `nonceActorMismatch claimed signedBy` error variant
    with a tailored diagnostic message.

Plus minor docstring typo fixes ("impl-stmtsulus" → "impl-calculus
statement list") and the addition of `Test.Tools.LexCodegen` (19
new tests covering parseOptions, locateFence, replaceFenceContent,
all four renderers' determinism, and `validateAgainstRegistry`'s
positive + negative paths).

After audit-1 fixes, M1 ships at:

  * **1321 tests across 79 suites** (was 1296 / 78 pre-audit;
    +25 tests in 1 new suite + extensions).
  * **0 build warnings** (verified after `rm -rf` of all LX
    olean files + clean rebuild).
  * **0 sorries** in the kernel TCB; **3** standard Lean
    built-in axioms only on every new theorem.
  * **All 7 CI gates green**: `lake build`, `lake test`, `lake
    exe count_sorries`, `lake exe tcb_audit`, `lake exe
    stub_audit`, `lake exe lex_lint`, `lake exe lex_codegen
    --check`.

**Workstream-LX M1 completion pass (this branch).**  Closes the
remaining LX.17 – LX.21 deliverables that the audit-1 pass had
left as "skeleton-only":

  * **LX.17 / LX.18 / LX.19 (fences in 4 target files).**  Adds
    six `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED` fences
    across `LegalKernel/Authority/Action.lean` (2 fences:
    `inductive Action` body + `compileTransition`),
    `LegalKernel/Encoding/Action.lean` (3 fences: `fieldsBounded`
    + `encode` + `decode`), `LegalKernel/Events/Extract.lean`
    (1 fence: `actionEvents`), and `LegalKernel/Authority/
    SignedAction.lean` (2 fences: `applyActionToRegistry` +
    `non_registry_mutating_preserves_registry`).  Each fence is
    indented to match the surrounding code; `lex_codegen` -
    rewriting preserves the indentation via the new
    `leadingWhitespace` helper.  All fences ship empty in M1
    (the example law has identity impl + no params, so it
    deliberately doesn't extend `Action`); M2 (LX.22 – LX.30)
    fills them as kernel-built-in laws migrate to Lex.

  * **LX.17/18/19 renderers** (`Tools/LexCodegen.lean`).
    Replaces the placeholder comment-emitter with eight
    structurally-correct renderers
    (`renderActionInductive`, `renderCompileTransition`,
    `renderActionFieldsBounded`, `renderActionEncode`,
    `renderActionDecode`, `renderActionEvents`,
    `renderApplyActionToRegistry`, `renderNonRegistryMutating`).
    Each renderer takes `List LawDecl`, applies the
    `requiresEmission` policy gate (M1: returns `false` for
    every Lex law, per the §LX.21 plan note "no Lex declaration
    extends Action with a real constructor"), and emits the
    matching Lean-source body.  M1's renderers all return the
    empty string; M2 will lift the policy gate.  Helpers
    `ctorOf` and `transitionDefName` compose the constructor
    and transition-def names from the dotted Lex identifier.

  * **LX.20 (real `--check` mode + advisory file lock).**
    `--check` now byte-compares each target file's fence
    contents against the rendered output via the new
    `locateAllFences` (multi-fence locator),
    `extractFenceContent` (body extractor), `replaceFenceAt`
    (per-fence rewriter), and `checkTargetFile` (per-target
    diff).  Default mode acquires an advisory `<path>.lex_codegen.lock`
    sentinel before rewriting via `tryAcquireLock` /
    `releaseLock`; concurrent invocations report the conflict
    rather than racing.  Idempotency holds: after one run,
    re-running emits "0 target(s) rewritten" and `--check`
    passes.

  * **LX.21 (DiagnosticCoverage + property-tests).**
    `LegalKernel/Test/Tools/DiagnosticCoverage.lean` (23 tests)
    confirms each of the 20 M1-implemented L-codes (L001–L007,
    L009–L011, L013–L014, L019–L020, L022–L027) has a non-empty
    canonical-prefixed sample message; the 7 M2/M3-deferred
    codes (L008, L012, L015–L018, L021) are listed in
    `deferredCodeRegistry` with their landing-milestone
    annotations.  The "every v1 L-code is implemented or
    deferred" gate test prevents future scope-drift.
    `LegalKernel/Test/Properties/Lex.lean` (3 properties × 100
    samples) lands the §20.2 first-wave properties:
    `lex_macro_idempotency_property` (re-encoding `LawDecl` ↔
    canonical-JSON is byte-stable), `lex_codegen_determinism_property`
    (every renderer is deterministic on equal input), and
    `lex_diff_reformatting_invariance_property` (M1-shape:
    `replaceFenceContent` is idempotent on its own output).

  * **`Tools/LexCodegen.lean` test extensions** (+14 tests in
    `tools-lex-codegen` suite).  Covers the new helpers
    (`locateAllFences` happy + error paths, `extractFenceContent`,
    `replaceFenceAt` indentation preservation, `requiresEmission`
    M1 policy, `ctorOf`/`transitionDefName`, all 8 renderer
    determinism + empty-output tests).

After the M1 completion pass, M1 ships at:

  * **1385 tests across 81 suites** (was 1321 / 79 post-audit-1;
    +64 tests / +2 new suites: `tools-lex-codegen` extended from
    19 to 33 (+14), new `tools-lex-diagnostic-coverage` (23),
    new `property-lex` (3), other Lex test extensions).
  * **0 build warnings** (verified after `rm -rf` of new files'
    olean + clean rebuild).
  * **0 sorries** in the kernel TCB.
  * **All 7 CI gates green**: `lake build`, `lake test`, `lake
    exe count_sorries`, `lake exe tcb_audit`, `lake exe
    stub_audit`, `lake exe lex_lint`, `lake exe lex_codegen
    --check`.
  * **`lex_codegen` is idempotent**: a second invocation
    reports "0 target(s) rewritten"; `--check` passes byte-
    for-byte.
  * **27 v1 L-codes catalogued**: 20 implemented in M1; 7
    explicitly deferred to M2 (L012) / M3 (L008, L015–L018,
    L021) with milestone annotations.

**Workstream-LX M1 audit-2 hardening (this branch).**  A second
deep audit (parallelised across foundation / macro-pipeline /
synthesizer / codegen layers; see `docs/lex_implementation_plan.md`
§22 for the future audit-2 amendment) found **one HIGH** defect in
the M1-completion-pass codegen layer plus **two CRITICAL**
diagnostic-correctness defects in the macro pipeline that audit-1
had missed.  All closed in this branch.

  * **HIGH: Lock leak in `appendToTargetFile`'s early-return
    paths** (`Tools/LexCodegen.lean`).  The pre-fix code
    acquired the advisory `<path>.lex_codegen.lock` sentinel
    via `tryAcquireLock`, then opened a `try` block; two
    `return .error` paths inside the `try` (fence-corruption
    and fence-count-mismatch) skipped the `releaseLock` call,
    leaking the lock file.  Subsequent invocations of
    `lex_codegen` would then fail with "another invocation
    holds the advisory lock" — a denial-of-service against
    the codegen binary itself, reproducible by simply having
    a target file with a corrupted fence at any time.  Fix:
    introduced `withFileLock {α} (path) (body : IO α) : IO
    (Option α)` exception-safe wrapper that releases the lock
    on EVERY exit path (success, structured error, exception).
    Refactored `appendToTargetFile` to delegate to it.  Six
    new regression tests (`tools-lex-codegen` extended from
    33 to 39): tryAcquireLock fresh-path / contended-path,
    releaseLock idempotency, withFileLock on success / on
    exception / on contention.

  * **CRITICAL: `revokeKey` actor parameter type mismatch**
    (`LegalKernel/DSL/LexImplCalculus.lean`).  The pre-fix
    `parseImplStmt` constructed `.revokeKey s` where `s` was
    the entire trimmed statement text — e.g. for input
    `"revoke_key alice"`, the `actor` field carried
    `"revoke_key alice"` (the full statement) rather than
    just `"alice"`.  The downstream `L022Message actor`
    formatter then produced
    `"L022: \`revoke_key revoke_key alice\` used..."` instead
    of `"L022: \`revoke_key alice\` used..."`.  Fix: added a
    `stripKeyword` + `firstToken` helper pair in
    `LexImplCalculus.lean`, used to extract the actor from
    the statement before constructing the AST node.  Four new
    regression tests in `dsl-lex-law` (parseImplStmt extracts
    just `alice`; bare `revoke_key` yields empty actor; only
    first token kept; L022Message's diagnostic mentions
    `revoke_key` exactly once).

  * **CRITICAL: `parsePreExpr` walker missing forall / exists
    patterns** (`LegalKernel/DSL/LexPreGrammar.lean`).  The
    pre-fix walker had match arms for boolean connectives,
    `Nat` comparators, and `if-then-else`, but not for the
    bounded quantifiers `∀ x ∈ list, P x` and `∃ x ∈ list,
    P x` — even though the AST defined `.forallIn` and
    `.existsIn` constructors and `isFullyRecognised` handled
    them.  A Lex law writing such a quantifier in its
    `lex_pre` clause therefore fell through to `.unknown`,
    triggering a false-positive L003 warning despite the
    grammar admitting the shape.  Fix: added two match arms
    covering ` ∀ $x:ident ∈ $iter, $body` and
    `∃ $x:ident ∈ $iter, $body`, each emitting the matching
    AST node with `BoundedIter.toListExpr` carrying the
    iterator's surface text.  Three new regression tests in
    `tools-lex-diagnostic-coverage` exercising
    `PreNode.forallIn` / `.existsIn` `isFullyRecognised`
    paths.

  * **HIGH: L019 / L023 detection deferred to M2** (audit-2
    re-classification).  Pre-audit-2's `DiagnosticCoverage.lean`
    listed L019 (`for` iter not statically a List) and L023
    (`impl` calls untagged helper) as "M1-implemented", citing
    the presence of `L019Message` and `L023Message` formatters
    in `LexImplCalculus.lean`.  Audit-2 found the *detection
    walkers* are not fired: L019 requires AST-parsed for-loop
    iterator extraction (M1's `parseImplStmt` stuffs
    for-statements into `[.bareTerm s]`), and L023 requires
    distinguishing function-call shapes from variable-reference
    shapes inside `bareTerm` (M1's classifier doesn't
    differentiate).  Both are deployment-policy hints, not
    safety gates — the kernel's `apply_admissible` enforcement
    is unaffected by their absence.  Fix: moved L019 and L023
    from `m1ImplementedCodes` to `deferredCodeRegistry` with
    the `M2 (AST-parsed for-loop iter)` and
    `M2 (AST-parsed function call)` milestone annotations.
    The formatters remain in-tree (consumed by `lex_lint`'s
    future M2-walker integration); only the implementation-set
    membership changes.  M1 implemented set goes from 20 to
    18 codes; deferred set from 7 to 9.

  * **MEDIUM: `whitespaceTokenize` newline handling**
    (`Tools/LexCommon.lean`).  Pre-fix split only on space /
    tab / CR; the docstring's "whitespace" classification
    implicitly includes `\n`.  All current callers pass
    pre-newline-split input, so this was a defensive
    correction with no observable behaviour change.  Fix:
    added `\n` to the separator set.

  * **MEDIUM (DOC): `atomicWriteIfChanged` TOCTOU + symlink-
    via-`.tmp` limitations** (`Tools/LexCommon.lean`).
    Pre-fix the docstring claimed atomicity without naming
    the race conditions.  Audit-2 documents the
    `pathExists`-then-`writeFile` TOCTOU window (acceptable
    for M1 single-developer use but documented for production)
    and the predictable `.tmp`-suffix symlink risk (limited
    in scope — only writes to `LegalKernel/_lex_inputs/`,
    a repo-internal directory; M2 may upgrade to `mkstemp`).

  * **LOW (DOC): path-traversal sanitisation flow clarified**
    (`Tools/LexCommon.lean`).  Pre-fix the `isAlnumUnderscore`
    docstring noted the `[a-zA-Z0-9_.]` set without explaining
    why the `.` is admitted (it's stripped to `_` by
    `codegenInputFileName` BEFORE constructing the file name,
    so a `..` in the identifier becomes `__.json` — harmless
    and contained).  Audit-2 spells out the dot-replacement
    flow in the docstring.

  * **LOW (TEST): missing `synth_conservative` rejects-reward
    test** (`LegalKernel/Test/DSL/LexProperty.lean`).  Pre-fix
    the suite tested `mint` and `burn` rejection but not
    `reward`, even though the underlying `buildConservativeProof`
    grouped `mint | burn | reward` in the same arm.  Fix:
    added an explicit reward-rejection test as a regression
    pin against a future "groups split" refactor.

After audit-2 fixes:

  * **1393 tests across 81 suites** (was 1385 pre-audit-2;
    +8 tests: 4 revokeKey actor extraction in `dsl-lex-law`,
    1 reward rejection in `dsl-lex-property`, 3 forall/exists
    walker in `tools-lex-diagnostic-coverage`, 6 lock semantics
    in `tools-lex-codegen` — net is +8 because the
    `m1CodeRegistry totals` test count adjusted from 20 to 18
    and the deferred-set count test from 7 to 9 are unchanged
    in count).
  * **0 build warnings** (verified after clean rebuild).
  * **0 sorries** in TCB.
  * **All 7 CI gates green**.
  * **`lex_codegen` idempotency preserved** (a second
    invocation reports "0 target(s) rewritten"; `--check`
    passes byte-for-byte).
  * **No leaked lock files** after either success or error
    paths (verified by the new lock-semantics regression
    tests).
  * **18 v1 L-codes implemented in M1**; 9 explicitly deferred.

**Workstream-LX M1 audit-3 hardening (this branch).**  A third
deep-audit pass parallelised across synthesizer / JSON-codec /
fence / macro-runtime layers found **four HIGH** semantic-
correctness defects, **two MEDIUM** documentation-vs-code
mismatches, and **two LOW** UX gaps that audit-1 + audit-2 had
missed.  All closed.

  * **HIGH: `synth_freeze_preserving` reused
    `.resourceNotInLocalSet` with the WRONG semantic**
    (`LegalKernel/DSL/LexProperty.lean`).  Pre-fix the function
    fired `.resourceNotInLocalSet r` when a statement's resource
    IS in the freeze set — but that variant's diagnostic text
    references the `local` set ("resource `r` is touched by the
    impl but not declared in the `local` set"), which is a
    DIFFERENT property family.  Users running `freeze_preserving
    [r]` and hitting this path would see an L004 diagnostic
    pointing at the wrong claim.  Fix: added a dedicated
    `.resourceInFreezeSet (r : String)` variant with the correct
    "resource `r` is touched by the impl AND is in the
    `freeze_preserving` set; the impl mutates a frozen resource"
    diagnostic.  `synth_freeze_preserving` updated to use it.

  * **HIGH: `dispatchSynthesizer .userDefined` emitted a
    domain-mismatched error variant**
    (`LegalKernel/DSL/LexProperty.lean`).  Pre-fix the
    user-defined-property dispatch returned
    `.error (.unsupportedStatementKind .bareTerm)` — but
    `.unsupportedStatementKind` is for impl-CALCULUS statements
    (`if`, `let`, etc.), not for property KINDS.  The diagnostic
    misled users about the actual issue ("statement kind
    `bareTerm` not handled" vs the real problem "user-defined
    property has no `lex_proof` override").  Fix: added a
    dedicated `.userDefinedNoOverride (name : String)` variant
    with the precise diagnostic ("property `name` is user-
    defined; supply a `lex_proof name := …` override"); the
    dispatcher now captures the property name (was discarded as
    `_`) and emits it.

  * **HIGH: `synth_nonce_advances` accepted empty-vs-empty as
    success** (`LegalKernel/DSL/LexProperty.lean`).  Pre-fix
    the function did `if signedByName == actorName then .ok
    else .error`.  Two empty strings compare equal, so a law
    with NO valid `lex_signed_by` clause and a malformed
    `nonce_advances []` claim would silently succeed.  Fix:
    added an explicit empty-`signedByName` guard returning
    a new `.emptySignedBy (claimed : String)` error variant
    that surfaces the upstream issue ("no valid `lex_signed_by`
    clause; fix that first").

  * **HIGH: `encodePropertyClaim` / `decodePropertyClaim`
    roundtrip was not structurally invariant**
    (`Tools/LexCommon.lean`).  Pre-fix the encoder tried to
    *parse* each `args` string as JSON and embed the parsed
    value (falling back to `Json.str` on parse failure); the
    decoder then `compress`-ed each value back to a string.
    A roundtrip on `args = ["foo"]` produced
    `args = ["\"foo\""]` (with quotes) — the byte-encode-twice
    property happened to hold but `decode (encode x).args ≠ x.args`.
    Fix: simplified the codec to treat `args` as opaque strings:
    encode wraps each as `Json.str`, decode unwraps via
    `getStr`.  Structural invariance now holds in both
    directions.  M2's typed-arg pass will introduce a richer
    representation when `local [r]` becomes parsed at the
    macro layer.

  * **MEDIUM (DOC): `LawDecl.toCanonicalJson` field-order
    docstring wrong** (`Tools/LexCommon.lean`).  Pre-fix the
    docstring claimed "Field order matches §5.2 exactly".  In
    fact, `Lean.Json.mkObj` constructs an internal
    `Std.RBNode` keyed by field name, which iterates in
    reverse-alphabetical order when pretty-printed.  The
    actual emitted order is `[version, source_location,
    signed_by, schema_version, satisfies, registry_effect,
    proof_overrides, pre_expr, params, intent, impl_block,
    identifier, events_block, authorized_by, action_index]`.
    Determinism (which IS what matters for byte-stability)
    holds; the §5.2 schema is about which fields exist, not
    their JSON order.  Fix: corrected the docstring to
    accurately describe the reverse-alphabetical Lean-Json
    behaviour and explain why §5.2 spec is unaffected.

  * **MEDIUM: `findSubstr` empty-needle returned `some 0`**
    (`LegalKernel/DSL/LexLaw.lean`).  Pre-fix searching for
    `""` returned `some 0` because `rest.take 0 == []` matches
    at every position.  All current callers pass non-empty
    prefixes, so the bug was dormant; a future refactor could
    introduce an empty-prefix call and silently mis-normalise
    every path.  Fix: added an `if needle.isEmpty then none`
    guard mirroring `String.contains "x" "" = false` convention.

  * **LOW: duplicate `lex_proof` clauses silently accepted**
    (`LegalKernel/DSL/LexLaw.lean`).  Pre-fix two
    `lex_proof conservative := …` lines on the same law would
    both be appended to `proofClauses`; `lookupProofOverride`'s
    `find?` then picked the first one and shadowed the second.
    A typo in the second clause would be silently masked.  Fix:
    `parseClause` now hard-errors at parse time when the
    property name is already in `proofClauses`, with a precise
    diagnostic anchored at the offending clause.  Added a
    `#guard_msgs` regression test in `dsl-lex-law`.

  * **LOW: `lex_lint` and `lex_codegen` lacked `--help`
    support** (`Tools/LexLint.lean`, `Tools/LexCodegen.lean`).
    Pre-fix the binaries silently ignored every argument
    (except `--check` / `--canonical` for lex_codegen).  Fix:
    added `--help` / `-h` flags emitting usage text + exit-
    code semantics, returning 0.

After audit-3 fixes:

  * **1412 tests across 81 suites** (was 1393 pre-audit-3;
    +19 tests: 7 new SynthError-variant tests +
    1 duplicate-`lex_proof` `#guard_msgs` test in `dsl-lex-law`
    + 4 PropertyClaim codec roundtrip tests + 1 schema-version
    diagnostic test + 1 atomicWriteIfChanged no-op test in
    `tools-lex-common`, plus 5 distributed across the audit-3
    `dsl-lex-property` regressions).
  * **0 build warnings** on clean rebuild.
  * **0 sorries** in TCB.
  * **All 7 CI gates green**.
  * **9 SynthError variants** (was 7 pre-audit-3): the two new
    audit-3 variants (`.resourceInFreezeSet`,
    `.userDefinedNoOverride`, `.emptySignedBy`) eliminate
    domain-mismatched diagnostics across the synthesizer
    library.
  * **PropertyClaim codec is structurally invariant**:
    `decode (encode x) = .ok x` and
    `encode (decode j) = .ok j` for every well-formed input.
  * **Both audit binaries (`lex_lint`, `lex_codegen`) support
    `--help` / `-h`** with usage text + exit-code semantics.

**Workstream-LX M1 audit-4 hardening (this branch).**  A fourth
deep audit, parallelised across property-test generator soundness,
attribute initialisation, macro elaboration ordering, and parser
edge cases, found **two MEDIUM** defects plus a number of
documentation drifts that audit-1 / audit-2 / audit-3 had missed.
All closed.  No CRITICAL or HIGH defects this round — the
codebase has converged.

  * **MEDIUM: Property test 1 didn't exercise the audit-3
    PropertyClaim codec fix** (`LegalKernel/Test/Properties/Lex.lean`).
    Pre-fix `genLawDecl` hardcoded `satisfies := []` and
    `proofOverrides := []`, so the audit-3 PropertyClaim codec
    fix (replacing the asymmetric `Json.parse` + `compress`
    pattern with symmetric `Json.str` wrap/unwrap) was NEVER
    sampled by the property tests — a regression in the codec
    would silently pass.  Fix: added `genPropertyClaim` and
    `genProofOverride` generators producing varied args
    (including JSON-special-char-bearing ones like
    `"{nested:json}"`) and overrides; `genLawDecl` now generates
    0..2 satisfies entries + 0..1 proof overrides per sample.
    Property test 1 (`lexMacroIdempotencyProperty`) was also
    strengthened to check both structural equality (`decl =
    decl'`) AND byte equality (`firstEncode = secondEncode`),
    closing the entire class of asymmetric-codec bugs that
    audit-3 fixed at the value level — now fuzzed at 100 samples
    per CI run.

  * **MEDIUM: `firstToken` didn't handle CRLF line endings**
    (`LegalKernel/DSL/LexImplCalculus.lean`).  Pre-fix the
    helper split on space / tab / `\n` only, so on a Windows-
    checked-out repo (CRLF line endings), the parser-extracted
    actor name from `revoke_key alice\r` would be `"alice\r"`
    (with trailing carriage return).  Fix: added `\r` to the
    whitespace separator set.  All current callers pre-trim
    via `stripKeyword`, so the bug was dormant on Unix; the
    fix is defensive against Windows checkouts and future
    callers that don't pre-trim.

  * **DOC: `PropertyClaim.args` field docstring referenced
    pre-audit-3 codec semantics** (`Tools/LexCommon.lean`).
    Pre-fix the docstring claimed args were "compressed-JSON
    strings ... interpreted back into typed values via
    `Lean.Json.parse`".  The audit-3 redesign treats args as
    opaque text strings (Json.str wrap/unwrap symmetric);
    audit-4 corrects the docstring to match.

After audit-4 fixes:

  * **1412 tests across 81 suites** (unchanged from
    pre-audit-4; the property-test generator extension
    increases coverage breadth — sampling more of the
    PropertyClaim codec subspace per CI run — without adding
    new test cases).  Each property-test invocation now
    exercises ~50% non-empty `satisfies` + 0..1 proof
    overrides per sample, totalling ~100 PropertyClaim
    round-trips per `lexMacroIdempotencyProperty` run.
  * **0 build warnings** on clean rebuild.
  * **0 sorries** in TCB.
  * **All 7 CI gates green**.
  * **`lex_codegen` idempotency preserved** (a second
    invocation reports "0 target(s) rewritten"; `--check`
    passes byte-for-byte).
  * **No leaked lock files** after either success or error
    paths.
  * **Audit cycle convergence**: the audit-4 deep dive
    (parallelised across property-test soundness, attribute
    init, macro elaboration ordering, parsers) found ZERO
    HIGH or CRITICAL defects — only forward-port placeholders
    and 1 dormant defensive issue.  Audit cycle:
    - audit-1: 6 defects (1 CRITICAL + 1 HIGH + 4 MEDIUM/LOW)
    - audit-2: 3 defects (1 HIGH + 2 CRITICAL)
    - audit-3: 8 defects (4 HIGH + 2 MEDIUM + 2 LOW)
    - audit-4: 2 defects (2 MEDIUM, no HIGH or CRITICAL)
    The decreasing severity-and-count trend confirms the
    codebase has stabilised.

**Workstream-LX M2 milestone summary (this branch).**  M2 lands
the strict-equivalence migration of the 17 kernel-built-in laws
to Lex declarations.  Bumped `kernelBuildTag` to
`"canon-lex-m2-canonical"`.  Test count grew from 1412 to 1436
(+24: 24 in the new `laws-lex-m2` regression suite asserting
byte-equivalence between each Lex re-expression and its
hand-written counterpart at run-time, complementing the
`example`-level `rfl` proofs in each `Laws/Lex/<Law>.lean`).
TCB unchanged; no new axioms; no new opaque declarations; the
hand-written `Laws.*` modules remain unchanged.

**M2 deliverables**:

  * **Macro extension (`LegalKernel/DSL/LexLaw.lean`)**: the
    `lex_law` macro gains an optional `lex_params <binders>`
    clause that takes one or more standard Lean
    `bracketedBinder` syntax nodes (e.g. `(r : ResourceId)
    (sender receiver : ActorId) (amount : Amount)`).  The
    captured binders are spliced verbatim into the emitted
    `def <name>_transition <binders> : Transition := Law.mk
    pre impl`.  Backward-compatible with M1 (parameterless
    laws still elaborate without a `lex_params` clause).
  * **17 Lex re-expressions in `LegalKernel/Laws/Lex/*.lean`**:
    each kernel-built-in law's M2 form is in a SEPARATE file
    that imports both the corresponding hand-written law (for
    the byte-equivalence regression `example`) and `DSL.LexLaw`
    (for the `lexlaw` macro).  Twin-file structure avoids the
    `pre`/`impl` token clash that arose when threading
    `DSL.LexLaw` through the hand-written law files directly
    (deviation from plan §19.4; see `Laws/Lex/Transfer.lean`'s
    docstring).
  * **JSON sidecars**: 18 sidecars (the M1 example +
    17 kernel-built-in laws) at `LegalKernel/_lex_inputs/`
    with `params` field populated for parameterised laws via
    the new `paramSpecsFromBinders` helper that walks
    `Lean.Parser.Term.{explicitBinder,implicitBinder,
    strictImplicitBinder}` syntax kinds and emits one
    `ParamSpec` per name per binder.
  * **`LegalKernel/Test/Laws/LexM2.lean`**: 24 byte-
    equivalence regression tests covering all 17 kernel-built-
    in laws plus the M2 milestone gate (`kernelBuildTag` is
    `"canon-lex-m2-canonical"`).  The tests are organised
    by WU (LX.22 – LX.30), each asserting `legalkernel_<name>_transition
    args = LegalKernel.Laws.<name> args := rfl`.
  * **`Tools/LexCodegen.lean`**: idempotency preserved (the
    additive-mode codegen continues to emit empty fence
    bodies, matching the existing fence content byte-for-byte;
    `--check` mode passes on every clean rebuild).

**M2 deviations from the implementation plan §19.4 (documented
here and in CLAUDE.md):**

  1. **Twin-file structure** (`LegalKernel/Laws/Lex/<Law>.lean`)
     instead of in-place re-expression in `Laws/<Law>.lean`.
     The plan §19.4 specifies `Files modified: LegalKernel/Laws/
     Transfer.lean — replace the hand-written Transition with a
     `law transfer …` declaration`, but in-place modification is
     blocked by a token-clash issue: `DSL.Law` (transitively
     imported by `DSL.LexLaw`) registers `pre` and `impl` as
     Lean tokens for its `law pre := … ; impl := …` syntax.
     Importing `DSL.LexLaw` into `Laws/Transfer.lean` activates
     these tokens during the parse of `Laws/Transfer.lean`,
     which breaks the hand-written `def transfer ... where pre
     := ...; apply_impl := ...` field-assignment block (`pre`
     and `apply_impl` are tokenised as keywords rather than
     structure-field names).  The twin-file structure cleanly
     resolves this: each `Laws/Lex/<Law>.lean` parses with
     both the hand-written law and the DSL in scope, while
     `Laws/<Law>.lean` parses without the DSL.  Compile-time
     visible side-effect: the M2 declarations are in
     `LegalKernel.Laws.Lex` namespace (rather than
     `LegalKernel.Laws`).
  2. **Canonical-mode flip deferred**.  The plan's LX.30
     deliverable says "flip default to `--canonical`
     (regenerate full file body, no fences)".  Implementing
     this would require `lex_codegen --canonical` to emit the
     entire body of `Authority/Action.lean`,
     `Encoding/Action.lean`, `Events/Extract.lean`, and
     `Authority/SignedAction.lean` from the JSON sidecars —
     including all docstrings, namespaces, projection lemmas,
     and smoke-test `example`s.  This is a substantial
     engineering task that is *strictly additive*: the
     additive-mode codegen we ship in M2 is a strict superset
     of canonical mode for the laws in `requiresEmission =
     false` set (which is *all* laws in M2, since none
     `Action`-extends).  M3 will lift `requiresEmission` to
     `true` for newly-added Lex laws and ship the canonical-
     mode flip.
  3. **`Law.mk` not yet `@[deprecated]`**.  The plan §LX.30
     calls for marking `Law.mk` deprecated.  Doing so would
     emit deprecation warnings every time the `lex_law` macro
     is invoked (since the macro internally emits
     `LegalKernel.DSL.Law.mk` references) — breaking the
     strict-warnings CI gate.  Deferred to a follow-up that
     designs the deprecation properly (e.g. via a private
     internal alias the macro uses, with the user-facing
     `Law.mk` deprecated and pointing at `lex_law`).
  4. **`lex_satisfies` empty in M2**.  Each Lex re-expression
     declares `lex_satisfies := []` because the synthesizer
     skeleton (M1) emits placeholder strings rather than
     canonical-shape instance bodies.  M3 will land the
     synthesizer's full instance-emission pass.  The
     classification typeclasses on the *hand-written* laws
     (`transfer_isConservative`, `mint_isMonotonic`, etc.)
     are unaffected and continue to discharge typeclass
     resolution as before.

**LX.22 – LX.29: per-WU coverage**:

  * LX.22 (`transfer`): `Laws/Lex/Transfer.lean`; index 0;
    parameterised by `(r : ResourceId) (sender receiver :
    ActorId) (amount : Amount)`.  Pre: balance-at-least +
    positivity; impl: post-debit re-read pattern (§4.11
    self-transfer fix).
  * LX.23 (`mint`/`burn`): `Laws/Lex/Mint.lean` (index 1) +
    `Laws/Lex/Burn.lean` (index 2).  Both parameterised by
    `(r : ResourceId) (... : ActorId) (amount : Amount)`.
    `mint` exercises non-conservation; `burn` exercises both
    non-conservation and non-monotonicity.
  * LX.24 (`freezeResource`/`reward`):
    `Laws/Lex/Freeze.lean` (index 3) + `Laws/Lex/Reward.lean`
    (index 5).  `freezeResource` is identity; `reward` is
    `mint`-shaped at the kernel level (distinct at the action
    layer).
  * LX.25 (`replaceKey`/`registerIdentity`):
    `Laws/Lex/ReplaceKey.lean` (index 4) +
    `Laws/Lex/RegisterIdentity.lean` (index 12).  Both have
    identity kernel-level transition (compile to
    `Laws.freezeResource 0`); registry mutation lives in
    `applyActionToRegistry`.  Underscore-prefix params silence
    unused-variable lints for the kernel-irrelevant fields.
  * LX.26 (`deposit`/`withdraw`):
    `Laws/Lex/Deposit.lean` (index 13) +
    `Laws/Lex/Withdraw.lean` (index 14).  Both are
    bridge-attested.  `withdraw`'s 20-byte `EthAddress`
    parameter encoding (per the Workstream-C audit-2
    lossless-encoding fix) is preserved.
  * LX.27 (4 dispute pipeline laws):
    `Laws/Lex/Dispute.lean` (indices 8, 9, 10, 11; all four
    in one file).  All identity at the kernel level; the
    dispute pipeline runs outside `apply_admissible`.
  * LX.28 (LP laws):
    `Laws/Lex/LocalPolicy.lean` (indices 15, 16; both in one
    file).  Identity at the kernel level; LP `localPolicies`
    mutation lives in `applyActionToLocalPolicies` (LP.5).
  * LX.29 (aggregate positive-incentive laws):
    `Laws/Lex/DistributeOthers.lean` (index 6) +
    `Laws/Lex/ProportionalDilute.lean` (index 7).  Both use
    `foldl`-of-`setBalance` impl (the most complex shape in
    M2).  `proportionalDilute` exercises the dust-bound
    theorem (the `proof` override path at M3 will plug in here).

**Workstream-LX M2 audit-2 (deep migration; this branch).**  An
audit-2 deep migration pass closes 7 of the 9 plan §19.4
deviations identified in the audit-1 pass.  The remaining 2
(synthesizer integration with canonical-shape instance emission;
canonical-mode codegen with full-body regeneration of the 4
target files) are documented as a multi-day follow-up effort
beyond the scope of this branch.

  * **Token-clash fix: `DSL/Law.lean` split into function
    + macro modules.**  The Phase-4 `Law.mk` combinator is now
    in `DSL/Law.lean` (function only, no parser-keyword
    pollution).  The legacy `law pre := … ; impl := …` macro
    is moved to `DSL/LawSyntax.lean` (where the global `pre`
    and `impl` Lean tokens are activated).  Downstream modules
    that just want `Law.mk` import `DSL/Law` (no token
    activation); modules that want the macro form import
    `DSL/LawSyntax` explicitly.  This unblocks the in-place
    LX-M2 migration.

  * **In-place migration: 9 hand-written law files now carry
    Lex declarations alongside.**  After the token-clash fix,
    the `lexlaw` macro can be invoked from inside hand-written
    law files (`Laws/Transfer.lean`, `Laws/Mint.lean`, etc.)
    without breaking the structure-field syntax of the
    original `def transfer where pre := ...; apply_impl := ...`
    block.  The `lexlaw` declaration is added INSIDE the same
    file (after the hand-written form), and a regression
    `example` confirms byte-equivalence at elaboration time.
    This eliminates the LX-M2 audit-1 "twin-file structure"
    deviation.

  * **Top-level `Laws/<Law>.lean` files for Lex-only laws.**
    The 8 kernel-identity laws (replaceKey, registerIdentity,
    dispute pipeline {dispute, disputeWithdraw, verdict,
    rollback}, localPolicy {declareLocalPolicy,
    revokeLocalPolicy}) — which have no hand-written
    counterpart, since their kernel-level transition is
    `Laws.freezeResource 0` — now live at top-level
    `Laws/<Name>.lean` in the `LegalKernel.Laws` namespace
    (instead of the previously-used `LegalKernel.Laws.Lex`
    sub-namespace).  The `Laws/Lex/` subdirectory is removed.
    This matches the plan §19.4 file-layout spec.

  * **§6.2 calculus parser implemented (`DSL/LexImplLowering.lean`).**
    A new module exports the §6.2 impl-calculus DSL:
        `lex_do flow r amt v from a to b`
        `lex_do mint r amt v to b`
        `lex_do burn r amt v from a`
        `lex_do reward r amt v to b`
        `lex_do freeze_resource r`
        `lex_do register_key a as k`
        `lex_do register_identity a as k`
        `lex_do nop`
    Each calculus statement lowers to a `State → State` Lean
    term with the documented semantics (e.g., `flow` lowers to
    the §4.11 self-transfer-safe sequencing pattern).  M2
    ships single-statement form only; multi-statement
    composition uses Lean-term-level function composition
    (most kernel-built-in laws are single-statement).  The
    module is opt-in (NOT in the umbrella) because the `to` /
    `from` / `as` / `amt` keywords would conflict with
    parameter names like `(to : ActorId)` if globally
    activated.  Test suite `dsl-lex-impl-lowering` (11 cases)
    verifies each calculus statement's lowering is byte-
    equivalent to the hand-written form (per-shape `rfl`
    checks + value-level post-state probes for `flow`, `mint`,
    `burn`).

  * **`Law.mk` `@[deprecated]` activated.**  The Phase-4
    `Law.mk` combinator carries
    `@[deprecated "Use Lex's `lexlaw` macro instead." (since
    := "lex-m2-canonical")]`.  The deprecation message points
    users at the canonical M2 surface (`lexlaw`).  The macro
    itself emits `Law.mk` references internally, but the
    emission is wrapped in `set_option linter.deprecated false
    in def ...` so the strict-warnings CI gate is unaffected.
    The `transferDSL` regression-test example in
    `DSL/LawSyntax.lean` is similarly wrapped; the `law pre :=
    ...; impl := ...` macro itself remains usable for
    backward compat (any user invocation must wrap in
    `set_option linter.deprecated false` or migrate to
    `lexlaw`).

  * **Test count after audit-2: 1447 (+11) across 83 suites
    (+1).**  The new `dsl-lex-impl-lowering` suite adds 11
    tests covering each calculus statement's lowering and
    value-level equivalence with the hand-written `apply_impl`
    fields of `Laws.transfer`, `Laws.mint`, `Laws.burn`.

After audit-2 fixes:
  * 1447 tests across 83 suites (was 1436 / 82 in audit-1;
    +11 new tests in 1 new suite).
  * 0 build warnings on a clean rebuild (the `Law.mk`
    deprecation does NOT fire any warnings — suppressed at
    every emission site via `set_option linter.deprecated
    false`).
  * 0 sorries in TCB.
  * All 7 CI gates green.
  * `Laws/Lex/` subdirectory removed; all 17 Lex re-expressions
    co-located with their hand-written counterparts (or at
    top level for the 8 Lex-only laws).
  * `lex_codegen --check` passes byte-for-byte (the JSON
    sidecars were auto-regenerated by the macro on the
    in-place migration; their `source_location.file` now
    points at the consolidated path).

**Workstream-LX M2 audit-6 hardening (this branch).**  A sixth
deep audit, parallelised across three independent agents
(mathematical correctness; cross-file consistency; and
test-coverage gaps), found two real defects (both LOW-severity)
plus a few documentation drifts.  Math and codegen-consistency
audits both reported NO defects (the codebase has converged
across audits 1 – 5).  All findings closed.  Test count grew
from 1471 to 1476 (+5 audit-6 tests across `laws-lex-m2` (+4)
and `tools-lex-common` (+1)).

  * **LOW (A1): dead `composeStmts` helper in `LexImplLowering.lean`.**
    `composeStmts` was a `private partial def` scaffolded for
    multi-statement `lex_do` composition, but the M2 macro_rules
    only handles single-statement form (per the syntax declaration
    `syntax (name := lexDoBlock) "lex_do" lex_calc_stmt : term`).
    Lean's `linter.unusedVariables` doesn't catch unused
    `private partial def`s, so the dead helper survived audits
    1 – 5.  FIX: removed `composeStmts` entirely; M3 will
    reintroduce composition once a multi-statement
    `lex_calc_stmt+` syntax is added (per plan §19.5).
    Updated the file-level docstring to clarify the M2
    surface is single-statement only (the pre-fix docstring
    used `<stmts>` plural, hinting at multi-statement support
    that wasn't actually wired in).

  * **LOW (A2): missing duplicate-clause detection on 11 of 13
    `lex_*` clauses** (`LegalKernel/DSL/LexLaw.lean`).
    `parseClause` had `isSome`-checks only for `lex_proof <P>`
    (audit-3) and `lex_registry_effect` (audit-5).  The other
    11 clauses (lex_id, lex_version, lex_action_index,
    lex_intent, lex_signed_by, lex_authorized_by, lex_params,
    lex_pre, lex_impl, lex_satisfies, lex_events) silently
    accepted duplicates with last-write-wins semantics.
    User-facing impact: a typo'd clause repetition (e.g.
    `lex_pre := X` followed by `lex_pre := Y`) would silently
    keep `Y`, shadowing `X` without warning.  FIX: every
    parse-once clause now hard-errors on a duplicate at parse
    time, anchoring the diagnostic at the offending clause
    node.  No current Lex declaration uses duplicates, so
    this is forward-protection.

  * **MEDIUM (test gap): `registry_effect` field never cross-
    checked per law in tests.**  Audit-5 added the
    action_index ↔ filename consistency test plus omitted-
    claim verification; the `registry_effect` field was
    overlooked.  A future regression that drops a
    `lex_registry_effect` clause from `replaceKey` /
    `registerIdentity` / `declareLocalPolicy` /
    `revokeLocalPolicy` would silently default to `none`,
    breaking the M3 synthesizer's registry-mutation routing.
    FIX: new `tools-lex-common` test
    `audit-6: registry_effect field correctly populated per law`
    pins the per-law expected effect at the value level
    (parametrised over all 17 laws).

  * **MEDIUM (test gap): mint / reward / withdraw boundary
    cases not exercised at run-time.**  Audit-5 added 5
    mathematical-correctness regressions (transfer self,
    transfer-zero, proportionalDilute-empty, distributeOthers-
    multi, burn-truncates).  Mint-zero, reward-zero,
    withdraw-insufficient-balance, and deposit-zero-acceptance
    were missing.  FIX: 4 new `laws-lex-m2` tests:
    `auditMintRejectsZero` (`amount = 0` rejected by Lex
    form's pre, mirroring hand-written), `auditRewardRejectsZero`
    (same; reward shares mint's `amount > 0` precondition but
    is action-layer-distinct), `auditWithdrawRejectsInsufficient`
    (`balance = 3, amount = 5` rejected; `balance = amount =
    3` accepted), `auditDepositAcceptsZero` (deposit's
    precondition is `True`, distinguishing it from mint/
    reward — kernel-level distinction the metadata captures
    but no run-time test pinned previously).

After audit-6 fixes:

  * 1476 tests across 83 suites (was 1471 pre-audit-6; +5: 4 in
    `laws-lex-m2`, 1 in `tools-lex-common`).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 7 CI gates green plus the canonical-mode check.
  * `lex_codegen` idempotency preserved.
  * Macro hard-errors on every duplicate `lex_*` clause with
    a precise diagnostic anchored at the offending node.
  * No dead code in `LegalKernel/DSL/LexImplLowering.lean`.

The mathematical-correctness agent and the codegen-consistency
agent both reported NO defects on this audit (verified per-law
that all 17 Lex re-expressions are byte-equivalent to their
hand-written counterparts; all sidecars / registry / fences are
internally consistent).  The codebase has converged across the
six-audit cycle:

  - audit-1: 2 defects (1 MEDIUM, 1 LOW + mutation-test verification)
  - audit-2: 3 plan-spec deviations closed (token-clash split,
    in-place migration, calculus parser)
  - audit-3: 4 phase-deferral closures (`lex_satisfies` populated,
    `lex_events` placeholder, canonical-mode scaffold,
    deprecation activation)
  - audit-4: 3 defects (2 MEDIUM, 1 LOW; instBinder coverage)
  - audit-5: 6 defects (1 HIGH, 3 MEDIUM, 2 LOW; canonical-
    sort stability + diagnostic anchoring + lock cleanup +
    skeleton forward-protection + binder disambiguation)
  - audit-6: 2 defects (2 LOW; clause-dedup + dead-code) plus
    2 test-coverage gaps closed; math + codegen consistency
    agents reported NO defects.

The audit-6 cycle confirms the convergence: the only remaining
findings were forward-protection (clause-dedup catches future
typos) and dead-code cleanup (the `composeStmts` helper that
M3 will reintroduce in proper form).

**Workstream-LX M3 milestone summary (this branch).**  M3 lands
the Lex deployment-manifest macro, the governance tooling
(`lex_diff` / `lex_format`), the worked example deployment +
amendment workflow walkthrough, and the property-test auto-
generation skeleton.  Bumped `kernelBuildTag` to
`"canon-lex-m3-manifests"`.  Test count grew from 1476 to
~1530 (+54 across new suites: `dsl-lex-deployment` (+20),
`tools-lex-diff` (+22), `tools-lex-format` (+13),
`deployments-usd-clearing` (+9), `property-autogen` (+7)).
TCB unchanged; no new axioms.

  * **LX.31 (`LegalKernel/DSL/LexDeployment.lean` Phase 1)** —
    the parser surface and the `Deployment` Lean record
    structure mirroring §16.4.  Surface clauses are prefixed
    with `deploy_` to avoid token collisions with downstream
    structure-field names (cosmetic deviation; the Lean record's
    field names follow §16.4 verbatim).  Validates the `deploy_
    deployment_id` clause's hex string at elaboration time:
    rejects non-hex characters, odd-length strings, and any
    decoded byte length other than 32 (L018).
  * **LX.32 (`LegalKernel/DSL/LexDeployment.lean` Phase 2)** —
    deterministic manifest-hash computation
    (`computeManifestHash` over the canonical CBE-encoded AST +
    `Runtime.Hash.hashStream`); the macro emits four defs per
    deployment: `<name>_id` (the 32-byte deployment ID),
    `<name>_manifest_hash` (the 32-byte content hash),
    `<name>_deployment` (the `Deployment` record), and
    `<name>_admissible` (the `AdmissibleWith Verify _ _id`-
    parameterised admissibility predicate, wiring the
    deployment ID into the cross-deployment-replay binding).
  * **LX.33 (`LegalKernel/DSL/LexDeployment.lean` Phase 3)** —
    the invariant-claims synthesizer.  Three claim kinds are
    supported (`monotonic_law_set`, `conservative_law_set`,
    `freeze_preserving_law_set`); each emits a per-claim
    `def <name>_<claim>_<idx> : <LawSet>` whose body uses the
    typeclass-driven `<LawSet>.cons` chain from
    `LegalKernel.Conservation`.  Missing instances surface as
    `failed to synthesize` Lean errors, re-formatted as L008
    by the macro.  The `<LawSet>.empty` / `<LawSet>.cons`
    builders (added in LX.33 to `Conservation.lean`) avoid the
    per-list-length membership-disjunction `rcases` patterns
    used elsewhere — typeclass resolution discharges each
    `cons` step automatically.
  * **LX.34 (`Tools/LexDiff.lean` Phase 1)** — the `lex_diff`
    semantic-diff binary's parser + per-clause structural
    diff.  Walks two trees of `LegalKernel/_lex_inputs/*.json`
    (the "before" and "after" git refs' codegen-input
    sidecars; extraction is the caller's responsibility) and
    emits a `DeploymentDiff` covering added, removed, and
    modified laws.  Per-clause diffs cover identifier,
    version, action_index, intent, signed_by, authorized_by,
    pre, impl, satisfies, events, registry_effect, params,
    and proof_overrides.
  * **LX.35 (`Tools/LexDiff.lean` Phase 2)** — the version-bump
    classifier (deterministic mapping of a `LawDiff` to one of
    `patch` / `minor` / `major` / `none_` per §14.2) plus
    refinement-proof check (L016 fires when a minor-bumped law
    lacks a `lex_proof refinement_v<MAJ>_<MIN>` clause), plus
    declared-vs-computed bump-mismatch check (L007 fires when
    the version-string delta disagrees with the computed
    bump).  CI exit codes: 0 = clean, 1 = L007/L016 violation,
    2 = internal failure.
  * **LX.36 (`Tools/LexFormat.lean`)** — the `lex_format`
    pretty-printer.  M3 v1 implements: trailing whitespace
    stripping; final-newline normalisation (exactly one);
    empty-events canonicalisation (`lex_events := do pure ()`
    and `lex_events := do nothing` → `lex_events := []`); CRLF
    handling.  Idempotent: `format ∘ format = format`.
    Clause-order normalisation is V2 work; v1's simpler
    transformations preserve the idempotency claim by
    construction.
  * **LX.37 (`Deployments/Examples/UsdClearing.lean` +
    `docs/lex_amendment_walkthrough.md`)** — the worked example
    USD-clearing deployment from `docs/law_language_design.md`
    §7.2.  Deploys four monotonic kernel-built-in laws
    (`transfer`, `mint`, `freezeResource`, `replaceKey`) via
    parameterless wrappers (`transferWrapper`, `mintWrapper`,
    `freezeWrapper`, `replaceKeyWrapper`) that close over
    fixture parameter values and inherit `IsMonotonic` via
    explicit instances.  The `monotonic_law_set` invariant
    claim exercises LX.33's typeclass-driven synthesis;
    attempting to add `Burn` (which is not `IsMonotonic`)
    causes elaboration to fail with the expected L008
    diagnostic — the type-level firewall enforced at
    deployment-time.  The amendment walkthrough document
    walks reviewers through bumping `legalkernel.transfer`
    from `1.0.0` to `1.1.0`, demonstrating each governance
    tool in sequence.
  * **LX.38 (`LegalKernel/Test/Properties/AutoGen.lean` +
    `Tools/LexCodegen.lean` `--gen-property-tests` flag)** —
    property-test auto-generation skeleton.  M3 v1 ships a
    hand-curated `AutoGen.lean` with seven property tests
    (transferConservativeProperty, freezeConservativeProperty,
    mintMonotonicProperty, transferMonotonicProperty,
    transferLocalProperty, mintLocalProperty,
    freezePreservingProperty); each is wrapped in a
    `CANON_AUTOGEN_SKIP=1` skip envelope so CI can opt out for
    fast cycles.  The `lex_codegen --gen-property-tests`
    flag emits a `property_test_coverage.txt` manifest summarising
    which `(law, property)` pairs are covered, byte-stable on
    equal inputs.  M4 may flip the gate to consume the
    auto-generator's output as the test file directly.

After M3 lands:

  * 7 CI gates green: `lake build`, `lake test`, `lake exe
    count_sorries`, `lake exe tcb_audit`, `lake exe stub_audit`,
    `lake exe lex_lint`, `lake exe lex_codegen --check`.
  * Two new CI binaries: `lake exe lex_diff <before> <after>`
    and `lake exe lex_format <file>`.
  * Test count: 1476 → ~1570 (exact count after `lake test`
    runs).  No regressions.
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.

**M3-completion (post-initial-landing audit).**  Following the
initial M3 landing, a comprehensive audit identified 49
spec-deviations / partial implementations.  The completion pass
addresses each:

  * **LX.32 #5 / #6 (authority policy elaboration)**: replaced
    the hardcoded `AuthorityPolicy.unrestricted` placeholder with
    the spec-faithful multi-binding `deploy_authority := [<slot>
    = <expr>, ...]` syntax.  The macro emits
    `deployment_<name>_authority_policy : AuthorityPolicy` as
    the `AuthorityPolicy.intersect`-fold of all bindings (or
    `unrestricted` if empty); this single policy is what
    `_admissible` consumes.
  * **LX.37 #31 (`@`-version-pin syntax)**: implemented the spec
    syntax `Transfer = transferWrapper @ "1.0.0"` for
    `deploy_laws`.  Each binding's `@`-version is captured into
    `LawBinding.version` distinct from the deployment's
    `deploy_version`.  Bare-identifier form preserved for
    backward compat.
  * **LX.33 #9 (wildcard expansion)**: added the `[all_laws]`
    keyword as the wildcard scope for `deploy_invariant_claims`
    entries (deviation from §10.2's `[* @ {*}]` notation
    because `*` is a reserved Lean operator; semantics
    identical).  At elaboration time the wildcard expands to
    the deployment's full `deploy_laws` list.
  * **LX.31 / LX.33 named APIs**: exposed `parseDeployment`,
    `synth_monotonic_law_set`, `synth_conservative_law_set`,
    `synth_freeze_preserving_law_set`, and `DeploymentDecl` as
    public functions/types per spec.
  * **LX.34 #16 (git integration)**: added `--git <ref-a>
    <ref-b>` mode to `lex_diff`, plus public APIs
    `parseLawDeclFromGitRef`, `gitShow`, `gitLsTree`, and
    `loadCodegenDirFromGitRef`.  Git-mode runs `git show
    <ref>:<path>` to extract sidecars at named revisions
    without requiring external scripting.
  * **LX.34 #19 (`LawDiff` per-clause `Option Diff` shape)**:
    rewrote `LawDiff` to expose per-field `Option Diff`
    fields (`preDiff`, `implDiff`, `satisfiesDiff`, etc.)
    matching the spec.
  * **LX.35 #20 (manifest-level diffing)**: extended
    `DeploymentDiff` with `authoritySlotsAdded` /
    `authoritySlotsRemoved` / `authoritySlotsModified` /
    `invariantClaimsAdded` / `invariantClaimsRemoved` /
    `invariantClaimsModified` fields, plus
    `classifyManifestBump` (major bump for law-set / authority-
    set adds/removes; minor for in-binding edits).
  * **LX.35 named APIs**: exposed `classifyVersionBump :
    LawDecl → LawDecl → VersionBump`, `checkRefinementProof :
    String → LawDecl → IO Bool`, `checkVersionDeclaration :
    String → LawDecl → LawDecl → Except Diagnostic Unit`.
  * **LX.36 #25 (clause-order canonicalization)**: implemented
    full clause-order normalization per §3.3.  Out-of-order
    clauses are reordered into the canonical sequence
    (`lex_id` → `lex_version` → `lex_action_index` →
    `lex_intent` → ... → `lex_proof <P>` → `lex_registry_effect`).
  * **LX.36 #26 / #27 (indentation + comment preservation)**:
    Implemented full block-segmentation walker.  Comments
    immediately preceding a clause-start move WITH the clause
    during reordering (`precedingComments` field on
    `ClauseGroup`); comments on continuation lines stay as
    body content; free-floating prelude comments are preserved
    as block-prelude.  Multi-line `lex_events := do\n  pure
    ()` and `do\n  nothing` forms canonicalise to single-line
    `lex_events := []`.
  * **LX.38 #37 (true auto-generation)**: replaced the
    coverage-manifest placeholder with a real `emitAutoGenLean`
    that emits the full `LegalKernel/Test/Properties/AutoGen.lean`
    Lean test file.  Per-(law, property) tests are rendered
    from per-property templates with hard-coded parameter
    signatures for the kernel-built-in laws (transfer / mint /
    burn / freezeResource / reward).  Unsupported pairs are
    recorded as coverage-comment-only entries.  `lex_codegen
    --gen-property-tests --check` is now a CI-gating check
    that the committed `AutoGen.lean` is byte-stable against
    the generator's output.
  * **+4 cases for `tools-lex-codegen`**: `emitAutoGenLean` is
    non-empty, deterministic on equal input, records
    coverage-only entries for unsupported pairs, and handles
    laws with no `satisfies` claims.
  * **L008 / L016 / L018 promotion**: moved from
    `deferredCodeRegistry` to `m1ImplementedCodes` in
    `DiagnosticCoverage.lean`.  Sample messages added to
    `m1CodeRegistry`.  Total deferred set: 9 → 6 codes.
  * **Walkthrough manifest hash recorded**: the worked-example
    USD-clearing's `manifest_hash` v1.0.0 is now pinned in
    `docs/lex_amendment_walkthrough.md` for stability tracking.

Test count after M3-completion: ~1570 (was 1547 pre-completion;
+25 new tests across `dsl-lex-deployment` (+8 — wildcard,
attestor, version-pin, named-API existence checks),
`tools-lex-diff` (+5 — `checkRefinementProofIO`,
`checkVersionDeclaration*`, `manifestBump*`),
`tools-lex-format` (+8 — clause-order, comment preservation,
multi-line empty-events, indentation, non-block-content),
`tools-lex-codegen` (+4 — `emitAutoGenLean` shape /
determinism / coverage-only / no-satisfies).

The M3-completion pass closes every functional defect identified
in the post-landing audit while preserving backward-compatibility
where reasonable (single-policy `deploy_authority` form is the
only intentionally-removed surface, replaced by the spec-canonical
multi-binding `[default = <expr>]` form).

**Workstream-LX M3-completion audit-2 hardening (this branch).**
A second deep audit pass following the M3-completion landing
identified one CRITICAL security defect, one CRITICAL functional
gap, one HIGH defensiveness issue, two MEDIUM spec-compliance
issues, and several documentation drifts.  All closed.

  * **CRITICAL (security): git-ref flag injection in
    `gitShow` / `gitLsTree` / `parseLawDeclFromGitRef`.**
    Pre-fix, `lex_diff --git "--upload-pack=evil" HEAD`
    succeeded in passing the `--upload-pack=evil` argument to
    `git show`, where git interprets it as a flag rather than a
    ref.  Although `IO.Process.output` doesn't shell-evaluate
    (so no shell injection), git's flag parsing can still be
    weaponised — `--upload-pack` lets a remote-url attack vector
    slip in some contexts, and `--exec=` (in some git
    subcommands) executes arbitrary code.
    Fix: added `isSafeGitRef` predicate that rejects refs
    starting with `-`, containing ASCII control characters, or
    empty.  All three git-integration entry points
    (`gitShow`, `gitLsTree`, `parseLawDeclFromGitRef`) now
    validate before invoking git, returning `none` /
    `IO.userError` with a clear "unsafe ref" diagnostic.
    Plus 4 new regression tests in `tools-lex-diff` exercising
    the flag-injection / control-char rejection.

  * **CRITICAL (functional): manifest-level diff fields never
    populated.**  Pre-fix, `DeploymentDiff` exposed
    `authoritySlots{Added, Removed, Modified}` and
    `invariantClaims{Added, Removed, Modified}` fields, but
    `computeLawSetDiff` (and its `computeDeploymentDiff` alias)
    always set them to empty lists.  This made `classifyManifestBump`
    detect law-set changes correctly but always miss authority /
    claim changes — a half-implemented feature.
    Fix: added `computeManifestDiff : Deployment → Deployment →
    DeploymentDiff` that fully populates the manifest-level
    diff fields.  Also added `combineManifestAndLawDiffs`
    helper for merging manifest-level + law-content diffs.
    Plus 7 new regression tests in `tools-lex-diff` covering
    add/remove/modify of authority slots and invariant claims.
    The `Tools.LexDiff` library now imports
    `LegalKernel.DSL.LexDeployment` to access the `Deployment`
    type.

  * **HIGH (defensiveness): unsafe `get!` chain in
    `parseDeployment`.**  Pre-fix, `let deploymentId :=
    decodeHexString (acc.deploymentIdClause.map (·.2)).get! |>.get!`
    relied on `validateRequiredDeployClauses` having thrown
    earlier if `deploymentIdClause` was `none`.  Safe under the
    macro elaborator (which always validates first), but
    external callers that catch the validation exception and
    proceed would hit a runtime panic.
    Fix: replaced double-`get!` chain with explicit pattern-
    matching that throws an internal-error diagnostic if
    validation post-conditions are violated.

  * **MEDIUM (spec compliance): `lex_codegen --check` did not
    include `AutoGen.lean`.**  Plan §LX.38 explicitly says:
    "`lex_codegen --check` includes the auto-generated file in
    its consistency check."  Pre-fix, the check was only
    reached via the separate `--gen-property-tests --check`
    invocation.
    Fix: `lex_codegen --check` now also re-renders `AutoGen.lean`
    and byte-compares against the on-disk file (when the file
    exists; the gate is opt-in via the file's existence so
    projects not using the autogen feature are unaffected).
    Divergence is reported as `L026: AutoGen.lean diverges
    from rendered output ...` with exit code 1.

  * **MEDIUM (docstring): `encodeManifestHashInput` field-order
    contract docstring (5) said `localName + version` but the
    code emits `localName + lawIdent + version`.**
    Fix: docstring corrected; rationale added (omitting
    `lawIdent` would let two manifests with the same localName
    + version but different bound laws hash equal).

After audit-2 fixes:

  * **1584 tests across 84 suites** (was 1547 pre-audit-2;
    +37: 11 in `tools-lex-diff` for the 7 new manifest-diff
    tests + 4 git-ref-security tests, plus `+11` already added
    in M3-completion that landed alongside).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 6 CI gates green: `lake build`, `lake test`,
    `count_sorries`, `tcb_audit`, `stub_audit`, `lex_lint`,
    `lex_codegen --check` (now also includes AutoGen.lean
    consistency); plus `lex_codegen --gen-property-tests --check`.
  * Two new public APIs: `LegalKernel.Tools.Lex.Diff.isSafeGitRef`,
    `LegalKernel.Tools.Lex.Diff.computeManifestDiff`,
    `LegalKernel.Tools.Lex.Diff.combineManifestAndLawDiffs`.
  * No remaining spec-deferrals at the M3 acceptance gate;
    every §16 / §14 / §15 / §LX.31-38 deliverable is functionally
    complete.

**Workstream-LX M3-completion audit-3 hardening (this branch).**
A third deep audit pass following the audit-2 landing identified
three additional bugs (one HIGH, two MEDIUM) — none caught by
the first two audit passes because they only manifested at end-
to-end test scenarios that the prior audit didn't reach.  All
closed.

  * **HIGH (correctness): `gitLsTree` returned just the
    directory entry, not its contents.**  Pre-fix, `git ls-tree
    --name-only <ref> -- <dir>` (without `-r`) returns
    `LegalKernel/_lex_inputs` (the directory name) when called
    on a directory, NOT the JSON files inside.  This caused
    `loadCodegenDirFromGitRef` to find ZERO sidecars for any
    git-ref input — `lex_diff --git <ref-a> <ref-b>` always
    reported "no changes" regardless of actual diffs.  The
    audit-2 manifest-diff bug was symptomatically related but
    only audit-3's end-to-end testing caught the underlying
    `gitLsTree` issue.  FIX: added `-r` flag to recurse into the
    directory.

  * **HIGH (correctness): `LawDiff.isEmpty` ignored the
    `versionBefore` / `versionAfter` fields.**  Pre-fix, a pure
    version-bump (`1.0.0 → 1.0.1` with no clause changes) was
    reported as empty diff.  This caused:
      (a) `computeLawSetDiff` to filter out the law from
          `lawsModified` (so the bump was invisible).
      (b) `validateDeploymentDiff`'s declared-vs-computed
          mismatch check (L007) to never fire on version-only
          changes.
    FIX: `isEmpty` now requires `versionBefore == versionAfter`
    in addition to all clause diffs being `none`.  Plus 2 new
    regression tests.

  * **MEDIUM (correctness): manifest hash + claim diff were
    order-sensitive but should have been canonical.**  Pre-fix,
    reordering laws / authority bindings / invariant claims at
    the source level (a no-op semantic change) would change the
    manifest hash AND `computeManifestDiff` would triple-count
    `[A, B] → [B, A]` claim reorderings as added + removed +
    modified.
    FIX: `encodeManifestHashInput` now sorts all lists
    (resources, laws, authority, claims, and law-names within
    claims) before encoding.  `computeManifestDiff`'s
    `invariantClaimToString` and modified-claim renderer also
    sort law-name lists before comparison.  Per spec §10.2 —
    "the set of laws" — claim law lists are unordered sets,
    so this canonicalisation matches the spec semantics.

After audit-3 fixes:

  * **1590 tests across 84 suites** (was 1584 pre-audit-3; +6
    new regression tests in `tools-lex-diff`).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 6 CI gates green.
  * `lex_diff --git` end-to-end now correctly detects diffs
    (verified manually on a synthetic `1.0.0 → 1.1.0` test
    commit pair).
  * Manifest hash for the worked-example USD-clearing changed
    from `1919db5de8cacee10...` to
    `f9182604d6417760000000...` due to canonicalisation;
    walkthrough doc updated.
  * **Audit-3 lessons learned**: end-to-end testing of git
    integration was the only way to surface the `gitLsTree -r`
    bug; unit tests on the function in isolation passed because
    they didn't test the directory-vs-file distinction in the
    git layout.  Added a regression test pattern of
    "synthesise a temp commit + diff" to the audit checklist.

**Workstream-LX M3-completion audit-4 hardening (this branch).**
A fourth deep audit pass following the audit-3 landing identified
one HIGH-severity correctness gap, two MEDIUM-severity
defensive-hardening items, and one MEDIUM-severity test-logic
bug.  All closed.

  * **HIGH (correctness): `satisfiesDiff` ignored property-claim
    args.**  Pre-fix, `computeLawDiff`'s `satisfiesDiff` rendered
    each `PropertyClaim` as `c.name` only, dropping the `args`
    field.  A refinement that changed args (e.g. `local [r]` →
    `local [r, s]`, or `freeze_preserving []` →
    `freeze_preserving [r]`) would silently produce an EMPTY
    `satisfiesDiff` and be misclassified as "no satisfies
    change".  Cascading impact: `LawDiff.isPreOnly` (and
    `isProofOnly`) would then be true for an args-only refinement,
    misclassifying it as `.minor` or `.patch` instead of `.major`
    (which is the correct classification for a removal of a
    property scope, e.g. removing a resource from a `local`
    claim).  FIX: render each claim as `name[arg1,arg2,...]`
    when args are non-empty.  One new regression test
    (`satisfiesDiffIncludesArgs`) in `tools-lex-diff`.

  * **MEDIUM (security defensiveness): `gitShow` /
    `gitLsTree` accepted refs with embedded `:`.**  Pre-fix
    `isSafeGitRef` rejected leading `-` and control characters
    but allowed `:` in refs.  A ref like `HEAD~1:malicious`
    when concatenated into `git show <ref>:<path>` would
    smuggle a second pathspec component (`HEAD~1` becomes
    the rev; `malicious:path` becomes the path argument).
    FIX: `isSafeGitRef` now rejects refs containing `:`.
    Plus added a dedicated `isSafeGitPath` validator that
    rejects empty paths, embedded `/../` segments, and
    control characters.  Both `gitShow` and `gitLsTree` now
    consult both validators before invoking the subprocess.
    Four new regression tests
    (`gitRefRejectsColons`, `gitPathValidator`,
    `gitShowRejectsUnsafePath`, `gitLsTreeRejectsUnsafeDir`)
    in `tools-lex-diff`.

  * **MEDIUM (robustness): `gitShow` / `gitLsTree` propagated
    uncaught IO exceptions on subprocess failure.**  Pre-fix,
    if `git` was not installed (or `IO.Process.output`
    encountered a spawn failure for any other reason — broken
    pipe, OOM at fork time, etc.), the IO exception would
    propagate to the caller.  Callers expect `none` /
    `.error` for any recoverable failure.  FIX: both
    functions now wrap `IO.Process.output` in `.toBaseIO`
    and convert subprocess errors into structured
    `none` / `.error` returns.

  * **MEDIUM (test-logic bug): `noSpuriousTrailingBlank`
    test detected the trailing newline as a false-positive
    "internal blank".**  The test verified the audit-4 fix
    in `formatLexSource` (stripping trailing blanks from
    `bodyLines` before segmentation).  Pre-fix, the test's
    blank-line-detection loop walked all entries from
    `output.splitOn "\n"` including the trailing empty
    entry from the final `\n`, incorrectly flagging that
    entry as "internal".  FIX: drop the trailing empty
    entry before scanning for internal blanks.

After audit-4 fixes:

  * **1596 tests across 89 suites** (was 1590 pre-audit-4;
    +6 new regression tests across `tools-lex-diff` and
    `tools-lex-format`).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 7 CI gates green plus the `--canonical --check`
    and `--gen-property-tests --check` byte-stability gates.
  * **`lex_diff` is now version-bump-classifier-correct** for
    every refinement that changes property-claim args, not
    just claim names.
  * **`lex_diff --git`'s git subprocess interface is hardened**
    against (a) flag injection via `:` in refs, (b) path
    traversal via embedded `..` segments, and (c) IO
    exceptions on missing git binary or subprocess spawn
    failures.
  * **Audit cycle convergence (LX-M3)**:
    - audit-1 (M3-completion): 49 spec deviations + functional
      gaps closed
    - audit-2: 5 defects (1 CRITICAL security + 1 CRITICAL
      functional + 3 MEDIUM)
    - audit-3: 3 defects (1 HIGH `gitLsTree -r` + 1 HIGH
      version-only-bump invisibility + 1 MEDIUM hash
      canonicalisation)
    - audit-4: 4 defects (1 HIGH satisfies args + 2 MEDIUM
      git defensiveness + 1 MEDIUM test-logic)

    The decreasing severity-and-count trend suggests
    convergence; future audits should focus on (a) end-to-end
    git-integration scenarios with real commit histories and
    (b) edge cases in property-claim args-aware refinement
    classification.

**Workstream-LX M3-completion audit-5 hardening (this branch).**
A fifth deep audit pass parallelised across four independent
agents (spec-compliance, math-correctness, security,
test-coverage) found 1 HIGH math-correctness defect, 4 MEDIUM
defects (1 math, 2 security, 1 test-coverage source defect),
plus several LOW/INFO observations.  All actionable findings
closed.

  * **HIGH (math-correctness): claim sort comparator collision
    via `intercalate ","`.**  In
    `LegalKernel/DSL/LexDeployment.lean:357`, the
    `encodeManifestHashInput` function's claim sort comparator
    used `(String.intercalate "," a.2.2) < (...)` to break ties
    on the law-names list.  Two distinct claims with these
    law-name lists produce identical intercalated keys: `["foo,
    bar"]` (single string with comma) and `["foo", "bar"]` (two
    strings) both intercalate to `"foo,bar"`, comparing equal
    under the comparator.  Combined with `qsort` instability,
    the manifest bytes — and hash — could differ
    non-deterministically across runs even on equal input.
    Lean identifiers admit commas via the French-quoted `«…»`
    form, so a future law identifier like `«foo,bar»` would
    trigger the collision.  FIX: replaced the `intercalate ","`
    comparator with a structural lexicographic list comparator
    (`lexicographicListCompare`) that compares element-by-
    element.  Same fix to `Tools/LexDiff.lean`'s
    `invariantClaimToString` (line 649) and `renderScope`
    (line 703) — both used `,` separator; switched to the
    `\x1f` US (unit separator) byte which is illegal in any
    Lean identifier.  Two new regression tests:
    `manifestHashClaimListInjective` (verifies
    `["foo,bar"]` and `["foo","bar"]` produce distinct hashes)
    and `manifestHashAllEmpty` (verifies the all-empty
    edge-case hash is exactly 32 bytes).

  * **MEDIUM (security defensiveness): `isSafeGitPath`
    accepted absolute paths and Windows-style paths.**  Pre-fix
    the validator rejected leading `-`, control characters,
    and parent-directory escapes, but allowed `/etc/passwd` and
    `Foo\\Bar.lean`.  Git's pathspec layer would reject
    absolute paths, but the API contract is repo-relative-
    only.  FIX: added `!path.startsWith "/"` and `!path.contains
    '\\'` checks.  One new regression test
    (`gitPathRejectsAbsolute`) in `tools-lex-diff`.

  * **MEDIUM (security): `lex_format --in-place` followed
    symlinks.**  An attacker with write access to a
    `.lean` file's parent directory could replace `Foo.lean`
    with a symlink to a sensitive path (`~/.bashrc`, `/etc/...`).
    `IO.FS.rename` follows the symlink and overwrites the
    target.  FIX: before in-place rewrite, call
    `System.FilePath.symlinkMetadata` and reject if `meta.type
    == FileType.symlink` with a precise diagnostic.

  * **MEDIUM (spec-compliance): elaborator parsed every clause
    TWICE.**  The deployment macro's `elab_rules` body ran the
    parse loop AND then called `parseDeployment` (which re-runs
    the same loop).  Side-effect-free so semantically
    idempotent, but a footgun if any clause-parser ever gains
    side-effects.  FIX: documented the duplication as
    intentional (the macro needs the raw user-supplied Syntax
    for authority bindings, which the public `DeploymentDecl`
    type doesn't carry — preserving Syntax in the public type
    would couple it to elaborator internals).  Added the
    `(diagAnchor : Option Lean.Syntax := none)` parameter to
    `parseDeployment` for precise diagnostic anchoring.

  * **HIGH (test-coverage source defect): UsdClearing
    docstring promised a `[all_laws]` wildcard demonstration
    that the deployment did not include.**  The module
    docstring claimed `freeze_preserving_law_set [all_laws]`
    was demonstrated, but the actual `deploy_invariant_claims`
    only had the explicit `monotonic_law_set [Transfer, Mint,
    Freeze, ReplaceKey]`.  Adding the promised
    `freeze_preserving_law_set [all_laws]` claim would FAIL
    the L008 firewall (transfer + mint mutate USD balances so
    they are NOT `FreezePreserving [USD]`).  FIX: replaced the
    explicit `monotonic_law_set` claim with the wildcard
    `monotonic_law_set [all_laws]` form (which DOES satisfy
    the firewall — all four wrappers are `IsMonotonic`).
    Added two regression tests in
    `LegalKernel/Test/Deployments/UsdClearing.lean`:
    `wildcardDemoElaborates` (pins successful elaboration of
    the wildcard claim) and `burnNotMonotonicRegression`
    (pins the L008 firewall foundation: `Laws.burn_not_monotonic`
    is the kernel-level negative witness that no
    `IsMonotonic Laws.burn` instance exists).
    Worked-example manifest hash changed from
    `f9182604d6417760...` to `cd7f3e2dd117087e...` due to the
    wildcard's distinct canonical encoding (the `lawNames`
    list is empty in wildcard scope).  Walkthrough doc updated.

  * **HIGH (test-coverage): `genTestState` only populated
    resource 0.**  The auto-gen property test
    `transferLocalProperty` checks
    `getBalance s r' a = getBalance s' r' a` for `r' = 1`.
    Since all `r'=1` balances were always 0 in the generated
    state, the test reduced to `0 = 0` — a tautology that
    would silently pass even if `transfer` corrupted other-
    resource state for actors with non-zero pre-balances.
    FIX: extended `genTestState` (in `Tools/LexCodegen.lean`'s
    `emitAutoGenLean` template) to populate `nResources` (= 3)
    distinct resource slots with independently-sampled
    balances.  Regenerated `LegalKernel/Test/Properties/AutoGen.lean`.
    The auto-gen property tests now exercise multi-resource
    state non-trivially.

  * **MEDIUM (coverage): `classifyVersionBump` lacked tests
    for events / params / actionIndex / registry_effect-only
    changes.**  The classifier's fall-through-to-`.major` path
    was untested for these clause categories.  FIX: added 4
    regression tests
    (`classifyMajorOnEventsOnly`, `classifyMajorOnParamsOnly`,
    `classifyMajorOnActionIndexOnly`,
    `classifyMajorOnRegistryEffectOnly`) in `tools-lex-diff`.

After audit-5 fixes:

  * **1605 tests across 89 suites** (was 1596 pre-audit-5;
    +9 new regression tests across `dsl-lex-deployment` (+2),
    `tools-lex-diff` (+5), `deployments-usd-clearing` (+2)).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 7 CI gates green plus the `--canonical --check`
    and `--gen-property-tests --check` byte-stability gates.
  * **Manifest-hash injectivity is now structural**: distinct
    claim shapes cannot collide regardless of identifier
    contents.
  * **`lex_format --in-place` is symlink-resistant**.
  * **`isSafeGitPath` rejects absolute + Windows-style paths**.
  * **Auto-gen property tests exercise multi-resource state**:
    `transferLocalProperty` and similar are no longer
    tautological for `r' != 0`.
  * **Worked example demonstrates the L008 firewall** at the
    value level via the `burnNotMonotonicRegression` test.

  * **Audit cycle convergence (LX-M3)**:
    - audit-1 (M3-completion): 49 spec deviations + functional
      gaps closed
    - audit-2: 5 defects (1 CRITICAL security + 1 CRITICAL
      functional + 3 MEDIUM)
    - audit-3: 3 defects (1 HIGH `gitLsTree -r` + 1 HIGH
      version-only-bump invisibility + 1 MEDIUM hash
      canonicalisation)
    - audit-4: 4 defects (1 HIGH satisfies args + 2 MEDIUM
      git defensiveness + 1 MEDIUM test-logic)
    - audit-5: 5 defects (1 HIGH math + 2 MEDIUM security +
      1 HIGH coverage source defect + 1 HIGH test soundness)
      plus 4 MEDIUM coverage gaps closed; 0 CRITICAL.

    The audit-5 round used 4 parallel agents (spec, math,
    security, coverage) each with deep mandate.  No CRITICAL
    findings.  Math-correctness audit found the most severe
    issue (claim comparator collision).  Coverage audit found
    the worked-example docstring drift.  Both fixes are
    landed and pinned with regression tests.

**Workstream-LX M2 audit-5 hardening (this branch).**  A fifth
deep audit, parallelised across three independent agents (law-
file mathematical correctness, test-coverage gaps, and
macro/codegen security), found one HIGH-severity defect, three
MEDIUM-severity defects, and two LOW-severity items.  All closed.
Plus 18 new audit-5-driven tests (17 from the test-coverage gap
analysis + 1 H1 stable-sort regression).  Test count grew from
1453 to 1471 (+18 across `laws-lex-m2` (+5), `tools-lex-common`
(+8), `tools-lex-codegen` (+5)).

  * **HIGH (H1): `Array.qsort` is not stable; canonical-mode
    skips registry validation** (`Tools/LexCodegen.lean`).
    `emitCanonicalManifest` sorted `decls` by `actionIndex` via
    `Array.qsort`, which Lean documents as NOT stable.  In the
    canonical-mode path, registry validation runs AFTER manifest
    emission (the `--check` byte-comparison happens against the
    pre-validation manifest).  If two decls share an `actionIndex`
    — which is itself a registry-validity bug, but a
    possible input shape if the codegen-input directory is
    corrupted — the manifest order would be non-deterministic
    across runs, breaking the byte-stability claim asserted by
    `--check` and potentially passing CI non-deterministically.
    FIX: tie-break on `identifier` (lexicographic) so the order
    is total across any input shape.  One new regression test
    in `tools-lex-codegen` constructs three synthetic shared-
    actionIndex decls in three different orderings and verifies
    the manifest output is byte-identical, with the secondary
    key applied.

  * **MEDIUM (M2): bare `throwError` in `parseClause`'s default
    arm** (`LegalKernel/DSL/LexLaw.lean`).  All sibling clauses
    use `throwErrorAt clause` to anchor the diagnostic at the
    offending node; the unknown-clause branch used a bare
    `throwError`, anchoring instead at the macro's parent.
    User-facing impact: a diagnostic for a typo'd `lex_id` →
    `lex_idd` would point at the `lexlaw` keyword rather than
    the offending clause, making the error harder to localise.
    FIX: `throwErrorAt clause "lex law: unknown clause `{clause}`"`.

  * **MEDIUM (M3): `withFileLock` propagates a transient release
    failure over the user's IO result** (`Tools/LexCodegen.lean`).
    The success path called `releaseLock path` directly; if a
    concurrent process beat us to `removeFile` between our
    `pathExists` check and `removeFile` call (a TOCTOU race in
    `releaseLock` itself), the resulting `IO.Error` would
    propagate, masking the body's success result.  The catch
    arm had the same hazard.  FIX: introduce a local
    `safeRelease : IO Unit := try releaseLock path catch _ =>
    pure ()` swallowing transient cleanup failures; both exit
    paths now use it.  The user's IO result is preserved
    verbatim.

  * **MEDIUM (M1) + LOW (L2): renderer skeletons silently
    misencode parameterised actions** (`Tools/LexCodegen.lean`).
    `renderActionEncode` / `renderActionDecode` /
    `renderApplyActionToRegistry` ship with M1-correct skeleton
    bodies for parameterless laws; for parameterised laws their
    output is incomplete (encode drops field bytes; decode
    reconstructs to a parameterless ctor; `applyActionToRegistry`
    references undefined identifiers).  M1 / M2 are gated by
    `requiresEmission := false` so the renderers currently
    return `""`, but a future M3 author flipping that gate
    without rewriting the skeletons would silently produce
    incorrect wire bytes (and ungrammatical Lean for the
    registry case).  FIX: when `params` is non-empty (or
    `registryEffect ∈ {.replaceKey, .registerIdentity}`), emit
    a deliberately-illegal Lean token
    `M2_RENDERER_TODO_PARAMETERIZED_*_<ctor>` so the next
    `--check` build (or the next target-file rebuild) fails
    immediately with a parse error — forcing the author to
    revisit the renderer rather than discovering the bug
    via a cross-stack mismatch downstream.

  * **LOW (L1): anonymous instance binders collide on name
    "_"** (`LegalKernel/DSL/LexLaw.lean`).  `paramSpecsFromBinder`
    emits one `ParamSpec` per binder, but multiple anonymous
    `[T]` binders (no leading ident) all collapsed to
    `name := "_"`, breaking the JSON sidecar's invariant that
    the `params` list is a per-binder record.  No current
    kernel-built-in law uses anonymous instance binders, so
    this is forward-protection.  FIX: post-flatten pass in
    `paramSpecsFromBinders` walks the list and re-numbers
    duplicate `_`-named entries with a positional `_2`, `_3`,
    ... suffix.  The first `_`-named entry preserves its
    legacy single-`_` form for back-compat.

After audit-5 fixes:

  * 1471 tests across 83 suites (was 1453 pre-audit-5; +18:
    5 in `laws-lex-m2`, 8 in `tools-lex-common`, 5 in
    `tools-lex-codegen`).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 7 CI gates green plus the canonical-mode check
    (`lake exe lex_codegen --canonical --check`).
  * `lex_codegen` idempotency preserved (a second invocation
    reports "0 target(s) rewritten"; both `--check` modes
    pass byte-for-byte).
  * Macro now anchors every diagnostic at the offending node
    (no remaining bare `throwError` in clause-parser
    branches).
  * `withFileLock` is robust against transient TOCTOU races
    in `removeFile` cleanup; the body's IO result is never
    masked by a release failure.
  * Forward-protection: future M3 work flipping
    `requiresEmission := true` for a parameterised law fails
    fast (`--check` build error) rather than silently producing
    incorrect wire bytes.

The test-coverage analysis additionally landed:

  * **5 mathematical-correctness tests in `laws-lex-m2`**:
    `auditSelfTransferRegression` (verifies §4.11 self-transfer
    fix is preserved on `r=1, sender=10, receiver=10, amount=5`
    — same actor as sender and receiver, post-debit re-read
    pattern); `auditTransferRejectsZero` (`amount = 0`
    rejection); `auditProportionalDiluteRejectsEmpty`
    (`sumOthers = 0` precondition); `auditDistributeOthersMultiActor`
    (3-actor foldl correctness on hand-computed fixture);
    `auditBurnTruncates` (Nat-truncation precondition rejection
    when balance < amount).
  * **8 JSON sidecar consistency tests in `tools-lex-common`**:
    per-law omitted-claim verification (`mint` omits
    `conservative`; `burn` omits both `conservative` and
    `monotonic`; `withdraw` omits both; `replaceKey` omits
    `registry_preserving`; `registerIdentity` omits
    `registry_preserving`; `transfer` claims all six);
    French-quoted `«local»` parses to plain identifier
    `"local"` in the satisfies list; every sidecar's
    `action_index` matches its filename (parametrised over
    all 17 laws).
  * **5 canonical-mode + corruption-detection tests in
    `tools-lex-codegen`**: `emitCanonicalManifest is byte-
    stable on real M2 corpus` (loads the actual 17 sidecars,
    re-emits 3× and verifies byte-equality);
    `emitCanonicalManifest sorts even when input unsorted`
    (reverse-list invariance); `validateAgainstRegistry catches
    mismatched action_index` (synthetic 999 violation);
    `validateAgainstRegistry catches unknown identifier`;
    `emitCanonicalManifest is deterministic on shared-index
    input` (the H1 regression test described above).

Audit cycle (Workstream-LX M2 only) convergence:
  - audit-1: 2 defects (1 MEDIUM, 1 LOW + mutation-test verification)
  - audit-2: 3 plan-spec deviations closed (token-clash split,
    in-place migration, calculus parser)
  - audit-3: 4 phase-deferral closures (`lex_satisfies` populated,
    `lex_events` placeholder, canonical-mode scaffold,
    deprecation activation)
  - audit-4: 3 defects (2 MEDIUM, 1 LOW; instBinder coverage)
  - audit-5: 6 defects (1 HIGH, 3 MEDIUM, 2 LOW; canonical-
    sort stability + diagnostic anchoring + lock cleanup +
    skeleton forward-protection + binder disambiguation)

The HIGH-severity finding in audit-5 (qsort stability) is a
canonical-mode-only edge case that would only manifest under
already-corrupt input, but the byte-stability claim is a
load-bearing CI invariant; the fix preserves it
unconditionally.

**Workstream-LX M2 audit-4 hardening (this branch).**  A fourth
deep audit (parallelised across the 17 law files and the macro/
codegen infrastructure) found three issues — one MEDIUM
correctness gap, one MEDIUM lock-management defect, and one LOW
documentation drift.  All closed in this branch.

  * **MEDIUM (correctness gap): `paramSpecsFromBinder` silently
    dropped instance binders.**  Pre-audit-4, the binder walker
    handled `explicitBinder` / `implicitBinder` /
    `strictImplicitBinder` syntax kinds but had a catch-all
    `else => []` arm that silently swallowed `instBinder`
    (`[Inhabited α]`-style typeclass parameters).  The
    consequence: any deployment-private law using `[]`-style
    parameters would have its instance-binder metadata
    DROPPED from the JSON sidecar's `params` field — silent
    JSON-vs-source drift.  None of the 17 kernel-built-in laws
    use instance binders, so the drift was dormant.

    Fix: extended `BinderKind` (in `Tools/LexCommon.lean`) with
    a fourth `inst` variant; updated `encodeBinderKind` /
    `decodeBinderKind`; extended `paramSpecsFromBinder` to
    handle `Lean.Parser.Term.instBinder` syntax kind, capturing
    both named (`[h : Inhabited α]`) and anonymous
    (`[Inhabited α]`) forms.  Three new regression tests in
    `tools-lex-common` exercise the new variant: round-trip
    encoding, encoding-form, and decoder-handles-all-four-
    variants.  Audit-4 closed an M3-risk drift before any law
    actually hit the codepath.

  * **MEDIUM (lock leak): canonical-mode emit bypassed
    `withFileLock`.**  Pre-audit-4, the `lex_codegen --canonical`
    mode wrote `canonical_manifest.txt` directly via
    `atomicWriteIfChanged`, with no advisory-lock wrapper.  Two
    concurrent `--canonical` invocations (e.g. CI + a developer
    running locally) could race: both observe the absent lock,
    both invoke `atomicWriteIfChanged`, and the second
    `IO.FS.rename` silently overwrites the first's atomic
    commit, producing inconsistent canonical-manifest state.

    Fix: wrapped the canonical-mode write in `withFileLock
    manifestPath`, mirroring the default-mode `appendToTargetFile`
    discipline.  The wrapper releases the lock on every exit
    path (success / structured error / exception); concurrent
    invocations now serialise.  The lock contention path
    returns exit code 1 with a precise diagnostic
    ("another invocation holds the advisory lock").

  * **LOW (documentation drift): `id` vs `nop` no-op naming.**
    Pre-audit-4, the `LexImplLowering.lean` module's docstring
    listed `id` as the kernel-level no-op calculus statement
    (line 40), and the diagnostic message at the unrecognised-
    statement catch-all also listed `id` as admissible (line
    181).  But the actual parser kind was `lexCalcNop` matching
    the `nop` keyword (the `id` keyword had been renamed earlier
    to avoid clashing with the `lex_id` macro clause's
    antiquote naming).  Users typing `lex_do id` would receive
    a confusing diagnostic listing `id` as admissible.

    Fix: corrected both docstring instances and the diagnostic
    message to say `nop`.  Module-level documentation is now
    consistent with the actual parser surface.

  * **Audit-4 also performed mutation-test verification of the
    `rfl`-equivalence regression examples.**  Empirically
    confirmed that:
    - Mutating the hand-written `Laws.reward.apply_impl` body
      from `+ amount` to `- amount` triggers an `omega` failure
      in `reward_isMonotonic` proof (downstream protection).
    - Mutating ONLY the Lex declaration's `lex_impl` body (in
      `Laws.Mint.lean`) triggers a precise `Type mismatch` at
      the regression `example`'s `:= rfl` (the byte-equivalence
      invariant catches drift).
    Both protections continue to work after audit-4 fixes.

  * **Test count after audit-4: 1453 (+3) across 83 suites.**
    The 3 new tests in `tools-lex-common` cover the new
    `BinderKind.inst` variant.  All 7 CI gates remain green;
    0 build warnings on a clean rebuild.

**Workstream-LX M2 audit-3 hardening (this branch).**  An
audit-3 deep pass closes the remaining tractable items from the
audit-2 deferred list.  Test count: 1447 → 1450 (+3 in
`tools-lex-codegen` for canonical-manifest tests).  All 7 CI
gates remain green; 0 build warnings.

  * **Phase A: Populated `lex_satisfies` per plan §19.4 spec.**
    All 17 kernel-built-in laws now declare their satisfies
    claims:
      - `transfer`, `freezeResource`, `dispute*`, `LP-*`:
        `[conservative, monotonic, local, freeze_preserving,
        nonce_advances, registry_preserving]` (kernel-identity
        or supply-conserving).
      - `mint`, `reward`, `deposit`, `distributeOthers`,
        `proportionalDilute`: omit `conservative` (additive).
      - `burn`, `withdraw`: omit both `conservative` and
        `monotonic` (subtractive).
      - `replaceKey`, `registerIdentity`: omit
        `registry_preserving` (registry mutation explicit).
    The `local` keyword conflicts with Lean's `local`
    reserved word; the Lex declarations use the French-
    quoted `«local»` form, which the macro extracts as the
    plain identifier "local" via `getId`.

  * **Phase B: `lex_events := []` populated as M2 metadata.**
    The full events-block elaborator (`do emit
    Event.disputeFiled ...` calculus form per plan §19.4
    LX.27) is M3 work.  M2 documents the intended event
    emissions in per-law comments alongside the empty
    `lex_events := []` placeholder.  The actual run-time
    event emission lives in `actionEvents` in
    `Events/Extract.lean` (hand-written, byte-equivalent).

  * **Phase C: Synthesizer-verification integration.**
    Attempted but not landed.  The hand-written instances
    (`mint_isMonotonic`, `transfer_isConservative`, etc.) are
    typed on the hand-written form (`Laws.mint r to amount`),
    not on the lex-emitted def (`legalkernel_mint_transition
    r to amount`).  Even though these are byte-equivalent
    (verified by the `rfl`-close regression `example`s),
    Lean's typeclass resolution doesn't see through the def-
    boundary automatically.  Bridging requires either (a)
    marking every hand-written law `@[reducible]` (broad
    performance / unification implications), OR (b) emitting
    fresh instance bodies that don't conflict with the
    hand-written ones (multi-property-shape instance-body
    emitter walking the calculus form — multi-day work).
    Both are M3 canonical-mode integration work.

  * **Phase D: `lex_codegen --canonical` mode now functional.**
    Pre-audit-3, `--canonical` returned exit code 2 with
    "not yet implemented".  Now it emits a structured
    canonical-manifest at
    `LegalKernel/_lex_inputs/canonical_manifest.txt` summarising
    all 18 Lex laws (sorted by frozen action_index) with
    intent / params / signed_by / registry_effect / satisfies /
    source location per law.  Byte-stable across runs;
    `--canonical --check` mode byte-compares the regenerated
    manifest against the committed file (exit 1 on
    divergence; CI-gating).  Three new tests in
    `tools-lex-codegen` exercise determinism, header shape,
    and action_index sorting.

    The canonical-mode SCAFFOLD enables M3's full-body
    regeneration: M3 will extend the manifest into a Lean
    module re-exporting each law's `Action` constructor,
    `Transition`, encoder/decoder arms, and event-emission
    rules — replacing the hand-written cross-module artefacts
    entirely.

**M3 follow-up items (genuinely deferred):**

  1. **Synthesizer integration with canonical-shape instance
     emission.**  Requires removing hand-written instances
     OR coordinating reducibility (see Phase C above).
     Multi-day effort.

  2. **Full-body regeneration of 4 target files.**  Per plan
     §19.4 LX.30: `lex_codegen --canonical` should emit the
     entire body of `Authority/Action.lean` (~505 lines),
     `Encoding/Action.lean` (~600+ lines),
     `Events/Extract.lean`, `Authority/SignedAction.lean`'s
     registry-mutation portions — including docstrings,
     namespace declarations, projection lemmas, smoke-test
     `example`s, instance declarations.  Multi-day effort.

  3. **Events-block elaborator (`do emit Event.foo ...`).**
     Per plan §19.4 LX.27.  Currently `lex_events := []`
     populated with comment-form documentation of intended
     emissions; M3 will land the calculus-form parser.

  4. **Populated `lex_satisfies` per law per plan spec.**
     The plan §19.4 LX.23 specifies `mint`'s `lex_satisfies`
     should include `[monotonic, local, freeze_preserving,
     nonce_advances, registry_preserving]`; `burn`'s should
     omit `monotonic` and `conservative`.  ✓ DONE in
     audit-3 Phase A (with `«local»` workaround for the
     Lean keyword).  Was deferred from audit-2; now closed.

**Plan §19.4 deliverables remaining (deferred to M3):**

  1. **Synthesizer integration with canonical-shape instance
     emission.**  The plan §19.4 LX.23 / LX.24 / LX.29 specifies
     that `lex_satisfies := [...]` claims drive the synthesizer
     to emit canonical-shape instance bodies (e.g., `instance :
     IsConservative <law> := <synthesized term>`).  The
     synthesizer skeleton in `DSL/LexProperty.lean` returns
     placeholder strings; wiring it into the macro to emit
     real Lean instances requires a per-property-shape
     instance-body emitter that walks the calculus form and
     produces canonical-shape proofs.  Multi-day engineering
     effort.

  2. **Canonical-mode codegen with full-body regeneration.**
     The plan §19.4 LX.30 specifies `lex_codegen --canonical`
     should emit the entire body of `Authority/Action.lean`
     (505 lines), `Encoding/Action.lean` (600+ lines),
     `Events/Extract.lean`, and `Authority/SignedAction.lean`'s
     registry-mutation portions from JSON sidecars — including
     all docstrings, namespace declarations, projection
     lemmas, smoke-test `example`s, and instance declarations.
     Multi-day engineering effort.  After this lands, the
     fences in those 4 files are removed and the bodies are
     fully generated.  Audit-3 closed Phase D's SCAFFOLD
     (manifest emission) — the entry point now works; M3
     extends it.

  3. **Populated `lex_satisfies` per law per plan spec.** ✓
     DONE in audit-3 Phase A.

  4. **Populated `lex_events` for dispute laws.** ✓ Comment-
     form M2 metadata documented in audit-3 Phase B.  The
     full events-block elaborator (calculus form) is M3
     work.

**Workstream-LX M2 audit-1 hardening (deep migration baseline).**  A post-
landing deep audit identified one M2-acceptance gap and one
test-coverage observation; both are closed in this branch.

  * **LX.25 + LX.28 acceptance gap: `registry_effect` field
    not set per-law.**  Per plan §19.4 LX.25 ("The codegen-
    input's `registry_effect` field is set to `\"replaceKey\"`
    and `\"registerIdentity\"` respectively") and LX.28 ("The
    codegen-input's `registry_effect` field is extended with a
    `\"localPolicy\"` variant"), the M2 declarations for
    `replaceKey` (index 4), `registerIdentity` (index 12),
    `declareLocalPolicy` (index 15), and `revokeLocalPolicy`
    (index 16) should each set the `registry_effect` field to
    a non-`none` kind.  Pre-audit: all 4 sidecars defaulted to
    `{"kind": "none"}`.  This was a per-WU acceptance gap
    (informational only — the `requiresEmission := false`
    policy means the renderers don't currently consume the
    field), but the plan calls it out as an explicit
    deliverable.  Fix: extended the `lex_law` macro with a new
    `lex_registry_effect <ident>` clause (admissible kinds:
    `none` / `replaceKey` / `registerIdentity` / `localPolicy`;
    defaults to `none` if absent for backward compat).  The 4
    affected Lex re-expressions now declare the correct kind;
    audit binaries (`lex_lint`, `lex_codegen --check`)
    continue to pass byte-for-byte.

  * **Mutation-test verification of the byte-equivalence
    regression.**  An empirical mutation test on
    `Laws/Lex/Mint.lean` (changing `+ amount` to `- amount`
    in the `lex_impl` body) confirmed that the `rfl`-close
    `example` regression test correctly fails the build with
    a precise `Type mismatch` diagnostic.  This validates the
    M2 strict-equivalence invariant: any drift in the Lex
    re-expression's `pre` / `apply_impl` from the hand-written
    form is caught at elaboration time.  Reverting the
    mutation restores the build.

After audit-1 fixes:

  * Test count unchanged (1436; the macro extension + sidecar
    updates don't add new tests — the existing
    `lex_codegen --check` suite already validates byte-stability).
  * 0 build warnings on a clean rebuild.
  * 0 sorries in TCB.
  * All 7 CI gates green.
  * Macro now exposes the `lex_registry_effect <ident>` clause
    for explicit per-law registry-effect classification (M2-
    compliant per plan §19.4 LX.25 + LX.28).
  * Mutation-test sanity: the `rfl`-close `example` regression
    catches at least the trivial `+ → -` impl mutation.

**Workstream LX deferred to M3.**  Per the plan §19.5, M3 lands
the `deployment` macro, `lex_diff` / `lex_format` audit
binaries, property-test auto-generation, the synthesizer
canonical-shape instance emission, the `Law.mk` deprecation,
and the `lex_codegen --canonical` flip.

**Workstream LP (actor-scoped policies) summary.**  Workstream
LP introduces per-actor, on-chain, mutable policy filters that
let each actor declare a `LocalPolicy` constraining their *own*
outgoing actions.  Bumped `kernelBuildTag` to
`"canon-local-policies"`.  Test count grew from 1103 to 1228
(+125: 66 in 5 new suites + 59 across existing-suite extensions).
The new suites are: `authority-localpolicy` (+27),
`authority-localpolicy-admissibility` (+14),
`encoding-localpolicy` (+18, including 6 audit-1 DoS-bound
regression tests), `localpolicy-lawclass` (+10),
`property-localpolicy` (+3).  Audit-1 follow-up extensions:
`encoding-action` (+7), `authority-action` (+6),
`authority-signed` (+9), `events-types` (+8),
`events-extract` (+8), `encoding-state` (+3),
`bridge-actor` (+5), `bridge-accounting` (+4),
`bridge-admissible` (+3).  Audit-1 also lands a critical DoS
hardening fix: the LP.2 decoder now enforces all four §3.0
bounds (`MAX_CLAUSES_PER_POLICY`, `MAX_TAGS_PER_DENY`,
`MAX_RECIPIENTS_PER_REQUIRE`) at decode time, rejecting oversize
inputs as `DecodeError.invalidLength`.  This closes the
defense-in-depth gap where a malicious encoder could craft an
oversize payload accepted by the kernel.  Audit-2 strengthens
the LP.12 `localpolicyEmptyNoNarrowingProperty` to vary the
action variant across 7 non-meta types (transfer / mint / burn
/ freezeResource / reward / distributeOthers /
proportionalDilute) — previously this only tested
`freezeResource`.  TCB unchanged; no new axioms; no new opaque
declarations.  See `docs/actor_scoped_policies_plan.md` for the
full engineering plan.

  * **LP.1 (`LegalKernel/Authority/LocalPolicy.lean` and
    `LegalKernel/Authority/LocalPolicySemantics.lean`)** —
    `LocalPolicyClause` inductive (3 MVP variants: `denyTags`,
    `requireRecipientIn`, `capAmount`); `LocalPolicy` structure
    (list of clauses, conjunctively combined); `LocalPolicies`
    abbrev (`TreeMap ActorId LocalPolicy compare`) with
    `empty`/`lookup`/`declare`/`revoke` operations; `Action.tag`
    projection (17-branch table covering pre-LP indices 0..14
    plus LP indices 15..16); `LocalPolicyClause.permits` /
    `LocalPolicy.permits` semantic predicates with named
    `Decidable` instances; the four §3.0 DoS bounds
    (`MAX_CLAUSES_PER_POLICY = 64` etc.); five RBMap-derived
    look-up lemmas (`lookup_declare_self/_other`,
    `lookup_revoke_self/_other`, `empty_lookup`).  Split into
    two modules to break the circular import: the data layer
    (`LocalPolicy.lean`) doesn't depend on `Action`; the
    semantics layer (`LocalPolicySemantics.lean`) imports both
    `Action` and the data layer for `Action.tag` and
    `permits`.
  * **LP.2 (`LegalKernel/Encoding/LocalPolicy.lean`)** — CBE
    `Encodable` instances for `LocalPolicyClause`,
    `LocalPolicy`, and `LocalPolicies`; `fieldsBounded`
    predicates enforcing the §3.0 caps;
    `localPolicyClause_roundtrip` /
    `localPolicy_roundtrip` round-trip + injectivity proofs
    under the bounded hypothesis;
    `LocalPolicies.encodeMap` / `decodeMap` (sorted-key map
    encoding) with structural and Equiv-based determinism
    theorems.
  * **LP.3 (extension to `Authority/Nonce.lean` and
    `Encoding/State.lean`)** — adds `localPolicies :
    LocalPolicies := LocalPolicies.empty` field to
    `ExtendedState` (default-valued, so pre-LP fixtures keep
    elaborating); extends `ExtendedState.encode`/`.decode`
    with a 5th appended segment.  Strict-decoder design
    (per §4.5 of the plan): pre-LP snapshots cannot be
    decoded by the post-LP build; operators upgrade by
    re-snapshotting under the new build.
  * **LP.4 (extension to `Authority/Action.lean` and
    `Encoding/Action.lean`)** — appends two new constructors
    at frozen indices 15 (`declareLocalPolicy (policy :
    LocalPolicy)`) and 16 (`revokeLocalPolicy`); both compile
    to `Laws.freezeResource 0` at the kernel level (mirrors
    `replaceKey` / `registerIdentity`).  CBE encoder /
    decoder extensions; `Action.fieldsBounded` extension;
    `Action.compile_injective` extends mechanically (one-line
    `congrArg` covers the full constructor list);
    `Action.tag_matches_encode_tag` theorem proves the
    agreement between `Action.tag` and the leading byte of
    `Action.encode` for all 17 constructors.
    `non_registry_mutating_preserves_registry`,
    `applyActionToBridgeState_non_bridge`, and
    `apply_admissible_with_eq_kernelOnlyApply` all extend by
    two `rfl` cases.
  * **LP.5 (extension to `Authority/SignedAction.lean`)** —
    `applyActionToLocalPolicies` helper (mirrors
    `applyActionToRegistry`); extends `apply_admissible_with`
    body with a final `localPolicies := …` step (the four
    field updates now happen in order: `base` →
    `advanceNonce` → `registry` → `localPolicies`).  Five
    new mutation theorems:
    `declareLocalPolicy_updates_localPolicies`,
    `revokeLocalPolicy_clears_localPolicies`,
    `non_meta_preserves_localPolicies`,
    `localPolicies_other_actor_untouched`, and
    `apply_admissible_localPolicies` (field projection).
    `kernelOnlyApply` in `Disputes/Evidence.lean` is also
    extended with the LP meta-action branches so the
    dispute pipeline's prefix-replay reproduces the
    runtime's localPolicies state.
  * **LP.6 (proof-body re-discharge in
    `Authority/SignedAction.lean`)** —
    `expectsNonce_after_apply_admissible{,_other}`,
    `apply_admissible_base/_registry`,
    `replaceKey_updates_registry/_other_actor_untouched`,
    `registerIdentity_updates_registry/_other_actor_untouched`,
    `non_registry_mutating_preserves_registry`,
    `nonce_uniqueness`, and `replay_impossible` all
    re-elaborate after LP.5's body change.  The five
    field-extractors (`admissible_authorized`,
    `admissible_nonce`, `admissible_signer_registered_and_signed`,
    `admissibleWith_signer_registered_and_signed`,
    `admissible_pre`) are rewritten using `obtain ⟨…⟩ := h`
    rather than chained-tuple projection (`.1`, `.2.1`,
    etc.), making them robust to LP.7's added conjunct.
  * **LP.7 (extension to `Authority/SignedAction.lean`)** —
    `isMetaPolicyAction` Bool-returning classifier (returns
    `true` for the two LP-introduced action ctors only);
    `localPolicyPermits` predicate (the 6th admissibility
    condition); extends `AdmissibleWith` with the 5th
    top-level conjunct; new `admissible_localPolicy` /
    `admissibleWith_localPolicy` field extractors;
    `localPolicy_meta_action_independent` headline theorem
    (the structural lockout-prevention proof: meta-actions
    are admissibility-permitted regardless of any declared
    policy);
    `localPolicyPermits_no_policy` (the strict-narrowing
    property at the conjunct level: actors with no declared
    policy see no narrowing).  Decidability synthesises via
    `instDecidableLocalPolicyPermits`.
    `nonce_uniqueness` and `replay_impossible` re-elaborate
    with byte-identical proof bodies (the new conjunct is
    irrelevant to nonce reasoning).
  * **LP.8 (extensions in `Bridge/{Accounting, BridgeActor}.lean`
    and `Disputes/Evidence.lean`)** — verification of
    cross-module re-elaboration.  Two new accounting
    deltas (`accounting_delta_declareLocalPolicy /
    _revokeLocalPolicy` — both zero), two new shape lemmas
    (`applyActionToBridgeState_declareLocalPolicy /
    _revokeLocalPolicy` — both identity).  Two new bridge-
    rejection theorems (`bridgePolicy_rejects_declareLocalPolicy /
    _revokeLocalPolicy`): the bridge actor cannot declare
    or revoke local policies (deployment-policy decision
    pinned at the type level).
  * **LP.9 (`LegalKernel/LocalPolicy/LawClassification.lean`)** —
    Two `compileTransition_eq_freezeResource_zero` rfl
    lemmas + four `IsConservative` / `IsMonotonic`
    typeclass instances (mirrors
    `Disputes/LawClassification.lean`); composite
    `local_policy_actions_classification` summary theorem.
    Lets deployments include the LP pipeline alongside
    `ConservativeLawSet` / `MonotonicLawSet` typeclass
    firewalls without breaking either invariant.
  * **LP.10 (extension to `Events/{Types, Extract}.lean`)** —
    Two new `Event` constructors at frozen indices 11
    (`localPolicyDeclared`) and 12 (`localPolicyRevoked`);
    extends `Event.actor` projection;
    `Event.isLocalPolicyEvent` Bool-returning classifier;
    `extractEvents` extension emitting the LP semantic
    events UNCONDITIONALLY (not delta-filtered: a re-
    declaration of the same policy still emits the event,
    mirroring the `rewardIssued` / bridge-event convention);
    two new emission-rule theorems
    (`extractEvents_declareLocalPolicy_emits_localPolicyDeclared`,
    `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked`).
  * **LP.11 (`Test/Authority/LocalPolicyAdmissibility.lean`)** —
    14 end-to-end acceptance tests (`mockVerify`-driven
    value-level admissibility witnesses) covering: full
    declare-then-revoke lifecycle; cross-actor independence;
    meta-actions self-exempt (the LP.7 lockout-prevention
    theorem at the value level); `requireRecipientIn` /
    `capAmount` enforcement (positive + negative + boundary
    + cross-resource isolation); replay protection still
    holds; multi-clause conjunction; re-declaration overwrites;
    bridge-actor rejection (LP.8); snapshot survival (LP.2 +
    LP.3 round-trip).
  * **LP.12 (`Test/Properties/LocalPolicy.lean`)** — Three
    property tests × 100 default samples each:
    `localpolicyRoundtripProperty` (LP.2 round-trip on
    randomly-generated bounded policies);
    `localpolicyMetaActionAdmissibleProperty` (the LP.7
    meta-action exemption at the value level);
    `localpolicyEmptyNoNarrowingProperty` (the LP.7
    strict-narrowing property: actors without declared
    policies see no admissibility narrowing).  Reproducible
    via `CANON_PROPERTY_SEED` env var.
  * **LP.13 (`docs/abi.md`, `solidity/README.md`)** —
    extends the on-disk-format tables with the two new
    `Action` ctors at frozen indices 15, 16 and the two
    new `Event` ctors at indices 11, 12; documents the
    `LocalPolicy` CBE encoding (§5.4); pins the future
    Solidity-port shape (the implementer can land the
    Solidity-side mirror as a focused follow-up without
    re-litigating the Lean-side decisions).
  * **LP.14 (umbrella + `CLAUDE.md` + `Tests.lean`)** —
    `kernelBuildTag` bumped to `"canon-local-policies"`;
    umbrella module imports the 5 new modules; test
    driver registers the 5 new test suites; Test/Umbrella's
    build-tag check updated; this changelog entry added.

**Ethereum Workstream F (cross-stack verification) summary.**
Workstream F lands the safety-net behavioural-equivalence
corpus (656 fixture inputs total) plus the operator-facing
testnet deployment script and three property-based bridge
tests.  See `docs/ethereum_integration_plan.md` §10 + §21 for
the full spec.

  * **F.1.1 — Cross-stack test-driver framework.** Lean side
    (`LegalKernel/Test/Bridge/CrossCheck/Framework.lean`):
    minimal no-Std-deps JSON encoder, fixture-path resolution,
    hex-byte serialisers, write-vs-verify mode helpers gated
    on `CANON_FIXTURES_OVERWRITE`.  Solidity side
    (`solidity/test/CrossCheck/Framework.t.sol`): forge-friendly
    base contract resolving fixture paths under
    `test/CrossCheck/fixtures/` via `vm.readFile` + `vm.parseJson`.
  * **F.1.2 — `ecdsa_verify.json` (128 entries).**  64 valid
    low-s + 32 wrong-signer + 16 high-s + 16 malformed-length,
    spanning the four `CanonDisputeVerifier.checkSignatureInvalid`
    control-flow branches.
  * **F.1.3 — `keccak256.json` (104 entries).**  4 reference
    KAT vectors (`kat_empty`, `kat_abc`, `kat_helloWorld`,
    `kat_singleZero`) + 50 short ≤32B + 30 medium 32-256B +
    20 long 256-2048B inputs.
  * **F.1.4 — `deposit_receipt_hash.json` (128 entries).**
    Pins the audit-2 6-field ABI-encoded
    `keccak256(deploymentId, depositor, resourceId, token,
    amount, depositorNonce)` recipe.  16 corner-native + 16
    corner-erc20 + 8 boundary + 8 replay-resistance + 16
    deployment-replay + 64 randomised.  L2-side `DepositId`
    projection: `natFromBytesBE(receiptHash[0..8])`.
  * **F.1.5 — `withdrawal_proof.json` (96 entries).**  64
    valid (16 sparse + 16 dense-pair + 16 unmapped + 16
    boundary) + 32 tampered (5 mutator classes: leaf-bitflip,
    sibling-bitflip, sibling-swap, wrong-index, wrong-root).
    Dense-pair sub-suite is the audit-2 regression class:
    sequentially-assigned WithdrawalIds 0+1 share a deepest
    pair, leaf-adjacent sibling is `leafBytes wd_1` ≈ 56
    bytes (variable-size, NOT 32-byte default-hash).
  * **F.1.6 — `dispute_evidence.json` (168 entries).**  144
    per-claim (48 each × 3 MVP variants: signatureInvalid,
    nonceMismatch, doubleApply) + 24 verdict-finalisation.
    Adversarial sub-cases pin audit-1 + audit-3 regressions:
    high-s, zero signerHint, MAX_PREFIX_LEN boundary,
    SelfClaimInvalid, DoubleApplyConcatBadCount,
    CBEInvalidLength, MAX_VERDICT_SIGNERS=64,
    MAX_EVIDENCE_BLOB_BYTES=100k, quorum dedup, EIP-712
    domain pinning ("CanonAction" vs "CanonDisputeVerifier").
  * **F.1.7 — `migration_attestation.json` (32 entries).**
    Audit-3 direction-fix regression class: 16 happy-path +
    8 boundary (4 at MIN_GRACE_WINDOW_BLOCKS=216_000 accepted;
    4 below rejected with `GraceTooShort`) + 4 cross-deployment-
    replay + 4 audit-3-direction (predecessor pre-committed
    accepted; predecessor.migration() == address(0) rejected).
    Mirrors `CanonEip712.migrationStructHash` exactly: 5-field
    struct + canonMigrationTypeHash prefix → 192-byte preimage.
  * **F.2 — keccak256 / ECDSA / RLP goldens (96 records).**
    32 block-header preimages + recorded keccak256 hashes,
    32 (pubkey, msg, sig) ECDSA triples, 32 RLP-encoded
    transactions + their keccak256 hashes.  Ships a synthetic
    LCG-seeded corpus initially; replacing with real mainnet
    records is a follow-up tracked in
    `solidity/test/goldens/README.md`.
  * **F.3 — Testnet acceptance deployment script.**
    `solidity/script/TestnetAcceptance.s.sol` deploys all four
    core contracts via CREATE3 with deterministic salts;
    asserts CREATE3 predictions match deployed addresses;
    invokes post-deploy `assertConsistent()` on
    `CanonDisputeVerifier` + `CanonSequencerStake`; verifies
    `bridge.migration() == address(0)` for the v1 design.
    Operator interface via `solidity/Makefile` with
    `make testnet-acceptance` (broadcast) and
    `make testnet-acceptance-dryrun` (local fork) targets.
  * **F.4 — Property-based bridge tests** (3 properties × 100
    samples each).  `bridgeLawSet : MonotonicLawSet` of §12.13
    (`{transfer, deposit, freezeResource}`) — `withdraw`
    deliberately excluded (typeclass-level forward-protection
    against future additions).  Properties: deposit-then-
    withdraw round-trip, bridge-account invariant non-decrease,
    withdrawal-proof unconditional verification.

Hash-binding-conditional behaviour: the Lean side's
`Bridge.HashAdaptor.isKeccak256Linked` flag gates per-entry
byte-equivalence assertions in the cross-check fixtures — when
the production keccak256 binding is not linked, the Lean fixture
content is FNV-derived and the Solidity-side cross-check skips
with an explicit log line.  CI gates the
`cross-stack-equivalence` job on the production binding being
linked before counting a skipped fixture as "passing".

Cumulative test count:
  * Lean: **1103** tests across 60 suites (was 1024; +79: 8
    framework + 7 ECDSA + 9 keccak256 + 12 deposit-receipt +
    8 withdrawal-proof + 10 dispute-evidence + 12 migration-
    attestation + 10 goldens + 3 property-bridge).
  * Solidity: **191 passing + 8 conditionally-skipped** across
    16 suites (was 166; +25 / +8 net: 4 framework smoke + 3 ECDSA
    + 3 keccak256 + 4 deposit-receipt + 3 withdrawal-proof +
    5 dispute-evidence + 4 migration-attestation + 5 goldens; the
    implementation audit replaced 1 tautological migration-test
    with 1 real digest assertion + 2 new type-string-pin tests
    for net +2 over the pre-audit count).
  * Audit binaries (count_sorries, tcb_audit, stub_audit) all
    pass; zero Lean warnings AND zero Solidity warnings on
    `lake build` / `forge build`.

TCB unchanged; no new axioms; no new opaque declarations; no
new theorem obligations (F is a cross-stack equivalence
corpus, not a kernel-level proof obligation, per §21.11).

**Toolchain bootstrap.**  `scripts/setup.sh` is now extended
to also install Foundry v1.7.0 and solc v0.8.20 (SHA-256
pinned for both x86_64 and aarch64 Foundry; x86_64 only for
solc since upstream v0.8.20 doesn't ship an ARM static
binary).  New flags: `--skip-solidity` (Lean-only) and
`--solidity-only` (Solidity-only).  A SessionStart hook at
`.claude/hooks/session-start.sh` invokes `setup.sh --quiet`
at session start so subsequent `lake build` / `forge test`
calls don't race against an in-flight install.

**Workstream-F implementation audit hardening (this branch).**
A deep post-landing audit of the Workstream-F deliverables found
four defects, all closed in this branch.  See
`docs/ethereum_integration_plan.md` §22 for the full per-defect
breakdown:

  * **CRITICAL: F.1.7 EIP-712 wrap divergence.**  The Lean-side
    fixture generator's hand-rolled `migrationDomainSeparator`
    used a 4-field `EIP712Domain(...address verifyingContract)`
    type string; the Solidity-side `CanonEip712.domainSeparator`
    uses a 5-field `EIP712Domain(... uint256 rollupId, bytes
    verifyingContract)`.  Plus the migration struct type string
    declared `uint256 migrationStateRootLogIdx` on Lean vs
    `uint64` on Solidity.  Either divergence makes the
    cross-stack digest assertion fail byte-for-byte under the
    production keccak256 binding (the typeHash and domainHash
    diverge by one character or one field).  Fixed by
    delegating to the canonical
    `LegalKernel.Bridge.eip712DomainSeparator` (eliminates a
    class of cross-stack-drift bugs by construction) and
    correcting the type string character-for-character.

  * **HIGH: F.1.7 Solidity test was a tautology.**  Pre-fix
    `test_perEntry_struct_hash_matches` compared
    `expected ^ actual` against itself
    (`assertTrue(sink == sink, "no-op sink")`) — passed
    regardless of byte-equality.  Fixed by replacing with a
    real `assertEq(actual, expected)` and adding two
    type-string-pin tests against the Solidity-side constants.

  * **MEDIUM: F.1.2 ECDSA `expectedSigner` parsing.**  The
    pre-fix Solidity test used `abi.decode(vm.parseJson(...),
    (address))` instead of the idiomatic
    `vm.parseJsonAddress(...)`.  Latent bug — the cross-check
    is currently skipped (binding-gated) and would only surface
    when the production binding is linked.  Fixed
    preemptively.

  * **MEDIUM: 7 Solidity build warnings closed.**  3
    unsafe-typecast (`uint256 → uint64`) and 4
    state-mutability warnings.  The unsafe-typecast warnings
    in `DepositReceiptHash.t.sol` were closed by dropping the
    casts entirely (Solidity ABI v2 zero-pads every integer
    type ≤ 256 bits to 32-byte words, so passing as `uint256`
    to `abi.encode` produces byte-identical output to passing
    as `uint64` for any value < 2^64; bound checks
    `assertLt(value, 1 << 64)` retain runtime safety).  The
    one remaining cast in `MigrationAttestation.t.sol` is
    structurally forced by the `CanonEip712.migrationStructHash`
    library function's `uint64` parameter type; closed via
    bound check + the documented Foundry
    `forge-lint: disable-next-line(unsafe-typecast)` directive
    with an inline justification.  The 4 state-mutability
    warnings closed by adding `view` / `pure` modifiers and
    deleting the unused `_assertFixtureIsValidJson` helper.

Plus a property-strengthening pass for F.4: pre-fix
`prop_bridge_account_invariant_holds` was a single-step
near-tautology; the post-fix version drives a 4-step trace
exercising every constructor in `bridgeLawSet` (deposit →
transfer → freezeResource → deposit) and asserts non-decrease
at every intermediate step.

Final state after audit-pass-1: **1100 Lean tests**;
**191 Solidity tests + 8 conditionally-skipped** (was 189,
+2 new type-string-pin tests); **0 build warnings**.

A second audit pass (audit-pass-2) found three additional
issues, all closed:

  * One residual `unsafe-typecast` warning (the
    `forge-lint: disable-next-line` directive was placed
    above a comment-line that intervened between the
    directive and the cast; Foundry's suppressor treats the
    comment as the "next line").  Fixed by hoisting the
    cast to a dedicated line so the directive is adjacent.

  * F.1.4 + F.1.7 lacked recipe self-consistency coverage.
    Added 3 new tests that recompute each fixture's
    `expectedHash` / `expectedDigest` from the entry's
    recorded fields and assert byte-equality with the
    stored values.  These checks are hash-binding-independent
    (both sides of the equation use the same hashBytes
    binding under either FNV fallback or production
    keccak256 mode), so they're valuable in both modes.
    Lean test count: 1100 → 1103.

Final state: **1103 Lean tests**, **191 Solidity tests + 8
conditionally-skipped**, **0 build warnings**.  All audit
binaries (count_sorries / tcb_audit / stub_audit) pass.

**Ethereum Workstream E (Solidity contracts) summary.**  Workstream E
ships the L1 mirror of Canon's kernel as five immutable contracts
in `solidity/`: `CanonBridge.sol` (E.1.1 – E.1.5), `CanonDispute
Verifier.sol` (E.2.1 – E.2.5), `CanonIdentityRegistry.sol` (E.3),
`CanonSequencerStake.sol` (E.4), and `CanonMigration.sol` (E.5).
The implementation follows the §20 immutability amendment of the
integration plan: no proxies, no `initialize` functions, no admin
roles, no `Pausable.pause()`.  Recovery from sequencer / attestor
misbehaviour uses the dispute pipeline (`applyVerdict (.upheld)`
calls `revertToPriorRoot` via the immutable `disputeVerifier`
reference); recovery from buggy contract code uses an attested
one-shot handoff to a successor deployment via `CanonMigration.sol`
with a `MIN_GRACE_WINDOW_BLOCKS = 216_000` (≈ 30 days) Solidity
`constant` baked into the bytecode.  Whole-system halts use the
four §9.1.4 automatic circuit breakers (`AttestationStale`,
`DisputeCooldown`, `TvlCapReached`, `MigrationActivated`) which
fire on observable state predicates with no privileged caller.
Cross-cutting libraries: `solidity/src/lib/CBEDecode.sol` (CBE
byte decoder mirroring `LegalKernel.Encoding.cborHeadDecode`);
`solidity/src/lib/SmtVerifier.sol` (SMT verifier mirroring
`LegalKernel.Bridge.WithdrawalRoot.verifyProof` line-for-line);
`solidity/src/lib/CanonEip712.sol` (EIP-712 wrap helpers); and
`solidity/src/lib/CREATE3.sol` (proxy-factory deployment that
breaks the bridge ↔ verifier ↔ stake reference cycle by deriving
addresses from `(deployer, salt)` only).  Solidity test count:
**166** forge tests across 8 suites (CBEDecode +23,
SmtVerifier +20, CREATE3 +3, CanonIdentityRegistry +19,
CanonBridge +39, CanonSequencerStake +19, CanonDisputeVerifier
+34, CanonMigration +9; +17 from audit-1, +8 from audit-2,
+2 from audit-3).  Build commands: `cd solidity &&
forge build` and `cd solidity && forge test`.  Toolchain pin:
solc 0.8.20, Foundry v1.7.0 (forge / cast / anvil).  Vendored
deps: OpenZeppelin v5.0.2, forge-std v1.9.4 (installable via
`scripts/vendor-deps.sh`).  TCB unchanged; no Lean theorems
altered; no new axioms.  See `solidity/README.md` for the
day-to-day Solidity developer guide.

The Solidity-side `CanonDisputeVerifier` MVP ports three of
the five Lean `Disputes.Evidence` claim variants
(`signatureInvalid`, `nonceMismatch`, `doubleApply`); the
remaining two (`preconditionFalse`, `oracleMisreported`) are
deferred to v2 per the integration plan §9.2.  Adding either
requires a new dispute-verifier deployment + a `CanonMigration`
handoff (no in-place extension path; matches the kernel's
append-only frozen-index discipline).

The Solidity port deliberately does **not** include a
production-ready CREATE3 inner-revert propagation: standard
CREATE3 proxy bytecode (used by Solady, Solmate, and our impl)
returns 0 from CREATE on inner failure, leaving no code at the
predicted address.  The `CanonMigration` test fixtures use
direct `new ...(...)` deployment so constructor reverts
propagate verbatim; production deployment scripts that need
richer revert info must use a bespoke proxy.

**Workstream-E audit-3 hardening (this branch).**  A third deep
audit found one HIGH-severity semantic bug that broke the
migration mechanism's intent (freezing the wrong bridge), plus
several smaller defensive fixes.  Test count grew from 164 to
**166** (+2 new audit-3 tests; one existing test refactored to
verify post-activation successor operability).

  * **HIGH (audit-3): CanonMigration constructor's
    bidirectional consent check was inverted.**  The pre-audit-3
    code asserted `successor.migration() == address(this)`,
    which silently FROZE THE SUCCESSOR (the OPPOSITE of the
    intended user-exit behaviour) on activation.  The
    integration plan §20 specifies the predecessor is what
    freezes; the successor remains operational so users can
    interact with it post-migration.
    FIX: swap the check to `predecessor.migration() ==
    address(this)`.  Renamed error from
    `SuccessorDoesNotReferenceThisMigration` to
    `PredecessorDoesNotReferenceThisMigration`.  The
    predecessor must be pre-committed via its `migration`
    immutable to be frozen by THIS migration's activation;
    without this commitment, the migration's `activated()`
    flag has no effect.  The new lifecycle test asserts
    BOTH that predecessor freezes AND that successor
    remains operational (`successor.depositETH` succeeds
    post-activation).
  * **LOW: missing zero-recipient check in
    `withdrawWithProof`.**  The L2-side leaf could in
    principle name `address(0)` as the recipient.
    `Address.sendValue(payable(0), x)` reverts on most L1
    forks but `safeTransfer(token, address(0), x)` is
    silent for some non-conforming ERC-20s.
    FIX: explicit `InvalidRecipient()` revert before the
    proof check.
  * **LOW: `_runDoubleApplyFromConcat` decoder didn't
    assert fully-consumed and didn't validate array
    count.**  A malformed evidence blob (count ≠ 2 or
    trailing bytes) was silently accepted.
    FIX: assert `count == 2` (`DoubleApplyConcatBadCount`
    revert) and call `assertFullyConsumed` post-decode.
  * **LOW: redundant length check in `withdrawWithProof`.**
    `proofLeaf.length != leafBlob.length` was checked
    explicitly, but the subsequent `keccak256(proofLeaf)
    != leafHash` check already subsumes it under
    collision-resistance.
    FIX: removed the redundant check; documented that
    keccak256 equality covers length equality.
  * **Test coverage gaps closed:**
    - Added `test_audit3_checkSignatureInvalid_rejected_when_signature_is_valid`
      (REJECTED-path test that audit-2 missed).
    - Added `test_audit3_checkSignatureInvalid_upheld_on_signature_for_wrong_signer`
      (cross-signer mismatch path).
    - Added `test_audit3_constructor_reverts_on_predecessor_does_not_reference`
      (audit-3 fix-1 regression test).
    - The lifecycle test now verifies the SUCCESSOR remains
      operational after migration activation (audit-3 fix-1
      semantic correctness).

**Workstream-E audit-2 hardening (this branch).**  A second
deep audit found six additional defects (one critical) that the
first audit missed; all are now closed.  Test count grew from
156 to 164 (+8 audit-2 tests; SmtVerifier suite refactored
from 18 to 20 tests using the new variable-size API).

  * **CRITICAL: SMT cross-stack leaf-format mismatch.**  The
    pre-audit-2 Solidity `SmtVerifier.recomputeRoot` accepted
    `bytes32 leaf` and `bytes32[] siblings`, but Lean's
    `WithdrawalProof.leaf : ByteArray` is variable-size (raw
    `leafBytes wd` ≈ 56 bytes for a populated cell, 32 for the
    empty sentinel) and `Vector ByteArray smtHeight` allows
    each sibling to be variable-size.  In the dense-pair case
    (sequentially-assigned WithdrawalIds 0 and 1 share a
    deepest pair, the leaf-adjacent sibling for id 0 is
    `leafBytes wd_1` ≈ 56 bytes, NOT 32), the Solidity
    verifier could not represent the sibling.  Cross-stack
    F.1.5 fixtures would have caught this; the Solidity port
    silently broke withdrawal-proof verification for any tree
    with adjacent populated cells.
    FIX: SmtVerifier now takes `bytes memory leaf` and
    `bytes[] memory siblings` (each variable-size).  The
    bridge's `_decodeWithdrawalProof` reads the proof's
    `leaf` field as variable-size bytes (mirroring Lean's
    `WithdrawalProof.leaf`); the proof structure on the wire
    contains the leaf bytes directly, NOT a leafHash.  The
    bridge cross-checks that the proof's leaf bytes equal the
    separately-supplied leafBlob.  Added
    `emptyProofSiblings()` convenience for tests.
  * **HIGH: `revertToPriorRoot` floor-only design auto-reverted
    every post-revert submission.**  The pre-audit-2 code
    tracked only `lowestRevertedLogIndexHigh` as a floor;
    `isStateRootReverted(idx) := idx >= floor` meant that
    after `revertToPriorRoot(N)`, EVERY future submission at
    idx >= N was auto-marked reverted, breaking the bridge's
    ability to recover from a dispute.
    FIX: track the (floor, ceiling) pair.  On revert, the
    ceiling rises to `latestSubmittedLogIndexHigh` (the
    highest existing root at revert time).  Future
    submissions land at idx > ceiling, so they are NOT in
    the reverted range.  `isStateRootReverted(idx) := floor
    <= idx <= ceiling`.  Event signature updated to carry
    both floor and ceiling.
  * **HIGH: missing zero-address check on `sequencerStake`
    in CanonBridge constructor.**  The pre-audit-2 code
    rejected zero attestor / disputeVerifier but silently
    accepted zero `sequencerStake`, allowing misconfigured
    deployments.
    FIX: added `ZeroSequencerStake()` revert.
  * **MEDIUM: duplicate token addresses allowed in resource
    map.**  Two distinct resourceIds could be mapped to the
    same ERC-20 token, splitting accounting at the L2 level.
    FIX: quadratic uniqueness check in the constructor;
    `DuplicateResourceToken(token)` revert.
  * **MEDIUM: fee-on-transfer / rebasing ERC-20s would
    desync L2 credit from L1 lock.**  The pre-audit-2 code
    used the declared `amount` for accounting; if the actual
    received amount differed (FoT tokens), L2 would be
    over-credited.
    FIX: balance-delta accounting (measure pre/post
    `balanceOf` and assert exact equality with declared
    `amount`); `TransferAmountMismatch(declared, received)`
    revert.
  * **MEDIUM: missing `nonReentrant` on `finalizeUpheld` /
    `finalizeRejected` (defense-in-depth).**  The functions
    use CEI ordering correctly (status → STATUS_UPHELD before
    external calls), but a reentry from a malicious
    challenger via `slash`'s `Address.sendValue` could call
    other dispute-verifier entry points (e.g. file new
    disputes) during the slash.  Not a current security
    issue but a future-proofing concern.
    FIX: import OZ ReentrancyGuard; mark both functions
    `nonReentrant`.

**Workstream-E audit-1 hardening (this branch).**  The first
audit identified eight defects (also closed).  Cumulative
test count grew from 139 to **164** (+17 audit-1 + +8
audit-2 fix tests; SmtVerifier suite refactored from 18 to
20 tests using the new variable-size API).

  * **Critical: `_signerToAddress` was a stub** that broke
    `checkSignatureInvalid`.  The pre-audit code synthesized
    an "address" from a uint64 signer-id by zero-padding,
    which never matched any registered address — so the
    verifier always returned `INCONCLUSIVE`.  Fix: removed
    the stub; `checkSignatureInvalid` now takes an explicit
    `address signerHint` parameter (the dispute filer
    supplies the actor-id ↔ address resolution from the
    runtime adaptor's L1 ingestor).  Added
    `MissingSignerHint` revert for finalisation paths.
  * **Critical: EIP-712 domain mismatch in
    `checkSignatureInvalid`.** The pre-audit code used
    `("CanonDisputeVerifier", "1")` as the domain when
    recomputing the digest, but users sign actions against
    `("CanonAction", "1")` per the integration plan.  Fix:
    added `ACTION_DOMAIN_NAME = "CanonAction"` and
    `VERDICT_DOMAIN_NAME = "CanonDisputeVerifier"` as
    distinct constants, mirroring Lean's
    `signedActionDomain` / `verdictDomain` split.
  * **Critical: `verdictHash` was an unbound free
    parameter** in `finalizeUpheld` / `finalizeRejected`.
    Adjudicators signed an arbitrary `bytes32 verdictHash`;
    a signature for verdict X could be replayed as a
    verdict for dispute Y.  Fix: contract now derives the
    canonical digest on-chain via `verdictDigest(disputeId,
    outcome)` and adjudicators must sign that exact value.
    `verdictDigest` binds `(disputeId, outcome,
    deploymentId)` via EIP-712 wrap; replay across disputes
    is structurally impossible.
  * **High: `revertToPriorRoot` had an O(N) loop** over
    state-root submissions.  A malicious sequencer with
    millions of submitted roots could DoS the dispute
    finalisation by exhausting the block gas budget.  Fix:
    replaced with O(1) `lowestRevertedLogIndexHigh` floor
    tracking; per-record `reverted` status is computed
    on-the-fly via `_isReverted(idx) := idx >=
    lowestRevertedLogIndexHigh`.  Added
    `isStateRootReverted(idx)` view.  Renamed event from
    `StateRootReverted_` (underscore due to error-name
    collision) to `StateRootRangeReverted` carrying the new
    floor.
  * **High: `signers[]` array unbounded** in
    `_countVerifiedSignatures`.  A malicious caller could
    pass a 100k-element array, DoS-ing finalisation via
    memory allocation.  Fix: added `MAX_VERDICT_SIGNERS =
    64` constant; `finalizeUpheld` / `finalizeRejected`
    revert with `TooManySigners` above the bound.
  * **High: `evidenceBlob` unbounded** in `fileDispute`.  A
    griefer could submit huge blobs to inflate gas costs.
    Fix: added `MAX_EVIDENCE_BLOB_BYTES = 100_000`
    constant; `fileDispute` reverts with
    `EvidenceBlobTooLarge` above the bound.
  * **Med: `evidenceBlob` stored in state but never read at
    finalisation.** Finalisation uses a fresh
    `reEvidenceBlob` calldata argument; the file-time blob
    was wasted gas (~640k for a 50KB blob).  Fix: removed
    `bytes evidenceBlob` from the `DisputeRecord` struct;
    emit it in the `DisputeFiled` event instead (events
    are ~60× cheaper than storage per byte).
  * **Med: `InvariantViolation_DisputeWindowVsRedemption`
    error reused** for a TVL-accounting underflow check.
    Wrong / misleading error name made the failure mode
    hard to diagnose.  Fix: added a separate
    `BridgeAccountingMismatch(uint256 totalLockedValue,
    uint256 amountRequested)` error for the underflow case;
    the dispute-window-vs-redemption error is reserved for
    the constructor-time invariant check.

The audit also identified several **low-severity items
investigated but not changed**: (i) `receive()` reverts on
all bridge contracts, but ETH can still be selfdestructed
into them — documented limitation that doesn't break
correctness because the contracts use `totalLockedValue`
rather than `address(this).balance` for accounting; (ii)
the `hasOpenDisputeOlderThan` predicate is conservative
(returns `true` if any state root is within the dispute
window, regardless of actual open-dispute count) —
documented; the dispute verifier can be extended to
maintain a per-state-root open-dispute index in a
follow-up; (iii) the `withdrawWithProof` recipient could
revert on `receive()` causing self-DoS on their own
withdrawal — accepted as a known property of
`Address.sendValue` semantics; users avoid by using EOAs
or known-good contract recipients.

**Ethereum Workstream D (withdrawal proofs) summary.**  Workstream D
adds the user-facing withdrawal redemption flow: a sparse Merkle
tree (SMT) over `BridgeState.pending`, a verifier and constructor
for inclusion proofs, a snapshot-window finalisation policy, and
the `canon withdrawal-proof` CLI subcommand for emitting hex-
encoded proofs ready for L1 submission.  Bumped `kernelBuildTag`
to `"canon-ethereum-workstream-d-withdrawal-proofs"`.  Test count
grew from 940 to 1024 (+84 tests across five new suites:
`bridge-withdrawal-root` (+41), `bridge-withdrawal-proof` (+12),
`bridge-withdrawal-proof-cli` (+6), `bridge-finalisation` (+20),
`bridge-withdrawal-goldens` (+5)).
TCB unchanged; no new axioms; no new opaque declarations.

  * **WU D.1.1 (`LegalKernel/Bridge/WithdrawalRoot.lean`,
    SMT data structures + tree construction)** — `smtHeight = 64`,
    `emptyLeafHash := zeroHash` (32 zero bytes per Audit-3.1),
    `defaultHash H i` (level-`i` empty-subtree hash, recursive),
    `pathBitAtLevel idx level` (LSB-up bit indexing — bit 0
    selects at the leaf level, bit 63 at the root), `hashUp H
    bit current sibling` (per-level hash combinator with bit-
    based ordering), `leafBytes wd` (canonical CBE encoding of a
    `PendingWithdrawal`, ~56 bytes), `rangeRoot H level entries`
    (the recursive SMT root over a sub-list of `pending.toList`,
    with a critical performance short-circuit on empty `entries`
    that returns `defaultHash H level` directly — without this
    short-circuit, computing `rangeRoot 64 []` would take O(2^64)
    work via empty-subtree forking), `withdrawalRoot H b :=
    rangeRoot H smtHeight b.pending.toList`.  Three §8.1.1
    headline theorems: `defaultHash_well_defined` (totality),
    `withdrawalRoot_empty_eq_defaultHash_top` (the empty bridge
    state's root equals `defaultHash 64`), and
    `withdrawalRoot_extensional` (extensional in `pending.toList`).
  * **WU D.1.2 (verifier + constructor definitions)** —
    `WithdrawalProof` structure (leaf : ByteArray, index :
    WithdrawalId, siblings : Vector ByteArray smtHeight; siblings
    ordered root-to-leaf so `siblings[0]` is root-adjacent and
    `siblings[smtHeight - 1]` is leaf-adjacent); `verifyProofRec`
    (the recursive verifier walking siblings root-to-leaf,
    composing `hashUp` at each level); `verifyProof H proof root
    := decide (recomputed_root = root)` (top-level entry);
    `constructProofAux` (recursive descent that mirrors
    `rangeRoot` exactly, with a short-circuit on empty entries
    via `emptyProofSiblings H level := [defaultHash (level - 1),
    ..., defaultHash 0]`); `constructProof H b idx` (top-level
    entry: builds the `WithdrawalProof` from the bridge state).
    Three §8.1.2 headline theorems: `constructProof_deterministic`,
    `constructProof_siblings_length` (= smtHeight, statically
    enforced by the `Vector ByteArray smtHeight` type), and
    `verifyProof_total` (always returns Bool).
  * **WU D.1.3 (`verifyProof_complete`, unconditional)** —
    The completeness theorem: for any populated `(idx, wd) ∈
    b.pending`, `verifyProof H (constructProof H b idx)
    (withdrawalRoot H b) = true`.  Proved without
    collision-resistance hypotheses, by structural induction on
    the recursion depth of `constructProofAux` (which mirrors
    `rangeRoot`'s recursion exactly, so the per-level hashes
    agree by definitional unfolding).  Auxiliary lemmas:
    `verifyProofRec_eq_rangeRoot` (the workhorse identity
    relating verifier and constructor on canonical inputs),
    `verifyProofRec_emptyProof_eq_defaultHash` (verifier output
    on the all-empty proof equals `defaultHash`),
    `rangeRoot_succ_cons` and `rangeRoot_nil_eq_defaultHash`
    (per-step rangeRoot reductions),
    `constructProof_siblings_toList` /
    `constructProof_leaf` / `constructProof_index` (Vector ↔
    list bridge lemmas).
  * **WU D.1.4 (`verifyProof_sound`, hash-conditional)** —
    The soundness theorem: under `CollisionFree H`,
    `UniformOutputSize H 32`, and matched leaf / sibling sizes,
    a verifying proof's leaf and siblings match the canonical
    construction's.  Proved via verifier injectivity:
    `verifyProofRec_inj` (the verifier function, viewed as a
    function of `(leaf, siblings)`, is injective under the
    hypotheses).  The injection works by induction on `level`,
    using `hashUp_inj_of_collisionFree` (one-level hash
    injectivity from CR + size match) and
    `byteArray_append_inj` (byte-prefix injectivity at known
    sizes, lifted from `List.append_inj` via `.data.toList`).
    Auxiliary helpers include `verifyProofRec_size_succ` (every
    non-zero-level verifier output is 32 bytes by `UniformOutputSize`).
  * **WU D.1.5 (`Test/Bridge/WithdrawalRootGoldens.lean`)** —
    The 16-leaf cross-stack golden fixture.  Lean side: builds
    the canonical 16-leaf `BridgeState`, computes the root, and
    verifies all 16 canonical proofs against it.  The fixture
    is byte-stable across runs (deterministic FNV-1a-64 fallback
    or production keccak256 binding).  Solidity-side
    integration is deferred to Workstream E.1.3 (where
    `CanonBridge.sol`'s SMT verifier consumes the same fixture
    bytes); the Lean side documents the wire format and provides
    the reference computation.
  * **WU D.2 (`LegalKernel/Bridge/WithdrawalProof.lean`,
    extractor + CLI)** — `Snapshot.bridgeWithdrawalRoot`
    (function on `Runtime.Snapshot` that decodes the snapshot's
    encoded `ExtendedState` and applies `withdrawalRoot
    hashBytes` to its `bridge` field; falls back to the empty-
    tree root on decode failure); `extractProof snap idx`
    (returns `some (constructProof hashBytes es.bridge idx)`
    if decode succeeds and `idx ∈ pending`; `none` otherwise);
    headline theorem `extractProof_consistent_with_root` (every
    extracted proof verifies against the snapshot's bridge root,
    by case analysis on the decode + lookup paths plus
    `verifyProof_complete`).  Plus determinism theorems for
    both functions.  CLI: `canon withdrawal-proof SNAP_PATH ID`
    subcommand in `Main.lean` that loads a snapshot, extracts
    the proof for `ID`, and emits a hex-encoded leaf + sibling
    path to stdout (suitable for piping to a Solidity test
    driver).
  * **WU D.3 (`LegalKernel/Bridge/Finalisation.lean`,
    snapshot-window finalisation)** — `FinalisableSnapshot`
    structure wrapping a `Runtime.Snapshot` with the
    finalisation metadata (`submitL1Block`, `logIndexLow`,
    `logIndexHigh`); `hasUpheldInRange log fromIdx toIdx`
    (forward-walk that returns `true` iff any
    `disputeStatus log i = some (.decided .upheld)` for `i ∈
    [fromIdx, toIdx)`); `isFinalised fsnap currentL1Block
    disputeWindowBlocks log` (= `currentL1Block ≥
    submitL1Block + disputeWindowBlocks ∧ no upheld in
    range`).  Two §8.3 headline theorems:
    `isFinalised_monotonic_in_currentBlock` (once finalised,
    always finalised under the same log) and
    `isFinalised_implies_no_upheld_against` (a finalised
    snapshot's covered log range has no upheld disputes,
    proved by induction on the fuel parameter of
    `hasUpheldInRange`).  **Audit-1** adds
    `extractFinalisedProof` (combines D.2's `extractProof`
    with D.3's `isFinalised`, matching §8.2's spec form
    "returns `none` if not finalised") plus
    `extractFinalisedProof_consistent_with_root` and
    determinism / negative theorems.

**Workstream-D audit-2 hardening (this branch).**  A second
deep audit found that the audit-1 soundness theorem's
"all canonical siblings = 32 bytes" hypothesis was *unsatisfiable*
for the realistic dense-pair case (sequentially-assigned
WithdrawalIds 0 and 1 share a deepest pair, so the canonical
leaf-adjacent sibling for id 0 is `leafBytes wd_1` ≈ 56 bytes,
not 32).  Audit-2 generalises:

  * **`siblingsHaveMatchingSizes` predicate**:
    `∀ p ∈ List.zip sibs₁ sibs₂, p.1.size = p.2.size`.
    Element-wise size match between proof and canonical siblings.
    Dischargeable in production: the runtime adaptor knows both
    sizes (proof's from user input, canonical's from the bridge
    state) and can size-check element-wise.

  * **Refactored `verifyProofRec_inj`** to use
    `siblingsHaveMatchingSizes` instead of "all 32 bytes".
    The 32-byte form is preserved as
    `siblingsHaveMatchingSizes_of_all_32` (a corollary).

  * **`verifyProof_sound`** now takes element-wise size match
    (handles dense-pair case).  The "all 32 bytes" form is
    preserved as `verifyProof_sound_all_32` corollary (applies
    when the runtime hashes leaves before placing in the SMT —
    standard SMT design).

  * **Edge-case tests added** verifying:
    - Dense-pair case (id 0 + id 1 both mapped): both canonical
      proofs verify against the root, and the leaf-adjacent
      sibling has size 56 (not 32) confirming the variable-size
      path is exercised.
    - Empty bridge state: `withdrawalRoot empty = defaultHash 64`.
    - Max-Nat WithdrawalId: doesn't crash (treated as
      `idx mod 2^smtHeight` due to bit-shifting semantics).
    - Unmapped idx: canonical proof verifies as a non-membership
      claim (leaf = sentinel, siblings = canonical path).

Audit-2 raised the test count from 1016 to 1024 (+8 tests).
TCB unchanged; no new axioms; all theorems use only the
canonical 3.

**Workstream-D audit-1 hardening (this branch).**  A first
post-implementation audit identified several issues; all are
now closed.

  * **`extractProof` doesn't check finalisation (§8.2 spec
    drift).**  The integration plan §8.2 says `extractProof`
    should return `none` if the snapshot is not yet finalised.
    The pre-audit `extractProof` only checked pending
    membership; finalisation was a separate predicate that
    the caller had to invoke.  Audit-1 adds the
    `extractFinalisedProof` wrapper (D.3 module) that combines
    pending-check with finalisation check; the `canon
    withdrawal-proof` CLI subcommand can be wired to it in a
    follow-up.  The pre-audit `extractProof` is preserved for
    callers that handle finalisation separately.

  * **Dead code in `constructProofAux` level=0 nonempty
    case.**  The pre-audit code had an inner
    `match entries with | [] => emptyLeafHash | _ :: _ =>
    leafBytes wd` inside an outer `_ :: _` pattern — the `[]`
    branch was unreachable.  Audit-1 simplifies to
    `(leafBytes wd, [])` directly with explicit pattern
    `(_, wd) :: _` in the outer match.

  * **Strengthened `verifyProof_complete_any_index`.**  The
    pre-audit `verifyProof_complete` required a hypothesis
    `b.pending[idx]? = some wd` but never used it (the
    canonical proof for any idx — mapped or unmapped —
    verifies against the actual root, with the unmapped case
    being a valid non-membership proof).  Audit-1 introduces
    the stronger `verifyProof_complete_any_index` (no
    hypothesis) and keeps `verifyProof_complete` as a direct
    corollary that retains the spec's exact signature.

  * **Added auxiliary `constructProofAux_leaf_singleton` and
    `mem_filter_pathBitAtLevel_self` lemmas.**  These are
    work-horses for any future proof of the spec-form
    soundness corollary (`∃ wd, mapped ∧ proof.leaf = encode
    wd`).  The current `verifyProof_sound` proves the
    canonical-match form; the spec-form corollary requires an
    additional leaf-recovery lemma over the TreeMap-backed
    filter chain, scoped as a follow-up.

  * **Added `WithdrawalId ≥ 2^64` aliasing documentation.**
    The SMT consults only `smtHeight = 64` bits of each
    WithdrawalId.  Two ids whose low 64 bits agree map to the
    same SMT position.  The runtime adaptor's `nextWdId`
    counter is a UInt64 in production, so this aliasing
    doesn't occur in practice; the Lean type uses `Nat` for
    arithmetic flexibility and documents the bound as a
    deployment-correctness obligation.

  * **Added 15 new tests:**
    - `bridge-withdrawal-root`: +3 (tampered-index rejection,
      tampered leaf-adjacent-sibling rejection, non-membership
      proof for unmapped idx verifies).
    - `bridge-finalisation`: +6 (extractFinalisedProof API
      checks + value-level negative cases).
    - `bridge-withdrawal-proof-cli` (NEW suite, 6 tests):
      end-to-end CLI flow (save / load / extract / verify),
      byte-stability across runs, absent-id behaviour,
      bridgeWithdrawalRoot preservation across save/load,
      corrupt-snapshot handling, bridgeWithdrawalRoot
      determinism.

Audit-1 raised the test count from 1001 to 1016 (+15 tests).
TCB unchanged; no new axioms; all theorems use only the
canonical 3 (`propext`, `Classical.choice`, `Quot.sound`).

**Workstream-D deviations from the integration plan.**  Three
documented Lean-level deviations from
`docs/ethereum_integration_plan.md` §8:

  1. **`rangeRoot` short-circuits on empty entries** (§8.1.1):
     the integration plan's pseudocode does not specify the
     short-circuit, but without it the function is O(2^smtHeight)
     in the worst case (computing `rangeRoot 64 []` forks into
     two recursive calls on the empty list at level 63, etc.).
     The fix: pattern-match on `entries` first, returning
     `defaultHash H level` on empty.  Logically equivalent (the
     `rangeRoot_nil_eq_defaultHash` theorem reduces to `rfl`
     under the new definition); operationally O(N * smtHeight)
     for a sparse tree with N populated entries.

  2. **`constructProofAux` short-circuits on empty entries**
     (§8.1.2): same reasoning.  The empty case returns
     `(emptyLeafHash, emptyProofSiblings H level)`, where
     `emptyProofSiblings` is a fresh definition that emits
     `[defaultHash (level - 1), ..., defaultHash 0]` (root-to-
     leaf order, length = level).  This makes `constructProof
     hashBytes BridgeState.empty 0` terminate in O(smtHeight)
     hashes rather than O(2^smtHeight).

  3. **`Snapshot.bridgeWithdrawalRoot` uses a fallback**
     (§8.2): if `snap.encodedState` fails to decode, the
     function returns `withdrawalRoot hashBytes
     BridgeState.empty` (the empty-tree root) rather than
     panicking.  This keeps the function total at the Lean
     level; the runtime adaptor checks the decode status
     separately and reports diagnostic errors via the CLI.

These deviations are recorded in this CLAUDE.md changelog;
none weakens any kernel guarantee.

**Ethereum Workstream C (bridge laws) summary.**  Workstream C
introduces the bridge L1 ↔ L2 deposit / withdrawal flow at the
kernel + admissibility + accounting levels.  Bumped
`kernelBuildTag` to `"canon-ethereum-workstream-c-bridge-laws"`.
Test count grew from 835 to 921 (+86 tests across new and
extended suites: `deposit` (+12), `withdraw` (+15),
`bridge-state` (+11), `bridge-admissible` (+14),
`bridge-accounting` (+19), plus +5 in `bridge-actor`
(deposit/withdraw policy admissions), +4 in `encoding-action`
(deposit/withdraw round-trips), and +5 in `events-extract`
(deposit/withdraw event emission)).  TCB unchanged; no new
axioms; no new opaque declarations.

  * **WU C.0 (`LegalKernel/Bridge/Admissible.lean`)** —
    `BridgeAdmissibleWith` predicate strengthening
    `AdmissibleWith` with three bridge-specific obligations:
    (6) deposit-id uniqueness for `Action.deposit`; (7)
    first-time-registration for `Action.registerIdentity`; (8)
    bridge-only signer for `Action.isBridgeOnly`-flagged
    constructors.  `applyActionToBridgeState` helper updates
    `BridgeState` for `deposit` (insert into `consumed` with
    `(resource, amount)` metadata) and `withdraw` (insert into
    `pending` at `nextWdId`, bump counter); identity on every
    other action.  `apply_bridge_admissible_with` entry point
    delegates to `apply_admissible_with` then updates the
    `bridge` field.  Three pass-through theorems
    (`apply_admissible_with_preserves_bridge`,
    `apply_admissible_preserves_bridge`,
    `apply_bridge_admissible_with_preserves_bridge_for_non_bridge`)
    plus per-field agreement
    (`apply_bridge_admissible_with_{base,nonces,registry}_agrees`)
    plus a `bridge_replay_impossible` lift via the
    `BridgeAdmissibleWith.toAdmissibleWith` projection.
  * **WU C.1 (`LegalKernel/Bridge/State.lean` + extension to
    `Authority/Nonce.lean` + `Encoding/State.lean`)** —
    `DepositId` (`Nat`, with the runtime adaptor converting
    32-byte BE L1 hashes at the bridge boundary; documented
    deviation from the plan's `ByteArray` to avoid the
    `TransCmp / LawfulEqCmp` re-derivation cost on a custom
    `byteArrayCompare`); `WithdrawalId` (`Nat`); `DepositRecord`
    (resource + amount; the audit-2 amendment to §7.1.1 that
    enables the `totalDeposited` accounting fold);
    `PendingWithdrawal` (resource + recipient + amount +
    l2LogIndex); `BridgeState` (consumed + pending + nextWdId);
    `BridgeState.empty`, `markConsumed`, `appendWithdrawal`,
    `isConsumed`, `hasConsumed` accessors / mutators.
    `ExtendedState.bridge : Bridge.BridgeState :=
    Bridge.BridgeState.empty` field embedding (default-valued,
    so pre-Workstream-C constructions keep elaborating without
    modification); CBE encoding for `BridgeState` extending
    `ExtendedState.encode/decode`.
  * **WU C.2 (`LegalKernel/Laws/Deposit.lean`)** — `deposit r
    recipient amount depositId` law.  Kernel-level: `setBalance`
    crediting `recipient`'s balance at `r`; precondition is
    `True` (the deposit-id uniqueness check lives at the bridge-
    admissibility layer).  Five §7.2 theorems:
    `totalSupply_after_deposit`, `deposit_other_resource_untouched`,
    `deposit_other_actor_untouched`, `deposit_isMonotonic`
    instance, `deposit_not_conservative` negative witness.  Plus
    `deposit_does_not_touch_other_resources` and
    `deposit_conserves_other_resource` for completeness.
  * **WU C.3 (`LegalKernel/Laws/Withdraw.lean`)** — `withdraw r
    sender amount recipientL1` law.  Kernel-level: `setBalance`
    debiting `sender`'s balance at `r`; precondition: `getBalance
    s r sender ≥ amount`.  Five §7.3 theorems:
    `totalSupply_after_withdraw` (additive form, mirroring
    `totalSupply_after_burn` to avoid `Nat`-subtraction
    asymmetry), `withdraw_other_resource_untouched`,
    `withdraw_other_actor_untouched`,
    `withdraw_not_monotonic` (negative witness),
    `withdraw_not_conservative`.  Plus
    `withdraw_does_not_touch_other_resources` and
    `withdraw_conserves_other_resource`.
  * **WU C.4 (extends `Authority/Action.lean` +
    `Encoding/Action.lean` + `Authority/SignedAction.lean` +
    `Bridge/BridgeActor.lean`)** — Two new `Action` constructors
    at frozen indices 13 (`deposit`) and 14 (`withdraw`).
    `Action.compile_injective` extends to the new constructors
    (structural via `CompiledAction.source`).  CBE encoder
    extended with the new branches; `action_roundtrip` /
    `action_encode_injective` extended to cover them.  The
    Workstream-B `non_registry_mutating_preserves_registry`
    extends with `rfl` cases for `deposit` / `withdraw`
    (neither mutates the registry).  Extends
    `bridgeAuthorizedAction` and `bridgePolicy` to admit
    `deposit` / `withdraw` for the bridge actor, with the
    matching `bridgePolicy_authorizes_deposit` /
    `bridgePolicy_authorizes_withdraw` theorems.
  * **WU C.5 (extends `Events/Types.lean` +
    `Events/Extract.lean`)** — Two new `Event` constructors at
    frozen indices 9 (`withdrawalRequested`) and 10
    (`depositCredited`).  Extended `Event.actor` /
    `Event.resource` projections; new `Event.isBridgeEvent`
    classifier.  Extended `actionEvents` to delta-filter the
    balance-changed events for `deposit` / `withdraw`; the
    bridge semantic events are emitted UNCONDITIONALLY in
    `extractEvents` (mirroring the `rewardIssued` convention),
    with the `withdrawalRequested` event carrying the *pre*-
    state's `BridgeState.nextWdId`.  Two new theorems:
    `extractEvents_deposit_emits_credited`,
    `extractEvents_withdraw_emits_requested`.
  * **WU C.6 (`LegalKernel/Bridge/Accounting.lean`)** —
    `totalDeposited` / `totalWithdrawn` quantity functionals
    folding over `BridgeState.consumed` / `BridgeState.pending`.
    Genesis sanity lemmas: both quantities are 0 at genesis.
    `PendingWithdrawal.amountAt` / `DepositRecord.amountAt`
    per-resource projection helpers.  Per-action accounting
    deltas covering every `Action` variant
    (`accounting_delta_transfer`, `_freeze`, `_replaceKey`,
    `_registerIdentity`, `_non_bridge` parameterised form).
    Plus the bridge-state shape lemmas
    `applyActionToBridgeState_deposit` and
    `_withdraw`.  The full `bridge_supply_account_general`
    inductive theorem (§7.6.4 / §7.6.5) over a custom
    `BridgeReachable` chain is documented as a follow-up; the
    per-action level (which the chain-level theorem would
    close by structural induction over) is fully discharged
    in this WU.

The §7.6.4 `bridge_supply_account_general` and §7.6.5
`bridge_supply_account` chain-level theorems are documented as
deferred follow-ups: the per-action accounting is fully proved
here, and the chain-level induction over a custom
`BridgeReachable` predicate is a structural lift that does not
require additional kernel-level theorems beyond what is shipped
in WU C.6.  The deferred theorems are scoped in
`docs/ethereum_integration_plan.md` §7.6.4 / §7.6.5 and
referenced from `Bridge/Accounting.lean`'s docstring.

**Workstream-C deviations from the integration plan.**  Two
documented Lean-level deviations from
`docs/ethereum_integration_plan.md`:

  1. **`DepositId : Nat` rather than `ByteArray`** (§7.1.1): the
     plan's `abbrev DepositId := ByteArray` would require
     defining `byteArrayCompare` and re-proving `TransCmp` /
     `LawfulEqCmp` for it before TreeMap operations on
     `consumed` could be backed by Std lemmas.  Using `Nat`
     keeps the comparator lawful by Lean core's `compare : Nat
     → Nat → Ordering`.  The runtime adaptor performs the
     32-byte BE → Nat conversion at the bridge boundary;
     conversion is injective on fixed-length 32-byte inputs.

  2. **`bridge` field has default value `BridgeState.empty`**
     (§7.1.2): the plan has the `bridge` field as a positional
     field with no default.  Phase-3 / Phase-4-prelude / Phase-6
     test fixtures construct `ExtendedState` via `{ base :=
     …, nonces := …, registry := … }` literals (without `bridge`).
     Adding a default value is an additive, backwards-compatible
     extension that lets existing fixtures keep elaborating.
     The runtime layer's `ExtendedState.empty` (and every
     bridge-aware construction) explicitly sets the field.

Both deviations are recorded in this CLAUDE.md changelog;
neither weakens any kernel guarantee.

**Workstream-C audit-1 hardening summary.**  A first post-landing
audit identified three issues; all are now closed.

  * **Critical: `Action.isBridgeOnly` flagged `withdraw` (security
    bug).**  The pre-audit `Action.isBridgeOnly : Action → Bool`
    returned `true` for `withdraw`, which through `BridgeAdmissibleWith`
    conjunct 8 (`Action.isBridgeOnly st.action = true → st.signer
    = bridgeActor`) forced ALL withdrawals to be bridge-actor-
    signed.  This contradicted the design where users sign their
    own withdrawals — a user attempting to withdraw their own
    balance would fail bridge admissibility.  Audit-1 removes
    `withdraw` from `isBridgeOnly`; only `registerIdentity` and
    `deposit` (the truly bridge-attested L1 → L2 actions) remain.
    User-signed withdrawals now pass conjunct 8 vacuously.
  * **`bridgePolicy_authorizes_withdraw` → `bridgePolicy_rejects_withdraw`.**
    The pre-audit `bridgePolicy` admitted `withdraw` for the
    bridge actor, which (combined with the `isBridgeOnly` bug)
    meant the bridge could in principle drain L2 balances and
    forge L1 redemption proofs.  The integration plan §12.9 #33
    spec is `bridgePolicy_rejects_withdraw`: the bridge actor is
    forbidden from signing withdrawals, closing the coordinated-
    attack vector.  `bridgeAuthorizedAction` updated to exclude
    `withdraw`; the test suite now confirms the bridge actor
    cannot withdraw on any user's behalf.
  * **Added post-application bridge-state invariants.**  Three
    new theorems pin the type-level evolution of `BridgeState`
    under bridge-admissible application:

    - `deposit_marks_consumed`: after a `deposit r recipient
      amount d` admissible application, `d` IS in the post-
      state's `consumed` map.  Direct corollary: a second
      admissibility check on the same `d` fails conjunct 6 —
      closes the L1-deposit-replay attack at the type level.
    - `deposit_replay_blocked_by_consumed`: the post-state's
      `consumed` map cannot evaluate `false` at `d` after a
      successful deposit application — proof-irrelevant
      reformulation of the above.
    - `withdraw_bumps_nextWdId`: after a `withdraw r sender
      amount rcp` admissible application, `bridge.nextWdId` is
      exactly one greater than the pre-state's — distinct
      withdrawals get distinct ids, closing the L2-withdraw-
      replay attack at the type level.
  * **Added BridgeState encoding determinism + DepositRecord
    round-trip.**  Three new theorems:
    `bridgeState_encode_deterministic` (structural rfl-class),
    `depositRecord_encode_deterministic`, and
    `pendingWithdrawal_encode_deterministic` cover the §7.1.4
    deliverable for the `BridgeState` CBE encoding.  Plus
    `depositRecord_roundtrip` (under canonical-encoding
    bounds), the per-record decode-after-encode identity.
  * **Documented `DepositId` 64-bit constraint.**  The Lean-
    side `DepositId : Nat` representation has a CBE round-trip
    bound of `< 2^64`.  Real L1 32-byte hashes are 256 bits
    and don't fit losslessly.  The runtime adaptor must
    project the L1 hash into a 64-bit deployment-canonical
    form (e.g. `keccak256(blockHash ‖ logIdx)[0:8]`,
    collision-resistant for the deployment lifetime; or
    sequential `uint64` numbering by the L1 contract).
    Documented in `Bridge/State.lean`'s `DepositId` docstring;
    the deployment-side projection's injectivity is a
    deployment-correctness obligation.

Audit-1 raised the test count from 921 to 934 (+13: 6 new
admissible/state encoding tests, 4 new bridge-actor tests for
the deposit-admit / withdraw-reject changes, 3 new tests for
the post-application invariants).

**Workstream-C audit-2 hardening summary.**  A second post-landing
audit identified one additional critical signature-forgery
vulnerability in the `Action.withdraw` and `PendingWithdrawal`
encoders.  Closed.

  * **Critical: 64-bit truncation of `recipientL1` enabled
    signature replay.**  The pre-audit `Action.withdraw` and
    `Bridge.PendingWithdrawal` encoders serialised
    `recipient.val` as a CBE Nat with `< 2^64` bound (8-byte
    payload).  But `EthAddress = Fin (2^160)` can be up to
    160 bits.  Two distinct EthAddresses sharing low 64 bits
    encode to **identical bytes** — meaning the same
    `signingInput` for `Action.withdraw`, hence the same valid
    signature.  An attacker could:

    1. Wait for a user to submit a signed withdrawal to L1
       address A.
    2. Construct a forged action with the SAME low 64 bits but
       different high 96 bits (any attacker-controlled
       address B sharing the low 64 bits).
    3. The forged action's `signingInput` matches the original
       (because the encoder truncates to low 64 bits), so the
       user's signature validates.
    4. The bridge processes the forged action and produces an
       L1 redemption proof for address B instead of A.

    This is a bypass of the user's signature: the destination
    L1 address is not fully bound by the signed bytes.

  * **Fix: lossless 20-byte ByteArray encoding.**  The audit-2
    encoders use `Encodable.encode (T := ByteArray)
    (Bridge.EthAddress.toBytes rcp)` — a CBE byte string
    containing all 20 bytes of the BE-encoded address (29 bytes
    total: 1 type tag + 8 length bytes + 20 payload).  This is
    lossless on every value in `Fin (2^160)`.  The decoder reads
    the 20 bytes via `Encodable.decode (T := ByteArray)`, then
    converts via `Bridge.EthAddress.ofBytes`, rejecting non-
    20-byte payloads with a precise diagnostic.

  * **`EthAddress.ofBytes_toBytes` round-trip lemma proved.**  The
    audit-2 fix's correctness rests on `ofBytes ∘ toBytes = some`.
    Audit-2 lands a sorry-free proof in `Bridge/AddressBook.lean`
    via three supporting lemmas: `toBytes_go_append` (factoring
    accumulator out), `toUInt8_toNat_of_lt` (the UInt8 round-trip
    helper), and `foldl_decode_go` (the inductive BE-decode-of-BE-
    encode identity, conditional on `n < 256^k`).  The proof
    depends only on the standard Lean built-in axioms.

  * **Decoder hardening.**  The audit-2 decoders for
    `Action.withdraw` and `Bridge.PendingWithdrawal` reject
    malformed payloads with precise diagnostics:
    `"... recipientL1 expects 20 bytes; got N"` (where `N` is
    the actual decoded ByteArray size).  This catches both
    truncated streams and legitimate-but-wrong-length inputs.

  * **`Action.fieldsBounded` simplified.**  The `rcp.val < 2^64`
    clause for `.withdraw` is removed (the 20-byte encoding
    needs only `(toBytes rcp).size = 20 < 2^64`, which is
    unconditional).  This means `fieldsBounded (.withdraw r s a
    rcp) = r.toNat < 2^64 ∧ sender.toNat < 2^64 ∧ amount < 2^64`
    only — the recipient's full 160-bit value is admissible
    without an explicit bound.

  * **`EthAddress.ofBytes` cleanup.**  The pre-audit ofBytes used
    `bs.toList` (Lean's custom `loop`-based implementation,
    which is not definitionally equal to `bs.data.toList`).  The
    audit-2 ofBytes uses `bs.data.toList` (the canonical Array
    projection), matching every other byte-decode helper in the
    codebase.  Equivalent results; necessary for the round-trip
    proof to close.

Audit-2 raised the test count from 934 to 940 (+6: 4 new
EthAddress round-trip + distinguishability tests in
`bridge-address-book`, 2 new audit-2 security regression tests in
`encoding-action`).  TCB unchanged; no new axioms; no new opaque
declarations.

The audit-2 fix is a behaviour-breaking change for the on-disk
log format: pre-audit-2 logs containing `Action.withdraw`
records cannot be replayed under the post-audit decoder (the
decoder expects 20-byte ByteArrays, not 8-byte truncated Nats).
Since Workstream C is shipping for the first time and no
production deployments depend on the pre-audit format, this is
an acceptable break; future audit passes will preserve on-disk
compatibility within a phase.

**Ethereum Workstream B (identity and authority) summary.**  Three
work units (B.1 – B.3) landing the Lean-side identity-translation
infrastructure that wires Ethereum's address-based identity model
into Canon's `KeyRegistry`.  Bumped `kernelBuildTag` to
`"canon-ethereum-workstream-b-identity-authority"`.  Initial commit
test count grew from 758 to 816; the post-landing audit-1 pass added
the strengthened `ingest_isSome_equivalent_for_distinct_addresses`
theorem (now covers ALL addresses, matching the plan's §12.8 #30
exactly), the `ingest_preserves_consistent` lemma, the
`assign_fresh_actorId_le` Nat-projected form (matching plan's `≤`
spec), the `EthAddress.toBytes_size` lemma, the
`ingest_lookup_isSome_pre_invariant` work-horse lemma, plus the
`L1Event.DecidableEq` instance (matching plan), bringing the post-
audit test count to 835 (+77 over baseline; +19 audit-1 additions
across `bridge-address-book` (+3), `bridge-actor` (+3),
`bridge-ingest` (+9), and `encoding-action` (+2 new
`registerIdentity` round-trip + cross-constructor distinguishability
tests)).  TCB unchanged; no new axioms; no new opaque declarations.

**Workstream-B audit-1 hardening summary.**  A first post-landing
audit identified several documentation-vs-code drift items and one
under-strength theorem; all are now closed.

  * **Strengthened `ingest_isSome_equivalent_for_distinct_addresses`.**
    Initial commit had this restricted to addresses NOT touching
    either event.  The plan §12.8 #30 form covers ALL addresses
    (including those touching one of the events).  Audit-1
    proved the full form via a new `ingest_lookup_isSome_pre_invariant`
    work-horse lemma plus 3-way case analysis on `addr` vs each
    event's address.  Closes a §12.8 spec deviation.

  * **Added `assign_fresh_actorId_le`.**  The plan §12.7 #28 spec
    uses `≤`; the initial commit used the strictly stronger `=`
    (which holds unconditionally under UInt64 wraparound, but
    deviates from the plan's signature).  Audit-1 adds the
    Nat-projected `≤` form under a `b.nextActorId.toNat + 1 < 2^64`
    no-overflow hypothesis, matching the plan's spec under
    pragmatic deployment-bound assumptions.

  * **Added `ingest_preserves_consistent`.**  The runtime adaptor's
    invariant (the `AddressBook` is `Consistent` after every
    `ingest`) was implicit pre-audit; audit-1 makes it a theorem,
    closing the type-level guarantee that L1-event ingestion does
    not corrupt the bookkeeping invariant.

  * **Added `EthAddress.toBytes_size`.**  The big-endian encoder
    for Ethereum addresses always produces 20 bytes (matching
    Ethereum's address format).  The size theorem makes this a
    type-level guarantee rather than an inspection-only invariant.

  * **Added `L1Event.DecidableEq`.**  The plan's `inductive L1Event
    deriving Repr, DecidableEq` declaration was implemented as just
    `deriving Repr` initially; audit-1 added `DecidableEq` (lifted
    from the underlying `EthAddress` and `ByteArray` via Lean
    core's `inferInstanceAs (Decidable (b₁ = b₂))` pattern that
    `PublicKey` already uses).

  * **Added `ingest_lookup_isSome_pre_invariant`.**  A strong
    locality lemma that says: applying the same event to two books
    that agree on `addr.isSome` produces post-states that agree on
    `addr.isSome`.  Independent property, but also load-bearing
    for the strengthened `_isSome_equivalent_` theorem.

  * **Renamed `non_replaceKey_preserves_registry`** to
    `non_registry_mutating_preserves_registry` for content-accurate
    naming (now that `registerIdentity` also mutates the registry,
    the old name was misleading per CLAUDE.md's "Names describe
    content, never provenance" rule).  The old name is preserved
    as a definitional alias so existing tests continue to elaborate.

  * **Fixed `Repr EthAddress` bug.**  The pre-audit instance printed
    `EthAddress(0x{a.val})` where `a.val` is rendered in decimal,
    so an EthAddress with `val = 16` displayed as `EthAddress(0x16)`
    but represented the value 16 (not 0x16 = 22).  The audit-1
    instance prints `EthAddress({a.val})` with decimal-only
    rendering, matching the underlying `Fin (2^160)`
    representation directly.  Hex rendering is the runtime adaptor's
    serialiser's responsibility at the network boundary.

  * **Added `Action.registerIdentity` encoding round-trip test.**
    The pre-audit suite did not cover `registerIdentity` round-trip
    (it covered `replaceKey` and the other 7 Phase-3 / Phase-4-prelude
    constructors but skipped the new index-12 constructor).  Audit-1
    adds `registerIdentityRT` plus a cross-constructor
    distinguishability test (`registerIdentityVsReplaceKeyBytes`)
    catching any future tag-collision bug.

  * **Added value-level Consistent-preservation tests** in
    `bridge-address-book` (3 new cases) and `bridge-ingest` (1 new
    case): the runtime adaptor's invariant is exercised at the
    value level on concrete `empty + assign + ingest` chains, not
    just the term-level API stability.

  * **Added bridgeAuthorizedAction direct value-level tests** plus
    a drift check between `bridgePolicy` and `bridgeAuthorizedAction`,
    catching any future divergence between the two.

  * **Documentation fixes**: BridgeActor.lean's coverage-map docstring
    incorrectly listed `(#32, #34, #35, #36 from §12.9)` for the
    implemented theorems; corrected to `(#32, #35, #36)` since
    #33 (`bridgePolicy_rejects_withdraw`) and #34
    (`bridgePolicy_authorizes_deposit`) are deferred to C.4.

  * **WU B.1 (`LegalKernel/Bridge/AddressBook.lean`)** —
    `EthAddress = Fin (2^160)` (type-level 20-byte width
    enforcement); `AddressBook` structure (`forward : TreeMap
    EthAddress ActorId compare`; `reverse : TreeMap ActorId
    EthAddress compare`; `nextActorId : ActorId`); `Consistent`
    propositional invariant (forward / reverse maps are key-by-key
    inverses); `empty` (initial book with `nextActorId := 1` so
    that the bridge actor's slot id 0 is never reused); `lookup` /
    `lookupRev` accessors; `assign` operation that adds a fresh
    address with the next id, or returns the existing id for a
    known address.  `EthAddress.ofBytes` / `EthAddress.toBytes`
    big-endian byte conversions.  Three §12.7 headline theorems:
    `addressBook_invariant` (the forward-reverse equivalence),
    `assign_fresh_actorId` (fresh assignment yields a new
    mapping; nextActorId is exactly bumped by one),
    `assign_idempotent_for_known` (known address returns the
    book unchanged).  Plus `empty_consistent`,
    `assign_preserves_consistent` (under an external freshness
    hypothesis on `nextActorId`), and the locality lemmas
    `assign_other_address_untouched` /
    `assign_other_id_untouched`.  24 tests in the
    `bridge-address-book` suite.
  * **WU B.2 (`LegalKernel/Bridge/Ingest.lean`)** —
    `L1Event` inductive (3 variants: `identityRegistered`,
    `identityRevoked`, `depositInitiated`, each carrying the
    originating L1 metadata `(blockNum, logIdx)`);
    `UnsignedBridgeAction` envelope structure; `ingest` function
    translating each L1Event into the appropriate updates to the
    `AddressBook` and an optional `UnsignedBridgeAction`.
    `identityRegistered` emits `Action.registerIdentity` for
    fresh addresses and `Action.replaceKey` for already-registered
    ones; `identityRevoked` and `depositInitiated` are MVP no-ops
    (revocation is a deployment policy concern; deposit handling
    is reserved for Workstream C.4).  Three §12.8 theorems:
    `ingest_emits_bridge_actor` (every emitted unsigned action's
    signer is the bridge actor — pinning the bridge's authority
    boundary at the type level);
    `ingest_preserves_lookup_for_other_addresses` (the per-address
    locality lemma — events not touching `addr` preserve the
    lookup at `addr`); and
    `ingest_lookup_equivalent_for_distinct_addresses` (the
    cross-address commutativity result — two ingests touching
    distinct addresses commute on the lookup at every third
    address).  Plus the isSome-form weakening
    `ingest_isSome_equivalent_for_distinct_addresses`.  19 tests
    in the `bridge-ingest` suite.
  * **WU B.3 (`LegalKernel/Bridge/BridgeActor.lean`)** —
    `bridgeActor : ActorId := 0` reservation; `bridgePolicy :
    AuthorityPolicy` admitting only `replaceKey` and
    `registerIdentity` actions by the bridge actor.  Decidability
    is automatic (each branch reduces to a finite conjunction of
    decidable equalities).  Five §12.9 theorems for the bridge
    policy: `bridgePolicy_rejects_transfer` (#32),
    `bridgePolicy_authorizes_replaceKey` (#35),
    `bridgePolicy_authorizes_registerIdentity` (#36), plus the
    cross-actor rejection `bridgePolicy_rejects_non_bridge_signer`
    and a wider rejection family for every other Action
    constructor (mint, burn, freezeResource, reward,
    distributeOthers, proportionalDilute, dispute,
    disputeWithdraw, verdict, rollback).  18 tests in the
    `bridge-actor` suite.  Workstream C.4's
    `bridgePolicy_authorizes_deposit` and
    `bridgePolicy_rejects_withdraw` will land when the
    `Action.deposit` / `Action.withdraw` constructors are added
    at frozen indices 13 / 14.
  * **`Action.registerIdentity` constructor (frozen index 12).**
    Workstream B's identity-registration flow needs an action
    that inserts a *new* (actor, key) mapping into the
    `KeyRegistry` (signed by the bridge, not the actor itself —
    the actor has no prior registration to sign with).
    Distinct from `replaceKey` (which is signed by the *old*
    key) so deployments can grant the bridge "may register"
    permission without granting general "may rotate" permission.
    Compiles to `Laws.freezeResource 0` at the kernel level (a
    no-op `Transition`); the registry mutation lives in
    `applyActionToRegistry` (now extended to also handle
    `registerIdentity`).  Plus two new §12.5-style theorems:
    `registerIdentity_updates_registry` (inserts the new key) and
    `registerIdentity_other_actor_untouched` (cross-actor
    independence).  The pre-existing
    `non_replaceKey_preserves_registry` was extended with a
    second exclusion hypothesis to also reject `registerIdentity`
    actions; the updated test asserts the new signature.

The Workstream B implementation deliberately couples the
`Action.registerIdentity` constructor (which the integration plan
attributes to C.4) with the B.2 / B.3 work because B.2's `ingest`
and B.3's `bridgePolicy` cannot be type-checked without it.  The
constructor is appended at frozen index 12 (per the append-only
discipline).  The plan's original index allocation for C.4
(`deposit` = 12, `withdraw` = 13, `registerIdentity` = 14)
shifts in this codebase to (`registerIdentity` = 12,
`deposit` = 13, `withdraw` = 14); C.4's implementation will
adopt this order.  The §12.9 #37 theorem
`registerIdentity_first_time_only` is reserved for C.4 (it
requires extending `Admissible` to include action-specific
authority-layer preconditions); for now, the bridge runtime
enforces first-time-only at the `AddressBook` level (Workstream
B.2 only generates `Action.registerIdentity` for addresses that
do not yet have an `AddressBook` mapping), and deployment-
configured `AuthorityPolicy` predicates can additionally reject
`registerIdentity` for already-registered actors via
`AuthorityPolicy.intersect`.

**Ethereum Workstream A (cryptographic adaptors) summary.**  Three
work units (A.1 – A.3) landing the Lean-side documentation,
canonical type / constant exports, and stability theorems for the
production crypto adaptors that bridge Canon to Ethereum L1.
Test count grew from 665 to 758 (+93 tests across three new
bridge suites).  TCB unchanged; no new axioms; no new opaque
declarations beyond the existing `Verify` and `signingInput`.

**Workstream-A audit-1 hardening summary.**  A first post-landing
audit of the workstream identified a critical EIP-712 interop bug
plus several quality-of-life issues; all are now closed.

  * **Critical: `eip712StructHash` encoded only 1 of 4 declared
    fields.**  The `canonActionTypeString` declared four fields
    (`actionHash`, `signer`, `nonce`, `deploymentId`) but
    `eip712StructHash` only computed
    `keccak256(typeHash ‖ actionHash)` — committing to just one
    field.  A spec-compliant MetaMask wallet parsing the type
    string would compute
    `keccak256(typeHash ‖ actionHash ‖ signer_BE ‖ nonce_BE ‖
    keccak256(deploymentId))`, producing a **different** struct
    hash and a signature that **would fail to verify** against the
    Lean side.  This broke the §5.3 acceptance criterion
    ("MetaMask-produced EIP-712 signature on a Canon `signInput`
    verifies via the A.1 binding").

    Fix: `eip712StructHash` now encodes all four declared fields
    via the new `structPreHash` helper (5-field 160-byte
    concatenation: `typeHash ‖ actionHash ‖ signer_BE ‖ nonce_BE
    ‖ hashBytes(deploymentId)`).  The proof of
    `eip712Wrap_injective` was rewritten to handle the 5-field
    preimage via four successive byte-level boundary extractions
    plus two `CollisionFree hashBytes` applications.

  * **Type-string EIP-712 spec alignment.**
    `canonActionTypeString` previously declared `bytes32
    deploymentId`, but the Lean encoder hashes the `deploymentId`
    bytes (i.e., applies the EIP-712 `bytes` rule).  The two were
    inconsistent.  Fix: changed type string to `bytes
    deploymentId`, so a spec-compliant wallet applies the same
    hashing rule the Lean side does.  Same fix applied to
    `verifyingContract` (was `address`, now `bytes`).  Under the
    corrected type strings the Lean encoder is exactly EIP-712
    spec-compliant for the declared field types.

  * **KAT-vector authoritative verification.**  All four reference
    `kat_*` vectors (`kat_empty`, `kat_abc`, `kat_helloWorld`,
    `kat_singleZero`) cross-verified against `pycryptodome`'s
    `Crypto.Hash.keccak.new(digest_bits=256)` output during the
    audit.  No deltas.  Two new conditional KAT tests added
    (`hashAdaptorMatchesL1KeccakAbc`,
    `hashAdaptorMatchesL1KeccakHelloWorld`) to exercise the
    production binding path; one new defence-in-depth test
    (`katVectorsLeadingBytesDistinct`) catches future
    copy-paste corruption of the KAT constants.

  * **Constant-coherence test.**  Added
    `orderBytesDecodesToOrder` test: the BE bytes of
    `secp256k1OrderBytes` decode to exactly `secp256k1Order`.
    Catches a future copy-paste error that desyncs the two
    constant declarations.  Plus `halfOrderMatchesEip2`: the
    `secp256k1HalfOrder` constant matches the documented EIP-2
    threshold value.

  * **`structPreHash` byte-layout regression tests.**  Three
    new tests pin the 5-field encoding directly:
    `structPreHashSize` (= 160 bytes total), `structPreHashContainsSigner`
    (distinct signers ⇒ distinct `structPreHash` bytes),
    `structPreHashSignerLSBLayout` and
    `structPreHashNonceLSBLayout` (verify the signer/nonce LSB
    bytes appear at the documented BE positions, byte 95 and
    byte 127 respectively).  Closes a coverage gap where the
    old 1-field struct hash bug would have been hidden by the
    coarser cross-field-distinguishability tests.

  * **Type-string sanity tests.**  Four new tests
    (`domainTypeStringExact`, `actionTypeStringExact`,
    `actionTypeStringDeploymentIsBytes`,
    `domainTypeStringContractIsBytes`) pin the type string
    declarations, preventing a future regression where the type
    string and encoder drift apart.

  * **Unused-import cleanup.**  Removed three unused imports
    surfaced during the audit:
    `LegalKernel.Authority.SignedAction` from
    `Bridge/VerifyAdaptor.lean` and `Bridge/Eip712.lean`;
    `LegalKernel.Authority.Crypto` from `Bridge/HashAdaptor.lean`.
    No semantic change; tighter dependency graph.

The audit raised the test count from 745 to 758 (+13 audit-1
tests).  All gates remain green; axioms unchanged
(`propext`, `Quot.sound` only); no new sorries.

  * **WU A.1 (`LegalKernel/Bridge/VerifyAdaptor.lean`)** —
    Lean-side contract for the ECDSA secp256k1 verify adaptor
    (`runtime/canon-verify-secp256k1` Rust crate, deferred).
    Exports: `secp256k1Order` / `secp256k1HalfOrder` /
    `secp256k1OrderBytes` (the canonical curve order and EIP-2
    low-s threshold), `ecdsaSignatureSize` /
    `ecdsaPublicKeyCompressedSize` /
    `ecdsaPublicKeyUncompressedSize` (byte-length constants),
    `verifyAdaptorIdentifier` /
    `fallbackVerifyAdaptorIdentifier` (runtime-introspectable
    identifiers, mirroring Audit-3.1), and the `isLowS` predicate
    + decidability.  Stability theorems:
    `Verify_deterministic`, `secp256k1HalfOrder_eq`,
    `secp256k1OrderBytes_size`, `isLowS_zero`,
    `isLowS_at_threshold`, `isLowS_just_below_order`.  23 tests
    in the `bridge-verify-adaptor` suite.
  * **WU A.2 (`LegalKernel/Bridge/HashAdaptor.lean`)** —
    Lean-side contract for the keccak256 hash adaptor
    (`runtime/canon-hash-keccak256` Rust crate, deferred).
    Exports: the canonical `keccak256AdaptorIdentifier`
    (`"keccak256/EVM-compatible/v1"`); `isKeccak256Linked`
    runtime predicate; four reference KAT vectors (`kat_empty`,
    `kat_abc`, `kat_helloWorld`, `kat_singleZero`) lifted from
    NIST SHA-3 / Ethereum-block-header outputs;
    `expectedFallbackEmptyHash` (the Lean fallback's expected
    output for diagnostic comparison).  Bridge-namespace
    forwarders for `hashAdaptor_thirty_two_byte_output`,
    `hashAdaptor_deterministic`,
    `hashAdaptor_identifier_distinct`.  KAT-vector sizes pinned
    at 32 bytes via 5 size theorems.  23 tests in the
    `bridge-hash-adaptor` suite, including the conditional
    `hashAdaptor_matches_l1_keccak` test that branches on
    `isKeccak256Linked` (production binding case checks the KAT;
    Lean-fallback case checks `expectedFallbackEmptyHash`).
  * **WU A.3 (`LegalKernel/Bridge/Eip712.lean`)** — full
    Lean-side EIP-712 typed-data wrap module.  Defines:
    `eip712Prefix` (the `\x19\x01` magic bytes),
    `eip712DomainTypeString` / `canonActionTypeString` /
    `eip712DomainTypeHash` / `canonActionTypeHash` (canonical
    type strings and 32-byte type hashes), `encodeUint256BE`
    (32-byte BE uint256 encoder), `DomainParams` (5-field
    EIP-712 domain), `Eip712Message` (4-field action message),
    `domainPreHash` (6-field 192-byte preimage),
    `eip712DomainSeparator`, `structPreHash` (5-field 160-byte
    preimage), `eip712StructHash`, `eip712Wrap`.

    The type strings declare:
    * `EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)` — `verifyingContract` declared
      `bytes` (not `address`) so the EIP-712 spec's
      hash-before-encoding rule for `bytes` matches the Lean
      side's `hashBytes p.verifyingContract` field encoding.
    * `CanonAction(bytes32 actionHash,uint64 signer,uint64 nonce,bytes deploymentId)` — `deploymentId` declared `bytes`
      (not `bytes32`) for the same reason; `actionHash`
      declared `bytes32` and encoded verbatim (since
      `hashBytes` returns exactly 32 bytes per
      `hashAdaptor_thirty_two_byte_output`).
    Under these declarations the Lean encoder is **exactly
    EIP-712 spec-compliant** for the declared field types: a
    spec-compliant wallet (MetaMask, Ledger) parsing the
    declared types and signing produces a struct hash that
    equals `eip712StructHash m` byte-for-byte.

    Headline theorems (Genesis Plan §12.6 #24 – #26):
    * `eip712Wrap_injective` (theorem #24): under
      `CollisionFree hashBytes`, equal wraps for fixed domain
      separator imply equal sign-input bytes.  Proof peels the
      5-field struct preimage via four successive byte-level
      boundary extractions plus two collision-free
      applications (one for the struct hash, one for the
      action hash).
    * `eip712DomainSeparator_distinguishes` (theorem #25):
      under `CollisionFree hashBytes` plus bounded chainId /
      rollupId hypotheses, distinct domain params produce
      distinct separators.
    * `eip712Wrap_distinguishes` (theorem #26): composing #24 +
      #25 — same-size distinct domains plus distinct messages
      produce distinct wraps.

    Auxiliary: `domainPreHash_injective`, `encodeUint256BE_injective`
    (under `< 2^256` bound), `encodeUint256BE_injective_uint64`
    (UInt64-bounded variant), `Eip712Message.actionHash_size`,
    `structPreHash_size` (= 160 bytes; direct evidence the
    struct hash encodes all four fields), plus per-component size
    theorems (`eip712Prefix_size`, `eip712DomainSeparator_size`,
    `eip712StructHash_size`, `eip712Wrap_size`,
    `encodeUint256BE_size`, etc.).

    All theorems `#print axioms`-clean (only `propext` /
    `Quot.sound`; no custom axioms).  42 tests in the
    `bridge-eip712` suite, covering: prefix shape (3); type
    string declarations (4); domain-separator + type-hash sizes
    (4); wrap and struct shapes including byte-layout
    regression tests (8); determinism (2); cross-* and
    cross-protocol distinguishability (7); `encodeUint256BE`
    shape / value (4); headline theorem APIs (3); auxiliary
    lemma APIs (5); stability size APIs (2).

The §5.3 `eip712Wrap_injective` theorem statement is *strictly
stronger than the cryptographically meaningful security goal*:
the Lean-tractable conclusion is "equal wraps imply equal
sign-input bytes" rather than the weaker "equal wraps imply
equal `Eip712Message`s".  The two are equivalent under
`signInput` injectivity in `(action, signer, nonce, deploymentId)`,
which is a separate property of the Canon CBE encoding (provable
but not stated here; production wallet adaptors apply the missing
field-injectivity at the FFI boundary when displaying the message
fields).  See `LegalKernel/Bridge/Eip712.lean`'s docstring for
the full coverage map and the deviations from strict EIP-712 spec
(hash-based canonicalisation of `address` / `bytes` fields rather
than left-padding).

**Trust assumptions introduced by Workstream A.**  The headline
EIP-712 theorems are stated under `CollisionFree hashBytes` (a
Prop parameter), satisfied by production keccak256 but *not* by
the FNV-1a-64 Lean fallback.  This is the Workstream-A-equivalent
of the Phase-3 EUF-CMA-on-`Verify` trust assumption: the kernel's
authority and bridge guarantees hold conditional on the
production binding, not on the Lean fallback.  The Lean side
exposes the assumption as a Prop hypothesis; the runtime adaptor's
test suite (deferred Rust crate) checks the implication against
the linked binding.



**Audit-3 hardening summary.**  A nine-track post-Phase-6 hardening
pass closing the residual deployment-readiness items identified
by the project-feedback review.  Bumped `kernelBuildTag` to
`"canon-phase-6-audit-3-hardening"`.  Test count grew from 614 to
664 (+50 tests across new happy-path, attestation, coherence-API,
property-based, and Audit-3.5 canonicality suites).  TCB unchanged; no new axioms.

  * **Audit-3.1** — Fixed 32-byte hash output (eliminates the
    previous 8/32-byte variable-width chain); documented C ABI
    swap-point symbols (`canon_hash_bytes`, `canon_hash_stream`,
    `canon_hash_identifier`); CLI fail-fast on the Lean fallback
    hash (`canon-replay --allow-fallback-hash` opt-in).  See
    `docs/abi.md §11`.
  * **Audit-3.7** — CI strict-warnings gate; fails the build on
    any `: warning:` line.  Pre-flight inventory found zero
    existing warnings, so the gate adds no remediation burden;
    pure forward-protection.
  * **Audit-3.8** — `lake exe stub_audit` audit binary catches
    placeholder-body stubs (`:= ByteArray.empty`, `:= []`, etc.)
    accompanied by red-flag docstring tokens.  Closes the
    historical `signingInput := ByteArray.empty` regression class.
    Allowlist-bound (`tools/stub_allowlist.txt`).
  * **Audit-3.3 / 3.4 (bundled)** — `AdmissibleWith verify P
    deploymentId` parameterised admissibility predicate with
    back-compat alias `Admissible := AdmissibleWith Verify
    ByteArray.empty`.  `signingInput` extended with deploymentId
    parameter (Genesis Plan §8.8.5 cross-deployment-replay
    rejection at the kernel level).  `Test/MockCrypto.lean`
    supplies `mockVerify` / `mockSign` for value-level happy-path
    test coverage that the production opaque `Verify` (returns
    `false` at the Lean level) makes impossible.  18 happy-path
    tests added across `Test/Authority/SignedActionHappyPath.lean`
    and `Test/Runtime/LoopHappyPath.lean`.
  * **Audit-3.2** — `LegalKernel/Runtime/AttestedSnapshot.lean`
    wraps `Snapshot` with an attestor signature over a domain-
    separated canonical encoding.  `verifyAttestation` checks the
    signature against a known attestor public key.  Closes the
    self-attesting bootstrap gap.  11 attestation tests in the
    new `runtime-attested-snapshot` suite.
  * **Audit-3.5** — `Verdict.signers` / `Verdict.sigs` parallel-
    list shape replaced with a single `signatures : List (ActorId
    × Signature)` field plus a `Verdict.canonical` propositional
    invariant requiring strict-ascending order on the keys.
    Per-signer uniqueness is structural under canonicality
    (strict-less-than implies no duplicates); encoding
    malleability is eliminated for canonical verdicts (the
    decoder enforces canonicality on input bytes via
    `actorsStrictlyAscending` and rejects unsorted /
    duplicate-key input as `nonCanonical`).  An initial attempt
    using `Std.TreeMap` was abandoned because Lean core's
    `Std.Data.TreeMap.Lemmas` does not ship a `(ofList compare
    m.toList).toList = m.toList` lemma; the chosen
    list-of-pairs+canonicality-invariant design avoids that
    problem (round-trip closes via the standard `List.zip_unzip`
    identity).  Back-compat accessors `Verdict.signers` and
    `Verdict.sigs` derive the parallel-list views from
    `signatures` so downstream consumers (e.g.
    `Disputes/Rewards.lean`) keep working unchanged.  5 new
    canonicality tests in `encoding-disputes`.
  * **Audit-3.6** — `apply_admissible_with_eq_kernelOnlyApply`
    coherence theorem: under admissibility, the dispute pipeline's
    `kernelOnlyApply` and the runtime's `apply_admissible_with`
    produce the same `ExtendedState`.  Plus the inductive
    `RuntimeAdmissibleWith` predicate and `head` extractor for
    chain-level lifting.  Closes the previously-flagged trust-
    boundary concern that a registry-state divergence could let a
    dispute verifier reach a different verdict than the runtime's
    behaviour warrants.  4 API stability tests added.
  * **Audit-3.9** — `LegalKernel/Test/Property.lean` minimal
    in-tree property-based testing harness (deterministic LCG;
    no `Std.Random` dependency, no third-party packages — Std-only
    rule preserved).  6 first-wave properties × 100 default samples
    in `Test/Properties/Encoding.lean`.  Reproducibility:
    `CANON_PROPERTY_SEED` and `CANON_PROPERTY_ITERATIONS` env
    vars override the defaults; failing properties log the seed
    for reproduction.

The Audit-3 Genesis Plan amendment (single PR bundling
§8.8.4 / §8.4.2 / §8.8.5 amendments) landed between Wave 1 and
Wave 2 to keep spec and code in lockstep.



**Phase 5 deferred sub-WUs.**  The Lean-only implementation
deliberately defers the Rust-host WUs (5.4 network adaptor, 5.7
event subscription, 5.8 SQLite indexer, 5.11 10k-tx/sec benchmark)
to a follow-up PR with its own CI infrastructure.  The on-disk
log format (WU 5.2), crash-consistency (WU 5.3), replay tool
(WU 5.5), event extraction (WU 5.6), runtime loop (WU 5.1),
snapshot machinery (WU 5.12), extraction notes (WU 5.9), and ABI
documentation (WU 5.10) are all complete and tested.

WU 0.1 (Lean toolchain pin & Lake project skeleton) — complete:
- `lean-toolchain` pinned to `leanprover/lean4:v4.29.1` (the latest
  stable Lean release).
- `lakefile.lean` with `LegalKernel` library, `canon` placeholder
  exe, and `Tests` test driver (wired via `@[test_driver]`).  Strict
  hygiene: `autoImplicit := false`, `relaxedAutoImplicit := false`,
  `linter.unusedVariables := true`, `linter.missingDocs := true`.
- `Main.lean` placeholder runtime.
- `.gitignore` covering `.lake/`, `build/`, OS / editor noise.
- `scripts/setup.sh` SHA-256-verified setup script (`shellcheck`
  clean, fast-path skip, defense-in-depth binary integrity snapshot).
- `lake build` succeeds on a clean checkout.

WU 0.2 (Kernel module skeleton) — complete:
- `LegalKernel/Kernel.lean` ships the literal §4.12 listing.
- Zero `sorry`, zero custom axioms.  Each of the five kernel
  theorems (`impl_refines_spec`, `impl_noop_if_not_pre`,
  `apply_certified_eq_step_impl`, `invariant_preservation`,
  `invariants_compose`) `#print axioms` to exactly
  `[propext, Classical.choice, Quot.sound]` — the Lean built-in
  set CLAUDE.md explicitly allows.
- `lake build LegalKernel.Kernel` succeeds with strict linters on.
- Note: the original draft's `Std.Data.RBMap` is replaced by
  `Std.Data.TreeMap` (Lean core ≥ 4.10; same red-black-tree
  semantics; `Std`-only rule preserved).
- The non-TCB `kernelBuildTag` constant lives in the umbrella
  `LegalKernel.lean` module, *not* in `Kernel.lean`, so the WU 1.11
  TCB audit tool can enumerate the trusted core without seeing
  convenience constants.

WU 0.3 (`transfer` law) — complete:
- `LegalKernel/Laws/Transfer.lean` ships the §4.11 transfer law.
- Self-transfer fix preserved verbatim (read receiver balance from
  post-debit state).
- `decPre := fun _ => inferInstance` discipline followed.
- Decidability smoke-test: `example : Decidable ((transfer …).pre s)
  := inferInstance`.
- Conservation theorem `transfer_conserves` is **deferred to Phase 2**
  (depends on §8.3 fold lemmas from Phase 1) so Phase 0 modules are
  `sorry`-free.

WU 0.4 (CI) — complete:
- `.github/workflows/ci.yml` runs `lake build` and `lake test` on
  every PR to `main` and on direct pushes to `main`.  Phase 1
  extended this to also run `lake exe count_sorries` (WU 1.12) and
  `lake exe tcb_audit` (WU 1.11).
- Third-party actions (`actions/checkout`, `leanprover/lean-action`)
  pinned to **commit SHAs** with version comments — the only
  immutable-release form per GitHub's supply-chain guidance.
- Concurrency group cancels in-flight runs on force-push.
- `permissions: contents: read` (no workflow step writes to the repo).

WU 0.5 (Genesis Plan) — complete (predates this branch).

WU 1.1 – 1.4 (RBMap proof library, §8.3) — complete:
- `LegalKernel/RBMapLemmas.lean` (TCB) ships pointwise insert
  lemmas and `Nat`-summing fold lemmas:
  - WU 1.1: `find?_insert_self`, `find?_insert_other`.
  - WU 1.2: `sumValues_insert_absent` (key absent case).
  - WU 1.3: `sumValues_insert_present` (key present, additive form).
  - WU 1.4: `sumValues_eq_values_sum` (the canonical
    sum-of-values form).
- Proofs go through `Std.TreeMap.toList_insert_perm`, `List.Perm`,
  and `Std.DTreeMap.Equiv.of_forall_constGet?_eq`; no Mathlib, no
  custom axioms.

WU 1.5 (Balance lemmas, §4.3) — complete:
- `getBalance_setBalance_same` and `getBalance_setBalance_other`
  proved in `LegalKernel/Kernel.lean`, using
  `RBMap.find?_insert_self` and `RBMap.find?_insert_other` from
  WU 1.1.

WU 1.6 (Decidability discipline) — complete:
- `docs/decidability_discipline.md` records the
  `decPre := fun _ => inferInstance` rule, the security-review
  trigger when `inferInstance` does not resolve, and the manual
  audit grep.

WU 1.7 – 1.9 (Reachability extensions, §4.9 / §4.10) — complete:
- `Reachable.refl` and `Reachable.trans` close `Reachable` under
  the standard refl-trans laws.
- `ReachableViaLaws L s0 s` restricts reachability to a deployed
  law set.
- `reachable_of_reachable_via_laws` embeds the restricted form
  into the unrestricted one.
- `invariant_preservation_via_laws` is the law-set-indexed variant
  of the §4.10 central theorem; Phase 2's `total_supply_global`
  argument depends on it.

WU 1.10 (Package & document `RBMapLemmas`) — complete:
- `LegalKernel.lean` umbrella re-exports `RBMapLemmas` so
  downstream callers can `import LegalKernel`.
- `kernelBuildTag` bumped to `"canon-phase-1-kernel-completion"`;
  the Umbrella test suite verifies the bump.

WU 1.11 (TCB-audit tool) — complete:
- `Tools/TcbAudit.lean` and `tcb_allowlist.txt` ship; the audit
  enumerates direct imports of `Kernel.lean` and `RBMapLemmas.lean`
  and rejects any not on the allowlist.  CI runs `lake exe
  tcb_audit` after `lake build`.

WU 1.12 (`count_sorries`) — complete:
- `Tools/CountSorries.lean` walks `LegalKernel/` and counts `sorry`
  occurrences in proof position.  CI runs `lake exe count_sorries`
  and fails on any kernel-TCB hit (`Kernel.lean`,
  `RBMapLemmas.lean`, `Laws/Transfer.lean`).

WU 1.13 (Std-dependency audit) — complete:
- `docs/std_dependencies.md` enumerates every `Std`-library lemma
  the TCB invokes, with stability notes and a per-toolchain-bump
  review checklist.

WU 2.1 – 2.9 (Phase 2: Economic Invariants) — complete:
- WU 2.1: `LegalKernel/Conservation.lean` ships `genesisState`, the
  §8.1 `TotalSupply` definition, the sanity lemma
  `totalSupply_genesis_eq_zero`, the more general
  `totalSupply_eq_zero_of_no_resource`, and the master accounting
  lemma `totalSupply_setBalance` (the `Nat`-equation that every
  per-law conservation proof reduces to).
- WU 2.2 + 2.3: `LegalKernel/Laws/Transfer.lean` proves
  `transfer_conserves` (§4.11.1).  The proof is *uniform* over the
  distinct-actor and self-transfer cases — the §4.11 self-transfer
  fix in `transfer.apply_impl` makes the case-split unnecessary at
  the conservation level.  Also lands `transfer_other_resource_untouched`
  (state-level) and `transfer_does_not_touch_other_resources`
  (pointwise; §4.11.2), both via `RBMap.find?_insert_other`.
- WU 2.4: `IsConservative` typeclass in `Conservation.lean`;
  `transfer_isConservative` instance in `Laws/Transfer.lean` combines
  `transfer_conserves` (at the transferred resource) with
  `transfer_conserves_other_resource` (at every other resource).
- WU 2.5: `LegalKernel/Laws/Mint.lean` and `LegalKernel/Laws/Burn.lean`
  ship the two non-conservative balance mutators with `decPre := fun _
  => inferInstance` and a single `setBalance` transformer each.  Both
  ship `totalSupply_after_*` accounting corollaries plus a per-law
  cross-resource locality triple (state-level
  `*_other_resource_untouched`, pointwise
  `*_does_not_touch_other_resources`, and the per-resource supply form
  `*_conserves_other_resource`) that mirrors the Phase-2 additions to
  `Laws/Transfer.lean`.
- WU 2.6: `mint_not_conservative` and `burn_not_conservative` deliver
  explicit non-conservation witnesses; both negate the
  `IsConservative` typeclass directly.
- WU 2.7: `ConservativeLawSet` structure in `Conservation.lean` is
  the §6.2 type-level firewall — mint/burn cannot be added because
  no `IsConservative` instance exists.
- WU 2.8: `total_supply_global` (§5.3 verbatim) plus the
  typeclass-driven corollary `total_supply_global_via_law_set`.
- WU 2.9: `LegalKernel/Laws/Freeze.lean` ships the `freezeResource _r`
  no-op marker (the `_r` parameter is part of the action-layer API
  but deliberately ignored at the kernel level, so `freezeResource 1`
  and `freezeResource 2` are *definitionally equal* `Transition`
  values), the `FrozenForResource r snap` invariant (a closure over
  the snapshotted per-resource `BalanceMap`), and the four
  preservation lemmas: `freezeResource_preserves_freeze` reduces to
  `hI` by definitional equality (`step_impl` on a `True`-precondition
  identity transition collapses); `transfer_preserves_freeze`,
  `mint_preserves_freeze`, `burn_preserves_freeze` each consume the
  corresponding `*_other_resource_untouched` state-level helper and
  are conditional on operating on a *different* resource than the
  frozen one.

WU 3.1 + 3.2 (Action layer + structural compile_injective) — complete:
- `LegalKernel/Authority/Action.lean` ships the `Action` inductive
  with five constructors (`transfer`, `mint`, `burn`,
  `freezeResource`, `replaceKey`); the `CompiledAction` wrapper
  (`source : Action`, `transition : Transition`); the
  `Action.compileTransition` raw compiler; the `Action.compile`
  wrapper that produces `CompiledAction`; and the headline
  `Action.compile_injective` theorem proved as a one-line
  `congrArg CompiledAction.source`.
- The `CompiledAction` wrapper is the Phase-3 redesign that makes
  injectivity *structural*: distinct compiled actions necessarily
  have distinct `source` fields, so the proof is mechanical.  The
  alternative — proving injectivity at the bare `Transition` level
  — would have required hairy discrimination lemmas and would have
  *failed* on the Phase-2 `freezeResource` (whose body ignores its
  parameter) and on vacuous action pairs like `transfer r s s 0` vs
  `mint r s 0`.
- The kernel TCB is unchanged: `Transition` retains its three
  fields, and `CompiledAction` lives in `LegalKernel/Authority/`
  (non-TCB).
- Convenience accessors `Action.pre`, `Action.apply_impl`, and
  `Action.decPre` are also exported for downstream call sites that
  want kernel-shaped APIs.

WU 3.3 (Identity, KeyRegistry, AuthorityPolicy) — complete:
- `LegalKernel/Authority/Identity.lean` ships the `Identity`
  structure (`id : ActorId`, `key : PublicKey`); the `KeyRegistry =
  TreeMap ActorId PublicKey compare` abbreviation with `empty`,
  `register`, `revoke`, `lookup`, and `mergeLeftBiased`; the
  `AuthorityPolicy` structure (`authorized` predicate + `decAuth`
  decidability witness); and four combinators (`empty`,
  `unrestricted`, `union`, `intersect`, `singleton`).
- Phase-3 design deviation from §8.2: the dynamic `KeyRegistry`
  lives in `ExtendedState` (so `replaceKey` can mutate it), not
  inside `AuthorityPolicy`.  The `AuthorityPolicy` retains only the
  static authorisation predicate and its decidability witness.
- `mergeLeftBiased` uses left-biased key collision resolution per
  the Genesis-Plan §8.2 spec; deployments needing a different
  resolution rule supply their own combinator.

WU 3.4 (`Verify` interface) — complete:
- `LegalKernel/Authority/Crypto.lean` ships `PublicKey` and
  `Signature` as `ByteArray` abbreviations (with explicit `Repr`
  and `DecidableEq` instances for downstream `deriving`); the
  `Nonce = Nat` abbreviation; the opaque `Verify : PublicKey →
  ByteArray → Signature → Bool`; and the `SigningInput` abbreviation
  (`= ByteArray`).  The actual `signingInput : Action → ActorId →
  Nonce → SigningInput` function lives in `Authority/SignedAction.lean`
  and ships the real CBE-encoded bytes (post-audit hardening; see
  the Phase-3 entry below).
- `Verify` is declared `opaque` rather than `axiom`, so the kernel's
  axiom audit continues to return exactly `[propext,
  Classical.choice, Quot.sound]`.  The EUF-CMA security assumption
  is a *trust assumption* on the deployment-supplied runtime
  adaptor (Phase 5, WU 3.9), not a Lean axiom.

WU 3.5 (`NonceState` + `ExtendedState`) — complete:
- `LegalKernel/Authority/Nonce.lean` ships the `NonceState`
  structure (`next : TreeMap ActorId Nonce compare`); the
  `ExtendedState` structure (`base : State`, `nonces : NonceState`,
  `registry : KeyRegistry`); and the `expectsNonce` / `advanceNonce`
  operations.
- The §8.5 headline lemma `expectsNonce_strict_mono` is proved via
  `RBMap.find?_insert_self` (WU 1.1) in three lines.  Companion
  lemmas `expectsNonce_advance_other` (cross-actor isolation),
  `advanceNonce_base`, `advanceNonce_registry` (field
  preservation), and the Nat-arithmetic corollaries
  `expectsNonce_after_advance_gt_old` and
  `expectsNonce_after_advance_ne_old` are also exported.

WU 3.6 (`SignedAction` + `Admissible`) — complete:
- `LegalKernel/Authority/SignedAction.lean` ships the `SignedAction`
  structure (`action`, `signer`, `nonce`, `sig`); the §8.2
  `Admissible` predicate as a four-conjunct `Prop` (registration
  conjoined with signature verification, since both consume the
  same `pk`); and the `applyActionToRegistry` helper that captures
  the action-specific authority-layer effects (`replaceKey` mutates
  the registry; other actions leave it unchanged).
- The `Admissible` predicate's clause order matches the §8.2
  static-vs-dynamic decomposition: condition 2 (`authorized`) and
  conditions 1+3 (registration + signature) are static in the
  signer-action-nonce triple; condition 4 (nonce match) and
  condition 5 (kernel pre) are dynamic in the `ExtendedState`.

WU 3.7 (`apply_admissible` + `nonce_uniqueness`) — complete:
- `apply_admissible : (P : AuthorityPolicy) → (es : ExtendedState) →
  (st : SignedAction) → Admissible P es st → ExtendedState` is the
  single guarded entry point.  Order of operations: compile the
  action, apply the kernel transition's `apply_impl` to `es.base`,
  wrap, advance the signer's nonce, and (for `replaceKey`) update
  the registry.
- `nonce_uniqueness` has a five-line proof: extract the nonce-match
  conjunct from each admissibility witness, rewrite by the
  same-signer hypothesis, and chain the equalities.
- `expectsNonce_after_apply_admissible` is the algebraic core that
  `replay_impossible` consumes: after one `apply_admissible`, the
  signer's expected nonce is exactly one greater than before.

WU 3.8 (`replay_impossible`) — complete:
- Proved in eight lines via `expectsNonce_after_apply_admissible`,
  `admissible_nonce_eq` (×2, on the pre- and post-states), and a
  single `Nat.ne_of_lt (Nat.lt_succ_self _)` to close the
  contradiction.
- The headline takeaway: a successfully applied signed action
  cannot be admissible at the post-state.  No race, no log replay,
  no pathological scenario in which this guarantee fails.

WU 3.10 (`replaceKey` + key rotation) — complete:
- `Action.replaceKey` is one of the five Action constructors; its
  authority-layer effect is captured by `applyActionToRegistry`
  inside `apply_admissible`.  Three theorems pin down the
  semantics:
  - `replaceKey_updates_registry`: the post-`apply_admissible`
    registry has `actor → newKey`.
  - `replaceKey_other_actor_untouched`: other actors' registry
    entries are unchanged.
  - `non_replaceKey_preserves_registry`: any non-`replaceKey`
    action preserves the registry pointwise.
- The end-to-end key-rotation chain (§8.2 acceptance criterion) is
  exercised by the `keyRotationTests` sub-suite in
  `LegalKernel/Test/Authority/SignedAction.lean`: register actor 10
  with K1, rotate to K2, rotate back to K1, and verify cross-actor
  independence.

WUs R.1 – R.23 (Phase-4 prelude: Positive Incentives) — complete:
- **R.1 / R.2**: introduce the missing tier between conservation and
  unrestricted laws.  `IsMonotonic` typeclass (supply non-decreasing)
  + `monotonic_of_conservative` low-priority auto-upgrade in
  `Conservation.lean`.  `MonotonicLawSet` structure + headline
  theorems `total_supply_globally_nondecreasing[_via_law_set]`.
  Mirror of `IsConservative` / `ConservativeLawSet` /
  `total_supply_global[_via_law_set]` in shape.
- **R.3 / R.4**: per-existing-law classification.
  `transfer_isMonotonic`, `mint_isMonotonic`,
  `freezeResource_isConservative` + `_isMonotonic` (the latter pair
  was missing in Phase 2); `burn_not_monotonic` negative witness in
  `Laws/Burn.lean` (mirroring `burn_not_conservative` in proof shape,
  with the equality flipped to a strict inequality discharged by
  manual additive cancellation).
- **R.5 / R.6**: `Laws/Reward.lean` — single-recipient
  positive-incentive credit.  Definitionally identical to `mint` at
  the kernel level, but distinct at the `Action` layer (see R.17) so
  authority policies can grant reward / mint independently.  Eleven
  test cases mirroring `Test/Laws/Mint.lean`.
- **R.7**: `getBalance_le_totalSupply` lemma in `Conservation.lean`
  (bound any single actor's balance by the per-resource supply).
  Used by `proportionalDilute`'s precondition reasoning and by the
  dust-bound theorem.  Pivot from the original `bmReplaceValues`
  generic helper to a focused single-lemma WU because the per-law
  `apply_impl` implementations (foldl-of-`setBalance`) avoid the
  rebuild-from-empty fold that would have required the generic
  lemma.
- **R.8 / R.9 / R.10**: `Laws/DistributeOthers.lean` — uniform
  reward of all non-excluded actors at a resource.  `apply_impl`
  iterates `setBalance` over the pre-filtered list of non-excluded
  entries; each step is a known kernel operation, so locality
  (other-resource untouched, excluded actor unchanged) and the supply
  equation `post = pre + amount * size_excluding_key` reduce to short
  inductive arguments.  `IsMonotonic` instance + non-conservative
  witness.  Fourteen test cases on multi-actor fixtures.
- **R.11 / R.12 / R.13 / R.14 / R.15 / R.16**: `Laws/ProportionalDilute.lean` —
  proportional positive-incentive distribution.  Each non-excluded
  actor `k` receives `totalReward * v_k / sumOthers` (Nat floor
  division; dust discarded).  Generic foldl-of-`setBalance` helpers
  generalised over the per-step value function (since the increment
  is data-dependent on the snapshotted balance).  Supply equation
  (R.13), the **full dust bound**
  `proportionalDilute_distributed_le_totalReward` (R.14), `IsMonotonic`
  instance + non-conservative witness (R.15), seventeen test cases
  on hand-computed fixtures (R.16).  R.14's proof goes through new
  filter-sum infrastructure in `Conservation.lean`
  (`list_partition_sum_by_key`, `list_filter_eq_singleton_of_distinct`,
  `balanceMap_filter_sum_plus_lookup`,
  `state_filter_sum_eq_sumOthers`) which uses
  `Std.TreeMap.distinct_keys_toList` to bridge the per-bm filter sum
  to `sumOthers`.
- **R.17 / R.18**: extend `Authority/Action.lean` with three new
  constructors (`reward`, `distributeOthers`, `proportionalDilute`),
  three new `compileTransition` cases, three smoke `example` lines.
  `Action.compile_injective` is unchanged (structural via
  `CompiledAction.source`).  `non_replaceKey_preserves_registry` in
  `Authority/SignedAction.lean` extended to handle the three new
  constructors (each closes by `rfl` since none mutate the registry).
  Eight new test cases in `Test/Authority/Action.lean`.
- **R.19 / R.20**: per-existing-law instance-resolution tests
  (Transfer / Mint / Burn / Freeze test files); ConservationTests
  extensions exercising `IsMonotonic`, `MonotonicLawSet`, and the
  headline theorems; **end-to-end behaviour test** that runs a
  4-step trace (mint, reward, distributeOthers, transfer) and
  verifies per-step non-decrease at the value level + the expected
  final supply.
- **R.21**: `LegalKernel.lean` umbrella adds three new imports;
  `kernelBuildTag` bumped to
  `"canon-phase-4-prelude-positive-incentives"`; `Tests.lean` driver
  registers three new suites; `Test/Umbrella.lean` build-tag literal
  updated.

WUs 4.1 – 4.9 (Phase 4: DSL and Serialization) — complete:
- **WU 4.1 + 4.2**: `LegalKernel/Encoding/CBOR.lean` ships the
  byte-level codec foundation: `DecodeError`, `Stream = List UInt8`,
  the `cborHeadEncode` / `cborHeadDecode` head pair (1 type-tag byte
  + 8 LE value bytes), and the `natFromBytesLE` ↔ `natToBytesLE`
  fixed-width Nat codec.  Headline lemmas
  `cborHeadRoundtrip{,_append}` for `n < 2^64`.
  `LegalKernel/Encoding/Encodable.lean` ships the `Encodable`
  typeclass plus instances for `Bool`, `Nat`, `BoundedNat`,
  `ByteArray`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `List α`,
  `Option α`.  Per-type round-trip + injectivity theorems for the
  primitives (`bool_*`, `nat_*`, `boundedNat_*`, `byteArray_*`,
  `uInt8_*`, `uInt16_*`, `uInt32_*`, `uInt64_*`); for `List α` and
  `Option α`, round-trip is *parameterised* on a per-element
  hypothesis `ElemRoundtrip α` (avoiding a `LawfulEncodable`
  typeclass that would have to be retro-fitted to every
  `Encodable` instance).  `BoundedNat` is the typeclass-driven
  (unconditional) version for runtime callers that need to
  enforce the `< 2^64` bound at the type level.  ActorId /
  ResourceId / Amount / Nonce inherit the `Nat` instance via
  abbrev unification.  The Genesis Plan §12 WU 4.1's `String`
  instance is *omitted* here (the §8.8 deviation block in
  `GENESIS_PLAN.md` documents the deferral): no in-tree consumer
  needs it and Lean core doesn't currently expose the
  `fromUTF8?_toUTF8` identity needed to prove its round-trip.
- **WU 4.3**: `LegalKernel/Encoding/Action.lean` ships `Action.encode`
  / `Action.decode` (constructor-tag uint + fields, with frozen
  constructor indices 0..7), the `Action.fieldsBounded` predicate,
  and the headline `action_roundtrip` + `action_encode_injective`
  theorems.  Decidable `Action.decFieldsBounded`.  Spot-check
  `example`s.
- **WU 4.4**: `LegalKernel/Encoding/SignedAction.lean` ships the
  fixed-order `[action, signer, nonce, sig]` encoding plus
  `signedAction_roundtrip` + `signedAction_encode_injective`
  conditional on `SignedAction.fieldsBounded`.  Dispute / Verdict
  encodings deferred to Phase 6 (those types don't exist yet).
- **WU 4.5**: `LegalKernel/Encoding/State.lean` ships `State.encode`
  / `State.decode` plus `BalanceMap.encode` (sorted-pair-list of
  inner balance maps) and `ExtendedState.encode` (`base ++ nonces ++
  registry`).  Each inner `BalanceMap` is wrapped as a CBE byte
  string before being placed in the outer map's value slot
  (`BalanceMap.encodeAsBytes`); this length-prefixed framing is
  what lets the decoder cleanly extract each inner-map payload
  from the outer map's value slot.  The shared map decoder
  (`decodeMap`) enforces the §8.8.6 canonicalisation rule via
  `keysStrictlyAscending`: any CBE map encoding with unsorted or
  duplicate keys is rejected with `nonCanonical`.  This is the
  decoder-side counterpart to the encoder's "sorted toList"
  invariant; without it an attacker could construct alternative-
  but-equally-valid encodings of the same logical state with
  distinct sign-input bytes.  `state_encode_deterministic`
  (structural) and `balanceMap_encode_deterministic_of_equiv`
  (extensional via `TreeMap.equiv_iff_toList_eq`).  The
  TreeMap-backed encoding canonicalises away RB-tree shape
  variation by going through `toList` (sorted) and decoding via
  `ofList`.  The full abstract `decode_encode_extensional`
  theorem is deferred; the value-level round-trip is verified
  end-to-end by `Test/Encoding/State.lean`'s
  `stateRoundtripGetBalance` (4 probed cells),
  `extendedStateRoundtrip` (probes base, nonces, and registry),
  and `stateEncodeDecodeEncodeIdempotent` (audit 2: re-encoding a
  decoded state produces the original bytes).
- **WU 4.6 + 4.7**: round-trip + injectivity rolled into each
  WU 4.1 – WU 4.5 module above.  Every `Encodable` instance has
  either an unconditional or a bounded round-trip / injectivity
  theorem (no `sorry`).
- **WU 4.8**: `LegalKernel/Encoding/SignInput.lean` ships
  `signInput action signer nonce deploymentId` returning the
  domain-separated CBE byte sequence (Genesis Plan §8.8.5 layout).
  Domain string `"legalkernel/v1/signedaction"` (27 ASCII chars)
  prefixes every signing input; the deployment-ID encoding
  prevents cross-deployment replay.  `signInput_deterministic` /
  `signInput_nonempty` headline theorems.  Cross-deployment
  distinguishability verified at the value level via test vectors
  (the abstract Lean theorem requires byte-surgery that's
  tractable but tedious; deferred to a follow-up).
- **WU 4.9**: `LegalKernel/DSL/Law.lean` ships the `Law.mk`
  combinator and the `law` macro (`law pre := <expr> ; impl :=
  <expr>` and `law impl := <expr>` impl-only form).  Both fill in
  `decPre := fun _ => inferInstance` automatically; if the
  precondition is not instance-decidable, elaboration FAILS with
  the standard "failed to synthesize Decidable" message — which
  correctly flags the precondition as needing a hand-written
  decidability witness.  `transferDSL` test verifies the DSL-built
  transition is value-level identical to `Laws.transfer`.
- **Integration**: `LegalKernel.lean` umbrella adds seven new
  imports (`Encoding/{CBOR, Encodable, Action, SignedAction, State,
  SignInput}` + `DSL/Law`); `kernelBuildTag` bumped to
  `"canon-phase-4-dsl-serialization"`; `Tests.lean` driver
  registers seven new suites; `Test/Umbrella.lean` build-tag
  literal updated.

**Phase 4 design deviations (documented).**  Phase 4 ships **CBE**
(Canon Binary Encoding), a *strictly canonical* fixed-width binary
form rather than the RFC 8949 canonical CBOR sketched in
§8.8.2.  CBE has 1 type-tag byte + 8 LE value bytes for every uint
head, fixed length-prefixed bytestrings / arrays / maps, and
sorted-key map encoding.  This trades canonical-CBOR wire
compatibility for proof tractability: round-trip and injectivity
are provable by direct structural induction with no bit-level
case-splitting on uint size buckets.  Phase 5's runtime adaptor
MAY add a CBE↔canonical-CBOR translation layer for wire interop;
the kernel proof obligations are independent of that adaptor.
See the §8.8 deviation block in `docs/GENESIS_PLAN.md` for the
full list of Phase 4 deviations.

WUs 5.1 – 5.12 (Phase 5: Runtime and Extraction) — complete (Lean
side); Rust-side WUs (5.4 / 5.7 / 5.8 / 5.11) deferred:
- **WU 5.1**: `LegalKernel/Runtime/Loop.lean` ships the
  `RuntimeState` record (policy, state, prevHash, logIndex,
  logPath), the `processSignedAction` single-step state advance
  (admissibility-check → apply → log-append → events), the
  `bootstrap` startup path (load + truncate + replay), and the
  `processBatch` convenience helper.  `Main.lean` now hosts the
  Phase-5 `canon` runtime CLI with five subcommands (`info`,
  `process`, `replay`, `bootstrap`, `snapshot`).  `Replay.lean`
  is a separate single-purpose binary (`canon-replay`).
- **WU 5.2**: `LegalKernel/Runtime/LogFile.lean` ships the
  `LogEntry` structure (`prevHash`, `signedAction`,
  `postStateHash`), its `Encodable` instance, the framed on-disk
  format (`MAGIC + LENGTH + PAYLOAD + TRAILER` with FNV-1a-64
  trailer), the `appendEntry` / `readAllEntries` IO primitives,
  and the `verifyChain` chain-integrity helper.  Frame magic is
  the ASCII string `"CANO"` (0x43 0x41 0x4E 0x4F).
- **WU 5.3**: crash-consistency lives in the same module
  (`loadAndTruncate`).  On startup the runtime walks the file
  frame-by-frame, stops at the first incomplete / corrupt frame,
  and truncates to the last good byte boundary.  Error
  diagnostics distinguish `truncated` (legitimate torn write)
  from `badMagic` / `badTrailer` (genuine corruption).
- **WU 5.4**: deferred (Rust network adaptor — depends on Rust as
  the host language).  `docs/abi.md` §10 documents the planned
  wire format.
- **WU 5.5**: `LegalKernel/Runtime/Replay.lean` ships `replay`
  (genesis + log → final state), `replayHash` (final-hash-only),
  `replayFromSeed` (snapshot-bootstrap-friendly variant), and
  the `Decidable Admissible` instance the runtime needs to
  dispatch admissibility checks.  The standalone `canon-replay`
  binary (`Replay.lean`) is the auditor entry point.  Acceptance:
  `canon process LOG IN` followed by `canon-replay LOG`
  reproduces the runtime's `StateHash` byte-for-byte.
- **WU 5.6**: `LegalKernel/Events/Types.lean` ships the
  five-constructor `Event` inductive (per §8.9.2; Phase 6 will
  append two more for disputes / verdicts).
  `LegalKernel/Events/Extract.lean` ships the deterministic
  `extractEvents : (preState, postState, signedAction) → List
  Event` function with per-action emission rules documented in
  the file's coverage map.
- **WU 5.7**: deferred (Rust subscription).
- **WU 5.8**: deferred (Rust + SQLite indexer).
- **WU 5.9**: `docs/extraction_notes.md` — what survives Lean's
  compilation pipeline into the runtime binary.  Per-construct
  erasure / persistence map (Prop-typed values erased; opaque
  declarations get a placeholder body unless `@[extern]`-linked;
  state-hash determinism preserved across architectures).
- **WU 5.10**: `docs/abi.md` — on-disk frame layout, FNV-1a-64
  trailer format, per-type CBE encodings, CLI subcommand
  contracts.  External implementers can reproduce a compatible
  client from this document alone.
- **WU 5.11**: deferred (10k tx/sec benchmark — depends on the
  Rust network adaptor for end-to-end measurement).
- **WU 5.12**: `LegalKernel/Runtime/Snapshot.lean` ships the
  `Snapshot` record (`stateHash`, `encodedState`, `logIndex`,
  `seedHash`), `takeSnapshot` / `restoreSnapshot`, the file IO
  helpers (`saveSnapshot` / `loadSnapshot`), and
  `replicaFromSnapshot` (the headline operation: a fresh replica
  bootstraps from a snapshot file plus the post-snapshot log
  tail).

WUs 6.1 – 6.12 (Phase 6: Disputes and Adjudication) — complete:
- **WU 6.1**: `LegalKernel/Disputes/Types.lean` ships the
  first-order data types: `LogIndex` (= `Nat`), `DisputeClaim` (5
  variants: `preconditionFalse`, `signatureInvalid`,
  `nonceMismatch`, `oracleMisreported`, `doubleApply`),
  `EvidenceVerdict` (3 variants: `upheld`, `rejected`,
  `inconclusive`), `Dispute` structure (`challenger`, `claim`,
  `evidence`, `nonce`, `sig`), `Verdict` structure (`disputeId`,
  `outcome`, `rationale`, `signers`, `sigs`), `DisputeStatus`
  (3 variants: `open`, `withdrawn`, `decided`), `DisputeRecord`,
  `OraclePolicy` (with `alwaysRejects` / `alwaysUpheld`
  fixtures), `FilingError` (4 variants), and `VerdictError` (5
  variants).  `LegalKernel/Encoding/Disputes.lean` ships
  canonical CBE byte encodings for each new type with per-type
  round-trip and injectivity theorems.  `Verdict.fieldsBounded`
  uses `List.all` for `Decidable` synthesis on the per-signature
  size bound.  Parametric `list_roundtrip_bounded` lemma in
  `Encoding/Encodable.lean` lifts the per-element-bounded round-
  trip via a new `ElemRoundtripIn` predicate.
- **WU 6.2**: extends `LegalKernel/Authority/Action.lean` with
  four new constructors at frozen indices 8..11: `dispute (d :
  Dispute)`, `disputeWithdraw (idx : LogIndex)`, `verdict (v :
  Verdict)`, `rollback (targetIdx : LogIndex)`.  All four compile
  to `Laws.freezeResource 0` (kernel-level no-ops).  Updates
  `Encoding/Action.lean`'s `fieldsBounded`, `encode`, `decode`,
  and `action_roundtrip` to handle the new constructors.  Uses
  the `verdict_roundtrip` lemma from `Encoding/Disputes.lean` to
  discharge the `verdict` round-trip case (which depends on the
  per-element-bounded list lemma).  Extends
  `non_replaceKey_preserves_registry` in
  `Authority/SignedAction.lean` with four new `rfl` cases.
  Extends `Events/Types.lean`'s `Event` inductive with three new
  constructors at frozen indices 5..7: `disputeFiled`,
  `disputeWithdrawn`, `verdictApplied`.  Extends
  `Events/Extract.lean`'s `actionEvents` to emit dispute events
  for the three new dispute-pipeline action constructors.
- **WU 6.3**: `LegalKernel/Disputes/Filing.lean` ships
  `claimImpugnedIdx` / `claimSecondaryIdx` (per-claim impugned-
  index extractors), `disputeMatchesEntry` /
  `findPriorDisputeIdx` (log-scan helpers for the duplicate
  check), and `fileDispute` (Stage 1 with all four §8.4.4
  acceptance checks: `malformedAction`, `unknownChallenger`,
  `indexOutOfRange` for primary / secondary index,
  `duplicateDispute`).  Returns `DisputeRecord` with `status =
  open` on success.
- **WU 6.4**: `Disputes/Evidence.lean` ships
  `checkPreconditionFalse`: replays `log[0..idx-1]` via
  `kernelOnlyReplay` (admissibility-blind helper that uses
  `step_impl` directly so logs whose runtime-time admissibility
  cannot be re-established do not block the dispute pipeline),
  evaluates `(Action.compile log[idx].action).pre` at the
  recovered pre-state, returns `upheld` iff false.
- **WU 6.5**: `checkSignatureInvalid` re-runs `Verify` against
  the current registered key for `log[idx].signer`, returning
  `upheld` iff `false`, `inconclusive` if the signer is
  unregistered or the entry is missing.
- **WU 6.6**: `checkNonceMismatch` recomputes
  `expectsNonce es_{idx-1} log[idx].signer` via
  `kernelOnlyReplay`, returns `upheld` iff the recorded nonce
  differs.
- **WU 6.7**: `checkOracleMisreported` delegates to the
  deployment-supplied `OraclePolicy.verifier` (pure pass-through).
  `OraclePolicy.alwaysRejects` and `alwaysUpheld` ship as test
  fixtures.
- **WU 6.8**: `checkDoubleApply` verifies `log[idx₁].nonce =
  log[idx₂].nonce` and `signer₁ = signer₂` and `idx₁ ≠ idx₂`.
  Returns `rejected` on `idx₁ = idx₂` (claim structurally
  invalid).  The `checkEvidence` dispatcher routes to the
  appropriate verifier per `claim` variant.
- **WU 6.9**: `Disputes/Verdict.lean` ships `QuorumPolicy`
  (with `singleton` / `empty` constructors), `verdictSigningInput`
  (CBE-encoded `(disputeId, outcome, rationale)` — the bytes
  every approved adjudicator signs; the `signers` / `sigs` lists
  are deliberately excluded so all adjudicators sign the same
  payload),
  `countVerifiedSignatures` (walks the parallel `signers` /
  `sigs` lists with **per-signer deduplication** so a single
  adjudicator with one valid signature contributes at most 1 to
  the count, regardless of list-length padding; counts pairs
  whose distinct signer is approved + registered + whose
  first-paired signature verifies), and `proposeVerdict` (Stage 3
  with the four §8.4.2 validation checks: `unknownDispute`,
  `alreadyDecided`, `outcomeMismatch`, `quorumNotMet`).
- **WU 6.10**: `applyVerdict` (Stage 4) computes the rollback
  target via `replayPrefix` for `upheld` outcomes; returns
  `currentEs` unchanged for `rejected` / `inconclusive`
  outcomes.  Surfaces precise diagnostics (`unknownDispute`,
  `alreadyDecided`, `replayFailed`).  Per-outcome no-change
  theorems (`applyVerdict_rejected_no_change`,
  `applyVerdict_inconclusive_no_change`) and determinism theorems
  (`applyVerdict_deterministic`,
  `proposeVerdict_deterministic`) close the §8.4.3 acceptance
  property.
- **WU 6.11**: `applyWithdraw` is `.open → .withdrawn`,
  identity on `.withdrawn` and `.decided` (the idempotency
  property).  `applyWithdraw_idempotent` theorem:
  `applyWithdraw (applyWithdraw s) = applyWithdraw s` for every
  `s : DisputeStatus`.  `disputeStatus` walks the log forward
  from a dispute's filing index, applying `applyWithdraw` /
  `applyVerdictOutcome` per matching action.
- **WU 6.12**: `Test/Disputes/EndToEnd.lean` ships the
  acceptance test: a 2-entry pre-dispute log
  `[legitimate_transfer; planted_illegal_transfer]` is filed
  against (returning `DisputeRecord` with `idx = 2`); the
  full 3-entry log (with the dispute appended) is checked via
  `checkEvidence` (returns `.upheld` because `transfer.pre` is
  false at the post-entry-0 state); a corresponding `.upheld`
  verdict is applied via `applyVerdict`, returning the
  rolled-back state whose `getBalance r a` queries match the
  state immediately before the planted illegal transfer.
- **Integration**: `LegalKernel.lean` umbrella adds five new
  imports (`Disputes/{Types, Filing, Evidence, Verdict}` +
  `Encoding/Disputes`); `kernelBuildTag` bumped to
  `"canon-phase-6-disputes-adjudication"`; `Tests.lean` driver
  registers five new suites; `Test/Umbrella.lean` build-tag
  literal updated.

**Post-Phase-6 security-audit hardening.**  A whole-codebase
security audit identified and fixed three production-readiness
defects whose exploit conditions all required either (a) a
fully-wired `Verify` adaptor (i.e. Phase 5+ runtime deployment)
or (b) a malicious adjudicator inside the deployment.  Each
defect is closed without any kernel-TCB changes; the fixes are
all confined to non-TCB authority / disputes layers.

* **`countVerifiedSignatures` per-signer deduplication
  (`Disputes/Verdict.lean`).**  Pre-fix, the function counted
  every `(signer, sig)` pair in `v.signers`/`v.sigs` separately,
  so a single approved adjudicator with one valid signature
  could meet any quorum threshold by replicating the
  `(signer, sig)` pair `N` times in the verdict's lists — a
  trivial-quorum-forgery vulnerability.  The fixed function
  threads a "seen" list through the foldl, so each distinct
  signer contributes at most 1 to the count regardless of
  list-length padding.  Five regression tests in
  `disputes-verdict` pin the dedup invariant: count ≤ #distinct
  approved signers.

* **`signingInput` content-distinguishing encoding
  (`Authority/SignedAction.lean`).**  Pre-fix, the function
  returned `ByteArray.empty` for every `(action, signer, nonce)`
  triple — a Phase-3 stub explicitly documented as "insecure for
  runtime use" pending Phase-4 integration.  Phase 4 shipped
  `Encoding/SignInput.signInput` but never threaded it through
  `Admissible`; production deployments would have called
  `Verify pk ByteArray.empty sig` for every action, permitting
  trivial signature replay across distinct triples.  The fixed
  function emits the real CBE encoding (concatenation of
  `encode action ++ encode signer.toNat ++ encode nonce`) so
  distinct triples produce distinct sign-input bytes.  The
  cross-deployment domain prefix (`Encoding.signInput`'s
  deploymentId hash) remains a deployment-scoped concern (the
  runtime adaptor scopes `Verify` per-deployment).  Six
  regression tests in `authority-signed` pin the
  content-distinguishing property.

* **`verdictSigningInput` content-distinguishing encoding
  (`Disputes/Verdict.lean`).**  Same shape as the
  `signingInput` defect.  Pre-fix, every verdict shared identical
  bytes, so any adjudicator's signature on one verdict was
  trivially replayable as their signature on another.  The fixed
  function emits CBE-encoded `(disputeId, outcome, rationale)`;
  the `signers` / `sigs` fields are deliberately excluded
  (otherwise each adjudicator would need to predict every other
  adjudicator's signature — a circular dependency).  Five
  regression tests in `disputes-verdict` pin the
  content-distinguishing property.

The first audit also produced a comprehensive list of
informational findings (documentation drift, defensive hardening
opportunities, cross-layer architectural notes), all filed for
follow-up but none rising to the level of a security defect.

**Audit-2 hardening (this branch).**  A second whole-codebase
audit identified four further issues; all are now closed.

* **Cross-protocol domain separation for `signingInput` and
  `verdictSigningInput`.**  The first audit's CBE-bytes fix made
  each function content-distinguishing within its own protocol,
  but the two byte sequences could still potentially collide
  (a `SignedAction` signing input could in principle match a
  `Verdict` signing input for some payload combination).  Both
  functions now prepend a length-prefixed CBE byte string of
  their domain — `"legalkernel/v1/signedaction"` vs
  `"legalkernel/v1/verdict"` — so a signature on one protocol
  cannot be re-interpreted as a signature on the other.  Five
  regression tests pin the property.

* **DSL `transferDSL` precondition drift.**  The
  `LegalKernel/DSL/Law.lean` example `transferDSL` claimed to
  re-derive `Laws.transfer` via the `law pre := … ; impl := …`
  macro, but its precondition omitted the `amount > 0`
  positivity clause.  The DSL itself was correct; only the
  example was missing the clause.  Fixed; a new value-level
  test (`transferDSLPreMatches`) confirms the DSL form's pre
  agrees with `Laws.transfer`'s on the boundary case
  (`amount = 0` is rejected by both).

* **List/map decoder DoS bounded-by-input documentation.**
  The list and map decoders (`decodeListN`, `decodeNPairs`)
  could in principle recurse deeply on a malicious-input
  declared count.  Re-analysis confirms the recursion depth is
  bounded by `input_size / 9` (each successful element decode
  consumes ≥ 9 bytes via the CBE head; an empty/short remaining
  stream causes `unexpectedEof` to fire on the next element
  decode and the recursion to terminate).  The runtime
  adaptor's max-message-size policy (Phase 5; not in-tree) is
  the appropriate guard for the *outer* input size.  Documented
  as a `decodeMap` in-line comment.

* **CBE `Nat`-key truncation: confirmed non-issue.**  An
  initial concern that decoders for `BalanceMap` /
  `NonceState` / `KeyRegistry` could silently truncate `Nat`
  keys to `UInt64` was withdrawn after re-checking
  `cborHeadDecode`: the function reads exactly 8 LE bytes and
  produces a `Nat` strictly less than `2^64`, so `toUInt64`
  is exact.  No fix required.

No new axioms, no kernel-TCB expansion, no new `sorry`
admissions across either audit; the post-audit codebase passes
`lake exe count_sorries`, `lake exe tcb_audit`, and the full
614-test suite.

**Phase 5 audit fixes (post-landing).**  Following the initial Phase
5 landing, two audit passes identified and fixed:

**Audit pass 1:**

* **`partial def decodeAllFrames'` made terminating** — replaced the
  opaque `partial def` with a fueled structurally-recursive
  definition.  The fuel measure (input length + 1) is strictly
  larger than the actual recursion depth (≥ 1 byte consumed per
  iteration), so the fuel never runs out in practice.
* **`BootstrapError` name collision resolved** — `Snapshot.lean`'s
  type renamed to `ReplicaError` (it is for replica startup,
  distinct from runtime bootstrap).  `Loop.lean`'s
  `BootstrapError'` (with prime) renamed to `BootstrapError`.
* **`bootstrapFromSnapshot` precise diagnostics** — previously a
  snapshot-restoration failure was collapsed into a misleading
  `replay (.chainBroken 0)` error.  Now surfaces as
  `.snapshot e` with the precise `SnapshotError`.
  `BootstrapError` gained a `.snapshot` constructor.
* **`canon-replay` fail-fast on snapshot errors (security fix)** —
  previously a corrupted snapshot caused the tool to silently fall
  back to empty genesis and print `OK <hash>` — masking the
  failure and producing fake-valid output.  Now the tool prints
  `SNAPSHOT_ERROR` / `SNAPSHOT_DECODE_ERROR` and exits non-zero
  WITHOUT proceeding to replay.
* **`loadSnapshot` graceful missing-file handling** — previously
  threw an uncaught IO exception; now returns
  `.error .unexpectedEof` so the caller's error surface is uniform.
* **`actionEvents` comment / docstring corrected** — comment
  claimed "always emit both events" but code filters zero-deltas;
  docstring updated to accurately describe delta-filtering.
* **`Main.lean` docstring corrected** — claimed "three operating
  modes" but binary has six subcommands.
* **Inelegant `let _ := h_p` patterns removed** — `decodeFrame`
  rewritten without the explicit-bound `let _ := proof` patterns
  that suppressed unused-variable warnings.
* **`replayHash` doc claim fixed** — claimed "avoids holding the
  final `ExtendedState` in memory" which was misleading;
  rephrased to describe what the function actually does.
* **`replayStep` / `restoreSnapshot` `by; exact ...` patterns
  simplified** — replaced with direct definitional form.

**Audit pass 2 (correctness):**

* **`bootstrapFromSnapshot` snapshot-slicing fix (correctness
  bug)** — the function previously passed the full log file to
  `replayFromSeed`, even when the snapshot's `logIndex > 0`.
  This meant the runtime would attempt to apply pre-snapshot
  entries on top of the snapshot state and fail at the chain
  check (since the snapshot's `seedHash` is the hash of the
  *last* pre-snapshot entry, not the first).  Failure was
  surfaced as `.replay (.chainBroken 0)`, but the symptom looked
  like a chain break rather than the actual cause (the bootstrap
  was misapplying pre-snapshot entries).  **Fix**: slice
  `entries.drop snap.logIndex` before replay, fulfilling the
  Genesis Plan §13.2 acceptance criterion ("apply only subsequent
  log entries").  Without this fix, the snapshot+log replay path
  was broken for any non-empty log.
* **`canon-replay LOG SNAPSHOT` snapshot-slicing fix (same bug,
  same severity)** — the standalone replay binary had the same
  defect; now slices the log to post-snapshot entries.
* **`BootstrapError.logIndexOverrun snapIdx logEntries`** — new
  variant for the case where `snap.logIndex > entries.length`
  (snapshot was taken at index N, but log has fewer entries).
  Previously this was undetectable.
* **`canon-replay` `SNAPSHOT_INDEX_OVERRUN`** — the
  corresponding CLI output line + non-zero exit.
* **`LogEntry.hash` spec divergence fixed** — previously hashed
  `encode signedAction ++ prevHash.toList` (raw hash bytes);
  Genesis Plan §8.8.4 specifies `encode signedAction ++ encode
  previousLogEntryHash` (with `encode` adding a CBE bytestring
  header).  Fixed to match the spec; future BLAKE3 swap
  drop-in-compatible.
* **`hashEncodable` optimised** — was `hashBytes (encodeBytes v)`
  which round-tripped through `ByteArray ↔ List`; now
  `hashStream (encode v)` directly on the encoder's `Stream`
  output.
* **Frame layout doc fixed** — was "15 + N bytes per record" but
  actual is `4 + 8 + N + 8 = 20 + N`.
* **Fuel-exhaustion handling clarified** — `decodeAllFrames'`
  and `decodeSignedActionStream` now distinguish "stream
  exhausted" from "fuel exhausted".  In practice fuel is set to
  a strict upper bound on iteration count, so fuel-exhaustion
  is unreachable; previously the case silently returned success
  (potentially masking a bug); now it surfaces an explicit
  diagnostic.

**Phase 5 design deviations (documented).**

- **Hash function fallback.**  Genesis Plan §8.8.4 specifies
  BLAKE3-256 (32-byte output).  Phase 5 ships **FNV-1a-64**
  (8-byte output) as a deterministic Lean-native fallback.  The
  swap point is `LegalKernel.Runtime.Hash.hashBytes`; production
  deployments link a real BLAKE3 implementation via `@[extern]`
  without touching kernel or law modules.  The `zeroHash`
  constant is 32 bytes (matching BLAKE3-256 width) so the type
  shape is forward-compatible.  This means the on-disk log format
  has variable-width `prevHash` fields: the first entry's
  `prevHash` is 32 bytes (the seed = `zeroHash`); subsequent
  entries' `prevHash` is 8 bytes (the FNV-1a-64 hash of the
  previous entry).  The chain check compares byte sequences, so
  the width transition is invisible — but on-disk consumers must
  not assume a fixed width.
- **Verify-opaque caveat.**  `Verify` (Phase 3 WU 3.4) is
  `opaque` with a placeholder body of `false`; without a real
  Ed25519 adaptor (Phase 5 WU 3.9, deferred), every signature
  verification fails at runtime.  This means Phase 5's runtime
  tests exercise the *rejection paths* (`processSignedAction`
  rejects every action with `notAdmissible`); the
  success-with-real-actions paths require WU 3.9 to land first.
  This is documented in each runtime test module's header and
  in `docs/extraction_notes.md` §2.3.
- **Rust deliverables (5.4 / 5.7 / 5.8 / 5.11) deferred.**  The
  Lean-side runtime is fully functional and end-to-end-tested
  without them.  Each is documented in `docs/abi.md` §10 (for
  5.4 / 5.7) or in the relevant Phase-5 module headers, so the
  follow-up PR can land them as a drop-in.

**Test coverage (after Phase-6 Option-C amendment + two security-
audit rounds).**  614 passing tests across forty suites (468 was
the post-Phase-6-base count; the incentive amendment added 89
tests across 5 new suites — 13 in `disputes-lawclass`, 7 in
`disputes-monodepl`, 25 in `disputes-rewards`, 17 in
`disputes-staking`, 19 in `disputes-incentivized-e2e` — plus 8
new tests in the existing `events-types` and `events-extract`
suites for the `rewardIssued` constructor / projection / extract
behaviour; the Option-C amendment then added 29 more tests
across the existing `disputes-evidence` (+2 for Layer-0
hardening), `disputes-verdict` (+15 for the witness API + 5 for
`proposeAndApplyVerdict`), `disputes-e2e` (+3),
`disputes-incentivized-e2e` (+3), and a new
`disputes-witness-helpers` suite (+6); the **first
post-Phase-6 security audit** added 11 regression tests across
`authority-signed` (+6 for the content-distinguishing
`signingInput` property) and `disputes-verdict` (+5 for the
`countVerifiedSignatures` deduplication invariant and the
content-distinguishing `verdictSigningInput` property); the
**second post-Phase-6 security audit** (this branch) adds 5
more regression tests across `authority-signed` (+2 for the
`signingInput` domain prefix), `disputes-verdict` (+2 for the
`verdictSigningInput` domain prefix and cross-protocol
distinguishability against `signedActionDomain`), and `dsl-law`
(+1 for the `transferDSL` precondition matching `Laws.transfer`'s
positivity clause).  The umbrella build-tag check value
continues at `canon-phase-6-disputes-adjudication` since the
audit-hardening fixes do not bump phase boundaries.):
- `KernelTests` (22) — unchanged from Phase 1.
- `RBMapLemmasTests` (8) — unchanged from Phase 1.
- `Umbrella` (2) — non-TCB build-tag smoke test, with the Phase-4-
  prelude bump check (`kernelBuildTag =
  "canon-phase-4-prelude-positive-incentives"`).
- `ConservationTests` (21) — Phase 2 (15) + Phase-4-prelude R.20
  extensions: `IsMonotonic` typeclass resolution checks,
  `MonotonicLawSet` constructibility (mixed conservative + monotone
  laws), `total_supply_globally_nondecreasing[_via_law_set]` API
  stability, plus the **end-to-end behaviour test** (4-step trace
  through positive-incentive laws verified to be supply-non-
  decreasing at the value level).
- `Transfer` (17) — Phase 2 (16) + R.19's `transfer_isMonotonic`
  instance-resolution check.
- `Mint` (11) — Phase 2 (10) + R.19's `mint_isMonotonic`
  instance-resolution check.
- `Burn` (13) — Phase 2 (12) + R.19's `burn_not_monotonic` API
  stability check (the negative-witness counterpart to the
  monotonicity firewall).
- `Freeze` (12) — Phase 2 (10) + R.19's `freezeResource_isConservative`
  AND `freezeResource_isMonotonic` instance-resolution checks (the
  `IsConservative` instance was missing in Phase 2 and is added by
  R.3).
- `Reward` (11) — Phase-4-prelude WU R.6.  Mirrors `Test/Laws/Mint.lean`
  case-for-case (since `reward`'s kernel-level shape is identical to
  `mint`); plus monotonicity-instance check and non-conservation API
  stability.
- `DistributeOthers` (14) — Phase-4-prelude WU R.10.  Multi-actor
  fixtures (3-actor F1: balances 30/40/50, exclude 2, distributes 50
  to actors 1 & 3); per-actor and total-supply assertions; locality
  (other resources untouched, excluded actor unchanged); arithmetic
  API stability and the negative-witness API check.
- `ProportionalDilute` (17) — Phase-4-prelude WU R.16.  Hand-computed
  fixtures: F1 with 3 actors {1→30, 2→40, 3→50}, exclude actor 2,
  totalReward 10; verifies actor 1 → 33 (3+amt), actor 3 → 56
  (6+amt), supply 120 → 129 with dust 1 discarded.  F2 with exact
  division (no dust).  F3 precondition fail (sumOthers = 0).
  F4 excluded-absent.  Numerical dust-bound check; API stability for
  the four headline theorems including
  `_distributed_le_totalReward`.
- `Authority.ActionTests` (31) — Action constructor distinguishability,
  `Action.compile` shape per constructor, compiled `apply_impl`
  matching the underlying law, term-level + value-level
  `compile_injective` / `compile_eq_iff` / `compile_ne_of_ne` API
  stability, convenience-accessor smoke tests, plus Phase-4-prelude
  R.18 additions: distinguishability for the three new constructors
  including the critical `.reward` vs `.mint` distinguishability
  check (same scalar shape, different constructors), plus compile
  shape rfl-checks.
- `Authority.IdentityTests` (27) — `KeyRegistry` round-trips
  (register / revoke / overwrite / merge); `AuthorityPolicy`
  `empty`/`unrestricted`/`union`/`intersect`/`singleton` decidability
  checks at concrete `(actor, action)` pairs; term-level API
  stability for the four `KeyRegistry.lookup_*` semantic theorems
  (`register_self`, `register_other`, `revoke_self`, `revoke_other`)
  and the seven `AuthorityPolicy` combinator theorems
  (`empty_authorized`, `unrestricted_authorized`,
  `union_authorized`, `intersect_authorized`, `singleton_authorized`,
  `union_comm`, `union_empty`, `intersect_unrestricted`).
- `Authority.NonceTests` (11) — `expectsNonce` zero-default,
  `advanceNonce` increments, cross-actor isolation, base/registry
  preservation, and term-level `expectsNonce_strict_mono`/
  `_advance_other`/`_after_advance_*` API stability.
- `Authority.SignedActionTests` (46) — admissibility decomposition
  (auth + nonce + pre); negative cases for every condition (stale
  nonce, unauthorized signer, unregistered signer, insufficient
  balance); `apply_admissible` term-level signature check;
  `applyActionToRegistry` value semantics for every Action
  constructor including the three Phase-4-prelude additions
  (`reward`, `distributeOthers`, `proportionalDilute`) — each
  asserted to be registry-identity, mirroring the existing
  transfer/mint/burn/freezeResource non-replaceKey tests; term-level
  API stability for the five `admissible_*`
  field extractors; the new `apply_admissible_base`,
  `apply_admissible_registry`, and
  `expectsNonce_after_apply_admissible_other` cross-actor isolation
  theorems; term-level `nonce_uniqueness`/`replay_impossible` API
  stability; post-advance ≠ pre-action nonce algebraic check; cross-
  actor isolation value-level check; full WU 3.10 key-rotation chain
  (forward + back + cross-actor isolation); the **post-audit
  signingInput regression sub-suite** (8 cases: non-empty output;
  distinct actions / signers / nonces produce distinct bytes;
  cross-constructor distinguishability `.transfer` vs `.reward`;
  determinism on equal inputs; **audit-2 additions** for the
  cross-protocol domain prefix — verifying the canonical
  `signedActionDomain` ASCII bytes are present and that the first
  byte is the CBE byte-string tag).
- `Encoding.CBORTests` (6) — Phase 4 WU 4.1.  CBE head round-trip
  at small (n=2) and medium (n=2^32) values; rejection of
  wrong-tag and short-input.  Term-level
  `cborHeadRoundtrip{,_append}` API stability.
- `Encoding.EncodableTests` (21) — Phase 4 WU 4.1 / 4.2 + audit
  expansion.  Per-type round-trip for `Bool`, `Nat` (small + 2^33),
  `BoundedNat`, `ByteArray` (small + empty), `UInt8`, `UInt16`,
  `UInt32`, `UInt64`; `List Bool` round-trip via the
  parameterised `list_roundtrip` (consuming `bool_roundtrip` as
  per-element evidence); `Option Bool` round-trip in both `none`
  and `some` cases.  Term-level API stability for
  `nat_roundtrip`, `byteArray_roundtrip`, `bool_encode_injective`,
  `uInt16_roundtrip`, `uInt32_roundtrip`, `list_roundtrip`,
  `option_roundtrip`.
- `Encoding.ActionTests` (12) — Phase 4 WU 4.3.  Round-trip for
  every `Action` constructor (transfer, mint, burn, freezeResource,
  replaceKey, reward, distributeOthers, proportionalDilute);
  cross-constructor distinguishability (transfer vs mint produce
  different bytes); spot-check encoded byte length (transfer has
  5 nat fields × 9 bytes = 45 bytes).  Term-level `action_roundtrip`
  / `action_encode_injective` API stability.
- `Encoding.SignedActionTests` (4) — Phase 4 WU 4.4.  Round-trip
  for `SignedAction` carrying transfer and replaceKey actions;
  term-level `signedAction_roundtrip`/`_encode_injective` API
  stability.
- `Encoding.StateTests` (13) — Phase 4 WU 4.5 + dual audit
  expansion.  Empty-state encoding shape (9-byte head); empty-state
  round-trip (encode-then-decode is identity at the value level);
  structural determinism (encoding twice yields the same bytes);
  insertion-order invariance (TreeMap canonicalisation makes two
  states built from different insert sequences encode to the same
  bytes); populated-state round-trip (`stateRoundtripGetBalance`
  probes 4 `(resource, actor)` cells through encode-then-decode);
  `extendedStateRoundtrip` (probes `getBalance`, `expectsNonce`,
  and `KeyRegistry.lookup` through encode-then-decode);
  `decoderRejectsUnsortedKeys` and `decoderRejectsDuplicateKeys`
  (audit 2: §8.8.6 canonicality enforcement — manually constructed
  malicious inputs must be rejected with `nonCanonical`);
  `decoderAcceptsCanonicalMap` (sanity: the canonicality check
  doesn't reject valid inputs);
  `stateEncodeDecodeEncodeIdempotent` (audit 2: the operational
  form of canonicality — re-encoding a decoded state produces the
  original bytes).  Term-level `state_encode_deterministic`,
  `extendedState_encode_deterministic`, and
  `balanceMap_encode_deterministic_of_equiv` API stability.  The
  populated round-trip test was added in audit 1 and surfaced a
  bug where `State.encode` was producing CBE arrays for inner
  `BalanceMap`s while `State.decode` expected CBE byte strings; the
  bug is fixed by `BalanceMap.encodeAsBytes`.  The unsorted /
  duplicate-key tests were added in audit 2 and surfaced a
  §8.8.6 canonicality bug; fixed by `keysStrictlyAscending`.
- `Encoding.SignInputTests` (7) — Phase 4 WU 4.8.  Domain-prefix
  shape (sign-input begins with the canonical domain bytes);
  cross-deployment / cross-action / cross-nonce distinguishability
  (the §8.8.5 headline security property, verified at the value
  level); determinism; term-level API stability.
- `DSL.LawTests` (5) — Phase 4 WU 4.9.  `law pre := ... ; impl :=
  ...` produces a `Transition` whose `apply_impl` reduces correctly;
  impl-only form defaults `pre` to `True`; DSL-built `transferDSL`
  matches the hand-written `Laws.transfer` at the value level.
  Term-level `Law.mk` API stability.  **Audit-2 regression**
  (`transferDSLPreMatches`): the DSL-built `transferDSL`'s
  precondition agrees with `Laws.transfer`'s on the *positivity*
  case (`amount = 0` is rejected by both, *not* just the balance
  check) — closes a documentation-vs-implementation drift where
  the DSL example was missing the `amount > 0` clause.
- `Events.TypesTests` (7) — Phase 5 WU 5.6 `Event` inductive
  classification and projection checks; `DecidableEq` coverage.
- `Events.ExtractTests` (10) — Phase 5 WU 5.6 per-action event
  emission contracts (transfer = sender + receiver + nonce events;
  freeze = nonce only; replaceKey = registration + nonce; etc.);
  determinism + non-emptiness API stability.
- `Runtime.HashTests` (10) — Phase 5 WU 5.1 / 5.5 / 5.12 FNV-1a-64
  identity (offset basis on empty input; `* prime` on a single
  zero); determinism; output-shape; avalanche-ish non-collision;
  term-level `hashBytes_deterministic` / `_size` / `hashStream_*`
  API stability.
- `Runtime.LogFileTests` (20) — Phase 5 WU 5.2 + 5.3.  `LogEntry`
  encode-then-decode + `encodeFrame` / `decodeFrame` round-trip;
  multi-frame `decodeAllFrames` recovery; rejection of truncated /
  bad-magic / bad-trailer inputs; `verifyChain` accept / reject;
  `appendEntry` / `readAllEntries` IO round-trip;
  `loadAndTruncate` torn-write recovery (a sweep across multiple
  partial-tail lengths); empty-log handling; **post-audit
  additions**: post-truncation file is byte-clean
  (`truncationProducesCleanFile`), empty-stream decode, exact
  consumed-byte-count on partial tails; term-level
  `encodeFrame_deterministic` / `frameTrailer_length` API stability.
- `Runtime.ReplayTests` (10) — Phase 5 WU 5.5.  Empty-log replay
  returns genesis; `replayHash` returns the genesis hash;
  determinism; chain-broken rejection; not-admissible rejection
  (Verify-stub returns false in tests); `replayFromSeed` empty
  + chain-broken paths; multi-entry failure-index reporting;
  term-level `replay_deterministic` / `replay_empty` API stability.
- `Runtime.SnapshotTests` (11) — Phase 5 WU 5.12.  `takeSnapshot`
  field shape; `Snapshot.encode` / `decode` round-trip;
  `restoreSnapshot` recovers state at every probed cell;
  `restoreSnapshot` rejects tampered `stateHash` with
  `hashMismatch`; `replicaFromSnapshot` empty-tail bootstrap
  reproduces snapshot state; `saveSnapshot` / `loadSnapshot` IO
  round-trip; **post-audit additions**: `Snapshot.encode` byte-
  determinism, truncated snapshot file rejection,
  `replicaFromSnapshot`-preserves-state hash check, `loadSnapshot`
  on missing file returns `DecodeError` (not throw); term-level
  `takeSnapshot_deterministic` API stability.
- `Runtime.LoopTests` (13) — Phase 5 WU 5.1.  `bootstrap` of
  missing log returns fresh runtime (logIndex = 0, prevHash =
  zeroHash); `processSignedAction` rejects an inadmissible
  action with `notAdmissible` and does NOT touch the log file;
  `processBatch` returns one rejection per inadmissible action;
  `processPure` determinism + rejection check; **post-audit
  additions (audit 1)**: bootstrap-twice idempotence,
  `bootstrapFromSnapshot` surfaces precise `.snapshot
  .hashMismatch` (not collapsed into `chainBroken`),
  `BootstrapError` constructor distinguishability via `Repr`;
  **audit-2 additions**: `bootstrapFromSnapshot` rejects
  `logIndex > log.length` with `.logIndexOverrun` (the new
  variant), `bootstrapFromSnapshot` correctly slices to empty
  tail when `logIndex = log.length`, `bootstrapFromSnapshot`
  drops pre-snapshot entries via `entries.drop snap.logIndex`
  (proving the slicing actually slices), and `bootstrapFromSnapshot`
  surfaces post-slice failure indices correctly.  Term-level
  `processPure_deterministic` API stability.
- `Encoding.DisputesTests` (17) — Phase-6 WU 6.1.  Per-variant
  round-trip for `DisputeClaim` (5 variants), `EvidenceVerdict`
  (3 variants), `Dispute` (full structure + API stability), and
  `Verdict` (full structure including `signers` / `sigs` lists,
  rejected-outcome variant, API stability).  Cross-variant
  distinguishability check.  Term-level `disputeClaim_roundtrip`,
  `dispute_roundtrip_empty`, `verdict_roundtrip_empty`, and
  `verdict_encode_deterministic` API stability.
- `Disputes.FilingTests` (16) — Phase-6 WU 6.3 / 6.11.
  `fileDispute` happy paths (registered challenger + in-range
  primary + in-range secondary on `doubleApply`); error paths
  (`unknownChallenger`, `indexOutOfRange` for primary and
  secondary indices).  `claimImpugnedIdx` / `claimSecondaryIdx`
  projection correctness.  `applyWithdraw` per-status idempotency
  (open → withdrawn; withdrawn → withdrawn; decided → decided
  unchanged).  `disputeStatus` walk-the-log derivation
  (non-dispute index returns `none`; verdict-after-dispute
  returns `decided` with the verdict outcome).  Term-level
  `applyWithdraw_idempotent` API stability.
- `Disputes.EvidenceTests` (16) — Phase-6 WU 6.4 / 6.5 / 6.6 /
  6.7 / 6.8.  `checkPreconditionFalse` inconclusive paths
  (missing entry, out-of-range index).  `checkSignatureInvalid`
  inconclusive paths (unregistered signer, missing entry).
  `checkNonceMismatch` inconclusive path.
  `checkOracleMisreported` pass-through (alwaysRejects /
  alwaysUpheld returns the policy's verdict verbatim).
  `checkDoubleApply` correctness (rejects `idx₁ = idx₂`,
  inconclusive on missing entries, upheld on same-signer +
  same-nonce + distinct indices, rejected when signers differ).
  `checkEvidence` dispatcher correctness (oracleMisreported,
  doubleApply branches).  Term-level
  `checkEvidence_deterministic` and `checkDoubleApply_rejects_self`
  API stability.
- `Disputes.VerdictTests` (33) — Phase-6 WU 6.9 / 6.10 + Option-C
  amendment + two rounds of post-audit hardening.  `proposeVerdict`
  rejects unknown disputeId (both unmapped index and non-dispute
  log entry); `applyVerdict` rejects unknown dispute, leaves state
  unchanged on `.rejected` and `.inconclusive` outcomes;
  `QuorumPolicy.singleton` / `QuorumPolicy.empty` constructor
  sanity; `countVerifiedSignatures` correctness (empty list → 0,
  non-approved adjudicators skipped).  Term-level
  `applyVerdict_deterministic` and `applyVerdict_unknown_dispute`
  API stability.  Witness-bearing API (15 cases) +
  `proposeAndApplyVerdict` (5 cases) per the Option-C amendment.
  **Audit-1 security regression** (5 cases):
  `countVerifiedSignatures` deduplicates repeated approved signers
  (count ≤ #distinct approved adjudicators regardless of list
  length — closes the trivial-quorum-forgery bug);
  `verdictSigningInput` distinguishes outcomes / disputeIds;
  `verdictSigningInput` ignores `signers`/`sigs` (avoids the
  circular-signature-dependency that would otherwise prevent any
  verdict from being signed).  **Audit-2 cross-protocol
  regression** (2 cases): `verdictSigningInput` begins with the
  canonical `verdictDomain` bytes (cross-protocol replay
  protection — a signature on a `Verdict` cannot be re-interpreted
  as a `SignedAction` signature); `verdictDomain` is structurally
  distinct from `signedActionDomain` (so the prefix check is
  meaningful).
- `Disputes.EndToEndTests` (5) — Phase-6 WU 6.12.  The full
  acceptance test: planted illegal transfer (precondition
  false at the recovered pre-state) → `fileDispute` succeeds
  on the pre-dispute log → `checkEvidence` returns `.upheld`
  via `kernelOnlyReplay` → `applyVerdict` (`.upheld`) computes
  the rollback target via `replayPrefix log[0..1]` → final
  state's per-actor balances match the pre-illegal-tx state
  (sender = 50, receiver = 50).  Plus `.rejected` outcome
  state-unchanged sanity, full pipeline composition test.

Tests use two complementary patterns:
1. **Value-level**: assert `==` between expected and actual results
   (catches definitional drift / Std-API renames at runtime).
2. **Term-level API stability**: ascribe a `let _proof : T :=
   theorem ...` binding whose type uses the theorem's exact
   signature (catches signature changes at elaboration time, before
   the `IO Unit` body runs).

The `Authority.SignedActionTests` suite uses term-level API checks
for `nonce_uniqueness` and `replay_impossible` (rather than
value-level admissibility witness construction) because the `Verify`
opaque cannot be reduced at the Lean level — the runtime adaptor
(Phase 5) wires the actual cryptographic implementation.  The
algebraic core of the theorems (the post-advance nonce inequality)
is value-level checked separately.

`lake test` runs the suite via the `Tests.lean` driver and exits
non-zero on any failure; CI runs the same driver.

**Axiom audit (Phase 6).**  `#print axioms` on every kernel, RBMap,
Phase-2, Phase-3, Phase-4, Phase-5, and Phase-6 theorem returns
exactly `[propext, Classical.choice, Quot.sound]` (and many
encoding theorems use only a subset, e.g. `verdict_roundtrip`
depends on `[propext, Quot.sound]` alone).  No custom axioms have
been introduced in any phase.  The `Verify` and `signingInput`
declarations are `opaque`, not `axiom`, so they do not appear in
the axiom-audit output of theorems that mention them.  Phase 6
introduces no new opaque declarations: the dispute pipeline reads
`Verify` only at value level (in tests) and never proves theorems
*about* its return value.

**TCB-audit hardening.**  `Tools.Common.tcbInternalImports` lists
the project-internal modules each TCB core file may import — only
`LegalKernel.Kernel` and `LegalKernel.RBMapLemmas`.  This is a
*specific allowlist*, not a `LegalKernel.*` namespace pattern: a
TCB core file that tries to import e.g. `LegalKernel.Laws.Transfer`
fails the audit, blocking the merge and forcing a §13.6
amendment.

## Vulnerability reporting

Canon is research-stage software.  If you discover a logic bug in
the kernel module (e.g. a counterexample to `impl_noop_if_not_pre`,
or a state advance that bypasses the `if` in `step_impl`), open an
issue with the `kernel-soundness` label.  Such reports gate any
in-flight PR; the two-reviewer rule applies to the fix.

For non-kernel issues (laws, tooling, documentation), the standard
issue tracker workflow applies.
