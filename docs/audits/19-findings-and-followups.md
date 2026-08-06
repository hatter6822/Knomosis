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
| **C-2** — a bulk step's post-state not determined by the pre-state root | `Laws/BulkBound.lean`'s `bulkRecipients` | **Closed.**  Zero-valued balance entries have no leaf in the commitment tree but were counted as recipients, so `distributeOthers` paid an actor the root cannot see — two root-identical pre-states reached different post-roots, and `BulkBounded` disagreed across the same pair so one advanced and one no-oped.  The recipient list now drops them, and all four spellings collapse to the one definition. |
| **C-3** — the commitment is blind to balances at multiples of the amount head's modulus | `Encoding.encodeAmount` | **Closed.**  The head is `2^256` (the EVM word), the ceiling is a precondition conjunct on every crediting law (`Laws.AmountBounded`), and it is proved unreachable rather than assumed (`FaultProof.canonicalBounds_base_amt_of_reachable`).  See the section below for why widening alone would have left it open. |
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

### C-2 — Closed: a bulk step's post-state was not determined by the pre-state root

**Severity: critical.**  Not an L1 or a wire defect — a defect in the
LAW, which broke the premise the whole fault proof is built on.

`Laws.bulkRecipients` read the resource's `Std.TreeMap` directly:

```lean
(s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)
```

so an actor whose entry is **present and zero** counted as a recipient.
But `stateCellEntries` drops canonically-absent cells and
`canonicalAbsentValue (.balance _ _) = encodeAmount 0`, so that actor
has **no leaf in the state-commitment tree**.  `distributeOthers`'
credit is flat — `getBalance s' r kv.1 + amount` — so the actor did
receive `amount`.

The consequence, stated at the root:

| | pre-state at `r` | published pre-root | post-state after `distributeOthers r e 7` | published post-root |
|---|---|---|---|---|
| A | `{1↦10, 2↦0, 4↦10, 5↦10}` | `H` | `{1↦17, 2↦7, 4↦17, 5↦17}` | `H₁` |
| B | `{1↦10, 4↦10, 5↦10}` | `H` (same) | `{1↦17, 4↦17, 5↦17}` | `H₂ ≠ H₁` |

Two states with the **same** published root, the **same** action, and
**different** published post-roots.  The pre-state root is therefore
not a sufficient statistic for the transition, and a verifier holding
only that root cannot decide which post-root is honest — there are two,
both correct, and the sequencer picks by holding a map the root does
not distinguish.

`setBalance s r a 0` does not erase the entry (`Kernel.lean`), so the
reachable states are ordinary ones: any whole-balance `transfer` leaves
its sender at a live zero, and `reclaimAmmReserves` sweeps to zero by
design.

**Not caught earlier** because the bulk pair is excluded from
adjudication (`FaultProofAdjudicable` is `false` on kinds 6/7,
`isAdjudicable` likewise on the L1), so no fault-proof test drove a
bulk step through a root comparison — and no LAW test needed to, since
at the law layer paying a zero-balance actor is merely a policy choice.
The defect lives exactly in the seam between the two.

**Closed** by filtering zero-valued entries out of `bulkRecipients`
(`LegalKernel/Laws/BulkBound.lean`), so the recipients are precisely
the live balance cells at `r` other than `excluded` — and "live" is
what the root observes.  `bulkRecipients_values_ne_zero` states the
resulting invariant; `mem_bulkRecipients_iff` unpacks membership once
for the sites that used to re-run `List.mem_filter` themselves.

**The precondition was broken the same way, and more sharply.**
`BulkBounded s r excluded` is `(bulkRecipients …).length ≤
maxRecipientsPerBulkAction`, and `step_impl` is `if pre then apply_impl
else id`.  Under the retired rule a live zero entry counted toward that
bound, so a state carrying 300 swept-to-zero actors sat OVER the cap
while its root-identical twin sat under it: **two root-identical states,
one of which advances and one of which does not.**  No credit has to be
wrong for that to be fatal — the honest sequencer's post-root is simply
not reachable from the root the verifier holds.  The same filter closes
it, and `faultproof-substep`'s "the PRECONDITION is root-determined too"
pins both directions with the over-the-cap negative control.

Both laws now **call** `bulkRecipients` instead of respelling the
filter inline, which is the structural half of the fix.  The list had
**four** independent spellings: `distributeOthers.apply_impl`, the
`lexlaw` `lex_impl` mirror, `Events.affectedActors`, and
`Action.stateWriteCells` (which already called `bulkRecipients`, and
was therefore *right* while the other three were wrong).  Changing one
would have made the declared cell footprint and the executed fold
disagree, which is a worse failure than the one being fixed.
`bulkRecipients_eq_law_list` pins the shared list to a concrete
traversal so a future edit surfaces rather than silently moving
consensus.

`Events.affectedActors` was the one that hid best, and it is worth
recording why: its events stayed *correct* through the defect, because
`balanceChangeEvents` re-checks `oldV != newV` downstream and silently
dropped the surplus actors.  A divergence between the helper and the
laws was therefore invisible at the event layer and would have surfaced
somewhere else entirely.  It now reads `Laws.bulkRecipients`, so the
delta filter is a second line rather than the only one, and the
bulk-law event path — **previously uncovered by any test** — has three
cases in `events-extract`, including one asserting `affectedActors` is
the recipient list key-for-key and in order.

A fifth near-spelling was removed on the way.  The dust bound's divisor
identity was stated in `Conservation.lean` over a literal copy of the
filter, because that module sits below `Laws/BulkBound.lean` and cannot
name `bulkRecipients`.  What lives there now is the general
`balanceList_sum_filter_ne_zero`, which knows nothing about which
entries a bulk law keeps; the bulk-specific corollary
`bulkRecipients_values_sum_eq_sumOthers` moved up to sit with the
definition it is about.

**This is a behaviour change.**  A holder whose balance of `r` is a
live zero no longer receives a `distributeOthers` credit.  That is the
point — the previous behaviour was not root-determined — but a
deployment relying on "an entry exists, therefore it is paid" must
mint to such actors first, exactly as the law's docstring has always
said about actors with no entry at all.

`proportionalDilute` was **already safe**: its credit is
`totalReward * kv.2 / S`, which is `0` at `kv.2 = 0`, so its
post-state was root-determined either way and the filter is a no-op
for it.  That asymmetry is the reason the shared list matters — a
per-law filter would have left `distributeOthers` broken while looking
correct from `proportionalDilute`'s side.  The dust bound survives
unchanged, via the new
`Laws.bulkRecipients_values_sum_eq_sumOthers` (zero entries
contribute nothing to a sum, so the divisor is still `sumOthers`).

Pinned by three cases in `faultproof-substep`, the third of which is a
negative control: it rebuilds the retired recipient rule and asserts
that on the SAME fixture pair it reaches **different** post-roots — so
the first two cannot pass vacuously, and the defect is exhibited rather
than described.

### C-3 — Closed: the commitment is blind to balances at multiples of the head's modulus

**Severity: critical in kind, remote in reach.**  Surfaced while
auditing C-2, and deliberately **not** fixed there, because fixing it
where it was found would have been fixing the wrong thing.

`Encoding.encodeAmount` is `cbeTagAmount :: natToBytesLE n 16` — a
fixed 16-byte body, so it truncates modulo `2^128`.  A balance that is
a *nonzero multiple of* `2^128` therefore encodes byte-for-byte as
`encodeAmount 0`, which is exactly `canonicalAbsentValue (.balance _
_)`.  `stateCellEntries` drops it, the cell has no leaf, and **the
published root cannot see the balance at all.**

Verified rather than argued (`faultproof-substep`, "OBLIGATION: the
zero filter is exact only below 2^128"):

| | pre-state at `r` | root | consequence |
|---|---|---|---|
| A | `{1↦10, 2↦2^128}` | `H` | `distributeOthers` credits actor 2; `transfer` from actor 2 has `pre = true` |
| B | `{1↦10}` | `H` (same) | actor 2 is not a recipient; `transfer` from actor 2 has `pre = false` |

**It is not bulk-specific, which is the whole point.**  The obvious
patch — add `∀ kv ∈ bulkRecipients, kv.2 < 2^128` to the bulk
preconditions — was considered and rejected.  The `transfer` row above
is the reason: a law with no connection to the recipient list forks on
the same pair, through its *precondition*, because `getBalance` reads a
value the root does not carry.  The blind spot belongs to the
**commitment**, not to `bulkRecipients`, and bounding one law would
treat a symptom while reading as if the rest were safe.

**Why widening alone does not close it.**  C-1 had already moved the
head once, `2^64` → `2^128`, on the reasoning that the entire ETH
supply is about `2^87` wei so the new ceiling was out of reach.  That
moved the ceiling without ever *establishing* it, and the defect simply
recurred one modulus up — which is how this finding came to be written
against a head that had already been "fixed".

The load-bearing gap was not the width.  It was that
`ExtendedState.CanonicalBounds.base_amt` — the hypothesis every
commitment-injectivity and terminal-step theorem carries — was
**established nowhere**: a search for it in conclusion position
returned empty.  A hypothesis nothing discharges is not a mitigation;
it is a record of what would have to be true.

**How it was closed.**  Three things together, none sufficient alone:

  * the head is `2^256`, the width of an EVM word, so no mirrored L1
    surface can hold a value it cannot carry.  The tag moved `0x01` →
    `0x06` with it, so a stale peer fails closed on an unexpected tag
    rather than reading 17 of 33 bytes and mis-parsing the rest;
  * the ceiling is **enforced**: `Laws.AmountBounded` is a precondition
    conjunct on all twelve balance-crediting sites
    (`Laws/AmountBound.lean`).  Cell-local by construction, so the L1
    verifier can evaluate it from the single cell it already opens —
    on that side it is exactly "the `uint256` sum does not wrap";
  * the ceiling is **proved unreachable**:
    `FaultProof.balancesBounded_apply_impl` makes the bound inductive
    across all twenty-five variants and
    `canonicalBounds_base_amt_of_reachable` composes it along a trace.

**Where enforcement belongs, corrected.**  An earlier draft of this
entry recommended the admission layer, "where it can cover every
value-carrying cell at once".  That was wrong on a fact: the terminal
step adjudicates `productionApplyBudget`, not the admission gate, so a
bound the gate imposes is one the fault proof never reads.  It also
had the failure mode backwards — `step_impl` is
`if pre then apply_impl else id`, so a precondition conjunct makes an
over-ceiling credit a **no-op**, which is what the L1 can reproduce; an
admission rejection is not a state transition at all.

**Residual.**  `base_amt` is one of `CanonicalBounds`' twenty-five
fields.  The others are still hypotheses, and for two distinct reasons
rather than one missing lemma — see "CanonicalBounds' remaining
fields" below.

**What was done instead of patching it:**

  * the "zero balance ⟺ absent cell" bridge is **split along the
    bound**, so a consumer takes on only what it actually needs.
    `balanceCell_absent_of_balance_zero` and
    `mem_bulkRecipients_of_cell_live` are unconditional — they
    evaluate the encoder at `0` and never invert it — and the latter is
    the *completeness* half the bulk-adjudicability work (P1) will
    consume: every live leaf at `r` other than `excluded` is a
    recipient, so a verifier enumerating live leaves enumerates exactly
    the credited actors.  Only the converse
    (`balanceCell_absent_iff_balance_zero`'s forward direction, and
    hence `exists_mem_bulkRecipients_iff_cell_live`) needs the bound,
    and it carries it as an explicit `h_amt` rather than assuming it;
  * `Laws.bulkRecipients`' docstring states the scope of its claim
    instead of asserting root-determinism unconditionally;
  * the `OBLIGATION:` case above exhibits the fork on both a bulk law
    and `transfer`, so the gap cannot be quietly forgotten and its true
    radius is on the record.

### CanonicalBounds' remaining fields — open, and two different problems

`canonicalBounds_base_amt_of_reachable` discharges the amount field.
The other twenty-four remain hypotheses, and they do **not** all
succumb to the same argument:

  * **Trace-length-bounded** — the `< 256^8` map-length fields
    (`base_outer_len`, `nonces_len`, `registry_len`, …) and the `2^64`
    value fields (`nonces_val`, `eb_val`).  Each step adds at most a
    bounded number of entries and advances a nonce by exactly one, so
    `2^64` needs on the order of `10^13` actions.  This is why those
    fields were deliberately **not** widened: the nonce and
    epoch-budget cells are the two that EVERY action writes, so 24
    extra bytes each would run against the multiproof's measured
    −48% calldata win.  The argument is stated where it can be checked
    — `FaultProof.expectsNonce_le_of_reachableIn` over the
    step-indexed `AdmissibleReachableIn` — and its conclusion is
    honestly `≤ start + n`, not an unconditional `< 2^64`, because
    nothing in the step relation bounds trace length.
  * **Payload-bounded** — the size fields (`registry_size`, `lp_size`,
    `bs_cons_size`, …).  These are bounded by what a submitter puts on
    the wire, so closing them needs an admission-layer cap on action
    field widths, which no gate currently imposes.  Unlike the amount
    ceiling, this one genuinely does belong at admission: an over-long
    public key is not a state transition whose effect the L1 must
    reproduce, it is a message the deployment should never have
    accepted.

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

The old recipe has been removed — `KnomosisStepVM.sol`,
`SolidityStepVMCommit.lean`, `stepVMHash` and the 37 theorems pinning
its per-variant arms, the corpus's `expectedStepVMCommitHex` column and
its byte-equivalence driver.  The Lean MODEL of the terminal step
(`Step.kernelStepApply`) routes through the verifier, so the game model
and the contract compute the same thing.

One operator-facing condition remains, recorded in the runbook's §0
rather than here: a deployment leaning on the fault proof must not
authorise `distributeOthers` / `proportionalDilute`, because a verifier
cannot tell a complete recipient set from a short one.

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

**Update (C-2).**  The hazard stands, but the helper no longer
re-derives the actor set: it is now
`(Laws.bulkRecipients preState r excluded).map (·.1)`, the same list
both bulk laws fold.  It had been a *fourth* independent spelling of
the recipient rule, and the audit that closed C-2 initially missed it
because its output stayed correct — `balanceChangeEvents` re-checks
`oldV != newV` downstream and silently dropped the surplus.  The
original note's reasoning ("those laws operate over `bm.toList`, which
is the pre-state actor set") is superseded: they operate over
`bulkRecipients`, a strict sub-list of the pre-state's entries, which
makes the no-new-actors conclusion hold more clearly than before.  The
bulk-law event path now has test coverage (`events-extract`); it had
none.

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

**SB.9 update — the operational gap is closed.**  The Lean
`ingest` observation stands (it remains the Lean-mirror default),
but the production pipeline now materialises deposits: the Rust
translator's opt-in `preview_ingest_materialising`
(`knomosis-l1-ingest`, `--materialise-deposits`) constructs the
bridge-signed `Deposit` / `DepositWithFee` actions from the two L1
deposit events, with a content-derived deposit id (the receipt
hash's first 8 bytes, so re-orgs/restarts re-derive the same id and
the kernel's `consumed`-set conjuncts refuse replays), a
reject-never-truncate amount range-check, and fresh-id assignment
for unregistered depositors.  See `docs/abi.md` §16.7.

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

**Status:** CLOSED — see the disposition table at the head of this
document.  The entry below is the original write-up, preserved for the
audit trail; its "Remaining: the migration itself" section describes
work that has since landed.  The head is now `2^256`
(`cbeTagAmount = 0x06`, a 32-byte body), the ceiling is enforced as a
precondition conjunct on every crediting law (`Laws.AmountBounded`,
`Laws.maxAmount = 256 ^ 32`), and it is proved unreachable rather than
assumed (`FaultProof.canonicalBounds_base_amt_of_reachable`).  C-3
below records why widening alone would have left the defect open.

Found by a later audit pass; not covered by the original review, whose
closing note ("No critical findings") is superseded by this entry.

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

---

## Close-out: the chained write algebra is retired

The declarations this document references by name — `stepWriteBundle`,
`stepPostRoot`, `foldStateCellWrites_eq_commit_of_coherent`,
`chainCoherent_canonicalCellChain`, `ChainCoherent`, `chainWrites`,
`canonicalCellChain`, `CellWriteChain` — no longer exist.  They were the
consensus surface before the deduplicating pre-root multiproof replaced
it, and they were kept past that replacement on one ground: the
multiproof's guarantee was only value-level.  `stepMultiFold_eq_commit_post`
(`FaultProof/Terminate.lean`) removed that ground, and the whole chained
surface went with it.

What the passages below say about the STEP's semantics still holds; only
the machinery that carried it has changed.  The current statements are:

  * `stepMultiFold_eq_commit_post` — the honest merged walk lands on the
    published post-root (replaces `stepPostRoot_eq_commit_productionApplyBudget`).
  * `writeSetComplete_productionApplyBudget` — the per-variant
    completeness obligation, unchanged, and now consumed by the
    multiproof through `agreeOffOpened_openedOf`.
  * `updateStateCellRoot_eq_commit_of_canonical` — the single-cell
    update, unchanged, with
    `dropKey_stateCellEntries_perm_of_agree_off` still discharging its
    hypothesis.

See `docs/planning/state_root_merkleisation_plan.md` M9e for the
retirement's scope and the two declarations reclassified against the
original list.

## Close-out: Workstream SB (batched submission + user L2 AMM)

Workstream SB rebuilt the submission pipeline around batches (one L1
record per batch `[prevEnd, end)`, a per-batch actions-root SMT, the
bisection game anchored inside one batch, the terminal step
authenticated by inclusion proof) and landed the user-signed L2 swap
(`Laws.reserveSwap`, Action 25) funded by the deposit fee-split's
seed leg.  Three audit-relevant records:

**Two pre-existing defects were found during the workstream's
research and FIXED in scope**, each with a regression test that
fails on the old code (`solidity/test/CrossCheck/BatchGame.t.sol`):

  1. **The revert path was a dead end.**  Reverted indices were
     permanently unresubmittable (the chain extended straight
     through reverted entries, and the contract docstring described
     a recovery that was impossible).  Closed by rulings R1/R3/R4:
     the `lastRevertAtBlock` stamp makes post-revert resubmissions
     readable as canonical, an overwrite of a reverted key requires
     its bond out, and `reclaimRevertedBond` returns a reverted
     undisputed record's bond.
  2. **A challenger win never reached the bridge.**  The registry's
     revert marking had zero on-chain readers — the runbook's "user
     funds protected" claim was untrue of the shipped wiring.
     Closed by ruling R6: game → `KnomosisDisputeVerifierV2.
     finaliseFromFaultProof` → `bridge.revertToPriorRoot` (the
     verifier is the bridge's second immutable
     `faultProofRollbackAuthority`), end-to-end-tested on the real
     contract quadruple.

**Recorded follow-ups (not built in SB):**

  * **On-chain signature verification at terminate.**  The batch
    leaf BINDS the 65-byte signature
    (`hash(kind ‖ uint64BE signer ‖ fields ‖ sig)`, ruling R7), so
    the terminal step authenticates the signature bytes by
    inclusion; VERIFYING the signature on-chain needs an L1
    actorId→key resolution surface that does not exist yet.
  * **The Lean game-model chain binding** (the standing audit-22
    MAJOR): `actionProof_binds_action`
    (`FaultProof/ActionsRoot.lean`) gives the authentication
    primitive a proven Lean counterpart, but `GameState` still
    carries no actions-root anchor and the Settlement theorems are
    stated over the unanchored model.  Narrowed, not closed — see
    the annotation in `22-full-codebase-sweep.md`.
  * **The L1→L2 swap-mirror ingest is deliberately unbuilt** under
    the L2-primary pool topology (deposits stopped accruing the L1
    `ammReserve*` books; the two AMM venues price independently and
    arbitrage closes divergence — `gas_pool_runbook.md` §9.6).

