/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.Event — tests for the §8.9.2 `Event` CBE
codec (`LegalKernel/Encoding/Event.lean`).

Covers: a per-constructor encode→decode round-trip sweep (all 20
frozen constructors 0..19), non-circular byte-layout pins for the
leading tag head + the Workstream-GP gas-pool family, value-level
tag-agreement checks (complementing the `Event.tag_matches_encode_tag`
theorem), constructor distinctness, and API-stability term checks.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.Event

namespace LegalKernel.Test.Encoding
namespace EventTests

open LegalKernel.Encoding
open LegalKernel.Authority
open LegalKernel.Events

/-- A non-zero 20-byte `EthAddress` for the `withdrawalRequested`
    round-trip (falls back to `zero` only if the 20-byte literal
    somehow fails `ofBytes`, which it does not). -/
def sampleAddr : Bridge.EthAddress :=
  (Bridge.EthAddress.ofBytes
      (ByteArray.mk #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                      11, 12, 13, 14, 15, 16, 17, 18, 19, 20])).getD
    Bridge.EthAddress.zero

/-- The 20 representative events, one per frozen constructor. -/
def sampleEvents : List Event :=
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
  , .delegatedActionBudgetTopUp 9 7 0 500 10 1 ]

/-- Assert that `e` encodes and decodes back to itself, consuming
    the whole stream (no trailing bytes). -/
def assertRoundtrips (e : Event) : IO Unit := do
  let bytes := Encodable.encode (T := Event) e
  match Event.decode bytes with
  | .ok (e', rest) =>
    assertEq e e' s!"event {Event.tag e} round-trip value"
    assertEq ([] : Stream) rest s!"event {Event.tag e} round-trip tail"
  | .error err =>
    throw <| IO.userError s!"event {Event.tag e} decode failed: {repr err}"

/-- Every frozen constructor round-trips encode→decode. -/
def roundtripAllConstructors : TestCase := {
  name := "Event codec round-trips all 20 constructors"
  body := do
    for e in sampleEvents do
      assertRoundtrips e
}

/-- The round-trip sweep covers exactly the 20 frozen tags 0..19,
    one event per tag (catches an omitted / duplicated constructor
    in `sampleEvents`). -/
def roundtripCoversAllTags : TestCase := {
  name := "Event round-trip sweep covers tags 0..19"
  body := do
    let tags := (sampleEvents.map Event.tag)
    assertEq (20 : Nat) tags.length "sample count"
    -- Tags are exactly 0..19 in order.
    assertEq (List.range 20) tags "sample tags are 0..19 in order"
}

/-- Non-circular byte-layout pin: `gasPoolClaim 0 2 250` (tag 18)
    encodes to exactly 4 CBE uint heads (36 bytes), beginning with
    the hand-spelled `0x00`-tag + little-endian-18 head. -/
def gasPoolClaimByteLayout : TestCase := {
  name := "gasPoolClaim byte layout pinned"
  body := do
    let bytes := Encodable.encode (T := Event) (Event.gasPoolClaim 0 2 250)
    -- tag(18) + resource(0) + sequencer(2) + amount(250) = 4 × 9 = 36.
    assertEq (36 : Nat) bytes.length "gasPoolClaim encoded length"
    -- Leading head: 0x00 then 18 in the lowest LE byte, then 7 zeros.
    let head := bytes.take 9
    assertEq ([0x00, 18, 0, 0, 0, 0, 0, 0, 0] : List UInt8) head "gasPoolClaim tag head"
    -- The `amount = 250` field's head is at offset 27.
    assertEq ([0x00, 250, 0, 0, 0, 0, 0, 0, 0] : List UInt8)
      ((bytes.drop 27).take 9) "gasPoolClaim amount field head"
}

/-- The leading 9-byte CBE head of every event's encoding equals
    `Encodable.encode (T := Nat) (Event.tag e)` — the value-level
    companion to `Event.tag_matches_encode_tag`, and the exact
    contract `knomosis-event-subscribe::peek_event_tag` relies on. -/
def leadingTagHeadMatchesTag : TestCase := {
  name := "Event encoding leads with the tag head"
  body := do
    for e in sampleEvents do
      let bytes := Encodable.encode (T := Event) e
      let tagHead := Encodable.encode (T := Nat) (Event.tag e)
      assertEq (9 : Nat) tagHead.length s!"tag head width for tag {Event.tag e}"
      assertEq tagHead (bytes.take tagHead.length)
        s!"leading head for tag {Event.tag e}"
}

/-- The GP-family events (16/17/18/19) encode to distinct byte
    sequences (their tags differ, so the leading heads differ). -/
def gasPoolFamilyDistinct : TestCase := {
  name := "gas-pool-family events encode distinctly"
  body := do
    let h16 := (Encodable.encode (T := Event)
      (Event.depositWithFeeCredited 0 7 1 900 100 50 12)).take 9
    let h17 := (Encodable.encode (T := Event)
      (Event.actionBudgetTopUp 7 0 500 10 1)).take 9
    let h18 := (Encodable.encode (T := Event)
      (Event.gasPoolClaim 0 2 250)).take 9
    let h19 := (Encodable.encode (T := Event)
      (Event.delegatedActionBudgetTopUp 9 7 0 500 10 1)).take 9
    assert
      (h16 != h17 && h16 != h18 && h16 != h19 &&
       h17 != h18 && h17 != h19 && h18 != h19)
      "gas-pool-family leading heads must be pairwise distinct"
}

/-- Encoding is deterministic (same event ⇒ same bytes). -/
def encodeDeterministic : TestCase := {
  name := "Event encode is deterministic"
  body := do
    for e in sampleEvents do
      let a := Encodable.encode (T := Event) e
      let b := Encodable.encode (T := Event) e
      assertEq a b s!"determinism for tag {Event.tag e}"
}

/-- Decoder rejects an out-of-range constructor tag (≥ 20) with
    `invalidConstructorIndex` rather than producing a bogus event. -/
def decodeRejectsUnknownTag : TestCase := {
  name := "Event decode rejects unknown constructor tag"
  body := do
    -- A lone tag-50 uint head (CBE-encoded Nat 50), no fields.
    let bytes := Encodable.encode (T := Nat) 50
    match Event.decode bytes with
    | .error (.invalidConstructorIndex n) => assertEq (50 : Nat) n "unknown tag value"
    | other => throw <| IO.userError s!"expected invalidConstructorIndex, got {repr other}"
}

/-- Decoder is total / never panics on adversarial byte patterns
    (returns `.ok` or `.error`, never diverges). -/
def decodeNeverPanics : TestCase := {
  name := "Event decode is total on adversarial input"
  body := do
    let patterns : List Stream :=
      [ [], [0x00], List.replicate 100 0xFF,
        [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        [0x02, 0, 0, 0, 0, 0, 0, 0, 0] ]
    for p in patterns do
      let _ := Event.decode p
      pure ()
}

/-- API stability: `Event.tag_matches_encode_tag` keeps its
    signature (elaboration-time check). -/
def tagMatchesEncodeTagAPI : TestCase := {
  name := "Event.tag_matches_encode_tag API stable"
  body := do
    let _proof : ∀ e : Event,
        ∃ tail : Stream,
          Encodable.encode (T := Event) e =
          Encodable.encode (T := Nat) (Event.tag e) ++ tail :=
      Event.tag_matches_encode_tag
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [ roundtripAllConstructors
  , roundtripCoversAllTags
  , gasPoolClaimByteLayout
  , leadingTagHeadMatchesTag
  , gasPoolFamilyDistinct
  , encodeDeterministic
  , decodeRejectsUnknownTag
  , decodeNeverPanics
  , tagMatchesEncodeTagAPI ]

end EventTests
end LegalKernel.Test.Encoding
