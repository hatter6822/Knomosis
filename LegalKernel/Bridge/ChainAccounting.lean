-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.ChainAccounting — Workstream CA (chain-level bridge
accounting; GENESIS_PLAN §7.6.4 / §7.6.5; audit finding m-16).

`Accounting.lean` ships the per-action accounting deltas at the unit-step
level and notes that the chain closure "just lifts what is already
proved here" over "a custom `BridgeReachable` predicate [that] Phase-3 /
Phase-4-prelude / Phase-6 do not currently expose."  `Bridge/Reachable.lean`
now exposes that predicate; this module performs the lift.

The conservation invariant `BridgeConserves` states, at every resource,
that the L2 escrow backing (deposits minus withdrawals) is mirrored by
the L2 circulating supply — written additively to avoid `Nat`
truncation: `totalWithdrawn + TotalSupply = totalDeposited`.  Each bridge
transition moves the deposit/withdrawal ledger and the L2 supply in
lockstep (deposit mints, withdrawal burns), so the invariant is preserved
along any `BridgeReachable` chain; from a genesis base case it yields
solvency (`totalWithdrawn ≤ totalDeposited`), which makes the §7.6.4
accounting equation hold unconditionally along bridge chains.

This module is **not** part of the kernel TCB.
-/

import LegalKernel.Bridge.Reachable
import LegalKernel.Bridge.Accounting

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority
open Std

/-- The base-state advance of a `deposit` bridge step reduces to the
    kernel `step_impl` of the `deposit` law: the bridge override leaves
    `.base` untouched, and `toTransition` of a non-signer-aware action
    is its `compileTransition`, which for `deposit` is `Laws.deposit`. -/
theorem deposit_step_base
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip : ActorId} {amt : Amount} {dpid : DepositId}
    (haction : st.action = Action.deposit r₀ recip amt dpid)
    (h : BridgeAdmissibleWith verify P dep es st) :
    (apply_bridge_admissible_with verify P dep es st idx h).base
      = step_impl es.base (Laws.deposit r₀ recip amt dpid) := by
  rw [apply_bridge_admissible_with_base, haction]
  rfl

/-- The per-resource L2 supply delta of a `deposit` bridge step: supply
    at `r` rises by `amt` if the deposit is for `r`, else is unchanged.
    Folds the existing `totalSupply_after_deposit` (at the deposit's
    resource) and `deposit_conserves_other_resource` (elsewhere) through
    `deposit_step_base`. -/
theorem deposit_step_supply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip : ActorId} {amt : Amount} {dpid : DepositId}
    (haction : st.action = Action.deposit r₀ recip amt dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    TotalSupply (apply_bridge_admissible_with verify P dep es st idx h).base r
      = TotalSupply es.base r + (if r₀ = r then amt else 0) := by
  rw [deposit_step_base haction h]
  by_cases hr : r₀ = r
  · subst hr
    rw [if_pos rfl]
    exact Laws.totalSupply_after_deposit r₀ recip amt dpid es.base
  · rw [if_neg hr]
    exact Laws.deposit_conserves_other_resource r₀ r recip amt dpid es.base hr

/-- The base-state advance of a `withdraw` bridge step reduces to the
    kernel `step_impl` of the `withdraw` law. -/
theorem withdraw_step_base
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {sender : ActorId} {amt : Amount} {rcp : EthAddress}
    (haction : st.action = Action.withdraw r₀ sender amt rcp)
    (h : BridgeAdmissibleWith verify P dep es st) :
    (apply_bridge_admissible_with verify P dep es st idx h).base
      = step_impl es.base (Laws.withdraw r₀ sender amt rcp) := by
  rw [apply_bridge_admissible_with_base, haction]
  rfl

/-- The per-resource L2 supply delta of a `withdraw` bridge step: supply
    at `r` falls by `amt` if the withdrawal is for `r`, else is
    unchanged.  Stated additively (`supply' + burned = supply`) to avoid
    `Nat` truncation.  The burn is *exact* because admissibility forces
    the withdraw precondition `getBalance ≥ amt` (conjunct 5). -/
theorem withdraw_step_supply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {sender : ActorId} {amt : Amount} {rcp : EthAddress}
    (haction : st.action = Action.withdraw r₀ sender amt rcp)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    TotalSupply (apply_bridge_admissible_with verify P dep es st idx h).base r
        + (if r₀ = r then amt else 0)
      = TotalSupply es.base r := by
  rw [withdraw_step_base haction h]
  by_cases hr : r₀ = r
  · subst hr
    rw [if_pos rfl]
    have hpre : (Laws.withdraw r₀ sender amt rcp).pre es.base := by
      have hp := h.1.2.2.2.1
      rw [haction] at hp
      exact hp
    exact Laws.totalSupply_after_withdraw r₀ sender amt rcp es.base hpre
  · rw [if_neg hr, Nat.add_zero]
    exact Laws.withdraw_conserves_other_resource r₀ r sender amt rcp es.base hr

/-- At-resource L2 supply delta of the `depositWithFee` law: total
    supply at the deposit's resource rises by `userAmount + poolAmount`
    (the two mints to `recipient` and `poolActor`).  Mirrors the
    `totalSupply_after_deposit` law lemma; derived by applying the §8.1
    master lemma `totalSupply_setBalance` once per mint. -/
private theorem totalSupply_after_depositWithFee
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (d : DepositId)
    (s : State)
    (hpre : (Laws.depositWithFee r recipient poolActor userAmount poolAmount
              budgetGrant d).pre s) :
    TotalSupply (step_impl s (Laws.depositWithFee r recipient poolActor
        userAmount poolAmount budgetGrant d)) r
      = TotalSupply s r + (userAmount + poolAmount) := by
  rw [step_impl, if_pos hpre]
  show TotalSupply (setBalance (setBalance s r recipient
          (getBalance s r recipient + userAmount)) r poolActor
          (getBalance (setBalance s r recipient
            (getBalance s r recipient + userAmount)) r poolActor + poolAmount)) r
      = TotalSupply s r + (userAmount + poolAmount)
  have h1 := totalSupply_setBalance s r recipient (getBalance s r recipient + userAmount)
  have h2 := totalSupply_setBalance
      (setBalance s r recipient (getBalance s r recipient + userAmount)) r poolActor
      (getBalance (setBalance s r recipient (getBalance s r recipient + userAmount))
        r poolActor + poolAmount)
  omega

/-- The base-state advance of a `depositWithFee` bridge step reduces to
    the kernel `step_impl` of the `depositWithFee` law. -/
theorem depositWithFee_step_base
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip pool : ActorId} {ua pa : Amount}
    {bg : Nat} {dpid : DepositId}
    (haction : st.action = Action.depositWithFee r₀ recip pool ua pa bg dpid)
    (h : BridgeAdmissibleWith verify P dep es st) :
    (apply_bridge_admissible_with verify P dep es st idx h).base
      = step_impl es.base (Laws.depositWithFee r₀ recip pool ua pa bg dpid) := by
  rw [apply_bridge_admissible_with_base, haction]
  rfl

/-- The per-resource L2 supply delta of a `depositWithFee` bridge step:
    supply at `r` rises by `ua + pa` if the deposit is for `r`, else is
    unchanged. -/
theorem depositWithFee_step_supply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip pool : ActorId} {ua pa : Amount}
    {bg : Nat} {dpid : DepositId}
    (haction : st.action = Action.depositWithFee r₀ recip pool ua pa bg dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    TotalSupply (apply_bridge_admissible_with verify P dep es st idx h).base r
      = TotalSupply es.base r + (if r₀ = r then ua + pa else 0) := by
  rw [depositWithFee_step_base haction h]
  have hpre : (Laws.depositWithFee r₀ recip pool ua pa bg dpid).pre es.base := by
    have hp := h.1.2.2.2.1
    rw [haction] at hp
    exact hp
  by_cases hr : r₀ = r
  · subst hr
    rw [if_pos rfl]
    exact totalSupply_after_depositWithFee r₀ recip pool ua pa bg dpid es.base hpre
  · rw [if_neg hr, Nat.add_zero]
    unfold TotalSupply
    rw [Laws.depositWithFee_other_resource_untouched r₀ r recip pool ua pa bg dpid es.base hr]

/-! ## Withdrawal-ledger deltas

The `withdraw` step appends a `PendingWithdrawal` at the fresh key
`bs.nextWdId` (the monotonic counter), so its effect on the
`totalWithdrawn` fold is a `pending.insert` at an absent key.  The
freshness of `nextWdId` is the reachability invariant
`WithdrawalsMonotonic` below (it is *not* an admissibility fact). -/

/-- List-sum form of a `Nat`-projecting fold over the `pending` map.
    The withdrawal-ledger analogue of `Accounting.depositFold_eq_listSum`
    (re-derived here because that helper is `private`). -/
private theorem pendingFold_eq_listSum (f : PendingWithdrawal → Nat)
    (m : TreeMap WithdrawalId PendingWithdrawal compare) :
    m.foldl (fun acc _ wd => acc + f wd) 0 =
    (m.toList.map (fun p => f p.2)).sum := by
  have hmap : m.foldl (fun acc _ wd => acc + f wd) 0 =
      (m.toList.map (fun p => f p.2)).foldl (· + ·) 0 := by
    rw [TreeMap.foldl_eq_foldl_toList]
    generalize m.toList = l
    suffices h : ∀ (acc : Nat),
        l.foldl (fun a b => a + f b.2) acc =
        (l.map (fun p => f p.2)).foldl (· + ·) acc by
      exact h 0
    intro acc
    induction l generalizing acc with
    | nil => rfl
    | cons _ _ ih => simp only [List.foldl, List.map_cons]; exact ih _
  rw [hmap, ← List.sum_eq_foldl_nat]

/-- Fresh-insert delta for a projected `pending` fold: inserting a fresh
    `(k, v)` increases the fold by exactly `f v`.  Reduces to `List.sum`
    permutation invariance via `TreeMap.toList_insert_perm`, exactly as
    `Accounting.depositFold_insert_absent` does for the deposit ledger. -/
private theorem pendingFold_insert_absent (f : PendingWithdrawal → Nat)
    (m : TreeMap WithdrawalId PendingWithdrawal compare) (k : WithdrawalId)
    (v : PendingWithdrawal) (h : ¬ k ∈ m) :
    (m.insert k v).foldl (fun acc _ wd => acc + f wd) 0 =
    m.foldl (fun acc _ wd => acc + f wd) 0 + f v := by
  rw [pendingFold_eq_listSum f (m.insert k v), pendingFold_eq_listSum f m]
  have hperm :
      (m.insert k v).toList.Perm
        (⟨k, v⟩ :: m.toList.filter (fun x => decide ¬(k == x.fst) = true)) :=
    TreeMap.toList_insert_perm
  have hfilter :
      m.toList.filter (fun x => decide ¬(k == x.fst) = true) = m.toList := by
    apply List.filter_eq_self.mpr
    intro p hp
    simp only [decide_eq_true_eq]
    intro hbeq
    apply h
    rcases p with ⟨pk, pv⟩
    have hk : k = pk := LawfulBEq.eq_of_beq hbeq
    rw [hk, TreeMap.mem_iff_isSome_getElem?,
        TreeMap.mem_toList_iff_getElem?_eq_some.mp hp]
    rfl
  rw [hfilter] at hperm
  have hperm_vals :
      ((m.insert k v).toList.map (fun p => f p.2)).Perm
        (f v :: m.toList.map (fun p => f p.2)) := by
    have := hperm.map (fun p => f p.2)
    simpa using this
  rw [hperm_vals.sum_nat]
  simp only [List.sum_cons]
  omega

/-- Withdrawal ids are assigned monotonically: every id present in
    `pending` is strictly below `nextWdId`, the next id to assign.  This
    is the well-formedness invariant that makes each `appendWithdrawal`
    a fresh insert; it holds at genesis (empty `pending`) and is
    preserved by every bridge transition (`withdrawalsMonotonic_step`). -/
def WithdrawalsMonotonic (es : ExtendedState) : Prop :=
  ∀ k : WithdrawalId, k ∈ es.bridge.pending → k < es.bridge.nextWdId

/-- Under `WithdrawalsMonotonic`, the next withdrawal id is absent from
    `pending` (a present id would be strictly below itself). -/
theorem nextWdId_not_mem_of_monotonic {es : ExtendedState}
    (hmono : WithdrawalsMonotonic es) :
    ¬ es.bridge.nextWdId ∈ es.bridge.pending :=
  fun hmem => Nat.lt_irrefl _ (hmono _ hmem)

/-- Withdrawal-ledger delta of a `withdraw` bridge step: `totalWithdrawn`
    at `r` rises by `amt` if the withdrawal is for `r`, else is
    unchanged.  Uses the `WithdrawalsMonotonic` invariant to discharge
    the fresh-insert side condition. -/
theorem withdraw_step_withdrawn
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {sender : ActorId} {amt : Amount} {rcp : EthAddress}
    (haction : st.action = Action.withdraw r₀ sender amt rcp)
    (h : BridgeAdmissibleWith verify P dep es st)
    (hmono : WithdrawalsMonotonic es)
    (r : ResourceId) :
    totalWithdrawn (apply_bridge_admissible_with verify P dep es st idx h) r
      = totalWithdrawn es r + (if r₀ = r then amt else 0) := by
  have hbridge : (apply_bridge_admissible_with verify P dep es st idx h).bridge
      = es.bridge.appendWithdrawal
          { resource := r₀, recipient := rcp, amount := amt, l2LogIndex := idx } := by
    show applyActionToBridgeState es.bridge st.action idx = _
    rw [haction]
    rfl
  unfold totalWithdrawn
  rw [hbridge]
  exact pendingFold_insert_absent (fun wd => PendingWithdrawal.amountAt wd r)
    es.bridge.pending es.bridge.nextWdId
    { resource := r₀, recipient := rcp, amount := amt, l2LogIndex := idx }
    (nextWdId_not_mem_of_monotonic hmono)

/-- Withdrawal-ledger delta of a `deposit` bridge step: `totalWithdrawn`
    is unchanged (`markConsumed` leaves `pending` untouched). -/
theorem deposit_step_withdrawn
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip : ActorId} {amt : Amount} {dpid : DepositId}
    (haction : st.action = Action.deposit r₀ recip amt dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    totalWithdrawn (apply_bridge_admissible_with verify P dep es st idx h) r
      = totalWithdrawn es r := by
  have hpending : (apply_bridge_admissible_with verify P dep es st idx h).bridge.pending
      = es.bridge.pending := by
    show (applyActionToBridgeState es.bridge st.action idx).pending = es.bridge.pending
    rw [haction]
    rfl
  unfold totalWithdrawn
  rw [hpending]

/-- Withdrawal-ledger delta of a `depositWithFee` bridge step:
    `totalWithdrawn` is unchanged (`markConsumed` leaves `pending`
    untouched). -/
theorem depositWithFee_step_withdrawn
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip pool : ActorId} {ua pa : Amount}
    {bg : Nat} {dpid : DepositId}
    (haction : st.action = Action.depositWithFee r₀ recip pool ua pa bg dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    totalWithdrawn (apply_bridge_admissible_with verify P dep es st idx h) r
      = totalWithdrawn es r := by
  have hpending : (apply_bridge_admissible_with verify P dep es st idx h).bridge.pending
      = es.bridge.pending := by
    show (applyActionToBridgeState es.bridge st.action idx).pending = es.bridge.pending
    rw [haction]
    rfl
  unfold totalWithdrawn
  rw [hpending]

/-! ## Deposit-ledger deltas

`totalDeposited` reads only `es.bridge.consumed`, so each delta lifts the
existing GP.4.2 `*_step_eq_*` deltas (stated on `{es with bridge := …}`)
to the production stepper via `totalDeposited_unchanged_when_bridge_eq`
(the two states share a `bridge`).  The deposit-id freshness side
condition is discharged from the `BridgeAdmissibleWith` uniqueness
conjunct. -/

/-- Deposit-ledger delta of a `deposit` bridge step: `totalDeposited` at
    `r` rises by `amt` if the deposit is for `r`, else is unchanged. -/
theorem deposit_step_deposited
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip : ActorId} {amt : Amount} {dpid : DepositId}
    (haction : st.action = Action.deposit r₀ recip amt dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P dep es st idx h) r
      = totalDeposited es r + (if r₀ = r then amt else 0) := by
  have hfresh : ¬ dpid ∈ es.bridge.consumed := by
    have hc := h.depositIdFresh r₀ recip amt dpid haction
    rw [TreeMap.mem_iff_contains, hc]; simp
  have hbeq : (apply_bridge_admissible_with verify P dep es st idx h).bridge
      = ({ es with bridge := applyActionToBridgeState es.bridge (Action.deposit r₀ recip amt dpid) idx } : ExtendedState).bridge := by
    show applyActionToBridgeState es.bridge st.action idx
        = applyActionToBridgeState es.bridge (Action.deposit r₀ recip amt dpid) idx
    rw [haction]
  rw [totalDeposited_unchanged_when_bridge_eq _ _ hbeq r]
  have hU := totalUserDeposited_step_eq_deposit es r₀ recip amt dpid idx r hfresh
  have hP := totalPoolDeposited_step_eq_deposit es r₀ recip amt dpid idx r hfresh
  have hSplit1 := totalUserDeposited_plus_pool_eq_totalDeposited
    ({ es with bridge := applyActionToBridgeState es.bridge (Action.deposit r₀ recip amt dpid) idx } : ExtendedState) r
  have hSplit2 := totalUserDeposited_plus_pool_eq_totalDeposited es r
  omega

/-- Deposit-ledger delta of a `depositWithFee` bridge step:
    `totalDeposited` at `r` rises by `userAmount + poolAmount` if the
    deposit is for `r`, else is unchanged. -/
theorem depositWithFee_step_deposited
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip pool : ActorId} {ua pa : Amount}
    {bg : Nat} {dpid : DepositId}
    (haction : st.action = Action.depositWithFee r₀ recip pool ua pa bg dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P dep es st idx h) r
      = totalDeposited es r + (if r₀ = r then ua + pa else 0) := by
  have hfresh : ¬ dpid ∈ es.bridge.consumed := by
    have hc := h.depositWithFeeIdFresh r₀ recip pool ua pa bg dpid haction
    rw [TreeMap.mem_iff_contains, hc]; simp
  have hbeq : (apply_bridge_admissible_with verify P dep es st idx h).bridge
      = ({ es with bridge := applyActionToBridgeState es.bridge (Action.depositWithFee r₀ recip pool ua pa bg dpid) idx } : ExtendedState).bridge := by
    show applyActionToBridgeState es.bridge st.action idx
        = applyActionToBridgeState es.bridge (Action.depositWithFee r₀ recip pool ua pa bg dpid) idx
    rw [haction]
  rw [totalDeposited_unchanged_when_bridge_eq _ _ hbeq r,
      ← totalUserDeposited_plus_pool_eq_totalDeposited
        ({ es with bridge := applyActionToBridgeState es.bridge (Action.depositWithFee r₀ recip pool ua pa bg dpid) idx } : ExtendedState) r,
      totalUserDeposited_step_eq es r₀ recip pool ua pa bg dpid idx r hfresh,
      totalPoolDeposited_step_eq es r₀ recip pool ua pa bg dpid idx r hfresh,
      ← totalUserDeposited_plus_pool_eq_totalDeposited es r]
  by_cases hr : r₀ = r
  · simp only [if_pos hr]; omega
  · simp only [if_neg hr]; omega

/-- Deposit-ledger delta of a `withdraw` bridge step: `totalDeposited`
    is unchanged (`withdraw` mutates `pending`, leaving `consumed`). -/
theorem withdraw_step_deposited
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {sender : ActorId} {amt : Amount} {rcp : EthAddress}
    (haction : st.action = Action.withdraw r₀ sender amt rcp)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P dep es st idx h) r
      = totalDeposited es r := by
  obtain ⟨hU, hP⟩ := accounting_userpool_delta_withdraw verify P dep es st idx h
    ⟨r₀, sender, amt, rcp, haction⟩ r
  have hSplit1 := totalUserDeposited_plus_pool_eq_totalDeposited
    (apply_bridge_admissible_with verify P dep es st idx h) r
  have hSplit2 := totalUserDeposited_plus_pool_eq_totalDeposited es r
  omega

/-! ## Chain-level conservation (§7.6.4 / §7.6.5) -/

/-- The chain conservation invariant: at every resource, withdrawals plus
    the L2 circulating supply equal deposits.  Additive (no `Nat`
    truncation); `BridgeSolvent` (`totalWithdrawn ≤ totalDeposited`) and
    the §7.6.4 accounting equation are immediate corollaries. -/
def BridgeConserves (es : ExtendedState) : Prop :=
  ∀ r : ResourceId, totalWithdrawn es r + TotalSupply es.base r = totalDeposited es r

/-- The genesis L2 state: empty balances, nonces, registry, and bridge
    ledger.  The base case of every chain-level induction. -/
def genesisExtended : ExtendedState :=
  { base := genesisState, nonces := NonceState.empty,
    registry := KeyRegistry.empty, bridge := BridgeState.empty }

/-- Genesis conserves: all three ledgers are empty (0 + 0 = 0). -/
theorem genesis_conserves : BridgeConserves genesisExtended := by
  intro r
  have hw : totalWithdrawn genesisExtended r = 0 := totalWithdrawn_genesis r
  have hd : totalDeposited genesisExtended r = 0 := totalDeposited_genesis r
  have hs : TotalSupply genesisExtended.base r = 0 := totalSupply_genesis_eq_zero r
  omega

/-- Genesis withdrawal ids are monotonic (vacuously: `pending` is empty). -/
theorem genesis_monotonic : WithdrawalsMonotonic genesisExtended := by
  intro k hmem
  rw [TreeMap.mem_iff_contains] at hmem
  simp [genesisExtended, BridgeState.empty] at hmem

/-- One bridge step preserves `WithdrawalsMonotonic`.  Deposits leave
    `pending` / `nextWdId` untouched; a withdrawal inserts at `nextWdId`
    and bumps the counter, so every prior id (`< nextWdId`) and the new
    id (`= nextWdId`) are both `< nextWdId + 1`. -/
theorem withdrawalsMonotonic_step
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat} {ba : BridgeAction}
    (haction : st.action = ba.toAction)
    (h : BridgeAdmissibleWith verify P dep es st)
    (hmono : WithdrawalsMonotonic es) :
    WithdrawalsMonotonic (apply_bridge_admissible_with verify P dep es st idx h) := by
  cases ba with
  | deposit r₀ recip amt dpid =>
      intro k hmem
      have hb : (apply_bridge_admissible_with verify P dep es st idx h).bridge
          = es.bridge.markConsumed dpid
              { resource := r₀, userAmount := amt, poolAmount := 0, budgetGrant := 0 } := by
        show applyActionToBridgeState es.bridge st.action idx = _
        rw [haction]; rfl
      rw [hb] at hmem ⊢
      exact hmono k hmem
  | depositWithFee r₀ recip pool ua pa bg dpid =>
      intro k hmem
      have hb : (apply_bridge_admissible_with verify P dep es st idx h).bridge
          = es.bridge.markConsumed dpid
              { resource := r₀, userAmount := ua, poolAmount := pa, budgetGrant := bg } := by
        show applyActionToBridgeState es.bridge st.action idx = _
        rw [haction]; rfl
      rw [hb] at hmem ⊢
      exact hmono k hmem
  | withdraw r₀ sender amt rcp =>
      intro k hmem
      have hb : (apply_bridge_admissible_with verify P dep es st idx h).bridge
          = es.bridge.appendWithdrawal
              { resource := r₀, recipient := rcp, amount := amt, l2LogIndex := idx } := by
        show applyActionToBridgeState es.bridge st.action idx = _
        rw [haction]; rfl
      rw [hb] at hmem ⊢
      show k < es.bridge.nextWdId + 1
      rcases TreeMap.mem_insert.mp hmem with heq | hmem'
      · have hkeq : es.bridge.nextWdId = k := by
          rwa [Nat.compare_eq_eq] at heq
        subst hkeq
        exact Nat.lt_succ_self _
      · exact Nat.lt_succ_of_lt (hmono k hmem')

/-- One bridge step preserves `BridgeConserves`.  Each case combines the
    matching `*_step_withdrawn` (W), `*_step_supply` (S), and
    `*_step_deposited` (D) deltas with the inductive hypothesis: deposits
    mint and withdrawals burn exactly in lockstep with the ledger. -/
theorem bridgeConserves_step
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat} {ba : BridgeAction}
    (haction : st.action = ba.toAction)
    (h : BridgeAdmissibleWith verify P dep es st)
    (hmono : WithdrawalsMonotonic es)
    (hconv : BridgeConserves es) :
    BridgeConserves (apply_bridge_admissible_with verify P dep es st idx h) := by
  intro r
  have hIH := hconv r
  cases ba with
  | deposit r₀ recip amt dpid =>
      have hW := deposit_step_withdrawn (idx := idx) haction h r
      have hS := deposit_step_supply (idx := idx) haction h r
      have hD := deposit_step_deposited (idx := idx) haction h r
      omega
  | depositWithFee r₀ recip pool ua pa bg dpid =>
      have hW := depositWithFee_step_withdrawn (idx := idx) haction h r
      have hS := depositWithFee_step_supply (idx := idx) haction h r
      have hD := depositWithFee_step_deposited (idx := idx) haction h r
      omega
  | withdraw r₀ sender amt rcp =>
      have hW := withdraw_step_withdrawn (idx := idx) haction h hmono r
      have hS := withdraw_step_supply (idx := idx) haction h r
      have hD := withdraw_step_deposited (idx := idx) haction h r
      omega

/-- **Chain-level conservation (§7.6.4 / §7.6.5).**  Every state
    bridge-reachable from genesis conserves: `totalWithdrawn +
    TotalSupply = totalDeposited` at every resource, and withdrawal ids
    remain monotonic.  Proved by induction on `BridgeReachable`, carrying
    both invariants from the empty genesis ledgers. -/
theorem bridgeReachable_preserves
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es es' : ExtendedState}
    (hreach : BridgeReachable verify P dep es es') :
    WithdrawalsMonotonic es → BridgeConserves es →
    WithdrawalsMonotonic es' ∧ BridgeConserves es' := by
  induction hreach with
  | refl _ => exact fun hm hc => ⟨hm, hc⟩
  | step ba st idx haction h _hnext ih =>
      exact fun hmono hconv =>
        ih (withdrawalsMonotonic_step haction h hmono)
           (bridgeConserves_step haction h hmono hconv)

/-- Conservation holds at every state bridge-reachable from genesis. -/
theorem bridge_chain_conserves
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es' : ExtendedState}
    (hreach : BridgeReachable verify P dep genesisExtended es') :
    BridgeConserves es' :=
  (bridgeReachable_preserves hreach genesis_monotonic genesis_conserves).2

/-- **Solvency.**  Every state bridge-reachable from genesis is solvent:
    no resource has more withdrawn than deposited.  Immediate from
    conservation (`TotalSupply ≥ 0`). -/
theorem bridgeReachable_solvent
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es' : ExtendedState}
    (hreach : BridgeReachable verify P dep genesisExtended es') :
    BridgeSolvent es' := by
  intro r
  have := bridge_chain_conserves hreach r
  omega

/-- **§7.6.4 accounting equation, unconditional along bridge chains.**
    For every state bridge-reachable from genesis, total deposits equal
    total withdrawals plus the (now solvency-backed, non-truncating)
    escrow balance.  This closes audit finding m-16: the escrow term
    `bridge_accounting_equation_balanced_iff` left abstract is now the
    concrete `bridgeEscrowBalance`, and solvency is proved rather than
    assumed. -/
theorem bridge_chain_accounting_equation
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es' : ExtendedState}
    (hreach : BridgeReachable verify P dep genesisExtended es') (r : ResourceId) :
    totalDeposited es' r = totalWithdrawn es' r + bridgeEscrowBalance es' r :=
  bridge_accounting_equation es' r (bridgeReachable_solvent hreach r)

end Bridge
end LegalKernel
