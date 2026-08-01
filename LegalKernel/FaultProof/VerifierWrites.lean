-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.VerifierWrites — the write derivation an L1
verifier can perform, holding only proven cell values.

`StepWriteSets.lean` builds `stepWriteBundle es st idx` and proves its
fold lands on the published root.  That bundle's `newValue` column is
read off `productionApplyBudget es st idx` — it is the SEQUENCER's
computation, from the pre-state and the post-state.  A verifier holds
neither: it has a 32-byte pre-root and a bundle of openings some party
submitted.  Folding what it is handed is not adjudication, because the
`newValue` column would be the responder's to choose, and a responder
who can choose it can fold to any root.

So the verifier must DERIVE each written cell's new value from the
PROVEN pre-values.  This module is that derivation, and the theorems
that it agrees with the sequencer's.
`docs/planning/state_root_merkleisation_plan.md` §4 step 3 is the
specification; `docs/audits/19-findings-and-followups.md` records why
it is the largest remaining piece of the state-root swap.

**Scope: the two cells every action writes.**

  * **The nonce.**  `Action.writeCells` declares `.nonce signer` on all
    twenty-five variants and the advance is the same on every one —
    `pre + 1` — so the derivation is a single proof rather than
    twenty-five.  It is also the cell the L1 gets most conspicuously
    wrong today: the step-VM handlers read and emit BALANCE cells only,
    which `faultproof-stepvm-coherence`'s `OBLIGATION: stepVMHash
    ignores the nonce cell it must write` pins directly.
  * **The epoch budget**, as far as the SPEC.
    `productionApplyBudget_epochBudgets_eq` names the value the advance
    produces, which
    `productionApplyBudget_eq_productionApply_off_budget` deliberately
    left existential — enough to settle the other six fields'
    footprints, and silent about the one a verifier has to compute.
    The three branches are the content: the bridge actor is exempt from
    the consume, a refused consume leaves the budgets entirely alone
    (grant included), and otherwise the grant lands on the consumed
    state in that order.

Remaining, in the same shape — a `derive*CellValue` over proven
pre-values plus a `*_correct` theorem: the epoch-budget cell's byte
derivation on top of the equation above; `.balance`, which is the
per-variant part and the only part the Solidity handlers already
compute; and the registry / local-policy / bridge cells of eight
variants.

**Which decoder.**  This module decodes with `Encodable.decode`, whose
round-trip is `Encoding.nat_roundtrip`.  The L1 mirrors it with
`StepVMCoherence.decodeCellNat`, whose agreement with the CBE head is
a cross-stack concern the step-VM corpus already pins.  Splitting them
this way keeps the semantic content — "the nonce advances by one at
the signer, on every action" — provable in Lean without a
bitwise-OR-versus-sum bridge that says nothing about the kernel.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.StepWriteSets

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## The nonce cell -/

/-- **The nonce cell's post-value, from its proven pre-value alone.**

    `Option` because the input is untrusted: a verifier is handed
    whatever bytes the responder put in the bundle, and a value that is
    not a well-formed CBE `Nat` has no successor.  Returning `none`
    rather than a default is what makes the failure visible — a
    derivation that fell back to `0` would silently reset a nonce, and
    a reset nonce is a replay.

    The residual stream must be EMPTY.  A cell value is exactly one
    encoded `Nat`, so trailing bytes mean the responder appended
    something, and accepting them would let two distinct bundles
    produce the same derived write. -/
def deriveNonceCellValue (preValue : ByteArray) : Option ByteArray :=
  match Encodable.decode (T := Nat) preValue.data.toList with
  | .ok (n, []) => some (ByteArray.mk (Encodable.encode (T := Nat) (n + 1)).toArray)
  | _           => none

/-- **The nonce advances by exactly one, at the signer, on every
    action.**

    The companion to `productionApplyBudget_expectsNonce_of_ne`, which
    says it moves nowhere else.  Together they are the whole footprint
    of the nonce ledger, and neither is per-variant: `kernelOnlyApply`
    advances the signer's nonce before it dispatches on the action at
    all. -/
theorem productionApplyBudget_expectsNonce_signer
    (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    Authority.expectsNonce (productionApplyBudget es st idx) st.signer =
      Authority.expectsNonce es st.signer + 1 := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  have h_n : (productionApplyBudget es st idx).nonces
      = { next := es.nonces.next.insert st.signer
            (Authority.expectsNonce es st.signer + 1) } := by
    rw [h]
    show (Disputes.kernelOnlyApply es (signedActionEntry st)).nonces = _
    exact kernelOnlyApply_nonces es st
  show (productionApplyBudget es st idx).nonces.next[st.signer]?.getD 0 = _
  rw [h_n]
  show (es.nonces.next.insert st.signer _)[st.signer]?.getD 0 = _
  rw [LegalKernel.RBMap.find?_insert_self _ st.signer _]
  rfl

/-- The nonce cell's bytes decode back to the nonce they encode.

    Conditional on the `2^64` bound the CBE head carries: the encoder
    writes eight little-endian bytes, so a nonce at or above `2^64`
    would encode its low bits and decode to a different number.  No
    reachable nonce approaches it — one increment per admitted action —
    but the statement does not get to assume that, so the bound is a
    hypothesis rather than a comment. -/
theorem decode_nonceCell (es : ExtendedState) (a : ActorId)
    (h : Authority.expectsNonce es a < 256 ^ 8) :
    Encodable.decode (T := Nat) (getCellValue es (.nonce a)).data.toList
      = .ok (Authority.expectsNonce es a, []) := by
  show Encodable.decode (T := Nat)
    (ByteArray.mk (Encodable.encode
      (T := Nat) (Authority.expectsNonce es a)).toArray).data.toList = _
  have h_list : (ByteArray.mk (Encodable.encode
      (T := Nat) (Authority.expectsNonce es a)).toArray).data.toList
      = Encodable.encode (T := Nat) (Authority.expectsNonce es a) := by
    simp
  rw [h_list]
  have h_app : Encodable.encode (T := Nat) (Authority.expectsNonce es a)
      = Encodable.encode (T := Nat) (Authority.expectsNonce es a) ++ [] :=
    (List.append_nil _).symm
  rw [h_app]
  exact Encoding.nat_roundtrip _ [] h

/-- **The verifier's nonce write is the sequencer's nonce write.**

    This is §4 step 3's statement for the one cell every action writes:
    what an L1 derives from the cell's PROVEN pre-value equals what
    `productionApplyBudget` puts there — with no access to the
    post-state, and no dependence on the action beyond the signer.

    Composed with `stepPostRoot_eq_commit_productionApplyBudget`, it is
    the piece that carries the fold's guarantee across to a party
    holding only a root. -/
theorem deriveNonceCellValue_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h : Authority.expectsNonce es st.signer < 256 ^ 8) :
    deriveNonceCellValue (getCellValue es (.nonce st.signer))
      = some (getCellValue (productionApplyBudget es st idx) (.nonce st.signer)) := by
  unfold deriveNonceCellValue
  rw [decode_nonceCell es st.signer h]
  show some (ByteArray.mk (Encodable.encode
    (T := Nat) (Authority.expectsNonce es st.signer + 1)).toArray) = _
  rw [← productionApplyBudget_expectsNonce_signer es st idx]
  rfl

/-! ## The epoch-budget cell

The second cell every action writes.  Unlike the nonce it is not a
single arithmetic step — the advance is consume-then-grant against the
deployment's policy — but it is still action-INdependent in shape, so
the spec is one equation rather than twenty-five.
-/

/-- **The epoch budgets after the production advance, concretely.**

    `productionApplyBudget_eq_productionApply_off_budget` says the
    budget leg differs from `productionApply` in this field and nothing
    else, existentially — enough to settle the OTHER six fields'
    footprints, and deliberately silent about which value this one
    takes.  A verifier needs the value.

    Three branches, and each is a real case rather than bookkeeping:
    the bridge actor is exempt from the consume (it pays no budget, so
    a bridge-credited deposit cannot be starved); a refused consume
    leaves the budgets ENTIRELY alone, including the grant, so a step
    the actor could not afford grants nothing; and otherwise the grant
    lands on the consumed state, in that order — a grant applied to the
    pre-consume budgets would let a top-up pay for itself.

    This is the equation the L1 handlers mirror, and the reason the
    epoch-budget cell cannot be derived from the signer's budget alone:
    the branch is selected by the `.budgetPolicy` cell, which is why
    that cell exists in the cell space at all. -/
theorem productionApplyBudget_epochBudgets_eq
    (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    (productionApplyBudget es st idx).epochBudgets =
      (match es.budgetPolicy with
       | .bounded freeTier actionCost currentEpoch =>
         if st.signer = Bridge.bridgeActor then
           budgetGrant st.signer st.action freeTier currentEpoch es.epochBudgets
         else
           match EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
                   freeTier (actionCost + refundConsumeExtra st.action) with
           | none      => es.epochBudgets
           | some ebs' => budgetGrant st.signer st.action freeTier currentEpoch ebs') := by
  unfold productionApplyBudget
  cases h_pol : es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    simp only []
    by_cases h : st.signer = Bridge.bridgeActor
    · simp only [if_pos h]
    · simp only [if_neg h]
      cases hc : EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
                   freeTier (actionCost + refundConsumeExtra st.action) with
      | none      =>
        show (productionApply es st idx).epochBudgets = _
        unfold productionApply
        show (Disputes.kernelOnlyApply es (signedActionEntry st)).epochBudgets = _
        rw [kernelOnlyApply_epochBudgets es st]
      | some ebs' => rfl

/-- A malformed pre-value derives nothing.

    The fail-closed direction, and the reason `deriveNonceCellValue`
    returns `Option`: a responder who supplies garbage in the nonce
    cell gets no derived write, so the fold cannot proceed and the step
    cannot be adjudicated in their favour on a value the verifier never
    understood. -/
theorem deriveNonceCellValue_none_of_malformed (preValue : ByteArray)
    (h : ∀ n rest, Encodable.decode (T := Nat) preValue.data.toList ≠ .ok (n, rest)) :
    deriveNonceCellValue preValue = none := by
  unfold deriveNonceCellValue
  cases h_dec : Encodable.decode (T := Nat) preValue.data.toList with
  | error _ => rfl
  | ok p => exact absurd h_dec (h p.1 p.2)

/-- A pre-value with a trailing byte derives nothing either.

    Stated separately because it is the case a "decode and ignore the
    rest" implementation would get wrong, and it is not covered by
    malformedness: `encode n ++ [0]` decodes fine and leaves a
    residual. -/
theorem deriveNonceCellValue_none_of_trailing (n : Nat) (b : UInt8)
    (rest : List UInt8) (preValue : ByteArray)
    (h : Encodable.decode (T := Nat) preValue.data.toList = .ok (n, b :: rest)) :
    deriveNonceCellValue preValue = none := by
  unfold deriveNonceCellValue
  rw [h]

end FaultProof
end LegalKernel
