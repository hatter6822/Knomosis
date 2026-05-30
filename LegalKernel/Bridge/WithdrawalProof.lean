-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.WithdrawalProof — Workstream D.2
(`docs/planning/ethereum_integration_plan.md` §8.2).

The user-facing withdrawal proof extractor: given a snapshot file
and a `WithdrawalId`, produce a `WithdrawalProof` ready for L1
redemption (or `none` if the withdrawal is not in the snapshot's
pending set).

Coverage:

  * D.2 — `extractProof` definition;
    `Snapshot.bridgeWithdrawalRoot`; `extractProof_consistent_with_root`
    (the headline theorem: every extracted proof verifies against
    the snapshot's withdrawal root).

The proof root used by `withdrawalRoot` is the production keccak256
binding (`Runtime.Hash.hashBytes`).  Tests can substitute
hash-of-a-test-vector via the parameterised `withdrawalRoot H _`
form in `WithdrawalRoot.lean`; this module wires the production
binding for end-to-end CLI use.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Runtime.Snapshot

open LegalKernel.Authority
open LegalKernel.Encoding

namespace LegalKernel.Runtime

/-! ## Snapshot.bridgeWithdrawalRoot

The withdrawal SMT root extracted from a snapshot's encoded
`ExtendedState`.  Lives in `LegalKernel.Runtime` namespace
(alongside `Snapshot`) so dot-notation works (`snap.bridgeWithdrawalRoot`). -/

/-- The withdrawal SMT root computed from the snapshot's encoded
    `ExtendedState`.

    Computed lazily from `snap.encodedState`: decode the
    `ExtendedState`, then apply `withdrawalRoot hashBytes` to its
    `bridge` field.  Returns the `defaultHash smtHeight` sentinel
    (= `withdrawalRoot hashBytes BridgeState.empty`) if the
    snapshot's bytes fail to decode (a deployment-correctness
    issue, not a redemption-validity issue).

    **Empty-tree fallback (AR.13.3).**  On decode failure, the
    fallback `withdrawalRoot hashBytes BridgeState.empty` is the
    canonical empty-tree sentinel; consumer code (`Bridge.State`'s
    redemption gate) checks the boundary explicitly before
    accepting the proof.  A decode failure surfaces upstream as
    an invalid-snapshot diagnostic rather than as silently-valid
    empty-tree redemption.

    Production deployments compute this once at snapshot-creation
    time and persist it on the L1 side; the on-Lean computation
    is the authoritative reference. -/
def Snapshot.bridgeWithdrawalRoot (snap : Snapshot) : ByteArray :=
  match Encodable.decodeAllBytes (T := ExtendedState) snap.encodedState with
  | .ok es  => Bridge.withdrawalRoot hashBytes es.bridge
  | .error _ => Bridge.withdrawalRoot hashBytes Bridge.BridgeState.empty

end LegalKernel.Runtime

namespace LegalKernel
namespace Bridge

open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## extractProof -/

/-- Extract a withdrawal proof from a finalised snapshot.

    Returns `none` if:
      * the snapshot's encoded state fails to decode, OR
      * the `idx` is not in the decoded state's `pending` map.

    Returns `some (constructProof hashBytes es.bridge idx)`
    otherwise — the canonical proof for the `idx`-th withdrawal
    in the snapshot's bridge ledger. -/
def extractProof (snap : Snapshot) (idx : WithdrawalId) :
    Option WithdrawalProof :=
  match Encodable.decodeAllBytes (T := ExtendedState) snap.encodedState with
  | .ok es =>
    match es.bridge.pending[idx]? with
    | some _ => some (constructProof hashBytes es.bridge idx)
    | none   => none
  | .error _ => none

/-! ## §8.2 — `extractProof_consistent_with_root` -/

/-- §8.2 headline theorem: if `extractProof` returns a proof, that
    proof verifies against the snapshot's withdrawal root.

    Proof: case-split on the decode of `snap.encodedState`.  If
    decode succeeds and `idx ∈ pending`, then `extractProof` returns
    the canonical proof, which verifies by `verifyProof_complete`.
    If decode fails or `idx ∉ pending`, `extractProof` returns
    `none`, contradicting the hypothesis. -/
theorem extractProof_consistent_with_root
    (snap : Snapshot) (idx : WithdrawalId) (proof : WithdrawalProof)
    (h : extractProof snap idx = some proof) :
    verifyProof hashBytes proof snap.bridgeWithdrawalRoot = true := by
  -- Case-split on the decode result, then on the pending lookup.
  unfold extractProof at h
  unfold Snapshot.bridgeWithdrawalRoot
  split at h
  case h_2 e =>
    -- decode failed; extractProof returned none, contradiction.
    exact absurd h (by simp)
  case h_1 es h_decode =>
    -- decode succeeded; case-split on pending lookup.
    split at h
    case h_2 h_none =>
      -- idx not in pending; contradiction.
      exact absurd h (by simp)
    case h_1 wd h_lookup =>
      -- h : some (constructProof hashBytes es.bridge idx) = some proof.
      have h_proof_eq : constructProof hashBytes es.bridge idx = proof :=
        Option.some.inj h
      rw [← h_proof_eq]
      exact verifyProof_complete hashBytes es.bridge idx wd h_lookup

/-! ## extractProof determinism -/

/-- `extractProof` is deterministic: equal snapshots and equal
    indices produce equal proof outputs.  Pure function, so this
    follows by `rfl` after rewriting. -/
theorem extractProof_deterministic
    (snap₁ snap₂ : Snapshot) (idx₁ idx₂ : WithdrawalId)
    (h_snap : snap₁ = snap₂) (h_idx : idx₁ = idx₂) :
    extractProof snap₁ idx₁ = extractProof snap₂ idx₂ := by
  rw [h_snap, h_idx]

/-- `Snapshot.bridgeWithdrawalRoot` is deterministic. -/
theorem bridgeWithdrawalRoot_deterministic
    (snap₁ snap₂ : Snapshot) (h : snap₁ = snap₂) :
    snap₁.bridgeWithdrawalRoot = snap₂.bridgeWithdrawalRoot := by
  rw [h]

end Bridge
end LegalKernel
