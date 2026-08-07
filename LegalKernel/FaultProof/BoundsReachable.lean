-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.BoundsReachable — the amount ceiling is a
property of reachable states, not a standing assumption.

`ExtendedState.CanonicalBounds` (`FaultProof/Commit.lean`) is carried
as a hypothesis by every commitment-injectivity and terminal-step
theorem on this project, and until now **nothing established it** — a
search for it in conclusion position returned empty.  That is the
half of finding C-3 the two previous widenings (`2^64` → `2^128` →
`2^256`) did not do: each moved the ceiling without ever showing it
unreachable, so the same defect could recur at the next modulus.

This module closes that for the field the fault proof actually turns
on, `base_amt`.  `Laws.AmountBounded` is a precondition conjunct on
every crediting law (`Laws/AmountBound.lean`), so a step cannot lift a
balance over the ceiling; `BalancesBounded` is the whole-state form of
that, and it is *preserved* by every admissible step and hence by
every reachable state.

**Why a new reachability relation.**  `Bridge.BridgeReachable` is
restricted to the three bridge-state-mutating actions, because the
chain-accounting identity it serves is about the bridge ledger.  A
whole-state bound has to survive `transfer`, `mint`, `ammSwap` and the
rest, so it needs the unrestricted relation — same production stepper
and same admissibility gate, without the `BridgeAction` restriction.
`AdmissibleReachable` is that relation, and `BridgeReachable` embeds
into it (`admissibleReachable_of_bridgeReachable`).

**Scope.**  `base_amt` is discharged.  The remaining `CanonicalBounds`
fields are NOT, and the reason differs by field rather than being one
missing lemma:

* the `< 256 ^ 8` map-LENGTH fields (`base_outer_len`, `nonces_len`,
  `registry_len`, …) and the `2^64` value fields (`nonces_val`,
  `eb_val`) are bounded by *trace length*, not by any per-step
  conjunct.  Each step adds at most a bounded number of entries and
  advances a nonce by one, so `2^64` is unreachable in any real trace
  — but "any real trace" is a statement about `n`, and the honest form
  is the step-indexed `AdmissibleReachableIn` below plus
  `expectsNonce_le_of_reachableIn`, which give the bound for
  `n < 2^64` rather than unconditionally.
* the SIZE fields (`registry_size`, `lp_size`, `bs_cons_size`, …) are
  bounded by the submitted payload, so they need an admission-layer
  cap on action field widths, which no gate currently imposes.

Both are recorded in `docs/audits/19-findings-and-followups.md` rather
than papered over: a narrowed hypothesis is the honest record.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Bridge.Reachable
import LegalKernel.Laws.AmountBound

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge

/-! ## The whole-state form of the ceiling -/

/-- Every balance the state holds is strictly under `Laws.maxAmount`.

    Stated POINTWISE over `getBalance` rather than over the balance
    maps' `toList`s, which is the form `CanonicalBounds.base_amt`
    takes.  The pointwise form is what the per-law preservation proofs
    can actually manipulate — `setBalance` has clean `getBalance`
    lemmas and no clean `toList` ones — and
    `canonicalBounds_base_amt_of_balancesBounded` converts, so nothing
    is lost. -/
def BalancesBounded (es : ExtendedState) : Prop :=
  ∀ r a, LegalKernel.getBalance es.base r a < Laws.maxAmount

/-- The pointwise bound gives `CanonicalBounds`' `base_amt` field.

    A live map entry IS what `getBalance` reads there, so the two
    forms agree on entries the state holds; the pointwise form
    additionally says the `0` default is under the ceiling, which is
    free. -/
theorem canonicalBounds_base_amt_of_balancesBounded (es : ExtendedState)
    (h : BalancesBounded es) :
    ∀ p ∈ es.base.balances.toList, ∀ q ∈ p.2.toList, q.2 < 256 ^ 32 := by
  intro p hp q hq
  have houter : es.base.balances[p.1]? = some p.2 :=
    Std.TreeMap.mem_toList_iff_getElem?_eq_some.mp hp
  have hinner : p.2[q.1]? = some q.2 :=
    Std.TreeMap.mem_toList_iff_getElem?_eq_some.mp hq
  have := h p.1 q.1
  unfold LegalKernel.getBalance at this
  rw [houter] at this
  show q.2 < Laws.maxAmount
  simpa [hinner] using this

/-! ## One write preserves the bound

The single lemma every per-law case reduces to: a `setBalance` whose
written value is under the ceiling leaves the whole state under it.
-/

/-- A bounded write preserves the whole-state bound. -/
theorem balancesBounded_setBalance {s : State} {r₀ : ResourceId} {a₀ : ActorId}
    {v : Nat} (hs : ∀ r a, LegalKernel.getBalance s r a < Laws.maxAmount)
    (hv : v < Laws.maxAmount) :
    ∀ r a, LegalKernel.getBalance (setBalance s r₀ a₀ v) r a < Laws.maxAmount := by
  intro r a
  by_cases h : r = r₀ ∧ a = a₀
  · obtain ⟨hr, ha⟩ := h
    subst hr; subst ha
    rw [getBalance_setBalance_same]
    exact hv
  · rw [getBalance_setBalance_other s r₀ r a₀ a v
      (by
        rcases Classical.em (r = r₀) with hr | hr
        · exact Or.inr (fun ha => h ⟨hr, ha.symm⟩)
        · exact Or.inl (fun he => hr he.symm))]
    exact hs r a

/-- A debit preserves the bound with no side condition: `Nat`
    subtraction only shrinks.  The reason `burn`, `withdraw` and every
    debit leg carry no ceiling conjunct of their own. -/
theorem balancesBounded_setBalance_sub {s : State} {r₀ : ResourceId} {a₀ : ActorId}
    {d : Nat} (hs : ∀ r a, LegalKernel.getBalance s r a < Laws.maxAmount) :
    ∀ r a, LegalKernel.getBalance
      (setBalance s r₀ a₀ (LegalKernel.getBalance s r₀ a₀ - d)) r a
        < Laws.maxAmount :=
  balancesBounded_setBalance hs
    (Nat.lt_of_le_of_lt (Nat.sub_le _ _) (hs r₀ a₀))

/-- A write that keeps the value it found preserves the bound — the
    shape a law's no-op branch takes. -/
theorem balancesBounded_setBalance_self {s : State} {r₀ : ResourceId} {a₀ : ActorId}
    (hs : ∀ r a, LegalKernel.getBalance s r a < Laws.maxAmount) :
    ∀ r a, LegalKernel.getBalance
      (setBalance s r₀ a₀ (LegalKernel.getBalance s r₀ a₀)) r a < Laws.maxAmount :=
  balancesBounded_setBalance hs (hs r₀ a₀)

/-! ## The bulk fold

Both bulk laws credit every recipient in one `foldl`, so the
single-write lemma does not reach them.  The induction has to carry a
SECOND invariant besides the bound — that each remaining recipient's
credit is still under the ceiling — because the fold's state moves
under it.  That invariant survives a step for exactly the reason the
precondition can be stated against the pre-state at all: the
recipients are pairwise distinct, so a write at one leaves the others
where they were.
-/

/-- A distinct-key crediting fold preserves the bound.

    `credit` is a parameter rather than a fixed `amount` because the
    two bulk laws pay differently — `distributeOthers` a flat amount,
    `proportionalDilute` a share of the snapshot — and both credits
    are functions of the recipient ENTRY, not of the running state,
    which is what makes one lemma serve both. -/
theorem balancesBounded_bulk_foldl (r : ResourceId)
    (credit : ActorId × Amount → Nat) :
    ∀ (xs : List (ActorId × Amount)) (s : State),
      (∀ r' a', LegalKernel.getBalance s r' a' < Laws.maxAmount) →
      xs.Pairwise (fun a b => a.1 ≠ b.1) →
      (∀ kv ∈ xs, LegalKernel.getBalance s r kv.1 + credit kv < Laws.maxAmount) →
      ∀ r' a', LegalKernel.getBalance
        (xs.foldl (fun s' kv =>
          setBalance s' r kv.1 (LegalKernel.getBalance s' r kv.1 + credit kv)) s)
        r' a' < Laws.maxAmount := by
  intro xs
  induction xs with
  | nil => intro s hs _ _; exact hs
  | cons hd tl ih =>
    intro s hs hpair hall
    simp only [List.foldl]
    refine ih _ ?_ (List.Pairwise.of_cons hpair) ?_
    · exact balancesBounded_setBalance hs (hall hd (List.mem_cons_self ..))
    · intro kv hkv
      -- `kv.1 ≠ hd.1`, so the head's write is invisible at `kv`.
      have hne : hd.1 ≠ kv.1 := (List.pairwise_cons.mp hpair).1 kv hkv
      rw [getBalance_setBalance_other _ r r hd.1 kv.1 _ (Or.inr hne)]
      exact hall kv (List.mem_cons_of_mem _ hkv)

/-! ## One admitted advance preserves the bound

The per-action case analysis.  Eleven variants do not touch `State` at
all (it is exactly `{ balances }`, and their `apply_impl` is `fun s =>
s`), so they are immediate.  Of the fourteen that do, the debit-only
ones need no hypothesis — `Nat` subtraction shrinks — and every
crediting one reads its bound straight off the precondition conjunct
`Laws/AmountBound.lean` put there.

That is the point of the whole exercise: the case that used to be
unprovable is now the case that closes by projection.
-/

/-- **A law's advance preserves the amount ceiling.**

    Stated over `apply_impl` under the precondition rather than over
    `step_impl`, because that is where the content is; the `step_impl`
    form below adds only the no-op branch. -/
theorem balancesBounded_apply_impl (a : Action) (signer : ActorId) (s : State)
    (hs : ∀ r a', LegalKernel.getBalance s r a' < Laws.maxAmount)
    (hpre : (Action.toTransition a signer).pre s) :
    ∀ r a', LegalKernel.getBalance
      ((Action.toTransition a signer).apply_impl s) r a' < Laws.maxAmount := by
  cases a with
  -- The eleven variants whose kernel effect is the identity on `State`.
  | freezeResource _ => exact hs
  | replaceKey _ _ => exact hs
  | dispute _ => exact hs
  | disputeWithdraw _ => exact hs
  | verdict _ => exact hs
  | rollback _ => exact hs
  | registerIdentity _ _ => exact hs
  | declareLocalPolicy _ => exact hs
  | revokeLocalPolicy => exact hs
  | faultProofChallenge _ => exact hs
  | faultProofResolution _ _ => exact hs
  -- Credits: the bound is the precondition's own conjunct.
  | mint r to amount => exact balancesBounded_setBalance hs hpre.2
  | reward r to amount => exact balancesBounded_setBalance hs hpre.2
  | deposit r recipient amount d => exact balancesBounded_setBalance hs hpre
  -- Debits: subtraction only shrinks, so no conjunct is needed.
  | burn r fromActor amount => exact balancesBounded_setBalance_sub hs
  | withdraw r sender amount rcp => exact balancesBounded_setBalance_sub hs
  -- Debit-then-credit pairs: the debit by shrinkage, the credit by the
  -- conjunct, which is stated over the POST-DEBIT state exactly as the
  -- law's own credit reads it.
  | transfer r sender receiver amount =>
      exact balancesBounded_setBalance (balancesBounded_setBalance_sub hs) hpre.2.2
  | topUpActionBudget gr ga bi pa =>
      exact balancesBounded_setBalance (balancesBounded_setBalance_sub hs) hpre.2
  | topUpActionBudgetFor recipient gr ga bi pa =>
      exact balancesBounded_setBalance (balancesBounded_setBalance_sub hs) hpre.2.2
  | claimBudgetRefund gr bu w pa =>
      exact balancesBounded_setBalance (balancesBounded_setBalance_sub hs) hpre.2
  | reclaimAmmReserves r amount reserveActor poolActor =>
      exact balancesBounded_setBalance (balancesBounded_setBalance_sub hs) hpre.2.2.2
  -- Three chained credits (Workstream SB added the seed leg), each
  -- bounded by its own precondition conjunct.
  | depositWithFee r recipient poolActor ua pa bg d sa =>
      exact balancesBounded_setBalance
        (balancesBounded_setBalance (balancesBounded_setBalance hs hpre.1)
          hpre.2.1)
        hpre.2.2.2
  -- Workstream SB: the four-write user swap — debit, credit, debit,
  -- credit; each credit's bound is its own precondition conjunct,
  -- stated over exactly the chained intermediate state the law's
  -- apply reads.
  | reserveSwap fromResource toResource user amountIn minAmountOut reserveActor =>
      exact balancesBounded_setBalance
        (balancesBounded_setBalance_sub
          (balancesBounded_setBalance (balancesBounded_setBalance_sub hs)
            hpre.2.2.2.2.2.2.2.2.1))
        hpre.2.2.2.2.2.2.2.2.2.1
  -- The bulk pair: one fold, distinct recipients.
  | distributeOthers r excluded amount =>
      exact balancesBounded_bulk_foldl r (fun _ => amount) _ s hs
        (Laws.bulkRecipients_keys_pairwise_ne s r excluded) hpre.2.2
  | proportionalDilute r excluded totalReward =>
      exact balancesBounded_bulk_foldl r
        (fun kv => totalReward * kv.2 / sumOthers s r excluded) _ s hs
        (Laws.bulkRecipients_keys_pairwise_ne s r excluded) hpre.2.2.2

/-- ...hence so does a whole `step_impl`, the no-op branch included. -/
theorem balancesBounded_step_impl (a : Action) (signer : ActorId) (s : State)
    (hs : ∀ r a', LegalKernel.getBalance s r a' < Laws.maxAmount) :
    ∀ r a', LegalKernel.getBalance
      (step_impl s (Action.toTransition a signer)) r a' < Laws.maxAmount := by
  unfold step_impl
  by_cases hpre : (Action.toTransition a signer).pre s
  · rw [if_pos hpre]; exact balancesBounded_apply_impl a signer s hs hpre
  · rw [if_neg hpre]; exact hs

/-! ## Reachability over the whole action set -/

/-- `AdmissibleReachable verify P deploymentId es es'`: `es'` is
    reachable from `es` by a finite sequence of bridge-admissible
    steps over ANY action, each advanced through the production
    `apply_bridge_admissible_with` stepper.

    The unrestricted counterpart of `Bridge.BridgeReachable`, which
    admits only the three bridge-state-mutating actions.  That
    restriction is right for the chain-accounting identity — the
    others do not move the bridge ledger — and wrong for a whole-state
    bound, which `transfer` and `mint` can break just as easily. -/
inductive AdmissibleReachable
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray) :
    ExtendedState → ExtendedState → Prop where
  /-- A state is reachable from itself in zero steps. -/
  | refl (es : ExtendedState) : AdmissibleReachable verify P deploymentId es es
  /-- Prepend one admissible step to a chain. -/
  | step {es es'' : ExtendedState} (st : SignedAction) (l2LogIndex : Nat)
      (h : BridgeAdmissibleWith verify P deploymentId es st)
      (hnext : AdmissibleReachable verify P deploymentId
                 (apply_bridge_admissible_with verify P deploymentId es st
                   l2LogIndex h) es'') :
      AdmissibleReachable verify P deploymentId es es''

/-- Every bridge-reachable state is admissible-reachable: the bridge
    relation is this one restricted to three constructors.

    Stated so the CA chain-accounting results and this module's bound
    apply to the same states rather than to two families that merely
    look alike. -/
theorem admissibleReachable_of_bridgeReachable
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es es' : ExtendedState}
    (h : BridgeReachable verify P d es es') :
    AdmissibleReachable verify P d es es' := by
  induction h with
  | refl es => exact .refl es
  | step ba st idx _ hadm _ ih => exact .step st idx hadm ih

/-! ## The `2^64` fields are bounded by trace length, not by a conjunct

`nonces_val` and `eb_val` sit on the 8-byte head, and the decision NOT
to widen them rests on a reachability argument: each advances by a
bounded increment per action, so `2^64` is out of reach of any real
trace.  That argument is load-bearing, so it is stated where it can be
checked rather than left in a comment.

**The nonce half is proved here.**  `expectsNonce_admissible_step_le`
gives `≤ +1` per step and `expectsNonce_le_of_reachableIn` composes it
along a trace.  What that yields is weaker than `base_amt`'s
unconditional bound, and deliberately so: the conclusion is
`expectsNonce es' a ≤ expectsNonce es a + n`, and turning it into
`< 2^64` needs a hypothesis about `n`.  A theorem claiming otherwise
would be false.

**The budget half is NOT the same argument, and an earlier draft of
this docstring stated it wrongly.**  It read "a budget by at most
`Authority.MAX_TOPUP_BUDGET_PER_ACTION`", which is false on two
independent counts, and it claimed to be checked here while no theorem
about `budgetBalance` existed anywhere:

  * `ActorBudget.normalise` floors a stale cell at the policy's
    `freeTier` (`max b.budgetBalance freeTier`) BEFORE the credit
    lands, so one step can lift a balance of `0` to `freeTier + amount`
    however small the grant.  `BudgetPolicy.bounded` takes `freeTier`
    as an unbounded `Nat` and `mkBounded` clamps only `actionCost`, so
    nothing caps that term;
  * `depositWithFee`'s `budgetGrant` is not covered by the cap.
    `topUpActionBudget_gasCheck` bounds `budgetIncrement` for
    `.topUpActionBudget` and `topUpActionBudgetFor_gate` for the
    delegated variant, but `depositWithFee` reaches `applyGrant`
    through `depositWithFee_signerCheck`, which constrains the SIGNER
    (`= bridgeActor`) and not the amount.

The true per-step statement is `max stored freeTier + grant`, and it
is now proved rather than asserted:
`Authority.EpochBudgetState.storedBalance_topUp_le` and
`…_consume_le` bound every actor's stored cell across the two
operations `applyGrant` and the consume step are built from.  Those
are stated over `storedBalance` — the raw number
`FaultProof.budgetCellValue` encodes — rather than `currentBudget`,
which folds the free-tier floor in and so cannot be transported to the
cell.

**Why the residual matters more here than for the nonce.**  Lean's
`Encodable Nat` is total and truncating, so a stored balance at or
above `2^64` encodes as its residue and the published root goes blind
to it — the C-3 shape.  The Solidity mirror does not truncate: it
REVERTS (`CBEEncode._leBytes` → `CBEValueTooWide`).  The two stacks
therefore disagree at the ceiling rather than merely losing precision,
and by this file's own "a revert is not a verdict" reasoning the party
whose turn it is would lose by timeout.  Reaching the ceiling needs a
`freeTier` at `2^64`, a bridge-signed grant that large, or ~1.8·10^13
capped top-ups; the first is a configuration a deployment controls and
nothing currently rejects. -/

/-- One admissible step raises any actor's expected nonce by at most
    one — exactly one at the signer, and not at all elsewhere. -/
theorem expectsNonce_admissible_step_le
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    (h : BridgeAdmissibleWith verify P d es st) (a : ActorId) :
    expectsNonce (apply_bridge_admissible_with verify P d es st idx h) a
      ≤ expectsNonce es a + 1 := by
  show (advanceNonce { es with base := _ } st.signer).nonces.next[a]?.getD 0
    ≤ es.nonces.next[a]?.getD 0 + 1
  by_cases hsig : st.signer = a
  · subst hsig
    rw [show (advanceNonce ({ es with base := _ } : ExtendedState)
          st.signer).nonces.next[st.signer]?.getD 0
        = expectsNonce ({ es with base := _ } : ExtendedState) st.signer + 1 from
      expectsNonce_strict_mono _ st.signer]
    exact Nat.le_refl _
  · rw [show (advanceNonce ({ es with base := _ } : ExtendedState)
          st.signer).nonces.next[a]?.getD 0
        = expectsNonce ({ es with base := _ } : ExtendedState) a from
      expectsNonce_advance_other _ st.signer a hsig]
    exact Nat.le_succ _

/-- Step-indexed reachability: `es'` is reachable from `es` in exactly
    `n` admissible steps.

    Carries the step count the un-indexed `AdmissibleReachable` throws
    away, which is precisely what a growth bound needs. -/
inductive AdmissibleReachableIn
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray) :
    Nat → ExtendedState → ExtendedState → Prop where
  /-- Zero steps. -/
  | refl (es : ExtendedState) : AdmissibleReachableIn verify P deploymentId 0 es es
  /-- One more step. -/
  | step {n : Nat} {es es'' : ExtendedState} (st : SignedAction) (l2LogIndex : Nat)
      (h : BridgeAdmissibleWith verify P deploymentId es st)
      (hnext : AdmissibleReachableIn verify P deploymentId n
                 (apply_bridge_admissible_with verify P deploymentId es st
                   l2LogIndex h) es'') :
      AdmissibleReachableIn verify P deploymentId (n + 1) es es''

/-- **A nonce grows by at most the trace length.**

    The W2 result: `2^64` is not reachable in any trace shorter than
    `2^64` steps, which is why the nonce cell stays on the 8-byte head
    rather than paying 24 extra bytes in every fault-proof opening
    (the nonce is one of the two cells EVERY action writes). -/
theorem expectsNonce_le_of_reachableIn
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {n : Nat} {es es' : ExtendedState}
    (h : AdmissibleReachableIn verify P d n es es') (a : ActorId) :
    expectsNonce es' a ≤ expectsNonce es a + n := by
  induction h with
  | refl es => exact Nat.le_refl _
  | @step n es es'' st idx hadm _ ih =>
      -- `ih` bounds the tail against the POST-step state; the step
      -- lemma bounds that against `es`.  Composing the two is the
      -- whole argument, spelled as a `calc` rather than handed to
      -- `omega`: the two facts mention the same `apply_…` term, and
      -- omega treats it as an opaque atom only if it is syntactically
      -- identical in both — which it is here, but only once the
      -- intermediate step is named.
      calc expectsNonce es'' a
          ≤ expectsNonce (apply_bridge_admissible_with _ _ _ es st idx hadm) a + n := ih
        _ ≤ (expectsNonce es a + 1) + n :=
            Nat.add_le_add_right (expectsNonce_admissible_step_le hadm a) n
        _ = expectsNonce es a + (n + 1) := Nat.add_right_comm _ _ _

/-- ...hence `CanonicalBounds`' nonce field holds for any trace whose
    length leaves room under the head.

    Stated with the trace-length hypothesis explicit rather than
    discharged, because it cannot be discharged: nothing in the step
    relation bounds how many actions a deployment may process.  What
    the theorem does establish is that the ceiling is unreachable by
    CONSTRUCTION of the step relation rather than merely improbable —
    a nonce cannot jump, only increment. -/
theorem expectsNonce_lt_of_reachableIn
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {n : Nat} {es es' : ExtendedState}
    (h : AdmissibleReachableIn verify P d n es es') (a : ActorId)
    (hstart : expectsNonce es a = 0) (hn : n < 256 ^ 8) :
    expectsNonce es' a < 256 ^ 8 :=
  Nat.lt_of_le_of_lt (by simpa [hstart] using expectsNonce_le_of_reachableIn h a) hn

/-! ## The bound is inductive, hence true of every reachable state -/

/-- One admissible bridge step preserves the whole-state bound. -/
theorem balancesBounded_admissible_step
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    (h : BridgeAdmissibleWith verify P d es st)
    (hb : BalancesBounded es) :
    BalancesBounded (apply_bridge_admissible_with verify P d es st idx h) := by
  intro r a
  rw [apply_bridge_admissible_with_base]
  exact balancesBounded_step_impl st.action st.signer es.base hb r a

/-- **The amount ceiling holds at every reachable state.**

    The induction C-3 was missing.  `Laws.AmountBounded` makes the
    bound a precondition conjunct, `balancesBounded_apply_impl` makes
    it inductive over all twenty-five variants, and this composes it
    along a trace. -/
theorem balancesBounded_of_admissibleReachable
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es es' : ExtendedState}
    (hb : BalancesBounded es)
    (h : AdmissibleReachable verify P d es es') :
    BalancesBounded es' := by
  induction h with
  | refl _ => exact hb
  | step st idx hadm _ ih => exact ih (balancesBounded_admissible_step hadm hb)

/-- Genesis holds the bound vacuously: it carries no balances. -/
theorem balancesBounded_genesis (es : ExtendedState)
    (h : es.base.balances.isEmpty = true) : BalancesBounded es := by
  intro r a
  unfold LegalKernel.getBalance
  have : es.base.balances[r]? = none := by
    rcases hq : es.base.balances[r]? with _ | bm
    · rfl
    · exact absurd (Std.TreeMap.isEmpty_eq_false_iff_exists_mem.mpr
        ⟨r, Std.TreeMap.mem_iff_isSome_getElem?.mpr (by rw [hq]; rfl)⟩)
        (by rw [h]; exact Bool.noConfusion)
  rw [this]
  exact Nat.pow_pos (by decide)

/-- **`CanonicalBounds.base_amt`, discharged over reachability.**

    The headline of this module, and the closure of C-3's second half.
    Every theorem that carries `ExtendedState.CanonicalBounds` as a
    hypothesis can now obtain this field from the trace rather than
    assuming it — the assumption that, until now, nothing anywhere
    established.

    The other twenty-four fields remain hypotheses; see this module's
    header for why they are a different problem (trace-length bounds
    and payload-width caps) rather than the same one left undone. -/
theorem canonicalBounds_base_amt_of_reachable
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es es' : ExtendedState}
    (hb : BalancesBounded es)
    (h : AdmissibleReachable verify P d es es') :
    ∀ p ∈ es'.base.balances.toList, ∀ q ∈ p.2.toList, q.2 < 256 ^ 32 :=
  canonicalBounds_base_amt_of_balancesBounded es'
    (balancesBounded_of_admissibleReachable hb h)

end FaultProof
end LegalKernel
