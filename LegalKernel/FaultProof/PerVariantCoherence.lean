/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.PerVariantCoherence — per-Action-variant
coherence theorems #226.* and #251.* (Workstream H WUs H.1.3.*).

The headline universal coherence theorem #225
(`recomputeCommitment_coherent_with_kernelOnlyApply` in
`Coherence.lean`) covers all 19 Action variants by construction
(both sides of the equation reduce to the same
`commitExtendedState ∘ kernelOnlyApply` definition).  This module
ships the per-variant *specialisations* per the plan §5.4.* and
§5.6.* WU breakdown:

  * `#226.<variant>` — per-variant coherence between the
    L1 step VM's specialised step function and `kernelOnlyApply`
    for that constructor.
  * `#251.<variant>` — per-variant cell-write semantic agreement
    between `applyCellWrites_to_state` and the kernel.

Both forms are corollaries of the universal form (#225), but
documenting them per-variant aids cross-stack debugging: a
fixture failure can be localised to a specific variant.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Coherence

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-- Helper: wrap a SignedAction into a LogEntry for
    `kernelOnlyApply`'s signature. -/
private def signedActionToLogEntry (st : SignedAction) : LogEntry :=
  { prevHash := ByteArray.empty,
    signedAction := st,
    postStateHash := ByteArray.empty }

/-- Per-variant template: `recomputeCommitment` agrees with
    `commitExtendedState ∘ kernelOnlyApply` on the wrapped log
    entry, regardless of which Action variant the SignedAction
    carries.  This is the structural reduction every per-variant
    theorem below specialises. -/
theorem recomputeCommitment_eq_signedActionToLogEntry
    (es : ExtendedState) (st : SignedAction) :
    recomputeCommitment es st =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry st)) := by
  exact recomputeCommitment_coherent_with_kernelOnlyApply
          es st (signedActionToLogEntry st) rfl

/-! ## #226.* — Per-variant coherence theorems (one per Action
    constructor).  Each pins the universal form to the specific
    constructor; because the universal form is by construction,
    each per-variant form is a structural rewrite. -/

/-- #226.transfer — coherence for `Action.transfer`. -/
theorem coherence_transfer
    (es : ExtendedState)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray)
    (h : (st : SignedAction) → st.action = .transfer r sender receiver amount →
                              st.signer = signer ∧ st.nonce = nonce ∧ st.sig = sig) :
    let st : SignedAction :=
      { action := .transfer r sender receiver amount,
        signer := signer, nonce := nonce, sig := sig }
    recomputeCommitment es st =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry st)) := by
  let _ := h
  exact recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.mint — coherence for `Action.mint`. -/
theorem coherence_mint
    (es : ExtendedState)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .mint r to amount, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .mint r to amount, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.burn — coherence for `Action.burn`. -/
theorem coherence_burn
    (es : ExtendedState)
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .burn r fromActor amount, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .burn r fromActor amount, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.freezeResource — coherence for `Action.freezeResource`. -/
theorem coherence_freezeResource
    (es : ExtendedState)
    (r : ResourceId)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .freezeResource r, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .freezeResource r, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.replaceKey — coherence for `Action.replaceKey`. -/
theorem coherence_replaceKey
    (es : ExtendedState)
    (actor : ActorId) (newKey : Authority.PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .replaceKey actor newKey, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .replaceKey actor newKey, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.reward — coherence for `Action.reward`. -/
theorem coherence_reward
    (es : ExtendedState)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .reward r to amount, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .reward r to amount, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.distributeOthers — coherence for `Action.distributeOthers`. -/
theorem coherence_distributeOthers
    (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .distributeOthers r excluded amount, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .distributeOthers r excluded amount, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.proportionalDilute — coherence for `Action.proportionalDilute`. -/
theorem coherence_proportionalDilute
    (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .proportionalDilute r excluded totalReward, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .proportionalDilute r excluded totalReward, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.dispute — coherence for `Action.dispute`. -/
theorem coherence_dispute
    (es : ExtendedState)
    (d : Dispute)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .dispute d, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .dispute d, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.disputeWithdraw — coherence for `Action.disputeWithdraw`. -/
theorem coherence_disputeWithdraw
    (es : ExtendedState)
    (idx : LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .disputeWithdraw idx, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .disputeWithdraw idx, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.verdict — coherence for `Action.verdict`. -/
theorem coherence_verdict
    (es : ExtendedState)
    (v : Verdict)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .verdict v, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .verdict v, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.rollback — coherence for `Action.rollback`. -/
theorem coherence_rollback
    (es : ExtendedState)
    (targetIdx : LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .rollback targetIdx, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .rollback targetIdx, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.registerIdentity — coherence for `Action.registerIdentity`. -/
theorem coherence_registerIdentity
    (es : ExtendedState)
    (actor : ActorId) (newKey : Authority.PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .registerIdentity actor newKey, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .registerIdentity actor newKey, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.deposit — coherence for `Action.deposit`. -/
theorem coherence_deposit
    (es : ExtendedState)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .deposit r recipient amount depositId, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .deposit r recipient amount depositId, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.withdraw — coherence for `Action.withdraw`. -/
theorem coherence_withdraw
    (es : ExtendedState)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .withdraw r sender amount recipientL1, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .withdraw r sender amount recipientL1, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.declareLocalPolicy — coherence for `Action.declareLocalPolicy`. -/
theorem coherence_declareLocalPolicy
    (es : ExtendedState)
    (policy : LegalKernel.Authority.LocalPolicy)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .declareLocalPolicy policy, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .declareLocalPolicy policy, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.revokeLocalPolicy — coherence for `Action.revokeLocalPolicy`. -/
theorem coherence_revokeLocalPolicy
    (es : ExtendedState)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .revokeLocalPolicy, signer := signer,
        nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .revokeLocalPolicy, signer := signer,
        nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.faultProofChallenge — coherence for `Action.faultProofChallenge`. -/
theorem coherence_faultProofChallenge
    (es : ExtendedState)
    (bindingHash : ByteArray)
    (disputedStartIdx disputedEndIdx : LogIndex)
    (challengerCommit : ByteArray)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .faultProofChallenge bindingHash
                    disputedStartIdx disputedEndIdx challengerCommit,
        signer := signer, nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .faultProofChallenge bindingHash
                    disputedStartIdx disputedEndIdx challengerCommit,
        signer := signer, nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-- #226.faultProofResolution — coherence for `Action.faultProofResolution`. -/
theorem coherence_faultProofResolution
    (es : ExtendedState)
    (bindingHash : ByteArray) (gameId : Nat) (winner : ActorId)
    (revertFromIdx : LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    recomputeCommitment es
      { action := .faultProofResolution bindingHash gameId winner revertFromIdx,
        signer := signer, nonce := nonce, sig := sig } =
    commitExtendedState (kernelOnlyApply es (signedActionToLogEntry
      { action := .faultProofResolution bindingHash gameId winner revertFromIdx,
        signer := signer, nonce := nonce, sig := sig })) :=
  recomputeCommitment_eq_signedActionToLogEntry es _

/-! ## #251.* — Per-variant cell-write semantic agreement.

`applyCellWrites_to_state` agrees with `kernelOnlyApply` on the
wrapped LogEntry by construction (both unfold to the same
expression).  Per-variant forms specialise to specific Action
constructors. -/

/-- The structural template: `applyCellWrites_to_state` agrees
    with `kernelOnlyApply (signedActionToLogEntry st)` for every
    SignedAction.  Both sides reduce to the same expression. -/
theorem applyCellWrites_eq_signedActionToLogEntry
    (es : ExtendedState) (st : SignedAction) :
    applyCellWrites_to_state es st = kernelOnlyApply es (signedActionToLogEntry st) := by
  unfold applyCellWrites_to_state signedActionToLogEntry
  rfl

/-- #251.transfer — semantic agreement for `Action.transfer`. -/
theorem cellwrites_transfer
    (es : ExtendedState)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .transfer r sender receiver amount, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .transfer r sender receiver amount, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.mint — semantic agreement for `Action.mint`. -/
theorem cellwrites_mint
    (es : ExtendedState)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .mint r to amount, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .mint r to amount, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.burn — semantic agreement for `Action.burn`. -/
theorem cellwrites_burn
    (es : ExtendedState)
    (r : ResourceId) (fromActor : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .burn r fromActor amount, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .burn r fromActor amount, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.freezeResource — semantic agreement for `Action.freezeResource`. -/
theorem cellwrites_freezeResource
    (es : ExtendedState)
    (r : ResourceId)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .freezeResource r, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .freezeResource r, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.replaceKey — semantic agreement for `Action.replaceKey`. -/
theorem cellwrites_replaceKey
    (es : ExtendedState)
    (actor : ActorId) (newKey : Authority.PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .replaceKey actor newKey, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .replaceKey actor newKey, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.reward — semantic agreement for `Action.reward`. -/
theorem cellwrites_reward
    (es : ExtendedState)
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .reward r to amount, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .reward r to amount, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.distributeOthers — semantic agreement for `Action.distributeOthers`. -/
theorem cellwrites_distributeOthers
    (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .distributeOthers r excluded amount, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .distributeOthers r excluded amount, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.proportionalDilute — semantic agreement for `Action.proportionalDilute`. -/
theorem cellwrites_proportionalDilute
    (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .proportionalDilute r excluded totalReward, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .proportionalDilute r excluded totalReward, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.dispute — semantic agreement for `Action.dispute`. -/
theorem cellwrites_dispute
    (es : ExtendedState)
    (d : Dispute)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .dispute d, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .dispute d, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.disputeWithdraw — semantic agreement for `Action.disputeWithdraw`. -/
theorem cellwrites_disputeWithdraw
    (es : ExtendedState)
    (idx : LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .disputeWithdraw idx, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .disputeWithdraw idx, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.verdict — semantic agreement for `Action.verdict`. -/
theorem cellwrites_verdict
    (es : ExtendedState)
    (v : Verdict)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .verdict v, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .verdict v, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.rollback — semantic agreement for `Action.rollback`. -/
theorem cellwrites_rollback
    (es : ExtendedState)
    (targetIdx : LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .rollback targetIdx, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .rollback targetIdx, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.registerIdentity — semantic agreement for `Action.registerIdentity`. -/
theorem cellwrites_registerIdentity
    (es : ExtendedState)
    (actor : ActorId) (newKey : Authority.PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .registerIdentity actor newKey, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .registerIdentity actor newKey, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.deposit — semantic agreement for `Action.deposit`. -/
theorem cellwrites_deposit
    (es : ExtendedState)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .deposit r recipient amount depositId, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .deposit r recipient amount depositId, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.withdraw — semantic agreement for `Action.withdraw`. -/
theorem cellwrites_withdraw
    (es : ExtendedState)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .withdraw r sender amount recipientL1, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .withdraw r sender amount recipientL1, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.declareLocalPolicy — semantic agreement for `Action.declareLocalPolicy`. -/
theorem cellwrites_declareLocalPolicy
    (es : ExtendedState)
    (policy : LegalKernel.Authority.LocalPolicy)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .declareLocalPolicy policy, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .declareLocalPolicy policy, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.revokeLocalPolicy — semantic agreement for `Action.revokeLocalPolicy`. -/
theorem cellwrites_revokeLocalPolicy
    (es : ExtendedState)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .revokeLocalPolicy, signer := signer,
        nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .revokeLocalPolicy, signer := signer,
        nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.faultProofChallenge — semantic agreement for `Action.faultProofChallenge`. -/
theorem cellwrites_faultProofChallenge
    (es : ExtendedState)
    (bindingHash : ByteArray)
    (disputedStartIdx disputedEndIdx : LogIndex)
    (challengerCommit : ByteArray)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .faultProofChallenge bindingHash
                    disputedStartIdx disputedEndIdx challengerCommit,
        signer := signer, nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .faultProofChallenge bindingHash
                    disputedStartIdx disputedEndIdx challengerCommit,
        signer := signer, nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

/-- #251.faultProofResolution — semantic agreement for `Action.faultProofResolution`. -/
theorem cellwrites_faultProofResolution
    (es : ExtendedState)
    (bindingHash : ByteArray) (gameId : Nat) (winner : ActorId)
    (revertFromIdx : LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    applyCellWrites_to_state es
      { action := .faultProofResolution bindingHash gameId winner revertFromIdx,
        signer := signer, nonce := nonce, sig := sig } =
    kernelOnlyApply es (signedActionToLogEntry
      { action := .faultProofResolution bindingHash gameId winner revertFromIdx,
        signer := signer, nonce := nonce, sig := sig }) :=
  applyCellWrites_eq_signedActionToLogEntry es _

end FaultProof
end LegalKernel
