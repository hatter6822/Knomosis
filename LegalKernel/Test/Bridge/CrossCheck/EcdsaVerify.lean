-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.EcdsaVerify — Workstream F.1.2.

Generates the `ecdsa_verify.json` cross-stack fixture: 20 REAL
secp256k1 vectors exercising every control-flow branch of
`KnomosisDisputeVerifier.checkSignatureInvalid`'s recovery path
(integration plan §10.1.2):

  * 8 valid low-s signatures      (`outcome = "verifies"`)
  * 4 wrong-signer signatures     (`outcome = "wrongSigner"`)
  * 4 high-s signatures           (`outcome = "highS"`)
  * 4 malformed-length signatures (`outcome = "malformed"`)

**Real vectors, hash-independent.**  The Lean side cannot sign / verify
ECDSA (no secp256k1 in core; `Verify` is opaque), so the corpus is a
fixed set of REAL precomputed secp256k1 vectors (generated out-of-band
with `cast wallet sign --no-hash`; see `realVectors`).  Each
`(expectedSigner, digest, sig)` triple is genuine test data, independent
of the kernel's hash binding (FNV vs keccak256).

Earlier this fixture emitted random LCG bytes and the Solidity consumer
SKIPPED the recovery assertion under the FNV fallback — meaning the
recovery cross-check was never actually exercised (random
`(digest, sig)` can never recover to a random `expectedSigner`).  With
real vectors the Solidity side runs `ecrecover` UNCONDITIONALLY (no
`isKeccak256Linked` gate), so the L1 recovery branches are continuously
verified in every build.

Reproducibility: the corpus is fixed, so the fixture is byte-identical
across runs regardless of `KNOMOSIS_PROPERTY_SEED`.

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
  /-- 64-byte shape-only placeholder (`digest ‖ digest`); the recovery
      cross-check uses `(digest, sig, expectedSigner)` and never the
      pubkey.  See the `realVectors` docstring. -/
  uncompressedPubkey : ByteArray
  /-- 32-byte EIP-712 digest. -/
  digest             : ByteArray
  /-- 65-byte ECDSA `r ‖ s ‖ v` (or 64 for `malformed`). -/
  sig                : ByteArray
  /-- Expected verifier outcome on this entry. -/
  outcome            : Outcome

/-! ## Hex → bytes -/

/-- Parse one lowercase hex nibble to its 0–15 value (0 on a
    non-hex char; the embedded vectors below are well-formed). -/
def hexNibble (c : Char) : UInt8 :=
  let n := c.toNat
  if n ≥ '0'.toNat ∧ n ≤ '9'.toNat then UInt8.ofNat (n - '0'.toNat)
  else if n ≥ 'a'.toNat ∧ n ≤ 'f'.toNat then UInt8.ofNat (n - 'a'.toNat + 10)
  else 0

/-- Fold a char list (pairs of hex nibbles) into bytes, accumulator
    reversed at the base case. -/
partial def bytesOfHexAux : List Char → List UInt8 → List UInt8
  | a :: b :: rest, acc => bytesOfHexAux rest (((hexNibble a) * 16 + hexNibble b) :: acc)
  | _,              acc => acc.reverse

/-- Parse a `0x`-less lowercase hex string into a `ByteArray`. -/
def bytesOfHex (s : String) : ByteArray :=
  ByteArray.mk (bytesOfHexAux s.toList []).toArray

/-! ## Real secp256k1 test vectors

The Lean side cannot compute ECDSA (no secp256k1 in core; `Verify` is an
opaque), so the corpus is a fixed set of REAL precomputed secp256k1
vectors (generated out-of-band with `cast wallet sign --no-hash`).  Each
`(expectedSigner, digest, sig)` triple is real test data, INDEPENDENT of
the kernel's hash binding (FNV vs keccak256) — so the Solidity consumer's
`ecrecover` cross-check runs UNCONDITIONALLY (it is no longer gated on
`isKeccak256Linked`), exercising every outcome branch of the L1 recovery
logic in `KnomosisDisputeVerifier.checkSignatureInvalid`:

  * `verifies`    — `ecrecover(digest, sig) == expectedSigner` (low-s).
  * `wrongSigner` — a valid signature whose recovered signer ≠
    `expectedSigner` (here a different key's address).
  * `highS`       — `s > secp256k1HalfOrder` (the low-s mate `n - s` of a
    valid signature); OpenZeppelin `ECDSA.tryRecover` flags
    `InvalidSignatureS`.
  * `malformed`   — a 64-byte signature (length ≠ 65 short-circuit).

`uncompressedPubkey` is retained for fixture-shape stability only; the
recovery cross-check uses `(digest, sig, expectedSigner)` and never the
pubkey, so a deterministic 64-byte placeholder (`digest ‖ digest`)
suffices. -/

/-- The frozen corpus: `(expectedSignerHex, digestHex, sigHex, outcome)`,
    all `0x`-less lowercase.  8 verifies + 4 wrongSigner + 4 highS + 4
    malformed = 20 entries. -/
def realVectors : List (String × String × String × Outcome) :=
  [ ( "7e5f4552091a69125d5dfcb7b8c2659029395bdf", "6bb10157cf7374bfbb5e84a3384d0fb4dca2579680e8a66632645bf0aaf21914", "4333a042525b8bc7c134f9d5121090568d7520001495c62d939e16116dbec7a436e7b064a4f4760a3f3fbe3a01cde3415de20aea4da07d0b8bb036fd6c1102131c", .verifies )
  , ( "2b5ad5c4795c026514f8317c7a215e218dccd6cf", "802dfc1ab23e47adb36662fd5622647e686fbc66df7ef44430d7057637594536", "5127b0bbec3e3f887af19e24ddc0753022327e84022bc4d4e6b07fc9ce3b95bb2dea0f0f967b6bf780a31f44193ea26f88d2485a3f6acc181e732a90b76138621b", .verifies )
  , ( "6813eb9362372eef6200f3b1dbc3f819671cba69", "07b8d6fca5250921aace74944baa3f6f433fa0c9fdfc7987e4cb5b73dafe2c58", "bb0c8db32219ef439528f4883b50febe8ccacada14c6e9a5f8d1213498a0fa2d7976af472a8ea3a2b163e5ae4f2a40b3f6cf2b5b60b404f54b3eb21e30c47c921b", .verifies )
  , ( "1eff47bc3a10a45d4b230b5d10e37751fe6aa718", "ee88220cd45d422de228a4bcd7c96afb0d3ccded0ade67d1e4849aab3f780e47", "9116ef14a1b61f8e6b4512ae49bbf3ca7667b52a26b6f3d396b2bfad820aa4484760946f3c9382350d3bd94bf89ae7e7cc91f659530e9b015a9a88cf7db822ed1c", .verifies )
  , ( "e1ab8145f7e55dc933d51a18c793f901a3a0b276", "7cc01d870dd4ff1741a7b726755ff44b89927c8009693bff1100e6be89b5aaac", "3f5f9458521d721ed1d94ea24035571adeeb73628813922829a25f57e8b07d3328c06ae6977329a3079e29211c8c8b11e8dcae39e2e8e50b0393184cf89357de1b", .verifies )
  , ( "e57bfe9f44b819898f47bf37e5af72a0783e1141", "84033e8107cd8b5ea243af5dd56d7e65dd1973cd35ea162fcba0bc4ce2853394", "112a76bf32a58b71b0c2494e585030a674d368040345498773277bb9a832ddf61f2f84333905393336dda0329ac5e938f61f3d5f39bbff08ac8e1cdd48eee7271c", .verifies )
  , ( "d41c057fd1c78805aac12b0a94a405c0461a6fbb", "807d27abda857467ca23eb4444426057412141b9faa033eb26b9c08415861831", "6e7eb9a0ad382f3e97ed25edf112942cde1c4ed1618a4bc33579d9fa4b54d18b664a6886dad173761ff14d42941e5c0185ad32e6100f2bdd73f93c326afe6a631b", .verifies )
  , ( "f1f6619b38a98d6de0800f1defc0a6399eb6d30c", "f2f206122f57c0687bbf0978f719ad8de3ffb04b8788c1affe440e901811826d", "935584d05e0c9639f66be35addee3c511d8b4e199a212fc3ac19d2ccb474403f2c9f84b55d5427f4a055d45b68c2cd17e69d87a073e9caf412f7499fe294c9981c", .verifies )
  , ( "f7edc8fa1ecc32967f827c9043fcae6ba73afa5c", "6bb10157cf7374bfbb5e84a3384d0fb4dca2579680e8a66632645bf0aaf21914", "4333a042525b8bc7c134f9d5121090568d7520001495c62d939e16116dbec7a436e7b064a4f4760a3f3fbe3a01cde3415de20aea4da07d0b8bb036fd6c1102131c", .wrongSigner )
  , ( "f7edc8fa1ecc32967f827c9043fcae6ba73afa5c", "802dfc1ab23e47adb36662fd5622647e686fbc66df7ef44430d7057637594536", "5127b0bbec3e3f887af19e24ddc0753022327e84022bc4d4e6b07fc9ce3b95bb2dea0f0f967b6bf780a31f44193ea26f88d2485a3f6acc181e732a90b76138621b", .wrongSigner )
  , ( "f7edc8fa1ecc32967f827c9043fcae6ba73afa5c", "07b8d6fca5250921aace74944baa3f6f433fa0c9fdfc7987e4cb5b73dafe2c58", "bb0c8db32219ef439528f4883b50febe8ccacada14c6e9a5f8d1213498a0fa2d7976af472a8ea3a2b163e5ae4f2a40b3f6cf2b5b60b404f54b3eb21e30c47c921b", .wrongSigner )
  , ( "f7edc8fa1ecc32967f827c9043fcae6ba73afa5c", "ee88220cd45d422de228a4bcd7c96afb0d3ccded0ade67d1e4849aab3f780e47", "9116ef14a1b61f8e6b4512ae49bbf3ca7667b52a26b6f3d396b2bfad820aa4484760946f3c9382350d3bd94bf89ae7e7cc91f659530e9b015a9a88cf7db822ed1c", .wrongSigner )
  , ( "7e5f4552091a69125d5dfcb7b8c2659029395bdf", "6bb10157cf7374bfbb5e84a3384d0fb4dca2579680e8a66632645bf0aaf21914", "4333a042525b8bc7c134f9d5121090568d7520001495c62d939e16116dbec7a4c9184f9b5b0b89f5c0c041c5fe321cbd5cccd1fc61a823303422278f64253f2e1c", .highS )
  , ( "2b5ad5c4795c026514f8317c7a215e218dccd6cf", "802dfc1ab23e47adb36662fd5622647e686fbc66df7ef44430d7057637594536", "5127b0bbec3e3f887af19e24ddc0753022327e84022bc4d4e6b07fc9ce3b95bbd215f0f0698494087f5ce0bbe6c15d8f31dc948c6fddd423a15f33fc18d508df1b", .highS )
  , ( "6813eb9362372eef6200f3b1dbc3f819671cba69", "07b8d6fca5250921aace74944baa3f6f433fa0c9fdfc7987e4cb5b73dafe2c58", "bb0c8db32219ef439528f4883b50febe8ccacada14c6e9a5f8d1213498a0fa2d868950b8d5715c5d4e9c1a51b0d5bf4ac3dfb18b4e949b467493ac6e9f71c4af1b", .highS )
  , ( "1eff47bc3a10a45d4b230b5d10e37751fe6aa718", "ee88220cd45d422de228a4bcd7c96afb0d3ccded0ade67d1e4849aab3f780e47", "9116ef14a1b61f8e6b4512ae49bbf3ca7667b52a26b6f3d396b2bfad820aa448b89f6b90c36c7dcaf2c426b407651816ee1ce68d5c3a053a6537d5bd527e1e541c", .highS )
  , ( "e1ab8145f7e55dc933d51a18c793f901a3a0b276", "7cc01d870dd4ff1741a7b726755ff44b89927c8009693bff1100e6be89b5aaac", "3f5f9458521d721ed1d94ea24035571adeeb73628813922829a25f57e8b07d3328c06ae6977329a3079e29211c8c8b11e8dcae39e2e8e50b0393184cf89357de", .malformed )
  , ( "e57bfe9f44b819898f47bf37e5af72a0783e1141", "84033e8107cd8b5ea243af5dd56d7e65dd1973cd35ea162fcba0bc4ce2853394", "112a76bf32a58b71b0c2494e585030a674d368040345498773277bb9a832ddf61f2f84333905393336dda0329ac5e938f61f3d5f39bbff08ac8e1cdd48eee727", .malformed )
  , ( "d41c057fd1c78805aac12b0a94a405c0461a6fbb", "807d27abda857467ca23eb4444426057412141b9faa033eb26b9c08415861831", "6e7eb9a0ad382f3e97ed25edf112942cde1c4ed1618a4bc33579d9fa4b54d18b664a6886dad173761ff14d42941e5c0185ad32e6100f2bdd73f93c326afe6a63", .malformed )
  , ( "f1f6619b38a98d6de0800f1defc0a6399eb6d30c", "f2f206122f57c0687bbf0978f719ad8de3ffb04b8788c1affe440e901811826d", "935584d05e0c9639f66be35addee3c511d8b4e199a212fc3ac19d2ccb474403f2c9f84b55d5427f4a055d45b68c2cd17e69d87a073e9caf412f7499fe294c998", .malformed )
  ]

/-- Build an `Entry` from a `(signerHex, digestHex, sigHex, outcome)`
    vector.  `uncompressedPubkey` is the shape-only placeholder
    `digest ‖ digest` (64 bytes); see the corpus docstring. -/
def mkRealEntry : (String × String × String × Outcome) → Entry
  | (signerHex, digestHex, sigHex, out) =>
    let digest := bytesOfHex digestHex
    { expectedSigner     := bytesOfHex signerHex
    , uncompressedPubkey := digest.append digest
    , digest             := digest
    , sig                := bytesOfHex sigHex
    , outcome            := out
    }

/-- The full entry corpus (20 real vectors). -/
def allEntries : List Entry := realVectors.map mkRealEntry

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

/-- The top-level fixture object including a header.  The corpus is the
    fixed `allEntries` real-vector set; `seed` is recorded in the header
    for provenance but does not affect the (precomputed) entries. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let header : Json := .obj
    [ ("seed",                .num seed.toNat)
    , ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("count",               .num allEntries.length)
    , ("countVerifies",       .num 8)
    , ("countWrongSigner",    .num 4)
    , ("countHighS",          .num 4)
    , ("countMalformed",      .num 4)
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
  [ { name := "F.1.2: ecdsa_verify fixture has 20 real vectors (8+4+4+4)"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 20 then
          throw <| IO.userError s!"expected 20 entries, got {n}"
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
        for e in allEntries do
          let want := if e.outcome = .malformed then 64 else 65
          if e.sig.size ≠ want then
            throw <| IO.userError
              s!"sig length {e.sig.size} ≠ {want} for outcome {e.outcome.toString}"
    }
  , { name := "F.1.2: every entry has 20-byte expectedSigner + 64-byte pubkey + 32-byte digest"
    , body := do
        for e in allEntries do
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
  , { name := "F.1.2: bytesOfHex parses a known vector (anchors the corpus parser)"
    , body := do
        -- The corpus is embedded as hex; anchor the parser to ground truth
        -- so a parser regression cannot silently corrupt the real vectors.
        if bytesOfHex "00ff10ab" ≠ ByteArray.mk #[0x00, 0xff, 0x10, 0xab] then
          throw <| IO.userError "bytesOfHex parse mismatch"
        -- The recovery cross-check is hash-INDEPENDENT (real precomputed
        -- secp256k1 vectors), so — unlike the FNV-era design — the Solidity
        -- consumer runs it unconditionally rather than gating on
        -- `isKeccak256Linked`.
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
