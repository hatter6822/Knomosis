/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Lex.LocalPolicy — Lex (LX.28) re-expression of
the two LP-introduced action constructors.

M2-milestone Lex declarations for `declareLocalPolicy` (frozen
action index 15) and `revokeLocalPolicy` (index 16; Workstream
LP).  Both compile to `Laws.freezeResource 0` at the kernel level;
the authority-layer effect (`localPolicies` mutation) lives in
`applyActionToLocalPolicies` (LP.5).

The plan §19.4 LX.28 acceptance note says:
> The codegen-input's `registry_effect` field is extended with a
> `"localPolicy"` variant; LX.19's SignedAction renderer routes
> this to `applyActionToLocalPolicies` rather than
> `applyActionToRegistry`.

The `RegistryEffectKind.localPolicy` variant already exists in
`Tools/LexCommon.lean` (it was introduced in M1); the M2
declaration uses the same `none` registry-effect classification
because the kernel-level Transition is identity (the local-
policy mutation lives outside `applyActionToRegistry`).

See `LegalKernel/Laws/Lex/Transfer.lean`'s docstring for the
"Why a separate file?" explanation.
-/

import LegalKernel.Laws.Freeze
import LegalKernel.Authority.LocalPolicy
import LegalKernel.DSL.LexLaw

namespace LegalKernel
namespace Laws

open LegalKernel.Authority

/-! ## `declareLocalPolicy` (frozen action index 15) -/

set_option linter.missingDocs false in
lexlaw legalkernel_declareLocalPolicy where
  lex_id              legalkernel.declareLocalPolicy
  lex_version         "1.0.0"
  lex_action_index    15
  lex_intent          "Declare (or replace) the signer's local policy (Workstream LP §5.2).  Mutates the `ExtendedState.localPolicies` table to map the signer's `ActorId` to `_policy`.  Idempotent on equal `policy`; replaces on differing `policy`.  Kernel-level effect: `Laws.freezeResource 0`.  Authority-level effect: `localPolicies` insertion via `applyActionToLocalPolicies`."
  lex_signed_by       signer
  lex_authorized_by   (fun _ _ => True)
  lex_registry_effect localPolicy
  lex_params          (_policy : LegalKernel.Authority.LocalPolicy)
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  -- Per plan §19.4 LX.28: local-policy laws are kernel-level
  -- identity transitions; the `localPolicies` mutation lives in
  -- `applyActionToLocalPolicies` (LP.5 helper, separate from
  -- `applyActionToRegistry`).  All kernel-level properties hold
  -- trivially.  `registry_preserving` is claimed because the
  -- KEY REGISTRY is preserved (the local-policy mutation lives
  -- in the SEPARATE `localPolicies` table); this is consistent
  -- with the `lex_registry_effect localPolicy` annotation
  -- routing the codegen to `applyActionToLocalPolicies` rather
  -- than `applyActionToRegistry`.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- LX.28 byte-equivalence regression for `declareLocalPolicy`. -/
example (policy : LocalPolicy) :
    legalkernel_declareLocalPolicy_transition policy =
    Laws.freezeResource 0 := rfl

/-! ## `revokeLocalPolicy` (frozen action index 16) -/

set_option linter.missingDocs false in
lexlaw legalkernel_revokeLocalPolicy where
  lex_id              legalkernel.revokeLocalPolicy
  lex_version         "1.0.0"
  lex_action_index    16
  lex_intent          "Revoke the signer's local policy (Workstream LP §5.3).  Mutates the `ExtendedState.localPolicies` table to erase the signer's `ActorId` entry.  Idempotent: revoking a non-existent entry is a no-op.  Kernel-level effect: `Laws.freezeResource 0`.  No fields: which actor is being revoked is the signer."
  lex_signed_by       signer
  lex_authorized_by   (fun _ _ => True)
  lex_registry_effect localPolicy
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  -- Per plan §19.4 LX.28: local-policy laws are kernel-level
  -- identity transitions; the `localPolicies` mutation lives in
  -- `applyActionToLocalPolicies` (LP.5 helper, separate from
  -- `applyActionToRegistry`).  All kernel-level properties hold
  -- trivially.  `registry_preserving` is claimed because the
  -- KEY REGISTRY is preserved (the local-policy mutation lives
  -- in the SEPARATE `localPolicies` table); this is consistent
  -- with the `lex_registry_effect localPolicy` annotation
  -- routing the codegen to `applyActionToLocalPolicies` rather
  -- than `applyActionToRegistry`.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- LX.28 byte-equivalence regression for `revokeLocalPolicy`. -/
example :
    legalkernel_revokeLocalPolicy_transition =
    Laws.freezeResource 0 := rfl

end Laws
end LegalKernel
