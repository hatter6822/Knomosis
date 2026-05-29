/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.Event — the §8.9.2 `Event` CBE codec.

Defines the canonical wire encoding of the deployment-facing
`Events.Event` inductive: the byte sequence the `knomosis
extract-events` subcommand emits per event, and the off-chain
event-subscription server (`knomosis-event-subscribe`) streams to
subscribers.  Until this module, the `Event` wire format was
*assumed* by the Rust consumers (`knomosis-indexer::decoder` decodes
it; `knomosis-event-subscribe::event_type` peeks its leading tag)
but had no Lean-side authority.  This module IS that authority.

**Layout.**  Each `Event` is encoded as a constructor-tag uint
(matching `Event.tag`, frozen indices 0..19) followed by the
constructor's fields in declaration order, mirroring
`Encoding.Action.encode`:

  * `ResourceId` / `ActorId` (`UInt64`) → `Encodable.encode (T := Nat)`
    of `.toNat` (a CBE uint head).
  * `Amount` / `Nonce` / `DepositId` / `WithdrawalId` / general `Nat`
    → `Encodable.encode (T := Nat)` (a CBE uint head).
  * `PublicKey` (`ByteArray`) and the fault-proof hash fields
    (`bindingHash`, `commit`) → `Encodable.encode (T := ByteArray)`
    (a CBE byte string).
  * `Bridge.EthAddress` → `Encodable.encode (T := ByteArray)` of the
    20-byte `EthAddress.toBytes` (a CBE byte string), decoded back
    via `EthAddress.ofBytes` — exactly as `Action.encode` handles
    the `withdraw` recipient.
  * `Authority.LocalPolicy` (the `localPolicyDeclared` field) →
    `Encodable.encode (T := LocalPolicy)` (the structured policy
    encoding), exactly as `Action.encode` handles the
    `declareLocalPolicy` field.

The leading tag is the load-bearing wire contract: the streamer's
`peek_event_tag` reads exactly the first 9-byte CBE uint head, and
`Event.tag_matches_encode_tag` proves the encoding always begins
with `Encodable.encode (T := Nat) (Event.tag e)`.

**Trust posture.**  This module is **NOT** part of the trusted
computing base.  `Event` values are observations derived from log
entries (§8.9.1); an encoding bug here misleads an indexer but
cannot violate any kernel invariant.  Lean never *decodes* an
`Event` in production (events flow Lean → Rust), so the symmetric
`Event.decode` exists for codec completeness + the round-trip test
sweep in `LegalKernel/Test/Encoding/Event.lean`, while the
load-bearing soundness guarantee is the tag-agreement theorem.
-/

import LegalKernel.Events.Types
import LegalKernel.Encoding.Action
import LegalKernel.Encoding.LocalPolicy

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority
open LegalKernel.Events

/-! ## `Event.encode` (§8.9.2)

Constructor-tag uint + fields in declaration order.  Total on every
`Event`; lossy (modular truncation) only on numeric fields `≥ 2^64`,
identical to `Action.encode`'s documented behaviour. -/

/-- Encode an `Event` to its canonical CBE byte stream.  The leading
    9 bytes are the constructor-tag uint head (`Event.tag`); the
    remaining bytes are the fields in declaration order.  Mirrors
    `Encoding.Action.encode` and matches `knomosis-indexer`'s
    `decode_event` field layout. -/
def Event.encode : Event → Stream
  | .balanceChanged r a oldV newV =>
      Encodable.encode (T := Nat) 0 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) a.toNat ++
      Encodable.encode (T := Nat) oldV ++
      Encodable.encode (T := Nat) newV
  | .nonceAdvanced a oldN newN =>
      Encodable.encode (T := Nat) 1 ++
      Encodable.encode (T := Nat) a.toNat ++
      Encodable.encode (T := Nat) oldN ++
      Encodable.encode (T := Nat) newN
  | .identityRegistered a key =>
      Encodable.encode (T := Nat) 2 ++
      Encodable.encode (T := Nat) a.toNat ++
      Encodable.encode (T := ByteArray) key
  | .identityRevoked a =>
      Encodable.encode (T := Nat) 3 ++
      Encodable.encode (T := Nat) a.toNat
  | .timeRecorded t =>
      Encodable.encode (T := Nat) 4 ++
      Encodable.encode (T := Nat) t
  | .disputeFiled challenger targetIdx =>
      Encodable.encode (T := Nat) 5 ++
      Encodable.encode (T := Nat) challenger.toNat ++
      Encodable.encode (T := Nat) targetIdx
  | .disputeWithdrawn disputeIdx =>
      Encodable.encode (T := Nat) 6 ++
      Encodable.encode (T := Nat) disputeIdx
  | .verdictApplied disputeIdx outcomeTag =>
      Encodable.encode (T := Nat) 7 ++
      Encodable.encode (T := Nat) disputeIdx ++
      Encodable.encode (T := Nat) outcomeTag
  | .rewardIssued resource recipient amount =>
      Encodable.encode (T := Nat) 8 ++
      Encodable.encode (T := Nat) resource.toNat ++
      Encodable.encode (T := Nat) recipient.toNat ++
      Encodable.encode (T := Nat) amount
  | .withdrawalRequested resource sender amount recipientL1 withdrawalId =>
      Encodable.encode (T := Nat) 9 ++
      Encodable.encode (T := Nat) resource.toNat ++
      Encodable.encode (T := Nat) sender.toNat ++
      Encodable.encode (T := Nat) amount ++
      Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes recipientL1) ++
      Encodable.encode (T := Nat) withdrawalId
  | .depositCredited resource recipient amount depositId =>
      Encodable.encode (T := Nat) 10 ++
      Encodable.encode (T := Nat) resource.toNat ++
      Encodable.encode (T := Nat) recipient.toNat ++
      Encodable.encode (T := Nat) amount ++
      Encodable.encode (T := Nat) depositId
  | .localPolicyDeclared actor policy =>
      -- The `policy` field is a CBE BYTE STRING wrapping the
      -- structured `LocalPolicy.encode` bytes — matching
      -- `knomosis-indexer::decoder`'s tag-11 `read_byte_string`
      -- ("opaque policy bytes").  Encoding it structurally
      -- (`Encodable.encode (T := LocalPolicy)`) would NOT lead with a
      -- `0x02` byte-string head and so would not decode on the Rust
      -- side; the wrap keeps the full 0..15 encoding byte-equivalent
      -- to the indexer's existing decoder.
      Encodable.encode (T := Nat) 11 ++
      Encodable.encode (T := Nat) actor.toNat ++
      Encodable.encode (T := ByteArray) (LocalPolicy.encodeAsBytes policy)
  | .localPolicyRevoked actor =>
      Encodable.encode (T := Nat) 12 ++
      Encodable.encode (T := Nat) actor.toNat
  | .faultProofGameOpened gameId challenger startIdx endIdx bindingHash =>
      Encodable.encode (T := Nat) 13 ++
      Encodable.encode (T := Nat) gameId ++
      Encodable.encode (T := Nat) challenger.toNat ++
      Encodable.encode (T := Nat) startIdx ++
      Encodable.encode (T := Nat) endIdx ++
      Encodable.encode (T := ByteArray) bindingHash
  | .faultProofBisectionStep gameId round party idx commit =>
      Encodable.encode (T := Nat) 14 ++
      Encodable.encode (T := Nat) gameId ++
      Encodable.encode (T := Nat) round ++
      Encodable.encode (T := Nat) party.toNat ++
      Encodable.encode (T := Nat) idx ++
      Encodable.encode (T := ByteArray) commit
  | .faultProofGameSettled gameId winner loser payout =>
      Encodable.encode (T := Nat) 15 ++
      Encodable.encode (T := Nat) gameId ++
      Encodable.encode (T := Nat) winner.toNat ++
      Encodable.encode (T := Nat) loser.toNat ++
      Encodable.encode (T := Nat) payout
  | .depositWithFeeCredited resource recipient poolActor userAmount poolAmount budgetGrant depositId =>
      Encodable.encode (T := Nat) 16 ++
      Encodable.encode (T := Nat) resource.toNat ++
      Encodable.encode (T := Nat) recipient.toNat ++
      Encodable.encode (T := Nat) poolActor.toNat ++
      Encodable.encode (T := Nat) userAmount ++
      Encodable.encode (T := Nat) poolAmount ++
      Encodable.encode (T := Nat) budgetGrant ++
      Encodable.encode (T := Nat) depositId
  | .actionBudgetTopUp signer gasResource gasAmount budgetIncrement poolActor =>
      Encodable.encode (T := Nat) 17 ++
      Encodable.encode (T := Nat) signer.toNat ++
      Encodable.encode (T := Nat) gasResource.toNat ++
      Encodable.encode (T := Nat) gasAmount ++
      Encodable.encode (T := Nat) budgetIncrement ++
      Encodable.encode (T := Nat) poolActor.toNat
  | .gasPoolClaim resource sequencer amount =>
      Encodable.encode (T := Nat) 18 ++
      Encodable.encode (T := Nat) resource.toNat ++
      Encodable.encode (T := Nat) sequencer.toNat ++
      Encodable.encode (T := Nat) amount
  | .delegatedActionBudgetTopUp recipient signer gasResource gasAmount budgetIncrement poolActor =>
      Encodable.encode (T := Nat) 19 ++
      Encodable.encode (T := Nat) recipient.toNat ++
      Encodable.encode (T := Nat) signer.toNat ++
      Encodable.encode (T := Nat) gasResource.toNat ++
      Encodable.encode (T := Nat) gasAmount ++
      Encodable.encode (T := Nat) budgetIncrement ++
      Encodable.encode (T := Nat) poolActor.toNat

/-! ## `Event.decode` (§8.9.2)

The inverse of `Event.encode`, mirroring `Action.decode`'s
nested-match idiom.  Reuses `Action.readUInt64Field` /
`Action.readNatField` (the shared field readers) plus
`Encodable.decode` for the `ByteArray` / `LocalPolicy` fields, and
`EthAddress.ofBytes` for the `withdrawalRequested` recipient.

Lean never decodes an `Event` in production (events flow Lean →
Rust); this exists for codec completeness and the round-trip test
sweep. -/

/-- Decode an `Event` from the front of a byte stream.  Returns the
    event and the unconsumed tail, or a typed `DecodeError`.  An
    out-of-range constructor tag yields `invalidConstructorIndex`. -/
def Event.decode (s : Stream) : Except DecodeError (Event × Stream) :=
  match Action.readNatField s with
  | .error e => .error e
  | .ok (0, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (a, s₃) =>
        match Action.readNatField s₃ with
        | .ok (oldV, s₄) =>
          match Action.readNatField s₄ with
          | .ok (newV, s₅) => .ok (.balanceChanged r a oldV newV, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (1, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (a, s₂) =>
      match Action.readNatField s₂ with
      | .ok (oldN, s₃) =>
        match Action.readNatField s₃ with
        | .ok (newN, s₄) => .ok (.nonceAdvanced a oldN newN, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (2, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (a, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (key, s₃) => .ok (.identityRegistered a key, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (3, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (a, s₂) => .ok (.identityRevoked a, s₂)
    | .error e => .error e
  | .ok (4, s₁) =>
    match Action.readNatField s₁ with
    | .ok (t, s₂) => .ok (.timeRecorded t, s₂)
    | .error e => .error e
  | .ok (5, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (challenger, s₂) =>
      match Action.readNatField s₂ with
      | .ok (targetIdx, s₃) => .ok (.disputeFiled challenger targetIdx, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (6, s₁) =>
    match Action.readNatField s₁ with
    | .ok (disputeIdx, s₂) => .ok (.disputeWithdrawn disputeIdx, s₂)
    | .error e => .error e
  | .ok (7, s₁) =>
    match Action.readNatField s₁ with
    | .ok (disputeIdx, s₂) =>
      match Action.readNatField s₂ with
      | .ok (outcomeTag, s₃) => .ok (.verdictApplied disputeIdx outcomeTag, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (8, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (resource, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (recipient, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) => .ok (.rewardIssued resource recipient amount, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (9, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (resource, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (sender, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) =>
          match Encodable.decode (T := ByteArray) s₄ with
          | .ok (rcpBytes, s₅) =>
            match Bridge.EthAddress.ofBytes rcpBytes with
            | some recipientL1 =>
              match Action.readNatField s₅ with
              | .ok (withdrawalId, s₆) =>
                .ok (.withdrawalRequested resource sender amount recipientL1 withdrawalId, s₆)
              | .error e => .error e
            | none =>
              .error (.invalidLength
                s!"withdrawalRequested recipientL1 expects 20 bytes; got {rcpBytes.size}")
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (10, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (resource, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (recipient, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) =>
          match Action.readNatField s₄ with
          | .ok (depositId, s₅) => .ok (.depositCredited resource recipient amount depositId, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (11, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (actor, s₂) =>
      -- Read the opaque policy byte string, then decode the inner
      -- `LocalPolicy` from its bytes (the wrap inverse of
      -- `LocalPolicy.encodeAsBytes`).  The inner decode must consume
      -- ALL the wrapped bytes; any residue is a malformed policy.
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (policyBytes, s₃) =>
        match LocalPolicy.decode policyBytes.toList with
        | .ok (policy, []) => .ok (.localPolicyDeclared actor policy, s₃)
        | .ok (_, residue) => .error (.trailingBytes residue.length)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (12, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (actor, s₂) => .ok (.localPolicyRevoked actor, s₂)
    | .error e => .error e
  | .ok (13, s₁) =>
    match Action.readNatField s₁ with
    | .ok (gameId, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (challenger, s₃) =>
        match Action.readNatField s₃ with
        | .ok (startIdx, s₄) =>
          match Action.readNatField s₄ with
          | .ok (endIdx, s₅) =>
            match Encodable.decode (T := ByteArray) s₅ with
            | .ok (bindingHash, s₆) =>
              .ok (.faultProofGameOpened gameId challenger startIdx endIdx bindingHash, s₆)
            | .error e => .error e
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (14, s₁) =>
    match Action.readNatField s₁ with
    | .ok (gameId, s₂) =>
      match Action.readNatField s₂ with
      | .ok (round, s₃) =>
        match Action.readUInt64Field s₃ with
        | .ok (party, s₄) =>
          match Action.readNatField s₄ with
          | .ok (idx, s₅) =>
            match Encodable.decode (T := ByteArray) s₅ with
            | .ok (commit, s₆) => .ok (.faultProofBisectionStep gameId round party idx commit, s₆)
            | .error e => .error e
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (15, s₁) =>
    match Action.readNatField s₁ with
    | .ok (gameId, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (winner, s₃) =>
        match Action.readUInt64Field s₃ with
        | .ok (loser, s₄) =>
          match Action.readNatField s₄ with
          | .ok (payout, s₅) => .ok (.faultProofGameSettled gameId winner loser payout, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (16, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (resource, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (recipient, s₃) =>
        match Action.readUInt64Field s₃ with
        | .ok (poolActor, s₄) =>
          match Action.readNatField s₄ with
          | .ok (userAmount, s₅) =>
            match Action.readNatField s₅ with
            | .ok (poolAmount, s₆) =>
              match Action.readNatField s₆ with
              | .ok (budgetGrant, s₇) =>
                match Action.readNatField s₇ with
                | .ok (depositId, s₈) =>
                  .ok (.depositWithFeeCredited resource recipient poolActor
                        userAmount poolAmount budgetGrant depositId, s₈)
                | .error e => .error e
              | .error e => .error e
            | .error e => .error e
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (17, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (signer, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (gasResource, s₃) =>
        match Action.readNatField s₃ with
        | .ok (gasAmount, s₄) =>
          match Action.readNatField s₄ with
          | .ok (budgetIncrement, s₅) =>
            match Action.readUInt64Field s₅ with
            | .ok (poolActor, s₆) =>
              .ok (.actionBudgetTopUp signer gasResource gasAmount budgetIncrement poolActor, s₆)
            | .error e => .error e
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (18, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (resource, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (sequencer, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) => .ok (.gasPoolClaim resource sequencer amount, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (19, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (recipient, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (signer, s₃) =>
        match Action.readUInt64Field s₃ with
        | .ok (gasResource, s₄) =>
          match Action.readNatField s₄ with
          | .ok (gasAmount, s₅) =>
            match Action.readNatField s₅ with
            | .ok (budgetIncrement, s₆) =>
              match Action.readUInt64Field s₆ with
              | .ok (poolActor, s₇) =>
                .ok (.delegatedActionBudgetTopUp recipient signer gasResource
                      gasAmount budgetIncrement poolActor, s₇)
              | .error e => .error e
            | .error e => .error e
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (n, _) => .error (.invalidConstructorIndex n)

/-- `Encodable Event` — the symmetric CBE codec used by the
    event-subscription wire format. -/
instance instEncodableEvent : Encodable Event where
  encode := Event.encode
  decode := Event.decode

/-! ## Tag-agreement (the load-bearing soundness guarantee)

The streamer's `peek_event_tag` reads exactly the leading 9-byte
CBE uint head and interprets it as the constructor tag.  This
theorem proves that interpretation is always correct: every
`Event.encode` output begins with `Encodable.encode (T := Nat)
(Event.tag e)`.  Mirrors `Action.tag_matches_encode_tag`. -/

/-- `Event.tag` agrees with the leading uint of `Event.encode`: the
    encoded stream begins with `Encodable.encode (T := Nat)
    (Event.tag e)` for every event.  Proven by `cases e` plus a
    per-branch `rfl`. -/
theorem Event.tag_matches_encode_tag (e : Event) :
    ∃ tail : Stream,
      Encodable.encode (T := Event) e =
      Encodable.encode (T := Nat) (Event.tag e) ++ tail := by
  cases e with
  | balanceChanged _ _ _ _              => exact ⟨_, rfl⟩
  | nonceAdvanced _ _ _                 => exact ⟨_, rfl⟩
  | identityRegistered _ _              => exact ⟨_, rfl⟩
  | identityRevoked _                   => exact ⟨_, rfl⟩
  | timeRecorded _                      => exact ⟨_, rfl⟩
  | disputeFiled _ _                    => exact ⟨_, rfl⟩
  | disputeWithdrawn _                  => exact ⟨_, rfl⟩
  | verdictApplied _ _                  => exact ⟨_, rfl⟩
  | rewardIssued _ _ _                  => exact ⟨_, rfl⟩
  | withdrawalRequested _ _ _ _ _       => exact ⟨_, rfl⟩
  | depositCredited _ _ _ _             => exact ⟨_, rfl⟩
  | localPolicyDeclared _ _             => exact ⟨_, rfl⟩
  | localPolicyRevoked _                => exact ⟨_, rfl⟩
  | faultProofGameOpened _ _ _ _ _      => exact ⟨_, rfl⟩
  | faultProofBisectionStep _ _ _ _ _   => exact ⟨_, rfl⟩
  | faultProofGameSettled _ _ _ _       => exact ⟨_, rfl⟩
  | depositWithFeeCredited _ _ _ _ _ _ _ => exact ⟨_, rfl⟩
  | actionBudgetTopUp _ _ _ _ _         => exact ⟨_, rfl⟩
  | gasPoolClaim _ _ _                  => exact ⟨_, rfl⟩
  | delegatedActionBudgetTopUp _ _ _ _ _ _ => exact ⟨_, rfl⟩

end Encoding
end LegalKernel
