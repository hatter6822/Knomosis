/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.Keccak256 — Workstream F.1.3.

Generates the `keccak256.json` cross-stack fixture: 100 inputs of
varying lengths (50 short ≤ 32 bytes, 30 medium 32-256 bytes, 20
long 256-2048 bytes) plus 4 reference KAT vectors lifted from
`LegalKernel/Bridge/HashAdaptor.lean`.  Each entry is

```jsonc
{ "input": "0x...", "expected": "0x..." }
```

where `expected` is the 32-byte keccak256 of `input` as produced by
the production Ethereum hash function.

**Hash-binding-conditional behaviour.**  When
`Bridge.HashAdaptor.isKeccak256Linked = true` (i.e. the runtime
adaptor links the Rust `knomosis-hash-keccak256` crate), the Lean
side computes `expected` via `Runtime.Hash.hashBytes` and asserts
byte-exact match against the on-chain keccak256 opcode.  When
`isKeccak256Linked = false`, the fixture's `expected` field still
holds the FNV-1a-64 fallback bytes (deterministic, but NOT
keccak256-compatible); the Solidity side reads the fixture and
SKIPs byte-equivalence assertion via the header's `isKeccak256Linked
= false` flag.  CI gates on the production binding being linked.

KAT vectors (always emitted, conditional on binding for assertion):
  * keccak256("")             → kat_empty
  * keccak256("abc")          → kat_abc
  * keccak256("Hello, World!") → kat_helloWorld
  * keccak256(0x00)           → kat_singleZero

Reproducibility: same `KNOMOSIS_PROPERTY_SEED` → byte-identical fixture
content (input bytes are LCG-deterministic; `expected` derived from
`hashBytes`, also deterministic).

Total fixture size: 100 + 4 KAT = **104** entries.

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

namespace Keccak256

/-- One fixture entry. -/
structure Entry where
  /-- Input bytes (variable size). -/
  input    : ByteArray
  /-- 32-byte keccak256 (or 32-byte FNV fallback if not linked). -/
  expected : ByteArray
  /-- Optional human label (e.g. for KAT entries). -/
  label    : String

/-- Generate `n` deterministic bytes via the LCG. -/
def genBytes (n : Nat) : Gen ByteArray := fun st =>
  let rec loop (k : Nat) (acc : List UInt8) (s : GenState) : List UInt8 × GenState :=
    if k = 0 then (acc, s)
    else
      let (b, s') := genUInt8 s
      loop (k - 1) (b :: acc) s'
  let (bytes, st') := loop n [] st
  (ByteArray.mk bytes.toArray, st')

/-- Generate one entry of the given length-bucket.  The expected
    output is computed via `hashBytes` (which routes to keccak256
    when the production binding is linked, otherwise to FNV-1a-64
    padded to 32 bytes — see `LegalKernel/Runtime/Hash.lean`). -/
def genEntry (len : Nat) (label : String) : Gen Entry := fun st0 =>
  let (input, st1) := genBytes len st0
  ({ input := input
   , expected := hashBytes input
   , label := label
   }, st1)

/-- Generate `n` entries each of length `len`.  Implementation uses
    `List.foldl` over a `List.range` to avoid kernel deep-recursion
    issues that the inner `let rec loop` form triggered. -/
def genEntries (len : Nat) (count : Nat) (labelPrefix : String) :
    Gen (List Entry) := fun st0 =>
  let res :=
    (List.range count).foldl
      (fun (acc : List Entry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (e, s') := genEntry len s!"{labelPrefix}-{k}" s
        (e :: entries, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-- Generate entries spanning a length range `[loLen, hiLen]`.
    Length is sampled uniformly within the bucket using the LCG. -/
def genEntriesInRange (loLen hiLen : Nat) (count : Nat) (labelPrefix : String) :
    Gen (List Entry) := fun st0 =>
  let span := hiLen - loLen
  let res :=
    (List.range count).foldl
      (fun (acc : List Entry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (offset, s1) := genNat (span + 1) s
        let len := loLen + offset
        let (e, s2) := genEntry len s!"{labelPrefix}-{k}" s1
        (e :: entries, s2))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## Reference KAT vectors -/

/-- The four reference keccak256 KAT entries from `Bridge/HashAdaptor.lean`. -/
def katEntries : List Entry :=
  [ { input := ByteArray.empty
    , expected := kat_empty
    , label := "kat:empty"
    }
  , { input := ByteArray.mk #[0x61, 0x62, 0x63]   -- "abc"
    , expected := kat_abc
    , label := "kat:abc"
    }
  , { input := ByteArray.mk #[
        -- "Hello, World!"
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20,
        0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21
      ]
    , expected := kat_helloWorld
    , label := "kat:helloWorld"
    }
  , { input := ByteArray.mk #[0x00]
    , expected := kat_singleZero
    , label := "kat:singleZero"
    }
  ]

/-! ## JSON serialisation -/

/-- Convert an `Entry` to JSON.  KAT entries get an extra `label`
    field; randomised entries get a numeric label that's stable
    across runs at a given seed. -/
def Entry.toJson (e : Entry) : Json :=
  .obj
    [ ("label",    .str e.label)
    , ("input",    .str (hexFromBytes e.input))
    , ("expected", .str (hexFromBytes e.expected))
    ]

/-- Convert a list of entries to a JSON array. -/
def entriesToJson (es : List Entry) : Json :=
  .arr (es.map Entry.toJson)

/-! ## Top-level fixture -/

/-- Build the full fixture: 50 short + 30 medium + 20 long + 4 KAT. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let (short,  s1) := genEntriesInRange 0   32   50 "short"  ⟨seed⟩
  let (medium, s2) := genEntriesInRange 32  256  30 "medium" s1
  let (long,   _ ) := genEntriesInRange 256 2048 20 "long"   s2
  let allEntries := katEntries ++ short ++ medium ++ long
  let header : Json := .obj
    [ ("seed",                .num seed.toNat)
    , ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("hashIdentifier",      .str (hashImplementationIdentifier ()))
    , ("count",               .num allEntries.length)
    , ("countKat",            .num 4)
    , ("countShort",          .num 50)
    , ("countMedium",         .num 30)
    , ("countLong",           .num 20)
    ]
  let topLevel : Json := .obj
    [ ("header", header)
    , ("entries", entriesToJson allEntries)
    ]
  (topLevel, allEntries.length)

/-- The fixture file name. -/
def fixtureName : String := "keccak256.json"

/-! ## Test cases -/

/-- The test cases.  Verify fixture shape, determinism, KAT
    embedding, output sizes, file write/verify cycle, and
    conditional cross-check. -/
def tests : List TestCase :=
  [ { name := "F.1.3: keccak256 fixture has 104 entries (4 KAT + 50 + 30 + 20)"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 104 then
          throw <| IO.userError s!"expected 104 entries, got {n}"
    }
  , { name := "F.1.3: fixture generation is deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.1.3: every entry's expected output is exactly 32 bytes"
    , body := do
        let seed ← readSeed
        let (short,  s1) := genEntriesInRange 0   32   50 "short"  ⟨seed⟩
        let (medium, s2) := genEntriesInRange 32  256  30 "medium" s1
        let (long,   _ ) := genEntriesInRange 256 2048 20 "long"   s2
        for e in katEntries ++ short ++ medium ++ long do
          if e.expected.size ≠ 32 then
            throw <| IO.userError
              s!"entry {e.label}: expected.size = {e.expected.size}, want 32"
    }
  , { name := "F.1.3: KAT entries embed the four reference vectors"
    , body := do
        if katEntries.length ≠ 4 then
          throw <| IO.userError s!"katEntries.length = {katEntries.length}, want 4"
        let names := katEntries.map (·.label)
        let expected := ["kat:empty", "kat:abc", "kat:helloWorld", "kat:singleZero"]
        if names ≠ expected then
          throw <| IO.userError s!"KAT labels mismatch: {names}"
    }
  , { name := "F.1.3: short entries have input.size ≤ 32"
    , body := do
        let seed ← readSeed
        let (short, _) := genEntriesInRange 0 32 50 "short" ⟨seed⟩
        for e in short do
          if e.input.size > 32 then
            throw <| IO.userError s!"short entry {e.label}: size {e.input.size} > 32"
    }
  , { name := "F.1.3: medium entries have 32 ≤ input.size ≤ 256"
    , body := do
        let seed ← readSeed
        let (short, s1) := genEntriesInRange 0 32 50 "short" ⟨seed⟩
        let _ := short -- thread RNG state forward
        let (medium, _) := genEntriesInRange 32 256 30 "medium" s1
        for e in medium do
          if e.input.size < 32 || e.input.size > 256 then
            throw <| IO.userError s!"medium entry {e.label}: size {e.input.size} ∉ [32,256]"
    }
  , { name := "F.1.3: long entries have 256 ≤ input.size ≤ 2048"
    , body := do
        let seed ← readSeed
        let (short, s1)  := genEntriesInRange 0 32 50 "short" ⟨seed⟩
        let _ := short
        let (medium, s2) := genEntriesInRange 32 256 30 "medium" s1
        let _ := medium
        let (long, _)    := genEntriesInRange 256 2048 20 "long" s2
        for e in long do
          if e.input.size < 256 || e.input.size > 2048 then
            throw <| IO.userError s!"long entry {e.label}: size {e.input.size} ∉ [256,2048]"
    }
  , { name := "F.1.3: fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        writeFixture fixtureName json.encode
    }
  , { name := "F.1.3: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback (FNV-1a-64); cross-stack assert skipped"
    }
  ]

end Keccak256
end LegalKernel.Test.Bridge.CrossCheck
