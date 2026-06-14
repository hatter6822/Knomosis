# Audit 21 — Solidity deep security review (L1 mirror contracts)

**Date:** 2026-06-14
**Status:** Workstream P2 deliverable.  Companion to
`docs/audits/20-production-security-review-and-external-audit-scope.md`.
**Scope:** a focused, line-by-line security pass over the highest-risk
L1 contracts — `KnomosisBridge.sol` (custody, 2 245 LOC),
`KnomosisFaultProofGame.sol` (adjudication, 575 LOC),
`KnomosisSequencerStake.sol` (stake escrow, 212 LOC), and
`KnomosisAmmDisasterRecoveryMultisig.sol` (governance, 321 LOC), plus
the shared `lib/SmtVerifier.sol`.  Toolchain: solc 0.8.20, via-IR,
optimizer (200 runs).

> **Method.**  Two independent review passes (one per contract group)
> against vulnerability classes — reentrancy, access control, fund
> accounting, arithmetic, proof verification, state-machine soundness,
> DoS/griefing, initialization, replay, MEV.  Every finding below was
> *re-verified against source* by the workstream owner before landing;
> false positives were dropped.  This is an **internal** review and does
> **not** substitute for the independent external audit scoped in
> Audit 20 — it sharpens that audit's starting point and remediates the
> two unambiguous defects it surfaced.

---

## 1. Summary of findings

| # | Contract | Title | Severity | Status |
|---|----------|-------|----------|--------|
| 1.1 | FaultProofGame | Unanchored attacker-controlled `low` interval endpoint | **Critical** | **Open — decision required** |
| 1.2 | FaultProofGame | Active-game lock cleared under the wrong key (re-challenge brick) | **High** | **Fixed** |
| 1.3 | FaultProofGame | Push-payment settlement DoS if winner/treasury rejects ETH | Medium | Open — recommended |
| 1.4 | FaultProofGame | No constructor check `responseTimeout > stepInterval` | Low | Open — recommended |
| B.1 | SmtVerifier / Bridge | Upper-level SMT siblings not size-checked (Lean soundness precondition) | Medium | **Fixed** |
| B.2 | Bridge | Emergency roles are immutable single keys (no rotation) | Low | Open — deployment posture |
| 2.1 | SequencerStake | First slash zeroes the entire stake (multi-dispute reward) | Low | Open — design note |
| 3.1 | Multisig | Stale-round confirmations read "live" until rolled (observability) | Informational | Open — no action |

**Headline.**  The contracts are maturely engineered and have clearly
absorbed prior audit passes (pervasive, substantive "audit-2"/"audit-3"
annotations; thorough reentrancy + CEI discipline; exact bond/fee
conservation; fee-on-transfer rejection; tightly-scoped roles).  Two
**real defects** were found and **fixed in this landing** (1.2, B.1).
One **Critical** soundness issue (1.1) and one Medium robustness issue
(1.3) require a design decision and are documented here with concrete
remediation; they are the priority follow-ups.

---

## 2. Fixed in this landing

### B.1 — SMT verifier omits the per-sibling size check the Lean soundness proof requires (Medium → Fixed)

**Files:** `solidity/src/lib/SmtVerifier.sol` (`recomputeRoot`);
consumed by `KnomosisBridge.withdrawWithProof`.

The Lean reference `verifyProof_sound`
(`LegalKernel/Bridge/WithdrawalRoot.lean:1017`) is *parametric* in two
size-witness hypotheses (`h_leaf_size`, `h_sibs_match`), and its
docstring (lines 1006-1016) states plainly: *"If the runtime does not
check these sizes, a malformed proof bytes could in principle pass
`verifyProof` without satisfying the soundness conclusion."*  The hash
chain has no length prefix / domain separation (`hashUp` is
`H(current ‖ sibling)`, mirrored as `keccak256(abi.encodePacked(...))`),
and the Solidity verifier took every sibling as variable-length `bytes`
while checking only the array *count* (`!= SMT_HEIGHT`) — never the
per-sibling size.  This is the exact "implicit invariant maintained only
by convention" anti-pattern the project forbids: the on-chain verifier
relied on keccak second-preimage resistance to cover a structural check
the formal model demands.

**Remediation (landed).**  `recomputeRoot` now enforces that every
**upper-level** sibling (`siblings[0..62]`) is *exactly 32 bytes*
(`SmtBadSiblingSize`).  A canonical proof's siblings above the leaf are
always 32-byte keccak-output / default-hash values, so this rejects no
valid proof yet supplies the Lean `h_sibs_match` precondition
structurally (the operand boundary in the `keccak256(sibling ‖ current)`
packing is now fixed by construction).  The *only* legitimately
variable-size operand — the dense-pair leaf-adjacent sibling
`siblings[63]` — is consumed at the leaf level and intentionally left
variable; its boundary is anchored by the Bridge's leaf-hash binding
(`keccak256(proofLeaf) == keccak256(leafBlob)` pins the leaf to the
canonical 56-byte CBE structure).  This corresponds to the general
`verifyProof_sound` form (not the stricter `verifyProof_sound_all_32`,
which would break the dense-pair case the audit-2 fix enabled).

### 1.2 — Active-game lock cleared under the wrong key (High → Fixed)

**File:** `solidity/src/contracts/KnomosisFaultProofGame.sol:_settle`.

The lock is *set* under `disputedLogIndex`
(`activeGameForLogIndex[disputedLogIndex] = gameId`, line 291) but was
*cleared* under `g.high.idx` (line 457).  `respondToMidpoint(disagree)`
reassigns `g.high = g.pendingMidpoint` (line 365), so after any
`disagree` the high index is a *midpoint*, not `disputedLogIndex`.  The
clear therefore zeroed an unrelated slot, leaving
`activeGameForLogIndex[disputedLogIndex]` pinned to the finished game
**forever** — every subsequent `initiateChallenge(disputedLogIndex, …)`
reverts `GameAlreadyExists`, permanently bricking re-challenge of that
root (and, on a sequencer-win settlement that calls `clearDisputed`,
letting a genuinely invalid root finalise unchallengeably).  The game
struct already stores the correct key (`g.disputedLogIndex`, line 289)
precisely so settlement can recover it.

**Remediation (landed).**  `_settle` now clears
`activeGameForLogIndex[g.disputedLogIndex]`.

---

## 3. Open — decision required / recommended

### 1.1 — Unanchored, attacker-controlled `low` interval endpoint (Critical)

**File:** `KnomosisFaultProofGame.sol:initiateChallenge` (lines
232-289), consumed by `terminateOnSingleStep` (line 401).

`initiateChallenge` accepts `lowCommit` as a *raw caller parameter* and
stores it directly (`g.low = Claim({ idx: lowLogIndex, commit:
lowCommit })`, line 277), validated **only** by `lowLogIndex <
disputedLogIndex` (line 245).  It is **never** checked against
`roots[lowLogIndex].stateCommit` — whereas the *high* endpoint **is**
anchored to the looked-up `rootStateCommit` (lines 278-279).  The Lean
model is explicit that the lower bound must be *agreed*
(`FaultProof/Game.lean`: "Both parties have agreed on the commits at
`low` and `high`").

**Exploit (single-step).**  A dishonest challenger calls
`initiateChallenge(disputedLogIndex, challengerCommit,
lowCommit = <fabricated>, lowLogIndex = disputedLogIndex − 1)`.  The
range is single-step from the start; at game open `turn = Sequencer`, so
only the honest sequencer may `terminateOnSingleStep`, which executes
`stepVM.executeStep(g.low.commit = <fabricated>, …)`.  Because the
step-VM post-commit is a function of the *pre*-commit, it cannot equal
the real `high.commit`, so the sequencer's terminal claim mismatches and
**the challenger wins** (or the sequencer stalls and loses by
`claimTimeout`).  Either branch slashes the honest sequencer's bond.
The sequencer has no in-contract move to repudiate the fabricated
initial `low`.

**Why it is filed Open rather than auto-fixed.**  The remediation
direction is clear — anchor `low` on-chain like `high` — but it changes
the game's core challenge-initiation semantics and has a genuine design
choice with different security/liveness trade-offs:

  - **(A)** require `lowCommit == roots[lowLogIndex].stateCommit` and the
    low root *exists* (submitted) — minimal anchor, mirrors `high`;
  - **(B)** additionally require the low root be *finalised* (an
    immutable agreed point) — strongest, but may be too strict if the
    immediate predecessor is not yet finalised;
  - **(C)** bind `low` via the hash chain
    (`roots[disputedLogIndex].prevLogEntryHash` / the prior
    `expectedNextHash`) rather than the state commit.

It will also require updating any existing test that passes an arbitrary
`lowCommit`.  Because this is a Critical change to the adjudication
contract, the decision is surfaced to the maintainer rather than chosen
unilaterally.  **Recommended:** (A) as the floor, escalating to (B) if
the protocol's finalisation cadence permits.  A regression test
producing a `SequencerWon` outcome (see §4) must land with the fix.

### 1.3 — Push-payment settlement DoS if winner/treasury rejects ETH (Medium)

**File:** `KnomosisFaultProofGame.sol:_settle` (lines 545-552).

`_settle` pushes ETH to `winner` and `treasury` via `.call`, reverting
the whole settlement (`BondTransferFailed`) if either rejects.  Since
`g.status = finalStatus` is set earlier in the same call, a reverting
recipient rolls back the status mutation — the game can never settle and
all bonds are stuck.  The `treasury` is immutable; a treasury that
reverts on plain ETH would brick *every* game globally; a
sequencer-contract that reverts on receive could deny an honest
challenger their win.  This is a robustness gap, not fund theft (hence
Medium).

**Recommendation.**  Adopt pull-payment escrow: credit
`pendingWithdrawals[recipient] += payout` in `_settle` and expose a
separate `nonReentrant` `withdraw()`.  At minimum, constrain `treasury`
to a known-accepting address and document the winner-must-accept-ETH
constraint.

### 1.4 — Constructor does not validate `responseTimeout > stepInterval` (Low)

**File:** `KnomosisFaultProofGame.sol` constructor.

If a deployment sets `MIN_BISECTION_STEP_INTERVAL_BLOCKS >=
BISECTION_RESPONSE_TIMEOUT`, the responsible party is physically unable
to act before the deadline and always loses by `claimTimeout`.  A
configuration footgun, not exploitable post-correct-deploy.
**Recommendation:** add `require(_bisectionResponseTimeout >
_minBisectionStepInterval)` and `require(_bisectionResponseTimeout > 0)`.

### B.2 — Bridge emergency roles are immutable single keys (Low)

`boldCircuitBreaker`, `ammDisasterRecovery`, `boldAdmin` are immutable
with no rotation.  Blast radius is correctly minimised (none can move
funds, alter roots, or change immutables — verified), but a compromised
key is a liveness/griefing risk remediable only by full migration.
**Recommendation:** require these to be multisigs at deployment (the
NatSpec says `ammDisasterRecovery` is "intended to be a multisig" but
this is never enforced on-chain); optionally add 2-step rotation for the
two *reversible* roles.  Deployment-posture item, not a code defect.

### 2.1 — First slash zeroes the entire sequencer stake (Low, design)

`KnomosisSequencerStake.slash` consumes 100 % of `totalStaked` on the
first upheld dispute (paying `slashRatioBps` to the challenger, burning
the rest, zeroing `totalStaked`).  A second independent upheld dispute
computes `stakeAtTime = 0` and rewards its challenger nothing
(idempotency and no-underflow are preserved).  Acceptable under a
single-fatal-fault model; flagged for multi-concurrent-dispute
deployments.  **Recommendation:** escrow a per-dispute slashable portion
if simultaneous disputes must each reward, or document the
single-fatal-fault intent at the function level.

### 3.1 — Multisig stale-round confirmations (Informational)

`KnomosisAmmDisasterRecoveryMultisig` resets `roundId`/`confirmationCount`
lazily inside `confirmDisable`, so between expiry and the next
confirmation `hasConfirmed()` / `confirmationCount` report stale
approvals as live.  **Not a vulnerability** — an expired quorum can
never execute (the expiry-reset precedes the threshold check, verified),
and the contract exposes `roundExpired()` for consumers.  Observability
caveat only; no action required.

---

## 4. Systemic gap — adjudication path test coverage

The most important *non-finding* observation: the fault-proof game's
**terminal adjudication path is not exercised end-to-end on-chain**.  No
test drives `terminateOnSingleStep` or produces a `SequencerWon` /
`ChallengerWon` settlement (only timeout settlements), and the
`KnomosisStepVM` per-entry cross-stack byte-equivalence is currently
gated off under the FNV hash default (it runs under
`scripts/verify_keccak_crossstack.sh`).  Both 1.1 and 1.2 would have
been caught by an end-to-end "honest sequencer wins a single-step
termination" test.  **Recommendation (gating the 1.1 fix):** add
adjudication-outcome tests covering (a) honest sequencer wins a
single-step termination against a *correctly anchored* `low`, (b) honest
challenger wins against an invalid root, and (c) re-challenge succeeds
after a prior game settles (the 1.2 regression).

---

## 5. Positive observations (preserve these)

- **Reentrancy / CEI:** every fund-moving entry point across all four
  contracts is `nonReentrant` with effects-before-interactions ordering
  (Bridge withdraw/deposit/swap; game `_settle`; stake withdraw/slash).
- **Bond / fee / stake conservation is exact** — the game's 95/5 split,
  the stake's `paid + burned == stakeAtTime`, and the Bridge fee-split's
  provably-non-wrapping `unchecked` subtraction (bounded by
  `MAX_FEE_BPS_CAP`) all conserve with no rounding leak.
- **Fee-on-transfer / rebasing ERC-20s are rejected** by balance-delta
  accounting on every BOLD path (deposit + AMM).
- **Double-withdrawal / double-slash / double-settle are structurally
  prevented** by consumed-maps and one-way status latches.
- **The disaster-recovery multisig is the strongest surface:**
  constructor-enforced 3-of-N floor, duplicate/zero/bridge/self signer
  rejection, replay-proof per-round ledger, genuinely fail-safe
  group-expiry (reset precedes threshold), single-purpose by
  construction (the only outbound call is `emergencyDisableAmm`).
- **Authoritative lookups** (sequencer, root commit, deploymentId) and
  EIP-712 + chainid + address binding give cross-deployment/chain replay
  resistance; constructors reject zero/EOA addresses for code-bearing
  roles.

---

## 6. Remediation tracking

| Finding | Action | Lands in |
|---------|--------|----------|
| B.1 | Enforce 32-byte upper siblings in `SmtVerifier.recomputeRoot` | this PR |
| 1.2 | Clear `activeGameForLogIndex[g.disputedLogIndex]` in `_settle` | this PR |
| 1.1 | Anchor `lowCommit`; add `SequencerWon` regression test | follow-up (decision) |
| 1.3 | Pull-payment settlement escrow | follow-up |
| 1.4 / B.2 / 2.1 | Constructor guard / multisig roles / per-dispute slash | follow-up / deployment |
| Coverage | End-to-end adjudication-outcome tests | follow-up (gates 1.1) |
