<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon Fault-Proof Operator Runbook

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
        `CANON_FIXTURES_OVERWRITE=1 lake test` (writes
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

  1. `CanonStepVM` — pure logic, no dependencies.
  2. `CanonStateRootSubmission` — depends on the (predicted)
     fault-proof game address.
  3. `CanonFaultProofGame` — depends on the deployed step VM
     address + the (predicted) state-root submission address.
  4. `CanonDisputeVerifierV2` — depends on the deployed
     fault-proof game address.
  5. `CanonFaultProofMigration` — depends on the V1 contracts
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

Track the following events from `CanonStateRootSubmission`:

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

Track the following events from `CanonFaultProofGame`:

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

The `runtime/canon-faultproof-observer` Rust crate (tracked
separately; see §H.10.5 of the workstream plan) is the recommended
production off-chain observer.  Until the Rust port lands, operators
should run the Lean-side `LegalKernel.FaultProof.Observer` reference
at audit cadence (weekly minimum) to detect:

  * State-root submissions inconsistent with the operator's
    own L2 replay.
  * Dispute-game positions where the operator's view differs
    from on-chain.

When a divergence is detected, the operator should file a
challenge using `CanonFaultProofGame.initiateChallenge`.

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

**Symptom**: A logic error in `CanonStepVM` or another
deployed contract.

**Response**: Use `CanonFaultProofMigration` to hand off to a
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
`CanonFaultProofGame._settle`.  Per the design-rationale §3:

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
is via `CanonFaultProofMigration`:

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
(`CanonDisputeVerifierV2`) supports both quorum-based and
fault-proof-based dispute finalisation, so the migration is
backward-compatible at the dispute-pipeline level.

## 7. Rust observer crate specification

The off-chain observer is the operational complement to the
on-chain fault-proof game.  Per §H.10.5 of the workstream plan,
the Rust crate `runtime/canon-faultproof-observer` is the
production form; the Lean-side reference is
`LegalKernel.FaultProof.Observer`.  The Rust port is tracked
separately, mirroring the Phase-5 Rust host's separation from
the Lean specification.

### 7.1 Crate API surface

```rust
// runtime/canon-faultproof-observer/src/lib.rs

/// The observer's state.  Holds the local L2 log + a connection
/// to the L1 RPC for monitoring state-root submissions.
pub struct Observer {
    l2_log: Vec<LogEntry>,
    l1_rpc: L1RpcClient,
    state_root_submission: Address,
    fault_proof_game: Address,
}

impl Observer {
    /// Construct a new observer from a local L2 log + L1 RPC URL.
    pub fn new(
        l2_log: Vec<LogEntry>,
        l1_rpc_url: &str,
        state_root_submission: Address,
        fault_proof_game: Address,
    ) -> Result<Self, ObserverError>;

    /// Detect state-root divergences by comparing on-chain
    /// submissions against the local L2 replay.  Returns a list
    /// of (log_index, on_chain_commit, local_commit) triples for
    /// every divergence.
    pub fn detect_faults(&self) -> Result<Vec<FaultDetection>, ObserverError>;

    /// Build cell proofs for a given (log_index, signed_action)
    /// from the local state.  Used to construct
    /// `terminateOnSingleStep` calldata.
    pub fn build_cell_proofs(
        &self,
        log_index: u64,
        action: &SignedAction,
    ) -> Result<CellProofBundle, ObserverError>;

    /// Compute the next honest move in an in-progress game.
    /// Returns the appropriate `submitMidpoint` /
    /// `respondToMidpoint` / `terminateOnSingleStep` /
    /// `claimTimeout` call.
    pub fn compute_next_move(
        &self,
        game_id: u64,
    ) -> Result<HonestMove, ObserverError>;

    /// File a challenge against an on-chain state root.  Returns
    /// the L1 transaction hash on success.
    pub fn file_challenge(
        &self,
        wallet: &Wallet,
        log_index: u64,
        challenger_commit: Bytes32,
    ) -> Result<H256, ObserverError>;
}
```

### 7.2 Cross-stack equivalence requirement

The Rust observer's `compute_next_move` MUST agree byte-for-
byte with the Lean-side `LegalKernel.FaultProof.Strategy.honestStrategy`
on every input the F.1.10 fixture corpus exercises.  Cross-stack
equivalence is verified at the fixture-corpus level.

### 7.3 Build target

```toml
# runtime/canon-faultproof-observer/Cargo.toml
[package]
name = "canon-faultproof-observer"
version = "0.1.0"
edition = "2021"

[dependencies]
ethers = "2.0"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
sha3 = "0.10"
secp256k1 = { version = "0.28", features = ["recovery"] }
tokio = { version = "1.0", features = ["full"] }

[[bin]]
name = "canon-faultproof-observer"
path = "src/main.rs"
```

### 7.4 Deployment

The observer runs as a long-lived daemon alongside the L2
sequencer node:

```bash
canon-faultproof-observer \
    --l2-log-path /var/lib/canon/log \
    --l1-rpc-url https://mainnet.infura.io/v3/<KEY> \
    --state-root-submission 0xDEAD... \
    --fault-proof-game 0xC0DE... \
    --challenger-wallet $WALLET_PATH
```

The observer logs detected divergences to syslog and (when
configured with a wallet) automatically files challenges.
Operators should run at least 2 observers per deployment to
satisfy the "1-of-anyone honest" trust assumption.

---

*End of Canon Fault-Proof Operator Runbook.*
