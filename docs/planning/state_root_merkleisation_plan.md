<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# State-root Merkleisation (closing B-3)

This is the implementation spec for the one remaining critical
finding: the fault-proof game's terminal step compares two different
hash constructions and therefore never adjudicates.

The defect, the blast radius, and the operator consequences are in
`docs/audits/19-findings-and-followups.md` ("Open critical: the
fault-proof commit-recipe split") and
`docs/fault_proof_runbook.md` §0.  This document is the *how*.

Everything below was read from source, not from plan documents.

---

## 1. What is already in place

Every prerequisite landed additively and green; §3 — the swap
itself — landed on top of them, and §3A closed a defect in the
shipped root that §4 would have hit on its first handler.  What
remains is §4, the step VM.

| Piece | Where | What it gives |
|---|---|---|
| Complete cell space | `FaultProof/Cell.lean` tags 0–16, `FaultProof/Verify.lean` | Every one of `ExtendedState`'s seven fields is now readable through some `CellTag`.  Before this, `ammDisabled`, `epochBudgets`, `budgetPolicy` and the AMM/BOLD scalars were inside the published root with no tag, so no cell proof could speak about them. |
| On-chain key derivation | `FaultProof/KeyDerivation.lean` `smtCellKey`, `StepVMMerkle.deriveCellSmtKey` | The SMT key is derived from `(kind, keyA, keyB)` rather than accepted from the caller, so a proof opening cell X cannot be replayed as a proof about cell Y.  Pinned byte-for-byte across the stacks by `cell_key.json`. |
| The SMT root | `FaultProof/StateCells.lean` `commitExtendedState` | The root over those cells is now the PUBLISHED root (§3, done).  Covered by `stateCells_covers_every_kind`, and it binds the fields the seven-hash bound — flipping `ammDisabled`, inflating a budget, moving a balance each move it. |
| **Root injectivity** | `FaultProof/SmtInjective.lean` | §2 below, complete. |
| **Cell determination** | `FaultProof/StateCellsInjective.lean` | §2A below, complete. |
| **Cell updates** | `FaultProof/SmtInjective.lean` `smtUpdateRoot` | §2B below, complete. |
| **Path coherence** | `FaultProof/SmtInjective.lean` `canonicalSiblings` | §2C below, complete. |
| **Cell openings** | `FaultProof/StateCellsInjective.lean` `verifyStateCellProof` | §3A below, complete — including absent cells, which the root as first shipped could not open at all. |

## 2. The former blocker: SMT root injectivity — **DONE**

The swap replaced a hash whose injectivity is proved
(`commitExtendedStateConcat_subcommits_extensional_eq_under_collision_free`,
via the `extendedStateCommitPreimages` decomposition) with one whose
injectivity had not been proved.  Landing the swap without the
replacement theorem would have silently downgraded the EI.8
guarantee, which is in CLAUDE.md's headline table.

`smtRootListAux_perm_of_eq_under_collision_free`
(`FaultProof/SmtInjective.lean`) is that replacement:

```
∀ d ≤ 256, ∀ e₁ e₂,
  BitsDistinctBelow d e₁ → BitsDistinctBelow d e₂ →
  EntriesEncodable e₁ → EntriesEncodable e₂ →
  CollisionFreeOn (smtRootPreimages d e₁ ++ smtRootPreimages d e₂ ++
                   emptyRootPreimages d) hashBytes →
  smtRootListAux d e₁ = smtRootListAux d e₂ →
  e₁.Perm e₂
```

The three cases the plan flagged as the real work, and how each
landed:

  1. **Leaf (`d = 0`).**  `leafHash_inj_under_collision_free` splits
     the leaf pre-image at the CBE byte-string length head, reading
     the split off `byteArray_roundtrip` (decode-with-suffix) rather
     than re-proving self-delimitation.
  2. **Empty vs non-empty.**
     `smtRootListAux_ne_emptyRootAt_under_collision_free`, by
     induction on depth.  This needed a piece that did not exist:
     `emptySubtreeHashes` is built by a tail-recursive `Array` push
     loop that exposes nothing about the relation between
     consecutive entries, so `emptySubtreeHash_succ`
     (`H_{d+1} = hash (H_d ++ H_d)`) had to be recovered from the
     builder before collision-freeness could separate an empty
     sub-tree from a populated one.  Both sides are well-formed
     32-byte hashes, so nothing else would have caught the omission.
  3. **Permutation.**  `List.Perm` on distinctly-keyed lists, as
     anticipated.

The distinct-key hypothesis is not decorative and the suite exhibits
why rather than asserting it: `smtRootListAux` at `d = 0` matches
`[(k, v)]` and falls through to `emptySubtreeHash 0` for any other
shape, so a duplicate-keyed depth-0 bucket hashes *exactly as if it
were empty*.  That is a test
(`faultproof-smt-injective`, "NEGATIVE CONTROL"), not a remark.

`BitsDistinctBelow` is stated on key *bits* because bits are all
`smtRootListAux` reads; `bitsDistinctBelow_of_keys_pairwise_ne`
bridges from distinct 32-byte keys via
`byteArray_eq_of_keyBits_eq`.

## 2A. Cell determination — **DONE**

`FaultProof/StateCellsInjective.lean` composes §2 with the cell
enumeration:

```
commitExtendedState es₁ = commitExtendedState es₂ →
  ∀ t : CellTag, getCellValue es₁ t = getCellValue es₂ t
```

under `StateCellsWellFormed` on both sides and `CollisionFreeOn` on
`stateCommitSmtPreimages`.

`ExtendedState.extEq` is deliberately **not** the target, and could
not be reached even in principle: `State.Equiv` quantifies over
outer-map membership (`r ∈ s₁.balances ↔ r ∈ s₂.balances`) while a
balance cell reads `getBalance`, which defaults an absent entry to
`0`.  A resource present with an all-zero balance map and a resource
absent entirely are `State.Equiv`-distinct and cell-indistinguishable
— correctly so, because no cell read, hence no step, separates them.
The behavioural statement is the honest one and is also exactly the
interface the step VM has.

Four supporting facts had to be proved rather than assumed:

  * `stateCellTags_nodup` — the enumeration is duplicate-free (needs
    a `Pairwise` lemma for `flatMap`, which core lacks).
  * `cellKeyPreimage_injective` — discharges the hypothesis
    `smtCellKey_injective_under_collision_free` had been taking.
    `natToBytes32BE` is now *defined* as `Bridge.encodeUint256BE`
    rather than re-spelled — they were byte-identical duplicates, and
    collapsing them means the bounded injectivity proved for one
    covers both with no drift possible.
  * `getCellValue_of_not_mem` — an unenumerated cell reads
    `canonicalAbsentValue`, which is what lets the theorem conclude
    for tags live in neither state.
  * `CellTag.KeyBounded` — the `2^256` word the key layout gives
    `DepositId` / `WithdrawalId`, which are `Nat`.

## 2B. Cell updates — **DONE**

`smtUpdateRoot key newValue proof` is the post-root after writing one
cell: the same walk with a new leaf.  Two theorems make it usable in
adjudication:

  * `smtUpdateRoot_verifies` — the same opening verifies the new
    value against the updated root.  This is what lets a multi-write
    step chain openings, each against the root the previous write
    produced.
  * `smtUpdateRoot_proof_independent` — **the post-root does not
    depend on which verifying proof was supplied.**  Without it a
    responder facing a losing terminal step could shop among openings
    for one whose update lands on the root it needs.  Needed a
    strengthening of `walk_leaf_inj_under_collision_free`, which
    establishes the per-level sibling equality on the way and then
    discards it; `walk_inj_under_collision_free` keeps it.

## 2C. Canonical-path coherence — **DONE**

Everything above is soundness, and soundness is stated over *any*
verifying proofs — it does not care how one was built.  The honest
defender's side does care: it must be able to construct an opening
that reproduces the published root, or it cannot compute the
post-root the L1 will accept, which is the failure mode this whole
line of work exists to remove.

`canonicalSiblings_walks_to_root` proves it: walking the canonical
sibling path back from a key's leaf reproduces the bucket's root, for
distinctly-keyed entries at any depth.  What remains is the
representation half — that `buildSmtCellProof`'s bitmask-compressed
encoding expands to that path — which is pinned by
`faultproof-smt-injective` and is bookkeeping over `setBitmaskBit`
rather than content.

## 3. The swap — **DONE**

`commitExtendedState` is the SMT root over the state's cells.  The
seven-component concatenation is retained as
`commitExtendedStateConcat` with its ~33 theorems intact — they are
true and worth keeping — but nothing publishes it.

What the swap actually cost, against the estimate above:

  * **One structural obstacle, fixed first.**  `getCellValue` lived
    in `Verify.lean`, which imports `Commit.lean`; a root built from
    `getCellValue` with the reader above it is an import cycle.
    `FaultProof/CellValue.lean` now holds the reader and writer, and
    `StateCommit` moved to `Cell.lean` so the cell layer can name its
    own output type.  Pure move, no values changed.
  * **Three broken proof sites, not thirty.**  The ~34 files that
    mention `commitExtendedState` mostly use it opaquely
    (determinism, size, equality), so they carried over untouched.
    Only the theorems that decompose the concatenation had to move:
    `Verify.lean`'s witness-uniqueness, and two test ascriptions.
  * **`verifyCellProof_witness_unique_under_collision_free` became
    `verifyCellProof_witness_cells_agree_under_collision_free`**,
    concluding per-cell agreement instead of `ExtendedState.extEq`.
    That is a strengthening in the direction that matters: a cell
    proof speaks about a cell, and what a consumer needs is that the
    cell reads the same in every state behind the root.  The
    consumer-facing corollary
    `verifyCellProof_no_value_substitution_under_collision_free`
    states it at the tag the proof claims.
  * **One fixture drifted**: `step_vm.json`, in its
    `preStateCommitHex` / `expectedPostStateCommitHex` /
    `expectedStepVMCommitHex` / `cellProofs` fields.  Everything else
    generates commits the same way on both sides and was unaffected.

**The absent-vs-empty gap this section used to flag is closed.**
`getCellValue`'s registry and local-policy arms route through the
CBE byte-string encoder, whose 9-byte head is present even for a
zero-length payload, so present-empty and absent are distinguishable;
`getCellValue_of_not_mem` (§2A) proves the absent reading is the
canonical one, and `faultproof-state-cells-injective` pins that a
registration with the empty key moves the root.

## 3A. Opening a cell — **DONE**

The step VM reads cells it does not hold the state for, so it needs
a verifier that works against the published root alone.  Building
that surfaced a defect in the root as first shipped, which §4 would
have hit on its very first handler.

**Absent cells were not openable.**  `stateCellTags` enumerates only
LIVE cells, so a cell with no entry has an empty sub-tree beneath its
key — not a leaf holding the canonical absent value.  An opening
built the present-way walks from `leafHash key absentValue` and
reconstructs a root the tree does not have, so it cannot verify.
Crediting a receiver who holds no balance yet is the common case,
not an edge case.

The fix is that a cell's leaf branches on absence
(`cellLeaf`), and the walk starts there
(`verifyStateCellProof`).  Completeness is proved on both sides:
`canonicalSiblings_verifies_present` and
`canonicalSiblings_verifies_absent`, the latter resting on the new
`canonicalSiblings_walks_to_root_absent` — the same induction as the
present case, factored through `bucketAt` so both fall out of one
proof.  `bucketAt_eq_nil_of_not_mem` is where the depth matters:
after 256 levels the survivors agree with the key on every bit, and
32-byte keys with equal bit-vectors are equal, so a survivor would
have to BE the key.

**And the verifier's present-vs-absent test needed the root
canonicalised.**  It decides from the claimed value, which is only
sound when "value is canonically absent" and "key is absent from the
tree" coincide.  They did not: `setBalance s r a 0` leaves a LIVE map
entry whose value is `encodeAmount 0`, reachable the moment a sender
transfers their whole balance.  `stateCellEntries` now drops
canonically-absent cells, which makes the two conditions the same
condition — and makes the root a function of the state's OBSERVABLE
content, since a balance explicitly zeroed and one never written are
already indistinguishable through `getCellValue`.

Both are pinned as tests, including the negative control that the
present-style leaf does NOT reach the root for an absent cell.

**And the canonicalisation forced the absent-cell hypothesis to be
scoped.**  `canonicalSiblings_verifies_absent` needs "no OTHER cell's
entry sits at this cell's key", and stating that over every
*enumerated* tag is unsatisfiable exactly where the canonicalisation
bites: `setBalance s r a 0` leaves `t` enumerated while its value
reads canonically absent, so the hypothesis would demand
`smtCellKey t ≠ smtCellKey t`.  The theorem would then be vacuous on
a state a single whole-balance transfer produces.  It is scoped to
the tags that CONTRIBUTE an entry, which is all the proof ever used,
and a non-vacuity test checks the scoped form actually holds on a
zeroed cell.  The enumeration hypothesis in the present branch is
likewise derived rather than assumed —
`getCellValue_of_not_mem` already gives it.

## 3B. Writing a cell — **DONE**

§2B's `smtUpdateRoot` computes *a* root from an opening and a new
value, and §2B's theorems say it is well-defined and unsteerable.
Neither says the number it computes is the root of any state.  That
gap is the whole of §4's soundness: an L1 folding proven writes into
a pre-root would otherwise be computing an arbitrary hash, and an
honest sequencer's published root would not match it.

The missing statement is about *two* entry lists rather than one, and
it holds because the canonical sibling path never looks at the key's
own entry — at every level the sibling is the root of the half the key
does NOT descend into.  So two lists that agree off the key share the
path, and the entire difference is concentrated in the leaf:

  * `canonicalSiblings_eq_of_dropKey_eq` — the path is a function of
    the entries away from the key.
  * `smtRootListAux_update_single` — composing that with §3A's
    `canonicalSiblings_walks_from_bucket` gives the post-root for
    free, with no second induction.
  * `smtRootListAux_update_to_present` /
    `smtRootListAux_update_to_absent` — the two leaf branches.  Both
    are reachable in production: `reclaimAmmReserves` sweeps a
    balance to zero and `revokeLocalPolicy` clears a policy, and
    §3A's canonicalisation turns each into a key the tree drops.
  * `smtWalkFrom_proof_independent` — `smtUpdateRoot_proof_independent`
    restated over the starting leaf, because an absent cell's opening
    verifies from `emptyRootAt 0` rather than from a leaf hash.

Lifted to state cells: `updateStateCellRoot` is the per-write
primitive, `canonicalSiblings_updates_root` and
`updateStateCellRoot_eq_commit_of_canonical` say the re-walk lands on
`commitExtendedState` of the post-state, and
`updateStateCellRoot_proof_independent` says a responder cannot steer
it.  `foldStateCellWrites` is the multi-write fold — strictly ordered,
each opening re-checked against the root the previous write produced —
and `foldStateCellWrites_eq_commit_of_coherent` proves a coherent
chain lands on the last state's published root.

The representation obligation stays exactly where §2C left it:
`updateStateCellRoot_eq_commit_of_canonical` takes
`expandSiblings canon = canonicalSiblings …` as a hypothesis rather
than deriving it, because that the bitmask encoding expands to the
canonical path is pinned by `faultproof-smt-injective` rather than
proved.

Pinned by four value-level tests, including the fail-closed negative
control: a second write whose opening was built against the PRE-root
is rejected by the fold rather than folded into a wrong root.

## 4. The step VM — REMAINING

`KnomosisStepVM.executeStep` must return a value in state-root
space:

1. Verify each cell proof with
   `StepVMMerkle.verifyCellSmtProof(root, deriveCellSmtKey(...), leafPreimage, proofData)`
   — key **derived**, never taken from the `CellProof` struct —
   reverting `BadCellProof()` on false.  This replaces the current
   loop, whose only check is
   `cellProofs[i].witnessCommit != preStateCommit`, a caller-set
   struct field.

   The leaf must branch on absence, mirroring `cellLeaf` (§3A): a
   cell with no entry has an empty sub-tree beneath its key, so its
   opening walks from the canonical empty leaf.  A Solidity verifier
   that always starts from `keccak(key ‖ value)` cannot read an
   absent cell, and a step crediting a fresh actor reads one on its
   first line.
2. Extend `CellProof` with `bytes proofData` (bitmask + siblings),
   matching the shipped `SmtCellVerifier` wire format.
3. Compute the post-root by applying each write to the pre-root
   through the same opening, rather than emitting the bespoke
   per-variant hash.  The 25 `_step<Variant>` handlers change from
   "return a hash of the new values" to "return the list of
   `(cellKey, newValue)` writes"; the root update becomes shared.
4. Delete the per-entry SKIP in `test/CrossCheck/StepVM.t.sol` so
   the corpus pins the equality it was written to pin.
5. Deploy-script guard so `DeploySepolia.s.sol` /
   `DeployFaultProof.s.sol` cannot ship the unsound configuration.

**§4 is bigger than a return-type change, and the reason was not
visible from the plan's original text.**  Three things were read from
source and are now pinned as tests in `faultproof-stepvm-coherence`
(the three `OBLIGATION:` cases) so a future implementer meets them up
front rather than halfway through the rewrite:

  1. **The handlers compute balance cells only.**  `stepVMHash`'s 25
     arms and their Solidity mirrors read and emit `.balance` cells
     and nothing else — 30 `.balance` references, zero for any other
     tag.  `Action.writeCells` meanwhile declares, correctly, that
     EVERY action advances `.nonce signer`, and that `replaceKey` /
     `registerIdentity` write `.registry`, `declareLocalPolicy` /
     `revokeLocalPolicy` write `.localPolicy`, `deposit` /
     `depositWithFee` write `.bridgeConsumed`, and `withdraw` writes
     `.bridgeNextWdId`.  Today that mismatch is harmless because the
     dispatcher's output is only ever compared against another
     dispatcher output.  After the swap it means the post-root is
     wrong for *every* action, not for exotic ones: the nonce moves
     on all 25.  So each handler must become semantically complete
     against its own declaration, not merely restructured.
     The declaration layer is the good news — `Action.writeCells`
     already says which cells, so the work is per-variant value
     computation, and the values are all derivable from
     `actionFields` plus the opened pre-values (the CBE-wrapped key
     for the registry cells; `actionFields` verbatim for
     `declareLocalPolicy`, whose L1 bytes ARE the policy encoding;
     `old + 1` for the nonce and the withdrawal counter).

  2. **The reference apply is the wrong function, and this is the
     one that needs a decision rather than typing.**
     `FaultProof/Coherence.lean`'s semantic core
     `applyCellWrites_to_state` *is* `kernelOnlyApply`, explicitly —
     and `kernelOnlyApply` deliberately models neither bridge nor
     budget effects.  The runtime advances state through
     `apply_bridge_admissible_with_budget` (`Runtime/Loop.lean:220`
     and `:558`), whose bridge leg `applyActionToBridgeState` records
     the consumed deposit.  So for a deposit the fault-proof model's
     post-state and the state whose root is published are DIFFERENT
     states with different roots — pinned by the third `OBLIGATION:`
     test, which exhibits both the cell divergence and the root
     divergence side by side.

     Today nothing compares a step-VM output to a real state root, so
     the divergence is invisible.  After the swap it is an
     adjudication error on every bridge action: an honest sequencer's
     published root would not match what the game computes.  The fix
     is to re-anchor the fault-proof chain on the production stepper
     rather than on the dispute pipeline's analytical replay.
     `FaultProof/ProductionApply.lean` supplies what that needs.  The
     guarded stepper takes a `BridgeAdmissibleWith` witness and so is
     not a total function of `(state, action)`, which is why the
     fault-proof layer reached for `kernelOnlyApply` in the first
     place; `productionApply` is the total function the guarded one
     computes, and
     `apply_bridge_admissible_with_eq_productionApply` proves they
     agree wherever the guarded form is defined.
     `productionApply_eq_kernelOnlyApply_of_non_bridge` and
     `productionApply_marks_deposit_consumed` bound the difference
     from both sides — the two cores agree off the bridge path and
     differ exactly by the consumed-deposit record on it.

     The budget leg is covered too: `apply_bridge_admissible_with_budget`
     returns `Option` because five admission gates can refuse, so its
     total form splits into the computation
     (`productionApplyBudget`) and the gate (`budgetGateAdmits`),
     recomposed by `apply_bridge_admissible_with_budget_eq`.  The
     split is the right shape for a step VM, which needs what the
     advance produced rather than whether admission would have
     allowed it — by the time a game reaches a single step,
     admission already happened on L2 and the dispute is over what
     the state became.

     What remains for §4 is repointing `Coherence.lean`'s
     `applyCellWrites_to_state` at `productionApplyBudget` and
     restating the ~33 `PerVariantCoherence.lean` theorems against
     it.

  3. **Bulk actions need the sub-step machinery.**
     `distributeOthers` and `proportionalDilute` touch every
     non-excluded actor's balance in a resource — unboundedly many
     cells, which no `O(log N)` opening bundle can carry.
     `Action.writeCells` already declines to enumerate them and
     defers to `Action.subSteps`; §4 must route those two variants
     through `FaultProof/SubStep.lean` rather than through the
     single-step path.

**Proof ordering within step 3.**  Openings become stale as soon as
a write lands, so the bundle must be processed strictly in array
order with proof `i` opening against `root_i` (`root_0 :=
preStateCommit`, `root_{i+1} := smtUpdateRoot key_i newValue_i
proof_i`).  Cells the step only reads carry `newValue = oldValue`,
so they leave the root alone; a duplicate entry for an
already-written cell fails verification against the updated root,
which is the fail-closed direction.  §3B is what makes this
correct rather than merely well-defined: `foldStateCellWrites` is
that fold, and `foldStateCellWrites_eq_commit_of_coherent` proves it
lands on `commitExtendedState` of the state the writes produce.  What
§4 still owes it is the per-variant write list — the fold is
generic, the values are not.

**Lean and Rust move with it.**  `StepVMCoherence.stepVMHash`'s
25-arm match currently ends each arm in a `stepCommit<Variant>` hash;
each arm instead yields its `(CellTag, newValue)` writes and a shared
fold applies them, which retires `SolidityStepVMCommit.lean` and
restates `PerVariantCoherence.lean`'s per-variant theorems.
`Observer.buildObserverCellProofs` must emit real SMT openings, and
`runtime/knomosis-faultproof-observer` mirrors the same.

**The honest-defender direction is covered.**
`canonicalSiblings_walks_to_root` (§2C) proves the substantive half
of `buildSmtCellProof`'s operational coherence: the uncompressed
sibling path along a key's route walks back to exactly the root
`smtRootListAux` computes.  The representation half — that the
shipped bitmask-compressed encoding expands to that path — is pinned
by `faultproof-smt-injective` rather than proved, and is bookkeeping
over `setBitmaskBit` rather than content.

## 5. Ordering

§2 → §2A → §2B → §2C → §3 → §3A → §3B → §4, and §4's corpus
regeneration last.  §2, §2A, §2B and §3B are additive and have landed
on their own; §3 / §3A and §4 are one consensus change and must not be
split across releases that could be deployed independently.

The runbook's §0 deployment blocker stays in force until §4 lands
and `verify_keccak_crossstack.sh` reports the step-VM
byte-equivalence corpus running rather than skipping.
