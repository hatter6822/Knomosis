/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Authority.Nonce — per-actor nonce ledger and ExtendedState.

Phase 3 WU 3.5.  Defines the per-actor next-expected-nonce ledger
(`NonceState`), the runtime's `ExtendedState` (kernel state + nonce
ledger + key registry), and the supporting `expectsNonce` /
`advanceNonce` operations and lemmas.

Genesis Plan §8.5 specifies the nonce protocol verbatim; Phase 3
adapts the spec in two minor ways:

  1. **Nonce type.**  We use `LegalKernel.Authority.Nonce = Nat`
     (unbounded) rather than `UInt64`.  This makes overflow absence
     a theorem (`Nat`-arithmetic doesn't overflow); the canonical
     encoding in Phase 4 will marshal `Nat → UInt64` with an explicit
     bound check at the deployment boundary.
  2. **Registry placement.**  `ExtendedState` carries the
     `KeyRegistry` field in addition to the `(base, nonces)` pair the
     spec calls for.  This is a deliberate Phase-3 deviation that
     enables the WU 3.10 `replaceKey` action to mutate the registry
     through the same `apply_admissible` path the rest of the
     authority machinery uses.  The Genesis Plan's §8.2 had the
     registry inside `AuthorityPolicy`; Phase 3 moves it to
     `ExtendedState` (and trims `AuthorityPolicy` to the static
     authorisation predicate).  See `Authority/Identity.lean` for the
     `KeyRegistry` definition and `Authority/SignedAction.lean` for
     the use sites.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong admissibility decisions or stale nonce reads,
but the kernel's `apply_admissible` would still refuse any action
whose admissibility check fails — the worst case is a denial-of-
service or a permitted action that should have been rejected (e.g.
a re-applied action in a runtime that incorrectly skipped
`advanceNonce`).  The §8.5 `replay_impossible` headline theorem
(proved in `Authority/SignedAction.lean`) closes the loop: as long
as `advanceNonce` was called after the last successful application,
no replay is possible.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Identity

open Std

namespace LegalKernel
namespace Authority

/-! ## NonceState (§8.5) -/

/-- Per-actor next-expected-nonce ledger.  Missing entries default
    to `0` — a freshly-registered actor starts at nonce 0.  The
    ledger is monotonic per actor (`expectsNonce_strict_mono`):
    every successful `advanceNonce` call strictly increases the
    actor's expected nonce. -/
structure NonceState where
  /-- The underlying map from actor → next-expected nonce. -/
  next : TreeMap ActorId Nonce compare
  deriving Repr

/-- The empty nonce state: every actor's next-expected nonce is `0`. -/
def NonceState.empty : NonceState := { next := ∅ }

/-! ## ExtendedState

`ExtendedState` is the runtime's view of "everything the kernel
needs to authorise and apply a signed action".  It bundles:

  * `base`     — the kernel-level `State` (per-resource balances).
  * `nonces`   — the per-actor next-expected-nonce ledger.
  * `registry` — the key registry mapping actor IDs to public keys.

The Genesis Plan §8.5 sketch had only `(base, nonces)`; Phase 3
adds the `registry` field so the `replaceKey` action of WU 3.10 can
mutate it.  See the module docstring for the rationale. -/

/-- The runtime's extended state: kernel `State` plus per-actor nonce
    ledger plus key registry.  Owned by the runtime layer (Phase 5);
    the kernel module proper still operates on the bare `State`.

    The `registry` field is what `Admissible` consults for condition
    1 (signer is registered) and for looking up the public key the
    signature is verified against (condition 3).  The runtime layer
    persists `ExtendedState` across calls to `apply_admissible`. -/
structure ExtendedState where
  /-- The kernel-level state (per-resource balance maps). -/
  base     : State
  /-- The per-actor next-expected-nonce ledger. -/
  nonces   : NonceState
  /-- The key registry mapping registered actors to their current
      public keys.  Mutable by `replaceKey` actions through
      `apply_admissible`. -/
  registry : KeyRegistry
  deriving Repr

/-- The genesis extended state: empty `base`, empty nonce ledger,
    empty key registry.  Deployments typically build a non-trivial
    initial `ExtendedState` (e.g. with founding actors registered)
    by chaining `register` / `setBalance` calls on top of this. -/
def ExtendedState.empty : ExtendedState where
  base     := genesisState
  nonces   := NonceState.empty
  registry := KeyRegistry.empty

/-! ## expectsNonce / advanceNonce (§8.5) -/

/-- The next-expected nonce for actor `a`.  Returns `0` if `a` has
    never had a nonce recorded (i.e. either is unregistered or has
    not yet issued any signed action). -/
def expectsNonce (es : ExtendedState) (a : ActorId) : Nonce :=
  (es.nonces.next[a]?.getD 0)

/-- Advance the next-expected nonce for actor `a` by 1.  Called by
    `apply_admissible` after a successful state advance. -/
def advanceNonce (es : ExtendedState) (a : ActorId) : ExtendedState :=
  { es with nonces :=
    { next := es.nonces.next.insert a (expectsNonce es a + 1) } }

/-! ## Properties (Stated and Proved) -/

/-- §8.5: the next expected nonce is strictly increasing per actor.
    After one `advanceNonce`, the actor's next-expected-nonce is
    exactly one greater than before.

    Proof: `advanceNonce` writes `expectsNonce es a + 1` at key `a`
    in the underlying TreeMap; `expectsNonce` then reads it back via
    `TreeMap.getElem?_insert_self` (the §8.3 / WU 1.1 lemma). -/
theorem expectsNonce_strict_mono (es : ExtendedState) (a : ActorId) :
    expectsNonce (advanceNonce es a) a = expectsNonce es a + 1 := by
  show (es.nonces.next.insert a (expectsNonce es a + 1))[a]?.getD 0 =
       expectsNonce es a + 1
  rw [RBMap.find?_insert_self]
  rfl

/-- A different actor's expected nonce is unchanged by `advanceNonce a`.
    This is the cross-actor isolation property of the nonce ledger. -/
theorem expectsNonce_advance_other
    (es : ExtendedState) (a a' : ActorId) (h : a ≠ a') :
    expectsNonce (advanceNonce es a) a' = expectsNonce es a' := by
  show (es.nonces.next.insert a (expectsNonce es a + 1))[a']?.getD 0 =
       es.nonces.next[a']?.getD 0
  rw [RBMap.find?_insert_other _ a a' _ h]

/-- `advanceNonce` does not affect the kernel-level `base` state.
    Used by `apply_admissible` to factor out the kernel-state update
    from the nonce-ledger update. -/
theorem advanceNonce_base
    (es : ExtendedState) (a : ActorId) :
    (advanceNonce es a).base = es.base := rfl

/-- `advanceNonce` does not affect the key registry. -/
theorem advanceNonce_registry
    (es : ExtendedState) (a : ActorId) :
    (advanceNonce es a).registry = es.registry := rfl

/-! ## Replay-relevant nonce identities -/

/-- After `advanceNonce a`, the next expected nonce for `a` is
    strictly greater than any nonce seen before — in particular,
    strictly greater than the nonce used in the just-applied action.
    This is the algebraic core of `replay_impossible`. -/
theorem expectsNonce_after_advance_gt_old
    (es : ExtendedState) (a : ActorId) :
    expectsNonce (advanceNonce es a) a > expectsNonce es a := by
  have h := expectsNonce_strict_mono es a
  rw [h]
  exact Nat.lt_succ_self _

/-- After `advanceNonce a`, the next expected nonce for `a` is
    strictly greater than `n` for any `n ≤ expectsNonce es a` — in
    particular, for `n = expectsNonce es a` (the matched-nonce case
    in `Admissible`).  Convenience corollary. -/
theorem expectsNonce_after_advance_ne_old
    (es : ExtendedState) (a : ActorId) (n : Nonce)
    (hle : n ≤ expectsNonce es a) :
    expectsNonce (advanceNonce es a) a ≠ n := by
  have h := expectsNonce_strict_mono es a
  intro heq
  rw [h] at heq
  -- heq : expectsNonce es a + 1 = n; combined with hle : n ≤ expectsNonce es a:
  -- expectsNonce es a + 1 ≤ expectsNonce es a, contradiction.
  exact Nat.not_succ_le_self _ (heq.symm ▸ hle)

end Authority
end LegalKernel
