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

## 2. The blocker: SMT root injectivity

The swap replaces a hash whose injectivity is proved
(`commitExtendedState_subcommits_extensional_eq_under_collision_free`,
via the `extendedStateCommitPreimages` decomposition) with one whose
injectivity is **not yet proved**.  Landing the swap without the
replacement theorem would silently downgrade the EI.8 guarantee,
which is in CLAUDE.md's headline table.

The statement needed:

```
theorem smtRootListAux_inj_under_collision_free
    (d : Nat) (e₁ e₂ : List (ByteArray × ByteArray))
    (h_cf  : CollisionFreeOn (smtRootPreimages d e₁ e₂) hashBytes)
    (h_wf₁ : entries are distinctly keyed, values sized)
    (h_wf₂ : …)
    (h_eq  : smtRootListAux d e₁ = smtRootListAux d e₂) :
    e₁ ~ e₂    -- equal as key→value maps
```

The building blocks exist; this is assembly, not new theory:

  * `byteArray_append_inj_left` (`Smt.lean`) — splits
    `hash(L₁ ++ R₁) = hash(L₂ ++ R₂)` into `L₁ = L₂` and `R₁ = R₂`
    once collision-freeness has undone the outer hash.  Both halves
    are 32 bytes, so the known-left-size hypothesis is discharged by
    `smtRootListAux_size`.
  * `smtStep_inj_under_collision_free` — the same shape one level
    down, already proved for the walk.
  * `smtCellProof_no_value_substitution` — the *local* version of
    the property (two verifying proofs at one key witness one
    value); the global theorem is its inductive closure.

Three cases need care, and they are where the work is:

  1. **Leaf (`d = 0`).**  `leafHash k₁ v₁ = leafHash k₂ v₂` gives
     `(k₁, v₁) = (k₂, v₂)` under collision-freeness plus
     `Encodable` injectivity on the key and value.
  2. **Empty vs non-empty.**  `emptySubtreeHash d` must differ from
     any real subtree root at the same depth, or a populated subtree
     could impersonate an empty one.  This is a collision-freeness
     consequence and needs its own lemma; it is the case most likely
     to be skipped by accident, because both sides are well-formed
     32-byte hashes.
  3. **Permutation.**  `smtRootListAux` partitions by
     `BitsKey.keyBit`, so the conclusion is equality *as a map*, not
     as a list.  Stating it as `List.Perm` on distinctly-keyed lists
     is the honest form; stating list equality would be false.

The distinct-key hypothesis is not decorative: `smtRootListAux` at
`d = 0` matches `[(k, v)]` and falls through to
`emptySubtreeHash 0` for any other shape, so two entries sharing a
key silently vanish from the root.  `smtCellKey`'s injectivity is
what discharges it for state cells, and
`faultproof-state-cells` checks it directly on the enumerated set.

## 3. The swap

Once §2 is proved, in one commit (it is a consensus change; the
C-1 amount migration is the precedent for why it cannot be split):

1. `commitExtendedState es := commitExtendedStateSmt es`.
2. Retire `extendedStatePreimage` / `subStatePreimages` /
   `extendedStateCommitPreimages` and the ~33 theorems in
   `FaultProof/Commit.lean` stated over them, replacing the EI.8
   headline with the §2 theorem composed with cell-map
   determination.
3. `Verify.lean`'s `verifyCellProof` witness-state form: it
   re-commits the witness state, so it keeps working unchanged —
   but it is now strictly dominated by the SMT form and should be
   marked legacy rather than left as an equal alternative.
4. Regenerate every fixture carrying a state commit.

**Known gap to resolve during step 2, not after.**  `getCellValue`
is not injective on some sub-states: an empty registry public key,
an empty local policy, and an absent `bridgeConsumed` entry all
read as `ByteArray.empty`, indistinguishable from absent.  The
seven-hash did not care (it hashed the encodings); a cell root
does.  Either the absent encodings must become distinguishable
(a presence byte), or the determination theorem must be stated
modulo that equivalence — and if the latter, the equivalence has to
be shown harmless for the properties the game relies on.  This is
the one place where the swap is not mechanical.

## 4. The step VM

`KnomosisStepVM.executeStep` must return a value in state-root
space:

1. Verify each cell proof with
   `StepVMMerkle.verifyCellSmtProof(preStateCommit, deriveCellSmtKey(...), leafPreimage, proofData)`
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

## 5. Ordering

§2 → §3 → §4, and §4's corpus regeneration last.  §2 is additive
and can land on its own; §3 and §4 are one consensus change and
must not be split across commits that could be deployed
independently.

The runbook's §0 deployment blocker stays in force until §4 lands
and `verify_keccak_crossstack.sh` reports the step-VM
byte-equivalence corpus running rather than skipping.
