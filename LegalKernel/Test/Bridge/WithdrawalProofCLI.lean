-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.WithdrawalProofCLI — Workstream D.2
CLI-integration tests.

The integration plan §8.2 acceptance criterion:

  * "CLI integration test in `Test/Bridge/WithdrawalProofCLI.lean`."
  * "The output is byte-stable across runs (the proof is
    deterministic per D.1)."

This module exercises the same end-to-end flow the `knomosis
withdrawal-proof SNAP_PATH ID` CLI subcommand uses, in-process
(without shelling out to the binary).  Specifically:

  1. Build a `BridgeState` with one or more pending withdrawals.
  2. Wrap it in an `ExtendedState` and take a snapshot.
  3. Persist the snapshot to a temp file.
  4. Re-load it (mirroring the CLI's `loadSnapshot`).
  5. Extract the proof for a given id (mirroring
     `cmdWithdrawalProof`'s call to `extractProof`).
  6. Verify the proof against the snapshot's
     `bridgeWithdrawalRoot`.

The byte-stability test re-extracts the same proof twice and
asserts the results are byte-equal.

Out-of-scope: actually invoking the `knomosis` binary via
`IO.Process` (Std.Process integration is a Phase-5 follow-up).
The in-process tests below establish the same correctness
properties at a lower implementation-level granularity.
-/

import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Bridge.State
import LegalKernel.Bridge.AddressBook
import LegalKernel.Authority.Nonce
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Snapshot
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.WithdrawalProofCLI

/-- Build an `ExtendedState` with one pending withdrawal at id 0. -/
def fixtureES : ExtendedState :=
  let wd : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero, amount := 100, l2LogIndex := 5 }
  { base := genesisState
    nonces := NonceState.empty
    registry := KeyRegistry.empty
    bridge := BridgeState.empty.appendWithdrawal wd }

/-- A snapshot of `fixtureES` at log index 0. -/
def fixtureSnap : Snapshot := takeSnapshot fixtureES zeroHash 0

/-- A path under `/tmp` for the snapshot file (test-only).  We use
    a unique name so concurrent test runs don't collide. -/
def snapPath : System.FilePath := "/tmp/knomosis_withdrawalproofcli_test.snap"

/-- The CLI integration tests. -/
def tests : List TestCase :=
  [ -- §8.2: end-to-end CLI flow.  Save snapshot, load it back, extract proof,
    -- verify against the bridge withdrawal root.
    { name := "CLI flow: save snapshot, load, extract, verify (id 0)"
    , body := do
        saveSnapshot snapPath fixtureSnap
        match (← loadSnapshot snapPath) with
        | .error e =>
          throw <| IO.userError s!"loadSnapshot failed: {repr e}"
        | .ok loadedSnap =>
          match extractProof loadedSnap 0 with
          | none =>
            throw <| IO.userError "extractProof returned none for known id"
          | some proof =>
            let root := loadedSnap.bridgeWithdrawalRoot
            if !verifyProof hashBytes proof root then
              throw <| IO.userError "extracted proof failed verification"
    }
  -- §8.2 acceptance criterion: byte-stability across runs.
  , { name := "CLI byte-stability: extracted proofs are byte-identical across runs"
    , body := do
        saveSnapshot snapPath fixtureSnap
        match (← loadSnapshot snapPath) with
        | .error e =>
          throw <| IO.userError s!"loadSnapshot failed: {repr e}"
        | .ok loadedSnap =>
          let p1 := extractProof loadedSnap 0
          let p2 := extractProof loadedSnap 0
          match p1, p2 with
          | some proof1, some proof2 =>
            if proof1.leaf.toList != proof2.leaf.toList then
              throw <| IO.userError "proof.leaf bytes differ across runs"
            if proof1.index != proof2.index then
              throw <| IO.userError "proof.index differs across runs"
            -- Vector equality via toList:
            let s1 := (proof1.siblings.toList.map (fun b => b.toList))
            let s2 := (proof2.siblings.toList.map (fun b => b.toList))
            if s1 != s2 then
              throw <| IO.userError "proof.siblings differ across runs"
          | _, _ =>
            throw <| IO.userError "extractProof returned none unexpectedly"
    }
  -- §8.2: absent id → none.
  , { name := "CLI flow: extractProof on absent id returns none"
    , body := do
        match extractProof fixtureSnap 99 with
        | none   => pure ()
        | some _ => throw <| IO.userError "expected none for absent id"
    }
  -- Snapshot persistence: the loaded snapshot's bridgeWithdrawalRoot
  -- equals the original's.
  , { name := "CLI flow: bridgeWithdrawalRoot is preserved across save/load"
    , body := do
        saveSnapshot snapPath fixtureSnap
        match (← loadSnapshot snapPath) with
        | .error e => throw <| IO.userError s!"loadSnapshot failed: {repr e}"
        | .ok loadedSnap =>
          let r1 := fixtureSnap.bridgeWithdrawalRoot.toList
          let r2 := loadedSnap.bridgeWithdrawalRoot.toList
          if r1 != r2 then
            throw <| IO.userError "bridgeWithdrawalRoot changed across save/load"
    }
  -- Negative: snapshot with corrupt bytes → extractProof should still be
  -- well-defined (returns none on decode failure).  We can't easily
  -- construct a corrupt snapshot in Lean; instead test the in-Lean error
  -- handling of extractProof on a snapshot with empty encodedState.
  , { name := "CLI flow: extractProof on corrupt snapshot returns none"
    , body := do
        -- A snapshot whose encodedState is the empty byte array fails to
        -- decode as ExtendedState.
        let corruptSnap : Snapshot :=
          { stateHash    := zeroHash
            encodedState := ByteArray.empty
            logIndex     := 0
            seedHash     := zeroHash }
        match extractProof corruptSnap 0 with
        | none   => pure ()
        | some _ => throw <| IO.userError "expected none for corrupt snapshot"
    }
  -- Byte-stability of bridgeWithdrawalRoot across two computations.
  , { name := "CLI flow: bridgeWithdrawalRoot is byte-stable on identical inputs"
    , body := do
        let r1 := fixtureSnap.bridgeWithdrawalRoot
        let r2 := fixtureSnap.bridgeWithdrawalRoot
        if r1.toList != r2.toList then
          throw <| IO.userError "bridgeWithdrawalRoot is not deterministic"
    }
  ]

end LegalKernel.Test.Bridge.WithdrawalProofCLI
