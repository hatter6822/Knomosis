-- SPDX-License-Identifier: GPL-3.0-or-later
-- Knomosis  - A Societal Kernel
-- Copyright (C) 2026  Adam Hall
-- This program comes with ABSOLUTELY NO WARRANTY.
-- This is free software, and you are welcome to redistribute it
-- under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

/-
# Tests — `FaultProof.ActionsRoot` (Workstream SB)

Value-level pins for the batch actions root plus the term-level API
stability of its headline theorems.

Two of these carry weight beyond regression:

  * **The compressed-wire round-trip.**  The completeness theorem
    (`actionProof_canonical_walks_to_root`) is stated over the
    UNCOMPRESSED canonical sibling path, exactly as the state-cell
    family states it; that the bitmask-compressed wire
    `buildActionProof` emits expands to that path is the
    representation half, pinned HERE across batch shapes (singleton,
    pair, middle-of-eight) — the same division of labour
    `buildSmtCellProof`'s docstring records for the cell tree.
  * **The negative controls.**  A wrong commit, a wrong index, and a
    truncated wire must all be refused; without these the round-trip
    cases could pass vacuously against a verifier that accepts
    everything.
-/

import LegalKernel.FaultProof.ActionsRoot
import LegalKernel.FaultProof.Game
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.ActionsRoot

/-- A batch entry whose action distinguishes itself by `amount`:
    a transfer of `amount` from actor 1 to actor 2 on resource 0,
    carrying a fixed-width 65-byte pseudo-signature filled with
    `sigByte` so leaf commits also separate on the signature. -/
private def entryWith (amount : Nat) (sigByte : UInt8) : LogEntry := {
  prevHash := ByteArray.empty,
  signedAction := {
    action := .transfer 0 1 2 amount,
    signer := 1,
    nonce := 0,
    sig := ByteArray.mk (Array.replicate 65 sigByte)
  },
  postStateHash := ByteArray.empty
}

/-- An eight-entry batch with pairwise-distinct actions. -/
private def batch8 : List LogEntry :=
  (List.range 8).map (fun i => entryWith (100 + i) (UInt8.ofNat i))

/-- Tests. -/
def tests : List TestCase :=
  [ -- ## Keys
    { name := "actionKey: 32 bytes, deterministic, index-separating"
    , body := do
        assertEq (expected := 32) (actual := (actionKey 0).size)
          "key size at 0"
        assertEq (expected := 32) (actual := (actionKey 77).size)
          "key size at 77"
        assertEq (expected := (actionKey 5).toList)
          (actual := (actionKey 5).toList) "determinism"
        assert (actionKey 5 != actionKey 6)
          "adjacent indices key differently"
        assert (actionKey 0 != actionKey (2 ^ 32))
          "distant indices key differently"
    }
  , -- ## Roots
    { name := "actionsRoot: 32 bytes; separates on entries and on position"
    , body := do
        let e₁ := [entryWith 100 0x11]
        let e₂ := [entryWith 101 0x11]
        assertEq (expected := 32) (actual := (actionsRoot 0 e₁).size)
          "root is 32 bytes"
        assert (actionsRoot 0 e₁ != actionsRoot 0 e₂)
          "a different action moves the root"
        assert (actionsRoot 0 e₁ != actionsRoot 1 e₁)
          "the same action at a different index moves the root"
        -- The signature is committed: two spellings differing ONLY
        -- in the signature must not share a root.
        let s₁ := [entryWith 100 0x11]
        let s₂ := [entryWith 100 0x22]
        assert (actionsRoot 0 s₁ != actionsRoot 0 s₂)
          "the leaf binds the signature"
    }
  , -- ## The compressed-wire round-trip (representation half of
    -- completeness)
    { name := "verifyActionProof ∘ buildActionProof: singleton batch"
    , body := do
        let es := [entryWith 100 0x11]
        let root := actionsRoot 7 es
        let commit := actionLeafValue (entryWith 100 0x11).signedAction
        let proof := buildActionProof 7 es 7
        assert (verifyActionProof root 7 commit proof)
          "the singleton opening verifies"
    }
  , { name := "verifyActionProof ∘ buildActionProof: both indices of a pair"
    , body := do
        let es := [entryWith 100 0x11, entryWith 200 0x22]
        let root := actionsRoot 10 es
        for (i, e) in [(10, entryWith 100 0x11), (11, entryWith 200 0x22)] do
          let proof := buildActionProof 10 es i
          assert (verifyActionProof root i
              (actionLeafValue e.signedAction) proof)
            s!"index {i} of the pair verifies"
    }
  , { name := "verifyActionProof ∘ buildActionProof: middle of eight"
    , body := do
        let root := actionsRoot 1000 batch8
        let proof := buildActionProof 1000 batch8 1004
        assert (verifyActionProof root 1004
            (actionLeafValue (entryWith 104 (UInt8.ofNat 4)).signedAction)
            proof)
          "a middle index of an eight-batch verifies"
    }
  , -- ## Negative controls
    { name := "a wrong commit is refused"
    , body := do
        let es := [entryWith 100 0x11, entryWith 200 0x22]
        let root := actionsRoot 0 es
        let proof := buildActionProof 0 es 0
        let forged := actionLeafValue (entryWith 999 0x11).signedAction
        assert (!(verifyActionProof root 0 forged proof))
          "a commit for a different action must not verify"
    }
  , { name := "a proof replayed at another index is refused"
    , body := do
        let es := [entryWith 100 0x11, entryWith 200 0x22]
        let root := actionsRoot 0 es
        let proof := buildActionProof 0 es 0
        assert (!(verifyActionProof root 1
            (actionLeafValue (entryWith 100 0x11).signedAction) proof))
          "index 0's opening must not authenticate index 1"
    }
  , { name := "a truncated wire is refused"
    , body := do
        let es := batch8
        let root := actionsRoot 0 es
        let proof := buildActionProof 0 es 3
        let truncated : SmtCellProof :=
          { proof with siblings := proof.siblings.pop }
        assert (!(verifyActionProof root 3
            (actionLeafValue (entryWith 103 (UInt8.ofNat 3)).signedAction)
            truncated))
          "dropping a sibling must break verification"
    }
  , -- ## The chain
    { name := "genesisChainSeed + batchChainFold commit every argument"
    , body := do
        let gsc := ByteArray.mk (Array.replicate 32 0xAA)
        let seed := genesisChainSeed gsc
        assertEq (expected := 32) (actual := seed.size) "seed is 32 bytes"
        assert (seed != genesisChainSeed (ByteArray.mk
            (Array.replicate 32 0xAB)))
          "the seed commits the genesis state commit"
        let sc₁ := ByteArray.mk (Array.replicate 32 0x01)
        let ar₁ := ByteArray.mk (Array.replicate 32 0x02)
        let one := batchChainFold seed [(sc₁, ar₁)]
        assert (one != seed) "a batch moves the chain"
        assert (one != batchChainFold seed [(ar₁, sc₁)])
          "state commit and actions root are not interchangeable"
        let two := batchChainFold seed [(sc₁, ar₁), (sc₁, ar₁)]
        assert (two != one) "each batch moves the chain again"
        assertEq (expected := (batchChainFold one [(sc₁, ar₁)]).toList)
          (actual := two.toList)
          "the fold is the iterated single step"
    }
  , -- ## Term-level API stability (elaboration-time pins)
    { name := "headline theorem signatures are stable"
    , body := do
        let _completeness :
            ∀ (first : Nat) (entries : List LogEntry)
              (i : Nat) (e : LogEntry), entries[i]? = some e →
              first + entries.length ≤ 2 ^ 64 →
              Bridge.CollisionFreeOn
                (batchKeyPreimages first entries.length) hashBytes →
              ((canonicalSiblings smtDepth (batchActionEntries first entries)
                  (actionKey (first + i))).zip
                (keyBitsUpTo smtDepth (actionKey (first + i)))).foldl stepPair
                  (leafHash (actionKey (first + i))
                    (actionLeafValue e.signedAction))
                = LegalKernel.FaultProof.actionsRoot first entries :=
          actionProof_canonical_walks_to_root
        let _soundness :
            ∀ (root : ByteArray) (n : Nat) (c₁ c₂ : ByteArray),
              c₁.size = 32 → c₂.size = 32 →
              ∀ (p₁ p₂ : SmtCellProof),
              Bridge.CollisionFreeOn
                (smtCellProofPreimages (actionKey n) c₁ c₂ p₁ p₂)
                hashBytes →
              verifyActionProof root n c₁ p₁ = true →
              verifyActionProof root n c₂ p₂ = true →
              c₁ = c₂ :=
          actionProof_no_value_substitution
        let _parity :
            ∀ {gs gs' : GameState} {t : GameTransition},
              applyTransition gs t = .ok gs' →
              turnAlignedWithPending gs → turnAlignedWithPending gs' :=
          @turn_aligned_preserved
        let _owner :
            ∀ {gs : GameState}, turnAlignedWithPending gs →
              gs.pendingMidpoint = none → gs.turn = .sequencer :=
          @terminate_owner_is_sequencer
        assert true "theorem signatures elaborated"
    }
  ]

end LegalKernel.Test.FaultProof.ActionsRoot
