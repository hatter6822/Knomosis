# Audit — full-codebase sweep (Lean / Rust / Solidity)

A full-codebase audit pass across the three stacks.  This is a
**finding register, not a completion record**: every entry below is
open unless it says otherwise, and each states where it was found and
what would close it.

## Method, and what the numbers mean

Independent auditors read one area each and reported defects against
source rather than against documentation.  A second, adversarial stage
re-read the source for the highest-severity findings and tried to
REFUTE them, with instructions to judge on the merits rather than
default either way.

  * **65 raw findings** (28 Lean, 37 Rust / Solidity).
  * **39 went through adversarial verification**;
    **37 were upheld** and
    **2 refuted**.
  * That stage was **capped per area**.  The 28 findings it did not
    reach were put through the same adversarial stage afterwards —
    see "Second verification pass" at the end of this document — so
    **every finding in this register now carries an independent
    verdict**.  Across both passes: 67 verdicts, 62 upheld, 5 refuted.

Severities below are the VERIFIER's corrected severity, which in two
cases is lower than the reporting auditor's.  Post-verification split:
25 major, 7 critical, 5 minor.

Two verifications built a temporary executable reproduction rather
than arguing from source alone.

## Closed by the pass that produced this register

Five defects were fixed in the same pass rather than filed:

  * **`CellTag.decode` covered 7 of 15 constructors** while `encode`
    emitted all 15.  Every honest bundle carries an `.epochBudget`
    (tag 13) and a `.budgetPolicy` (14) cell, so the gap covered the
    majority of real bundles.  Nothing caught it because the module's
    only theorems were `*_encode_deterministic`
    (`t₁ = t₂ → encode t₁ = encode t₂`, true of every function) and no
    test called the decoder.  Decoder completed, `cellTag_roundtrip`
    proved, `encoding-kernelstep` suite added.

    *Read the verification result for this one carefully.*  It appears
    in the journals as REFUTED, and that verdict is an artefact of
    timing, not a judgment: the fix landed while the pass was still
    running, so the verifier read the already-corrected file and
    correctly reported that the arms are present.  The finding was
    real when reported.

  * **"No custom axioms (ABSOLUTE)" had no mechanical gate.**  Six
    audit binaries ship beside that claim and none checked it;
    `count_sorries` says so itself.  `Test/AxiomFootprint.lean` adds a
    build-time one.
  * **The epoch-budget growth bound was asserted, unproved, and false
    as stated.**  `storedBalance_topUp_le` / `_consume_le` now carry
    it.
  * **Solidity project-source warnings** (one solc, eleven
    forge-lint) — cleared, and `ci-solidity.yml` gained the
    strict-warnings gate the Lean side already had.
  * **Seven docstrings** still describing the retired `2^128` amount
    head.

## Standing note on the two amount-head findings

`LocalPolicyClause.capAmount` and the epoch-budget cell are both
reported as C-3 recurrences.  For whoever triages them:
`capAmount`'s bound IS enforced at the decode boundary
(`LocalPolicyClause.fieldsBounded` requires `max < 2^64` and the CBE
decoder rejects violations), so a wire-originated policy cannot carry
an over-bound cap — the open question is whether any non-decoder path
constructs one.  The epoch-budget cell has no such gate on its value,
and there the stacks genuinely disagree at the ceiling: Lean
truncates, Solidity reverts (`CBEValueTooWide`).

---

## Verified findings (verifier severity, critical first)


### CRITICAL — Withdrawal SMT is keyed by `nextWdId` but L1 redemption requires the proof index to equal the leaf's `l2LogIndex` — no production withdrawal can be redeemed

*Where:* `LegalKernel/Bridge/Admissible.lean:178` — Lean sweep, verifier confidence high

`applyActionToBridgeState` records the withdrawal with `l2LogIndex :=
l2LogIndex` (Admissible.lean:178-182), where that argument is the
runtime's global per-*action* counter `rs.logIndex`
(Runtime/Loop.lean:220, incremented by 1 on every admitted action of
any kind, Loop.lean:235). But `BridgeState.appendWithdrawal` inserts
the entry into the SMT at key `bs.nextWdId` — a per-*withdrawal*
counter (State.lean:391-395). `constructProof H b idx` / `verifyProof`
therefore locate the leaf at the withdrawal-id key
(WithdrawalRoot.lean:468-479, WithdrawalProof.lean:94-101). On L1,
`KnomosisBridge.withdrawWithProof` decodes the leaf, then requires
`proofIndex == wd.l2LogIndex` before running
`SmtVerifier.verifyProof(uint256(proofIndex), …)`
(KnomosisBridge.sol:2020-2023). The two counters coincide only if
every action ever admitted was a withdrawal. `PendingWithdrawal`
carries no withdrawal-id field (State.lean:270-282), so the L1 side
has no way to recover the correct SMT key from the leaf. The cross-
stack corpus hides this: `buildBridgeState` force-sets `nextWdId :=
idx` and then writes `l2LogIndex := idx` into the same entry
(Test/Bridge/CrossCheck/WithdrawalProof.lean:139-142), manufacturing
the very equality production never maintains, so
`test_perEntry_verifyProof` passes by construction.

**Failure scenario.**

Genesis → `registerIdentity` (logIndex 0) → `deposit` (logIndex 1) →
user's `withdraw` (logIndex 2). The withdrawal is stored at SMT key
`nextWdId = 0` with leaf field `l2LogIndex = 2`. `extractProof snap 0`
returns the canonical proof for index 0, which verifies against
`withdrawalRoot` in Lean. On L1, `_decodePendingWithdrawal` yields
`wd.l2LogIndex = 2`; the submitted `proofIndex` must equal 2 to pass
line 2021, but a proof at index 2 opens an empty cell and fails
`SmtVerifier.verifyProof` against the root; a proof at index 0 is
rejected by line 2021. `withdrawWithProof` reverts `InvalidProof` for
every real withdrawal, so escrowed ETH/BOLD is permanently
unredeemable.

**Verifier's finding.**

Verified end-to-end in source. (1)
LegalKernel/Bridge/State.lean:391-395 `appendWithdrawal` is the ONLY
production insertion into `pending`, keying at `bs.nextWdId` (a per-
withdrawal counter); grep for `pending.insert` outside tests confirms
no other writer. (2) LegalKernel/Bridge/Admissible.lean:177-182 stores
`l2LogIndex` into the leaf, and the sole production caller passes
`rs.logIndex` (Runtime/Loop.lean:220), which is incremented on EVERY
admitted action (Loop.lean:235) — a different counter. (3) The only
production proof builder is `extractProof snap idx`
(Bridge/WithdrawalProof.lean:94-101) → `constructProof` sets `index :=
idx` = the withdrawal id (WithdrawalRoot.lean:468-479); the CLI
(Main.lean:1266/735) takes the withdrawal id. `PendingWithdrawal`
(State.lean:270-282) has no withdrawal-id field, so L1 cannot recover
the SMT key from the leaf. (4) KnomosisBridge.sol:2021 requires
`proofIndex == wd.l2LogIndex` before SmtVerifier.verifyProof at 2022,
and `withdrawWithProof` is the contract's only exit function.
Refutation attempts all failed. No code path constrains …

**Suggested remediation.**

Pick one key and make it authoritative on both stacks. Either (a) add
a `withdrawalId : Nat` field to `PendingWithdrawal` (and to the
Solidity `PendingWithdrawal` struct / CBE layout) and change the L1
check to `proofIndex == wd.withdrawalId`; or (b) key the SMT by the
log index (`pending.insert l2LogIndex wd`) and drop `nextWdId` as the
insertion key. Then regenerate the cross-stack corpus with `nextWdId`
advancing naturally and `l2LogIndex` set to a *different* value in at
least one fixture, so the two counters are no longer pinned equal by
the fixture builder.


### CRITICAL — An honest responder loses the game outright on any step over `distributeOthers` / `proportionalDilute`, and nothing enforces the deployment-level exclusion the design relies on

*Where:* `LegalKernel/FaultProof/VerifierWrites.lean:1733` — Lean sweep, verifier confidence high

`FaultProofAdjudicable` is `false` on exactly the two bulk variants
(VerifierWrites.lean:1733-1736, pinned by
`faultProofAdjudicable_eq_false_iff` at :1771).
`verifierPostRootMulti` returns `none` for them unconditionally
(Terminate.lean:428), and `applyTransition` maps `kernelStepApply step
= none` to "the responding party loses" (Game.lean:336-341). The
Solidity mirror behaves identically by reverting:
`StepWrites.isAdjudicable(actionKind)` is `actionKind <= 24 &&
actionKind != 6 && actionKind != 7`
(solidity/src/lib/StepWrites.sol:759-761) and `KnomosisStepVMRoot`
reverts `ActionNotAdjudicable`
(solidity/src/contracts/KnomosisStepVMRoot.sol:277-278), so the
responder cannot terminate at all and loses by timeout. The stated
mitigation — that a deployment leaning on the fault proof "must not
authorise them — its `AuthorityPolicy` already expresses that"
(VerifierWrites.lean:1714-1723) — is enforced by nothing:
`FaultProofAdjudicable` appears in no `AuthorityPolicy`, no admission
gate, no genesis-ratification check, and no theorem outside
`FaultProof/` (verified by repo-wide grep: the only non-test
references are Terminate.lean, Step.lean, VerifierWrites.lean).

**Failure scenario.**

A deployment authorises `distributeOthers` (e.g.
`AuthorityPolicy.unrestricted`, or the worked reward deployments) and
the sequencer honestly executes one at log index i, publishing the
correct root R_{i+1}. Any challenger posts a bond, opens a challenge
over a window containing i, and — since the challenger chooses
`respondAgree`/`respondDisagree` at every round and thereby chooses
which half survives — steers the bisection to the single step [i,
i+1]. The sequencer, as responder, calls `terminateOnSingleStep`;
`kernelStepApply` returns `none` (Lean) / the contract reverts
(Solidity), and the sequencer loses its bond to the challenger. The
attack is profitable, repeatable, and requires no dishonesty by the
sequencer whatsoever.

**Verifier's finding.**

Traced end to end in source. (1) VerifierWrites.lean:1733-1736 makes
FaultProofAdjudicable false on exactly
.distributeOthers/.proportionalDilute (iff-pinned at :1771). (2)
Terminate.lean:428 has verifierPostRootMulti return none for them
before inspecting anything. (3) Game.lean:336-341 maps kernelStepApply
= none to "turn-holder loses". (4) The two honesty theorems that could
rescue this (Step.lean:148, Terminate.lean:1161) both take h_adj :
FaultProofAdjudicable = true as a hypothesis, so no theorem covers the
bulk case. The claimed mitigation is enforced nowhere:
FaultProofAdjudicable occurs in no non-test Lean file outside
FaultProof/{Terminate,Step,VerifierWrites}; AuthorityPolicy
(Authority/Identity.lean:157-165) is an unconstrained ActorId ->
Action -> Prop with no adjudicability conjunct; no genesis-
ratification or admission gate references it; no Rust guard (grep
'adjudicab' over runtime/ yields three comments in the observer only);
no actionKind filter in KnomosisStateRootSubmission.sol. The project's
own worked deployment authorises the bulk pair — …

**Suggested remediation.**

Make the exclusion structural rather than a runbook sentence: add a
decidable `AuthorityPolicy.FaultProofSafe P := ∀ a act, P.authorized a
act → FaultProofAdjudicable act = true`, require it in the genesis-
ratification path for any deployment that installs the fault-proof
game, and add a theorem that a `FaultProofSafe` policy admits no step
on which `verifierPostRootMulti` returns `none` for adjudicability
reasons. Alternatively close the real gap by making the bulk write set
verifier-derivable (a per-resource actor-set cell, or moving the
recipient list into the action's fields).


### CRITICAL — Pivot de-duplication cache blocks the honest sequencer's terminateOnSingleStep, forcing a bond loss in the normal adversarial trace

*Where:* `runtime/knomosis-faultproof-observer/src/observer.rs:1420` — Rust / Solidity sweep, verifier confidence high

`maybe_play_move` de-duplicates moves on the key `(game_id,
pivot_idx)` where `pivot_for_move` (observer.rs:1672-1682) returns
`Some(claim.idx)` for `Submit`, `Some(pending_midpoint.idx)` for
`Respond*`, and `Some(range.high.idx)` for `TerminateOnSingleStep`.
These three index spaces are NOT disjoint: after a `RespondDisagree`
the contract sets `g.high = g.pendingMidpoint`
(KnomosisFaultProofGame.sol:445), so the terminal `range.high.idx` is
exactly the midpoint index the same party submitted a round earlier.
The dedup lookup therefore returns `true` for a terminate move that
has never been submitted, and `maybe_play_move` returns
`Ok(Some(false))` without broadcasting.

**Failure scenario.**

Observer runs with `play_as = Sequencer` (the only role that ever
terminates, because `submitMidpoint` and `respondToMidpoint` both flip
the turn, so the sequencer always submits and the challenger always
responds). Game range [0,4], turn Sequencer. (1) Observer submits
midpoint idx 2 -> `submitted_pivots` gains `(g, Some(2))`. (2)
Challenger agrees -> range [2,4], turn Sequencer. (3) Observer submits
midpoint idx 3 -> `submitted_pivots` gains `(g, Some(3))`. (4)
Challenger disagrees -> `g.high = {idx:3}`, range [2,3], single step,
turn Sequencer. (5) `handle_response_submitted` -> `maybe_play_move`
-> `compute_next_move` returns `TerminateOnSingleStep`,
`build_terminate_calldata` succeeds, then `pivot_for_move` yields
`Some(3)`, `has_submitted_for_pivot` returns true, and the move is
silently skipped (`debug!` only). No further event ever arrives for
this game, so the observer never …

**Verifier's finding.**

CONFIRMED by source trace plus a temporary executable reproduction
(since reverted). Mechanism, verified line by line: - observer.rs:156
declares the dedup cache as HashSet<(u128, Option<u64>)> — game_id +
bare pivot index, no move-kind or depth discriminator. -
observer.rs:1413-1427: build_calldata_for_move runs FIRST (terminate
calldata is built successfully), then pivot_for_move +
has_submitted_for_pivot skip the move with only a debug! log,
returning Ok(Some(false)) before any ResponseRecord is persisted. -
observer.rs:1672-1681: Submit(c) => Some(c.idx) but
TerminateOnSingleStep => Some(state.range.high.idx) — two different
index spaces sharing one key. - KnomosisFaultProofGame.sol:445-448
`else { g.high = g.pendingMidpoint; }` (Rust mirror game.rs:428-432
apply_respond disagree branch) makes post-disagree range.high.idx
EXACTLY the midpoint index previously submitted. - Turn parity forces
the collision onto one party: initiateChallenge sets g.turn =
Sequencer (:364); submitMidpoint (:413) and respondToMidpoint (:453)
both flip. So the sequencer always sees pending_midpoint == …

**Suggested remediation.**

Make the dedup key discriminate the move kind, e.g. key on `(game_id,
move_discriminant, pivot_idx)` or store the pivot as an enum
`Pivot::Midpoint(u64) | Pivot::Response(u64) | Pivot::Terminate(u64)`.
Persist the same discriminant in `ResponseRecord.pivot_idx` so the
startup repopulation (observer.rs:257) rebuilds the same key space.
Add a regression test driving the exact trace above (submit mid N,
opponent disagrees, terminate at high == N) and asserting a terminate
calldata is broadcast.


### CRITICAL — AMM has no minimum-liquidity/reserve guard: a 1-wei BOLD seed lets an attacker drain ~half the ETH reserve per swap

*Where:* `solidity/src/contracts/KnomosisBridge.sol:1811` — Rust / Solidity sweep, verifier confidence high

`ammSwap` only rejects a *zero* reserve (`if (reserveIn == 0 ||
reserveOut == 0) revert AmmEmpty();`, line 1811). There is no minimum-
reserve floor, no initial-price anchor, and no external price
reference. Reserves are grown exclusively by `_seedAmmReserves` (lines
1537-1579), which carves `floor(poolAmount * ammSeedRatioBps / 10000)`
out of each fee-split deposit — so the ETH and BOLD legs accumulate
from two *independent* deposit flows and are never balanced to market
value. The constant-product formula in `AmmMath.getAmountOut` is
correct in isolation, but on a pool with `reserveIn = 1` it returns
`floor(amountIn*9970*reserveOut / (reserveIn*10000 + amountIn*9970))`,
which for `amountIn = 1, reserveIn = 1` is ~0.4992 * reserveOut. The
on-chain k-monotonicity guard at line 1839 does not fire (k rises from
1*X to 2*0.5008X), and `minAmountOut` protects the caller, not the
pool.

**Failure scenario.**

Deployment with `boldEnabled = true` and `ammSeedRatioBps = 2000`. ETH
fee-split deposits accumulate `ammReserveEth = 100 ETH`; no BOLD
deposit has yet occurred so `ammReserveBold = 0` and every swap
reverts `AmmEmpty`. (1) Attacker calls `depositBoldWithFee(10, 5000)`:
`poolAmount = floor(10*5000/10000) = 5`, `ammSeedAmount =
floor(5*2000/10000) = 1`, so `ammReserveBold = 1` at a cost of 10 wei
of BOLD. (2) Same block, attacker calls `ammSwap(RESOURCE_ID_BOLD, 1,
0, deadline)`: `amountInWithFee = 9970`, `numerator = 9970 * 100e18`,
`denominator = 1*10000 + 9970 = 19970`, `amountOut = 49.92 ETH`,
transferred to the attacker at line 1861. (3) Repeating with `amountIn
= 1` extracts a further ~16.6 ETH, then ~10 ETH, etc.; using larger
inputs extracts the remainder. Total loss: essentially the whole
`ammReserveEth`, i.e. gas-pool funds, for a few wei of BOLD. The same
attack works in the …

**Verifier's finding.**

CONFIRMED by direct source reading and an executed proof-of-concept.
KnomosisBridge.sol:1811 (`if (reserveIn == 0 || reserveOut == 0)
revert AmmEmpty();`) is the ONLY liquidity gate in `ammSwap` — there
is no minimum-reserve floor, no initial-price anchor, no external
price reference, and no cap on swap size relative to reserves. A grep
over solidity/src confirms `ammReserveEth`/`ammReserveBold` are
written only by `_seedAmmReserves` (1541-1579) and `ammSwap`
(1845-1850): there is NO admin or genesis seeding function, so
reserves start at zero and accrue from two independent, unbalanced
deposit flows. At line 1563 `ammSeedAmount = (poolAmount * ratio) /
10_000;` with only `if (ammSeedAmount == 0) return 0;` at 1565, so a
seed of exactly 1 wei is admissible and fully attacker-choosable via
the permissionless `depositBoldWithFee(amount, chosenFeeBps)` (both
parameters caller-controlled; `amount == 0` is the only floor). I
wrote and ran a Foundry PoC on the repo's own AmmTestBase deployment
(ammSeedRatioBps=8000, maxFeeBps=5000), then deleted it. Results: ETH
fee-split deposits gave …

**Suggested remediation.**

Enforce a per-leg minimum reserve before a swap is admissible (e.g.
`if (reserveIn < MIN_AMM_RESERVE || reserveOut < MIN_AMM_RESERVE)
revert AmmEmpty();` with `MIN_AMM_RESERVE` an immutable well above
dust), and additionally bound the per-swap output as a fraction of
`reserveOut` (e.g. reject `amountOut * 3 > reserveOut`, the standard
single-swap-impact cap). Consider gating the AMM behind a first-
activation threshold so it cannot be enabled until both reserves
exceed a value-comparable floor.


### CRITICAL — Withdrawal proof binds the SMT leaf position to `l2LogIndex`, but the Lean authority keys the withdrawal SMT by `WithdrawalId` — all withdrawals become unredeemable

*Where:* `solidity/src/contracts/KnomosisBridge.sol:2021` — Rust / Solidity sweep, verifier confidence high

`withdrawWithProof` requires the proof's tree position to equal the
leaf's `l2LogIndex` field (`if (proofIndex != wd.l2LogIndex) revert
InvalidProof();`) and then walks the SMT at that position. The Lean
authority builds the withdrawal SMT keyed by **WithdrawalId**, not by
log index: `Bridge.BridgeState.appendWithdrawal` inserts at
`bs.nextWdId` (LegalKernel/Bridge/State.lean:394) and `rangeRoot`
splits on `pathBitAtLevel p.1 k` where `p.1` is the map key, i.e. the
WithdrawalId (LegalKernel/Bridge/WithdrawalRoot.lean:212-220).
`WithdrawalProof.index` is documented as "The withdrawal id this proof
is about" (LegalKernel/Bridge/WithdrawalRoot.lean:276). `nextWdId` is
incremented only by `withdraw` actions while `l2LogIndex` is the
global log index incremented by every action
(LegalKernel/Bridge/Admissible.lean:168-183), so the two counters
diverge permanently after the first non-withdraw action.

**Failure scenario.**

An L2 processes one `transfer` (log index 0), then a `withdraw` (log
index 1). The pending entry is inserted at `WithdrawalId = 0` with
`l2LogIndex = 1`. The sequencer's honest proof, built by Lean's
`constructProof hashBytes s 0`, carries `index = 0` and its sibling
path opens tree position 0 — which is the only position whose walk
reproduces the published `withdrawalRoot`. On L1,
`_decodeWithdrawalProof` returns `proofIndex = 0` while
`_decodePendingWithdrawal` returns `wd.l2LogIndex = 1`, so line 2021
reverts `InvalidProof`. Supplying `proofIndex = 1` instead passes line
2021 but then `SmtVerifier.verifyProof(1, ...)` walks the wrong path
and cannot reproduce the root, reverting at line 2022. The withdrawal
is unredeemable by any input; every bridged position is permanently
stranded once the two counters diverge, which is after the first non-
withdraw L2 action.

**Verifier's finding.**

Traced end-to-end in source. Lean keys the withdrawal SMT by
WithdrawalId: `appendWithdrawal` inserts at `bs.nextWdId`
(LegalKernel/Bridge/State.lean:389-394), `rangeRoot` splits on the map
key `p.1` (Bridge/WithdrawalRoot.lean:205-220), and the production
emitter `extractProof` / `knomosis withdrawal-proof`
(Bridge/WithdrawalProof.lean:97-99, Main.lean:723-742) sets
`WithdrawalProof.index := idx`, that same key (constructProof,
WithdrawalRoot.lean:469-477). `l2LogIndex` is a distinct counter: the
`.withdraw` arm of `applyActionToBridgeState` stores the function's
`l2LogIndex` parameter as a leaf FIELD while taking the key from
`nextWdId` (Bridge/Admissible.lean:168-183), and that parameter is the
runtime's global per-action log index
(FaultProof/ProductionApply.lean:121-124). The repo's own test proves
divergence: Test/Runtime/BridgeAdmission.lean:415-424 runs deposit,
deposit, withdraw and asserts the pending entry sits at key 0 with
`l2LogIndex = 2` and `nextWdId = 1`. L1 requires equality:
KnomosisBridge.sol:2021 `if (proofIndex != wd.l2LogIndex) revert
InvalidProof();` where …

**Suggested remediation.**

Add the withdrawal id to the redeemed leaf's on-wire identity and bind
the proof index to it, not to `l2LogIndex`. Either (a) carry
`withdrawalId` as an explicit `withdrawWithProof` argument and check
`proofIndex == withdrawalId` (with the SMT walk at `withdrawalId`),
keeping `l2LogIndex` as a non-positional field, or (b) drop line 2021
entirely — the SMT walk already binds position to root, so the check
adds no soundness and only breaks the honest path. Add a regression
fixture where `withdrawalId != l2LogIndex` on both stacks.


### CRITICAL (reported MAJOR) — The attestation-staleness circuit breaker gates `submitStateRoot` itself, so one missed window permanently bricks the bridge

*Where:* `solidity/src/contracts/KnomosisBridge.sol:1880` — Rust / Solidity sweep, verifier confidence high

`submitStateRoot` carries the `circuitOpen` modifier (line 1882),
whose first arm reverts `AttestationStale` when `block.number >
latestStateRootSubmittedAtBlock + maxAttestationStaleBlocks` (lines
1044-1048). `latestStateRootSubmittedAtBlock` is written *only* inside
`submitStateRoot` (line 1904), and `maxAttestationStaleBlocks` is
`immutable` (line 271). The breaker is therefore self-sealing: the one
action that could clear the staleness condition is the action the
breaker blocks. There is no admin reset, no timeout, and no alternate
write path.

**Failure scenario.**

A deployment sets `maxAttestationStaleBlocks = 200` (the value used
throughout the test suite, ~40 minutes on mainnet). The
sequencer/attestor suffers a 45-minute outage — a routine operational
event. On recovery it calls `submitStateRoot(root, n+1, sig)`;
`circuitOpen` evaluates `block.number >
latestStateRootSubmittedAtBlock + 200`, which is now true and will
remain true forever, so the call reverts `AttestationStale`. Every
subsequent attempt reverts identically. `depositETH`, `depositERC20`,
`depositETHWithFee` and `depositBoldWithFee` also revert (same
modifier). No new L2 state root can ever be published, so every L2
withdrawal not already covered by a submitted-and-finalised root is
permanently unredeemable; recovery requires the full
`KnomosisMigration` handoff to a freshly deployed bridge.

**Verifier's finding.**

Verified in source and reproduced with a forge test.
KnomosisBridge.sol:1880-1882 applies `circuitOpen` to
`submitStateRoot`; the modifier's first arm (1043-1048) reverts
`AttestationStale` when `block.number >
latestStateRootSubmittedAtBlock + maxAttestationStaleBlocks`.
`latestStateRootSubmittedAtBlock` is written only at 1904 (inside the
very function the breaker blocks — confirmed by grep over the whole
contract; `revertToPriorRoot` at 2124 does not touch it), and
`maxAttestationStaleBlocks` is `immutable` (271/942) with no setter
and no admin reset in the contract's function list. A temporary test
(submit at block 1 with window 200, roll to 202) reverted
`AttestationStale`, and still reverted after a further 1,000,000
blocks; a control at exactly latest+200 succeeded, isolating the
overshoot. Two facts make it worse than reported. (1) The claimed
`KnomosisMigration` recovery does not exist in the shipped
configuration: `migration` is immutable (267/939),
`script/DeploySepolia.s.sol` hard-codes `migration: address(0)`
(665/694) and asserts it at 726, and `circuitOpen`'s …

**Suggested remediation.**

Exempt `submitStateRoot` from the `AttestationStale` arm (it is the
recovery action, not a value-moving one) — e.g. split `circuitOpen`
into `depositOpen` (all four arms) and `submissionOpen` (dispute-
cooldown, TVL and migration arms only). Keeping deposits halted while
a fresh root is accepted preserves the intended "deposits halted,
exits continue" posture without making the halt terminal. Add a
regression test that rolls past `maxAttestationStaleBlocks` and
asserts a subsequent `submitStateRoot` succeeds.


### CRITICAL — StepWrites.applyGrantAt skips the epoch normalisation Lean performs on a ZERO grant, forking the state root

*Where:* `solidity/src/lib/StepWrites.sol:302` — Rust / Solidity sweep, verifier confidence high

`StepWrites.applyGrantAt` short-circuits with `if (grantAmount == 0 ||
target != grantRecipient) return pre;`. The Lean authority
`VerifierWrites.applyGrantAt`
(LegalKernel/FaultProof/VerifierWrites.lean:290-300) has NO zero-
amount guard: for
`depositWithFee`/`topUpActionBudget`/`topUpActionBudgetFor` it
computes `pre.topUp currentEpoch freeTier g` whenever `target =
recipient`, and `ActorBudget.topUp`
(LegalKernel/Authority/ActorBudget.lean:51-53) NORMALISES before
adding — `normalise` sets `lastSeenEpoch := now` and `budgetBalance :=
max(bal, freeTier)` whenever `lastSeenEpoch < now`. So `topUp now ft
0` is NOT the identity on a stale cell; it is `normalise`.
`ProductionApply.budgetGrant` (line 165-170) confirms this is
unconditional on the sequencer side. The Solidity guard is doing
double duty: it is needed to make the 22 non-granting variants correct
(where `grantRecipient=0` is a sentinel that collides with the real
actor id 0), but it also wrongly swallows a genuine zero grant on the
three granting variants.

**Failure scenario.**

A user calls `KnomosisBridge.depositETHWithFee` with a small fee
split, so `rawBudgetGrant = poolAmount / weiPerBudgetUnitEth` floors
to 0 (KnomosisBridge.sol:1292) and the L2 action is `depositWithFee r
recipient pool userAmount poolAmount budgetGrant=0 d`. The recipient
is a first-time depositor, so its `.epochBudget recipient` cell is
canonically absent = `{lastSeenEpoch:0, budgetBalance:0}`; the
deployment's policy cell is `freeTier=100, actionCost=1,
currentEpoch=1` (the exact shape in step_vm.json's
`uniformWriteGoldens`). `.epochBudget recipient` is write-set slot 5
of `deriveWriteSet(19,…)`, so it is in the frontier and both folds
must produce its post-value. * Lean / the honest sequencer:
`applyGrantAt` fires (`target = recipient`), `topUp 1 100 0` =
`normalise` = `{lastSeenEpoch:1, budgetBalance:100}` → cell bytes
`0x00 0100000000000000 00 6400000000000000`, a PRESENT leaf …

**Verifier's finding.**

Confirmed by reading both stacks and by executing the Solidity path.
solidity/src/lib/StepWrites.sol:302 `applyGrantAt` returns `pre`
unchanged when `grantAmount == 0`; the Lean authority
(LegalKernel/FaultProof/VerifierWrites.lean:290-300) has no zero-
amount case and calls `pre.topUp currentEpoch freeTier g`, which is
`normalise` then add (LegalKernel/Authority/ActorBudget.lean:36-53).
On a stale cell (`lastSeenEpoch < currentEpoch`) `normalise` returns
`{currentEpoch, max(bal, freeTier)}`, so `topUp(…, 0)` is NOT the
identity. The sequencer side agrees with Lean's verifier:
ProductionApply.lean:161-170 `budgetGrant` is unconditional and
`EpochBudgetState.topUp` (ActorBudget.lean:239-242) inserts the
result. I ran the Solidity function under forge with the corpus's own
policy cell (freeTier=100, actionCost=1, currentEpoch=1), signer=7,
target=grantRecipient=8, absent target cell, grantAmount=0: it
returned 0x000000000000000000000000000000000000 (the canonical-absent
value) where Lean produces 0x000100000000000000006400000000000000. The
Lean value is forced by the corpus's own …

**Suggested remediation.**

Stop overloading `grantAmount == 0` as the "this variant grants
nothing" sentinel. Add an explicit `bool grants` (or `hasGrant`) to
`StepPlan.Plan`, set it true only for action kinds 19/20/21 in
`StepPlan.planGrant`, and change the guard to `if (!grants || target
!= grantRecipient) return pre;` so a genuine zero grant still runs
`_topUp` (hence `_normalise`) exactly as `ActorBudget.topUp now ft 0`
does. Add a `uniformWriteGoldens` row with `grantAmount = 0`, `target
== grantRecipient != signer`, and `targetBudgetPre.lastSeenEpoch <
policy.currentEpoch` so the corpus pins the case.


### MAJOR — MAX_TOPUP_BUDGET_PER_ACTION lets 1 wei buy 1,000,000 budget units, defeating the L2's only spam-admission control

*Where:* `LegalKernel/Authority/SignedAction.lean:682` — Lean sweep, verifier confidence high

`Laws.topUpActionBudget`'s kernel leg requires only `getBalance s
gasResource a ≥ gasAmount`
(`LegalKernel/Laws/TopUpActionBudget.lean:18-20`); nothing ties
`gasAmount` to `budgetIncrement`. The admission gate is supposed to
supply that binding via two mechanisms, and neither does.
`topUpActionBudget_gasCheck` (SignedAction.lean:747-758) requires only
`gasAmount > 0` and `budgetIncrement ≤ MAX_TOPUP_BUDGET_PER_ACTION =
1_000_000`. `topUpRoundTripCheck` (SignedAction.lean:966-971) requires
`budgetIncrement * refundRate gasResource ≤ gasAmount`, but
`refundRate` defaults to `fun _ => 0` on every runtime entry point
(`Runtime/Loop.lean:126,338,382,417,487`,
`Runtime/Replay.lean:347,405,441,462,475`,
`Runtime/EventStream.lean:81,104`), and
`topUpRoundTripCheck_true_of_zero_rate` (SignedAction.lean:998-1000)
proves the conjunct is unconditionally true at rate zero. The grant
arm then credits the full `budgetIncrement`
(SignedAction.lean:1199-1200) while consume debits only `actionCost`
(SignedAction.lean:1223-1224). `EpochBudgetState.topUp` accumulates
without ceiling and `normalise` never lowers a balance
(`Authority/ActorBudget.lean:51-53`, `normalise_balance_lower_bound`),
so the gain persists across epochs. The exchange rate is therefore `1
wei → up to 10^6 budget units`, unboundedly repeatable. The gate's own
docstring asserts the opposite property — "each repetition …

**Failure scenario.**

Default-configured deployment: `refundRate = fun _ => 0`,
`budgetPolicy = .bounded freeTier 1 epoch`. Registered actor A holds
1000 wei of gas resource 0 and is neither `bridgeActor` nor
`gasPoolActor`. A signs `Action.topUpActionBudget 0 1 1000000
Bridge.gasPoolActor`. Every gate conjunct passes: `signer ≠
bridgeActor` ✓, `signer ≠ poolActor` ✓, `poolActor = gasPoolActor` ✓,
`gasResource = 0` ✓, `1000000 ≤ MAX_TOPUP_BUDGET_PER_ACTION` ✓,
`gasAmount = 1 > 0` ✓, `balance 1000 ≥ 1` ✓; `topUpRoundTripCheck`
gives `1000000 * 0 = 0 ≤ 1` ✓. `consume` debits 1 budget unit,
`applyGrant` credits 1,000,000. Net: +999,999 budget for 1 wei. A
repeats 1000 times, spending its entire 1000-wei balance, and ends
with ~10^9 accumulated budget units — enough to flood the sequencer
indefinitely. The per-actor epoch-budget gate, described at
SignedAction.lean:667-668 as "the L2's only spam/DoS admission …

**Verifier's finding.**

CONFIRMED by independent trace of every conjunct on the production
path. (1) Kernel leg: Laws/TopUpActionBudget.lean:16-21 has pre :=
getBalance s gasResource a >= gasAmount AND AmountBounded ...;
budgetIncrement is bound as `_budgetIncrement` (literally unused). No
binding between mint size and gas paid. (2) Gate leg:
topUpActionBudget_gasCheck (SignedAction.lean:747-758) has only two
quantitative conjuncts -- budgetIncrement <=
MAX_TOPUP_BUDGET_PER_ACTION (line 755; def = 1000000 at line 682) and
gasAmount > 0 (satisfied by 1). The SAME gate is used on the
production bridge path (Bridge/Admissible.lean:496), so this is not a
kernel-only artifact. (3) The only conjunct that relates the two is
topUpRoundTripCheck (SignedAction.lean:966-971), and
topUpRoundTripCheck_true_of_zero_rate (998-1000) proves it
unconditionally true at refundRate = fun _ => 0 -- the default on
every entry point (Runtime/Loop.lean:126,338,382,417,487;
Main.lean:1050-1053 refundRateEth/Bold : Option Nat := none, .getD 0).
(4) Grant/consume asymmetry: SignedAction.lean:1199-1200 and …

**Suggested remediation.**

Add a rate-independent price conjunct to `topUpActionBudget_gasCheck`
and `topUpActionBudgetFor_gate` that binds the mint to the payment
unconditionally — e.g. `budgetIncrement ≤ gasAmount /
MIN_WEI_PER_BUDGET_UNIT` for a deployment-pinned positive
`MIN_WEI_PER_BUDGET_UNIT` — rather than relying on
`topUpRoundTripCheck`, whose binding evaporates at the default
`refundRate = 0`. Alternatively make a nonzero `refundRate` mandatory
(drop the `:= fun _ => 0` defaults on the runtime entry points and
fail closed when the sidecar supplies no rate), so the round-trip seal
is never vacuous. `MAX_TOPUP_BUDGET_PER_ACTION` should remain as a
second-order cap, not as the only bound.


### MAJOR (reported CRITICAL) — Cross-resource budget arbitrage: budget is minted at the buy leg's refund rate and redeemed at the sell leg's rate, draining the gas pool

*Where:* `LegalKernel/Authority/SignedAction.lean:966` — Lean sweep, verifier confidence high

`topUpRoundTripCheck` (SignedAction.lean:966-972) prices a budget mint
against `refundRate gasResource` where `gasResource` is the *top-up's*
resource, while `claimBudgetRefund_gate` (SignedAction.lean:1090-1106)
pays out at `refundRate gasResource` of the *refund's* resource. The
action budget itself is a single per-actor scalar (`EpochBudgetState
:= TreeMap ActorId ActorBudget`, ActorBudget.lean:171 — no resource
dimension), so units bought on one blessed leg are redeemable on the
other. Both gates bless exactly `gasResource = 0 ∨ gasResource = 1`
(SignedAction.lean:754 and :1099), and nothing anywhere requires
`refundRate 0 = refundRate 1`. The asymmetric configuration is not
exotic: `RefundRateConfig` (Runtime/RefundRateSidecar.lean:76-92) and
the CLI (`--wei-per-budget-unit-eth` / `--wei-per-budget-unit-bold`,
Main.lean:816-832) explicitly support enabling one leg and leaving the
other at 0, and at rate 0 the round-trip seal is *provably* vacuous
(`topUpRoundTripCheck_true_of_zero_rate`, SignedAction.lean:998-1001).
The docstring of `topUpActionBudget_roundtrip_not_profitable`
(SignedAction.lean:1975-1996) claims 'The top-up -> refund round-trip
is therefore non-profitable for EVERY caller', but the theorem it
decorates only concludes `budgetIncrement * refundRate gasResource <=
gasAmount` for the buy leg, which does not imply the claim once the
sell leg's rate differs.

**Failure scenario.**

Deployment runs `knomosis ... --wei-per-budget-unit-bold 3000` and
omits `--wei-per-budget-unit-eth` (documented as 'refunds disabled at
ETH'). So refundRate 0 = 0, refundRate 1 = 3000. Attacker A
(registered, non-bridge, non-pool) holds 1 wei of resource 0. 1. A
signs `topUpActionBudget gasResource=0 gasAmount=1
budgetIncrement=1000000 poolActor=gasPoolActor`. -
`topUpActionBudget_gasCheck`: signer != bridgeActor OK, signer !=
poolActor OK, poolActor = gasPoolActor OK, gasResource in {0,1} OK,
1000000 <= MAX_TOPUP_BUDGET_PER_ACTION (=1000000) OK, gasAmount=1 > 0
OK, balance 1 >= 1 OK. - `topUpRoundTripCheck`: 1000000 * refundRate 0
= 1000000 * 0 = 0 <= 1. Passes. - Admitted; A's epoch budget is
credited +1000000 (applyGrant, SignedAction.lean:1199-1200) at a cost
of 1 wei ETH and 1 budget unit. 2. A signs `claimBudgetRefund
gasResource=1 budgetUnits=999899 weiPerBudgetUnit=3000 …

**Verifier's finding.**

Mechanism verified end-to-end in source. (1) Budget is a single per-
actor scalar with no resource dimension: ActorBudget.lean:19-25
(fields lastSeenEpoch/budgetBalance only) and EpochBudgetState :=
TreeMap ActorId ActorBudget; applyGrant (SignedAction.lean:1195-1211)
credits the signer irrespective of gasResource, and refundConsumeExtra
debits that same scalar. (2) The buy leg is priced at refundRate of
the top-up's resource (topUpRoundTripCheck, SignedAction.lean:966-972)
while the sell leg pays at refundRate of the refund's resource
(claimBudgetRefund_gate, :1090-1106); both bless {0,1} (:754, :1099).
(3) topUpActionBudget_gasCheck (:753-760) adds no price link — only
budgetIncrement <= MAX_TOPUP_BUDGET_PER_ACTION (=1_000_000, :682),
gasAmount > 0, balance >= gasAmount — and Laws.topUpActionBudget
(Laws/TopUpActionBudget.lean:15-24) charges only gasAmount. So at
refundRate 0 the seal is provably vacuous
(topUpRoundTripCheck_true_of_zero_rate, :998-1001) and 1 wei mints 1e6
units, redeemable at the other blessed leg subject only to
refundableBudget …

**Suggested remediation.**

Make the price link resource-invariant rather than per-leg. Either (a)
add a conjunct to both
`topUpActionBudget_gasCheck`/`topUpActionBudgetFor_gate` and
`claimBudgetRefund_gate` requiring the mint to be priced at the
MAXIMUM blessed rate — i.e. replace `refundRate gasResource` in
`topUpRoundTripCheck` with `max (refundRate 0) (refundRate 1)` — so
budget bought on the cheap leg still costs at least what the rich leg
will pay; or (b) partition the budget ledger per resource
(`EpochBudgetState : TreeMap (ActorId x ResourceId) ActorBudget`) so a
unit is only redeemable on the leg it was bought on. Option (a) is the
minimal change and preserves every existing GP.3.2/GP.3.4 theorem; …


### MAJOR (reported CRITICAL) — No gas-price floor on budget minting: with refunds disabled (the default) 1 wei mints 10^6 budget units, defeating the per-actor admission gate

*Where:* `LegalKernel/Authority/SignedAction.lean:747` — Lean sweep, verifier confidence high

`topUpActionBudget_gasCheck` (SignedAction.lean:747-758) requires only
`gasAmount > 0` and `getBalance >= gasAmount`; it imposes no relation
between `gasAmount` (gas actually paid) and `budgetIncrement` (budget
minted), bounding the latter only by the per-action ceiling
`MAX_TOPUP_BUDGET_PER_ACTION = 1000000` (SignedAction.lean:682). The
only conjunct that ties the two is `topUpRoundTripCheck`, which
`topUpRoundTripCheck_true_of_zero_rate` (SignedAction.lean:998) proves
is unconditionally `true` at the default `refundRate = fun _ => 0` —
the default on every production entry point
(`apply_admissible_with_budget`'s default argument,
SignedAction.lean:1166; `apply_bridge_admissible_with_budget`,
Bridge/Admissible.lean:483; and `RefundRateConfig.disabled` as the CLI
default, Runtime/RefundRateSidecar.lean:101). The gate's own docstring
(SignedAction.lean:676-681) recognises the hole and asserts 'each
repetition permanently moves gasAmount > 0 out of the signer's balance
into the real pool, and costs a budget unit to admit. The mint is
therefore paid for' — but `gasAmount > 0` is satisfied by 1 wei while
the mint is 10^6 units, so each repetition nets +999,999 budget for 1
wei. The per-actor budget gate is described in the same file as the
L2's only spam/DoS admission control.

**Failure scenario.**

Default deployment (no `--wei-per-budget-unit-*` flags, so refundRate
= fun _ => 0), `BudgetPolicy.bounded freeTier actionCost currentEpoch`
with actionCost = 1. Attacker A is a registered actor holding 1000 wei
of resource 0 (1e-15 ETH). A repeatedly signs `topUpActionBudget
gasResource=0 gasAmount=1 budgetIncrement=1000000
poolActor=gasPoolActor`. Each submission: - passes
`topUpActionBudget_gasCheck` (gasAmount = 1 > 0, balance >= 1,
budgetIncrement = 1000000 <= MAX_TOPUP_BUDGET_PER_ACTION), - passes
`topUpRoundTripCheck` vacuously (1000000 * 0 = 0 <= 1), - consumes 1
budget unit and grants 1000000 (SignedAction.lean:1223-1228), - debits
exactly 1 wei from A. After 1000 such actions A holds ~10^9 action-
budget units and has spent 1000 wei. A can then submit ~10^9 arbitrary
admitted actions (transfers, policy churn, withdrawals) before the
budget gate refuses anything, i.e. the …

**Verifier's finding.**

VERIFIED REAL. Traced end-to-end in source. 1.
topUpActionBudget_gasCheck
(LegalKernel/Authority/SignedAction.lean:747-758) imposes NO relation
between gasAmount and budgetIncrement: only `gasAmount > 0`,
`getBalance >= gasAmount`, and `budgetIncrement <=
MAX_TOPUP_BUDGET_PER_ACTION = 1000000` (line 682). 2. The kernel law
cannot compensate: Laws/TopUpActionBudget.lean:15-24 takes the
parameter as `_budgetIncrement` and never uses it; `pre` is only
`getBalance >= gasAmount /\ AmountBounded ...`. 3. The only conjunct
tying the two, topUpRoundTripCheck (SignedAction.lean:966-971), is
`budgetIncrement * refundRate gasResource <= gasAmount`, which
topUpRoundTripCheck_true_of_zero_rate (line 998) proves
unconditionally true at rate 0. Rate 0 is the default at every level I
checked: apply_admissible_with_budget:1166,
Bridge/Admissible.lean:483, Runtime/Loop.lean:126, and
Main.lean:1133-1141 (`ofFlags (refundRateEth.getD 0)
(refundRateBold.getD 0)`), i.e. zero unless --wei-per-budget-unit-eth
is passed. REFUTATION ATTEMPTS, ALL FAILED: - bridgeAuthorizedAction
returns false for …

**Suggested remediation.**

Add a deployment-configured minimum price per budget unit to
`topUpActionBudget_gasCheck` and `topUpActionBudgetFor_gate`,
independent of `refundRate`: a conjunct `budgetIncrement *
minWeiPerBudgetUnit gasResource <= gasAmount` with
`minWeiPerBudgetUnit` threaded from the runtime alongside `refundRate`
(and required to be >= 1 on every blessed leg). That makes the mint
proportional to gas paid under every configuration, including the
refunds-disabled default, and makes `MAX_TOPUP_BUDGET_PER_ACTION` a
secondary bound rather than the only one. The existing GP.3.2 theorems
are unaffected because the new conjunct is another `decide` in the
same `Bool` gate.


### MAJOR (reported CRITICAL) — Bridge-signed `ammSwap` is actor-parametric with no admission conjunct pinning the reserve actor — it can debit an arbitrary actor's balance

*Where:* `LegalKernel/Bridge/Admissible.lean:271` — Lean sweep, verifier confidence high

`BridgeAdmissibleWith` (Admissible.lean:271-311) adds conjunct 9
pinning `.reclaimAmmReserves`'s actor fields to the canonical reserved
slots, with the explicit rationale "the kernel law is actor-
parametric, so without this pin a bridge-signed action could sweep an
ARBITRARY actor's balance into an arbitrary recipient"
(Admissible.lean:296-301). The sibling action `.ammSwap` is equally
actor-parametric — `Action.compile` maps `.ammSwap fr tr ai ao ra`
straight to `Laws.ammSwap fr tr ai ao ra` (Authority/Action.lean:623)
and `Laws.ammSwap` debits the *supplied* `ammReserveActor` at
`toResource` (Laws/AmmSwap.lean:83-87) — but NO conjunct pins that
field. `bridgeAuthorizedAction` wildcards every field (`| .ammSwap _ _
_ _ _ => true`, BridgeActor.lean:480), `Action.isBridgeOnly` likewise
(Admissible.lean:113), and the `ammReservePolicy` LocalPolicy is keyed
on `st.signer` (Authority/SignedAction.lean:264-267), so it is never
consulted for a bridgeActor-signed swap. The docstrings assert the
opposite: BridgeActor.lean:206-209 claims the reserve actor's balances
are "mutated only by bridge-attested `ammSwap` actions ... no other
action targets this actor", and BridgeActor.lean:248-251 offers
`ammReserveActor_ne_gasPoolActor` as "Guarantees an `ammSwap` mutates
a ledger domain disjoint from the gas pool" — a theorem about two
constants that says nothing about the action's field. …

**Failure scenario.**

With the bridge key (or a buggy/compromised L1 event watcher), submit
`SignedAction { signer := bridgeActor, action := .ammSwap 7 0 1 V
victim }` where `V = getBalance s 0 victim`. Every `Laws.ammSwap`
precondition holds: `getBalance s 0 victim ≥ V` ✓, `7 ≠ 0` ✓,
`amountIn = 1 > 0` ✓, `AmountBounded s 7 victim 1` ✓. `bridgePolicy`
authorises it (wildcarded), conjunct 8 is satisfied (signer =
bridgeActor), and no conjunct 9 analogue exists. The step credits
`victim` 1 unit of the junk resource 7 and debits `victim`'s entire
resource-0 balance, which is credited to nobody — the funds are
destroyed. Substituting `gasPoolActor` for `victim` drains the gas
pool at leg 0 while `pool_drain_bounded_by_action_count` remains
silent, because that theorem's `hext` hypothesis is exactly what this
action falsifies.

**Verifier's finding.**

Verified end-to-end in source. BridgeAdmissibleWith
(LegalKernel/Bridge/Admissible.lean:270-310) has nine conjuncts;
conjunct 9 pins .reclaimAmmReserves's actor fields to
ammReserveActor/gasPoolActor with an explicit rationale about actor-
parametric kernel laws, and there is no analogous conjunct for the
equally actor-parametric .ammSwap. Trace: (a) Action.compile maps
.ammSwap fr tr ai ao ra straight to Laws.ammSwap fr tr ai ao ra
(Authority/Action.lean:623); (b) Laws.ammSwap credits the SUPPLIED
actor at fromResource and debits it at toResource
(Laws/AmmSwap.lean:74-87), with preconditions bal(to,ra) >= amountOut,
from != to, amountIn > 0, AmountBounded — all satisfiable with
.ammSwap 7 0 1 V victim where V = getBalance s 0 victim; (c)
Action.isBridgeOnly .ammSwap = true (Admissible.lean:113) so conjunct
8 only forces signer = bridgeActor, which the attacker holds; (d)
bridgeAuthorizedAction wildcards all five fields
(BridgeActor.lean:480) and bridgePolicy is just signer = bridgeActor
AND bridgeAuthorizedAction (BridgeActor.lean:498-500); (e) the two
reserved-actor …

**Suggested remediation.**

Add a `BridgeAdmissibleWith` conjunct mirroring conjunct 9: `(∀ fr tr
ai ao ra, st.action = .ammSwap fr tr ai ao ra → ra = ammReserveActor ∧
(fr = 0 ∨ fr = 1) ∧ (tr = 0 ∨ tr = 1) ∧ es.bridge.ammDisabled =
false)`, with a projection theorem and a negative test that a non-
canonical `ra` is inadmissible. Restate
`ammReserveActor_ne_gasPoolActor`'s docstring claim as a real theorem
over admitted steps (e.g.
`ammSwap_admissible_does_not_touch_gasPool`).


### MAJOR — GP.7.3 pool-drain bound excludes the refund outflow by hypothesis, so the 'per-resource pool drain bound' does not bound total pool outflow

*Where:* `LegalKernel/Bridge/PoolDrainBound.lean:723` — Lean sweep, verifier confidence high

The headline `pool_drain_bounded_by_action_count_per_resource`
(PoolDrainBound.lean:762-771) is stated over `PoolBoundedTrace`, whose
`step` constructor (PoolDrainBound.lean:718-727) carries the
hypothesis `hext : st.signer != gasPoolActor -> getBalance es.base
rLeg gasPoolActor <= getBalance (apply_admissible_with ...) rLeg
gasPoolActor` — i.e. every non-pool-signed step is *assumed* not to
lower the pool balance. That hypothesis is exactly the conclusion for
those steps, and the only mechanism offered to discharge it is
`Action.doesNotDebitPoolAt` (PoolDrainBound.lean:388-423), whose
`claimBudgetRefund` arm (line 406) is `gr != rLeg \/ pa !=
gasPoolActor` — false precisely for a real refund. So a user-signed
`claimBudgetRefund gasResource=0 ... poolActor=gasPoolActor` cannot be
a step of any `PoolBoundedTrace` at leg 0, and the theorem says
nothing about traces containing one. The module comment (lines
394-405) acknowledges this and delegates: 'The refund outflow is
bounded SEPARATELY by the GP.9.1 admission gate -- per-action by pool
solvency ... and by the free-tier-excluding budget consume'. Pool
solvency is only 'the balance cannot go negative', which is not a
bound; the free-tier-excluding consume only bounds *units*, and the
price of those units is the round-trip seal — which findings 1 and 2
show does not bound anything at rate 0 or across legs. The net effect
is that …

**Failure scenario.**

Deployment with maxDrainPerActionEth = 1 ETH intersects
`gasPoolAuthorityPolicy` and believes GP.7.3 guarantees the pool loses
at most n * 1 ETH over n admitted actions. Attacker A instead drives
the refund path: n admitted `claimBudgetRefund gasResource=0
budgetUnits=B weiPerBudgetUnit=refundRate 0 poolActor=gasPoolActor`
actions. Each is signed by A (not gasPoolActor), so `hpool` is
vacuous, and each lowers `getBalance es.base 0 gasPoolActor` by `B *
refundRate 0`, violating `hext` — the trace is simply outside
`PoolBoundedTrace` and the proved bound never applies. The pool can be
drained to zero in a single such action if B * rate equals the pool
balance, regardless of `maxDrainPerActionEth`.

**Verifier's finding.**

Verified line by line. PoolBoundedTrace.step
(PoolDrainBound.lean:718-727) carries hext, which for non-pool signers
IS the per-step conclusion (pool_step_drain_le:634 discharges that
branch by `Nat.le_trans (hext hs) …`). The only discharge mechanism is
Action.doesNotDebitPoolAt:388, whose claimBudgetRefund arm (:406) is
`gr != rLeg \/ pa != gasPoolActor`. That excluded case is not
hypothetical: claimBudgetRefund_gate
(Authority/SignedAction.lean:1090-1105) PINS `poolActor =
gasPoolActor` and `gasResource in {0,1}` and requires `1 <=
weiPerBudgetUnit` and `1 <= budgetUnits`, so every admitted refund
debits gasPoolActor at a gas leg by >= 1; Laws.claimBudgetRefund
(Laws/ClaimBudgetRefund.lean:95-108) is a genuine debit-then-credit
and AdmissibleWith implies the precondition holds (used as h.2.2.2.1
at PoolDrainBound.lean:257), so the step really lowers the balance and
hext is false. The trace is unconstructible and the headline theorem
covers no trace containing a refund. Refutations attempted and failed:
gasPoolAuthorityPolicy (GasPoolPolicy.lean:848-856) is `else True` for
non-pool …

**Suggested remediation.**

Either extend `PoolBoundedTrace` with a refund arm that carries the
refund's own per-action cap (so the bound becomes `n * (legCap +
maxRefundPerAction)` and covers both outflow paths), or add a per-
action refund cap conjunct to `claimBudgetRefund_gate` (e.g.
`budgetUnits * weiPerBudgetUnit <= maxRefundPerAction gasResource`)
and prove a companion `refund_drain_bounded_by_action_count` over a
trace relation that admits refunds. Until one of those exists, the
CLAUDE.md headline row and the PoolDrainBound module docstring should
not be read as bounding total pool outflow.


### MAJOR (reported CRITICAL) — `LocalPolicyClause.capAmount`'s `max : Amount` is encoded on the 8-byte uint head, silently truncating wei-denominated caps mod 2^64

*Where:* `LegalKernel/Encoding/LocalPolicy.lean:111` — Lean sweep, verifier confidence high

`capAmount` is declared with an `Amount`-typed field
(`LegalKernel/Authority/LocalPolicy.lean:174`: `| capAmount (resource
: ResourceId) (max : Amount)`) and its semantics compares against a
full unbounded `Nat`
(`LegalKernel/Authority/LocalPolicySemantics.lean:128-137`: `|
.transfer r' _ _ amt => r' ≠ r ∨ amt ≤ max`). But the encoder writes
it with `Encodable.encode (T := Nat) max` — the 9-byte `cbeTagUint`
head whose body is `natToBytesLE n 8` (`Encoding/CBOR.lean:283`),
which truncates mod 2^64. This is the one Amount-typed field in the
whole tree left on the narrow head; every other value-carrying field
(`transfer`/`mint`/`burn` amounts, `userAmount`/`poolAmount`,
`ammReserveEth`, `boldTvlCap`, balances via `AmountValue`) was
migrated to `encodeAmount`'s 33-byte `cbeTagAmount` head.
`LocalPolicyClause.fieldsBounded` (line 64-65) codifies the narrow
bound `max < 256 ^ 8` rather than the `256 ^ 32` every other amount
site carries, so the round-trip/injectivity ladder
(`localPolicyClause_roundtrip`, `LocalPolicy.encodeAsBytes_injective`,
`LocalPolicies.encodeMap_injective`) is only stated below 2^64 —
exactly the range `Encoding/CBOR.lean`'s own `cbeTagAmount` docstring
says wei amounts leave at ~18.45 ETH. Nothing on the production path
enforces the bound: `Laws/LocalPolicy.lean:60` has `lex_pre := fun _
=> True` and `Authority/SignedAction.lean:554` stores the action's …

**Failure scenario.**

A deployment declares the canonical gas-pool policy with a per-action
drain cap above 2^64 wei — e.g. `gasPoolPolicy (20 * 10^18) …`, i.e.
20 ETH, which `Bridge/GasPoolPolicy.lean:732`'s
`gasPoolPolicy_fieldsBounded` explicitly cannot discharge (`hEth :
maxDrainPerActionEth < 256 ^ 8`). (1) The live node enforces `amt ≤
20000000000000000000`. (2) `getCellValue es (.localPolicy
gasPoolActor)` (`FaultProof/CellValue.lean:120-129`) encodes `20e18
mod 2^64 = 1553255926290448384` (~1.553 ETH), so the published
`commitExtendedState` root is byte-identical to that of a state
holding a 1.553-ETH cap — two states with different admission
behaviour commit to the same root, the same class-C-3 defect
`Laws/AmountBound.lean` was written to close for balances. (3)
`Runtime/Snapshot.lean:140` writes `Encodable.encodeBytes (T :=
ExtendedState)`; `restoreSnapshot` (`Snapshot.lean:169`) decodes it
back …

**Verifier's finding.**

REAL, but the claimed attack surface is narrower than stated; severity
major, not critical. Verified in source: -
Encoding/LocalPolicy.lean:108-111 encodes capAmount's `max` with
`Encodable.encode (T := Nat)` = `cborHeadEncode` (CBOR.lean:213),
whose body is `natToBytesLE n 8`; its own docstring says values >=
2^64 are silently truncated. - The field is `Amount`
(Authority/LocalPolicy.lean:174) and its semantics compares against an
unbounded Nat (LocalPolicySemantics.lean:128-137, `amt <= max`). - The
asymmetry is exactly as claimed: Action.fieldsBounded gives every
amount `< 256^32` (Encoding/Action.lean:99-127, all via
`encodeAmount`'s 33-byte head), while LocalPolicyClause.fieldsBounded
gives `max < 256^8` (Encoding/LocalPolicy.lean:64-65). Laws.maxAmount
= 256^32 (Laws/AmountBound.lean:77), so admissible amounts far exceed
the cap's representable range. capAmount is the one Amount-typed field
left on the narrow head. - FaultProof/CellValue.lean:119-129 encodes
the localPolicy cell with that truncating encoder, while the sibling
.balance arm (100-104) explicitly uses encodeAmount …

**Suggested remediation.**

Route the field through the amount head: `LocalPolicyClause.encode`'s
`capAmount` arm becomes `... ++ encodeAmount max`,
`LocalPolicyClause.decode`'s tag-2 arm reads it with `decodeAmount`,
and `LocalPolicyClause.fieldsBounded` becomes `max < 256 ^ 32`. Update
`localPolicyClause_roundtrip`'s `capAmount` case to use
`amount_roundtrip`, and re-derive `gasPoolPolicy_fieldsBounded` /
`ammReservePolicy_fieldsBounded` under the widened bound. Mirror the
change in the Solidity `CBEEncode`/`CBEDecode` policy path and the
Rust decoders, and add a `capAmount` case to the cross-stack corpus
with a value above 2^64. Separately, make `Laws.declareLocalPolicy`
carry a decidable …


### MAJOR — Epoch-budget cell truncates mod 2^64 into the canonical-absent value; the `eb_val` bound is neither enforced nor correctly justified (C-3 reproduced on the budget cell)

*Where:* `LegalKernel/FaultProof/BoundsReachable.lean:315` — Lean sweep, verifier confidence high

`ExtendedState.CanonicalBounds.eb_val`
(LegalKernel/FaultProof/Commit.lean:777-778) requires
`p.2.budgetBalance < 256 ^ 8`. Unlike `base_amt` — which was promoted
from assumption to theorem by adding the `Laws.AmountBounded`
precondition conjunct to every crediting law — `eb_val` is left as a
standing assumption, justified only by the prose reachability argument
at BoundsReachable.lean:315-319. That argument is wrong in two ways.
(a) It names only `MAX_TOPUP_BUDGET_PER_ACTION` (= 1_000_000,
Authority/SignedAction.lean:682) as the per-action increment, but
`budgetGrant` (FaultProof/ProductionApply.lean:162-171) has a THIRD
arm — `.depositWithFee _ recipient _ _ _ g _ => ebs.topUp recipient
currentEpoch freeTier g` — whose `g` is an unbounded `Nat` field of
the action. Nothing in Lean bounds it: `Laws.depositWithFee`
(Laws/DepositWithFee.lean:16-26) takes it as `_budgetGrant` and
ignores it, its `pre` bounds only `userAmount`/`poolAmount`; the
admission gate `depositWithFee_signerCheck`
(Authority/SignedAction.lean:802-805) checks only `signer =
Bridge.bridgeActor`; and `ActorBudget.topUp`
(Authority/ActorBudget.lean:51-54) adds with no clamp. So in the very
relation this module reasons over (`AdmissibleReachable`),
`budgetBalance ≥ 2^64` is reachable in ONE step. (b) The section
claims "That argument is load-bearing, so it is stated here where it
can be checked rather than left …

**Failure scenario.**

Two `ExtendedState`s, `esA` and `esB`, identical except that in `esA`
actor `A` has `epochBudgets[A] = { lastSeenEpoch := 0, budgetBalance
:= 2^64 }` and in `esB` actor `A` has no `epochBudgets` entry.
`getCellValue esA (.epochBudget A) = encode 0 ++ encode (2^64)`, and
`natToBytesLE (2^64) 8` is eight zero bytes, so that equals `encode 0
++ encode 0 = canonicalAbsentValue (.epochBudget A)`.
`stateCellEntries` drops the cell in both states, so
`commitExtendedState esA = commitExtendedState esB` — the two states
publish the SAME root. Now apply the same `SignedAction` signed by `A`
(any non-bridge action) with `budgetPolicy = .bounded 0 1 0`.
`productionApplyBudget` (FaultProof/ProductionApply.lean:193-209)
takes the `else` branch and evaluates `EpochBudgetState.consume
es.epochBudgets A 0 0 1`. In `esA` the consume succeeds (`1 ≤ 2^64`)
and yields `budgetBalance = 2^64 - 1`, which is …

**Verifier's finding.**

The underlying defect is REAL and I traced every mechanical step, but
the finding's supporting narrative is substantially stale and two of
its three specific accusations are refuted by the current source. WHAT
I CONFIRMED (all verified against source, not docs): 1. `eb_val` is an
undischarged standing assumption.
`ExtendedState.CanonicalBounds.eb_val`
(LegalKernel/FaultProof/Commit.lean:777-778) requires
`p.2.budgetBalance < 256^8`. A grep for `CanonicalBounds` across all
`.lean` files shows exactly one discharge theorem —
`canonicalBounds_base_amt_of_reachable` (BoundsReachable.lean:512) —
and no `..._eb_val_of_reachable` or `..._nonces_val_of_reachable`
anywhere. So unlike `base_amt`, `eb_val` is assumed, not proved. 2.
The truncation collision is real by construction. `instEncodableNat`
(Encoding/Encodable.lean:196-197) = `cborHeadEncode cbeTagUint n` =
`major :: natToBytesLE n 8` (CBOR.lean:315-316), and `natToBytesLE`
(CBOR.lean:214-216) is `(n % 256) :: natToBytesLE (n/256) k` — a pure
mod-2^64 truncation with no range check. `budgetCellValue`
(CellStore.lean:109-112) is …

**Suggested remediation.**

Close it the same way `base_amt` was closed, rather than by trace-
length prose. Either (a) move the epoch-budget cell onto the 33-byte
amount head (`Encoding.encodeAmount`) so its modulus is 2^256 like the
balance cell, and widen `eb_val` to `< 256 ^ 32`; or (b) add an
enforced precondition conjunct — a `BudgetBounded es a grant :=
currentBudget … + grant < 256 ^ 8` predicate — to `budgetGateAdmits`
for all three granting arms (`depositWithFee`, `topUpActionBudget`,
`topUpActionBudgetFor`), mirroring `Laws.AmountBounded`. In either
case add the Lean-side bound `budgetGrant ≤ MAX_BUDGET_PER_DEPOSIT` to
`depositWithFee_signerCheck` so the L1 clamp is mirrored on the
verified surface instead …


### MAJOR — The epoch-budget cell rides the truncating 8-byte CBE head, so `commitExtendedState` is not injective in `budgetBalance` — and at `budgetBalance ≡ 0 (mod 2^64)` the cell disappears from the root entirely (C-3, unclosed for budgets)

*Where:* `LegalKernel/FaultProof/CellValue.lean:170` — Lean sweep, verifier confidence high

`getCellValue es (.epochBudget a)` encodes both components through
`Encodable.encode (T := Nat)`, i.e. `cborHeadEncode`, whose body is
`natToBytesLE n 8` — a *fixed 8-byte little-endian* body that silently
reduces `n` mod 2^64 (`LegalKernel/Encoding/CBOR.lean:315`,
`natToBytesLE n k` at :214 takes `n % 256` k times). `budgetBalance`
is a wei-denominated, ACCUMULATING quantity (`ActorBudget.topUp` =
`budgetBalance + amount`, `LegalKernel/Authority/ActorBudget.lean:53`,
with no ceiling anywhere), yet it is encoded on the narrow head
reserved for identifiers and counters. Consequences: (1) two states
whose `budgetBalance` differs by exactly 2^64 produce byte-identical
epoch-budget cell values, hence identical `commitExtendedState` roots;
(2) far worse, when `budgetBalance ≡ 0 (mod 2^64)` and `lastSeenEpoch
= 0` (which is the *permanent* case under the default `epochLength =
0`, where `BudgetPolicy.advanceEpoch` is the identity), the cell value
is byte-identical to `canonicalAbsentValue (.epochBudget a)` = `encode
0 ++ encode 0` (`CellValue.lean:79-81`), so `stateCellEntries`'
canonicalising filter
(`LegalKernel/FaultProof/StateCells.lean:113-116`) DROPS the cell and
the published root is identical to that of a state where the actor
holds no budget at all. This is precisely the failure mode
`LegalKernel/Laws/AmountBound.lean` documents as finding C-3 and
closes for balances with …

**Failure scenario.**

Deployment runs the default budget policy `.bounded ft ac 0` with
`epochLength = 0`, so `currentEpoch` stays 0 and every
`ActorBudget.normalise` writes `lastSeenEpoch := 0`. The sequencer's
bridge identity submits two `depositWithFee` actions crediting actor A
with `budgetGrant = 2^64 - 1` and `budgetGrant = 1` (the L2 gate
imposes no bound on `budgetGrant`; only `signer = bridgeActor` is
checked). A's `epochBudgets` entry is now `{lastSeenEpoch := 0,
budgetBalance := 2^64}`. `getCellValue` reads `encode 0 ++ encode
(2^64)`; `natToBytesLE (2^64) 8` is eight zero bytes, so the value is
byte-identical to `canonicalAbsentValue (.epochBudget A)`, the filter
in `stateCellEntries` drops the entry, and `commitExtendedState`
equals the root of the same state with A holding no budget. A can now
pay for 2^64 admitted actions that the published state root — and
therefore every fault-proof opening …

**Verifier's finding.**

Verified end-to-end in source. (1) `Encodable Nat` is `cborHeadEncode
cbeTagUint n = tag :: natToBytesLE n 8` (Encodable.lean:196,
CBOR.lean:214-216/315-316) — a fixed 8-byte LE body that truncates mod
2^64; its round-trip and injectivity theorems are explicitly gated on
`n < 256^8`. (2) `getCellValue es (.epochBudget a)`
(CellValue.lean:170-174) puts BOTH `lastSeenEpoch` and the
accumulating `budgetBalance` on that head, and `canonicalAbsentValue
(.epochBudget _)` is `encode 0 ++ encode 0` (CellValue.lean:79-81), so
`{0, 2^64}` is byte-identical to absent; `stateCellEntries`' filter
(StateCells.lean:113-116) then drops it from `commitExtendedState`
(StateCells.lean:158). With the default `epochLength = 0`,
`advanceEpoch` is the identity (Nonce.lean:100-112) so `lastSeenEpoch`
stays 0 and the vanish case — not merely the alias case — is the live
one. (3) `budgetBalance` accumulates with no ceiling anywhere:
`ActorBudget.topUp` (ActorBudget.lean:51-53), `EpochBudgetState.topUp`
(:239-242), `ProductionApply.budgetGrant` (:162-170) — no clamp, no
min. (4) No `AmountBounded` analogue …

**Suggested remediation.**

Apply the C-3 remedy to the budget cell rather than to balances alone.
Either (a) move `budgetBalance` (and `budgetGrant` in
`DepositRecord.encode`) onto the 33-byte `encodeAmount` head so the
modulus matches the EVM word, updating `CanonicalBounds.eb_val` to `<
256 ^ 32` and the Solidity `CBEEncode`/`StepWrites` mirrors in
lockstep; or (b) add a `BudgetBounded`-style conjunct — `(normalise
…).budgetBalance + amount < 256 ^ 8` — to the *state-transforming*
budget arm (`EpochBudgetState.topUp` call sites in
`apply_admissible_with_budget` /
`apply_bridge_admissible_with_budget`), so an over-ceiling grant is a
no-op exactly as an over-ceiling credit is, and cap `depositWithFee`'s
`budgetGrant` …


### MAJOR — `CellWriteReady.keysInjective` is self-contradictory for any cell the state actually holds, so `verifyStateCellProof_buildStateCellProof` is vacuous exactly on present cells

*Where:* `LegalKernel/FaultProof/CellWrites.lean:155` — Lean sweep, verifier confidence high

`CellWriteReady es t` requires `keysInjective : ∀ t' ∈ stateCellTags
es, getCellValue es t' ≠ canonicalAbsentValue t' → smtCellKey t' ≠
smtCellKey t`, quantified over *every* enumerated tag with no `t' ≠ t`
side condition. If the cell `t` being opened is present (`getCellValue
es t ≠ canonicalAbsentValue t`), then `t ∈ stateCellTags es` follows
by the contrapositive of `getCellValue_of_not_mem`
(`LegalKernel/FaultProof/StateCellsInjective.lean:303`), and
instantiating the field at `t' := t` yields `smtCellKey t ≠ smtCellKey
t` — False. So `CellWriteReady es t` is inhabited only when
`getCellValue es t = canonicalAbsentValue t`, i.e. only for ABSENT
cells. `verifyStateCellProof_buildStateCellProof`
(CellWrites.lean:173, listed in CLAUDE.md as the B-3 headline 'The
canonical opening verifies') therefore proves nothing about the case
it exists for: opening a live cell. Its own proof splits on `h_abs`
and uses `keysInjective` only in the absent branch and `distinct` only
in the present branch — the present branch is discharged under a
contradictory hypothesis. The scoping bug is a mis-transplant:
`canonicalSiblings_verifies_absent`
(`StateCellsInjective.lean:617-621`) carries the identical predicate
legitimately, because there `h_abs` makes the antecedent false at `t'
= t`; the docstring at StateCellsInjective.lean:608-616 even explains
that scoping choice, and the structure …

**Failure scenario.**

Take any state with a live balance, e.g. `base` with `getBalance base
1 7 = 100`, and `t := CellTag.balance 1 7`. Then `getCellValue base t
≠ canonicalAbsentValue t`, so `t ∈ stateCellTags base` and any `h :
CellWriteReady base t` gives `h.keysInjective t ‹t ∈ stateCellTags
base› ‹value ≠ absent› : smtCellKey t ≠ smtCellKey t`, from which
`False` follows in one step. Consequently
`verifyStateCellProof_buildStateCellProof base t h` is derivable for
*any* conclusion whatsoever and establishes no completeness guarantee
for the openings the observer actually publishes as `proofData` via
`buildCellProofWithOpening`. A future change that broke
`buildStateCellProof` for present cells — a wrong sibling order, an
off-by-one in `setBitmaskBit`, a dropped non-empty sibling — would
leave this theorem still provable, so the proof layer would not flag
it; only the fixture test would.

**Verifier's finding.**

Confirmed by compiling against the project's own build artifacts.
`CellWriteReady.keysInjective`
(LegalKernel/FaultProof/CellWrites.lean:155-156) quantifies over every
`t' ∈ stateCellTags es` with no `t' ≠ t` guard. Since
`getCellValue_of_not_mem` (StateCellsInjective.lean:303) is total over
all fifteen CellTag constructors, `getCellValue es t ≠
canonicalAbsentValue t` gives `t ∈ stateCellTags es` by
contraposition, and instantiating the field at `t' := t` yields
`smtCellKey t ≠ smtCellKey t`, hence False. I compiled `theorem
cellWriteReady_forces_absent ... := Classical.byContradiction fun h_ne
=> h.keysInjective t (Classical.byContradiction fun hc => h_ne
(getCellValue_of_not_mem es t hc)) h_ne rfl` against
LEAN_PATH=.lake/build/lib/lean and it succeeded, so `CellWriteReady es
t` is uninhabited for every present cell and
`verifyStateCellProof_buildStateCellProof` (CellWrites.lean:173)
proves nothing about opening a live cell. Refutation attempts all
failed: no guard anywhere in the structure; no caller constrains the
input (grep finds ZERO non-test consumers — the sole reference …

**Suggested remediation.**

Add the missing side condition: `keysInjective : ∀ t' ∈ stateCellTags
es, t' ≠ t → getCellValue es t' ≠ canonicalAbsentValue t' → smtCellKey
t' ≠ smtCellKey t`, and in the absent branch supply
`canonicalSiblings_verifies_absent`'s unrestricted form by case-
splitting on `t' = t` (where `h_abs` discharges it). Then add a
regression test that *constructs* a `CellWriteReady` for a present
cell — e.g. `⟨…⟩` for `CellTag.balance 1 7` on the populated fixture —
so the hypothesis set is exhibited as inhabited rather than merely
assumed, matching the `collisionFreeOn_id` satisfiability discipline
used for `CollisionFreeOn`.


### MAJOR (reported CRITICAL) — Lean game model's terminal step adjudicates an unauthenticated, caller-supplied action — the L1 log-chain binding has no Lean counterpart

*Where:* `LegalKernel/FaultProof/Game.lean:336` — Lean sweep, verifier confidence high

> **Status (applies to this finding and the next): CLOSED at the
> model level.**  Two steps.  First, the batching cutover replaced
> the per-action mechanism this finding describes: the L1 no longer
> re-derives `_requireActionInLogChain` /
> `LogChain.actionCommit`-per-entry — `terminateOnSingleStep` now
> authenticates the disputed action by INCLUSION PROOF against the
> disputed batch's submitted `actionsRoot`
> (`_requireActionInBatch` / `ActionNotInBatch`, ruling R7), with the
> proven Lean primitive
> `LegalKernel.FaultProof.ActionsRoot.actionProof_binds_action`
> (under collision-freeness, a verifying opening at the action's key
> determines the signature-bound leaf commitment, hence the
> `(kind, signer, fields, sig)` tuple).  Second — the remediation this
> finding asks for — the Lean game model now carries the anchor and
> gates on it: `GameState.actionsRoot` models the L1's
> `roots[disputedLogIndex].actionsRoot` (immutable while the game is
> open, since `markDisputed` blocks the R3 overwrite), the
> `.terminateOnSingleStep` transition takes the responder's
> `actionProof : SmtCellProof`, and the arm refuses (`.error
> .actionNotInBatch`, mirroring the L1 revert — retryable, not a
> loss) any step whose signature is not the fixed 65 bytes or whose
> signature-bound leaf does not open at `gs.range.low.idx` against
> the anchor.  `terminate_ok_requires_authentication` inverts the
> arm (any `.ok` outcome implies authentication), and the upgraded
> composite `anchored_challenger_wins`
> (`FaultProof/Settlement.lean`) derives the responder's spelling
> from the batch-committed one via `actionProof_binds_action` — so
> kernel-truthfulness is now hypothesised about the COMMITTED
> `(kind, signer, fields, sig)` tuple, not about whatever step the
> responder chose, which is precisely the substitution attack in the
> failure scenario below.  Value-level pins: substituted action /
> re-signed action / mis-width signature all refuse with
> `actionNotInBatch` (`Test/FaultProof/Settlement.lean`).  The one
> residual interface: `anchored_challenger_wins`'s truthfulness
> hypothesis quantifies over the responder's bundle (verifier
> proof-independence is not itself a theorem); it is discharged
> per-variant by the `VerifierWrites.*_correct` derivation
> discipline.  On-chain SIGNATURE verification at terminate remains
> the separately-recorded F-A follow-up in
> `19-findings-and-followups.md`'s SB close-out.

`applyTransition gs (.terminateOnSingleStep step)` calls
`kernelStepApply step` and compares the result against
`gs.range.high.commit`, but nothing anywhere in the Lean model
constrains `step.signedAction` to be the action the L2 actually
executed at that log index. The Solidity contract does exactly this
check (`KnomosisFaultProofGame.sol:498`
`_requireActionInLogChain(g.high.idx, actionKind, actionFields,
signer)`, whose own error docstring at :207-215 says that without it
"a party about to lose could search for a different action whose step
reproduces the disputed root and settle in its favour on a step that
never happened"). The Lean `GameState` (Game.lean:108-138) carries no
`prevLogEntryHash`/`expectedNextHash` field, and the two primitives
that would implement the check — `StepVMCoherence.l1ActionCommit`
(StepVMCoherence.lean:513) and `StepVMCoherence.l1NextEntryHash`
(:524) — exist in Lean and have no caller in the game. The
`GameTransition` docstring at Game.lean:145-170 nevertheless claims
"Both non-trivial transitions take strictly less from the caller than
the state machine needs and derive the rest from `gs`" and that the
transition "mirrors the 5-argument
`KnomosisFaultProofGame.terminateOnSingleStep`" — the shipped contract
function takes 8 arguments and performs the binding.

**Failure scenario.**

A dishonest sequencer publishes a fabricated root R at log index i.
The challenger bisects honestly; `Honesty.disagreement_persists_on_*`
keeps `low.commit = truth low.idx` and `high.commit = R ≠ truth
high.idx`, and the range narrows to `[i-1, i]` with `gs.turn =
.sequencer`. The sequencer chose R in the first place, so it can pick
R to be `commitExtendedState (productionApplyBudget es st' i)` for
some *other* action `st'` (e.g. a transfer crediting itself) that it
can actually build an honest bundle for from the real pre-state. It
then submits `KernelStep { preStateCommit := gs.range.low.commit,
signedAction := st', l2LogIndex := i, bundle := stepMultiBundle es st'
}`. `verifierPostRootMulti` accepts (the bundle is honest for `st'`),
returns R, the guard at Game.lean:345 succeeds, and `applyTransition`
settles `.sequencerWon` — the sequencer defends a fabricated root with
an action …

**Verifier's finding.**

Verified against source, not docs. Game.lean:314-359's
terminateOnSingleStep branch guards only status/isSingleStep/no-
pending-midpoint/preStateCommit; it then calls kernelStepApply
(Step.lean:118-120), which feeds step.signedAction.action,
step.signedAction.signer and step.l2LogIndex straight from the caller-
supplied KernelStep into verifierPostRootMulti. GameState
(Game.lean:108-138) carries no prevLogEntryHash/expectedNextHash, and
a repo-wide grep shows l1ActionCommit (StepVMCoherence.lean:513) and
l1NextEntryHash (:523) have no caller outside tests — so the L1
binding truly has no Lean counterpart. The Solidity mirror does bind:
KnomosisFaultProofGame.sol:498 calls _requireActionInLogChain,
implemented at :551-574 by re-deriving
LogChain.nextEntryHash(prevLogEntryHash, stateCommit,
LogChain.actionCommit(kind, signer, fields)) and reverting on
mismatch; its error docstring at :206-216 describes exactly the attack
the Lean model allows. The attack is constructible and does not even
need a search: the sequencer holds the real pre-state es with
commitExtendedState es = low.commit …

**Suggested remediation.**

Add the log-entry-chain anchor to `GameState` (e.g.
`highPrevLogEntryHash`, `highStateCommit`, `highExpectedNextHash`,
populated at `initiateChallenge` time as the contract does), and gate
the `.terminateOnSingleStep` arm on `l1NextEntryHash
highPrevLogEntryHash highStateCommit (l1ActionCommit
step.signedAction.action step.signedAction.signer) =
highExpectedNextHash`, awarding the loss to the responder when it
fails — mirroring `ActionNotInLogChain`. Then restate
`honest_challenger_wins_against_invalid_state_root` so
`h_kernel_truthful` is *derived* from the anchor plus
`stepMultiFold_eq_commit_post`, rather than assumed.


### MAJOR (reported CRITICAL) — Lean game model's terminal step never binds the executed action to the disputed log entry (Solidity does); the headline settlement theorems are proved over this weaker model

*Where:* `LegalKernel/FaultProof/Game.lean:314` — Lean sweep, verifier confidence high

`applyTransition`'s `.terminateOnSingleStep` branch
(Game.lean:314-341) validates exactly three things: game status,
single-step range, no pending midpoint, and `step.preStateCommit =
gs.range.low.commit`. It then calls `kernelStepApply step`, which
executes `step.signedAction.action` / `step.signedAction.signer` —
both caller-supplied fields of the responder's `KernelStep`
(Step.lean:53-75) — and compares the result against
`gs.range.high.commit`. Nothing anywhere in `GameState`
(Game.lean:101-137) carries a log-entry-chain commitment, and nothing
checks that `step.signedAction` is the action the sequencer actually
committed to at index `gs.range.high.idx`. The production contract
does perform this check:
`KnomosisFaultProofGame.terminateOnSingleStep` calls
`_requireActionInLogChain(g.high.idx, actionKind, actionFields,
signer)` (solidity/src/contracts/KnomosisFaultProofGame.sol:498,
551-574) and reverts with `ActionNotInLogChain` on mismatch. So the
Lean model — the object every `Settlement.lean` theorem, including
`honest_challenger_wins_against_invalid_state_root`
(Settlement.lean:213) and
`terminate_responder_loses_when_step_differs` (Settlement.lean:99), is
stated about — is strictly weaker than the deployed game, and the
inline comment at Game.lean:310-313 ("Neither side of that comparison
comes from the caller") is false of the action itself.

**Failure scenario.**

A dishonest sequencer publishes root R_{i+1} that is NOT the result of
applying the real log entry i, but is the result of applying some
substituted action a' (transaction censorship/substitution). A
challenger disputes and bisects to the single step [low=(i,R_i),
high=(i+1,R_{i+1})]. The sequencer is the responder and calls
`terminateOnSingleStep` with a `KernelStep` whose `preStateCommit =
R_i` (passes the only binding check) and whose `signedAction` is a',
with the honest multiproof for a' against R_i. `kernelStepApply step`
returns `some R_{i+1}`, the equality at Game.lean:343 holds, and
Game.lean:344-350 awards `sequencerWon`. The fabricated root is upheld
and the challenger's bond is slashed. In Lean this is fully reachable;
the only thing preventing it in production is a check that exists
solely in Solidity and is therefore unmodelled and unproved.

**Verifier's finding.**

Verified by reading source. Game.lean:314-359 gates
.terminateOnSingleStep on only four conditions (status, isSingleStep,
no pendingMidpoint, step.preStateCommit = gs.range.low.commit), then
calls kernelStepApply and compares to gs.range.high.commit.
kernelStepApply (Step.lean:118-121) forwards step.signedAction.action
/ .signer / .l2LogIndex — all caller-supplied KernelStep fields
(Step.lean:53-75) — into verifierPostRootMulti
(Terminate.lean:426-474), which derives every post-cell value FROM the
supplied action (derivedCellValue ... a signer l2LogIndex plan t) and
only checks the pre-side walk against preRoot (line 469). GameState
(Game.lean:108-138) carries no log-chain commitment. I grepped the
entire Lean tree: l1ActionCommit / l1NextEntryHash exist only in
StepVMCoherence.lean:507-536 and are consumed ONLY by
LegalKernel/Test/Bridge/CrossCheck/StepVM.lean — no production Lean
module (Game, Settlement, Honesty, Strategy, Transcript) references
them. Transcript.chainKernelStepApplyFromLog builds steps from a log
but is never wired to applyTransition/GameState. Solidity does …

**Suggested remediation.**

Give `GameState`/`DisputedRange.Claim` the log-entry-chain fields the
contract reads (`prevLogEntryHash`, `stateCommit`, `expectedNextHash`
at `high.idx`) and add a guard in `applyTransition
.terminateOnSingleStep` mirroring `_requireActionInLogChain`:
recompute `StepVMCoherence.l1NextEntryHash prevLogEntryHash
stateCommit (StepVMCoherence.l1ActionCommit step.signedAction.action
step.signedAction.signer)` and treat a mismatch exactly as the
contract does (responder loses / refusal). Then restate the Settlement
theorems over the guarded transition.


### MAJOR — No theorem connects `verifierPostRootMulti` to the true post-state root in either direction; the settlement theorems' load-bearing hypothesis is never discharged

*Where:* `LegalKernel/FaultProof/Terminate.lean:426` — Lean sweep, verifier confidence high

`stepMultiFold_eq_commit_post` (Terminate.lean:1160) proves only the
inner `multiWalk` equality — that the merged walk of `openedOf
(productionApplyBudget …)` against the pre-state's siblings equals
`commitExtendedState (productionApplyBudget …)`. It is never composed
through `verifierPostRootMulti`'s wrapper (adjudicability gate, shape
check, policy lookup, `plannedBalances`, the two `filterMap` length
checks, `isWellFormedFor`, `expandMultiProof`, and the pre-root
comparison). Repo-wide grep shows `verifierPostRootMulti` /
`stepMultiPostRoot` appear in only four non-test files and in no
theorem's conclusion: there is no completeness result
`stepMultiPostRoot es st idx = some (commitExtendedState
(productionApplyBudget es st idx))` and, more importantly, no
soundness result `verifierPostRootMulti preRoot a signer idx b = some
c → c = <true post root>`. The file itself concedes the first
(Terminate.lean:513-517: "Composing this with the `*_correct` family
is the remaining step toward `stepMultiPostRoot = some
(commitExtendedState (productionApplyBudget …))`"). Consequently
`Settlement.honest_challenger_wins_against_invalid_state_root`
(Settlement.lean:213) is conditional on `h_kernel_truthful :
kernelStepApply step = some (truth gs.range.high.idx)` for an
arbitrary caller-supplied `truth : LogIndex → StateCommit`, and
`terminate_responder_loses_when_step_differs`'s docstring …

**Failure scenario.**

Two distinct failure modes are both unexcluded by the current proof
set. (a) Soundness: nothing rules out a bundle `b` for which
`verifierPostRootMulti (commitExtendedState es) st.action st.signer
idx b = some c` with `c ≠ commitExtendedState (productionApplyBudget
es st idx)`; if such a `b` exists (e.g. via any residual freedom in
the shape check, the gap-mask expansion, or the plan lookup),
`terminate_responder_wins_when_step_reproduces_high`
(Settlement.lean:79) upholds a fabricated `gs.range.high.commit` and
slashes the honest challenger. (b) Completeness: nothing rules out
`stepMultiPostRoot es st idx = none` for some honest `(es, st, idx)`;
Game.lean:336-341 then declares the honest responder the loser. Both
outcomes are checked only by nineteen/twenty value-level corpus probes
in `faultproof-terminate`, which is a spot check over a finite fixture
set, not a proof over the …

**Verifier's finding.**

Every factual claim in the finding checks out against the source. (1)
`stepMultiFold_eq_commit_post` (Terminate.lean:1160-1177) concludes an
equality about `multiWalk` on `openedOf`/`multiSiblings` only; it
never mentions `verifierPostRootMulti`, so the adjudicability gate
(:428), `frontierShapeOk` (:431), policy lookup (:434),
`plannedBalances` (:437), the two length checks (:456-457),
`isWellFormedFor` (:464), `expandMultiProof` (:466) and the pre-root
comparison (:469) are all outside any proof. (2) Repo-wide,
`verifierPostRootMulti`/`stepMultiPostRoot` occur in a theorem only
via `rfl`/`Iff.rfl` projections (Step.lean:127-132, Step.lean:326-330,
TerminateBundle.lean:240-243) — there is no `stepMultiPostRoot es st
idx = some (commitExtendedState (productionApplyBudget es st idx))`
anywhere. (3) The soundness direction is worse than "uncomposed": it
has no ingredients at all. `CollisionFreeOn` appears nowhere in
MultiProof.lean, Terminate.lean or Frontier.lean; every multiproof
theorem is stated on the honest `openedOf`/`multiSiblings` pair, i.e.
completeness. The retired …

**Suggested remediation.**

Prove the two wrapper-level theorems and thread them into Settlement:
(1) completeness — `stepMultiPostRoot es st idx = some
(commitExtendedState (productionApplyBudget es st idx))` under
`FaultProofAdjudicable`, `CanonicalBounds`, `KeyInjectiveOn` and the
`BitsDistinctBelow` side conditions, discharging each wrapper check
for the honest bundle (`isWellFormedFor_buildMultiProof`,
`expandMultiProof_buildMultiProof`, `postOpened_eq_openedOf`,
`plannedBalances_stateBalanceReader_isSome`) and finishing with
`stepMultiFold_eq_commit_post`; (2) soundness — `verifierPostRootMulti
preRoot a signer idx b = some c` plus a `CollisionFreeOn` hypothesis
over the step's own pre-images implies `c = …


### MAJOR — `Laws.ammSwap` places no relation between `amountOut` and the reserves, so a single admitted swap can zero the AMM reserve; the constant-product guarantee exists only in `AmmMath`, which nothing on the L2 path calls

*Where:* `LegalKernel/Laws/AmmSwap.lean:77` — Lean sweep, verifier confidence high

`AmmMath.getAmountOut` and its two soundness theorems
(`getAmountOut_lt_reserveOut`, `k_nondecreasing`, AmmMath.lean:61-162)
are never referenced by any non-test module — `grep getAmountOut` over
the Lean sources returns only `Bridge/AmmMath.lean` and
`LegalKernel/Test/**`. `Laws.ammSwap`'s precondition
(AmmSwap.lean:77-81) constrains `amountOut` only by `getBalance s
toResource ammReserveActor ≥ amountOut`, i.e. "at most the entire
reserve". `Bridge/Admissible.lean` adds no swap conjunct, and
`BridgeState.ammReserveEth` / `ammReserveBold` are never written by
any production Lean code (they are initialised to 0 at State.lean:334
and `applyActionToBridgeState` has `| _ => bs` for `.ammSwap`,
Admissible.lean:183), so even if the law wanted to check the curve
there is no committed reserve to check it against.
`AmmReservePolicy.lean:29-45` nevertheless claims "No
`requireRecipientIn` or `capAmount` clauses are needed because the L1
contract's `ammSwap` math (GP.11.3) already provides the deterministic
swap output" and concludes "`ammReserveActor`'s balances can only be
mutated by a legitimate, L1-attested AMM swap". The fault proof re-
executes L2 admission (`productionApplyBudget`), so an L2-admissible-
but-curve-violating swap is a *valid* state transition that no
challenger can dispute.

**Failure scenario.**

The L1 emits `AmmSwapExecuted(user, 0, 1, amountIn=1 wei,
amountOut=3)` and the watcher mis-decodes the log (or is compromised)
into `.ammSwap 0 1 1 R ammReserveActor` with `R` = the reserve actor's
entire resource-1 balance. `Laws.ammSwap.pre` holds (`getBalance s 1
ammReserveActor ≥ R` by construction, `0 ≠ 1`, `1 > 0`,
`AmountBounded` ✓), the action is bridge-authorised, and the step
executes. The L2 reserve at resource 1 goes to zero against 1 wei of
input while the L1 reserve is untouched, permanently desynchronising
the mirror; the resulting state root is *correct* under the fault-
proof's own reference semantics, so
`honest_challenger_wins_against_invalid_state_root` offers no
protection.

**Verifier's finding.**

Confirmed by direct source trace. (1) `getAmountOut` +
`getAmountOut_lt_reserveOut` + `k_nondecreasing`
(Bridge/AmmMath.lean:54-162) are imported by no production module —
only LegalKernel/Test/Bridge/AmmMath.lean and
Test/Bridge/CrossCheck/AmmMath.lean. (2) `Laws.ammSwap.pre`
(Laws/AmmSwap.lean:77-81) bounds `amountOut` only by `getBalance s
toResource ammReserveActor >= amountOut`, so `amountIn = 1, amountOut
= entire balance` is admissible — a single swap zeroes the leg. (3)
`BridgeAdmissibleWith` (Bridge/Admissible.lean:270-310) has conjuncts
6, 6b, 7, 8, 9 and none of them mentions `.ammSwap`. (4)
`bridgeAuthorizedAction` (BridgeActor.lean:480) returns `true` for
`.ammSwap _ _ _ _ _` and `bridgePolicy` (498-502) is only `signer =
bridgeActor and bridgeAuthorizedAction action`, constraining no field.
(5) `Action.compileTransition` (Authority/Action.lean:623) passes all
five fields through unmodified. (6) `applyActionToBridgeState` has `|
_ => bs` for `.ammSwap` (Admissible.lean:183) and
`ammReserveEth`/`ammReserveBold` are written nowhere in production
Lean (only …

**Suggested remediation.**

Mirror the L1 reserves into `BridgeState` on `.ammSwap` (extend
`applyActionToBridgeState`'s `.ammSwap` arm to update
`ammReserveEth`/`ammReserveBold`), then add a `BridgeAdmissibleWith`
conjunct requiring `amountOut = AmmMath.getAmountOut amountIn
(reserveIn es) (reserveOut es) ammSwapFeeBps`, and prove
`ammSwap_admissible → k_nondecreasing` over the mirrored reserves.
Until then, correct `AmmReservePolicy.lean`'s docstring to state that
the curve is unenforced on L2.


### MAJOR — BulkBounded caps live holders at 256, making both bulk laws unusable on any real deployment and permanently griefable by any unprivileged actor

*Where:* `LegalKernel/Laws/BulkBound.lean:121` — Lean sweep, verifier confidence high

`BulkBounded s r excluded` requires `(bulkRecipients s r
excluded).length ≤ 256`, and it is a conjunct of both bulk laws'
`Transition.pre` (`LegalKernel/Laws/DistributeOthers.lean:74-76`,
`LegalKernel/Laws/ProportionalDilute.lean:76-79`). `bulkRecipients` is
every actor holding a nonzero balance at `r` other than `excluded` — a
quantity no participant in the action controls and any third party can
inflate. Because the bulk laws compile signer-unawarely
(`Action.compileTransition` at
`LegalKernel/Authority/Action.lean:545-546` returns the real law),
`AdmissibleWith` conjunct 5
(`LegalKernel/Authority/SignedAction.lean:309`) evaluates this
precondition, so once the resource has 257 live holders every
`distributeOthers`/`proportionalDilute` at `r` is rejected at
admission — permanently. The stated justification for the cap no
longer holds: it is documented (BulkBound.lean:14-36) as bounding the
fault proof's per-recipient sub-step decomposition and as mirroring
`KnomosisStepVM.MAX_RECIPIENTS_PER_BULK_ACTION`, but (a)
`FaultProof.FaultProofAdjudicable`
(`LegalKernel/FaultProof/VerifierWrites.lean:1733-1736`) returns
`false` on exactly these two actions, so the L1 never adjudicates a
bulk step at all, and (b) `KnomosisStepVM.sol` and that constant no
longer exist anywhere in `solidity/` (grep returns no hits). The cap
therefore buys nothing operationally while imposing a hard …

**Failure scenario.**

Resource `r` runs a `proportionalDilute` reward program. Attacker A is
a registered actor holding 257 units of `r`. A submits 257 ordinary
`Action.transfer r A f_i 1` actions to 257 fresh `ActorId`s
`f_1..f_257` that A invented and for which no key will ever be
registered. Each transfer is admissible: `Laws.transfer.pre` holds
(balance ≥ 1, amount > 0, ceiling fine) and `AdmissibleWith` only
requires the *signer* to be in the registry
(`LegalKernel/Authority/SignedAction.lean:306`) — the receiver need
not exist. Now `bulkRecipients s r excluded` has ≥ 257 entries with
nonzero values, so `BulkBounded` is false. Every subsequent
`distributeOthers r excluded amount` and `proportionalDilute r
excluded totalReward` fails `AdmissibleWith` conjunct 5 and is
rejected forever. The dust is unrecoverable: only a balance's holder
can move it (`transfer`/`burn`/`withdraw` are all signed by the …

**Verifier's finding.**

VERIFIED. Every link in the chain checks out against source. 1. The
cap is a real precondition conjunct, not a comment.
`LegalKernel/Laws/BulkBound.lean:109-111` defines `bulkRecipients s r
excluded = (s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 !=
excluded && kv.2 != 0)` — every live (nonzero) holder at `r` except
one. `BulkBound.lean:120-122` makes `BulkBounded` `(...).length ≤ 256`
(`maxRecipientsPerBulkAction`, line 52). `DistributeOthers.lean:74-76`
and `ProportionalDilute.lean:76-79` both carry `BulkBounded s r
excluded` in `Transition.pre` (and in their `lex_pre` mirrors,
DistributeOthers.lean:94-98). 2. The precondition is reached at
admission with the real law. `Action.compileTransition`
(`Authority/Action.lean:546-547`) maps
`.distributeOthers`/`.proportionalDilute` to
`Laws.distributeOthers`/`Laws.proportionalDilute` (not the
`Laws.freezeResource 0` no-op used for the signer-aware/advisory
actions), and `AdmissibleWith` conjunct 5
(`Authority/SignedAction.lean:309`) is `(Action.compile
st.action).transition.pre es.base`. So above the cap the action is …

**Suggested remediation.**

Decouple the law's admissibility from a third-party-controlled
quantity. Either (a) drop `BulkBounded` from both `pre`s now that
`FaultProofAdjudicable` excludes the two actions from adjudication,
keeping the cap only where it is actually needed — as a hypothesis on
the `Action.stateWriteCells` enumeration lemmas in
`FaultProof/StepWriteSets.lean` — or (b) if a runtime cap must stay,
make the credited set a function of data the submitter controls (an
explicit recipient list in the action's fields, or a paginated
`distributeOthers r excluded amount offset count`) so a third party
cannot move the resource out of the admissible region. In either case
remove the dangling …


### MAJOR (reported CRITICAL) — Observer only ever moves in reaction to an opponent event, so the honest sequencer never submits its first midpoint and any deferred move is never retried

*Where:* `runtime/knomosis-faultproof-observer/src/observer.rs:693` — Rust / Solidity sweep, verifier confidence high

`maybe_play_move` is invoked from exactly two call sites --
`handle_midpoint_submitted` (observer.rs:1187) and
`handle_response_submitted` (observer.rs:1291). Nothing else drives
it: `handle_game_opened` deliberately does not (it records
`state_known=false`), and `hydrate_cold_start_games` (observer.rs:565,
called at observer.rs:693) flips `state_known` to true via
`mark_state_known` but never asks whether a move is now owed. There is
no per-iteration sweep over `self.games` for `status == InProgress &&
turn == me`. Consequently the observer can only act when the opposing
party has just acted.

**Failure scenario.**

The L1 contract sets `g.turn = TurnSide.Sequencer` at
`initiateChallenge` (KnomosisFaultProofGame.sol:361), so after a game
opens the SEQUENCER owes the first midpoint and the challenger
correctly does nothing. An observer with `play_as = Sequencer` adopts
the game from `FaultProofGameOpened` with `state_known=false` (no
move), hydrates it on the next iteration (state_known=true,
turn=Sequencer, pending_midpoint=None) -- and then waits for an event
that can never arrive, because the challenger has no legal move while
it is the sequencer's turn. `turnDeadline` expires and the challenger
calls `claimTimeout`, slashing an honest sequencer that never got to
defend. The same dead-end applies to every deferred move: a
`TruthOracleMissed` (observer.rs:1400), a `build_calldata_for_move`
failure (observer.rs:1413), or a `build_and_sign` failure
(observer.rs:1434) all return `Ok(Some(false))` and …

**Verifier's finding.**

Verified end-to-end in source. (1) `self.maybe_play_move(` has exactly
two call sites: observer.rs:1187 (handle_midpoint_submitted) and
observer.rs:1291 (handle_response_submitted). (2)
`run_iteration_inner` (observer.rs:663-780) contains no sweep over
`self.games` — it is recover_intent_records ->
hydrate_cold_start_games -> watcher.run_iteration -> per-event
handle_event -> commit_batch -> drain pending_broadcasts;
`Observer::run` (observer.rs:1601) merely loops that with a sleep. (3)
`mark_state_known` (observer.rs:481-530), the only thing
`hydrate_cold_start_games` (observer.rs:565) calls, flips
`state_known=true`, commits, logs, and returns — it never asks whether
a move is owed, contradicting its own docstring ("maybe_play_move will
then start submitting moves"). (4) The opponent cannot supply the
retrigger: KnomosisFaultProofGame.sol:364 sets `g.turn =
TurnSide.Sequencer` at initiateChallenge, and both submitMidpoint
(lines 403-405) and respondToMidpoint (lines 438-440) compute
`responsible = g.turn == Sequencer ? g.sequencer : g.challenger` and
revert NotResponsible for …

**Suggested remediation.**

Add a per-iteration sweep after hydration and after event dispatch:
for every `GameRecord` with `state.status.is_in_progress() &&
state_known && state.turn == me`, call `maybe_play_move`. That single
loop covers the sequencer's opening move, post-hydration catch-up, and
retry of every deferred move, and is naturally idempotent once the
pivot key is fixed (see the terminate-dedup finding).


### MAJOR — A move whose L1 broadcast fails is marked Failed and its pivot stays consumed forever, so one transient RPC error permanently forfeits the move

*Where:* `runtime/knomosis-faultproof-observer/src/observer.rs:883` — Rust / Solidity sweep, verifier confidence high

`maybe_play_move` inserts the pivot into `submitted_pivots` and stages
an `Intent` response record BEFORE the broadcast.
`broadcast_and_update_status` transitions the record to
`ResponseStatus::Failed` on a broadcast error.
`recover_intent_records` (observer.rs:795-806) re-broadcasts ONLY
records whose `status == ResponseStatus::Intent` -- a `Failed` record
is skipped forever. Meanwhile the pivot remains in the in-memory
`submitted_pivots` set (the rollback at observer.rs:649-655 only fires
when `run_iteration` returns `Err`, and a failed broadcast returns
`Ok`), and on restart the set is rebuilt from `response_records` with
no status filter (observer.rs:257-260), so the `Failed` record re-
blocks the same pivot.

**Failure scenario.**

The observer computes the correct honest midpoint, persists the Intent
record, and calls `eth_sendRawTransaction`; the RPC endpoint is
momentarily unreachable (or returns `already known`, or the tx-hash
echo mismatches -- jsonrpc_submitter.rs:596 turns that into
`TxHashMismatch`). `broadcast_and_update_status` logs a warning, marks
the record `Failed`, and invalidates the nonce cache. On every
subsequent iteration and after every restart,
`has_submitted_for_pivot` reports the pivot as already submitted, so
the move is never rebuilt or re-broadcast. The honest party silently
stops defending and loses the game by `claimTimeout` after a single
lost packet.

**Verifier's finding.**

Traced end-to-end in source. maybe_play_move (observer.rs:1450-1471)
persists the Intent record and inserts (game_id, pivot_idx) into
submitted_pivots before broadcast; run_iteration_inner clears
iteration_pivot_inserts on commit success (observer.rs:742) BEFORE the
broadcast phase (769-772), so the Err-path rollback at 649-656 is
doubly unreachable — and broadcast_and_update_status returns Ok(())
even on broadcast failure, so run_iteration never returns Err anyway.
The Err arm sets ResponseStatus::Failed (observer.rs:906) and persists
it. recover_intent_records skips anything not Intent
(observer.rs:802), and Observer::new rebuilds submitted_pivots from
list_responses() with no status filter (observer.rs:257-260), so the
Failed record re-blocks the pivot across restarts.
has_submitted_for_pivot then short-circuits the rebuild
(observer.rs:1420-1427). Refutation attempts all failed: the observer
never calls check_inclusion (defined at submitter.rs:999 /
jsonrpc_submitter.rs:647 but zero call sites in observer.rs), so the
Dropped->re-broadcast arrow in the persistence.rs:204 status …

**Suggested remediation.**

Either (a) leave the record in `Intent` on a broadcast failure (or add
a `Retryable` status) so `recover_intent_records` picks it up next
iteration, or (b) exclude `Failed` records from the startup
`submitted_pivots` rebuild and remove the pivot from the in-memory set
when the broadcast fails. Bound the retries with a `Failed` counter so
a genuinely unbroadcastable tx eventually alerts instead of looping.


### MAJOR — Observer is deadline-blind: it never claims an opponent's timeout, never checks tx inclusion, and never escalates fees

*Where:* `runtime/knomosis-faultproof-observer/src/state_reader.rs:490` — Rust / Solidity sweep, verifier confidence high

The state reader decodes `turnDeadline` (slot 11) and `lastStepBlock`
(slot 16) and immediately discards both (`let _turn_deadline = ...`,
`let _last_step_block = ...`), and `GameState` carries no deadline
field at all. Consequently the observer has no notion of the response
window: (1) it never submits `claimTimeout`, so
`encode_claim_timeout_calldata` (submitter.rs:904) has no non-test
caller; (2) `Submitter::check_inclusion` (jsonrpc_submitter.rs:610) is
never called by the orchestrator, so a broadcast tx that is dropped
from the mempool or mined-but-reverted is never noticed; (3)
`escalate_for_deadline` / `rebroadcast_with_bump`
(jsonrpc_submitter.rs:363, 404) have no non-test callers, so an under-
priced tx is never bumped. `check_inclusion_inner` additionally
ignores the receipt's `status` field, so a reverted transaction would
report `Some(true)` ("included") if it were ever consulted.

**Failure scenario.**

(a) A dishonest sequencer opens a game and then simply stops
responding. The honest challenger's observer records the game, sees no
further events, and never calls the permissionless `claimTimeout`
(KnomosisFaultProofGame.sol:580) -- so `_settle(TimedOutSequencer)`
never runs, the challenger's bond stays locked, the disputed root
stays un-finalised, and the challenger must intervene manually to
collect a win it has already earned. (b) The observer broadcasts a
correct midpoint at a fee below the prevailing base fee during a gas
spike; the tx never mines, nothing checks inclusion, no bump is
issued, and the honest party loses on `turnDeadline` while believing
it moved.

**Verifier's finding.**

Confirmed on every leg by reading source. (1) state_reader.rs:490
discards turnDeadline (`let _turn_deadline =
read_u64_from_slot(slot(11))`) and :507 discards lastStepBlock; slot
11 is verified to be `turnDeadline` against the Solidity `struct Game`
field order (KnomosisFaultProofGame.sol:103-121). game::GameState
(game.rs:216-248) has no deadline field, so the value cannot reach any
caller. (2) `claimTimeout` is permissionless on L1
(KnomosisFaultProofGame.sol:580, external nonReentrant, no auth) but
workspace-wide grep shows `encode_claim_timeout_calldata`
(submitter.rs:904) and `GameTransition::TimeoutLoss` (game.rs:298) are
referenced only from #[cfg(test)] modules and the two integration test
files; observer.rs contains neither. (3) `run_iteration_inner`
(observer.rs:663-786) is purely event-driven and never calls
`check_inclusion`; `broadcast_and_update_status` sets
ResponseStatus::Pending (observer.rs:885) and `recover_intent_records`
skips anything not Intent (observer.rs:802), so a Pending record is
never revisited. Decisive corroboration: `ResponseStatus::Confirmed`
and …

**Suggested remediation.**

Carry `turn_deadline` and `last_step_block` on `GameState`, and add a
per-iteration deadline pass that (1) submits `claimTimeout` when
`block.number > turnDeadline && turn != me`, (2) calls
`check_inclusion` on `Pending` responses and re-broadcasts/escalates
via `escalate_for_deadline` as the deadline approaches, and (3)
honours `MIN_BISECTION_STEP_INTERVAL_BLOCKS` before submitting so the
move is not wasted on a `BisectionStepTooFast` revert. Also parse the
receipt `status` in `check_inclusion_inner` and report a reverted tx
as not-included.


### MAJOR — The mux swallows the upstream TRUNCATED gap, so the ring holds a hole that `position` classifies as InWindow

*Where:* `runtime/knomosis-gateway/src/events/fanout/mux.rs:169` — Rust / Solidity sweep, verifier confidence high

`Mux::run_epoch`'s `StreamItem::Gap` arm (lines 169-179) resubscribes
from `oldest_available_seq` and returns nothing to the shared state.
`FanoutState` (fanout/mod.rs:36-39) carries only the ring and the
decode-fault cell — there is no gap/discontinuity marker — and
`EventRing` records only `last`, `last_evicted` and `watermark`, all
of which are advanced normally by the post-gap push (ring.rs:205-225).
`EventRing::position` therefore decides contiguity purely from its own
RETENTION history (ring.rs:254-295): a cursor at or above the oldest
retained record (or above `last_evicted`) is `InWindow`, regardless of
the seq discontinuity sitting between it and the newest record.

**Failure scenario.**

The mux's connection drops and the reconnect backoff (up to
BACKOFF_CAP = 5 s, mux.rs:53) plus a busy log pushes the resume point
out of the upstream's `--keep-history` window. The reconnect receives
TRUNCATED{oldest_available_seq: 501} while the ring's last record is
(100,0) and the ring still retains (90,0)..(100,0). The mux resumes at
501 and pushes (501,0); records 101..500 never enter the ring and
nothing records that they are missing. An SSE client whose cursor is
(100,0) is classified `InWindow` (cursor >= oldest retained), is NOT
evicted, receives no `behind`/`truncated`/`lag_exceeded` event, and is
simply streamed (501,0) next — silently skipping 400 seqs of
balance/nonce/deposit events it will never backfill.

**Verifier's finding.**

Traced end to end in source. mux.rs:169-179 handles StreamItem::Gap by
resubscribing at oldest_available_seq and mutating nothing shared — no
ring call, no FanoutState write. FanoutState (fanout/mod.rs:36-39)
holds only `ring` and `fault`, so a discontinuity is structurally
unrepresentable. EventRing::push (ring.rs:205-225) treats the post-gap
record as an ordinary advance (inserts, sets watermark to the pre-gap
seq, leaves last_evicted untouched since eviction is count-driven, not
seq-driven). EventRing::position (ring.rs:254-295) decides contiguity
only from retention history: `Some(ev) => cursor >= ev` / `None =>
cursor >= oldest() || cursor.is_immediately_before(oldest())`. With
the ring holding (90,0)..(100,0) then (501,0), a cursor at (100,0) is
>= oldest() -> InWindow. Both consumers then take the wrong branch:
dispatch.rs:155-167 sees behind=false and records.len()==1 (under
max_client_lag), so the live client is written (501,0) with no error
event; resume.rs:122-128 with stream.rs:110-114 passing
upstream_oldest=None returns ResumeAction::Stream for a reconnect at …

**Suggested remediation.**

Give the ring an explicit discontinuity frontier: on a `Gap`, call
something like `ring.mark_gap(oldest_available_seq)` which records the
highest seq below which no cursor is contiguous, and have `position`
return `Behind { oldest_seq }` for any cursor at or below that
frontier (in addition to the eviction/floor tests). The
`dispatch::run_stream` `behind` path then emits
`lag_exceeded`/`behind` and the client is correctly steered to `GET
/v1/events` — which must first be fixed per the finding above.


### MAJOR — Upstream cursor regresses to the live-tail sentinel on LagExceeded{0}/ServerShutdown{0}, turning a backfill page into a false "caught up" answer

*Where:* `runtime/knomosis-gateway/src/events/subscribe.rs:224` — Rust / Solidity sweep, verifier confidence high

`UpstreamSubscription::recv` assigns the server-supplied
`last_delivered_seq` straight into `self.resume_from` for both
`ServerFrame::LagExceeded` (line 224) and
`ServerFrame::ServerShutdown` (line 231), with no monotonicity guard.
`resume_from = 0` is the RESERVED live-tail sentinel (documented at
subscribe.rs:30-31 and honoured by `EventCache::range`,
event_cache.rs:339). The event-subscribe server emits exactly
`OutboundFrame::LagExceeded { last_delivered_seq: 0 }` when its
subscriber registry is at capacity (knomosis-event-
subscribe/src/server.rs:818-828 — "re-using the lag-exceeded byte
semantics for 'server-side cannot accept you'"), and `ServerShutdown {
last_delivered_seq: sub.last_delivered_seq() }` is 0 for a connection
that delivered nothing (server.rs:1052-1054). A concrete backfill
cursor is therefore silently rewritten to "start from the live tail".
`backfill()` then reconnects, the server answers `AtLiveTail`, the
read idles out, and `ReconnectReason::StaleTimeout` is treated as the
caught-up stop (backfill.rs:205-208) rather than a failure.

**Failure scenario.**

A BFF requests `GET /v1/events?since=100` while the event-subscribe
server is at its subscriber cap (readily reached: the gateway opens a
NEW upstream subscription for every backfill request, dispatch.rs:149,
each held for at least the 500 ms BACKFILL_IDLE_TIMEOUT). Connection 1
handshakes with resume_from=100 and receives LagExceeded{0}. The
subscription sets resume_from=0; the reconnect handshakes with 0 =
live tail; the server delivers nothing; the 500 ms idle timeout fires
and is classified "caught up". The gateway answers HTTP 200 with
`{"events":[],"nextCursor":"100","hasMore":false}` — i.e. "you are
fully caught up" — while events 101..tip exist and were never
delivered. The client advances no cursor, sees no error, and never
learns of the balance changes; a client steered here by the SSE
`behind` signal loses exactly the range it was told to backfill.

**Verifier's finding.**

Confirmed by source trace and empirical reproduction.
runtime/knomosis-gateway/src/events/subscribe.rs:224 and :231 assign
the server-supplied last_delivered_seq into self.resume_from with no
monotonicity guard or zero floor, while resume_from=0 is the reserved
live-tail sentinel (subscribe.rs:30-31, honoured by
event_cache.rs:341-344 returning RangeOutcome::AtLiveTail). The event-
subscribe server emits LagExceeded{last_delivered_seq: 0} on two
capacity paths that are not lag at all — server.rs:818-828 (subscriber
registry at max_subscribers, default 256) and server.rs:726-738
write_capacity_rejection (connection slot at capacity) — and
ServerShutdown{sub.last_delivered_seq()} is 0 before the first
record_delivered (subscription.rs:185 initialises the AtomicU64 to 0).
backfill.rs:204-215 continues the drain after a non-StaleTimeout
Reconnecting, so the next sub.recv() reconnects with the poisoned
cursor; the ensuing silence trips the 500 ms BACKFILL_IDLE_TIMEOUT
(dispatch.rs:35), and backfill.rs:205-208 classifies StaleTimeout as
caught_up() rather than a failure, yielding …

**Suggested remediation.**

Never let a server-supplied seq move the cursor backwards, and never
let it land on the reserved sentinel: in both the `LagExceeded` and
`ServerShutdown` arms use `self.resume_from =
last_delivered_seq.max(self.resume_from);`. Additionally, distinguish
the capacity rejection from a genuine lag eviction on the wire (a
distinct frame kind, or a documented non-zero sentinel), and make
`backfill()` treat a `StaleTimeout` that follows a non-progress
reconnect as `BackfillError::Upstream` (503) rather than
`caught_up()`, so an upstream problem can never render as an empty,
caught-up page.


### MAJOR — POST /rpc is auth- and rate-limit-exempt and fully materialises a --max-frame-size JSON body before the MAX_BATCH cap is applied

*Where:* `runtime/knomosis-gateway/src/rpc.rs:75` — Rust / Solidity sweep, verifier confidence high

`/rpc` is on the auth exemption list (auth.rs:203) and therefore also
skips the rate limiter (auth.rs:245). `handler::handle` reads the
request body bounded only by `--max-frame-size` (handler.rs:141,
default 1 MiB, ceiling 16 MiB — config.rs:132/137) and hands it to
`rpc::handle`, which calls `serde_json::from_slice(payload.body)` into
an owned `serde_json::Value` (rpc.rs:75) *before* the `MAX_BATCH`
guard is evaluated (rpc.rs:92). The `MAX_BATCH = 100` cap (rpc.rs:61)
— whose own docstring says it exists because "`/rpc` is auth- and
rate-limit-exempt … an unbounded batch would fan one request out into
an unbounded number of response objects — a cheap memory/CPU
amplification" — bounds only the *response* fan-out, not the parse
that precedes it.

**Failure scenario.**

An anonymous client sends `POST /rpc` with `Content-Type:
application/json` and a 1 MiB body of `[0,0,0,...]` (~500 000
elements). `serde_json` materialises a `Vec<Value>` of ~500 000
32-byte `Value`s ≈ 16 MB of live heap plus reallocation churn, and
only then is `requests.len() > MAX_BATCH` checked and the request
rejected. With the default `--max-connections 1024` this is ~16 GB of
concurrent transient allocation from callers holding no credential; a
raised `--max-frame-size` (up to the 16 MiB ceiling) multiplies it by
16 again. Because the crate builds with `panic = "abort"`, an
allocation failure terminates the process rather than failing the
request.

**Verifier's finding.**

Verified end-to-end in source, not from docs. (1) auth.rs:203
`is_exempt_path` matches "/healthz"|"/readyz"|"/rpc"; auth.rs:215
`gate` and auth.rs:245 `rate_limit_check` both short-circuit on it, so
/rpc is genuinely auth- AND rate-limit-exempt, with no enable flag
(router.rs:274 maps it unconditionally). (2) The "gate-before-body"
DoS boundary documented at conn.rs:419-431 / handler.rs:140-144
protects every other body-consuming route; /rpc passes the gate
trivially, so `read_body_fn` runs and conn.rs:1066 `read_body` buffers
exactly `content_length`, bounded only by `max_frame_size`
(conn.rs:836; default 1 MiB, ceiling 16 MiB, config.rs:132/137). (3)
rpc.rs:75 `serde_json::from_slice` materialises an owned Value BEFORE
the MAX_BATCH guard at rpc.rs:92, which tests `requests.len()` on an
already-parsed Vec<Value>. The MAX_BATCH doc comment (rpc.rs:54-61)
itself cites the exempt status as the reason a cap is needed and
claims "--max-frame-size" bounds the rest — that bounds input bytes,
not the parsed representation. I measured the amplification rather
than asserting it: a scratch …

**Suggested remediation.**

Apply a dedicated, much smaller body cap on the exempt `/rpc` route (a
wallet Add-Network probe is a few hundred bytes; 8 KiB is generous)
*before* the body is read, e.g. by making the `read_body` closure
route-aware in `handler::handle`, and reject an over-cap body with 413
without parsing. Additionally rate-limit the exempt surface per peer
as in the `/readyz` finding, and cheaply pre-screen the batch size
(count top-level commas / reject a leading `[` longer than N bytes) or
use a streaming/depth-and-length-limited deserializer instead of
`Value`.


### MAJOR — `CommandKernel` waits for the `knomosis` child to exit before draining its piped stderr — a pipe-capacity block stalls the entire single-threaded host for the full 60 s timeout

*Where:* `runtime/knomosis-host/src/kernel.rs:1356` — Rust / Solidity sweep, verifier confidence high

`CommandKernel::submit` configures `cmd.stderr(Stdio::piped())` and
then calls `wait_with_timeout(&mut child, self.timeout)`, which polls
`child.try_wait()` in a sleep loop *without ever reading the stderr
pipe*. Only after the wait resolves does it call `child.stderr.take()`
and `take_with_limit(..., MAX_SUBPROCESS_OUTPUT)`. This is the classic
wait-before-drain deadlock: a POSIX pipe has a fixed capacity (64 KiB
by default on Linux), and once the child fills it the child blocks in
`write(2)` and can never exit, so `try_wait` never returns `Some`. The
`MAX_SUBPROCESS_OUTPUT` bound the comment cites as the defence
("Bounded by `MAX_SUBPROCESS_OUTPUT`") is applied strictly *after* the
wait and therefore cannot prevent the block. The blast radius is the
whole host, not one request: `submit` holds `self.spawn_lock`
(kernel.rs:1210) for the entire wait, and the server runs exactly one
worker thread (`server.rs:197-218`, `worker_loop`/`fair_worker_loop`),
so no other request can be dispatched for the full `DEFAULT_TIMEOUT`
of 60 s.

**Failure scenario.**

The configured `--knomosis-binary` (or an operator wrapper script
around it — a common deployment pattern for env setup /
`LD_LIBRARY_PATH` / logging) emits more than the 64 KiB pipe capacity
on stderr for a single `process` invocation. The child fills the pipe
on its 65 537th stderr byte and blocks in `write`. `wait_with_timeout`
polls `try_wait` every 10 ms for 60 s, then SIGKILLs the child and
returns `TimedOut`. During those 60 s: `spawn_lock` is held, the
single worker thread is parked inside `kernel.submit`, the bounded
queue (default depth 256) fills and every subsequent connection is
answered `Busy`, and each in-flight connection handler hits its own
`kernel_reply_timeout` (60 s) and answers `NotAdmissible "kernel
timeout"`. Every submitted action in that window is rejected even
though the kernel would have admitted it. The condition repeats on
every subsequent request, so the …

**Verifier's finding.**

CONFIRMED, and the finding understates reachability. MECHANISM (traced
+ empirically reproduced). runtime/knomosis-
host/src/kernel.rs:1343-1345 sets `stderr(Stdio::piped())`; :1356
calls `wait_with_timeout(&mut child, self.timeout)` BEFORE :1361 does
`child.stderr.take()`. `wait_with_timeout` (:1450-1476) only polls
`child.try_wait()` and `sleep(WAIT_POLL_INTERVAL)` — it never touches
the pipe fd. The `MAX_SUBPROCESS_OUTPUT` (64 KiB, :856) bound the
comment cites as the defence is applied strictly after the wait, so it
cannot prevent the block. I compiled a standalone replica of the exact
spawn/poll/drain sequence: 60 KiB of child stderr exits in 10 ms; 65
KiB and 128 KiB both stall for the FULL timeout and get SIGKILLed. The
boundary is exactly Linux's 65536-byte pipe capacity. BLAST RADIUS
(confirmed). `spawn_lock` is held across the whole wait
(kernel.rs:1210-1213). server.rs:197-218 spawns exactly ONE worker
thread on both the `Fifo` and `Drr` arms. `DEFAULT_TIMEOUT =
Duration::from_mins(1)` (kernel.rs:883). So the entire host is
unavailable for 60 s per triggering request; …

**Suggested remediation.**

Drain stderr concurrently with the wait. Spawn a short-lived reader
thread that owns `child.stderr.take()` and runs `take_with_limit(...,
MAX_SUBPROCESS_OUTPUT)`, then poll `try_wait` as today and `join` the
reader after the child exits (or after the SIGKILL, which closes the
pipe and unblocks the reader): ```rust let stderr_pipe =
child.stderr.take(); let collector = std::thread::Builder::new()
.name("knomosis-host-stderr".into()) .spawn(move || { let mut buf =
Vec::with_capacity(1024); if let Some(mut s) = stderr_pipe { let _ =
take_with_limit(&mut s, &mut buf, MAX_SUBPROCESS_OUTPUT); } buf });
let exit_status = wait_with_timeout(&mut child, self.timeout); let
stderr_text = collector.ok() …


### MAJOR (reported CRITICAL) — Per-connection writer-thread spawn uses `.expect()`, so an OS thread refusal aborts the whole host process (release `panic = "abort"`)

*Where:* `runtime/knomosis-host/src/listener.rs:594` — Rust / Solidity sweep, verifier confidence high

`run_persistent` spawns the per-connection response-writer thread with
`std::thread::Builder::new()...spawn(...).expect("spawn persistent
writer thread")`. `Builder::spawn` returns `Err(io::Error)` — not a
panic — precisely on `EAGAIN` (RLIMIT_NPROC, cgroup `pids.max`, or
thread-stack VA exhaustion), which is the condition that arises under
exactly the load an unauthenticated remote attacker controls: the
number of simultaneously open connections. The workspace release
profile sets `panic = "abort"` (`runtime/Cargo.toml`
`[profile.release]`), so this panic terminates the entire `knomosis-
host` process rather than just the connection thread. The identical
hazard is explicitly recognised and correctly handled ~180 lines later
in the TCP accept loop (`listener.rs:782-804`: "thread::spawn PANICS
when the OS refuses a thread (EAGAIN under fd/thread pressure —
exactly when a server is under load) ... Handle the error instead.")
and in the Unix accept loop (`listener.rs:1336-1356`), so the
hardening was applied to one of the two per-connection spawn sites and
missed on the other. `run_persistent` is the site that *doubles*
thread pressure: with `--persistent-connections`, every accepted
connection costs two threads (handler + writer), so the default
`max_concurrent_connections = 1024` means up to 2048 live threads.

**Failure scenario.**

Host started with `--persistent-connections` (TCP or Unix), defaults
otherwise (`max_concurrent_connections = 1024`), running in a
container with `pids.max = 1500` or under `RLIMIT_NPROC`. An attacker
opens ~750 concurrent TCP connections. Each accepted connection
acquires a `ConnectionSlot` (cap not yet reached), spawns its handler
thread, and the handler immediately calls `run_persistent`, which
tries to spawn a second (writer) thread. At ~750 connections the
1500-pid budget is exhausted; `Builder::spawn` returns `Err(EAGAIN)`;
`.expect` panics; `panic = "abort"` fires `abort()` and the whole
sequencer host dies. No authentication, no valid `SignedAction`, and
no valid CBE payload is required — the attacker only has to complete
TCP handshakes. Restarting the process does not help: the attacker
reconnects and kills it again.

**Verifier's finding.**

Traced directly in source. runtime/knomosis-
host/src/listener.rs:589-594 spawns the per-connection writer thread
via `std::thread::Builder::new().name(...).spawn(...).expect("spawn
persistent writer thread")`. `Builder::spawn` returns Err(io::Error)
on EAGAIN (RLIMIT_NPROC / cgroup pids.max / stack VA exhaustion), so
`.expect` panics. runtime/Cargo.toml:253 sets `panic = "abort"` in
[profile.release], and the project itself confirms the consequence at
server.rs:472 ("`catch_unwind` is a no-op (a panic aborts the process
before ...)"). No catch_unwind wraps the connection thread; the only
ones in the crate are in server.rs around kernel.submit. The asymmetry
the reporter cites is real and complete: grep of `.spawn(` shows four
per-connection/accept spawn sites in listener.rs. The three accept
loops -- TCP 775-804, TLS 965, Unix 1338-1356 -- all match on the Err
and respond Busy, each carrying an explicit comment that spawn fails
"when the OS refuses a thread (EAGAIN under fd/thread pressure --
exactly when a server is under load)". Site 591 is the only unhandled
one, and it is …

**Suggested remediation.**

Replace the `.expect` with error handling that degrades instead of
aborting. `run_persistent` already has a natural fallback — the one-
shot handler — and both call sites (`handle_single_connection`,
`handle_single_unix_connection`) already implement a
`try_clone`-failure fallback to `handle_connection`. Change
`run_persistent` to return a `Result`/sentinel on spawn failure, e.g.:
```rust let writer = match std::thread::Builder::new()
.name("knomosis-host-persist-writer".into()) .spawn(move || {
persistent_writer_loop(write_half, resp_rx, kernel_reply_timeout,
&writer_dead); }) { Ok(w) => w, Err(e) => { tracing::warn!(error = %e,
"failed to spawn persistent writer; one-shot fallback"); …


### MAJOR — The gas-pool drain event (tag 18) is never emitted, so `pool_balances_*` are monotone-increasing gross inflows and the gateway serves them as `net: true`

*Where:* `runtime/knomosis-indexer/src/budget_view.rs:286` — Rust / Solidity sweep, verifier confidence high

`dispatch_event`'s `Event::GasPoolClaim` arm is the only code path
that ever decrements `pool_balances_eth` / `pool_balances_bold`, and
the module docstring (budget_view.rs:55-61) states the contract
`pool_balances_eth[p] = inflow(p, 0) − drain(p, 0)` when `--gas-pool-
actor` is configured. But `Event.gasPoolClaim` is never constructed by
the Lean event authority:
`LegalKernel/Events/Extract.lean::extractEvents` builds tags
0,1,2,3,8,9,10,11,12,13,15,16,17,19,20,21,22 and nothing else — a
repo-wide grep for `gasPoolClaim` outside `Encoding/Event.lean`,
`Events/Types.lean` and test fixtures returns zero constructors. The
actual pool outflow is an ordinary `Laws.transfer` from `gasPoolActor`
to `sequencerActor` gated by `gasPoolPolicy`
(`LegalKernel/Bridge/GasPoolPolicy.lean:396
gasPoolPolicy_permits_sequencer_transfer_bold`), which emits
`Event.balanceChanged` (tag 0) — and `dispatch_event`'s catch-all `_
=> {}` at budget_view.rs:317 ignores tag 0 for the pool tables. So the
drain half of the stated identity can never execute.

**Failure scenario.**

An operator runs the indexer with `--gas-pool-actor 1` (the documented
production configuration). Users top up budgets, crediting
`pool_balances_eth[1]` via tags 16/17/19. The sequencer then
reimburses itself repeatedly by transferring from the pool actor,
draining the real on-chain/kernel pool balance toward zero.
`pool_balances_eth[1]` never decreases. The gateway's `GET
/v1/pools/1?resource=0` (`knomosis-gateway/src/reads/pools.rs:77`)
returns that gross-inflow figure with `net: true` — the flag whose
documented meaning is "the balance is net of drains". An operator or
BFF monitoring pool solvency reads a number that only ever goes up
while the pool is being emptied, and will not trigger a refill or a
circuit-breaker until the pool is actually insolvent and user actions
start failing.

**Verifier's finding.**

Verified independently against source. (1) Producer:
LegalKernel/Events/Extract.lean's actionEvents + extractEvents
construct no Event.gasPoolClaim arm; grep for gasPoolClaim across
*.lean hits only Events/Types.lean (constructor + tag/actor/resource
projections), Encoding/Event.lean (codec), and LegalKernel/Test/**
fixtures. Tag 18 is declared but never constructed by the event
authority. (2) Real outflow:
runtime/knomosis-l1-ingest/src/sequencer_claim.rs:166 builds
Action::Transfer{sender: GAS_POOL_ACTOR_ID, receiver:
SEQUENCER_ACTOR_ID}, matching GasPoolPolicy.lean's
gasPoolPolicy_permits_sequencer_transfer_{eth,bold}; its pool-side
event is Event.balanceChanged (tag 0). Laws.claimBudgetRefund likewise
debits the pool and surfaces only tag 0. (3) Consumer:
budget_view.rs:286-311 is the ONLY drain_pool call site (grep-
confirmed; the other references are the hand-constructed unit tests at
822/845/868), and the catch-all `_ => {}` at budget_view.rs:317 drops
tag 0 for the pool tables. So the drain half of the identity
documented at budget_view.rs:24/59 and budget_storage.rs:53-54 is …

**Suggested remediation.**

Per the project's implement-the-improvement rule, make the description
true rather than weakening it: add a `gasPoolClaim` emission to
`extractEvents` for the pool-actor→sequencer transfer (the
`gasPoolPolicy`-gated `Laws.transfer` arm already has `resource`,
`sender = gasPoolActor` and `amount` in scope, and the sequencer is
the recipient), freeze it against tag 18, and extend the
`event_subscribe_cbe.json` corpus so the cross-stack pin exercises a
real emission rather than a synthetic fixture. If instead the design
is that tag 18 is retired, then `dispatch_event` must derive the drain
from the tag-0 `balanceChanged` on the configured pool actor, and the
gateway's `net` flag must stop …


### MAJOR — Indexer CBE decoder caps amounts at 2^128 while the Lean authority admits < 2^256 — a legally-admitted balance permanently wedges the indexer

*Where:* `runtime/knomosis-indexer/src/decoder.rs:257` — Rust / Solidity sweep, verifier confidence high

`Cursor::read_amount` reads the 33-byte CBE amount head (tag 0x06 +
32-byte LE body) but requires bytes 17..33 (the high 128 bits) to be
zero, returning `DecodeError::AmountTooWide` otherwise. The Lean
authority's range is strictly wider:
`LegalKernel/Encoding/CBOR.lean:403 cborAmountHeadEncode` writes
`natToBytesLE n 32` (lossy only above 2^256) and
`LegalKernel/Laws/AmountBound.lean:77` sets `maxAmount = 256 ^ 32 =
2^256`, so `AmountBounded s r a amount := getBalance s r a + amount <
2^256` is the ONLY ceiling any crediting law enforces. Every value in
[2^128, 2^256) is therefore a legal kernel state that the Rust mirror
cannot represent (`BALANCE_VALUE_LEN = 16` in `balance.rs:72`) and
cannot decode. The decoder's own comment (`decoder.rs:119`) justifies
this as "Unreachable in practice: 2^128 wei is ~3.4e20 ETH", but
resources are generic `ResourceId`s, not only ETH, and `Laws.mint`
(`LegalKernel/Laws/Mint.lean:55`) has no cap beyond `AmountBounded`.

**Failure scenario.**

A deployment authorises `Action.mint r to (2^128)` for any resource
`r` (e.g. a token with a large decimal base, or a supply-bootstrap
mint). The kernel admits it: `pre = amount > 0 ∧ getBalance + amount <
2^256` holds. `extractEvents` emits `Event.balanceChanged r to 0
(2^128)`; `Event.encode` writes an amount head whose byte 17 is 0x01.
The indexer's `decode_event` returns `AmountTooWide`;
`daemon.rs:240-250` converts it to
`ConsumeOutcome::IndexerError(IndexerError::Decode)`; `main.rs:207`
logs and returns `OperatorExitCode::OperatorAction`. Because the batch
was never committed, `c/cursor` still points at the previous seq, so
every restart re-subscribes at the same cursor, re-receives the same
frame, and dies again. The indexer — and every gateway read view fed
from its SQLite file (balances, budget, pools, `/v1/events` backfill)
— is permanently frozen at that seq with no operator …

**Verifier's finding.**

Traced end-to-end in source. Lean authority admits balances in [0,
2^256): Encoding/CBOR.lean:403 cborAmountHeadEncode writes
natToBytesLE n 32; Encodable.lean:244 encodeAmount routes to it;
Laws/AmountBound.lean:77,94-96 sets maxAmount = 256^32 and
AmountBounded is the ONLY ceiling; Laws/Mint.lean:55 pre = amount > 0
AND AmountBounded, with Authority/Action.lean:540 dispatching .mint to
Laws.mint unchanged and Encoding/Action.lean:100 bounding the field at
256^32. Encoding/Event.lean:80-85 encodes balanceChanged oldV/newV as
absolute amounts via encodeAmount, and Main.lean:956 ->
Runtime/EventStream.lean:138 confirms production `extract-events`
emits Encodable.encode Event, i.e. the 33-byte head. The Rust mirror
narrows: knomosis-indexer/src/decoder.rs:257 returns AmountTooWide if
bytes 17..33 are non-zero, and balance.rs:72 BALANCE_VALUE_LEN = 16.
Halt path confirmed: daemon.rs:240-250 and :264-272 map the decode
error to IndexerError::Decode; main.rs:193-208 treats only
CommitAmbiguous as recoverable and returns
OperatorExitCode::OperatorAction otherwise; the batch commits only …

**Suggested remediation.**

Either (a) narrow the authority to match the mirrors — make
`Laws.maxAmount = 2^128` so `AmountBounded` structurally excludes
every value the Rust/SQLite side cannot hold (this is the option the
Genesis Plan's own C-3 narrative already leans on: the bound is a
*checked precondition*, so tightening it is a one-line change plus
proof re-check), or (b) widen the indexer to a 32-byte amount
representation end-to-end (`Amount = [u8; 32]` or a bignum newtype,
`BALANCE_VALUE_LEN = 32`, plus a migration). Whichever is chosen, add
a cross-stack test that pins the two ceilings to the same constant so
they cannot drift again; the current `event_subscribe_cbe.json` corpus
does not contain an amount …


### MAJOR — JSON-RPC log fetch verifies the returned blockHash but not the emitting contract address, and neither decoder checks it

*Where:* `runtime/knomosis-l1-ingest/src/source.rs:834` — Rust / Solidity sweep, verifier confidence high

`JsonRpcL1Source::logs_in_block_by_hash` sends an `eth_getLogs` filter
carrying both `blockHash` and `address`, and then re-verifies only the
`blockHash` on each returned log ("Defence-in-depth: verify the log
carries the expected `blockHash`... historically some providers have
ignored the filter"). The `address` field is parsed into
`RawLog.address` but never compared against the requested `contract`.
Neither consumer closes the gap:
`knomosis_l1_ingest::events::decode_event` (events.rs:665) dispatches
purely on `topics[0]` and never reads `log.address`, and the
observer's `decode_event` (faultproof-observer/events.rs:326) does the
same while merging logs from two different contracts into one decode
stream (faultproof-observer/watcher.rs:407-428).

**Failure scenario.**

A compromised, misconfigured, or filter-ignoring RPC endpoint (the
same class of provider bug the blockHash check was added to defend
against) returns, inside a legitimate confirmed block, a log emitted
by an attacker-deployed contract whose `topics[0]` is
`keccak256("RegisteredECDSA(address,bytes)")`. The ingestor accepts
it, translates it via `preview_ingest`, signs it with the bridge-actor
key and submits a `RegisterIdentity`/`ReplaceKey` for an attacker-
chosen L1 address and public key -- an unauthorised L2 identity
binding. The same primitive against the observer is worse: an injected
`FaultProofGameSettled` log makes `handle_game_settled` mark a live
game terminal, after which `maybe_play_move` returns early on
`!rec.state.status.is_in_progress()` and the honest party stops
defending a game it is winning.

**Verifier's finding.**

Verified by reading source.
runtime/knomosis-l1-ingest/src/source.rs:757-760 sends an eth_getLogs
filter with both blockHash and address; lines 771-778 parse the log's
address into RawLog.address; lines 822-839 re-verify only blockHash
("some providers have ignored the filter"). No equality check on
address exists anywhere — grep for log.address / '.address ==' across
l1-ingest source.rs, watcher.rs and the observer returns only the
construction site at :776. The field is write-only. The trait contract
at source.rs:82-85 explicitly promises "every log emitted by
`contract`", so the impl violates its own documented contract on the
half it did not check. Both decoders are address-blind: l1-ingest
events.rs:665-670 and observer events.rs:332-345 dispatch solely on
topics[0]; the observer's docstring at :322-324 even names "logs from
other contracts captured by an over-broad RPC filter" as an expected
input. Merge sites confirmed at l1-ingest/watcher.rs:443-459 and
observer/watcher.rs:406-428. Impact traced further than the reporter
did. A spoofed RegisteredECDSA log reaches …

**Suggested remediation.**

In `logs_in_block_by_hash`, reject any returned log whose `address !=
*contract` with `SourceError::Malformed`, mirroring the existing
blockHash check. Additionally pass the expected contract into both
`decode_event` functions (or split the observer's decode into per-
contract dispatch) so `FaultProofGameOpened`/`Settled` are accepted
only from the game contract and `StateRootSubmitted` only from the
submission contract, and `RegisteredECDSA`/`Revoked` only from the
identity registry.


### MINOR (reported MAJOR) — `bridge_chain_accounting_equation` is proved over a trace relation that excludes the supply-moving actions a production deployment must admit, so the "unconditional" escrow identity does not hold on any real chain

*Where:* `LegalKernel/Bridge/Reachable.lean:57` — Lean sweep, verifier confidence high

`BridgeReachable` closes only over `BridgeAction`, which enumerates
exactly `deposit`, `depositWithFee`, `withdraw`
(Reachable.lean:57-71). `bridge_chain_conserves` /
`bridgeReachable_solvent` / `bridge_chain_accounting_equation`
(ChainAccounting.lean:570-599) are stated only over that relation. The
module's justification — "Every other action either leaves the bridge
ledger untouched or is supply-non-conservative (mint / burn / reward)"
(Reachable.lean:30-32) — is false for two production, bridge-only,
non-user-optional actions. `.ammSwap` (frozen index 23) changes
`TotalSupply` at both legs (`Laws.ammSwap` credits `+amountIn` at
`fromResource` and debits `−amountOut` at `toResource`,
AmmSwap.lean:83-87) while `applyActionToBridgeState` leaves the bridge
ledger identity (Admissible.lean:183); `.reclaimAmmReserves` (index
24) likewise. Both are `Action.isBridgeOnly = true`
(Admissible.lean:113-114) and `bridgeAuthorizedAction = true`
(BridgeActor.lean:480, 488), i.e. a deployment that runs the AMM
cannot exclude them. `BridgeConserves es := ∀ r, totalWithdrawn es r +
TotalSupply es.base r = totalDeposited es r`
(ChainAccounting.lean:447) is therefore violated by the first swap.
CLAUDE.md advertises this as "§7.6.4 escrow identity (unconditional)"
and as closing audit finding m-16.

**Failure scenario.**

A chain that admits `deposit(resource 0, 100)` then one bridge-
attested `.ammSwap 0 1 amountIn=10 amountOut=9 ammReserveActor` has
`totalDeposited(0) = 100`, `totalWithdrawn(0) = 0`, but
`TotalSupply(0) = 110`. `BridgeConserves` fails at r=0 (`0 + 110 ≠
100`), and at r=1 the supply drops by 9 with no matching
`totalWithdrawn` entry, so `bridgeEscrowBalance` (= `totalDeposited −
totalWithdrawn`, Accounting.lean:556) over-states resource-1 backing
by 9 while under-stating resource-0 backing by 10. Neither
`bridgeReachable_solvent` nor `bridge_chain_accounting_equation`
applies to this state, because no `BridgeReachable` derivation exists
for a trace containing an `ammSwap` — the guarantee is silently
vacuous on the deployed action set rather than false.

**Verifier's finding.**

Core claim verified by reading source. `BridgeAction`
(Reachable.lean:57-71) admits only deposit/depositWithFee/withdraw and
`BridgeReachable.step` (:99-106) pins `st.action = ba.toAction`, so no
trace containing any other action has a derivation. `BridgeConserves`
(ChainAccounting.lean:447) contains a `TotalSupply` term, so it is
broken by any supply-moving action even when the bridge ledger is
untouched. `.ammSwap` is exactly that case: `applyActionToBridgeState`
is identity on it (Admissible.lean:183, pinned at :221) while
`ammSwap_fromResource_supply_increase` (AmmSwap.lean:240) and
`ammSwap_toResource_supply_decrease` (:280) prove supply moves at both
legs, and the law's own header says "NOT globally conserved" (:34-37).
It is `isBridgeOnly` (Admissible.lean:113) and `bridgeAuthorizedAction
= true` (BridgeActor.lean:~480) with no conjunct in
`BridgeAdmissibleWith` (:270-310) blocking it, so an AMM deployment
cannot stay inside the relation. The stated justification at
Reachable.lean:27-30 — the three constructors are "exactly the
constructors that move the per-resource L2 …

**Suggested remediation.**

Extend `BridgeAction` to cover `.ammSwap` and `.reclaimAmmReserves`
and either (a) strengthen `BridgeConserves` to a per-resource
invariant that nets the AMM legs (e.g. `totalWithdrawn r + TotalSupply
r = totalDeposited r + ammNetIn r − ammNetOut r`, with `ammNetIn/Out`
tracked in `BridgeState` — which also fixes finding #3's missing
reserve mirror), or (b) prove the deltas and carry a separate AMM
accounting term. Failing that, restate the CLAUDE.md / docstring claim
to say the identity holds only over deposit/withdraw-only traces, and
record the AMM legs as an open obligation.


### MINOR (reported MAJOR) — Terminal step takes `l2LogIndex` from the caller instead of from the game range, contradicting its own docstring and the contract

*Where:* `LegalKernel/FaultProof/Step.lean:120` — Lean sweep, verifier confidence high

`kernelStepApply` forwards `step.l2LogIndex` — a field of the caller-
supplied `KernelStep` — into `verifierPostRootMulti`, and
`applyTransition`'s `.terminateOnSingleStep` arm (Game.lean:314-359)
never checks it against `gs.range.high.idx` (or `gs.range.low.idx +
1`). The contract does derive it: `KnomosisFaultProofGame.sol:526-528`
passes `g.high.idx` to `executeStepToRootMulti`, with the comment "the
game supplies the index it is adjudicating rather than the step VM
guessing one". The `KernelStep.l2LogIndex` docstring (Step.lean:60-63)
asserts the L1 behaviour — "On L1 the game supplies `g.high.idx`
rather than reading it from the caller" — while the Lean model it
documents does read it from the caller. The index is not inert:
`derivedCellValue` for `.bridgePending` embeds it verbatim
(`Terminate.lean:244-250`, `derivePendingCellValue { ..., l2LogIndex
:= l2LogIndex }`), so it is a free parameter in the post-root the
verifier computes.

**Failure scenario.**

A sequencer publishes, at log index i, a state root whose pending-
withdrawal record carries `l2LogIndex := j` for some j ≠ i (an off-by-
one or a deliberately mislabelled withdrawal, which downstream L1
withdrawal-proof consumers key on). A challenger disputes index i and
bisects to the single step `[i-1, i]`. The sequencer terminates with
`step.l2LogIndex := j`; `derivePendingCellValue` then reproduces
exactly the record in the published root, `verifierPostRootMulti`
returns `gs.range.high.commit`, and Game.lean:345 settles
`.sequencerWon` — the model upholds a root that the contract (which
would have passed `g.high.idx = i`) would have rejected. The Lean game
therefore admits a class of invalid roots the L1 refuses, so the model
is not a sound over-approximation of the contract it is stated to
specify.

**Verifier's finding.**

VERIFIED REAL by direct source tracing. (1)
LegalKernel/FaultProof/Step.lean:118-120 — kernelStepApply forwards
step.l2LogIndex, a plain caller-supplied field of KernelStep
(Step.lean:64), into verifierPostRootMulti. (2)
LegalKernel/FaultProof/Game.lean:314-359 — the .terminateOnSingleStep
arm checks status, isSingleStep, pendingMidpoint, and explicitly
rejects step.preStateCommit != gs.range.low.commit (line 323), then
calls kernelStepApply and compares to gs.range.high.commit. It never
compares step.l2LogIndex to gs.range.high.idx. Conclusive: grep of
"l2LogIndex" across LegalKernel/ returns ZERO hits in Game.lean.
Claim.idx is available in the game state (Game.lean:56-61), so the
derivation is possible and simply omitted. (3) The index is not inert.
Terminate.lean:426-427 threads it into derivedCellValue at 453-454,
and Terminate.lean:244-250 embeds it verbatim in the .bridgePending
branch for .withdraw. derivePendingCellValue
(VerifierWrites.lean:1550) is the raw CBE encoding, and
derivePendingCellValue_correct (VerifierWrites.lean:1636-1643) shows
production puts the STEP's idx …

**Suggested remediation.**

In `applyTransition`'s `.terminateOnSingleStep` arm, call
`verifierPostRootMulti step.preStateCommit step.signedAction.action
step.signedAction.signer gs.range.high.idx step.bundle` directly (or
reject `step.l2LogIndex ≠ gs.range.high.idx` the way
`step.preStateCommit ≠ gs.range.low.commit` is already rejected at
Game.lean:323). Prefer the former: dropping the field from
`KernelStep` makes the index underivable from the caller by
construction, exactly as removing `claimedPostCommit` did.


### MINOR (reported MAJOR) — `step.l2LogIndex` is caller-supplied and unconstrained in the Lean terminal step, though its own docstring says the game must supply it

*Where:* `LegalKernel/FaultProof/Step.lean:64` — Lean sweep, verifier confidence high

`KernelStep.l2LogIndex` (Step.lean:60-64) is documented as "the log
index this step produces ... On L1 the game supplies `g.high.idx`
rather than reading it from the caller", but `applyTransition
.terminateOnSingleStep` (Game.lean:314-341) never compares
`step.l2LogIndex` to `gs.range.high.idx` (or `low.idx`), and
`kernelStepApply` (Step.lean:118-120) passes it straight into
`verifierPostRootMulti`. That index is not inert: `derivedCellValue`'s
`.bridgePending` arm (Terminate.lean:244-250) builds `{ resource,
recipient, amount, l2LogIndex := l2LogIndex }` and
`derivePendingCellValue` (VerifierWrites.lean:1550) encodes it into
the cell value, so the derived post-root is a function of it. The
contract passes `g.high.idx`
(solidity/src/contracts/KnomosisFaultProofGame.sol:526-528), so again
the Lean model is weaker than production and the property is
unmodelled.

**Failure scenario.**

Log entry i is `withdraw r sender amount rcp`. The honest post-state's
pending-withdrawal record at `nextWdId` carries `l2LogIndex = i`. A
dishonest sequencer instead publishes R_{i+1} computed with
`l2LogIndex = j ≠ i` (a wrong index in the pending record, which the
L1 withdrawal-proof path reads). Challenged and bisected to that step,
the sequencer submits a `KernelStep` with `preStateCommit = R_i`, the
true action, the honest bundle, and `l2LogIndex := j`.
`verifierPostRootMulti` derives the pending cell with `l2LogIndex :=
j`, the fold lands exactly on the sequencer's fabricated R_{i+1}, and
Game.lean:343-350 declares `sequencerWon`.

**Verifier's finding.**

Traced and confirmed in source. (1) Game.lean:314-359 guards status,
isSingleStep, pendingMidpoint and step.preStateCommit vs
gs.range.low.commit (line 323) but never constrains step.l2LogIndex,
even though gs.range.high.idx is available in GameState (Claim.idx,
Game.lean:56-61). The sibling guard at 323 even carries a comment
explaining why a caller-supplied value must be rejected explicitly in
the Lean model; the same reasoning was not applied to the index. (2)
Step.lean:118-120 passes it straight into verifierPostRootMulti. (3)
Terminate.lean:426-474 threads it to derivedCellValue (453-454); the
frontier is NOT a function of it, since verifierWriteCells
(Terminate.lean:100-105) keys the pending cell as .bridgePending
nextWdIdPre from the bundle's own .bridgeNextWdId opening, so the cell
key set is identical and only the value moves. (4)
Terminate.lean:244-250 -> VerifierWrites.lean:1550-1551
derivePendingCellValue encodes the full PendingWithdrawal incl.
l2LogIndex, so the derived post-root is a function of the caller-
chosen index; derivePendingCellValue_correct (1636-1662) …

**Suggested remediation.**

In `applyTransition .terminateOnSingleStep`, either drop `l2LogIndex`
from `KernelStep` and pass `gs.range.high.idx` to `kernelStepApply`
directly (matching the contract), or add an explicit `step.l2LogIndex
≠ gs.range.high.idx → responder loses` guard alongside the existing
`preStateCommit` guard.


### MINOR (reported MAJOR) — /readyz is exempt from both the auth gate and the rate limiter yet performs upstream I/O, giving anonymous callers a thread- and lock-exhaustion primitive

*Where:* `runtime/knomosis-gateway/src/auth.rs:203` — Rust / Solidity sweep, verifier confidence high

`is_exempt_path` (auth.rs:203) exempts `/healthz`, `/readyz` and
`/rpc` from authentication, and `rate_limit_check` (auth.rs:245)
returns `None` — i.e. "admit, do not throttle" — for the *same* exempt
set before it ever consults the token bucket. `/readyz` is therefore
reachable by any anonymous caller at unbounded rate, and it is not a
static probe: `system::readyz` (system.rs:143-147) calls
`probe_indexer` (a live `read_cursor` that takes `SqliteStorage`'s
single `Mutex<Connection>` — knomosis-storage/src/sqlite.rs:304, the
one lock every authenticated read endpoint also serialises on) and
then two `probe_tcp` calls, each a `TcpStream::connect_timeout` with
`READINESS_PROBE_TIMEOUT = 2s` (system.rs:41, 172-176). The work is
synchronous on the connection thread, and the gateway is thread-per-
connection bounded by `--max-connections` (default 1024,
config.rs:45).

**Failure scenario.**

An attacker opens 1024 plaintext connections (the default `--max-
connections`) and issues `GET /readyz` in a loop on each, with no
credential. Two effects, both without any token: (1) every request
acquires the process-wide SQLite connection mutex, so authenticated
`GET /v1/actors/{id}/balances` / `/budget` / `/pools` requests queue
behind anonymous traffic; (2) if either upstream address is behind a
packet-dropping firewall or a saturated backlog — exactly the
condition a readiness probe exists to detect — each request blocks its
connection thread for up to 4 s in `connect_timeout`, so ~256
anonymous requests/second occupy every connection slot and the gateway
stops serving authenticated traffic entirely. Each request
additionally opens two fresh TCP connections to the internal knomosis-
host and event-subscribe daemons, churning their own bounded
connection caps.

**Verifier's finding.**

Traced end to end in source. auth.rs:203 `is_exempt_path` covers
`/healthz|/readyz|/rpc`; `gate` (auth.rs:214) short-circuits on it,
and `rate_limit_check` (auth.rs:245) short-circuits on the same set
before the token bucket. handler.rs:118 composes them with `.or_else`,
so a `None` gate falls straight to `dispatch` → `system::readyz`.
`readyz` (system.rs:143-147) is not static: `probe_indexer` does a
live `read_cursor` that takes SqliteStorage's single `conn:
Mutex<Connection>` (knomosis-storage/src/sqlite.rs:304 — the same lock
every authenticated read serialises on), then two `probe_tcp` calls,
each `TcpStream::connect_timeout(.., READINESS_PROBE_TIMEOUT = 2s)`
(system.rs:172-176). No caching, coalescing, or per-probe concurrency
bound anywhere; thread-per-connection bounded only by
DEFAULT_MAX_CONNECTIONS = 1024 (config.rs:45), with keep-alive so one
connection issues unbounded requests, and no per-IP limit.
tests/integration.rs:707 and auth.rs:371 pin the exemption as
intended, so nothing catches it. Strong corroboration the auditor
missed: rpc.rs:100-106 fixes this exact class …

**Suggested remediation.**

Split the exempt set in two: exempt from *authentication* only, and
still subject to a limiter. Give the unauthenticated surface a
separate peer-keyed (or global) token bucket rather than the per-
credential one, and make `/readyz` cheap: memoise the probe result for
a short interval (e.g. 1 s) behind an `AtomicU64` timestamp so N
concurrent anonymous requests collapse to one cursor read and one pair
of connects, and shorten `READINESS_PROBE_TIMEOUT` or move the probing
to a background thread that `/readyz` merely reads a cached verdict
from.


### MINOR (reported MAJOR) — V1 dispute verifier's quorum tally reverts on a malleable signature instead of skipping it, letting one adjudicator block finalisation

*Where:* `solidity/src/contracts/KnomosisDisputeVerifier.sol:849` — Rust / Solidity sweep, verifier confidence high

`_countVerifiedSignatures` filters on `sigs[i].length != 65` and then
calls `ECDSA.recover(verdictHash, sigs[i])` directly. OpenZeppelin's
`ECDSA.recover` *reverts* (`ECDSAInvalidSignatureS` /
`ECDSAInvalidSignature`) on a 65-byte signature whose `s` is in the
upper half-order or whose `v` is not 27/28 — it does not return
`address(0)`. So a single malformed-but-length-65 entry aborts the
entire `finalizeUpheld` / `finalizeRejected` call rather than being
discarded, contradicting the function's own docstring ("a signer with
one valid signature counts at most 1 regardless of (signers, sigs)
padding"). The sibling contract `KnomosisDisputeVerifierV2` implements
exactly this correctly, wrapping the recover in `try
this.tryRecover(...) { } catch { }`
(KnomosisDisputeVerifierV2.sol:343-350) — and
`KnomosisDisputeVerifier` even ships the same `tryRecover` external
wrapper (line 574) but never calls it.

**Failure scenario.**

Quorum threshold is 3 of 5 approved adjudicators. Adjudicators A, B
and C sign the UPHELD verdict digest; C, wishing to appear cooperative
while blocking the rollback, returns the ECDSA-malleable twin of its
signature (`s' = n - s`, `v` flipped) — a signature that verifies
under any lenient off-chain verifier and is indistinguishable from a
normal one to the finaliser. The finaliser calls `finalizeUpheld(id,
evidence, hint, [A,B,C], [sigA,sigB,sigC'])`; at line 849
`ECDSA.recover` reverts on `sigC'` and the whole transaction reverts,
so `verified` is never computed, the dispute stays `STATUS_OPEN`, the
sequencer's stake stays locked by `openDisputeCount != 0`, and no
rollback occurs. Because the failure surfaces as a bare revert rather
than `QuorumNotMet(2, 3)`, the finaliser has no on-chain signal
identifying which signature to drop, and C can keep re-issuing
malleable signatures each …

**Verifier's finding.**

Mechanics confirmed by reading source. KnomosisDisputeVerifier.sol:849
calls ECDSA.recover directly inside the tally loop (822-855) where
every other rejection reason uses `continue`. The vendored OZ v5 ECDSA
(solidity/lib/openzeppelin-
contracts/contracts/utils/cryptography/ECDSA.sol:89, 137-144, 163-171)
reverts via _throwError with ECDSAInvalidSignatureS on high-s and
ECDSAInvalidSignature on bad v — it does not return address(0). So a
single 65-byte non-canonical signature aborts
finalizeUpheld/finalizeRejected. The unused tryRecover wrapper is at
line 574-580 with a docstring stating exactly this purpose, and the
same file uses it correctly at 557-563 in checkSignatureInvalid;
KnomosisDisputeVerifierV2.sol:343-350 is the correct pattern. Cross-
stack divergence is genuine: the Lean authority
LegalKernel/Disputes/Verdict.lean:171-173 states the mirrored
countVerifiedSignatures is "total: missing signatures, unregistered
signers, or mismatched signature lengths simply produce a count that
does not clear the quorum threshold" — the V1 Solidity mirror is not
total. No test covers …

**Suggested remediation.**

Replace line 849 with the V2 pattern: `try
this.tryRecover(verdictHash, sigs[i]) returns (address rec) { if (rec
== s) { seen[seenLen++] = s; } } catch { }`. (`tryRecover` already
exists at line 574 and is `external pure`, so the self-call works
unchanged.) Add a test that includes one high-s signature alongside a
satisfied quorum and asserts finalisation still succeeds.


---

## Refuted


Recorded so the reasoning is not lost and the same finding is not re-filed.


### Refuted — Lean sweep (confidence high)

Traced the scenario through the actual source and it fails at the
first step. LegalKernel/Encoding/KernelStep.lean:165-181 implements
decoder arms for every tag the encoder emits: 7-12 as singletons (tag
alone, residual stream passed through, mirroring the encoder at lines
87-92), 13 as epochBudget with the same <2^64 actor guard the other
actor-keyed arms use, and 14 as budgetPolicy. Lines 161-164 — the
location the finding cites as the error arm — are a comment
introducing exactly those arms; the .error (.invalidConstructorIndex
other) catch-all is at line 182 and is reachable only for tags >= 15,
which the 15-constructor CellTag (FaultProof/Cell.lean:104-148) cannot
produce. The claim that the module ships no round-trip theorem is also
false: cellTag_roundtrip (lines 224-364) proves CellTag.decode
(CellTag.encode t ++ rest) = .ok (t, rest) by explicit cases over all
fifteen constructors, with arms for bridgeAmmReserveEth (322) through
budgetPolicy (361). Its hypothesis CellTag.fieldsBounded (line 197) is
not a smuggled escape: it is True on 13 constructors and a genuine <
256^8 head-width bound only on the two bare-Nat bridge keys, with the
UInt64-keyed arms discharged from uint64_key_lt_head (line 208).
Test/Encoding/KernelStep.lean:110-115 asserts round-tripping of
.epochBudget and .budgetPolicy by name, calling out that they are the
two present in every real bundle, plus the 256^8-1 boundary cases at
144-146. git log on the file shows commit ee72b6b "Close the CellTag
codec gap, gate the axiom claim, and prove the budget bound" as the
latest change with a clean …


### Refuted — Lean sweep (confidence high)

The finding's code citations are all accurate, but its failure
scenario does not reach the state it claims, so it is not a real
defect as reported. Accurate parts: `legalkernel_declareLocalPolicy`'s
precondition really is `True` (LegalKernel/Laws/LocalPolicy.lean:60)
with the policy parameter unused; `applyActionToLocalPolicies` really
does store the policy verbatim (Authority/SignedAction.lean:552-556);
`AdmissibleWith` (Authority/SignedAction.lean:295-316) really has no
`fieldsBounded` conjunct; and the §3.0 caps really are enforced only
on the decode side (Encoding/LocalPolicy.lean:402 for the clause
count, :134 / :149 / :177 for the per-list caps), while
`LocalPolicy.encode` (:388) is total. What refutes it: the auditor
never traced how a `SignedAction` enters the runtime. Every production
ingest path obtains actions by DECODING CBE bytes, and
`Action.decode`'s tag-15 arm is literally `Encodable.decode (T :=
LocalPolicy) s1` (Encoding/Action.lean:499-503), i.e. the capped
`LocalPolicy.decode`. Concretely: Main.lean:101-121
(`decodeSignedActionStream` / `readSignedActionsFromFile` ->
`Encodable.decode (T := SignedAction)` -> `Action.decode`);
Runtime/LogFile.lean:147-156 (`LogEntry.decode` -> `Encodable.decode
(T := SignedAction)`); Main.lean:940 (the `extract-events` stdin frame
loop decodes each `LogEntry` before replay). A 65-clause policy (or a
65-element denyTags/requireRecipientIn/allowTopUpFrom list) therefore
fails at frame decode with `DecodeError.invalidLength` and never
reaches `AdmissibleWith`, never reaches `apply_admissible_with`, and
never lands in …


---

## Second verification pass — the remainder

The first pass capped verification per area, leaving 28 findings re-
checked by nobody. They were put through the same adversarial stage
afterwards, so EVERY finding in this register now carries an
independent verdict. The result is reassuring about the original
triage: of the 28, exactly one is major and the rest are minor or
informational — the severity-ordered sampling had already caught what
mattered.

  * **28 re-verified**; **25 upheld**, **3 refuted**.
  * Corrected severities: 16 minor, 11 info, 1 major.
Several verdicts are 'real but reclassified': the observation holds
and the reasoning is sound, but the consequence the reporting auditor
drew does not follow, so the entry is recorded at the severity its
actual impact warrants.


### MAJOR — The idempotency cache replays a stored response without binding it to the request body, and its namespace is the service credential rather than the end user

*Verifier confidence:* high

Traced and confirmed on both halves. (1) No body binding:
`IdempotencyCache::get` (idempotency.rs:139-158) keys solely on
`scoped_key(credential, key)` (idempotency.rs:97-103) and
`submit/handler.rs:54-57` returns `cached` at line 55, ten lines
before `decode_body` at line 66 — the SignedAction bytes are never
read, let alone compared. idempotency.rs:31-33 concedes this outright
('the cache does not fingerprint the body'). No test covers same-
key/different-body:
`idempotency_key_replays_cached_response_without_resubmit`
(tests/integration.rs:650-679) only varies the key, never the body.
(2) The namespace is the *service* credential: `scoped_key` takes
`crate::auth::bearer_credential_key` over the bearer token
(handler.rs:143, auth.rs:189-191), and the target deployment is one
BFF holding one 'bearer service credential' for all its end users
(auth.rs:18-26, cors.rs:10). What makes this a defect rather than a
documented client responsibility is that the project's own contract
asserts the opposite safety property and its own plan recommends the
colliding key: gateway.openapi.yaml:543-548 states 'two clients
independently choosing the same value (nonce `1`, say) do not collide
and neither observes the other's verdict', while
gateway_integration_plan.md:908-909 tells the BFF to 'use the action
nonce' as the key — and nonces are per-actor (`expectsNonce es a`,
LegalKernel/Authority/Nonce.lean:244, with
`expectsNonce_advance_other` at :271 confirming independence across
actors), so two end users of one BFF both at nonce 1 produce the
identical scoped key. The result is exactly …


### MINOR — The C-3 AmountBounded conjunct is absent from the three signer-aware admission gates, so the budget grant can run when the kernel step no-ops

*Verifier confidence:* high

Traced end to end. `Action.compileTransition` returns
`Laws.freezeResource 0` for `.topUpActionBudget` /
`.topUpActionBudgetFor` / `.claimBudgetRefund`
(Action.lean:600,609,619), so `AdmissibleWith` conjunct 5
(SignedAction.lean:309) is vacuous for them.
`Laws.topUpActionBudget.pre` has TWO conjuncts
(TopUpActionBudget.lean:16-20): balance ≥ gasAmount AND
`AmountBounded` on the post-debit state. `topUpActionBudget_gasCheck`
(SignedAction.lean:750-758) enforces seven conjuncts and mirrors only
the first; `topUpActionBudgetFor_gate` (SignedAction.lean:891-903) and
`claimBudgetRefund_gate` (SignedAction.lean:1090-1105, which does
mirror the solvency conjunct — cf. `refund_pre_iff_pool_solvent`,
BudgetRefund.lean:284-297) likewise omit the ceiling conjunct.
`apply_admissible_with_budget` then runs `apply_admissible_with`
(which is `step_impl`, SignedAction.lean:615) and `applyGrant`
independently (SignedAction.lean:1195-1229), so a failing
`AmountBounded` no-ops the kernel step while the budget grant still
lands. The bridge production path shares the identical gate list
(Bridge/Admissible.lean:496-517), so it is not saved by being bridge-
aware. The comment at SignedAction.lean:618-620 ("the admission gate
rejects the action earlier when the gas precondition fails, so the no-
op branch is reachable only by callers that bypass the budget gate")
is now false. Constructibility: `Laws.mint.pre` is `amount > 0 ∧
AmountBounded` (Mint.lean:55), so a single mint of `maxAmount - 2` to
`gasPoolActor` at r=0 is admissible and puts the pool one step from
the ceiling. Severity held at minor …


### MINOR — Laws.topUpActionBudget and Laws.depositWithFee ship with no conservation, locality, or classification results, unlike every sibling law

*Verifier confidence:* high

Confirmed by reading both files whole.
`LegalKernel/Laws/TopUpActionBudget.lean` is 27 lines and contains
only the `Transition` — no theorems, no instances.
`LegalKernel/Laws/DepositWithFee.lean` is 46 lines with exactly one
theorem (`depositWithFee_other_resource_untouched`, line 28) and no
instances. The two structurally identical siblings carry the full
ladder: `topUpActionBudgetFor_isConservative/_isMonotonic/_localTo/_fr
eezePreserving_empty` (TopUpActionBudgetFor.lean:304,320,333,370) and
`claimBudgetRefund_*` (ClaimBudgetRefund.lean:308,322,334,369). A
repo-wide grep for any classification instance naming either law
returns nothing. The results are true — `topUpActionBudget`'s
`apply_impl` is debit-then-credit of the same `gasAmount` with
`getBalance ≥ gasAmount` in `pre`, conservative including the `a =
poolActor` self-case; `depositWithFee` is credit-only, hence
monotonic. `ConservativeLawSet.cons` / `MonotonicLawSet.cons` /
`FreezePreservingLawSet.cons` (Conservation.lean:833,848,864) each
demand the instance, so the laws cannot be consed. Downgrading the
narrative slightly: the instance argument is an ordinary instance-
implicit, so a deployment could discharge it locally with `haveI`
rather than being forced to drop the ratified claim. That makes this a
real library-completeness gap (and an `implement-the-improvement`
obligation) rather than a hard blocker.


### MINOR — `CanonicalBounds.base_amt` and `Laws.bulkRecipients` docstrings state a `2^128` amount-head modulus that the code has not used since `maxAmount` became `2^256`

*Verifier confidence:* high

PARTLY real — the anchor site holds, the second cited site does not.
CONFIRMED: LegalKernel/FaultProof/Commit.lean:719-721 documents the
field as "Each inner balance fits the 33-byte amount head's `2^128`
range" while line 722 is `base_amt : ... q.2 < 256 ^ 32`;
`cborAmountHeadEncode` (Encoding/CBOR.lean:403-404) is `cbeTagAmount
:: natToBytesLE n 32` and `Laws.maxAmount` (Laws/AmountBound.lean:77)
is `256 ^ 32`, so the stated modulus is off by 2^128 and a 33-byte
head cannot describe a 2^128 range at all. The drift is broader than
the finding says: LegalKernel/FaultProof/SubStep.lean:147-149 still
calls `encodeAmount` "a 16-byte little-endian body, so it truncates
modulo `2^128`", Encoding/StateInjective.lean:113-120 says "the bound
is `2^128`", and FaultProof/Terminate.lean:555 says "a balance past
`2^128`". REFUTED: the second cited site is already correct —
Laws/BulkBound.lean:95-97 reads `2^256` in all three places, and lines
105-113 explicitly say C-3 is "since **closed** ... proved unreachable
by `FaultProof.canonicalBounds_base_amt_of_reachable`", so the
finding's claim that it "still describes the C-3 obligation as open"
and asserts a `2^128` truncation mechanism is false against HEAD. No
behavioural impact — every enforced bound in code is `256 ^ 32` — so
this is documentation-only, but a fix is implied by the project's
implement-the-improvement rule.


### MINOR — Admissibility conjunct 5 is `True` for the three signer-aware value-moving actions, so the documented `apply_admissible` entry point moves funds with no gate at all

*Verifier confidence:* high

Traced end to end and the mechanism holds. `AdmissibleWith` conjunct 5
is `(Action.compile st.action).transition.pre es.base`
(Authority/SignedAction.lean:309); `Action.compileTransition` returns
`Laws.freezeResource 0` for `.topUpActionBudget` /
`.topUpActionBudgetFor` / `.claimBudgetRefund`
(Authority/Action.lean:600,609,619) and `Laws.freezeResource`'s `pre`
is `fun _ => True` (Laws/Freeze.lean:71-74), so conjunct 5 is vacuous
for exactly those three. Meanwhile `apply_admissible_with` steps
`Action.toTransition st.action st.signer` (SignedAction.lean:606,622),
which for `.claimBudgetRefund` is `Laws.claimBudgetRefund signer
poolActor gasResource (budgetUnits * weiPerBudgetUnit)`
(Action.lean:704-711), whose only precondition is `getBalance s
gasResource poolActor >= refundAmount` plus `AmountBounded`
(Laws/ClaimBudgetRefund.lean:97-102) — nothing pins `poolActor =
Bridge.gasPoolActor`, the rate, or the claimant's retirable budget.
All nine of those checks live only in `claimBudgetRefund_gate`
(SignedAction.lean:1090-1106), reached only from
`apply_admissible_with_budget` /
`apply_bridge_admissible_with_budget`. So the `apply_admissible`
docstring (SignedAction.lean:1229-1231, "the only externally callable
state-advance path. The dependent `Admissible` witness ensures every
call site has discharged the five-condition check") is false in both
halves: it is not the only path, and the check is vacuous for the
three signer-aware value-moving constructors. Downgrading from exploit
to hazard: no in-repo production caller uses it —
Runtime/Loop.lean:220,558 and …


### MINOR — `gapCountClosed` is dead code whose docstring claims the verifier uses it; the closed form the on-chain length gate depends on is never proved equal to the gap enumeration

*Verifier confidence:* high

Confirmed on both halves. (a) Dead code + false docstring:
`gapCountClosed` (FaultProof/Frontier.lean:854-856) claims 'The
verifier uses this', but `verifierPostRootMulti` computes `let levels
:= multiGapLevels smtDepth preOpened` and gates on
`b.proof.isWellFormedFor levels` (FaultProof/Terminate.lean:463-464) —
the enumeration, never the closed form. Tree-wide grep puts `gapCountC
losed`/`gapCount`/`activeAt`/`mergesAt`/`gapsAt`/`adjacentDivs` only
in their own definitions (Frontier.lean:826-856) and one test
(Test/FaultProof/Frontier.lean:180-190) that checks `gapCount ==
gapCountClosed` on exactly two frontiers. (b) No proof links the three
quantities: no theorem `gapCount = gapCountClosed`, and none relating
either to `(multiGapLevels d opened).length`;
`multiGapLevels_length_eq` (MultiProof.lean:954-956) relates gap
levels to `multiSiblings`, both enumerations. (c) The closed form is
what L1 enforces: `SmtMultiVerifier.gapCount` is `g = SMT_DEPTH + 1 -
m + Σ divLevel` (solidity/src/lib/SmtMultiVerifier.sol:158-166, self-
described as 'mirroring Lean's `gapCountClosed`') and `requireShape`
derives `wantMask = (g+7)/8`, the padding-bit sweep and `wantSibs =
popcount*32` from it (:264-300). The only cross-stack link is a
fixture column: Test/Bridge/CrossCheck/MultiProof.lean:208 emits
`levels.length` under key `gapCount`, read back by
solidity/test/CrossCheck/MultiProof.t.sol:189-207. Held at minor
rather than major: divergence is hypothetical today and agreement is
implicitly exercised on every multiproof corpus entry (a mismatch
reverts inside `requireShape`), so this …


### MINOR — `BoundsReachable`'s stated justification for leaving `eb_val` undischarged ('advances a nonce by one') is false for `budgetBalance`

*Verifier confidence:* high

The quoted text is present and is contradicted 270 lines later in the
same file. FaultProof/BoundsReachable.lean:41-50 still groups 'the
`2^64` value fields (`nonces_val`, `eb_val`)' under one argument —
'Each step adds at most a bounded number of entries and advances a
nonce by one, so `2^64` is unreachable in any real trace' — offering
`AdmissibleReachableIn` + `expectsNonce_le_of_reachableIn` as the
substitute. The same file's § at :313-370 says the opposite for the
budget field: '**The budget half is NOT the same argument, and an
earlier draft of this docstring stated it wrongly**', citing (i)
`ActorBudget.normalise` flooring a stale cell at the unbounded policy
`freeTier` before the credit and (ii) `depositWithFee`'s `budgetGrant`
reaching `applyGrant` via `depositWithFee_signerCheck`, which
constrains the signer (`= bridgeActor`) and not the amount — unlike
`topUpActionBudget_gasCheck`'s `budgetIncrement ≤
MAX_TOPUP_BUDGET_PER_ACTION` (Authority/SignedAction.lean:682, :755,
:902). I confirmed the uncapped grant at SignedAction.lean:1197-1198
and :1737-1738 (`ebs.topUp recipient currentEpoch freeTier
budgetGrant`), and the free-tier lift is an executable pin at
Test/Authority/ActorBudget.lean:126-143 ('OBLIGATION: the free tier
lifts a balance past the grant cap'). The underlying residual is real
— the file itself notes at :359-370 that at the ceiling Lean's
`Encodable Nat` truncates while Solidity's `CBEEncode._leBytes`
reverts, so the stacks diverge. Two corrections to the finding's
narrative keep this at minor rather than major: a true per-step bound
DOES exist and …


### MINOR — Authenticated read responses carry an ETag with no Cache-Control, and Vary: Origin is emitted only on the origin-allowed branch

*Verifier confidence:* high

Both code facts verified. (a) `actor_balance` (balances.rs:63) and
`actor_balances` (balances.rs:127) attach `ETag` + `X-Knomosis-Seq`
via `json_with_seq` (balances.rs:145-149), which sets no cache
directive; a repo-wide grep for `Cache-Control` in runtime/knomosis-
gateway/src returns only the two SSE paths (conn.rs:602,
events/stream.rs:166) — no read endpoint emits one. (b)
`cors::response_headers` returns `Vec::new()` on both the origin-
absent and origin-not-allowed branches (cors.rs:118-123), so `Vary:
Origin` (cors.rs:126) is emitted only when the origin is on the
allowlist, even though the response demonstrably varies on Origin
whenever a policy is configured. Severity held at minor rather than
raised: scenario (a) is overstated — there is no `Last-Modified`, so
heuristic freshness computes to ~0 and a private cache revalidates
(re-presenting the credential through `auth::gate`), and RFC 9111 §3.5
forbids a shared cache from storing Authorization-bearing responses at
all, so 'served after credential rotation' is not established.
Scenario (b) is a genuine conformance bug but its reachable surface is
the three auth-exempt paths (`/healthz`, `/readyz`, `/rpc`,
auth.rs:202-204), which also flow through `respond`/`cors::decorate`
(handler.rs:112-117) and carry only public data — so the concrete harm
is a broken legitimate cross-origin client (e.g. the wallet Add-
Network `/rpc` flow), not disclosure. Real defensive-header gap worth
fixing (`Cache-Control: no-store` on authenticated reads;
unconditional `Vary: Origin` whenever a policy is configured), no
security break.


### MINOR — Watermark fallback `oldest_seq - 1` collides with the live-tail sentinel when the ring starts at seq 1

*Verifier confidence:* high

Traced end to end and it holds. `mux.rs:195-200` `next_resume` =
`ring.watermark().or_else(|| ring.oldest_seq().map(|s|
s.saturating_sub(1))).unwrap_or(previous)`. `ring.rs:198-199`/`214`
show `watermark` stays `None` until a second distinct seq is ingested,
so a mux that has seen only group 1 has `watermark() == None` and
`oldest_seq() == Some(1)` → `next_resume` returns 0. 0 is the reserved
live-tail sentinel, not "just before seq 1": `subscribe.rs:30-31`
("`0` means start from the live tail") and the server
`event_cache.rs:340-345` returns `RangeOutcome::AtLiveTail` for
`from_seq == 0` *even on a populated cache*, and its own docstring
(event_cache.rs:299-306) states the exclusive `seq > from_seq`
contract cannot express "from seq 1" — `FROM_OLDEST` (u64::MAX) is the
intended encoding. So on a drop/`--sse-stale-secs` fire in that state
the resubscribe skips every event cached between the drop and
reconnect. The loss is silent: `ring.rs:206-212` `push` only guards
monotonicity (no contiguity/gap check), and `position`
(ring.rs:281-284) with `last_evicted == None` classifies a client
cursor `(1,0)` as `InWindow` against a ring whose oldest is still
`(1,0)`, so no `Behind` signal and no backfill steer. Narrow
precondition (gateway started against a fresh log so the ring's oldest
is exactly seq 1, drop before any second seq), and the blast radius is
the SSE notification surface rather than consensus — but it defeats
the module's stated no-silent-gap property (mux.rs:20-32, §2 principle
7). Minor, as reported.


### MINOR — Multi-subscription fan-in can silently drop records: `push`'s reject is ignored and the dedup guard is monotonic-only

*Verifier confidence:* medium

Mechanism verified. `EventRing::push` (ring.rs:205-225) rejects any
`cursor <= last` where `last` is a monotone frontier persisting across
eviction — a strictly-increasing gate, not a seen-set.
`http/server.rs:133-140` spawns N muxes sharing one `Arc<FanoutState>`
whose ring is a single `Mutex<EventRing>` (fanout/mod.rs:36-56), and
`Mux::run_epoch` throws the bool away at mux.rs:159, so a drop is
never logged or counted. The divergence premise checks out in the
upstream: the broadcast uses a once-per-batch registry snapshot and a
mid-batch registrant is 'uniformly EXCLUDED from this batch ... or
skip[s] them (`resume_from = 0` live-tail)' (knomosis-event-
subscribe/src/server.rs:1301-1315). Every mux starts at `resume_from =
0` (mux.rs:114) and `next_resume` degrades to `previous` (=0) while
the ring is still empty (mux.rs:195-200), so a mux whose first connect
fails (`ConnectFailed`, subscribe.rs:196-199) re-enters live-tail
later, widening the skew window. No downstream signal exists:
`position` infers contiguity from `last_evicted`/`oldest` only
(ring.rs:254-295), so a hole in the middle of the retained window
still reports `InWindow` and clients get ...100 then 106 with no gap.
This directly refutes the explicit claim at mux.rs:16-17 and
http/server.rs:128-131 that 'N > 1 loses no record'; no test covers
N>1. Held at minor rather than major because `--upstream-
subscriptions` defaults to 1 (config.rs:1376) and the loss
additionally requires the leading mux to be backlogged at the instant
the trailing mux pushes — a genuine race, not deterministic. Post-
startup …


### MINOR — The SSE ring is bounded in record count but not in bytes

*Verifier confidence:* high

Verified: eviction is purely count-based — `while self.buf.len() >
self.capacity` (ring.rs:219-223) — and I found no byte accounting
anywhere under knomosis-gateway/src/events/ (grep for
data.len()/total_bytes/max_bytes returns nothing). Each retained
`EventRecord` owns the fully rendered JSON `String` (ring.rs:92,
produced at mux.rs:236-244), and the rendering expands: `hex()` is 2x
for byte fields (decode.rs:123-131) and an unknown tag base64s the
entire payload (decode.rs:107). The size premise holds:
`IdentityRegistered.key` is an unbounded `Vec<u8>` (knomosis-
indexer/src/event.rs:144-148) capped only by `HARD_MAX_BYTE_STRING_LEN
= 1 MiB` (decoder.rs:77) and the 1 MiB frame default (gateway
config.rs:132, ceiling 16 MiB; host frame.rs:88), and the Lean side
really does impose no key-length bound — `abbrev PublicKey : Type :=
ByteArray` (Authority/Crypto.lean:55) with `lex_pre := fun (_ : State)
=> True` (Laws/RegisterIdentity.lean:50). At the default
`ring_capacity: 4096` (config.rs:536) the worst case is multi-GiB
resident memory. Kept at minor rather than major: a read-side
availability/resource-bound gap on a BFF service, not a consensus or
admissibility break, and each oversized action must first be admitted
(nonce + budget cost).


### MINOR — `records_after` scans and clones the entire ring under the shared mutex on every client poll

*Verifier confidence:* high

The code fact is exactly as described: `records_after` filters the
whole `VecDeque` and collects a fresh `Vec` (ring.rs:230-236), and
`run_stream` calls it while holding the shared ring guard together
with `position` (dispatch.rs:153-161). The deque is provably sorted by
the strictly-increasing `push` invariant (ring.rs:205-216), so
`VecDeque::partition_point` would reduce this to O(log n) + O(matches)
— the scan is genuinely unnecessary. Cited constants check out:
`STREAM_POLL = 100ms` (stream.rs:37-38), `max_streams: 256`,
`ring_capacity: 4096` (config.rs:536-537). The failure narrative is
overstated: for a caught-up client (the common case) the filter
matches nothing, so there are no `Arc` refcount bumps — just ~4096
derefs and cursor compares per poll, an aggregate lock-held duty cycle
of tens of ms/sec, not enough to starve the mux writer. The
amplification is real only once clients accumulate backlogs, when the
clones do occur under the lock. Efficiency/scalability defect with a
clear fix, no correctness impact.


### MINOR — Strict-mode refund pool-solvency check multiplies two wire-controlled integers without overflow checking and fails OPEN on wrap

*Verifier confidence:* high

Traced and confirmed the arithmetic defect. runtime/knomosis-
host/src/budget.rs:1486 is `let refund_amount =
u128::from(budget_units) * wei_per_budget_unit;` — a plain `*`; grep
for `checked_mul`/`saturating_mul` in that file returns only this
line, so there is no guarded variant anywhere. Both operands are full-
range and wire-derived: budget.rs:590 decodes `budget_units` via
`cur.read_uint()` (budget.rs:~760, unconstrained `u64::from_le_bytes`)
and `wei_per_budget_unit` via `cur.read_amount()` (budget.rs:806-812),
which rejects only `head[17..33]` non-zero, i.e. accepts all of `[0,
2^128)`. Product range is `[0, 2^192)`. runtime/Cargo.toml:248-254
`[profile.release]` sets opt-level/lto/codegen-units/debug/panic/strip
and NOT `overflow-checks`, so release wraps; the wrapped value can be
0 (4 * 2^126), and budget.rs:1487's `balance_of(...) < refund_amount`
then passes against an empty pool — the check inverts from fail-closed
to fail-open. The upstream guards I looked for do not close it: the
only bounds before line 1486 are `wei != 0`, `budget_units != 0`,
`gas_resource in {0,1}`, and signer != bridge/pool
(budget.rs:1465-1483) — none bounds magnitude. The debug/release
verdict split is also real (`catch_unwinding_submit`, server.rs:484).
What lowers this from the reported framing: the arm is inside `if
self.strict`, and `with_strict_checks()` (budget.rs:1252) has exactly
one caller in the tree — kernel.rs:820, inside a `#[test]`. Production
wiring at main.rs:191-193 builds
`BudgetGate::new(policy).with_epoch_length(...)` with strict OFF, and
attaches it only to …


### MINOR — `read_current_epoch` fails open on a corrupt cell, silently wiping a live epoch's grant/consumption counters

*Verifier confidence:* high

Confirmed, including the outlier claim and the destructive
consequence. runtime/knomosis-indexer/src/budget_view.rs:106-114: the
wrong-length arm logs `tracing::warn!` and returns `Ok(0)` rather than
an error. Every sibling I checked fails closed: cursor.rs:218-221
`decode_cursor` -> `CursorError::CorruptCell`;
combined_transaction.rs:959-964 `read_cell` ->
`BudgetStorageError::CorruptCell`; indexer.rs:488-493 `balance_get` ->
`BalanceError::CorruptCell`. All three are same-shape `Some(bytes) if
bytes.len() == N` / `Some(bytes) =>` matches, so this one is genuinely
the odd path out. The blast radius traces through: budget_view.rs:210
`let persisted_epoch = read_current_epoch(tx)?;` -> 211 `if new_epoch
== persisted_epoch { return Ok(false) }` -> 214
`tx.reset_current_epoch()?`, which at combined_transaction.rs:732-745
executes `DELETE FROM actor_budgets_current_epoch_grants` and `DELETE
FROM actor_budgets_current_epoch_consumed`. With a corrupt cell mid-
epoch-7 the fabricated 0 makes `7 != 0` true, so the live epoch's
grant/consumption rows are unconditionally deleted and the cell
rewritten to 7 — self-healing but data-destroying, and the lifetime
tables are not epoch-scoped so it is unreconstructable. Called from
indexer.rs:345 in `apply_batch`, on every batch. No upstream guard:
`epoch_length = 0` only short-circuits via `epoch_for_seq` returning
0, which does not help when the persisted value is the corrupt one.
Severity stays minor rather than higher because the indexer is a read-
only view (it feeds `BudgetReadView::remaining_this_epoch`, not an
admission gate), and …


### MINOR — `--epoch-length` is neither persisted nor validated, so a restart under a different value silently mis-scopes the per-epoch budget tables

*Verifier confidence:* high

Traced end to end. `epoch_for_seq` (budget_view.rs:176-184) derives
the epoch purely from the in-memory flag, and
`dispatch_epoch_if_crossed` (budget_view.rs:204-223) compares that
against the PERSISTED `c/current_epoch` cell (key
`b"c/current_epoch"`, budget_view.rs:82). The flag reaches the indexer
only through `Indexer::open_with_config` (indexer.rs:248-269), which
stores it in the struct and logs it; the only durable check on open is
`ensure_identifier(storage, INDEXER_IDENTIFIER)` (indexer.rs:253),
which validates a fixed identifier string, not any config. Grep over
runtime/ shows `epoch_length` never written to storage anywhere (only
config.rs:292/310 parse, main.rs:84/113 pass-through). So the two
numbers being compared are only commensurate if the divisor never
changed. Both branches of the failure scenario hold: a changed divisor
that yields a different quotient fires `tx.reset_current_epoch()` mid-
epoch (budget_view.rs:214), wiping live
`current_epoch_grants`/`consumed`; a changed divisor that happens to
yield the same quotient returns `Ok(false)` and suppresses the reset,
so `remaining_this_epoch` (budget_view.rs:532-535) under-reports
indefinitely. Note the same non-persistence applies to `--gas-pool-
actor`, and `epoch_length = 0` is not distinguished from a real value
— it maps to epoch 0 via `checked_div` returning `None`, so switching
100 -> 0 also triggers a spurious reset. Severity minor, not major:
the indexer is a read/index view, the kernel's own admission gate
keeps its epoch state independently in `knomosis-
host::budget::BudgetGate`, and …


### MINOR — CBEEncode._leBytes reverts on values >= 2^64 where Lean's cborHeadEncode truncates, turning a no-op step into an un-adjudicable revert

*Verifier confidence:* high

Confirmed on both stacks, and the repo's own source agrees. Lean:
`cborHeadEncode major n = major :: natToBytesLE n 8`
(Encoding/CBOR.lean:315, with natToBytesLE at 214-216 taking `n % 256`
per byte) truncates mod 2^64 and its own docstring says so;
`budgetCellValue` (FaultProof/CellStore.lean:109-112) encodes
`budgetBalance : Nat` through exactly that head. Solidity:
CBEEncode._leBytes (lib/CBEEncode.sol:73-79) reverts `CBEValueTooWide`
when `widthBytes < 32 && n >= 1<<(8*widthBytes)`, and `uintValue`(102)
-> `epochBudgetValue`(153-159) is what
StepWrites.deriveEpochBudgetCellValue returns (StepWrites.sol:1043),
with `_topUp` doing an unbounded `bn.budgetBalance + amount` (242). No
bound exists on the Lean side: ActorBudget.topUp is a plain Nat add
(ActorBudget.lean:53) and `mkBounded` clamps only actionCost
(`.bounded freeTier (max actionCost 1) currentEpoch`,
Authority/Nonce.lean:80-81), leaving freeTier an unbounded Nat that
`normalise` floors every stale cell to.
FaultProof/BoundsReachable.lean:329-370 states this finding verbatim —
'The Solidity mirror does not truncate: it REVERTS ... the party whose
turn it is would lose by timeout' — and lists the routes: freeTier at
2^64 ('a configuration a deployment controls and nothing currently
rejects'), an oversized bridge-signed grant (depositWithFee is signer-
checked, not amount-checked), or ~1.8e13 capped top-ups. Not minor-by-
narrative but minor-by-reachability: the L1 clamp
MAX_BUDGET_PER_DEPOSIT = 1e12 (KnomosisBridge.sol:398,1293) makes the
volume route economically absurd, so the practical trigger is …


### MINOR — StepWrites.decodeBudgetPolicy omits Lean's actionCost != 0 canonicality gate, so the L1 adjudicates a policy the Lean verifier refuses

*Verifier confidence:* high

Real, and I confirmed every link.
solidity/src/lib/StepWrites.sol:177-190 (`decodeBudgetPolicy`) checks
only `value.length != 4 * CBE_UINT_LEN` and the constructor tag
`_readUint(value,0) != 0`; it accepts `actionCost = 0`. Its Lean
counterpart `Encoding.BudgetPolicy.decode`
(LegalKernel/Encoding/State.lean:980-984) returns `.error
(.nonCanonical "budgetPolicy actionCost must be >= 1")`. That `none`
propagates: `deriveEpochBudgetCellValue`
(LegalKernel/FaultProof/VerifierWrites.lean:495-503) returns `none` on
any policy-decode failure and `derivedCellValue`'s `.epochBudget` arm
(LegalKernel/FaultProof/Terminate.lean:218-222) forwards it, so
`verifierPostRootMulti` yields no root — and since the epoch-budget
cell is written on EVERY action, the Lean verifier adjudicates NO step
under such a policy while KnomosisStepVMRoot adjudicates all of them
(StepWrites.sol:1002,1038 is the only decode site; no compensating
gate exists anywhere in solidity/src). The trigger value is exactly
`canonicalAbsentValue .budgetPolicy = .bounded 0 0 0`
(LegalKernel/FaultProof/CellValue.lean:82-84), so it arises whenever
the policy cell is canonically absent, not just via an explicit
literal. What caps severity: (a) reachability is narrow — the CLI
genesis path routes through `mkBounded` with `getD 1`
(Main.lean:1078,1082) and `mkBounded` clamps `max actionCost 1`
(LegalKernel/Authority/Nonce.lean:80-81); `ExtendedState.empty` is
`.bounded 0 1 0` (Nonce.lean:202,217); `advanceEpoch` preserves the
cost; only a direct record literal reaches it, and such a state does
not round-trip the CBE state …


### INFO — The kernel's unrestricted `Reachable` relation is the universal relation, so `invariant_preservation` over it is unusable for any non-constant predicate

*Verifier confidence:* high

The mathematical claim checks out: `Transition` (Kernel.lean:164-175)
constrains nothing, `step_impl` is `if t.pre s then t.apply_impl s
else s` (Kernel.lean:196), and at `t := ⟨fun _ => True, fun _ =>
isTrue trivial, fun _ => s'⟩` the `ite` iota-reduces so
`Reachable.step s0 t Reachable.base trivial : Reachable s0 s'`
typechecks for any `s'`. Hence `Reachable` is universal and
`invariant_preservation`'s `h_step` at the unrestricted relation is
dischargeable only for predicates constant on `State`. But this is not
a defect and not an undocumented trap — it is the stated design,
spelled out 70 lines below the cited docstring in the same file:
Kernel.lean:334-345 says verbatim that "properties that fail under the
unrestricted `Reachable` relation may still hold under
`ReachableViaLaws`, as long as the offending laws aren't in the
deployed set", and gives the mint/transfer conservation example.
`ReachableViaLaws` + `invariant_preservation_via_laws`
(Kernel.lean:350,382) are the supplied instruments, and every
substantive invariant in the tree uses a restricted relation
(`Conservation.lean:607,669,802`; `Bridge.BridgeReachable`;
`FaultProof.AdmissibleReachableIn`). Grep shows no production consumer
of the unrestricted `invariant_preservation` at all — only the axiom-
footprint assertion and the trivial-invariant term-stability tests
(KernelTests.lean:232-260). The cited docstring's claim ("illegal
applications cannot extend the reachable set") is literally true of
the constructor and asserts nothing about non-universality. True
observation, no action implied.


### INFO — The fail-closed startup warning understates the auth-exempt surface: it omits /rpc

*Verifier confidence:* high

Confirmed by direct read. `runtime/knomosis-
gateway/src/http/server.rs:116-120` warns "every request except
/healthz and /readyz will be rejected (401/403)", while
`auth.rs:202-204` is `matches!(path, "/healthz" | "/readyz" | "/rpc")`
and `gate` (auth.rs:213-215) returns `None` for every exempt path
before any credential check; `rate_limit_check`'s own docstring
(auth.rs:236) even names all three. `/rpc` is not a static probe:
`rpc.rs:107-119` parses a JSON body up to `--max-frame-size` and
`handle_one`'s `eth_blockNumber` arm (rpc.rs:167) reads the indexer
cursor via `current_block` → `read_cursor(&reads.storage)`
(rpc.rs:216-224). So the operator-facing message describes a strictly
smaller open surface than the code implements. No exploit — a
documentation/message accuracy defect on an operator-facing security
control, and the code's own comments are the better artefact, so the
fix is to correct the warning string. Severity info is right.


### INFO — write_response emits Content-Length on 204 No Content responses, which RFC 9110 forbids

*Verifier confidence:* high

Confirmed. `http/conn.rs:1176` writes `Content-Length: {}`
unconditionally for every outcome; the only status-sensitive code in
the writer is `reason_phrase` (conn.rs:1235 maps 204). Nothing strips
it — `grep -n 204 http/{conn,handler,plain,tls}.rs` finds only the
reason-phrase arm, and `router.rs:161-162` explicitly documents that
"the IO shell emits Content-Length: 0" for `no_content()`. Both 204
producers are live: `cors.rs:170` (`preflight`, reachable whenever
`--cors-origin` is set) and `rpc.rs:136` (JSON-RPC notification / all-
notification batch, on the auth-exempt `/rpc`). RFC 9110 §8.6 is a
MUST NOT for 1xx and 204. Impact is conformance only: the declared
length agrees with the actual empty body, so there is no
request/response desync and mainstream intermediaries tolerate it; the
sharp edge is that this is a hand-rolled reader/writer that rejects
framing sloppiness on the request side (conn.rs:991-1007). Info.


### INFO — Host budget decoder narrows the CBE amount space to 2^128 while the Lean encoder/kernel admits up to 2^256, so identical bytes get different verdicts on the two stacks

*Verifier confidence:* high

Divergence confirmed on both sides. Rust: runtime/knomosis-
host/src/budget.rs:804-807 rejects any amount with a non-zero byte in
`head[17..33]` as `BudgetDecodeError::AmountTooWide`, capping the
accepted space at `[0, 2^128)`. Lean:
LegalKernel/Laws/AmountBound.lean:77 `def maxAmount : Nat := 256 ^ 32`
(= 2^256) and line 96 `getBalance s r a + amount < maxAmount`;
Encoding/Encodable.lean:244-245 `encodeAmount = cborAmountHeadEncode`
over the full 32-byte payload (CBOR.lean:403, 33-byte head), and
Encodable.lean:253 `amount_roundtrip` is proved for `n < 256 ^ 32`. So
`[2^128, 2^256)` is encodable, round-trippable and admissible on the
Lean side and unparseable on the Rust side — a genuine accept/reject
boundary split between stacks that are meant to agree byte-for-byte.
Impact is correctly bounded to informational: the direction is fail-
closed (reject, not truncate — the comment at budget.rs:800-804 says
so explicitly and cites C-3), and the path is dev-only —
`decode_budget_view` has exactly one caller outside its own module,
kernel.rs:533 inside `mod mock`, and kernel.rs:552 maps the error to
`Verdict::ParseError`; production `CommandKernel` forwards the CBE
bytes to the Lean binary opaquely. The project already tracks the
general remedy (open task 'Widen the Rust amount representation to
256-bit'). Real observation, correct severity as filed.


### INFO — `BalanceView::credit` writes a saturated `u128::MAX` balance non-transactionally before returning the overflow error

*Verifier confidence:* high

The code behaviour is exactly as described: `BalanceView::credit`
(balance.rs:212-235) on `checked_add` -> `None` calls `self.set(actor,
resource, Amount::MAX)` — which is an unconditional `self.storage.put`
(balance.rs:191-201) with no transaction — and only then returns
`BalanceError::CreditOverflow`. `credit_overflow_saturates`
(balance.rs:520-541) asserts the persisted `u128::MAX` after the
error, so it is intentional and pinned, not an oversight. I could not
refute the write itself. What I can refute is the impact framing. (a)
The production path is the transactional twin
`indexer::balance_credit` (indexer.rs:513-533) reached via
`apply_batch`; every mutation there rides one `begin_combined_tx`
(indexer.rs:338) and the `?` on error drops the tx without commit, and
`SqliteCombinedTransaction`/`SqliteBudgetTransaction` ROLLBACK on Drop
(budget_storage.rs:800-806, combined_transaction.rs:302), so the
saturated cell never lands. (b) There is no non-test caller of
`BalanceView::credit` in the workspace: grep for `.credit(` hits only
balance.rs:507/516/526/604; every other `BalanceView` use
(main.rs:225, gateway-bench fixture.rs:168, indexer tests) calls
`get`/`set`/`scan_all` only. (c) The behaviour is documented on the
method and in the module header (balance.rs:38-42, 205-207), so an
external caller is warned rather than surprised. It is a genuine fail-
open API wart on a `pub` surface worth removing (write-then-error is
never the safer order), but with zero live callers and a rollback-
protected production path it carries no action beyond hygiene — info,
not minor.


### INFO — CBE amount-head constants are documented at 17 bytes while the code and the Lean authority use 33

*Verifier confidence:* high

Verified every citation. decoder.rs:64-65 reads `/// Length of a CBE
amount head (1-byte tag + 16-byte LE u128).` immediately above `pub
const AMOUNT_HEAD_LEN: usize = 33;` — the prose sums to 17.
`write_amount` (decoder.rs:537-541) says 'on the 16-byte amount head';
`EncodeError::AmountExceedsBound` (decoder.rs:528-530) says 'they ride
the 16-byte amount head'. `read_amount` (decoder.rs:234-237) says 'The
head is 32 bytes' — that is the body width, not the head. Only
`write_amount_head` (decoder.rs:502-511) is correct, and its own body
confirms the layout: `push(CBE_TAG_AMOUNT)` + 16 LE bytes + 16 zero
bytes = 33. The Lean authority agrees with the code, not the comments:
`cborAmountHeadDecode` reads `natFromBytesLE rest 32` after the tag
(CBOR.lean:413-421) and `cborAmountHeadEncode_length` proves `= 33`
(CBOR.lean:433-437). So the constant and both stacks are right and
four doc comments are wrong — no runtime or wire effect, and round-
trip/cross-stack corpora are unaffected because nothing reads the
prose. Pure comment rot on a wire-format spec that three stacks must
agree on; per the project's implement-the-improvement rule the fix
direction is to correct the comments (here the docs are the inferior
artefact). Info.


### INFO — `terminateOnSingleStep` omits the turn-deadline check that every other move enforces

*Verifier confidence:* high

The code fact is exact: KnomosisFaultProofGame.sol:397 and :432 gate
on `block.number > g.turnDeadline`; terminateOnSingleStep (lines
465-483) checks only status, `high.idx - low.idx == 1`,
`!hasPendingMidpoint` and `msg.sender == responsible` — grep for
`turnDeadline` returns hits at 112/365/397/415/432/455/583 and none
inside terminate. So terminate and claimTimeout (line 580-591,
requires `block.number > g.turnDeadline`) are simultaneously callable
after expiry and can race. But the auditor's failure scenario is
unreachable, for two independent reasons. (1) `g.turn` is Sequencer
whenever `hasPendingMidpoint` is false: it is set Sequencer at
initiateChallenge:363-364, flipped to Challenger only in
submitMidpoint:413 (which sets hasPendingMidpoint=true) and back to
Sequencer only in respondToMidpoint:453 (which clears it). terminate
requires `!hasPendingMidpoint` (line 470), so `responsible` is ALWAYS
`g.sequencer` — a challenger can never call it, so no challenger
front-run and no challenger-triggered slash of the sequencer. (2) The
move is truth-determining: executeStepToRootMulti recomputes the post-
root from `g.low.commit` and the derived writes, so a late terminate
settles on the merits (an incorrect sequencer still loses). The
residual is only that the sequencer can escape a `TimedOutSequencer`
slash by playing late when its root is in fact correct — and the
migration-plan spec for this entry point
(docs/planning/fault_proof_migration_plan.md:3265-3285) deliberately
lists no deadline step, unlike submitMidpoint (step 3, line 3211) and
respondToMidpoint (step 3). …


### INFO — SMT leaf level hashes two variable-length operands with no length separation, leaving an unguarded concatenation boundary

*Verifier confidence:* high

The described code shape is exactly as reported: SmtVerifier.sol:84-95
hashes `abi.encodePacked(leafSibling, leaf)` / `(leaf, leafSibling)`
with both operands `bytes memory`, while the upper-level loop at
113-119 reverts `SmtBadSiblingSize` unless every sibling is exactly 32
bytes — the leaf-adjacent sibling `siblings[SMT_HEIGHT-1]` is consumed
before the loop and is exempt by construction. I confirmed the safety
today rests on the leaf's rigidity, not on any check in the verifier:
KnomosisBridge.withdrawWithProof (2022) passes `proofLeaf`, which
keccak-equals `leafBlob` (line 2019), and `_decodePendingWithdrawal`
(2067-2079) forces exactly 9 (readUint) + 29 (readBytesExact 20-byte
address) + 33 (readAmount = 1 tag + readUint256LE) + 9 bytes with
`assertFullyConsumed` — an exactly-80-byte leaf, confirming the
finding's arithmetic over the stale 64-byte struct comment at line
1956. With the leaf width fixed, the level-0 split point is a function
of the preimage length in both bit0 branches, so the only alternative
parse is the cross-branch one the auditor describes (leaf window
shifted by the sibling length), which needs the honest amount's byte
31 to equal TAG_AMOUNT 0x06 among ~10 other fixed bytes — i.e. an
amount above 6·2^248. Latent, defense-in-depth only: any future
variable-width leaf field removes the rigidity and there is no
structural check to fall back on.


### INFO — REFUTED — `CellTag.decode` handles only tags 0..6, so every honest fault-proof `MultiBundle`/`KernelStep` fails to decode

*Verifier confidence:* high

Refuted against HEAD — the gap the finding describes was already
closed. `CellTag.decode` (Encoding/KernelStep.lean:100-183) has
explicit arms for all fifteen tags: 7..12 as singleton passthroughs at
lines 165-170, `.epochBudget` at 171-180 (with the same `< 2^64` actor
bound as the other key-bearing tags), and `.budgetPolicy` at line 181,
with `.invalidConstructorIndex` only at line 182 for `other >= 15`. It
mirrors `CellTag.encode` (lines 64-95) constructor for constructor.
The finding also claims "the module ships no round-trip or injectivity
theorem": false — `cellTag_roundtrip` at line 224 discharges every tag
including 7..14 (lines 325-364, `nat_roundtrip 7`…`nat_roundtrip 14`).
`git log -- LegalKernel/Encoding/KernelStep.lean` shows commit ee72b6b
"Close the CellTag codec gap...", so the finding was written against a
pre-ee72b6b tree. The failure scenario cannot occur: encoding a
`stepMultiBundle` `KernelStep` and decoding it now round-trips.
Residual nit only: the module header at line 60 still describes the
tag space as "the frozen tag (0..16)" when there are fifteen
constructors (0..14).


### INFO — REFUTED — `declareLocalPolicy` accepts policies the CBE decoder rejects, so one user action permanently breaks snapshot restore

*Verifier confidence:* high

The write-side observation is literally true —
`legalkernel_declareLocalPolicy`'s `lex_pre` is `fun (_ :
LegalKernel.State) => True` (LegalKernel/Laws/LocalPolicy.lean:64) and
`applyActionToLocalPolicies` stores the payload verbatim
(Authority/SignedAction.lean:554-557, wired at :633). But the scenario
needs an over-cap policy to REACH that call, and it cannot. Every
production ingress for a `SignedAction` is `Encodable.decode (T :=
SignedAction)` — Main.lean:107 (`decodeSignedActionStream`, feeding
`readSignedActionsFromFile`) and Runtime/LogFile.lean:150 (log
replay). That routes constructor index 15 through `Encodable.decode (T
:= LocalPolicy)` (Encoding/Action.lean:499-503), i.e.
`LocalPolicy.decode`, which rejects `clauses.length >
MAX_CLAUSES_PER_POLICY` (Encoding/LocalPolicy.lean:396-404), and whose
clause decoder rejects the three per-list caps
(Encoding/LocalPolicy.lean:130-182). A signed `declareLocalPolicy`
with 65 clauses or a 65-entry `denyTags` is refused at decode, before
admission; the same gate means such bytes could never sit in a log
either. The design is explicit at Authority/LocalPolicy.lean:60-64
('enforced at the LP.2 `fieldsBounded` level ... they are *not* new
admissibility conjuncts'). No Rust path builds a declareLocalPolicy
action (runtime/knomosis-l1-ingest/src/action.rs mentions index 15
only in a doc table). The sole non-decode writer of `localPolicies` in
production is the genesis hook `gasPoolGenesisState`
(Bridge/GasPoolPolicy.lean:1063-1065), whose 5-clause policy is proved
bounded by `gasPoolPolicy_fieldsBounded` (:733). Unreachable as …


### INFO — REFUTED — The CORS preflight short-circuit is evaluated before both the auth gate and the rate limiter, for every path and every Origin

*Verifier confidence:* high

The code fact is accurate (handler.rs:105-109 short-circuits
OPTIONS+Origin before the gates computed at handler.rs:121-122), but
the claimed consequence is refuted. The gateway's rate limiter is
*per-credential only*: auth.rs:249 (`let token =
bearer_token(header)?;`) returns None — i.e. no throttle — for any
request lacking a bearer token, and auth.rs:214-231 `gate` 401s
anonymous requests before `rate_limit_check` is ever reached (they are
chained by `.or_else`, handler.rs:121-122). So anonymous traffic was
never throttled on any path; the preflight bypasses nothing. The
anonymous 401 path is in fact *more* expensive per request than the
204 preflight, because `finalize` (handler.rs:163-172) runs a
serde_json parse + reserialize on every application/problem+json body
while `cors::preflight` (cors.rs:165+) just builds a headers-only 204.
Two further guards: conn.rs:800-802/850-855 reject any OPTIONS
carrying a body at the framing layer (400), so no buffering primitive
exists; and `preflight` ignores the request path entirely, so it is
not a path-enumeration oracle. Answering a preflight before auth is
also mandated by the Fetch standard, and the short-circuit is gated on
`--cors-origin` being configured (state.cors.is_some()). True
observation, no defect.

