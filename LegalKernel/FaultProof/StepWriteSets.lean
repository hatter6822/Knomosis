-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.StepWriteSets — `WriteSetComplete` for the
production advance, per variant.

`CellWrites.lean` reduces the fault proof's per-variant obligation to
one property: the advance changes no cell the write set omits.  This
module discharges it against `productionApplyBudget`, the function the
runtime actually advances state through.

The work splits in two, and only the second half is per-variant:

  * **The field footprints of `productionApplyBudget` itself.**  Six of
    the seven `ExtendedState` fields have an action-independent story —
    the budget policy is never written, the six bridge scalars are
    never written, the nonce moves only at the signer, and the epoch
    budgets move only at the signer and at a grant recipient.  Proved
    once, here.
  * **The balance footprint of each law.**  `getBalance` after
    `step_impl` is where the twenty-five variants genuinely differ, and
    `Conservation.LocalTo` does not cover it: that class is about
    RESOURCE locality, and a step VM needs actor locality within a
    resource too (a transfer moves two actors at one resource, and the
    cell space is keyed by the pair).

Both bulk actions are out of scope by construction:
`distributeOthers` and `proportionalDilute` touch every non-excluded
actor's balance, which is unboundedly many cells and no `O(log N)`
opening bundle can carry.  They route through `FaultProof/SubStep.lean`
instead — see the plan's §4 item 4.

`docs/planning/state_root_merkleisation_plan.md` §4A.
-/

import LegalKernel.FaultProof.CellWrites
import LegalKernel.FaultProof.ProductionApply

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## `kernelOnlyApply`'s field projections

`kernelOnlyApply` computes the kernel step, advances the nonce, and
then mutates the registry or the local policies for four actions.  So
each field's post-value is a function of one layer, and naming them
keeps the per-variant proofs from re-deriving the same reduction. -/

/-- The kernel step is the whole of `kernelOnlyApply`'s effect on the
    base state; neither the nonce advance nor the registry / policy
    arms touch it. -/
theorem kernelOnlyApply_base (es : ExtendedState) (st : SignedAction) :
    (kernelOnlyApply es (signedActionEntry st)).base =
      step_impl es.base (Action.toTransition st.action st.signer) := by
  unfold kernelOnlyApply signedActionEntry
  cases st.action <;> rfl

/-- The nonce ledger after `kernelOnlyApply`: the signer's entry
    incremented, everything else untouched. -/
theorem kernelOnlyApply_nonces (es : ExtendedState) (st : SignedAction) :
    (kernelOnlyApply es (signedActionEntry st)).nonces =
      { next := es.nonces.next.insert st.signer
          (Authority.expectsNonce es st.signer + 1) } := by
  unfold kernelOnlyApply signedActionEntry
  cases st.action <;> rfl

/-- The epoch budgets and the budget policy are outside
    `kernelOnlyApply` entirely — the dispute pipeline's replay has no
    budget leg, which is exactly why the budget-cell gap was invisible
    from it. -/
theorem kernelOnlyApply_epochBudgets (es : ExtendedState) (st : SignedAction) :
    (kernelOnlyApply es (signedActionEntry st)).epochBudgets = es.epochBudgets := by
  unfold kernelOnlyApply signedActionEntry
  cases st.action <;> rfl

/-- ...and the policy likewise. -/
theorem kernelOnlyApply_budgetPolicy (es : ExtendedState) (st : SignedAction) :
    (kernelOnlyApply es (signedActionEntry st)).budgetPolicy = es.budgetPolicy := by
  unfold kernelOnlyApply signedActionEntry
  cases st.action <;> rfl

/-! ## `productionApplyBudget`'s field footprints

The three branches of `productionApplyBudget` differ in `epochBudgets`
and in nothing else, so every other field is read off
`productionApply` — and through it off `kernelOnlyApply`, except the
bridge. -/

/-- **The budget leg touches only `epochBudgets`.**  Stated
    existentially because which of the three branches is taken depends
    on the consume, and no caller needs to know: the point is that the
    other six fields are the same either way. -/
theorem productionApplyBudget_eq_productionApply_off_budget
    (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    ∃ ebs : EpochBudgetState,
      productionApplyBudget es st idx =
        { productionApply es st idx with epochBudgets := ebs } := by
  unfold productionApplyBudget
  cases h_pol : es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    simp only []
    by_cases h : st.signer = bridgeActor
    · refine ⟨budgetGrant st.signer st.action freeTier currentEpoch es.epochBudgets, ?_⟩
      simp only [if_pos h]
    · simp only [if_neg h]
      cases _hc : EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
                    freeTier (actionCost + refundConsumeExtra st.action) with
      | none      => exact ⟨(productionApply es st idx).epochBudgets, rfl⟩
      | some ebs' =>
        exact ⟨budgetGrant st.signer st.action freeTier currentEpoch ebs', rfl⟩

/-- The base state after the production advance is the kernel step. -/
theorem productionApplyBudget_base (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    (productionApplyBudget es st idx).base =
      step_impl es.base (Action.toTransition st.action st.signer) := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  rw [h]
  show (productionApply es st idx).base = _
  unfold productionApply
  exact kernelOnlyApply_base es st

/-- **The budget policy is never written.**  No `Action` constructor
    changes the deployment's policy; epoch advancement is a runtime
    concern threaded through `ExtendedState`, not a step effect. -/
theorem productionApplyBudget_budgetPolicy
    (es : ExtendedState) (st : SignedAction) (idx : Nat) :
    (productionApplyBudget es st idx).budgetPolicy = es.budgetPolicy := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  rw [h]
  show (productionApply es st idx).budgetPolicy = _
  unfold productionApply
  exact kernelOnlyApply_budgetPolicy es st

/-- **The nonce moves only at the signer.** -/
theorem productionApplyBudget_expectsNonce_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (a : ActorId)
    (h_ne : a ≠ st.signer) :
    Authority.expectsNonce (productionApplyBudget es st idx) a =
      Authority.expectsNonce es a := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  have h_n : (productionApplyBudget es st idx).nonces
      = { next := es.nonces.next.insert st.signer
            (Authority.expectsNonce es st.signer + 1) } := by
    rw [h]
    show (kernelOnlyApply es (signedActionEntry st)).nonces = _
    exact kernelOnlyApply_nonces es st
  show (productionApplyBudget es st idx).nonces.next[a]?.getD 0 = _
  rw [h_n]
  show (es.nonces.next.insert st.signer _)[a]?.getD 0 = _
  rw [LegalKernel.RBMap.find?_insert_other _ st.signer a _ (Ne.symm h_ne)]
  rfl


/-! ### The epoch budgets

Two actors can move: the signer (the consume) and, for the three
budget-granting actions, the grant recipient.  `budgetGrant` names the
latter, so the footprint is stated against it rather than against a
constructor list. -/

/-- `budgetGrant` writes at most one actor's budget, and names which. -/
theorem budgetGrant_getElem?_of_ne (signer : ActorId) (action : Action)
    (freeTier currentEpoch : Nat) (ebs : EpochBudgetState) (a : ActorId)
    (h_dwf : ∀ r recipient poolActor ua pa bg d,
      action = .depositWithFee r recipient poolActor ua pa bg d → a ≠ recipient)
    (h_top : ∀ gr ga bi pa, action = .topUpActionBudget gr ga bi pa → a ≠ signer)
    (h_for : ∀ recipient gr ga bi pa,
      action = .topUpActionBudgetFor recipient gr ga bi pa → a ≠ recipient) :
    (budgetGrant signer action freeTier currentEpoch ebs)[a]? = ebs[a]? := by
  unfold budgetGrant EpochBudgetState.topUp
  cases hact : action with
  | depositWithFee r recipient poolActor ua pa bg d =>
    exact LegalKernel.RBMap.find?_insert_other _ recipient a _
      (fun he => h_dwf r recipient poolActor ua pa bg d hact (he ▸ rfl))
  | topUpActionBudget gr ga bi pa =>
    exact LegalKernel.RBMap.find?_insert_other _ signer a _
      (fun he => h_top gr ga bi pa hact (he ▸ rfl))
  | topUpActionBudgetFor recipient gr ga bi pa =>
    exact LegalKernel.RBMap.find?_insert_other _ recipient a _
      (fun he => h_for recipient gr ga bi pa hact (he ▸ rfl))
  | _ => rfl

/-- **The epoch budgets move only at the signer and the grant
    recipient.**

    The `a ≠ signer` hypothesis covers the consume, whose write-back is
    unconditional — `EpochBudgetState.consume` ends in `ebs.insert a b'`
    even when it only normalises across an epoch boundary.  The three
    grant hypotheses cover `budgetGrant`. -/
theorem productionApplyBudget_epochBudgets_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (a : ActorId)
    (h_signer : a ≠ st.signer)
    (h_dwf : ∀ r recipient poolActor ua pa bg d,
      st.action = .depositWithFee r recipient poolActor ua pa bg d → a ≠ recipient)
    (h_for : ∀ recipient gr ga bi pa,
      st.action = .topUpActionBudgetFor recipient gr ga bi pa → a ≠ recipient) :
    (productionApplyBudget es st idx).epochBudgets[a]? = es.epochBudgets[a]? := by
  have h_grant : ∀ ebs : EpochBudgetState,
      (budgetGrant st.signer st.action
        (match es.budgetPolicy with | .bounded ft _ _ => ft)
        (match es.budgetPolicy with | .bounded _ _ ce => ce) ebs)[a]? = ebs[a]? := by
    intro ebs
    exact budgetGrant_getElem?_of_ne _ _ _ _ _ _ h_dwf
      (fun _ _ _ _ _ => h_signer) h_for
  unfold productionApplyBudget
  cases h_pol : es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    simp only []
    by_cases h : st.signer = bridgeActor
    · simp only [if_pos h]
      show (budgetGrant st.signer st.action freeTier currentEpoch es.epochBudgets)[a]? = _
      exact budgetGrant_getElem?_of_ne _ _ _ _ _ _ h_dwf
        (fun _ _ _ _ _ => h_signer) h_for
    · simp only [if_neg h]
      cases hc : EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
                   freeTier (actionCost + refundConsumeExtra st.action) with
      | none      =>
        show (productionApply es st idx).epochBudgets[a]? = _
        unfold productionApply
        show (kernelOnlyApply es (signedActionEntry st)).epochBudgets[a]? = _
        rw [kernelOnlyApply_epochBudgets es st]
      | some ebs' =>
        show (budgetGrant st.signer st.action freeTier currentEpoch ebs')[a]? = _
        rw [budgetGrant_getElem?_of_ne _ _ _ _ _ _ h_dwf
          (fun _ _ _ _ _ => h_signer) h_for]
        -- The consume's write-back is an insert at the SIGNER, so it
        -- too misses `a`.
        unfold EpochBudgetState.consume at hc
        cases hb : (es.epochBudgets[st.signer]?.getD ActorBudget.empty).consume
                     currentEpoch freeTier (actionCost + refundConsumeExtra st.action) with
        | none   => rw [hb] at hc; exact absurd hc (by simp)
        | some b =>
          rw [hb] at hc
          have : ebs' = es.epochBudgets.insert st.signer b := by
            injection hc with hc'; exact hc'.symm
          rw [this]
          exact LegalKernel.RBMap.find?_insert_other _ st.signer a _ (Ne.symm h_signer)

/-! ## Registry and local policies

Four actions mutate one of these, each at a single key the write set
declares.  The remaining twenty-one leave both alone. -/

/-- The registry after one production advance, at any actor the
    mutating actions do not name. -/
theorem productionApplyBudget_registry_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (a : ActorId)
    (h_rk : ∀ actor newKey, st.action = .replaceKey actor newKey → a ≠ actor)
    (h_ri : ∀ actor pk, st.action = .registerIdentity actor pk → a ≠ actor) :
    (productionApplyBudget es st idx).registry[a]? = es.registry[a]? := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  rw [h]
  show (kernelOnlyApply es (signedActionEntry st)).registry[a]? = _
  unfold kernelOnlyApply signedActionEntry
  cases hact : st.action with
  | replaceKey actor newKey =>
    exact LegalKernel.RBMap.find?_insert_other _ actor a _
      (fun he => h_rk actor newKey hact (he ▸ rfl))
  | registerIdentity actor pk =>
    exact LegalKernel.RBMap.find?_insert_other _ actor a _
      (fun he => h_ri actor pk hact (he ▸ rfl))
  | _ => rfl

/-- The local policies after one production advance, at any actor other
    than the signer of a policy meta-action. -/
theorem productionApplyBudget_localPolicies_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (a : ActorId)
    (h_dec : ∀ policy, st.action = .declareLocalPolicy policy → a ≠ st.signer)
    (h_rev : st.action = .revokeLocalPolicy → a ≠ st.signer) :
    (productionApplyBudget es st idx).localPolicies[a]? = es.localPolicies[a]? := by
  obtain ⟨_, h⟩ := productionApplyBudget_eq_productionApply_off_budget es st idx
  rw [h]
  show (kernelOnlyApply es (signedActionEntry st)).localPolicies[a]? = _
  unfold kernelOnlyApply signedActionEntry
  cases hact : st.action with
  | declareLocalPolicy policy =>
    show (es.localPolicies.declare st.signer policy)[a]? = _
    unfold Authority.LocalPolicies.declare
    exact LegalKernel.RBMap.find?_insert_other _ st.signer a _
      (fun he => h_dec policy hact (he ▸ rfl))
  | revokeLocalPolicy =>
    show (es.localPolicies.revoke st.signer)[a]? = _
    unfold Authority.LocalPolicies.revoke
    rw [Std.TreeMap.getElem?_erase]
    have h_ne : compare st.signer a ≠ .eq := fun he =>
      (h_rev hact) (Std.LawfulEqCmp.eq_of_compare he).symm
    simp [h_ne]
  | _ => rfl

/-! ### The bridge scalars

`applyActionToBridgeState` writes `consumed`, `pending` and `nextWdId`.
It writes nothing else, and the six scalars below are the "nothing
else" made checkable — a future bridge action that touched one would
break these rather than silently escaping the write set. -/

/-- Every bridge field the step VM does not write survives one
    `applyActionToBridgeState`, packaged as the six equations
    `writeSetComplete_of_field_footprints` asks for. -/
theorem applyActionToBridgeState_scalars
    (bs : BridgeState) (action : Action) (idx : Nat) :
    (applyActionToBridgeState bs action idx).ammReserveEth = bs.ammReserveEth ∧
    (applyActionToBridgeState bs action idx).ammReserveBold = bs.ammReserveBold ∧
    (applyActionToBridgeState bs action idx).boldCircuitClosed = bs.boldCircuitClosed ∧
    (applyActionToBridgeState bs action idx).boldTvlCap = bs.boldTvlCap ∧
    (applyActionToBridgeState bs action idx).boldTotalLockedValue
      = bs.boldTotalLockedValue ∧
    (applyActionToBridgeState bs action idx).ammDisabled = bs.ammDisabled := by
  unfold applyActionToBridgeState
  cases action <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩


/-! ## The bridge maps

`applyActionToBridgeState` writes `consumed` at a deposit's id,
`pending` at the pre-state's `nextWdId`, and the counter itself.  Each
key is one the write set declares — the pending one only since
`Action.writeCellsAt`, which is the whole reason that function
exists. -/

/-- A consumed-deposit cell moves only at the action's own deposit
    id. -/
theorem productionApplyBudget_bridgeConsumed_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (d : Bridge.DepositId)
    (h_dep : ∀ r recipient amount d', st.action = .deposit r recipient amount d' → d ≠ d')
    (h_dwf : ∀ r recipient poolActor ua pa bg d',
      st.action = .depositWithFee r recipient poolActor ua pa bg d' → d ≠ d') :
    (productionApplyBudget es st idx).bridge.consumed[d]? = es.bridge.consumed[d]? := by
  rw [productionApplyBudget_bridge]
  unfold applyActionToBridgeState
  cases hact : st.action with
  | deposit r recipient amount d' =>
    show (es.bridge.markConsumed d' _).consumed[d]? = _
    unfold Bridge.BridgeState.markConsumed
    exact LegalKernel.RBMap.find?_insert_other _ d' d _
      (fun he => h_dep r recipient amount d' hact (he ▸ rfl))
  | depositWithFee r recipient poolActor ua pa bg d' =>
    show (es.bridge.markConsumed d' _).consumed[d]? = _
    unfold Bridge.BridgeState.markConsumed
    exact LegalKernel.RBMap.find?_insert_other _ d' d _
      (fun he => h_dwf r recipient poolActor ua pa bg d' hact (he ▸ rfl))
  | _ => rfl

/-- A pending-withdrawal cell moves only at the pre-state's
    `nextWdId` — the key `Action.writeCells` could not name. -/
theorem productionApplyBudget_bridgePending_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat) (w : Bridge.WithdrawalId)
    (h_wd : ∀ r sender amount rcp,
      st.action = .withdraw r sender amount rcp → w ≠ es.bridge.nextWdId) :
    (productionApplyBudget es st idx).bridge.pending[w]? = es.bridge.pending[w]? := by
  rw [productionApplyBudget_bridge]
  unfold applyActionToBridgeState
  cases hact : st.action with
  | withdraw r sender amount rcp =>
    show (es.bridge.appendWithdrawal _).pending[w]? = _
    unfold Bridge.BridgeState.appendWithdrawal
    exact LegalKernel.RBMap.find?_insert_other _ es.bridge.nextWdId w _
      (fun he => h_wd r sender amount rcp hact he.symm)
  | _ => rfl

/-- The withdrawal counter moves only on a withdrawal. -/
theorem productionApplyBudget_bridgeNextWdId_of_ne
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_wd : ∀ r sender amount rcp, st.action ≠ .withdraw r sender amount rcp) :
    (productionApplyBudget es st idx).bridge.nextWdId = es.bridge.nextWdId := by
  rw [productionApplyBudget_bridge]
  unfold applyActionToBridgeState
  cases hact : st.action with
  | withdraw r sender amount rcp => exact absurd hact (h_wd r sender amount rcp)
  | _ => rfl

/-! ## Balance footprints

The per-variant half.  `step_impl` is `if pre then apply_impl else id`,
so a failing precondition makes the step a no-op and the footprint
holds vacuously — which is why these are stated UNCONDITIONALLY rather
than under the law's precondition, unlike the
`*_does_not_touch_other_resources` family they generalise.  A fault
proof adjudicates a step whose admissibility is not in evidence, so an
unconditional statement is the one it can use. -/

/-- Lift a footprint on `apply_impl` through the precondition guard. -/
theorem getBalance_step_impl_of_untouched
    (s : State) (t : Transition) (r : ResourceId) (a : ActorId)
    (h : getBalance (t.apply_impl s) r a = getBalance s r a) :
    getBalance (step_impl s t) r a = getBalance s r a := by
  unfold step_impl
  split
  · exact h
  · rfl

/-- A one-cell law: `setBalance` at a single `(resource, actor)` pair
    leaves every other cell alone. -/
theorem getBalance_setBalance_of_ne (s : State) (r₀ : ResourceId) (a₀ : ActorId)
    (v : Amount) (r : ResourceId) (a : ActorId) (h : (r₀, a₀) ≠ (r, a)) :
    getBalance (setBalance s r₀ a₀ v) r a = getBalance s r a :=
  getBalance_setBalance_other s r₀ r a₀ a v
    (by
      by_cases hr : r₀ = r
      · exact Or.inr (fun ha => h (by rw [hr, ha]))
      · exact Or.inl hr)


/-- A `CellTag` disequality read as a `(resource, actor)` pair
    disequality, which is the form `getBalance_setBalance_of_ne`
    consumes. -/
private theorem balance_pair_ne {r r' : ResourceId} {a a' : ActorId}
    (h : CellTag.balance r a ≠ CellTag.balance r' a') : (r', a') ≠ (r, a) := by
  intro he
  have h1 : r' = r := congrArg Prod.fst he
  have h2 : a' = a := congrArg Prod.snd he
  subst h1; subst h2
  exact h rfl

set_option linter.unusedSimpArgs false in
/-- **The balance footprint of every non-bulk variant.**

    The advance moves no balance cell the write set omits.  This is the
    per-variant half of `WriteSetComplete`, and the only half that is
    genuinely per-variant: the other six fields were settled above,
    action-independently.

    The two bulk actions are excluded by hypothesis rather than by a
    catch-all arm.  Their footprint is the whole non-excluded actor set
    at a resource — unboundedly many cells — so there is no finite write
    set to be complete against, and a proof that pretended otherwise
    would be the most dangerous kind of true statement.  They route
    through `FaultProof/SubStep.lean`.

    The linter option is scoped to this proof and is about the shared
    automation: one `simp only` list serves all twenty-five arms, and
    `withdraw` is the only one whose state-keyed write list is
    non-empty, so the append-elimination lemma is idle in the other
    twenty-four. -/
theorem productionApplyBudget_getBalance_of_not_written
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (r : ResourceId) (a : ActorId)
    (h_bulk₁ : ∀ x y z, st.action ≠ .distributeOthers x y z)
    (h_bulk₂ : ∀ x y z, st.action ≠ .proportionalDilute x y z)
    (h : CellTag.balance r a ∉ st.action.writeCellsAt es st.signer) :
    LegalKernel.getBalance (productionApplyBudget es st idx).base r a
      = LegalKernel.getBalance es.base r a := by
  rw [productionApplyBudget_base]
  refine getBalance_step_impl_of_untouched es.base _ r a ?_
  unfold Action.writeCellsAt Action.toTransition at *
  cases hact : st.action with
  | transfer r' sender receiver amount =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance ((Laws.transfer r' sender receiver amount).apply_impl es.base) r a = _
    simp only [Laws.transfer]
    rw [getBalance_setBalance_of_ne _ r' receiver _ r a
      (balance_pair_ne h.2.1)]
    exact getBalance_setBalance_of_ne _ r' sender _ r a
      (balance_pair_ne h.1)
  | mint r' to amount =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance ((Laws.mint r' to amount).apply_impl es.base) r a = _
    simp only [Laws.mint]
    exact getBalance_setBalance_of_ne _ r' to _ r a
      (balance_pair_ne h.1)
  | burn r' fromActor amount =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance ((Laws.burn r' fromActor amount).apply_impl es.base) r a = _
    simp only [Laws.burn]
    exact getBalance_setBalance_of_ne _ r' fromActor _ r a
      (balance_pair_ne h.1)
  | reward r' to amount =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance ((Laws.reward r' to amount).apply_impl es.base) r a = _
    simp only [Laws.reward]
    exact getBalance_setBalance_of_ne _ r' to _ r a
      (balance_pair_ne h.1)
  | deposit r' recipient amount d =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance ((Laws.deposit r' recipient amount d).apply_impl es.base) r a = _
    simp only [Laws.deposit]
    exact getBalance_setBalance_of_ne _ r' recipient _ r a
      (balance_pair_ne h.1)
  | withdraw r' sender amount rcp =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance ((Laws.withdraw r' sender amount rcp).apply_impl es.base) r a = _
    simp only [Laws.withdraw]
    -- `withdraw` is the one arm whose write set is an `append`, so its
    -- first conjunct is the STATIC half rather than the first cell.
    exact getBalance_setBalance_of_ne _ r' sender _ r a
      (balance_pair_ne h.1.1)
  | depositWithFee r' recipient poolActor ua pa bg d =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance
      ((Laws.depositWithFee r' recipient poolActor ua pa bg d).apply_impl es.base) r a = _
    simp only [Laws.depositWithFee]
    rw [getBalance_setBalance_of_ne _ r' poolActor _ r a
      (balance_pair_ne h.2.1)]
    exact getBalance_setBalance_of_ne _ r' recipient _ r a
      (balance_pair_ne h.1)
  | topUpActionBudget gr ga bi pa =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance
      ((Laws.topUpActionBudget st.signer gr ga bi pa).apply_impl es.base) r a = _
    simp only [Laws.topUpActionBudget]
    rw [getBalance_setBalance_of_ne _ gr pa _ r a
      (balance_pair_ne h.2.1)]
    exact getBalance_setBalance_of_ne _ gr st.signer _ r a
      (balance_pair_ne h.1)
  | topUpActionBudgetFor recipient gr ga bi pa =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance
      ((Laws.topUpActionBudgetFor recipient st.signer gr ga bi pa).apply_impl es.base) r a = _
    simp only [Laws.topUpActionBudgetFor]
    rw [getBalance_setBalance_of_ne _ gr pa _ r a
      (balance_pair_ne h.2.1)]
    exact getBalance_setBalance_of_ne _ gr st.signer _ r a
      (balance_pair_ne h.1)
  | claimBudgetRefund gr bu w pa =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance
      ((Laws.claimBudgetRefund st.signer pa gr (bu * w)).apply_impl es.base) r a = _
    simp only [Laws.claimBudgetRefund]
    rw [getBalance_setBalance_of_ne _ gr st.signer _ r a
      (balance_pair_ne h.1)]
    exact getBalance_setBalance_of_ne _ gr pa _ r a
      (balance_pair_ne h.2.1)
  | ammSwap fr tr amountIn amountOut ra =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance
      ((Laws.ammSwap fr tr amountIn amountOut ra).apply_impl es.base) r a = _
    simp only [Laws.ammSwap]
    rw [getBalance_setBalance_of_ne _ tr ra _ r a
      (balance_pair_ne h.2.1)]
    exact getBalance_setBalance_of_ne _ fr ra _ r a
      (balance_pair_ne h.1)
  | reclaimAmmReserves r' amount ra pa =>
    rw [hact] at h
    simp only [Action.writeCells, Action.stateWriteCells, List.append_nil,
      List.mem_append, List.mem_cons, List.not_mem_nil, or_false, not_or] at h
    show LegalKernel.getBalance
      ((Laws.reclaimAmmReserves r' amount ra pa).apply_impl es.base) r a = _
    simp only [Laws.reclaimAmmReserves]
    rw [getBalance_setBalance_of_ne _ r' pa _ r a
      (balance_pair_ne h.2.1)]
    exact getBalance_setBalance_of_ne _ r' ra _ r a
      (balance_pair_ne h.1)
  | distributeOthers x y z => exact absurd hact (h_bulk₁ x y z)
  | proportionalDilute x y z => exact absurd hact (h_bulk₂ x y z)
  -- The kernel-identity family: `apply_impl` is `fun s => s`, so the
  -- footprint is empty and every balance cell survives.
  | freezeResource _ => rfl
  | replaceKey _ _ => rfl
  | dispute _ => rfl
  | disputeWithdraw _ => rfl
  | verdict _ => rfl
  | rollback _ => rfl
  | registerIdentity _ _ => rfl
  | declareLocalPolicy _ => rfl
  | revokeLocalPolicy => rfl
  | faultProofChallenge _ _ _ _ => rfl
  | faultProofResolution _ _ _ _ => rfl


/-! ## Assembling `WriteSetComplete`

Every footprint above is now in the shape
`writeSetComplete_of_field_footprints` consumes.  What is left is to
turn "the cell is not in the write set" into the disequalities each
footprint asks for — pure list membership over a concrete list, with
no state reasoning in it. -/

/-- Every action advances the signer's nonce, so the cell is always
    declared.  This is the mechanised form of the §4.13 contract. -/
theorem mem_writeCellsAt_nonce (es : ExtendedState) (action : Action) (signer : ActorId) :
    CellTag.nonce signer ∈ action.writeCellsAt es signer := by
  unfold Action.writeCellsAt Action.writeCells Action.stateWriteCells
  cases action <;> simp

/-- ...and, under a `.bounded` policy, consumes the signer's budget. -/
theorem mem_writeCellsAt_epochBudget
    (es : ExtendedState) (action : Action) (signer : ActorId) :
    CellTag.epochBudget signer ∈ action.writeCellsAt es signer := by
  unfold Action.writeCellsAt Action.writeCells Action.stateWriteCells
  cases action <;> simp

/-- `replaceKey` declares the key it replaces. -/
theorem mem_writeCellsAt_registry_replaceKey
    (es : ExtendedState) (actor : ActorId) (newKey : Authority.PublicKey)
    (signer : ActorId) :
    CellTag.registry actor ∈ (Action.replaceKey actor newKey).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- `registerIdentity` declares the key it registers. -/
theorem mem_writeCellsAt_registry_registerIdentity
    (es : ExtendedState) (actor : ActorId) (pk : Authority.PublicKey) (signer : ActorId) :
    CellTag.registry actor ∈ (Action.registerIdentity actor pk).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- `declareLocalPolicy` declares the signer's policy cell. -/
theorem mem_writeCellsAt_localPolicy_declare
    (es : ExtendedState) (policy : Authority.LocalPolicy) (signer : ActorId) :
    CellTag.localPolicy signer
      ∈ (Action.declareLocalPolicy policy).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- `revokeLocalPolicy` likewise. -/
theorem mem_writeCellsAt_localPolicy_revoke
    (es : ExtendedState) (signer : ActorId) :
    CellTag.localPolicy signer ∈ Action.revokeLocalPolicy.writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- `deposit` declares the deposit id it consumes. -/
theorem mem_writeCellsAt_consumed_deposit
    (es : ExtendedState) (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : Bridge.DepositId) (signer : ActorId) :
    CellTag.bridgeConsumed d
      ∈ (Action.deposit r recipient amount d).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- `depositWithFee` likewise. -/
theorem mem_writeCellsAt_consumed_depositWithFee
    (es : ExtendedState) (r : ResourceId) (recipient poolActor : ActorId)
    (ua pa : Amount) (bg : Nat) (d : Bridge.DepositId) (signer : ActorId) :
    CellTag.bridgeConsumed d
      ∈ (Action.depositWithFee r recipient poolActor ua pa bg d).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- **The cell `Action.writeCells` could not name.**  `withdraw`
    allocates its pending entry at the pre-state's counter, and
    `writeCellsAt` is where that becomes declarable. -/
theorem mem_writeCellsAt_pending_withdraw
    (es : ExtendedState) (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : Bridge.EthAddress) (signer : ActorId) :
    CellTag.bridgePending es.bridge.nextWdId
      ∈ (Action.withdraw r sender amount rcp).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- `withdraw` also declares the counter it bumps. -/
theorem mem_writeCellsAt_nextWdId_withdraw
    (es : ExtendedState) (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : Bridge.EthAddress) (signer : ActorId) :
    CellTag.bridgeNextWdId
      ∈ (Action.withdraw r sender amount rcp).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- The two budget-GRANTING actions whose grant lands on someone other
    than the signer declare that recipient's budget cell. -/
theorem mem_writeCellsAt_epochBudget_depositWithFee
    (es : ExtendedState) (r : ResourceId) (recipient poolActor : ActorId)
    (ua pa : Amount) (bg : Nat) (d : Bridge.DepositId) (signer : ActorId) :
    CellTag.epochBudget recipient
      ∈ (Action.depositWithFee r recipient poolActor ua pa bg d).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- ...and the delegated top-up likewise. -/
theorem mem_writeCellsAt_epochBudget_topUpFor
    (es : ExtendedState) (recipient : ActorId) (gr : ResourceId)
    (ga : Amount) (bi : Nat) (pa signer : ActorId) :
    CellTag.epochBudget recipient
      ∈ (Action.topUpActionBudgetFor recipient gr ga bi pa).writeCellsAt es signer := by
  simp [Action.writeCellsAt, Action.writeCells, Action.stateWriteCells]

/-- **`WriteSetComplete` for the production advance, on every
    non-bulk action.**

    This is what `docs/planning/state_root_merkleisation_plan.md` §4A
    asks for on the Lean side.  Composed with
    `fold_stepCellWrites_eq_commit_post`, it says the L1's fold of a
    step's proven writes lands on exactly the root an honest sequencer
    publishes — the property the fault-proof game has never had and
    cannot adjudicate without.

    The bulk exclusions are the same two as
    `productionApplyBudget_getBalance_of_not_written`, and for the same
    reason: no finite write set is complete for an action that touches
    every actor's balance, so they route through
    `FaultProof/SubStep.lean` instead. -/
theorem writeSetComplete_productionApplyBudget
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_bulk₁ : ∀ x y z, st.action ≠ .distributeOthers x y z)
    (h_bulk₂ : ∀ x y z, st.action ≠ .proportionalDilute x y z) :
    WriteSetComplete es (productionApplyBudget es st idx) st.action st.signer :=
  writeSetComplete_of_field_footprints es _ st.action st.signer
    (fun r a h => productionApplyBudget_getBalance_of_not_written es st idx r a
      h_bulk₁ h_bulk₂ h)
    (fun a h => productionApplyBudget_expectsNonce_of_ne es st idx a (by
      intro he; subst he; exact h (mem_writeCellsAt_nonce es st.action st.signer)))
    (fun a h => productionApplyBudget_registry_of_ne es st idx a
      (by intro actor newKey hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_registry_replaceKey es a newKey st.signer))
      (by intro actor pk hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_registry_registerIdentity es a pk st.signer)))
    (fun a h => productionApplyBudget_localPolicies_of_ne es st idx a
      (by intro policy hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_localPolicy_declare es policy st.signer))
      (by intro hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_localPolicy_revoke es st.signer)))
    (fun d h => productionApplyBudget_bridgeConsumed_of_ne es st idx d
      (by intro r recipient amount d' hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_consumed_deposit es r recipient amount d st.signer))
      (by intro r recipient poolActor ua pa bg d' hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_consumed_depositWithFee es r recipient poolActor
            ua pa bg d st.signer)))
    (fun w h => productionApplyBudget_bridgePending_of_ne es st idx w
      (by intro r sender amount rcp hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_pending_withdraw es r sender amount rcp st.signer)))
    (fun h => productionApplyBudget_bridgeNextWdId_of_ne es st idx
      (by intro r sender amount rcp hact
          rw [hact] at h
          exact h (mem_writeCellsAt_nextWdId_withdraw es r sender amount rcp st.signer)))
    ((productionApplyBudget_bridge es st idx) ▸
      (applyActionToBridgeState_scalars es.bridge st.action idx).1)
    ((productionApplyBudget_bridge es st idx) ▸
      (applyActionToBridgeState_scalars es.bridge st.action idx).2.1)
    ((productionApplyBudget_bridge es st idx) ▸
      (applyActionToBridgeState_scalars es.bridge st.action idx).2.2.1)
    ((productionApplyBudget_bridge es st idx) ▸
      (applyActionToBridgeState_scalars es.bridge st.action idx).2.2.2.1)
    ((productionApplyBudget_bridge es st idx) ▸
      (applyActionToBridgeState_scalars es.bridge st.action idx).2.2.2.2.1)
    ((productionApplyBudget_bridge es st idx) ▸
      (applyActionToBridgeState_scalars es.bridge st.action idx).2.2.2.2.2)
    (fun a h => productionApplyBudget_epochBudgets_of_ne es st idx a
      (by intro he; subst he
          exact h (mem_writeCellsAt_epochBudget es st.action st.signer))
      (by intro r recipient poolActor ua pa bg d hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_epochBudget_depositWithFee es r a poolActor
            ua pa bg d st.signer))
      (by intro recipient gr ga bi pa hact he
          subst he; rw [hact] at h
          exact h (mem_writeCellsAt_epochBudget_topUpFor es a gr ga bi pa st.signer)))
    (productionApplyBudget_budgetPolicy es st idx)


/-! ## The §4A headline

Composing completeness with the chain machinery.  What the L1 folds
out of a pre-root and a bundle of proven writes is the root an honest
sequencer publishes for the post-state. -/

/-- **A step's write bundle folds the pre-root onto the published
    post-root.**

    Every hypothesis is either standing well-formedness (the SMT side
    conditions and `CanonicalBounds`, which the commitment layer
    already carries), a bulk exclusion, or the append-only restriction
    that no `Action` violates.  Nothing here is a fact about a
    particular variant — those were discharged in
    `writeSetComplete_productionApplyBudget`.

    `Nodup` is the one hypothesis a caller must check per step rather
    than per deployment, and the reason is a real shape rather than an
    artefact: a SELF-transfer names `.balance r sender` twice, because
    sender and receiver coincide.  The fold still lands correctly there
    — a later write to the same cell wins, matching the production
    advance's own composition order — but the split-at-the-occurrence
    argument that reads each written cell back needs uniqueness, so it
    is required rather than quietly assumed. -/
theorem fold_stepWrites_eq_commit_productionApplyBudget
    (es : ExtendedState) (st : SignedAction) (idx : Nat)
    (h_bulk₁ : ∀ x y z, st.action ≠ .distributeOthers x y z)
    (h_bulk₂ : ∀ x y z, st.action ≠ .proportionalDilute x y z)
    (h_ready : CellWritesReady es
      (stepCellWrites es (productionApplyBudget es st idx) st.action st.signer))
    (h_nodup : (st.action.writeCellsAt es st.signer).Nodup)
    (h_bounds : ExtendedState.CanonicalBounds (productionApplyBudget es st idx))
    (h_wf : BitsDistinctBelow smtDepth
      (stateCellEntries (productionApplyBudget es st idx)))
    (h_append : ∀ t : CellTag, t.appendOnly = true →
      getCellValue (productionApplyBudget es st idx) t = canonicalAbsentValue t →
      getCellValue es t = canonicalAbsentValue t) :
    foldStateCellWrites (commitExtendedState es)
        (chainWrites es (canonicalCellChain es
          (stepCellWrites es (productionApplyBudget es st idx) st.action st.signer)))
      = some (commitExtendedState (productionApplyBudget es st idx)) :=
  fold_stepCellWrites_eq_commit_post es (productionApplyBudget es st idx)
    st.action st.signer h_ready
    (writeSetComplete_productionApplyBudget es st idx h_bulk₁ h_bulk₂)
    h_nodup h_bounds h_wf h_append

end FaultProof
end LegalKernel
