/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.GameState — CBE codec for `GameState` and
its sub-types (Workstream H WU H.4.5).

The L1 fault-proof game contract stores the current `GameState`
in Solidity storage; cross-stack equivalence with the Lean side
requires a canonical byte encoding.  Layout matches the plan
§12.4.5 specification:

```
sequencer        : 8 bytes  (UInt64 / CBE uint head)
challenger       : 8 bytes
range.low.idx    : 8 bytes
range.low.commit : variable (CBE bstr)
range.high.idx   : 8 bytes
range.high.commit: variable (CBE bstr)
pendingMidpoint  : 1 byte  (Bool tag) + (Claim if Some)
depth            : 8 bytes
turn             : 1 byte  (TurnSide tag)
sequencerBond    : variable (CBE Nat)
challengerBond   : variable (CBE Nat)
status           : 1 byte  (GameStatus tag)
deploymentId     : variable (CBE bstr)
```

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Encoding.Encodable
import LegalKernel.FaultProof.Game

namespace LegalKernel
namespace Encoding

open LegalKernel.FaultProof
open LegalKernel.Authority

/-! ## `Claim` codec -/

/-- Encode a `Claim`. -/
def Claim.encode (c : LegalKernel.FaultProof.Claim) : Stream :=
  Encodable.encode (T := Nat) c.idx ++
  Encodable.encode (T := ByteArray) c.commit

/-- Decode a `Claim`. -/
def Claim.decode (s : Stream) :
    Except DecodeError (LegalKernel.FaultProof.Claim × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (idx, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (commit, s₂) => .ok ({ idx := idx, commit := commit }, s₂)
    | .error e => .error e
  | .error e => .error e

instance : Encodable LegalKernel.FaultProof.Claim where
  encode := Claim.encode
  decode := Claim.decode

/-! ## `DisputedRange` codec -/

/-- Encode a `DisputedRange`. -/
def DisputedRange.encode (r : LegalKernel.FaultProof.DisputedRange) : Stream :=
  Encodable.encode (T := LegalKernel.FaultProof.Claim) r.low ++
  Encodable.encode (T := LegalKernel.FaultProof.Claim) r.high

/-- Decode a `DisputedRange`. -/
def DisputedRange.decode (s : Stream) :
    Except DecodeError (LegalKernel.FaultProof.DisputedRange × Stream) :=
  match Encodable.decode (T := LegalKernel.FaultProof.Claim) s with
  | .ok (lo, s₁) =>
    match Encodable.decode (T := LegalKernel.FaultProof.Claim) s₁ with
    | .ok (hi, s₂) => .ok ({ low := lo, high := hi }, s₂)
    | .error e => .error e
  | .error e => .error e

instance : Encodable LegalKernel.FaultProof.DisputedRange where
  encode := DisputedRange.encode
  decode := DisputedRange.decode

/-! ## `TurnSide` codec -/

/-- Encode a `TurnSide` as a 1-byte CBE uint tag. -/
def TurnSide.encode : LegalKernel.FaultProof.TurnSide → Stream
  | .sequencer  => Encodable.encode (T := Nat) 0
  | .challenger => Encodable.encode (T := Nat) 1

/-- Decode a `TurnSide` from a 1-byte CBE uint tag. -/
def TurnSide.decode (s : Stream) :
    Except DecodeError (LegalKernel.FaultProof.TurnSide × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) => .ok (.sequencer, s₁)
  | .ok (1, s₁) => .ok (.challenger, s₁)
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance : Encodable LegalKernel.FaultProof.TurnSide where
  encode := TurnSide.encode
  decode := TurnSide.decode

/-! ## `GameStatus` codec -/

/-- Encode a `GameStatus` as a CBE uint tag. -/
def GameStatus.encode : LegalKernel.FaultProof.GameStatus → Stream
  | .inProgress         => Encodable.encode (T := Nat) 0
  | .sequencerWon       => Encodable.encode (T := Nat) 1
  | .challengerWon      => Encodable.encode (T := Nat) 2
  | .timedOutSequencer  => Encodable.encode (T := Nat) 3
  | .timedOutChallenger => Encodable.encode (T := Nat) 4

/-- Decode a `GameStatus` from a CBE uint tag. -/
def GameStatus.decode (s : Stream) :
    Except DecodeError (LegalKernel.FaultProof.GameStatus × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) => .ok (.inProgress,         s₁)
  | .ok (1, s₁) => .ok (.sequencerWon,       s₁)
  | .ok (2, s₁) => .ok (.challengerWon,      s₁)
  | .ok (3, s₁) => .ok (.timedOutSequencer,  s₁)
  | .ok (4, s₁) => .ok (.timedOutChallenger, s₁)
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance : Encodable LegalKernel.FaultProof.GameStatus where
  encode := GameStatus.encode
  decode := GameStatus.decode

/-! ## `GameState` codec -/

/-- Encode a `GameState` per the plan §12.4.5 layout. -/
def GameState.encode (gs : LegalKernel.FaultProof.GameState) : Stream :=
  Encodable.encode (T := Nat) gs.sequencer.toNat ++
  Encodable.encode (T := Nat) gs.challenger.toNat ++
  Encodable.encode (T := LegalKernel.FaultProof.DisputedRange) gs.range ++
  Encodable.encode (T := Option LegalKernel.FaultProof.Claim) gs.pendingMidpoint ++
  Encodable.encode (T := Nat) gs.depth ++
  Encodable.encode (T := LegalKernel.FaultProof.TurnSide) gs.turn ++
  Encodable.encode (T := Nat) gs.sequencerBond ++
  Encodable.encode (T := Nat) gs.challengerBond ++
  Encodable.encode (T := LegalKernel.FaultProof.GameStatus) gs.status ++
  Encodable.encode (T := ByteArray) gs.deploymentId

/-- Decode a `GameState` (best-effort; returns the fields if all
    parts decode successfully). -/
def GameState.decode (s : Stream) :
    Except DecodeError (LegalKernel.FaultProof.GameState × Stream) := do
  let (seqId, s) ← Encodable.decode (T := Nat) s
  let (chalId, s) ← Encodable.decode (T := Nat) s
  let (range, s) ← Encodable.decode (T := LegalKernel.FaultProof.DisputedRange) s
  let (pendMp, s) ←
    Encodable.decode (T := Option LegalKernel.FaultProof.Claim) s
  let (depth, s) ← Encodable.decode (T := Nat) s
  let (turn, s) ← Encodable.decode (T := LegalKernel.FaultProof.TurnSide) s
  let (seqBond, s) ← Encodable.decode (T := Nat) s
  let (chalBond, s) ← Encodable.decode (T := Nat) s
  let (status, s) ← Encodable.decode (T := LegalKernel.FaultProof.GameStatus) s
  let (depId, s) ← Encodable.decode (T := ByteArray) s
  -- Cap actor ids at UInt64 (2^64).
  if h_seq : seqId < 18446744073709551616 then
    if h_chal : chalId < 18446744073709551616 then
      let _ := h_seq
      let _ := h_chal
      .ok ({
        sequencer       := seqId.toUInt64,
        challenger      := chalId.toUInt64,
        range           := range,
        pendingMidpoint := pendMp,
        depth           := depth,
        turn            := turn,
        sequencerBond   := seqBond,
        challengerBond  := chalBond,
        status          := status,
        deploymentId    := depId
      }, s)
    else
      let _ := h_chal
      .error (.invalidLength s!"GameState challenger {chalId} exceeds 2^64")
  else
    let _ := h_seq
    .error (.invalidLength s!"GameState sequencer {seqId} exceeds 2^64")

instance : Encodable LegalKernel.FaultProof.GameState where
  encode := GameState.encode
  decode := GameState.decode

/-! ## Determinism theorems -/

theorem gameState_encode_deterministic
    (g₁ g₂ : LegalKernel.FaultProof.GameState) (h : g₁ = g₂) :
    GameState.encode g₁ = GameState.encode g₂ := by rw [h]

theorem claim_encode_deterministic
    (c₁ c₂ : LegalKernel.FaultProof.Claim) (h : c₁ = c₂) :
    Claim.encode c₁ = Claim.encode c₂ := by rw [h]

theorem disputedRange_encode_deterministic
    (r₁ r₂ : LegalKernel.FaultProof.DisputedRange) (h : r₁ = r₂) :
    DisputedRange.encode r₁ = DisputedRange.encode r₂ := by rw [h]

/-! ## Smoke checks -/

/-- TurnSide encoding distinguishes constructors. -/
example : TurnSide.encode .sequencer ≠ TurnSide.encode .challenger := by decide

/-- GameStatus encoding distinguishes inProgress from sequencerWon. -/
example :
    GameStatus.encode .inProgress ≠ GameStatus.encode .sequencerWon := by
  decide

end Encoding
end LegalKernel
