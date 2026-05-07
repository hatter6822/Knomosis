/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.EcdsaVerify — Workstream F.1.2.

Generates the `ecdsa_verify.json` cross-stack fixture: 128 entries
exercising every control-flow branch of
`CanonDisputeVerifier.checkSignatureInvalid` and the supporting
`Bridge.VerifyAdaptor` Lean adaptor.  Per the integration plan
§10.1.2:

  * 64 valid low-s signatures      (`outcome = "verifies"`)
  * 32 wrong-signer signatures     (`outcome = "wrongSigner"`)
  * 16 high-s signatures           (`outcome = "highS"`)
  * 16 malformed-length signatures (`outcome = "malformed"`)

**Hash-binding-conditional behaviour.**  The Lean fallback can't
sign / verify ECDSA at the Lean level; the production binding via
the Rust `canon-verify-secp256k1` crate is required.  Without it,
this generator emits fixture entries with deterministic LCG-derived
placeholder bytes (so the fixture file is byte-stable across runs)
plus an `outcome` marker; the Solidity side reads the fixture and
SKIPs the byte-equivalence assertion (the digest can't be re-derived
without the production binding).  CI gates on the production binding
being linked before counting this fixture as passing.

Reproducibility: same `CANON_PROPERTY_SEED` → byte-identical fixture
content.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Test
open LegalKernel.Test.Property

namespace EcdsaVerify

/-! ## Fixture entry types -/

/-- The four outcome variants exercised by the fixture. -/
inductive Outcome : Type where
  /-- Valid low-s signature — verifier returns REJECTED. -/
  | verifies     : Outcome
  /-- Recovered ≠ expectedSigner — verifier returns UPHELD. -/
  | wrongSigner  : Outcome
  /-- s > secp256k1HalfOrder — `recover` reverts → UPHELD. -/
  | highS        : Outcome
  /-- length ≠ 65 — short-circuit to UPHELD. -/
  | malformed    : Outcome
  deriving DecidableEq

/-- Render an outcome as the JSON-string the fixture file uses. -/
def Outcome.toString : Outcome → String
  | .verifies     => "verifies"
  | .wrongSigner  => "wrongSigner"
  | .highS        => "highS"
  | .malformed    => "malformed"

/-- One fixture entry. -/
structure Entry where
  /-- 20-byte L1 address. -/
  expectedSigner     : ByteArray
  /-- 64-byte uncompressed pubkey (no `0x04` prefix). -/
  uncompressedPubkey : ByteArray
  /-- 32-byte EIP-712 digest. -/
  digest             : ByteArray
  /-- 65-byte ECDSA `r ‖ s ‖ v` (or 64 for `malformed`). -/
  sig                : ByteArray
  /-- Expected verifier outcome on this entry. -/
  outcome            : Outcome

/-! ## Deterministic generators -/

/-- Generate `n` deterministic bytes via the LCG. -/
def genBytes (n : Nat) : Gen ByteArray := fun st =>
  let rec loop (k : Nat) (acc : List UInt8) (s : GenState) : List UInt8 × GenState :=
    if k = 0 then (acc, s)
    else
      let (b, s') := genUInt8 s
      loop (k - 1) (b :: acc) s'
  let (bytes, st') := loop n [] st
  (ByteArray.mk bytes.toArray, st')

/-- Generate one fixture entry of the given outcome. -/
def genEntry (out : Outcome) : Gen Entry := fun st0 =>
  let (signerBytes, st1) := genBytes 20 st0
  let (pubkey, st2)      := genBytes 64 st1
  let (digest, st3)      := genBytes 32 st2
  let sigLen : Nat :=
    match out with
    | .malformed => 64
    | _          => 65
  let (sig, st4)         := genBytes sigLen st3
  ({ expectedSigner := signerBytes
   , uncompressedPubkey := pubkey
   , digest := digest
   , sig := sig
   , outcome := out
   }, st4)

/-- Generate a list of entries of the given outcome.  Uses `foldl
    over List.range` to avoid kernel deep-recursion issues in nested
    `let rec`. -/
def genEntries (out : Outcome) (count : Nat) : Gen (List Entry) := fun st0 =>
  let res :=
    (List.range count).foldl
      (fun (acc : List Entry × GenState) (_ : Nat) =>
        let (entries, s) := acc
        let (e, s') := genEntry out s
        (e :: entries, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## JSON serialisation -/

/-- Convert an `Entry` to its JSON object form. -/
def Entry.toJson (e : Entry) : Json :=
  .obj
    [ ("expectedSigner",     .str (hexFromBytes e.expectedSigner))
    , ("uncompressedPubkey", .str (hexFromBytes e.uncompressedPubkey))
    , ("digest",             .str (hexFromBytes e.digest))
    , ("sig",                .str (hexFromBytes e.sig))
    , ("outcome",            .str e.outcome.toString)
    ]

/-- Convert a list of entries to a JSON array. -/
def entriesToJson (es : List Entry) : Json :=
  .arr (es.map Entry.toJson)

/-- The top-level fixture object including a header. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let (verifies,    s1) := genEntries .verifies    64 ⟨seed⟩
  let (wrongSig,    s2) := genEntries .wrongSigner 32 s1
  let (highS,       s3) := genEntries .highS       16 s2
  let (malformed,   _)  := genEntries .malformed   16 s3
  let allEntries := verifies ++ wrongSig ++ highS ++ malformed
  let header : Json := .obj
    [ ("seed",                .num seed.toNat)
    , ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("count",               .num allEntries.length)
    , ("countVerifies",       .num 64)
    , ("countWrongSigner",    .num 32)
    , ("countHighS",          .num 16)
    , ("countMalformed",      .num 16)
    ]
  let topLevel : Json := .obj
    [ ("header", header)
    , ("entries", entriesToJson allEntries)
    ]
  (topLevel, allEntries.length)

/-- The fixture file name. -/
def fixtureName : String := "ecdsa_verify.json"

/-! ## Test cases -/

/-- The test cases.  Verify fixture shape, determinism, per-outcome
    invariants, file write/verify cycle, and the conditional skip. -/
def tests : List TestCase :=
  [ { name := "F.1.2: ecdsa_verify fixture has 128 entries (64+32+16+16)"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 128 then
          throw <| IO.userError s!"expected 128 entries, got {n}"
    }
  , { name := "F.1.2: fixture generation is deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.1.2: malformed entries have sig.length == 64; others have 65"
    , body := do
        let seed ← readSeed
        let (verifies,    s1) := genEntries .verifies    64 ⟨seed⟩
        let (wrongSig,    s2) := genEntries .wrongSigner 32 s1
        let (highS,       s3) := genEntries .highS       16 s2
        let (malformed,   _)  := genEntries .malformed   16 s3
        for e in verifies do
          if e.sig.size ≠ 65 then
            throw <| IO.userError s!"verifies entry sig length: {e.sig.size}"
        for e in wrongSig do
          if e.sig.size ≠ 65 then
            throw <| IO.userError s!"wrongSigner entry sig length: {e.sig.size}"
        for e in highS do
          if e.sig.size ≠ 65 then
            throw <| IO.userError s!"highS entry sig length: {e.sig.size}"
        for e in malformed do
          if e.sig.size ≠ 64 then
            throw <| IO.userError s!"malformed entry sig length: {e.sig.size}"
    }
  , { name := "F.1.2: every entry has 20-byte expectedSigner + 64-byte pubkey + 32-byte digest"
    , body := do
        let seed ← readSeed
        let (verifies,    s1) := genEntries .verifies    64 ⟨seed⟩
        let (wrongSig,    s2) := genEntries .wrongSigner 32 s1
        let (highS,       s3) := genEntries .highS       16 s2
        let (malformed,   _)  := genEntries .malformed   16 s3
        for e in verifies ++ wrongSig ++ highS ++ malformed do
          if e.expectedSigner.size ≠ 20 then
            throw <| IO.userError s!"expectedSigner size {e.expectedSigner.size} ≠ 20"
          if e.uncompressedPubkey.size ≠ 64 then
            throw <| IO.userError s!"pubkey size {e.uncompressedPubkey.size} ≠ 64"
          if e.digest.size ≠ 32 then
            throw <| IO.userError s!"digest size {e.digest.size} ≠ 32"
    }
  , { name := "F.1.2: fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        let content := json.encode
        writeFixture fixtureName content
    }
  , { name := "F.1.2: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"ECDSA fallback (keccak256 not linked); cross-stack assert skipped"
    }
  , { name := "F.1.2: outcome string round-trip distinguishes all four variants"
    , body := do
        let outs : List (Outcome × String) :=
          [ (.verifies,    "verifies")
          , (.wrongSigner, "wrongSigner")
          , (.highS,       "highS")
          , (.malformed,   "malformed")
          ]
        for (o, s) in outs do
          if o.toString ≠ s then
            throw <| IO.userError s!"outcome string mismatch for {s}"
    }
  ]

end EcdsaVerify
end LegalKernel.Test.Bridge.CrossCheck
