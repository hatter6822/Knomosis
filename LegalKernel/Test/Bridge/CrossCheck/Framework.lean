/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.Framework — Workstream F.1.1.

Shared infrastructure for the Lean ↔ Solidity behavioural-equivalence
fixture corpus (Workstream F).  Each Lean-side fixture generator
writes a JSON file under `solidity/test/CrossCheck/fixtures/`; the
matching `forge` test loads the same file via `vm.readFile` /
`vm.parseJson` and re-runs each entry on the EVM, asserting per-entry
expected outcomes match.

This module ships:

  * A small, no-Std-deps JSON encoder
    (`Json.{Value, encode, encodeIndented}`).
  * Fixture-file path resolution
    (`fixturePath : String → String`).
  * Helpers for per-entry hex-byte serialisation
    (`hexFromBytes`, `hexFromUInt64`, `hexFromNat32`).
  * The `WriteFixtureMode` switch (write-only vs verify-existing) so a
    fixture's first run produces the file and subsequent runs assert
    byte-stability.
  * Property-based generation hooks
    (`LegalKernel.Test.Property.GenState`-driven; reuses Audit-3.9's
    deterministic LCG).

Every fixture-file consumer (F.1.2 – F.1.7) writes via this
framework.  The framework itself exercises only its own JSON
encoder against a smoke-test fixture.

Reproducibility: the same `KNOMOSIS_PROPERTY_SEED` yields the same
fixture content byte-for-byte.

Scope: the Lean side of the cross-stack contract.  The Solidity
side lives in `solidity/test/CrossCheck/Framework.t.sol`.
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.Property

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel.Test
open LegalKernel.Test.Property

/-! ## Minimal JSON encoder

A small, no-Std-deps JSON encoder that supports the value subset
the F.1.x fixtures need: nulls, booleans, numbers (Nat),
hex-strings, and homogeneous arrays / objects.  Designed to be
parsed by Foundry's `vm.parseJson` (which accepts standard JSON).
-/

/-- A minimal JSON value type. -/
inductive Json : Type where
  /-- JSON `null`. -/
  | null   : Json
  /-- JSON boolean. -/
  | bool   : Bool → Json
  /-- JSON number (Nat-only; sufficient for our fixtures). -/
  | num    : Nat → Json
  /-- JSON string. -/
  | str    : String → Json
  /-- JSON array. -/
  | arr    : List Json → Json
  /-- JSON object (key-value pairs, preserves insertion order). -/
  | obj    : List (String × Json) → Json
  deriving Inhabited

/-- Escape a single character for JSON-string output.  Handles the
    five mandatory escapes (`"`, `\\`, `\b`, `\f`, `\n`, `\r`,
    `\t`); other ASCII printables pass through verbatim. Other
    control bytes (< 0x20) are emitted as `\u00XX`. -/
def escapeChar (c : Char) : String :=
  if c = '"' then "\\\""
  else if c = '\\' then "\\\\"
  else if c.toNat = 0x08 then "\\b"
  else if c.toNat = 0x0C then "\\f"
  else if c = '\n' then "\\n"
  else if c = '\r' then "\\r"
  else if c = '\t' then "\\t"
  else if c.toNat < 0x20 then
    -- Control character: emit \u00XX form.
    let hex := Nat.toDigits 16 c.toNat
    let padded :=
      if hex.length = 1 then '0' :: hex else hex
    "\\u00" ++ String.ofList padded
  else
    String.singleton c

/-- Escape a string for JSON output. -/
def escapeStr (s : String) : String :=
  s.foldl (fun acc c => acc ++ escapeChar c) ""

/-- Encode a Json value as a compact (single-line) JSON string. -/
partial def Json.encode : Json → String
  | .null     => "null"
  | .bool true  => "true"
  | .bool false => "false"
  | .num n    => toString n
  | .str s    => "\"" ++ escapeStr s ++ "\""
  | .arr []   => "[]"
  | .arr (x :: xs) =>
    let head := Json.encode x
    let tail := xs.foldl (fun acc e => acc ++ "," ++ Json.encode e) ""
    "[" ++ head ++ tail ++ "]"
  | .obj []   => "{}"
  | .obj ((k, v) :: rest) =>
    let head := "\"" ++ escapeStr k ++ "\":" ++ Json.encode v
    let tail := rest.foldl
      (fun acc (k', v') =>
        acc ++ ",\"" ++ escapeStr k' ++ "\":" ++ Json.encode v')
      ""
    "{" ++ head ++ tail ++ "}"

/-- Encode a Json value with two-space indentation (one entry per
    line for arrays / objects).  Useful for human-readable fixture
    files; Solidity's `vm.parseJson` accepts both forms. -/
partial def Json.encodeIndentedAux : Nat → Json → String
  | _,     .null     => "null"
  | _,     .bool true  => "true"
  | _,     .bool false => "false"
  | _,     .num n    => toString n
  | _,     .str s    => "\"" ++ escapeStr s ++ "\""
  | _,     .arr []   => "[]"
  | depth, .arr (x :: xs) =>
    let pad   := String.ofList (List.replicate (2 * (depth + 1)) ' ')
    let close := String.ofList (List.replicate (2 * depth) ' ')
    let head  := pad ++ Json.encodeIndentedAux (depth + 1) x
    let tail  := xs.foldl
      (fun acc e =>
        acc ++ ",\n" ++ pad ++ Json.encodeIndentedAux (depth + 1) e)
      ""
    "[\n" ++ head ++ tail ++ "\n" ++ close ++ "]"
  | _,     .obj []   => "{}"
  | depth, .obj ((k, v) :: rest) =>
    let pad   := String.ofList (List.replicate (2 * (depth + 1)) ' ')
    let close := String.ofList (List.replicate (2 * depth) ' ')
    let head := pad ++ "\"" ++ escapeStr k ++ "\": " ++
                Json.encodeIndentedAux (depth + 1) v
    let tail := rest.foldl
      (fun acc (k', v') =>
        acc ++ ",\n" ++ pad ++ "\"" ++ escapeStr k' ++ "\": " ++
        Json.encodeIndentedAux (depth + 1) v')
      ""
    "{\n" ++ head ++ tail ++ "\n" ++ close ++ "}"

/-- Encode a Json value with two-space indentation. -/
def Json.encodeIndented (j : Json) : String :=
  Json.encodeIndentedAux 0 j

/-! ## Hex byte encoding -/

/-- Convert a single nibble (0..15) to its lowercase hex character. -/
def nibbleToHex (n : Nat) : Char :=
  if n < 10 then Char.ofNat (n + '0'.toNat)
  else Char.ofNat (n - 10 + 'a'.toNat)

/-- Encode a `UInt8` as a 2-character lowercase hex string. -/
def hexFromUInt8 (b : UInt8) : String :=
  let n := b.toNat
  String.ofList [nibbleToHex (n / 16), nibbleToHex (n % 16)]

/-- Encode a `ByteArray` as a `0x`-prefixed lowercase hex string.
    Empty input encodes to `"0x"`. -/
def hexFromBytes (bs : ByteArray) : String :=
  -- Iterate via foldl over data: concise, terminates trivially.
  "0x" ++ bs.toList.foldl (fun acc b => acc ++ hexFromUInt8 b) ""

/-- Encode a `Nat` as a 32-byte big-endian hex string (256-bit
    uint).  Required for fixture compatibility with EVM's `bytes32`
    and `uint256`. -/
def hexFromUint256BE (n : Nat) : String :=
  let rec loop (i : Nat) (acc : String) : String :=
    if i = 0 then acc
    else
      let byte := (n / (256 ^ (i - 1))) % 256
      loop (i - 1) (acc ++ hexFromUInt8 (UInt8.ofNat byte))
  "0x" ++ loop 32 ""

/-- Encode a `UInt64` as a 8-byte big-endian hex string. -/
def hexFromUInt64BE (n : UInt64) : String :=
  let rec loop (i : Nat) (acc : String) : String :=
    if i = 0 then acc
    else
      let byte := (n.toNat / (256 ^ (i - 1))) % 256
      loop (i - 1) (acc ++ hexFromUInt8 (UInt8.ofNat byte))
  "0x" ++ loop 8 ""

/-! ## Fixture-file path resolution -/

/-- Base directory (relative to repo root) where fixture JSON files
    live.  Mirrored on the Solidity side via the `vm.projectRoot()`
    call's `solidity/test/CrossCheck/fixtures/` resolution. -/
def fixturesDir : String := "solidity/test/CrossCheck/fixtures"

/-- Resolve a fixture's relative path. -/
def fixturePath (name : String) : String :=
  fixturesDir ++ "/" ++ name

/-! ## Fixture-write semantics -/

/-- Whether a fixture-write step should overwrite the file or assert
    byte-stability against an existing one. -/
inductive WriteFixtureMode : Type where
  /-- Always (re)write the fixture file. -/
  | overwrite : WriteFixtureMode
  /-- Verify the file's existing contents match.  Used in CI to
      catch unexpected drift. -/
  | verify    : WriteFixtureMode
  deriving DecidableEq

/-- Write `content` to the fixture file `name`, with semantics
    determined by `mode`.

      * `.overwrite` → write unconditionally.
      * `.verify`    → if the file exists, compare byte-for-byte
                        and `throw` on mismatch.  If it does not
                        exist, write it.

    The intent: per-CI runs use `.verify` (the seed-stable bytes
    are reproducible, so a mismatch indicates either a drift or a
    seed override); local-developer regenerations use `.overwrite`
    (gated by `KNOMOSIS_FIXTURES_OVERWRITE=1`).
-/
def writeFixtureWith (mode : WriteFixtureMode) (name : String)
    (content : String) : IO Unit := do
  let path := fixturePath name
  match mode with
  | .overwrite => IO.FS.writeFile path content
  | .verify =>
    let pathPresent ← System.FilePath.pathExists path
    if pathPresent then
      let onDisk ← IO.FS.readFile path
      if onDisk ≠ content then
        throw <| IO.userError
          s!"fixture {name} drifted: re-run with KNOMOSIS_FIXTURES_OVERWRITE=1 to regenerate"
    else
      IO.FS.writeFile path content

/-- Read the `KNOMOSIS_FIXTURES_OVERWRITE` env var.  When set to `1`,
    fixture-writers regenerate; otherwise they verify byte-stability. -/
def readWriteMode : IO WriteFixtureMode := do
  match (← IO.getEnv "KNOMOSIS_FIXTURES_OVERWRITE") with
  | some "1" => pure .overwrite
  | _        => pure .verify

/-- Write a fixture using the env-var-driven mode.  Convenience
    wrapper for use in fixture generators. -/
def writeFixture (name : String) (content : String) : IO Unit := do
  let mode ← readWriteMode
  writeFixtureWith mode name content

/-! ## Binary (`.cxsf`) fixture writer

Some cross-stack corpora are binary blobs rather than JSON — notably
the Rust `knomosis-cross-stack` `.cxsf` files (a 16-byte header plus
length-prefixed `(input, expected)` records).  The helpers below let a
Lean fixture generator author such a file directly so a Rust consumer
can `load` it and assert byte-equivalence against the Lean-authored
expected bytes.

These are NON-TCB test-framework helpers; the on-disk format is the
one defined by `runtime/knomosis-cross-stack/src/lib.rs` (magic
`"CXSF"`, format-version 1, big-endian u32 header fields and record
length prefixes). -/

/-- Emit `value` as `width` big-endian bytes (most-significant first).
    High bytes beyond `width` are truncated, exactly like a fixed-width
    big-endian encoder.  Used to build the `.cxsf` header / record
    length prefixes and the fixed-width fee-split input layout. -/
def beBytes (value width : Nat) : ByteArray :=
  let rec loop (i : Nat) (acc : ByteArray) : ByteArray :=
    if i = 0 then acc
    else
      let byte := (value / (256 ^ (i - 1))) % 256
      loop (i - 1) (acc.push (UInt8.ofNat byte))
  loop width ByteArray.empty

/-- Base directory (relative to repo root) where binary cross-stack
    corpora (`.cxsf`) live.  Mirrors the Rust consumers' relative
    `runtime/tests/cross-stack/` path. -/
def cxsfFixturesDir : String := "runtime/tests/cross-stack"

/-- Resolve a binary fixture's relative path. -/
def cxsfFixturePath (name : String) : String :=
  cxsfFixturesDir ++ "/" ++ name

/-- Build the byte content of a `.cxsf` fixture file from a list of
    `(input, expected)` records, tagged with `kindTag`.

    Layout (matching `runtime/knomosis-cross-stack/src/lib.rs`):

      * magic bytes `0x43 0x58 0x53 0x46` (`"CXSF"`)
      * `version` as a big-endian u32 (always `1`)
      * `kindTag` as a big-endian u32
      * `count` (number of records) as a big-endian u32
      * for each `(input, expected)`:
          * `input.size` as a big-endian u32, then `input`
          * `expected.size` as a big-endian u32, then `expected`
-/
def buildCxsf (kindTag : UInt32) (records : List (ByteArray × ByteArray)) :
    ByteArray :=
  let magic : ByteArray := ByteArray.mk #[0x43, 0x58, 0x53, 0x46]
  let header :=
    magic
      |>.append (beBytes 1 4)
      |>.append (beBytes kindTag.toNat 4)
      |>.append (beBytes records.length 4)
  records.foldl
    (fun acc (rec : ByteArray × ByteArray) =>
      acc
        |>.append (beBytes rec.1.size 4)
        |>.append rec.1
        |>.append (beBytes rec.2.size 4)
        |>.append rec.2)
    header

/-- Write `content` (a binary `.cxsf` blob) to the corpus file `name`
    under `cxsfFixturesDir`, with the same overwrite-vs-verify
    semantics as `writeFixtureWith` (byte-comparison via the
    underlying `ByteArray` data so a drift throws the standard
    re-generate message). -/
def writeBinFixtureWith (mode : WriteFixtureMode) (name : String)
    (content : ByteArray) : IO Unit := do
  let path := cxsfFixturePath name
  match mode with
  | .overwrite => IO.FS.writeBinFile path content
  | .verify =>
    let pathPresent ← System.FilePath.pathExists path
    if pathPresent then
      let onDisk ← IO.FS.readBinFile path
      if onDisk.toList ≠ content.toList then
        throw <| IO.userError
          s!"fixture {name} drifted: re-run with KNOMOSIS_FIXTURES_OVERWRITE=1 to regenerate"
    else
      IO.FS.writeBinFile path content

/-- Write a binary `.cxsf` fixture using the env-var-driven mode.
    Convenience wrapper for use in fixture generators. -/
def writeBinFixture (name : String) (content : ByteArray) : IO Unit := do
  let mode ← readWriteMode
  writeBinFixtureWith mode name content

/-! ## Conditional cross-check helpers

The `Bridge.HashAdaptor.isKeccak256Linked` predicate gates whether
hash-dependent fixtures can be cross-checked byte-for-byte.  When
the production binding is not linked, the cross-check is skipped
with an explicit log line; CI gates on the binding being linked
before counting the fixture as passing. -/

/-- Log a "skipped" message and return success.  Used when the
    production hash binding is not linked. -/
def skipWithReason (reason : String) : IO Unit := do
  IO.println s!"  SKIPPED: {reason}"

/-! ## Smoke-test fixture

The framework is exercised by writing and reading back a tiny
fixture JSON.  This pins the JSON encoder + escape rules + path
resolution behaviour. -/

/-- The smoke-test fixture's JSON value.  A 2-element array of
    objects, each with a string + number field. -/
def smokeFixture : Json :=
  .arr
    [ .obj [("name", .str "alpha"), ("value", .num 42)]
    , .obj [("name", .str "beta"),  ("nums", .arr [.num 1, .num 2, .num 3])]
    ]

/-- Smoke-test fixture's expected compact JSON. -/
def smokeFixtureExpected : String :=
  "[{\"name\":\"alpha\",\"value\":42},{\"name\":\"beta\",\"nums\":[1,2,3]}]"

/-! ## Test cases for the framework itself -/

/-- The test cases (3): JSON encoder smoke test, hex byte encoder
    sanity, fixture-path resolution. -/
def tests : List TestCase :=
  [ { name := "framework: JSON encoder produces expected compact form"
    , body := do
        let actual := smokeFixture.encode
        if actual ≠ smokeFixtureExpected then
          throw <| IO.userError
            s!"compact JSON mismatch:\n  expected: {smokeFixtureExpected}\n  actual:   {actual}"
    }
  , { name := "framework: JSON encoder escapes special characters"
    , body := do
        let v := Json.str "hello\n\"world\""
        let expected := "\"hello\\n\\\"world\\\"\""
        if v.encode ≠ expected then
          throw <| IO.userError s!"escape mismatch: got {v.encode}"
    }
  , { name := "framework: hexFromBytes round-trips a 4-byte input"
    , body := do
        let bs := ByteArray.mk #[0xDE, 0xAD, 0xBE, 0xEF]
        let actual := hexFromBytes bs
        if actual ≠ "0xdeadbeef" then
          throw <| IO.userError s!"hex mismatch: got {actual}"
    }
  , { name := "framework: hexFromUint256BE pads to 32 bytes (66 chars)"
    , body := do
        let s := hexFromUint256BE 1
        if s.length ≠ 66 then
          throw <| IO.userError s!"expected 66 chars, got {s.length}: {s}"
        if s ≠ "0x0000000000000000000000000000000000000000000000000000000000000001" then
          throw <| IO.userError s!"hex value mismatch: {s}"
    }
  , { name := "framework: hexFromUInt64BE pads to 8 bytes (18 chars)"
    , body := do
        let s := hexFromUInt64BE 0xDEADBEEFCAFE0001
        if s.length ≠ 18 then
          throw <| IO.userError s!"expected 18 chars, got {s.length}: {s}"
        if s ≠ "0xdeadbeefcafe0001" then
          throw <| IO.userError s!"hex value mismatch: {s}"
    }
  , { name := "framework: fixturePath joins correctly"
    , body := do
        let p := fixturePath "smoke.json"
        if p ≠ "solidity/test/CrossCheck/fixtures/smoke.json" then
          throw <| IO.userError s!"path mismatch: {p}"
    }
  , { name := "framework: empty array / empty object encode correctly"
    , body := do
        if (Json.arr []).encode ≠ "[]" then
          throw <| IO.userError "empty array encoding wrong"
        if (Json.obj []).encode ≠ "{}" then
          throw <| IO.userError "empty object encoding wrong"
    }
  , { name := "framework: indented encoder produces multi-line output"
    , body := do
        let v := Json.arr [Json.num 1, Json.num 2]
        let s := v.encodeIndented
        -- Indented form contains a newline.
        let containsNewline := s.foldl (fun acc c => acc || c = '\n') false
        if !containsNewline then
          throw <| IO.userError s!"indented encoder produced no newline: {s}"
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck
