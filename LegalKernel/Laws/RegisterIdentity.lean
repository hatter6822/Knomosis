/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.RegisterIdentity — Lex re-expression of the
authority-layer first-time identity registration `registerIdentity`
action.

LX-M2 milestone WU LX.25.  Produces a `def
legalkernel_registerIdentity_transition` whose kernel-level body
is the identity `Transition`.  First-time-registration analogue
of `replaceKey`: signed by the bridge actor (rather than the old
key, which doesn't exist for first-time registrations).  The
authority-level effect (KeyRegistry insertion) lives in
`applyActionToRegistry`.

The bridge-actor signing constraint is enforced by the deployment's
`bridgePolicy` (see `LegalKernel/Bridge/BridgeActor.lean`); the
Lex declaration captures the *kernel-level* shape, not the bridge
authorisation policy.
-/

import LegalKernel.Laws.Freeze
import LegalKernel.Authority.Crypto
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

open LegalKernel.Authority

/-! ## LX-M2 (LX.25) Lex declaration for `registerIdentity` -/

set_option linter.missingDocs false in
lexlaw legalkernel_registerIdentity where
  lex_id              legalkernel.registerIdentity
  lex_version         "1.0.0"
  lex_action_index    12
  lex_intent          "Insert a fresh `(actor, pk)` pair into the `KeyRegistry`, signed by the bridge actor.  Used for first-time identity registrations where `replaceKey` cannot apply (the old key doesn't exist yet).  Kernel-level effect is identity on `State`; the authority-level effect (registry insertion) happens in `apply_admissible` via `applyActionToRegistry`."
  lex_signed_by       bridge
  lex_authorized_by   (fun _ _ => True)
  lex_registry_effect registerIdentity
  lex_params          (_actor : ActorId) (_pk : Authority.PublicKey)
  lex_pre             := fun (_ : State) => True
  lex_impl            := fun (s : State) => s
  -- Per plan §19.4 LX.25: same as `replaceKey` — claims all
  -- kernel-level properties EXCEPT `registry_preserving` (the
  -- registry is mutated by the authority layer).
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances]
  lex_events          := []

/-- LX-M2 LX.25 byte-equivalence regression for `registerIdentity`. -/
example (actor : ActorId) (pk : Authority.PublicKey) :
    legalkernel_registerIdentity_transition actor pk =
    Laws.freezeResource 0 := rfl

end Laws
end LegalKernel
