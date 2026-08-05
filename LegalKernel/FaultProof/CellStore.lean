-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.CellStore — the store laws for `CellValue`'s
reader/writer pair.

`getCellValue` and `setCell` are documented as a cell reader and "the
L1 step VM's per-cell write primitive".  Nothing said they behave like
a *store*, and the step VM cannot use them until they provably do:

  * **Locality.**  Writing one cell must leave every other cell's
    value exactly as it was.  This is what discharges the off-cell
    hypothesis the retired chained fold asked of
    each link — via `dropKey_stateCellEntries_perm_of_agree_off`,
    whose hypothesis is stated over cell VALUES, which is precisely
    what locality supplies.

  * **Read-back.**  A written value must read back.  This one is not
    unconditional and the exceptions are load-bearing rather than
    incidental: `setCell` decodes the bytes it is handed, so a value
    outside the arm's encoder image is a no-op, and at the three
    "append-only within a step" kinds (`registry`, `bridgeConsumed`,
    `bridgePending`) the canonical ABSENT marker is a no-op too —
    no action removes a registry entry, un-consumes a deposit, or
    retires a pending withdrawal inside a single step.  The read-back
    laws below are therefore stated per kind over the canonical
    constructors, which is exactly the form the write set produces.

Both are stated over the canonical value constructors named here
(`amountCellValue` and friends) rather than over raw bytes, because
that is the form `getCellValue` itself emits — so a write set built
from them is closed under the reader.

`docs/planning/state_root_merkleisation_plan.md` §4.
-/

import LegalKernel.FaultProof.CellValue

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding

/-- A cell value built from a non-empty byte list has non-zero size —
    which is exactly what `setCell`'s absent-marker guard tests.

    Stated on `.size = 0` rather than on `= ByteArray.empty` because
    that is the form the guard takes, and because reducing
    `ByteArray.empty` under `simp` loops on `ByteArray.size`. -/
private theorem byteArray_mk_size_ne_zero (l : List UInt8) (h : l ≠ []) :
    ¬ (ByteArray.mk l.toArray).size = 0 := by
  intro hs
  simp [ByteArray.size] at hs
  exact h hs

/-! ## Canonical cell-value constructors

`getCellValue` builds each cell's bytes inline.  Naming the seven
shapes lets the write set produce values in exactly the reader's form,
which is what makes the read-back laws below statable at all. -/

/-- The byte form of a value-carrying cell: the 33-byte CBE amount
    head.  Balances, the AMM reserves and the BOLD TVL figures. -/
def amountCellValue (n : Nat) : ByteArray :=
  ByteArray.mk (Encoding.encodeAmount n).toArray

/-- The byte form of a counter or flag cell: the 9-byte CBE uint
    head.  Nonces, the next-withdrawal id and the two bridge flags. -/
def natCellValue (n : Nat) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := Nat) n).toArray

/-- The byte form of a registry cell: the public key wrapped in the
    CBE byte-string encoder.  The 9-byte head is present even for a
    zero-length key, which is what keeps present-empty distinct from
    absent. -/
def keyCellValue (pk : Authority.PublicKey) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := ByteArray) pk).toArray

/-- The byte form of a local-policy cell. -/
def policyCellValue (p : Authority.LocalPolicy) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := Authority.LocalPolicy) p).toArray

/-- The byte form of the budget-policy cell: the whole policy value
    under its own encoder, not one scalar of it.  `BudgetPolicy` is a
    single value, so a cell that carried a component would make every
    write a read-modify-write of the other two. -/
def budgetPolicyCellValue (p : Authority.BudgetPolicy) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := Authority.BudgetPolicy) p).toArray

/-- The byte form of a consumed-deposit cell. -/
def depositCellValue (rec : Bridge.DepositRecord) : ByteArray :=
  ByteArray.mk (Bridge.DepositRecord.encode rec).toArray

/-- The byte form of a pending-withdrawal cell. -/
def withdrawalCellValue (pw : Bridge.PendingWithdrawal) : ByteArray :=
  ByteArray.mk (Bridge.PendingWithdrawal.encode pw).toArray

/-- The byte form of an epoch-budget cell: the epoch and the balance
    concatenated, so a proof cannot open one without the other. -/
def budgetCellValue (b : Authority.ActorBudget) : ByteArray :=
  ByteArray.mk
    ((Encodable.encode (T := Nat) b.lastSeenEpoch) ++
     (Encodable.encode (T := Nat) b.budgetBalance)).toArray

/-! ## Reader reductions

One equation per cell kind, naming the constructor the reader emits.
All `rfl`; they exist so downstream proofs rewrite by kind instead of
unfolding the fifteen-arm match. -/

/-- A balance cell reads the amount head over `getBalance`. -/
theorem getCellValue_balance (es : ExtendedState) (r : ResourceId) (a : ActorId) :
    getCellValue es (.balance r a) = amountCellValue (LegalKernel.getBalance es.base r a) := rfl

/-- A nonce cell reads the uint head over `expectsNonce`. -/
theorem getCellValue_nonce (es : ExtendedState) (a : ActorId) :
    getCellValue es (.nonce a) = natCellValue (Authority.expectsNonce es a) := rfl

/-- A registry cell reads the wrapped key, or the absent marker. -/
theorem getCellValue_registry (es : ExtendedState) (a : ActorId) :
    getCellValue es (.registry a) =
      (match es.registry[a]? with
       | some pk => keyCellValue pk
       | none    => ByteArray.empty) := rfl

/-- A local-policy cell reads the encoded policy, or the absent
    marker.  Keyed off the map, not `lookup`. -/
theorem getCellValue_localPolicy (es : ExtendedState) (a : ActorId) :
    getCellValue es (.localPolicy a) =
      (match es.localPolicies[a]? with
       | some p => policyCellValue p
       | none   => ByteArray.empty) := rfl

/-- The next-withdrawal-id cell reads the uint head over the
    counter. -/
theorem getCellValue_bridgeNextWdId (es : ExtendedState) :
    getCellValue es .bridgeNextWdId = natCellValue es.bridge.nextWdId := rfl

/-- An epoch-budget cell reads the epoch/balance pair. -/
theorem getCellValue_epochBudget' (es : ExtendedState) (a : ActorId) :
    getCellValue es (.epochBudget a) =
      budgetCellValue (es.epochBudgets[a]?.getD Authority.ActorBudget.empty) := rfl

/-- The consumed-deposit cell's `contains` guard is redundant: a key
    the map does not hold reads `none` through `getElem?` anyway.
    Stated so the diagonal locality case reasons about one lookup
    rather than a lookup and a membership test that must agree. -/
theorem getCellValue_bridgeConsumed (es : ExtendedState) (d : DepositId) :
    getCellValue es (.bridgeConsumed d) =
      (match es.bridge.consumed[d]? with
       | some rec => depositCellValue rec
       | none     => ByteArray.empty) := by
  show (if es.bridge.consumed.contains d then _ else _) = _
  rw [Std.TreeMap.contains_eq_isSome_getElem?]
  cases h : es.bridge.consumed[d]? <;> simp [depositCellValue]

/-- The budget-policy cell reads the whole policy value.

    One cell, so the reduction is a projection rather than a
    scrutinee-exposing match: nothing downstream has to reason about
    which components of a `bounded` triple survive a write to a
    sibling, because there are no siblings. -/
theorem getCellValue_budgetPolicy' (es : ExtendedState) :
    getCellValue es .budgetPolicy = budgetPolicyCellValue es.budgetPolicy := rfl

/-- A pending-withdrawal cell reads the encoded payload, or the
    absent marker. -/
theorem getCellValue_bridgePending (es : ExtendedState) (w : WithdrawalId) :
    getCellValue es (.bridgePending w) =
      (match es.bridge.pending[w]? with
       | some pw => withdrawalCellValue pw
       | none    => ByteArray.empty) := rfl

/-! ## Locality

The store law the fold consumes.  Note the hypothesis is tag
disequality, not key disequality: `smtCellKey t ≠ smtCellKey t₀`
implies `t ≠ t₀` by congruence, so a caller holding the key form can
use this without any injectivity assumption. -/

set_option linter.unusedSimpArgs false in
/-- **Writing one cell leaves every other cell's value alone.**

    Off the diagonal the write lands on a sub-state component the read
    does not look at; along it, the underlying map's
    write-at-another-key equation does the work.

    The nine bridge-shaped kinds are why this is not a statement about
    `ExtendedState` FIELDS: they all read `es.bridge`, so "different
    field" is too coarse and the case analysis has to run at the
    granularity of the cell.

    The linter option is scoped to this proof and is about the shared
    automation, not the statement: one argument list serves 225 tag
    pairs, so some argument is necessarily idle in some of them. -/
theorem getCellValue_setCell_ne (es : ExtendedState) (t t₀ : CellTag) (v : ByteArray)
    (h : t ≠ t₀) :
    getCellValue (setCell es t₀ v) t = getCellValue es t := by
  by_cases hk : t₀.kindIndex = t.kindIndex
  · -- Same kind: the mismatched pairs die on the index, the singleton
    -- kinds on `h`, and the seven keyed kinds are the map lemmas.
    cases t <;> cases t₀ <;> simp only [CellTag.kindIndex] at hk <;>
      first
        | omega
        | exact absurd rfl h
        | skip
    next r a r' a' =>
      have hne : r' ≠ r ∨ a' ≠ a := by
        by_cases hr : r' = r
        · exact Or.inr (fun ha => h (by rw [hr, ha]))
        · exact Or.inl hr
      simp only [setCell]
      split
      · rw [getCellValue_balance, getCellValue_balance]
        show amountCellValue (LegalKernel.getBalance (LegalKernel.setBalance es.base r' a' _) r a)
          = amountCellValue (LegalKernel.getBalance es.base r a)
        rw [LegalKernel.getBalance_setBalance_other _ _ _ _ _ _ hne]
      · rfl
    next a a' =>
      have hne : a' ≠ a := fun he => h (by rw [he])
      simp only [setCell]
      split
      · rw [getCellValue_nonce, getCellValue_nonce]
        show natCellValue ((es.nonces.next.insert a' _)[a]?.getD 0)
          = natCellValue (es.nonces.next[a]?.getD 0)
        rw [LegalKernel.RBMap.find?_insert_other _ a' a _ hne]
      · rfl
    next a a' =>
      have hne : a' ≠ a := fun he => h (by rw [he])
      simp only [setCell]
      split
      · rfl
      · split
        · rw [getCellValue_registry, getCellValue_registry,
            LegalKernel.RBMap.find?_insert_other _ a' a _ hne]
        · rfl
    next a a' =>
      have hne : a' ≠ a := fun he => h (by rw [he])
      simp only [setCell]
      split
      · rw [getCellValue_localPolicy, getCellValue_localPolicy]
        show (match (es.localPolicies.revoke a')[a]? with
              | some p => policyCellValue p | none => ByteArray.empty)
          = (match es.localPolicies[a]? with
             | some p => policyCellValue p | none => ByteArray.empty)
        unfold Authority.LocalPolicies.revoke
        rw [Std.TreeMap.getElem?_erase]
        have : compare a' a ≠ .eq := fun he => hne (Std.LawfulEqCmp.eq_of_compare he)
        simp [this]
      · split
        · rw [getCellValue_localPolicy, getCellValue_localPolicy]
          show (match (es.localPolicies.declare a' _)[a]? with
                | some p => policyCellValue p | none => ByteArray.empty)
            = (match es.localPolicies[a]? with
               | some p => policyCellValue p | none => ByteArray.empty)
          unfold Authority.LocalPolicies.declare
          rw [LegalKernel.RBMap.find?_insert_other _ a' a _ hne]
        · rfl
    next d d' =>
      have hne : d' ≠ d := fun he => h (by rw [he])
      simp only [setCell]
      split
      · rfl
      · split
        · rw [getCellValue_bridgeConsumed, getCellValue_bridgeConsumed]
          show (match (es.bridge.markConsumed d' _).consumed[d]? with
                | some rec => depositCellValue rec | none => ByteArray.empty)
            = (match es.bridge.consumed[d]? with
               | some rec => depositCellValue rec | none => ByteArray.empty)
          unfold Bridge.BridgeState.markConsumed
          rw [LegalKernel.RBMap.find?_insert_other _ d' d _ hne]
        · rfl
    next w w' =>
      have hne : w' ≠ w := fun he => h (by rw [he])
      simp only [setCell]
      split
      · rfl
      · split
        · rw [getCellValue_bridgePending, getCellValue_bridgePending,
            LegalKernel.RBMap.find?_insert_other _ w' w _ hne]
        · rfl
    next a a' =>
      have hne : a' ≠ a := fun he => h (by rw [he])
      simp only [setCell]
      split
      · split
        · rw [getCellValue_epochBudget', getCellValue_epochBudget',
            LegalKernel.RBMap.find?_insert_other _ a' a _ hne]
        · rfl
      · rfl
  · -- Different kind: after both tags are concrete the write is a
    -- record update of one component and the read a projection of a
    -- different one, so each pair reduces.
    cases t <;> cases t₀ <;> simp only [CellTag.kindIndex] at hk <;>
      first
        | omega
        | rfl
        | (simp only [setCell]; split <;> first | rfl | (split <;> rfl))
        | ((simp only [setCell]; split <;>
              first | rfl | simp_all | (split <;> simp_all)); done)

/-! ## Read-back

`setCell` decodes the bytes it is handed, so read-back is conditional
on the value being in the arm's encoder image — which is exactly what
the canonical constructors above give, once their fields are in the
encoder's bounded range.  The bounds are the same
`ExtendedState.CanonicalBounds` figures the commitment layer already
carries; they are taken as hypotheses here rather than assumed.

Eight kinds, because eight are all an action ever writes: the bridge
scalars and the budget policy are genesis parameters, mutated by no
`Action` constructor. -/

/-- A balance write reads back. -/
theorem getCellValue_setCell_balance (es : ExtendedState) (r : ResourceId) (a : ActorId)
    (n : Nat) (h : n < 256 ^ 32) :
    getCellValue (setCell es (.balance r a) (amountCellValue n)) (.balance r a)
      = amountCellValue n := by
  have hd : Encoding.decodeAmount (amountCellValue n).data.toList = .ok (n, []) := by
    simpa [amountCellValue] using Encoding.amount_roundtrip_empty n h
  simp only [setCell, hd, getCellValue_balance, LegalKernel.getBalance_setBalance_same]

/-- A nonce write reads back. -/
theorem getCellValue_setCell_nonce (es : ExtendedState) (a : ActorId)
    (n : Nat) (h : n < 256 ^ 8) :
    getCellValue (setCell es (.nonce a) (natCellValue n)) (.nonce a) = natCellValue n := by
  have hd : Encodable.decode (T := Nat) (natCellValue n).data.toList = .ok (n, []) := by
    simpa [natCellValue] using Encoding.nat_roundtrip_empty n h
  simp only [setCell, hd, getCellValue_nonce, Authority.expectsNonce,
    LegalKernel.RBMap.find?_insert_self, Option.getD_some]

/-- A registry write reads back.  The written value is never the
    absent marker: the CBE byte-string head is a `cons`, so the
    encoding of even the empty key is non-empty. -/
theorem getCellValue_setCell_registry (es : ExtendedState) (a : ActorId)
    (pk : Authority.PublicKey) (h : pk.size < 256 ^ 8) :
    getCellValue (setCell es (.registry a) (keyCellValue pk)) (.registry a)
      = keyCellValue pk := by
  have hne : ¬ (keyCellValue pk).size = 0 := by
    unfold keyCellValue
    exact byteArray_mk_size_ne_zero _
      (by simp [Encodable.encode, Encoding.encodeBytesList, Encoding.cborHeadEncode])
  have hd : Encodable.decode (T := ByteArray) (keyCellValue pk).data.toList = .ok (pk, []) := by
    simpa [keyCellValue] using Encoding.byteArray_roundtrip_empty pk h
  simp only [setCell, hne, if_false, hd, getCellValue_registry,
    LegalKernel.RBMap.find?_insert_self]

/-- A local-policy declaration reads back. -/
theorem getCellValue_setCell_localPolicy (es : ExtendedState) (a : ActorId)
    (p : Authority.LocalPolicy) (h : Encoding.LocalPolicy.fieldsBounded p) :
    getCellValue (setCell es (.localPolicy a) (policyCellValue p)) (.localPolicy a)
      = policyCellValue p := by
  have hne : ¬ (policyCellValue p).size = 0 := by
    unfold policyCellValue
    exact byteArray_mk_size_ne_zero _
      (by simp [Encodable.encode, Encoding.LocalPolicy.encode, Encoding.encodeList,
                Encoding.cborHeadEncode])
  have hd : Encodable.decode (T := Authority.LocalPolicy)
      (policyCellValue p).data.toList = .ok (p, []) := by
    simpa [policyCellValue] using Encoding.localPolicy_roundtrip_empty p h
  simp only [setCell, hne, if_false, hd, getCellValue_localPolicy,
    Authority.LocalPolicies.declare, LegalKernel.RBMap.find?_insert_self]

/-- A local-policy revocation reads back as the absent marker.  This
    is the one kind where writing the canonical absent value is a real
    erase rather than a no-op, and `revokeLocalPolicy` needs it. -/
theorem getCellValue_setCell_localPolicy_absent (es : ExtendedState) (a : ActorId) :
    getCellValue (setCell es (.localPolicy a) ByteArray.empty) (.localPolicy a)
      = ByteArray.empty := by
  have hz : (ByteArray.empty).size = 0 := rfl
  simp only [setCell, hz, if_true, getCellValue_localPolicy,
    Authority.LocalPolicies.revoke, Std.TreeMap.getElem?_erase_self]

/-- A consumed-deposit write reads back. -/
theorem getCellValue_setCell_bridgeConsumed (es : ExtendedState) (d : DepositId)
    (rec : Bridge.DepositRecord)
    (h : rec.resource.toNat < 256 ^ 8 ∧ rec.userAmount < 256 ^ 32 ∧
         rec.poolAmount < 256 ^ 32 ∧ rec.budgetGrant < 256 ^ 8) :
    getCellValue (setCell es (.bridgeConsumed d) (depositCellValue rec)) (.bridgeConsumed d)
      = depositCellValue rec := by
  have hne : ¬ (depositCellValue rec).size = 0 := by
    unfold depositCellValue
    exact byteArray_mk_size_ne_zero _
      (by simp [Bridge.DepositRecord.encode, Encodable.encode, Encoding.cborHeadEncode])
  have hd : Bridge.DepositRecord.decode (depositCellValue rec).data.toList
      = .ok (rec, []) := by
    simpa [depositCellValue] using Encoding.depositRecord_roundtrip rec [] h
  simp only [setCell, hne, if_false, hd, getCellValue_bridgeConsumed,
    Bridge.BridgeState.markConsumed, LegalKernel.RBMap.find?_insert_self]

/-- A pending-withdrawal write reads back. -/
theorem getCellValue_setCell_bridgePending (es : ExtendedState) (w : WithdrawalId)
    (pw : Bridge.PendingWithdrawal)
    (h_res : pw.resource.toNat < 256 ^ 8) (h_amt : pw.amount < 256 ^ 32)
    (h_idx : pw.l2LogIndex < 256 ^ 8) :
    getCellValue (setCell es (.bridgePending w) (withdrawalCellValue pw)) (.bridgePending w)
      = withdrawalCellValue pw := by
  have hne : ¬ (withdrawalCellValue pw).size = 0 := by
    unfold withdrawalCellValue
    exact byteArray_mk_size_ne_zero _
      (by simp [Bridge.PendingWithdrawal.encode, Encodable.encode, Encoding.cborHeadEncode])
  have hd : Bridge.PendingWithdrawal.decode (withdrawalCellValue pw).data.toList
      = .ok (pw, []) := by
    simpa [withdrawalCellValue] using
      Encoding.pendingWithdrawal_roundtrip pw [] h_res h_amt h_idx
  simp only [setCell, hne, if_false, hd, getCellValue_bridgePending,
    LegalKernel.RBMap.find?_insert_self]

/-- A next-withdrawal-id write reads back. -/
theorem getCellValue_setCell_bridgeNextWdId (es : ExtendedState) (n : Nat)
    (h : n < 256 ^ 8) :
    getCellValue (setCell es .bridgeNextWdId (natCellValue n)) .bridgeNextWdId
      = natCellValue n := by
  have hd : Encodable.decode (T := Nat) (natCellValue n).data.toList = .ok (n, []) := by
    simpa [natCellValue] using Encoding.nat_roundtrip_empty n h
  simp only [setCell, hd, getCellValue_bridgeNextWdId]

/-- An epoch-budget write reads back.  Both components travel in one
    value, so the decoder reads the epoch and then the balance out of
    the residual stream — which is why this needs the
    residual-carrying round-trip rather than the empty-residual
    one. -/
theorem getCellValue_setCell_epochBudget (es : ExtendedState) (a : ActorId)
    (b : Authority.ActorBudget)
    (h_epoch : b.lastSeenEpoch < 256 ^ 8) (h_bal : b.budgetBalance < 256 ^ 8) :
    getCellValue (setCell es (.epochBudget a) (budgetCellValue b)) (.epochBudget a)
      = budgetCellValue b := by
  -- Stated on the UNFOLDED stream: `budgetCellValue` is in the
  -- `simp only` set below, so a hypothesis phrased over the folded
  -- form would stop matching the moment the goal unfolds.
  have hd₁ : Encodable.decode (T := Nat)
      (Encodable.encode (T := Nat) b.lastSeenEpoch ++
        Encodable.encode (T := Nat) b.budgetBalance)
      = .ok (b.lastSeenEpoch, Encodable.encode (T := Nat) b.budgetBalance) :=
    Encoding.nat_roundtrip b.lastSeenEpoch
      (Encodable.encode (T := Nat) b.budgetBalance) h_epoch
  have hd₂ : Encodable.decode (T := Nat) (Encodable.encode (T := Nat) b.budgetBalance)
      = .ok (b.budgetBalance, []) := Encoding.nat_roundtrip_empty b.budgetBalance h_bal
  simp only [setCell, hd₁, hd₂, getCellValue_epochBudget',
    LegalKernel.RBMap.find?_insert_self, Option.getD_some, budgetCellValue]

/-! ## Read-back at the genesis cells

No `Action` writes the bridge scalars or the budget policy — they are
deployment parameters.  The step VM still has to be able to write
them, and for one reason: `stepCellWrites` sets each cell it names to
the value the advance gives it, and the generic round-trip law below
(`getCellValue_setCell_getCellValue`) quantifies over EVERY cell kind.
A law with holes at six kinds would push a case split into every
caller for the sake of six arms that are true. -/

/-- The AMM ETH reserve reads back. -/
theorem getCellValue_setCell_bridgeAmmReserveEth (es : ExtendedState) (n : Nat)
    (h : n < 256 ^ 32) :
    getCellValue (setCell es .bridgeAmmReserveEth (amountCellValue n))
        .bridgeAmmReserveEth = amountCellValue n := by
  simp only [setCell, amountCellValue, Encoding.amount_roundtrip_empty n h, getCellValue]

/-- The AMM BOLD reserve reads back. -/
theorem getCellValue_setCell_bridgeAmmReserveBold (es : ExtendedState) (n : Nat)
    (h : n < 256 ^ 32) :
    getCellValue (setCell es .bridgeAmmReserveBold (amountCellValue n))
        .bridgeAmmReserveBold = amountCellValue n := by
  simp only [setCell, amountCellValue, Encoding.amount_roundtrip_empty n h, getCellValue]

/-- The BOLD TVL cap reads back. -/
theorem getCellValue_setCell_bridgeBoldTvlCap (es : ExtendedState) (n : Nat)
    (h : n < 256 ^ 32) :
    getCellValue (setCell es .bridgeBoldTvlCap (amountCellValue n))
        .bridgeBoldTvlCap = amountCellValue n := by
  simp only [setCell, amountCellValue, Encoding.amount_roundtrip_empty n h, getCellValue]

/-- The BOLD total-locked-value reads back. -/
theorem getCellValue_setCell_bridgeBoldTotalLockedValue (es : ExtendedState) (n : Nat)
    (h : n < 256 ^ 32) :
    getCellValue (setCell es .bridgeBoldTotalLockedValue (amountCellValue n))
        .bridgeBoldTotalLockedValue = amountCellValue n := by
  simp only [setCell, amountCellValue, Encoding.amount_roundtrip_empty n h, getCellValue]

/-- The BOLD circuit-breaker flag reads back.

    Stated over the 0/1 encoding rather than over an arbitrary `Nat`,
    because the write is lossy: `setCell` stores `n != 0`, so every
    non-zero value reads back as `1`.  The reader only ever emits 0 or
    1, which is why the round-trip law below still holds at this
    kind. -/
theorem getCellValue_setCell_bridgeBoldCircuitClosed (es : ExtendedState) (b : Bool) :
    getCellValue (setCell es .bridgeBoldCircuitClosed (natCellValue (if b then 1 else 0)))
        .bridgeBoldCircuitClosed = natCellValue (if b then 1 else 0) := by
  -- Both branches close by computation: the written value is a
  -- literal, so the decoder runs to a `Nat` literal and the flag's
  -- `!= 0` test decides.  No round-trip lemma is needed, which is
  -- itself the reason the lossy write is safe HERE and nowhere else.
  cases b <;> rfl

/-- The AMM kill switch reads back.  Lossy in the same way as the
    circuit breaker, and stated the same way. -/
theorem getCellValue_setCell_bridgeAmmDisabled (es : ExtendedState) (b : Bool) :
    getCellValue (setCell es .bridgeAmmDisabled (natCellValue (if b then 1 else 0)))
        .bridgeAmmDisabled = natCellValue (if b then 1 else 0) := by
  -- Both branches close by computation: the written value is a
  -- literal, so the decoder runs to a `Nat` literal and the flag's
  -- `!= 0` test decides.  No round-trip lemma is needed, which is
  -- itself the reason the lossy write is safe HERE and nowhere else.
  cases b <;> rfl

/-- The budget policy reads back.  One cell, so this is a plain
    round-trip through the `BudgetPolicy` encoder rather than a
    rebuild of a triple.

    The `1 ≤ actionCost` hypothesis is the decoder's, not this
    theorem's: `BudgetPolicy.decode` ends in `mkBounded`, which clamps
    the per-action cost to at least one.  That clamp is the anti-spam
    invariant — a zero-cost policy would make the budget gate
    vacuous — so a policy with `actionCost = 0` is one the deployment
    cannot hold, and the hypothesis records that rather than working
    around it. -/
theorem getCellValue_setCell_budgetPolicy (es : ExtendedState)
    (freeTier actionCost currentEpoch : Nat)
    (h_ft : freeTier < 256 ^ 8) (h_ac : actionCost < 256 ^ 8)
    (h_ce : currentEpoch < 256 ^ 8) (h_pos : 1 ≤ actionCost) :
    getCellValue
        (setCell es .budgetPolicy
          (budgetPolicyCellValue (.bounded freeTier actionCost currentEpoch)))
        .budgetPolicy
      = budgetPolicyCellValue (.bounded freeTier actionCost currentEpoch) := by
  -- Stated on the UNFOLDED stream: `budgetPolicyCellValue` is in the
  -- `simp only` set below, so a hypothesis phrased over the folded
  -- form stops matching the moment the goal unfolds.
  have hd : Encodable.decode (T := Authority.BudgetPolicy)
      (Encodable.encode (T := Authority.BudgetPolicy)
        (Authority.BudgetPolicy.bounded freeTier actionCost currentEpoch))
      = .ok (Authority.BudgetPolicy.bounded freeTier actionCost currentEpoch, []) := by
    simpa using
      Encoding.budgetPolicy_bounded_roundtrip freeTier actionCost currentEpoch []
        h_ft h_ac h_ce h_pos
  simp only [setCell, budgetPolicyCellValue, hd, getCellValue_budgetPolicy']

end FaultProof
end LegalKernel
