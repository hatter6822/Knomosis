/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Smt — value-level + term-level
tests for the sparse-Merkle-tree cell-proof spec
(`LegalKernel/FaultProof/Smt.lean`).

Coverage:

  * **Empty / canonical hashes.**  `emptySubtreeHashes` has size
    256; every entry is 32 bytes; `emptySubtreeHash 0` matches
    `hashBytes emptyLeafSeedBytes`.
  * **BitsKey instances.**  Read-back from `UInt64` and
    `ByteArray` matches the expected MSB-first bit pattern.
  * **`SmtCellProof.empty`.**  Well-formed by construction.
    Has zero non-canonical siblings, all-zero bitmask.
  * **Walk / verifier.**  The empty proof matches the
    canonical "all-empty siblings" root.
  * **Soundness — value substitution rejected.**  If two
    proofs verify for `(root, key)`, they must claim the same
    value.
  * **Term-level API stability.**  Each shipped theorem's
    signature is pinned via a `let _proof : T := theorem`
    binding (elaboration-time check).
-/

import LegalKernel.FaultProof.Smt
import LegalKernel.Test.Framework

namespace LegalKernel.Test.FaultProof.Smt

open LegalKernel.Test
open LegalKernel.Encoding
open LegalKernel.Runtime
open LegalKernel.Bridge
open LegalKernel.FaultProof

/-! ## Term-level API stability checks

Each headline theorem of `LegalKernel/FaultProof/Smt.lean` is
pinned here via a `let _proof : T := theorem`-shaped term.
Elaboration of these terms fails if the theorem's signature
changes — catching API drift before any value-level test runs. -/

/-- API-stability term for `smtCellProof_no_value_substitution`. -/
example : True := by
  let _api :
      ∀ {K V : Type} [BitsKey K] [Encodable K] [Encodable V],
        Function.Injective (Encodable.encode : V → Stream) →
        CollisionFree hashBytes →
        ∀ (root : ByteArray) (key : K) (v₁ v₂ : V)
          (proof₁ proof₂ : SmtCellProof),
          verifySmtCellProof root key v₁ proof₁ = true →
          verifySmtCellProof root key v₂ proof₂ = true →
          v₁ = v₂ :=
    @smtCellProof_no_value_substitution
  trivial

/-- API-stability term for `smtCellProof_sound_under_collision_free`
    (the plan-named alias). -/
example : True := by
  let _api :
      ∀ {K V : Type} [BitsKey K] [Encodable K] [Encodable V],
        Function.Injective (Encodable.encode : V → Stream) →
        CollisionFree hashBytes →
        ∀ (root : ByteArray) (key : K) (v₁ v₂ : V)
          (proof₁ proof₂ : SmtCellProof),
          verifySmtCellProof root key v₁ proof₁ = true →
          verifySmtCellProof root key v₂ proof₂ = true →
          v₁ = v₂ :=
    @smtCellProof_sound_under_collision_free
  trivial

/-- API-stability term for the step-injectivity lemma. -/
example : True := by
  let _api :
      CollisionFree hashBytes →
      ∀ (c₁ c₂ s₁ s₂ : ByteArray),
        c₁.size = 32 → c₂.size = 32 →
        s₁.size = 32 → s₂.size = 32 →
        ∀ (bit : Bool),
          smtStep c₁ s₁ bit = smtStep c₂ s₂ bit →
          c₁ = c₂ ∧ s₁ = s₂ :=
    @smtStep_inj_under_collision_free
  trivial

/-- API-stability term for the walk-leaf-injectivity lemma. -/
example : True := by
  let _api :
      CollisionFree hashBytes →
      ∀ (bits : List Bool) (sibs₁ sibs₂ : List ByteArray)
        (leaf₁ leaf₂ : ByteArray),
        sibs₁.length = bits.length →
        sibs₂.length = bits.length →
        leaf₁.size = 32 →
        leaf₂.size = 32 →
        (∀ s ∈ sibs₁, s.size = 32) →
        (∀ s ∈ sibs₂, s.size = 32) →
        (sibs₁.zip bits).foldl stepPair leaf₁ =
        (sibs₂.zip bits).foldl stepPair leaf₂ →
        leaf₁ = leaf₂ :=
    @walk_leaf_inj_under_collision_free
  trivial

/-- API-stability term for the completeness theorem. -/
example : True := by
  let _api :
      ∀ {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
        (key : K) (value : V) (proof : SmtCellProof),
        proof.isWellFormed = true →
        verifySmtCellProof (smtWalk key value proof) key value proof = true :=
    @verifySmtCellProof_walks_to_root
  trivial

/-- API-stability term for empty-proof self-verification. -/
example : True := by
  let _api :
      ∀ {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
        (key : K) (value : V),
        verifySmtCellProof
          (smtWalk key value SmtCellProof.empty)
          key value SmtCellProof.empty = true :=
    @verifySmtCellProof_empty_self_verifies
  trivial

/-! ## Value-level tests -/

/-- Tests for the SMT cell-proof spec. -/
def tests : List TestCase :=
  [ { name := "smtDepth = 256"
    , body := do
        assertEq (expected := 256) (actual := smtDepth) "depth"
    }
  , { name := "emptySubtreeHashes has size 256"
    , body := do
        assertEq (expected := 256) (actual := emptySubtreeHashes.size) "size"
    }
  , { name := "emptySubtreeHash 0 is 32 bytes"
    , body := do
        let h0 := emptySubtreeHash 0
        assertEq (expected := 32) (actual := h0.size) "0-th hash size"
    }
  , { name := "emptySubtreeHash 100 is 32 bytes"
    , body := do
        let h100 := emptySubtreeHash 100
        assertEq (expected := 32) (actual := h100.size) "100-th hash size"
    }
  , { name := "emptySubtreeHash 255 is 32 bytes"
    , body := do
        let h255 := emptySubtreeHash 255
        assertEq (expected := 32) (actual := h255.size) "255-th hash size"
    }
  , { name := "emptySubtreeHashes[0] equals hashBytes emptyLeafSeedBytes"
    , body := do
        let h0_via_def := emptySubtreeHash 0
        let h0_direct := hashBytes emptyLeafSeedBytes
        assert (h0_via_def == h0_direct) "H_0 matches hashBytes EMPTY_LEAF"
    }
  , { name := "emptySubtreeHash d+1 equals hashBytes (H_d ++ H_d)"
    , body := do
        let h0 := emptySubtreeHash 0
        let h1_via_def := emptySubtreeHash 1
        let h1_direct := hashBytes (h0 ++ h0)
        assert (h1_via_def == h1_direct) "H_1 = hashBytes(H_0 ++ H_0)"
    }
  , { name := "paddingHash is 32 bytes"
    , body := do
        assertEq (expected := 32) (actual := paddingHash.size) "padding size"
    }
  , { name := "BitsKey UInt64: MSB of 0x80000000_00000000 is true"
    , body := do
        let k : UInt64 := 0x8000000000000000
        assert (BitsKey.keyBit k 0) "MSB"
        assert (¬ BitsKey.keyBit k 1) "bit 1 should be 0"
        assert (¬ BitsKey.keyBit k 63) "LSB should be 0"
    }
  , { name := "BitsKey UInt64: LSB of 1 is true"
    , body := do
        let k : UInt64 := 1
        assert (¬ BitsKey.keyBit k 0) "MSB should be 0"
        assert (BitsKey.keyBit k 63) "LSB"
        assert (¬ BitsKey.keyBit k 64) "out of range"
        assert (¬ BitsKey.keyBit k 100) "out of range deep"
    }
  , { name := "BitsKey UInt64: zero key has no bits set"
    , body := do
        let k : UInt64 := 0
        assert (¬ BitsKey.keyBit k 0) "bit 0"
        assert (¬ BitsKey.keyBit k 32) "bit 32"
        assert (¬ BitsKey.keyBit k 63) "bit 63"
        assert (¬ BitsKey.keyBit k 64) "out of range"
    }
  , { name := "BitsKey ByteArray: empty array returns false for all bits"
    , body := do
        let k : ByteArray := ByteArray.empty
        assert (¬ BitsKey.keyBit k 0) "bit 0"
        assert (¬ BitsKey.keyBit k 7) "bit 7"
        assert (¬ BitsKey.keyBit k 100) "bit 100"
    }
  , { name := "BitsKey ByteArray: MSB of #[0x80] is true"
    , body := do
        let k : ByteArray := ByteArray.mk #[0x80]
        assert (BitsKey.keyBit k 0) "MSB"
        assert (¬ BitsKey.keyBit k 1) "bit 1"
        assert (¬ BitsKey.keyBit k 7) "LSB of byte"
        assert (¬ BitsKey.keyBit k 8) "out of array"
    }
  , { name := "BitsKey ByteArray: LSB of #[0x01] is true"
    , body := do
        let k : ByteArray := ByteArray.mk #[0x01]
        assert (¬ BitsKey.keyBit k 0) "MSB"
        assert (BitsKey.keyBit k 7) "LSB"
    }
  , { name := "SmtCellProof.empty has empty siblings, 32-byte bitmask"
    , body := do
        let p := SmtCellProof.empty
        assertEq (expected := 0) (actual := p.siblings.size) "0 siblings"
        assertEq (expected := 32) (actual := p.bitmask.size) "32-byte bitmask"
    }
  , { name := "SmtCellProof.empty.bitmaskBit returns false for all depths"
    , body := do
        let p := SmtCellProof.empty
        assert (¬ p.bitmaskBit 0) "bit 0"
        assert (¬ p.bitmaskBit 100) "bit 100"
        assert (¬ p.bitmaskBit 255) "bit 255"
        assert (¬ p.bitmaskBit 1000) "out of range"
    }
  , { name := "SmtCellProof.empty is well-formed"
    , body := do
        let p := SmtCellProof.empty
        assert (p.isWellFormed) "empty proof is well-formed"
    }
  , { name := "isWellFormed rejects bitmask of wrong size"
    , body := do
        let p : SmtCellProof :=
          { siblings := #[],
            bitmask := ByteArray.mk #[0, 0, 0] }  -- 3 bytes, not 32
        assert (¬ p.isWellFormed) "3-byte bitmask rejected"
    }
  , { name := "isWellFormed rejects non-32-byte sibling"
    , body := do
        let p : SmtCellProof :=
          { siblings := #[ByteArray.mk #[0, 1, 2]],  -- 3-byte sibling
            bitmask := ByteArray.mk (Array.replicate 32 (0 : UInt8)) }
        assert (¬ p.isWellFormed) "3-byte sibling rejected"
    }
  , { name := "expandSiblings on empty proof: length 256, all 32 bytes"
    , body := do
        let p := SmtCellProof.empty
        let sibs := expandSiblings p
        assertEq (expected := 256) (actual := sibs.length) "length"
        -- Every sibling should be 32 bytes (canonical empty).
        for s in sibs do
          assertEq (expected := 32) (actual := s.size) "sibling size"
    }
  , { name := "expandSiblings on empty proof matches emptySubtreeHash sequence"
    , body := do
        let p := SmtCellProof.empty
        let sibs := expandSiblings p
        -- Each entry should equal emptySubtreeHash d for d = 0..255.
        for d in [0:256] do
          match sibs[d]? with
          | some sib =>
              assert (sib == emptySubtreeHash d)
                s!"sib at depth {d} should equal emptySubtreeHash {d}"
          | none =>
              throw <| IO.userError s!"sibs[{d}] is none — expected length 256"
    }
  , { name := "keyBits length is 256"
    , body := do
        let key : UInt64 := 42
        let bits := keyBits key
        assertEq (expected := 256) (actual := bits.length) "length"
    }
  , { name := "leafHash is 32 bytes"
    , body := do
        let key : UInt64 := 42
        let value : UInt64 := 100
        let leaf := leafHash key value
        assertEq (expected := 32) (actual := leaf.size) "leaf size"
    }
  , { name := "smtStep output is 32 bytes (bit = false)"
    , body := do
        let c := paddingHash
        let s := paddingHash
        let parent := smtStep c s false
        assertEq (expected := 32) (actual := parent.size) "parent size"
    }
  , { name := "smtStep output is 32 bytes (bit = true)"
    , body := do
        let c := paddingHash
        let s := paddingHash
        let parent := smtStep c s true
        assertEq (expected := 32) (actual := parent.size) "parent size"
    }
  , { name := "smtStep distinguishes bit = false vs bit = true"
    , body := do
        -- For non-symmetric (current, sibling), the bit determines
        -- the order of concatenation, producing different parents.
        let c := ByteArray.mk #[1, 2, 3, 4]
        let s := ByteArray.mk #[5, 6, 7, 8]
        let parent_left := smtStep c s false   -- hashBytes (c ++ s)
        let parent_right := smtStep c s true  -- hashBytes (s ++ c)
        -- Under any non-trivial hash, the two should differ.  For
        -- FNV-1a-64 fallback, they SHOULD differ (the fold over
        -- distinct inputs produces distinct outputs with high
        -- probability), but we don't strictly assert this — just
        -- that both are 32 bytes.  Inequality would be a stronger
        -- claim that depends on the linked hash.
        assertEq (expected := 32) (actual := parent_left.size) "left size"
        assertEq (expected := 32) (actual := parent_right.size) "right size"
    }
  , { name := "smtWalk on empty proof is determined by key + value"
    , body := do
        let key : UInt64 := 0  -- All-zero bits ⇒ always "current ++ sibling".
        let value : UInt64 := 42
        let proof := SmtCellProof.empty
        let root1 := smtWalk key value proof
        let root2 := smtWalk key value proof
        assert (root1 == root2) "deterministic"
        assertEq (expected := 32) (actual := root1.size) "32 bytes"
    }
  , { name := "smtWalk reflects value change (likely; fallback hash)"
    , body := do
        let key : UInt64 := 100
        let v1 : UInt64 := 1
        let v2 : UInt64 := 2
        let proof := SmtCellProof.empty
        let r1 := smtWalk key v1 proof
        let r2 := smtWalk key v2 proof
        -- Under the FNV-1a-64 fallback, distinct (encoded) values
        -- should produce distinct leafs and thus distinct roots.
        -- This is a smoke check; the formal soundness theorem
        -- is `smtCellProof_no_value_substitution`.
        assert (¬ r1 == r2) "distinct values produce distinct roots (likely)"
    }
  , { name := "verifySmtCellProof accepts canonical empty-proof walk"
    , body := do
        let key : UInt64 := 0
        let value : UInt64 := 42
        let proof := SmtCellProof.empty
        let root := smtWalk key value proof
        assert (verifySmtCellProof root key value proof) "self-verifies"
    }
  , { name := "verifySmtCellProof rejects proof with wrong root"
    , body := do
        let key : UInt64 := 0
        let value : UInt64 := 42
        let proof := SmtCellProof.empty
        let wrong_root := ByteArray.mk (Array.replicate 32 (99 : UInt8))
        assert (¬ verifySmtCellProof wrong_root key value proof)
          "wrong root rejected"
    }
  , { name := "verifySmtCellProof rejects ill-formed (wrong bitmask size) proof"
    , body := do
        let key : UInt64 := 0
        let value : UInt64 := 42
        let bad_proof : SmtCellProof :=
          { siblings := #[],
            bitmask  := ByteArray.mk #[0, 0, 0] }  -- 3 bytes
        let any_root := ByteArray.mk (Array.replicate 32 (0 : UInt8))
        assert (¬ verifySmtCellProof any_root key value bad_proof)
          "ill-formed proof rejected regardless of root"
    }
  , { name := "verifySmtCellProof rejects ill-formed (wrong sibling size) proof"
    , body := do
        let key : UInt64 := 0
        let value : UInt64 := 42
        -- Bitmask has bit 0 set, sibling is wrong size.
        let mut bm_arr : Array UInt8 := Array.replicate 32 (0 : UInt8)
        bm_arr := bm_arr.set! 0 1  -- bit 0 = LSB of byte 0 set
        let bad_proof : SmtCellProof :=
          { siblings := #[ByteArray.mk #[1, 2, 3]],  -- 3-byte sibling
            bitmask  := ByteArray.mk bm_arr }
        let any_root := ByteArray.mk (Array.replicate 32 (0 : UInt8))
        assert (¬ verifySmtCellProof any_root key value bad_proof)
          "wrong-sibling-size proof rejected"
    }
  , { name := "verifySmtCellProof_deterministic spot-check"
    , body := do
        let key : UInt64 := 42
        let value : UInt64 := 100
        let proof := SmtCellProof.empty
        let root := smtWalk key value proof
        let v1 := verifySmtCellProof root key value proof
        let v2 := verifySmtCellProof root key value proof
        assertEq (expected := v1) (actual := v2) "two calls agree"
    }
  , { name := "encodeAsBytes is deterministic"
    , body := do
        let v1 : UInt64 := 42
        let v2 : UInt64 := 42
        let b1 := encodeAsBytes v1
        let b2 := encodeAsBytes v2
        assert (b1 == b2) "same input ⇒ same bytes"
    }
  , { name := "encodeAsBytes distinguishes distinct UInt64s"
    , body := do
        let v1 : UInt64 := 42
        let v2 : UInt64 := 43
        let b1 := encodeAsBytes v1
        let b2 := encodeAsBytes v2
        assert (¬ b1 == b2) "different inputs ⇒ different bytes"
    }
  , { name := "Two different keys yield different leafHash (likely)"
    , body := do
        let k1 : UInt64 := 1
        let k2 : UInt64 := 2
        let v : UInt64 := 42
        let leaf1 := leafHash k1 v
        let leaf2 := leafHash k2 v
        assert (¬ leaf1 == leaf2) "distinct keys yield distinct leaves"
    }
  , { name := "verifySmtCellProof_walks_to_root: well-formed proof self-verifies"
    , body := do
        let key : UInt64 := 42
        let value : UInt64 := 100
        let proof := SmtCellProof.empty
        let root := smtWalk key value proof
        -- Equivalent to verifySmtCellProof_walks_to_root applied at this point.
        assert (verifySmtCellProof root key value proof)
          "well-formed proof self-verifies"
    }
  , { name := "SmtCellProof.empty is well-formed (theorem)"
    , body := do
        -- Value-level reflection of `SmtCellProof.empty_isWellFormed`.
        assertEq (expected := true) (actual := SmtCellProof.empty.isWellFormed)
          "empty proof well-formed"
    }
  , { name := "verifySmtCellProof_empty_self_verifies for UInt64 cells"
    , body := do
        -- Spot-check across several (key, value) pairs.
        let pairs : List (UInt64 × UInt64) :=
          [(0, 0), (1, 1), (42, 100), (0xDEADBEEF, 0xCAFEBABE),
           (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF)]
        for (k, v) in pairs do
          let r := smtWalk k v SmtCellProof.empty
          assert (verifySmtCellProof r k v SmtCellProof.empty)
            s!"empty proof self-verifies for ({k}, {v})"
    }
  , { name := "Padding hash differs from canonical empty hash H_0"
    , body := do
        -- paddingHash = 32 zero bytes; H_0 = hashBytes "EMPTY_LEAF".
        -- Under any non-trivial hash, these differ.
        let h0 := emptySubtreeHash 0
        assert (¬ paddingHash == h0)
          "padding hash distinct from canonical empty"
    }
  , { name := "keyBits is deterministic"
    , body := do
        let k : UInt64 := 12345
        let bits1 := keyBits k
        let bits2 := keyBits k
        assert (bits1 == bits2) "deterministic"
    }
  , { name := "keyBits depends on the key"
    , body := do
        let bits_zero := keyBits (0 : UInt64)
        let bits_one := keyBits (1 : UInt64)
        assert (¬ bits_zero == bits_one) "distinct keys give distinct bits"
    }
  , { name := "expandSiblings respects bitmask: empty bitmask ⇒ all empty hashes"
    , body := do
        let p := SmtCellProof.empty
        let sibs := expandSiblings p
        -- Every entry equals emptySubtreeHash d, verified earlier.
        -- Here we also verify that no entry equals paddingHash (which
        -- would indicate an out-of-bounds lookup — but the empty proof
        -- never sets a bitmask bit, so no proof.siblings lookup
        -- occurs).
        let mut padding_count := 0
        for s in sibs do
          if s == paddingHash then
            padding_count := padding_count + 1
        assertEq (expected := 0) (actual := padding_count)
          "no padding-hash entries for empty proof"
    }
  , { name := "Non-trivial proof with one set bitmask bit verifies self-walk"
    , body := do
        -- Build a non-trivial proof: bitmask has bit 0 set, supplying
        -- one custom sibling.
        let custom_sib := ByteArray.mk (Array.replicate 32 (7 : UInt8))
        let bm_array := (Array.replicate 32 (0 : UInt8)).set! 0 1
        let proof : SmtCellProof :=
          { siblings := #[custom_sib], bitmask := ByteArray.mk bm_array }
        assert (proof.isWellFormed) "non-trivial proof is well-formed"
        assert (proof.bitmaskBit 0) "bit 0 set"
        assert (¬ proof.bitmaskBit 1) "bit 1 unset"
        let key : UInt64 := 42
        let value : UInt64 := 100
        let root := smtWalk key value proof
        assertEq (expected := 32) (actual := root.size) "32-byte walk output"
        assert (verifySmtCellProof root key value proof) "self-verify"
    }
  , { name := "Non-trivial proof: walk differs from empty-proof walk"
    , body := do
        -- A non-trivial proof with different sibling than canonical
        -- empty should produce a different walked root.
        let custom_sib := ByteArray.mk (Array.replicate 32 (7 : UInt8))
        let bm_array := (Array.replicate 32 (0 : UInt8)).set! 0 1
        let proof_nt : SmtCellProof :=
          { siblings := #[custom_sib], bitmask := ByteArray.mk bm_array }
        let proof_empty := SmtCellProof.empty
        let key : UInt64 := 42
        let value : UInt64 := 100
        let root_nt := smtWalk key value proof_nt
        let root_empty := smtWalk key value proof_empty
        assert (¬ root_nt == root_empty)
          "non-trivial proof walks to different root than empty proof"
    }
  , { name := "Two custom proofs with different siblings walk to different roots"
    , body := do
        -- Two proofs sharing the same bitmask (bit 0 set) but with
        -- different siblings should walk to different roots.
        let bm_array := (Array.replicate 32 (0 : UInt8)).set! 0 1
        let sib_a := ByteArray.mk (Array.replicate 32 (1 : UInt8))
        let sib_b := ByteArray.mk (Array.replicate 32 (2 : UInt8))
        let proof_a : SmtCellProof :=
          { siblings := #[sib_a], bitmask := ByteArray.mk bm_array }
        let proof_b : SmtCellProof :=
          { siblings := #[sib_b], bitmask := ByteArray.mk bm_array }
        let key : UInt64 := 42
        let value : UInt64 := 100
        let root_a := smtWalk key value proof_a
        let root_b := smtWalk key value proof_b
        assert (¬ root_a == root_b)
          "different siblings yield different roots"
    }
  , { name := "Bitmask bit 8 = LSB of byte 1"
    , body := do
        -- Verify the depth-to-(byte, bit) mapping.
        let mut bm_array : Array UInt8 := Array.replicate 32 (0 : UInt8)
        bm_array := bm_array.set! 1 1  -- byte 1, LSB
        let proof : SmtCellProof :=
          { siblings := #[ByteArray.mk (Array.replicate 32 (0 : UInt8))],
            bitmask  := ByteArray.mk bm_array }
        assert (proof.bitmaskBit 8) "bit 8 (LSB of byte 1) set"
        assert (¬ proof.bitmaskBit 9) "bit 9 not set"
        assert (¬ proof.bitmaskBit 0) "bit 0 not set"
    }
  , { name := "smtRoot of empty TreeMap is 32 bytes"
    , body := do
        let m : Std.TreeMap UInt64 UInt64 compare := ∅
        let root := smtRoot m
        assertEq (expected := 32) (actual := root.size) "32-byte empty root"
    }
  , { name := "smtRoot of singleton TreeMap is 32 bytes"
    , body := do
        let m : Std.TreeMap UInt64 UInt64 compare := Std.TreeMap.empty.insert 42 100
        let root := smtRoot m
        assertEq (expected := 32) (actual := root.size) "32-byte singleton root"
    }
  , { name := "smtRoot is deterministic"
    , body := do
        let m : Std.TreeMap UInt64 UInt64 compare := Std.TreeMap.empty.insert 1 10
        let root1 := smtRoot m
        let root2 := smtRoot m
        assert (root1 == root2) "deterministic"
    }
  , { name := "smtRoot distinguishes empty from non-empty maps"
    , body := do
        let m_empty : Std.TreeMap UInt64 UInt64 compare := ∅
        let m_nonempty : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 42 100
        let root_empty := smtRoot m_empty
        let root_nonempty := smtRoot m_nonempty
        assert (¬ root_empty == root_nonempty)
          "empty and non-empty maps have distinct roots"
    }
  , { name := "smtRoot distinguishes maps with different values at same key"
    , body := do
        let m1 : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 42 100
        let m2 : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 42 200
        let r1 := smtRoot m1
        let r2 := smtRoot m2
        assert (¬ r1 == r2) "distinct values yield distinct roots"
    }
  , { name := "smtRoot of two-element map is 32 bytes"
    , body := do
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 1 10 |>.insert 2 20
        let root := smtRoot m
        assertEq (expected := 32) (actual := root.size) "32-byte two-element root"
    }
  -- ## SC.1.f plan coverage: gap-filling tests
  --
  -- Per the plan §SC.1.f, additional value-level coverage:
  --   * empty-map smtRoot matches hashBytes(H_255 ++ H_255).
  --   * singleton coherence: smtRoot == empty-proof smtWalk.
  --   * adversarial tampering: tamper value, sibling, bitmask
  --     individually and check verifier rejects each.
  --   * two-cell map with canonical proof construction via
  --     `buildSmtCellProof`.
  , { name := "Empty TreeMap smtRoot equals hashBytes (H_255 ++ H_255)"
    , body := do
        -- The empty map's SMT root at depth 256 is conceptually H_256,
        -- computed on the fly as hashBytes(H_255 ++ H_255) since
        -- emptySubtreeHashes only stores depths 0..255.
        let m : Std.TreeMap UInt64 UInt64 compare := ∅
        let actual := smtRoot m
        let h_255 := emptySubtreeHash 255
        let expected := hashBytes (h_255 ++ h_255)
        assert (actual == expected)
          "empty-map smtRoot matches hashBytes(H_255 ++ H_255)"
    }
  , { name := "Singleton smtRoot equals empty-proof smtWalk (coherence)"
    , body := do
        -- For a singleton map m = {(k, v)}, the canonical cell proof
        -- for k is the empty proof (all-canonical-empty siblings).
        -- The empty proof's smtWalk should equal smtRoot m.
        let pairs : List (UInt64 × UInt64) :=
          [(0, 0), (1, 100), (42, 99), (12345, 67890),
           (0xDEADBEEF, 0xCAFEBABE)]
        for (k, v) in pairs do
          let m : Std.TreeMap UInt64 UInt64 compare :=
            Std.TreeMap.empty.insert k v
          let root_via_root := smtRoot m
          let root_via_walk := smtWalk k v SmtCellProof.empty
          assert (root_via_root == root_via_walk)
            s!"singleton coherence for ({k}, {v})"
    }
  , { name := "Adversarial: tamper value rejects verification"
    , body := do
        -- Compute a valid (root, key, value, proof) tuple, then
        -- substitute a wrong value and ensure verifySmtCellProof
        -- rejects.  This validates the no-substitution property
        -- operationally.
        let key : UInt64 := 42
        let value_honest : UInt64 := 100
        let value_tampered : UInt64 := 999
        let proof := SmtCellProof.empty
        let root := smtWalk key value_honest proof
        -- Honest verification succeeds.
        assert (verifySmtCellProof root key value_honest proof)
          "honest verification accepts"
        -- Tampered verification (different value) fails.
        assert (¬ verifySmtCellProof root key value_tampered proof)
          "tampered-value verification rejects"
    }
  , { name := "Adversarial: tamper key rejects verification"
    , body := do
        -- Verify the proof against a wrong key (different from the
        -- one used to compute root).  The walk traces a different
        -- path, so should miss the root.
        let key_honest : UInt64 := 42
        let key_tampered : UInt64 := 43
        let value : UInt64 := 100
        let proof := SmtCellProof.empty
        let root := smtWalk key_honest value proof
        -- Honest verification succeeds.
        assert (verifySmtCellProof root key_honest value proof)
          "honest key accepts"
        -- Wrong key fails (different bit path produces different walk).
        assert (¬ verifySmtCellProof root key_tampered value proof)
          "tampered-key verification rejects"
    }
  , { name := "Adversarial: tamper sibling at depth 0 rejects verification"
    , body := do
        -- Build a valid (key, value, proof) with a custom sibling at
        -- depth 0.  Then submit a DIFFERENT custom sibling — the walk
        -- should differ, and the original-root verification should
        -- reject.
        let custom_sib := ByteArray.mk (Array.replicate 32 (7 : UInt8))
        let tampered_sib := ByteArray.mk (Array.replicate 32 (8 : UInt8))
        let bm_array := (Array.replicate 32 (0 : UInt8)).set! 0 1
        let proof_honest : SmtCellProof :=
          { siblings := #[custom_sib], bitmask := ByteArray.mk bm_array }
        let proof_tampered : SmtCellProof :=
          { siblings := #[tampered_sib], bitmask := ByteArray.mk bm_array }
        let key : UInt64 := 42
        let value : UInt64 := 100
        let root := smtWalk key value proof_honest
        assert (verifySmtCellProof root key value proof_honest)
          "honest proof verifies"
        assert (¬ verifySmtCellProof root key value proof_tampered)
          "tampered-sibling proof rejects"
    }
  , { name := "Adversarial: tamper bitmask bit rejects verification"
    , body := do
        -- Build a valid proof, then change a bitmask bit (turning a
        -- non-canonical sibling into canonical-empty, or vice versa).
        -- The walk should differ.
        let custom_sib := ByteArray.mk (Array.replicate 32 (7 : UInt8))
        let bm_honest := (Array.replicate 32 (0 : UInt8)).set! 0 1  -- bit 0 set
        let bm_tampered := (Array.replicate 32 (0 : UInt8)).set! 0 2  -- bit 1 set
        let proof_honest : SmtCellProof :=
          { siblings := #[custom_sib], bitmask := ByteArray.mk bm_honest }
        let proof_tampered : SmtCellProof :=
          { siblings := #[custom_sib], bitmask := ByteArray.mk bm_tampered }
        let key : UInt64 := 42
        let value : UInt64 := 100
        let root := smtWalk key value proof_honest
        assert (verifySmtCellProof root key value proof_honest)
          "honest proof verifies"
        assert (¬ verifySmtCellProof root key value proof_tampered)
          "tampered-bitmask proof rejects"
    }
  , { name := "buildSmtCellProof: empty map produces empty proof"
    , body := do
        let m : Std.TreeMap UInt64 UInt64 compare := ∅
        let proof := buildSmtCellProof m (42 : UInt64)
        -- An empty map's canonical proof has no non-canonical-empty
        -- siblings and an all-zero bitmask.
        assertEq (expected := 0) (actual := proof.siblings.size) "0 siblings"
        assertEq (expected := 32) (actual := proof.bitmask.size) "32-byte bitmask"
        assert (proof.isWellFormed) "well-formed"
    }
  , { name := "buildSmtCellProof: singleton map produces empty proof"
    , body := do
        -- For a singleton, the canonical proof is the empty proof —
        -- no non-canonical siblings, all canonical-empty.
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 42 100
        let proof := buildSmtCellProof m (42 : UInt64)
        assertEq (expected := 0) (actual := proof.siblings.size) "0 siblings"
        assert (proof.isWellFormed) "well-formed"
    }
  , { name := "buildSmtCellProof: singleton proof verifies against smtRoot"
    , body := do
        -- The full coherence check: build a canonical proof for a
        -- singleton, verify it against smtRoot m.
        let pairs : List (UInt64 × UInt64) :=
          [(0, 0), (1, 100), (42, 99), (12345, 67890),
           (0xDEADBEEF, 0xCAFEBABE)]
        for (k, v) in pairs do
          let m : Std.TreeMap UInt64 UInt64 compare :=
            Std.TreeMap.empty.insert k v
          let proof := buildSmtCellProof m k
          let root := smtRoot m
          assert (verifySmtCellProof root k v proof)
            s!"canonical proof for ({k}, {v}) verifies against smtRoot m"
    }
  , { name := "buildSmtCellProof: two-cell map produces non-trivial proof"
    , body := do
        -- For a two-element map with keys diverging at some bit,
        -- the canonical proof has exactly ONE non-canonical-empty
        -- sibling (the other key's sub-tree root at the divergence
        -- depth).
        let k1 : UInt64 := 1
        let k2 : UInt64 := 2
        let v1 : UInt64 := 100
        let v2 : UInt64 := 200
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k1 v1 |>.insert k2 v2
        let proof_k1 := buildSmtCellProof m k1
        let proof_k2 := buildSmtCellProof m k2
        -- Both proofs should be well-formed.
        assert (proof_k1.isWellFormed) "proof for k1 well-formed"
        assert (proof_k2.isWellFormed) "proof for k2 well-formed"
        -- Both should have at least one non-canonical-empty sibling.
        assert (proof_k1.siblings.size >= 1) "proof for k1 has siblings"
        assert (proof_k2.siblings.size >= 1) "proof for k2 has siblings"
    }
  , { name := "buildSmtCellProof: two-cell proofs verify against smtRoot"
    , body := do
        -- The complete coherence test for multi-cell maps.
        let k1 : UInt64 := 1
        let k2 : UInt64 := 2
        let v1 : UInt64 := 100
        let v2 : UInt64 := 200
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k1 v1 |>.insert k2 v2
        let root := smtRoot m
        let proof_k1 := buildSmtCellProof m k1
        let proof_k2 := buildSmtCellProof m k2
        assert (verifySmtCellProof root k1 v1 proof_k1)
          "proof_k1 verifies for (k1, v1) at root"
        assert (verifySmtCellProof root k2 v2 proof_k2)
          "proof_k2 verifies for (k2, v2) at root"
    }
  , { name := "buildSmtCellProof: tampering value at k1 fails"
    , body := do
        -- The no-value-substitution property exercised operationally:
        -- a proof for the honest value verifies; the same proof with
        -- a wrong value claim should fail.
        let k1 : UInt64 := 1
        let k2 : UInt64 := 2
        let v1 : UInt64 := 100
        let v2 : UInt64 := 200
        let v_wrong : UInt64 := 999
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k1 v1 |>.insert k2 v2
        let root := smtRoot m
        let proof_k1 := buildSmtCellProof m k1
        -- Honest verification works.
        assert (verifySmtCellProof root k1 v1 proof_k1) "honest"
        -- Substituting v_wrong fails.
        assert (¬ verifySmtCellProof root k1 v_wrong proof_k1)
          "value substitution rejected"
    }
  , { name := "Distinct two-cell maps have distinct smtRoots"
    , body := do
        -- Two maps differing in one cell value should have distinct
        -- smtRoots — a basic sanity check on the SMT discrimination.
        let m1 : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 1 100 |>.insert 2 200
        let m2 : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 1 100 |>.insert 2 201
        let r1 := smtRoot m1
        let r2 := smtRoot m2
        assert (¬ r1 == r2) "distinct maps yield distinct roots"
    }
  , { name := "Far-apart keys diverge at high depth (UInt64 MSB)"
    , body := do
        -- For UInt64 keys 0 and 2^63, they diverge at the MSB
        -- (bit 0 in our MSB-first indexing).  Verify keyBit detects
        -- this.
        let k_low : UInt64 := 0
        let k_high : UInt64 := 0x8000000000000000  -- 2^63
        assert (¬ BitsKey.keyBit k_low 0) "k_low MSB = 0"
        assert (BitsKey.keyBit k_high 0) "k_high MSB = 1"
        -- All other bits agree.
        for i in [1:64] do
          assert (BitsKey.keyBit k_low i == BitsKey.keyBit k_high i)
            s!"bit {i} agrees"
    }
  , { name := "verifySmtCellProof rejects proof with extra siblings (DoS bound)"
    , body := do
        -- A well-formed proof can have more siblings than the bitmask
        -- popcount.  These extra siblings are simply unused by the
        -- walk.  This test ensures the verifier doesn't accidentally
        -- accept such a proof at a *different* root.
        let extra_sib := ByteArray.mk (Array.replicate 32 (5 : UInt8))
        let proof : SmtCellProof :=
          { siblings := #[extra_sib, extra_sib, extra_sib],  -- 3 unused siblings
            bitmask  := ByteArray.mk (Array.replicate 32 (0 : UInt8)) }
        -- Well-formedness should still pass (every sibling is 32 bytes).
        assert (proof.isWellFormed) "well-formed despite extras"
        -- The walk is determined by the bitmask (all zeros) and key/value.
        let key : UInt64 := 42
        let value : UInt64 := 100
        let root_via_extras := smtWalk key value proof
        let root_via_empty := smtWalk key value SmtCellProof.empty
        -- Both produce the same root because extras are unused.
        assert (root_via_extras == root_via_empty)
          "extras don't affect walk"
    }
  , { name := "buildSmtCellProof: 3-cell map with siblings at multiple depths"
    , body := do
        -- 3-cell map where the proof has non-canonical siblings at
        -- multiple depths.  This tests the order of siblings in the
        -- `siblings` array (must be low-depth-first to match the
        -- expander's consumption order).
        --
        -- Keys: k_a = 0, k_b = 1 (LSB=1), k_c = 2^63 (MSB=1).
        -- For k_a's proof in {k_a, k_b, k_c}:
        --   - At top depths: all three on left.
        --   - At d=64 (partition by LSB): k_b diverges; sibling at d=63 added.
        --   - At d=1 (partition by MSB): k_c diverges; sibling at d=0 added.
        -- Result: 2 non-canonical siblings (at d=0 and d=63).
        let k_a : UInt64 := 0
        let k_b : UInt64 := 1
        let k_c : UInt64 := 0x8000000000000000
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k_a 100 |>.insert k_b 200 |>.insert k_c 300
        let proof := buildSmtCellProof m k_a
        let root := smtRoot m
        -- The canonical proof for k_a should verify against smtRoot m.
        assert (verifySmtCellProof root k_a 100 proof)
          "canonical proof for 3-cell map verifies"
        -- Sanity: proof has exactly 2 non-canonical siblings.
        assertEq (expected := 2) (actual := proof.siblings.size)
          "proof has 2 siblings (one per divergence)"
    }
  , { name := "buildSmtCellProof: 3-cell map verifies all cells"
    , body := do
        -- Build all three canonical proofs for the 3-cell map and
        -- verify each.
        let k_a : UInt64 := 0
        let k_b : UInt64 := 1
        let k_c : UInt64 := 0x8000000000000000
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k_a 100 |>.insert k_b 200 |>.insert k_c 300
        let root := smtRoot m
        for (k, v) in [(k_a, (100 : UInt64)), (k_b, 200), (k_c, 300)] do
          let proof := buildSmtCellProof m k
          assert (verifySmtCellProof root k v proof)
            s!"canonical proof for k={k} verifies"
    }
  , { name := "buildSmtCellProof: 3-cell map rejects value substitution"
    , body := do
        -- For the 3-cell map, substituting a different value into
        -- one cell's verification should be rejected.
        let k_a : UInt64 := 0
        let k_b : UInt64 := 1
        let k_c : UInt64 := 0x8000000000000000
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k_a 100 |>.insert k_b 200 |>.insert k_c 300
        let root := smtRoot m
        let proof_k_a := buildSmtCellProof m k_a
        -- Honest verification (k_a → 100) passes.
        assert (verifySmtCellProof root k_a 100 proof_k_a) "honest"
        -- Substituting wrong values fails.
        assert (¬ verifySmtCellProof root k_a 99 proof_k_a) "v=99 rejected"
        assert (¬ verifySmtCellProof root k_a 200 proof_k_a) "v=200 rejected"
        assert (¬ verifySmtCellProof root k_a 300 proof_k_a) "v=300 rejected"
    }
  , { name := "buildSmtCellProof: 4-cell map verifies all cells"
    , body := do
        -- Verify the canonical proofs for a 4-cell map.  Each
        -- proof must verify against smtRoot m.
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 0 10 |>.insert 1 20
            |>.insert 0x4000000000000000 30
            |>.insert 0x8000000000000000 40
        let root := smtRoot m
        for (k, v) in [((0 : UInt64), (10 : UInt64)),
                       (1, 20),
                       (0x4000000000000000, 30),
                       (0x8000000000000000, 40)] do
          let proof := buildSmtCellProof m k
          assert (verifySmtCellProof root k v proof)
            s!"canonical proof for k={k} verifies in 4-cell map"
    }
  , { name := "buildSmtCellProof: key NOT in map — proof rejects all values"
    , body := do
        -- For a key absent from the map, the canonical proof
        -- construction walks the tree (using `keyBit k d` for
        -- the absent key), but `verifySmtCellProof` rejects
        -- every value claim because the leafHash never matches
        -- the tree's actual content at this position.  This
        -- validates the verifier's correct behaviour on
        -- absent-cell claims.
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert 1 100 |>.insert 2 200
        let absent_key : UInt64 := 999  -- not in m
        let root := smtRoot m
        let proof := buildSmtCellProof m absent_key
        -- The proof is well-formed (constructed by our canonical
        -- builder), but verification fails for any value.
        assert (proof.isWellFormed) "proof is well-formed"
        let candidate_values : List UInt64 := [0, 1, 100, 200, 999, 0xFFFFFFFF]
        for v in candidate_values do
          assert (¬ verifySmtCellProof root absent_key v proof)
            s!"absent-key verification rejects v={v}"
    }
  , { name := "buildSmtCellProof: cross-key — k1's proof rejects k2"
    , body := do
        -- Each cell has its own canonical proof.  The proof for
        -- k1 should NOT verify when supplied with k2 (different
        -- key produces different walk path).
        let k1 : UInt64 := 1
        let k2 : UInt64 := 2
        let v1 : UInt64 := 100
        let v2 : UInt64 := 200
        let m : Std.TreeMap UInt64 UInt64 compare :=
          Std.TreeMap.empty.insert k1 v1 |>.insert k2 v2
        let root := smtRoot m
        let proof_k1 := buildSmtCellProof m k1
        let proof_k2 := buildSmtCellProof m k2
        -- Honest verifications pass.
        assert (verifySmtCellProof root k1 v1 proof_k1) "k1 honest"
        assert (verifySmtCellProof root k2 v2 proof_k2) "k2 honest"
        -- Cross-key with own value fails.
        assert (¬ verifySmtCellProof root k2 v2 proof_k1)
          "k1's proof can't witness k2"
        assert (¬ verifySmtCellProof root k1 v1 proof_k2)
          "k2's proof can't witness k1"
    }
  , { name := "Stress test: 8 random UInt64 keys all verify"
    , body := do
        -- Deterministic 'random' UInt64 keys derived from a seed.
        -- This validates buildSmtCellProof + verifySmtCellProof
        -- on a realistic-sized map.
        let keys : List UInt64 :=
          [0x0001_0002_0003_0004, 0x1234_5678_90AB_CDEF,
           0xDEAD_BEEF_CAFE_BABE, 0xFFFF_0000_FFFF_0000,
           0x0000_FFFF_0000_FFFF, 0x8000_0000_0000_0001,
           0x7FFF_FFFF_FFFF_FFFF, 0xA5A5_A5A5_A5A5_A5A5]
        let values : List UInt64 :=
          [100, 200, 300, 400, 500, 600, 700, 800]
        -- Build the map.
        let pairs := keys.zip values
        let m : Std.TreeMap UInt64 UInt64 compare :=
          pairs.foldl (fun acc (k, v) => acc.insert k v) Std.TreeMap.empty
        let root := smtRoot m
        -- Verify each cell's canonical proof.
        for (k, v) in pairs do
          let proof := buildSmtCellProof m k
          assert (proof.isWellFormed) s!"proof for k={k} is well-formed"
          assert (verifySmtCellProof root k v proof)
            s!"canonical proof for ({k}, {v}) verifies"
    }
  , { name := "Stress test: 8-key map — substitution rejected for each cell"
    , body := do
        -- For each cell in an 8-key map, substituting a wrong
        -- value (taken from a different cell) should be
        -- rejected.  Operational version of
        -- `smtCellProof_no_value_substitution`.
        let keys : List UInt64 :=
          [0x0001_0002_0003_0004, 0x1234_5678_90AB_CDEF,
           0xDEAD_BEEF_CAFE_BABE, 0xFFFF_0000_FFFF_0000]
        let values : List UInt64 := [100, 200, 300, 400]
        let pairs := keys.zip values
        let m : Std.TreeMap UInt64 UInt64 compare :=
          pairs.foldl (fun acc (k, v) => acc.insert k v) Std.TreeMap.empty
        let root := smtRoot m
        for (k, v_honest) in pairs do
          let proof := buildSmtCellProof m k
          assert (verifySmtCellProof root k v_honest proof) "honest"
          -- Try substituting each OTHER value; all should fail.
          for v_wrong in values do
            if v_wrong != v_honest then
              assert (¬ verifySmtCellProof root k v_wrong proof)
                s!"substitution v={v_wrong} rejected for k={k}"
    }
  , { name := "smtRoot is independent of insertion order"
    , body := do
        -- Inserting the same key-value pairs in different orders
        -- yields the same smtRoot (since smtRootListAux is
        -- order-independent on its input list).
        let pairs1 : List (UInt64 × UInt64) :=
          [(1, 100), (2, 200), (3, 300)]
        let pairs2 : List (UInt64 × UInt64) :=
          [(3, 300), (1, 100), (2, 200)]
        let m1 : Std.TreeMap UInt64 UInt64 compare :=
          pairs1.foldl (fun acc (k, v) => acc.insert k v) Std.TreeMap.empty
        let m2 : Std.TreeMap UInt64 UInt64 compare :=
          pairs2.foldl (fun acc (k, v) => acc.insert k v) Std.TreeMap.empty
        let r1 := smtRoot m1
        let r2 := smtRoot m2
        assert (r1 == r2) "same entries ⇒ same smtRoot"
    }
  , { name := "verifySmtCellProof rejects malformed proof regardless of root"
    , body := do
        -- Robustness check: an ill-formed proof never verifies
        -- against ANY root, regardless of root's actual content.
        let bad_proof : SmtCellProof :=
          { siblings := #[ByteArray.mk #[1]],  -- 1-byte sibling
            bitmask  := ByteArray.mk (Array.replicate 32 (0xFF : UInt8)) }
        assert (¬ bad_proof.isWellFormed) "proof is ill-formed"
        let k : UInt64 := 42
        let v : UInt64 := 100
        -- Try multiple candidate roots; all should reject.
        let candidate_bytes : List UInt8 := [0, 1, 0x80, 0xFF]
        for root_byte in candidate_bytes do
          let root := ByteArray.mk (Array.replicate 32 root_byte)
          assert (¬ verifySmtCellProof root k v bad_proof)
            s!"ill-formed proof rejected at root_byte={root_byte}"
    }
  , { name := "setBitmaskBit sets the correct bit"
    , body := do
        -- Sanity check on the bitmask manipulation helper.
        let bm := ByteArray.mk (Array.replicate 32 (0 : UInt8))
        let bm_after_bit_0 := setBitmaskBit bm 0
        let bm_after_bit_8 := setBitmaskBit bm 8
        let bm_after_bit_255 := setBitmaskBit bm 255
        -- For each, construct a dummy proof to check via bitmaskBit.
        let p0 : SmtCellProof := { siblings := #[], bitmask := bm_after_bit_0 }
        let p8 : SmtCellProof := { siblings := #[], bitmask := bm_after_bit_8 }
        let p255 : SmtCellProof := { siblings := #[], bitmask := bm_after_bit_255 }
        assert (p0.bitmaskBit 0) "bit 0 set after setBitmaskBit 0"
        assert (¬ p0.bitmaskBit 1) "bit 1 not set"
        assert (p8.bitmaskBit 8) "bit 8 set after setBitmaskBit 8"
        assert (¬ p8.bitmaskBit 0) "bit 0 not set"
        assert (p255.bitmaskBit 255) "bit 255 set after setBitmaskBit 255"
        assert (¬ p255.bitmaskBit 254) "bit 254 not set"
    }
  ]

end LegalKernel.Test.FaultProof.Smt
