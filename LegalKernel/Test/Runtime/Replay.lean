/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.Replay — Phase-5 WU 5.5 tests for the
replay tool.

We exercise:

  * Empty-log replay returns the genesis state.
  * Determinism: equal inputs → equal results.
  * Chain-broken: an entry with a wrong `prevHash` triggers
    `chainBroken`.
  * NotAdmissible: an entry whose action fails admissibility (with
    the default Verify-returns-false stub) triggers `notAdmissible`.
  * `replayHash` returns just the final state hash.

**Verify-opaque caveat.**  The `Verify` function is `opaque` with
a placeholder body of `false`.  At test-time runtime, every
`Verify pk msg sig` returns `false`, so the signature-verification
clause of `Admissible` always fails.  This means we **cannot**
construct successful end-to-end replay traces in pure Lean tests
without supplying a real signature scheme.  The tests below cover
the rejection paths (chain-broken, not-admissible) and the
trivial-success path (empty log); the success-with-real-actions
path is covered by deployment integration tests (Phase 5 WU 5.4 +
WU 3.9 — Rust adaptors that wire a real Ed25519 implementation).
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.Replay

namespace LegalKernel.Test.Runtime
namespace ReplayTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding

/-- Test policy: unrestricted (every action authorised). -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- A genesis with one resource (id 1) and one actor (id 1) holding 100. -/
def genesis : ExtendedState :=
  { base    := setBalance ({ balances := ∅ }) 1 1 100
  , nonces  := { next := ∅ }
  , registry := KeyRegistry.empty }

/-- A signed action that's admissible under the *kernel* part of
    `Admissible` (auth + nonce + pre) but not under the signature
    part, because Verify returns false in the test runtime. -/
def transfer30 : SignedAction :=
  { action := .transfer 1 1 2 30
  , signer := 1
  , nonce  := 0
  , sig    := ⟨#[]⟩ }

/-- A synthetic LogEntry: not produced by a real `apply_admissible`,
    just a hand-built record we use to test replay's rejection
    paths (chain check, post-hash check). -/
def syntheticEntry : LogEntry :=
  { prevHash      := zeroHash
  , signedAction  := transfer30
  , postStateHash := hashStream [0xAA, 0xBB] }    -- arbitrary

/-- Empty-log replay returns genesis. -/
def replayEmpty : TestCase := {
  name := "replay [] returns genesis state"
  body := do
    match replay policy genesis [] with
    | .ok finalState =>
      assertEq (LegalKernel.getBalance genesis.base 1 1)
        (LegalKernel.getBalance finalState.base 1 1) "balance preserved"
    | .error e => throw <| IO.userError s!"unexpected error: {repr e}"
}

/-- Empty-log replay hash equals genesis hash. -/
def replayEmptyHash : TestCase := {
  name := "replayHash [] returns genesis hash"
  body := do
    let expected := hashEncodable genesis
    match replayHash policy genesis [] with
    | .ok h =>
      if h.toList == expected.toList then pure ()
      else throw <| IO.userError "hash mismatch"
    | .error e => throw <| IO.userError s!"unexpected error: {repr e}"
}

/-- Determinism: equal inputs produce equal results. -/
def replayDeterministic : TestCase := {
  name := "replay is deterministic"
  body := do
    let r1 := replay policy genesis []
    let r2 := replay policy genesis []
    match r1, r2 with
    | .ok s1, .ok s2 =>
      let h1 := hashEncodable s1
      let h2 := hashEncodable s2
      if h1.toList == h2.toList then pure ()
      else throw <| IO.userError "non-deterministic replay"
    | _, _ => throw <| IO.userError "unexpected error"
}

/-- Replay rejects an entry with a chain-broken `prevHash`.  This
    test runs even with the test-time Verify stub because chain
    integrity is checked *before* admissibility — the failure mode
    is `chainBroken`, not `notAdmissible`. -/
def chainBrokenRejected : TestCase := {
  name := "replay rejects entry with wrong prevHash"
  body := do
    -- Synthetic entry whose prevHash is bogus (not zeroHash and not
    -- any real predecessor hash).
    let entry : LogEntry :=
      { syntheticEntry with prevHash := hashStream [0xDE, 0xAD] }
    match replay policy genesis [entry] with
    | .ok _ =>
      throw <| IO.userError "BUG: replay accepted broken-chain entry"
    | .error (.chainBroken 0) => pure ()
    | .error other =>
      throw <| IO.userError s!"expected chainBroken, got {repr other}"
}

/-- Replay rejects an entry whose action fails admissibility (the
    Verify stub returns false in tests).  Chain check passes
    (synthetic entry's prevHash is zeroHash, matching the seed), so
    we reach the admissibility check and it fails. -/
def notAdmissibleRejected : TestCase := {
  name := "replay rejects inadmissible entry"
  body := do
    match replay policy genesis [syntheticEntry] with
    | .ok _ =>
      throw <| IO.userError "BUG: replay accepted entry whose action is inadmissible"
    | .error (.notAdmissible 0) => pure ()
    | .error other =>
      throw <| IO.userError s!"expected notAdmissible, got {repr other}"
}

/-- Replay from snapshot seed: an empty tail starting from a
    `(seedHash, state)` pair returns the seed state. -/
def replayFromSeedEmpty : TestCase := {
  name := "replayFromSeed [] returns seed state"
  body := do
    let seed := hashStream [0x42]
    match replayFromSeed policy seed genesis [] with
    | .ok finalState =>
      assertEq (LegalKernel.getBalance genesis.base 1 1)
        (LegalKernel.getBalance finalState.base 1 1) "balance preserved"
    | .error e => throw <| IO.userError s!"unexpected error: {repr e}"
}

/-- Replay from snapshot seed: a chain-broken tail (entry's
    prevHash != seedHash) is rejected. -/
def replayFromSeedChainBroken : TestCase := {
  name := "replayFromSeed rejects mismatched seed hash"
  body := do
    let seed := hashStream [0x42]
    -- syntheticEntry's prevHash is zeroHash, which differs from `seed`.
    match replayFromSeed policy seed genesis [syntheticEntry] with
    | .ok _ =>
      throw <| IO.userError "BUG: accepted chain-broken entry"
    | .error (.chainBroken 0) => pure ()
    | .error other =>
      throw <| IO.userError s!"expected chainBroken, got {repr other}"
}

/-- Multi-entry replay: two synthetic entries with linked hashes
    are first chain-checked then both rejected at admissibility.
    We verify the failure index is 0 (first entry fails first). -/
def multiEntryFailsAtFirst : TestCase := {
  name := "replay surfaces failure index correctly"
  body := do
    let h1 := LogEntry.hash syntheticEntry
    let entry2 : LogEntry :=
      { prevHash := h1
      , signedAction := { transfer30 with nonce := 1 }
      , postStateHash := hashStream [0xCC] }
    match replay policy genesis [syntheticEntry, entry2] with
    | .ok _ => throw <| IO.userError "BUG: accepted inadmissible chain"
    | .error (.notAdmissible 0) => pure ()  -- fails at idx 0
    | .error other =>
      throw <| IO.userError s!"expected notAdmissible at idx 0, got {repr other}"
}

/-- Term-level API: `replay_deterministic`. -/
def deterministicAPI : TestCase := {
  name := "replay_deterministic API stability"
  body := do
    let _proof : ∀ (P : AuthorityPolicy) (g₁ g₂ : ExtendedState)
                   (e₁ e₂ : List LogEntry),
                   g₁ = g₂ → e₁ = e₂ →
                   replay P g₁ e₁ = replay P g₂ e₂ :=
      replay_deterministic
    pure ()
}

/-- Term-level API: `replay_empty`. -/
def emptyAPI : TestCase := {
  name := "replay_empty API stability"
  body := do
    let _proof : ∀ (P : AuthorityPolicy) (g : ExtendedState),
                   replay P g [] = .ok g :=
      replay_empty
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [replayEmpty, replayEmptyHash, replayDeterministic,
   chainBrokenRejected, notAdmissibleRejected,
   replayFromSeedEmpty, replayFromSeedChainBroken, multiEntryFailsAtFirst,
   deterministicAPI, emptyAPI]

end ReplayTests
end LegalKernel.Test.Runtime
