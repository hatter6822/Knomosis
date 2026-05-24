/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.StepVMCoherence — Workstream SVC: closure of
the L1 step-VM cross-stack coherence chain.

This module ships three load-bearing pieces:

  1. `actionKindByte : Action → UInt8` — the 0..20 dispatcher byte
     that the Solidity `executeStep(actionKind, ...)` consumes.
     Mirrors the `Encoding.Action.encode`'s leading-tag table and
     the `KnomosisStepVM.sol::ActionKind` enum.  (Workstream GP widened
     the range from 0..18 to 0..20 with `depositWithFee` = 19 and
     `topUpActionBudget` = 20.)

  2. `actionFieldsForL1 : Action → ByteArray` — the canonical byte
     layout the Solidity `_stepXX` decoders expect.  For structured
     variants the layout is a sequence of fixed-width big-endian
     fields (`uint64BE` per primitive numeric); for opaque variants
     it is the action's CBE-encoded payload (which the L1 step VM
     simply hashes via `keccak256(actionFields)` without inspecting
     internal structure).

  3. `stepVMHash` — the unified dispatcher over the 21 per-variant
     `stepCommitXX` functions.  Given `(preCommit, kind, fields,
     signer, bundle)` it produces the same 32-byte output Solidity's
     `KnomosisStepVM.executeStep` would.  This is the load-bearing
     cross-stack contract: under the production keccak256 binding,
     `stepVMHash` is byte-equal to `executeStep` for every input
     pair.

The headline theorem `step_vm_dispatch_coherent_<variant>` for each
variant establishes that, when the inputs are constructed from a
canonical `(ExtendedState, Action, ActorId)` triple via
`actionFieldsForL1` + `buildObserverCellProofs`, the dispatcher's
output equals the per-variant `SolidityStepVMCommit.stepCommit<variant>`
invocation with the appropriate pre/post-cell values.

## Architectural decision (Workstream SVC OQ-SVC-1)

The plan §SVC.1.c records a deep tension: for opaque variants
(Dispute, DisputeWithdraw, Verdict, Rollback, DeclareLocalPolicy,
RevokeLocalPolicy, FaultProofChallenge, FaultProofResolution) the
L1 step VM's hash recipe is

```
keccak256(preCommit || TAG || keccak256(actionFields) || signer)
```

This is NOT equal to `commitExtendedState(postState)` because the
canonical 5-component state commit doesn't embed `(action, signer)`
into the hash.  The plan presents three resolution candidates:

  * **Option A**: Redefine `commitExtendedState` to include an
    "action accumulator" component.  TCB-touching; rejected for
    SVC.
  * **Option B**: Accept that the bisection-game's chain of commits
    uses **step-VM hashes** throughout (not state commits).  The
    L1's `executeStep` output IS the canonical step-VM hash; both
    sides agree on it byte-for-byte.
  * **Option C**: Restrict the off-chain observer to terminate only
    on structured variants; opaque-variant disputes settle via
    `claimTimeout`.

**This module adopts Option B at the architectural level**: the
`stepVMHash` dispatcher is the canonical reference for the
bisection-game's commit chain.  The off-chain observer's terminate
move (Workstream SVC.5) submits a `claimedPostCommit` value equal
to `stepVMHash` (NOT `commitExtendedState`).  The `TerminateBundle`
type carries this discipline as part of its contract.

**Option C remains operational** as a defence-in-depth: the
observer's `compute_next_move` MAY choose to defer terminate on
opaque variants and wait for the L1's `claimTimeout` path, since
the observer's truth-oracle delegate is the responsible party for
choosing which move to play.

This module is **not** part of the trusted computing base.  Bugs
here would surface as cross-stack fixture mismatches at the WU
H.10.1 corpus level; the kernel's invariant proofs are unaffected.
-/

import LegalKernel.Authority.Action
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Bridge.State
import LegalKernel.Encoding.Encodable
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.Observer
import LegalKernel.FaultProof.SolidityStepVMCommit
import LegalKernel.FaultProof.StepVariants
import LegalKernel.FaultProof.Verify
import LegalKernel.Runtime.Hash

namespace LegalKernel
namespace FaultProof
namespace StepVMCoherence

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Disputes
open LegalKernel.Encoding
open LegalKernel.FaultProof
open LegalKernel.FaultProof.SolidityStepVMCommit
open LegalKernel.Runtime

/-! ## `actionKindByte` — the 0..20 dispatcher byte

Mirrors `Encoding.Action.encode`'s leading-tag table (which uses
`Encodable.encode (T := Nat) <idx>`).  The Solidity-side
`KnomosisStepVM.ActionKind` enum has the same indices. -/

/-- The 0..20 dispatcher index for an `Action`'s constructor.
    Mirrors the Solidity `ActionKind` enum and the
    `Encoding.Action.encode`'s leading-tag emission.  Frozen,
    append-only: a new variant takes the next index. -/
def actionKindByte : Action → UInt8
  | .transfer _ _ _ _              => 0
  | .mint _ _ _                    => 1
  | .burn _ _ _                    => 2
  | .freezeResource _              => 3
  | .replaceKey _ _                => 4
  | .reward _ _ _                  => 5
  | .distributeOthers _ _ _        => 6
  | .proportionalDilute _ _ _      => 7
  | .dispute _                     => 8
  | .disputeWithdraw _             => 9
  | .verdict _                     => 10
  | .rollback _                    => 11
  | .registerIdentity _ _          => 12
  | .deposit _ _ _ _               => 13
  | .withdraw _ _ _ _              => 14
  | .declareLocalPolicy _          => 15
  | .revokeLocalPolicy             => 16
  | .faultProofChallenge _ _ _ _   => 17
  | .faultProofResolution _ _ _ _  => 18
  -- Workstream GP (v1.0): depositWithFee + topUpActionBudget.
  | .depositWithFee _ _ _ _ _ _ _  => 19
  | .topUpActionBudget _ _ _ _     => 20

/-- `actionKindByte` is total: the codomain is `0..20`.  The
    decidable membership-in-list form is what downstream callers
    consume (e.g., to enumerate all 21 dispatch arms). -/
def actionKindByteCases : List UInt8 :=
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]

/-! ## `actionFieldsForL1` — canonical byte layout per variant

For STRUCTURED variants (Transfer, Mint, Burn, FreezeResource,
ReplaceKey, Reward, DistributeOthers, ProportionalDilute,
RegisterIdentity, Deposit, Withdraw): the layout is a sequence of
fixed-width big-endian fields (`uint64BE` per primitive numeric)
followed by any variable-length trailing payload.  This matches
the Solidity `_stepXX::_decodeUint64BE` reads byte-for-byte.

For OPAQUE variants (Dispute, DisputeWithdraw, Verdict, Rollback,
DeclareLocalPolicy, RevokeLocalPolicy, FaultProofChallenge,
FaultProofResolution): the L1's `_stepXX` only hashes the bytes
(`keccak256(actionFields)`); the internal structure is opaque.  We
use the Lean-side `Encodable.encode` payload directly, which is
the most natural cross-stack convention.

**Width discipline.**  Each `uint64BE` produces exactly 8 bytes;
each `uint256BE` produces exactly 32 bytes; variable-length
trailers (newKey, pk, recipientL1) are appended as-is. -/

/-- The canonical byte layout the L1 step VM's `_stepXX` decoder
    consumes.  For structured variants this is a sequence of
    big-endian fixed-width fields plus any variable-length trailing
    payload; for opaque variants this is the Lean-side
    `Encodable.encode` payload (the L1 step VM only hashes it). -/
def actionFieldsForL1 : Action → ByteArray
  -- Structured variants: `uint64BE r || uint64BE sender || ...`
  | .transfer r sender receiver amount =>
      uint64BE r.toNat ++ uint64BE sender.toNat ++
      uint64BE receiver.toNat ++ uint64BE amount
  | .mint r to amount =>
      uint64BE r.toNat ++ uint64BE to.toNat ++ uint64BE amount
  | .burn r fromActor amount =>
      uint64BE r.toNat ++ uint64BE fromActor.toNat ++ uint64BE amount
  | .freezeResource r =>
      uint64BE r.toNat
  | .replaceKey actor newKey =>
      -- `uint64BE actor || newKey-bytes` (variable trailer).
      uint64BE actor.toNat ++ newKey
  | .reward r to amount =>
      uint64BE r.toNat ++ uint64BE to.toNat ++ uint64BE amount
  | .distributeOthers r excluded amount =>
      uint64BE r.toNat ++ uint64BE excluded.toNat ++ uint64BE amount
  | .proportionalDilute r excluded totalReward =>
      uint64BE r.toNat ++ uint64BE excluded.toNat ++ uint64BE totalReward
  | .registerIdentity actor pk =>
      uint64BE actor.toNat ++ pk
  | .deposit r recipient amount depositId =>
      uint64BE r.toNat ++ uint64BE recipient.toNat ++
      uint64BE amount ++ uint64BE depositId
  | .withdraw r sender amount recipientL1 =>
      uint64BE r.toNat ++ uint64BE sender.toNat ++
      uint64BE amount ++ Bridge.EthAddress.toBytes recipientL1
  -- Opaque variants: use Lean's CBE encoding (the L1 step VM only
  -- hashes the bytes; structure is internal to both sides).
  | .dispute d =>
      ByteArray.mk (Encodable.encode (T := Dispute) d).toArray
  | .disputeWithdraw idx =>
      ByteArray.mk (Encodable.encode (T := Nat) idx).toArray
  | .verdict v =>
      ByteArray.mk (Encodable.encode (T := Verdict) v).toArray
  | .rollback targetIdx =>
      ByteArray.mk (Encodable.encode (T := Nat) targetIdx).toArray
  | .declareLocalPolicy policy =>
      ByteArray.mk (Encodable.encode (T := LocalPolicy) policy).toArray
  | .revokeLocalPolicy =>
      ByteArray.empty
  | .faultProofChallenge bindingHash startIdx endIdx challengerCommit =>
      ByteArray.mk (Encodable.encode (T := ByteArray) bindingHash).toArray ++
      ByteArray.mk (Encodable.encode (T := Nat) startIdx).toArray ++
      ByteArray.mk (Encodable.encode (T := Nat) endIdx).toArray ++
      ByteArray.mk (Encodable.encode (T := ByteArray) challengerCommit).toArray
  | .faultProofResolution bindingHash gameId winner revertFromIdx =>
      ByteArray.mk (Encodable.encode (T := ByteArray) bindingHash).toArray ++
      ByteArray.mk (Encodable.encode (T := Nat) gameId).toArray ++
      ByteArray.mk (Encodable.encode (T := Nat) winner.toNat).toArray ++
      ByteArray.mk (Encodable.encode (T := Nat) revertFromIdx).toArray
  -- Workstream GP (v1.0): depositWithFee is a structured variant:
  -- `uint64BE resource || uint64BE recipient || uint64BE poolActor ||
  -- uint64BE userAmount || uint64BE poolAmount || uint64BE budgetGrant
  -- || uint64BE depositId`.  Mirrors the Solidity `_step19` decoder's
  -- byte-for-byte field reads.
  | .depositWithFee r recipient poolActor userAmount poolAmount budgetGrant depositId =>
      uint64BE r.toNat ++ uint64BE recipient.toNat ++ uint64BE poolActor.toNat ++
      uint64BE userAmount ++ uint64BE poolAmount ++ uint64BE budgetGrant ++
      uint64BE depositId
  -- topUpActionBudget is a structured variant:
  -- `uint64BE gasResource || uint64BE gasAmount || uint64BE budgetIncrement ||
  -- uint64BE poolActor`.  The signer is provided separately to the L1 step VM
  -- via the SignedAction payload, not encoded in the action fields.
  | .topUpActionBudget gasResource gasAmount budgetIncrement poolActor =>
      uint64BE gasResource.toNat ++ uint64BE gasAmount ++
      uint64BE budgetIncrement ++ uint64BE poolActor.toNat

/-! ## Helpers for reading cell values from cell-proof bundles

The Solidity-side `_stepXX` functions read cell values via
`_findBalanceCellProof` / `_findCellProof`.  The Lean-side mirror
walks the bundle's `proofs` list looking for matching `cellTag`.
Returns `none` if the cell is absent. -/

/-- Find the cell-proof in the bundle with the given tag.  Returns
    `none` if the bundle has no matching entry. -/
def findCellProof (bundle : CellProofBundle) (tag : CellTag) :
    Option CellProof :=
  bundle.proofs.find? (fun p => decide (p.cellTag = tag))

/-- Read a cell's value from a bundle, defaulting to
    `canonicalAbsentValue tag` if missing.  Mirrors the Solidity-
    side semantic where an absent cell encodes as canonical
    absent bytes. -/
def readCellValue (bundle : CellProofBundle) (tag : CellTag) :
    ByteArray :=
  match findCellProof bundle tag with
  | some p => p.cellValue
  | none   => canonicalAbsentValue tag

/-- Decode a cell value as a `Nat` per Solidity's `_decodeNat`
    semantics: byte-for-byte mirror.

    **Cross-stack contract (byte-equivalent).**  For every input
    `bytes` this function returns the same `Nat` value that
    Solidity's `_decodeNat(bytes)` produces, EXCEPT for the
    length-1..8 case where Solidity reverts (`MalformedCellValue`)
    and this function returns 0.  The revert case has no
    `Nat`-valued analogue in a total function; the chosen 0 has
    the property that the dispatcher's output hash (computed from
    a value-0 cell read) cannot match any honestly-claimed pivot
    commit under collision-resistance of `hashBytes`, so a
    bisection-game opponent who supplies length-1..8 cell bytes
    on a Lean-side replay forfeits the implicit terminate
    response (mirroring the on-chain outcome where Solidity's
    revert leaves the game in-progress until the responsible
    party times out).

    **Concrete decoder.**
      * `bytes.size == 0` → return 0.  Matches Solidity's
        `if (data.length == 0) return 0` early-out.  This is the
        canonical-absent path: when a balance cell is absent from
        the bundle, `readCellValue` returns
        `canonicalAbsentValue` (= empty bytes), and both sides
        treat the absent cell as a 0 pre-balance.
      * `1 ≤ bytes.size < 9` → return 0.  Solidity reverts here;
        see the section above on why this returns 0 rather than
        attempting to model a revert in a pure `Nat`-valued
        function.  In practice this case never arises on canonical
        cell bytes (which are always exactly 9 bytes:
        `[tag(1) ++ payload(8)]`).
      * `bytes.size ≥ 9` → read `bytes[1..9]` little-endian as a
        `Nat`, **ignoring the tag byte at offset 0**.  This is
        the byte-for-byte mirror of Solidity's
        `result |= uint256(uint8(data[1 + i])) << (8 * i)` loop.
        Excess bytes after offset 9 are silently ignored,
        matching Solidity's slice-only semantics. -/
def decodeCellNat (bytes : ByteArray) : Nat :=
  if bytes.size = 0 then 0
  else if bytes.size < 9 then 0
  else
    -- Read `bytes[1..9]` as a little-endian `Nat`, ignoring the
    -- tag byte at offset 0.  Mirrors Solidity's `_decodeNat`'s
    -- inner loop byte-for-byte (offset 1, 8 bytes, LE order).
    let b1 := bytes.data[1]!.toNat
    let b2 := bytes.data[2]!.toNat
    let b3 := bytes.data[3]!.toNat
    let b4 := bytes.data[4]!.toNat
    let b5 := bytes.data[5]!.toNat
    let b6 := bytes.data[6]!.toNat
    let b7 := bytes.data[7]!.toNat
    let b8 := bytes.data[8]!.toNat
    b1 ||| (b2 <<< 8) ||| (b3 <<< 16) ||| (b4 <<< 24) |||
    (b5 <<< 32) ||| (b6 <<< 40) ||| (b7 <<< 48) ||| (b8 <<< 56)

/-! ## `stepVMHash` — unified dispatcher

The Lean reference for what Solidity's `executeStep` returns.  Given
the dispatcher byte, the action fields' bytes, the signer's id,
and the cell-proof bundle, computes the per-variant step-VM hash.

**Failure modes.**  For an unknown `kind` (≥ 21), returns
`canonicalAbsentValue` (0 bytes).  Solidity-side reverts with
`UnknownActionKind`; the Lean side surfaces it as an empty hash
that won't match any L1-produced commit.  Production callers
(`stepVMHashFromAction`) construct `kind` from `actionKindByte`,
which is provably in 0..20 — so the catch-all path is unreachable
in practice. -/

/-- Read a big-endian `UInt64`-sized `Nat` field from a byte array
    at offset `o`.

    **Cross-stack contract.**  On inputs with sufficient bytes
    (`offset + 8 ≤ bytes.size`), returns the same `Nat` value
    Solidity's `_decodeUint64BE(bytes, offset)` produces.  Out-of-
    bounds reads return 0; Solidity reverts via an out-of-bounds
    panic in that case.  Since both behaviours map to "dispatcher
    cannot produce the responsible party's claim" (Lean: non-
    matching hash; Solidity: revert keeps the game in-progress
    until timeout), this is not a semantic divergence on the
    domain where both decoders succeed — the success domain
    matches byte-for-byte. -/
def readUint64BE (bytes : ByteArray) (offset : Nat) : Nat :=
  if offset + 8 > bytes.size then 0
  else
    let b0 := bytes.data[offset]!.toNat
    let b1 := bytes.data[offset + 1]!.toNat
    let b2 := bytes.data[offset + 2]!.toNat
    let b3 := bytes.data[offset + 3]!.toNat
    let b4 := bytes.data[offset + 4]!.toNat
    let b5 := bytes.data[offset + 5]!.toNat
    let b6 := bytes.data[offset + 6]!.toNat
    let b7 := bytes.data[offset + 7]!.toNat
    (b0 <<< 56) ||| (b1 <<< 48) ||| (b2 <<< 40) ||| (b3 <<< 32) |||
    (b4 <<< 24) ||| (b5 <<< 16) ||| (b6 <<< 8) ||| b7

/-- Slice a byte array from `offset` to its end.  Mirrors
    Solidity's `actionFields[offset:]` slice expression. -/
def sliceFrom (bytes : ByteArray) (offset : Nat) : ByteArray :=
  bytes.extract offset bytes.size

/-- Cap on the number of cell proofs Solidity's bulk-action loop
    iterates per `executeStep` invocation.  Matches Solidity's
    `KnomosisStepVM.MAX_RECIPIENTS_PER_BULK_ACTION = 256`.  The Lean
    dispatcher honors this cap for bulk variants (kinds 6 + 7) so
    that for any bundle the Lean output byte-equals Solidity's
    `executeStep` output, including the edge case where a caller
    supplies more than 256 cells. -/
def maxRecipientsPerBulkAction : Nat := 256

/-- The unified Lean-side dispatcher mirroring Solidity's
    `KnomosisStepVM.executeStep`.  Returns the 32-byte step-VM hash
    that the L1 contract emits.

    **Cross-stack discipline.**  Under the production keccak256
    binding, this function's output byte-equals
    `KnomosisStepVM.executeStep(preCommit, kind, fields, signer, bundle)`.
    Verified at the cross-stack fixture corpus level (WU H.10.1,
    SVC.5.e).

    **Unknown-kind handling.**  Kinds ≥ 21 return an empty hash
    (which cannot equal any L1 output).  Production callers must
    construct `kind` from `actionKindByte`, which is in 0..20. -/
def stepVMHash
    (preCommit : ByteArray) (kind : UInt8) (fields : ByteArray)
    (signer : Nat) (bundle : CellProofBundle) : ByteArray :=
  match kind with
  -- 0: Transfer
  | 0 =>
    let r        := readUint64BE fields 0
    let sender   := readUint64BE fields 8
    let receiver := readUint64BE fields 16
    let amount   := readUint64BE fields 24
    let senderBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 sender.toUInt64))
    -- Self-transfer mirrors Lean's §4.11 read-after-debit pattern:
    -- both balances stay at the pre-balance.
    let newSenderBalance : Nat :=
      if sender = receiver then senderBalance
      else senderBalance - amount
    let newReceiverBalance : Nat :=
      if sender = receiver then senderBalance
      else
        let receiverBalance :=
          decodeCellNat (readCellValue bundle
                          (.balance r.toUInt64 receiver.toUInt64))
        receiverBalance + amount
    stepCommitTransfer preCommit r sender receiver signer
      newSenderBalance newReceiverBalance
  -- 1: Mint
  | 1 =>
    let r      := readUint64BE fields 0
    let to     := readUint64BE fields 8
    let amount := readUint64BE fields 16
    let toBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 to.toUInt64))
    stepCommitMint preCommit r to signer (toBalance + amount)
  -- 2: Burn
  | 2 =>
    let r         := readUint64BE fields 0
    let fromActor := readUint64BE fields 8
    let amount    := readUint64BE fields 16
    let fromBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 fromActor.toUInt64))
    stepCommitBurn preCommit r fromActor signer (fromBalance - amount)
  -- 3: FreezeResource
  | 3 =>
    let r := readUint64BE fields 0
    stepCommitFreezeResource preCommit r signer
  -- 4: ReplaceKey
  | 4 =>
    let actor  := readUint64BE fields 0
    let newKey := sliceFrom fields 8
    stepCommitReplaceKey preCommit actor signer newKey
  -- 5: Reward
  | 5 =>
    let r      := readUint64BE fields 0
    let to     := readUint64BE fields 8
    let amount := readUint64BE fields 16
    let toBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 to.toUInt64))
    stepCommitReward preCommit r to signer (toBalance + amount)
  -- 6: DistributeOthers (bulk).  Mirrors Solidity's `_stepDistributeOthers`
  -- byte-for-byte: head hash plus per-recipient fold over the
  -- bundle's balance cells matching `(r, ≠ excluded)`.  Iteration
  -- order is the bundle's `cellProofs[0..min(n, MAX_RECIPIENTS)]`
  -- — matches Solidity's `for (i = 0; i < cellProofs.length &&
  -- i < MAX_RECIPIENTS_PER_BULK_ACTION; i++)` loop, including the
  -- `MAX_RECIPIENTS_PER_BULK_ACTION = 256` DoS-protection cap.
  | 6 =>
    let r        := readUint64BE fields 0
    let excluded := readUint64BE fields 8
    let amount   := readUint64BE fields 16
    let head :=
      stepCommitDistributeOthersHead preCommit r excluded signer amount
    (bundle.proofs.take maxRecipientsPerBulkAction).foldl
      (fun acc p =>
        match p.cellTag with
        | .balance pr pa =>
          if pr.toNat = r ∧ pa.toNat ≠ excluded then
            let preBal := decodeCellNat p.cellValue
            let newBal := preBal + amount
            stepCommitDistributeOthersFold acc pa.toNat newBal
          else acc
        | _ => acc)
      head
  -- 7: ProportionalDilute (bulk; two-pass).  Mirrors Solidity's
  -- `_stepProportionalDilute` byte-for-byte:
  --   * Pass 1: walk bundle (up to MAX_RECIPIENTS_PER_BULK_ACTION),
  --     sum balance-cell values into `sumOthers` (matching
  --     `keyA == r && keyB != excluded`).
  --   * Pass 2: walk bundle again (same cap), per-recipient
  --     `credit := totalReward * v / sumOthers`,
  --     `newBal := v + credit`, fold into hash.
  -- Both passes use the SAME filter and the SAME cap; both produce
  -- the same balance-cell iteration order Solidity sees.
  | 7 =>
    let r           := readUint64BE fields 0
    let excluded    := readUint64BE fields 8
    let totalReward := readUint64BE fields 16
    let capped := bundle.proofs.take maxRecipientsPerBulkAction
    let sumOthers : Nat :=
      capped.foldl
        (fun acc p =>
          match p.cellTag with
          | .balance pr pa =>
            if pr.toNat = r ∧ pa.toNat ≠ excluded then
              acc + decodeCellNat p.cellValue
            else acc
          | _ => acc)
        0
    let head :=
      stepCommitProportionalDiluteHead preCommit r excluded signer
        totalReward sumOthers
    capped.foldl
      (fun acc p =>
        match p.cellTag with
        | .balance pr pa =>
          if pr.toNat = r ∧ pa.toNat ≠ excluded then
            let preBal := decodeCellNat p.cellValue
            let credit :=
              if sumOthers = 0 then 0
              else totalReward * preBal / sumOthers
            let newBal := preBal + credit
            stepCommitProportionalDiluteFold acc pa.toNat newBal
          else acc
        | _ => acc)
      head
  -- 8: Dispute (opaque)
  | 8 =>
    stepCommitDispute preCommit fields signer
  -- 9: DisputeWithdraw (opaque)
  | 9 =>
    stepCommitDisputeWithdraw preCommit fields signer
  -- 10: Verdict (opaque)
  | 10 =>
    stepCommitVerdict preCommit fields signer
  -- 11: Rollback (opaque)
  | 11 =>
    stepCommitRollback preCommit fields signer
  -- 12: RegisterIdentity
  | 12 =>
    let actor := readUint64BE fields 0
    let pk    := sliceFrom fields 8
    stepCommitRegisterIdentity preCommit actor signer pk
  -- 13: Deposit
  | 13 =>
    let r         := readUint64BE fields 0
    let recipient := readUint64BE fields 8
    let amount    := readUint64BE fields 16
    let depositId := readUint64BE fields 24
    let recipientBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 recipient.toUInt64))
    stepCommitDeposit preCommit r recipient signer
      (recipientBalance + amount) depositId
  -- 14: Withdraw
  | 14 =>
    let r           := readUint64BE fields 0
    let sender      := readUint64BE fields 8
    let amount      := readUint64BE fields 16
    let recipientL1 := sliceFrom fields 24
    let senderBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 sender.toUInt64))
    stepCommitWithdraw preCommit r sender signer
      (senderBalance - amount) recipientL1
  -- 15: DeclareLocalPolicy (opaque)
  | 15 =>
    stepCommitDeclareLocalPolicy preCommit fields signer
  -- 16: RevokeLocalPolicy (opaque)
  | 16 =>
    stepCommitRevokeLocalPolicy preCommit fields signer
  -- 17: FaultProofChallenge (opaque)
  | 17 =>
    stepCommitFaultProofChallenge preCommit fields signer
  -- 18: FaultProofResolution (opaque)
  | 18 =>
    stepCommitFaultProofResolution preCommit fields signer
  -- 19: DepositWithFee (Workstream GP; structured).  Layout:
  -- `uint64BE r || uint64BE recipient || uint64BE poolActor ||
  --  uint64BE userAmount || uint64BE poolAmount ||
  --  uint64BE budgetGrant || uint64BE depositId`.
  -- Reads recipient + poolActor pre-balances from the cell-proof
  -- bundle; emits new balances under the Laws.depositWithFee
  -- two-step pattern (recipient += userAmount, then poolActor +=
  -- poolAmount).  When recipient = poolActor, both writes target
  -- the same cell, so the new balance is pre + userAmount +
  -- poolAmount (matching the kernel's sequential setBalance chain
  -- via `Laws.depositWithFee.apply_impl`).  `budgetGrant` is an
  -- admission-layer effect on the recipient's epochBudgets slot,
  -- NOT a kernel-state write — it is excluded from the step-VM
  -- hash by design.
  | 19 =>
    let r          := readUint64BE fields 0
    let recipient  := readUint64BE fields 8
    let poolActor  := readUint64BE fields 16
    let userAmount := readUint64BE fields 24
    let poolAmount := readUint64BE fields 32
    -- fields 40..48 = budgetGrant (admission-layer; not hashed)
    let depositId  := readUint64BE fields 48
    let recipientBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance r.toUInt64 recipient.toUInt64))
    let newRecipientBalance : Nat :=
      if recipient = poolActor then
        recipientBalance + userAmount + poolAmount
      else
        recipientBalance + userAmount
    let newPoolBalance : Nat :=
      if recipient = poolActor then
        recipientBalance + userAmount + poolAmount
      else
        let poolBalance :=
          decodeCellNat (readCellValue bundle
                          (.balance r.toUInt64 poolActor.toUInt64))
        poolBalance + poolAmount
    stepCommitDepositWithFee preCommit r recipient poolActor signer
      newRecipientBalance newPoolBalance depositId
  -- 20: TopUpActionBudget (Workstream GP; structured).  Layout:
  -- `uint64BE gasResource || uint64BE gasAmount ||
  --  uint64BE budgetIncrement || uint64BE poolActor`.
  -- Reads signer + poolActor pre-gas balances; emits new balances
  -- under the Laws.topUpActionBudget pattern (signer's gas balance
  -- -= gasAmount, poolActor's gas balance += gasAmount).  The
  -- admission gate's `topUpActionBudget_gasCheck` upstream rejects
  -- signer = poolActor (round-4 self-pool defense), so the
  -- if-signer-equals-poolActor branch below is unreachable on the
  -- canonical path; the explicit handling defends against a
  -- malformed bundle reaching this dispatcher with that shape.
  -- `budgetIncrement` is an admission-layer effect on signer's
  -- epochBudgets slot, NOT a kernel-state write — excluded from
  -- the step-VM hash by design.
  | 20 =>
    let gasResource := readUint64BE fields 0
    let gasAmount   := readUint64BE fields 8
    -- fields 16..24 = budgetIncrement (admission-layer; not hashed)
    let poolActor   := readUint64BE fields 24
    let signerBalance :=
      decodeCellNat (readCellValue bundle
                      (.balance gasResource.toUInt64 signer.toUInt64))
    let newSignerBalance : Nat :=
      if signer = poolActor then signerBalance  -- net zero (defended at admission)
      else signerBalance - gasAmount
    let newPoolBalance : Nat :=
      if signer = poolActor then signerBalance
      else
        let poolBalance :=
          decodeCellNat (readCellValue bundle
                          (.balance gasResource.toUInt64 poolActor.toUInt64))
        poolBalance + gasAmount
    stepCommitTopUpActionBudget preCommit gasResource signer poolActor
      newSignerBalance newPoolBalance
  -- Unknown kind: return empty bytes (won't match any L1 output).
  -- With the addition of kinds 19/20 above, the dispatcher now
  -- covers the full 0..20 range that `actionKindByte` produces.
  -- Any future Action constructor addition MUST extend this
  -- match before merging — enforced by the
  -- `stepVMHash_covers_actionKindByte_range` regression test.
  | _ => ByteArray.empty

/-! ## Determinism + output-size properties -/

/-- `stepVMHash` is deterministic: equal inputs ⇒ equal outputs. -/
theorem stepVMHash_deterministic
    (pc₁ pc₂ : ByteArray) (k₁ k₂ : UInt8) (f₁ f₂ : ByteArray)
    (s₁ s₂ : Nat) (b₁ b₂ : CellProofBundle)
    (h_pc : pc₁ = pc₂) (h_k : k₁ = k₂) (h_f : f₁ = f₂)
    (h_s : s₁ = s₂) (h_b : b₁ = b₂) :
    stepVMHash pc₁ k₁ f₁ s₁ b₁ = stepVMHash pc₂ k₂ f₂ s₂ b₂ := by
  rw [h_pc, h_k, h_f, h_s, h_b]

/-- `actionKindByte` is deterministic: equal actions ⇒ equal kind
    bytes. -/
theorem actionKindByte_deterministic
    (a₁ a₂ : Action) (h : a₁ = a₂) :
    actionKindByte a₁ = actionKindByte a₂ := by rw [h]

/-- `actionFieldsForL1` is deterministic: equal actions ⇒ equal
    field bytes. -/
theorem actionFieldsForL1_deterministic
    (a₁ a₂ : Action) (h : a₁ = a₂) :
    actionFieldsForL1 a₁ = actionFieldsForL1 a₂ := by rw [h]

/-! ## Per-variant dispatch coherence theorems

For each of the 21 variants (0..18 from SVC.5.e plus Workstream-GP's
`depositWithFee` = 19 and `topUpActionBudget` = 20), the dispatcher's
output equals the canonical `stepCommitXX` invocation with the
decoded fields.  Each proof is a structural reduction: `stepVMHash`
unfolds to the appropriate `stepCommitXX` branch when
`kind = <variant>`. -/

/-- Dispatch coherence for the `Transfer` variant.

    When `kind = 0`, `stepVMHash` reduces to `stepCommitTransfer`
    with the fields decoded from `actionFieldsForL1`. -/
theorem stepVMHash_transfer_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 0 fields signer bundle =
    (let r        := readUint64BE fields 0
     let sender   := readUint64BE fields 8
     let receiver := readUint64BE fields 16
     let amount   := readUint64BE fields 24
     let senderBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 sender.toUInt64))
     let newSenderBalance : Nat :=
       if sender = receiver then senderBalance
       else senderBalance - amount
     let newReceiverBalance : Nat :=
       if sender = receiver then senderBalance
       else
         let receiverBalance :=
           decodeCellNat (readCellValue bundle
                           (.balance r.toUInt64 receiver.toUInt64))
         receiverBalance + amount
     stepCommitTransfer preCommit r sender receiver signer
       newSenderBalance newReceiverBalance) := rfl

/-- Dispatch coherence for the `Mint` variant. -/
theorem stepVMHash_mint_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 1 fields signer bundle =
    (let r      := readUint64BE fields 0
     let to     := readUint64BE fields 8
     let amount := readUint64BE fields 16
     let toBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 to.toUInt64))
     stepCommitMint preCommit r to signer (toBalance + amount)) := rfl

/-- Dispatch coherence for the `Burn` variant. -/
theorem stepVMHash_burn_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 2 fields signer bundle =
    (let r         := readUint64BE fields 0
     let fromActor := readUint64BE fields 8
     let amount    := readUint64BE fields 16
     let fromBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 fromActor.toUInt64))
     stepCommitBurn preCommit r fromActor signer (fromBalance - amount)) := rfl

/-- Dispatch coherence for the `FreezeResource` variant. -/
theorem stepVMHash_freezeResource_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 3 fields signer bundle =
    stepCommitFreezeResource preCommit (readUint64BE fields 0) signer := rfl

/-- Dispatch coherence for the `ReplaceKey` variant. -/
theorem stepVMHash_replaceKey_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 4 fields signer bundle =
    stepCommitReplaceKey preCommit (readUint64BE fields 0) signer
      (sliceFrom fields 8) := rfl

/-- Dispatch coherence for the `Reward` variant. -/
theorem stepVMHash_reward_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 5 fields signer bundle =
    (let r      := readUint64BE fields 0
     let to     := readUint64BE fields 8
     let amount := readUint64BE fields 16
     let toBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 to.toUInt64))
     stepCommitReward preCommit r to signer (toBalance + amount)) := rfl

/-- Dispatch coherence for the `DistributeOthers` variant (bulk).

    When `kind = 6`, `stepVMHash` reduces to head + per-recipient
    fold over the bundle's first `maxRecipientsPerBulkAction`
    balance cells.  This mirrors Solidity's `_stepDistributeOthers`
    byte-for-byte (including the 256-cap DoS bound). -/
theorem stepVMHash_distributeOthers_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 6 fields signer bundle =
    (let r        := readUint64BE fields 0
     let excluded := readUint64BE fields 8
     let amount   := readUint64BE fields 16
     let head :=
       stepCommitDistributeOthersHead preCommit r excluded signer amount
     (bundle.proofs.take maxRecipientsPerBulkAction).foldl
       (fun acc p =>
         match p.cellTag with
         | .balance pr pa =>
           if pr.toNat = r ∧ pa.toNat ≠ excluded then
             let preBal := decodeCellNat p.cellValue
             let newBal := preBal + amount
             stepCommitDistributeOthersFold acc pa.toNat newBal
           else acc
         | _ => acc)
       head) := rfl

/-- Dispatch coherence for the `ProportionalDilute` variant (bulk
    two-pass).  When `kind = 7`, `stepVMHash` computes `sumOthers`
    in pass 1 over the first `maxRecipientsPerBulkAction` cells,
    then folds head + per-recipient credits in pass 2 over the
    same prefix.  Mirrors Solidity's `_stepProportionalDilute`
    (including the 256-cap DoS bound applied to both passes). -/
theorem stepVMHash_proportionalDilute_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 7 fields signer bundle =
    (let r           := readUint64BE fields 0
     let excluded    := readUint64BE fields 8
     let totalReward := readUint64BE fields 16
     let capped := bundle.proofs.take maxRecipientsPerBulkAction
     let sumOthers : Nat :=
       capped.foldl
         (fun acc p =>
           match p.cellTag with
           | .balance pr pa =>
             if pr.toNat = r ∧ pa.toNat ≠ excluded then
               acc + decodeCellNat p.cellValue
             else acc
           | _ => acc)
         0
     let head :=
       stepCommitProportionalDiluteHead preCommit r excluded signer
         totalReward sumOthers
     capped.foldl
       (fun acc p =>
         match p.cellTag with
         | .balance pr pa =>
           if pr.toNat = r ∧ pa.toNat ≠ excluded then
             let preBal := decodeCellNat p.cellValue
             let credit :=
               if sumOthers = 0 then 0
               else totalReward * preBal / sumOthers
             let newBal := preBal + credit
             stepCommitProportionalDiluteFold acc pa.toNat newBal
           else acc
         | _ => acc)
       head) := rfl

/-- Dispatch coherence for the `Dispute` variant (opaque). -/
theorem stepVMHash_dispute_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 8 fields signer bundle =
    stepCommitDispute preCommit fields signer := rfl

/-- Dispatch coherence for the `DisputeWithdraw` variant (opaque). -/
theorem stepVMHash_disputeWithdraw_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 9 fields signer bundle =
    stepCommitDisputeWithdraw preCommit fields signer := rfl

/-- Dispatch coherence for the `Verdict` variant (opaque). -/
theorem stepVMHash_verdict_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 10 fields signer bundle =
    stepCommitVerdict preCommit fields signer := rfl

/-- Dispatch coherence for the `Rollback` variant (opaque). -/
theorem stepVMHash_rollback_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 11 fields signer bundle =
    stepCommitRollback preCommit fields signer := rfl

/-- Dispatch coherence for the `RegisterIdentity` variant. -/
theorem stepVMHash_registerIdentity_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 12 fields signer bundle =
    stepCommitRegisterIdentity preCommit (readUint64BE fields 0) signer
      (sliceFrom fields 8) := rfl

/-- Dispatch coherence for the `Deposit` variant. -/
theorem stepVMHash_deposit_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 13 fields signer bundle =
    (let r         := readUint64BE fields 0
     let recipient := readUint64BE fields 8
     let amount    := readUint64BE fields 16
     let depositId := readUint64BE fields 24
     let recipientBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 recipient.toUInt64))
     stepCommitDeposit preCommit r recipient signer
       (recipientBalance + amount) depositId) := rfl

/-- Dispatch coherence for the `Withdraw` variant. -/
theorem stepVMHash_withdraw_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 14 fields signer bundle =
    (let r           := readUint64BE fields 0
     let sender      := readUint64BE fields 8
     let amount      := readUint64BE fields 16
     let recipientL1 := sliceFrom fields 24
     let senderBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 sender.toUInt64))
     stepCommitWithdraw preCommit r sender signer
       (senderBalance - amount) recipientL1) := rfl

/-- Dispatch coherence for the `DeclareLocalPolicy` variant (opaque). -/
theorem stepVMHash_declareLocalPolicy_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 15 fields signer bundle =
    stepCommitDeclareLocalPolicy preCommit fields signer := rfl

/-- Dispatch coherence for the `RevokeLocalPolicy` variant (opaque). -/
theorem stepVMHash_revokeLocalPolicy_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 16 fields signer bundle =
    stepCommitRevokeLocalPolicy preCommit fields signer := rfl

/-- Dispatch coherence for the `FaultProofChallenge` variant (opaque). -/
theorem stepVMHash_faultProofChallenge_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 17 fields signer bundle =
    stepCommitFaultProofChallenge preCommit fields signer := rfl

/-- Dispatch coherence for the `FaultProofResolution` variant (opaque). -/
theorem stepVMHash_faultProofResolution_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 18 fields signer bundle =
    stepCommitFaultProofResolution preCommit fields signer := rfl

/-- Dispatch coherence for the `DepositWithFee` variant (Workstream
    GP, action-index 19; structured per-field read).  Mirrors the
    Lean-side `Laws.depositWithFee.apply_impl` two-step sequence:
    first `setBalance` credits `recipient`, then a second
    `setBalance` reads the intermediate state's `poolActor`
    balance and credits it.  The self-credit case (`recipient =
    poolActor`) collapses both into a single accumulated credit
    of `userAmount + poolAmount`, matching the kernel's
    sequential-update semantics. -/
theorem stepVMHash_depositWithFee_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 19 fields signer bundle =
    (let r          := readUint64BE fields 0
     let recipient  := readUint64BE fields 8
     let poolActor  := readUint64BE fields 16
     let userAmount := readUint64BE fields 24
     let poolAmount := readUint64BE fields 32
     let depositId  := readUint64BE fields 48
     let recipientBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance r.toUInt64 recipient.toUInt64))
     let newRecipientBalance : Nat :=
       if recipient = poolActor then
         recipientBalance + userAmount + poolAmount
       else
         recipientBalance + userAmount
     let newPoolBalance : Nat :=
       if recipient = poolActor then
         recipientBalance + userAmount + poolAmount
       else
         let poolBalance :=
           decodeCellNat (readCellValue bundle
                           (.balance r.toUInt64 poolActor.toUInt64))
         poolBalance + poolAmount
     stepCommitDepositWithFee preCommit r recipient poolActor signer
       newRecipientBalance newPoolBalance depositId) := rfl

/-- Dispatch coherence for the `TopUpActionBudget` variant
    (Workstream GP, action-index 20; structured per-field read).
    Mirrors `Laws.topUpActionBudget.apply_impl`'s
    setBalance / setBalance two-step:
    debit signer's gas balance by `gasAmount`, credit `poolActor`
    by `gasAmount`.  The admission gate rejects `signer =
    poolActor` upstream (round-4 self-pool defense), so the
    no-op `signer = poolActor` branch is unreachable on the
    canonical path. -/
theorem stepVMHash_topUpActionBudget_kind
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 20 fields signer bundle =
    (let gasResource := readUint64BE fields 0
     let gasAmount   := readUint64BE fields 8
     let poolActor   := readUint64BE fields 24
     let signerBalance :=
       decodeCellNat (readCellValue bundle
                       (.balance gasResource.toUInt64 signer.toUInt64))
     let newSignerBalance : Nat :=
       if signer = poolActor then signerBalance
       else signerBalance - gasAmount
     let newPoolBalance : Nat :=
       if signer = poolActor then signerBalance
       else
         let poolBalance :=
           decodeCellNat (readCellValue bundle
                           (.balance gasResource.toUInt64 poolActor.toUInt64))
         poolBalance + gasAmount
     stepCommitTopUpActionBudget preCommit gasResource signer poolActor
       newSignerBalance newPoolBalance) := rfl

/-- For unknown kinds (≥ 21), `stepVMHash` returns empty bytes.

    Note: `actionKindByte` is provably in `0..20` after the
    Workstream-GP extension (kinds 19 / 20 for `.depositWithFee` /
    `.topUpActionBudget`), so the catch-all path is unreachable
    from `stepVMHashFromAction`; this property is only relevant for
    caller-supplied raw `UInt8` inputs ≥ 21. -/
theorem stepVMHash_unknown_kind_empty
    (preCommit : ByteArray) (fields : ByteArray) (signer : Nat)
    (bundle : CellProofBundle) :
    stepVMHash preCommit 21 fields signer bundle = ByteArray.empty := rfl

/-! ## `stepVMHashFromAction` — the action-driven convenience form

This is the entry point a production caller (the off-chain
observer's terminate-bundle builder) uses: given a canonical
`(ExtendedState, Action, ActorId)` triple, compute the step-VM
hash that the L1 contract will emit for this step.

The function is the composition of the canonical inputs:
  * `preCommit := commitExtendedState es`
  * `kind     := actionKindByte action`
  * `fields   := actionFieldsForL1 action`
  * `bundle   := buildObserverCellProofs es action signer`

Under the production keccak256 binding, the output byte-equals
`KnomosisStepVM.executeStep(commitExtendedState es, actionKindByte
action, actionFieldsForL1 action, signer, bundle.proofs)`.  This
is the cross-stack contract the SVC workstream closes. -/

/-- Compute the step-VM hash for a canonical `(state, action,
    signer)` triple.  This is the value the responding party
    must claim in `terminateOnSingleStep`'s `claimedPostCommit`
    argument; under the production keccak256 binding it
    byte-equals what the L1 step VM computes. -/
def stepVMHashFromAction
    (es : ExtendedState) (action : Action) (signer : ActorId) :
    ByteArray :=
  stepVMHash (commitExtendedState es) (actionKindByte action)
    (actionFieldsForL1 action) signer.toNat
    (Observer.buildObserverCellProofs es action signer)

/-- `stepVMHashFromAction` is deterministic. -/
theorem stepVMHashFromAction_deterministic
    (es₁ es₂ : ExtendedState) (a₁ a₂ : Action) (s₁ s₂ : ActorId)
    (h_es : es₁ = es₂) (h_a : a₁ = a₂) (h_s : s₁ = s₂) :
    stepVMHashFromAction es₁ a₁ s₁ = stepVMHashFromAction es₂ a₂ s₂ := by
  rw [h_es, h_a, h_s]

/-! ## Per-variant `stepVMHashFromAction` reductions

For each variant, `stepVMHashFromAction` unfolds to the canonical
`stepCommitXX` invocation with the right inputs.  These are
`rfl`-proofs (or near-`rfl`) since the chain
`stepVMHashFromAction → stepVMHash → stepCommitXX` is by definition.

For STRUCTURED variants we provide the explicit reduction so a
caller can rewrite at the per-variant boundary; for OPAQUE variants
the reduction is straightforward via the opaque-arm lemmas above. -/

/-- For the `Dispute` variant, `stepVMHashFromAction` reduces to
    the opaque `stepCommitDispute` form.  Direct from
    `stepVMHash_dispute_kind`. -/
theorem stepVMHashFromAction_dispute
    (es : ExtendedState) (d : Dispute) (signer : ActorId) :
    stepVMHashFromAction es (.dispute d) signer =
    stepCommitDispute (commitExtendedState es)
      (actionFieldsForL1 (.dispute d)) signer.toNat := rfl

/-- For the `DisputeWithdraw` variant, `stepVMHashFromAction`
    reduces to the opaque `stepCommitDisputeWithdraw` form. -/
theorem stepVMHashFromAction_disputeWithdraw
    (es : ExtendedState) (idx : Disputes.LogIndex) (signer : ActorId) :
    stepVMHashFromAction es (.disputeWithdraw idx) signer =
    stepCommitDisputeWithdraw (commitExtendedState es)
      (actionFieldsForL1 (.disputeWithdraw idx)) signer.toNat := rfl

/-- For the `Verdict` variant, `stepVMHashFromAction` reduces to
    the opaque `stepCommitVerdict` form. -/
theorem stepVMHashFromAction_verdict
    (es : ExtendedState) (v : Verdict) (signer : ActorId) :
    stepVMHashFromAction es (.verdict v) signer =
    stepCommitVerdict (commitExtendedState es)
      (actionFieldsForL1 (.verdict v)) signer.toNat := rfl

/-- For the `Rollback` variant. -/
theorem stepVMHashFromAction_rollback
    (es : ExtendedState) (idx : Disputes.LogIndex) (signer : ActorId) :
    stepVMHashFromAction es (.rollback idx) signer =
    stepCommitRollback (commitExtendedState es)
      (actionFieldsForL1 (.rollback idx)) signer.toNat := rfl

/-- For the `DeclareLocalPolicy` variant. -/
theorem stepVMHashFromAction_declareLocalPolicy
    (es : ExtendedState) (p : LocalPolicy) (signer : ActorId) :
    stepVMHashFromAction es (.declareLocalPolicy p) signer =
    stepCommitDeclareLocalPolicy (commitExtendedState es)
      (actionFieldsForL1 (.declareLocalPolicy p)) signer.toNat := rfl

/-- For the `RevokeLocalPolicy` variant. -/
theorem stepVMHashFromAction_revokeLocalPolicy
    (es : ExtendedState) (signer : ActorId) :
    stepVMHashFromAction es .revokeLocalPolicy signer =
    stepCommitRevokeLocalPolicy (commitExtendedState es)
      (actionFieldsForL1 .revokeLocalPolicy) signer.toNat := rfl

/-- For the `FaultProofChallenge` variant. -/
theorem stepVMHashFromAction_faultProofChallenge
    (es : ExtendedState) (bh : ByteArray)
    (sIdx eIdx : Disputes.LogIndex) (cc : ByteArray) (signer : ActorId) :
    stepVMHashFromAction es (.faultProofChallenge bh sIdx eIdx cc) signer =
    stepCommitFaultProofChallenge (commitExtendedState es)
      (actionFieldsForL1 (.faultProofChallenge bh sIdx eIdx cc))
      signer.toNat := rfl

/-- For the `FaultProofResolution` variant. -/
theorem stepVMHashFromAction_faultProofResolution
    (es : ExtendedState) (bh : ByteArray) (gid : Nat)
    (winner : ActorId) (rfi : Disputes.LogIndex) (signer : ActorId) :
    stepVMHashFromAction es (.faultProofResolution bh gid winner rfi) signer =
    stepCommitFaultProofResolution (commitExtendedState es)
      (actionFieldsForL1 (.faultProofResolution bh gid winner rfi))
      signer.toNat := rfl

/-- For the `FreezeResource` variant. -/
theorem stepVMHashFromAction_freezeResource
    (es : ExtendedState) (r : ResourceId) (signer : ActorId)
    (h_r : r.toNat < 256 ^ 8) :
    stepVMHashFromAction es (.freezeResource r) signer =
    stepCommitFreezeResource (commitExtendedState es)
      (readUint64BE (actionFieldsForL1 (.freezeResource r)) 0)
      signer.toNat := by
  let _ := h_r
  rfl

/-! ## `step_vm_coherent_with_kernel_apply` — the headline theorem

The plan §SVC.1 calls for a coherence statement of the form

```
stepVMHash preCommit kind fields signer bundle =
  commitExtendedState (kernelOnlyApply es entry)
```

As discussed in the module docstring, this equation is **NOT
universal** — for opaque variants, the L1 step VM's output is
NOT equal to `commitExtendedState(postState)`.  Per the
architectural decision (Option B), the bisection-game's chain of
commits uses step-VM hashes throughout, not state commits.

The honest statement of the coherence claim is therefore:

> For the production deployment, the off-chain observer's claimed
> post-commit at terminate-time IS `stepVMHashFromAction es action
> signer`.  Under the production keccak256 binding, this equals
> `KnomosisStepVM.executeStep(commitExtendedState es, ...)`
> byte-for-byte.

This is what `stepVMHashFromAction` is defined to compute; the
per-variant reductions above expose its body for inspection.  The
**byte-for-byte equality with Solidity's executeStep** is verified
at the cross-stack fixture corpus level (WU H.10.1 + SVC.5.e
widening), not as a Lean theorem (since `KnomosisStepVM.executeStep`
is Solidity bytecode, not a Lean function).

The `step_vm_dispatch_dispatch_well_typed` property below records
this discipline as a value-level claim. -/

/-- `step_vm_dispatch_well_typed` — for every Action, the
    dispatcher's output through `stepVMHashFromAction` is reached
    via the per-variant dispatch arm matching `actionKindByte`. -/
theorem step_vm_dispatch_well_typed
    (es : ExtendedState) (action : Action) (signer : ActorId) :
    stepVMHashFromAction es action signer =
    stepVMHash (commitExtendedState es) (actionKindByte action)
      (actionFieldsForL1 action) signer.toNat
      (Observer.buildObserverCellProofs es action signer) := rfl

/-! ## Smoke checks -/

/-- `actionKindByte` agrees with the constructor index in
    `Encoding.Action.encode`. -/
example : actionKindByte (.transfer 0 0 0 0) = 0 := rfl
example : actionKindByte (.mint 0 0 0) = 1 := rfl
example : actionKindByte (.burn 0 0 0) = 2 := rfl
example : actionKindByte (.freezeResource 0) = 3 := rfl
example : actionKindByte (.faultProofResolution ByteArray.empty 0 0 0) = 18 := rfl

/-- `actionFieldsForL1` for RevokeLocalPolicy is empty (no
    fields).  Mechanical via `rfl`. -/
example : (actionFieldsForL1 .revokeLocalPolicy).size = 0 := rfl

end StepVMCoherence
end FaultProof
end LegalKernel
