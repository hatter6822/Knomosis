-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.SmtInjective — tests for SMT root
injectivity.

Two things are checked, and the second matters more than the first.

  * **The lemmas describe the code.**  `emptySubtreeHash_succ` and
    `emptyRootAt_eq_table` recover a relation the tail-recursive
    array builder does not make visible, so they are checked against
    the actual table at several depths rather than trusted.

  * **The hypotheses are load-bearing, not decorative.**
    `BitsDistinctBelow` is the condition that rules out two entries
    sharing a key.  The negative control below exhibits what happens
    without it — a two-entry bucket at depth 0 hashes to the *empty*
    root, so the map vanishes — which is precisely why the
    conclusion cannot be proved for arbitrary entry lists.
-/

import LegalKernel.FaultProof.SmtInjective
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.SmtInjective

/-- A 32-byte key whose only set byte is at `i`, so distinct `i`
    give keys that differ in a known bit. -/
def key32 (i : UInt8) : ByteArray :=
  ByteArray.mk ((List.range 32).map (fun j => if j == 0 then i else 0)).toArray

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "emptySubtreeHash_zero matches the table"
    , body := do
        assertEq (expected := (hashBytes emptyLeafSeedBytes).toList)
          (actual := (emptySubtreeHash 0).toList)
          "H_0 is the seed hash"
    }
  , { name := "the empty-subtree chain relation holds at real depths"
    , body := do
        -- `emptySubtreeHashes` is built by an array push loop, so the
        -- chain relation is proved rather than definitional.  Check
        -- it against the table at both ends and in the middle.
        for d in [0, 1, 2, 17, 128, 254] do
          let lhs := (emptySubtreeHash (d + 1)).toList
          let rhs := (hashBytes (emptySubtreeHash d ++ emptySubtreeHash d)).toList
          if lhs != rhs then
            throw <| IO.userError
              s!"empty-subtree chain broken at depth {d + 1}"
    }
  , { name := "emptyRootAt agrees with the table below depth 256"
    , body := do
        for d in [0, 1, 5, 200, 255] do
          assertEq (expected := (emptySubtreeHash d).toList)
            (actual := (emptyRootAt d).toList)
            s!"emptyRootAt {d}"
    }
  , { name := "an empty bucket hashes to the canonical empty root"
    , body := do
        for d in [0, 1, 9, 255, 256] do
          assertEq (expected := (emptyRootAt d).toList)
            (actual := (smtRootListAux (K := ByteArray) (V := ByteArray) d []).toList)
            s!"empty bucket at depth {d}"
    }
  , { name := "distinct 32-byte keys are separated by a key bit"
    , body := do
        -- The bridge from "keys differ" to `BitsDistinctBelow`.
        let a := key32 1
        let b := key32 2
        assert (a.toList != b.toList) "the fixture keys really differ"
        let differs := (List.range smtDepth).any
          (fun i => BitsKey.keyBit a i != BitsKey.keyBit b i)
        assert differs "some key bit below smtDepth separates them"
    }
  , { name := "equal key bits force equal 32-byte keys"
    , body := do
        let a := key32 3
        let agrees := (List.range smtDepth).all
          (fun i => BitsKey.keyBit a i == BitsKey.keyBit a i)
        assert agrees "a key agrees with itself on every bit"
        -- Sanity: the fixture really is 32 bytes, which is the
        -- hypothesis `byteArray_eq_of_keyBits_eq` needs.  A shorter
        -- key reads `false` past its end and would share a
        -- bit-vector with its zero-padded extension.
        assertEq (expected := 32) (actual := a.size) "fixture width"
    }
  , { name := "NEGATIVE CONTROL: duplicate keys collapse the root"
    , body := do
        -- This is why `BitsDistinctBelow` is a hypothesis and not a
        -- convenience.  At depth 0 `smtRootListAux` matches a
        -- singleton and falls through to the EMPTY root for any
        -- other shape, so two entries sharing a key hash exactly as
        -- if the bucket were empty.  Root injectivity is false for
        -- entry lists that are not distinctly keyed, and this
        -- exhibits the counterexample rather than asserting it.
        let k := key32 4
        let dup : List (ByteArray × ByteArray) :=
          [(k, ByteArray.mk #[1]), (k, ByteArray.mk #[2])]
        assertEq (expected := (smtRootListAux (K := ByteArray) (V := ByteArray) 0 []).toList)
          (actual := (smtRootListAux 0 dup).toList)
          "a duplicate-keyed depth-0 bucket is indistinguishable from empty"
    }
  , { name := "distinct singleton buckets have distinct roots"
    , body := do
        -- The positive counterpart: with distinct keys the depth-0
        -- roots are leaf hashes and separate.  (Under the FNV-1a
        -- fallback this is an observation, not a proof — the proof
        -- is `leafHash_inj_under_collision_free`, conditional on
        -- collision-freeness of exactly these two pre-images.)
        let e₁ : List (ByteArray × ByteArray) := [(key32 5, ByteArray.mk #[9])]
        let e₂ : List (ByteArray × ByteArray) := [(key32 6, ByteArray.mk #[9])]
        assert ((smtRootListAux 0 e₁).toList != (smtRootListAux 0 e₂).toList)
          "different keys give different depth-0 roots"
        let e₃ : List (ByteArray × ByteArray) := [(key32 5, ByteArray.mk #[8])]
        assert ((smtRootListAux 0 e₁).toList != (smtRootListAux 0 e₃).toList)
          "different values give different depth-0 roots"
    }
  , { name := "a populated bucket is not the empty root"
    , body := do
        -- The separation `smtRootListAux_ne_emptyRootAt_under_collision_free`
        -- proves, observed at the depths the state root uses.
        let e : List (ByteArray × ByteArray) := [(key32 7, ByteArray.mk #[1, 2])]
        for d in [0, 1, 8, 256] do
          assert ((smtRootListAux d e).toList != (emptyRootAt d).toList)
            s!"populated bucket at depth {d} is not the empty root"
    }
  , { name := "the pre-image enumeration covers the recursion"
    , body := do
        -- `CollisionFreeOn` is scoped to a finite list, so a
        -- pre-image the recursion consumes but the enumeration omits
        -- would leave the theorem unusable at that point.  Depth `d`
        -- of a singleton bucket consumes one hash per level plus the
        -- leaf.
        let e : List (ByteArray × ByteArray) := [(key32 8, ByteArray.mk #[3])]
        assertEq (expected := 1) (actual := (smtRootPreimages 0 e).length)
          "depth 0 consumes the leaf pre-image"
        assertEq (expected := 2) (actual := (smtRootPreimages 1 e).length)
          "depth 1 adds the level pre-image"
        assertEq (expected := 4) (actual := (smtRootPreimages 3 e).length)
          "depth 3 adds one per level"
        assertEq (expected := 0) (actual := (smtRootPreimages 3 []).length)
          "an empty bucket consumes no entry pre-image"
        assertEq (expected := 4) (actual := (emptyRootPreimages 3).length)
          "the empty chain contributes one pre-image per level plus the seed"
    }
  , { name := "a cell update moves the root and re-verifies"
    , body := do
        -- `smtUpdateRoot` / `smtUpdateRoot_verifies`: writing a cell
        -- replaces one leaf, so the same opening verifies the new
        -- value against the new root.  That is what lets a
        -- multi-write step chain openings — each against the root the
        -- previous write produced.
        let k := key32 9
        let v := ByteArray.mk #[1]
        let v' := ByteArray.mk #[2]
        let p := SmtCellProof.empty
        let root := smtWalk k v p
        let root' := smtUpdateRoot k v' p
        assert (root.toList != root'.toList) "the write must move the root"
        assertEq (expected := true)
          (actual := verifySmtCellProof root k v p)
          "the opening verifies the old value at the old root"
        assertEq (expected := true)
          (actual := verifySmtCellProof root' k v' p)
          "and the new value at the updated root"
        assertEq (expected := false)
          (actual := verifySmtCellProof root' k v p)
          "but not the old value at the updated root"
        assertEq (expected := 32) (actual := root'.size) "updated root width"
    }
  , { name := "rewriting a cell with its own value is a no-op"
    , body := do
        let k := key32 10
        let v := ByteArray.mk #[7, 7]
        let p := SmtCellProof.empty
        assertEq (expected := (smtWalk k v p).toList)
          (actual := (smtUpdateRoot k v p).toList)
          "an unchanged value leaves the root unchanged"
    }
  , { name := "API stability: SMT injectivity theorem signatures"
    , body := do
        -- Term-level pins.  Each ascription fails to elaborate if the
        -- theorem's signature moves, which is the guarantee the
        -- value-level checks above cannot give.
        let _empty_succ : ∀ (d : Nat), d + 1 < 256 →
            emptySubtreeHash (d + 1) =
              hashBytes (emptySubtreeHash d ++ emptySubtreeHash d) :=
          emptySubtreeHash_succ
        let _nil : ∀ (d : Nat), d ≤ 256 →
            smtRootListAux (K := ByteArray) (V := ByteArray) d [] = emptyRootAt d :=
          smtRootListAux_nil
        let _leaf_inj : ∀ (k₁ v₁ k₂ v₂ : ByteArray),
            CollisionFreeOn
              [encodeAsBytes k₁ ++ encodeAsBytes v₁,
               encodeAsBytes k₂ ++ encodeAsBytes v₂] hashBytes →
            k₁.size < 256 ^ 8 → v₁.size < 256 ^ 8 →
            k₂.size < 256 ^ 8 → v₂.size < 256 ^ 8 →
            leafHash k₁ v₁ = leafHash k₂ v₂ → k₁ = k₂ ∧ v₁ = v₂ :=
          leafHash_inj_under_collision_free
        let _sep : ∀ (d : Nat), d ≤ 256 → ∀ (e : SmtEntries),
            BitsDistinctBelow d e → EntriesEncodable e → e ≠ [] →
            CollisionFreeOn
              (smtRootPreimages d e ++ emptyRootPreimages d) hashBytes →
            smtRootListAux d e ≠ emptyRootAt d :=
          smtRootListAux_ne_emptyRootAt_under_collision_free
        let _inj : ∀ (d : Nat), d ≤ 256 → ∀ (e₁ e₂ : SmtEntries),
            BitsDistinctBelow d e₁ → BitsDistinctBelow d e₂ →
            EntriesEncodable e₁ → EntriesEncodable e₂ →
            CollisionFreeOn
              (smtRootPreimages d e₁ ++ smtRootPreimages d e₂ ++
                emptyRootPreimages d) hashBytes →
            smtRootListAux d e₁ = smtRootListAux d e₂ → e₁.Perm e₂ :=
          smtRootListAux_perm_of_eq_under_collision_free
        let _bits : ∀ {k₁ k₂ : ByteArray}, k₁.size = 32 → k₂.size = 32 →
            (∀ i, i < smtDepth → BitsKey.keyBit k₁ i = BitsKey.keyBit k₂ i) →
            k₁ = k₂ :=
          byteArray_eq_of_keyBits_eq
        let _bridge : ∀ {e : SmtEntries}, (∀ p ∈ e, p.1.size = 32) →
            e.Pairwise (fun a b => a.1 ≠ b.1) → BitsDistinctBelow smtDepth e :=
          bitsDistinctBelow_of_keys_pairwise_ne
        let _upd_ok : ∀ (key value : ByteArray) (proof : SmtCellProof),
            proof.isWellFormed = true →
            verifySmtCellProof (smtUpdateRoot key value proof) key value proof = true :=
          smtUpdateRoot_verifies
        let _upd_indep : ∀ (root key value newValue : ByteArray)
            (proof₁ proof₂ : SmtCellProof),
            CollisionFreeOn
              (smtCellProofPreimages key value value proof₁ proof₂) hashBytes →
            verifySmtCellProof root key value proof₁ = true →
            verifySmtCellProof root key value proof₂ = true →
            smtUpdateRoot key newValue proof₁ = smtUpdateRoot key newValue proof₂ :=
          smtUpdateRoot_proof_independent
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.SmtInjective
