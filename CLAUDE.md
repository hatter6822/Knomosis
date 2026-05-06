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
lake build canon                              # Phase-5 `canon` runtime CLI
lake build canon-replay                       # Phase-5 `canon-replay` audit binary
lake test                           # run Tests.lean driver (664 tests post-Audit-3)
lake exe count_sorries              # WU 1.12: zero-sorry kernel gate
lake exe tcb_audit                  # WU 1.11: TCB allowlist gate
lake exe stub_audit                 # Audit-3.8: stub-detection gate

# Phase-5 runtime smoke test (single-shot demo of the binary):
.lake/build/bin/canon info
.lake/build/bin/canon bootstrap /tmp/test.log
.lake/build/bin/canon-replay /tmp/test.log
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
│   │   └── ProportionalDilute.lean -- Phase-4-prelude WU R.12 / R.13 /
│   │                                  R.14 / R.15: proportional reward
│   │                                  (Nat floor, dust discarded) with
│   │                                  the dust-bound theorem.
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
│   │   │                             registry), expectsNonce,
│   │   │                             advanceNonce,
│   │   │                             expectsNonce_strict_mono (non-TCB).
│   │   └── SignedAction.lean      -- Phase-3 WU 3.6 / 3.7 / 3.8 / 3.10:
│   │                                 SignedAction, Admissible (5
│   │                                 conditions), apply_admissible
│   │                                 (single guarded entry point),
│   │                                 nonce_uniqueness, replay_impossible,
│   │                                 replaceKey registry-mutation
│   │                                 theorems (non-TCB).
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
│   │   └── Law.lean                -- Phase-4 WU 4.9: Law.mk combinator
│   │                                 + `law pre := <expr> ; impl :=
│   │                                 <expr>` macro; auto-fills decPre :=
│   │                                 fun _ => inferInstance.
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
│       │   ├── Nonce.lean         -- Phase-3 nonce ledger tests (11 cases).
│       │   └── SignedAction.lean  -- Phase-3 admissibility / replay /
│       │                             key-rotation tests (17 cases).
│       ├── Encoding/
│       │   ├── CBOR.lean          -- Phase-4 CBE codec tests (6 cases).
│       │   ├── Encodable.lean     -- primitive-instance roundtrip tests
│       │   │                         (12 cases).
│       │   ├── Action.lean        -- Action encoder roundtrip tests
│       │   │                         (12 cases).
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
├── Tools/
│   ├── Common.lean                -- shared TCB constants + readFileSafe.
│   ├── TcbAudit.lean              -- WU 1.11 TCB allowlist enforcer.
│   └── CountSorries.lean          -- WU 1.12 sorry-counting CI gate.
├── scripts/
│   └── setup.sh                   -- SHA-256-verified toolchain installer.
├── .github/workflows/
│   └── ci.yml                     -- lake build + test + count_sorries +
│                                     tcb_audit on PR / push.
├── CLAUDE.md                      -- this file.
├── README.md                      -- project entry point.
└── docs/
    ├── GENESIS_PLAN.md            -- canonical design document.
    ├── decidability_discipline.md -- WU 1.6 (decPre) discipline.
    ├── std_dependencies.md        -- WU 1.13 Std lemma audit.
    ├── economic_invariants.md     -- Phase 2 design + Phase-4-prelude
    │                                 monotonicity tier section.
    ├── extraction_notes.md        -- Phase 5 WU 5.9: erasure / persistence
    │                                 map for the `canon` runtime binary.
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
    must describe *what the declaration is or proves*, never *which
    work unit, audit, phase, or session produced it*.  Forbidden
    tokens in declaration names include, non-exhaustively:
    - work-unit labels: `wu`, `wu1`, `wu_2_5`, `phase`, `phase0`
    - audit / finding ids: `audit`, `finding`, `f02`, `cve`
    - session / branch references: `claude_`, `session_`, `pr23`
    - temporal markers: `old`, `new`, `v2`, `legacy`, `tmp`, `todo`,
      `fixme`
    Process markers may appear in *docstrings* (a `/-- ... -/`
    block can say "added in WU 2.5") and in commit messages, branch
    names, and planning documents.  The boundary is sharp: the
    docstring may carry a process tag, the identifier may not.
  - **Enforcement.**  Before landing any new declaration, scan the
    diff:
    ```bash
    git diff --cached -U0 -- '*.lean' \
      | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
      | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit|\bf[0-9]{2}\b|\btmp\b|\btodo\b|\bfixme\b|claude_|session_'
    ```
    A non-empty result is a review-blocking naming violation.

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

The "Phase / File" `R` markers identify the Phase-4-prelude
positive-incentive WUs (`R.1` – `R.23`); they precede Phase 4 (DSL and
Serialisation) in the implementation roadmap.

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
| 7      | Advanced capabilities              | 7.x                      | Not started |

Read the Genesis Plan's per-phase work-unit breakdown before
starting any new work.  Each work unit has explicit deliverables,
acceptance criteria, and dependencies.

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
complete; Phase 7 (Advanced Capabilities) is the next scoped phase
but is open-ended and per-WU chartered.

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
