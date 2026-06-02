-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.DepositWithFeeAction — Workstream GP.6.1.

Generates the `deposit_with_fee_action.json` cross-stack fixture: a
set of `(Action constructor fields → expected CBE bytes)` reference
vectors for the three Workstream-GP `Action` constructors —
`depositWithFee` (frozen index 19), `topUpActionBudget` (index 20),
and `topUpActionBudgetFor` (index 21).

**Why this fixture exists.**  The Rust `knomosis-l1-ingest` crate
hand-rolls a CBE encoder (`encoding.rs::encode_action`) that MUST
produce bytes byte-identical to the Lean kernel's
`LegalKernel.Encoding.Action.encode` for these constructors.  The
crate's own `.cxsf` corpus (`l1_ingest_fee_split.cxsf`) sweeps the
fee-split parameter space but is *Rust-self-generated* — its expected
bytes come from the Rust encoder itself.  This fixture closes that
gap: the `expectedCbe` field of every entry is computed by running
LEAN's `Action.encode` and hex-encoding the result.  The Rust
consumer (`runtime/knomosis-l1-ingest/tests/cross_stack_lean_action.rs`)
reconstructs each `Action` from the numeric fields, runs its own
`encode_action`, and asserts byte-equality against the Lean-sourced
`expectedCbe`.  This is the genuine Lean → Rust differential the WU
GP.6.1 "pinned via the Lean reference generator" deliverable calls
for.

**What it catches.**

  * A Rust encoder bug (wrong field order, wrong tag, wrong head
    width) → byte mismatch on the Rust side.
  * A Lean encoder change (e.g. a frozen-index bump or a field-order
    edit) → the committed JSON drifts; `lake test`'s verify-mode
    catches it on the Lean side, and the Rust consumer catches it on
    the Rust side once the fixture is regenerated.

**Hash independence.**  Unlike the receiptHash fixtures, this corpus
is purely the CBE byte-encoding of the `Action` inductive — no
hashing is involved — so it is byte-identical regardless of the
kernel's hash binding (FNV vs keccak256).  The cross-check runs
unconditionally on both sides.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Test

namespace DepositWithFeeAction

/-! ## Per-deposit budget-grant ceiling (cross-stack constitutional pin)

Mirrors `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT`,
`DepositFeeSplit.maxBudgetPerDeposit`, and the Rust
`fixture::MAX_BUDGET_PER_DEPOSIT`.  Surfaced in the fixture header so
the Rust consumer can assert all three stacks agree on the value. -/

/-- The per-deposit budget-grant ceiling (`10^12`). -/
def maxBudgetPerDeposit : Nat := 1000000000000

/-! ## Lean-encoder hex helper

`Action.encode` (resolved through the opened `LegalKernel.Encoding`
namespace) yields a `Stream = List UInt8`.  We pack it into a
`ByteArray` and reuse the framework's `hexFromBytes` so the on-disk
form is a `0x`-prefixed lowercase hex string the Rust consumer parses
with `hex::decode`. -/

/-- Encode an `Action` with Lean's canonical `Action.encode` and
    return the `0x`-prefixed lowercase hex of the byte stream.  This
    is the load-bearing value: the Rust consumer byte-matches its own
    `encode_action` output against this. -/
def encodeActionHex (a : Action) : String :=
  hexFromBytes (ByteArray.mk (Encodable.encode (T := Action) a).toArray)

/-! ## Entry builders (one per GP-family constructor) -/

/-- Build a `depositWithFee` (index 19) entry.  Field order on the
    wire: `r ‖ recipient ‖ poolActor ‖ userAmount ‖ poolAmount ‖
    budgetGrant ‖ depositId`. -/
def mkDepositWithFee (r recipient poolActor userAmount poolAmount budgetGrant depositId : Nat)
    (category : String) : Json :=
  let a : Action :=
    .depositWithFee (UInt64.ofNat r) (UInt64.ofNat recipient) (UInt64.ofNat poolActor)
      userAmount poolAmount budgetGrant depositId
  .obj
    [ ("kind",        .str "depositWithFee")
    , ("category",    .str category)
    , ("r",           .num r)
    , ("recipient",   .num recipient)
    , ("poolActor",   .num poolActor)
    , ("userAmount",  .num userAmount)
    , ("poolAmount",  .num poolAmount)
    , ("budgetGrant", .num budgetGrant)
    , ("depositId",   .num depositId)
    , ("expectedCbe", .str (encodeActionHex a))
    ]

/-- Build a `topUpActionBudget` (index 20) entry.  Field order:
    `gasResource ‖ gasAmount ‖ budgetIncrement ‖ poolActor`. -/
def mkTopUpActionBudget (gasResource gasAmount budgetIncrement poolActor : Nat)
    (category : String) : Json :=
  let a : Action :=
    .topUpActionBudget (UInt64.ofNat gasResource) gasAmount budgetIncrement (UInt64.ofNat poolActor)
  .obj
    [ ("kind",            .str "topUpActionBudget")
    , ("category",        .str category)
    , ("gasResource",     .num gasResource)
    , ("gasAmount",       .num gasAmount)
    , ("budgetIncrement", .num budgetIncrement)
    , ("poolActor",       .num poolActor)
    , ("expectedCbe",     .str (encodeActionHex a))
    ]

/-- Build a `topUpActionBudgetFor` (index 21) entry.  Field order:
    `recipient ‖ gasResource ‖ gasAmount ‖ budgetIncrement ‖
    poolActor`. -/
def mkTopUpActionBudgetFor (recipient gasResource gasAmount budgetIncrement poolActor : Nat)
    (category : String) : Json :=
  let a : Action :=
    .topUpActionBudgetFor (UInt64.ofNat recipient) (UInt64.ofNat gasResource)
      gasAmount budgetIncrement (UInt64.ofNat poolActor)
  .obj
    [ ("kind",            .str "topUpActionBudgetFor")
    , ("category",        .str category)
    , ("recipient",       .num recipient)
    , ("gasResource",     .num gasResource)
    , ("gasAmount",       .num gasAmount)
    , ("budgetIncrement", .num budgetIncrement)
    , ("poolActor",       .num poolActor)
    , ("expectedCbe",     .str (encodeActionHex a))
    ]

/-! ## Reference vectors

A representative subset spanning the byte-layout corners: all-zero
fields (minimal heads), small values, the budget cap, and the
`2^64 - 1` boundary that exercises every byte of an 8-byte LE head.
Both ETH (`r = 0`) and BOLD (`r = 1`) deposit legs are present so the
resource-parametric byte-equality is pinned end-to-end. -/

/-- `2^64 - 1`, the largest value an 8-byte CBE uint head represents
    without truncation. -/
def maxU64 : Nat := 18446744073709551615

/-- The fixture entries (18 total: 8 depositWithFee + 5
    topUpActionBudget + 5 topUpActionBudgetFor). -/
def entries : List Json :=
  [ -- depositWithFee (ETH leg, r = 0)
    mkDepositWithFee 0 0 0 0 0 0 0 "depositWithFee:all-zero"
  , mkDepositWithFee 0 1 2 1000 500 10 42 "depositWithFee:canonical"
  , mkDepositWithFee 0 7 1 (10 ^ 18) (10 ^ 17) (10 ^ 8) 99 "depositWithFee:one-eth-ten-percent"
  , mkDepositWithFee 0 3 1 (10 ^ 15) (10 ^ 15) maxBudgetPerDeposit 7 "depositWithFee:budget-at-cap"
  , mkDepositWithFee 0 maxU64 maxU64 maxU64 0 0 maxU64 "depositWithFee:max-u64-ids-and-user"
    -- depositWithFee (BOLD leg, r = 1) — identical to the ETH
    -- canonical except the resource field.
  , mkDepositWithFee 1 1 2 1000 500 10 42 "depositWithFee:bold-canonical"
  , mkDepositWithFee 1 7 1 (10 ^ 18) (10 ^ 17) (10 ^ 8) 99 "depositWithFee:bold-one-bold-ten-percent"
  , mkDepositWithFee 1 3 1 0 maxU64 maxBudgetPerDeposit 1 "depositWithFee:bold-max-pool"
    -- topUpActionBudget (index 20)
  , mkTopUpActionBudget 0 0 0 0 "topUpActionBudget:all-zero"
  , mkTopUpActionBudget 0 100 5 2 "topUpActionBudget:canonical"
  , mkTopUpActionBudget 1 (10 ^ 12) 1000 1 "topUpActionBudget:bold-rate"
  , mkTopUpActionBudget 0 maxU64 maxU64 maxU64 "topUpActionBudget:max-u64"
  , mkTopUpActionBudget 5 1 1 9 "topUpActionBudget:small"
    -- topUpActionBudgetFor (index 21)
  , mkTopUpActionBudgetFor 0 0 0 0 0 "topUpActionBudgetFor:all-zero"
  , mkTopUpActionBudgetFor 7 0 100 5 2 "topUpActionBudgetFor:canonical"
  , mkTopUpActionBudgetFor 3 1 (10 ^ 12) 1000 1 "topUpActionBudgetFor:bold-rate"
  , mkTopUpActionBudgetFor maxU64 0 maxU64 maxU64 maxU64 "topUpActionBudgetFor:max-u64"
  , mkTopUpActionBudgetFor 9 5 1 1 2 "topUpActionBudgetFor:small"
  ]

/-- The fixture's JSON value: a header + the entries array. -/
def buildFixture : Json :=
  let header : Json := .obj
    [ ("identifier",          .str "knomosis-l1-ingest/deposit-with-fee-action/v1")
    , ("count",               .num entries.length)
    , ("countDepositWithFee", .num 8)
    , ("countTopUpBudget",    .num 5)
    , ("countTopUpBudgetFor", .num 5)
    , ("maxBudgetPerDeposit", .num maxBudgetPerDeposit)
    , ("note",
        .str "expectedCbe is Lean Encoding.Action.encode of the constructor; Rust encode_action must match byte-for-byte")
    ]
  .obj
    [ ("header",  header)
    , ("entries", .arr entries)
    ]

/-- Fixture file name. -/
def fixtureName : String := "deposit_with_fee_action.json"

/-! ## Test cases -/

/-- The test cases: count, determinism, byte-shape (tag byte + head
    multiple), self-consistency against a hand-pinned vector, the
    constitutional-constant pin, and the fixture-file write. -/
def tests : List TestCase :=
  [ { name := "GP.6.1: deposit_with_fee_action fixture has 18 entries"
    , body := do
        if entries.length ≠ 18 then
          throw <| IO.userError s!"expected 18 entries, got {entries.length}"
    }
  , { name := "GP.6.1: fixture JSON contains one entry-record per built entry"
    , body := do
        -- Structural sanity on the JSON serialiser: count how many
        -- entry-shaped substrings (`"kind":`) the encoded fixture
        -- contains and assert it equals `entries.length`.  This
        -- catches a serialiser regression that drops or duplicates
        -- entries — a meaningful end-to-end check that the
        -- in-memory `entries` list ↦ on-the-wire JSON pipeline is
        -- shape-preserving.  (The cross-run byte-stability check
        -- the original test was meant to provide is enforced by
        -- `writeFixture`'s verify-mode at CI time, not by an
        -- in-process compare-to-self that is tautologically true
        -- in a pure language.)
        let s := buildFixture.encode
        let occ := (s.splitOn "\"kind\":").length - 1
        if occ ≠ entries.length then
          throw <| IO.userError s!"JSON has {occ} \"kind\": substrings; expected {entries.length}"
    }
  , { name := "GP.6.1: depositWithFee canonical vector matches hand-pinned bytes"
    , body := do
        -- Anchor the Lean encoder to ground truth so the cross-stack
        -- equivalence is not circular: `.depositWithFee 0 1 2 1000
        -- 500 10 42` must encode to the 72-byte sequence below (8 ×
        -- 9-byte CBE uint heads, tag 19 first), identical to the
        -- Rust `encode_deposit_with_fee_known_vector` test.
        let a : Action := .depositWithFee 0 1 2 1000 500 10 42
        let hex := encodeActionHex a
        let expected :=
          -- tag 19 | r 0 | recipient 1 | poolActor 2
          "0x" ++
          "001300000000000000" ++ "000000000000000000" ++
          "000100000000000000" ++ "000200000000000000" ++
          -- userAmount 1000 (0x03e8 LE) | poolAmount 500 (0x01f4 LE)
          "00e803000000000000" ++ "00f401000000000000" ++
          -- budgetGrant 10 | depositId 42
          "000a00000000000000" ++ "002a00000000000000"
        if hex ≠ expected then
          throw <| IO.userError s!"depositWithFee canonical bytes mismatch:\n  got      {hex}\n  expected {expected}"
    }
  , { name := "GP.6.1: every entry's expectedCbe is 0x-prefixed and even-length"
    , body := do
        for e in entries do
          match e with
          | .obj fields =>
            match fields.lookup "expectedCbe" with
            | some (.str hex) =>
              if ¬ hex.startsWith "0x" then
                throw <| IO.userError s!"expectedCbe not 0x-prefixed: {hex}"
              -- "0x" + an even number of hex chars (whole bytes).
              if (hex.length - 2) % 2 ≠ 0 then
                throw <| IO.userError s!"expectedCbe has odd nibble count: {hex}"
            | _ => throw <| IO.userError "entry missing string expectedCbe"
          | _ => throw <| IO.userError "entry is not a JSON object"
    }
  , { name := "GP.6.1: every entry's leading tag byte is 19 / 20 / 21 per kind"
    , body := do
        for e in entries do
          match e with
          | .obj fields =>
            let kind := match fields.lookup "kind" with
              | some (.str k) => k
              | _ => ""
            let hex := match fields.lookup "expectedCbe" with
              | some (.str h) => h
              | _ => ""
            -- The tag is the SECOND byte of the stream (the first is
            -- the CBE uint type-tag 0x00); on the "0x"-prefixed hex
            -- that is chars [4,6).  19 = "13", 20 = "14", 21 = "15".
            let tagHex := if hex.length ≥ 6 then String.ofList ((hex.toList.drop 4).take 2) else ""
            let expectedTag := match kind with
              | "depositWithFee"       => "13"
              | "topUpActionBudget"    => "14"
              | "topUpActionBudgetFor" => "15"
              | _                      => "??"
            if tagHex ≠ expectedTag then
              throw <| IO.userError
                s!"kind {kind}: tag byte {tagHex} ≠ expected {expectedTag} (hex {hex})"
          | _ => throw <| IO.userError "entry is not a JSON object"
    }
  , { name := "GP.6.1: maxBudgetPerDeposit is the constitutional 10^12"
    , body := do
        if maxBudgetPerDeposit ≠ 10 ^ 12 then
          throw <| IO.userError s!"maxBudgetPerDeposit {maxBudgetPerDeposit} ≠ 10^12"
    }
  , { name := "GP.6.1: write deposit_with_fee_action.json fixture file"
    , body :=
        Test.Bridge.CrossCheck.writeFixture fixtureName buildFixture.encodeIndented
    }
  ]

end DepositWithFeeAction
end LegalKernel.Test.Bridge.CrossCheck
