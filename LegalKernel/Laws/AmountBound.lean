-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.AmountBound — the balance ceiling every crediting
law enforces.

`Encoding.encodeAmount` carries a value in a fixed-width head, so it
is lossy above that width: a balance at a nonzero multiple of the
modulus encodes byte-for-byte as `encodeAmount 0`, which *is*
`canonicalAbsentValue (.balance _ _)`.  `stateCellEntries` drops a
canonically-absent cell, so such a balance has no leaf and **the
published state root cannot see it at all**.

That is not a rounding complaint.  Two states differing only in such
a balance commit to the SAME root and reach DIFFERENT post-roots
under the same action, so the pre-state root stops being a sufficient
statistic for the transition — the premise the whole fault proof
rests on.  An honest sequencer reaching such a state would lose every
game it correctly defended.  Recorded as finding **C-3**.

The bound had been raised once before, from `2^64` to `2^128`, which
moved the ceiling without establishing it.  This module is the other
half: `maxAmount` is `2^256`, the width of an EVM word — so no
mirrored L1 surface can hold a value the head cannot — and the
ceiling is *enforced* rather than assumed, as a precondition conjunct
on every balance-increasing law.

**Why the precondition and not the admission gate.**  `step_impl` is
`if pre then apply_impl else id`, so a conjunct here makes an
over-ceiling credit a no-op rather than a rejected submission.  That
is the fail-closed direction and, more to the point, it is what
`productionApplyBudget` — the function the terminal step adjudicates
— actually evaluates.  A check in the admission gate would bind who
may submit, not what the transition does, and the fault proof does
not read the admission gate.

**Why cell-local and not `TotalSupply`-shaped.**  The L1 verifier
holds a pre-root and a bundle of openings, not a state.  It can
evaluate `getBalance s r a + amount < maxAmount` from the single
opened cell it already needs for the write derivation
(`solidity/src/lib/StepWrites.sol`); it cannot evaluate a predicate
over a whole resource's supply without opening every actor at that
resource.  A supply-shaped bound would be unenforceable exactly where
enforcement matters.

The bound composes with `Laws.BulkBound`'s recipient cap rather than
replacing it: that one bounds HOW MANY cells a bulk action writes,
this one bounds WHAT each written cell may hold.
-/

import LegalKernel.Kernel
import Lex.DSL.PreGrammar

namespace LegalKernel
namespace Laws

/-- The exclusive ceiling on any balance a law may create.

    `256 ^ 32 = 2 ^ 256` — the CBE amount head's capacity
    (`Encoding.cborAmountHeadEncode` carries 32 little-endian body
    bytes) and equally the width of an EVM word, so the L1 mirror
    (`solidity/src/lib/CBEEncode.sol`) represents exactly the same
    range with no narrowing on either side.

    Stated as `256 ^ 32` rather than `2 ^ 256` to match the form every
    `ExtendedState.CanonicalBounds` field and every encoder
    round-trip lemma is written in; they are definitionally equal and
    `Nat.pow` reassociation in a bound hypothesis is a needless
    obstacle. -/
def maxAmount : Nat := 256 ^ 32

/-- A credit of `amount` onto actor `a`'s balance at `r` stays under
    the ceiling.

    Read the arguments as "the state the credit reads", not "the
    state the action was submitted against".  The two differ for laws
    that debit before crediting — `transfer` reads the receiver from
    the POST-DEBIT state (§4.11's read-after-debit, which is what
    makes a self-transfer conserve), so its conjunct is stated over
    that intermediate state and a self-transfer is bounded by the
    sender's balance rather than by twice it.

    `@[lex_pre]` because the crediting laws with a `lexlaw` mirror
    name it in their `lex_pre` clause, and the §7.2 grammar admits a
    user predicate only when it is tagged. -/
@[lex_pre]
def AmountBounded (s : State) (r : ResourceId) (a : ActorId)
    (amount : Amount) : Prop :=
  getBalance s r a + amount < maxAmount

/-- Decidable, so it composes into a `Transition.decPre` built by
    `inferInstance` like every other precondition on this project.

    This is the §13.6-step-2 discipline: the predicate is a single
    arithmetic comparison over `Nat`, so no bespoke decision procedure
    is needed and none should be written. -/
instance AmountBounded.decidable (s : State) (r : ResourceId) (a : ActorId)
    (amount : Amount) : Decidable (AmountBounded s r a amount) := by
  unfold AmountBounded; exact inferInstance

/-- Every credit in a bulk fold stays under the ceiling.

    Takes the recipient list and the per-recipient credit as
    parameters rather than calling `Laws.bulkRecipients`: that lives
    in `Laws/BulkBound.lean`, which sits above this module, and the
    two bulk laws do not credit the same way — `distributeOthers`
    pays a flat `amount` while `proportionalDilute` pays
    `totalReward * kv.2 / S`.  A `credit` function covers both
    without this module learning either law's arithmetic.

    **Bounding against `s` is exact, not conservative.**  The fold
    writes progressively, so the naive reading is that a later
    recipient should be bounded against the partially-updated state.
    It need not be: `bulkRecipients_nodup_keys` says the recipients
    are pairwise distinct, so each write lands on a cell no other
    iteration touches and every recipient's pre-credit balance is
    still the one `s` holds.

    `@[lex_pre]` for the same reason `AmountBounded` carries it: both
    bulk laws name it in their `lex_pre` clause. -/
@[lex_pre]
def AmountBoundedAll (s : State) (r : ResourceId)
    (recipients : List (ActorId × Amount))
    (credit : ActorId × Amount → Amount) : Prop :=
  ∀ kv ∈ recipients, AmountBounded s r kv.1 (credit kv)

/-- Decidable by `List.decidableBAll` over a decidable body — so a
    bulk law's `decPre` is still `fun _ => inferInstance`. -/
instance AmountBoundedAll.decidable (s : State) (r : ResourceId)
    (recipients : List (ActorId × Amount))
    (credit : ActorId × Amount → Amount) :
    Decidable (AmountBoundedAll s r recipients credit) := by
  unfold AmountBoundedAll; exact inferInstance

/-! ### The `@[lex_pre]` tags really fire

Same check `BulkBounded` carries, for the same reason: the tag
records fully-qualified names while the Lex walker runs on surface
syntax before elaboration, so a `lex_pre` clause spelling the short
form falls through to L003 with only a warning.  CI fails on Lean
warnings, so a build failure here is the right severity — but the
warning would issue from each crediting law rather than from this
file, which is the harder place to read it.

Placed below both definitions so the check sees them; a `run_cmd`
reads the environment as it stands at that point in the file. -/

open Lean Elab Command in
run_cmd do
  for n in [`LegalKernel.Laws.AmountBounded,
            `LegalKernel.Laws.AmountBoundedAll] do
    unless LegalKernel.DSL.Lex.isLexPreTagged (← getEnv) n do
      throwError "{n} lost its @[lex_pre] tag: a crediting law's \
                  `lex_pre` clause will emit L003, and CI fails on \
                  warnings"

/-- A bulk bound, read at one recipient. -/
theorem amountBoundedAll_mem {s : State} {r : ResourceId}
    {recipients : List (ActorId × Amount)}
    {credit : ActorId × Amount → Amount} {kv : ActorId × Amount}
    (h : AmountBoundedAll s r recipients credit) (hmem : kv ∈ recipients) :
    AmountBounded s r kv.1 (credit kv) := h kv hmem

/-- The bound is exactly what the encoder needs: a bounded credit
    lands strictly under the amount head's capacity.

    Trivial by definition, and stated anyway — it is the bridge every
    `CanonicalBounds.base_amt` discharge goes through, and naming it
    keeps those proofs from unfolding `maxAmount` and reasoning about
    `256 ^ 32` directly. -/
theorem amountBounded_credit_lt (s : State) (r : ResourceId) (a : ActorId)
    (amount : Amount) (h : AmountBounded s r a amount) :
    getBalance s r a + amount < 256 ^ 32 := h

/-- A bounded credit leaves the CREDITED actor under the ceiling.

    The `setBalance` form, which is what a law's `apply_impl` actually
    produces, so the discharge does not have to re-derive the
    post-state's reading. -/
theorem getBalance_setBalance_lt_of_amountBounded
    (s : State) (r : ResourceId) (a : ActorId) (amount : Amount)
    (h : AmountBounded s r a amount) :
    getBalance (setBalance s r a (getBalance s r a + amount)) r a < 256 ^ 32 := by
  rw [getBalance_setBalance_same]
  exact h

/-- Under the bound, the pre-credit balance is itself under the
    ceiling.  Needed wherever a proof has the conjunct in hand but
    wants the pre-state's bound — the induction's "the state was
    already good" half. -/
theorem amountBounded_pre_lt (s : State) (r : ResourceId) (a : ActorId)
    (amount : Amount) (h : AmountBounded s r a amount) :
    getBalance s r a < 256 ^ 32 :=
  Nat.lt_of_le_of_lt (Nat.le_add_right _ _) h

/-- A debit never breaks the ceiling: subtraction on `Nat` only
    shrinks.  The counterpart of `amountBounded_pre_lt` for the laws
    that move value out of a cell, so `burn` / `withdraw` / the debit
    leg of `transfer` need no conjunct of their own. -/
theorem sub_lt_of_lt (s : State) (r : ResourceId) (a : ActorId)
    (amount : Amount) (h : getBalance s r a < 256 ^ 32) :
    getBalance s r a - amount < 256 ^ 32 :=
  Nat.lt_of_le_of_lt (Nat.sub_le _ _) h

end Laws
end LegalKernel
