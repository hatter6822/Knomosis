-- SPDX-License-Identifier: GPL-3.0-or-later
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

Covers: a per-constructor encode→decode round-trip sweep (all 23
frozen constructors 0..22, including the GP.6.4 `budgetConsumed` at
tag 20 and the GP.11.4 / GP.11.10 AMM pair at tags 21/22),
non-circular byte-layout pins for the leading tag head +
the Workstream-GP gas-pool family, value-level tag-agreement checks
(complementing the `Event.tag_matches_encode_tag` theorem),
constructor distinctness, and API-stability term checks.
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

/-- The 23 representative events, one per frozen constructor
    (tags 0..22).  The tag-20 `budgetConsumed` entry was added
    by GP.6.4; the tag-21 `ammSwapExecuted` and tag-22
    `ammReservesReclaimed` entries by GP.11.4 / GP.11.10.

    Every sweep below iterates this list, so an entry missing here
    silently removes a constructor from the round-trip, leading-head,
    determinism, and distinctness suites at once.  `requiredTag`
    guards against exactly that: it is total over `Event`, so a new
    constructor fails to elaborate until it is handled there, and
    `roundtripCoversAllTags` cross-checks this list against it. -/
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
  , .delegatedActionBudgetTopUp 9 7 0 500 10 1
  , .budgetConsumed 42 1
  , .ammSwapExecuted 0 1 1000 995 77
  , .ammReservesReclaimed 0 5000 77 88 ]

/-- The frozen tag every `Event` constructor must carry, spelled out
    by hand rather than read back from `Event.tag` — so this table is
    a NON-CIRCULAR pin: a renumbering of `Event.tag` disagrees with it
    and fails `roundtripCoversAllTags`.

    The match is total over `Event`, which is the structural half of
    the guard: adding a constructor to the inductive without adding an
    arm here is an elaboration error in this file, and the resulting
    build failure is what forces `sampleEvents` above to be extended
    in the same change.  Before this table existed, `sampleEvents` was
    pinned only by a hand-maintained `21` and silently omitted the two
    AMM constructors (tags 21/22) that GP.11.4 / GP.11.10 added. -/
def requiredTag : Event → Nat
  | .balanceChanged             .. =>  0
  | .nonceAdvanced              .. =>  1
  | .identityRegistered         .. =>  2
  | .identityRevoked            .. =>  3
  | .timeRecorded               .. =>  4
  | .disputeFiled               .. =>  5
  | .disputeWithdrawn           .. =>  6
  | .verdictApplied             .. =>  7
  | .rewardIssued               .. =>  8
  | .withdrawalRequested        .. =>  9
  | .depositCredited            .. => 10
  | .localPolicyDeclared        .. => 11
  | .localPolicyRevoked         .. => 12
  | .faultProofGameOpened       .. => 13
  | .faultProofBisectionStep    .. => 14
  | .faultProofGameSettled      .. => 15
  | .depositWithFeeCredited     .. => 16
  | .actionBudgetTopUp          .. => 17
  | .gasPoolClaim               .. => 18
  | .delegatedActionBudgetTopUp .. => 19
  | .budgetConsumed             .. => 20
  | .ammSwapExecuted            .. => 21
  | .ammReservesReclaimed       .. => 22

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
  name := "Event codec round-trips all 23 constructors"
  body := do
    for e in sampleEvents do
      assertRoundtrips e
}

/-- The round-trip sweep covers exactly the 23 frozen tags 0..22,
    one event per tag (catches an omitted / duplicated constructor
    in `sampleEvents`), and each sample's `Event.tag` agrees with the
    hand-spelled `requiredTag` table (catches a renumbering). -/
def roundtripCoversAllTags : TestCase := {
  name := "Event round-trip sweep covers tags 0..22"
  body := do
    let tags := (sampleEvents.map Event.tag)
    assertEq (23 : Nat) tags.length "sample count"
    -- Tags are exactly 0..22 in order.
    assertEq (List.range 23) tags "sample tags are 0..22 in order"
    -- Non-circular cross-check against the total `requiredTag` match:
    -- `Event.tag` must agree with the independently spelled table, so
    -- a renumbering of either is caught here rather than silently
    -- re-pinning both.
    for e in sampleEvents do
      assertEq (requiredTag e) (Event.tag e)
        s!"Event.tag agrees with requiredTag for tag {requiredTag e}"
}

/-- Non-circular byte-layout pin: `gasPoolClaim 0 2 250` (tag 18)
    encodes to three 9-byte CBE uint heads plus one 17-byte amount
    head (44 bytes), beginning with the hand-spelled `0x00`-tag +
    little-endian-18 head. -/
def gasPoolClaimByteLayout : TestCase := {
  name := "gasPoolClaim byte layout pinned"
  body := do
    let bytes := Encodable.encode (T := Event) (Event.gasPoolClaim 0 2 250)
    -- tag(18) + resource(0) + sequencer(2) are 9-byte uint heads;
    -- amount(250) is a 17-byte amount head.  3 × 9 + 17 = 44.
    assertEq (44 : Nat) bytes.length "gasPoolClaim encoded length"
    -- Leading head: 0x00 then 18 in the lowest LE byte, then 7 zeros.
    let head := bytes.take 9
    assertEq ([0x00, 18, 0, 0, 0, 0, 0, 0, 0] : List UInt8) head "gasPoolClaim tag head"
    -- The `amount = 250` field is a 17-byte amount head at offset 27:
    -- tag 0x01 then 250 (0xfa) in the lowest LE byte, then 15 zeros.
    assertEq ([0x01, 250, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] : List UInt8)
      ((bytes.drop 27).take 17) "gasPoolClaim amount field head"
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

/-- The GP-family events (16/17/18/19/20) encode to distinct byte
    sequences (their tags differ, so the leading heads differ).
    GP.6.4 added tag 20 (`budgetConsumed`) to the family. -/
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
    let h20 := (Encodable.encode (T := Event)
      (Event.budgetConsumed 42 1)).take 9
    assert
      (h16 != h17 && h16 != h18 && h16 != h19 && h16 != h20 &&
       h17 != h18 && h17 != h19 && h17 != h20 &&
       h18 != h19 && h18 != h20 && h19 != h20)
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

/-- Cross-stack-consistency pin: `localPolicyDeclared` (tag 11)
    encodes its `policy` field as a CBE BYTE STRING (head tag
    `0x02`), exactly what `knomosis-indexer::decoder`'s tag-11
    `read_byte_string` expects.  The structurally-distinct
    `Encodable LocalPolicy` form would not lead with `0x02` and would
    fail to decode on the Rust side. -/
def localPolicyDeclaredPolicyIsByteString : TestCase := {
  name := "localPolicyDeclared policy field is a CBE byte string (indexer-compatible)"
  body := do
    let bytes := Encodable.encode (T := Event) (Event.localPolicyDeclared 9 { clauses := [] })
    -- tag head (9) + actor head (9) = 18; the policy field's head
    -- begins at byte 18 and MUST be the byte-string tag 0x02.
    assertEq (0x02 : UInt8) ((bytes.drop 18).head!) "policy field head is the 0x02 byte-string tag"
}

/-- All tests. -/
def tests : List TestCase :=
  [ roundtripAllConstructors
  , roundtripCoversAllTags
  , gasPoolClaimByteLayout
  , localPolicyDeclaredPolicyIsByteString
  , leadingTagHeadMatchesTag
  , gasPoolFamilyDistinct
  , encodeDeterministic
  , decodeRejectsUnknownTag
  , decodeNeverPanics
  , tagMatchesEncodeTagAPI ]

end EventTests
end LegalKernel.Test.Encoding
