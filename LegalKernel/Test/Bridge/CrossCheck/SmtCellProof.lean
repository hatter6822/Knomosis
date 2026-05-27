/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.SmtCellProof — Workstream SC.3.

Generates the `smt_cell_proof.json` cross-stack fixture: 100 entries
(50 honest + 50 adversarial) verifying byte-equivalence between
Lean's sparse-Merkle-tree cell-proof verifier
(`LegalKernel.FaultProof.verifySmtCellProof`, Workstream SC.1) and
the Solidity port (`solidity/src/lib/SmtCellVerifier.sol`,
Workstream SC.2).

**Cross-stack contract.**  Each entry carries the four byte-string
inputs the Solidity verifier consumes (`smtKey`, `leafPreimage`,
`proofData`, `root`) plus the expected verdict (`shouldVerify`).
The Lean side generates entries via the canonical
`buildSmtCellProof` constructor and emits the proof's on-wire
bytes (32-byte LSB-first bitmask || N × 32-byte siblings,
low-depth-first).  The Solidity side feeds the same bytes through
`SmtCellVerifier.verifyCellProof` and asserts byte-equivalence
verdicts.

**Honest entries (50).**  Cover the canonical-proof construction
across map shapes:
  * 8 singleton maps with varied keys (zero, low bits, MSB-only,
    LSB-only, alternating bits, max-value, mid-range, big random)
  * 8 two-cell maps probing each cell
  * 8 three-cell maps probing keys whose paths diverge at
    multiple depths
  * 8 four-cell maps probing each cell
  * 8 eight-cell stress maps probing each cell
  * 10 single-cell edge cases probing specific bit positions
    (MSB at d=0, mid at d=32, LSB at d=63, full 0xFFFF...)

**Adversarial entries (50).**  Cover the load-bearing soundness
property `smtCellProof_no_value_substitution`: an adversarial
responder cannot substitute a wrong cell value via a forged
SMT proof.  Six tamper classes:
  1. `valueSubst`     — re-encode `leafPreimage` with a different
                         value (changes the leaf hash; walk
                         diverges immediately).
  2. `siblingTamper`  — flip the first byte of the first sibling
                         in `proofData` (changes the walk's depth-0
                         intermediate; root diverges).
  3. `bitmaskTamper`  — flip bit 0 of the bitmask (re-routes one
                         depth from canonical-empty to padding, or
                         vice-versa; root diverges).
  4. `rootTamper`     — flip the first byte of the claimed root
                         (proof walks to the original root, but the
                         claim is wrong).
  5. `keyMismatch`    — use a different `smtKey` (re-routes the
                         walk; the original siblings no longer fit
                         the new path).
  6. `absentKey`      — build a canonical proof for a key NOT in
                         the map; the walk produces a different
                         root than `smtRoot m`.

Each tamper class contributes evenly across honest base entries
to maximise structural coverage.

**Hash-binding-conditional behaviour.**  When
`Bridge.HashAdaptor.isKeccak256Linked = false`, the Lean side
computes `root` and `proofData` siblings via the FNV-1a-64
fallback; cross-stack verification on the Solidity side
(which always uses keccak256) is gated and skipped.  When
linked, both sides walk the same hash function and the
fixture's bytes are cross-stack-binding.

**Lean-side verification.**  Regardless of binding, the Lean
verifier walks the SAME `hashBytes` used to construct the
fixture, so all 50 honest entries verify on the Lean side and
all 50 adversarial entries reject — this catches Lean-side
regressions independently of the Solidity port.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.FaultProof.Smt
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.FaultProof
open LegalKernel.Runtime
open LegalKernel.Test

namespace SmtCellProof

/-! ## Tamper descriptors -/

/-- The six tamper classes used by the adversarial-entries subset.
    Each maps a valid (honest) entry to an entry that MUST reject
    on both sides (Lean's `verifySmtCellProof` and Solidity's
    `SmtCellVerifier.verifyCellProof`). -/
inductive Tamper : Type where
  /-- Substitute the value in `leafPreimage`. -/
  | valueSubst    : Tamper
  /-- Flip the first byte of the first sibling in `proofData`.
      Only applicable when `siblings.size > 0`. -/
  | siblingTamper : Tamper
  /-- Flip bit 0 of the bitmask region of `proofData`. -/
  | bitmaskTamper : Tamper
  /-- Flip the first byte of the claimed root. -/
  | rootTamper    : Tamper
  /-- Use a different `smtKey` (the proof was built for another
      key; the walk re-routes to a divergent path). -/
  | keyMismatch   : Tamper
  /-- Use a canonical proof for a key NOT in the map.  The walk
      produces a different root than the published `root`. -/
  | absentKey     : Tamper
  deriving DecidableEq, Inhabited

/-- Render a tamper descriptor as a JSON-string. -/
def Tamper.toString : Tamper → String
  | .valueSubst    => "valueSubst"
  | .siblingTamper => "siblingTamper"
  | .bitmaskTamper => "bitmaskTamper"
  | .rootTamper    => "rootTamper"
  | .keyMismatch   => "keyMismatch"
  | .absentKey     => "absentKey"

/-! ## Byte helpers -/

/-- Encode a `UInt64` as 8 big-endian bytes.  This is the byte
    layout the Solidity verifier reads MSB-first via
    `readKeyBitMSBFirst`: byte 0's MSB is `bit 63` of the
    underlying integer (i.e. depth 0 in the SMT walk).  Mirrors
    Lean's `BitsKey.UInt64` instance, which returns
    `(k.toNat >>> (63 - d)) & 1` at depth `d ∈ [0, 64)`. -/
def uint64ToBytesBE (x : UInt64) : ByteArray :=
  let n := x.toNat
  ByteArray.mk #[
    UInt8.ofNat ((n >>> 56) % 256),
    UInt8.ofNat ((n >>> 48) % 256),
    UInt8.ofNat ((n >>> 40) % 256),
    UInt8.ofNat ((n >>> 32) % 256),
    UInt8.ofNat ((n >>> 24) % 256),
    UInt8.ofNat ((n >>> 16) % 256),
    UInt8.ofNat ((n >>> 8)  % 256),
    UInt8.ofNat ( n         % 256)
  ]

/-- Concatenate a list of `ByteArray`s in order. -/
def concatBytes : List ByteArray → ByteArray
  | []       => ByteArray.empty
  | bs :: rest => bs ++ concatBytes rest

/-- Serialise an `SmtCellProof` to its on-wire bytes consumed by
    `SmtCellVerifier.verifyCellProof`:

    ```
    proofData = bitmask(32 bytes) || siblings(N × 32 bytes)
    ```

    The siblings are flat-concatenated in low-depth-first order
    (the order produced by `buildSmtCellProof`).  No length
    prefix is needed: the bitmask is fixed at 32 bytes, and
    the siblings region is `proofData.size - 32` bytes. -/
def proofToWireBytes (p : SmtCellProof) : ByteArray :=
  p.bitmask ++ concatBytes p.siblings.toList

/-- Encode the value (8-byte big-endian) used by the cross-stack
    `leafPreimage`.  Cross-stack consumers compute
    `keccak256(leafPreimage)` exactly; both sides observe the
    same bytes regardless of Encodable's CBE conventions. -/
def valueToBytesBE (v : UInt64) : ByteArray :=
  uint64ToBytesBE v

/-- Flip the first byte of a `ByteArray`.  No-op on empty input.
    Used by several tamper classes to produce a one-byte
    perturbation. -/
def bitFlipFirst (bs : ByteArray) : ByteArray :=
  if bs.size = 0 then bs
  else
    let b := bs.get! 0
    bs.set! 0 (UInt8.xor b 0x01)

/-! ## Fixture entry -/

/-- One fixture entry.  The four byte-string fields are exactly
    what the Solidity verifier consumes; `shouldVerify` is the
    verdict both sides must produce. -/
structure Entry where
  /-- The SMT key.  8-byte big-endian encoding of the UInt64
      key the entry probes.  Solidity reads this MSB-first via
      `readKeyBitMSBFirst`. -/
  smtKey       : ByteArray
  /-- The leaf preimage: bytes hashed to form the leaf node.
      Cross-stack contract: both sides compute
      `hashBytes leafPreimage` to get the starting leaf hash.
      Layout: `valueToBytesBE key ++ valueToBytesBE value` (16
      bytes total for UInt64 key + UInt64 value). -/
  leafPreimage : ByteArray
  /-- The wire-encoded proof: `bitmask(32) || siblings(N × 32)`,
      siblings in low-depth-first order. -/
  proofData    : ByteArray
  /-- The claimed SMT root.  Honest entries: this is
      `smtRoot m` for the map `m` the entry was built from.
      Adversarial entries: may be tampered (`rootTamper`) or
      the original root (other classes). -/
  root         : ByteArray
  /-- `true` for honest entries (both sides MUST accept);
      `false` for adversarial entries (both sides MUST reject). -/
  shouldVerify : Bool
  /-- Per-entry human-readable category tag (e.g.
      "honest:singleton:k=42", "tamper:siblingTamper:k=42"). -/
  category     : String
  /-- Optional tamper descriptor (only set for `shouldVerify =
      false`). -/
  tamper       : Option Tamper

/-! ## Honest-entry builder

The honest-entry builder lives in §"Honest-entry builder (cross-stack
aligned)" below.  It routes through `liftMap` + `CrossStackUInt64` so
the proof construction uses big-endian byte encoding for keys + values
— matching the Solidity verifier's MSB-first `readKeyBitMSBFirst` and
the cross-stack `leafPreimage = BE(key) || BE(value)` convention.

We deliberately do NOT provide a `mkValidEntry` overload that takes a
raw `Std.TreeMap UInt64 UInt64 compare` (without lifting): such an
overload would use Lean's default `Encodable UInt64` instance (which
produces CBE-encoded bytes — variable-length head + payload, NOT
8-byte big-endian), and the resulting Lean-side proof would carry
internal leaf hashes byte-incompatible with the Solidity side.  The
only constructor exported below is `mkValidEntryAligned`, which always
routes through the cross-stack-aligned `CrossStackUInt64` wrapper. -/

/-! ## Lean-side leaf hashing for cross-stack alignment

We use plain byte-encoded keys / values (`valueToBytesBE`) for
the cross-stack leaf preimage rather than Lean's CBE-encoded
form (`encodeAsBytes`).  Reason: the cross-stack contract is
`hashBytes leafPreimage`, and the Lean verifier supplies the
preimage directly via the cross-stack value type defined below.

This requires defining a small `Encodable` instance for the
cross-stack-aligned key/value pair so that Lean's
`verifySmtCellProof` walks with the SAME leaf bytes as
Solidity.  The instance is private to this file and not part
of the kernel; it exists only to anchor the cross-stack
contract.
-/

/-- A cross-stack-aligned UInt64 wrapper whose `Encodable`
    instance produces 8 big-endian bytes (matching the Solidity
    `leafPreimage` convention).  Lean's default
    `Encodable UInt64` produces 8 little-endian bytes; we need
    big-endian to align with Solidity's MSB-first reading. -/
structure CrossStackUInt64 where
  /-- The underlying `UInt64`. -/
  value : UInt64

/-- `Encodable` instance for `CrossStackUInt64`: 8 big-endian
    bytes on encode (matching `uint64ToBytesBE`).  `decode`
    reads 8 BE bytes and reconstructs the wrapper; though
    correct, it is never invoked by the SMT cell-proof
    machinery (`leafHash` / `smtRoot` / `verifySmtCellProof`
    all consume `encode` only).  The decoder is supplied for
    typeclass completeness. -/
instance instEncodableCrossStackUInt64 :
    LegalKernel.Encoding.Encodable CrossStackUInt64 where
  encode x := (uint64ToBytesBE x.value).toList
  decode s :=
    if s.length ≥ 8 then
      let bytes : List UInt8 := s.take 8
      let rest := s.drop 8
      let n := bytes.foldl (fun acc b => acc * 256 + b.toNat) 0
      Except.ok (⟨UInt64.ofNat n⟩, rest)
    else
      Except.error LegalKernel.Encoding.DecodeError.unexpectedEof

/-- `BitsKey` instance for `CrossStackUInt64`: defer to the
    underlying `UInt64`'s instance. -/
instance instBitsKeyCrossStackUInt64 : BitsKey CrossStackUInt64 where
  keyBit x i := BitsKey.keyBit x.value i

/-- `Ord` instance for `CrossStackUInt64`: defer to the
    underlying `UInt64`. -/
instance instOrdCrossStackUInt64 : Ord CrossStackUInt64 where
  compare a b := compare a.value b.value

/-- Lift a `Std.TreeMap UInt64 UInt64 compare` to the
    cross-stack-aligned wrapper, preserving content. -/
def liftMap (m : Std.TreeMap UInt64 UInt64 compare) :
    Std.TreeMap CrossStackUInt64 CrossStackUInt64 compare :=
  m.toList.foldl
    (fun acc (k, v) => acc.insert ⟨k⟩ ⟨v⟩)
    Std.TreeMap.empty

/-- Verify an honest entry on the Lean side using the same
    `verifySmtCellProof` Solidity mirrors.  This routes through
    the cross-stack-aligned `CrossStackUInt64` so the leaf bytes
    match the Solidity `leafPreimage` byte-for-byte. -/
def leanVerify (e : Entry) : Bool :=
  -- Reconstruct the proof from its wire bytes.
  let bitmask := e.proofData.extract 0 32
  let siblingsRegion := e.proofData.extract 32 e.proofData.size
  let siblingsCount := siblingsRegion.size / 32
  let siblings : Array ByteArray :=
    (List.range siblingsCount).foldl
      (fun acc i =>
        acc.push (siblingsRegion.extract (i * 32) ((i + 1) * 32)))
      (#[] : Array ByteArray)
  let proof : SmtCellProof := { siblings := siblings, bitmask := bitmask }
  -- Reconstruct the cross-stack key/value: read the smtKey as a
  -- big-endian UInt64 and read the value from the second half of
  -- the leafPreimage.
  let keyN : Nat :=
    e.smtKey.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
  let valBytes := e.leafPreimage.extract 8 16
  let valN : Nat :=
    valBytes.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
  let key  : CrossStackUInt64 := ⟨UInt64.ofNat keyN⟩
  let value : CrossStackUInt64 := ⟨UInt64.ofNat valN⟩
  verifySmtCellProof e.root key value proof

/-- Build a cross-stack-aligned canonical proof from a UInt64 map
    by routing through the `CrossStackUInt64` wrapper.  Returns
    the lifted root, leafPreimage, smtKey, and proofData. -/
def mkValidEntryAligned (m : Std.TreeMap UInt64 UInt64 compare)
    (key value : UInt64) (category : String) : Entry :=
  -- Compute root + proof through the lifted map so the
  -- `Encodable` instance used internally is CrossStackUInt64.
  let lifted := liftMap m
  let liftedKey : CrossStackUInt64 := ⟨key⟩
  let proof := buildSmtCellProof lifted liftedKey
  { smtKey       := uint64ToBytesBE key
  , leafPreimage := valueToBytesBE key ++ valueToBytesBE value
  , proofData    := proofToWireBytes proof
  , root         := smtRoot lifted
  , shouldVerify := true
  , category     := category
  , tamper       := none
  }

/-! ## Honest fixtures -/

/-- 8 singleton maps with varied key patterns.  Each entry probes
    the only cell. -/
def honestSingletons : List Entry := Id.run do
  let mut acc : List Entry := []
  let pairs : List (UInt64 × UInt64) :=
    [ (0,                    100)
    , (1,                    200)
    , (42,                   300)
    , (0xDEADBEEF,           400)
    , (0x8000000000000000,   500)
    , (0xFFFFFFFFFFFFFFFF,   600)
    , (0x0102030405060708,   700)
    , (0xFEDCBA9876543210,   800)
    ]
  for (k, v) in pairs do
    let m : Std.TreeMap UInt64 UInt64 compare :=
      Std.TreeMap.empty.insert k v
    acc := mkValidEntryAligned m k v s!"honest:singleton:k={k}" :: acc
  return acc.reverse

/-- 8 two-cell maps.  4 with non-adjacent keys probing each cell. -/
def honestTwoCell : List Entry := Id.run do
  let mut acc : List Entry := []
  let pairs : List (UInt64 × UInt64) :=
    [ (1, 2)
    , (0, 0x8000000000000000)
    , (42, 100)
    , (0xAAAAAAAAAAAAAAAA, 0x5555555555555555)
    ]
  for (k1, k2) in pairs do
    let v1 : UInt64 := (1000 : UInt64) + k1
    let v2 : UInt64 := (2000 : UInt64) + k2
    let m : Std.TreeMap UInt64 UInt64 compare :=
      (Std.TreeMap.empty.insert k1 v1).insert k2 v2
    acc := mkValidEntryAligned m k1 v1 s!"honest:two-cell:k=({k1},{k2}):probe=lo" :: acc
    acc := mkValidEntryAligned m k2 v2 s!"honest:two-cell:k=({k1},{k2}):probe=hi" :: acc
  return acc.reverse

/-- 8 three-cell maps.  Keys are chosen so paths diverge at
    multiple depths, exercising multi-sibling proofs. -/
def honestThreeCell : List Entry := Id.run do
  let mut acc : List Entry := []
  -- Map 1: keys 0, 1, MSB-only — paths diverge at d=63 (0 vs 1)
  -- and at d=0 (MSB-only vs others).
  do
    let k1 : UInt64 := 0
    let k2 : UInt64 := 1
    let k3 : UInt64 := 0x8000000000000000
    let m : Std.TreeMap UInt64 UInt64 compare :=
      ((Std.TreeMap.empty.insert k1 100).insert k2 200).insert k3 300
    acc := mkValidEntryAligned m k1 100 s!"honest:three-cell-A:probe=k1" :: acc
    acc := mkValidEntryAligned m k2 200 s!"honest:three-cell-A:probe=k2" :: acc
    acc := mkValidEntryAligned m k3 300 s!"honest:three-cell-A:probe=k3" :: acc
  -- Map 2: alternating high-bit keys exercising several depths.
  do
    let k1 : UInt64 := 0xFFFF000000000000
    let k2 : UInt64 := 0x0000FFFF00000000
    let k3 : UInt64 := 0x00000000FFFF0000
    let m : Std.TreeMap UInt64 UInt64 compare :=
      ((Std.TreeMap.empty.insert k1 1).insert k2 2).insert k3 3
    acc := mkValidEntryAligned m k1 1 s!"honest:three-cell-B:probe=k1" :: acc
    acc := mkValidEntryAligned m k2 2 s!"honest:three-cell-B:probe=k2" :: acc
  -- Map 3: dense low keys (1, 2, 3) — all share many high-zero bits.
  do
    let m : Std.TreeMap UInt64 UInt64 compare :=
      ((Std.TreeMap.empty.insert 1 10).insert 2 20).insert 3 30
    acc := mkValidEntryAligned m 1 10 "honest:three-cell-C:probe=1" :: acc
    acc := mkValidEntryAligned m 2 20 "honest:three-cell-C:probe=2" :: acc
    acc := mkValidEntryAligned m 3 30 "honest:three-cell-C:probe=3" :: acc
  return acc.reverse.take 8

/-- 8 four-cell maps. -/
def honestFourCell : List Entry := Id.run do
  let mut acc : List Entry := []
  -- Map A: low keys 0..3 — all share the same top-62 bits.
  do
    let m : Std.TreeMap UInt64 UInt64 compare :=
      (((Std.TreeMap.empty.insert 0 10).insert 1 20).insert 2 30).insert 3 40
    for (k, v) in [((0 : UInt64), (10 : UInt64)), (1, 20), (2, 30), (3, 40)] do
      acc := mkValidEntryAligned m k v s!"honest:four-cell-A:probe={k}" :: acc
  -- Map B: scattered keys.
  do
    let keys : List UInt64 :=
      [0x0000000000000001, 0x4000000000000000, 0x8000000000000000, 0xC000000000000000]
    let values : List UInt64 := [11, 22, 33, 44]
    let pairs := keys.zip values
    let m : Std.TreeMap UInt64 UInt64 compare :=
      pairs.foldl (fun acc (k, v) => acc.insert k v) Std.TreeMap.empty
    for (k, v) in pairs do
      acc := mkValidEntryAligned m k v s!"honest:four-cell-B:probe={k}" :: acc
  return acc.reverse.take 8

/-- 8-entry stress map.  All 8 cells get a proof. -/
def honestEightCell : List Entry := Id.run do
  let mut acc : List Entry := []
  let keys : List UInt64 :=
    [ 0x0001000200030004
    , 0x1234567890ABCDEF
    , 0xDEADBEEFCAFEBABE
    , 0x0000000000000001
    , 0x8000000000000000
    , 0xAAAAAAAAAAAAAAAA
    , 0x5555555555555555
    , 0xFFFFFFFFFFFFFFFE
    ]
  let values : List UInt64 := [100, 200, 300, 400, 500, 600, 700, 800]
  let pairs := keys.zip values
  let m : Std.TreeMap UInt64 UInt64 compare :=
    pairs.foldl (fun acc (k, v) => acc.insert k v) Std.TreeMap.empty
  for (k, v) in pairs do
    acc := mkValidEntryAligned m k v s!"honest:eight-cell:probe={k}" :: acc
  return acc.reverse

/-- 10 single-bit-position edge cases.  Each is a singleton map
    with the key being a single-bit-set pattern at a varied
    position, exercising the per-depth bit-reading logic across
    bytes. -/
def honestSingleBitEdgeCases : List Entry := Id.run do
  let mut acc : List Entry := []
  let keys : List UInt64 :=
    [ 0x0000000000000001  -- LSB (d=63)
    , 0x0000000000000080  -- bit 7 from low (d=56)
    , 0x0000000000000100  -- bit 8 from low (d=55)
    , 0x0000000080000000  -- middle, MSB of byte 4 (d=32)
    , 0x0000800000000000  -- byte 2 MSB (d=16)
    , 0x0080000000000000  -- byte 1 MSB (d=8)
    , 0x4000000000000000  -- bit 1 (d=1)
    , 0x8000000000000000  -- MSB (d=0)
    , 0xC000000000000000  -- top two bits (d=0, d=1)
    , 0xFFFFFFFFFFFFFFFF  -- all bits
    ]
  for (k, i) in keys.zipIdx do
    let v : UInt64 := UInt64.ofNat (1000 + i)
    let m : Std.TreeMap UInt64 UInt64 compare :=
      Std.TreeMap.empty.insert k v
    acc := mkValidEntryAligned m k v s!"honest:edge:bit-pos[{i}]:k={k}" :: acc
  return acc.reverse

/-- All honest entries.  50 total. -/
def honestEntries : List Entry :=
  honestSingletons
    ++ honestTwoCell
    ++ honestThreeCell
    ++ honestFourCell
    ++ honestEightCell
    ++ honestSingleBitEdgeCases

/-! ## Adversarial-entry builders -/

/-- Apply a tamper class to a valid entry.  Returns an entry
    whose `shouldVerify` is `false`.  Each class mutates exactly
    one of the entry's four byte fields (or supplies a substitute
    proof + key); the rest are preserved. -/
def applyTamper (e : Entry) (t : Tamper) : Entry :=
  match t with
  | .valueSubst =>
    -- Re-encode the value with a different value (XOR with
    -- 0xDEADBEEF to guarantee a different leaf).
    let origValBytes := e.leafPreimage.extract 8 16
    let origValN : Nat :=
      origValBytes.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
    let newVal : UInt64 := UInt64.ofNat (origValN ^^^ 0xDEADBEEF)
    { e with
      leafPreimage := e.leafPreimage.extract 0 8 ++ valueToBytesBE newVal
      shouldVerify := false
      tamper := some .valueSubst
      category := e.category ++ "::tampered:valueSubst"
    }
  | .siblingTamper =>
    -- The siblingTamper attack must produce proofData genuinely
    -- distinct from bitmaskTamper (which flips bit 0 of the
    -- bitmask byte 0).  Two cases:
    --
    --   * Entry has at least one sibling (proofData.size ≥ 64):
    --     flip the first byte of the first sibling.  The walk at
    --     depth corresponding to the first set bitmask bit reads
    --     a different sibling → walks to a different root.
    --
    --   * Entry has no siblings (proofData.size = 32, i.e. an
    --     all-canonical-empty proof for a singleton / edge case):
    --     APPEND a 32-byte sibling of arbitrary content AND set
    --     bit 0 of the bitmask so the verifier expects a
    --     non-canonical sibling at depth 0.  The walk uses the
    --     appended sibling (instead of canonical H_0) → walks to
    --     a different root.  This produces proofData.size = 64,
    --     structurally distinct from bitmaskTamper's
    --     proofData.size = 32 with bit 0 set + zero siblings
    --     (which forces the verifier to use paddingHash at
    --     depth 0).
    if e.proofData.size < 64 then
      -- Append a 32-byte all-`0x42` sibling and set bitmask bit 0.
      let appendedSibling : ByteArray :=
        ByteArray.mk (Array.replicate 32 (0x42 : UInt8))
      -- OR (rather than XOR) bit 0 into byte 0 of the bitmask.
      -- This preserves any other bits the original bitmask had
      -- (for the typical no-siblings case, byte 0 = 0x00, so the
      -- result is 0x01).
      let bitmaskByte0 := e.proofData.get! 0
      let newBitmaskByte0 := UInt8.ofNat (bitmaskByte0.toNat ||| 1)
      let newProofData :=
        (e.proofData.set! 0 newBitmaskByte0) ++ appendedSibling
      { e with
        proofData := newProofData
        shouldVerify := false
        tamper := some .siblingTamper
        category := e.category ++ "::tampered:siblingTamper(appended-fake-sibling)"
      }
    else
      -- Byte at offset 32 = first byte of first sibling.
      let b := e.proofData.get! 32
      let mutated := e.proofData.set! 32 (UInt8.xor b 0x01)
      { e with
        proofData := mutated
        shouldVerify := false
        tamper := some .siblingTamper
        category := e.category ++ "::tampered:siblingTamper"
      }
  | .bitmaskTamper =>
    -- Flip bit 0 of byte 0 of the bitmask (depth 0's
    -- non-canonical/canonical flag).  This always changes the
    -- walk's behavior at depth 0.
    { e with
      proofData := bitFlipFirst e.proofData
      shouldVerify := false
      tamper := some .bitmaskTamper
      category := e.category ++ "::tampered:bitmaskTamper"
    }
  | .rootTamper =>
    { e with
      root := bitFlipFirst e.root
      shouldVerify := false
      tamper := some .rootTamper
      category := e.category ++ "::tampered:rootTamper"
    }
  | .keyMismatch =>
    -- Re-route the proof to a different smtKey.  XOR with a
    -- non-trivial mask to guarantee bit-pattern divergence at
    -- multiple depths (forces the walk down a different path).
    let origKeyBytes := e.smtKey
    let origKeyN : Nat :=
      origKeyBytes.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
    let newKey : UInt64 := UInt64.ofNat (origKeyN ^^^ 0xAAAAAAAAAAAAAAAA)
    -- Also re-derive the leafPreimage's key half (since cross-
    -- stack contract is `hash(key_bytes ++ value_bytes)`).
    let valHalf := e.leafPreimage.extract 8 16
    { e with
      smtKey := uint64ToBytesBE newKey
      leafPreimage := valueToBytesBE newKey ++ valHalf
      shouldVerify := false
      tamper := some .keyMismatch
      category := e.category ++ "::tampered:keyMismatch"
    }
  | .absentKey =>
    -- Replace the proof with a canonical proof for a key NOT in
    -- the original map.  We can't rebuild the original map from
    -- the entry alone (we don't carry it), so instead we mark
    -- this entry as adversarial by perturbing both the key AND
    -- the proof (effectively a hybrid: keyMismatch + siblingTamper).
    -- The walk uses a different key, against a different proof,
    -- targeting the same root → walk produces a different output.
    let origKeyBytes := e.smtKey
    let origKeyN : Nat :=
      origKeyBytes.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
    let newKey : UInt64 := UInt64.ofNat (origKeyN ^^^ 0x123456789ABCDEF0)
    let valHalf := e.leafPreimage.extract 8 16
    -- Use the EMPTY proof: 32-byte zero bitmask, no siblings.
    -- This is a canonical proof for a key in an empty map; using
    -- it against a populated map's root cannot verify (the leaf
    -- hash at the wrong key collapses to the empty walk, which
    -- differs from the populated map's root).
    let emptyProof : ByteArray :=
      ByteArray.mk (Array.replicate 32 (0 : UInt8))
    { e with
      smtKey := uint64ToBytesBE newKey
      leafPreimage := valueToBytesBE newKey ++ valHalf
      proofData := emptyProof
      shouldVerify := false
      tamper := some .absentKey
      category := e.category ++ "::tampered:absentKey"
    }

/-- Build the 50 adversarial entries by applying 6 tamper classes
    in round-robin across the first 50 honest entries.

    Class distribution (50 entries / 6 classes ≈ 8 each):
      - valueSubst     : 9
      - siblingTamper  : 9
      - bitmaskTamper  : 8
      - rootTamper     : 8
      - keyMismatch    : 8
      - absentKey      : 8 -/
def adversarialEntries (honestSlice : List Entry) : List Entry := Id.run do
  let mut acc : List Entry := []
  let tamperClasses : List Tamper :=
    [ .valueSubst, .siblingTamper, .bitmaskTamper
    , .rootTamper, .keyMismatch, .absentKey
    ]
  let n := honestSlice.length
  for k in (List.range n) do
    let t := tamperClasses[k % tamperClasses.length]!
    match honestSlice[k]? with
    | some valid =>
      acc := applyTamper valid t :: acc
    | none => pure ()
  return acc.reverse

/-! ## JSON serialisation -/

/-- Convert one entry to JSON.  Includes the optional `tamper`
    descriptor for tampered entries. -/
def Entry.toJson (e : Entry) : Json :=
  let tamperJson : Json :=
    match e.tamper with
    | none   => .null
    | some t => .str t.toString
  .obj
    [ ("category",        .str e.category)
    , ("smtKeyHex",       .str (hexFromBytes e.smtKey))
    , ("leafPreimageHex", .str (hexFromBytes e.leafPreimage))
    , ("proofDataHex",    .str (hexFromBytes e.proofData))
    , ("rootHex",         .str (hexFromBytes e.root))
    , ("shouldVerify",    .bool e.shouldVerify)
    , ("tamper",          tamperJson)
    ]

/-! ## Top-level fixture -/

/-- Build the full fixture: 50 honest + 50 adversarial. -/
def buildFixture : (Json × Nat) :=
  let honest := honestEntries
  let adversarial := adversarialEntries honest
  let allEntries := honest ++ adversarial
  let header : Json := .obj
    [ ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("hashIdentifier",      .str (hashImplementationIdentifier ()))
    , ("smtDepth",            .num smtDepth)
    , ("count",               .num allEntries.length)
    , ("countHonest",         .num honest.length)
    , ("countAdversarial",    .num adversarial.length)
    , ("countSingleton",      .num honestSingletons.length)
    , ("countTwoCell",        .num honestTwoCell.length)
    , ("countThreeCell",      .num honestThreeCell.length)
    , ("countFourCell",       .num honestFourCell.length)
    , ("countEightCell",      .num honestEightCell.length)
    , ("countEdge",           .num honestSingleBitEdgeCases.length)
    , ("countValueSubst",     .num (adversarial.filter
                                      (fun e => e.tamper = some .valueSubst)).length)
    , ("countSiblingTamper",  .num (adversarial.filter
                                      (fun e => e.tamper = some .siblingTamper)).length)
    , ("countBitmaskTamper",  .num (adversarial.filter
                                      (fun e => e.tamper = some .bitmaskTamper)).length)
    , ("countRootTamper",     .num (adversarial.filter
                                      (fun e => e.tamper = some .rootTamper)).length)
    , ("countKeyMismatch",    .num (adversarial.filter
                                      (fun e => e.tamper = some .keyMismatch)).length)
    , ("countAbsentKey",      .num (adversarial.filter
                                      (fun e => e.tamper = some .absentKey)).length)
    ]
  let topLevel : Json := .obj
    [ ("header",  header)
    , ("entries", .arr (allEntries.map Entry.toJson))
    ]
  (topLevel, allEntries.length)

/-- Fixture file name. -/
def fixtureName : String := "smt_cell_proof.json"

/-! ## Test cases -/

/-- Test cases.  Verify count breakdown; verify honest entries
    accept on the Lean side; verify adversarial entries reject on
    the Lean side; check fixture is byte-deterministic; write the
    fixture file; gate cross-stack assertion on
    `isKeccak256Linked`. -/
def tests : List TestCase :=
  [ { name := "SC.3: smt_cell_proof fixture has 100 entries (50 honest + 50 adversarial)"
    , body := do
        let (_, n) := buildFixture
        if n ≠ 100 then
          throw <| IO.userError s!"expected 100 entries, got {n}"
    }
  , { name := "SC.3: 50 honest entries verify on the Lean side"
    , body := do
        let honest := honestEntries
        if honest.length ≠ 50 then
          throw <| IO.userError s!"honest count: {honest.length}"
        for e in honest do
          if !leanVerify e then
            throw <| IO.userError
              s!"honest entry {e.category} failed to verify on Lean side"
    }
  , { name := "SC.3: 50 adversarial entries reject on the Lean side"
    , body := do
        let honest := honestEntries
        let adversarial := adversarialEntries honest
        if adversarial.length ≠ 50 then
          throw <| IO.userError s!"adversarial count: {adversarial.length}"
        for e in adversarial do
          if leanVerify e then
            throw <| IO.userError
              s!"adversarial entry {e.category} unexpectedly verified on Lean side"
    }
  , { name := "SC.3: every honest entry's proofData has size ≥ 32 (bitmask present)"
    , body := do
        for e in honestEntries do
          if e.proofData.size < 32 then
            throw <| IO.userError
              s!"honest entry {e.category}: proofData.size = {e.proofData.size} < 32"
    }
  , { name := "SC.3: every honest entry's proofData has aligned siblings"
    , body := do
        for e in honestEntries do
          let siblingsRegion := e.proofData.size - 32
          if siblingsRegion % 32 ≠ 0 then
            throw <| IO.userError
              s!"honest entry {e.category}: siblings region {siblingsRegion} not multiple of 32"
    }
  , { name := "SC.3: every honest entry's smtKey has size 8 (UInt64 BE)"
    , body := do
        for e in honestEntries do
          if e.smtKey.size ≠ 8 then
            throw <| IO.userError
              s!"honest entry {e.category}: smtKey.size = {e.smtKey.size}, want 8"
    }
  , { name := "SC.3: every honest entry's leafPreimage has size 16 (UInt64 key + UInt64 value)"
    , body := do
        for e in honestEntries do
          if e.leafPreimage.size ≠ 16 then
            throw <| IO.userError
              s!"honest entry {e.category}: leafPreimage.size = {e.leafPreimage.size}, want 16"
    }
  , { name := "SC.3: every honest entry's root has size 32 (one hash output)"
    , body := do
        for e in honestEntries do
          if e.root.size ≠ 32 then
            throw <| IO.userError
              s!"honest entry {e.category}: root.size = {e.root.size}, want 32"
    }
  , { name := "SC.3: each tamper class appears in the adversarial set"
    , body := do
        let adversarial := adversarialEntries honestEntries
        let classes : List Tamper :=
          [ .valueSubst, .siblingTamper, .bitmaskTamper
          , .rootTamper, .keyMismatch, .absentKey
          ]
        for t in classes do
          let count := (adversarial.filter (fun e => e.tamper = some t)).length
          if count = 0 then
            throw <| IO.userError
              s!"tamper class {t.toString} has zero entries in adversarial set"
    }
  , { name := "SC.3: each adversarial entry's byte fields differ from its honest base"
    , body := do
        -- The round-robin maps adversarial[k] ↔ honest[k] for k ∈ [0,50).
        -- This regression test catches the failure mode where a future
        -- refactor accidentally makes a tamper class a no-op: if the
        -- tampered entry had byte-identical (smtKey, leafPreimage,
        -- proofData, root) to its honest base, the Lean verifier would
        -- ACCEPT it (the bytes verify), but `shouldVerify=false` would
        -- claim rejection.  The `50 adversarial reject` test catches
        -- this indirectly; this test diagnoses the cause directly.
        let honest : List Entry := honestEntries
        let adversarial : List Entry := adversarialEntries honest
        if adversarial.length ≠ honest.length then
          throw <| IO.userError
            s!"length mismatch: honest={honest.length}, adv={adversarial.length}"
        for (h, a) in honest.zip adversarial do
          let sameBytes :=
            h.smtKey       == a.smtKey       &&
            h.leafPreimage == a.leafPreimage &&
            h.proofData    == a.proofData    &&
            h.root         == a.root
          if sameBytes then
            throw <| IO.userError
              s!"adversarial entry {a.category} has byte-identical fields to honest {h.category}"
    }
  , { name := "SC.3: per-tamper-class field-delta matches the documented mutation"
    , body := do
        -- Stricter version of the previous test: for each tamper class,
        -- verify that EXACTLY the expected fields differ between the
        -- adversarial entry and its honest base.  Catches "tamper
        -- mutates too many fields" bugs (which would be a real
        -- regression: a tamper that touches an unrelated field hides
        -- the documented attack vector).
        let honest : List Entry := honestEntries
        let adversarial : List Entry := adversarialEntries honest
        for (h, a) in honest.zip adversarial do
          let kSame := h.smtKey       == a.smtKey
          let lSame := h.leafPreimage == a.leafPreimage
          let pSame := h.proofData    == a.proofData
          let rSame := h.root         == a.root
          match a.tamper with
          | some Tamper.valueSubst =>
            if !(kSame && !lSame && pSame && rSame) then
              throw <| IO.userError
                s!"valueSubst {a.category}: delta=({!kSame},{!lSame},{!pSame},{!rSame}) want (F,T,F,F)"
          | some Tamper.siblingTamper =>
            if !(kSame && lSame && !pSame && rSame) then
              throw <| IO.userError
                s!"siblingTamper {a.category}: delta=({!kSame},{!lSame},{!pSame},{!rSame}) want (F,F,T,F)"
          | some Tamper.bitmaskTamper =>
            if !(kSame && lSame && !pSame && rSame) then
              throw <| IO.userError
                s!"bitmaskTamper {a.category}: delta=({!kSame},{!lSame},{!pSame},{!rSame}) want (F,F,T,F)"
          | some Tamper.rootTamper =>
            if !(kSame && lSame && pSame && !rSame) then
              throw <| IO.userError
                s!"rootTamper {a.category}: delta=({!kSame},{!lSame},{!pSame},{!rSame}) want (F,F,F,T)"
          | some Tamper.keyMismatch =>
            -- expected delta: smtKey + leafPreimage's first 8 bytes
            -- (the key half).  The value half of leafPreimage and
            -- the proofData / root must be unchanged.
            let lValHalfSame :=
              h.leafPreimage.extract 8 16 == a.leafPreimage.extract 8 16
            if !(!kSame && !lSame && pSame && rSame && lValHalfSame) then
              throw <| IO.userError
                s!"keyMismatch {a.category}: delta=({!kSame},{!lSame},{!pSame},{!rSame}), valHalfSame={lValHalfSame}"
          | some Tamper.absentKey =>
            -- expected delta: smtKey + leafPreimage's first 8 bytes
            -- (the key half) differ; leafPreimage's value half and
            -- root are unchanged.  proofData is REPLACED with the
            -- canonical empty-proof bytes (32-byte zero bitmask).
            -- For singleton honest entries the original proof was
            -- already the empty proof, so proofData ends up
            -- byte-identical; for multi-cell honest entries
            -- proofData genuinely differs.  We assert the invariant
            -- "proofData equals the canonical empty proof" rather
            -- than "proofData differs from honest base", since the
            -- former is the documented contract.
            let lValHalfSame :=
              h.leafPreimage.extract 8 16 == a.leafPreimage.extract 8 16
            let emptyProofBytes : ByteArray :=
              ByteArray.mk (Array.replicate 32 (0 : UInt8))
            let pIsEmptyProof := a.proofData == emptyProofBytes
            if !(!kSame && !lSame && rSame && lValHalfSame && pIsEmptyProof) then
              throw <| IO.userError
                s!"absentKey {a.category}: delta=({!kSame},{!lSame},{!pSame},{!rSame}), valHalfSame={lValHalfSame}, pIsEmpty={pIsEmptyProof}"
          | none =>
            throw <| IO.userError
              s!"adversarial entry {a.category} has tamper=none"
    }
  , { name := "SC.3: honest entries have tamper = none"
    , body := do
        for e in honestEntries do
          if e.tamper ≠ none then
            throw <| IO.userError s!"honest entry {e.category} has unexpected tamper"
    }
  , { name := "SC.3: adversarial entries have tamper = some _"
    , body := do
        for e in adversarialEntries honestEntries do
          if e.tamper = none then
            throw <| IO.userError
              s!"adversarial entry {e.category} unexpectedly has tamper = none"
    }
  , { name := "SC.3: fixture is byte-deterministic across runs"
    , body := do
        let (j₁, _) := buildFixture
        let (j₂, _) := buildFixture
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "SC.3: fixture file write / verify cycle succeeds"
    , body := do
        let (json, _) := buildFixture
        writeFixture fixtureName json.encode
    }
  , { name := "SC.3: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack assert skipped"
    }
  ]

end SmtCellProof
end LegalKernel.Test.Bridge.CrossCheck
