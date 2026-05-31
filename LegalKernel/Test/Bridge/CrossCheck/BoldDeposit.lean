-- SPDX-License-Identifier: GPL-3.0-or-later
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
(each leg `≈ 9.2 · 10^18 < 2^64`) so every leg stays encodable; each
boundary case is mirrored on BOTH legs (6 boundary entries).

**Fee-bps grid.**  `chosenFeeBps ∈ {0, 100, 1000, 2500, 5000}` —
`minFeeBps` through the `maxFeeBps` cap (5000).

**Rate grid.**  `weiPerBudgetUnit ∈ {1, 10^9, 3·10^15, 10^18}`, the
full four-magnitude set the WU GP.6.5 spec enumerates.  `1` saturates
the budget at the `MAX_BUDGET_PER_DEPOSIT` clamp; `10^9` is a generic
mid-scale rate; `3·10^15` is the production USD-calibrated BOLD rate;
`10^18` floors the budget to zero for these ETH-scale pools.  Together
they exercise the budget-grant arithmetic across its whole regime —
clamp, proportional, and floor-to-zero.

**USD-calibration block.**  Beyond the grid's same-amount resource-flip
twins, the corpus carries 12 USD-calibrated cross-amount ETH/BOLD pairs
(24 entries): each pair deposits `amount_eth` ETH at `rate_eth = 10^12`
and `3000 · amount_eth` BOLD at `rate_bold = 3 · 10^15` — the same USD
value at the same USD-per-budget-unit rate — and the two legs MUST yield
EQUAL budget grants.  This is the spec's "calibration parity"
deliverable (DIFFERENT amounts, equal grants), distinct from the grid
twins' resource-agnosticism (IDENTICAL amounts).  See `calibrationEntries`
for the exact-equality argument.

**Corpus size.**  `160 grid (2 legs × 4 amounts × 5 fee-bps × 4 rates)
+ 6 boundary + 24 calibration = 190 entries.`

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
    `{lastSeenEpoch := 0, budgetBalance := budgetGrant}`.

    The two theorems below (`recipientBudgetCell_currentBudget` and
    `recipientBudgetCell_matches_gate`) bind this re-derivation to the
    PRODUCTION admission gate's grant arm, so a future change to
    `apply_admissible_with_budget`'s `depositWithFee` branch (a
    different `topUp` argument order, a non-zero genesis `freeTier`,
    etc.) breaks the Lean build rather than silently leaving the
    corpus asserting a stale model. -/
def recipientBudgetCell (budgetGrant : Nat) : ActorBudget :=
  let ebs : EpochBudgetState :=
    EpochBudgetState.empty.topUp (UInt64.ofNat fixedRecipient) 0 0 budgetGrant
  (ebs[(UInt64.ofNat fixedRecipient)]?).getD ActorBudget.empty

/-- The `EpochBudgetState` the corpus models: a genesis-empty ledger
    after crediting `budgetGrant` to the recipient at epoch 0,
    `freeTier 0`.  `recipientBudgetCell` is exactly this ledger's
    recipient cell. -/
def recipientBudgetLedger (budgetGrant : Nat) : EpochBudgetState :=
  EpochBudgetState.empty.topUp (UInt64.ofNat fixedRecipient) 0 0 budgetGrant

/-- **Value binding.**  The recipient's `currentBudget` in the corpus
    ledger equals exactly `budgetGrant` — the value the fixture's
    `budgetGrant` / `recipientBudgetAfter` fields carry.  Proven from
    the kernel lemmas `currentBudget_after_topUp_self` (the `topUp`
    credits the slot) and `currentBudget_empty_genesis` (genesis is
    `0`), so this is the kernel's own arithmetic, not a restatement. -/
theorem recipientBudgetCell_currentBudget (budgetGrant : Nat) :
    EpochBudgetState.currentBudget (recipientBudgetLedger budgetGrant)
        (UInt64.ofNat fixedRecipient) 0 0 = budgetGrant := by
  unfold recipientBudgetLedger
  rw [EpochBudgetState.currentBudget_after_topUp_self,
      EpochBudgetState.currentBudget_empty_genesis, Nat.zero_add]

/-- **Gate binding (the load-bearing theorem).**  For ANY production-
    admitted `depositWithFee` whose `budgetGrant = g`, run under the
    genesis budget policy `.bounded 0 _ 0` (the corpus's `freeTier = 0`,
    `currentEpoch = 0`), the recipient's post-admission `currentBudget`
    equals the corpus's modelled `currentBudget` — namely `g`.

    This is NOT a re-derivation: the left-hand side is computed by the
    REAL `apply_admissible_with_budget` (via the proven
    `depositWithFee_grants_budget`), and the right-hand side is the
    corpus ledger.  If the gate's grant arm ever diverges from
    `topUp recipient currentEpoch freeTier budgetGrant`, this theorem
    no longer type-checks and the corpus must be updated in lockstep. -/
theorem recipientBudgetCell_matches_gate
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature)
    (h : AdmissibleWith verify P d es
            ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                              budgetGrant depositId, signer, nonce, sig⟩)
    (actionCost : Nat)
    (hpolicy : es.budgetPolicy = .bounded 0 actionCost 0)
    -- The corpus always credits the fixed recipient (`fixedRecipient`).
    (hrecip : recipient = UInt64.ofNat fixedRecipient)
    -- The corpus models a genesis-empty pre-state: the recipient has
    -- no prior budget (`currentBudget = 0` at epoch 0, freeTier 0).
    (hpre : EpochBudgetState.currentBudget es.epochBudgets recipient 0 0 = 0)
    {es' : ExtendedState}
    (hsuc : apply_admissible_with_budget verify P d es
              ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                                budgetGrant depositId, signer, nonce, sig⟩ h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets recipient 0 0
      = EpochBudgetState.currentBudget (recipientBudgetLedger budgetGrant) recipient 0 0 := by
  -- Right side: the corpus ledger credits the fixed recipient, so its
  -- recipient `currentBudget` is `budgetGrant` (via the value binding).
  subst hrecip
  rw [show EpochBudgetState.currentBudget (recipientBudgetLedger budgetGrant)
            (UInt64.ofNat fixedRecipient) 0 0 = budgetGrant
        from recipientBudgetCell_currentBudget budgetGrant]
  -- Left side: the production gate credits the recipient by exactly
  -- `budgetGrant` (the proven `depositWithFee_grants_budget`), and the
  -- genesis pre-state contributes `0`.  (`subst hrecip` has replaced
  -- `recipient` by `UInt64.ofNat fixedRecipient` everywhere.)
  rw [depositWithFee_grants_budget verify P d es r (UInt64.ofNat fixedRecipient) poolActor
        userAmount poolAmount budgetGrant depositId signer nonce sig h
        0 actionCost 0 hpolicy hsuc, hpre, Nat.zero_add]

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

/-- Boundary entries, mirrored on BOTH legs (DISTINCT deposit ids):

      * `u64::MAX @ 0 %`     : user = `2^64-1`, pool = 0 (whole-on-user).
      * `u64::MAX @ 50 %`    : each leg `≈ 9.2 · 10^18 < 2^64`.
      * `10^18 @ 50 % @ rate 1` : explicit budget-clamp at the cap.

    Each case is emitted for ETH (`r = 0`) AND BOLD (`r = 1`) so the
    BOLD-specific corpus does not under-cover the whale / clamp corners
    on its namesake leg (the three cases were ETH-leaning pre-v1.2). -/
def boundaryEntries : List Entry :=
  [ mkEntry resourceIdEth  maxU64    0    1 1000 "boundary:eth-u64max-zero-fee"
  , mkEntry resourceIdBold maxU64    0    1 1001 "boundary:bold-u64max-zero-fee"
  , mkEntry resourceIdEth  maxU64    5000 1 1002 "boundary:eth-u64max-half-fee"
  , mkEntry resourceIdBold maxU64    5000 1 1003 "boundary:bold-u64max-half-fee"
  , mkEntry resourceIdEth  (10 ^ 18) 5000 1 1004 "boundary:eth-explicit-clamp"
  , mkEntry resourceIdBold (10 ^ 18) 5000 1 1005 "boundary:bold-explicit-clamp"
  ]

/-! ### USD-calibrated cross-amount ETH/BOLD pairs (the spec's
    "calibration parity" deliverable)

The spec asks that for each `(amount_eth, amount_bold)` pair
"calibrated to the same USD value", the resulting budget grants match
"to within floor-division residue".  Unlike the grid's resource-flip
twins (which share an IDENTICAL amount and only differ in the resource
tag), these pairs carry DIFFERENT amounts on the two legs, deposited at
DIFFERENT per-leg exchange rates, yet must yield matching budget
grants.

**Calibration model.**  Production ETH:BOLD ≈ $3000 : $1, so a USD
value `U` is `U/3000` ETH = `U` BOLD.  In wei: `amount_eth` ETH-wei and
`amount_bold = 3000 · amount_eth` BOLD-wei represent the same USD value.
The per-leg budget rates are calibrated to the SAME USD-per-budget-unit:
`rate_eth = 10^12` wei/unit and `rate_bold = 3000 · 10^12 = 3 · 10^15`
wei/unit.

**Why the grants are EXACTLY equal (not merely within residue).**
For a leg, `budget = floor( floor(amount · feeBps / 10000) / rate )`.
Write `amount · feeBps / 10000 = β · rate` with
`β = (amount / rate) · feeBps / 10000`.  The nested-floor identity
`floor( floor(β · rate) / rate ) = floor β` holds for every real `β`
and positive integer `rate`.  Since calibration makes
`amount_eth / rate_eth = amount_bold / rate_bold` EXACTLY (both equal
`amount_eth / 10^12`), the two legs share the same `β`, hence the same
`floor β` — the grants are byte-for-byte equal.  This corpus therefore
pins the STRONGER exact-equality form; the spec's residue tolerance is
a conservative upper bound we beat.  (All `amount_bold = 3000 ·
amount_eth ≤ 3000 · 3·10^15 = 9·10^18 < 2^64`, so every leg stays
encodable.) -/

/-- The ETH-leg calibration rate: `10^12` wei per budget unit. -/
def calibRateEth : Nat := 10 ^ 12

/-- The BOLD-leg calibration rate: `3 · 10^15` wei per budget unit
    (`3000 ·` the ETH rate, matching the $3000 : $1 ETH:BOLD price). -/
def calibRateBold : Nat := 3 * 10 ^ 15

/-- The ETH:BOLD price ratio used to calibrate paired amounts. -/
def calibRatio : Nat := 3000

/-- The ETH-leg amounts of the calibration pairs (ETH-wei).  Kept small
    enough that `3000 ·` them stays `< 2^64` on the BOLD leg. -/
def calibAmountEths : List Nat := [10 ^ 14, 10 ^ 15, 3 * 10 ^ 15]

/-- The fee-bps values swept for each calibration amount (the non-zero
    fees, so every pair has a non-trivial pool / budget grant). -/
def calibFeeBps : List Nat := [100, 1000, 2500, 5000]

/-- The USD-calibrated cross-amount ETH/BOLD pairs.  For each
    `(amount_eth, feeBps)` the ETH entry deposits `amount_eth` at
    `calibRateEth` and its BOLD partner deposits
    `calibRatio · amount_eth` at `calibRateBold` — the same USD value at
    the same USD-per-budget-unit rate.  Each pair shares a UNIQUE
    `depositId` (`2000 +`) so a consumer can group the two legs of a
    pair without colliding with the grid (`depositId = 42`) or the
    boundary entries (`1000…1005`). -/
def calibrationEntries : List Entry := Id.run do
  let mut acc : List Entry := []
  let mut did : Nat := 2000
  for amountEth in calibAmountEths do
    for feeBps in calibFeeBps do
      let amountBold := calibRatio * amountEth
      acc := acc ++
        [ mkEntry resourceIdEth amountEth feeBps calibRateEth did
            s!"calib:eth-a{amountEth}-f{feeBps}"
        , mkEntry resourceIdBold amountBold feeBps calibRateBold did
            s!"calib:bold-a{amountBold}-f{feeBps}" ]
      did := did + 1
  return acc

/-- The full deterministic entry list:
    `160 grid + 6 boundary + 24 calibration = 190`.  The grid is
    `2 legs × 4 amounts × 5 fee-bps × 4 rates = 160`; the calibration
    block is `3 amounts × 4 fees × 2 legs = 24` (12 USD-calibrated
    pairs). -/
def allEntries : List Entry := gridEntries ++ boundaryEntries ++ calibrationEntries

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
  [ { name := "GP.6.5: bold_deposit corpus has exactly 190 entries (≥ 50)"
    , body := do
        -- 160 grid + 6 boundary + 24 calibration = 190.
        if gridEntries.length ≠ 160 then
          throw <| IO.userError s!"expected 160 grid entries, got {gridEntries.length}"
        if boundaryEntries.length ≠ 6 then
          throw <| IO.userError s!"expected 6 boundary entries, got {boundaryEntries.length}"
        if calibrationEntries.length ≠ 24 then
          throw <| IO.userError s!"expected 24 calibration entries, got {calibrationEntries.length}"
        if allEntries.length ≠ 190 then
          throw <| IO.userError s!"expected 190 entries, got {allEntries.length}"
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
  , { name := "GP.6.5: exactly 20 entries clamp the budget at the cap (≥ 5)"
    , body := do
        -- 16 grid (rate-1 entries with pool ≥ 10^12) + 4 boundary
        -- (the two 10^18 @ 50 % @ rate-1 legs and the two
        -- u64::MAX @ 50 % @ rate-1 legs) = 20.  Pinned EXACTLY so a
        -- corpus regression that drops clamp coverage cannot hide
        -- behind a loose `≥ 5` floor; the `≥ 5` spec floor is also
        -- (re)checked.
        if clampActiveCount ≠ 20 then
          throw <| IO.userError s!"expected exactly 20 clamp-active entries, got {clampActiveCount}"
        if clampActiveCount < 5 then
          throw <| IO.userError s!"only {clampActiveCount} clamp-active entries; expected ≥ 5"
    }
  , { name := "GP.6.5: grid resource-agnosticism (80 twins; same triple ⇒ same split)"
    , body := do
        -- Each grid ETH entry has exactly one BOLD twin sharing
        -- (amount, feeBps, weiPerBudgetUnit, depositId); the split is
        -- resource-INDEPENDENT, so the twin's (user, pool, budget) must
        -- be IDENTICAL (the amounts are the same — this is NOT the
        -- USD-calibration property, which uses DIFFERENT amounts; see
        -- the dedicated calibration test below).  Pinned at exactly 80
        -- twin pairs (4 amounts × 5 fees × 4 rates).
        let eths := gridEntries.filter (fun e => e.resourceId == resourceIdEth)
        let mut twins : Nat := 0
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
            twins := twins + 1
            if eth.userAmount ≠ bold.userAmount
               ∨ eth.poolAmount ≠ bold.poolAmount
               ∨ eth.budgetGrant ≠ bold.budgetGrant then
              throw <| IO.userError <|
                s!"resource-agnosticism broken for {eth.category}: " ++
                s!"({eth.userAmount},{eth.poolAmount},{eth.budgetGrant}) vs " ++
                s!"({bold.userAmount},{bold.poolAmount},{bold.budgetGrant})"
        if twins ≠ 80 then
          throw <| IO.userError s!"expected exactly 80 grid twin pairs, got {twins}"
    }
  , { name := "GP.6.5: USD-calibration parity (12 pairs; different amounts ⇒ equal budget)"
    , body := do
        -- The spec's calibration-parity deliverable: ETH and BOLD
        -- legs carrying DIFFERENT amounts (amount_bold = 3000 ·
        -- amount_eth) at DIFFERENT rates (rate_bold = 3000 · rate_eth),
        -- calibrated to the same USD value, must yield EQUAL budget
        -- grants.  Pair the two legs by their shared unique depositId.
        let calibEths := calibrationEntries.filter (fun e => e.resourceId == resourceIdEth)
        let mut pairs : Nat := 0
        for eth in calibEths do
          let partner? := calibrationEntries.find? (fun b =>
            b.resourceId == resourceIdBold && b.depositId == eth.depositId)
          match partner? with
          | none => throw <| IO.userError s!"no BOLD calibration partner for {eth.category}"
          | some bold =>
            pairs := pairs + 1
            -- Calibration is EXACT: amount_eth / rate_eth =
            -- amount_bold / rate_bold (both = amount_eth / 10^12), so
            -- the budget grants are byte-for-byte equal, not merely
            -- within floor-division residue.
            if eth.amount == bold.amount then
              throw <| IO.userError <|
                s!"calibration pair {eth.category} has IDENTICAL amounts " ++
                s!"({eth.amount}); expected different (cross-amount) legs"
            if eth.amount * calibRateBold ≠ bold.amount * calibRateEth then
              throw <| IO.userError <|
                s!"calibration pair {eth.category} not USD-aligned: " ++
                s!"{eth.amount}/{calibRateEth} ≠ {bold.amount}/{calibRateBold}"
            if eth.budgetGrant ≠ bold.budgetGrant then
              throw <| IO.userError <|
                s!"USD-calibration parity broken for {eth.category}: " ++
                s!"budget_eth {eth.budgetGrant} ≠ budget_bold {bold.budgetGrant}"
            -- Guard against the vacuous all-zero case: each calibration
            -- pair must grant a positive budget (the fees are non-zero
            -- and the amounts large enough to clear the rate).
            if eth.budgetGrant == 0 then
              throw <| IO.userError s!"calibration pair {eth.category} has a zero budget grant"
        if pairs ≠ 12 then
          throw <| IO.userError s!"expected exactly 12 USD-calibration pairs, got {pairs}"
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
  , { name := "GP.6.5: hand-pinned budget anchors across the regime (0, 50, cap)"
    , body := do
        -- Span the budget-grant regime with LITERAL byte ground truth
        -- (not a recompute): floored-to-zero, mid (50), and the clamp
        -- cap 10^12.  Each is `[00][epoch 0 LE 8B] [00][budget LE 8B]`.
        let check (g : Nat) (expected : String) : IO Unit := do
          let got := hexFromBytes (budgetBytes (recipientBudgetCell g))
          if got ≠ expected then
            throw <| IO.userError <|
              s!"budget anchor g={g} mismatch:\n  got      {got}\n  expected {expected}"
        -- g = 0 (floored-to-zero): all eighteen bytes zero.
        check 0 ("0x" ++ "000000000000000000" ++ "000000000000000000")
        -- g = 50 (0x32 LE): redundant with the entry anchor above, kept
        -- so the three regime points read together.
        check 50 ("0x" ++ "000000000000000000" ++ "003200000000000000")
        -- g = MAX_BUDGET_PER_DEPOSIT = 10^12 = 0xE8D4A51000;
        -- 8-byte LE = 00 10 a5 d4 e8 00 00 00.
        check DepositFeeSplit.maxBudgetPerDeposit
          ("0x" ++ "000000000000000000" ++ "000010a5d4e8000000")
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
  , { name := "GP.6.5: recipient currentBudget binding == budgetGrant (value-level)"
    , body := do
        -- Value-level witness of `recipientBudgetCell_currentBudget`:
        -- across the corpus's budget magnitudes (zero, mid, the clamp
        -- cap), the modelled ledger's recipient `currentBudget` equals
        -- the `budgetGrant` the fixture carries.  The theorem proves
        -- this for ALL `budgetGrant`; this case exercises it at runtime
        -- on the boundary values the corpus actually emits.
        for g in [0, 1, 50, 1000, DepositFeeSplit.maxBudgetPerDeposit] do
          let cb := EpochBudgetState.currentBudget (recipientBudgetLedger g)
                      (UInt64.ofNat fixedRecipient) 0 0
          if cb ≠ g then
            throw <| IO.userError s!"currentBudget binding broken at g={g}: got {cb}"
          -- And the modelled cell's balance matches (the byte source).
          if (recipientBudgetCell g).budgetBalance ≠ g then
            throw <| IO.userError s!"recipientBudgetCell budgetBalance ≠ {g}"
    }
  , { name := "recipientBudgetCell_currentBudget API stability"
    , body := do
        -- Term-level pin: the value-binding theorem's signature is
        -- stable.  Elaboration fails if it changes.
        let _proof := @recipientBudgetCell_currentBudget
        pure ()
    }
  , { name := "recipientBudgetCell_matches_gate API stability"
    , body := do
        -- Term-level pin on the GATE-binding theorem — the load-bearing
        -- guarantee that the corpus budget tracks the production
        -- `apply_admissible_with_budget` grant arm.  If the gate's
        -- depositWithFee branch is refactored away from
        -- `topUp recipient currentEpoch freeTier budgetGrant`, the
        -- theorem stops elaborating and THIS test fails the build.
        let _proof := @recipientBudgetCell_matches_gate
        pure ()
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
