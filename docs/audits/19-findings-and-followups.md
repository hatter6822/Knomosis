# Synthesis — Cross-cutting findings and open follow-ups

This document aggregates the findings of every per-area audit
file into a single, severity-ranked list, with cross-references
back to the individual audit files where each finding was
documented in detail.

The findings are organised by severity tier.  Within each tier,
findings are grouped by theme.

* **Critical:** would invalidate a kernel-soundness claim or
  could allow a malicious actor to bypass an admissibility gate.
* **Major:** would invalidate a deployment-level claim or could
  produce misleading audit output.
* **Minor:** documentation drift, brittleness in tooling, or
  ergonomic issues that do not affect correctness.
* **Informational:** observations the auditor wants to surface
  without recommending action.

---

## Critical findings

**Superseded.**  This section originally read "None observed",
which was true of the scope the original review covered — the
kernel TCB — and was read afterwards as a statement about the
whole system.  A later full-codebase audit surfaced six critical
findings outside the TCB.  Their dispositions:

| Finding | Where | Disposition |
|---|---|---|
| **C-1** — `State.encode` non-injective on balances ≥ 2^64 | `Encoding/State.lean` and the two sibling 64-bit cap axes | **Closed.**  128-bit CBE amount head (`cbeTagAmount`), widened `actionFieldsForL1`, widened Rust/Solidity decoders, fixtures regenerated at `/v2`. |
| **B-1** — unbounded budget minting | `Authority/SignedAction.lean` | **Closed.**  `topUpPriceCheck` + `MAX_TOPUP_BUDGET_PER_ACTION` + `poolActor`/`gasResource` pinning, mirrored in the `knomosis-host` pre-filter. |
| **B-2** — vacuous headline injectivity theorems | `Bridge/Eip712.lean` and every `CollisionFree` consumer | **Closed.**  `CollisionFreeOn S h` replaces the globally-injective (and hence *refutable*) predicate; satisfiability is exhibited, not assumed. |
| **B-4a** — terminate ABI drift | `knomosis-faultproof-observer/src/submitter.rs` | **Closed.**  Rust moved to the contract's 5-argument form, and the selector table is now pinned against `method_selectors.json`, emitted from the COMPILED artifacts by `solidity/scripts/export_method_selectors.py` and gated in `ci-solidity.yml` — so the pin can no longer re-derive its expectation from the string it tests. |
| **B-4b** — game-model fidelity (Lean/Rust) | `FaultProof/Game.lean`, `FaultProof/Step.lean`, observer `game.rs` | **Closed.**  `kernelStepApply` computes through `stepVMHash` instead of echoing the responder's `postStateCommit`; `terminateOnSingleStep` dropped `claimedPostCommit` and reads both sides from the game state; `submitMidpoint` carries only a commit and the index is derived, which made the convergence bound logarithmic (`bisection_converges_in_log_rounds`). |
| **B-3** — fault-proof cell values bound to nothing | `KnomosisStepVM.executeStep` | **CLOSED — the game calls `KnomosisStepVMRoot.executeStepToRoot`, which returns a post-state ROOT folded from derived cell writes, so both sides of the terminal comparison are the same construction.**  What survives is a cleanup (the old recipe is still compiled); see the section below. |

### Open critical: the fault-proof commit-recipe split

**Status: CLOSED.**  The root swap is in (§3), the verifier is built on
both stacks (`KnomosisStepVMRoot.executeStepToRoot`, pinned against
Lean's `stepPostRoot` by the corpus's `writeBundleGoldens`), and
`terminateOnSingleStep` calls it — so both sides of the terminal
comparison are state roots.  What survives is a cleanup: the old
`KnomosisStepVM` and Lean's `stepVMHash` are still compiled alongside
the new path, called by nothing in the game.  Retiring them is
`docs/planning/state_root_merkleisation_plan.md` §5's S7.

Landed:

  * the cell space now covers all seven `ExtendedState` fields
    (tags 7–16 — the AMM mirror, the kill switch, the epoch budgets
    and the budget policy previously had no tag at all);
  * `smtCellKey` / `StepVMMerkle.deriveCellSmtKey` derive the SMT
    key on-chain from the cell's identity instead of accepting one,
    pinned byte-for-byte across the stacks by `cell_key.json`;
  * `commitExtendedStateSmt` builds the SMT root over those cells,
    additively, with coverage and binding tests;
  * `smtRootListAux_perm_of_eq_under_collision_free`
    (`FaultProof/SmtInjective.lean`) proves that root injective —
    the EI.8 replacement, so the swap can no longer downgrade the
    headline guarantee.  Needed `emptySubtreeHash_succ` (the chain
    relation the tail-recursive array builder does not expose) and
    a separation lemma for empty-vs-populated sub-trees, both of
    which would have been easy to skip: the two sides are equally
    well-formed 32-byte hashes;
  * `commitExtendedStateSmt_determines_cells`
    (`FaultProof/StateCellsInjective.lean`) composes it with the
    cell enumeration, concluding `∀ t, getCellValue es₁ t =
    getCellValue es₂ t` — behavioural rather than
    `ExtendedState.extEq`, because `State.Equiv` separates a
    resource present with an all-zero balance map from a resource
    absent entirely and no cell read can;
  * `smtUpdateRoot` plus `smtUpdateRoot_verifies` and
    `smtUpdateRoot_proof_independent` — the incremental write the
    step VM needs, and the guarantee that its result is a function
    of `(pre-root, key, new value)` rather than of which verifying
    opening the responder chose.

The `getCellValue` absent-vs-empty ambiguity this entry used to
flag is closed: the registry and local-policy arms route through the
CBE byte-string encoder, whose 9-byte head is present even for a
zero-length payload, and `getCellValue_of_not_mem` proves the absent
reading is the canonical one.

  * `canonicalSiblings_walks_to_root` — the honest-defender
    direction.  Soundness above is stated over *any* verifying
    proofs and does not care how one was built; a defender must be
    able to CONSTRUCT an opening that reproduces the published root,
    or it cannot compute the post-root the L1 will accept.  The
    representation half (that `buildSmtCellProof`'s
    bitmask-compressed encoding expands to that path) stays pinned by
    tests rather than proved; it is bookkeeping over `setBitmaskBit`,
    not content.

**§3 has landed.**  `commitExtendedState` IS the SMT cell root; the
seven-component concatenation is retained as
`commitExtendedStateConcat` with its theorems intact, but nothing
publishes it.  The guarantee did not weaken across the swap —
`commitExtendedState_determines_cells` replaces the EI.8 row for the
published root — and `verifyCellProof`'s witness-uniqueness theorem
became `verifyCellProof_witness_cells_agree_under_collision_free`,
which concludes per-cell agreement.  That is a strengthening in the
direction a cell proof cares about.

**§3A has landed too**, and it found a defect in the root as first
shipped: absent cells were not openable.  `stateCellTags` enumerates
only live cells, so a cell with no entry has an empty sub-tree
beneath its key rather than a leaf holding the canonical absent
value — and an opening built the present-way reconstructs a root the
tree does not have.  Crediting a receiver who holds no balance yet is
the common case, so §4's first handler would have hit it.  A cell's
leaf now branches on absence (`cellLeaf` /
`verifyStateCellProof`), with completeness proved on both sides, and
`stateCellEntries` drops canonically-absent cells so that "value is
canonically absent" and "key is absent from the tree" are the same
condition — without which the verifier could not decide, since
`setBalance s r a 0` leaves a live entry whose value is
`encodeAmount 0`.

**§3B has landed**, and it supplies the statement §4's fold is
otherwise missing.  §2B says `smtUpdateRoot` is well-defined and
unsteerable; neither of those says the value it computes is the root
of any state, so an L1 folding proven writes into a pre-root would be
computing an arbitrary hash.  `smtRootListAux_update_single` closes
that: the canonical path never reads the key's own entry, so two entry
lists that agree off the key share it and the whole difference is the
leaf — which composes with §3A's `canonicalSiblings_walks_from_bucket`
to give both leaf branches without a second induction.  Lifted to
cells, `updateStateCellRoot_eq_commit_of_canonical` says a re-walked
opening lands on `commitExtendedState` of the post-state, and
`foldStateCellWrites_eq_commit_of_coherent` says the ordered
multi-write fold lands on the last state's root.  A stale opening —
one built against the pre-root and replayed after an earlier write —
is rejected by the fold, pinned as a negative control.

**§4A has landed on the Lean side.**
`LegalKernel/FaultProof/CellWrites.lean` turns a step's writes into a
`setCell` chain and discharges every SMT-shaped obligation once —
`chainCoherent_canonicalCellChain` for the six `ChainCoherent`
conjuncts, `getCellValue_setCell_getCellValue` for the write values
(all fifteen cell kinds).  That reduces the per-variant obligation to
`WriteSetComplete`: the advance changes no cell the declaration omits.
`fold_stepCellWrites_eq_commit_post` composes it into the statement §4
needs.

The enabling result is `commitExtendedState_eq_of_cells_agree` — two
states whose every cell reads the same publish the same root.  Without
it the per-variant proofs would need agreement between the production
advance and a `setCell` chain at the level of the STATE.
`ExtendedState` equality is unreachable (core has no pointwise lemma
concluding `=` on `Std.TreeMap`), and map-level equivalence — which
core does supply, via `TreeMap.Equiv` — is the wrong target: it is
strictly stronger than what the root observes, because
`stateCellEntries` drops canonically-absent cells.  A balance swept to
zero by `reclaimAmmReserves` and one never written are cell-identical
and root-identical with pointwise-different maps, so a map-level proof
would be assuming something false on a reachable state pair.

Proving `WriteSetComplete` found a declaration gap.  `Action.writeCells`
was incomplete for `withdraw`: `appendWithdrawal` inserts at
`bs.nextWdId`, so the cell a withdrawal creates is keyed by the
pre-state and a function of `(action, signer)` cannot name it — a
bundle carrying the declared cells could not reproduce a withdrawal's
post-root.  `Action.writeCellsAt` is the complete set.

### Closed: a bulk action could exceed what the game can decompose

`FaultProof/SubStep.lean` caps the decomposition at
`maxRecipientsPerBulkAction = 256` — the L1 gas bound.
`Laws.distributeOthers`'s precondition was `amount > 0` **alone**, so
the law credited every non-excluded actor however many there were; the
same held for `proportionalDilute`.  Above the cap the two disagreed,
and a terminal step over such an action would have settled on a root
the L2 never published.  With 256 actors an ordinary deployment size,
that was reachable rather than theoretical.

The truncation was not the defect — an L1 that cannot iterate 257 cells
in one transaction is a fact.  The defect was that the ACTION layer
admitted a step the L1 could not adjudicate.

**Closed in the precondition** (`LegalKernel/Laws/BulkBound.lean`).
`BulkBounded s r excluded` is now a conjunct of both bulk laws' `pre`,
so `step_impl`'s `if pre then apply_impl else id` makes the step a
no-op above the bound.  Fail-closed in the direction that matters: an
action the L1 cannot adjudicate is one the L2 does not admit, and the
decomposition covers the law's effect in every admissible case by
construction rather than by convention.

Chosen over an admission-gate bound because the bound is a property of
the transition, not of who submits it — and because a consensus-critical
bound living outside the law it bounds is exactly the shape that drifts.
`step_impl` called directly (the dispute pipeline's replay does) now
honours it too, which an admission-layer bound would not have given.

Both directions are theorems, not just tests:
`subSteps_complete_of_pre` (an admitted step is fully decomposed, with
the bound supplied by the law rather than by the caller) and
`distributeOthers_noop_above_cap` (above the bound there is no advance
to decompose).  `faultproof-substep` checks both plus the gate itself,
so the bound cannot become vacuous in either direction without a
failure.

The cap now has ONE definition, in the law.  `SubStep` and
`StepVMCoherence` each used to hold their own copy of the same number,
checked by nothing.

**`WriteSetComplete` is proved for all twenty-five actions**
(`FaultProof/StepWriteSets.lean`,
`writeSetComplete_productionApplyBudget`), bulk included.  The two bulk
variants were excluded while their footprint was believed unnameable —
"every non-excluded actor's balance, unboundedly many cells".  It is
nameable: `Laws.BulkBounded` caps it in both laws' own preconditions,
and the real obstacle was the ARITY of `Action.writeCells`, not the
size of the set.  `Action.stateWriteCells` — which already existed
because `withdraw`'s pending cell is keyed by the pre-state's
`nextWdId` — takes the state, so the recipients go there, enumerated
as `Laws.bulkRecipients` in the order both laws fold.  A bulk step
therefore stays a single `executeStep` rather than acquiring a sub-step
index in the game's addressing.  Six of the seven state
fields have an action-independent footprint and are settled once; the
balance footprint is the per-variant half, and `Conservation.LocalTo`
does not cover it — that class is RESOURCE locality while the cell
space is keyed by `(resource, actor)`.  The footprints are
unconditional rather than stated under each law's precondition,
because `step_impl` is `if pre then apply_impl else id` and a fault
proof adjudicates a step whose admissibility is not in evidence.

`stepWriteBundle` / `stepPostRoot` are the honest sequencer's side:
the ordered `(cell, proven pre-value, new value, opening)` list the L1
folds, and the number the fold produces.
`stepPostRoot_eq_commit_productionApplyBudget` says the fold of THAT
bundle lands on exactly the root an honest sequencer publishes — the
fold itself never touches the post-state.  Exercised on real actions
including `withdraw` and both bulk variants, with a forged-value case
showing the fold does not reach the honest root.

**But read the quantifier, because it is the whole of what is left.**
`stepWriteBundle es st idx` takes the pre-state and derives its
`newValue` column from `productionApplyBudget es st idx` — it is the
SEQUENCER's computation.  A verifier holding only the pre-root and a
submitted bundle has neither, so if it simply folds what it is handed,
a responder free to choose the `newValue` column folds to a root of
their choosing and wins every game.  The fold is an adjudicator only
over a write list the verifier derived itself.

That derivation — each written cell's new value from the proven
PRE-values alone, in canonical CBE byte form, on both stacks, plus the
Lean theorem that it agrees with `stepCellWrites es
(productionApplyBudget es st idx) …` — is the largest remaining piece
and the one the plan understated as "the root update becomes shared".
**It is now complete on the Lean side.**
`FaultProof/VerifierWrites.lean` derives every cell kind a step can
write, each with a `*_correct` theorem against
`getCellValue (productionApplyBudget es st idx)`:

  * the **nonce** and **epoch-budget** cells, uniform across all
    twenty-five variants — the nonce because `kernelOnlyApply` advances
    it before dispatching on the action at all, the budget because its
    three branches are selected by the `.budgetPolicy` cell rather than
    by the variant;
  * the **balances** of all twelve variants that write one, five of
    them sharing `deriveChainPair` (write `x`, then write `y` reading
    the already-written state — the `x = y` case is reachable in every
    one), with `ammSwap` the single cross-resource case;
  * the **registry / local-policy / bridge** cells of the eight
    variants that write those.

Two properties run through all of it, and they are what turn a
calculator into an adjudicator.  The precondition is EVALUATED rather
than asserted, so a failing one yields the pre-values — which is the
fix for the "a revert is not a verdict" defect below.  And the reader
is PARTIAL: a cell the bundle does not open derives `none`, so a
responder cannot omit an opening and obtain a value of their choosing.
Every input is available (the cell space covers all seven state
fields, so the signer's nonce, the budget policy and the signer's
epoch budget are all openable cells), but it amounts to
`productionApplyBudget` re-expressed cell-locally: `.nonce` is `pre +
1` uniformly, `.epochBudget` is the consume-then-grant against the
proven policy cell uniformly, `.balance` is the per-variant arithmetic
the Solidity handlers already do, and the eight variants that write
registry / local-policy / bridge cells supply those from the action's
own fields.  `docs/planning/state_root_merkleisation_plan.md` §4 step 3
holds the specification.

On the L1 side `StepVMMerkle.updateCellRoot` and `cellLeafHash` supply
the fold's two primitives, replacing a placeholder that returned
`keccak256(newValue)` and a verifier with no absence branch — both
zero-caller, which is why neither had been caught.

**The wire is landed.**  Every production bundle is built by
`buildCellProofWithOpening`; `CellProof` carries `bytes proofData` —
the 32-byte bitmask plus siblings — through the Lean CBE codec, the
JSON emitter, the Rust conduit's ABI encoder (head 5 → 6 words, so
`terminateOnSingleStep`'s selector moved and `method_selectors.json`
regenerated) and the Solidity struct, which shape-validates it at
intake (`MalformedProofData`); and the corpus publishes `proofDataHex`
per proof.  Nothing consumes the opening yet, so nothing that any
surface computes has changed.

The field carries NO default.  It had `:= ByteArray.empty` for one
iteration and two of the corpus's bulk builders inherited it and
published proofs with no opening at all — caught by the corpus shape
check and by nothing else.

Not landed: the bundle-only write derivation above, and `executeStep`
verifying the openings and returning the fold's result instead of
`stepVMHash`.  Those two are one consensus change and close this
finding; the swap was their precondition, since a post-root is not
computable from a concatenation hash at all.  §0 of
`docs/fault_proof_runbook.md` stands until they land.

**Two design decisions the derivation has to settle**, both found by
reading the write sets against what a verifier actually holds, and
both pinned as `OBLIGATION:` cases in `faultproof-write-sets` so the
implementer meets them up front.

1. **A bulk write set is complete but not verifiable.**
   `writeSetComplete_productionApplyBudget` covers both bulk variants
   — a statement about the HONEST bundle.  A verifier holding only the
   pre-root checks each opening, and every opening in a bundle that
   drops a recipient is valid, because the dropped cell is simply not
   mentioned.  The short bundle folds successfully, onto a root for a
   state where that recipient was never credited; a sequencer that
   publishes that root defends it and wins.  The obligation test
   exhibits it: drop the last write, the fold accepts, the root
   differs.

   Non-bulk variants are immune — their tag lists are functions of
   `(action, signer)` plus cells the bundle itself proves, so a
   verifier re-derives the list and rejects a mismatched bundle.  A
   bulk tag list is the actor set at a resource, and `smtCellKey` is a
   HASH of the cell identity, so balance cells at one resource share
   no key prefix and no subtree argument enumerates them.

   Three ways out, all deployment-level: commit to the per-resource
   actor set in its own cell; put the recipient list in the action's
   fields (the L2's admission gate, which holds the state, checks it
   is exactly the non-excluded set); or exclude the bulk laws from a
   deployment leaning on the fault proof.

   **DECIDED: exclude them**, because it costs nothing and is
   reversible — either alternative can be adopted later without
   undoing it, whereas the actor-set cell widens nearly every variant's
   write set and the explicit recipient list changes frozen `Action`
   indices 6/7 and their encoders.  Recorded as
   `FaultProof.FaultProofAdjudicable`, a decidable predicate rather
   than a runbook sentence, pinned to exactly those two by
   `faultProofAdjudicable_eq_false_iff` so it cannot quietly widen, and
   with the positive property it buys proved:
   `writeCellsAt_eq_writeCells_of_adjudicable` and
   `writeCellsAt_withdraw_from_proven_counter` say an adjudicable
   action's write set is a function of `(action, signer)` plus the
   proven `.bridgeNextWdId`, so a verifier re-derives it and rejects a
   mismatched bundle.

2. **A revert is not a verdict.**  `step_impl` is `if pre then
   apply_impl else id`, so a failing precondition advances only the
   nonce and the budget, and `stepPostRoot` lands on that root.
   Solidity's `_stepTransfer` REVERTS (`InsufficientBalance`).

   Invisible today, because `Runtime.processSignedAction` appends an
   entry only when `AdmissibleWith` holds and conjunct 5 of that
   predicate IS the transition's precondition — no honestly produced
   log entry has a failing `pre`.  Not invisible after the flip: a
   dishonest sequencer can bind an inadmissible action into the
   log-entry chain, and `terminateOnSingleStep` may be reached on the
   CHALLENGER's turn (the turn alternates through
   `respondToMidpoint`).  The responsible party then cannot call at
   all and loses by timeout, so any input on which `executeStep`
   reverts is a weapon against whoever's turn it is.

   The flip owes one of: `executeStep` total over well-formed inputs,
   returning the pre-root on a failing precondition; or a terminal
   step either party may call.

   **DECIDED: totality**, and the Lean derivation already implements
   it — every `derive*Balances` evaluates its law's precondition and
   returns the pre-values when it fails, so the Solidity mirror
   inherits the behaviour.  A terminal step either party may call would
   also be a game-model change, interacting with the turn-based timeout
   accounting; totality is local to the step VM.

Three obligations for that work were read from source during this
pass and are pinned as tests (`faultproof-stepvm-coherence`, the
`OBLIGATION:` cases) rather than left as prose, because each would
otherwise surface halfway through the rewrite:

  * the 25 step-VM handlers compute `.balance` cells and nothing
    else, while `Action.writeCells` correctly declares that every
    action advances `.nonce signer` (plus registry / local-policy /
    bridge cells for eight variants).  Harmless while the
    dispatcher's output is compared only against another dispatcher
    output; after the swap it makes the post-root wrong for EVERY
    action;
  * the coherence chain is anchored to
    `commitExtendedState ∘ kernelOnlyApply` — `Coherence.lean`'s
    semantic core `applyCellWrites_to_state` IS that function — while
    the runtime advances through `apply_bridge_admissible_with_budget`
    and its bridge leg records consumed deposits.  For a deposit the
    two produce different states with different roots, which the pin
    exhibits directly.  Invisible today because nothing compares a
    step-VM output to a real state root; an adjudication error on
    every bridge action the moment the swap makes that comparison.
    `FaultProof/ProductionApply.lean` now supplies the total,
    production-faithful core the re-anchoring needs — both legs:
    `apply_bridge_admissible_with_eq_productionApply` for the bridge
    advance and `apply_bridge_admissible_with_budget_eq` for the
    budget one (split into computation + gate, since the guarded
    entry point returns `Option`).  **Both are now done**:
    `applyCellWrites_to_state` IS `productionApplyBudget`, threaded
    with the step's `l2LogIndex`, and `PerVariantCoherence.lean`'s
    theorems were restated against it — 52 of them, not the ~33 this
    entry previously claimed, and four were FALSE rather than merely
    weaker.  Measured effect: 18 of 278 corpus entries moved on the
    bridge leg, and 170 once the fixtures stopped being built from a
    policy (`.bounded 0 1 0`) under which every budget consume refuses;
  * `distributeOthers` / `proportionalDilute` touch unboundedly many
    balance cells and must route through `FaultProof/SubStep.lean`
    rather than the single-step path.

Stated precisely, from source rather than from the plan documents:

1. `KnomosisFaultProofGame.initiateChallenge` anchors **both**
   endpoints to submitted state roots: `g.high.commit` is the
   disputed root's `rootStateCommit` and `g.low.commit` is
   checked against `lowStateCommit`.  Both are
   `commitExtendedState`-shaped state roots.
2. `terminateOnSingleStep` calls
   `stepVM.executeStep(g.low.commit, …)` and tests the result
   against `g.high.commit`.
3. `KnomosisStepVM`'s own header states that `executeStep`
   produces "a step-VM-specific 32-byte hash" that "is NOT
   byte-identical to the Lean side's
   `commitExtendedState(kernelOnlyApply es entry)` value".

So the terminal comparison is between two different
constructions and can never succeed: an honest sequencer loses
every game it correctly defends.  The per-entry byte-equivalence
assertion in `solidity/test/CrossCheck/StepVM.t.sol` is skipped
for exactly this reason, which is why no suite reports it.

The Lean side USED to compound this with a vacuity: `kernelStepApply`
returned `step.postStateCommit` — the responder's own claim —
whenever `verifyCellProofs` passed, and that is `List.all` over the
bundle, so an **empty** bundle passed vacuously; the transition then
compared the result against the caller's own `claimedPostCommit`.
That half is closed (B-4b above): `kernelStepApply` computes through
`stepVMHash`, and the transition reads both sides from the game
state.  What remains is purely the recipe mismatch — the Lean model
now faithfully mirrors a contract whose terminal comparison is
between two different constructions.

Closing this is a protocol workstream, not a patch.  The step VM
sees only proven cells, so for its output to live in state-root
space the state root has to become a Merkle/SMT root over cells,
recomputable as pre-root + the proven writes.  That change lands
in `commitState` and its siblings, the EI.8 injectivity chain,
`KnomosisStepVM`, the observer, and every fixture corpus
including the 278-entry step-VM corpus.  It is recorded here
rather than started because a half-migrated commitment scheme is
a consensus split — the same failure mode the C-1 amount
migration had to be carried across all three stacks to avoid.

**That consensus change has landed**, as one unit across the three
stacks — the game's terminate call, the observer's CHAINED bundle plus
its read-only policy opening, and the Rust conduit's terminate
signature (`method_selectors.json` regenerated from the compiled ABI).
The `witnessCommit` word went with it: a claim only a holder of the
whole `ExtendedState` could check, and one a responder could set
freely.

Two operator-facing conditions remain, and both are recorded in the
runbook's §0 rather than here: a deployment leaning on the fault proof
must not authorise `distributeOthers` / `proportionalDilute` (a
verifier cannot tell a complete recipient set from a short one), and
the old recipe is still compiled alongside the new path until S7
removes it.  The Lean MODEL of the terminal step
(`Step.kernelStepApply`) routes through the verifier, so the game model
and the contract compute the same thing.

**Closed, and independently of the above.**
`KnomosisFaultProofGame.submitMidpoint` derives
`mpIdx = (g.low.idx + g.high.idx) / 2` on-chain; Lean's
`GameTransition.submitMidpoint` and the Rust observer took the whole
`Claim` — index included — from the caller and accepted any interior
index, which is why `bisection_converges_after_enough_rounds` proved
only *linear* narrowing and its depth-64 corollary covered initial
widths ≤ 64 rather than the `2^64` the `MAX_BISECTION_DEPTH`
docstring claims.  Both now carry only a commit and derive the
index, and the logarithmic bound is proved
(`bisection_converges_in_log_rounds`,
`bisection_converges_at_max_depth`).  The shared 50-trace observer
game-trace corpus moved with them.

### The kernel TCB itself

The kernel TCB (`Kernel.lean` + `RBMapLemmas.lean`) is sound.
Every theorem reviewed depends only on the three canonical Lean
built-in axioms (`propext`, `Classical.choice`, `Quot.sound`).
No `sorry` in proof position.  No custom axioms.  The proofs
are direct (induction or computation), and the case-trees in
the multi-case proofs (`getBalance_setBalance_other`,
`totalSupply_setBalance`) are exhaustive.

The Phase 3 admissibility predicate, the Phase 6 dispute
pipeline, and the Workstream H fault-proof migration each
extend the kernel-adjacent surface in a way that preserves
the type-level firewall.  No instance of "the kernel
silently admits a transition that should have been rejected"
was found.

---

## Major findings

### M-1 — Replay tool's deploymentId defaults to `ByteArray.empty`

**Where:** `LegalKernel/Runtime/Replay.lean:148`,
`LegalKernel/Runtime/Loop.lean:172-174` (Runtime audit
`06-runtime.md` finding "DeploymentId defaults to
`ByteArray.empty` in both replay and the runtime hot path").

**What:** Cross-deployment-replay protection (Audit-3.4)
relies on the `deploymentId` field of `SignInput` being a
deployment-specific constant.  Both the replay tool's main
entry point and the runtime hot path's `processSignedAction`
default the `deploymentId` parameter to `ByteArray.empty`.
This is opt-in — only callers of `processSignedActionWith`
get a non-empty `deploymentId`.  The replay tool exposes no
parameterised entry point at all.

**Impact:** Two log files from different deployments could
be replayed against each other without the cross-deployment
signature check firing, as long as the production runtime
binary uses the default `deploymentId`.  In practice, the
production runtime supplies a non-empty `deploymentId`, so
the operational binary is sound; the issue is that the
*Lean* infrastructure has the default that silently turns
the check off.

**Recommendation:** Either (a) require an explicit
`deploymentId` parameter at every entry point (no default),
or (b) document the `ByteArray.empty` default as a
deployment-specific "I am the test / dev deployment"
sentinel value rather than a hidden default.

### M-2 — `bootstrapFromSnapshot` does not verify the log prefix chains to the snapshot's seed hash

**Where:** `LegalKernel/Runtime/Loop.lean:267-297` (Runtime
audit finding).

**What:** When restoring from a snapshot, the runtime
`bootstrap` function drops the log prefix without verifying
that the dropped prefix actually chains to the snapshot's
seed hash.  Only the first post-snapshot entry's chain check
runs.

**Impact:** An operator who supplies a coherent-but-wrong
snapshot (e.g. one from a different deployment that happens
to have the same `logIndex`) over a long log will be told
only if the chain at `entries[baseIdx]` happens to fail.
Because the post-snapshot tail is a valid chain on its own,
the bootstrap could succeed despite the snapshot being for
the wrong starting state.

**Recommendation:** Add an explicit chain-anchor check
before dropping the log prefix.  `AttestedSnapshot` is the
documented partner that closes this gap, but it must be
*required* by the runtime CLI, not just available.

### M-3 — Map-backed sub-states ship `*_deterministic` only — no `*_encode_injective` or `*_roundtrip`

**Where:** `LegalKernel/Encoding/State.lean`,
`LegalKernel/Encoding/Encodable.lean`,
`LegalKernel/Encoding/Disputes.lean`,
`LegalKernel/Encoding/LocalPolicy.lean`
(Encoding audit `05-encoding.md` finding).

**What:** For `State`, `ExtendedState`, `BridgeState`,
`LocalPolicies`, `KeyRegistry`, `NonceState`, the audit
found only `*_encode_deterministic` lemmas — no
`*_encode_injective` (bytes-equal-implies-equal) and no
`*_roundtrip` (decode-encode-eq) at the structural level.

**Impact:** CLAUDE.md footnote 1 explicitly calls out this
chokepoint for Workstream H: "Lifting bytes-equality to
extensional state equality (`toList` equality) requires CBE
encoder canonicality for `State` / `NonceState` /
`KeyRegistry` / `LocalPolicies` / `BridgeState`, which is
shipped at the structural level (`*_encode_deterministic`
and round-trip lemmas) but not as a stand-alone
`*_encode_injective` lemma for the map-backed sub-states;
that's a Workstream-H follow-up."  The fault-proof
soundness chain depends on `commitExtendedState_subcommits_bytes_eq_under_collision_free`
giving bytes-equality; promoting that to state-equality
requires the encoder injectivity.

**Recommendation:** Ship `*_encode_injective` for each
map-backed sub-state as a Workstream-H follow-up.  This is
already on the documented roadmap; the auditor confirms it
as a load-bearing follow-up.

### M-4 — Encoder uses CBE major-type tags, not per-instance tags; type-collision is documented but not structurally prevented

**Where:** `LegalKernel/Encoding/Encodable.lean`,
`LegalKernel/Encoding/CBOR.lean` (Encoding audit finding).

**What:** Every `Encodable` instance starts with a CBE
major-type tag (uint / bytes / array / map), not a
per-instance tag.  This means `Bool true` and `Nat 1`
produce identical bytes.  An ambient decoder that doesn't
know the expected type will mis-decode.

**Impact:** The deployment's runtime adaptor is responsible
for the type context.  An attacker who can inject bytes
into a position where a decoder expects type A but the
attacker supplies bytes valid for type B could trigger an
unexpected decode.  This is mitigated by the encoder being
total (no decoder error path that an attacker could
exploit) and by the `Action` constructor index being
explicit.

**Recommendation:** This is fundamentally fine — CBE is
position-typed by spec — but a structural improvement would
be to prefix each `Encodable` instance with a per-type tag.
This is a TCB-adjacent change and would require care.

### M-5 — `checkSignatureInvalid` hardcodes `deploymentId := ByteArray.empty`

**Where:** `LegalKernel/Disputes/Evidence.lean:186`
(Disputes audit `07-disputes.md` finding).

**What:** The signature-invalid dispute claim verifier
hardcodes the `deploymentId` parameter to `ByteArray.empty`,
relying on a "back-compat path".  This means a verdict on
this claim cannot distinguish cross-deployment-signed
actions from same-deployment-signed actions.

**Impact:** Similar to M-1: in practice the production
runtime supplies a real `deploymentId`, so disputes filed
against production logs work correctly.  But the Lean
infrastructure has the same default-empty hazard.

**Recommendation:** Require the `deploymentId` at the
dispute filing site rather than hardcoding it at evidence
check.

### M-6 — `Lex/Tools/Diff.lean` parameter and proof-override comparators only compare names, not types/bodies

**Where:** `Lex/Tools/Diff.lean:172-175, 176-179` (Lex
Tools audit `14-lex-tools.md` finding).

**What:** `paramsDiff` compares parameter `.name` only,
silently missing type / kind changes.  `proofOverridesDiff`
compares `.property` only, missing tactic-body changes.

**Impact:** A semantic diff that misses a type change on
a parameter or a body change on a proof override could
mark a breaking change as compatible, weakening the
governance gate for Lex law updates.

**Recommendation:** Extend both comparators to compare the
full record, not just the name.  This is a Lex
tooling-only change; no Lean / kernel impact.

### M-7 — `signedActionDomain` constant duplicated as separate string literal

**Where:** `LegalKernel/Authority/SignedAction.lean:139`,
`LegalKernel/Encoding/SignInput.lean:63` (Authority audit
`04-authority.md` finding).

**What:** The `signedActionDomain` constant
(`"legalkernel/v1/signedaction"`) is defined as a string literal
at two locations.  No shared constant.

**Impact:** A refactor that changes the domain string in
one place but not the other would silently desynchronize the
kernel's `signingInput` from `Encoding.signInput`.  No
mechanical check catches this drift.

**Recommendation:** Extract to a single shared constant
(e.g. in `LegalKernel/Authority/Crypto.lean` or a new
`LegalKernel/Authority/Domains.lean`).  Low effort, high
defensive value.

### M-8 — `Action` tag indices: parallel enumerations not mechanically linked

**Where:** `LegalKernel/Authority/Action.lean`,
`LegalKernel/Encoding/Action.lean` (Authority + Encoding
audits).

**What:** Three parallel enumerations of `Action`'s 19
constructors:
* `Action.tag` (the integer projection function).
* The CBE encoder's tag byte.
* The LP.2 dispatch table.

Only 4 of 19 indices are pinned by smoke checks
(`transfer=0`, `withdraw=14`, `declareLocalPolicy=15`,
`revokeLocalPolicy=16`).

**Impact:** A future PR that reorders the `Action`
constructors must update all three enumerations in lockstep.
Lean's type system would catch some mismatches (the encoder
would still compile if `Action.tag` matched the
constructor order), but a "transposition" (swap indices 5
and 6) would silently break log-file compatibility with
the on-disk and on-the-wire format.

**Recommendation:** Add per-constructor index regression
tests that pin every tag to its specific integer value.
Mechanical, append-only, high defensive value.

### M-9 — `naming_audit` enforcement narrower than documented policy

**Where:** `Tools/NamingAudit.lean:79-119`,
`Deployments/Examples/UsdClearing.lean:111` (Tools +
Deployments audits).

**What:** CLAUDE.md says `v2` is a forbidden temporal
marker.  The `naming_audit` tool's `forbiddenTokens` list
(line 79) does NOT include `_v2` as a substring.  As a
result, `federation_transfer_policy_v2` evades the
mechanical check despite the documented policy.

**Impact:** Documentation-vs-enforcement drift.  Reviewers
relying on `naming_audit` to enforce the documented policy
could let `_v2`-suffixed identifiers slip through.

**Recommendation:** Either (a) add `_v2`, `_v3`, etc. to
the `forbiddenTokens` list, OR (b) update CLAUDE.md to
list only the tokens the mechanical check actually
enforces.

### M-10 — `MockCrypto` docstring claims stub_audit will catch production imports; it does not

**Where:** `LegalKernel/Test/MockCrypto.lean:39-40` (Tests
audit `18-tests-overview.md` finding).

**What:** The `MockCrypto.lean` module docstring asserts:
"This module is **test-only**.  It must NOT be imported
from any non-test module.  The `stub_audit` binary will
flag any production import."

The actual `stub_audit` tool flags placeholder *bodies*
(`:= ByteArray.empty`, etc.), not imports of the mock
module.  A production module that imports `MockCrypto` and
uses `mockVerify` would NOT be caught by any current audit
tool.

**Impact:** A future PR that accidentally imports
`MockCrypto` into a production module would not be caught
by automation.  The crypto adaptor's correctness is the
backstop.

**Recommendation:** Either (a) extend an audit tool to flag
imports of `Test.*` modules from non-test code, OR (b)
update the docstring to remove the incorrect claim.

---

## Minor findings

### m-1 — `tcb_audit` parser silently accepts unrecognised import forms

**Where:** `Tools/TcbAudit.lean:76-84`.  Does not handle
`prelude`, `import all`, `meta import`.  Documented as
"keeps the parser simple."

**Impact:** A future TCB amendment that adds one of these
forms to a TCB-core file would be silently accepted.
Reviewers must catch it manually.

### m-2 — `count_sorries` pattern set exhaustive for common patterns but not formally complete

**Where:** `Tools/CountSorries.lean:168-174`.  Four
patterns: `:= sorry`, `by sorry`, `exact sorry`, bare
`sorry` line.  Misses `refine sorry`, `apply sorry`,
`(sorry : T)`, etc.

**Impact:** A sufficiently obfuscated `sorry` could
escape.  Backstop is code review + the strict-warnings
gate + `#print axioms` discipline.

### m-3 — `stub_audit` 12-line docstring lookback is a magic number

**Where:** `Tools/StubAudit.lean:157-175`.  Scans upward
12 lines for a docstring.

**Impact:** A stub-flagged line with a 15-line docstring
above it would not match.  Currently safe.

### m-4 — `withdraw`'s precondition permits `amount = 0`

**Where:** `LegalKernel/Laws/Withdraw.lean` (Laws audit
`03-laws.md` finding).

**What:** Unlike `transfer` / `burn`, `withdraw`'s
precondition has no positivity clause.  A zero-amount
withdrawal is admissible at the kernel level; only the
bridge-level authorisation gates it.

**Impact:** A bug in the bridge actor's policy could
admit zero-amount withdrawals, which would advance the
nonce but produce no observable state change.  Operational
nuisance, not a soundness issue.

### m-5 — `deposit.pre := True`; deposit-id uniqueness deferred to runtime

**Where:** `LegalKernel/Laws/Deposit.lean` (Laws audit).

**What:** The `deposit` law's precondition is `True`;
uniqueness of deposit IDs is enforced entirely by
`applyActionToBridgeState`.

**Impact:** The kernel-level `deposit` is unconditionally
admissible.  The bridge-level gate is load-bearing.

### m-6 — `affectedActors` doesn't include actors who gained balance via the action

**Where:** `LegalKernel/Events/Extract.lean:100` (Events
audit `11-events.md` finding).

**What:** For `distributeOthers` and `proportionalDilute`,
the helper returns pre-state actors only.  A future law
that *introduces* new actors at a resource would not have
its new-actor `balanceChanged` event emitted.

**Impact:** No current law introduces new actors, so this
is theoretical.  Flagged for future extensibility.

### m-7 — `Event` constructor-index drift relies on encoder, not inductive declaration

**Where:** `LegalKernel/Events/Types.lean` (Events audit
finding).

**What:** The "frozen index" annotations are a contract
with indexers.  Re-ordering the constructors would compile
but break every off-chain indexer.  The encoder is the
canonical contract.

**Impact:** Documented in the source but not mechanically
enforced.

### m-8 — Lex codegen fence-marker contract is a string convention

**Where:** `LegalKernel/Events/Extract.lean:239-240`,
`Lex/Tools/Codegen.lean` (Events + Lex Tools audits).

**What:** `-- BEGIN LEX-GENERATED` / `-- END
LEX-GENERATED` are string markers consumed by the codegen
tool.  Moving or renaming them breaks codegen.

**Impact:** Documented in source; manual review during
refactors required.

### m-9 — `Lex/Tools/Common.lean` reverse-alphabetical JSON field order

**Where:** `Lex/Tools/Common.lean:711-723` (Lex Tools
audit).

**What:** `LawDecl.toCanonicalJson` produces JSON with
reverse-alphabetical field order (caused by
`Lean.Json.mkObj`'s internal RBNode iteration).
Deterministic but unintuitive.

**Impact:** Documented in source; field order is a
canonicality contract with the cross-stack JSON consumer.

### m-10 — `Lex/Tools/Codegen.lean` M1 emission policy is effectively no-op

**Where:** `Lex/Tools/Codegen.lean` (Lex Tools audit).

**What:** Every `requiresEmission` returns `false`, so all
6 renderers emit empty strings.  Deliberate-illegal
`M2_RENDERER_TODO_*` tokens act as forward-protection.

**Impact:** Codegen is currently disabled; M2 will turn it
on.  Reviewers should not expect lex-generated code in
the M1 release.

### m-11 — `synth_*` synthesizers emit placeholder *strings*, not real Lean terms

**Where:** `Lex/DSL/Property.lean` (DSL audit `10-dsl.md`
finding).

**What:** The six synthesizers (`synth_conservative`,
`synth_monotonic`, etc.) emit placeholder strings.
Documented as M1 skeletons but a reviewer expecting
actual instance emission would be misled.

**Impact:** M2 will replace placeholders with real
synthesis.  Current behaviour is documented but
counter-intuitive.

### m-12 — `Shim.stmtReferencesSignedBy` is a positionless substring match

**Where:** `Lex/DSL/Shim.lean` (DSL audit finding).

**What:** Both `flow ... from alice to a` and
`flow ... from a to alice` pass under `signed_by alice`
because the check is a positionless substring match.

**Impact:** A weak signer check; the actual
authorisation must come from the `AuthorityPolicy`.
Documented but worth knowing.

### m-13 — `lexlaw` `renderSyntax := toString` can drift from user source bytes

**Where:** `Lex/DSL/Law.lean` (DSL audit finding).

**What:** `lexlaw`'s JSON sidecar uses `toString` to
render the syntax, which is not byte-identical to the
user source.  `deployment` uses the reliable
`Syntax.reprint` instead.

**Impact:** A Lex law's JSON sidecar could drift from
the user source in whitespace / quoting.  Documented in
the DSL audit; reviewers should not expect byte
equivalence.

### m-14 — `kernelOnlyApply` in `Evidence.lean` uses non-exhaustive wildcard

**Where:** `LegalKernel/Disputes/Evidence.lean:89`
(Disputes audit finding).

**What:** `kernelOnlyApply` uses a `_ => s` wildcard for
unhandled `Action` constructors.  If `Action` grows, the
wildcard silently captures the new constructor.

**Impact:** The coherence theorem's exhaustive 19-arm
case split is the safety net.  Documented in source.

### m-15 — `ingest` returns `none` for `depositInitiated` events

**Where:** `LegalKernel/Bridge/Ingest.lean` (Bridge audit
`08-bridge.md` finding).

**What:** Despite `Action.deposit` existing, the
`ingest` function returns `none` for L1 `depositInitiated`
events.  The actual deposit flow at the Lean level
bypasses `ingest` entirely.

**Impact:** Documented but worth knowing; reviewers
looking at the `ingest` function might be surprised.

### m-16 — §7.6.4 / §7.6.5 chain-level accounting theorems deferred to runtime cross-stack verification

**Where:** `LegalKernel/Bridge/Accounting.lean` (Bridge
audit finding).

**What:** Per-step deltas are complete but no inductive
top-level theorem exists in `Accounting.lean`.

**Impact:** Documented; the cross-stack tests
(`solidity/make test-cross-stack`) ratify what would be
the inductive theorem.

### m-17 — `Verdict.encode` relies on `List.zip_unzip`

**Where:** `LegalKernel/Encoding/Disputes.lean` (Encoding
audit finding).

**What:** Fragile if the wire format lengths disagree.

**Impact:** A malformed `Verdict` bytes input that has
mismatched lengths could trigger a decode error rather
than a clean rejection.  Documented.

### m-18 — `Lex/Tools/Codegen.lean` non-deterministic load order under duplicate-index registries

**Where:** `Lex/Tools/Codegen.lean` (Lex Tools audit
finding).

**What:** `Array.qsort`-induced non-determinism when
codegen-input registry has duplicate indices.  Mitigated
in `emitCanonicalManifest` / `emitAutoGenLean` via an
explicit identifier tie-breaker, but not everywhere.

**Impact:** Operational; if a user produces a registry
with duplicates, the audit tool's output could drift
between runs.  Backstop is `lex_lint` which would have
flagged the duplicates.

### m-19 — Several stale docstring claims

**Where:**
* `Lex/Tools/Codegen.lean:55-62` still claims
  `--canonical` is unimplemented (it's the audit-3
  manifest-scaffold mode).
* `LegalKernel/Authority/Crypto.lean:16` says `Verify` is
  a "Lean `axiom`" but the file uses `opaque`.
* `LegalKernel/Runtime/LogFile.lean:109-112` says hashes
  are "8 bytes" while the module's own `padTo32`
  discipline emits 32 bytes.

**Impact:** Documentation drift only; no behavioural
issue.

---

## Informational observations

### i-1 — Two non-Lean trust assumptions, both surfaced via `opaque`

**Where:** `LegalKernel/Authority/Crypto.lean:138`
(`Verify`), `LegalKernel/Runtime/Hash.lean` (`hashBytes`),
`LegalKernel/FaultProof/Witness.lean:70-72`
(`l1FaultProofVerifier`).

The trust model is honest: each non-Lean assumption is an
`opaque` declaration, not an `axiom`.  This keeps
`#print axioms` clean for downstream theorems even when
those theorems' admissibility paths reach the opaque.  The
production-vs-Lean asymmetry (opaques return defaults at
the Lean level) means term-level admissibility witnesses
cannot be constructed without the `MockCrypto` adaptor.

### i-2 — `Std.TreeMap` API surface is stable

The kernel + RBMapLemmas rely on roughly 12 named `Std`
lemmas.  All verified to exist in Lean 4 v4.29.1.  Any
toolchain bump must re-verify them (the
`docs/std_dependencies.md` inventory exists for this).

### i-3 — No external Lake dependencies

The kernel imports `Std.Data.TreeMap` only.  No Mathlib, no
batteries, no third-party Lean packages.  This is the
strongest part of the project's threat-model posture.

### i-4 — Strict linters enforced as CI gates

`autoImplicit := false`, `relaxedAutoImplicit := false`,
`linter.unusedVariables := true`, `linter.missingDocs := true`.
CI's strict-warnings gate fails the build on any `: warning:`
line.

### i-5 — Five mechanical audit gates in CI

`tcb_audit`, `count_sorries`, `stub_audit`, `naming_audit`,
`deferral_audit`, plus the Lex-specific `lex_lint` and
`lex_codegen --check`.  All run on every PR.

### i-6 — Two-reviewer rule is a process rule, not technically enforced

No CODEOWNERS file or branch-protection rule observed.
CI's mechanical gates enforce content discipline; reviewer
discipline is enforced by the team.

### i-7 — Coherence-by-construction in FaultProof.Coherence

The headline `recomputeCommitment_coherent_with_kernelOnlyApply`
theorem is structurally `rfl` because
`applyCellWrites_to_state` is literally `kernelOnlyApply`.
The trust-model upgrade leans heavily on the
cross-stack corpus (WU H.10.1).

### i-8 — Commit-injectivity shipped at bytes level only

`commitExtendedState_subcommits_bytes_eq_under_collision_free`
gives byte equality; lifting to extensional state equality
requires the encoder-injectivity follow-up (M-3).  Honestly
documented.

### i-9 — `proportionalDilute` dust-bound proof has a brittle invariant

**Where:** `LegalKernel/Laws/ProportionalDilute.lean` (Laws audit).

The bound relies on `S := sumOthers` being captured *before*
the foldl plus `kv.2` reading the *pre-foldl snapshot*
balance.  A refactor swapping `kv.2` for
`getBalance s' r kv.1` would silently break the bound and
has no explicit guard comment.  Recommend adding a
guard-comment near the load-bearing lines.

### i-10 — Decidability discipline holds project-wide

Every `Transition.decPre` field reviewed in this audit is
either `fun _ => inferInstance` (the common case) or has a
tightly scoped hand-written instance immediately adjacent
to the law.  No decidability witness reaches into
`Classical.dec` or `Decidable.decide` against unresolved
opaques.

### i-11 — Reward / stake economics has sharp edges but is non-TCB

* `claimImpugnedAmount` (Rewards.lean:580) silently skips
  bridge actions.
* `proportionalChallengerReward` with `divisor=0` emits a
  zero-amount reward record rather than no reward.
* `stakeWeightedAdjudicatorRewards`'s sum-le-pool bound is
  in the docstring but not shipped as a theorem.
* `Staking.stakeResolutionActions`'s "rollback returns the
  stake on .upheld" is a runtime invariant, not proved.

All are deployment-level concerns, not kernel soundness.

---

## Open follow-ups (suggested priority order)

> **Post-AR reconciliation note.**  The backlog below is the
> *original* audit snapshot, preserved for the audit trail.  The
> AR (Audit Remediation) workstream has since **closed every major
> finding** listed here; each item is annotated inline with the AR
> sub-unit that remediated it (canonical status:
> `docs/planning/audit_remediation_plan.md` §15C.2).  **All audit
> follow-ups are now closed**: the lone deferred finding **m-16**
> (chain-level bridge accounting) was closed by Workstream **CA**
> (`LegalKernel/Bridge/{Reachable,ChainAccounting}.lean`; headline
> `bridge_chain_accounting_equation` proves the §7.6.4 escrow identity
> unconditionally along bridge chains).  The "Remaining open follow-up"
> section below is retained as the historical record.  This annotation
> resolves OQ-DOC-4 in `docs/planning/open_questions.md`.

Pulling from the major findings and the most actionable
minor findings, the recommended follow-up backlog is:

1. ~~**[M-3] Map-backed sub-state encoder injectivity.**~~
   **Closed** by AR.4.1–AR.4.8 and the EI workstream:
   `State.encode_injective` lifts to
   `commitExtendedState_subcommits_extensional_eq_under_collision_free`.
2. ~~**[M-1, M-5] DeploymentId default-empty cleanup.**~~
   **Closed** by AR.2.1–AR.2.6 (explicit `deploymentId`
   threading at every entry point + CLI wiring).
3. ~~**[M-2] Bootstrap-from-snapshot chain-anchor check.**~~
   **Closed** by AR.3.1 (anchor check + `.anchorMismatch`) +
   AR.3.2 (AttestedSnapshot CLI gate).
4. ~~**[M-8] Action-tag index regression tests.**~~
   **Closed** by AR.5 (Action-tag pins); the sibling Event-tag
   pins (m-7) landed under AR.6.
5. ~~**[M-6] Lex Diff parameter / proof-override comparators.**~~
   **Closed** by AR.7 (type/body comparison, not name-only).
6. ~~**[M-7] `signedActionDomain` shared constant.**~~
   **Closed** by AR.1 (single shared constant).
7. ~~**[M-9] `naming_audit` enforcement vs. CLAUDE.md policy.**~~
   **Closed** by AR.8 (`_v2` added to the forbidden-token set;
   `UsdClearing` rename).
8. ~~**[M-10] `MockCrypto` import-check audit tool.**~~
   **Closed** by AR.9 — `mock_import_audit` now ships as a CI
   gate (`lake exe mock_import_audit`).
9. ~~**[i-9] `proportionalDilute` guard comment** at the
   load-bearing snapshot-read line.~~
   **Closed** — the `INVARIANT (AR.15 / i-9)` guard comment ships
   on the production foldl's snapshot read
   (`Laws/ProportionalDilute.lean`), and the law's Lex
   re-expression carries a matching guard (in the section docstring
   immediately above the `lexlaw` block, so it cannot leak into the
   codegen sidecar) — so neither copy of the load-bearing `kv.2`
   read can be refactored to a live-state read without tripping over
   the warning.

**Remaining open follow-up** *(historical snapshot — since
closed; see the reconciliation note above)*.

  * ~~**[m-16] Chain-level bridge accounting (§7.6.4 / §7.6.5).**~~
    **Closed by Workstream CA** (`Bridge/Reachable.lean` +
    `Bridge/ChainAccounting.lean`; headline
    `bridge_chain_accounting_equation`).  The original snapshot:
    promote the runtime / cross-stack-checked bridge supply
    identities to inductive `BridgeReachable` theorems.  Triaged
    "Defer" in AR §15C.2; tracked by the CA workstream
    (`docs/planning/chain_level_accounting_plan.md`).  It was the
    last open finding from the comprehensive audit — with it
    closed, **no audit finding from this report remains open**.

The auditor's recommendation is that none of these
findings are urgent for a research-stage codebase, but
all should land before any production deployment that
depends on the cross-deployment-replay or
snapshot-bootstrap guarantees.

---

## C-1 (CRITICAL) — `State.encode` is non-injective on reachable
states: balances ≥ 2^64 collide, so two distinct states share one
L1 state root

**Status:** OPEN.  Found by a later audit pass; not covered by the
original review, whose closing note ("No critical findings") is
superseded by this entry.

**Where.**  `LegalKernel/Encoding/Encodable.lean` (`instEncodableNat`
→ `cborHeadEncode`, a fixed 8-byte little-endian body) and
`LegalKernel/Encoding/State.lean` (`State.encode` →
`BalanceMap.encodeAsBytes`, which encodes each balance with that
`Nat` instance).

**The defect.**  `Amount` is `Nat` (unbounded, `Kernel.lean`), but the
CBE `Nat` encoder is total and lossy above `2^64` — it truncates
modulo `2^64` rather than failing.  `State.encode_injective`
(`Encoding/StateInjective.lean`) is therefore correctly conditioned on
`h_amt : ∀ p ∈ s.balances.toList, ∀ q ∈ p.2.toList, q.2 < 256 ^ 8`,
and its docstring states that "the runtime adaptor (Phase 5) gates
inputs at the boundary".

That gate does not discharge the hypothesis, for two independent
reasons:

1. **Nothing in production Lean bounds a balance.**  Every `< 256 ^ 8`
   occurrence outside a proof is in `Encoding/Action.lean`'s
   well-formedness predicate, which constrains *action input fields*.
   There is no invariant, precondition, or smart constructor bounding
   a stored balance.
2. **Bounding inputs cannot bound balances anyway.**  Balances
   accumulate: repeated in-range deposits sum past `2^64`.  The
   hypothesis is on the *stored balance*, not the input amount, so an
   input gate is the wrong quantity even if it existed.

`State.encode_injective` has no production caller — it is referenced
only from its own module and the test suite — so `h_amt` is never
discharged anywhere.

**Executable demonstration** (run against this tree):

```lean
import LegalKernel
open LegalKernel LegalKernel.Encoding
def sA : State := setBalance { balances := ∅ } 0 1 100
def sB : State := setBalance { balances := ∅ } 0 1 (100 + 2^64)
#eval (getBalance sA 0 1 == getBalance sB 0 1)          -- false
#eval (State.encode sA == State.encode sB)              -- TRUE
```

Observed: balances `100` and `18446744073709551716` differ, yet both
states encode to the same 54 bytes.

**Impact.**  `commitState` / `commitExtendedState` hash exactly these
bytes, so two distinct states produce the same L1 state root.  The
state commitment is not binding on the balance ledger, which is the
assumption the fault-proof chain rests on: a committed root no longer
identifies a unique balance assignment, so a bisection game can settle
on a state root that does not correspond to the state actually
reached.  Reaching the threshold requires a single actor's balance to
touch `2^64` wei ≈ **18.45 ETH** — routine for a bridge escrow or the
gas-pool actor, not an exotic edge case.

**Resolution chosen: widen amounts to 128 bits.**  The three stacks
already disagree on amount width — Rust's balance cell is 16 bytes
(`BALANCE_VALUE_LEN = 16`, `Amount = u128`, with *checked* arithmetic
that errors on overflow), Solidity uses `uint256`, and only Lean's
commitment path is 8 bytes and silently truncating.  Lean is the
narrow one, so the fix is to widen it rather than to cap balances.

**Landed (this pass): the encoding foundation, fully proved.**

* `Encoding/CBOR.lean` — `cbeTagAmount = 0x01` (previously unused in
  the tag space `{0x00 uint, 0x02 bytes, 0x03 text, 0x04 array,
  0x05 map}`), plus `cborAmountHeadEncode` / `cborAmountHeadDecode`: a
  17-byte head (tag + 16 LE body).  Theorems:
  `cborAmountHeadEncode_length`, `cborAmountHeadRoundtrip{,_append}`,
  `cborAmountHeadEncode_injective`, and
  `cborAmountHeadEncode_ne_cborHeadEncode` (tag-disjointness, which is
  what stops a widened amount field aliasing an identifier field).
* `Encoding/Encodable.lean` — `encodeAmount` / `decodeAmount` with
  `amount_roundtrip{,_empty}`, `encodeAmount_injective` (bound `2^128`),
  and `encodeAmount_ne_encodeNat`.
* `Encoding/State.lean` — `encodeSortedAmountPairs`,
  `decodeNAmountPairs`, `decodeAmountMap`: the amount-valued map
  combinators `BalanceMap` will use.
* `Test/Encoding/Injectivity.lean` — four pins, including
  `amount head separates values colliding mod 2^64`, which asserts
  BOTH that the 8-byte head collides on `100` vs `100 + 2^64` and that
  the 128-bit head separates them.

Identifiers, nonces, constructor tags and length prefixes deliberately
stay on the 8-byte head: they are `UInt64`-typed or structurally
bounded, so widening them would cost wire size and add a canonicality
obligation for nothing.

**Remaining: the migration itself.**  Measured surface —

* 407 `Encodable.encode (T := Amount|Nat)` call sites across
  `Encoding/{Action,Event,State,Disputes}.lean`, each needing the
  judgment "is this field an amount (→ `encodeAmount`) or an
  identifier / nonce / tag / length (→ unchanged)";
* 298 `256 ^ 8` bounds across ten `Encoding/*.lean` files, each
  needing the same judgment to decide whether it becomes `256 ^ 16`;
* the Rust decoders (`knomosis-indexer::decoder`,
  `knomosis-event-subscribe`, `knomosis-l1-ingest`) which currently
  assume `HEAD_LEN = 9` for every field;
* the Solidity step-VM `_stepXX` field decoders;
* every cross-stack fixture corpus, regenerated; and
* `docs/abi.md` §4 / §5, which documents the 9-byte head per field.

**This must land atomically.**  `Amount` is an `abbrev` for `Nat`, so
any site left on `Encodable.encode (T := Amount)` silently keeps the
narrow codec.  A migration that moves some amount fields and not
others produces a *mixed-width* encoder — a new consensus split, and
strictly worse than the current uniform bug.  That is why the
foundation above is purely additive and no existing encoder was
switched: the tree stays consistent and green until the migration
lands in one piece.

---

## H-1 (HIGH) — `commitExtendedState` binds 5 of `ExtendedState`'s 7
fields: `epochBudgets` and `budgetPolicy` are absent from the L1
state root

**Status:** FIXED.

**Where.**  `LegalKernel/FaultProof/Commit.lean` (`commitExtendedState`)
against `LegalKernel/Authority/Nonce.lean` (`structure ExtendedState`).

**The defect.**  `ExtendedState` carries seven fields — `base`,
`nonces`, `registry`, `bridge`, `localPolicies`, `epochBudgets`,
`budgetPolicy`.  `commitExtendedState` hashes five of them:

```lean
hashBytes
  (commitState        es.base ++
   commitNonceState   es.nonces ++
   commitKeyRegistry  es.registry ++
   commitLocalPolicies es.localPolicies ++
   commitBridgeState  es.bridge)
```

Its docstring states the opposite: "a single 32-byte hash binding
**every sub-state** in canonical order.  This is the value the
sequencer publishes to L1 as the state root."  Per CLAUDE.md's
implement-the-improvement rule the docstring is the better artefact
here and the code is what must change — the docstring must NOT be
weakened to match.

**Why it matters.**  `epochBudgets` is live, mutable, security-relevant
state, not a derived cache: `Bridge/Admissible.lean` rewrites it on
admitted actions (`epochBudgets := applyGrant …`, lines 521 / 530), and
it is what the GP.3.2 admission gate meters spending against.  Because
the published root does not bind it, two executions that agree on every
committed sub-state but disagree on per-actor budget grants or
consumption produce the *same* state root — so a fault proof has
nothing to disagree about and cannot challenge a forged budget ledger.
The same holds for `budgetPolicy`, which sets the metering parameters
themselves.

Note this is distinct from the documented step-VM boundary in
`FaultProof/StepVMCoherence.lean` (a terminate step binds balance
writes but not nonce/budget effects).  That is a statement about
per-step cell proofs; H-1 is about the top-level state root, which the
docstring claims is total over sub-states.

**Feasibility.**  Half the fix already exists: `instEncodableBudgetPolicy`
is defined (`Encoding/State.lean:944`), so `budgetPolicy` can be folded
in immediately.  `EpochBudgetState` has no `Encodable` instance yet and
needs one (plus the matching injectivity lemma, to keep the EI ladder
whole).

**The fix.**  `commitExtendedState` now hashes all seven sub-commits.

* `Encoding/State.lean` — `EpochBudgetState.encode` / `.decode` and
  `instEncodableEpochBudgetState`, a sorted-pair CBE map keyed by actor
  id over `ActorBudget`'s existing fixed-width instance (the same shape
  `NonceState` uses).  `BudgetPolicy` already had `instEncodableBudgetPolicy`.
* `FaultProof/Commit.lean` — `commitEpochBudgets` / `commitBudgetPolicy`
  with their 32-byte size lemmas and bytes-injectivity lemmas;
  `byteArray_concat_seven_split` (composed from the existing five-split
  by peeling the two trailing 32-byte segments with `byteArrayAppendInj`);
  and `commitExtendedState_subcommits_eq_under_collision_free` /
  `…_bytes_eq_…` extended from five to seven components.

**Cross-stack scope: none.**  Checked rather than assumed — the
Solidity step VM explicitly does NOT recompute `commitExtendedState`
(`KnomosisStepVM.sol` documents that it uses a step-VM-specific commit
recipe and that the cross-check per-entry byte comparison is skipped
for exactly that reason), and the Rust observer DELEGATES truth
computation to its `TruthOracle` trait rather than re-implementing
`commitExtendedState ∘ kernelOnlyReplay` (`strategy.rs`).  So the
change is Lean-only; the single affected artefact is
`solidity/test/CrossCheck/fixtures/step_vm.json`, regenerated via
`KNOMOSIS_FIXTURES_OVERWRITE=1 lake test` (one line).

**Regression protection.**  Three tests in
`Test/FaultProof/AmmCommit.lean`: two value-level pins (mutating
`epochBudgets`, and mutating `budgetPolicy`, each must move the root)
and an arity pin on the decomposition theorem.  Reverting
`commitExtendedState` to its five-field form does not merely fail those
tests — it fails to BUILD (3 errors), because the arity pin and the
decomposition theorem both require seven components.  A future field
added to `ExtendedState` without extending the commitment is therefore
a compile error, not a silent omission.

**Not covered.**  The EI.8 extensional lift
(`commitExtendedState_subcommits_extensional_eq_under_collision_free`)
still concludes `ExtendedState.extEq`, which enumerates the original
fields; it remains true and is now fed by the seven-component
decomposition, but lifting the two new sub-states from bytes-equality
to `TreeMap.Equiv` needs an `EpochBudgetState.encode_injective`
mirroring `NonceState.encode_injective`.  That is a strengthening of
the injectivity ladder, not a gap in the binding property this finding
was about.

---

## Refutation re-check (audit follow-up pass)

The full-codebase audit produced 87 raw findings; 56 survived
adversarial verification and 31 were refuted.  The refutations were
produced under a verifier prompt that instructed *"default to
refuted"*, an asymmetric burden that had already generated wrong
refutations earlier in the same pass.  They therefore warranted a
re-check under a neutral burden.

**What was recoverable.**  17 of the 31 refutation rationales, with
their file attributions:

| File | Verdicts |
|---|---|
| `knomosis-host/src/queue.rs` | 3 refuted (2 confirmed) |
| `knomosis-gateway/src/rate_limit.rs` | 1 refuted (1 confirmed) |
| `knomosis-gateway/src/events/fanout/ring.rs` | 1 refuted (1 confirmed) |
| `knomosis-gateway/src/events/fanout/resume.rs` | 3 refuted (0 confirmed) |
| `knomosis-l1-ingest/src/receipt_verifier.rs` | 3 refuted (0 confirmed) |
| `knomosis-indexer/src/indexer.rs` | 2 refuted (1 confirmed) |
| (earlier block, file header not captured) | 4 refuted |

The remaining 14 are not recoverable: the verifier output was not
persisted as an artefact, and the surviving transcript records the
rationales but not the finding texts they answer.

**What the rationales look like.**  Contrary to the concern that
motivated the re-check, most cite specific lines and are decisive on
their own terms.  Three classes:

  * *Self-refuting* — the finding conditioned itself on a file the
    auditor said it had not read ("this finding is conditional on it
    not doing so").  A conditional on an unexamined file is not a
    finding.
  * *Wrong premise* — e.g. the `receipt_verifier` claim required
    `tx_hash` to be operator-chosen, but no line in that module reads
    `tx_hash` from the claim; it is a separate parameter.
  * *"It is documented"* — the weakest class, because on this project
    a documented behaviour is not thereby correct (CLAUDE.md's
    implement-the-improvement rule).  These were the ones re-checked
    against source.

**Re-checked in full, against source, under a neutral burden:**

  * **`rate_limit.rs` — unbounded bucket map.**  The underlying
    observation is true: `buckets: Mutex<HashMap<u64, TokenBucket>>`
    grows via `entry(key).or_insert(…)` and is never paired with a
    `remove`, `retain` or capacity check.  The refutation is
    nonetheless correct, for a reason the finding did not state:
    `http/handler.rs` calls
    `auth::gate(…).or_else(|| auth::rate_limit_check(…))`, and
    `or_else` evaluates its closure only when `gate` returned `None`
    — i.e. only for a credential auth already admitted.  The map is
    therefore bounded by the valid-token set, which is operator-
    controlled and small, not by anything an attacker supplies.
    **Refutation upheld.**

  * **`indexer.rs` — saturating a balance cell to `u128::MAX` before
    returning `CreditOverflow`.**  The write does happen, but every
    per-event error propagates through `?` in `consume_batch` before
    `tx.commit()`, so the transaction is dropped un-committed and
    SQLite rolls it back.  The saturated value never persists.
    **Refutation upheld.**  (Minor, not tracked as a finding: the
    docstring describes an effect that is always discarded, so the
    `balance_set(…, Amount::MAX)` on that path is dead.  The
    documentation errs toward alarming rather than reassuring, which
    is the harmless direction.)

**Disposition.**  Nothing promoted.  The two refutations with real
safety substance hold on inspection, and the remaining recovered
rationales are of the self-refuting or wrong-premise classes, which
do not depend on the burden of proof.  The 14 unrecoverable ones are
recorded here as unre-checked rather than as cleared.

---

## Closing notes

The audit reviewed ~73,000 lines of Lean across 241 files.
The kernel TCB is sound by construction; the deployment-facing
infrastructure is well-engineered and well-tested but has the
expected scattered minor issues that any large research-stage
codebase accumulates.

The mechanical audit suite (`tcb_audit`, `count_sorries`,
`stub_audit`, `naming_audit`, `deferral_audit`, `lex_lint`,
`lex_codegen --check`) is a strong forcing-function and
catches the historical regressions documented in the
project's history.

The two-reviewer rule for TCB changes is a documented
process rule, currently enforced by team discipline rather
than CODEOWNERS.  Combined with the mechanical gates, this
gives the project the right posture for its claimed phase
(research-stage with production-aspiration).

**Superseded:** this note originally read "No critical findings".
Findings **C-1** (`State.encode` non-injective on balances ≥ 2^64,
critical — OPEN) and **H-1** (`commitExtendedState` bound 5 of 7
sub-states, high — since FIXED) above were both missed by this
review.  The remainder of
the note stands as written.

Ten major findings, mostly
documentation-vs-enforcement drift or
non-TCB-but-could-be-tighter; each has a recommended fix
that does not require a TCB amendment.  ~30 minor and
informational findings, all bounded.

The project is in good shape.
