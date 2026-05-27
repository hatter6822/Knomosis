/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.Finalisation — Workstream D.3
(`docs/planning/ethereum_integration_plan.md` §8.3).

The snapshot-window finalisation policy: when a snapshot's
withdrawal root is "redeemable" on L1.  Two conditions must hold:

  1. **L1 confirmation maturity.**  The L1 transaction that
     submitted the snapshot's state root has at least
     `disputeWindowBlocks` confirmations on L1 (i.e.,
     `currentL1Block ≥ submitL1Block + disputeWindowBlocks`).

  2. **No upheld dispute against the snapshot's range.**  No
     `Verdict.upheld` has been applied against any log entry in
     `[snap.logIndexLow, snap.logIndexHigh)` — the snapshot's
     covered log range.  Phase 6's `disputeStatus` walk-the-log
     machinery is decidable, so the predicate is decidable.

Coverage:

  * D.3 — `FinalisableSnapshot` wrapper structure, `isFinalised`
    predicate, plus `isFinalised_monotonic_in_currentBlock` and
    `isFinalised_implies_no_upheld_against` headline theorems.

The `FinalisableSnapshot` wraps the existing `Runtime.Snapshot`
with the finalisation metadata the predicate requires
(`logIndexLow`, `logIndexHigh`, `submitL1Block`) without breaking
the Phase-5 Snapshot contract.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Disputes.Filing

namespace LegalKernel
namespace Bridge

open LegalKernel.Runtime
open LegalKernel.Disputes

/-! ## FinalisableSnapshot

A snapshot wrapped with the finalisation metadata required by
the §8.3 finalisation predicate:

  * `submitL1Block` — the L1 block height at which the
    snapshot's state root was submitted via
    `KnomosisBridge.submitStateRoot`.  Used to check confirmation
    maturity against the dispute window.
  * `logIndexLow` / `logIndexHigh` — the range of log indices
    this snapshot covers `[low, high)`.  An "upheld" dispute
    against any index in this range invalidates the snapshot
    for redemption.

The `snapshot` field carries the underlying `Runtime.Snapshot`
(state hash + encoded state + log index + seed hash). -/

/-- A `Runtime.Snapshot` wrapped with finalisation metadata. -/
structure FinalisableSnapshot where
  /-- The underlying state snapshot. -/
  snapshot       : Snapshot
  /-- The L1 block at which `submitStateRoot` was called. -/
  submitL1Block  : Nat
  /-- The lower bound (inclusive) of the log range this snapshot
      covers. -/
  logIndexLow    : Nat
  /-- The upper bound (exclusive) of the log range this snapshot
      covers. -/
  logIndexHigh   : Nat
  deriving Repr

/-! ## isFinalised predicate -/

/-- Check whether any log entry in `[fromIdx, toIdx)` has an
    upheld-decided dispute status.

    Implemented as a forward walk: scan `log[fromIdx]` through
    `log[toIdx - 1]`, calling `disputeStatus` at each index, and
    return `true` iff any is `some (.decided .upheld)`.

    Cost: `O((toIdx - fromIdx) * log.length)` (one
    walk-the-log per index in the range).  Production
    deployments can compute the per-index dispute status once
    and cache; we use the simpler form here for the proof. -/
def hasUpheldInRange (log : List LogEntry) (fromIdx toIdx : Nat) : Bool :=
  go log fromIdx toIdx (toIdx - fromIdx)
where
  go (log : List LogEntry) (i : Nat) (toIdx : Nat) :
      Nat → Bool
    | 0      => false
    | n + 1 =>
      if i ≥ toIdx then false
      else
        match disputeStatus log i with
        | some (.decided .upheld) => true
        | _                        => go log (i + 1) toIdx n

/-- §8.3: a snapshot is finalised when both:
      1. The dispute window has elapsed
         (`currentL1Block ≥ submitL1Block + disputeWindowBlocks`).
      2. No `.upheld` dispute has been recorded against any log
         entry in the snapshot's covered range. -/
def isFinalised (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
                (disputeWindowBlocks : Nat)
                (log : List LogEntry) : Bool :=
  decide (currentL1Block ≥ fsnap.submitL1Block + disputeWindowBlocks) &&
  !hasUpheldInRange log fsnap.logIndexLow fsnap.logIndexHigh

/-! ## §8.3 theorems -/

/-- §8.3: confirmation-maturity is monotonic in `currentL1Block`.
    Once finalised, always finalised (assuming the log doesn't
    accumulate new upheld disputes — which the predicate already
    guards against). -/
theorem isFinalised_monotonic_in_currentBlock
    (fsnap : FinalisableSnapshot) (b₁ b₂ : Nat) (w : Nat)
    (log : List LogEntry)
    (h_le : b₁ ≤ b₂)
    (h_fin : isFinalised fsnap b₁ w log = true) :
    isFinalised fsnap b₂ w log = true := by
  unfold isFinalised at h_fin ⊢
  -- Bool && simplifies via Bool.and_eq_true.
  rw [Bool.and_eq_true] at h_fin ⊢
  refine ⟨?_, h_fin.2⟩
  -- The decide-of-(b₁ ≥ submit + w) is true; need to lift to b₂ ≥ submit + w.
  have h_b₁ : b₁ ≥ fsnap.submitL1Block + w := of_decide_eq_true h_fin.1
  have h_b₂ : b₂ ≥ fsnap.submitL1Block + w := Nat.le_trans h_b₁ h_le
  exact decide_eq_true h_b₂

/-- The complement form: if `hasUpheldInRange` returns `false`,
    no index in the range has an upheld decision. -/
theorem hasUpheldInRange_false_implies
    (log : List LogEntry) (fromIdx toIdx : Nat)
    (h : hasUpheldInRange log fromIdx toIdx = false) :
    ∀ idx, fromIdx ≤ idx → idx < toIdx →
      disputeStatus log idx ≠ some (DisputeStatus.decided EvidenceVerdict.upheld) := by
  -- Induction on the fuel.
  unfold hasUpheldInRange at h
  intro idx h_low h_high
  -- The actual proof goes through induction on `n` (the fuel), tracking the current `i`.
  -- Generalise: for any fromIdx, fuel, with go log fromIdx toIdx fuel = false
  -- AND fromIdx + fuel ≥ toIdx, every idx in [fromIdx, toIdx) has non-upheld status.
  have h_aux : ∀ (n : Nat) (i : Nat),
      hasUpheldInRange.go log i toIdx n = false →
      i + n ≥ toIdx →
      ∀ j, i ≤ j → j < toIdx →
        disputeStatus log j ≠ some (DisputeStatus.decided EvidenceVerdict.upheld) := by
    intro n
    induction n with
    | zero =>
      intro i _ h_bound j h_j_low h_j_high
      -- n = 0 means i ≥ toIdx, so j ≥ i ≥ toIdx contradicts j < toIdx.
      have h_i_ge : i ≥ toIdx := by omega
      omega
    | succ k ih =>
      intro i h_go h_bound j h_j_low h_j_high
      unfold hasUpheldInRange.go at h_go
      split at h_go
      case isTrue h_ge =>
        -- i ≥ toIdx; vacuous since j < toIdx ≤ i ≤ j contradicts.
        omega
      case isFalse h_lt =>
        -- i < toIdx.
        -- Case-split on disputeStatus log i.
        cases h_disp : disputeStatus log i with
        | none =>
          -- Non-upheld; the match's default returns go log (i+1) toIdx n.
          rw [h_disp] at h_go
          -- h_go : go log (i+1) toIdx n = false.
          rcases Nat.eq_or_lt_of_le h_j_low with h_eq | h_lt_j
          · -- j = i; disputeStatus at j is none ≠ some (.decided .upheld).
            rw [← h_eq, h_disp]; simp
          · exact ih (i + 1) h_go (by omega) j (by omega) h_j_high
        | some s =>
          -- s could be (.decided .upheld) or anything else.
          cases s with
          | «open» =>
            rw [h_disp] at h_go
            rcases Nat.eq_or_lt_of_le h_j_low with h_eq | h_lt_j
            · rw [← h_eq, h_disp]
              intro h_c; cases h_c
            · exact ih (i + 1) h_go (by omega) j (by omega) h_j_high
          | withdrawn =>
            rw [h_disp] at h_go
            rcases Nat.eq_or_lt_of_le h_j_low with h_eq | h_lt_j
            · rw [← h_eq, h_disp]
              intro h_c; cases h_c
            · exact ih (i + 1) h_go (by omega) j (by omega) h_j_high
          | decided o =>
            cases o with
            | upheld =>
              -- The match's first branch fired; h_go : true = false. Contradiction.
              rw [h_disp] at h_go
              exact absurd h_go (by simp)
            | rejected =>
              rw [h_disp] at h_go
              rcases Nat.eq_or_lt_of_le h_j_low with h_eq | h_lt_j
              · rw [← h_eq, h_disp]
                intro h_c; cases h_c
              · exact ih (i + 1) h_go (by omega) j (by omega) h_j_high
            | inconclusive =>
              rw [h_disp] at h_go
              rcases Nat.eq_or_lt_of_le h_j_low with h_eq | h_lt_j
              · rw [← h_eq, h_disp]
                intro h_c; cases h_c
              · exact ih (i + 1) h_go (by omega) j (by omega) h_j_high
  exact h_aux (toIdx - fromIdx) fromIdx h (by omega) idx h_low h_high

/-- §8.3 #2: a finalised snapshot's covered log range has no
    upheld disputes. -/
theorem isFinalised_implies_no_upheld_against
    (fsnap : FinalisableSnapshot) (b w : Nat) (log : List LogEntry)
    (h_fin : isFinalised fsnap b w log = true) :
    ∀ idx, fsnap.logIndexLow ≤ idx → idx < fsnap.logIndexHigh →
      disputeStatus log idx ≠ some (DisputeStatus.decided EvidenceVerdict.upheld) := by
  unfold isFinalised at h_fin
  rw [Bool.and_eq_true] at h_fin
  obtain ⟨_, h_no_upheld⟩ := h_fin
  -- h_no_upheld : !hasUpheldInRange log fsnap.logIndexLow fsnap.logIndexHigh = true
  -- ↔ hasUpheldInRange log fsnap.logIndexLow fsnap.logIndexHigh = false
  have h_eq : hasUpheldInRange log fsnap.logIndexLow fsnap.logIndexHigh = false :=
    Bool.not_eq_true' _ |>.mp h_no_upheld
  exact hasUpheldInRange_false_implies log _ _ h_eq

/-! ## isFinalised determinism -/

/-- `isFinalised` is deterministic: equal inputs produce equal
    booleans. -/
theorem isFinalised_deterministic
    (fsnap₁ fsnap₂ : FinalisableSnapshot) (b₁ b₂ w₁ w₂ : Nat)
    (log₁ log₂ : List LogEntry)
    (hf : fsnap₁ = fsnap₂) (hb : b₁ = b₂) (hw : w₁ = w₂) (hl : log₁ = log₂) :
    isFinalised fsnap₁ b₁ w₁ log₁ = isFinalised fsnap₂ b₂ w₂ log₂ := by
  rw [hf, hb, hw, hl]

/-! ## §8.2 / §8.3 — `extractFinalisedProof`

Combines `extractProof` (§8.2) with the §8.3 finalisation predicate:
the spec §8.2 says the extractor should return `none` if the
snapshot is not yet finalised.  Production deployments call this
wrapper from the CLI / runtime rather than the bare `extractProof`.

The wrapper is conservative: it returns `none` if the finalisation
check fails, and only delegates to `extractProof` on the
underlying snapshot otherwise.  The headline consistency theorem
`extractFinalisedProof_consistent_with_root` lifts §8.2's
`extractProof_consistent_with_root` to the finalised form. -/

/-- Extract a withdrawal proof, but only if the snapshot is
    finalised under the supplied current-block / dispute-window
    parameters.  Returns `none` if the snapshot is not finalised
    OR if `extractProof` itself returns `none`. -/
def extractFinalisedProof
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (disputeWindowBlocks : Nat) (log : List LogEntry)
    (idx : WithdrawalId) : Option WithdrawalProof :=
  if isFinalised fsnap currentL1Block disputeWindowBlocks log then
    extractProof fsnap.snapshot idx
  else
    none

/-- §8.2 + §8.3: a proof extracted from a finalised snapshot
    verifies against the snapshot's withdrawal root.

    Composition of `isFinalised` (§8.3) and
    `extractProof_consistent_with_root` (§8.2). -/
theorem extractFinalisedProof_consistent_with_root
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (disputeWindowBlocks : Nat) (log : List LogEntry)
    (idx : WithdrawalId) (proof : WithdrawalProof)
    (h : extractFinalisedProof fsnap currentL1Block disputeWindowBlocks log idx
        = some proof) :
    verifyProof hashBytes proof fsnap.snapshot.bridgeWithdrawalRoot = true := by
  unfold extractFinalisedProof at h
  split at h
  case isTrue h_fin =>
    -- Snapshot is finalised; defer to extractProof_consistent_with_root.
    exact extractProof_consistent_with_root fsnap.snapshot idx proof h
  case isFalse h_not_fin =>
    -- Not finalised; extractFinalisedProof returned none, contradicting h.
    exact absurd h (by simp)

/-- `extractFinalisedProof` is deterministic: equal inputs produce
    equal proof outputs. -/
theorem extractFinalisedProof_deterministic
    (fsnap₁ fsnap₂ : FinalisableSnapshot) (b₁ b₂ w₁ w₂ : Nat)
    (log₁ log₂ : List LogEntry) (idx₁ idx₂ : WithdrawalId)
    (hf : fsnap₁ = fsnap₂) (hb : b₁ = b₂) (hw : w₁ = w₂)
    (hl : log₁ = log₂) (hi : idx₁ = idx₂) :
    extractFinalisedProof fsnap₁ b₁ w₁ log₁ idx₁ =
      extractFinalisedProof fsnap₂ b₂ w₂ log₂ idx₂ := by
  rw [hf, hb, hw, hl, hi]

/-- Negative: an unfinalised snapshot returns `none` regardless of
    the underlying snapshot's pending state. -/
theorem extractFinalisedProof_unfinalised
    (fsnap : FinalisableSnapshot) (currentL1Block : Nat)
    (disputeWindowBlocks : Nat) (log : List LogEntry)
    (idx : WithdrawalId)
    (h_not_fin : isFinalised fsnap currentL1Block disputeWindowBlocks log = false) :
    extractFinalisedProof fsnap currentL1Block disputeWindowBlocks log idx = none := by
  unfold extractFinalisedProof
  rw [h_not_fin]; rfl

end Bridge
end LegalKernel
