/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.BoldDeposit — Workstream GP.6.5.

Tri-stack (Lean authors; Rust + Solidity consume) byte-equivalence
corpus for the BOLD-currency deposit-with-fee path.  Lean is the single
source of truth: this generator builds ONE entry list and writes TWO
artifacts from it —

  * `solidity/test/CrossCheck/fixtures/bold_deposit.json` (rich JSON,
    consumed by the Solidity `BoldDepositFixtures` forge suite), and
  * `runtime/tests/cross-stack/l1_ingest_bold.cxsf` (binary corpus,
    consumed by the Rust `knomosis-l1-ingest` `cross_stack_bold` test).

Both consumers recompute and assert byte-equality against the
Lean-authored expected values.

**The NEW dimension over GP.5.4 / GP.6.1.**  Earlier corpora pinned
either the fee-split arithmetic + receiptHash (GP.5.4's `bold` JSON) or
the raw `depositWithFee` CBE encoding (GP.6.1's fee-split `.cxsf`).
This corpus additionally pins the *recipient `EpochBudgetState` budget
mutation post-deposit*: each entry carries the encoded `ActorBudget`
the admission gate's `ebs.topUp recipient currentEpoch freeTier
budgetGrant` produces (`Bridge.Admissible.apply_bridge_admissible_with_budget`).
Because the recipient cell is built through the REAL ledger API
(`EpochBudgetState.topUp` on an empty ledger, then a cell lookup), the
corpus budget byte-string IS the admission-gate result, byte-for-byte —
so a Rust / Solidity consumer that recomputes `{0, budgetGrant}` is
cross-checked against the kernel's actual post-state.  Throughout,
`freeTier = 0` and `currentEpoch = 0`, so `normalise` is a no-op on the
empty cell `{0, 0}` and `topUp` yields `{lastSeenEpoch := 0,
budgetBalance := budgetGrant}`; `currentBudget = budgetGrant`.

**Amount grid.**  `amount ∈ {1, 10^9, 10^15, 10^18}`.  The `10^21`
amount the L1 contract accepts as a `uint256` is deliberately DROPPED:
an L2 `depositWithFee` `Action` carries `userAmount` / `poolAmount` as
CBE uints whose 8-byte LE head only represents values `< 2^64`, so an
amount whose user/pool legs reach `2^64` is unencodable as an L2 Action
(the same reasoning the Rust generator records in
`runtime/knomosis-l1-ingest/examples/gen_fee_split_fixtures.rs`).  The
boundary entries use `2^64 - 1` at `0 %` (whole-on-user) and `50 %`
(each leg `≈ 9.2 · 10^18 < 2^64`) so every leg stays encodable.

**Fee-bps grid.**  `chosenFeeBps ∈ {0, 100, 1000, 2500, 5000}` —
`minFeeBps` through the `maxFeeBps` cap (5000).

**Rate grid.**  `weiPerBudgetUnit ∈ {1, 10^9, 3·10^15, 10^18}`, the
full four-magnitude set the WU GP.6.5 spec enumerates.  `1` saturates
the budget at the `MAX_BUDGET_PER_DEPOSIT` clamp; `10^9` is a generic
mid-scale rate; `3·10^15` is the production USD-calibrated BOLD rate;
`10^18` floors the budget to zero for these ETH-scale pools.  Together
they exercise the budget-grant arithmetic across its whole regime —
clamp, proportional, and floor-to-zero.  The full grid is
`2 legs × 4 amounts × 5 fee-bps × 4 rates = 160` entries; with the
three single-leg boundary entries the corpus is 163 entries.

**Hash independence.**  This corpus is purely the fee-split arithmetic,
the CBE byte-encoding of the `Action` inductive, and the CBE encoding
of the recipient `ActorBudget` — no hashing is involved — so it is
byte-identical regardless of the kernel's hash binding (FNV vs
keccak256).  The cross-checks run UNCONDITIONALLY on all three stacks;
`isKeccak256Linked` is recorded in the header only for parity with the
sibling fixtures.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplit

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Test

namespace BoldDeposit

/-! ## Constitutional constants + fixed actors -/

/-- The native-ETH resource id (mirrors `KnomosisBridge.RESOURCE_ID_NATIVE_ETH`). -/
def resourceIdEth : Nat := 0

/-- The BOLD resource id (mirrors `KnomosisBridge.RESOURCE_ID_BOLD`). -/
def resourceIdBold : Nat := 1

/-- The 20-byte BOLD ERC-20 address pin
    (`0x6440f144b7e50D6a8439336510312d2F54beB01D`,
    `KnomosisBridge.BOLD_TOKEN_ADDRESS`).  Surfaced in the fixture
    header so the Solidity consumer can assert the three stacks agree. -/
def boldTokenAddr20 : ByteArray :=
  ByteArray.mk
    #[ 0x64, 0x40, 0xf1, 0x44, 0xb7, 0xe5, 0x0d, 0x6a, 0x84, 0x39
     , 0x33, 0x65, 0x10, 0x31, 0x2d, 0x2f, 0x54, 0xbe, 0xb0, 0x1d ]

/-- The fixed L2 recipient actor for every corpus entry. -/
def fixedRecipient : Nat := 7

/-- The fixed gas-pool actor for every corpus entry. -/
def fixedPoolActor : Nat := 2

/-- The fixed deposit id shared by every GRID entry, so ETH/BOLD twins
    pair by an identical `(amount, feeBps, weiPerBudgetUnit, recipient,
    poolActor, depositId)` key (mirrors the Rust generator's
    `FIXED_DEPOSIT_ID`).  Boundary entries use distinct ids. -/
def fixedDepositId : Nat := 42

/-! ## Lean-encoder hex / byte helpers

`Action.encode` (resolved through the opened `LegalKernel.Encoding`
namespace) yields a `Stream = List UInt8`; we pack it into a
`ByteArray`.  `ActorBudget.encode` similarly yields the CBE encoding of
the recipient budget cell. -/

/-- Encode an `Action` with Lean's canonical `Action.encode` and return
    the packed byte stream (72 bytes for `depositWithFee`). -/
def actionBytes (a : Action) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := Action) a).toArray

/-- Encode an `ActorBudget` with its canonical CBE encoder and return
    the packed byte stream (18 bytes: two 9-byte CBE uint heads). -/
def budgetBytes (b : ActorBudget) : ByteArray :=
  ByteArray.mk (Encodable.encode (T := ActorBudget) b).toArray

/-- Build the `depositWithFee` (index 19) `Action` for an entry.  Field
    order on the wire: `r ‖ recipient ‖ poolActor ‖ userAmount ‖
    poolAmount ‖ budgetGrant ‖ depositId`. -/
def actionFor (resourceId userAmount poolAmount budgetGrant depositId : Nat) :
    Action :=
  .depositWithFee (UInt64.ofNat resourceId) (UInt64.ofNat fixedRecipient)
    (UInt64.ofNat fixedPoolActor) userAmount poolAmount budgetGrant depositId

/-- The recipient `ActorBudget` after the admission gate credits
    `budgetGrant` to a genesis-empty ledger at `currentEpoch = 0`,
    `freeTier = 0`.  Built through the REAL `EpochBudgetState.topUp`
    then a cell lookup, so the corpus budget IS the admission-gate
    post-state (`ebs.topUp recipient 0 0 budgetGrant`).  Equals
    `{lastSeenEpoch := 0, budgetBalance := budgetGrant}`. -/
def recipientBudgetCell (budgetGrant : Nat) : ActorBudget :=
  let ebs : EpochBudgetState :=
    EpochBudgetState.empty.topUp (UInt64.ofNat fixedRecipient) 0 0 budgetGrant
  (ebs[(UInt64.ofNat fixedRecipient)]?).getD ActorBudget.empty

/-! ## Fixture entry type -/

/-- One cross-stack BOLD-deposit entry. -/
structure Entry where
  /-- Human-readable category tag. -/
  category             : String
  /-- The Knomosis resource id (0 = native ETH, 1 = BOLD). -/
  resourceId           : Nat
  /-- The L1 `msg.value` / `amount` deposit. -/
  amount               : Nat
  /-- The user-chosen fee in basis points. -/
  chosenFeeBps         : Nat
  /-- The deployment exchange rate (wei per budget unit). -/
  weiPerBudgetUnit     : Nat
  /-- The L1 per-depositor deposit id. -/
  depositId            : Nat
  /-- Derived user-facing credit. -/
  userAmount           : Nat
  /-- Derived pool credit. -/
  poolAmount           : Nat
  /-- Derived action-budget grant. -/
  budgetGrant          : Nat
  /-- The recipient's post-deposit budget balance (= `budgetGrant`). -/
  recipientBudgetAfter : Nat
  /-- The 72-byte CBE encoding of the `depositWithFee` `Action`. -/
  actionCbe            : ByteArray
  /-- The 18-byte CBE encoding of the recipient `ActorBudget`
      post-deposit (`{0, budgetGrant}`). -/
  recipientBudgetCbe   : ByteArray

/-- Build an `Entry`, computing the fee split (via the reused
    `DepositFeeSplit.feeSplit` — no fee math is redefined here), the
    `Action` bytes, and the recipient-budget bytes. -/
def mkEntry (resourceId amount chosenFeeBps weiPerBudgetUnit depositId : Nat)
    (category : String) : Entry :=
  let split := DepositFeeSplit.feeSplit amount chosenFeeBps weiPerBudgetUnit
  let userAmount := split.1
  let poolAmount := split.2.1
  let budgetGrant := split.2.2
  let a := actionFor resourceId userAmount poolAmount budgetGrant depositId
  let cell := recipientBudgetCell budgetGrant
  { category := category
  , resourceId := resourceId
  , amount := amount
  , chosenFeeBps := chosenFeeBps
  , weiPerBudgetUnit := weiPerBudgetUnit
  , depositId := depositId
  , userAmount := userAmount
  , poolAmount := poolAmount
  , budgetGrant := budgetGrant
  , recipientBudgetAfter := budgetGrant
  , actionCbe := actionBytes a
  , recipientBudgetCbe := budgetBytes cell
  }

/-! ## Entry grid + boundary entries -/

/-- `2^64 - 1`, the largest value a CBE uint head represents without
    truncation. -/
def maxU64 : Nat := 18446744073709551615

/-- The amount grid: ETH-scale magnitudes that keep both fee legs
    `< 2^64` (the L2-Action encodability bound). -/
def amountGrid : List Nat := [1, 10 ^ 9, 10 ^ 15, 10 ^ 18]

/-- The fee-bps grid: `minFeeBps (0)` … `maxFeeBps (5000)`. -/
def feeBpsGrid : List Nat := [0, 100, 1000, 2500, 5000]

/-- The exchange-rate grid: the four `weiPerBudgetUnitBold` magnitudes
    the WU GP.6.5 spec enumerates.  `1` drives the budget to its
    `MAX_BUDGET_PER_DEPOSIT` clamp on any non-trivial pool; `10^9` is a
    generic mid-scale rate; `3 × 10^15` is the production USD-calibrated
    BOLD rate (≈ 33 000 actions per BOLD — see the §GP.6 calibration
    worked example); `10^18` (≈ 1 BOLD per budget unit) floors most
    pools to a sub-unit, zero-budget grant.  Together they span the
    budget-grant regime from saturated (clamped) through proportional
    down to floored-to-zero. -/
def weiPerBudgetUnitGrid : List Nat := [1, 10 ^ 9, 3 * 10 ^ 15, 10 ^ 18]

/-- The deterministic grid: ETH-then-BOLD legs over every
    `(amount, feeBps, weiPerBudgetUnit)` triple, all sharing
    `fixedDepositId` so the ETH/BOLD twins pair trivially.  The leg
    order (resourceId outermost) keeps the listing deterministic.
    `2 * 4 * 5 * 4 = 160` entries. -/
def gridEntries : List Entry :=
  ([resourceIdEth, resourceIdBold].flatMap (fun rid =>
    amountGrid.flatMap (fun amount =>
      feeBpsGrid.flatMap (fun feeBps =>
        weiPerBudgetUnitGrid.map (fun wpbu =>
          mkEntry rid amount feeBps wpbu fixedDepositId
            s!"grid:r{rid}-a{amount}-f{feeBps}-w{wpbu}")))))

/-- Single-leg boundary entries with DISTINCT deposit ids:

      * `u64::MAX @ 0 %` (ETH): user = `2^64-1`, pool = 0.
      * `u64::MAX @ 50 %` (BOLD): each leg `≈ 9.2 · 10^18 < 2^64`.
      * `10^18 @ 50 % @ rate 1` (ETH): explicit budget-clamp at the cap.
-/
def boundaryEntries : List Entry :=
  [ mkEntry resourceIdEth  maxU64    0    1 1000 "boundary:eth-u64max-zero-fee"
  , mkEntry resourceIdBold maxU64    5000 1 1001 "boundary:bold-u64max-half-fee"
  , mkEntry resourceIdEth  (10 ^ 18) 5000 1 1002 "boundary:eth-explicit-clamp"
  ]

/-- The full deterministic entry list (160 grid + 3 boundary = 163).
    The grid is `2 legs × 4 amounts × 5 fee-bps × 4 rates = 160`. -/
def allEntries : List Entry := gridEntries ++ boundaryEntries

/-! ## JSON artifact -/

/-- Serialise one entry to its JSON-object form.  Amounts are emitted
    as 32-byte big-endian hex (parsed Solidity-side as `uint256`);
    the small / bounded fields are emitted as JSON numbers. -/
def toJsonEntry (e : Entry) : Json :=
  .obj
    [ ("category",             .str e.category)
    , ("resourceId",           .num e.resourceId)
    , ("amount",               .str (hexFromUint256BE e.amount))
    , ("chosenFeeBps",         .num e.chosenFeeBps)
    , ("weiPerBudgetUnit",     .num e.weiPerBudgetUnit)
    , ("depositId",            .num e.depositId)
    , ("userAmount",           .str (hexFromUint256BE e.userAmount))
    , ("poolAmount",           .str (hexFromUint256BE e.poolAmount))
    , ("budgetGrant",          .num e.budgetGrant)
    , ("recipientBudgetAfter", .num e.recipientBudgetAfter)
    , ("actionCbe",            .str (hexFromBytes e.actionCbe))
    , ("recipientBudgetCbe",   .str (hexFromBytes e.recipientBudgetCbe))
    ]

/-- The fixture's JSON value: a header + the entries array. -/
def buildFixtureJson : Json :=
  let header : Json := .obj
    [ ("identifier",          .str "knomosis/bold-deposit-crossstack/v1")
    , ("count",               .num allEntries.length)
    , ("isKeccak256Linked",   .bool LegalKernel.Bridge.isKeccak256Linked)
    , ("hashIdentifier",      .str (LegalKernel.Runtime.hashImplementationIdentifier ()))
    , ("maxBudgetPerDeposit", .num DepositFeeSplit.maxBudgetPerDeposit)
    , ("maxFeeBpsCap",        .num 5000)
    , ("minWeiPerBudgetUnit", .num 1)
    , ("resourceIdEth",       .num resourceIdEth)
    , ("resourceIdBold",      .num resourceIdBold)
    , ("boldTokenAddress",    .str (hexFromBytes boldTokenAddr20))
    , ("freeTier",            .num 0)
    , ("currentEpoch",        .num 0)
    , ("note",
        .str "Lean-authored tri-stack corpus: fee split + depositWithFee CBE + recipient EpochBudgetState budget post-state ({0,budgetGrant}); hash-independent (cross-checks run unconditionally)")
    ]
  .obj
    [ ("header",  header)
    , ("entries", .arr (allEntries.map toJsonEntry))
    ]

/-- JSON fixture file name. -/
def fixtureJsonName : String := "bold_deposit.json"

/-! ## Binary (`.cxsf`) artifact -/

/-- The on-disk `FixtureKind` tag for this corpus
    (`FixtureKind::L1IngestBold` on the Rust side). -/
def cxsfKindTag : UInt32 := 7

/-- Binary fixture file name. -/
def cxsfName : String := "l1_ingest_bold.cxsf"

/-- Encode an entry's input as the EXACT 58-byte `FeeSplitInput` layout
    the Rust `decode_fee_split_input` expects (all big-endian):
    `msg_value (16) ‖ chosen_fee_bps (2) ‖ wei_per_budget_unit (8) ‖
    resource_id (8) ‖ recipient (8) ‖ pool_actor (8) ‖ deposit_id (8)`. -/
def encodeFeeSplitInput (e : Entry) : ByteArray :=
  (beBytes e.amount 16)
    |>.append (beBytes e.chosenFeeBps 2)
    |>.append (beBytes e.weiPerBudgetUnit 8)
    |>.append (beBytes e.resourceId 8)
    |>.append (beBytes fixedRecipient 8)
    |>.append (beBytes fixedPoolActor 8)
    |>.append (beBytes e.depositId 8)

/-- The `.cxsf` records: `input = 58-byte FeeSplitInput`,
    `expected = actionCbe (72) ‖ recipientBudgetCbe (18) = 90 bytes`.
    The Rust consumer splits `expected` at offset 72. -/
def cxsfRecords : List (ByteArray × ByteArray) :=
  allEntries.map (fun e => (encodeFeeSplitInput e, e.actionCbe.append e.recipientBudgetCbe))

/-! ## Test cases -/

/-- Count entries whose budget grant is clamped at the cap. -/
def clampActiveCount : Nat :=
  (allEntries.filter (fun e => e.budgetGrant == DepositFeeSplit.maxBudgetPerDeposit)).length

/-- The test cases.  Every assertion throws `IO.userError` on failure. -/
def tests : List TestCase :=
  [ { name := "GP.6.5: bold_deposit corpus has exactly 163 entries (≥ 50)"
    , body := do
        if allEntries.length ≠ 163 then
          throw <| IO.userError s!"expected 163 entries, got {allEntries.length}"
        if allEntries.length < 50 then
          throw <| IO.userError "corpus below the 50-entry floor"
    }
  , { name := "GP.6.5: both resource legs (ETH and BOLD) are present"
    , body := do
        let hasEth  := allEntries.any (fun e => e.resourceId == resourceIdEth)
        let hasBold := allEntries.any (fun e => e.resourceId == resourceIdBold)
        if ! hasEth then
          throw <| IO.userError "no ETH-leg entries"
        if ! hasBold then
          throw <| IO.userError "no BOLD-leg entries"
    }
  , { name := "GP.6.5: every entry conserves the deposit (user + pool = amount)"
    , body := do
        for e in allEntries do
          if e.userAmount + e.poolAmount ≠ e.amount then
            throw <| IO.userError <|
              s!"conservation violated in {e.category}: " ++
              s!"{e.userAmount} + {e.poolAmount} ≠ {e.amount}"
    }
  , { name := "GP.6.5: every entry's budgetGrant is within MAX_BUDGET_PER_DEPOSIT"
    , body := do
        for e in allEntries do
          if e.budgetGrant > DepositFeeSplit.maxBudgetPerDeposit then
            throw <| IO.userError <|
              s!"budgetGrant {e.budgetGrant} exceeds cap in {e.category}"
    }
  , { name := "GP.6.5: no fee leg reaches 2^64 (L2-Action encodability bound)"
    , body := do
        for e in allEntries do
          if e.userAmount ≥ 2 ^ 64 then
            throw <| IO.userError s!"userAmount ≥ 2^64 in {e.category}"
          if e.poolAmount ≥ 2 ^ 64 then
            throw <| IO.userError s!"poolAmount ≥ 2^64 in {e.category}"
    }
  , { name := "GP.6.5: at least 5 entries clamp the budget at the cap"
    , body := do
        if clampActiveCount < 5 then
          throw <| IO.userError s!"only {clampActiveCount} clamp-active entries; expected ≥ 5"
    }
  , { name := "GP.6.5: ETH/BOLD calibration parity (same triple ⇒ same split)"
    , body := do
        -- Pair each ETH grid entry with its BOLD twin by the shared
        -- (amount, feeBps, weiPerBudgetUnit, depositId) key and assert
        -- identical (user, pool, budget): the split is
        -- resource-independent, which is what this pins.
        let eths := gridEntries.filter (fun e => e.resourceId == resourceIdEth)
        for eth in eths do
          let twin? := gridEntries.find? (fun b =>
            b.resourceId == resourceIdBold
              && b.amount == eth.amount
              && b.chosenFeeBps == eth.chosenFeeBps
              && b.weiPerBudgetUnit == eth.weiPerBudgetUnit
              && b.depositId == eth.depositId)
          match twin? with
          | none => throw <| IO.userError s!"no BOLD twin for {eth.category}"
          | some bold =>
            if eth.userAmount ≠ bold.userAmount
               ∨ eth.poolAmount ≠ bold.poolAmount
               ∨ eth.budgetGrant ≠ bold.budgetGrant then
              throw <| IO.userError <|
                s!"calibration parity broken for {eth.category}: " ++
                s!"({eth.userAmount},{eth.poolAmount},{eth.budgetGrant}) vs " ++
                s!"({bold.userAmount},{bold.poolAmount},{bold.budgetGrant})"
    }
  , { name := "GP.6.5: recipientBudgetAfter == budgetGrant and CBE self-consistent"
    , body := do
        for e in allEntries do
          if e.recipientBudgetAfter ≠ e.budgetGrant then
            throw <| IO.userError <|
              s!"recipientBudgetAfter {e.recipientBudgetAfter} ≠ budgetGrant {e.budgetGrant} in {e.category}"
          -- Recompute the recipient cell CBE and assert byte-equality.
          let recomputed := budgetBytes (recipientBudgetCell e.budgetGrant)
          if e.recipientBudgetCbe.toList ≠ recomputed.toList then
            throw <| IO.userError s!"recipientBudgetCbe drift in {e.category}"
          -- Pin: the cell is exactly the {lastSeenEpoch 0, budgetBalance budgetGrant} cell.
          let expected := budgetBytes { lastSeenEpoch := 0, budgetBalance := e.budgetGrant }
          if e.recipientBudgetCbe.toList ≠ expected.toList then
            throw <| IO.userError s!"recipient cell mismatch (expected epoch 0 balance budgetGrant) in {e.category}"
    }
  , { name := "GP.6.5: every actionCbe is 72 bytes; tag head = uint(19)"
    , body := do
        for e in allEntries do
          if e.actionCbe.size ≠ 72 then
            throw <| IO.userError s!"actionCbe size {e.actionCbe.size} ≠ 72 in {e.category}"
          let bs := e.actionCbe.toList
          -- byte[0] is the CBE uint type-tag 0x00; byte[1..9] is the
          -- constructor index 19 as an 8-byte LE Nat.
          if bs.headD 0xFF ≠ 0x00 then
            throw <| IO.userError s!"actionCbe[0] ≠ 0x00 in {e.category}"
          let tagLow := (bs.drop 1).headD 0xFF
          let tagRest := (bs.drop 2).take 7
          if tagLow ≠ 19 ∨ tagRest ≠ [0,0,0,0,0,0,0] then
            throw <| IO.userError s!"actionCbe constructor tag ≠ 19 in {e.category}"
    }
  , { name := "GP.6.5: every recipientBudgetCbe is 18 bytes; epoch 0 head + budget head"
    , body := do
        for e in allEntries do
          if e.recipientBudgetCbe.size ≠ 18 then
            throw <| IO.userError s!"recipientBudgetCbe size {e.recipientBudgetCbe.size} ≠ 18 in {e.category}"
          let bs := e.recipientBudgetCbe.toList
          -- First 9 bytes: encode(Nat 0) = 0x00 ++ 0^8 (lastSeenEpoch).
          if bs.take 9 ≠ [0,0,0,0,0,0,0,0,0] then
            throw <| IO.userError s!"recipientBudgetCbe lastSeenEpoch head ≠ 0 in {e.category}"
          -- Next 9 bytes: encode(Nat budgetGrant) = 0x00 ++ budget LE.
          if (bs.drop 9).headD 0xFF ≠ 0x00 then
            throw <| IO.userError s!"recipientBudgetCbe budget type-tag ≠ 0x00 in {e.category}"
    }
  , { name := "GP.6.5: hand-pinned anchor (depositWithFee 1 7 2 950 50 50 42)"
    , body := do
        -- BOLD leg, amount 1000 @ 500 bps @ rate 1 ⇒ pool 50, user 950,
        -- budget 50.  Anchors the Lean encoders to ground truth so the
        -- cross-stack equivalence is not circular.
        let a : Action := .depositWithFee 1 7 2 950 50 50 42
        let actionHex := hexFromBytes (actionBytes a)
        let expectedAction :=
          -- tag 19 | r 1 | recipient 7 | poolActor 2
          "0x" ++
          "001300000000000000" ++ "000100000000000000" ++
          "000700000000000000" ++ "000200000000000000" ++
          -- userAmount 950 (0x03b6 LE) | poolAmount 50 (0x32 LE)
          "00b603000000000000" ++ "003200000000000000" ++
          -- budgetGrant 50 | depositId 42
          "003200000000000000" ++ "002a00000000000000"
        if actionHex ≠ expectedAction then
          throw <| IO.userError <|
            s!"anchor action bytes mismatch:\n  got      {actionHex}\n  expected {expectedAction}"
        -- Recipient budget cell {lastSeenEpoch 0, budgetBalance 50}.
        let budgetHex := hexFromBytes (budgetBytes (recipientBudgetCell 50))
        let expectedBudget :=
          -- lastSeenEpoch 0 | budgetBalance 50 (0x32 LE)
          "0x" ++ "000000000000000000" ++ "003200000000000000"
        if budgetHex ≠ expectedBudget then
          throw <| IO.userError <|
            s!"anchor budget bytes mismatch:\n  got      {budgetHex}\n  expected {expectedBudget}"
    }
  , { name := "GP.6.5: resourceId-flip — twin actionCbe differ only at byte 10"
    , body := do
        -- Pick the canonical grid triple (amount 10^9, feeBps 1000,
        -- wpbu 10^9) and assert ETH vs BOLD action bytes differ ONLY at
        -- the resource-field LE low byte (index 10 in the 72-byte
        -- stream: 9-byte tag head + 1-byte r type-tag, then r's LE low
        -- byte).  ETH = 0x00, BOLD = 0x01; all other bytes equal.
        let key (rid : Nat) :=
          gridEntries.find? (fun e =>
            e.resourceId == rid && e.amount == 10 ^ 9
              && e.chosenFeeBps == 1000 && e.weiPerBudgetUnit == 10 ^ 9)
        match key resourceIdEth, key resourceIdBold with
        | some eth, some bold =>
          let eb := eth.actionCbe.toList
          let bb := bold.actionCbe.toList
          if eb.length ≠ 72 ∨ bb.length ≠ 72 then
            throw <| IO.userError "twin action bytes not 72 long"
          let diffs := (List.range 72).filter (fun i =>
            (eb.getD i 0) ≠ (bb.getD i 0))
          if diffs ≠ [10] then
            throw <| IO.userError s!"resourceId-flip differs at indices {diffs}, expected [10]"
          if eb.getD 10 0 ≠ 0x00 ∨ bb.getD 10 0 ≠ 0x01 then
            throw <| IO.userError "resourceId byte not 0x00 (ETH) / 0x01 (BOLD)"
        | _, _ => throw <| IO.userError "missing canonical ETH/BOLD twin for resourceId-flip"
    }
  , { name := "GP.6.5: every .cxsf input is 58 bytes; expected is 90 bytes"
    , body := do
        for rec in cxsfRecords do
          if rec.1.size ≠ 58 then
            throw <| IO.userError s!".cxsf input size {rec.1.size} ≠ 58"
          if rec.2.size ≠ 90 then
            throw <| IO.userError s!".cxsf expected size {rec.2.size} ≠ 90"
    }
  , { name := "GP.6.5: feeSplit reference anchors (reused DepositFeeSplit.feeSplit)"
    , body := do
        -- Sanity-anchor the reused fee math at the boundary cases this
        -- corpus depends on.
        if DepositFeeSplit.feeSplit 1000 500 1 ≠ (950, 50, 50) then
          throw <| IO.userError "feeSplit 1000 500 1 mismatch"
        if DepositFeeSplit.feeSplit maxU64 0 1 ≠ (maxU64, 0, 0) then
          throw <| IO.userError "feeSplit maxU64 0 1 mismatch (whole-on-user)"
        if (DepositFeeSplit.feeSplit (10 ^ 18) 5000 1).2.2
            ≠ DepositFeeSplit.maxBudgetPerDeposit then
          throw <| IO.userError "feeSplit 10^18 5000 1 budget clamp mismatch"
    }
  , { name := "GP.6.5: write bold_deposit.json fixture file"
    , body :=
        Test.Bridge.CrossCheck.writeFixture fixtureJsonName buildFixtureJson.encodeIndented
    }
  , { name := "GP.6.5: write l1_ingest_bold.cxsf binary fixture file"
    , body :=
        Test.Bridge.CrossCheck.writeBinFixture cxsfName (buildCxsf cxsfKindTag cxsfRecords)
    }
  ]

end BoldDeposit
end LegalKernel.Test.Bridge.CrossCheck
