/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Deployments.Examples.UsdClearing — the Workstream-LX (M3) worked
example deployment.

LX.37 of `docs/lex_implementation_plan.md`.

This file is the canonical M3 acceptance gate: a USD-clearing
deployment manifest mirroring the §7.2 example in
`docs/law_language_design.md`.

Demonstrates:

  * The `deployment` macro's full surface (LX.31 / LX.32 / LX.33).
  * Manifest-hash determinism (LX.32).
  * Cross-deployment-replay binding via `deployment_id` (LX.32).
  * Invariant-claim synthesis: the `MonotonicLawSet` synthesised
    from the deployment's law list (LX.33).

The deployment's law set is the four monotonic kernel-built-in
laws: `transfer`, `mint`, `freezeResource`, `replaceKey`.  The
deliberate exclusions are the laws that breach the monotonicity
firewall:

  * `legalkernel.burn` — deflationary; not `IsMonotonic`.
  * Other deflationary laws — same.

If a manifest writer attempts to add `Burn` to the
`monotonic_law_set` claim, elaboration fails with L008 (the
typeclass-resolution firewall enforced at deployment-time).

# v1 deviations

The macro takes parameterless law identifiers in the
`deploy_laws` clause; for parameterised kernel laws like
`Laws.transfer r sender receiver amount`, we introduce
*parameterless wrappers* that close the laws over fixture
parameter values.  This is a v1-deployment-author convention;
v2 may admit parameterised law identifiers directly.

The wrappers' `IsMonotonic` instances delegate to the underlying
parameterised instances, so the wrapper inherits the parent
law's classification automatically.
-/

import LegalKernel.DSL.LexDeployment
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Freeze

namespace Deployments.Examples.UsdClearing

open LegalKernel
open LegalKernel.DSL
open LegalKernel.Laws

/-! ## Parameterless wrapper laws

The kernel-built-in laws are parameterised over resource / actor
/ amount.  The `deployment` macro's `deploy_laws` clause takes
identifiers (not applied terms), so we wrap each parameterised
law in a parameterless `def` that closes it over fixture
arguments.  The wrapper's `IsMonotonic` instance delegates to the
underlying instance.

The fixture arguments are placeholder zero-values; for production
deployments, the runtime adaptor selects the appropriate
instantiation per processed action.  The deployment's
`monotonic_law_set` claim is a *declarative* assertion ("the
deployment admits laws that, regardless of parameter
instantiation, are all monotonic"); the value-level law set is
constructed on demand at the runtime adaptor's call site. -/

/-- Parameterless wrapper for `Laws.transfer` at fixture
    parameters `(0, 0, 0, 0)`.  Inherits `IsMonotonic` via the
    underlying instance. -/
def transferWrapper : Transition := Laws.transfer 0 0 0 0

/-- The wrapper inherits `IsMonotonic` from
    `transfer_isMonotonic`. -/
instance transferWrapper_isMonotonic : IsMonotonic transferWrapper :=
  transfer_isMonotonic 0 0 0 0

/-- Parameterless wrapper for `Laws.mint`. -/
def mintWrapper : Transition := Laws.mint 0 0 0

/-- The wrapper inherits `IsMonotonic` from
    `mint_isMonotonic`. -/
instance mintWrapper_isMonotonic : IsMonotonic mintWrapper :=
  mint_isMonotonic 0 0 0

/-- Parameterless wrapper for `Laws.freezeResource`. -/
def freezeWrapper : Transition := Laws.freezeResource 0

/-- The wrapper inherits `IsMonotonic` from
    `freezeResource_isMonotonic`. -/
instance freezeWrapper_isMonotonic : IsMonotonic freezeWrapper :=
  freezeResource_isMonotonic 0

/-- Parameterless wrapper for `replaceKey`'s kernel-level
    transition.  Per the kernel design, `replaceKey` compiles to
    `Laws.freezeResource 0` at the kernel level (the registry
    mutation lives in the authority layer); so the wrapper is
    just `freezeResource 0`.  Inherits `IsMonotonic`. -/
def replaceKeyWrapper : Transition := Laws.freezeResource 0

/-- The wrapper inherits `IsMonotonic` from
    `freezeResource_isMonotonic`. -/
instance replaceKeyWrapper_isMonotonic : IsMonotonic replaceKeyWrapper :=
  freezeResource_isMonotonic 0

/-! ## The USD-clearing deployment manifest

Mirrors `docs/law_language_design.md` §7.2 verbatim, with the
v1 macro deviations:

  * Clauses prefixed with `deploy_`.
  * `deploy_deployment_id` is a hex string (the macro decodes).
  * `deploy_laws` references the parameterless wrappers above.
  * `deploy_authority` is captured as opaque text.

The `deploy_invariant_claims` clause exercises the LX.33
synthesizer's `monotonic_law_set` shape. -/

deployment usd_clearing where
  deploy_id              example.usd_clearing
  -- 32-byte deployment ID (64 hex chars).  Mirrors the design
  -- doc's `0xDEADBEEF...01234567` exactly.
  deploy_deployment_id
    "DEADBEEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 0 ]
  deploy_laws            := [
    transferWrapper,
    mintWrapper,
    freezeWrapper,
    replaceKeyWrapper
  ]
  deploy_authority       := (fun _ _ => True)
  deploy_invariant_claims := [
    monotonic_law_set [transferWrapper, mintWrapper,
                       freezeWrapper, replaceKeyWrapper]
  ]

end Deployments.Examples.UsdClearing
