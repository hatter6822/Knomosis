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

Every prerequisite has landed and is green.  None of them changed a
wire format; all were additive on purpose, so the swap that follows
is the first step that breaks compatibility.

| Piece | Where | What it gives |
|---|---|---|
| Complete cell space | `FaultProof/Cell.lean` tags 0–16, `FaultProof/Verify.lean` | Every one of `ExtendedState`'s seven fields is now readable through some `CellTag`.  Before this, `ammDisabled`, `epochBudgets`, `budgetPolicy` and the AMM/BOLD scalars were inside the published root with no tag, so no cell proof could speak about them. |
| On-chain key derivation | `FaultProof/KeyDerivation.lean` `smtCellKey`, `StepVMMerkle.deriveCellSmtKey` | The SMT key is derived from `(kind, keyA, keyB)` rather than accepted from the caller, so a proof opening cell X cannot be replayed as a proof about cell Y.  Pinned byte-for-byte across the stacks by `cell_key.json`. |
| The SMT root, additively | `FaultProof/StateCells.lean` `commitExtendedStateSmt` | The root over those cells exists, is covered (`stateCells_covers_every_kind`), and demonstrably binds the fields the seven-hash bound — flipping `ammDisabled`, inflating a budget, moving a balance each move it. |
| **Root injectivity** | `FaultProof/SmtInjective.lean` | §2 below, complete. |
| **Cell determination** | `FaultProof/StateCellsInjective.lean` | §2A below, complete. |
| **Cell updates** | `FaultProof/SmtInjective.lean` `smtUpdateRoot` | §2B below, complete. |
| **Path coherence** | `FaultProof/SmtInjective.lean` `canonicalSiblings` | §2C below, complete. |

## 2. The former blocker: SMT root injectivity — **DONE**

The swap replaces a hash whose injectivity is proved
(`commitExtendedState_subcommits_extensional_eq_under_collision_free`,
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
commitExtendedStateSmt es₁ = commitExtendedStateSmt es₂ →
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

## 3. The swap — REMAINING

§2, §2A, §2B and §2C are in.  What is left is the consensus change
itself, in one commit (the C-1 amount migration is the precedent for
why it cannot be split):

1. `commitExtendedState es := commitExtendedStateSmt es`.
2. Retire `extendedStatePreimage` / `subStatePreimages` /
   `extendedStateCommitPreimages` and the ~33 theorems in
   `FaultProof/Commit.lean` stated over them, replacing the EI.8
   headline row in CLAUDE.md with
   `commitExtendedStateSmt_determines_cells` (§2A).
3. `Verify.lean`'s `verifyCellProof` witness-state form: it
   re-commits the witness state, so it keeps working unchanged —
   but it is now strictly dominated by the SMT form and should be
   marked legacy rather than left as an equal alternative.
4. Regenerate every fixture carrying a state commit.

Roughly 34 `.lean` files reference `commitExtendedState`; the dense
ones are `FaultProof/Commit.lean` (34 references),
`PerVariantCoherence.lean` (31), `Verify.lean` (22),
`StepVMCoherence.lean` (19) and the cross-stack writer
`Test/Bridge/CrossCheck/StepVM.lean` (21).

**The absent-vs-empty gap this section used to flag is closed.**
`getCellValue`'s registry and local-policy arms now route through the
CBE byte-string encoder, whose 9-byte head is present even for a
zero-length payload, so present-empty and absent are distinguishable;
`getCellValue_of_not_mem` (§2A) proves the absent reading is the
canonical one, and `faultproof-state-cells-injective` pins that a
registration with the empty key moves the root.  The swap is now
mechanical throughout.

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

  2. **The reference apply is unsettled.**  The coherence chain is
     anchored to `commitExtendedState ∘ kernelOnlyApply` (theorem
     #225, `recomputeCommitment_coherent_with_kernelOnlyApply`), and
     `kernelOnlyApply` deliberately models neither bridge nor budget
     effects — a deposit leaves `bridge.consumed` untouched there.
     The PUBLISHED state root reflects the real, bridge-aware
     advance, so the two references disagree.  Harmless while the
     comparison is dispatcher-against-dispatcher; an adjudication
     error the moment it is dispatcher-against-state-root.  §4 must
     settle which apply is authoritative *before* the handlers are
     written, because the answer changes what several of them write.

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
which is the fail-closed direction.  §2B is what makes this
well-defined: `smtUpdateRoot_verifies` gives the chaining and
`smtUpdateRoot_proof_independent` gives that the responder cannot
steer the result by choosing an opening.

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

§2 → §2A → §2B → §2C → §3 → §4, and §4's corpus regeneration last.  §2,
§2A and §2B are additive and have landed on their own; §3 and §4 are
one consensus change and must not be split across commits that could
be deployed independently.

The runbook's §0 deployment blocker stays in force until §4 lands
and `verify_keccak_crossstack.sh` reports the step-VM
byte-equivalence corpus running rather than skipping.
