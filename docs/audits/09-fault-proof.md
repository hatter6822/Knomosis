# FaultProof Modules Audit (Workstream H)

Line-by-line audit of the 25 files under `/home/user/Knomosis/LegalKernel/FaultProof/`.
Scope: the fault-proof migration / bisection game (Workstream H). Each
file is examined for imports, primitives, theorems claimed to be
"headline", trust assumptions, and documentation/code drift.

The chain of load-bearing dependencies is:

```
Commit.lean  -->  Coherence.lean  -->  Game.lean  -->  Convergence.lean
                       |                    |                |
                       |                    +------> Honesty.lean
                       |                                     |
                       +-------------------> Settlement.lean -+
                                                             |
                                                             v
                                                       Witness.lean
```

Concretely: `commitExtendedState` (Commit.lean) underpins
`recomputeCommitment` (Coherence.lean); the coherence theorem feeds
into the per-step settlement reasoning in Settlement.lean; Honesty
+ Convergence supply the persistence and width-decrease invariants;
Witness.lean packages the L1 attestation that closes the
trust-model upgrade.

---

## 1. `Commit.lean` (421 lines)

**Imports** (`Commit.lean:39-44`): `Authority.Nonce`,
`Bridge.Eip712`, `Bridge.HashAdaptor`, `Bridge.State`,
`Encoding.State`, `Runtime.Hash`. Reasonable: this is the
state-commitment primitive that needs the encoding stack +
hash adaptor + bridge sub-state.

**State-commitment primitives** (the load-bearing definitions):

- `StateCommit : Type := ByteArray` at `Commit.lean:59` (32-byte alias).
- `commitState` (`Commit.lean:67`) — hash of `State.encode s`.
- `commitNonceState` (`Commit.lean:71`).
- `commitKeyRegistry` (`Commit.lean:77`) — via `KeyRegistry.encodeMap`.
- `commitLocalPolicies` (`Commit.lean:82`) — via `Encodable.encode`.
- `commitBridgeState` (`Commit.lean:87`).
- `commitExtendedState` (`Commit.lean:96`) — top-level: hash of the
  concatenation of all five sub-state commits, in the order
  `base ++ nonces ++ registry ++ localPolicies ++ bridge`.

All six commit functions use `hashBytes` (a deployment-supplied
opaque from Runtime.Hash), so collision-freedom is a hypothesis,
not an axiom.

**Headline theorem `commitExtendedState_subcommits_bytes_eq_under_collision_free`**
(`Commit.lean:392-411`): under `Bridge.CollisionFree hashBytes` and
equal top-level commits, the **encoded sub-state bytes** of the
two `ExtendedState`s agree pairwise. The five-component
decomposition proceeds via:

1. The 5-segment concat-injectivity `byteArray_concat_five_split`
   (`Commit.lean:292-336`), a pure structural lemma using
   `byteArrayAppendInj` (`Commit.lean:266-286`), unfolded layer by
   layer from `((a₁ ++ a₂ ++ a₃ ++ a₄) ++ a₅)`.
2. Each sub-state commit's 32-byte output size
   (`commitState_size` etc., `Commit.lean:131-154`) discharges the
   per-segment size hypothesis the split needs.
3. Each per-sub-state `*_bytes_injective_under_collision_free`
   lemma (`Commit.lean:189-236`) lifts hash-equality to encoded
   bytes-equality via `h_cf _ _ h`.

**Sharp point — bytes vs extensional equality.** The theorem is
shipped only at the *encoded bytes* level. The docstring at
`Commit.lean:367-391` is explicit and honest about this: lifting
bytes-equality to extensional equality on the underlying TreeMap
sub-states requires "encoder canonicality for State / NonceState /
KeyRegistry / LocalPolicies / BridgeState, which is shipped at the
structural level... but not as a stand-alone `*_encode_injective`
lemma for the map-backed sub-states; that's a Workstream-H
follow-up." This matches CLAUDE.md's footnote 1.

**Documentation drift — none significant.** The doc declares
"Headline theorems" including `commitExtendedState_size = 32`,
`commitExtendedState_deterministic`, and
`commitExtendedState_injective_under_collision_free` (#220). All
present (`Commit.lean:121-129`, `Commit.lean:127`,
`Commit.lean:342-365`).

**Collision-free hash dependency.** Uses
`Bridge.CollisionFree hashBytes` from `Bridge.Eip712`; no new
opaques introduced in this file.

---

## 2. `Coherence.lean` (323 lines)

**Imports** (`Coherence.lean:49-55`): `Disputes.Evidence`,
`FaultProof.Cell`, `FaultProof.Commit`, `FaultProof.Step`,
`FaultProof.StepVariants`, `FaultProof.Verify`, `Runtime.LogFile`.
Reasonable.

**Witness-state-bearing design** is committed to explicitly
(`Coherence.lean:14-44`). The semantic core
`applyCellWrites_to_state` (`Coherence.lean:78-85`) **is just
`kernelOnlyApply` wrapped via a synthetic `LogEntry` with empty
`prevHash` and `postStateHash`**. The implications:

- `recomputeCommitment es st = commitExtendedState (kernelOnlyApply es entry)`
  is **rfl-class** by construction.
- The L1 SMT-per-cell compute path is delegated to the cross-stack
  corpus (WU H.10.1), not formalised in Lean.

**Headline theorem `recomputeCommitment_coherent_with_kernelOnlyApply`**
(`Coherence.lean:150-171`): given `entry.signedAction = st`,
`recomputeCommitment es st = commitExtendedState (kernelOnlyApply es entry)`.
The proof:

1. Unfolds `recomputeCommitment` and `applyCellWrites_to_state`.
2. Decomposes `entry` to its three fields.
3. Unfolds `kernelOnlyApply` and rewrites by `h_entry`.

This depends on `kernelOnlyApply`'s independence from
`prevHash` / `postStateHash` (which is true by definition — it
only matches on `entry.signedAction.action`). The proof closes via
`rw`, not by appealing to a lemma about that independence.

**Headline theorem `recomputeCommitment_chain_coherent_with_kernelOnlyReplay`**
(`Coherence.lean:256-260`): direct corollary of the multi-step
state-level theorem `foldStepApplyOverLog_eq_kernelOnlyReplay`
(`Coherence.lean:230-250`), which is a structural induction with a
per-step bridge `applyCellWrites_to_state_eq_kernelOnlyApply`
(`Coherence.lean:210-221`).

**`kernelStepApply_canonical`** (`Coherence.lean:311-320`): closes
the loop from `buildKernelStep` to `kernelStepApply`. Uses
`buildKernelStep_verifies` (`Coherence.lean:303-307`) which in
turn relies on `verifyCellProofs_complete_for_canonical_bundle`
from Verify.lean.

**Sharp.** The design comment at `Coherence.lean:35-44` is
candid: "the 'semantic core' is not *independent* of the kernel —
it's literally the same function." The trust-model upgrade
therefore depends on cross-stack equivalence with the Solidity
step VM. This is an honest design statement, but a reviewer needs
to be aware that "coherence" here is structural rfl, not a deep
equivalence theorem.

---

## 3. `Game.lean` (496 lines)

**Imports** (`Game.lean:33-34`): `Disputes.Types`, `FaultProof.Step`.
Lightweight; appropriate.

**Bisection depth bound** (`Game.lean:48`):
`MAX_BISECTION_DEPTH := 64`. Covers `2^64` log lengths.

**`DisputedRange`** (`Game.lean:69-76`) holds `low : Claim` and
`high : Claim`. The plan-spec v1 vs v2 design correction
(`Game.lean:22-31`) is documented: v1 had simultaneous midpoint
submission, v2 has the standard "one party submits, the other
accepts/rejects."

**`GameState`** (`Game.lean:107-137`) carries sequencer/challenger,
range, `pendingMidpoint : Option Claim`, depth, turn,
sequencer/challenger bonds, `status : GameStatus`, deploymentId.

**`GameTransition`** (`Game.lean:148-174`): five constructors —
`submitMidpoint`, `respondAgree`, `respondDisagree`,
`terminateOnSingleStep` (takes `KernelStep + claimedPostCommit`),
`timeoutLoss` (loser derived from `gs.turn`, not parameterised).

**State-machine `applyTransition`** (`Game.lean:226-326`):
explicit, total `Except GameError GameState`. Notable:

- `submitMidpoint`: checks `gs.status = inProgress`, no pending
  mp, depth `<` cap, mp idx strictly inside the range. Flips turn.
- `respondAgree`: narrows to `[mid, high]`. Includes a depth-cap
  re-check (`Game.lean:252-253`) — agree increments `depth`, so
  the post-state cap is enforced pre-mutation.
- `respondDisagree`: narrows to `[low, mid]`. Same depth discipline.
- `terminateOnSingleStep`: gates on `range.isSingleStep`, then
  consults `kernelStepApply step`. On `none` → responding party
  loses. On `some computed`: if `computed = claimed` then the
  responding party wins; else loses. Loser/winner derived from
  `gs.turn` via match.
- `timeoutLoss`: loser is the current turn-holder. Documented at
  `Game.lean:163-172`.

**`gameWellFormed`** (`Game.lean:368-373`): four conjuncts —
range non-degenerate, depth ≤ cap, midpoint inside range when
pending, bond pool positive while in progress. The implication
form `inProgress → bond > 0` is encoded as
`¬ inProgress ∨ bond > 0` for decidability without
`Classical.propDecidable`.

**Headline theorem `range_narrows_on_response_agree`**
(`Game.lean:446-460`): post-`respondAgree` width strictly less
than pre-width, under well-formedness on the midpoint. Proof:
shape lemma + the arithmetic helper `nat_sub_lt_sub_left`
(`Game.lean:432-435`, discharged by `omega`).

**Headline theorem `range_narrows_on_response_disagree`**
(`Game.lean:463-477`): symmetric, via `nat_sub_lt_sub_right`.

**Sharp — the depth-cap branch in shape lemmas.** The shape lemmas
`applyTransition_respondAgree_shape` (`Game.lean:393-409`) and
`applyTransition_respondDisagree_shape` (`Game.lean:414-427`)
case-split on `MAX_BISECTION_DEPTH ≤ gs.depth`; the `true` branch
is closed by `simp [h_cap] at h_apply` deriving `False` from
`h_apply : .error = .ok gs'`. The `false` branch closes via
`⟨rfl, rfl⟩`. Looks correct.

---

## 4. `Convergence.lean` (158 lines)

**Imports** (`Convergence.lean:25`): `FaultProof.Game` only.

**`ResponseTrace`** (`Convergence.lean:39-54`): inductive predicate
on `(GameState, Nat, GameState)` capturing a chain of `k` legal
in-progress responses. Each `step` constructor bundles
`h_pending`, `h_status`, `h_wf_mp`, `h_t : t = .respondAgree ∨ t
= .respondDisagree`, and `h_apply`.

**`range_size_after_k_rounds`** (`Convergence.lean:65-97`): the
multi-round narrowing accountant. By induction on the trace:
trace of length 0 gives equality; step gives strict descent
combined with the IH via `Nat.le_trans`. Closes correctly.

**`range_narrows_to_zero_after_enough_rounds`**
(`Convergence.lean:108-126`): given `k ≥ initial_width`, the
final width is exactly 0.

**Headline theorem `bisection_converges_after_enough_rounds`**
(`Convergence.lean:132-139`): final width ≤ 1. Direct corollary of
the zero-width form via `Nat.zero_le _`.

**Convergence bound calculation.** Width strictly decreases by ≥ 1
per round; `k ≥ initial_width` forces width = 0. The
`MAX_BISECTION_DEPTH = 64` cap covers initial widths up to `2^64`.
Calculation looks right.

**Sharp.** The strict-descent form (width_k + k ≤ width_0) is the
key. The proof uses
`have h := Nat.add_le_add_right ih 1` then re-associates via
`Nat.add_assoc`. Correct.

---

## 5. `Honesty.lean` (267 lines)

**Imports** (`Honesty.lean:35-36`): `FaultProof.Convergence`,
`FaultProof.Strategy`. Reasonable.

**`inDisagreementWithTruth`** (`Honesty.lean:57-61`): predicate
`low.commit = truth low.idx ∧ high.commit ≠ truth high.idx`.
The invariant the honest challenger maintains.

**Disagreement persistence under honest play.** The two atomic
lemmas:

- `disagreement_persists_on_agree` (`Honesty.lean:91-109`): given
  the midpoint is truthful (`mp.commit = truth mp.idx`),
  `respondAgree` preserves `inDisagreementWithTruth`.
- `disagreement_persists_on_disagree` (`Honesty.lean:115-133`):
  given the midpoint is dishonest (`mp.commit ≠ truth mp.idx`),
  `respondDisagree` preserves the invariant.

**Headline theorem `disagreement_persists_along_trace`**
(`Honesty.lean:238-264`): trace-level. Threaded by induction over
`ResponseTrace`, applying `honest_challenger_wins_per_round`
(`Honesty.lean:211-232`) at each cons.

**Sharp — the honest-choice hypothesis.** The
`h_each_honest` hypothesis (`Honesty.lean:246-253`) is the
deployment-level discipline; it's not derived from
`honestStrategy`. The proof composes it through the trace; the
inference that an honest challenger actually satisfies this
hypothesis is a separate operational claim (the bridge through
`Strategy.lean`'s `isHonestByTruth` is in `Trust.lean`).

**`honest_challenger_wins_via_sequencer_timeout`**
(`Honesty.lean:165-173`): if the sequencer's turn elapses, the
challenger wins via `.timeoutLoss`. Straightforward unfold.

---

## 6. `Settlement.lean` (282 lines)

**Imports** (`Settlement.lean:42`): `FaultProof.Honesty`.

**Three branch theorems** at single-step termination:

- `honest_challenger_responds_truthfully_wins`
  (`Settlement.lean:75-91`): challenger responds with the truthful
  step; `kernelStepApply step = some claimedPostCommit`. Conclude
  `gs'.status = .challengerWon`.
- `sequencer_responding_with_disputed_high_loses`
  (`Settlement.lean:120-134`): sequencer responds; the kernel
  computes `computedPostCommit ≠ claimedPostCommit`. Conclude
  `challengerWon`.
- `sequencer_responding_with_invalid_proofs_loses`
  (`Settlement.lean:146-158`): sequencer's bundle is malformed
  (`kernelStepApply step = none`). Conclude `challengerWon`.

All three close via `unfold applyTransition at h_apply; simp [...]
at h_apply; rw [← h_apply]`. The `simp` invocations consume the
hypotheses, leaving the field-update reduction.

**`settlementDisagreement`** (`Settlement.lean:182-185`): the
projection at single-step `gs.range.high.commit ≠ truth gs.range.high.idx`.

**Headline theorem `honest_challenger_wins_against_invalid_state_root`**
(`Settlement.lean:213-242`): composite — given the
`settlementDisagreement` invariant + a kernel-truthful step +
the response branch (challenger = truthful claim OR sequencer =
high.commit), conclude `gs'.status = challengerWon`.

The proof `rcases`s on the response branch:

- Challenger branch: rewrites `claimedPostCommit = computedPostCommit`
  and calls `honest_challenger_responds_truthfully_wins`.
- Sequencer branch: shows `computedPostCommit ≠ claimedPostCommit`
  by transporting along `claimedPostCommit = gs.range.high.commit`
  and `computedPostCommit = truth gs.range.high.idx`, then
  invokes `sequencer_responding_with_disputed_high_loses`.

**`inDisagreementWithTruth_implies_settlementDisagreement`**
(`Settlement.lean:262-266`): projection of the second conjunct.

**Sharp.** The composite theorem requires the *hypothesis*
`h_computed_eq_truth : computedPostCommit = truth gs.range.high.idx`.
This is a *deployment-level* claim about the L1 step VM's
truthfulness, not derived inside Lean. The hypothesis names it
explicitly; consumers need to discharge it operationally (via
WU H.10.1 cross-stack equivalence).

---

## 7. `Witness.lean` (268 lines)

**Imports** (`Witness.lean:38-43`): `Authority.Action`,
`Bridge.Eip712`, `Disputes.Evidence`, `Disputes.Types`,
`FaultProof.Commit`, `Runtime.LogFile`. Reasonable.

**Trust-assumption opaque** (`Witness.lean:70-72`):

```
opaque l1FaultProofVerifier
    (bindingHash : ByteArray) (gameId : Nat)
    (winner : ActorId) (revertFromIdx : LogIndex) : Bool
```

This is the new opaque introduced by Workstream H (mentioned in
CLAUDE.md). It does NOT appear in `#print axioms` per the opaque
discipline. The production binding is a Rust crate
(`runtime/knomosis-faultproof-observer`); at the Lean level the
opaque returns `false` until a deployment-time binding.

**`FaultProofChallengerWon`** (`Witness.lean:98-117`): the
propositional witness structure. Three fields:

- `logIdx : LogIndex` + `log_lookup_proof : log[logIdx]? = some entry`.
- `action_eq : ∃ bh w, entry.signedAction.action = .faultProofResolution bh gameId w revertFromIdx`.
- `l1_attestation : ∃ bh w, ... ∧ l1FaultProofVerifier bh gameId w revertFromIdx = true`.

Note that `action_eq` is partially redundant — the existence
clause inside `l1_attestation` carries the same shape with the
extra attestation conjunct. This is harmless but slightly
asymmetric; reviewers should note that consumers using
`action_eq` alone don't get attestation.

**`L1AttestationSemantics`** (`Witness.lean:232-238`): the
**deployment-level trust assumption** capturing the operational
implication "L1 verifier confirms ⇒ sequencer's submitted root
differs from canonical". The user of
`faultProof_challenger_won_implies_state_root_wrong` must
supply this proposition as a hypothesis.

**Headline theorem `faultProof_challenger_won_implies_state_root_wrong`**
(`Witness.lean:255-265`): given the witness + the
`L1AttestationSemantics` assumption, derive
`sequencerSubmittedRoot ≠ canonicalCommitAt genesis log revertFromIdx`.

Proof composes:

1. `faultProof_challenger_won_carries_l1_attestation` extracts
   `bh, winner, _, h_attest : l1FaultProofVerifier ... = true`.
2. `h_semantics bh gameId winner revertFromIdx h_attest` discharges.

**Witness construction edge cases.**
`FaultProofChallengerWon.of_log_entry` (`Witness.lean:126-140`) is
a one-line aggregator. The caller must externally provide
log-lookup, action-shape, and attestation proofs. No corner cases
in the constructor itself.

**Documentation drift.** CLAUDE.md says the theorem
"decomposes... against an explicit `L1AttestationSemantics`
deployment assumption (the operational implication 'L1 watcher
confirms ⇒ sequencer's claim ≠ canonical commit')." Verified
matches: `Witness.lean:232-238` defines exactly that predicate;
the theorem at `Witness.lean:255-265` consumes it as a typed
hypothesis.

---

## 8. `Cell.lean` (191 lines)

**Imports** (`Cell.lean:61-64`): `Authority.Crypto`,
`Authority.Nonce`, `Bridge.State`, `Encoding.Encodable`.
Reasonable.

**`CellTag`** (`Cell.lean:88-106`): seven constructors — balance,
nonce, registry, localPolicy, bridgeConsumed, bridgePending,
bridgeNextWdId. `DecidableEq`, `Repr`.

**`CellTag.kindIndex`** (`Cell.lean:113-120`): the canonical
discriminator, frozen indices 0–6.

**`CellProof`** (`Cell.lean:152-160`): triple of `cellTag`,
`cellValue : ByteArray`, `witnessState : ExtendedState`. The
witness-state design is committed to here (see docstring
`Cell.lean:44-53` about SMT being a "deployment-time optimisation"
deferred per Genesis Plan §15.8).

**`CellProofBundle`** (`Cell.lean:166-170`): wraps `List CellProof`.

Helpers: `empty`, `push`, `size` (`Cell.lean:175-184`).

---

## 9. `Step.lean` (202 lines)

**Imports** (`Step.lean:29-32`): `Authority.SignedAction`,
`FaultProof.Cell`, `FaultProof.Commit`, `FaultProof.Verify`.

**`KernelStep`** (`Step.lean:51-61`): four-field — pre/post-state
commits, signed action, cell-proof bundle.

**`kernelStepApply`** (`Step.lean:91-95`): returns
`some step.postStateCommit` if every cell proof verifies against
`step.preStateCommit`; else `none`. The actual per-variant
post-state computation is delegated to Solidity (per
`Step.lean:68-79`). This is the *verifier-side* interface.

**`chainKernelStepApply`** (`Step.lean:116-125`): multi-step
composition; threads commits through. `chainKernelStepApply_split`
(`Step.lean:160-193`) proves chain-composition over list concat
via induction.

**Sharp.** The Lean-side `kernelStepApply` doesn't compute the
post-commit from scratch — it trusts `step.postStateCommit` after
verifying the cell proofs. The cross-stack corpus (H.10.1) is what
ties this to a per-variant computation in Solidity.

---

## 10. `StepVariants.lean` (230 lines)

**Imports** (`StepVariants.lean:38-39`): `Authority.Action`,
`FaultProof.Cell`.

**Namespace placement.** Defines `Action.readOnlyCells`,
`Action.writeCells`, `Action.requiredCells` **inside the
`LegalKernel.Authority` namespace** (`StepVariants.lean:42`) so
dot-notation `a.readOnlyCells signer` projects. Smart.

**Per-action declarations.**
- `readOnlyCells` (`StepVariants.lean:60-86`): every action reads
  `[registry signer]`; `deposit` additionally reads
  `bridgeConsumed d`.
- `writeCells` (`StepVariants.lean:109-153`): per-variant writes.
  Notable: bulk actions (`distributeOthers`, `proportionalDilute`)
  only declare `[nonce signer]` at this level — the per-recipient
  balance writes decompose via `SubStep.lean`.
- `requiredCells := readOnlyCells ++ writeCells` (`StepVariants.lean:158`).

**Sharp — withdraw and bridgePending.** `withdraw` declares
`[balance r sender, nonce signer, bridgeNextWdId]`
(`StepVariants.lean:144-145`). The newly-allocated
`bridgePending <nextWdId>` cell is **NOT** in the static
declaration; the docstring (`StepVariants.lean:103-108`) explains
this is a deliberate design choice — the runtime cell-proof
builder adds it at game-play time, but the static declaration
omits it. Reviewers verifying cross-stack equivalence should
double-check the Solidity side mirrors this convention.

---

## 11. `SubStep.lean` (200 lines)

**Imports** (`SubStep.lean:27-29`): `Authority.Action`,
`Encoding.Encodable`, `FaultProof.Cell`.

**DoS bound** (`SubStep.lean:41`):
`MAX_RECIPIENTS_PER_BULK_ACTION := 256`.

**`SubStep`** (`SubStep.lean:52-65`): one per-recipient credit
record with `parentAction`, `subStepIdx`, `affectedActor`,
`preBalance`, `postBalance`, `cellProof`.

**`distributeOthers_subSteps`** (`SubStep.lean:87-113`): iterates
the balance map at the resource, filters out the excluded actor,
caps at 256, builds one sub-step per (capped) recipient with
`postBalance := p.2 + amount`.

**`proportionalDilute_subSteps`** (`SubStep.lean:122-144`):
similar; computes `credit := totalReward * v / sumOthers` (Nat
floor). Zero-sum case returns zero credit.

**`subSteps_length_bound`** (`SubStep.lean:159-173`): bounded by
256. Discharged by `List.length_take_le`.

**Sharp — Nat floor dust.** The
`totalReward * v / sumOthers` floor causes dust loss; this is the
"proportionalDilute_distributed_le_totalReward" pattern from the
Phase 4-prelude work. The SubStep formalisation doesn't ship a
sub-step-level dust bound; it just enumerates the sub-step list.
The economic invariant lives in `Laws/ProportionalDilute.lean`.

---

## 12. `Verify.lean` (400 lines)

**Imports** (`Verify.lean:60-63`): `Authority.LocalPolicy`,
`Bridge.Eip712`, `FaultProof.Cell`, `FaultProof.Commit`.

**`canonicalAbsentValue`** (`Verify.lean:82-89`): canonical
"absent" bytes per cell type.

**`getCellValue`** (`Verify.lean:100-132`): seven match arms
across the cell tag. Each arm encodes the cell value canonically
(CBE) so values comparable via byte equality.

**`isCellAbsent`** (`Verify.lean:145-146`): decidable predicate.

**`setCell`** (`Verify.lean:167-208`): writes a cell value into a
state. Notes:

- `nonce` is a no-op (`Verify.lean:175-179`): "Nonces are bumped
  by `advanceNonce`, not arbitrarily set." So a verifier-driven
  write of a nonce silently leaves the state unchanged.
- `bridgePending _wd` is a no-op (`Verify.lean:199-203`):
  "Pending withdrawals are appended via `appendWithdrawal` which
  assigns a fresh id."
- Other tags decode the input and conditionally update; on
  decode failure, return original state unchanged.

**`buildCellProof`** (`Verify.lean:223-226`): canonical: witness =
the state itself.

**`verifyCellProof`** (`Verify.lean:237-239`): decides
`commitExtendedState witness = commit ∧ getCellValue witness tag = claimed`.

**`verifyCellProof_complete`** (`Verify.lean:276-280`):
unconditional — canonical proofs always verify.

**`verifyCellProof_sound_under_collision_free`**
(`Verify.lean:340-348`): under `CollisionFree`, a verifying proof
witnesses an existing state with the claimed cell value. The
proof packages `proof.witnessState` directly.

**Sharp — soundness is shallow.** `verifyCellProof_sound_*` does
not need `_h_cf` (it's unused, marked with underscore). The witness
state is *already* `proof.witnessState`. The "soundness" claim
here is therefore the verifier's own recompute equality. The
`CollisionFree` hypothesis is the *intended* trust route for
asserting *uniqueness* of the witness state (via commit
injectivity from Commit.lean), but the existence claim doesn't
need it. This is honestly noted in the docstring.

---

## 13. `Coherence.lean` per-variant: `PerVariantCoherence.lean` (608 lines)

**Imports** (`PerVariantCoherence.lean:52`): `FaultProof.Coherence`.

This is a long file (608 lines) consisting of 19 + 19 = 38
per-Action-constructor specialisations of the universal coherence
theorem from `Coherence.lean`. Each is a one-liner via:

- `recomputeCommitment_eq_signedActionToLogEntry` (`PerVariantCoherence.lean:73-78`).
- `applyCellWrites_eq_signedActionToLogEntry` (`PerVariantCoherence.lean:348-352`).

The audit docstring (`PerVariantCoherence.lean:13-50`) is candid:
"These theorems do NOT establish *per-Action-variant cell-write
semantics*... That richer per-variant content is captured
definitionally in `StepVariants.lean` (`Action.writeCells`) and at
the Solidity side by the per-variant `_step<Variant>` functions;
cross-stack agreement is verified at the fixture-corpus level (WU
H.10.1), not at the theorem level here."

**Sharp.** This is an honest documentation of partial coverage.
The per-variant theorems are essentially type-level pins — a
regression that breaks the universal #225 form for any specific
variant fails compilation here. They are not deep semantic
theorems.

---

## 14. `SolidityStepVMCommit.lean` (460 lines)

**Imports** (`SolidityStepVMCommit.lean:51-54`): `Bridge.Eip712`,
`Bridge.HashAdaptor`, `Runtime.Hash`, `Authority.Crypto`.

Mirrors the L1 `KnomosisStepVM` per-variant post-commit recipe at the
Lean level. Uses `uint64BE` and `uint256BE` helpers
(`SolidityStepVMCommit.lean:70-117`) plus a `hashString` for
per-variant tag hashes (`SolidityStepVMCommit.lean:144-184`,
**19** named tags).

Per-variant `stepCommit<X>` definitions
(`SolidityStepVMCommit.lean:196-403`): each is
`hashBytes (preCommit ++ tagX ++ packed-fields)`. Returns 32 bytes
under the production keccak256 binding; reverts to 8 bytes under
the FNV-1a-64 fallback (which is intentional and documented at
`SolidityStepVMCommit.lean:129-140`).

**Sharp — bulk actions' `keyB` width.** The
`stepCommitDistributeOthersFold` (`SolidityStepVMCommit.lean:271-274`)
and `stepCommitProportionalDiluteFold`
(`SolidityStepVMCommit.lean:297-300`) use `uint256BE keyB` (not
`uint64BE`) for cross-stack agreement: Solidity declares
`CellProof.keyB : uint256`. Reviewer note: this nontrivial
discipline is documented but easy to break.

**`hashString_inj_under_collision_free`**
(`SolidityStepVMCommit.lean:450-456`): forward direction of CR
lifted across `hashString = hashBytes ∘ toUTF8`. Useful for
distinguishing tag hashes.

---

## 15. `EncodeInjectivity.lean` (113 lines)

**Imports** (`EncodeInjectivity.lean:45-47`): `Encoding.GameState`,
`Encoding.KernelStep`, `FaultProof.Coherence`.

Five theorems:

- `commitState_setBalance_bytes_inj_under_collision_free` (#213,
  byte form) — composes the existing Commit.lean lemma.
- `kernelStep_encode_deterministic` (#228) — `rfl`.
- `kernelStep_encode_distinguishes_inputs` (#229) —
  contrapositive.
- `gameState_encode_deterministic` (#272) — `rfl`.
- `gameState_encode_distinguishes_inputs` (#272) — contrapositive.

The docstring at `EncodeInjectivity.lean:34-40` is honest about
the no-deferrals policy: full `encode s₁ = encode s₂ → s₁ = s₂`
injectivity is **not** shipped (it would require non-provable
hypotheses).

---

## 16. `Strategy.lean` (170 lines)

**Imports** (`Strategy.lean:27-29`): `FaultProof.Coherence`,
`FaultProof.Game`, `Runtime.LogFile`.

**`truthfulCommit`** (`Strategy.lean:44-47`): canonical
state-root function — `commitExtendedState (kernelOnlyReplay
genesis (log.take idx))`.

**`honestStrategy`** (`Strategy.lean:84-111`): the unique honest
move computation. Three cases: submit truthful midpoint, respond
based on truth match, decline (no termination — needs KernelStep).

**`isHonestByTruth`** (`Strategy.lean:121-128`): a strategy "agrees
with `honestStrategy` at every in-progress in-turn move."

**`honest_strategy_unique`** (`Strategy.lean:137-145`): by
definition. Reviewers should note: this is uniqueness *of the
move* given the truth function, not uniqueness of the truth
function or of the winning strategy in any deeper sense.

---

## 17. `Trust.lean` (205 lines)

**Imports** (`Trust.lean:26`): `FaultProof.Honesty`.

Composite trust-model upgrade theorems:

- `single_honest_challenger_narrows_with_disagreement` (#257,
  `Trust.lean:54-73`): packages `disagreement_persists_along_trace`
  + `bisection_converges_after_enough_rounds`.
- `terminal_disagreement_implies_sequencer_claim_wrong` (#266,
  `Trust.lean:96-101`): direct projection.
- `trust_model_upgrade_composite` (#232 composite,
  `Trust.lean:146-169`): trifecta — disagreement persists + range
  narrows + sequencer's high.commit ≠ truth.
- `state_root_invalidity_inequality` (#233,
  `Trust.lean:184-190`): symmetry rephrase.
- `disagreement_to_state_root_invalidity` (`Trust.lean:196-202`):
  bridge from game-state-level to witness-level.

**Sharp.** This module composes the per-round content; it does
*not* close the operational claim "the L1 contract settles the
game against the sequencer" — that's the operational implication
captured by `L1AttestationSemantics` in Witness.lean.

---

## 18. `Observer.lean` (121 lines)

**Imports** (`Observer.lean:32-38`): `Disputes.Evidence`,
`FaultProof.Cell`, `FaultProof.Coherence`, `FaultProof.Commit`,
`FaultProof.Strategy`, `FaultProof.Verify`, `Runtime.LogFile`.

The Lean **reference specification** for the off-chain
prover/observer (read-only watcher). Per CLAUDE.md, the Rust
observer crate is deferred. Three primitives:

- `detectFault` (`Observer.lean:55-60`): truth-vs-claim
  comparison via `decide`.
- `buildObserverCellProofs` (`Observer.lean:76-80`): wraps
  `buildCellProof` over `Action.requiredCells`. Verifies by
  `buildObserverCellProofs_verifies` (`Observer.lean:84-89`).
- `computeNextMove` (`Observer.lean:97-101`): alias for
  `honestStrategy`.

**Sharp.** This is the Lean reference; production observers are
deferred Rust work. The "observer reference" is read-only and
non-trust-bearing — it can crash, lag, or be wrong without
affecting safety.

---

## 19. `Transcript.lean` (249 lines)

**Imports** (`Transcript.lean:31`): `FaultProof.Coherence`.

Auxiliary infrastructure:

- `applyCellWrites` alias (`Transcript.lean:49-50`).
- `extractRequiredCells` (`Transcript.lean:64-65`).
- `Action.requiredCellProofs := buildCellProofsForAction`
  (`Transcript.lean:78-80`).
- `NonMembershipProof` (`Transcript.lean:97-105`): cell-absent
  witness; build helper at `Transcript.lean:110-114`.
- `isLegalTranscript` (`Transcript.lean:129-133`):
  chain-pre-commit-matches-prev-post predicate.
- `chainKernelStepApplyFromLog` (`Transcript.lean:176-181`):
  derive a chain of KernelSteps from a log; length-preserving
  (`Transcript.lean:188-195`) and legal-transcript
  (`Transcript.lean:209-246`) by induction.

**Sharp — `chainKernelStepApplyFromLog_isLegalTranscript` proof
construction** (`Transcript.lean:209-246`): the inductive step
shows the tail's pre-commit equals the head's post-commit
(which equals `recomputeCommitment es e.signedAction` =
`commitExtendedState (kernelOnlyApply es e)` by #225 coherence).
This is the canonical example of #225 being used downstream.

---

## 20. `AbsentCellCreation.lean` (118 lines)

**Imports** (`AbsentCellCreation.lean:28-32`): `Bridge.State`,
`Laws.Deposit`, `Laws.Mint`, `Laws.Reward`, `Laws.Transfer`.

Per-variant #261 specialisations of `applyCellWrites_creates_absent_cells`:

- `mint_creates_balance_cell` (`AbsentCellCreation.lean:42-48`).
- `reward_creates_balance_cell` (`AbsentCellCreation.lean:52-58`).
- `deposit_creates_balance_cell` (`AbsentCellCreation.lean:63-71`).
- `transfer_credits_receiver_from_fresh_actor`
  (`AbsentCellCreation.lean:82-115`).

All four are direct computations. The transfer case is the
trickiest because of the §4.11 self-transfer / post-debit re-read
discipline; the proof requires `sender ≠ receiver` explicitly.

---

## 21. `MigrationFreeze.lean` (121 lines)

**Imports** (`MigrationFreeze.lean:21-23`): `Authority.Action`,
`Disputes.Types`, `Runtime.LogFile`.

**`isMigrationActivation`** (`MigrationFreeze.lean:47-49`):
**always returns `false`**. The design choice: migration is
L1-only and never produces L2 log entries.

**`isMigrationActivation_always_false`**
(`MigrationFreeze.lean:57-61`): the substantive content.

**`every_log_lacks_migration_activation`**
(`MigrationFreeze.lean:100-104`): direct.

**`migration_activation_count_zero`**
(`MigrationFreeze.lean:109-118`): inductive — every filter result
is empty.

**Sharp.** This entire module is "L1-only migration; L2 log
records nothing." It's a documentation-codified invariant rather
than a substantive theorem.

---

## 22. `KeyDerivation.lean` (205 lines)

**Imports** (`KeyDerivation.lean:26`): `Bridge.WithdrawalRoot`.

**SMT-path discipline.**

- `smtPathFromNat` (`KeyDerivation.lean:40-44`): MSB-to-LSB bit
  string from `Nat.testBit`.
- `smtPathFromNat_length` (`KeyDerivation.lean:47-50`): `= smtHeight`.
- `smtPath` (`KeyDerivation.lean:119`): specialised to height 64.

**Aliasing analysis.**

- `smtPathFromNat_eq_iff_bits_eq` (`KeyDerivation.lean:75-98`):
  per-bit equality from path equality, via `List.getElem?` chase.
- `nat_eq_of_testBit_below` (`KeyDerivation.lean:159-176`,
  private): bits-below-bound lift to Nat equality. Uses
  `Nat.testBit_lt_two_pow`.
- `smtPathFromNat_inj_under_bound` (#258,
  `KeyDerivation.lean:183-202`): injectivity under bit-width
  bound. Reindexes from MSB-first to LSB-first and applies the
  helper.

**Sharp.** This is genuinely substantive work — the bit reindexing
in `smtPathFromNat_inj_under_bound` (the `h_swap : smtHeight - 1 -
(smtHeight - 1 - j) = j` step) is the kind of arithmetic that's
easy to get wrong. Closed via `omega`.

---

## 23. `DisputeConfig.lean` (139 lines)

**Imports** (`DisputeConfig.lean:28`): `Disputes.Verdict`.

**`DisputeConfig`** (`DisputeConfig.lean:47-54`): three-field —
`enableAdjudicatorQuorum`, `enableFaultProofGame`,
`oracleAdjudicatorQuorum`.

Three default configurations: `legacyOnly`, `faultProofOnly`,
`both` (belt-and-suspenders).

**`DisputeClaim.isFaultProofRoutable`**
(`DisputeConfig.lean:85-90`): four-of-five claim variants are
routable; `oracleMisreported` is **not** (it requires external
oracle data, not amenable to deterministic fault-proof discharge).

**Routing predicates** (`DisputeConfig.lean:100-114`):
`routesToFaultProof`, `routesToAdjudicatorQuorum`. Oracle claims
always go to the quorum.

---

## 24. `GameTransitionEdgeCases.lean` (113 lines)

**Imports** (`GameTransitionEdgeCases.lean:32`): `FaultProof.Game`.

Four rejection-path theorems:

- `applyTransition_rejects_response_without_pendingMidpoint`
  (#271.1, `GameTransitionEdgeCases.lean:50-62`).
- `applyTransition_rejects_disagree_without_pendingMidpoint`
  (#271.2, `GameTransitionEdgeCases.lean:67-77`).
- `applyTransition_rejects_post_settlement` (#271.3,
  `GameTransitionEdgeCases.lean:83-94`).
- `applyTransition_rejects_malformed_midpoint` (#271.6,
  `GameTransitionEdgeCases.lean:100-110`).

All four close by `unfold applyTransition; <case-splits>;
simp` discharging the relevant guards. No deep content; these
ensure the state machine doesn't silently absorb malformed input.

---

## 25. `LawClassification.lean` (139 lines)

**Imports** (`LawClassification.lean:33-36`): `Authority.Action`,
`Conservation`, `Disputes.Types`, `Laws.Freeze`.

Workstream H's two new Action constructors compile to
`Laws.freezeResource 0`:

- `faultProofChallenge_compileTransition_eq_freezeResource_zero`
  (`LawClassification.lean:51-55`): `:= rfl`.
- `faultProofResolution_compileTransition_eq_freezeResource_zero`
  (`LawClassification.lean:59-63`): `:= rfl`.

`IsConservative` and `IsMonotonic` instances are derived for each
by rewriting through the `eq_freezeResource_zero` lemma and
applying `freezeResource_isConservative` / `freezeResource_isMonotonic`.

**Composite** `fault_proof_pipeline_actions_classification`
(`LawClassification.lean:116-136`): packages all four instances.

**Sharp.** Both fault-proof Action constructors are **state-advance
identities** at the kernel level — `freezeResource 0` is the
no-op marker. The kernel sees no effect; the L1 game contract is
the only authoritative resolver. This is a notable design choice
that should be obvious to reviewers: an `Action.faultProofResolution`
log entry tells the L2 audit trail what happened on L1, but the
L2 kernel state advance for that entry is identity.

---

## 26. `TypedCellProof.lean` (175 lines)

**Imports** (`TypedCellProof.lean:25-27`): `FaultProof.Cell`,
`FaultProof.StepVariants`, `FaultProof.Verify`.

**`TypedCellProof`** (`TypedCellProof.lean:40-46`): two
constructors — `readOnly` (just `CellProof`) and `readWrite`
(`CellProof` + `newValue : ByteArray`).

**`verifyTypedCellProofs`** (`TypedCellProof.lean:79-88`): in
addition to verifying each proof, checks the access mode matches
the action's declared sets (`readOnly` → `Action.readOnlyCells`,
`readWrite` → `Action.writeCells`).

**`buildTypedCellProofs`** (`TypedCellProof.lean:102-111`):
canonical bundle from action's required cells, tagged by their
mode.

**`verifyTypedCellProofs_complete`** (#262,
`TypedCellProof.lean:138-172`): the canonical bundle verifies.
Proof rcases the bundle membership into the two append-halves,
case-discharging each via `verifyCellProof_complete` + tag-equality.

**Sharp.** The "post-value placeholder" in `buildTypedCellProofs`
at `TypedCellProof.lean:110` uses `getCellValue es t` rather than
the actual post-state value. This is the *pre-state* value, not
the post-state — the docstring acknowledges this as a placeholder.
The actual post-state value would require running the action; the
typed bundle's `readWrite` constructor's `newValue` field is
nominal for the L1 verifier to consume.

---

## Cross-cutting Findings

### Trust-assumption opaques

Two opaques outside the kernel TCB:

- `Verify` and `hashBytes` from earlier workstreams (Authority,
  Runtime).
- `l1FaultProofVerifier` from Witness.lean (`Witness.lean:70-72`)
  — new in Workstream H. Per the opaque discipline, none appear
  in `#print axioms` output.

### Collision-free hash hypothesis

`Bridge.CollisionFree hashBytes` is threaded through the load-bearing
injectivity theorems (Commit.lean §220, Verify.lean §222,
EncodeInjectivity.lean §213). The hypothesis is a *typed argument*,
not an axiom. Production deployments must justify it externally.

### The "headline" theorems checklist (asked by audit prompt)

- `commitExtendedState_subcommits_bytes_eq_under_collision_free` —
  shipped, `Commit.lean:392-411`. **Bytes form**, not extensional
  state equality (documented honestly).
- `recomputeCommitment_coherent_with_kernelOnlyApply` —
  shipped, `Coherence.lean:150-171`. Structural `rfl`-class given
  the witness-state-bearing design.
- `recomputeCommitment_chain_coherent_with_kernelOnlyReplay` —
  shipped, `Coherence.lean:256-260`. Direct corollary.
- `range_narrows_on_response_agree` — shipped,
  `Game.lean:446-460`.
- `range_narrows_on_response_disagree` — shipped,
  `Game.lean:463-477`.
- `bisection_converges_after_enough_rounds` — shipped,
  `Convergence.lean:132-139`.
- `disagreement_persists_along_trace` — shipped,
  `Honesty.lean:238-264`.
- `honest_challenger_wins_against_invalid_state_root` — shipped,
  `Settlement.lean:213-242`.
- `faultProof_challenger_won_implies_state_root_wrong` — shipped,
  `Witness.lean:255-265`, **with explicit
  `L1AttestationSemantics` hypothesis** (deployment-level trust
  assumption).

All headline theorems exist and are dischargeable from the source.

### Notable design honesty

- `Coherence.lean`'s docstring (`Coherence.lean:14-44`) admits that
  the "semantic core" is just `kernelOnlyApply` — the coherence
  theorem is structural by construction, not a separate
  semantic equivalence proof.
- `PerVariantCoherence.lean`'s docstring
  (`PerVariantCoherence.lean:13-50`) admits that per-variant
  cell-write semantics are NOT theorems here; they live in the
  cross-stack corpus.
- `EncodeInjectivity.lean`'s docstring
  (`EncodeInjectivity.lean:34-40`) admits the no-deferrals policy:
  forward injectivity in the `encode → eq` direction is not
  shipped.
- `Witness.lean`'s docstring (`Witness.lean:25-36`) flags the
  `l1FaultProofVerifier` opaque as a new trust assumption.

### Documentation drift

- The footnote in CLAUDE.md says the Witness theorem "decomposes a
  `FaultProofChallengerWon` witness's L1 attestation against an
  explicit `L1AttestationSemantics` deployment assumption."
  **Verified accurate**: `L1AttestationSemantics` is defined at
  `Witness.lean:232-238` and used as a typed hypothesis at
  `Witness.lean:259`. No drift.
- CLAUDE.md says Workstream H adds **one** new opaque
  (`l1FaultProofVerifier`). **Verified accurate**.
- CLAUDE.md's headline-theorem table footnote 1 says the bytes
  theorem "is shipped at the structural level... but not as a
  stand-alone `*_encode_injective` lemma for the map-backed
  sub-states". **Verified accurate**: `Commit.lean:367-391`
  docstring matches.

### Observer reference (read-only watcher)

`Observer.lean` ships `detectFault`, `buildObserverCellProofs`,
`computeNextMove` as the Lean reference. Production Rust observer
is deferred per CLAUDE.md.

### Convergence bound calculation

`MAX_BISECTION_DEPTH := 64` (`Game.lean:48`) covers initial range
widths up to `2^64`. The strict-descent argument in
`range_size_after_k_rounds` (`Convergence.lean:65-97`) compounds
to `width_k + k ≤ width_0`. Setting `k ≥ width_0` forces
`width_k = 0`. Calculation looks correct.

### Witness-construction edge cases

`FaultProofChallengerWon`'s `action_eq` and `l1_attestation` fields
both existentially quantify `bh, w`. The fields are structurally
independent (different existential witnesses *could* be supplied),
but the `of_log_entry` constructor (`Witness.lean:126-140`) uses
the same `bindingHash` and `winner` for both. Consumers that
extract `action_eq` separately don't get the L1 attestation; this
is a slight asymmetry but doesn't appear exploitable — the
trust-model upgrade theorem
`faultProof_challenger_won_implies_state_root_wrong` consumes
`l1_attestation` exclusively.

---

## Summary of audit results

The 25 FaultProof modules together implement the bisection game
(Game.lean), the cell-proof verifier (Cell, Verify, TypedCellProof),
the state commitment + coherence chain (Commit, Coherence,
PerVariantCoherence, EncodeInjectivity), convergence + honesty
+ settlement (Convergence, Honesty, Settlement, Trust), the L1
attestation witness (Witness), and various support code (Step,
StepVariants, SubStep, Strategy, Observer, Transcript,
AbsentCellCreation, MigrationFreeze, KeyDerivation, DisputeConfig,
GameTransitionEdgeCases, LawClassification, SolidityStepVMCommit).

**All nine headline theorems referenced by the audit prompt are
present and structurally dischargeable.** The major design choices
— the witness-state-bearing CellProof, the
`l1FaultProofVerifier` opaque, the `L1AttestationSemantics`
deployment assumption, the structural coherence-by-construction —
are documented in source-level docstrings and are consistent with
CLAUDE.md's claims. No documentation drift detected.

The most notable sharp points are:

1. **Coherence-by-construction.** The headline #225 coherence
   theorem is structurally `rfl` because the "semantic core"
   `applyCellWrites_to_state` is `kernelOnlyApply`. The
   trust-model upgrade therefore rests heavily on the cross-stack
   corpus (WU H.10.1) for the Solidity step VM's correctness.
2. **Bytes vs extensional equality.** The
   `commitExtendedState_subcommits_bytes_eq_under_collision_free`
   theorem proves bytes-equality only; lifting to extensional
   equality on TreeMap-backed sub-states needs encoder
   canonicality (deferred follow-up).
3. **`L1AttestationSemantics` is a deployment-level trust
   assumption.** It is the *typed* hypothesis through which the
   `faultProof_challenger_won_implies_state_root_wrong` theorem
   discharges; consumers must operationally justify it (the L1
   contract enforces the semantics).
4. **Static cell declarations omit the dynamically-allocated
   `bridgePending <nextWdId>` cell** for `withdraw`. The runtime
   adds it at game-play time. Cross-stack reviewers must verify
   Solidity mirrors this.
