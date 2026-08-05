# Audit — full-codebase sweep (Lean / Rust / Solidity)

This register records a full-codebase audit pass run across the three
stacks.  It is a **finding register, not a completion record**: most
entries below are open, and each states where it was found and what
would close it.

## How to read the verification status

The pass ran in two stages.  Independent auditors read one area each
and reported defects; a second, adversarial stage re-read the source
for the highest-severity findings and tried to REFUTE them.  Only the
subset that reached the second stage carries an independent judgment —
the stage was capped per area, so an entry's absence from the verified
list means "not re-checked", **not** "refuted".

  * **65 raw findings** across the two sweeps (28 Lean, 37 Rust /
    Solidity), of which 39 are critical or major and appear below.
  * **17 were adversarially re-verified and upheld.**  Two of those
    verifications built a temporary executable reproduction.
  * **0 were refuted at the verification stage.**  That is a fact
    about which findings were selected for re-checking, not a claim
    that every unverified entry is real.

Entries not re-checked should be treated as **plausible and
unconfirmed**.  Confirm before acting.

## Closed by the pass that produced this register

Five findings were fixed in the same pass rather than filed:

  * `CellTag.decode` covered 7 of 15 constructors while `encode`
    emitted all 15 — every honest bundle carries an `.epochBudget`
    (13) and a `.budgetPolicy` (14) cell.  Decoder completed,
    `cellTag_roundtrip` proved, `encoding-kernelstep` suite added.
  * "No custom axioms (ABSOLUTE)" had no mechanical gate.
    `Test/AxiomFootprint.lean` adds a build-time one.
  * The epoch-budget growth bound was asserted, unproved, and false as
    stated.  `storedBalance_topUp_le` / `_consume_le` now carry it.
  * Solidity project-source warnings (one solc, eleven forge-lint) —
    cleared, and `ci-solidity.yml` gained the strict-warnings gate the
    Lean side already had.
  * Seven docstrings still describing the retired `2^128` amount head.

Two register entries below therefore overlap work already done:
`CellTag.decode` (closed) and the `eb_val` bound (the growth lemmas
landed; the cross-stack truncate-vs-revert asymmetry is still open).

## Standing caveat on the two amount-head findings

`LocalPolicyClause.capAmount` and the epoch-budget cell are both
reported as C-3 recurrences.  Note for whoever triages them that
`capAmount`'s bound IS enforced at the decode boundary
(`LocalPolicyClause.fieldsBounded` requires `max < 2^64`, and the CBE
decoder rejects violations), so a wire-originated policy cannot carry
an over-bound cap.  The reachability question is whether any
non-decoder path constructs one.  The epoch-budget cell has no such
decode gate on the value, and there the stacks genuinely disagree at
the ceiling: Lean truncates, Solidity reverts (`CBEValueTooWide`).

---

## Findings (critical first)


### CRITICAL — Cross-resource budget arbitrage: budget is minted at the buy leg's refund rate and redeemed at the sell leg's rate, draining the gas pool

*Where:* `LegalKernel/Authority/SignedAction.lean:966` — Lean sweep

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


### CRITICAL — No gas-price floor on budget minting: with refunds disabled (the default) 1 wei mints 10^6 budget units, defeating the per-actor admission gate

*Where:* `LegalKernel/Authority/SignedAction.lean:747` — Lean sweep

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


### CRITICAL — Bridge-signed `ammSwap` is actor-parametric with no admission conjunct pinning the reserve actor — it can debit an arbitrary actor's balance

*Where:* `LegalKernel/Bridge/Admissible.lean:271` — Lean sweep

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

**Suggested remediation.**

Add a `BridgeAdmissibleWith` conjunct mirroring conjunct 9: `(∀ fr tr
ai ao ra, st.action = .ammSwap fr tr ai ao ra → ra = ammReserveActor ∧
(fr = 0 ∨ fr = 1) ∧ (tr = 0 ∨ tr = 1) ∧ es.bridge.ammDisabled =
false)`, with a projection theorem and a negative test that a non-
canonical `ra` is inadmissible. Restate
`ammReserveActor_ne_gasPoolActor`'s docstring claim as a real theorem
over admitted steps (e.g.
`ammSwap_admissible_does_not_touch_gasPool`).


### CRITICAL — Withdrawal SMT is keyed by `nextWdId` but L1 redemption requires the proof index to equal the leaf's `l2LogIndex` — no production withdrawal can be redeemed

*Where:* `LegalKernel/Bridge/Admissible.lean:178` — Lean sweep

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


### CRITICAL — `LocalPolicyClause.capAmount`'s `max : Amount` is encoded on the 8-byte uint head, silently truncating wei-denominated caps mod 2^64

*Where:* `LegalKernel/Encoding/LocalPolicy.lean:111` — Lean sweep

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


### CRITICAL — Lean game model's terminal step adjudicates an unauthenticated, caller-supplied action — the L1 log-chain binding has no Lean counterpart

*Where:* `LegalKernel/FaultProof/Game.lean:336` — Lean sweep

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


### CRITICAL — Lean game model's terminal step never binds the executed action to the disputed log entry (Solidity does); the headline settlement theorems are proved over this weaker model

*Where:* `LegalKernel/FaultProof/Game.lean:314` — Lean sweep

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


### CRITICAL — An honest responder loses the game outright on any step over `distributeOthers` / `proportionalDilute`, and nothing enforces the deployment-level exclusion the design relies on

*Where:* `LegalKernel/FaultProof/VerifierWrites.lean:1733` — Lean sweep

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

*Where:* `runtime/knomosis-faultproof-observer/src/observer.rs:1420` — Rust / Solidity sweep

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

**Suggested remediation.**

Make the dedup key discriminate the move kind, e.g. key on `(game_id,
move_discriminant, pivot_idx)` or store the pivot as an enum
`Pivot::Midpoint(u64) | Pivot::Response(u64) | Pivot::Terminate(u64)`.
Persist the same discriminant in `ResponseRecord.pivot_idx` so the
startup repopulation (observer.rs:257) rebuilds the same key space.
Add a regression test driving the exact trace above (submit mid N,
opponent disagrees, terminate at high == N) and asserting a terminate
calldata is broadcast.


### CRITICAL — Observer only ever moves in reaction to an opponent event, so the honest sequencer never submits its first midpoint and any deferred move is never retried

*Where:* `runtime/knomosis-faultproof-observer/src/observer.rs:693` — Rust / Solidity sweep

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

**Suggested remediation.**

Add a per-iteration sweep after hydration and after event dispatch:
for every `GameRecord` with `state.status.is_in_progress() &&
state_known && state.turn == me`, call `maybe_play_move`. That single
loop covers the sequencer's opening move, post-hydration catch-up, and
retry of every deferred move, and is naturally idempotent once the
pivot key is fixed (see the terminate-dedup finding).


### CRITICAL — Per-connection writer-thread spawn uses `.expect()`, so an OS thread refusal aborts the whole host process (release `panic = "abort"`)

*Where:* `runtime/knomosis-host/src/listener.rs:594` — Rust / Solidity sweep

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


### CRITICAL — AMM has no minimum-liquidity/reserve guard: a 1-wei BOLD seed lets an attacker drain ~half the ETH reserve per swap

*Where:* `solidity/src/contracts/KnomosisBridge.sol:1811` — Rust / Solidity sweep

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

*Where:* `solidity/src/contracts/KnomosisBridge.sol:2021` — Rust / Solidity sweep

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

**Suggested remediation.**

Add the withdrawal id to the redeemed leaf's on-wire identity and bind
the proof index to it, not to `l2LogIndex`. Either (a) carry
`withdrawalId` as an explicit `withdrawWithProof` argument and check
`proofIndex == withdrawalId` (with the SMT walk at `withdrawalId`),
keeping `l2LogIndex` as a non-positional field, or (b) drop line 2021
entirely — the SMT walk already binds position to root, so the check
adds no soundness and only breaks the honest path. Add a regression
fixture where `withdrawalId != l2LogIndex` on both stacks.


### CRITICAL — StepWrites.applyGrantAt skips the epoch normalisation Lean performs on a ZERO grant, forking the state root

*Where:* `solidity/src/lib/StepWrites.sol:302` — Rust / Solidity sweep

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

*Where:* `LegalKernel/Authority/SignedAction.lean:682` — Lean sweep

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


### MAJOR — GP.7.3 pool-drain bound excludes the refund outflow by hypothesis, so the 'per-resource pool drain bound' does not bound total pool outflow

*Where:* `LegalKernel/Bridge/PoolDrainBound.lean:723` — Lean sweep

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


### MAJOR — `bridge_chain_accounting_equation` is proved over a trace relation that excludes the supply-moving actions a production deployment must admit, so the "unconditional" escrow identity does not hold on any real chain

*Where:* `LegalKernel/Bridge/Reachable.lean:57` — Lean sweep

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


### MAJOR — `CellTag.decode` handles only tags 0..6, so every honest fault-proof `MultiBundle`/`KernelStep` fails to decode

*Where:* `LegalKernel/Encoding/KernelStep.lean:161` — Lean sweep

`CellTag.encode` emits fifteen tags (0..14), including the six
GP.11.8/GP.11.10 bridge scalars (7..12), `epochBudget` (13) and
`budgetPolicy` (14). `CellTag.decode` implements arms for 0..6 only
and routes everything else to `.error (.invalidConstructorIndex
other)`. The `Encodable FaultProof.CellTag` instance (line 164-166)
therefore does not round-trip on 8 of its 15 constructors, and every
composite codec built on it — `CellProof.decode` (line 180),
`CellOpening.decode` (line 254), `OpenedCell.decode` (line 307),
`MultiBundle.decode` (line 324), `KernelStep.decode` (line 350) —
inherits the failure. The module ships no round-trip or injectivity
theorem for any of these; the only theorems are
`cellTag_encode_deterministic` / `kernelStep_encode_deterministic`
(lines 386-397), which are `by rw [h]` and prove nothing about the
decoder. So no build-time check catches the gap, and the module header
still describes the tag space as "the frozen tag (0..16)".

**Failure scenario.**

`multiFrontierOf` is `frontierOf (.budgetPolicy :: verifierWriteCells
a signer nextWdIdPre)` (`LegalKernel/FaultProof/Terminate.lean:402`),
so `CellTag.budgetPolicy` (index 14) is present in EVERY honest
sequencer bundle, and `.epochBudget` (index 13) is written by every
one of the twenty-five action variants. Take any real `KernelStep`
produced by `stepMultiBundle`, encode it with `Encodable.encode (T :=
FaultProof.KernelStep)`, and hand the bytes to `Encodable.decode (T :=
FaultProof.KernelStep)`: `MultiBundle.decode` → `OpenedCell.decode` →
`CellTag.decode` reaches `| .ok (other, _) => .error
(.invalidConstructorIndex other)` with `other = 14` (or 13) and the
whole step is rejected. The CBE representation of a terminal step is
thus unusable for any Lean-side consumer — observer persistence, audit
replay, or a snapshot of an in-flight game — and a future consumer
wired to it would …

**Suggested remediation.**

Add decode arms 7..14 mirroring the encoder (tags 7-12 and 14 are
field-free; tag 13 reads one `Nat` actor id with the same `< 2^64`
guard the other actor-keyed arms use). Then ship a real
`cellTag_roundtrip : ∀ t rest, Encodable.decode (T := CellTag)
(Encodable.encode t ++ rest) = .ok (t, rest)` proved by `cases t` — an
exhaustive case split makes any future `CellTag` constructor addition
a build failure, which the current determinism-only theorems cannot
do. Correct the module header's "frozen tag (0..16)" to the actual
0..14.


### MAJOR — Epoch-budget cell truncates mod 2^64 into the canonical-absent value; the `eb_val` bound is neither enforced nor correctly justified (C-3 reproduced on the budget cell)

*Where:* `LegalKernel/FaultProof/BoundsReachable.lean:315` — Lean sweep

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

*Where:* `LegalKernel/FaultProof/CellValue.lean:170` — Lean sweep

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

*Where:* `LegalKernel/FaultProof/CellWrites.lean:155` — Lean sweep

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


### MAJOR — Terminal step takes `l2LogIndex` from the caller instead of from the game range, contradicting its own docstring and the contract

*Where:* `LegalKernel/FaultProof/Step.lean:120` — Lean sweep

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

**Suggested remediation.**

In `applyTransition`'s `.terminateOnSingleStep` arm, call
`verifierPostRootMulti step.preStateCommit step.signedAction.action
step.signedAction.signer gs.range.high.idx step.bundle` directly (or
reject `step.l2LogIndex ≠ gs.range.high.idx` the way
`step.preStateCommit ≠ gs.range.low.commit` is already rejected at
Game.lean:323). Prefer the former: dropping the field from
`KernelStep` makes the index underivable from the caller by
construction, exactly as removing `claimedPostCommit` did.


### MAJOR — `step.l2LogIndex` is caller-supplied and unconstrained in the Lean terminal step, though its own docstring says the game must supply it

*Where:* `LegalKernel/FaultProof/Step.lean:64` — Lean sweep

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

**Suggested remediation.**

In `applyTransition .terminateOnSingleStep`, either drop `l2LogIndex`
from `KernelStep` and pass `gs.range.high.idx` to `kernelStepApply`
directly (matching the contract), or add an explicit `step.l2LogIndex
≠ gs.range.high.idx → responder loses` guard alongside the existing
`preStateCommit` guard.


### MAJOR — No theorem connects `verifierPostRootMulti` to the true post-state root in either direction; the settlement theorems' load-bearing hypothesis is never discharged

*Where:* `LegalKernel/FaultProof/Terminate.lean:426` — Lean sweep

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

*Where:* `LegalKernel/Laws/AmmSwap.lean:77` — Lean sweep

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

*Where:* `LegalKernel/Laws/BulkBound.lean:121` — Lean sweep

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


### MAJOR — `declareLocalPolicy` accepts policies the CBE decoder rejects, so one user action permanently breaks snapshot restore

*Where:* `LegalKernel/Laws/LocalPolicy.lean:60` — Lean sweep

The §3.0 DoS caps (`MAX_CLAUSES_PER_POLICY = 64`, `MAX_TAGS_PER_DENY =
64`, `MAX_RECIPIENTS_PER_REQUIRE = 64`, `MAX_DELEGATES_PER_ALLOW =
64`, `Authority/LocalPolicy.lean:86-99`) are enforced only on the
DECODE side (`Encoding/LocalPolicy.lean:402` for the clause count, and
lines 131/155/180 for the per-list caps). Nothing on the write side
enforces them: `legalkernel_declareLocalPolicy`'s precondition is `fun
(_ : LegalKernel.State) => True` and `applyActionToLocalPolicies`
(`Authority/SignedAction.lean:554`) stores `policy` verbatim via
`lp.declare signer policy`. `ExtendedState.encode` is total, so an
over-cap policy serialises fine — but `ExtendedState.decode` routes
through `LocalPolicies.decodeMap`
(`Encoding/LocalPolicy.lean:710-730`), which calls
`LocalPolicy.decode` on each framed value and fails the whole map. The
encoder and decoder therefore disagree about which states exist, and
the asymmetry is one-directional: states are writable that are not
readable.

**Failure scenario.**

Any actor authorised to declare a local policy signs
`declareLocalPolicy { clauses := <65 clauses> }` (or a single
`denyTags` clause with 65 entries). Admission passes — the law's `pre`
is `True`, `AmountBounded` does not apply, and the LP.7 meta-action
exemption means no existing policy can block it. The clause list lands
in `es.localPolicies`. The node then writes a snapshot:
`Runtime/Snapshot.lean:140` calls `Encodable.encodeBytes (T :=
ExtendedState) state`, which succeeds. Every replica that later calls
`restoreSnapshot` (`Snapshot.lean:169`) gets `Encodable.decodeAllBytes
(T := ExtendedState) → LocalPolicies.decodeMap → LocalPolicy.decode →
.error (.invalidLength "LocalPolicy: 65 clauses exceeds
MAX_CLAUSES_PER_POLICY=64")`, i.e. `SnapshotError.decode`, and cannot
bootstrap. The poisoned entry is permanent — the offending actor need
never sign again, and only that actor can revoke …

**Suggested remediation.**

Give `legalkernel_declareLocalPolicy` a real precondition: `lex_pre :=
fun _ => Encoding.LocalPolicy.fieldsBounded policy` (the instance
`LocalPolicy.decFieldsBounded` at `Encoding/LocalPolicy.lean:81`
already makes `decPre := fun _ => inferInstance` work). Because
`step_impl` is `if pre then apply_impl else id`, an over-cap
declaration then becomes a no-op rather than a stored-but-unreadable
state, which is the fail-closed direction and matches the
`Laws/AmountBound.lean` precedent. This simultaneously discharges
`ExtendedState.CanonicalBounds.lp_pol` (`FaultProof/Commit.lean:740`)
inductively over reachable states instead of leaving it as a standing
assumption, and it closes the same hole …


### MAJOR — A move whose L1 broadcast fails is marked Failed and its pivot stays consumed forever, so one transient RPC error permanently forfeits the move

*Where:* `runtime/knomosis-faultproof-observer/src/observer.rs:883` — Rust / Solidity sweep

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

**Suggested remediation.**

Either (a) leave the record in `Intent` on a broadcast failure (or add
a `Retryable` status) so `recover_intent_records` picks it up next
iteration, or (b) exclude `Failed` records from the startup
`submitted_pivots` rebuild and remove the pivot from the in-memory set
when the broadcast fails. Bound the retries with a `Failed` counter so
a genuinely unbroadcastable tx eventually alerts instead of looping.


### MAJOR — Observer is deadline-blind: it never claims an opponent's timeout, never checks tx inclusion, and never escalates fees

*Where:* `runtime/knomosis-faultproof-observer/src/state_reader.rs:490` — Rust / Solidity sweep

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


### MAJOR — /readyz is exempt from both the auth gate and the rate limiter yet performs upstream I/O, giving anonymous callers a thread- and lock-exhaustion primitive

*Where:* `runtime/knomosis-gateway/src/auth.rs:203` — Rust / Solidity sweep

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


### MAJOR — The mux swallows the upstream TRUNCATED gap, so the ring holds a hole that `position` classifies as InWindow

*Where:* `runtime/knomosis-gateway/src/events/fanout/mux.rs:169` — Rust / Solidity sweep

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

*Where:* `runtime/knomosis-gateway/src/events/subscribe.rs:224` — Rust / Solidity sweep

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

*Where:* `runtime/knomosis-gateway/src/rpc.rs:75` — Rust / Solidity sweep

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

*Where:* `runtime/knomosis-host/src/kernel.rs:1356` — Rust / Solidity sweep

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


### MAJOR — The gas-pool drain event (tag 18) is never emitted, so `pool_balances_*` are monotone-increasing gross inflows and the gateway serves them as `net: true`

*Where:* `runtime/knomosis-indexer/src/budget_view.rs:286` — Rust / Solidity sweep

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

*Where:* `runtime/knomosis-indexer/src/decoder.rs:257` — Rust / Solidity sweep

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

*Where:* `runtime/knomosis-l1-ingest/src/source.rs:834` — Rust / Solidity sweep

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

**Suggested remediation.**

In `logs_in_block_by_hash`, reject any returned log whose `address !=
*contract` with `SourceError::Malformed`, mirroring the existing
blockHash check. Additionally pass the expected contract into both
`decode_event` functions (or split the observer's decode into per-
contract dispatch) so `FaultProofGameOpened`/`Settled` are accepted
only from the game contract and `StateRootSubmitted` only from the
submission contract, and `RegisteredECDSA`/`Revoked` only from the
identity registry.


### MAJOR — The attestation-staleness circuit breaker gates `submitStateRoot` itself, so one missed window permanently bricks the bridge

*Where:* `solidity/src/contracts/KnomosisBridge.sol:1880` — Rust / Solidity sweep

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

**Suggested remediation.**

Exempt `submitStateRoot` from the `AttestationStale` arm (it is the
recovery action, not a value-moving one) — e.g. split `circuitOpen`
into `depositOpen` (all four arms) and `submissionOpen` (dispute-
cooldown, TVL and migration arms only). Keeping deposits halted while
a fresh root is accepted preserves the intended "deposits halted,
exits continue" posture without making the halt terminal. Add a
regression test that rolls past `maxAttestationStaleBlocks` and
asserts a subsequent `submitStateRoot` succeeds.


### MAJOR — V1 dispute verifier's quorum tally reverts on a malleable signature instead of skipping it, letting one adjudicator block finalisation

*Where:* `solidity/src/contracts/KnomosisDisputeVerifier.sol:849` — Rust / Solidity sweep

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

**Suggested remediation.**

Replace line 849 with the V2 pattern: `try
this.tryRecover(verdictHash, sigs[i]) returns (address rec) { if (rec
== s) { seen[seenLen++] = s; } } catch { }`. (`tryRecover` already
exists at line 574 and is `external pure`, so the self-call works
unchanged.) Add a test that includes one high-s signature alongside a
satisfied quorum and asserts finalisation still succeeds.

