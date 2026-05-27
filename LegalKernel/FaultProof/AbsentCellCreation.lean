/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.AbsentCellCreation — per-Action-variant
absent-cell creation theorems.

For each balance-creating `Action` constructor (`mint`, `reward`,
`deposit`), this module proves that applying the action to a
fresh actor (whose pre-state balance at the resource was 0)
populates the balance entry with the action's amount.

These are the substantive content of plan §18's #261
(`applyCellWrites_creates_absent_cells`) per-variant
specialisations.  The registry-creating variant
`registerIdentity` is handled by the existing
`registerIdentity_updates_registry` lemma in
`Authority/SignedAction.lean`.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Bridge.State
import LegalKernel.Laws.Deposit
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Reward
import LegalKernel.Laws.Transfer

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority

/-- #261.mint — applying `Laws.mint r to amount` to a fresh
    actor `to` (whose pre-state balance at `r` is 0) populates
    the balance cell with value `amount`. -/
theorem mint_creates_balance_cell
    (s : LegalKernel.State) (r : ResourceId) (to : ActorId)
    (amount : Amount)
    (h_absent : getBalance s r to = 0) :
    getBalance ((Laws.mint r to amount).apply_impl s) r to = amount := by
  show getBalance (setBalance s r to (getBalance s r to + amount)) r to = amount
  rw [h_absent, Nat.zero_add, getBalance_setBalance_same]

/-- #261.reward — applying `Laws.reward r to amount` to a fresh
    actor `to` populates the balance cell with value `amount`. -/
theorem reward_creates_balance_cell
    (s : LegalKernel.State) (r : ResourceId) (to : ActorId)
    (amount : Amount)
    (h_absent : getBalance s r to = 0) :
    getBalance ((Laws.reward r to amount).apply_impl s) r to = amount := by
  show getBalance (setBalance s r to (getBalance s r to + amount)) r to = amount
  rw [h_absent, Nat.zero_add, getBalance_setBalance_same]

/-- #261.deposit — applying `Laws.deposit r recipient amount
    depositId` to a fresh `recipient` populates the balance
    cell with value `amount`. -/
theorem deposit_creates_balance_cell
    (s : LegalKernel.State) (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (depositId : Bridge.DepositId)
    (h_absent : getBalance s r recipient = 0) :
    getBalance ((Laws.deposit r recipient amount depositId).apply_impl s)
               r recipient = amount := by
  show getBalance (setBalance s r recipient
                    (getBalance s r recipient + amount)) r recipient = amount
  rw [h_absent, Nat.zero_add, getBalance_setBalance_same]

/-- #261.transfer — applying `Laws.transfer r sender receiver
    amount` to distinct actors (`sender ≠ receiver`) where the
    receiver had no pre-state balance at `r` creates the
    receiver's balance cell with value `amount`.

    The disjointness hypothesis is necessary: self-transfer
    preserves the actor's balance per the §4.11 read-receiver-
    after-debit fix, so a fresh self-transfer would yield 0,
    not the amount. -/
theorem transfer_credits_receiver_from_fresh_actor
    (s : LegalKernel.State) (r : ResourceId)
    (sender receiver : ActorId) (amount : Amount)
    (h_distinct : sender ≠ receiver)
    (h_receiver_absent : getBalance s r receiver = 0) :
    getBalance ((Laws.transfer r sender receiver amount).apply_impl s)
               r receiver = amount := by
  -- Unfold transfer's apply_impl:
  -- 1. fromBal := getBalance s r sender
  -- 2. s1 := setBalance s r sender (fromBal - amount)
  -- 3. toBal := getBalance s1 r receiver
  -- 4. setBalance s1 r receiver (toBal + amount)
  -- Since sender ≠ receiver, getBalance s1 r receiver = getBalance s r receiver = 0.
  -- Final: setBalance s1 r receiver (0 + amount) = setBalance s1 r receiver amount.
  -- Reading getBalance at receiver: = amount.
  show getBalance
        (setBalance
          (setBalance s r sender (getBalance s r sender - amount))
          r receiver
          (getBalance
            (setBalance s r sender (getBalance s r sender - amount))
            r receiver + amount))
        r receiver = amount
  -- getBalance after setBalance at receiver = the newly-set value.
  rw [getBalance_setBalance_same]
  -- Now: getBalance s1 r receiver + amount.  Since s1 was made by
  -- setBalance at sender ≠ receiver, getBalance s1 r receiver =
  -- getBalance s r receiver = 0.
  have h_other : getBalance
                  (setBalance s r sender (getBalance s r sender - amount))
                  r receiver = getBalance s r receiver :=
    getBalance_setBalance_other s r r sender receiver
      (getBalance s r sender - amount) (Or.inr h_distinct)
  rw [h_other, h_receiver_absent, Nat.zero_add]

end FaultProof
end LegalKernel
