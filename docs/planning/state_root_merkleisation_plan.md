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

Three prerequisites landed and are green.  None of them changed a
wire format; all three were additive on purpose, so the swap that
follows is the first step that breaks compatibility.

| Piece | Where | What it gives |
|---|---|---|
| Complete cell space | `FaultProof/Cell.lean` tags 0–16, `FaultProof/Verify.lean` | Every one of `ExtendedState`'s seven fields is now readable through some `CellTag`.  Before this, `ammDisabled`, `epochBudgets`, `budgetPolicy` and the AMM/BOLD scalars were inside the published root with no tag, so no cell proof could speak about them. |
| On-chain key derivation | `FaultProof/KeyDerivation.lean` `smtCellKey`, `StepVMMerkle.deriveCellSmtKey` | The SMT key is derived from `(kind, keyA, keyB)` rather than accepted from the caller, so a proof opening cell X cannot be replayed as a proof about cell Y.  Pinned byte-for-byte across the stacks by `cell_key.json`. |
| The SMT root, additively | `FaultProof/StateCells.lean` `commitExtendedStateSmt` | The root over those cells exists, is covered (`stateCells_covers_every_kind`), and demonstrably binds the fields the seven-hash bound — flipping `ammDisabled`, inflating a budget, moving a balance each move it. |
| **Root injectivity** | `FaultProof/SmtInjective.lean` | §2 below, complete. |
| **Cell determination** | `FaultProof/StateCellsInjective.lean` | §2A below, complete. |
| **Cell updates** | `FaultProof/SmtInjective.lean` `smtUpdateRoot` | §2B below, complete. |

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

## 3. The swap — REMAINING

§2, §2A and §2B are in.  What is left is the consensus change
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

**Still unproved and needed for the honest-defender direction.**
`buildSmtCellProof`'s operational coherence — `smtRoot m = smtWalk
key v (buildSmtCellProof m key)` for `m[key]? = some v` — is
currently validated only by the per-fixture tests in
`Test/FaultProof/Smt.lean`, as its own docstring says.  §2B's
soundness direction does not depend on it (it is stated over *any*
verifying proofs), but a responder's canonical proof must reproduce
the root or the honest defender cannot compute the post-root the L1
will accept.  Prove it alongside §4.

## 5. Ordering

§2 → §2A → §2B → §3 → §4, and §4's corpus regeneration last.  §2,
§2A and §2B are additive and have landed on their own; §3 and §4 are
one consensus change and must not be split across commits that could
be deployed independently.

The runbook's §0 deployment blocker stays in force until §4 lands
and `verify_keccak_crossstack.sh` reports the step-VM
byte-equivalence corpus running rather than skipping.
