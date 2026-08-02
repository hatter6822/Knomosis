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

   **The primitives step 1 and 3 need are in** (`StepVMMerkle`):
   `updateCellRoot` re-walks an opening from a new leaf, and
   `cellLeafHash` supplies the absence branch.  `SmtCellVerifier`
   gained `recomputeRootFromLeaf`, with the pinned preimage path
   rewritten as a wrapper over it so the two walks are the same code
   and the leaf entry point inherits `smt_cell_proof.json`'s
   cross-stack pin.  The placeholder `updateCommitment` (which
   discarded its root and siblings and returned `keccak256(newValue)`)
   and the unreachable `verifyCellProofWitness` /
   `verifyCellMerkleProof` are deleted.  All additive — `executeStep`
   is unchanged, so the flip is still one atomic change.
3. Compute the post-root by applying each write to the pre-root
   through the same opening, rather than emitting the bespoke
   per-variant hash.  The 25 `_step<Variant>` handlers change from
   "return a hash of the new values" to "return the list of
   `(cellKey, newValue)` writes"; the root update becomes shared.

   **The `newValue` column is the work, and §4A does not supply it.**
   Read the signatures: `stepWriteBundle es st idx` and
   `stepPostRoot es st idx` both take the pre-state `es`, and build
   their write list as `stepCellWrites es (productionApplyBudget es st
   idx) …` — i.e. by consulting the POST-state.  They are the honest
   sequencer's computation, and
   `stepPostRoot_eq_commit_productionApplyBudget` says the fold of
   THAT bundle lands on the published root.  It does not say a bundle
   an arbitrary party supplies does, and it cannot: a responder free to
   choose the `newValue` column folds to a root of their choosing and
   wins every game.  The fold is sound only over a write list the
   verifier derived itself.

   So the L1 needs a **bundle-only derivation**: each written cell's
   new value as a function of the proven PRE-values alone, which is the
   only state it holds.  Every input is available — the cell space
   covers all seven `ExtendedState` fields, so the signer's nonce, the
   budget policy, and the signer's epoch budget are all openable cells
   — but the derivation is `productionApplyBudget` re-expressed
   cell-locally:

     * `.nonce signer` → `pre + 1`, uniform across all 25.
     * `.epochBudget signer` → `EpochBudgetState.consume` against the
       proven `.budgetPolicy` cell, then `budgetGrant`; uniform across
       all 25, plus `.epochBudget recipient` on the two granting
       variants.
     * `.balance r a` → the per-variant arithmetic; this is the part
       the Solidity handlers already compute, and the only part.
     * `.registry` / `.localPolicy` / `.bridgeConsumed` /
       `.bridgePending` / `.bridgeNextWdId` → the eight variants that
       write them, from the action's own fields plus the proven
       pre-value.

   Each new value must also be produced in its canonical CBE byte
   form (`CellStore.lean`'s value constructors), on-chain, or the
   re-walked leaf is not the leaf the sequencer's root observes.

   The Lean side lives in `FaultProof/VerifierWrites.lean`: one
   `derive<Cell>CellValue` per cell kind, reading proven pre-values,
   each with a `*_correct` theorem against
   `getCellValue (productionApplyBudget es st idx) …`.  Those theorems
   are what carry `stepPostRoot`'s guarantee across to a verifier
   holding no state, and they are what the Solidity handlers mirror.

   **The nonce cell is done.**  `deriveNonceCellValue` plus
   `deriveNonceCellValue_correct`, and it is the cheapest of the set
   for a structural reason worth keeping: `Action.writeCells` declares
   `.nonce signer` on all twenty-five variants and `kernelOnlyApply`
   advances it BEFORE dispatching on the action, so the derivation is
   one proof rather than twenty-five.
   `productionApplyBudget_expectsNonce_signer` is the companion to the
   existing `_of_ne` — together they are the nonce ledger's whole
   footprint.

   Two shape decisions there generalise to the rest.  The derivation
   returns `Option` and refuses a malformed pre-value rather than
   defaulting — a nonce defaulting to `0` is a replay — and it refuses
   a value with a RESIDUAL, because a cell holds exactly one encoded
   value and accepting padding would let two distinct bundles derive
   the same write.  Both refusals are theorems, and the value-level
   tests check the honest cell still derives, so the checks are
   rejecting padding rather than everything.

   It decodes with `Encodable.decode`, whose round-trip is
   `Encoding.nat_roundtrip`; the L1 mirrors it with
   `StepVMCoherence.decodeCellNat`, whose agreement is the corpus's
   job.  Splitting them keeps the semantic content provable without a
   bitwise-OR-versus-sum bridge that says nothing about the kernel.

   **The epoch-budget SPEC is done too.**
   `productionApplyBudget_epochBudgets_eq` names the value the advance
   produces — which
   `productionApplyBudget_eq_productionApply_off_budget` deliberately
   left existential, enough to settle the other six fields' footprints
   and silent about the one a verifier must compute.  The three
   branches are the content, and each is a real case: the bridge actor
   is exempt from the consume, a REFUSED consume leaves the budgets
   entirely alone (grant included, so a step the actor cannot afford
   grants nothing), and otherwise the grant lands on the consumed
   state in that order — a grant applied to the pre-consume budgets
   would let a top-up pay for itself.  The value-level test exercises
   all three, the refused branch via a policy whose free tier cannot
   cover the cost, because the happy loop alone never reaches it.

   **The epoch-budget cell is done too**, spec and bytes, for every
   actor: `deriveEpochBudget` reads the equation pointwise,
   `deriveEpochBudgetCellValue` wraps it in the three cells' codecs,
   and `deriveEpochBudgetCellValue_correct` composes them.  It takes
   THREE cells — the deployment's `.budgetPolicy` selects the branch,
   the SIGNER's budget decides whether the consume succeeds, and the
   target's own supplies the value — which is what a derivation
   looking only at the target's cell would get wrong: it would credit
   a grant recipient on a step the signer could not afford.  The
   `topUpActionBudgetFor` case, where the grant recipient and the
   signer differ, is exercised at both targets, and the refused-consume
   branch is exercised through a policy whose free tier cannot cover
   the cost.

   **The balance cells are done**, for all twelve variants that write
   one.  Two things every derivation does that the L1 handlers do not,
   and both are the difference between computing and adjudicating:

     * **The precondition is EVALUATED, not asserted.**  `step_impl` is
       `if pre then apply_impl else id`, so a failing precondition
       advances no balance and the cells keep their pre-values.  This
       is where §4's "a revert is not a verdict" finding gets its fix:
       the handlers revert, and a revert costs the responsible party
       the game by timeout rather than settling it.
     * **The reader is PARTIAL.**  A cell the bundle does not open is
       not a zero balance; `none` in, `none` out, so a responder cannot
       omit an opening and get a value of their choosing.

   Five variants share `deriveChainPair` — write `x`, then write `y`
   reading the already-written state — whose `x = y` case is reachable
   in every one of them (a self-transfer, a signer who IS the pool
   actor) and is exactly where reading the second cell from the
   pre-state would miscount.  `ammSwap` is the one variant touching two
   different resources, so its cells are independent; that is sound
   only because `fromResource ≠ toResource` is a precondition conjunct
   rather than an assumption, and the proof uses it as one.

   **The registry, local-policy and bridge cells are done too**, for
   the eight variants that write them — so **every cell kind a step can
   write is now derived and proved on the Lean side**.  These were the
   cheap ones because their post-values come from the ACTION's own
   fields; two are not, and both matter.  `revokeLocalPolicy`'s value
   is the canonical ABSENT marker rather than an encoded empty policy
   (`revoke` erases the entry and `getCellValue` keys off the map, so
   the two are different cell values, and the test asserts they
   differ).  `withdraw`'s counter is `pre + 1` from the proven
   `.bridgeNextWdId` cell — the same fail-closed shape as the nonce,
   because a reset counter would let a later withdrawal overwrite an
   earlier one's pending cell.

   **The on-chain CBE value encoders are in** (`src/lib/CBEEncode.sol`),
   pinned against Lean by the corpus's `cbeEncoderGoldens` column.
   They are the mirror's foundation rather than an incidental helper:
   the SMT leaf is hashed over a cell's canonical bytes, so a value
   that is numerically right and byte-wrong re-walks to a different
   root and makes the honest sequencer's root unreachable — a liveness
   failure indistinguishable from a fraudulent submission.  `CBEDecode`
   had readers and no writers, which sufficed while `executeStep` only
   READ cell values.

   Two hazards the goldens catch that inspection would not: the CBE
   head is LITTLE-endian while `actionFieldsForL1` is big-endian, so
   both orders live in the same contract; and the widths are FIXED
   rather than minimal, because a compact encoding would give two
   encodings of one number and an SMT leaf must be a function of the
   value alone.  Over-wide values revert rather than truncating, and
   the round-trip is checked against the step VM's OWN decoder — the
   corpus pins Lean-vs-Solidity, and an encoder/decoder pair wrong the
   same way would agree with each other but not with Lean.

   **The two uniform cells are mirrored** (`src/lib/StepWrites.sol`),
   pinned per-variant by the corpus's `uniformWriteGoldens` column.
   The nonce is `pre + 1`; the epoch budget is the three-branch
   consume-then-grant, and it is where a mirror is most likely to
   diverge because the branch is not local to the target — the consume
   is checked against the SIGNER's budget but gates the write to every
   actor, and the grant recipient differs per variant.  The corpus
   emits the grant triple rather than letting Solidity re-derive it,
   so a "top up the signer" shortcut (correct on twenty-two variants)
   fails in the corpus instead of in a game;
   `topUpActionBudgetFor` is exercised at BOTH the signer and the
   recipient for exactly that reason.

   **The per-variant balance derivations are mirrored too**, pinned by
   `balanceWriteGoldens`.  Each golden carries the proven pre-balances
   and Lean's derived post-values, including the three cases a
   happy-path corpus never reaches: a self-transfer (the credit reads
   the DEBITED state, so the net is zero), a failing precondition (both
   cells keep their pre-values — the case the deployed step VM REVERTS
   on), and a same-actor chain (the payer IS the pool actor).  The
   golden base state is POPULATED on two resources; over an empty one
   every probe would start from zero, the transfer would fail its
   precondition, and the goldens would agree with a mirror that did
   nothing — a vacuous golden reads as coverage.

   **The registry / local-policy / bridge cells are mirrored too**
   (`recordWriteGoldens`), so **every cell kind now agrees byte-for-byte
   across both stacks**.  Three details the goldens pin that inspection
   would not: the registry value rides the CBE byte-string encoder, so
   a present-EMPTY key stays distinguishable from an absent one (and
   registration is an admissibility gate, so those are different
   states); a revoke emits the ABSENT marker rather than an encoded
   empty policy; and the two bridge records are concatenations whose
   components use DIFFERENT heads — uint, amount and byte-string — so a
   uniform encoder would produce plausible bytes for the wrong leaf.

   §4 step 3 is therefore complete on both stacks.  What remains of §4
   is step 1 and step 3's consumer: `executeStep` verifying each
   opening against the running root and returning the fold's result
   instead of `stepVMHash`.

   **The target is now a corpus column.**  `stepPostRootGoldens`
   carries, per probe, the root Lean reaches by folding a step's proven
   writes into the pre-root — the value `executeStep` must return —
   alongside the bespoke hash it returns today.  Three assertions run
   on both stacks: the fold LANDS on `commitExtendedState` of the
   production advance (the target is the right one), it DIFFERS from
   the bespoke hash (the flip is a real change, not a relabelling), and
   it is not the PRE-root (a fold that did nothing would fail rather
   than pass).

   That last pair is the one thing the 278-entry byte-equivalence
   corpus cannot establish, and the reason is structural: that corpus
   pins Lean's `stepVMHash` against Solidity's `executeStep` — two
   implementations of the SAME recipe, agreeing on every entry, whose
   agreement says nothing about whether either equals a published root.
   Written as a measurement rather than a comment, so the day it stops
   being true is a test failure rather than a stale paragraph.

   **And the fold itself is verified cross-stack, ahead of the flip.**
   `writeBundleGoldens` publishes the ORDERED
   `(cell, pre-value, new value, opening)` list Lean folds, and
   `StepVMMerkle.applyCellWrite` re-walks it: each opening verified
   against the RUNNING root with the old leaf, then re-walked from the
   new one.  Solidity arrives at exactly `stepPostRoot`.

   That is the riskiest single piece of §4 done and measured.  The
   ordering is what makes it risky — openings go stale as soon as a
   write lands, so proof `i` opens against the root write `i-1`
   produced, not against the pre-root — and the `selfTransfer` probe is
   the case that catches a fold which got it wrong: two writes at the
   SAME cell, where verifying both against the pre-root would accept
   the bundle and reach a root no state has.  The leaf PREIMAGE is
   pinned too, rebuilt on the Solidity side from `CBEEncode.bytesValue`
   and compared against Lean's, so the construction agrees and not just
   the walk.

   What is left is therefore mechanical rather than uncertain: a
   per-variant WRITE-SET dispatch in Solidity (which cells each action
   writes, from the action plus the proven `.bridgeNextWdId`), wiring
   it to the derivations and the fold inside `executeStep`, and the
   corpus regeneration.

   **This is the largest single remaining piece**, and the plan's
   original framing of step 3 as "the root update becomes shared"
   understated it: sharing the update is the easy half.

   **Two things the derivation must settle that are design decisions,
   not proofs.**  Both are pinned as `OBLIGATION:` cases in
   `faultproof-write-sets` so they are met up front.

   a. **A bulk write set is complete but not VERIFIABLE.**
      `writeSetComplete_productionApplyBudget` covers both bulk
      variants, and that is a statement about the honest bundle.  A
      verifier holding only the pre-root checks each opening — and
      every opening in a bundle that DROPS a recipient is valid,
      because the dropped cell is simply not mentioned.  The short
      bundle folds successfully, to a root for a state where that
      recipient was never credited; a sequencer that PUBLISHES that
      root then defends it and wins, on a state the L2 never reached.
      The obligation test exhibits exactly this: drop the last write,
      the fold accepts, the root differs.

      Non-bulk variants are immune — their tag lists are functions of
      `(action, signer)` plus cells the bundle itself proves
      (`withdraw`'s pending key comes from the proven
      `.bridgeNextWdId`), so a verifier re-derives the list and
      rejects a bundle that does not match.  A bulk tag list is the
      actor set at a resource, and `smtCellKey` is a HASH of the
      cell's identity, so balance cells at one resource share no key
      prefix and no subtree argument enumerates them.

      Three ways out, and the choice is a deployment-level one:
      commit to the per-resource actor set in its own cell (every
      balance write then also updates it); put the recipient list in
      the action's own fields (the tag list becomes static, and the
      L2's admission gate — which holds the state — checks the list is
      exactly the non-excluded set); or exclude the two bulk laws from
      any deployment leaning on the fault proof.

      **DECIDED: exclude them.**  A deployment leaning on the fault
      proof must not authorise `distributeOthers` /
      `proportionalDilute`, which its `AuthorityPolicy` already
      expresses; the two laws stay available to deployments using the
      adjudicator-quorum backstop.  Chosen because it costs nothing and
      is REVERSIBLE — either alternative can be adopted later without
      undoing it — whereas the actor-set cell widens nearly every
      variant's write set and the explicit recipient list changes
      frozen `Action` indices 6/7 and their encoders.

      Recorded as `FaultProof.FaultProofAdjudicable`, a decidable
      predicate rather than a sentence in a runbook, with
      `faultProofAdjudicable_eq_false_iff` pinning it to exactly those
      two so it cannot quietly widen, and
      `writeCellsAt_eq_writeCells_of_adjudicable` /
      `writeCellsAt_withdraw_from_proven_counter` giving the positive
      property it buys: an adjudicable action's write set is a function
      of `(action, signer)` plus the proven `.bridgeNextWdId`, so a
      verifier re-derives it and rejects a mismatched bundle.

   b. **A revert is not a verdict.**  `step_impl` is `if pre then
      apply_impl else id`, so an action whose precondition fails
      advances nothing but the nonce and the budget, and `stepPostRoot`
      lands on that root correctly.  Solidity's `_stepTransfer`
      REVERTS (`InsufficientBalance`) on the same input.

      Invisible today: `Runtime.processSignedAction` appends an entry
      only when `AdmissibleWith` holds, and conjunct 5 of that
      predicate IS the transition's precondition, so no honestly
      produced log entry has a failing `pre`.  It stops being
      invisible at the flip, because a dishonest sequencer can bind an
      inadmissible action into the log-entry chain, and
      `terminateOnSingleStep` may be reached on the CHALLENGER's turn
      (the turn alternates through `respondToMidpoint`, and both
      parties influence the parity).  The responsible party then
      cannot call at all and loses by timeout.  Any input on which
      `executeStep` reverts is a weapon against whoever's turn it is.

      The flip owes one of: `executeStep` total over well-formed
      inputs, returning the pre-root when the precondition fails; or a
      terminal step either party may call.

      **DECIDED: totality.**  It is the closer mirror of `step_impl`,
      and the Lean derivation already implements it — every
      `derive*Balances` evaluates its law's precondition and returns
      the pre-values when it fails, so the Solidity mirror inherits the
      behaviour rather than having to be argued into it.  Making the
      terminal step callable by either party would ALSO be a game-model
      change, and one that interacts with the turn-based timeout
      accounting; totality is local to the step VM.
4. ~~Delete the per-entry SKIP in `test/CrossCheck/StepVM.t.sol` so
   the corpus pins the equality it was written to pin.~~ **DONE**, and
   it was three defects rather than one — see "The cross-stack corpus
   was not evidence" below.
5. Deploy-script guard so `DeploySepolia.s.sol` /
   `DeployFaultProof.s.sol` cannot ship the unsound configuration.

### The cross-stack corpus was not evidence — **FIXED**

The 278-entry step-VM corpus looked like the thing that would have
caught all of this.  It was not, for three compounding reasons, none
of them visible from a green test run.  All three are closed; the
failure mode is recorded here because it is more instructive than the
fix.

1. **It pinned bespoke-hash against bespoke-hash.**  Both sides
   computed a construction living outside state-root space, so
   agreement between them said nothing about whether either equals a
   published root.  Only the §4 flip closes this one.
2. **The Lean side bypassed the Lean dispatcher.**
   `Test/Bridge/CrossCheck/StepVM.lean` called `stepCommit<Variant>`
   directly in every builder and never invoked `stepVMHash`, so an
   offset bug in the dispatcher would have been invisible — the fixture
   carried the test's value, not the dispatcher's.  All 18 builders now
   route through the production entry point.  Result: **zero drift
   across 278 entries** — the dispatcher was correct, and the corpus
   now proves it rather than assuming it.
3. **The default lane did not run the comparison at all.**  The
   per-entry assertion skipped on `isKeccak256Linked == false`, and the
   committed corpus carried `false`, so a bare `forge test` reported
   green having compared nothing.  Fixed structurally rather than by
   convention: `writeHashDependentFixture` / `writeHashDependentGoldens`
   REFUSE to author a hash-dependent fixture on a fallback-hash build,
   and the consuming suites call `_requireKeccakLinked`, which fails
   loudly instead of skipping.

A fourth, adjacent: `StepVM.t.sol`'s 278-entry replay needs well past
foundry's ~1.07e9 default gas limit and died `EvmError: OutOfGas` under
it, so only `verify_keccak_crossstack.sh` (which passes `--gas-limit`)
could ever have run it.  `gas_limit` is now set in
`solidity/foundry.toml` `[profile.default]`.

`forge test` went from 913 passed / 12 skipped to **928 / 0 / 0**.

Corpus staleness is now detectable too: the `identifier` field existed
and was read by nothing, so a superseded corpus still parsed and every
assertion passed against the wrong contract.
`CrossCheckFramework._requireIdentifier` wires it, with a self-test in
both directions — a gate never observed to fire is indistinguishable
from an absent gate.

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
     **The declaration layer was itself incomplete — now fixed.**
     Read from
     `EpochBudgetState.consume`, which ends in `ebs.insert a b'`
     unconditionally: under a `.bounded` policy every ADMITTED action
     from a non-bridge signer rewrites the signer's `.epochBudget`
     cell.  `Action.writeCells` declares that cell for none of the 25.
     This is the budget-leg peer of the nonce gap and is worse in one
     respect — it is invisible from `kernelOnlyApply`, which has no
     budget leg at all, so no theorem anchored to the current
     reference apply could ever have surfaced it.  Pinned as the
     fourth `OBLIGATION:` case in `faultproof-stepvm-coherence`,
     including the detail that the cell moves exactly when the consume
     succeeds (which is what admission requires, so on the
     adjudication path it always moves).

     `Action.writeCells` now declares `.epochBudget signer` on all 25,
     plus `.epochBudget recipient` on `depositWithFee` and
     `topUpActionBudgetFor`, whose grants land on a recipient rather
     than the signer.  Declaring a cell a particular step leaves
     unchanged is harmless — a read-only entry carries
     `newValue = oldValue` and does not move the root — so the
     declaration is the superset it needs to be.  The obligation test
     inverted accordingly: it now asserts the cell IS declared, on
     every variant.

     The declaration layer is otherwise the good news — `Action.writeCells`
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

     **Both halves have landed.**  `applyCellWrites_to_state` IS
     `productionApplyBudget`, threaded with the step's `l2LogIndex`
     (~100 sites across 8 files), and `PerVariantCoherence.lean`'s
     theorems were restated against it.  Note the count in this plan's
     earlier text was wrong: it is 52 theorems, not ~33, and they are
     not the recipe-bound ones — those are the 36 in
     `StepVMCoherence.lean`, which move for a different reason (S7).

     Four of the 52 were FALSE rather than merely weaker and had to be
     restated rather than re-proved; the inversion of
     `applyCellWrites_to_state_preserves_bridge` into
     `applyCellWrites_to_state_bridge` is the clearest, since the old
     name asserted the bridge is preserved and the whole point of the
     repoint is that it is not.

     Measured effect on the corpus: 18 of 278 entries moved on the
     bridge leg.  None moved on the budget leg — because every fixture
     was built from `ExtendedState.empty`, whose `.bounded 0 1 0` policy
     refuses every consume, so the budget path was entirely unexercised.
     Fixtures now use a `fixtureBase` with `.bounded 100 1 1`; 170
     entries moved and all 278 now have a post-root differing from
     their pre-root.

  3. **The fold's off-cell hypothesis — DISCHARGED (§3C).**
     `foldStateCellWrites_eq_commit_of_coherent` asks each link
     whether the two states' entry lists agree away from the written
     cell.  Nothing discharged that, and every per-variant coherence
     proof consumes it, so it was the one obligation that had to land
     before any handler work.  It has:
     `dropKey_stateCellEntries_perm_of_agree_off` takes the statement
     a caller can actually establish — the two states agree at every
     cell *value* except one — and produces the entry-list fact.

     The route is by permutation, which sidesteps `Std.TreeMap`
     ordering entirely: composing `stateCellEntries_spec` with
     `getCellValue_of_not_mem` characterises membership without
     mentioning the tag enumeration at all, and duplicate-freedom
     comes free from `BitsDistinctBelow`.  The update theorems were
     weakened from list equality to `Perm` to consume it, which cost
     `smtRootListAux_perm` and `canonicalSiblings_perm` (both
     straightforward) plus `perm_of_nodup_of_mem_iff`, absent from
     core.

     Worth recording: the off-cell lists are in fact literally
     *equal* on the shapes this is applied to — pinned as a test, not
     assumed.  The permutation is what can be proved cheaply, not a
     weaker fact that had to be settled for.

  4. **Bulk actions need the sub-step machinery.**
     `distributeOthers` and `proportionalDilute` touch every
     non-excluded actor's balance in a resource — unboundedly many
     cells, which no `O(log N)` opening bundle can carry.
     `Action.writeCells` already declines to enumerate them and
     defers to `Action.subSteps`; §4 must route those two variants
     through `FaultProof/SubStep.lean` rather than through the
     single-step path.

     **The ordering hazard is resolved and the cap is deduplicated.**
     `bulkRecipients` names the recipient order once, and
     `bulkRecipients_eq_law_list` pins it against
     `Laws.distributeOthers`'s own fold list — so the state-derived
     order is consensus and the caller-supplied `bundle.proofs` order
     is not.  `maxRecipientsPerBulkAction` now has one definition
     (`SubStep.lean`); `StepVMCoherence` read from a second copy of the
     same number, which is how a DoS bound drifts.  Each sub-step's
     write set is the singleton `[.balance r recipient]` — the parent
     step owns the nonce and the budget.

     **A gap this surfaced, now closed.**  The cap truncates the
     decomposition; `Laws.distributeOthers`'s precondition was
     `amount > 0` alone, so the LAW truncated nothing, and above 256
     recipients the game could not reach the L2's post-state at all.
     `Laws.BulkBound` puts the bound in both bulk preconditions, so
     `step_impl` no-ops above it and the decomposition is complete by
     construction.  `subSteps_complete_of_pre` and
     `distributeOthers_noop_above_cap` are the two directions;
     `faultproof-substep` checks both plus the gate itself, so the
     bound cannot go vacuous unnoticed.

     Still owed: `Nodup` on the recipient list (true, since they are a
     `Std.TreeMap`'s keys, but core states that as
     `Pairwise (compare · · ≠ .eq)` over `keys` rather than as `Nodup`
     over `toList.map Prod.fst`), and the game's single-step addressing
     extended to name a sub-step index.

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
lands on `commitExtendedState` of the state the writes produce.

### 4A. The Lean side of step 3 — the write list

**The per-variant obligation is not what this plan first assumed.**
The original framing was "decompose `productionApplyBudget` into a
`setCell` chain, twenty-five times".  It does not have to be, and
`LegalKernel/FaultProof/CellWrites.lean` is why.

A step's write list is "each declared cell, set to the value the
advance gives it".  Every value in it is therefore one `getCellValue`
produced, and `getCellValue_setCell_getCellValue` — proved over all
fifteen cell kinds — says `setCell` round-trips exactly that class.
The written cells land by construction, and what is left is the cells
the declaration does NOT name:

```
WriteSetComplete pre post action signer :=
  ∀ t ∉ action.writeCellsAt pre signer,
    getCellValue post t = getCellValue pre t
```

`fold_stepCellWrites_eq_commit_post` composes that with the chain
machinery into the §4 statement: the fold of a step's writes lands on
the post-state's published root.

Three enabling results, in the order they matter:

  * `commitExtendedState_eq_of_cells_agree` — two states whose every
    cell reads the same publish the same root.  This is load-bearing,
    not a convenience, and for a sharper reason than the first draft of
    this plan gave.  `ExtendedState` EQUALITY is out of reach: the two
    paths insert the same bindings in different orders into a balanced
    search tree, and core has no pointwise lemma concluding `=`.  Core
    does supply an extensional EQUIVALENCE (`TreeMap.Equiv`, built by
    `Equiv.of_forall_constGet?_eq`, reduced to `toList` equality by
    `equiv_iff_toList_eq`), which would carry to the root — so map
    agreement is reachable in principle.  It is nonetheless the WRONG
    target: `stateCellEntries` drops canonically-absent cells, so a
    balance swept to zero and one never written are cell-identical and
    root-identical while their maps differ pointwise.
    `reclaimAmmReserves` reaches that pair, so a per-variant proof
    phrased over maps would be assuming something FALSE on a real
    action.  Pinned by `faultproof-cell-writes`.
  * `chainCoherent_canonicalCellChain` — the chain a write list induces
    is coherent, discharging all six `ChainCoherent` conjuncts once
    rather than per link per variant.  The off-cell conjunct comes from
    `CellStore`'s locality law composed with §3C's discharge lemma.
  * `getCellValue_setCell_getCellValue` — the round-trip, whose two side
    conditions are both real: `CanonicalBounds` on the source (extended
    here, since it bounded five of the seven state fields and the epoch
    budgets and budget policy had none), and the `appendOnly`
    restriction at `registry` / `bridgeConsumed` / `bridgePending`,
    where writing the absent marker is a no-op rather than an erase.

**A declaration gap this surfaced.**  `Action.writeCells` was
incomplete for `withdraw`, provably: `BridgeState.appendWithdrawal`
inserts at `bs.nextWdId`, so the created cell is keyed by the
pre-state, and a function of `(action, signer)` cannot name it.
`Action.stateWriteCells` / `Action.writeCellsAt` close that;
`writeCellsAt_eq_writeCells` proves the other twenty-four pay nothing.

**§4A is complete on the Lean side, for all twenty-five actions.**
`writeSetComplete_productionApplyBudget`
(`FaultProof/StepWriteSets.lean`) proves it with no bulk exclusion.

The bulk pair was going to route through `SubStep.lean`'s
decomposition, on the stated grounds that their footprint is
unboundedly many cells.  Neither half of that held.  `Laws.BulkBounded`
caps the recipient count in both laws' own preconditions, so above the
cap the step is a no-op; and the real obstacle was ARITY, not size —
`Action.writeCells` takes `(action, signer)` and a recipient set is a
function of the state.  `Action.stateWriteCells` already existed for
exactly that shape (`withdraw`'s pending cell is keyed by the
pre-state's `nextWdId`), so the recipients go there, enumerated as
`Laws.bulkRecipients` in the same order both laws fold.  A bulk step
therefore stays a single `executeStep` — no sub-step index in the
game's addressing, no re-run of the convergence proof — with a bundle
of at most 2 + 256 written cells, inside the contract's existing
`MAX_CELL_PROOFS_PER_STEP = 256 + 16`.

The split turned out uneven, which is the useful part: six of the seven
state fields have an action-INdependent footprint, so they are proved
once (`productionApplyBudget_eq_productionApply_off_budget` is what
makes that cheap — the budget leg's three branches differ in
`epochBudgets` and nothing else).  Only the balance footprint is
per-variant, and `Conservation.LocalTo` does not reach it: that class
is RESOURCE locality while the cell space is keyed by
`(resource, actor)`.  The footprints are stated UNCONDITIONALLY rather
than under each law's precondition — unlike the
`*_does_not_touch_other_resources` family they generalise — because
`step_impl` is `if pre then apply_impl else id` and a fault proof
adjudicates a step whose admissibility is not in evidence.

`stepWriteBundle` and `stepPostRoot` are the honest sequencer's side,
also landed: the ordered `(cell, pre-value, post-value, opening)` list
the L1 folds, and the number the fold produces.
`stepPostRoot_eq_commit_productionApplyBudget` says the fold of THAT
bundle lands on the root an honest sequencer publishes — the fold
itself never touches the post-state.  Exercised on real actions
including `withdraw` (the state-keyed `bridgePending` cell) and both
bulk variants, with a forged-value case showing the fold does not reach
the honest root.

**Read the quantifier carefully.**  This is the sequencer's side and
only the sequencer's side: `stepWriteBundle` takes `es` and derives its
`newValue` column from `productionApplyBudget es st idx`.  A verifier
holding only the pre-root and a submitted bundle has neither, so it
must derive that column itself before the fold means anything — see §4
step 3, which is where that obligation now lives.  It is not a gap in
what §4A proves; it is the next theorem, and the plan did not name it.

What is left, in order: the bundle-only write derivation on both
stacks (§4 step 3 above — the largest piece), and `executeStep`
returning the fold's result instead of `stepVMHash`.  The observer's
openings (S4) and the `proofData` wire widening (S5) are **landed**:
every production bundle is built by `buildCellProofWithOpening`, the
`CellProof` wire carries `proofData` end to end (Lean CBE codec, JSON,
Rust ABI encoder, Solidity struct with intake shape validation), and
the corpus publishes `proofDataHex` per proof.  Nothing landed so far
changes what any surface COMPUTES — the step VM still returns the
bespoke hash — so the flip remains one atomic consensus change.

S5 also closed a defect the plan had mis-scoped.  "Bind the step's
action to the stored log-entry hash chain" assumed the chain carried
the action; `KnomosisStateRootSubmission` chained
`keccak256(abi.encode(prevLogEntryHash, stateCommit))`, state roots
alone, so nothing on L1 recorded WHICH action carried root `i-1` to
root `i` and `terminateOnSingleStep` executed whatever triple it was
handed.  The chain now folds in an `actionCommit`
(`solidity/src/lib/LogChain.sol`, mirrored by
`StepVMCoherence.l1ActionCommit` and pinned per-entry by the corpus),
which is also what the Lean chain it mirrors has always done —
`Runtime.LogFile.LogEntry.hash` chains the encoded signed action.

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
over `setBitmaskBit` rather than content.  It is threaded explicitly
as `CellWriteReady.expands` wherever it is consumed, so it is visible
in every signature that depends on it rather than assumed silently.
Discharging it is a self-contained piece of `ByteArray` bit
manipulation: that folding `setBitmaskBit` over a distinct depth list
sets exactly those bits, and that `expandSiblingsAux`'s cursor tracks
`buildSmtCellProofAux`'s low-depth-first output.

## 5. Ordering

§2 → §2A → §2B → §2C → §3 → §3A → §3B → §4, and §4's corpus
regeneration last.

**Where this stands.**  Everything through §4A is landed and green:
the Lean side computes the post-root from a pre-root plus openings
(`stepPostRoot`), for all twenty-five variants, and the L1 has the two
primitives that fold needs.

S4 and S5 have landed too, in one change since the wire and the
observer's output move together: every production bundle is built by
`buildCellProofWithOpening`, `CellProof` carries `bytes proofData`
through the Lean CBE codec, the JSON emitter, the Rust conduit's ABI
encoder (head 5 → 6 words, so `terminateOnSingleStep`'s selector moved
and `method_selectors.json` regenerated) and the Solidity struct, which
shape-validates it at intake.  The corpus publishes `proofDataHex` per
proof.  Nothing consumes the opening yet — that is the flip.

**What remains is S6, and it is one coupled unit:**

  * the **bundle-only write derivation** (§4 step 3): each written
    cell's new value from the proven pre-values alone, on both stacks,
    plus the Lean theorem that it agrees with
    `stepCellWrites es (productionApplyBudget es st idx) …`.  This is
    the largest piece and the one the plan originally understated;
    without it the fold is a calculator, not an adjudicator, because
    the `newValue` column would be the responder's to choose.
  * `executeStep` verifying the openings and returning the fold's
    result, with the corpus's `expectedStepVMCommitHex` becoming
    `expectedPostStateRootHex` and the fixture `identifier` bumped.
  * `Step.kernelStepApply` and
    `TerminateBundle.buildTerminateBundle` moving onto the derived
    fold, and the retirement of `SolidityStepVMCommit.lean` +
    `stepVMHash` + the 36 recipe-bound theorems (S7).

§2, §2A, §2B, §3B, S4 and S5 are additive and have landed on their
own; §3 / §3A and S6 are one consensus change and must not be split
across releases that could be deployed independently.

The runbook's §0 deployment blocker stays in force until §4 lands
and `verify_keccak_crossstack.sh` reports the step-VM
byte-equivalence corpus running rather than skipping.
