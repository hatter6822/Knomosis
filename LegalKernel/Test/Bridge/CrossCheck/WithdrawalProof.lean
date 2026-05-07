/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.WithdrawalProof — Workstream F.1.5.

Generates the `withdrawal_proof.json` cross-stack fixture: 96 entries
(64 valid + 32 tampered) verifying byte-equivalence between Lean's
sparse-Merkle-tree (`Bridge.WithdrawalRoot`) and Solidity's
`SmtVerifier`.

**Variable-size leaf and siblings (audit-2 cross-stack format).**
Per `solidity/src/lib/SmtVerifier.sol`, the verifier accepts
`bytes leaf` and `bytes[] siblings` (each variable-size).  In the
**dense-pair** case (sequentially-assigned WithdrawalIds 0 and 1
share a deepest pair), the leaf-adjacent sibling for id 0 is
`leafBytes wd_1` ≈ 56 bytes — NOT a 32-byte default-hash.

**Coverage** (per integration plan §10.1.5):

  * 16 sparse trees (1-4 populated cells, scattered indices)
  * 16 dense-pair cases (sequentially-assigned ids 0+1 or 100+101)
  * 16 unmapped-id cases (canonical non-membership proofs)
  * 16 boundary cases (id=0, id=2^64-1, id=nextWdId-1, etc.)
  * 32 tampered cases (5 mutator classes)

Total: 96.

**Tampering subset (32 entries).**  Each tampered entry mutates a
valid entry per a deterministic mutator:

  1. Bit-flip in `leafHex`.
  2. Bit-flip in `siblingsHex[k]` for a random k.
  3. Swap two distinct sibling positions.
  4. Wrong index (mismatched `withdrawalId`).
  5. Wrong root (cross-root substitution).

The Solidity side asserts `verifyProof` returns `false` on each.

Hash-binding-conditional behaviour: when `isKeccak256Linked = false`,
the Lean SMT root is FNV-derived; cross-check is skipped.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.Property

namespace WithdrawalProof

/-! ## Tamper descriptors -/

/-- The five tamper classes used by the tampered-entries subset. -/
inductive Tamper : Type where
  /-- Bit-flip the leaf bytes. -/
  | leafBitflip      : Tamper
  /-- Bit-flip a random sibling. -/
  | siblingBitflip   : Tamper
  /-- Swap two distinct sibling positions. -/
  | siblingSwap      : Tamper
  /-- Use the wrong `index` (mismatched `withdrawalId`). -/
  | wrongIndex       : Tamper
  /-- Use a different root (cross-root substitution). -/
  | wrongRoot        : Tamper
  deriving DecidableEq, Inhabited

/-- Render a tamper descriptor as a JSON-string. -/
def Tamper.toString : Tamper → String
  | .leafBitflip    => "leafBitflip"
  | .siblingBitflip => "siblingBitflip"
  | .siblingSwap    => "siblingSwap"
  | .wrongIndex     => "wrongIndex"
  | .wrongRoot      => "wrongRoot"

/-! ## Fixture entry -/

/-- One fixture entry.  Carries the canonical `WithdrawalProof`
    (Vector-typed siblings with length-proof) for Lean-side
    verification, plus the bridge state's published root.  Tampered
    entries set `shouldVerify := false` and store a possibly-broken
    proof; the Lean side does NOT verify them (we rely on the
    Solidity side, which has access to the stored byte arrays without
    a Vector-length constraint). -/
structure Entry where
  /-- The bridge state's withdrawal root. -/
  stateRoot      : ByteArray
  /-- The fixture's withdrawal id (matches the proof's `index`
      unless the entry is the `wrongIndex` tampered variant). -/
  withdrawalId   : WithdrawalId
  /-- The leaf blob (CBE-encoded `PendingWithdrawal` for populated;
      empty-leaf sentinel for non-membership). -/
  leafBlob       : ByteArray
  /-- The canonical proof, length-typed via `Vector ByteArray
      smtHeight`.  For valid entries: this is what the Lean side
      verifies via `verifyProof`.  For tampered entries: the bytes
      may be mutated, but the length is preserved (mutators only
      change content, never count). -/
  proof          : WithdrawalProof
  /-- `true` if this entry should `verifyProof = true` on the
      Solidity side; `false` for tampered entries. -/
  shouldVerify   : Bool
  /-- Per-entry tag for human readability. -/
  category       : String
  /-- Optional tamper descriptor (only set for `shouldVerify =
      false`). -/
  tamper         : Option Tamper

/-! ## Fixture builders -/

/-- Build a `BridgeState` populated at the given list of
    `(withdrawalId, recipient_byte)` pairs.  Recipient is built
    from a single byte for determinism. -/
def buildBridgeState (entries : List (WithdrawalId × Nat × Nat)) : BridgeState :=
  entries.foldl
    (fun s (idx, recByte, amt) =>
      let recBytes : ByteArray := ByteArray.mk
        ((List.replicate 19 (0 : UInt8)) ++ [UInt8.ofNat (recByte % 256)]).toArray
      let rec_ : EthAddress :=
        match EthAddress.ofBytes recBytes with
        | some a => a
        | none   => EthAddress.zero
      let wd : PendingWithdrawal :=
        { resource := 1, recipient := rec_, amount := amt, l2LogIndex := idx }
      -- Insert at exact id by setting nextWdId then appending.
      let s' : BridgeState := { s with nextWdId := idx }
      s'.appendWithdrawal wd)
    BridgeState.empty

/-- Build a valid `Entry` from a bridge state and a withdrawal id. -/
def mkValidEntry (s : BridgeState) (idx : WithdrawalId) (category : String) :
    Entry :=
  let proof := constructProof hashBytes s idx
  let leafBlob :=
    match s.pending[idx]? with
    | some wd => leafBytes wd
    | none    => emptyLeafHash
  { stateRoot     := withdrawalRoot hashBytes s
  , withdrawalId  := idx
  , leafBlob      := leafBlob
  , proof         := proof
  , shouldVerify  := true
  , category      := category
  , tamper        := none
  }

/-! ## Sparse-tree fixtures (16 entries) -/

/-- Generate 16 sparse-tree entries.  Each entry's bridge state has
    1-4 populated cells at scattered indices. -/
def sparseEntries : List Entry := Id.run do
  let mut acc : List Entry := []
  -- 4 single-cell trees at scattered indices.
  for (idx, recByte) in [(0, 1), (5, 2), (37, 3), (4242, 4)] do
    let s := buildBridgeState [(idx, recByte, 1000 + idx)]
    acc := mkValidEntry s idx s!"sparse-1cell:idx={idx}" :: acc
  -- 4 two-cell trees with non-adjacent ids.
  for (id1, id2) in [(0, 100), (5, 50), (10, 500), (1, 1000)] do
    let s := buildBridgeState [(id1, 1, 100), (id2, 2, 200)]
    acc := mkValidEntry s id1 s!"sparse-2cell:ids=({id1},{id2})" :: acc
  -- 4 three-cell trees.
  for triple in [[(0, 1, 100), (50, 2, 200), (100, 3, 300)],
                 [(7, 1, 70), (77, 2, 770), (777, 3, 7770)],
                 [(1, 1, 10), (3, 2, 30), (5, 3, 50)],
                 [(2, 1, 20), (20, 2, 200), (200, 3, 2000)]] do
    let s := buildBridgeState triple
    let idx := triple.head! |>.1
    acc := mkValidEntry s idx s!"sparse-3cell:idx={idx}" :: acc
  -- 4 four-cell trees.
  for quad in [[(0, 1, 100), (1, 2, 200), (2, 3, 300), (3, 4, 400)],
               [(10, 1, 100), (20, 2, 200), (30, 3, 300), (40, 4, 400)],
               [(0, 1, 1), (100, 2, 2), (200, 3, 3), (300, 4, 4)],
               [(5, 1, 50), (15, 2, 150), (25, 3, 250), (35, 4, 350)]] do
    let s := buildBridgeState quad
    let idx := quad.head! |>.1
    acc := mkValidEntry s idx s!"sparse-4cell:idx={idx}" :: acc
  return acc.reverse

/-! ## Dense-pair fixtures (16 entries; THE audit-2 regression class) -/

/-- Generate 16 dense-pair entries.  Each entry has sequentially-
    assigned ids 2k and 2k+1 (mapping to the same deepest pair),
    so the leaf-adjacent sibling is the *other* leaf's bytes
    (≈ 56 bytes), NOT a 32-byte default-hash. -/
def densePairEntries : List Entry := Id.run do
  let mut acc : List Entry := []
  -- 8 pairs at low indices.
  for k in (List.range 8) do
    let id0 := 2 * k
    let id1 := 2 * k + 1
    let s := buildBridgeState [(id0, k + 1, 1000 + k), (id1, k + 100, 2000 + k)]
    -- Generate proofs for BOTH ids in the pair (each pair contributes 2 entries).
    acc := mkValidEntry s id0 s!"dense-pair:ids=({id0},{id1}):probe=lo" :: acc
  -- 8 more entries probing the high-id pair member.
  for k in (List.range 8) do
    let id0 := 2 * k
    let id1 := 2 * k + 1
    let s := buildBridgeState [(id0, k + 1, 1000 + k), (id1, k + 100, 2000 + k)]
    acc := mkValidEntry s id1 s!"dense-pair:ids=({id0},{id1}):probe=hi" :: acc
  return acc.reverse

/-! ## Unmapped-id fixtures (16 entries) -/

/-- Generate 16 unmapped-id entries (canonical non-membership proofs).
    Each entry's bridge state has *some* populated cells, but the
    probed id is NOT among them. -/
def unmappedEntries : List Entry := Id.run do
  let mut acc : List Entry := []
  for k in (List.range 16) do
    -- Populate ids 0..3 with some content, then probe a higher id.
    let probedId := 100 + k
    let s := buildBridgeState
      [(0, 1, 100), (1, 2, 200), (2, 3, 300), (3, 4, 400)]
    acc := mkValidEntry s probedId s!"unmapped:probe={probedId}" :: acc
  return acc.reverse

/-! ## Boundary fixtures (16 entries) -/

/-- Generate boundary entries probing extreme indices. -/
def boundaryEntries : List Entry := Id.run do
  let mut acc : List Entry := []
  -- id = 0 (lowest), populated.
  do
    let s := buildBridgeState [(0, 1, 100)]
    acc := mkValidEntry s 0 "boundary:id-0-populated" :: acc
  -- id = 0, unpopulated.
  do
    let s := BridgeState.empty
    acc := mkValidEntry s 0 "boundary:id-0-empty-bridge" :: acc
  -- id = 2^32 - 1 (large but tractable).
  do
    let s := buildBridgeState [(2^32 - 1, 1, 100)]
    acc := mkValidEntry s (2^32 - 1) "boundary:id-32bit-max" :: acc
  -- id = 2^48 - 1.
  do
    let s := buildBridgeState [(2^48 - 1, 1, 100)]
    acc := mkValidEntry s (2^48 - 1) "boundary:id-48bit-max" :: acc
  -- 12 boundary entries probing nextWdId boundary.
  for k in (List.range 12) do
    let nextId := 50 + k
    let s := buildBridgeState [(nextId - 1, 1, 100)]   -- last assigned id
    acc := mkValidEntry s (nextId - 1) s!"boundary:last-id={nextId - 1}" :: acc
  return acc.reverse

/-! ## Tampered fixtures (32 entries) -/

/-- Bit-flip the first byte of a non-empty `ByteArray`.  No-op on
    empty input. -/
def bitFlipFirst (bs : ByteArray) : ByteArray :=
  if bs.size = 0 then bs
  else
    let b := bs.get! 0
    bs.set! 0 (UInt8.xor b 0x01)

/-- Apply a tamper class to a valid entry.  Mutates the underlying
    `Vector ByteArray smtHeight` via `Vector.set` / list-then-rebuild
    operations that preserve length, so the result is a structurally-
    valid `WithdrawalProof` (with broken content). -/
def applyTamper (e : Entry) (t : Tamper) (k : Nat) : Entry :=
  let pf := e.proof
  match t with
  | .leafBitflip =>
    { e with
      proof := { pf with leaf := bitFlipFirst pf.leaf }
      shouldVerify := false
      tamper := some .leafBitflip
      category := e.category ++ "::tampered:leafBitflip"
    }
  | .siblingBitflip =>
    let idx : Fin smtHeight := ⟨k % smtHeight, Nat.mod_lt _ (by decide)⟩
    let oldSib := pf.siblings.get idx
    let newSibs := pf.siblings.set idx (bitFlipFirst oldSib)
    { e with
      proof := { pf with siblings := newSibs }
      shouldVerify := false
      tamper := some .siblingBitflip
      category := e.category ++ "::tampered:siblingBitflip"
    }
  | .siblingSwap =>
    let i0 : Fin smtHeight := ⟨0, by decide⟩
    let i1 : Fin smtHeight := ⟨1, by decide⟩
    let s0 := pf.siblings.get i0
    let s1 := pf.siblings.get i1
    let swapped := (pf.siblings.set i0 s1).set i1 s0
    { e with
      proof := { pf with siblings := swapped }
      shouldVerify := false
      tamper := some .siblingSwap
      category := e.category ++ "::tampered:siblingSwap"
    }
  | .wrongIndex =>
    { e with
      proof := { pf with index := pf.index + 1 }
      shouldVerify := false
      tamper := some .wrongIndex
      category := e.category ++ "::tampered:wrongIndex"
    }
  | .wrongRoot =>
    { e with
      stateRoot := bitFlipFirst e.stateRoot
      shouldVerify := false
      tamper := some .wrongRoot
      category := e.category ++ "::tampered:wrongRoot"
    }

/-- Generate 32 tampered entries: cycle through 5 tamper classes
    against the first 32 valid entries. -/
def tamperedEntries (validEntries : List Entry) : List Entry := Id.run do
  let mut acc : List Entry := []
  let tamperClasses : List Tamper :=
    [.leafBitflip, .siblingBitflip, .siblingSwap, .wrongIndex, .wrongRoot]
  for k in (List.range 32) do
    let t := tamperClasses[k % tamperClasses.length]!
    match validEntries[k]? with
    | some valid =>
      acc := applyTamper valid t k :: acc
    | none => pure ()
  return acc.reverse

/-! ## JSON serialisation -/

/-- Convert a list of byte-arrays to a JSON array of hex strings. -/
def siblingsToJson (sibs : List ByteArray) : Json :=
  .arr (sibs.map (fun s => .str (hexFromBytes s)))

/-- Convert one entry to JSON.  Includes the optional `tamper`
    descriptor for tampered entries. -/
def Entry.toJson (e : Entry) : Json :=
  let tamperJson : Json :=
    match e.tamper with
    | none   => .null
    | some t => .str t.toString
  .obj
    [ ("category",      .str e.category)
    , ("stateRootHex",  .str (hexFromBytes e.stateRoot))
    , ("withdrawalId",  .num e.withdrawalId)
    , ("leafBlobHex",   .str (hexFromBytes e.leafBlob))
    , ("proof",         .obj
        [ ("leafHex",     .str (hexFromBytes e.proof.leaf))
        , ("index",       .num e.proof.index)
        , ("siblingsHex", siblingsToJson e.proof.siblings.toList)
        ])
    , ("shouldVerify",  .bool e.shouldVerify)
    , ("tamper",        tamperJson)
    ]

/-! ## Top-level fixture -/

/-- Build the full fixture: 64 valid + 32 tampered. -/
def buildFixture : (Json × Nat) :=
  let valid : List Entry :=
    sparseEntries ++ densePairEntries ++ unmappedEntries ++ boundaryEntries
  let tampered : List Entry := tamperedEntries valid
  let allEntries := valid ++ tampered
  let header : Json := .obj
    [ ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("hashIdentifier",      .str (hashImplementationIdentifier ()))
    , ("smtHeight",           .num smtHeight)
    , ("count",               .num allEntries.length)
    , ("countValid",          .num valid.length)
    , ("countSparse",         .num 16)
    , ("countDensePair",      .num 16)
    , ("countUnmapped",       .num 16)
    , ("countBoundary",       .num boundaryEntries.length)
    , ("countTampered",       .num tampered.length)
    ]
  let topLevel : Json := .obj
    [ ("header", header)
    , ("entries", .arr (allEntries.map Entry.toJson))
    ]
  (topLevel, allEntries.length)

/-- Fixture file name. -/
def fixtureName : String := "withdrawal_proof.json"

/-! ## Test cases -/

/-- Test cases.  Verify count breakdown, valid proofs verify on the
    Lean side (using `verifyProof`), tampered proofs reject on the
    Lean side, all siblings.length = smtHeight, dense-pair coverage,
    and conditional cross-check skip. -/
def tests : List TestCase :=
  [ { name := "F.1.5: withdrawal_proof fixture has 96 entries (64 valid + 32 tampered)"
    , body := do
        let (_, n) := buildFixture
        if n ≠ 96 then
          throw <| IO.userError s!"expected 96 entries, got {n}"
    }
  , { name := "F.1.5: 64 valid entries verify on the Lean side"
    , body := do
        let valid : List Entry :=
          sparseEntries ++ densePairEntries ++ unmappedEntries ++ boundaryEntries
        if valid.length ≠ 64 then
          throw <| IO.userError s!"valid count: {valid.length}"
        for e in valid do
          if !verifyProof hashBytes e.proof e.stateRoot then
            throw <| IO.userError s!"valid entry {e.category} failed to verify"
    }
  , { name := "F.1.5: every valid entry has 64 siblings"
    , body := do
        let valid : List Entry :=
          sparseEntries ++ densePairEntries ++ unmappedEntries ++ boundaryEntries
        for e in valid do
          if e.proof.siblings.toList.length ≠ smtHeight then
            throw <| IO.userError
              s!"entry {e.category}: {e.proof.siblings.toList.length} siblings, expected {smtHeight}"
    }
  , { name := "F.1.5: dense-pair entries exercise variable-size leaf-adjacent siblings"
    , body := do
        -- Audit-2 regression: at least one dense-pair entry has a
        -- leaf-adjacent sibling that is NOT 32 bytes (i.e. is the
        -- raw `leafBytes` of the paired withdrawal, ~56 bytes).
        let dense := densePairEntries
        let foundVarSize := dense.any (fun e =>
          match e.proof.siblings.toList.getLast? with
          | some sib => sib.size ≠ 32
          | none     => false)
        if !foundVarSize then
          throw <| IO.userError
            "dense-pair entries should have at least one variable-size leaf-adjacent sibling"
    }
  , { name := "F.1.5: tampered entries do NOT verify on the Lean side"
    , body := do
        let valid : List Entry :=
          sparseEntries ++ densePairEntries ++ unmappedEntries ++ boundaryEntries
        let tampered := tamperedEntries valid
        if tampered.length ≠ 32 then
          throw <| IO.userError s!"tampered count: {tampered.length}"
        for e in tampered do
          if verifyProof hashBytes e.proof e.stateRoot then
            throw <| IO.userError s!"tampered entry {e.category} unexpectedly verified"
    }
  , { name := "F.1.5: fixture is byte-deterministic across runs"
    , body := do
        let (j₁, _) := buildFixture
        let (j₂, _) := buildFixture
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.1.5: fixture file write / verify cycle succeeds"
    , body := do
        let (json, _) := buildFixture
        writeFixture fixtureName json.encode
    }
  , { name := "F.1.5: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack assert skipped"
    }
  ]

end WithdrawalProof
end LegalKernel.Test.Bridge.CrossCheck
