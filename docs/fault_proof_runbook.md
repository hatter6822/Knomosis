<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis Fault-Proof Operator Runbook

This document is the operator-facing companion to
`docs/planning/fault_proof_migration_plan.md` (engineering plan) and
`docs/fault_proof_design.md` (design rationale).  It covers
deployment, monitoring, and incident response for the
Workstream-H fault-proof migration.

---

## 0. The terminal step adjudicates — what changed, and the residue

**This section used to be a deployment blocker.**  It read: do not
deploy this system as an adjudicating backstop, because the bisection
narrowing works and the step that decides the winner does not.
`terminateOnSingleStep` fed `g.low.commit` — a state root — to
`KnomosisStepVM.executeStep`, whose own header stated that its output
"is NOT byte-identical to" a `commitExtendedState` value, and compared
the result to `g.high.commit`, another state root.  Two different
constructions, so the comparison never succeeded: **an honest sequencer
lost every game it correctly defended.**

The 278-entry cross-stack corpus could not report it and never could.
It pinned Lean's `stepVMHash` against Solidity's `executeStep` — two
implementations of the SAME bespoke recipe.  They agreed on all 278
entries; agreement between them said nothing about whether either
equalled a published state root, which is the only property the game
needs.  That column and its driver are gone, along with the recipe.

**It is closed.**  `terminateOnSingleStep` calls
`KnomosisStepVMRoot.executeStepToRootMulti`, which returns a post-state
ROOT computed by folding the step's DERIVED cell writes into
`g.low.commit`.  It derives both halves rather than accepting them —
the cell list from `StepWrites.deriveWriteSet`, whose frontier is
checked against the submitted one as a SET so a responder cannot omit
a write, and each cell's value from `StepWrites` / `StepPlan`, which
are `productionApplyBudget` re-expressed cell-locally.  Every
derivation EVALUATES its law's precondition and returns the pre-values
when it fails, so a failing precondition is a no-op rather than a
revert — a revert would not be a verdict, since the terminal step is
callable only by whoever's turn it is.

**What a responding party submits** is a deduplicating pre-root
multiproof: the step's frontier (every cell it touches, with that
cell's proven pre-value) plus ONE shared sibling list.  Four operator-
visible consequences.  The bundle's ORDER does not matter — the
verifier sorts, so a terminate cannot fail on a formatting question.
A cell the step writes twice (a self-transfer) is opened once, so the
responsible party is not charged for a redundant walk.  The wire's
length is fixed by the cell set, so a truncated proof reverts with a
named error rather than being padded out and walked to a wrong root.
And the read-only budget-policy cell rides IN the frontier — there is
no separate policy opening to forget.  `knomosis
export-terminate-bundle` emits exactly this shape (`opened_cells`,
`gap_mask_hex`, `siblings_hex`) and the observer forwards it.

The evidence is a corpus column on both stacks: `multiProofGoldens`
carries, per probe, the pre-root, the action, the frontier, the wire,
and TWO independently-computed post-roots — the one the fold reaches
and the one `commitExtendedState (productionApplyBudget …)` gives from
the post-STATE.  Both the L1 verifier
(`CrossCheck/StepVMRootMulti.t.sol`) and the Lean one
(`FaultProof/Terminate.lean`) reach it, and the corpus asserts the two
numbers coincide — which is more than agreeing with another verifier.
The game's own honest-sequencer-wins test is driven by that probe
rather than by hand-built values: with a real fold, a fabricated `low`
has no wire that reproduces it, so the honest path is only reachable
from a real one.

**Operator obligation, in force: do not authorise the bulk laws.**  A
deployment leaning on the fault proof must not permit
`distributeOthers` / `proportionalDilute` in its `AuthorityPolicy`.  A
verifier cannot tell a complete recipient set from one missing an entry
— the missing cell's opening is simply absent, the short bundle folds,
and the resulting root is one where that recipient was never credited,
which the sequencer that published it can then successfully defend.
The two laws remain available to deployments using the
adjudicator-quorum backstop.  `FaultProof.FaultProofAdjudicable` is the
predicate; it is false on exactly those two, mirrored by
`StepWrites.isAdjudicable` and pinned per kind across all twenty-five
variants by the corpus's `adjudicable` column.  The contract refuses
them before verifying any opening.

**The old recipe is gone.**  `KnomosisStepVM.sol`,
`SolidityStepVMCommit.lean`, `stepVMHash` / `stepVMHashFromAction` and
the 37 theorems pinning their per-variant arms were deleted once
nothing referenced them.  What survives from that surface is the L1
FIELD LAYOUT — `actionKindByte`, `actionFieldsForL1`, the big-endian
encoders and the log-entry chain's `l1ActionCommit` — which the
root-computing step VM reads unchanged.  The Lean MODEL of the
terminal step (`Step.kernelStepApply`) routes through the verifier, so
it computes what the contract computes.

---

## 1. Pre-deployment checklist

Before deploying the Workstream-H contracts:

  - [ ] **§0 read and accepted.**  In particular: the deployment's
        `AuthorityPolicy` must not authorise `distributeOthers` /
        `proportionalDilute`, which the fault proof cannot adjudicate.
  - [ ] **Lean side green**: `lake build`, `lake test`,
        `lake exe count_sorries`, `lake exe tcb_audit`,
        `lake exe stub_audit`, `lake exe lex_lint`,
        `lake exe lex_codegen --check`.
  - [ ] **Solidity side green**: `cd solidity && forge build`,
        `cd solidity && forge test`.
  - [ ] **Cross-stack fixtures regenerated**:
        `KNOMOSIS_FIXTURES_OVERWRITE=1 lake test` (writes
        `step_vm.json`, `bisection_game.json`,
        `fault_proof_scenarios.json` under
        `solidity/test/CrossCheck/fixtures/`).
  - [ ] **Bond constants reviewed**:
    - `STATE_ROOT_SUBMISSION_BOND` ≥ 1% of value-at-risk per
      state-root window (recommended 1 ETH for ≤ 100 ETH VAR;
      10 ETH for ≥ 1B TVL).
    - `MIN_CHALLENGE_BOND = 0.05 ETH` is the default; tune up
      for high-stakes deployments.
  - [ ] **Dispute window**: 30 days default
        (`FAULT_PROOF_DISPUTE_WINDOW = 216_000` blocks at
        12 s/block).  Shorter (e.g. 7 days = 50_400 blocks)
        trades faster finality for less detection time.
  - [ ] **Sequencer set**: single-sequencer per Workstream-E
        baseline (multi-sequencer is OQ3, deferred).
  - [ ] **Treasury address**: receives the 5% bond
        redistribution under the 95/5 split.
  - [ ] **L1 watcher binding**: production keccak256 +
        ECDSA bindings linked
        (`Bridge.HashAdaptor.isKeccak256Linked = true`).

## 2. Deployment sequence

The five Workstream-H contracts must be deployed in dependency
order via CREATE3 (the Lean-side
`solidity/script/DeployFaultProof.s.sol` script handles this
automatically):

  1. `KnomosisStepVM` — pure logic, no dependencies.
  2. `KnomosisStateRootSubmission` — depends on the (predicted)
     fault-proof game address.
  3. `KnomosisFaultProofGame` — depends on the deployed step VM
     address + the (predicted) state-root submission address.
  4. `KnomosisDisputeVerifierV2` — depends on the deployed
     fault-proof game address.
  5. `KnomosisFaultProofMigration` — depends on the V1 contracts
     (the predecessors) being pre-committed via their
     `migration` immutable.

After deployment, run the per-contract `assertConsistent()`
view to verify deploy-time invariants:

```solidity
stepVM.assertConsistent();
stateRootSubmission.assertConsistent();
faultProofGame.assertConsistent();
disputeVerifier.assertConsistent();
faultProofMigration.assertConsistent();
```

All five must succeed (no revert).

## 3. Operational monitoring

### 3.1 State-root submission monitoring

**Sequencer obligation: bind the action.**
`submitStateRoot(logIndex, stateCommit, prevLogEntryHash, actionCommit)`
takes a fourth argument, and getting it wrong is a *liveness* failure
for the sequencer rather than a submission-time error — the contract
folds the value into the chain without interpreting it, so a wrong
`actionCommit` is accepted at publish time and surfaces only when the
root is challenged, at which point every honest
`terminateOnSingleStep` reverts `ActionNotInLogChain` and the sequencer
loses by timeout.

Compute it as
`keccak256(abi.encodePacked(uint8 actionKind, uint64 signer, bytes actionFields))`
over the action that carried `logIndex - 1` to `logIndex` — the same
triple the terminate call passes. Lean's
`LegalKernel.FaultProof.StepVMCoherence.l1ActionCommit` is the
reference implementation, and `step_vm.json`'s
`expectedActionCommitHex` pins the two stacks byte-for-byte, so an
integration can check its own encoder against the corpus before it
publishes anything.

Track the following events from `KnomosisStateRootSubmission`:

| Event | Action |
|-------|--------|
| `StateRootSubmitted` | Watch for unexpected sequencer addresses or wrong-bond submissions (rejected at the contract level). |
| `StateRootFinalised` | Confirm the dispute window has fully elapsed; release sequencer bond. |
| `StateRootRangeReverted` | **Investigate immediately**: dispute upheld; rollback was triggered. Check the corresponding `DisputeUpheldByFaultProof` event. |

Per-sequencer rate-limit metrics:

  * `lastSubmissionBlock[sequencer]` — last submission block
    per sequencer.  Should advance at most once per
    `MIN_SUBMISSION_INTERVAL_BLOCKS` (default 100).
  * `outstandingRootsCount[sequencer]` — number of unfinalised
    submissions per sequencer.  Capped at
    `MAX_OUTSTANDING_ROOTS_PER_SEQUENCER` (default tuned per
    deployment).

### 3.2 Fault-proof game monitoring

Track the following events from `KnomosisFaultProofGame`:

| Event | Action |
|-------|--------|
| `FaultProofGameOpened` | New challenge filed.  Verify the disputed log range and the challenger's bond. |
| `BisectionMidpointSubmitted` | One bisection round.  Verify the midpoint index is in-range. |
| `BisectionResponseSubmitted` | One bisection response.  Track turn alternation. |
| `FaultProofGameSettled` | Game ended.  Check the winner; if challenger, expect `revertStateRootsFrom` on the bridge. |

Per-game state:

  * `games[gameId].turnDeadline` — time of next response
    deadline.  If exceeded with no response, anyone can call
    `claimTimeout(gameId)`.
  * `games[gameId].depth` — bisection depth.  Capped at
    `MAX_BISECTION_DEPTH = 64`.

### 3.3 Off-chain observer

The `runtime/knomosis-faultproof-observer` Rust crate (Workstream
RH-G, complete; see §7 below and §H.10.5 of the workstream plan) is
the recommended production off-chain observer; the Lean-side
`LegalKernel.FaultProof.Observer` reference remains available as a
cross-check.  Run an observer continuously (and at audit cadence,
weekly minimum, as a backstop) to detect:

  * State-root submissions inconsistent with the operator's
    own L2 replay.
  * Dispute-game positions where the operator's view differs
    from on-chain.

When a divergence is detected, the operator should file a
challenge using `KnomosisFaultProofGame.initiateChallenge`.

## 4. Incident response

### 4.1 Sequencer publishes wrong state root

**Symptom**: A state root at log index N differs from the
operator's L2 replay.

**Response**:
  1. Verify the divergence locally: re-replay the L2 log from
     genesis to index N; compare `commitExtendedState` against
     the on-chain `roots[N].stateCommit`.
  2. If divergence confirmed, file a challenge:
     ```solidity
     game.initiateChallenge{value: MIN_CHALLENGE_BOND}(
         N,                          // disputed log index
         challengerCommit,           // your computed commit
         lowCommit,                  // commit at last agreed idx
         lowLogIndex,                // last agreed idx
         disputedStateRoot,          // sequencer's commit
         deploymentId,
         sequencer);
     ```
  3. Watch for `BisectionMidpointSubmitted` events.  Respond
     using `submitMidpoint` or `respondToMidpoint` per turn.
  4. Run the off-chain observer to compute honest moves.
  5. Game settles in challenger's favour ⇒
     `FaultProofGameSettled(ChallengerWon)` emitted ⇒ bridge's
     `revertStateRootsFrom` triggered ⇒ user funds protected.

### 4.2 Sequencer abandoned game (no response within window)

**Symptom**: `turnDeadline` exceeded with no response.

**Response**:
  1. Anyone may call `claimTimeout(gameId)` — typically the
     challenger does this to avoid paying gas in vain.
  2. Game settles as `TimedOutSequencer` ⇒ bridge revert ⇒
     bond redistributed per 95/5 split.

### 4.3 Bug discovered in deployed contracts

**Symptom**: A logic error in `KnomosisStepVM` or another
deployed contract.

**Response**: Use `KnomosisFaultProofMigration` to hand off to a
successor deployment.  Per Workstream-E §20 immutability
discipline, contracts cannot be patched in place; the
predecessor's `migration` immutable points at the new
migration contract, which after the 30-day grace window
freezes the predecessor and routes new state-root submissions
to the successor.

### 4.4 Cross-deployment replay attack attempt

**Symptom**: A signature originally for deployment X is being
relayed to deployment Y.

**Response**: Mitigated by construction.  Every signed action
includes the `deploymentId` field in the EIP-712 wrap; cross-
deployment replay produces a different domain hash and the
signature fails verification.  No operator action required.

## 5. Bond economics — operator-facing

The 95/5 split (winner / treasury) is encoded in
`KnomosisFaultProofGame._settle`.  Per the design-rationale §3:

  * **Sequencer fraud cost**: a sequencer attempting fraud
    loses their `STATE_ROOT_SUBMISSION_BOND` plus L1 gas
    (~0.13 ETH).  Break-even attack value: ~112 ETH at 99%
    honest-detection probability.
  * **Challenger griefing cost**: each junk challenge costs
    `MIN_CHALLENGE_BOND + L1 gas ≈ 0.18 ETH`.  Sequencer's
    defensive cost per game ≈ 0.13 ETH.  Griefing is
    economically irrational unless attacker's goal is non-
    financial.

Treasury accumulates 5% of each slashed bond.  Operators
should periodically sweep the treasury to a multisig or
deployment-specific cold-storage address.

## 6. Migration to V2 (if applicable)

If your deployment is currently running pre-Workstream-H V1
(adjudicator-quorum) contracts, migration to V2 (fault-proof)
is via `KnomosisFaultProofMigration`:

  1. **Deploy V2 contracts** (per §2 above).
  2. **Pre-commit V1's `migration` immutable** to the V2
     migration contract address.  This requires a one-shot
     V1 amendment OR a specific migration-handoff hook in V1
     that points at V2.
  3. **Wait the grace window**: `MIN_GRACE_WINDOW_BLOCKS =
     216_000` blocks (≈ 30 days).
  4. **Activate**: anyone may call
     `faultProofMigration.activate()` after the grace window.
     This freezes the V1 contracts and authorises V2 to
     receive state-root submissions.
  5. **Verify post-activation**: V1's `revertToPriorRoot`
     should no longer be reachable; V2's
     `submitStateRoot` should accept the next submission.

**Backward compatibility**: V1 disputes filed before
activation continue to be adjudicable via the V1
adjudicator-quorum path until the grace window plus dispute
window have both elapsed.  The dual-path verifier
(`KnomosisDisputeVerifierV2`) supports both quorum-based and
fault-proof-based dispute finalisation, so the migration is
backward-compatible at the dispute-pipeline level.

## 7. Rust observer crate specification

The off-chain observer is the operational complement to the
on-chain fault-proof game.  Per §H.10.5 of the workstream plan,
the Rust crate `runtime/knomosis-faultproof-observer` is the
production form; the Lean-side reference is
`LegalKernel.FaultProof.Observer`.  Workstream RH-G is **complete**,
including the production EIP-1559 JSON-RPC submitter (`jsonrpc_submitter`:
signs responses and drives `eth_sendRawTransaction`), enabled by
supplying `--chain-id`.

### 7.1 Crate API surface

The observer ships eleven modules:

```rust
// runtime/knomosis-faultproof-observer/src/lib.rs

pub mod config;            // CLI argument parsing
pub mod error;             // Top-level error type + exit-code mapping
pub mod events;            // L1 event-topic registry + decoder
pub mod game;              // Rust port of LegalKernel.FaultProof.Game
pub mod jsonrpc_submitter; // EIP-1559 JSON-RPC submitter (sign + eth_sendRawTransaction)
pub mod observer;          // Top-level orchestrator (Observer)
pub mod persistence;       // knomosis-storage-backed game + cursor layer
pub mod state_reader;      // L2 log reader feeding the truthful-commit oracle
pub mod strategy;          // Honest-strategy computation (TruthOracle)
pub mod submitter;         // Calldata encoder + Submitter trait
pub mod watcher;           // L1 event-watch with re-org handling
```

The top-level type is `Observer<S: L1Source, Sub: Submitter,
T: TruthOracle>`:

```rust
impl<S, Sub, T> Observer<S, Sub, T> {
    /// Construct an observer.  Opens the persistence layer,
    /// restores the in-memory state, and seeds the watcher's
    /// resume point from the persisted cursor.
    pub fn new(
        config: ObserverConfig,
        source: S,
        submitter: Sub,
        oracle: T,
        persistence: Persistence,
    ) -> Result<Self, ObserverError>;

    /// Run a single orchestrator iteration.  Pulls a batch of
    /// L1 events, applies each to the in-memory game-state map,
    /// computes the honest move (if any), submits via the
    /// configured submitter, and commits the batch atomically.
    pub fn run_iteration(&mut self) -> Result<IterationOutcome, ObserverError>;

    /// Run the observer loop until the stop signal is set.
    pub fn run(&mut self) -> Result<(), ObserverError>;
}
```

The honest-strategy decision tree lives in `strategy::compute_next_move`:

```rust
pub fn compute_next_move<O: TruthOracle + ?Sized>(
    oracle: &O,
    gs: &GameState,
    me: TurnSide,
) -> Result<HonestMove, HonestMoveError>;
```

The calldata encoder lives in `submitter::encode_calldata`:

```rust
pub fn encode_calldata(
    game_id: u128,
    mv: HonestMove,
) -> Result<Vec<u8>, SubmitError>;
```

### 7.2 Cross-stack equivalence requirement

The Rust observer's `compute_next_move` MUST agree byte-for-
byte with the Lean-side `LegalKernel.FaultProof.Strategy.honestStrategy`
on every input the F.1.10 fixture corpus exercises.  Cross-stack
equivalence is verified at the fixture-corpus level.

### 7.3 Build target

```toml
# runtime/knomosis-faultproof-observer/Cargo.toml
[package]
name = "knomosis-faultproof-observer"
version.workspace = true     # 0.6.0, inherited from the workspace
edition.workspace = true     # 2021

[dependencies]
knomosis-cli-common = { workspace = true }
knomosis-storage = { path = "../knomosis-storage" }
knomosis-l1-ingest = { path = "../knomosis-l1-ingest" }  # shared re-org window + JSON-RPC L1 source + signing key
hex = { workspace = true }
k256 = { workspace = true }       # secp256k1 (ECDSA) — NOT the `secp256k1` crate
serde = { workspace = true }
serde_json = { workspace = true }
sha3 = { workspace = true }       # keccak256
thiserror = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
zeroize = { workspace = true }    # key-material zeroization

[[bin]]
name = "knomosis-faultproof-observer"
path = "src/main.rs"
```

The crate uses **no** async runtime (`tokio`), `ethers`, or the
`secp256k1` crate — consistent with the workspace conventions
(blocking I/O; `k256` for ECDSA).

### 7.4 Deployment

The observer runs as a long-lived daemon alongside the L2
sequencer node:

```bash
knomosis-faultproof-observer \
    --l1-rpc https://mainnet.infura.io/v3/<KEY> \
    --game-contract 0xC0DE... \
    --state-root-contract 0xDEAD... \
    --storage /var/lib/knomosis/observer.db \
    --keystore $KEYSTORE_PATH \
    --deployment-id <32-byte-hex> \
    --knomosis-binary /usr/local/bin/knomosis \
    --knomosis-log /var/lib/knomosis/log \
    --play-as challenger \
    --chain-id 1
```

The six required flags are `--l1-rpc`, `--game-contract`,
`--state-root-contract`, `--storage`, `--keystore`, and
`--deployment-id`.  `--knomosis-binary` and `--knomosis-log` must be
supplied **together** (or both omitted) — supplying only one is
rejected at startup (`--knomosis-log requires --knomosis-binary to be
set`, and vice-versa).  The pair wires up the production truth oracle
(the observer shells out to `knomosis replay-up-to` to compute the
canonical state commit), which is what lets it file challenges
automatically; without the pair it falls back to the in-memory oracle.
`--play-as` defaults to `challenger`, and supplying `--chain-id`
enables the production JSON-RPC submitter (otherwise the observer runs
read-only, logging moves without submitting).  `--chain-id`
additionally **requires** the truth-oracle pair — a broadcast-capable
observer with no truth oracle would defer every bisection move
(`TruthOracleMissed`) while appearing armed, silently voiding the
watchtower-liveness assumption, so that combination is rejected
fail-closed at startup.  Run
`knomosis-faultproof-observer --help` for the full flag list.

The observer logs detected divergences and (when configured with
`--chain-id` + a keystore) automatically files challenges.
Operators should run at least 2 observers per deployment to
satisfy the "1-of-anyone honest" trust assumption.

---

*End of Knomosis Fault-Proof Operator Runbook.*
