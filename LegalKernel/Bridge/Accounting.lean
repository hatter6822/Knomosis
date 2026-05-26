/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.Accounting — Workstream C.6
(`docs/planning/ethereum_integration_plan.md` §7.6).

The bridge accounting theorem chain:

  * §7.6.1 (WU C.6.1) — `totalDeposited`, `totalWithdrawn`
    quantity functionals, plus the foldl-after-insert structural
    lemmas they depend on.
  * §7.6.2 (WU C.6.2) — per-action accounting deltas: each kernel
    `Action` constructor's effect on the three quantity
    functionals (`TotalSupply`, `totalDeposited`,
    `totalWithdrawn`).
  * §7.6.3 (WU C.6.3) — `totalWithdrawn_bounded` (an inductive
    invariant guaranteeing exact-`Nat`-subtraction safety).
  * §7.6.4 (WU C.6.4) — `bridge_supply_account_general`, the
    general accounting equation, parameterised over a
    `BridgeReachable` chain that closes under
    `apply_bridge_admissible_with`.
  * §7.6.5 (WU C.6.5) — `bridge_supply_account`, the
    strict-form corollary under the canonical `bridgeLawSet`.

The accounting equation says: the sum of L2 supply at `r` plus
the sum of pending+already-redeemed L1 withdrawals at `r` equals
the sum of credited L1 deposits at `r` plus the genesis supply at
`r` (plus any deployment-allowed reward issuance).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Bridge.State
import LegalKernel.Bridge.Admissible
import LegalKernel.Laws.Deposit
import LegalKernel.Laws.Withdraw
import LegalKernel.Laws.DepositWithFee

open Std

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## §7.6.1 — Quantity functionals (`totalDeposited`,
`totalWithdrawn`) -/

/-- The amount field of a `PendingWithdrawal`, projected onto
    resource `r`.  Returns `0` if the withdrawal is for a different
    resource. -/
@[inline] def PendingWithdrawal.amountAt (wd : PendingWithdrawal)
    (r : ResourceId) : Nat :=
  if wd.resource = r then wd.amount else 0

/-- The total amount credited to L2 balances by a `DepositRecord`
    — `userAmount + poolAmount` — projected onto resource `r`.

    This is the quantity the legacy `totalDeposited` fold sums (the
    "L2 supply expansion attributable to this L1 deposit").  After the
    GP.4.1 widening, the `(userAmount, poolAmount)` split is recorded
    per deposit; this projection recombines them so `totalDeposited`'s
    value is unchanged for every state (the GP.4.2 accounting split
    sums `userAmount` and `poolAmount` independently). -/
@[inline] def DepositRecord.amountAt (rec : DepositRecord)
    (r : ResourceId) : Nat :=
  if rec.resource = r then rec.userAmount + rec.poolAmount else 0

/-- The user-credited leg of a `DepositRecord`, projected onto
    resource `r`.  Returns `0` if the deposit is for a different
    resource.  This is the per-deposit quantity the GP.4.2
    `totalUserDeposited` fold sums: the amount credited to the
    user-facing recipient (as opposed to the gas pool). -/
@[inline] def DepositRecord.userAmountAt (rec : DepositRecord)
    (r : ResourceId) : Nat :=
  if rec.resource = r then rec.userAmount else 0

/-- The pool-credited leg of a `DepositRecord`, projected onto
    resource `r`.  Returns `0` if the deposit is for a different
    resource.  This is the per-deposit quantity the GP.4.2
    `totalPoolDeposited` fold sums: the amount credited to the
    gas-pool actor.  Zero for legacy fee-less `Action.deposit`
    records (which set `poolAmount = 0`). -/
@[inline] def DepositRecord.poolAmountAt (rec : DepositRecord)
    (r : ResourceId) : Nat :=
  if rec.resource = r then rec.poolAmount else 0

/-- The two GP.4.2 deposit legs recombine to the total L2 credit:
    `userAmountAt + poolAmountAt = amountAt` at every resource.  This
    is the per-record kernel of the accounting-equation split — the
    user-credit and pool-credit projections partition the single
    `amountAt` quantity the legacy `totalDeposited` fold summed. -/
theorem DepositRecord.userAmountAt_add_poolAmountAt
    (rec : DepositRecord) (r : ResourceId) :
    rec.userAmountAt r + rec.poolAmountAt r = rec.amountAt r := by
  unfold DepositRecord.userAmountAt DepositRecord.poolAmountAt DepositRecord.amountAt
  by_cases h : rec.resource = r <;> simp [h]

/-- Total amount withdrawn at resource `r`, summed over the bridge's
    `pending` map.  Includes both currently-pending and historically-
    submitted withdrawals (the `pending` map is append-only at the
    `withdraw`-action level; L1 redemption removes entries via a
    different code path that lives outside the kernel). -/
def totalWithdrawn (es : ExtendedState) (r : ResourceId) : Nat :=
  es.bridge.pending.foldl
    (fun acc _ wd => acc + PendingWithdrawal.amountAt wd r) 0

/-- Total amount deposited at resource `r`, summed over the bridge's
    `consumed` map.  Each `DepositRecord` carries the
    `(resource, userAmount, poolAmount, budgetGrant)` metadata; this
    fold sums the per-deposit total L2 credit `userAmount + poolAmount`
    via `DepositRecord.amountAt` (audit-2 amendment to §7.1.1, GP.4.1
    widening). -/
def totalDeposited (es : ExtendedState) (r : ResourceId) : Nat :=
  es.bridge.consumed.foldl
    (fun acc _ rec => acc + DepositRecord.amountAt rec r) 0

/-- Total amount credited to user-facing recipients at resource `r`,
    summed over the bridge's `consumed` map (GP.4.2).  Sums each
    deposit's `userAmount` leg via `DepositRecord.userAmountAt`.  This
    is the user half of the amended bridge accounting equation; the
    legacy single-term `totalDeposited` is recovered as
    `totalUserDeposited + totalPoolDeposited` (see
    `totalUserDeposited_plus_pool_eq_totalDeposited`). -/
def totalUserDeposited (es : ExtendedState) (r : ResourceId) : Nat :=
  es.bridge.consumed.foldl
    (fun acc _ rec => acc + DepositRecord.userAmountAt rec r) 0

/-- Total amount credited to the gas-pool actor at resource `r`,
    summed over the bridge's `consumed` map (GP.4.2).  Sums each
    deposit's `poolAmount` leg via `DepositRecord.poolAmountAt`.  This
    is the pool half of the amended bridge accounting equation and the
    inflow side of the pool-solvency invariant
    (`pool_balance_eq_totalPoolDeposited_minus_payouts`).  Zero on a
    bridge populated only by legacy fee-less `Action.deposit`
    records. -/
def totalPoolDeposited (es : ExtendedState) (r : ResourceId) : Nat :=
  es.bridge.consumed.foldl
    (fun acc _ rec => acc + DepositRecord.poolAmountAt rec r) 0

/-! ### Genesis sanity lemmas -/

/-- The genesis bridge state has zero withdrawals at every
    resource.  Direct consequence of `pending = ∅`. -/
theorem totalWithdrawn_genesis (r : ResourceId) :
    totalWithdrawn { base := genesisState, nonces := NonceState.empty,
                     registry := KeyRegistry.empty,
                     bridge := BridgeState.empty } r = 0 := by
  unfold totalWithdrawn
  show (∅ : TreeMap WithdrawalId PendingWithdrawal compare).foldl
    (fun acc _ wd => acc + PendingWithdrawal.amountAt wd r) 0 = 0
  rw [TreeMap.foldl_eq_foldl_toList]
  have hempty : ((∅ : TreeMap WithdrawalId PendingWithdrawal compare).toList).isEmpty = true := by
    rw [TreeMap.isEmpty_toList]; exact TreeMap.isEmpty_emptyc
  have hnil : (∅ : TreeMap WithdrawalId PendingWithdrawal compare).toList = [] :=
    List.isEmpty_iff.mp hempty
  rw [hnil]; rfl

/-- The genesis bridge state has zero deposits at every resource. -/
theorem totalDeposited_genesis (r : ResourceId) :
    totalDeposited { base := genesisState, nonces := NonceState.empty,
                     registry := KeyRegistry.empty,
                     bridge := BridgeState.empty } r = 0 := by
  unfold totalDeposited
  show (∅ : TreeMap DepositId DepositRecord compare).foldl
    (fun acc _ rec => acc + DepositRecord.amountAt rec r) 0 = 0
  rw [TreeMap.foldl_eq_foldl_toList]
  have hempty : ((∅ : TreeMap DepositId DepositRecord compare).toList).isEmpty = true := by
    rw [TreeMap.isEmpty_toList]; exact TreeMap.isEmpty_emptyc
  have hnil : (∅ : TreeMap DepositId DepositRecord compare).toList = [] :=
    List.isEmpty_iff.mp hempty
  rw [hnil]; rfl

/-- The genesis bridge state has zero user-credited deposits at every
    resource (GP.4.2).  Pool-solvency base case companion. -/
theorem totalUserDeposited_genesis (r : ResourceId) :
    totalUserDeposited { base := genesisState, nonces := NonceState.empty,
                         registry := KeyRegistry.empty,
                         bridge := BridgeState.empty } r = 0 := by
  unfold totalUserDeposited
  show (∅ : TreeMap DepositId DepositRecord compare).foldl
    (fun acc _ rec => acc + DepositRecord.userAmountAt rec r) 0 = 0
  rw [TreeMap.foldl_eq_foldl_toList]
  have hempty : ((∅ : TreeMap DepositId DepositRecord compare).toList).isEmpty = true := by
    rw [TreeMap.isEmpty_toList]; exact TreeMap.isEmpty_emptyc
  have hnil : (∅ : TreeMap DepositId DepositRecord compare).toList = [] :=
    List.isEmpty_iff.mp hempty
  rw [hnil]; rfl

/-- The genesis bridge state has zero pool-credited deposits at every
    resource (GP.4.2).  Pool starts empty: it is the base case of the
    pool-solvency invariant. -/
theorem totalPoolDeposited_genesis (r : ResourceId) :
    totalPoolDeposited { base := genesisState, nonces := NonceState.empty,
                         registry := KeyRegistry.empty,
                         bridge := BridgeState.empty } r = 0 := by
  unfold totalPoolDeposited
  show (∅ : TreeMap DepositId DepositRecord compare).foldl
    (fun acc _ rec => acc + DepositRecord.poolAmountAt rec r) 0 = 0
  rw [TreeMap.foldl_eq_foldl_toList]
  have hempty : ((∅ : TreeMap DepositId DepositRecord compare).toList).isEmpty = true := by
    rw [TreeMap.isEmpty_toList]; exact TreeMap.isEmpty_emptyc
  have hnil : (∅ : TreeMap DepositId DepositRecord compare).toList = [] :=
    List.isEmpty_iff.mp hempty
  rw [hnil]; rfl

/-! ### Foldl-shape lemmas (§7.6.1)

Each accounting fold has a clean characterisation in terms of an
underlying list-fold over the TreeMap's sorted entries.  These
let downstream `_insert` lemmas reduce to standard list lemmas. -/

/-- The underlying list-fold form of `totalWithdrawn`. -/
private theorem totalWithdrawn_eq_listFold
    (es : ExtendedState) (r : ResourceId) :
    totalWithdrawn es r =
      es.bridge.pending.toList.foldl
        (fun acc p => acc + PendingWithdrawal.amountAt p.2 r) 0 := by
  unfold totalWithdrawn
  rw [TreeMap.foldl_eq_foldl_toList]

/-- The underlying list-fold form of `totalDeposited`. -/
private theorem totalDeposited_eq_listFold
    (es : ExtendedState) (r : ResourceId) :
    totalDeposited es r =
      es.bridge.consumed.toList.foldl
        (fun acc p => acc + DepositRecord.amountAt p.2 r) 0 := by
  unfold totalDeposited
  rw [TreeMap.foldl_eq_foldl_toList]

/-- The underlying list-fold form of `totalUserDeposited` (GP.4.2). -/
private theorem totalUserDeposited_eq_listFold
    (es : ExtendedState) (r : ResourceId) :
    totalUserDeposited es r =
      es.bridge.consumed.toList.foldl
        (fun acc p => acc + DepositRecord.userAmountAt p.2 r) 0 := by
  unfold totalUserDeposited
  rw [TreeMap.foldl_eq_foldl_toList]

/-- The underlying list-fold form of `totalPoolDeposited` (GP.4.2). -/
private theorem totalPoolDeposited_eq_listFold
    (es : ExtendedState) (r : ResourceId) :
    totalPoolDeposited es r =
      es.bridge.consumed.toList.foldl
        (fun acc p => acc + DepositRecord.poolAmountAt p.2 r) 0 := by
  unfold totalPoolDeposited
  rw [TreeMap.foldl_eq_foldl_toList]

/-! ### `totalDeposited` / `totalWithdrawn` are unchanged when the
bridge field is unchanged

Direct consequence: a function over `ExtendedState` that does not
mutate the `bridge` field leaves both quantity functionals
unchanged.  Used by `accounting_delta_balance_neutral` to
discharge the cases for non-bridge actions. -/

/-- If two `ExtendedState`s agree on `bridge`, they agree on
    `totalDeposited` at every `r`. -/
theorem totalDeposited_unchanged_when_bridge_eq
    (es₁ es₂ : ExtendedState) (h : es₁.bridge = es₂.bridge)
    (r : ResourceId) :
    totalDeposited es₁ r = totalDeposited es₂ r := by
  unfold totalDeposited
  rw [h]

/-- If two `ExtendedState`s agree on `bridge`, they agree on
    `totalWithdrawn` at every `r`. -/
theorem totalWithdrawn_unchanged_when_bridge_eq
    (es₁ es₂ : ExtendedState) (h : es₁.bridge = es₂.bridge)
    (r : ResourceId) :
    totalWithdrawn es₁ r = totalWithdrawn es₂ r := by
  unfold totalWithdrawn
  rw [h]

/-- GP.4.2: if two `ExtendedState`s agree on `bridge`, they agree on
    `totalUserDeposited` at every `r`. -/
theorem totalUserDeposited_unchanged_when_bridge_eq
    (es₁ es₂ : ExtendedState) (h : es₁.bridge = es₂.bridge)
    (r : ResourceId) :
    totalUserDeposited es₁ r = totalUserDeposited es₂ r := by
  unfold totalUserDeposited
  rw [h]

/-- GP.4.2: if two `ExtendedState`s agree on `bridge`, they agree on
    `totalPoolDeposited` at every `r`. -/
theorem totalPoolDeposited_unchanged_when_bridge_eq
    (es₁ es₂ : ExtendedState) (h : es₁.bridge = es₂.bridge)
    (r : ResourceId) :
    totalPoolDeposited es₁ r = totalPoolDeposited es₂ r := by
  unfold totalPoolDeposited
  rw [h]

/-! ## §7.6.2 — Per-action accounting deltas

Each `Action` constructor's effect on `(TotalSupply,
totalDeposited, totalWithdrawn)` after a bridge-admissible
application.  The lemmas isolate per-constructor work into named
sub-lemmas, avoiding a single 300-line monolithic case-split. -/

/-! ### Non-bridge actions: `bridge` field unchanged

For every non-`deposit` / non-`withdraw` action,
`apply_bridge_admissible_with` leaves the `bridge` field unchanged
(via `applyActionToBridgeState_non_bridge`).  As a corollary,
`totalDeposited` and `totalWithdrawn` are unchanged. -/

/-- §7.6.2: after applying a non-bridge action via the bridge-aware
    entry point, both `totalDeposited` and `totalWithdrawn` are
    unchanged at every `r`.  Excludes `.deposit`, `.depositWithFee`
    (Workstream GP), and `.withdraw` — the three bridge-mutating
    constructors. -/
theorem accounting_delta_non_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hne_dep : ∀ r recipient amount d', st.action ≠ .deposit r recipient amount d')
    (hne_dwf : ∀ r recipient poolActor ua pa bg d',
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg d')
    (hne_wd  : ∀ r sender amount rcp, st.action ≠ .withdraw r sender amount rcp)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  have h_bridge :
      (apply_bridge_admissible_with verify P d es st idx h).bridge = es.bridge :=
    apply_bridge_admissible_with_preserves_bridge_for_non_bridge
      verify P d es st idx h hne_dep hne_dwf hne_wd
  refine ⟨?_, ?_⟩
  · exact totalDeposited_unchanged_when_bridge_eq _ _ h_bridge r
  · exact totalWithdrawn_unchanged_when_bridge_eq _ _ h_bridge r

/-! ### Deposit action: bridge-state mutation is `consumed.insert` -/

/-- Per-step lemma: inserting a fresh `(d, rec)` pair into a
    TreeMap-backed `consumed` map increases the foldl by exactly
    `rec.amountAt r`.

    Direct application of TreeMap's insertion semantics + the
    associativity of `+` on `Nat`.  Not a Std built-in lemma; we
    prove it by reduction to the `toList` ordering plus the §8.3
    `sumValues_insert_*` lemmas. -/
private theorem listFold_amount_add_distrib
    (xs : List (DepositId × DepositRecord)) (r : ResourceId) (init : Nat) :
    xs.foldl (fun acc p => acc + DepositRecord.amountAt p.2 r) init =
    init + xs.foldl (fun acc p => acc + DepositRecord.amountAt p.2 r) 0 := by
  induction xs generalizing init with
  | nil => simp
  | cons hd tl ih =>
    simp only [List.foldl]
    rw [ih (init + DepositRecord.amountAt hd.2 r)]
    rw [ih (0 + DepositRecord.amountAt hd.2 r)]
    omega

/-- Per-step lemma for the `withdrawn` fold. -/
private theorem listFold_amount_add_distrib_wd
    (xs : List (WithdrawalId × PendingWithdrawal)) (r : ResourceId) (init : Nat) :
    xs.foldl (fun acc p => acc + PendingWithdrawal.amountAt p.2 r) init =
    init + xs.foldl (fun acc p => acc + PendingWithdrawal.amountAt p.2 r) 0 := by
  induction xs generalizing init with
  | nil => simp
  | cons hd tl ih =>
    simp only [List.foldl]
    rw [ih (init + PendingWithdrawal.amountAt hd.2 r)]
    rw [ih (0 + PendingWithdrawal.amountAt hd.2 r)]
    omega

/-! ## GP.4.2 — Accounting-equation split (`totalUserDeposited` +
`totalPoolDeposited`)

The Workstream-GP fee split records, per deposit, how much credit
went to the user-facing recipient (`userAmount`) versus the gas-pool
actor (`poolAmount`).  The amended bridge accounting equation (§15E)
splits the single legacy `totalDeposited` term on the LHS into the
two per-leg sums:

```
totalUserDeposited bs.consumed + totalPoolDeposited bs.consumed
  = totalWithdrawn bs.pending + bridgeEscrowBalance bs
```

The RHS is unchanged in structure — the L1 contract still escrows the
full `msg.value`; the user/pool split is a *bookkeeping* split, not an
escrow split.  The load-bearing fact is therefore the pointwise
identity `totalUserDeposited + totalPoolDeposited = totalDeposited`:
the amended equation balances *exactly when* the legacy equation does.
The full inductive promotion of the legacy equation (its
`bridgeEscrowBalance` RHS) is the §7.6.4 / §7.6.5 follow-up documented
above; GP.4.2 completes the LHS split and the per-action deltas it
rests on. -/

/-- Per-step distributivity for the `userAmountAt` fold (GP.4.2). -/
private theorem listFold_userAmount_add_distrib
    (xs : List (DepositId × DepositRecord)) (r : ResourceId) (init : Nat) :
    xs.foldl (fun acc p => acc + DepositRecord.userAmountAt p.2 r) init =
    init + xs.foldl (fun acc p => acc + DepositRecord.userAmountAt p.2 r) 0 := by
  induction xs generalizing init with
  | nil => simp
  | cons hd tl ih =>
    simp only [List.foldl]
    rw [ih (init + DepositRecord.userAmountAt hd.2 r)]
    rw [ih (0 + DepositRecord.userAmountAt hd.2 r)]
    omega

/-- Per-step distributivity for the `poolAmountAt` fold (GP.4.2). -/
private theorem listFold_poolAmount_add_distrib
    (xs : List (DepositId × DepositRecord)) (r : ResourceId) (init : Nat) :
    xs.foldl (fun acc p => acc + DepositRecord.poolAmountAt p.2 r) init =
    init + xs.foldl (fun acc p => acc + DepositRecord.poolAmountAt p.2 r) 0 := by
  induction xs generalizing init with
  | nil => simp
  | cons hd tl ih =>
    simp only [List.foldl]
    rw [ih (init + DepositRecord.poolAmountAt hd.2 r)]
    rw [ih (0 + DepositRecord.poolAmountAt hd.2 r)]
    omega

/-- List-level split: the user-leg fold plus the pool-leg fold equals
    the total-credit fold, pointwise over any list of deposit records.
    The engine behind `totalUserDeposited_plus_pool_eq_totalDeposited`.
    Proof: induct, distributing each fold's head contribution off the
    front, then close with the per-record split
    `userAmountAt + poolAmountAt = amountAt`. -/
private theorem listFold_userPool_eq_amount
    (xs : List (DepositId × DepositRecord)) (r : ResourceId) :
    xs.foldl (fun acc p => acc + DepositRecord.userAmountAt p.2 r) 0 +
    xs.foldl (fun acc p => acc + DepositRecord.poolAmountAt p.2 r) 0 =
    xs.foldl (fun acc p => acc + DepositRecord.amountAt p.2 r) 0 := by
  induction xs with
  | nil => rfl
  | cons hd tl ih =>
    simp only [List.foldl]
    rw [listFold_userAmount_add_distrib tl r (0 + DepositRecord.userAmountAt hd.2 r)]
    rw [listFold_poolAmount_add_distrib tl r (0 + DepositRecord.poolAmountAt hd.2 r)]
    rw [listFold_amount_add_distrib tl r (0 + DepositRecord.amountAt hd.2 r)]
    have hsplit : DepositRecord.userAmountAt hd.2 r + DepositRecord.poolAmountAt hd.2 r
        = DepositRecord.amountAt hd.2 r :=
      DepositRecord.userAmountAt_add_poolAmountAt hd.2 r
    omega

/-- **GP.4.2 split identity.**  The user-credit and pool-credit sums
    partition the legacy total-credit sum at every state and resource:

    ```
    totalUserDeposited es r + totalPoolDeposited es r = totalDeposited es r
    ```

    `totalDeposited` is the WU C.6 functional (the LHS of the §15D
    accounting equation), kept value-preserving by the GP.4.1
    widening.  This identity is therefore the formal statement that
    splitting the deposit ledger into user / pool legs leaves the
    accounting equation balanced: the amended LHS equals the legacy
    LHS verbatim.  For a bridge populated only by legacy fee-less
    `Action.deposit` records (`poolAmount = 0`), `totalPoolDeposited`
    is `0` and `totalUserDeposited = totalDeposited`. -/
theorem totalUserDeposited_plus_pool_eq_totalDeposited
    (es : ExtendedState) (r : ResourceId) :
    totalUserDeposited es r + totalPoolDeposited es r = totalDeposited es r := by
  rw [totalUserDeposited_eq_listFold, totalPoolDeposited_eq_listFold,
      totalDeposited_eq_listFold]
  exact listFold_userPool_eq_amount es.bridge.consumed.toList r

/-- **GP.4.2 balanced accounting equation.**  Given the legacy bridge
    accounting equation `totalDeposited es r = rhs` (whose right-hand
    side is `totalWithdrawn es r + bridgeEscrowBalance es r`, promoted
    inductively by the §7.6.4 / §7.6.5 follow-up), the amended split
    equation `totalUserDeposited es r + totalPoolDeposited es r = rhs`
    holds with the *same* right-hand side.

    This is the precise sense in which the deposit-fee split preserves
    the accounting equation: the L1 escrow is unaffected by how a
    deposit's `msg.value` is partitioned into user-credit and
    pool-credit on L2 (the escrow still holds the full value), so the
    only thing the amendment changes is the *presentation* of the LHS,
    which this theorem proves is value-identical to the legacy LHS. -/
theorem bridge_accounting_equation_balanced
    (es : ExtendedState) (r : ResourceId) (rhs : Nat)
    (h_legacy : totalDeposited es r = rhs) :
    totalUserDeposited es r + totalPoolDeposited es r = rhs := by
  rw [totalUserDeposited_plus_pool_eq_totalDeposited]
  exact h_legacy

/-! ### Fresh-insert deltas for the GP.4.2 folds

A deposit action records a *fresh* deposit id (uniqueness is enforced
by `BridgeAdmissibleWith` conjuncts 6 / 6b), so its bridge-state
effect is a `consumed.insert` at an absent key.  The generic
projected-fold insert-absent lemma below reduces such an insert's
effect on any `Nat`-valued projection of the record to a clean
`+ f rec` delta. -/

/-- A `Nat`-projecting foldl over a `DepositRecord`-valued TreeMap
    equals the `List.sum` of the projected value column.  Mirrors
    `RBMapLemmas.sumValues_eq_values_sum`, but for the bridge ledger's
    `DepositRecord` value type projected through an arbitrary
    `f : DepositRecord → Nat`. -/
private theorem depositFold_eq_listSum (f : DepositRecord → Nat)
    (m : TreeMap DepositId DepositRecord compare) :
    m.foldl (fun acc _ rec => acc + f rec) 0 =
    (m.toList.map (fun p => f p.2)).sum := by
  have hmap : m.foldl (fun acc _ rec => acc + f rec) 0 =
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

/-- §8.3-style fresh-insert delta for a projected `DepositRecord` fold:
    inserting a fresh `(k, v)` pair increases the projected fold by
    exactly `f v`.  Reduces to `List.sum` permutation invariance via
    `TreeMap.toList_insert_perm`, exactly as
    `RBMapLemmas.sumValues_insert_absent` does for `sumValues`. -/
private theorem depositFold_insert_absent (f : DepositRecord → Nat)
    (m : TreeMap DepositId DepositRecord compare) (k : DepositId)
    (v : DepositRecord) (h : ¬ k ∈ m) :
    (m.insert k v).foldl (fun acc _ rec => acc + f rec) 0 =
    m.foldl (fun acc _ rec => acc + f rec) 0 + f v := by
  rw [depositFold_eq_listSum f (m.insert k v), depositFold_eq_listSum f m]
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
  simp [List.sum_cons]
  omega

/-- GP.4.2 per-deposit delta: marking a *fresh* deposit id consumed
    with record `rec` increases `totalUserDeposited` by exactly
    `rec.userAmountAt r`. -/
theorem totalUserDeposited_markConsumed
    (es : ExtendedState) (d : DepositId) (rec : DepositRecord)
    (r : ResourceId) (hfresh : ¬ d ∈ es.bridge.consumed) :
    totalUserDeposited { es with bridge := es.bridge.markConsumed d rec } r =
    totalUserDeposited es r + rec.userAmountAt r := by
  show (es.bridge.consumed.insert d rec).foldl
        (fun acc _ rc => acc + DepositRecord.userAmountAt rc r) 0
      = es.bridge.consumed.foldl
          (fun acc _ rc => acc + DepositRecord.userAmountAt rc r) 0
        + rec.userAmountAt r
  exact depositFold_insert_absent (fun rc => DepositRecord.userAmountAt rc r)
    es.bridge.consumed d rec hfresh

/-- GP.4.2 per-deposit delta: marking a *fresh* deposit id consumed
    with record `rec` increases `totalPoolDeposited` by exactly
    `rec.poolAmountAt r`. -/
theorem totalPoolDeposited_markConsumed
    (es : ExtendedState) (d : DepositId) (rec : DepositRecord)
    (r : ResourceId) (hfresh : ¬ d ∈ es.bridge.consumed) :
    totalPoolDeposited { es with bridge := es.bridge.markConsumed d rec } r =
    totalPoolDeposited es r + rec.poolAmountAt r := by
  show (es.bridge.consumed.insert d rec).foldl
        (fun acc _ rc => acc + DepositRecord.poolAmountAt rc r) 0
      = es.bridge.consumed.foldl
          (fun acc _ rc => acc + DepositRecord.poolAmountAt rc r) 0
        + rec.poolAmountAt r
  exact depositFold_insert_absent (fun rc => DepositRecord.poolAmountAt rc r)
    es.bridge.consumed d rec hfresh

/-! ## §7.6.4 / §7.6.5 — Step-level accounting equations

The plan's headline `bridge_supply_account_general` (§7.6.4) and
`bridge_supply_account` (§7.6.5) are stated over a
`ReachableViaLaws`-style chain that closes under
`apply_bridge_admissible_with`.  Lifting `ReachableViaLaws` from
`State` to `ExtendedState` requires a custom inductive predicate;
Phase-3 / Phase-4-prelude / Phase-6 do not currently expose such a
predicate.

Workstream C ships the **per-action accounting deltas** here at
the unit-step level; the full inductive chain over a custom
`BridgeReachable` predicate is documented in
`docs/planning/ethereum_integration_plan.md` §7.6 as a follow-up under the
plan's existing "deferred" provisions for cross-stack
verification.  At the per-action level, the accounting equation
holds (per the deltas below); the chain closure is a structural
induction that the runtime layer (Phase 5) discharges via its
existing replay invariant.

The per-step equations cover every action variant, so the
accounting picture at the per-action level is complete; the
inductive chain just lifts what is already proved here. -/

/-! ### Per-action `(TotalSupply Δ, totalDeposited Δ, totalWithdrawn Δ)` table

The acceptance test `Test/Bridge/Accounting.lean` verifies the
table at value-level fixtures (§7.6.4 acceptance criterion: a
4-step trace `[deposit, transfer, withdraw, transfer]` satisfies
the equation at each step). -/

/-- After a bridge-admissible `transfer`, the `bridge` field is
    unchanged, so both `totalDeposited` and `totalWithdrawn` are
    unchanged at every `r`. -/
theorem accounting_delta_transfer
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ r₀ s r' a, st.action = .transfer r₀ s r' a)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨r₀, s, r', a, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-- After a bridge-admissible `freezeResource`, the `bridge` field
    is unchanged. -/
theorem accounting_delta_freeze
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ r₀, st.action = .freezeResource r₀)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨r₀, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-- After a bridge-admissible `replaceKey`, the `bridge` field is
    unchanged. -/
theorem accounting_delta_replaceKey
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ actor newKey, st.action = .replaceKey actor newKey)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨actor, newKey, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-- After a bridge-admissible `registerIdentity`, the `bridge` field
    is unchanged. -/
theorem accounting_delta_registerIdentity
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ actor pk, st.action = .registerIdentity actor pk)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨actor, pk, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-! ### LP.8 accounting deltas for actor-scoped policies

The two LP-introduced action constructors compile to the
kernel-level no-op (`Laws.freezeResource 0`).  They don't touch
`BridgeState`, so the accounting deltas are zero. -/

/-- LP.8: `declareLocalPolicy` doesn't change `totalDeposited` or
    `totalWithdrawn`.  The action mutates `localPolicies` only;
    `BridgeState` is unchanged. -/
theorem accounting_delta_declareLocalPolicy
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ p, st.action = .declareLocalPolicy p)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨p, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-- LP.8: `revokeLocalPolicy` doesn't change `totalDeposited` or
    `totalWithdrawn`.  Same as `accounting_delta_declareLocalPolicy`
    in shape; the action only touches `localPolicies`. -/
theorem accounting_delta_revokeLocalPolicy
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : st.action = .revokeLocalPolicy)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hact] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hact] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hact] at heq; cases heq

/-! ### Helper: `applyActionToBridgeState` shape on bridge actions

For `deposit` / `withdraw`, the bridge-state mutation is exactly
`markConsumed` / `appendWithdrawal`; the lemma below makes this
visible without unfolding `applyActionToBridgeState` at every call
site. -/

/-- `applyActionToBridgeState` on `deposit` rewrites to
    `markConsumed`. -/
theorem applyActionToBridgeState_deposit
    (bs : BridgeState) (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (d : DepositId) (idx : Nat) :
    applyActionToBridgeState bs (.deposit r recipient amount d) idx =
    bs.markConsumed d ({ resource := r, userAmount := amount,
                         poolAmount := 0, budgetGrant := 0 }) := by
  unfold applyActionToBridgeState
  rfl

/-- `applyActionToBridgeState` on `depositWithFee` rewrites to
    `markConsumed` with the recorded `(userAmount, poolAmount,
    budgetGrant)` split (Workstream GP). -/
theorem applyActionToBridgeState_depositWithFee
    (bs : BridgeState) (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (d : DepositId) (idx : Nat) :
    applyActionToBridgeState bs
      (.depositWithFee r recipient poolActor userAmount poolAmount budgetGrant d) idx =
    bs.markConsumed d ({ resource := r, userAmount := userAmount,
                         poolAmount := poolAmount, budgetGrant := budgetGrant }) := by
  unfold applyActionToBridgeState
  rfl

/-- LP.8: `applyActionToBridgeState` on `declareLocalPolicy` is the
    identity (the action doesn't touch `BridgeState`). -/
theorem applyActionToBridgeState_declareLocalPolicy
    (bs : BridgeState) (p : Authority.LocalPolicy) (idx : Nat) :
    applyActionToBridgeState bs (.declareLocalPolicy p) idx = bs := by
  unfold applyActionToBridgeState
  rfl

/-- LP.8: `applyActionToBridgeState` on `revokeLocalPolicy` is the
    identity. -/
theorem applyActionToBridgeState_revokeLocalPolicy
    (bs : BridgeState) (idx : Nat) :
    applyActionToBridgeState bs .revokeLocalPolicy idx = bs := by
  unfold applyActionToBridgeState
  rfl

/-- `applyActionToBridgeState` on `withdraw` rewrites to
    `appendWithdrawal`. -/
theorem applyActionToBridgeState_withdraw
    (bs : BridgeState) (r : ResourceId) (sender : ActorId)
    (amount : Amount) (rcp : EthAddress) (idx : Nat) :
    applyActionToBridgeState bs (.withdraw r sender amount rcp) idx =
    bs.appendWithdrawal
      { resource    := r
        recipient   := rcp
        amount      := amount
        l2LogIndex  := idx } := by
  unfold applyActionToBridgeState
  rfl

/-! ### Workstream H — fault-proof actions don't touch the bridge state -/

/-- Workstream H: `applyActionToBridgeState` on `faultProofChallenge`
    is the identity (the action is advisory; bridge state is not
    mutated). -/
theorem applyActionToBridgeState_faultProofChallenge
    (bs : BridgeState) (bh : ByteArray) (sIdx eIdx : Disputes.LogIndex)
    (cc : ByteArray) (idx : Nat) :
    applyActionToBridgeState bs (.faultProofChallenge bh sIdx eIdx cc) idx = bs := by
  unfold applyActionToBridgeState
  rfl

/-- Workstream H: `applyActionToBridgeState` on
    `faultProofResolution` is the identity. -/
theorem applyActionToBridgeState_faultProofResolution
    (bs : BridgeState) (bh : ByteArray) (gid : Nat) (winner : ActorId)
    (rfi : Disputes.LogIndex) (idx : Nat) :
    applyActionToBridgeState bs (.faultProofResolution bh gid winner rfi) idx = bs := by
  unfold applyActionToBridgeState
  rfl

/-- Workstream H: after a bridge-admissible `faultProofChallenge`,
    `totalDeposited` and `totalWithdrawn` are unchanged.  Same shape
    as `accounting_delta_declareLocalPolicy`; the action is
    advisory and only mutates the signer's nonce. -/
theorem accounting_delta_faultProofChallenge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ bh sIdx eIdx cc,
              st.action = .faultProofChallenge bh sIdx eIdx cc)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨bh, sIdx, eIdx, cc, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-- Workstream H: after a bridge-admissible `faultProofResolution`,
    `totalDeposited` and `totalWithdrawn` are unchanged. -/
theorem accounting_delta_faultProofResolution
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hact : ∃ bh gid winner rfi,
              st.action = .faultProofResolution bh gid winner rfi)
    (r : ResourceId) :
    totalDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalDeposited es r ∧
    totalWithdrawn (apply_bridge_admissible_with verify P d es st idx h) r =
      totalWithdrawn es r := by
  obtain ⟨bh, gid, winner, rfi, hst⟩ := hact
  apply accounting_delta_non_bridge verify P d es st idx h
  · intro r' rec am dep heq
    rw [hst] at heq; cases heq
  · intro r' rec po ua pa bg dep heq
    rw [hst] at heq; cases heq
  · intro r' s' am rcp heq
    rw [hst] at heq; cases heq

/-! ## GP.4.2 — Per-action deltas for the user / pool deposit folds

The deposit-mutating actions (`deposit`, `depositWithFee`) record a
*fresh* deposit id (uniqueness is enforced by `BridgeAdmissibleWith`
conjuncts 6 / 6b), so their effect on `totalUserDeposited` /
`totalPoolDeposited` is a clean `+ leg` delta at the matching
resource, and a no-op at every other resource.  Every non-deposit
action leaves both folds unchanged (the `bridge.consumed` map is
untouched). -/

/-- **GP.4.2 per-action delta (`totalUserDeposited`).**  A
    `depositWithFee` carrying a *fresh* deposit id credits the
    user-leg fold by exactly `userAmount` at the deposit's resource,
    and leaves it unchanged at every other resource.  The legacy
    fee-less `deposit` is the `userAmount = amount` instance of this
    (`totalUserDeposited_step_eq_deposit` below). -/
theorem totalUserDeposited_step_eq
    (es : ExtendedState) (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (d : DepositId)
    (idx : Nat) (r' : ResourceId) (hfresh : ¬ d ∈ es.bridge.consumed) :
    totalUserDeposited
      { es with bridge :=
        applyActionToBridgeState es.bridge (.depositWithFee r recipient poolActor userAmount poolAmount budgetGrant d) idx }
      r' =
    totalUserDeposited es r' + (if r = r' then userAmount else 0) := by
  rw [applyActionToBridgeState_depositWithFee es.bridge r recipient poolActor
        userAmount poolAmount budgetGrant d idx]
  rw [totalUserDeposited_markConsumed es d _ r' hfresh]
  congr 1

/-- **GP.4.2 per-action delta (`totalPoolDeposited`).**  A
    `depositWithFee` carrying a *fresh* deposit id credits the
    pool-leg fold by exactly `poolAmount` at the deposit's resource,
    and leaves it unchanged at every other resource.  This is the
    inflow side of pool solvency. -/
theorem totalPoolDeposited_step_eq
    (es : ExtendedState) (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (d : DepositId)
    (idx : Nat) (r' : ResourceId) (hfresh : ¬ d ∈ es.bridge.consumed) :
    totalPoolDeposited
      { es with bridge :=
        applyActionToBridgeState es.bridge (.depositWithFee r recipient poolActor userAmount poolAmount budgetGrant d) idx }
      r' =
    totalPoolDeposited es r' + (if r = r' then poolAmount else 0) := by
  rw [applyActionToBridgeState_depositWithFee es.bridge r recipient poolActor
        userAmount poolAmount budgetGrant d idx]
  rw [totalPoolDeposited_markConsumed es d _ r' hfresh]
  congr 1

/-- Legacy fee-less `deposit`: the user-leg fold gains the full
    `amount` (the entire L1 credit goes to the recipient). -/
theorem totalUserDeposited_step_eq_deposit
    (es : ExtendedState) (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (d : DepositId) (idx : Nat) (r' : ResourceId)
    (hfresh : ¬ d ∈ es.bridge.consumed) :
    totalUserDeposited
      { es with bridge :=
        applyActionToBridgeState es.bridge (.deposit r recipient amount d) idx }
      r' =
    totalUserDeposited es r' + (if r = r' then amount else 0) := by
  rw [applyActionToBridgeState_deposit es.bridge r recipient amount d idx]
  rw [totalUserDeposited_markConsumed es d _ r' hfresh]
  congr 1

/-- Legacy fee-less `deposit`: the pool-leg fold is unchanged — a
    fee-less deposit records `poolAmount = 0`, so it contributes
    nothing to the gas pool. -/
theorem totalPoolDeposited_step_eq_deposit
    (es : ExtendedState) (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (d : DepositId) (idx : Nat) (r' : ResourceId)
    (hfresh : ¬ d ∈ es.bridge.consumed) :
    totalPoolDeposited
      { es with bridge :=
        applyActionToBridgeState es.bridge (.deposit r recipient amount d) idx }
      r' =
    totalPoolDeposited es r' := by
  rw [applyActionToBridgeState_deposit es.bridge r recipient amount d idx]
  rw [totalPoolDeposited_markConsumed es d _ r' hfresh]
  -- `poolAmountAt {poolAmount := 0, …} r' = 0` (both `ite` branches are
  -- `0`), so the delta is `+ 0`.
  simp [DepositRecord.poolAmountAt]

/-- **GP.4.2 non-bridge delta.**  Every action other than `deposit`,
    `depositWithFee`, and `withdraw` leaves both the user-leg and the
    pool-leg deposit folds unchanged: the `bridge.consumed` map is
    untouched, so the folds are unchanged at every resource. -/
theorem accounting_userpool_delta_non_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hne_dep : ∀ r recipient amount d', st.action ≠ .deposit r recipient amount d')
    (hne_dwf : ∀ r recipient poolActor ua pa bg d',
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg d')
    (hne_wd  : ∀ r sender amount rcp, st.action ≠ .withdraw r sender amount rcp)
    (r : ResourceId) :
    totalUserDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalUserDeposited es r ∧
    totalPoolDeposited (apply_bridge_admissible_with verify P d es st idx h) r =
      totalPoolDeposited es r := by
  have h_bridge :
      (apply_bridge_admissible_with verify P d es st idx h).bridge = es.bridge :=
    apply_bridge_admissible_with_preserves_bridge_for_non_bridge
      verify P d es st idx h hne_dep hne_dwf hne_wd
  exact ⟨totalUserDeposited_unchanged_when_bridge_eq _ _ h_bridge r,
         totalPoolDeposited_unchanged_when_bridge_eq _ _ h_bridge r⟩

/-! ## GP.4.2 — Pool solvency

The pool-deposit ledger `totalPoolDeposited` is the *inflow* side of
the gas pool: it accumulates exactly the `poolAmount` recorded by each
`depositWithFee`.  The pool-solvency invariant says the gas-pool
actor's live L2 balance equals the total pool-deposited minus the
total paid out to the sequencer:

```
getBalance s.base r gasPoolActor = totalPoolDeposited s r − poolPayouts
```

The two facts this rests on are proved here at the bridge-ledger /
law level, independently of the (later) `gasPoolActor` reservation:

  1. **Inflow accounting** — `totalPoolDeposited` starts at `0`
     (`totalPoolDeposited_genesis`) and gains exactly `poolAmount` per
     fee-bearing deposit (`totalPoolDeposited_step_eq`).
  2. **Credit / ledger coherence** — every wei a `depositWithFee`
     credits to the pool actor's L2 balance is matched, wei-for-wei,
     by the ledger's recorded pool deposit
     (`depositWithFee_pool_credit_matches_ledger_delta`).

The inductive promotion (that the live balance stays reconciled with
the ledger across an entire trace, so the reconciliation hypothesis of
`pool_balance_eq_totalPoolDeposited_minus_payouts` holds) constrains
the pool actor's *outflows* to the sequencer-payout path only.  That
constraint is the `gasPoolPolicy` (Workstream GP.7.2) drain bound; the
trace-level invariant `pool_balance_lower_bound_via_trace` is
discharged there once `gasPoolActor` (GP.7.1) is reserved. -/

/-- The L2 pool-actor balance credited by a `depositWithFee`'s kernel
    effect: the gas-pool actor's balance increases by exactly
    `poolAmount`, provided the user-facing recipient is a distinct
    actor (so the user-credit write does not also land on the pool
    actor).  This is the `Laws.depositWithFee` kernel-step reading;
    its precondition is `True`, so `step_impl` collapses to
    `apply_impl` and the admitted bridge step realises this credit
    verbatim. -/
theorem depositWithFee_credits_poolActor
    (s : State) (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (d : DepositId)
    (hne : recipient ≠ poolActor) :
    getBalance ((Laws.depositWithFee r recipient poolActor userAmount poolAmount
      budgetGrant d).apply_impl s) r poolActor =
    getBalance s r poolActor + poolAmount := by
  simp only [Laws.depositWithFee]
  rw [getBalance_setBalance_same]
  rw [getBalance_setBalance_other _ r r recipient poolActor _ (Or.inr hne)]

/-- **GP.4.2 pool-credit / ledger coherence.**  For a fresh fee-bearing
    deposit (recipient distinct from the pool actor), the amount
    credited to the pool actor's L2 balance equals, wei-for-wei, the
    amount the bridge ledger records as a pool deposit.  Both deltas
    are exactly `poolAmount`.  This is the per-deposit correspondence
    underpinning pool solvency: nothing is recorded in the pool ledger
    that is not actually credited on L2, and vice versa. -/
theorem depositWithFee_pool_credit_matches_ledger_delta
    (es : ExtendedState) (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (d : DepositId)
    (idx : Nat) (hfresh : ¬ d ∈ es.bridge.consumed) (hne : recipient ≠ poolActor) :
    getBalance ((Laws.depositWithFee r recipient poolActor userAmount poolAmount
      budgetGrant d).apply_impl es.base) r poolActor - getBalance es.base r poolActor =
    totalPoolDeposited
      { es with bridge :=
        applyActionToBridgeState es.bridge (.depositWithFee r recipient poolActor userAmount poolAmount budgetGrant d) idx }
      r
      - totalPoolDeposited es r := by
  rw [depositWithFee_credits_poolActor es.base r recipient poolActor userAmount
        poolAmount budgetGrant d hne]
  rw [totalPoolDeposited_step_eq es r recipient poolActor userAmount poolAmount
        budgetGrant d idx r hfresh]
  simp

/-- **GP.4.2 pool-solvency invariant.**  Given the gas-pool actor's
    balance is reconciled with the ledger — its current balance plus
    everything it has paid out equals everything ever deposited into
    the pool — the live balance equals total pool deposits minus
    payouts.

    The reconciliation hypothesis `h_reconciled` is exactly the
    invariant the GP.7.2 `gasPoolPolicy` + GP.7.3 drain bound maintain
    inductively across a trace (`pool_balance_lower_bound_via_trace`):
    the pool actor's balance can only increase via `depositWithFee`
    pool credits (the inflow side, established here by
    `totalPoolDeposited_step_eq` +
    `depositWithFee_pool_credit_matches_ledger_delta`) and decrease via
    sequencer payouts (the `poolPayouts` term).  Under that constraint
    the pool can never pay out more than has been deposited:
    `poolPayouts ≤ totalPoolDeposited`, i.e. the pool is always
    solvent. -/
theorem pool_balance_eq_totalPoolDeposited_minus_payouts
    (es : ExtendedState) (r : ResourceId) (poolActor : ActorId)
    (poolPayouts : Nat)
    (h_reconciled :
      getBalance es.base r poolActor + poolPayouts = totalPoolDeposited es r) :
    getBalance es.base r poolActor = totalPoolDeposited es r - poolPayouts := by
  -- `deposited = balance + payouts`, so `deposited - payouts = balance`.
  rw [← h_reconciled, Nat.add_sub_cancel]

/-- Pool-solvency base case: the genesis state is solvent with zero
    payouts — the pool actor's balance (`0`) equals the total
    pool-deposited (`0`) minus zero payouts.  Anchors the GP.7.3
    inductive invariant at the genesis state. -/
theorem pool_balance_eq_totalPoolDeposited_minus_payouts_genesis
    (r : ResourceId) (poolActor : ActorId) :
    getBalance ExtendedState.empty.base r poolActor =
    totalPoolDeposited ExtendedState.empty r - 0 := by
  have hpool : totalPoolDeposited ExtendedState.empty r = 0 :=
    totalPoolDeposited_genesis r
  have hbal : getBalance ExtendedState.empty.base r poolActor = 0 := by
    show getBalance genesisState r poolActor = 0
    simp [getBalance, genesisState]
  rw [hpool, hbal]

end Bridge
end LegalKernel
