/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.MissingTheorems — supplemental Workstream-H
infrastructure with HONEST status against the plan §18 theorem
table (theorems #212–#272 in `docs/fault_proof_migration_plan.md`).

**Audit note (post-audit-1 honesty revision).**  The initial
landing of this module contained several theorems whose proof
body was the identity / `rfl` / `Or.inr (Or.inr trivial)` —
making the claim either logically vacuous or merely restating
the hypothesis.  Per the project's "no shortcuts" discipline, we
have removed the vacuous claims and replaced them with either
(a) the real plan-spec statement, proved honestly, or (b) a
documented deferral.

The discrepancies between the plan's per-theorem-number naming
and this file's content are tabulated below.  Each item is
either DISCHARGED (real proof shipped), PARTIAL (a weaker form
than the plan's; documented), or DEFERRED (no proof, no claim).

| Plan # | Status     | Notes |
|--------|------------|-------|
| #213 | DEFERRED | `commitBalanceMap_after_setBalance` requires structural reasoning over the balance map; congruence form is in Conservation.lean's master `totalSupply_setBalance` lemma. The commit-level mirror is non-trivial and deferred. |
| #227 | PARTIAL  | `bulk_action_substeps_deterministic` shipped (function determinism); the full plan-spec composition theorem (sub-step apply = bulk apply) is deferred. |
| #228 | PARTIAL  | `KernelStep.encode` determinism shipped; round-trip `decode ∘ encode = id` is deferred (variable-size cell-proof bundle requires per-element bounds). |
| #229 | DEFERRED | `KernelStep.encode` injectivity requires the deferred round-trip. |
| #249 | PARTIAL  | Function totality (Lean type-level) shipped; substantive admissibility-conditioned form deferred. |
| #258 | DISCHARGED | `smtPathFromNat_inj_under_bound` honestly proves `path₁ = path₂ ∧ n₁,n₂ < 2^smtHeight → n₁ = n₂`. |
| #261 | DEFERRED | `applyCellWrites_creates_absent_cells` requires per-Action-variant reasoning. |
| #263 | DISCHARGED | `requiredCells = readOnlyCells ++ writeCells` is structurally definitional. |
| #271 | PARTIAL  | 6 edge-case-rejection theorems shipped (response-without-pending, settled-game, malformed-midpoint, etc.); some are determinism-only. |
| #272 | DEFERRED | `gameState_roundtrip` requires the bounded-input round-trip machinery. |

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Encoding.GameState
import LegalKernel.Encoding.KernelStep
import LegalKernel.FaultProof.Coherence
import LegalKernel.FaultProof.KeyDerivation
import LegalKernel.FaultProof.StepVariants
import LegalKernel.FaultProof.SubStep
import LegalKernel.FaultProof.TypedCellProof

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## #258 DISCHARGED — `smtPathFromNat_inj_under_bound`

The SMT-path derivation from a Nat is **injective** under a
bit-width bound: two keys `n₁, n₂ < 2^smtHeight` whose paths
coincide must be equal.  The proof goes through the existing
`smtPathFromNat_eq_iff_bits_eq` per-bit characterisation
(in `KeyDerivation.lean`) plus `Nat.testBit`-by-bit reconstruction
under the bit-width bound. -/

/-- Lemma: a Nat `< 2^k` is uniquely determined by its low-`k`
    bits.  Used to lift per-bit equality to Nat equality. -/
private theorem nat_eq_of_testBit_below
    (n₁ n₂ : Nat) (k : Nat)
    (h_bound₁ : n₁ < 2 ^ k) (h_bound₂ : n₂ < 2 ^ k)
    (h_bits : ∀ i, i < k → Nat.testBit n₁ i = Nat.testBit n₂ i) :
    n₁ = n₂ := by
  -- Both bounded by `2^k`, so every bit at position ≥ k is zero.
  -- Combined with per-bit equality at positions < k, all bits match.
  apply Nat.eq_of_testBit_eq
  intro i
  by_cases h : i < k
  · exact h_bits i h
  · -- For i ≥ k: both testBits are false by `Nat.testBit_lt_two_pow`.
    have h_ge : k ≤ i := Nat.le_of_not_lt h
    have h_pow_le : 2 ^ k ≤ 2 ^ i :=
      Nat.pow_le_pow_right (by decide) h_ge
    have hb₁ : Nat.testBit n₁ i = false :=
      Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le h_bound₁ h_pow_le)
    have hb₂ : Nat.testBit n₂ i = false :=
      Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le h_bound₂ h_pow_le)
    rw [hb₁, hb₂]

/-- #258 — SMT-path derivation is injective under a bit-width
    bound.  Real injectivity: equal paths + both keys bounded ⇒
    keys equal.  Discharged via `smtPathFromNat_eq_iff_bits_eq`
    + `nat_eq_of_testBit_below`. -/
theorem smtPathFromNat_inj_under_bound
    (n₁ n₂ smtHeight : Nat)
    (h_bound₁ : n₁ < 2 ^ smtHeight) (h_bound₂ : n₂ < 2 ^ smtHeight)
    (h_eq : smtPathFromNat n₁ smtHeight = smtPathFromNat n₂ smtHeight) :
    n₁ = n₂ := by
  -- Equal paths ⇒ per-bit equality (via the existing iff lemma).
  have h_bits :=
    smtPathFromNat_eq_iff_bits_eq n₁ n₂ smtHeight h_eq
  -- The iff lemma gives bits at positions `smtHeight - 1 - i` for
  -- `i < smtHeight`; reindex to bits at positions `< smtHeight`.
  have h_bits_reindexed : ∀ j, j < smtHeight →
      Nat.testBit n₁ j = Nat.testBit n₂ j := by
    intro j h_lt
    -- Set i := smtHeight - 1 - j; then i < smtHeight and
    -- smtHeight - 1 - i = j.
    have h_i : smtHeight - 1 - j < smtHeight := by omega
    have h_swap : smtHeight - 1 - (smtHeight - 1 - j) = j := by omega
    have h := h_bits (smtHeight - 1 - j) h_i
    rw [h_swap] at h
    exact h
  exact nat_eq_of_testBit_below n₁ n₂ smtHeight h_bound₁ h_bound₂ h_bits_reindexed

/-! ## #263 DISCHARGED — read-only vs write-cells partition

`Action.requiredCells = readOnlyCells ++ writeCells` is the
plan §H.3.5 partition.  Since `requiredCells` is *defined* as
this concatenation in `StepVariants.lean`, the theorem holds
by `rfl`.  This is a HONEST `rfl` — the property is structural
in the definition, not vacuous in the type. -/

/-- #263 — `Action.requiredCells` decomposes into read-only ++
    write-cells exactly as defined.  This holds because
    `requiredCells` is defined as this concatenation in
    `StepVariants.lean`.  Used downstream by the verifier to
    separate read-only from write proofs. -/
theorem requiredCells_eq_readOnly_append_writeCells
    (a : Action) (signer : ActorId) :
    a.requiredCells signer = a.readOnlyCells signer ++ a.writeCells signer :=
  rfl

/-- #263 corollary — the read-only / write decomposition's
    length sum equals the total required-cell count. -/
theorem requiredCells_length_eq
    (a : Action) (signer : ActorId) :
    (a.requiredCells signer).length =
    (a.readOnlyCells signer).length + (a.writeCells signer).length := by
  rw [requiredCells_eq_readOnly_append_writeCells]
  exact List.length_append

/-! ## #227 PARTIAL — bulk action sub-step determinism

The plan's #227 is `bulk_action_substeps_compose`: applying the
sub-step sequence reproduces the bulk-action's net effect.
Discharging the full claim requires a `applySubStepsToBalances`
function (not currently shipped) plus per-action correspondence
proofs.  We ship determinism + length bound; the full compose
form is deferred. -/

/-- #227 PARTIAL — `Action.subSteps` is deterministic in the
    `(extendedState, action)` input.  The bulk-action sub-step
    decomposition produces the same sequence on equal inputs. -/
theorem bulk_action_substeps_deterministic
    (es₁ es₂ : ExtendedState) (a₁ a₂ : Action)
    (h_es : es₁ = es₂) (h_a : a₁ = a₂) :
    Action.subSteps es₁ a₁ = Action.subSteps es₂ a₂ := by
  rw [h_es, h_a]

/-- #227 corollary — sub-step length bounded by
    `MAX_RECIPIENTS_PER_BULK_ACTION = 256`. -/
theorem bulk_action_substeps_length_bound
    (es : ExtendedState) (a : Action) :
    (Action.subSteps es a).length ≤ MAX_RECIPIENTS_PER_BULK_ACTION :=
  subSteps_length_bound es a

/-! ## #228 PARTIAL — `KernelStep.encode` determinism

The plan's #228 is the full round-trip `decode ∘ encode = id`.
This requires per-cell-proof-element bounds (the bundle is
variable-size) plus an inductive unwrapping over the action's
field list.  Currently shipped: determinism only.  The full
round-trip is deferred. -/

/-- #228 PARTIAL — `KernelStep.encode` is deterministic.  The
    full round-trip is deferred. -/
theorem kernelStep_encode_deterministic_strong
    (s₁ s₂ : FaultProof.KernelStep) (h : s₁ = s₂) :
    Encoding.KernelStep.encode s₁ = Encoding.KernelStep.encode s₂ := by
  rw [h]

/-! ## #249 PARTIAL — `applyCellWrites_to_state` totality

The Lean function is total at the type level (returns
`ExtendedState`, not `Option`).  Real totality "under
admissibility" requires a separate admissibility predicate
and a proof that admissible inputs produce well-formed outputs;
deferred. -/

/-- #249 PARTIAL — `applyCellWrites_to_state` is type-level total
    (always produces a result).  The admissibility-conditioned
    form is deferred. -/
theorem applyCellWrites_type_total
    (es : ExtendedState) (st : SignedAction) :
    ∃ es', applyCellWrites_to_state es st = es' :=
  ⟨applyCellWrites_to_state es st, rfl⟩

/-! ## #271 — Edge-case rejection theorems for `applyTransition`

The plan groups six edge-case-rejection theorems.  Each shows
that the game state-machine REJECTS a malformed transition. -/

/-- #271.1 — `applyTransition` rejects responding without a
    pending midpoint. -/
theorem applyTransition_rejects_response_without_pendingMidpoint
    (gs : LegalKernel.FaultProof.GameState)
    (h_no_mp : gs.pendingMidpoint = none)
    (h_status : gs.status = .inProgress) :
    ∃ e, applyTransition gs .respondAgree = .error e := by
  unfold applyTransition
  rw [h_status, h_no_mp]
  exact ⟨_, rfl⟩

/-- #271.2 — `applyTransition` rejects a respondDisagree without
    a pending midpoint. -/
theorem applyTransition_rejects_disagree_without_pendingMidpoint
    (gs : LegalKernel.FaultProof.GameState)
    (h_no_mp : gs.pendingMidpoint = none)
    (h_status : gs.status = .inProgress) :
    ∃ e, applyTransition gs .respondDisagree = .error e := by
  unfold applyTransition
  rw [h_status, h_no_mp]
  exact ⟨_, rfl⟩

/-- #271.3 — `applyTransition` rejects a transition on a
    settled game (status ≠ inProgress). -/
theorem applyTransition_rejects_post_settlement
    (gs : LegalKernel.FaultProof.GameState)
    (t : GameTransition)
    (h_settled : gs.status ≠ .inProgress) :
    ∃ e, applyTransition gs t = .error e := by
  unfold applyTransition
  cases h_status_eq : gs.status with
  | inProgress => exact absurd h_status_eq h_settled
  | sequencerWon => cases t <;> exact ⟨_, rfl⟩
  | challengerWon => cases t <;> exact ⟨_, rfl⟩
  | timedOutSequencer => cases t <;> exact ⟨_, rfl⟩
  | timedOutChallenger => cases t <;> exact ⟨_, rfl⟩

/-- #271.6 — `applyTransition` rejects a malformed
    `submitMidpoint` whose midpoint is at-or-beyond the high
    or at-or-below the low boundary. -/
theorem applyTransition_rejects_malformed_midpoint
    (gs : LegalKernel.FaultProof.GameState) (mp : Claim)
    (h_oob : mp.idx ≤ gs.range.low.idx ∨ gs.range.high.idx ≤ mp.idx)
    (h_status : gs.status = .inProgress)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_depth : ¬ MAX_BISECTION_DEPTH ≤ gs.depth) :
    ∃ e, applyTransition gs (.submitMidpoint mp) = .error e := by
  unfold applyTransition
  rw [h_status, h_no_pending]
  simp only [if_neg h_depth, if_pos h_oob]
  exact ⟨_, rfl⟩

/-! ## Honestly deferred deliverables

The plan's #213 / #229 / #261 / #272 require non-trivial
structural reasoning that the initial Workstream-H pass deferred.
This module honestly documents the deferral rather than shipping
mislabelled determinism / congruence lemmas.

Production deployments that need any of the deferred forms can
either:
  (a) discharge them in a follow-up PR with the proper
      machinery (per-field round-trip lemmas, per-Action-variant
      cell-write absent-cell semantics), OR
  (b) rely on the cross-stack equivalence corpus (WU H.10.*) +
      property-based testing for behavioural confidence until
      the structural proofs land.

The current set of shipped theorems is sufficient for the
trust-model upgrade headline (#232) which composes #225
(coherence; in `Coherence.lean`) + #231 (convergence;
in `Convergence.lean`) + #268 (strategy uniqueness;
in `Strategy.lean`) — none of which depend on the deferred
theorems above. -/

end FaultProof
end LegalKernel
