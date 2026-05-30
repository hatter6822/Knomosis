/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.EventCbe — WU GP.6.3 / RH-D.

Generates the `event_subscribe_cbe.json` cross-stack fixture: one
reference vector per `Events.Event` constructor (frozen tags 0..20,
including the GP.6.4 `budgetConsumed` at tag 20), each carrying the
constructor's canonical CBE bytes computed by LEAN's
`Encoding.Event.encode`.

**Why this fixture exists.**  The Rust event-subscription server
(`knomosis-event-subscribe`) reads the leading constructor tag from
the CBE-encoded `Event` payloads it streams, via
`event_type::peek_event_tag` / `EventClass::classify`.  Until the
Lean `Encodable Event` instance landed (this workstream), the Rust
side's wire assumption — "the leading 9 bytes are a `0x00`-tag +
8-byte-LE constructor index" — was verified only against the CBE
*convention* and the indexer's self-consistent decoder, NOT against
real Lean output.  This fixture closes that gap: the `expectedCbe`
field of every entry is the hex of Lean's `Event.encode`, and the
Rust consumer
(`runtime/knomosis-event-subscribe/tests/cross_stack_lean_event.rs`)
asserts `peek_event_tag` reads exactly `tag` and `classify` resolves
to the named `EventType` for all 20 constructors.

**What it catches.**  A Lean encoder change (frozen-index bump,
field-order edit) drifts the committed JSON — `lake test`'s
verify-mode catches it Lean-side, and the Rust consumer catches it
once regenerated.  A Rust registry/peek bug — wrong head width,
wrong tag byte, big-endian read — fails the consumer assertions.

**Hash independence.**  Pure CBE byte-encoding of the `Event`
inductive; no hashing involved.  The cross-check runs
unconditionally regardless of the kernel's hash binding.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Events
open LegalKernel.Test

namespace EventCbe

/-- The number of frozen `Event` constructors (mirrors the Rust
    `event_type::KNOWN_EVENT_TAG_COUNT`).  Bumped 20 → 21 by
    GP.6.4 (the `budgetConsumed` event at tag 20). -/
def knownTagCount : Nat := 21

/-- Encode an `Event` with Lean's canonical `Event.encode` and return
    the `0x`-prefixed lowercase hex of the byte stream — the
    load-bearing value the Rust consumer reads. -/
def encodeEventHex (e : Event) : String :=
  hexFromBytes (ByteArray.mk (Encodable.encode (T := Event) e).toArray)

/-- The canonical lowerCamelCase constructor name, matching
    `LegalKernel/Events/Types.lean`, the §5.3 ABI table, and the Rust
    `EventType::name`. -/
def eventKind : Event → String
  | .balanceChanged ..             => "balanceChanged"
  | .nonceAdvanced ..              => "nonceAdvanced"
  | .identityRegistered ..         => "identityRegistered"
  | .identityRevoked ..            => "identityRevoked"
  | .timeRecorded ..               => "timeRecorded"
  | .disputeFiled ..               => "disputeFiled"
  | .disputeWithdrawn ..           => "disputeWithdrawn"
  | .verdictApplied ..             => "verdictApplied"
  | .rewardIssued ..               => "rewardIssued"
  | .withdrawalRequested ..        => "withdrawalRequested"
  | .depositCredited ..            => "depositCredited"
  | .localPolicyDeclared ..        => "localPolicyDeclared"
  | .localPolicyRevoked ..         => "localPolicyRevoked"
  | .faultProofGameOpened ..       => "faultProofGameOpened"
  | .faultProofBisectionStep ..    => "faultProofBisectionStep"
  | .faultProofGameSettled ..      => "faultProofGameSettled"
  | .depositWithFeeCredited ..     => "depositWithFeeCredited"
  | .actionBudgetTopUp ..          => "actionBudgetTopUp"
  | .gasPoolClaim ..               => "gasPoolClaim"
  | .delegatedActionBudgetTopUp .. => "delegatedActionBudgetTopUp"
  | .budgetConsumed ..             => "budgetConsumed"

/-- A non-zero 20-byte `EthAddress` for the `withdrawalRequested`
    entry. -/
def sampleAddr : Bridge.EthAddress :=
  (Bridge.EthAddress.ofBytes
      (ByteArray.mk #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                      11, 12, 13, 14, 15, 16, 17, 18, 19, 20])).getD
    Bridge.EthAddress.zero

/-- Build one fixture entry from an event + a category label. -/
def mkEntry (e : Event) (category : String) : Json :=
  .obj
    [ ("kind",        .str (eventKind e))
    , ("tag",         .num (Event.tag e))
    , ("category",    .str category)
    , ("expectedCbe", .str (encodeEventHex e))
    ]

/-- One canonical event per frozen constructor, in tag order
    (`canonicalEvents[i].tag = i`).  The single source of truth for
    the canonical entries and the tag-coverage test. -/
def canonicalEvents : List Event :=
  [ .balanceChanged 7 42 100 250
  , .nonceAdvanced 9 0 1
  , .identityRegistered 1 (ByteArray.mk #[0xab, 0xcd, 0xef])
  , .identityRevoked 12
  , .timeRecorded 1700000000
  , .disputeFiled 3 100
  , .disputeWithdrawn 99
  , .verdictApplied 99 0
  , .rewardIssued 2 5 1000000
  , .withdrawalRequested 4 7 50000 sampleAddr 42
  , .depositCredited 4 7 100000 42
  , .localPolicyDeclared 9 { clauses := [] }
  , .localPolicyRevoked 9
  , .faultProofGameOpened 1 2 3 4 (ByteArray.mk #[0xAB, 0xCD])
  , .faultProofBisectionStep 1 5 7 100 (ByteArray.mk #[0xCC, 0xDD, 0xEE])
  , .faultProofGameSettled 1 2 3 1000
  , .depositWithFeeCredited 0 7 1 900 100 50 12
  , .actionBudgetTopUp 7 0 500 10 1
  , .gasPoolClaim 0 2 250
  , .delegatedActionBudgetTopUp 9 7 0 500 10 1
  , .budgetConsumed 42 1 ]

/-- The six gas-pool-family edge-value events (tags 16..20),
    exercising the Rust head peek across field magnitudes.
    Includes one `budgetConsumed` edge case (tag 20) added in
    GP.6.4. -/
def gasPoolEdgeEvents : List Event :=
  [ .depositWithFeeCredited 0 0 0 0 0 0 0
  , .actionBudgetTopUp 0 0 0 0 0
  , .gasPoolClaim 0 0 0
  , .delegatedActionBudgetTopUp 0 0 0 0 0 0
  , .gasPoolClaim 18446744073709551615 18446744073709551615 18446744073709551615
  , .budgetConsumed 0 0 ]

/-- The fixture entries: one canonical vector per frozen constructor
    (tags 0..20, in order), plus the gas-pool edge-value variants. -/
def entries : List Json :=
  canonicalEvents.map (mkEntry · "canonical") ++
  gasPoolEdgeEvents.map (mkEntry · "gp-edge")

/-- The fixture's JSON value: a header + the entries array. -/
def buildFixture : Json :=
  let header : Json := .obj
    [ ("identifier",     .str "knomosis-event-subscribe/event-cbe/v1")
    , ("count",          .num entries.length)
    , ("knownTagCount",  .num knownTagCount)
    , ("note",
        .str ("expectedCbe is Lean Encoding.Event.encode of the constructor; " ++
              "knomosis-event-subscribe peek_event_tag must read `tag` from its leading 9-byte head"))
    ]
  .obj
    [ ("header",  header)
    , ("entries", .arr entries)
    ]

/-- Fixture file name. -/
def fixtureName : String := "event_subscribe_cbe.json"

/-! ## Test cases -/

/-- The fixture has 27 entries (21 canonical 0..=20 + 6 gas-pool
    edge cases including the `budgetConsumed` edge added in GP.6.4). -/
def entryCount : TestCase := {
  name := "GP.6.4: event_subscribe_cbe fixture has 27 entries"
  body := do
    assertEq (27 : Nat) entries.length "entry count"
}

/-- The 21 canonical entries cover tags 0..20 in order
    (GP.6.4 widened from 20 → 21 by adding `budgetConsumed`). -/
def canonicalCoversAllTags : TestCase := {
  name := "GP.6.4: canonical entries cover tags 0..20"
  body := do
    assertEq (21 : Nat) canonicalEvents.length "canonical count"
    assertEq (List.range 21) (canonicalEvents.map Event.tag) "canonical tags 0..20 in order"
}

/-- The serialised JSON contains one entry-record per built entry
    (serialiser shape-preservation). -/
def jsonShapePreserving : TestCase := {
  name := "GP.6.3: fixture JSON has one record per entry"
  body := do
    let s := buildFixture.encode
    let occ := (s.splitOn "\"expectedCbe\":").length - 1
    assertEq entries.length occ "expectedCbe occurrences"
}

/-- Non-circular ground-truth pin: `gasPoolClaim 0 2 250` encodes to
    the exact 36-byte hex below (tag-18 head + three uint heads),
    independent of the encoder under test. -/
def gasPoolClaimGroundTruth : TestCase := {
  name := "GP.6.3: gasPoolClaim canonical hex pinned to ground truth"
  body := do
    let hex := encodeEventHex (Event.gasPoolClaim 0 2 250)
    -- Spell the 36-byte stream explicitly: tag 18, r 0, sequencer 2,
    -- amount 250.  Each head = 0x00 ‖ 8-byte LE value.
    let want :=
      "0x" ++
      "001200000000000000" ++   -- tag = 18 (0x12)
      "000000000000000000" ++   -- r = 0
      "000200000000000000" ++   -- sequencer = 2
      "00fa00000000000000"      -- amount = 250 (0xfa)
    assertEq want hex "gasPoolClaim ground-truth hex"
}

/-- Write (or verify) the fixture file under
    `solidity/test/CrossCheck/fixtures/`. -/
def writeFixtureFile : TestCase := {
  name := "GP.6.3: write event_subscribe_cbe.json fixture"
  body := do
    writeFixture fixtureName (buildFixture.encode ++ "\n")
}

/-- All tests. -/
def tests : List TestCase :=
  [ entryCount
  , canonicalCoversAllTags
  , jsonShapePreserving
  , gasPoolClaimGroundTruth
  , writeFixtureFile ]

end EventCbe
end LegalKernel.Test.Bridge.CrossCheck
