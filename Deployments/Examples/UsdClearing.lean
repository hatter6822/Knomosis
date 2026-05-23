/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Deployments.Examples.UsdClearing — the Workstream-LX (M3) worked
example deployment.

LX.37 of `docs/planning/lex_implementation_plan.md`.

This file is the canonical M3 acceptance gate: a USD-clearing
deployment manifest mirroring the §7.2 example in
`docs/law_language_design.md`.

Demonstrates:

  * The `deployment` macro's full surface (LX.31 / LX.32 / LX.33).
  * Manifest-hash determinism (LX.32).
  * Cross-deployment-replay binding via `deployment_id` (LX.32).
  * Real `AuthorityPolicy` elaboration: the user's authority
    block is folded via `AuthorityPolicy.intersect` (LX.32 fix).
  * Spec-faithful `@`-version-pin syntax in `deploy_laws`
    (LX.37 fix).
  * Invariant-claim synthesis: the `MonotonicLawSet` synthesised
    from the deployment's law list (LX.33).
  * Wildcard `[all_laws]` expansion (LX.33 fix) — see the
    `monotonic_law_set [all_laws]` claim, which expands at
    elaboration time to the full `deploy_laws` localName list.
    Audit-5: previously misdescribed as `freeze_preserving_law_set
    [all_laws]`, but transfer + mint mutate USD balances so they
    are not `FreezePreserving [USD]` — the L008 firewall correctly
    rejects that claim.  `monotonic_law_set` exercises the
    typeclass-driven cons chain over every law in the deployment
    while staying within the firewall.

The deployment's law set is the four monotonic kernel-built-in
laws: `transfer`, `mint`, `freezeResource`, `replaceKey`.  The
deliberate exclusions are the laws that breach the monotonicity
firewall:

  * `legalkernel.burn` — deflationary; not `IsMonotonic`.
  * Other deflationary laws — same.

If a manifest writer attempts to add `Burn` to the
`monotonic_law_set` claim, elaboration fails with L008 (the
typeclass-resolution firewall enforced at deployment-time).

# v1 conventions

The macro takes parameterless law identifiers in the `deploy_laws`
clause; for parameterised kernel laws like `Laws.transfer r
sender receiver amount`, we introduce *parameterless wrappers*
that close the laws over fixture parameter values.  The
wrappers' `IsMonotonic` instances delegate to the underlying
parameterised instances, so the wrapper inherits the parent
law's classification automatically.
-/

import Lex.DSL.Deployment
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Freeze

namespace Deployments.Examples.UsdClearing

open LegalKernel
open LegalKernel.Authority
open LegalKernel.DSL
open LegalKernel.Laws

/-! ## Parameterless wrapper laws -/

/-- Parameterless wrapper for `Laws.transfer` at fixture
    parameters `(0, 0, 0, 0)`. -/
def transferWrapper : Transition := Laws.transfer 0 0 0 0

instance transferWrapper_isMonotonic : IsMonotonic transferWrapper :=
  transfer_isMonotonic 0 0 0 0

/-- Parameterless wrapper for `Laws.mint`. -/
def mintWrapper : Transition := Laws.mint 0 0 0

instance mintWrapper_isMonotonic : IsMonotonic mintWrapper :=
  mint_isMonotonic 0 0 0

/-- Parameterless wrapper for `Laws.freezeResource`. -/
def freezeWrapper : Transition := Laws.freezeResource 0

instance freezeWrapper_isMonotonic : IsMonotonic freezeWrapper :=
  freezeResource_isMonotonic 0

/-- Parameterless wrapper for `replaceKey`'s kernel-level
    transition.  Per the kernel design, `replaceKey` compiles to
    `Laws.freezeResource 0` at the kernel level (the registry
    mutation lives in the authority layer); so the wrapper is
    just `freezeResource 0`. -/
def replaceKeyWrapper : Transition := Laws.freezeResource 0

instance replaceKeyWrapper_isMonotonic : IsMonotonic replaceKeyWrapper :=
  freezeResource_isMonotonic 0

/-! ## Per-slot authority policies (mirror §7.2) -/

/-- The federated transfer policy.  Currently set to
    `AuthorityPolicy.unrestricted` as a placeholder; in production
    this would be a keyed-policy union over federation members'
    public keys (the suffix names the *current* content — an
    unrestricted policy — not a versioning marker; AR.8 rename of
    the former `federation_transfer_policy_v2`, which used a
    forbidden temporal-marker token now blocked by
    `naming_audit`). -/
def federation_transfer_policy_unrestricted : AuthorityPolicy :=
  AuthorityPolicy.unrestricted

/-- The central-bank-only mint policy.  V1 placeholder. -/
def central_bank_only : AuthorityPolicy :=
  AuthorityPolicy.unrestricted

/-- The self-only-with-central-bank-recovery identity policy.
    V1 placeholder. -/
def self_only_with_central_bank_recovery : AuthorityPolicy :=
  AuthorityPolicy.unrestricted

/-! ## The USD-clearing deployment manifest

Spec-faithful translation of `docs/law_language_design.md` §7.2:

  * `deploy_laws` uses the `<localName> = <lawIdent> @ <version>`
    syntax (LX.37 fix).
  * `deploy_authority` uses the multi-binding form (LX.32 fix).
  * `deploy_invariant_claims` includes a wildcard
    `monotonic_law_set [all_laws]` to demonstrate LX.33's
    wildcard expansion (audit-5: switched from
    `freeze_preserving_law_set` because the latter is
    semantically false for transfer/mint at the deployment's
    USD resource).

The `deploy_invariant_claims` clause exercises the LX.33
synthesizer's `monotonic_law_set` shape via the typeclass-driven
`<LawSet>.cons` chain. -/

deployment usd_clearing where
  deploy_id              example.usd_clearing
  -- 32-byte deployment ID (64 hex chars).  Mirrors the design
  -- doc's `0xDEADBEEF...01234567` exactly.
  deploy_deployment_id
    "DEADBEEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 0 ]
  -- LX.37: spec-faithful @-version-pin syntax for laws.
  deploy_laws            := [
    Transfer    = transferWrapper    @ "1.0.0",
    Mint        = mintWrapper        @ "1.0.0",
    Freeze      = freezeWrapper      @ "1.0.0",
    ReplaceKey  = replaceKeyWrapper  @ "1.0.0"
  ]
  -- LX.32: spec-faithful multi-binding authority syntax.  Each
  -- binding is folded via `AuthorityPolicy.intersect` to produce
  -- the deployment's `_authority_policy`.
  deploy_authority       := [
    transfer_policy = federation_transfer_policy_unrestricted,
    mint_policy     = central_bank_only,
    identity_policy = self_only_with_central_bank_recovery
  ]
  deploy_invariant_claims := [
    -- Audit-5: spec-faithful `[all_laws]` wildcard demonstration
    -- (LX.33).  Expands at elaboration time to the full
    -- `deploy_laws` list `[Transfer, Mint, Freeze, ReplaceKey]`,
    -- exercising the `synth_monotonic_law_set` typeclass-driven
    -- cons chain over EVERY law in the deployment.  All four
    -- wrappers are `IsMonotonic`, so the wildcard claim
    -- elaborates without diagnostics.  The wildcard is
    -- semantically equivalent to writing `[Transfer, Mint,
    -- Freeze, ReplaceKey]` explicitly here.
    monotonic_law_set [all_laws]
    -- `conservative_law_set` and `freeze_preserving_law_set`
    -- are *not* claimed:
    --   * `Mint` is not `IsConservative` (it credits without
    --     debiting).
    --   * `Transfer`/`Mint` mutate balances at resource `0`
    --     (the `USD` resource), so they are not
    --     `FreezePreserving [0]`.
    -- Adding either claim here would fail elaboration with
    -- diagnostic L008 — the type-level firewall at
    -- deployment-time.
  ]

end Deployments.Examples.UsdClearing
