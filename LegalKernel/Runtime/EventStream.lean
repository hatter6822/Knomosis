/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.EventStream — the per-frame event-extraction
step backing the `knomosis extract-events` subcommand (RH-D / WU
GP.6.3).

`extract-events` is a *stateful* streaming subcommand: it threads a
running `ExtendedState` across the log frames a subscriber feeds it
(one `LogEntry` per frame) and emits the `Events.Event` list each
frame produces.  This module provides the single-step core; the
stdin/stdout driver lives in `Main.lean`.

**Why a dedicated step.**  A log frame carries only a `LogEntry`
(prevHash + signedAction), NOT the pre/post states `extractEvents`
needs.  So the events for frame `n` can only be computed by
reconstructing the state after frames `0..n-1` (the pre-state),
applying frame `n`'s action (the post-state), and running
`extractEvents` on that triple.  This is exactly the production
runtime's `Loop.processPure` computation —
`extractEvents esEff newState signedAction` — so the events
`extract-events` emits are byte-identical to those the runtime
emitted when it wrote the log.

**Why the full admission path (not `kernelOnlyApply`).**  The
fault-proof `kernelOnlyApply` deliberately skips bridge- and
budget-state mutation, so it would yield WRONG bridge events (e.g. a
`withdrawalRequested` whose `withdrawalId` is read from the
post-state `BridgeState.nextWdId`).  `extractEventsStepWith`
therefore reuses `replayStepWith` — the bridge-aware
`BridgeAdmissibleWith` + `apply_bridge_admissible_with_budget` path —
so the reconstructed post-state matches production exactly.

**Verification posture.**  Like the rest of the replay family, this
re-checks the signed action via the supplied `verify`.  The
production binary links a real verifier; `lake test` uses
`mockVerify` (the Lean-level `Verify` opaque returns `false`).  Non-
TCB: an extraction bug misleads an indexer but cannot violate a
kernel invariant.
-/

import LegalKernel.Runtime.Replay
import LegalKernel.Events.Extract
import LegalKernel.Encoding.Event

namespace LegalKernel
namespace Runtime

open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Events

/-- One event-extraction step (parameterised by the verifier and
    deploymentId).  Reconstructs the post-state for `entry` via
    `replayStepWith` (the production bridge-aware admission path) and
    returns the post-state paired with the events `extractEvents`
    derives from the `(pre, post, signedAction)` triple — exactly the
    list `Loop.processPure` returns for the same entry.

    `epochLength` advances the budget epoch identically to the
    producing runtime (`0` ⇒ no advancement).  On any replay failure
    (chain break, inadmissible entry, post-hash mismatch) the
    `ReplayError` propagates unchanged.

    # Errors

    Returns the `ReplayError` from `replayStepWith` (chain /
    admissibility / post-hash). -/
def extractEventsStepWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray)
    (P : AuthorityPolicy) (state : ExtendedState) (prevHash : ContentHash)
    (e : LogEntry) (idx : Nat) (epochLength : Nat := 0) :
    Except ReplayError (ExtendedState × List Event) :=
  match replayStepWith verify d P state prevHash e idx epochLength with
  | .error err => .error err
  | .ok nextState =>
    -- `replayStepWith` validated the entry and produced `nextState`
    -- from the epoch-advanced pre-state below; recompute that exact
    -- pre-state so the extracted events match `Loop.processPure`'s
    -- `extractEvents esEff newState st` byte-for-byte.
    let esEff := state.withAdvancedEpoch epochLength idx
    .ok (nextState, extractEvents esEff nextState e.signedAction)

/-- `extractEventsStepWith` agrees with `replayStepWith` on the
    post-state: the state component it returns is exactly the state
    `replayStepWith` produces (the event list is the only addition).
    Pins the "extraction does not perturb replay" contract. -/
theorem extractEventsStepWith_state_eq_replayStepWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray) (P : AuthorityPolicy) (state : ExtendedState)
    (prevHash : ContentHash) (e : LogEntry) (idx : Nat) (epochLength : Nat) :
    (extractEventsStepWith verify d P state prevHash e idx epochLength).map Prod.fst =
    replayStepWith verify d P state prevHash e idx epochLength := by
  unfold extractEventsStepWith
  cases replayStepWith verify d P state prevHash e idx epochLength <;> rfl

/-! ## `extract-events` wire framing (RH-D / GP.6.3)

The pure byte-format helpers backing the `knomosis extract-events`
stdin/stdout protocol (`docs/abi.md` §11.10).  Kept in this library
module (not `Main.lean`) so they are unit-testable; the stdin/stdout
IO driver itself lives in `Main.lean::extractEventsLoop`.  The
big-endian convention matches the Rust `SubprocessExtractor`
(`seq` / lengths via `to_be_bytes` / `from_be_bytes`). -/

/-- Encode a `Nat` as 8 big-endian bytes (the wire `seq` width). -/
def beU64 (n : Nat) : ByteArray :=
  ByteArray.mk <| Array.ofFn (n := 8) (fun i => (UInt8.ofNat ((n >>> (8 * (7 - i.val))) % 256)))

/-- Encode a `Nat` as 4 big-endian bytes (the wire length / count
    width). -/
def beU32 (n : Nat) : ByteArray :=
  ByteArray.mk <| Array.ofFn (n := 4) (fun i => (UInt8.ofNat ((n >>> (8 * (3 - i.val))) % 256)))

/-- Read a big-endian `Nat` from `len` bytes of `bs` starting at
    `off`.  Out-of-range indices read as `0` (via `ByteArray.get!`'s
    default); callers pass a sufficiently long buffer. -/
def beToNat (bs : ByteArray) (off len : Nat) : Nat :=
  (List.range len).foldl (fun acc i => acc * 256 + (bs.get! (off + i)).toNat) 0

/-- Encode one `extract-events` response frame: `8-byte BE seq ‖
    4-byte BE event-count ‖ K × (4-byte BE event-length ‖
    Event.encode bytes)`.  Pure, so the response wire format is
    unit-testable independent of the stdin/stdout IO driver. -/
def encodeExtractResponse (seq : Nat) (events : List Events.Event) : ByteArray :=
  let header := beU64 seq ++ beU32 events.length
  events.foldl
    (fun acc ev =>
      let evBytes := ByteArray.mk (Encodable.encode (T := Events.Event) ev).toArray
      acc ++ beU32 evBytes.size ++ evBytes)
    header

end Runtime
end LegalKernel
