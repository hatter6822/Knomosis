-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.ReplaceKey — Lex re-expression of the authority-
layer key-rotation `replaceKey` action.

LX-M2 milestone WU LX.25.  Produces a `def
legalkernel_replaceKey_transition` whose kernel-level body is the
identity `Transition` (`Laws.freezeResource 0` per the Phase-3
design where authority-level effects live in
`applyActionToRegistry`, not in the compiled `Transition`).

This law has no hand-written `Laws.replaceKey` def — the
`Action.compileTransition (.replaceKey ...)` arm returns
`Laws.freezeResource 0` directly.  The Lex re-expression here is
the canonical M2 declaration for the `replaceKey` action; the
JSON sidecar at `Lex/Inputs/legalkernel_replaceKey.json`
records the metadata for the codegen pipeline.

The plan §19.4 LX.25 acceptance:
> Both laws use the `register_key` impl primitive (which routes
> to the authority-layer `applyActionToRegistry`, not to
> `apply_impl`).
> `RegistryPreserving` is **not** claimed in `satisfies` for
> either law (correctly so; both mutate the registry).

The M2 declaration sets `lex_registry_effect replaceKey` to
record the authority-layer effect, and omits `registry_preserving`
from `lex_satisfies` (vacuously true in M2 — `lex_satisfies` is
empty pending M3 synthesizer integration).

The byte-equivalence regression `example` confirms that the
emitted `legalkernel_replaceKey_transition` is definitionally
equal to `Laws.freezeResource 0` — the value that
`Action.compileTransition (.replaceKey ...)` returns.
-/

import LegalKernel.Laws.Freeze
import LegalKernel.Authority.Crypto
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

open LegalKernel.Authority

/-! ## LX-M2 (LX.25) Lex declaration for `replaceKey` -/

set_option linter.missingDocs false in
lexlaw legalkernel_replaceKey where
  lex_id              legalkernel.replaceKey
  lex_version         "1.0.0"
  lex_action_index    4
  lex_intent          "Re-point `actor`'s identity to `newKey` in the `KeyRegistry`, signed by the *old* key.  Kernel-level effect is identity on `State`; the authority-level effect (registry update) happens in `apply_admissible` via `applyActionToRegistry` (Phase 3 / WU 3.10)."
  lex_signed_by       actor
  lex_authorized_by   (fun _ _ => True)
  lex_registry_effect replaceKey
  -- Underscore prefix on `_actor` and `_newKey`: the kernel-level
  -- `Transition` is the identity (per the Phase-3 design where
  -- registry mutation lives in `applyActionToRegistry`, not in
  -- the compiled `Transition`).  The params are part of the
  -- action-layer API but deliberately unused at the kernel level.
  lex_params          (_actor : ActorId) (_newKey : Authority.PublicKey)
  lex_pre             := fun (_ : State) => True
  lex_impl            := fun (s : State) => s
  -- Per plan §19.4 LX.25: `replaceKey` claims all kernel-level
  -- properties (it's an identity transition at the kernel level)
  -- EXCEPT `registry_preserving` — it explicitly mutates the
  -- registry via `applyActionToRegistry` in `apply_admissible`.
  -- The plan note: "RegistryPreserving is **not** claimed in
  -- satisfies for either law (correctly so; both mutate the
  -- registry)."  Conservative / monotonic / local / freeze-
  -- preserving / nonce_advances all hold trivially for the
  -- kernel-level identity.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances]
  lex_events          := []

/-- LX-M2 LX.25 byte-equivalence regression for `replaceKey`. -/
example (actor : ActorId) (newKey : Authority.PublicKey) :
    legalkernel_replaceKey_transition actor newKey =
    Laws.freezeResource 0 := rfl

end Laws
end LegalKernel
