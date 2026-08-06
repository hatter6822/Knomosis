-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.ActionsRootBatch — Workstream SB.

Generates the TWO batching corpora:

  * `actions_root.json` — the batch actions-root tree: per batch, the
    root Lean computes over its `(actionKey n, actionLeafValue)`
    entries, and per entry the key, the signature-bound leaf commit
    (`expectedActionLeafHex`), and the bitmask-compressed inclusion
    proof.  The Solidity consumer (`ActionsRootBatch.t.sol`)
    re-derives every key and leaf from the published raw fields and
    walks every proof through `ActionsRoot.verifyActionInclusion` —
    plus the NEGATIVE rows, which must refuse: a forged commit under
    an honest proof, and an honest commit at the wrong index.

  * `batch_chain.json` — the batch submission chain: the genesis seed
    (`l1NextEntryHash zeroHash gsc zeroHash`) and a run of batches
    each folding `(stateCommit, actionsRoot)`, with the running
    `expectedNextEntryHashHex` published per step.  This finally pins
    `l1NextEntryHash` cross-stack (decision R8): the chain hash had
    Lean and Solidity spellings but no corpus row comparing them.

Both corpora are hash-DEPENDENT (`hashBytes` is in every key, leaf,
root, and chain link), so they are authored via
`writeHashDependentFixture` and the Solidity consumers gate on
`isKeccak256Linked` — the fallback hash would pin bytes no L1 can
reproduce.

The batch entries deliberately span the Workstream SB surface: a
seeded `depositWithFee` (kind 19, 136-byte fields) and a
`reserveSwap` (kind 25) ride the tree next to the legacy variants, so
the leaf pre-image split is pinned on variable field widths.
-/

import LegalKernel.FaultProof.ActionsRoot
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test
open LegalKernel.Test.Bridge.CrossCheck

namespace LegalKernel.Test.Bridge.CrossCheck.ActionsRootBatch

/-- The actions-root fixture this suite owns. -/
def fixtureName : String := "actions_root.json"

/-- The batch-chain fixture this suite owns. -/
def chainFixtureName : String := "batch_chain.json"

/-- A deterministic 65-byte signature: `seed` repeated.  The width is
    load-bearing (the leaf pre-image's fixed suffix; the Solidity
    delegate REVERTS on any other length), the content is not — the
    leaf HASHES the signature, it does not verify it. -/
def sig65 (seed : UInt8) : ByteArray :=
  ByteArray.mk (Array.replicate 65 seed)

/-- Wrap an action as the log entry the batch slice carries.  The
    chain hashes are irrelevant to the leaf (only the signed action is
    committed), so they are empty. -/
def entryOf (a : Action) (signer : ActorId) (nonce : Nonce)
    (seed : UInt8) : Runtime.LogEntry :=
  { prevHash := ByteArray.empty
  , signedAction := { action := a, signer, nonce, sig := sig65 seed }
  , postStateHash := ByteArray.empty }

/-- One batch probe: its first absolute log index and its entries. -/
structure Batch where
  /-- The probe's name, for failure messages on both stacks. -/
  name  : String
  /-- The batch's first absolute log index (`prevEndIndex` in
      submission terms). -/
  first : Nat
  /-- The batch slice, in log order. -/
  entries : List Runtime.LogEntry

/-- The batches.  Sizes 1 / 3 / 5, starts at zero and deep into the
    log, and every Workstream SB variant on the tree. -/
def batches : List Batch :=
  [ { name := "singleton", first := 0
    , entries := [entryOf (.transfer 1 7 8 30) 7 0 0x11] }
  , { name := "genesisTriple", first := 0
    , entries :=
        [ entryOf (.transfer 1 7 8 30) 7 0 0x21
        , entryOf (.mint 1 9 500) 2 1 0x22
          -- The seeded three-leg split (kind 19, 136-byte fields).
        , entryOf (.depositWithFee 1 10 99 700 300 5 42 120) 0 2 0x23 ] }
  , { name := "deepFive", first := 1000
    , entries :=
        [ entryOf (.deposit 1 8 5 3) 0 3 0x31
        , entryOf (.withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero) 7 1 0x32
          -- The user-facing swap (kind 25, 96-byte fields).
        , entryOf (.reserveSwap 0 1 12 1000 900 3) 12 0 0x33
          -- A full-seed split: the whole fee reaches the reserve.
        , entryOf (.depositWithFee 0 11 99 900 100 7 43 100) 0 4 0x34
          -- The empty-fields variant, so a zero-width `fields` slice
          -- rides the pre-image split too.
        , entryOf .revokeLocalPolicy 9 2 0x35 ] }
  ]

/-- One entry's JSON row: the raw fields the consumer re-derives
    from, the derived key and leaf, and the inclusion proof. -/
def entryJson (b : Batch) (i : Nat) (e : Runtime.LogEntry) : Json :=
  let st := e.signedAction
  let n := b.first + i
  Json.obj
    [ ("absoluteIndex",  Json.num n)
    , ("actionKindByte", Json.num (StepVMCoherence.actionKindByte st.action).toNat)
    , ("signerNat",      Json.num st.signer.toNat)
    , ("actionFieldsHex",
        Json.str (hexFromBytes (StepVMCoherence.actionFieldsForL1 st.action)))
    , ("sigHex",         Json.str (hexFromBytes st.sig))
    , ("actionKeyHex",   Json.str (hexFromBytes (FaultProof.actionKey n)))
    , ("expectedActionLeafHex",
        Json.str (hexFromBytes (FaultProof.actionLeafValue st)))
    , ("proofDataHex",
        Json.str (hexFromBytes
          (SmtCellProof.toWireBytes (FaultProof.buildActionProof b.first b.entries n))))
    ]

/-- One batch's JSON. -/
def batchJson (b : Batch) : Json :=
  Json.obj
    [ ("name",           Json.str b.name)
    , ("firstIndex",     Json.num b.first)
    , ("count",          Json.num b.entries.length)
    , ("actionsRootHex",
        Json.str (hexFromBytes (FaultProof.actionsRoot b.first b.entries)))
    , ("entries",
        Json.arr ((b.entries.zipIdx.map (fun (e, i) => entryJson b i e))))
    ]

/-- The negative rows are authored against the LAST batch (the widest
    tree).  Row 1 forges the commit under the honest proof; row 2
    replays an honest `(commit, proof)` at the wrong index, so only
    the derived KEY differs.  Both must refuse on both stacks. -/
def negativeBatch : Batch :=
  batches.getLastD { name := "", first := 0, entries := [] }

/-- A 32-byte commit with one bit flipped, for the forged row. -/
def flipFirstByte (b : ByteArray) : ByteArray :=
  ByteArray.mk (b.toList.toArray.modify 0 (fun x => x ^^^ 0x01))

/-- The negative-rows JSON. -/
def negativesJson : Json :=
  let b := negativeBatch
  let n := b.first  -- the batch's first entry
  let honestEntry := b.entries.headD (entryOf .revokeLocalPolicy 0 0 0)
  let honestCommit := FaultProof.actionLeafValue honestEntry.signedAction
  let honestProof :=
    SmtCellProof.toWireBytes (FaultProof.buildActionProof b.first b.entries n)
  Json.arr
    [ Json.obj
        [ ("category", Json.str "forged-commit")
        , ("actionsRootHex",
            Json.str (hexFromBytes (FaultProof.actionsRoot b.first b.entries)))
        , ("absoluteIndex", Json.num n)
        , ("commitHex", Json.str (hexFromBytes (flipFirstByte honestCommit)))
        , ("proofDataHex", Json.str (hexFromBytes honestProof))
        ]
    , Json.obj
        [ ("category", Json.str "wrong-index")
        , ("actionsRootHex",
            Json.str (hexFromBytes (FaultProof.actionsRoot b.first b.entries)))
          -- One PAST the batch's last entry: the key derivation alone
          -- must sink it.
        , ("absoluteIndex", Json.num (b.first + b.entries.length))
        , ("commitHex", Json.str (hexFromBytes honestCommit))
        , ("proofDataHex", Json.str (hexFromBytes honestProof))
        ]
    ]

/-- The `actions_root.json` fixture. -/
def buildFixture : Json :=
  Json.obj
    [ ("identifier", Json.str "knomosis/actions-root/v1")
    , ("isKeccak256Linked", Json.bool LegalKernel.Bridge.isKeccak256Linked)
    , ("count", Json.num batches.length)
    , ("batches", Json.arr (batches.map batchJson))
    , ("negatives", negativesJson)
    ]

/-! ## The batch chain -/

/-- The chain run's genesis state commit: an arbitrary but REAL
    commitment (the empty extended state's), so the corpus seed is a
    value an actual deployment could carry. -/
def genesisStateCommit : ByteArray :=
  commitExtendedState ExtendedState.empty

/-- The chain steps: each batch contributes its actions root, and the
    state commits are three distinct real roots (the empty state and
    two one-write descendants). -/
def chainBatches : List (ByteArray × ByteArray) :=
  let s1 := commitExtendedState
    { ExtendedState.empty with
        base := LegalKernel.setBalance ExtendedState.empty.base 1 7 100 }
  let s2 := commitExtendedState
    { ExtendedState.empty with
        base := LegalKernel.setBalance ExtendedState.empty.base 1 8 40 }
  (batches.zip [s1, s2, s1]).map (fun (b, sc) =>
    (sc, FaultProof.actionsRoot b.first b.entries))

/-- The running chain values, one per step. -/
def chainSteps : List (ByteArray × ByteArray × ByteArray) :=
  let seed := FaultProof.genesisChainSeed genesisStateCommit
  (List.range chainBatches.length).map (fun i =>
    let (sc, ar) := chainBatches[i]!
    (sc, ar, FaultProof.batchChainFold seed (chainBatches.take (i + 1))))

/-- The `batch_chain.json` fixture. -/
def buildChainFixture : Json :=
  Json.obj
    [ ("identifier", Json.str "knomosis/batch-chain/v1")
    , ("isKeccak256Linked", Json.bool LegalKernel.Bridge.isKeccak256Linked)
    , ("genesisStateCommitHex", Json.str (hexFromBytes genesisStateCommit))
    , ("genesisSeedHex",
        Json.str (hexFromBytes (FaultProof.genesisChainSeed genesisStateCommit)))
    , ("count", Json.num chainSteps.length)
    , ("steps", Json.arr (chainSteps.map (fun (sc, ar, next) =>
        Json.obj
          [ ("stateCommitHex", Json.str (hexFromBytes sc))
          , ("actionsRootHex", Json.str (hexFromBytes ar))
          , ("expectedNextEntryHashHex", Json.str (hexFromBytes next))
          ])))
    ]

/-! ## Tests -/

/-- The test cases: the Lean side of both pins, the negative rows'
    refusals, and the fixture writes. -/
def tests : List TestCase :=
  [ { name := "SB: every batch entry's proof verifies against its root"
    , body := do
        for b in batches do
          let root := FaultProof.actionsRoot b.first b.entries
          for (e, i) in b.entries.zipIdx do
            let n := b.first + i
            let commit := FaultProof.actionLeafValue e.signedAction
            let proof := FaultProof.buildActionProof b.first b.entries n
            assert (FaultProof.verifyActionProof root n commit proof)
              s!"{b.name}[{i}]: honest proof must verify"
    }
  , { name := "SB: a forged commit refuses under the honest proof"
    , body := do
        let b := negativeBatch
        let root := FaultProof.actionsRoot b.first b.entries
        let honest := FaultProof.actionLeafValue
          (b.entries.headD (entryOf .revokeLocalPolicy 0 0 0)).signedAction
        let proof := FaultProof.buildActionProof b.first b.entries b.first
        assert (!FaultProof.verifyActionProof root b.first
                  (flipFirstByte honest) proof)
          "forged commit must refuse"
    }
  , { name := "SB: an honest commit refuses at the wrong index"
    , body := do
        let b := negativeBatch
        let root := FaultProof.actionsRoot b.first b.entries
        let honest := FaultProof.actionLeafValue
          (b.entries.headD (entryOf .revokeLocalPolicy 0 0 0)).signedAction
        let proof := FaultProof.buildActionProof b.first b.entries b.first
        assert (!FaultProof.verifyActionProof root
                  (b.first + b.entries.length) honest proof)
          "wrong-index replay must refuse"
    }
  , { name := "SB: the chain fold recomputes step-by-step"
    , body := do
        -- The published running hash IS the single-step recurrence:
        -- next_i = l1NextEntryHash next_{i-1} sc_i ar_i.
        let seed := FaultProof.genesisChainSeed genesisStateCommit
        let mut acc := seed
        for (sc, ar, published) in chainSteps do
          acc := StepVMCoherence.l1NextEntryHash acc sc ar
          assertEq (expected := acc.toList) (actual := published.toList)
            "published chain value = the recurrence's"
    }
  , { name := "SB: every published word is 32 bytes"
    , body := do
        for b in batches do
          assertEq (expected := 32)
            (actual := (FaultProof.actionsRoot b.first b.entries).size)
            s!"{b.name}: root width"
          for (e, i) in b.entries.zipIdx do
            assertEq (expected := 32)
              (actual := (FaultProof.actionKey (b.first + i)).size)
              s!"{b.name}[{i}]: key width"
            assertEq (expected := 32)
              (actual := (FaultProof.actionLeafValue e.signedAction).size)
              s!"{b.name}[{i}]: leaf width"
            assertEq (expected := 65) (actual := e.signedAction.sig.size)
              s!"{b.name}[{i}]: the fixed signature suffix"
    }
  , { name := "SB: write actions_root.json fixture file"
    , body :=
        Test.Bridge.CrossCheck.writeHashDependentFixture fixtureName
          buildFixture.encodeIndented
    }
  , { name := "SB: write batch_chain.json fixture file"
    , body :=
        Test.Bridge.CrossCheck.writeHashDependentFixture chainFixtureName
          buildChainFixture.encodeIndented
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.ActionsRootBatch
