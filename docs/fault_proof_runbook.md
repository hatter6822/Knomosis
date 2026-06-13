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

## 1. Pre-deployment checklist

Before deploying the Workstream-H contracts:

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
    --knomosis-log /var/lib/knomosis/log \
    --play-as challenger \
    --chain-id 1
```

The six required flags are `--l1-rpc`, `--game-contract`,
`--state-root-contract`, `--storage`, `--keystore`, and
`--deployment-id`; `--play-as` defaults to `challenger`, and supplying
`--chain-id` enables the production JSON-RPC submitter (otherwise the
observer runs read-only, logging moves without submitting).  Run
`knomosis-faultproof-observer --help` for the full flag list.

The observer logs detected divergences and (when configured with
`--chain-id` + a keystore) automatically files challenges.
Operators should run at least 2 observers per deployment to
satisfy the "1-of-anyone honest" trust assumption.

---

*End of Knomosis Fault-Proof Operator Runbook.*
