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
  * **The epoch budget**, for every actor, spec and bytes.
    `productionApplyBudget_epochBudgets_eq` names the value the advance
    produces — which
    `productionApplyBudget_eq_productionApply_off_budget` deliberately
    left existential, enough to settle the other six fields' footprints
    and silent about the one a verifier has to compute.  Its three
    branches are the content: the bridge actor is exempt from the
    consume, a refused consume leaves the budgets entirely alone (grant
    included), and otherwise the grant lands on the consumed state in
    that order.

    `deriveEpochBudget` reads that pointwise and
    `deriveEpochBudgetCellValue` wraps it in the cells' codecs.  The
    branch structure is why this cannot collapse into "top up the
    signer": the consume is checked against the SIGNER's budget but
    gates the write to EVERY actor, so a derivation looking only at the
    target's own cell would credit a grant recipient on a step the
    signer could not afford.  It also takes THREE cells — the
    deployment's `.budgetPolicy` selects the branch, which is why that
    cell exists in the cell space at all.

Remaining, in the same shape — a `derive*CellValue` over proven
pre-values plus a `*_correct` theorem: `.balance`, which is the
per-variant part and the only part the Solidity handlers already
compute; and the registry / local-policy / bridge cells of the eight
variants that write them.

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

/-- **The grant's effect on ONE actor's budget.**

    `budgetGrant` is a map operation; a verifier holds cells.  This is
    the same function read pointwise: for the three granting variants,
    the target is topped up when it IS the grant recipient, and left
    alone otherwise.

    The recipient differs per variant — `depositWithFee` grants to the
    deposit's recipient, `topUpActionBudget` to the SIGNER, and
    `topUpActionBudgetFor` to the named recipient — which is why this
    cannot collapse into "top up the signer". -/
def applyGrantAt (action : Action) (signer : ActorId)
    (freeTier currentEpoch : Nat) (target : ActorId)
    (pre : ActorBudget) : ActorBudget :=
  match action with
  | .depositWithFee _ recipient _ _ _ g _ =>
      if target = recipient then pre.topUp currentEpoch freeTier g else pre
  | .topUpActionBudget _ _ inc _ =>
      if target = signer then pre.topUp currentEpoch freeTier inc else pre
  | .topUpActionBudgetFor recipient _ _ inc _ =>
      if target = recipient then pre.topUp currentEpoch freeTier inc else pre
  | _ => pre

/-- `budgetGrant` read at one actor IS `applyGrantAt`. -/
theorem budgetGrant_getD_eq_applyGrantAt (signer : ActorId) (action : Action)
    (freeTier currentEpoch : Nat) (ebs : EpochBudgetState) (a : ActorId) :
    (budgetGrant signer action freeTier currentEpoch ebs)[a]?.getD ActorBudget.empty
      = applyGrantAt action signer freeTier currentEpoch a
          (ebs[a]?.getD ActorBudget.empty) := by
  unfold budgetGrant applyGrantAt EpochBudgetState.topUp
  cases hact : action with
  | depositWithFee r recipient poolActor ua pa bg d =>
    by_cases h : a = recipient
    · subst h
      rw [LegalKernel.RBMap.find?_insert_self _ a _]
      simp
    · rw [LegalKernel.RBMap.find?_insert_other _ recipient a _ (fun he => h he.symm)]
      simp [h]
  | topUpActionBudget gr ga bi pa =>
    by_cases h : a = signer
    · subst h
      rw [LegalKernel.RBMap.find?_insert_self _ a _]
      simp
    · rw [LegalKernel.RBMap.find?_insert_other _ signer a _ (fun he => h he.symm)]
      simp [h]
  | topUpActionBudgetFor recipient gr ga bi pa =>
    by_cases h : a = recipient
    · subst h
      rw [LegalKernel.RBMap.find?_insert_self _ a _]
      simp
    · rw [LegalKernel.RBMap.find?_insert_other _ recipient a _ (fun he => h he.symm)]
      simp [h]
  | _ => rfl

/-- **One actor's epoch budget after the production advance, derived
    from proven cells alone.**

    The three inputs are all cells a bundle carries: the deployment's
    `.budgetPolicy`, the SIGNER's `.epochBudget` (which selects the
    branch — a refused consume freezes every actor's budget, not just
    the signer's), and the target's own.

    The signer's cell is in the write set of every action, so it is
    always available; that is not an accident of the declaration but
    the reason the derivation is possible at all. -/
def deriveEpochBudget (policy : Authority.BudgetPolicy)
    (signerPre targetPre : ActorBudget)
    (action : Action) (signer target : ActorId) : ActorBudget :=
  match policy with
  | .bounded freeTier actionCost currentEpoch =>
    if signer = Bridge.bridgeActor then
      applyGrantAt action signer freeTier currentEpoch target targetPre
    else
      match signerPre.consume currentEpoch freeTier
              (actionCost + refundConsumeExtra action) with
      | none     => targetPre
      | some sb' =>
        let afterConsume := if target = signer then sb' else targetPre
        applyGrantAt action signer freeTier currentEpoch target afterConsume

/-- **The verifier's epoch-budget value is the sequencer's.**

    §4 step 3's statement for the second cell every action writes, and
    the one whose branch structure an implementer is most likely to
    flatten: the consume is checked against the SIGNER's budget but
    gates the write to EVERY actor, so a derivation that looked only at
    the target's own cell would credit a grant recipient on a step the
    signer could not afford.

    Holds for every actor, not just the signer or the recipient — at an
    untouched actor both sides are the pre-value, which is the
    cell-level form of `productionApplyBudget_epochBudgets_of_ne`. -/
theorem deriveEpochBudget_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (a : ActorId) :
    deriveEpochBudget es.budgetPolicy
        (es.epochBudgets[st.signer]?.getD ActorBudget.empty)
        (es.epochBudgets[a]?.getD ActorBudget.empty)
        st.action st.signer a
      = (productionApplyBudget es st idx).epochBudgets[a]?.getD
          ActorBudget.empty := by
  rw [productionApplyBudget_epochBudgets_eq es st idx]
  unfold deriveEpochBudget
  cases h_pol : es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    simp only []
    by_cases h : st.signer = Bridge.bridgeActor
    · simp only [if_pos h]
      exact (budgetGrant_getD_eq_applyGrantAt st.signer st.action freeTier
        currentEpoch es.epochBudgets a).symm
    · simp only [if_neg h]
      -- The map-level consume is the actor-level one written back at
      -- the signer, so the two `match`es scrutinise the same value.
      have h_c : EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
            freeTier (actionCost + refundConsumeExtra st.action)
          = ((es.epochBudgets[st.signer]?.getD ActorBudget.empty).consume
              currentEpoch freeTier
              (actionCost + refundConsumeExtra st.action)).map
              (fun b' => es.epochBudgets.insert st.signer b') := by
        unfold EpochBudgetState.consume
        cases (es.epochBudgets[st.signer]?.getD ActorBudget.empty).consume
                currentEpoch freeTier
                (actionCost + refundConsumeExtra st.action) <;> rfl
      rw [h_c]
      cases hb : (es.epochBudgets[st.signer]?.getD ActorBudget.empty).consume
                   currentEpoch freeTier
                   (actionCost + refundConsumeExtra st.action) with
      | none     => rfl
      | some sb' =>
        simp only [Option.map_some]
        rw [budgetGrant_getD_eq_applyGrantAt st.signer st.action freeTier
          currentEpoch _ a]
        -- The consumed map differs from the pre-map only at the signer.
        by_cases ha : a = st.signer
        · subst ha
          rw [LegalKernel.RBMap.find?_insert_self _ st.signer _]
          simp
        · rw [LegalKernel.RBMap.find?_insert_other _ st.signer a _
            (fun he => ha he.symm)]
          simp [ha]

/-- Read an `ActorBudget` out of an epoch-budget cell's bytes.

    Two `Nat`s in sequence, and the residual must be empty for the same
    reason the nonce's must: a cell holds exactly one value, and
    accepting a tail would let two distinct bundles decode alike. -/
def decodeEpochBudgetCellValue (value : ByteArray) : Option ActorBudget :=
  match Encodable.decode (T := Nat) value.data.toList with
  | .ok (epoch, rest) =>
    match Encodable.decode (T := Nat) rest with
    | .ok (bal, []) => some { lastSeenEpoch := epoch, budgetBalance := bal }
    | _             => none
  | .error _ => none

/-- Write an `ActorBudget` back in the cell's canonical byte form. -/
def encodeEpochBudgetCellValue (b : ActorBudget) : ByteArray :=
  ByteArray.mk
    ((Encodable.encode (T := Nat) b.lastSeenEpoch) ++
     (Encodable.encode (T := Nat) b.budgetBalance)).toArray

/-- The cell's bytes decode to the budget they encode.

    Both components carry the CBE head's `2^64` bound, and both are
    hypotheses for the same reason as the nonce's: the encoder writes
    eight little-endian bytes, so a component at or above `2^64` would
    round-trip to a different number. -/
theorem decode_epochBudgetCell (es : ExtendedState) (a : ActorId)
    (h_epoch : (es.epochBudgets[a]?.getD ActorBudget.empty).lastSeenEpoch < 256 ^ 8)
    (h_bal : (es.epochBudgets[a]?.getD ActorBudget.empty).budgetBalance < 256 ^ 8) :
    decodeEpochBudgetCellValue (getCellValue es (.epochBudget a))
      = some (es.epochBudgets[a]?.getD ActorBudget.empty) := by
  unfold decodeEpochBudgetCellValue
  show (match Encodable.decode (T := Nat)
      (ByteArray.mk ((Encodable.encode
        (T := Nat) (es.epochBudgets[a]?.getD ActorBudget.empty).lastSeenEpoch) ++
       (Encodable.encode
        (T := Nat) (es.epochBudgets[a]?.getD
          ActorBudget.empty).budgetBalance)).toArray).data.toList with
    | .ok (epoch, rest) =>
      match Encodable.decode (T := Nat) rest with
      | .ok (bal, []) =>
        some ({ lastSeenEpoch := epoch, budgetBalance := bal } : ActorBudget)
      | _             => none
    | .error _ => none) = _
  have h_list : (ByteArray.mk ((Encodable.encode
      (T := Nat) (es.epochBudgets[a]?.getD ActorBudget.empty).lastSeenEpoch) ++
     (Encodable.encode
      (T := Nat) (es.epochBudgets[a]?.getD
        ActorBudget.empty).budgetBalance)).toArray).data.toList
      = (Encodable.encode
          (T := Nat) (es.epochBudgets[a]?.getD ActorBudget.empty).lastSeenEpoch) ++
        (Encodable.encode
          (T := Nat) (es.epochBudgets[a]?.getD ActorBudget.empty).budgetBalance) := by
    simp
  rw [h_list, Encoding.nat_roundtrip _ _ h_epoch]
  -- The first round-trip leaves a `match` on an `Except.ok` of a pair;
  -- it has to iota-reduce before the second one's pattern appears at
  -- all, and neither `rw` nor a lemma-only `simp` does that on its own.
  show (match Encodable.decode (T := Nat)
      (Encodable.encode (T := Nat)
        (es.epochBudgets[a]?.getD ActorBudget.empty).budgetBalance ++ []) with
    | .ok (bal, []) =>
      some ({ lastSeenEpoch :=
                (es.epochBudgets[a]?.getD ActorBudget.empty).lastSeenEpoch,
              budgetBalance := bal } : ActorBudget)
    | _ => none) = _
  rw [Encoding.nat_roundtrip _ _ h_bal]

/-- **The verifier's epoch-budget WRITE, in bytes.**

    The byte-level counterpart of `deriveEpochBudget_correct`: three
    proven cells in, one canonical cell value out, equal to what
    `productionApplyBudget` leaves at the target.

    `Option` and fail-closed throughout, like the nonce's — a
    derivation that fell back to a default budget would hand an actor a
    fresh free tier, which is minting. -/
def deriveEpochBudgetCellValue (policyValue signerValue targetValue : ByteArray)
    (action : Action) (signer target : ActorId) : Option ByteArray :=
  match Encodable.decode (T := Authority.BudgetPolicy) policyValue.data.toList with
  | .ok (policy, []) =>
    match decodeEpochBudgetCellValue signerValue,
          decodeEpochBudgetCellValue targetValue with
    | some signerPre, some targetPre =>
        some (encodeEpochBudgetCellValue
          (deriveEpochBudget policy signerPre targetPre action signer target))
    | _, _ => none
  | _ => none

/-- The budget-policy cell's bytes decode to the policy they encode.

    The bounds are the CBE head's, as everywhere; `1 ≤ actionCost` is
    the decoder's own gate (`mkBounded` clamps a zero cost to one, so a
    zero would not round-trip), and it is a real deployment property
    rather than an artefact: a zero action cost is a policy under which
    every actor has unlimited budget. -/
theorem decode_budgetPolicyCell (es : ExtendedState)
    (freeTier actionCost currentEpoch : Nat)
    (h_pol : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (h_ft : freeTier < 256 ^ 8) (h_ac : actionCost < 256 ^ 8)
    (h_ce : currentEpoch < 256 ^ 8) (h_pos : 1 ≤ actionCost) :
    Encodable.decode (T := Authority.BudgetPolicy)
        (getCellValue es .budgetPolicy).data.toList
      = .ok (es.budgetPolicy, []) := by
  show Encodable.decode (T := Authority.BudgetPolicy)
    (ByteArray.mk (Encodable.encode
      (T := Authority.BudgetPolicy) es.budgetPolicy).toArray).data.toList = _
  have h_list : (ByteArray.mk (Encodable.encode
      (T := Authority.BudgetPolicy) es.budgetPolicy).toArray).data.toList
      = Encodable.encode (T := Authority.BudgetPolicy) es.budgetPolicy := by
    simp
  rw [h_list, h_pol]
  show Encoding.BudgetPolicy.decode
    (Encoding.BudgetPolicy.encode (.bounded freeTier actionCost currentEpoch)) = _
  have h_nil : Encoding.BudgetPolicy.encode
      (.bounded freeTier actionCost currentEpoch)
      = Encoding.BudgetPolicy.encode
        (.bounded freeTier actionCost currentEpoch) ++ [] :=
    (List.append_nil _).symm
  rw [h_nil, Encoding.budgetPolicy_bounded_roundtrip _ _ _ [] h_ft h_ac h_ce h_pos]

/-- **The verifier's epoch-budget write is the sequencer's, in bytes.**

    `deriveEpochBudget_correct` composed with the three cells' codecs:
    what an L1 derives from the proven `.budgetPolicy`, the proven
    `.epochBudget signer` and the target's own cell is byte-for-byte
    what `productionApplyBudget` leaves at the target.

    The hypotheses are all CBE-head bounds plus the decoder's
    `1 ≤ actionCost` gate — deployment facts, not assumptions about the
    action or the party. -/
theorem deriveEpochBudgetCellValue_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (a : ActorId)
    (freeTier actionCost currentEpoch : Nat)
    (h_pol : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (h_ft : freeTier < 256 ^ 8) (h_ac : actionCost < 256 ^ 8)
    (h_ce : currentEpoch < 256 ^ 8) (h_pos : 1 ≤ actionCost)
    (h_se : (es.epochBudgets[st.signer]?.getD ActorBudget.empty).lastSeenEpoch
              < 256 ^ 8)
    (h_sb : (es.epochBudgets[st.signer]?.getD ActorBudget.empty).budgetBalance
              < 256 ^ 8)
    (h_te : (es.epochBudgets[a]?.getD ActorBudget.empty).lastSeenEpoch < 256 ^ 8)
    (h_tb : (es.epochBudgets[a]?.getD ActorBudget.empty).budgetBalance < 256 ^ 8) :
    deriveEpochBudgetCellValue
        (getCellValue es .budgetPolicy)
        (getCellValue es (.epochBudget st.signer))
        (getCellValue es (.epochBudget a))
        st.action st.signer a
      = some (getCellValue (productionApplyBudget es st idx) (.epochBudget a)) := by
  unfold deriveEpochBudgetCellValue
  rw [decode_budgetPolicyCell es freeTier actionCost currentEpoch h_pol
        h_ft h_ac h_ce h_pos,
      decode_epochBudgetCell es st.signer h_se h_sb,
      decode_epochBudgetCell es a h_te h_tb]
  show some (encodeEpochBudgetCellValue
    (deriveEpochBudget es.budgetPolicy _ _ st.action st.signer a)) = _
  rw [deriveEpochBudget_correct es st idx a]
  rfl

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
