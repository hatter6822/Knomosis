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

`StepWriteSets.lean` proves the per-variant write-set completeness its
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

  * **The balances**, for every variant that writes one — transfer,
    mint, reward, burn, deposit, withdraw, depositWithFee,
    topUpActionBudget, topUpActionBudgetFor, claimBudgetRefund,
    ammSwap, reclaimAmmReserves.  This is the per-variant part, and
    the only part the L1 handlers already compute; what they do NOT do
    is either of the two things every derivation here does:

      * **The precondition is evaluated, not asserted.**  `step_impl`
        is `if pre then apply_impl else id`, so a failing precondition
        advances no balance and the cells keep their pre-values.  The
        handlers revert instead, and a revert is not a verdict — the
        terminal step is callable only by whoever's turn it is, so any
        reverting input costs the responsible party the game by
        timeout, and the turn can land on the challenger.
      * **The reader is partial.**  A cell the bundle does not open is
        not a zero balance; `none` in, `none` out, so a responder
        cannot omit an opening and get a value of their choosing.

    Five of them share `deriveChainPair` — write `x`, then write `y`
    reading the ALREADY-WRITTEN state — whose `x = y` case is reachable
    in every one (a self-transfer, a signer who is the pool actor) and
    is where reading the second cell from the pre-state would
    miscount.  `ammSwap` is the one that touches two DIFFERENT
    resources, so its cells are independent; that is sound only
    because `fromResource ≠ toResource` is a precondition conjunct
    rather than an assumption.

  * **The registry, local-policy and bridge cells** of the eight
    variants that write them.  These are the cheap ones, and for a
    reason worth naming: their post-values come from the ACTION's own
    fields, so a verifier reads them off the logged action and needs no
    proven cell — which also makes them the cells an L1 ignoring its
    declared writes is most obviously wrong about, since the value is
    right there in the calldata.

    Two exceptions.  `revokeLocalPolicy`'s value is the canonical
    ABSENT marker, not an encoded empty policy: `revoke` ERASES the
    entry and `getCellValue` keys off the map, so "declared a policy
    with no clauses" and "declared nothing" are different cell values.
    And `withdraw`'s counter is `pre + 1` from the proven
    `.bridgeNextWdId` cell — the same fail-closed shape as the nonce,
    for the same reason: a reset counter would let a later withdrawal
    overwrite an earlier one's pending cell.

**Every cell kind a step can write is covered.**  What remains is the
Solidity mirror of these functions and the corpus column that pins the
two stacks against each other.

**Which decoder.**  This module decodes with `Encodable.decode`, whose
round-trip is `Encoding.nat_roundtrip`.  The L1 mirrors it with
`StepVMCoherence.decodeCellNat`, whose agreement with the CBE head is
a cross-stack concern the step-VM corpus already pins.  Splitting them
this way keeps the semantic content — "the nonce advances by one at
the signer, on every action" — provable in Lean without a
bitwise-OR-versus-sum bridge that says nothing about the kernel.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Frontier
import LegalKernel.FaultProof.StepVMCoherence
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

    Composed with `stepMultiFold_eq_commit_post`, it is
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

/-! ## Balance cells

The per-variant part, and the only part the L1 handlers already
compute — which is why it is also the part where the difference
between what they compute and what they OWE is easiest to miss.

Two things every balance derivation here does that the current
handlers do not.

**The precondition is evaluated, not asserted.**  `step_impl` is
`if pre then apply_impl else id`, so an action whose precondition fails
advances no balance and its cells keep their pre-values.  The handlers
REVERT instead (`InsufficientBalance`), and a revert is not a verdict:
the terminal step is callable only by whoever's turn it is, so any
reverting input costs the responsible party the game by timeout — and
the turn can land on the challenger.  Returning the pre-values is the
mirror of `step_impl` and removes the weapon.

**The reader is partial.**  A cell the bundle does not carry is not a
zero balance; it is a cell the verifier cannot see, and deriving from
it would let a responder omit an opening and get a value of their
choosing.  `none` in, `none` out.
-/

/-- What a balance derivation reads: the proven pre-value of a
    `(resource, actor)` cell, or `none` when the bundle does not open
    it. -/
abbrev BalanceReader := ResourceId → ActorId → Option Nat

/-- The reader backed by a state — what the agreement theorems
    instantiate, and what an honest sequencer's bundle presents. -/
def stateBalanceReader (es : ExtendedState) : BalanceReader :=
  fun r a => some (LegalKernel.getBalance es.base r a)

/-- **`transfer`'s balance writes, derived from proven pre-values.**

    The self-transfer branch mirrors §4.11's read-after-debit: the law
    debits the sender and then reads the receiver from the DEBITED
    state, so when the two coincide the net change is zero.  A
    derivation that debited and credited independently would move the
    root on a self-transfer, and a self-transfer is a cheap action any
    actor can submit.

    The `else` branch is the no-op: precondition false, both cells keep
    their pre-values. -/
def deriveTransferBalances (read : BalanceReader)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r sender, read r receiver with
  | some sBal, some rBal =>
    if amount > 0 ∧ amount ≤ sBal ∧
       (if sender = receiver then sBal - amount else rBal) + amount
         < Laws.maxAmount then
      if sender = receiver then
        some [((r, sender), sBal), ((r, receiver), sBal)]
      else
        some [((r, sender), sBal - amount), ((r, receiver), rBal + amount)]
    else
      some [((r, sender), sBal), ((r, receiver), rBal)]
  | _, _ => none

/-- **The verifier's transfer balances are the sequencer's.**

    The worked shape for the twelve other balance-writing variants: read
    the touched cells, evaluate the law's precondition from them, and
    branch — the advance on one side, the pre-values on the other.
    Nothing here consults the post-state. -/
theorem deriveTransferBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (h_act : st.action = .transfer r sender receiver amount) :
    deriveTransferBalances (stateBalanceReader es) r sender receiver amount
      = some [ ((r, sender), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r sender)
             , ((r, receiver), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r receiver) ] := by
  rw [productionApplyBudget_base, h_act]
  show (match some (LegalKernel.getBalance es.base r sender),
              some (LegalKernel.getBalance es.base r receiver) with
        | some sBal, some rBal =>
          if amount > 0 ∧ amount ≤ sBal ∧
             (if sender = receiver then sBal - amount else rBal) + amount
               < Laws.maxAmount then
            if sender = receiver then
              some [((r, sender), sBal), ((r, receiver), sBal)]
            else
              some [((r, sender), sBal - amount), ((r, receiver), rBal + amount)]
          else
            some [((r, sender), sBal), ((r, receiver), rBal)]
        | _, _ => none) = _
  simp only []
  -- The law's ceiling conjunct reads the receiver from the DEBITED
  -- state; the derivation branches on `sender = receiver` instead,
  -- because it holds pre-values rather than a state.  Same number.
  have h_read : LegalKernel.getBalance
        (setBalance es.base r sender
          (LegalKernel.getBalance es.base r sender - amount)) r receiver
      = (if sender = receiver then LegalKernel.getBalance es.base r sender - amount
         else LegalKernel.getBalance es.base r receiver) := by
    by_cases h : sender = receiver
    · subst h; rw [getBalance_setBalance_same, if_pos rfl]
    · rw [getBalance_setBalance_other _ r r sender receiver _ (Or.inr h), if_neg h]
  -- `Laws.transfer.pre` is `getBalance ≥ amount ∧ amount > 0 ∧ …`; the
  -- derivation orders the first two the other way, so the two guards
  -- agree only after commuting them.
  have h_iff : (amount > 0 ∧ amount ≤ LegalKernel.getBalance es.base r sender ∧
        (if sender = receiver then LegalKernel.getBalance es.base r sender - amount
         else LegalKernel.getBalance es.base r receiver) + amount < Laws.maxAmount)
      ↔ (Action.toTransition (.transfer r sender receiver amount) st.signer).pre es.base := by
    show _ ↔ (LegalKernel.getBalance es.base r sender ≥ amount ∧ amount > 0 ∧
              Laws.AmountBounded (setBalance es.base r sender
                (LegalKernel.getBalance es.base r sender - amount)) r receiver amount)
    unfold Laws.AmountBounded
    rw [h_read]
    exact ⟨fun h => ⟨h.2.1, h.1, h.2.2⟩, fun h => ⟨h.2.1, h.1, h.2.2⟩⟩
  unfold step_impl
  by_cases h_pre : amount > 0 ∧ amount ≤ LegalKernel.getBalance es.base r sender ∧
      (if sender = receiver then LegalKernel.getBalance es.base r sender - amount
       else LegalKernel.getBalance es.base r receiver) + amount < Laws.maxAmount
  · rw [if_pos h_pre, if_pos (h_iff.mp h_pre)]
    show _ = some [((r, sender), LegalKernel.getBalance
                      ((Laws.transfer r sender receiver amount).apply_impl es.base) r sender),
                   ((r, receiver), LegalKernel.getBalance
                      ((Laws.transfer r sender receiver amount).apply_impl es.base) r receiver)]
    simp only [Laws.transfer]
    by_cases h_self : sender = receiver
    · subst h_self
      rw [if_pos rfl]
      -- Debit then credit at the SAME cell: the credit reads the
      -- debited value, so the net is the pre-balance.
      rw [getBalance_setBalance_same]
      rw [getBalance_setBalance_same]
      have h_ge : amount ≤ LegalKernel.getBalance es.base r sender := h_pre.2.1
      have : LegalKernel.getBalance es.base r sender - amount + amount
          = LegalKernel.getBalance es.base r sender := Nat.sub_add_cancel h_ge
      rw [this]
    · rw [if_neg h_self]
      -- Distinct cells: the credit misses the sender, and the
      -- receiver's pre-value is read from the debited state (same
      -- value, since the debit missed it).
      rw [getBalance_setBalance_same]
      rw [getBalance_setBalance_other _ r r receiver sender _ (Or.inr (fun h => h_self h.symm))]
      rw [getBalance_setBalance_same]
      rw [getBalance_setBalance_other _ r r sender receiver _ (Or.inr h_self)]
  · rw [if_neg h_pre, if_neg (fun h => h_pre (h_iff.mpr h))]

/-- **`mint` / `reward`'s balance write.**

    Both laws are `setBalance r to (pre + amount)` under `amount > 0`,
    so they share a derivation.  Kept as one function with the variant
    named at the call site rather than two identical copies — a second
    spelling is a second place for the credit arithmetic to drift, and
    the two laws differ in classification (`IsMonotonic` vs
    conservation tier), not in cell effect. -/
def deriveCreditBalance (read : BalanceReader)
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r to with
  | some bal =>
    if amount > 0 ∧ bal + amount < Laws.maxAmount then some [((r, to), bal + amount)]
    else some [((r, to), bal)]
  | none => none

/-- **`burn`'s balance write** — a debit under a sufficiency check. -/
def deriveBurnBalance (read : BalanceReader)
    (r : ResourceId) (fromActor : ActorId) (amount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r fromActor with
  | some bal =>
    if amount > 0 ∧ amount ≤ bal then some [((r, fromActor), bal - amount)]
    else some [((r, fromActor), bal)]
  | none => none

/-- The verifier's `mint` balance is the sequencer's. -/
theorem deriveCreditBalance_correct_mint
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (h_act : st.action = .mint r to amount) :
    deriveCreditBalance (stateBalanceReader es) r to amount
      = some [((r, to), LegalKernel.getBalance
                (productionApplyBudget es st idx).base r to)] := by
  rw [productionApplyBudget_base, h_act]
  show (if amount > 0 ∧ LegalKernel.getBalance es.base r to + amount < Laws.maxAmount then
          some [((r, to), LegalKernel.getBalance es.base r to + amount)]
        else some [((r, to), LegalKernel.getBalance es.base r to)]) = _
  unfold step_impl
  by_cases h : amount > 0 ∧ LegalKernel.getBalance es.base r to + amount < Laws.maxAmount
  · rw [if_pos h, if_pos (show (Action.toTransition (.mint r to amount) st.signer).pre es.base from h)]
    show _ = some [((r, to), LegalKernel.getBalance
                      ((Laws.mint r to amount).apply_impl es.base) r to)]
    simp only [Laws.mint]
    rw [getBalance_setBalance_same]
  · rw [if_neg h, if_neg (show ¬ (Action.toTransition (.mint r to amount) st.signer).pre es.base from h)]

/-- ...and the verifier's `reward` balance likewise.  Stated separately
    because the two are different `Action` constructors even though the
    transitions coincide; a shared statement would hide a future
    divergence rather than prevent one. -/
theorem deriveCreditBalance_correct_reward
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (h_act : st.action = .reward r to amount) :
    deriveCreditBalance (stateBalanceReader es) r to amount
      = some [((r, to), LegalKernel.getBalance
                (productionApplyBudget es st idx).base r to)] := by
  rw [productionApplyBudget_base, h_act]
  show (if amount > 0 ∧ LegalKernel.getBalance es.base r to + amount < Laws.maxAmount then
          some [((r, to), LegalKernel.getBalance es.base r to + amount)]
        else some [((r, to), LegalKernel.getBalance es.base r to)]) = _
  unfold step_impl
  by_cases h : amount > 0 ∧ LegalKernel.getBalance es.base r to + amount < Laws.maxAmount
  · rw [if_pos h,
      if_pos (show (Action.toTransition (.reward r to amount) st.signer).pre es.base from h)]
    show _ = some [((r, to), LegalKernel.getBalance
                      ((Laws.reward r to amount).apply_impl es.base) r to)]
    simp only [Laws.reward]
    rw [getBalance_setBalance_same]
  · rw [if_neg h,
      if_neg (show ¬ (Action.toTransition (.reward r to amount) st.signer).pre es.base from h)]

/-- The verifier's `burn` balance is the sequencer's. -/
theorem deriveBurnBalance_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (h_act : st.action = .burn r fromActor amount) :
    deriveBurnBalance (stateBalanceReader es) r fromActor amount
      = some [((r, fromActor), LegalKernel.getBalance
                (productionApplyBudget es st idx).base r fromActor)] := by
  rw [productionApplyBudget_base, h_act]
  show (if amount > 0 ∧ amount ≤ LegalKernel.getBalance es.base r fromActor then
          some [((r, fromActor), LegalKernel.getBalance es.base r fromActor - amount)]
        else some [((r, fromActor), LegalKernel.getBalance es.base r fromActor)]) = _
  have h_iff : (amount > 0 ∧ amount ≤ LegalKernel.getBalance es.base r fromActor)
      ↔ (Action.toTransition (.burn r fromActor amount) st.signer).pre es.base :=
    ⟨fun h => ⟨h.2, h.1⟩, fun h => ⟨h.2, h.1⟩⟩
  unfold step_impl
  by_cases h : amount > 0 ∧ amount ≤ LegalKernel.getBalance es.base r fromActor
  · rw [if_pos h, if_pos (h_iff.mp h)]
    show _ = some [((r, fromActor), LegalKernel.getBalance
                      ((Laws.burn r fromActor amount).apply_impl es.base) r fromActor)]
    simp only [Laws.burn]
    rw [getBalance_setBalance_same]
  · rw [if_neg h, if_neg (fun hc => h (h_iff.mpr hc))]

/-- **`deposit`'s balance write** — an UNCONDITIONAL credit.

    `Laws.deposit.pre` is `True`: a bridge deposit's admissibility is
    settled by the bridge gate (the consumed-deposit cell, the attested
    receipt), not by the kernel transition, so there is no branch here
    and a zero-amount deposit credits zero rather than being refused.
    Separate from `deriveCreditBalance` for exactly that reason —
    reusing the `amount > 0` guarded one would silently no-op a
    legitimate zero deposit. -/
def deriveDepositBalance (read : BalanceReader)
    (r : ResourceId) (recipient : ActorId) (amount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r recipient with
  | some bal =>
    if bal + amount < Laws.maxAmount then some [((r, recipient), bal + amount)]
    else some [((r, recipient), bal)]
  | none     => none

/-- **`withdraw`'s balance write** — a debit under a sufficiency
    check, the `burn` shape with the conjuncts in the other order. -/
def deriveWithdrawBalance (read : BalanceReader)
    (r : ResourceId) (sender : ActorId) (amount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r sender with
  | some bal =>
    if 0 < amount ∧ amount ≤ bal then some [((r, sender), bal - amount)]
    else some [((r, sender), bal)]
  | none => none

/-- The verifier's `deposit` balance is the sequencer's. -/
theorem deriveDepositBalance_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : LegalKernel.Bridge.DepositId)
    (h_act : st.action = .deposit r recipient amount d) :
    deriveDepositBalance (stateBalanceReader es) r recipient amount
      = some [((r, recipient), LegalKernel.getBalance
                (productionApplyBudget es st idx).base r recipient)] := by
  rw [productionApplyBudget_base, h_act]
  show (if LegalKernel.getBalance es.base r recipient + amount < Laws.maxAmount then
          some [((r, recipient), LegalKernel.getBalance es.base r recipient + amount)]
        else some [((r, recipient), LegalKernel.getBalance es.base r recipient)]) = _
  unfold step_impl
  by_cases h : LegalKernel.getBalance es.base r recipient + amount < Laws.maxAmount
  · rw [if_pos h, if_pos (show (Action.toTransition (.deposit r recipient amount d)
      st.signer).pre es.base from h)]
    show _ = some [((r, recipient), LegalKernel.getBalance
                      ((Laws.deposit r recipient amount d).apply_impl es.base) r recipient)]
    simp only [Laws.deposit]
    rw [getBalance_setBalance_same]
  · rw [if_neg h, if_neg (show ¬ (Action.toTransition (.deposit r recipient amount d)
      st.signer).pre es.base from h)]

/-- The verifier's `withdraw` balance is the sequencer's. -/
theorem deriveWithdrawBalance_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : LegalKernel.Bridge.EthAddress)
    (h_act : st.action = .withdraw r sender amount rcp) :
    deriveWithdrawBalance (stateBalanceReader es) r sender amount
      = some [((r, sender), LegalKernel.getBalance
                (productionApplyBudget es st idx).base r sender)] := by
  rw [productionApplyBudget_base, h_act]
  show (if 0 < amount ∧ amount ≤ LegalKernel.getBalance es.base r sender then
          some [((r, sender), LegalKernel.getBalance es.base r sender - amount)]
        else some [((r, sender), LegalKernel.getBalance es.base r sender)]) = _
  have h_iff : (0 < amount ∧ amount ≤ LegalKernel.getBalance es.base r sender)
      ↔ (Action.toTransition (.withdraw r sender amount rcp) st.signer).pre es.base :=
    ⟨fun h => ⟨h.1, h.2⟩, fun h => ⟨h.1, h.2⟩⟩
  unfold step_impl
  by_cases h : 0 < amount ∧ amount ≤ LegalKernel.getBalance es.base r sender
  · rw [if_pos h, if_pos (h_iff.mp h)]
    show _ = some [((r, sender), LegalKernel.getBalance
                      ((Laws.withdraw r sender amount rcp).apply_impl es.base) r sender)]
    simp only [Laws.withdraw]
    rw [getBalance_setBalance_same]
  · rw [if_neg h, if_neg (fun hc => h (h_iff.mpr hc))]

/-! ### The two-cell chain

Five of the remaining balance-writing variants share one shape: write
`x`, then write `y` reading the ALREADY-WRITTEN state.
`topUpActionBudget` and `topUpActionBudgetFor` debit the payer and
credit the pool; `claimBudgetRefund` is the mirror; `depositWithFee`
credits the recipient and then the pool.  `transfer` is the same shape
and was proved directly above, before the pattern was visible.

The `x = y` case is what makes the chain more than two independent
writes, and it is reachable in every one of them — a self-transfer, a
signer who IS the pool actor.  Reading the second cell from the
pre-state instead would over- or under-count by the first write.
-/

/-- Both cells of a chained same-resource pair, after the chain. -/
theorem getBalance_chain_pair (s : State) (r : ResourceId) (x y : ActorId)
    (fx fy : Nat → Nat) :
    LegalKernel.getBalance
        (setBalance (setBalance s r x (fx (LegalKernel.getBalance s r x))) r y
          (fy (LegalKernel.getBalance
            (setBalance s r x (fx (LegalKernel.getBalance s r x))) r y))) r y
      = fy (if x = y then fx (LegalKernel.getBalance s r x)
            else LegalKernel.getBalance s r y) := by
  rw [getBalance_setBalance_same]
  by_cases h : x = y
  · subst h
    rw [getBalance_setBalance_same, if_pos rfl]
  · rw [getBalance_setBalance_other _ r r x y _ (Or.inr h), if_neg h]

/-- ...and the first cell, which the second write moves only when the
    two coincide. -/
theorem getBalance_chain_pair_first (s : State) (r : ResourceId) (x y : ActorId)
    (fx fy : Nat → Nat) :
    LegalKernel.getBalance
        (setBalance (setBalance s r x (fx (LegalKernel.getBalance s r x))) r y
          (fy (LegalKernel.getBalance
            (setBalance s r x (fx (LegalKernel.getBalance s r x))) r y))) r x
      = (if x = y then fy (fx (LegalKernel.getBalance s r x))
         else fx (LegalKernel.getBalance s r x)) := by
  by_cases h : x = y
  · subst h
    rw [getBalance_setBalance_same, getBalance_setBalance_same, if_pos rfl]
  · rw [getBalance_setBalance_other _ r r y x _ (Or.inr (fun he => h he.symm)),
      getBalance_setBalance_same, if_neg h]

/-- **What the credit leg reads, in the form the derivation holds it.**

    Every chained law states its ceiling conjunct over the POST-DEBIT
    state, because that is the state its credit reads.  A verifier
    holds pre-values rather than a state, so it must branch on
    `x = y` instead.  This is the bridge between the two spellings,
    and it is shared by all five chained variants — a per-variant copy
    would be five chances for the branch to drift from the law's. -/
theorem getBalance_chain_second_read (s : State) (r : ResourceId) (x y : ActorId)
    (fx : Nat → Nat) :
    LegalKernel.getBalance (setBalance s r x (fx (LegalKernel.getBalance s r x))) r y
      = (if x = y then fx (LegalKernel.getBalance s r x)
         else LegalKernel.getBalance s r y) := by
  by_cases h : x = y
  · subst h; rw [getBalance_setBalance_same, if_pos rfl]
  · rw [getBalance_setBalance_other _ r r x y _ (Or.inr h), if_neg h]

/-- **The chained pair's derivation.**  `fx` and `fy` are the law's own
    per-cell arithmetic; the branch on `x = y` is the chain's, not the
    law's, so every caller gets it right by construction. -/
def deriveChainPair (read : BalanceReader) (r : ResourceId) (x y : ActorId)
    (fx fy : Nat → Nat) : Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r x, read r y with
  | some bx, some by' =>
    let nx := fx bx
    let ny := fy (if x = y then nx else by')
    some [((r, x), if x = y then ny else nx), ((r, y), ny)]
  | _, _ => none

/-- The chained pair's derivation is the chain. -/
theorem deriveChainPair_correct (es : ExtendedState) (r : ResourceId)
    (x y : ActorId) (fx fy : Nat → Nat) :
    deriveChainPair (stateBalanceReader es) r x y fx fy
      = some [ ((r, x), LegalKernel.getBalance
                  (setBalance (setBalance es.base r x
                    (fx (LegalKernel.getBalance es.base r x))) r y
                    (fy (LegalKernel.getBalance (setBalance es.base r x
                      (fx (LegalKernel.getBalance es.base r x))) r y))) r x)
             , ((r, y), LegalKernel.getBalance
                  (setBalance (setBalance es.base r x
                    (fx (LegalKernel.getBalance es.base r x))) r y
                    (fy (LegalKernel.getBalance (setBalance es.base r x
                      (fx (LegalKernel.getBalance es.base r x))) r y))) r y) ] := by
  rw [getBalance_chain_pair, getBalance_chain_pair_first]
  -- The derivation's own `if x = y then ny else nx` is the same
  -- branch, so both sides reduce to the identical pair.
  show some [((r, x), if x = y then
                fy (if x = y then fx (LegalKernel.getBalance es.base r x)
                    else LegalKernel.getBalance es.base r y)
              else fx (LegalKernel.getBalance es.base r x)),
             ((r, y), fy (if x = y then fx (LegalKernel.getBalance es.base r x)
                          else LegalKernel.getBalance es.base r y))] = _
  by_cases h : x = y
  · simp only [if_pos h]
  · simp only [if_neg h]

/-- **`topUpActionBudget`'s balance writes** — debit the signer's gas
    balance, credit the pool.  `pre` is sufficiency only; there is no
    positivity conjunct, so a zero top-up is an admissible no-op rather
    than a refusal. -/
def deriveTopUpBalances (read : BalanceReader)
    (gr : ResourceId) (payer poolActor : ActorId) (gasAmount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read gr payer, read gr poolActor with
  | some payerBal, some poolBal =>
    if gasAmount ≤ payerBal ∧
       (if payer = poolActor then payerBal - gasAmount else poolBal) + gasAmount
         < Laws.maxAmount then
      deriveChainPair read gr payer poolActor
        (fun b => b - gasAmount) (fun b => b + gasAmount)
    else
      some [((gr, payer), payerBal), ((gr, poolActor), poolBal)]
  | _, _ => none

/-- **`claimBudgetRefund`'s balance writes** — the mirror: debit the
    pool, credit the claimant. -/
def deriveRefundBalances (read : BalanceReader)
    (gr : ResourceId) (poolActor claimant : ActorId) (refundAmount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read gr poolActor, read gr claimant with
  | some poolBal, some claimBal =>
    if refundAmount ≤ poolBal ∧
       (if poolActor = claimant then poolBal - refundAmount else claimBal)
         + refundAmount < Laws.maxAmount then
      deriveChainPair read gr poolActor claimant
        (fun b => b - refundAmount) (fun b => b + refundAmount)
    else
      some [((gr, poolActor), poolBal), ((gr, claimant), claimBal)]
  | _, _ => none

/-- **`depositWithFee`'s balance writes** — credit the recipient, then
    the pool.  `pre` is `True`, like `deposit`'s, so there is no
    branch. -/
def deriveDepositWithFeeBalances (read : BalanceReader)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r recipient, read r poolActor with
  | some recipBal, some poolBal =>
    if recipBal + userAmount < Laws.maxAmount ∧
       (if recipient = poolActor then recipBal + userAmount else poolBal)
         + poolAmount < Laws.maxAmount then
      deriveChainPair read r recipient poolActor
        (fun b => b + userAmount) (fun b => b + poolAmount)
    else
      some [((r, recipient), recipBal), ((r, poolActor), poolBal)]
  | _, _ => none

/-- The verifier's `topUpActionBudget` balances are the sequencer's. -/
theorem deriveTopUpBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (gr : ResourceId) (gasAmount : Amount) (bi : Nat) (pa : ActorId)
    (h_act : st.action = .topUpActionBudget gr gasAmount bi pa) :
    deriveTopUpBalances (stateBalanceReader es) gr st.signer pa gasAmount
      = some [ ((gr, st.signer), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base gr st.signer)
             , ((gr, pa), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base gr pa) ] := by
  rw [productionApplyBudget_base, h_act]
  unfold deriveTopUpBalances stateBalanceReader step_impl
  simp only []
  have h_read := getBalance_chain_second_read es.base gr st.signer pa
    (fun b => b - gasAmount)
  by_cases h : gasAmount ≤ LegalKernel.getBalance es.base gr st.signer ∧
      (if st.signer = pa then LegalKernel.getBalance es.base gr st.signer - gasAmount
       else LegalKernel.getBalance es.base gr pa) + gasAmount < Laws.maxAmount
  · rw [if_pos h,
      if_pos (show (Action.toTransition (.topUpActionBudget gr gasAmount bi pa)
        st.signer).pre es.base from ⟨h.1, by
          show Laws.AmountBounded _ gr pa gasAmount
          unfold Laws.AmountBounded
          rw [h_read]; exact h.2⟩)]
    exact deriveChainPair_correct es gr st.signer pa _ _
  · rw [if_neg h,
      if_neg (show ¬ (Action.toTransition (.topUpActionBudget gr gasAmount bi pa)
        st.signer).pre es.base from fun hp => h ⟨hp.1, by
          have := hp.2
          unfold Laws.AmountBounded at this
          rw [h_read] at this; exact this⟩)]

/-- The verifier's `claimBudgetRefund` balances are the sequencer's. -/
theorem deriveRefundBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (gr : ResourceId) (budgetUnits weiPerBudgetUnit : Nat) (pa : ActorId)
    (h_act : st.action = .claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa) :
    deriveRefundBalances (stateBalanceReader es) gr pa st.signer
        (budgetUnits * weiPerBudgetUnit)
      = some [ ((gr, pa), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base gr pa)
             , ((gr, st.signer), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base gr st.signer) ] := by
  -- The refund is `budgetUnits × weiPerBudgetUnit`, not a field: the
  -- amount is COMPUTED from the action's gate-verified fields, so a
  -- verifier reproduces it from the logged action alone.
  rw [productionApplyBudget_base, h_act]
  unfold deriveRefundBalances stateBalanceReader step_impl
  simp only []
  have h_read := getBalance_chain_second_read es.base gr pa st.signer
    (fun b => b - budgetUnits * weiPerBudgetUnit)
  by_cases h : budgetUnits * weiPerBudgetUnit ≤ LegalKernel.getBalance es.base gr pa ∧
      (if pa = st.signer then
         LegalKernel.getBalance es.base gr pa - budgetUnits * weiPerBudgetUnit
       else LegalKernel.getBalance es.base gr st.signer)
        + budgetUnits * weiPerBudgetUnit < Laws.maxAmount
  · rw [if_pos h,
      if_pos (show (Action.toTransition
        (.claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa)
        st.signer).pre es.base from ⟨h.1, by
          show Laws.AmountBounded _ gr st.signer _
          unfold Laws.AmountBounded
          rw [h_read]; exact h.2⟩)]
    exact deriveChainPair_correct es gr pa st.signer _ _
  · rw [if_neg h,
      if_neg (show ¬ (Action.toTransition
        (.claimBudgetRefund gr budgetUnits weiPerBudgetUnit pa)
        st.signer).pre es.base from fun hp => h ⟨hp.1, by
          have := hp.2
          unfold Laws.AmountBounded at this
          rw [h_read] at this; exact this⟩)]

/-- The verifier's `depositWithFee` balances are the sequencer's. -/
theorem deriveDepositWithFeeBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (bg : Nat)
    (d : LegalKernel.Bridge.DepositId)
    (h_act : st.action = .depositWithFee r recipient poolActor
      userAmount poolAmount bg d) :
    deriveDepositWithFeeBalances (stateBalanceReader es) r recipient poolActor
        userAmount poolAmount
      = some [ ((r, recipient), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r recipient)
             , ((r, poolActor), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r poolActor) ] := by
  rw [productionApplyBudget_base, h_act]
  unfold deriveDepositWithFeeBalances stateBalanceReader step_impl
  simp only []
  have h_read := getBalance_chain_second_read es.base r recipient poolActor
    (fun b => b + userAmount)
  have h_iff : (LegalKernel.getBalance es.base r recipient + userAmount < Laws.maxAmount ∧
      (if recipient = poolActor then LegalKernel.getBalance es.base r recipient + userAmount
       else LegalKernel.getBalance es.base r poolActor) + poolAmount < Laws.maxAmount)
      ↔ (Action.toTransition (.depositWithFee r recipient poolActor
          userAmount poolAmount bg d) st.signer).pre es.base := by
    show _ ↔ (Laws.AmountBounded es.base r recipient userAmount ∧
              Laws.AmountBounded (setBalance es.base r recipient
                (LegalKernel.getBalance es.base r recipient + userAmount))
                r poolActor poolAmount)
    unfold Laws.AmountBounded
    rw [h_read]
  by_cases h : LegalKernel.getBalance es.base r recipient + userAmount < Laws.maxAmount ∧
      (if recipient = poolActor then LegalKernel.getBalance es.base r recipient + userAmount
       else LegalKernel.getBalance es.base r poolActor) + poolAmount < Laws.maxAmount
  · rw [if_pos h, if_pos (h_iff.mp h)]
    exact deriveChainPair_correct es r recipient poolActor _ _
  · rw [if_neg h, if_neg (fun hc => h (h_iff.mpr hc))]

/-- **`topUpActionBudgetFor`'s balance writes** — the delegated
    top-up: the SIGNER pays, the pool is credited, and the recipient
    (who gets the budget, not the gas) is not a balance cell at all.

    Its precondition carries a second conjunct the undelegated form
    does not — `recipient ≠ signer` — so a self-delegation is a no-op
    rather than a top-up, and the derivation has to see it or it would
    move balances the advance leaves alone. -/
def deriveDelegatedTopUpBalances (read : BalanceReader)
    (gr : ResourceId) (payer poolActor recipient : ActorId)
    (gasAmount : Amount) : Option (List ((ResourceId × ActorId) × Nat)) :=
  match read gr payer, read gr poolActor with
  | some payerBal, some poolBal =>
    if gasAmount ≤ payerBal ∧ recipient ≠ payer ∧
       (if payer = poolActor then payerBal - gasAmount else poolBal) + gasAmount
         < Laws.maxAmount then
      deriveChainPair read gr payer poolActor
        (fun b => b - gasAmount) (fun b => b + gasAmount)
    else
      some [((gr, payer), payerBal), ((gr, poolActor), poolBal)]
  | _, _ => none

/-- **`reclaimAmmReserves`' balance writes** — the post-disable sweep:
    debit the reserve actor its ENTIRE balance, credit the pool.

    The precondition is an EQUALITY (`balance = amount`), not a
    sufficiency: an exact sweep, so a partial reclaim is a no-op. -/
def deriveReclaimBalances (read : BalanceReader)
    (r : ResourceId) (reserveActor poolActor : ActorId) (amount : Amount) :
    Option (List ((ResourceId × ActorId) × Nat)) :=
  match read r reserveActor, read r poolActor with
  | some reserveBal, some poolBal =>
    if reserveBal = amount ∧ reserveActor ≠ poolActor ∧ amount > 0 ∧
       (if reserveActor = poolActor then reserveBal - amount else poolBal) + amount
         < Laws.maxAmount then
      deriveChainPair read r reserveActor poolActor
        (fun b => b - amount) (fun b => b + amount)
    else
      some [((r, reserveActor), reserveBal), ((r, poolActor), poolBal)]
  | _, _ => none

/-- The verifier's `topUpActionBudgetFor` balances are the
    sequencer's. -/
theorem deriveDelegatedTopUpBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (recipient : ActorId) (gr : ResourceId) (gasAmount : Amount)
    (bi : Nat) (pa : ActorId)
    (h_act : st.action = .topUpActionBudgetFor recipient gr gasAmount bi pa) :
    deriveDelegatedTopUpBalances (stateBalanceReader es) gr st.signer pa
        recipient gasAmount
      = some [ ((gr, st.signer), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base gr st.signer)
             , ((gr, pa), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base gr pa) ] := by
  rw [productionApplyBudget_base, h_act]
  unfold deriveDelegatedTopUpBalances stateBalanceReader step_impl
  simp only []
  have h_read := getBalance_chain_second_read es.base gr st.signer pa
    (fun b => b - gasAmount)
  have h_iff : (gasAmount ≤ LegalKernel.getBalance es.base gr st.signer ∧
      recipient ≠ st.signer ∧
      (if st.signer = pa then LegalKernel.getBalance es.base gr st.signer - gasAmount
       else LegalKernel.getBalance es.base gr pa) + gasAmount < Laws.maxAmount)
      ↔ (Action.toTransition (.topUpActionBudgetFor recipient gr gasAmount bi pa)
          st.signer).pre es.base := by
    show _ ↔ (gasAmount ≤ LegalKernel.getBalance es.base gr st.signer ∧
              recipient ≠ st.signer ∧
              Laws.AmountBounded (setBalance es.base gr st.signer
                (LegalKernel.getBalance es.base gr st.signer - gasAmount))
                gr pa gasAmount)
    unfold Laws.AmountBounded
    rw [h_read]
  by_cases h : gasAmount ≤ LegalKernel.getBalance es.base gr st.signer ∧
      recipient ≠ st.signer ∧
      (if st.signer = pa then LegalKernel.getBalance es.base gr st.signer - gasAmount
       else LegalKernel.getBalance es.base gr pa) + gasAmount < Laws.maxAmount
  · rw [if_pos h, if_pos (h_iff.mp h)]
    exact deriveChainPair_correct es gr st.signer pa _ _
  · rw [if_neg h, if_neg (fun hc => h (h_iff.mpr hc))]

/-- The verifier's `reclaimAmmReserves` balances are the sequencer's. -/
theorem deriveReclaimBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (amount : Amount) (reserveActor poolActor : ActorId)
    (h_act : st.action = .reclaimAmmReserves r amount reserveActor poolActor) :
    deriveReclaimBalances (stateBalanceReader es) r reserveActor poolActor amount
      = some [ ((r, reserveActor), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r reserveActor)
             , ((r, poolActor), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r poolActor) ] := by
  rw [productionApplyBudget_base, h_act]
  unfold deriveReclaimBalances stateBalanceReader step_impl
  simp only []
  have h_read := getBalance_chain_second_read es.base r reserveActor poolActor
    (fun b => b - amount)
  have h_iff : (LegalKernel.getBalance es.base r reserveActor = amount ∧
      reserveActor ≠ poolActor ∧ amount > 0 ∧
      (if reserveActor = poolActor then
         LegalKernel.getBalance es.base r reserveActor - amount
       else LegalKernel.getBalance es.base r poolActor) + amount < Laws.maxAmount)
      ↔ (Action.toTransition (.reclaimAmmReserves r amount reserveActor poolActor)
          st.signer).pre es.base := by
    show _ ↔ (LegalKernel.getBalance es.base r reserveActor = amount ∧
              reserveActor ≠ poolActor ∧ amount > 0 ∧
              Laws.AmountBounded (setBalance es.base r reserveActor
                (LegalKernel.getBalance es.base r reserveActor - amount))
                r poolActor amount)
    unfold Laws.AmountBounded
    rw [h_read]
  by_cases h : LegalKernel.getBalance es.base r reserveActor = amount ∧
      reserveActor ≠ poolActor ∧ amount > 0 ∧
      (if reserveActor = poolActor then
         LegalKernel.getBalance es.base r reserveActor - amount
       else LegalKernel.getBalance es.base r poolActor) + amount < Laws.maxAmount
  · rw [if_pos h, if_pos (h_iff.mp h)]
    exact deriveChainPair_correct es r reserveActor poolActor _ _
  · rw [if_neg h, if_neg (fun hc => h (h_iff.mpr hc))]

/-- **`ammSwap`'s balance writes** — the one variant that touches two
    DIFFERENT resources, so the two cells are independent and the
    chained-pair lemma does not apply.

    `fromResource ≠ toResource` is a precondition conjunct rather than
    an assumption, which is what makes the independence sound: without
    it a same-resource swap would be a chain and reading the second
    cell from the pre-state would miscount. -/
def deriveAmmSwapBalances (read : BalanceReader)
    (fromResource toResource : ResourceId) (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) : Option (List ((ResourceId × ActorId) × Nat)) :=
  match read fromResource ammReserveActor, read toResource ammReserveActor with
  | some fromBal, some toBal =>
    if toBal ≥ amountOut ∧ fromResource ≠ toResource ∧ amountIn > 0 ∧
       fromBal + amountIn < Laws.maxAmount then
      some [ ((fromResource, ammReserveActor), fromBal + amountIn)
           , ((toResource, ammReserveActor), toBal - amountOut) ]
    else
      some [ ((fromResource, ammReserveActor), fromBal)
           , ((toResource, ammReserveActor), toBal) ]
  | _, _ => none

/-- The verifier's `ammSwap` balances are the sequencer's. -/
theorem deriveAmmSwapBalances_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (fromResource toResource : ResourceId) (amountIn amountOut : Amount)
    (ammReserveActor : ActorId)
    (h_act : st.action = .ammSwap fromResource toResource amountIn amountOut
      ammReserveActor) :
    deriveAmmSwapBalances (stateBalanceReader es) fromResource toResource
        amountIn amountOut ammReserveActor
      = some [ ((fromResource, ammReserveActor), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base fromResource ammReserveActor)
             , ((toResource, ammReserveActor), LegalKernel.getBalance
                  (productionApplyBudget es st idx).base toResource ammReserveActor) ] := by
  rw [productionApplyBudget_base, h_act]
  unfold deriveAmmSwapBalances stateBalanceReader step_impl
  simp only []
  have h_iff : (LegalKernel.getBalance es.base toResource ammReserveActor ≥ amountOut ∧
      fromResource ≠ toResource ∧ amountIn > 0 ∧
      LegalKernel.getBalance es.base fromResource ammReserveActor + amountIn
        < Laws.maxAmount)
      ↔ (Action.toTransition (.ammSwap fromResource toResource amountIn amountOut
          ammReserveActor) st.signer).pre es.base :=
    Iff.rfl
  by_cases h : LegalKernel.getBalance es.base toResource ammReserveActor ≥ amountOut ∧
      fromResource ≠ toResource ∧ amountIn > 0 ∧
      LegalKernel.getBalance es.base fromResource ammReserveActor + amountIn
        < Laws.maxAmount
  · rw [if_pos h, if_pos (h_iff.mp h)]
    show _ = some [((fromResource, ammReserveActor), LegalKernel.getBalance
                      ((Laws.ammSwap fromResource toResource amountIn amountOut
                        ammReserveActor).apply_impl es.base) fromResource ammReserveActor),
                   ((toResource, ammReserveActor), LegalKernel.getBalance
                      ((Laws.ammSwap fromResource toResource amountIn amountOut
                        ammReserveActor).apply_impl es.base) toResource ammReserveActor)]
    simp only [Laws.ammSwap]
    -- The credit lands at `fromResource`, the debit at `toResource`;
    -- the resources differ, so neither write is visible to the other.
    rw [getBalance_setBalance_other _ toResource fromResource ammReserveActor
      ammReserveActor _ (Or.inl (fun he => h.2.1 he.symm))]
    rw [getBalance_setBalance_same]
    rw [getBalance_setBalance_same]
    rw [getBalance_setBalance_other _ fromResource toResource ammReserveActor
      ammReserveActor _ (Or.inl h.2.1)]
  · rw [if_neg h, if_neg (fun hc => h (h_iff.mpr hc))]

/-! ## Registry and local-policy cells

Four variants, and they are the easiest of the set for a reason worth
naming: their post-values are functions of the ACTION's own fields
alone.  A verifier reads them off the logged action and needs no proven
cell at all — no `BalanceReader`, no precondition branch (all four
compile to kernel-inert transitions, so `step_impl` cannot no-op them
away).

That also makes them the cells where an L1 that simply ignored its
declared writes would be most obviously wrong: the value is right
there in the calldata.
-/

/-- **`replaceKey` / `registerIdentity`'s registry write.**

    Both are `registry.insert actor key`, so both derive the same way.
    The value goes through the CBE byte-string encoder rather than
    being emitted raw: `PublicKey` is a bare `ByteArray` and
    `registerIdentity` accepts any value, so a registration with the
    EMPTY key would otherwise read exactly like an absent one — and
    registration is an admissibility gate, so those are different
    states. -/
def deriveRegistryCellValue (key : Authority.PublicKey) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := ByteArray) key).toArray

/-- **`declareLocalPolicy`'s local-policy write.** -/
def deriveDeclaredPolicyCellValue (policy : Authority.LocalPolicy) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := Authority.LocalPolicy) policy).toArray

/-- **`revokeLocalPolicy`'s local-policy write** — the canonical ABSENT
    value, because `revoke` erases the entry rather than storing an
    empty policy.

    The distinction is load-bearing: `getCellValue` keys off the MAP,
    not `lookup`, so "declared a policy with no clauses" and "declared
    nothing" are different cell values.  A derivation that emitted an
    encoded empty policy here would move the root to a state the
    advance never reaches. -/
def deriveRevokedPolicyCellValue : ByteArray := ByteArray.empty

/-- The verifier's `replaceKey` registry write is the sequencer's. -/
theorem deriveRegistryCellValue_correct_replaceKey
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (actor : ActorId) (newKey : Authority.PublicKey)
    (h_act : st.action = .replaceKey actor newKey) :
    deriveRegistryCellValue newKey
      = getCellValue (productionApplyBudget es st idx) (.registry actor) := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  have h_reg : (productionApplyBudget es st idx).registry
      = (Disputes.kernelOnlyApply es (signedActionEntry st)).registry := by
    rw [h]; rfl
  show _ = (match (productionApplyBudget es st idx).registry[actor]? with
            | some pk => ByteArray.mk (Encodable.encode (T := ByteArray) pk).toArray
            | none    => ByteArray.empty)
  rw [h_reg]
  unfold Disputes.kernelOnlyApply signedActionEntry
  rw [h_act]
  show _ = (match ((Authority.advanceNonce _ st.signer).registry.insert
              actor newKey)[actor]? with
            | some pk => ByteArray.mk (Encodable.encode (T := ByteArray) pk).toArray
            | none    => ByteArray.empty)
  rw [LegalKernel.RBMap.find?_insert_self _ actor newKey]
  rfl

/-- ...and the `registerIdentity` one likewise. -/
theorem deriveRegistryCellValue_correct_registerIdentity
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (actor : ActorId) (pk : Authority.PublicKey)
    (h_act : st.action = .registerIdentity actor pk) :
    deriveRegistryCellValue pk
      = getCellValue (productionApplyBudget es st idx) (.registry actor) := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  have h_reg : (productionApplyBudget es st idx).registry
      = (Disputes.kernelOnlyApply es (signedActionEntry st)).registry := by
    rw [h]; rfl
  show _ = (match (productionApplyBudget es st idx).registry[actor]? with
            | some k => ByteArray.mk (Encodable.encode (T := ByteArray) k).toArray
            | none    => ByteArray.empty)
  rw [h_reg]
  unfold Disputes.kernelOnlyApply signedActionEntry
  rw [h_act]
  show _ = (match ((Authority.advanceNonce _ st.signer).registry.insert
              actor pk)[actor]? with
            | some k => ByteArray.mk (Encodable.encode (T := ByteArray) k).toArray
            | none   => ByteArray.empty)
  rw [LegalKernel.RBMap.find?_insert_self _ actor pk]
  rfl

/-- The verifier's `declareLocalPolicy` write is the sequencer's. -/
theorem deriveDeclaredPolicyCellValue_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (policy : Authority.LocalPolicy)
    (h_act : st.action = .declareLocalPolicy policy) :
    deriveDeclaredPolicyCellValue policy
      = getCellValue (productionApplyBudget es st idx) (.localPolicy st.signer) := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  have h_lp : (productionApplyBudget es st idx).localPolicies
      = (Disputes.kernelOnlyApply es (signedActionEntry st)).localPolicies := by
    rw [h]; rfl
  show _ = (match (productionApplyBudget es st idx).localPolicies[st.signer]? with
            | some p => ByteArray.mk
                          (Encodable.encode (T := Authority.LocalPolicy) p).toArray
            | none   => ByteArray.empty)
  rw [h_lp]
  unfold Disputes.kernelOnlyApply signedActionEntry
  rw [h_act]
  show _ = (match ((Authority.advanceNonce _ st.signer).localPolicies.declare
              st.signer policy)[st.signer]? with
            | some p => ByteArray.mk
                          (Encodable.encode (T := Authority.LocalPolicy) p).toArray
            | none   => ByteArray.empty)
  unfold Authority.LocalPolicies.declare
  rw [LegalKernel.RBMap.find?_insert_self _ st.signer policy]
  rfl

/-- **`declareLocalPolicy`'s cell value IS its action fields.**

    Both are `Encodable.encode (T := LocalPolicy) policy`, so an L1
    holding the calldata already holds the cell value and does not need
    a `LocalPolicy` encoder of its own — which would otherwise be the
    single largest encoder the step VM had to carry, since a policy is
    an array of clauses rather than a fixed-width record.

    Worth stating rather than noticing: the two are equal by
    construction TODAY, and a future change to either the L1 field
    layout or the cell encoding would silently break the flip's
    smallest assumption.  Stated as a theorem, that change fails to
    compile instead. -/
theorem deriveDeclaredPolicyCellValue_eq_actionFields
    (policy : Authority.LocalPolicy) :
    deriveDeclaredPolicyCellValue policy
      = FaultProof.StepVMCoherence.actionFieldsForL1 (.declareLocalPolicy policy) := rfl

/-- ...and `replaceKey` / `registerIdentity`'s key is the action
    fields' TAIL, after the 8-byte actor id.

    So the registry write needs only `CBEEncode.bytesValue` over a
    calldata slice — no key encoder either. -/
theorem registry_key_is_action_fields_tail
    (actor : ActorId) (newKey : Authority.PublicKey) :
    FaultProof.StepVMCoherence.actionFieldsForL1 (.replaceKey actor newKey)
      = FaultProof.StepVMCoherence.uint64BE actor.toNat ++ newKey := rfl

/-- The verifier's `revokeLocalPolicy` write is the sequencer's.

    The one of the four whose derived value is the ABSENT marker rather
    than an encoding, because `revoke` erases the map entry.  Proved
    through `TreeMap.getElem?_erase_self` rather than through
    `lookup_revoke_self`: `lookup` DEFAULTS an absent actor to
    `LocalPolicy.empty`, so it cannot distinguish the two states the
    cell must, and a proof routed through it would be proving the wrong
    thing. -/
theorem deriveRevokedPolicyCellValue_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_act : st.action = .revokeLocalPolicy) :
    deriveRevokedPolicyCellValue
      = getCellValue (productionApplyBudget es st idx) (.localPolicy st.signer) := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  have h_lp : (productionApplyBudget es st idx).localPolicies
      = (Disputes.kernelOnlyApply es (signedActionEntry st)).localPolicies := by
    rw [h]; rfl
  show _ = (match (productionApplyBudget es st idx).localPolicies[st.signer]? with
            | some p => ByteArray.mk
                          (Encodable.encode (T := Authority.LocalPolicy) p).toArray
            | none   => ByteArray.empty)
  rw [h_lp]
  unfold Disputes.kernelOnlyApply signedActionEntry
  rw [h_act]
  show _ = (match ((Authority.advanceNonce _ st.signer).localPolicies.revoke
              st.signer)[st.signer]? with
            | some p => ByteArray.mk
                          (Encodable.encode (T := Authority.LocalPolicy) p).toArray
            | none   => ByteArray.empty)
  unfold Authority.LocalPolicies.revoke
  rw [Std.TreeMap.getElem?_erase_self]
  rfl

/-! ## Bridge cells

Three variants write them: `deposit` and `depositWithFee` mark a
deposit consumed; `withdraw` appends a pending withdrawal and bumps the
counter.

`withdraw` is the one whose write set is not a function of
`(action, signer)`: the pending cell is keyed by the pre-state's
`nextWdId`, which is itself a cell.  A verifier reads that cell to
learn WHICH cell to write, which is exactly why `Action.stateWriteCells`
exists and why `bridgeNextWdId` is in the write set alongside the
pending entry rather than being an implementation detail.
-/

/-- **`deposit` / `depositWithFee`'s consumed-deposit write.**

    The record is built entirely from the action's own fields — a
    verifier needs no proven cell.  `deposit` is the degenerate case
    with no fee split, and writing it as `poolAmount := 0,
    budgetGrant := 0` rather than sharing `depositWithFee`'s builder
    keeps the two encodings visibly distinct at the call site. -/
def deriveConsumedCellValue (rec : LegalKernel.Bridge.DepositRecord) : ByteArray :=
  ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray

/-- **`withdraw`'s pending-withdrawal write.** -/
def derivePendingCellValue (wd : LegalKernel.Bridge.PendingWithdrawal) : ByteArray :=
  ByteArray.mk (Encoding.Bridge.PendingWithdrawal.encode wd).toArray

/-- **`withdraw`'s counter write** — `pre + 1`, from the proven
    `.bridgeNextWdId` cell.  The same fail-closed shape as the nonce:
    a malformed pre-value derives nothing rather than resetting the
    counter, and a reset counter would let a later withdrawal overwrite
    an earlier one's pending cell. -/
def deriveNextWdIdCellValue (preValue : ByteArray) : Option ByteArray :=
  match Encodable.decode (T := Nat) preValue.data.toList with
  | .ok (n, []) => some (ByteArray.mk (Encodable.encode (T := Nat) (n + 1)).toArray)
  | _           => none

/-- The verifier's `deposit` consumed-cell write is the sequencer's. -/
theorem deriveConsumedCellValue_correct_deposit
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : LegalKernel.Bridge.DepositId)
    (h_act : st.action = .deposit r recipient amount d) :
    deriveConsumedCellValue
        { resource := r, userAmount := amount, poolAmount := 0, budgetGrant := 0 }
      = getCellValue (productionApplyBudget es st idx) (.bridgeConsumed d) := by
  show _ = (if (productionApplyBudget es st idx).bridge.consumed.contains d then
              match (productionApplyBudget es st idx).bridge.consumed[d]? with
              | some rec => ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray
              | none     => ByteArray.empty
            else ByteArray.empty)
  rw [productionApplyBudget_bridge, h_act]
  show _ = (if (LegalKernel.Bridge.BridgeState.markConsumed es.bridge d
                 { resource := r, userAmount := amount,
                   poolAmount := 0, budgetGrant := 0 }).consumed.contains d then
              match (LegalKernel.Bridge.BridgeState.markConsumed es.bridge d
                 { resource := r, userAmount := amount,
                   poolAmount := 0, budgetGrant := 0 }).consumed[d]? with
              | some rec => ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray
              | none     => ByteArray.empty
            else ByteArray.empty)
  unfold LegalKernel.Bridge.BridgeState.markConsumed
  show _ = (if (es.bridge.consumed.insert d _).contains d then
              match (es.bridge.consumed.insert d _)[d]? with
              | some rec => ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray
              | none     => ByteArray.empty
            else ByteArray.empty)
  rw [Std.TreeMap.contains_insert_self, if_pos rfl,
    LegalKernel.RBMap.find?_insert_self _ d _]
  rfl

/-- ...and the `depositWithFee` one, which carries the fee split. -/
theorem deriveConsumedCellValue_correct_depositWithFee
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (bg : Nat)
    (d : LegalKernel.Bridge.DepositId)
    (h_act : st.action = .depositWithFee r recipient poolActor
      userAmount poolAmount bg d) :
    deriveConsumedCellValue
        { resource := r, userAmount := userAmount,
          poolAmount := poolAmount, budgetGrant := bg }
      = getCellValue (productionApplyBudget es st idx) (.bridgeConsumed d) := by
  show _ = (if (productionApplyBudget es st idx).bridge.consumed.contains d then
              match (productionApplyBudget es st idx).bridge.consumed[d]? with
              | some rec => ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray
              | none     => ByteArray.empty
            else ByteArray.empty)
  rw [productionApplyBudget_bridge, h_act]
  show _ = (if (LegalKernel.Bridge.BridgeState.markConsumed es.bridge d
                 { resource := r, userAmount := userAmount,
                   poolAmount := poolAmount, budgetGrant := bg }).consumed.contains d then
              match (LegalKernel.Bridge.BridgeState.markConsumed es.bridge d
                 { resource := r, userAmount := userAmount,
                   poolAmount := poolAmount, budgetGrant := bg }).consumed[d]? with
              | some rec => ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray
              | none     => ByteArray.empty
            else ByteArray.empty)
  unfold LegalKernel.Bridge.BridgeState.markConsumed
  show _ = (if (es.bridge.consumed.insert d _).contains d then
              match (es.bridge.consumed.insert d _)[d]? with
              | some rec => ByteArray.mk (Encoding.Bridge.DepositRecord.encode rec).toArray
              | none     => ByteArray.empty
            else ByteArray.empty)
  rw [Std.TreeMap.contains_insert_self, if_pos rfl,
    LegalKernel.RBMap.find?_insert_self _ d _]
  rfl

/-- The verifier's `withdraw` pending-cell write is the sequencer's —
    at the cell the PRE-state's counter names. -/
theorem derivePendingCellValue_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : LegalKernel.Bridge.EthAddress)
    (h_act : st.action = .withdraw r sender amount rcp) :
    derivePendingCellValue
        { resource := r, recipient := rcp, amount := amount, l2LogIndex := idx
        , wdId := es.bridge.nextWdId }
      = getCellValue (productionApplyBudget es st idx)
          (.bridgePending es.bridge.nextWdId) := by
  show _ = (match (productionApplyBudget es st idx).bridge.pending[es.bridge.nextWdId]? with
            | some pw => ByteArray.mk
                           (Encoding.Bridge.PendingWithdrawal.encode pw).toArray
            | none    => ByteArray.empty)
  rw [productionApplyBudget_bridge, h_act]
  show _ = (match (LegalKernel.Bridge.BridgeState.appendWithdrawal es.bridge
              { resource := r, recipient := rcp, amount := amount,
                l2LogIndex := idx,
                wdId := es.bridge.nextWdId }).pending[es.bridge.nextWdId]? with
            | some pw => ByteArray.mk
                           (Encoding.Bridge.PendingWithdrawal.encode pw).toArray
            | none    => ByteArray.empty)
  unfold LegalKernel.Bridge.BridgeState.appendWithdrawal
  show _ = (match (es.bridge.pending.insert es.bridge.nextWdId _)[es.bridge.nextWdId]? with
            | some pw => ByteArray.mk
                           (Encoding.Bridge.PendingWithdrawal.encode pw).toArray
            | none    => ByteArray.empty)
  rw [LegalKernel.RBMap.find?_insert_self _ es.bridge.nextWdId _]
  rfl

/-- The verifier's `withdraw` counter write is the sequencer's. -/
theorem deriveNextWdIdCellValue_correct
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : LegalKernel.Bridge.EthAddress)
    (h_act : st.action = .withdraw r sender amount rcp)
    (h_bound : es.bridge.nextWdId < 256 ^ 8) :
    deriveNextWdIdCellValue (getCellValue es .bridgeNextWdId)
      = some (getCellValue (productionApplyBudget es st idx) .bridgeNextWdId) := by
  unfold deriveNextWdIdCellValue
  have h_dec : Encodable.decode (T := Nat)
      (getCellValue es (.bridgeNextWdId)).data.toList
      = .ok (es.bridge.nextWdId, []) := by
    show Encodable.decode (T := Nat)
      (ByteArray.mk (Encodable.encode
        (T := Nat) es.bridge.nextWdId).toArray).data.toList = _
    have h_list : (ByteArray.mk (Encodable.encode
        (T := Nat) es.bridge.nextWdId).toArray).data.toList
        = Encodable.encode (T := Nat) es.bridge.nextWdId := by simp
    rw [h_list, show Encodable.encode (T := Nat) es.bridge.nextWdId
      = Encodable.encode (T := Nat) es.bridge.nextWdId ++ [] from
      (List.append_nil _).symm]
    exact Encoding.nat_roundtrip _ [] h_bound
  rw [h_dec]
  show some (ByteArray.mk (Encodable.encode
    (T := Nat) (es.bridge.nextWdId + 1)).toArray) = _
  show _ = some (ByteArray.mk (Encodable.encode
    (T := Nat) (productionApplyBudget es st idx).bridge.nextWdId).toArray)
  rw [productionApplyBudget_bridge, h_act]
  rfl

/-! ## Which steps a fault proof can adjudicate

Deriving each cell's VALUE is only half of what a verifier needs.  It
must also derive the write SET — which cells the step touches — because
a bundle that omits one folds successfully onto a root where that cell
never moved.

For twenty-three variants the set is a function of `(action, signer)`
plus cells the bundle itself proves: `withdraw`'s pending cell is keyed
by the proven `.bridgeNextWdId`, and everything else is static.  A
verifier re-derives the list and rejects a bundle that does not match
it.

The two bulk variants are not.  Their write set is the actor set at a
resource, `smtCellKey` is a HASH of the cell's identity, so balance
cells at one resource share no key prefix and no subtree argument
enumerates them — a verifier holding only the pre-root cannot tell a
complete recipient list from one missing an entry.

**The decision recorded here is to exclude them.**  A deployment
leaning on the fault proof must not authorise `distributeOthers` /
`proportionalDilute`, which its `AuthorityPolicy` already expresses —
the two laws remain available to deployments using the
adjudicator-quorum backstop.  Chosen over the two alternatives (a
per-resource actor-set cell, which would widen nearly every variant's
write set; or moving the recipient list into the action's fields, which
would change frozen `Action` indices 6/7 and their encoders) because it
costs nothing and is reversible: either alternative can be adopted
later without undoing this.

`FaultProofAdjudicable` makes that a checkable predicate rather than a
sentence in a runbook.
-/

/-- Whether a fault proof can adjudicate a step over this action.

    `false` exactly on the two bulk variants, whose write set a
    verifier cannot re-derive from the pre-root. -/
def FaultProofAdjudicable : Action → Bool
  | .distributeOthers _ _ _   => false
  | .proportionalDilute _ _ _ => false
  | _                         => true

/-- **An adjudicable, non-`withdraw` action's write set is static.**

    So a verifier re-derives it from `(action, signer)` alone and
    rejects any bundle naming a different set of cells. -/
theorem writeCellsAt_eq_writeCells_of_adjudicable
    (es : ExtendedState) (a : Action) (signer : ActorId)
    (h_adj : FaultProofAdjudicable a = true)
    (h_wd : ∀ r sender amount rcp, a ≠ .withdraw r sender amount rcp) :
    a.writeCellsAt es signer = a.writeCells signer := by
  refine Action.writeCellsAt_eq_writeCells es a signer h_wd ?_ ?_
  · intro r excluded amount he
    rw [he] at h_adj
    exact absurd h_adj (by simp [FaultProofAdjudicable])
  · intro r excluded amount he
    rw [he] at h_adj
    exact absurd h_adj (by simp [FaultProofAdjudicable])

/-- ...and at `withdraw` it is the static set plus exactly the cell the
    proven `.bridgeNextWdId` names, which is the one place a verifier
    reads a cell to learn WHICH cell to write. -/
theorem writeCellsAt_withdraw_from_proven_counter
    (es : ExtendedState) (r : ResourceId) (sender : ActorId)
    (amount : Amount) (rcp : LegalKernel.Bridge.EthAddress) (signer : ActorId) :
    (Action.withdraw r sender amount rcp).writeCellsAt es signer =
      (Action.withdraw r sender amount rcp).writeCells signer ++
        [.bridgePending es.bridge.nextWdId] := rfl

/-- The two bulk variants are the ONLY inadjudicable ones.

    Stated as an iff so the predicate cannot quietly widen: adding a
    variant to `FaultProofAdjudicable`'s `false` list without a reason
    would break this, and so would a new `Action` constructor whose
    write set is state-keyed in a way a verifier cannot re-derive. -/
theorem faultProofAdjudicable_eq_false_iff (a : Action) :
    FaultProofAdjudicable a = false ↔
      ((∃ r e amt, a = .distributeOthers r e amt) ∨
       (∃ r e amt, a = .proportionalDilute r e amt)) := by
  constructor
  · intro h
    cases a with
    | distributeOthers r e amt => exact Or.inl ⟨r, e, amt, rfl⟩
    | proportionalDilute r e amt => exact Or.inr ⟨r, e, amt, rfl⟩
    | _ => exact absurd h (by simp [FaultProofAdjudicable])
  · rintro (⟨r, e, amt, rfl⟩ | ⟨r, e, amt, rfl⟩) <;> rfl

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

/-! ## Alias consistency

A plan may name the same balance cell twice — every aliasable variant
reaches that case cheaply and permissionlessly (a self-transfer, a
self-delegated top-up, a `depositWithFee` whose recipient is the pool).
Under the chained fold that was harmless: each occurrence read the
RUNNING value, so the second write simply landed the value the first
one had.  A pre-root multiproof opens each cell ONCE, so the plan is
consulted per cell rather than per occurrence, and the question "which
entry wins" becomes real.

The answer is that it cannot matter, and these lemmas are why: at an
alias the two entries carry the same value in every variant.  Either
the branch is guarded against the alias outright, or both entries are
pre-values obtained from the SAME reader call at the SAME key — and a
reader is a function.

`plannedBalanceAt?` refuses a disagreeing duplicate rather than
resolving one.  These lemmas say that refusal is unreachable, which is
what makes it free; what it buys is that a future derivation bug fails
closed instead of silently picking whichever entry the search finds
first. -/

/-- Alias consistency for a two-entry plan reduces to one implication:
    if the keys coincide, the values must.  Every `derive*Balances`
    result is at most two entries, so this is the whole obligation. -/
theorem aliasConsistent_pair (k₁ k₂ : ResourceId × ActorId) (v₁ v₂ : Nat)
    (h : k₁ = k₂ → v₁ = v₂) : aliasConsistent [(k₁, v₁), (k₂, v₂)] = true := by
  by_cases hk : k₁ = k₂
  · subst hk
    have hv : v₁ = v₂ := h rfl
    subst hv
    simp [aliasConsistent]
  · have hk' : ¬ k₂ = k₁ := fun he => hk he.symm
    simp [aliasConsistent, hk, hk']

/-- A singleton plan is trivially consistent. -/
theorem aliasConsistent_singleton (k : ResourceId × ActorId) (v : Nat) :
    aliasConsistent [(k, v)] = true := by simp [aliasConsistent]

/-- The empty plan is trivially consistent. -/
theorem aliasConsistent_nil :
    aliasConsistent ([] : List ((ResourceId × ActorId) × Nat)) = true := by
  simp [aliasConsistent]

/-- **The chained pair is alias-consistent.**  Its `x = y` branch
    already exists — it is what makes the chain's second read see the
    first write — and it lands the SAME value in both slots, which is
    the property the frontier needs.  Four of the aliasable variants
    route through here, so they are covered at once. -/
theorem deriveChainPair_alias_consistent (read : BalanceReader) (r : ResourceId)
    (x y : ActorId) (fx fy : Nat → Nat)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveChainPair read r x y fx fy = some plan) :
    aliasConsistent plan = true := by
  unfold deriveChainPair at h
  cases hx : read r x with
  | none => rw [hx] at h; cases read r y <;> simp at h
  | some bx =>
    cases hy : read r y with
    | none => rw [hx, hy] at h; simp at h
    | some by' =>
      rw [hx, hy] at h
      simp only [Option.some.injEq] at h
      subst h
      refine aliasConsistent_pair _ _ _ _ (fun hk => ?_)
      have hxy : x = y := (Prod.mk.injEq .. ▸ hk).2
      simp [hxy]

/-- A pair of PRE-VALUES read at two keys is alias-consistent: when the
    keys coincide the two values come from the same reader call, and a
    reader is a function.  This is the shape every refusal branch
    takes — a failing precondition leaves both cells alone. -/
theorem aliasConsistent_read_pair (read : BalanceReader) (r₁ r₂ : ResourceId)
    (a₁ a₂ : ActorId) (v₁ v₂ : Nat)
    (h₁ : read r₁ a₁ = some v₁) (h₂ : read r₂ a₂ = some v₂) :
    aliasConsistent [((r₁, a₁), v₁), ((r₂, a₂), v₂)] = true := by
  refine aliasConsistent_pair _ _ _ _ (fun hk => ?_)
  have hr : r₁ = r₂ := (Prod.mk.injEq .. ▸ hk).1
  have ha : a₁ = a₂ := (Prod.mk.injEq .. ▸ hk).2
  subst hr; subst ha
  rw [h₁] at h₂
  exact (Option.some.injEq .. ▸ h₂)

/-- `deriveTransferBalances` is alias-consistent.  Its `sender =
    receiver` branch already lands the same value in both slots (which
    is why the corpus cannot tell a first-occurrence rule from a
    last-occurrence one); the refusal branch is a pair of pre-values. -/
theorem deriveTransferBalances_alias_consistent (read : BalanceReader)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveTransferBalances read r sender receiver amount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveTransferBalances at h
  cases hs : read r sender with
  | none => rw [hs] at h; cases read r receiver <;> simp at h
  | some sBal =>
    cases hr : read r receiver with
    | none => rw [hs, hr] at h; simp at h
    | some rBal =>
      rw [hs, hr] at h
      simp only [] at h
      by_cases hpre : amount > 0 ∧ amount ≤ sBal ∧
          (if sender = receiver then sBal - amount else rBal) + amount
            < Laws.maxAmount
      · rw [if_pos hpre] at h
        by_cases hsr : sender = receiver
        · rw [if_pos hsr] at h
          simp only [Option.some.injEq] at h
          subst h
          exact aliasConsistent_pair _ _ _ _ (fun _ => rfl)
        · rw [if_neg hsr] at h
          simp only [Option.some.injEq] at h
          subst h
          refine aliasConsistent_pair _ _ _ _ (fun hk => ?_)
          exact absurd ((Prod.mk.injEq ..).mp hk).2 hsr
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read r r sender receiver sBal rBal hs hr

/-- `deriveTopUpBalances` is alias-consistent: the admitted branch is a
    chained pair, the refusal branch a pair of pre-values. -/
theorem deriveTopUpBalances_alias_consistent (read : BalanceReader)
    (gr : ResourceId) (payer poolActor : ActorId) (gasAmount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveTopUpBalances read gr payer poolActor gasAmount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveTopUpBalances at h
  cases hp : read gr payer with
  | none => rw [hp] at h; cases read gr poolActor <;> simp at h
  | some payerBal =>
    cases hq : read gr poolActor with
    | none => rw [hp, hq] at h; simp at h
    | some poolBal =>
      rw [hp, hq] at h
      simp only [] at h
      by_cases hpre : gasAmount ≤ payerBal ∧
          (if payer = poolActor then payerBal - gasAmount else poolBal) + gasAmount
            < Laws.maxAmount
      · rw [if_pos hpre] at h
        exact deriveChainPair_alias_consistent read gr payer poolActor _ _ plan h
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read gr gr payer poolActor payerBal poolBal hp hq

/-- `deriveRefundBalances` is alias-consistent, by the same split. -/
theorem deriveRefundBalances_alias_consistent (read : BalanceReader)
    (gr : ResourceId) (poolActor claimant : ActorId) (refundAmount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveRefundBalances read gr poolActor claimant refundAmount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveRefundBalances at h
  cases hp : read gr poolActor with
  | none => rw [hp] at h; cases read gr claimant <;> simp at h
  | some poolBal =>
    cases hq : read gr claimant with
    | none => rw [hp, hq] at h; simp at h
    | some claimBal =>
      rw [hp, hq] at h
      simp only [] at h
      by_cases hpre : refundAmount ≤ poolBal ∧
          (if poolActor = claimant then poolBal - refundAmount else claimBal)
            + refundAmount < Laws.maxAmount
      · rw [if_pos hpre] at h
        exact deriveChainPair_alias_consistent read gr poolActor claimant _ _ plan h
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read gr gr poolActor claimant poolBal claimBal hp hq

/-- `deriveAmmSwapBalances` is alias-consistent.  Its two cells are at
    DIFFERENT resources in the admitted branch — `fromResource ≠
    toResource` is a precondition conjunct — and both are pre-values in
    the refusal branch. -/
theorem deriveAmmSwapBalances_alias_consistent (read : BalanceReader)
    (fromResource toResource : ResourceId) (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveAmmSwapBalances read fromResource toResource amountIn amountOut
           ammReserveActor = some plan) :
    aliasConsistent plan = true := by
  unfold deriveAmmSwapBalances at h
  cases hf : read fromResource ammReserveActor with
  | none => rw [hf] at h; cases read toResource ammReserveActor <;> simp at h
  | some fromBal =>
    cases ht : read toResource ammReserveActor with
    | none => rw [hf, ht] at h; simp at h
    | some toBal =>
      rw [hf, ht] at h
      simp only [] at h
      by_cases hpre : toBal ≥ amountOut ∧ fromResource ≠ toResource ∧ amountIn > 0 ∧
          fromBal + amountIn < Laws.maxAmount
      · rw [if_pos hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        refine aliasConsistent_pair _ _ _ _ (fun hk => ?_)
        exact absurd ((Prod.mk.injEq ..).mp hk).1 hpre.2.1
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read fromResource toResource
          ammReserveActor ammReserveActor fromBal toBal hf ht

/-- `deriveReclaimBalances` is alias-consistent: `reserveActor ≠
    poolActor` guards the admitted branch, and the refusal branch is a
    pair of pre-values. -/
theorem deriveReclaimBalances_alias_consistent (read : BalanceReader)
    (r : ResourceId) (reserveActor poolActor : ActorId) (amount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveReclaimBalances read r reserveActor poolActor amount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveReclaimBalances at h
  cases hs : read r reserveActor with
  | none => rw [hs] at h; cases read r poolActor <;> simp at h
  | some reserveBal =>
    cases hq : read r poolActor with
    | none => rw [hs, hq] at h; simp at h
    | some poolBal =>
      rw [hs, hq] at h
      simp only [] at h
      by_cases hpre : reserveBal = amount ∧ reserveActor ≠ poolActor ∧ amount > 0 ∧
          (if reserveActor = poolActor then reserveBal - amount else poolBal) + amount
            < Laws.maxAmount
      · rw [if_pos hpre] at h
        exact deriveChainPair_alias_consistent read r reserveActor poolActor _ _ plan h
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read r r reserveActor poolActor
          reserveBal poolBal hs hq

/-- `deriveDelegatedTopUpBalances` is alias-consistent, by the same
    split as its self-service sibling. -/
theorem deriveDelegatedTopUpBalances_alias_consistent (read : BalanceReader)
    (gr : ResourceId) (payer poolActor recipient : ActorId) (gasAmount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveDelegatedTopUpBalances read gr payer poolActor recipient gasAmount
           = some plan) :
    aliasConsistent plan = true := by
  unfold deriveDelegatedTopUpBalances at h
  cases hp : read gr payer with
  | none => rw [hp] at h; cases read gr poolActor <;> simp at h
  | some payerBal =>
    cases hq : read gr poolActor with
    | none => rw [hp, hq] at h; simp at h
    | some poolBal =>
      rw [hp, hq] at h
      simp only [] at h
      by_cases hpre : gasAmount ≤ payerBal ∧ recipient ≠ payer ∧
          (if payer = poolActor then payerBal - gasAmount else poolBal) + gasAmount
            < Laws.maxAmount
      · rw [if_pos hpre] at h
        exact deriveChainPair_alias_consistent read gr payer poolActor _ _ plan h
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read gr gr payer poolActor payerBal poolBal hp hq

/-- `deriveDepositWithFeeBalances` is alias-consistent.

    It used to BE a bare `deriveChainPair`, so the chained pair's own
    lemma covered it and `plannedBalances_alias_consistent` invoked
    that directly.  The C-3 ceiling put a guard in front, so the
    refusal branch is now a pair of pre-values and needs the same
    two-case split every other guarded pair takes. -/
theorem deriveDepositWithFeeBalances_alias_consistent (read : BalanceReader)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveDepositWithFeeBalances read r recipient poolActor
           userAmount poolAmount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveDepositWithFeeBalances at h
  cases hr : read r recipient with
  | none => rw [hr] at h; cases read r poolActor <;> simp at h
  | some recipBal =>
    cases hq : read r poolActor with
    | none => rw [hr, hq] at h; simp at h
    | some poolBal =>
      rw [hr, hq] at h
      simp only [] at h
      by_cases hpre : recipBal + userAmount < Laws.maxAmount ∧
          (if recipient = poolActor then recipBal + userAmount else poolBal)
            + poolAmount < Laws.maxAmount
      · rw [if_pos hpre] at h
        exact deriveChainPair_alias_consistent read r recipient poolActor _ _ plan h
      · rw [if_neg hpre] at h
        simp only [Option.some.injEq] at h
        subst h
        exact aliasConsistent_read_pair read r r recipient poolActor
          recipBal poolBal hr hq

/-- The four single-cell derivations are alias-consistent: one entry
    cannot alias anything. -/
theorem deriveCreditBalance_alias_consistent (read : BalanceReader)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveCreditBalance read r to amount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveCreditBalance at h
  cases hb : read r to with
  | none => rw [hb] at h; simp at h
  | some bal =>
    rw [hb] at h
    simp only [] at h
    by_cases hpos : amount > 0 ∧ bal + amount < Laws.maxAmount
    · rw [if_pos hpos] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _
    · rw [if_neg hpos] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _

/-- `deriveBurnBalance` writes one cell. -/
theorem deriveBurnBalance_alias_consistent (read : BalanceReader)
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveBurnBalance read r fromActor amount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveBurnBalance at h
  cases hb : read r fromActor with
  | none => rw [hb] at h; simp at h
  | some bal =>
    rw [hb] at h
    simp only [] at h
    by_cases hpre : amount > 0 ∧ amount ≤ bal
    · rw [if_pos hpre] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _
    · rw [if_neg hpre] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _

/-- `deriveDepositBalance` writes one cell. -/
theorem deriveDepositBalance_alias_consistent (read : BalanceReader)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveDepositBalance read r recipient amount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveDepositBalance at h
  cases hb : read r recipient with
  | none => rw [hb] at h; simp at h
  | some bal =>
    rw [hb] at h
    simp only [] at h
    by_cases hpre : bal + amount < Laws.maxAmount
    · rw [if_pos hpre] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _
    · rw [if_neg hpre] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _

/-- `deriveWithdrawBalance` writes one cell. -/
theorem deriveWithdrawBalance_alias_consistent (read : BalanceReader)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (plan : List ((ResourceId × ActorId) × Nat))
    (h : deriveWithdrawBalance read r sender amount = some plan) :
    aliasConsistent plan = true := by
  unfold deriveWithdrawBalance at h
  cases hb : read r sender with
  | none => rw [hb] at h; simp at h
  | some bal =>
    rw [hb] at h
    simp only [] at h
    by_cases hpre : 0 < amount ∧ amount ≤ bal
    · rw [if_pos hpre] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _
    · rw [if_neg hpre] at h; simp only [Option.some.injEq] at h; subst h
      exact aliasConsistent_singleton _ _

/-! ## Reader congruence

A derivation reads a fixed, small set of cells and is otherwise blind
to the reader.  So two readers agreeing at those cells produce the same
plan — which is what lets the honest bundle's PARTIAL reader stand in
for the state's TOTAL one without the derivations knowing the
difference.

Stated per derivation rather than as one lemma over `plannedBalances`
because "the cells it reads" is a different set for each, and naming
them in the signature is what makes the hypothesis checkable at the
call site.  Each proof is the same two moves: rewrite the reads,
recurse into the chained pair where there is one.
-/

/-- `deriveChainPair` reads its two cells and nothing else. -/
theorem deriveChainPair_congr (read₁ read₂ : BalanceReader) (r : ResourceId)
    (x y : ActorId) (fx fy : Nat → Nat)
    (hx : read₁ r x = read₂ r x) (hy : read₁ r y = read₂ r y) :
    deriveChainPair read₁ r x y fx fy = deriveChainPair read₂ r x y fx fy := by
  unfold deriveChainPair; rw [hx, hy]

/-- `transfer` reads the sender's and the receiver's cells. -/
theorem deriveTransferBalances_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (hs : read₁ r sender = read₂ r sender)
    (hr : read₁ r receiver = read₂ r receiver) :
    deriveTransferBalances read₁ r sender receiver amount
      = deriveTransferBalances read₂ r sender receiver amount := by
  unfold deriveTransferBalances; rw [hs, hr]

/-- `mint` / `reward` read the credited cell. -/
theorem deriveCreditBalance_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (h : read₁ r to = read₂ r to) :
    deriveCreditBalance read₁ r to amount = deriveCreditBalance read₂ r to amount := by
  unfold deriveCreditBalance; rw [h]

/-- `burn` reads the debited cell. -/
theorem deriveBurnBalance_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (h : read₁ r fromActor = read₂ r fromActor) :
    deriveBurnBalance read₁ r fromActor amount
      = deriveBurnBalance read₂ r fromActor amount := by
  unfold deriveBurnBalance; rw [h]

/-- `deposit` reads the recipient's cell. -/
theorem deriveDepositBalance_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (h : read₁ r recipient = read₂ r recipient) :
    deriveDepositBalance read₁ r recipient amount
      = deriveDepositBalance read₂ r recipient amount := by
  unfold deriveDepositBalance; rw [h]

/-- `withdraw` reads the sender's cell. -/
theorem deriveWithdrawBalance_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (h : read₁ r sender = read₂ r sender) :
    deriveWithdrawBalance read₁ r sender amount
      = deriveWithdrawBalance read₂ r sender amount := by
  unfold deriveWithdrawBalance; rw [h]

/-- `depositWithFee` reads the recipient's and the pool's cells. -/
theorem deriveDepositWithFeeBalances_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount)
    (hr : read₁ r recipient = read₂ r recipient)
    (hp : read₁ r poolActor = read₂ r poolActor) :
    deriveDepositWithFeeBalances read₁ r recipient poolActor userAmount poolAmount
      = deriveDepositWithFeeBalances read₂ r recipient poolActor userAmount poolAmount := by
  unfold deriveDepositWithFeeBalances
  rw [hr, hp, deriveChainPair_congr read₁ read₂ r recipient poolActor
        (fun b => b + userAmount) (fun b => b + poolAmount) hr hp]

/-- `topUpActionBudget` reads the payer's and the pool's cells — both
    branches, since the failing one still returns their pre-values. -/
theorem deriveTopUpBalances_congr (read₁ read₂ : BalanceReader)
    (gr : ResourceId) (payer poolActor : ActorId) (gasAmount : Amount)
    (hp : read₁ gr payer = read₂ gr payer)
    (hq : read₁ gr poolActor = read₂ gr poolActor) :
    deriveTopUpBalances read₁ gr payer poolActor gasAmount
      = deriveTopUpBalances read₂ gr payer poolActor gasAmount := by
  unfold deriveTopUpBalances
  rw [hp, hq, deriveChainPair_congr read₁ read₂ gr payer poolActor
        (fun b => b - gasAmount) (fun b => b + gasAmount) hp hq]

/-- `topUpActionBudgetFor` reads the payer's and the pool's cells; the
    recipient enters only through the guard, not through a read. -/
theorem deriveDelegatedTopUpBalances_congr (read₁ read₂ : BalanceReader)
    (gr : ResourceId) (payer poolActor recipient : ActorId) (gasAmount : Amount)
    (hp : read₁ gr payer = read₂ gr payer)
    (hq : read₁ gr poolActor = read₂ gr poolActor) :
    deriveDelegatedTopUpBalances read₁ gr payer poolActor recipient gasAmount
      = deriveDelegatedTopUpBalances read₂ gr payer poolActor recipient gasAmount := by
  unfold deriveDelegatedTopUpBalances
  rw [hp, hq, deriveChainPair_congr read₁ read₂ gr payer poolActor
        (fun b => b - gasAmount) (fun b => b + gasAmount) hp hq]

/-- `claimBudgetRefund` reads the pool's and the claimant's cells. -/
theorem deriveRefundBalances_congr (read₁ read₂ : BalanceReader)
    (gr : ResourceId) (poolActor claimant : ActorId) (refundAmount : Amount)
    (hp : read₁ gr poolActor = read₂ gr poolActor)
    (hc : read₁ gr claimant = read₂ gr claimant) :
    deriveRefundBalances read₁ gr poolActor claimant refundAmount
      = deriveRefundBalances read₂ gr poolActor claimant refundAmount := by
  unfold deriveRefundBalances
  rw [hp, hc, deriveChainPair_congr read₁ read₂ gr poolActor claimant
        (fun b => b - refundAmount) (fun b => b + refundAmount) hp hc]

/-- `ammSwap` reads the reserve actor's cell at BOTH resources. -/
theorem deriveAmmSwapBalances_congr (read₁ read₂ : BalanceReader)
    (fromResource toResource : ResourceId) (amountIn amountOut : Amount)
    (ammReserveActor : ActorId)
    (hf : read₁ fromResource ammReserveActor = read₂ fromResource ammReserveActor)
    (ht : read₁ toResource ammReserveActor = read₂ toResource ammReserveActor) :
    deriveAmmSwapBalances read₁ fromResource toResource amountIn amountOut ammReserveActor
      = deriveAmmSwapBalances read₂ fromResource toResource amountIn amountOut
          ammReserveActor := by
  unfold deriveAmmSwapBalances; rw [hf, ht]

/-- `reclaimAmmReserves` reads the reserve actor's and the pool's
    cells. -/
theorem deriveReclaimBalances_congr (read₁ read₂ : BalanceReader)
    (r : ResourceId) (reserveActor poolActor : ActorId) (amount : Amount)
    (hres : read₁ r reserveActor = read₂ r reserveActor)
    (hpool : read₁ r poolActor = read₂ r poolActor) :
    deriveReclaimBalances read₁ r reserveActor poolActor amount
      = deriveReclaimBalances read₂ r reserveActor poolActor amount := by
  unfold deriveReclaimBalances
  rw [hres, hpool, deriveChainPair_congr read₁ read₂ r reserveActor poolActor
        (fun b => b - amount) (fun b => b + amount) hres hpool]

end FaultProof
end LegalKernel
