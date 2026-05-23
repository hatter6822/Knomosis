/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.DisputeConfig — deployment-time routing
configuration for dispute resolution (Workstream H WU H.8.2).

Once Workstream H is deployed, deployments choose how to route
the four deterministic claim variants (`preconditionFalse`,
`signatureInvalid`, `nonceMismatch`, `doubleApply`):

  * Phase-6 adjudicator quorum (legacy path, M-of-N trust).
  * Workstream-H fault-proof game (1-of-anyone trust).
  * Both (belt-and-suspenders).

Plus the `oracleMisreported` claim variant, which is *always*
routed through the adjudicator quorum (it is not amenable to
fault-proof discharge).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Disputes.Verdict

namespace LegalKernel
namespace FaultProof

open LegalKernel.Disputes

/-! ## `DisputeConfig` -/

/-- The deployment's dispute-resolution configuration.

    `enableAdjudicatorQuorum`: route the four deterministic
        claim variants through the Phase-6 adjudicator quorum
        (legacy).  Default `true` for backwards compat.
    `enableFaultProofGame`: route the four deterministic
        claim variants through the Workstream-H fault-proof
        game.  Default `false` until the deployment migrates.
    `oracleAdjudicatorQuorum`: the quorum policy for
        `oracleMisreported` claims (always used). -/
structure DisputeConfig where
  /-- Enable Phase-6 adjudicator quorum for deterministic claims. -/
  enableAdjudicatorQuorum : Bool
  /-- Enable Workstream-H fault-proof game for deterministic claims. -/
  enableFaultProofGame    : Bool
  /-- Quorum policy for oracle-claim adjudication.  Always used
      regardless of the other flags. -/
  oracleAdjudicatorQuorum : QuorumPolicy

/-! ## Default configurations -/

/-- The legacy default: Phase-6 quorum only (no fault-proof
    game).  This is the configuration deployments land on
    pre-Workstream-H. -/
def DisputeConfig.legacyOnly (q : QuorumPolicy) : DisputeConfig where
  enableAdjudicatorQuorum := true
  enableFaultProofGame    := false
  oracleAdjudicatorQuorum := q

/-- The post-migration default: fault-proof game only for
    deterministic claims; adjudicator quorum for oracle
    claims.  This is the recommended Workstream-H deployment
    configuration. -/
def DisputeConfig.faultProofOnly (q : QuorumPolicy) : DisputeConfig where
  enableAdjudicatorQuorum := false
  enableFaultProofGame    := true
  oracleAdjudicatorQuorum := q

/-- Belt-and-suspenders: both paths active simultaneously.
    Useful during migration windows. -/
def DisputeConfig.both (q : QuorumPolicy) : DisputeConfig where
  enableAdjudicatorQuorum := true
  enableFaultProofGame    := true
  oracleAdjudicatorQuorum := q

/-! ## Routing predicates -/

/-- Whether a claim is routable through the fault-proof game. -/
def DisputeClaim.isFaultProofRoutable : DisputeClaim → Bool
  | .preconditionFalse _      => true
  | .signatureInvalid _       => true
  | .nonceMismatch _          => true
  | .doubleApply _ _          => true
  | .oracleMisreported _ _    => false

/-- Decidability of `isFaultProofRoutable`. -/
instance instDecidableIsFaultProofRoutable
    (c : DisputeClaim) :
    Decidable (DisputeClaim.isFaultProofRoutable c = true) :=
  inferInstance

/-- Predicate: under the given config, the claim should route
    through the fault-proof game. -/
def DisputeConfig.routesToFaultProof
    (cfg : DisputeConfig) (c : DisputeClaim) : Bool :=
  cfg.enableFaultProofGame && DisputeClaim.isFaultProofRoutable c

/-- Predicate: under the given config, the claim should route
    through the adjudicator quorum. -/
def DisputeConfig.routesToAdjudicatorQuorum
    (cfg : DisputeConfig) (c : DisputeClaim) : Bool :=
  match c with
  | .oracleMisreported _ _ =>
    -- Oracle claims always go to the quorum (fault-proof can't
    -- discharge them).
    true
  | _ =>
    cfg.enableAdjudicatorQuorum

/-! ## Smoke checks -/

/-- The legacy-only config doesn't route anything to fault-proof. -/
example (q : QuorumPolicy) (c : DisputeClaim) :
    (DisputeConfig.legacyOnly q).routesToFaultProof c = false := by
  unfold DisputeConfig.routesToFaultProof DisputeConfig.legacyOnly
  simp

/-- The fault-proof-only config routes deterministic claims to
    fault-proof, oracle claims to the quorum. -/
example (q : QuorumPolicy) (i : Disputes.LogIndex) :
    (DisputeConfig.faultProofOnly q).routesToFaultProof
      (.preconditionFalse i) = true := by
  unfold DisputeConfig.routesToFaultProof DisputeConfig.faultProofOnly
  simp [DisputeClaim.isFaultProofRoutable]

example (q : QuorumPolicy) (i : Disputes.LogIndex) (b : ByteArray) :
    (DisputeConfig.faultProofOnly q).routesToAdjudicatorQuorum
      (.oracleMisreported i b) = true := by
  unfold DisputeConfig.routesToAdjudicatorQuorum DisputeConfig.faultProofOnly
  simp

end FaultProof
end LegalKernel
