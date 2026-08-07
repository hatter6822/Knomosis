-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.StepVMCoherence — Workstream SVC: closure of
the L1 step-VM cross-stack coherence chain.

This module ships three load-bearing pieces:

  1. `actionKindByte : Action → UInt8` — the 0..24 dispatcher byte
     that the Solidity `executeStep(actionKind, ...)` consumes.
     Mirrors the `Encoding.Action.encode`'s leading-tag table and
     the `KnomosisStepVM.sol::ActionKind` enum.  (Workstream GP widened
     the range from 0..18 to 0..20 with `depositWithFee` = 19 and
     `topUpActionBudget` = 20; GP.5.3 added `topUpActionBudgetFor` =
     21; GP.9.1 `claimBudgetRefund` = 22; GP.11.4 `ammSwap` = 23; and
     GP.11.10 `reclaimAmmReserves` = 24.)

  2. `actionFieldsForL1 : Action → ByteArray` — the canonical byte
     layout the Solidity `_stepXX` decoders expect.  For structured
     variants the layout is a sequence of fixed-width big-endian
     fields (`uint64BE` per primitive numeric); for opaque variants
     it is the action's CBE-encoded payload (which the L1 step VM
     simply hashes via `keccak256(actionFields)` without inspecting
     internal structure).

  3. `stepVMHash` — the unified dispatcher over the 25 per-variant
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
output equalled the per-variant `SolidityStepVMCommit.stepCommit<variant>`
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

## Step-VM commit scope (what each `stepCommitXX` binds — and does NOT)

The per-variant step-VM hash binds the **kernel-state cell writes**
the step VM tracks — the `balance` cells (and, for the variants that
touch them, `registry` / `localPolicy` / bridge cells) — plus the
action's identity (the distinct per-variant tag), its
fixed-width fields, and the signer.  It deliberately does **NOT**
bind two classes of post-state:

  * **The signer's nonce.**  No variant folds the new nonce into its
    hash, even though every action advances it (`Action.writeCells`
    always lists `.nonce signer`).  The nonce cell is carried in the
    cell-proof bundle for witness verification, not for the output
    hash.
  * **The `epochBudgets` ledger.**  The Workstream-GP admission-layer
    effects — `depositWithFee`'s `budgetGrant` (kind 19),
    `topUpActionBudget`'s `budgetIncrement` (kind 20), and
    `topUpActionBudgetFor`'s `recipient` + `budgetIncrement` (kind 21)
    — are excluded.  There is no `epochBudgets` `CellTag`, so these
    effects are outside the cell-proof model the step VM re-executes.

**Consequence (a deliberate, design-wide scope boundary, NOT a
per-variant choice).**  A bisection-game terminate step catches a
sequencer who lies about a *balance* write, but NOT one who lies about
a nonce advance or an epoch-budget credit, because the honest
re-execution produces the same step-VM hash regardless of those
effects.  This boundary is uniform across all 25 variants; kind 21's
exclusion of `recipient` / `budgetIncrement` is the same posture kinds
19 / 20 take for their budget fields.  Binding `epochBudgets` would
require (1) an `epochBudgets` `CellTag` + cell-proof construction and
(2) folding the new budget value into every GP-variant hash on BOTH
stacks — a TCB-adjacent, design-wide change that is a Genesis-Plan
§13.6 amendment, tracked as `OQ-GP-11` in
`docs/planning/open_questions.md`, not a GP.5.3 deliverable.
The L2 admission gate (`topUpActionBudgetFor_gate` et al.) fully
governs the budget effects on the honest-sequencer path; the gap is
strictly the on-chain *re-execution* arm for a dishonest sequencer's
budget lie.

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
import LegalKernel.FaultProof.StepVariants
import LegalKernel.FaultProof.SubStep
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
open LegalKernel.Runtime

/-! ## `actionKindByte` — the constructor-index dispatcher byte

Mirrors `Encoding.Action.encode`'s leading-tag table (which uses
`Encodable.encode (T := Nat) <idx>`).  The Solidity-side
`KnomosisStepVM.ActionKind` enum has the same indices.  Kinds `0..24`
have a real `stepVMHash` execution arm with a cross-stack Solidity
counterpart (GP.5.3 closed the index-`21` `topUpActionBudgetFor` arm
that GP.3.4 had staged; GP.9.1 / GP.11.4 / GP.11.10 added kinds 22 /
23 / 24). -/

/-! ## Endian-encoding helpers

These match the byte layout `abi.encodePacked` produces in Solidity
0.8.x: each integer is big-endian, fixed-width per its declared type.

They lived in `SolidityStepVMCommit.lean` alongside the retired
per-variant hash, and moved here when that module was deleted: they
are the L1 FIELD LAYOUT, which `actionFieldsForL1` below is built
from, and were never bound to the hash recipe. -/

/-- Encode a `Nat` (assumed `< 2^64`) as 8 big-endian bytes.
    Matches Solidity's `abi.encodePacked(uint64)`. -/
def uint64BE (n : Nat) : ByteArray :=
  ByteArray.mk
    #[((n >>> 56) &&& 0xFF).toUInt8,
      ((n >>> 48) &&& 0xFF).toUInt8,
      ((n >>> 40) &&& 0xFF).toUInt8,
      ((n >>> 32) &&& 0xFF).toUInt8,
      ((n >>> 24) &&& 0xFF).toUInt8,
      ((n >>> 16) &&& 0xFF).toUInt8,
      ((n >>>  8) &&& 0xFF).toUInt8,
      ( n         &&& 0xFF).toUInt8]

/-- Encode a `Nat` (assumed `< 2^256`) as 32 big-endian bytes.
    Matches Solidity's `abi.encodePacked(uint256)`.  Inlined as
    a 32-element array literal so `rfl` can decide its size.

    The width for *value-carrying* fields in the L1 step-VM calldata
    layout.  `uint64BE` remains correct for identifiers, log indices,
    deposit ids and unit counts, which are `UInt64`-typed at the
    source and cannot exceed the narrower range; an amount can, and
    this layout is a *separate* encoding from the CBE codec with its
    own truncation boundary.  Widening one without the other would
    leave the fault proof unable to adjudicate a large-amount action,
    which is why the two move together.

    A 16-byte `uint256BE` sat here through the previous widening and
    is gone: nothing should be able to reach for a too-narrow amount
    encoder by accident, and `Laws.maxAmount` is `2^256` exactly so
    that this field and the CBE head have the same ceiling. -/
def uint256BE (n : Nat) : ByteArray :=
  ByteArray.mk
    #[((n >>> 248) &&& 0xFF).toUInt8,
      ((n >>> 240) &&& 0xFF).toUInt8,
      ((n >>> 232) &&& 0xFF).toUInt8,
      ((n >>> 224) &&& 0xFF).toUInt8,
      ((n >>> 216) &&& 0xFF).toUInt8,
      ((n >>> 208) &&& 0xFF).toUInt8,
      ((n >>> 200) &&& 0xFF).toUInt8,
      ((n >>> 192) &&& 0xFF).toUInt8,
      ((n >>> 184) &&& 0xFF).toUInt8,
      ((n >>> 176) &&& 0xFF).toUInt8,
      ((n >>> 168) &&& 0xFF).toUInt8,
      ((n >>> 160) &&& 0xFF).toUInt8,
      ((n >>> 152) &&& 0xFF).toUInt8,
      ((n >>> 144) &&& 0xFF).toUInt8,
      ((n >>> 136) &&& 0xFF).toUInt8,
      ((n >>> 128) &&& 0xFF).toUInt8,
      ((n >>> 120) &&& 0xFF).toUInt8,
      ((n >>> 112) &&& 0xFF).toUInt8,
      ((n >>> 104) &&& 0xFF).toUInt8,
      ((n >>>  96) &&& 0xFF).toUInt8,
      ((n >>>  88) &&& 0xFF).toUInt8,
      ((n >>>  80) &&& 0xFF).toUInt8,
      ((n >>>  72) &&& 0xFF).toUInt8,
      ((n >>>  64) &&& 0xFF).toUInt8,
      ((n >>>  56) &&& 0xFF).toUInt8,
      ((n >>>  48) &&& 0xFF).toUInt8,
      ((n >>>  40) &&& 0xFF).toUInt8,
      ((n >>>  32) &&& 0xFF).toUInt8,
      ((n >>>  24) &&& 0xFF).toUInt8,
      ((n >>>  16) &&& 0xFF).toUInt8,
      ((n >>>   8) &&& 0xFF).toUInt8,
      ( n          &&& 0xFF).toUInt8]

/-- Size of `uint64BE` is exactly 8. -/
theorem uint64BE_size (n : Nat) : (uint64BE n).size = 8 := by
  unfold uint64BE
  rfl

set_option maxHeartbeats 1000000 in
/-- `uint64BE` is injective below `2 ^ 64`.

    Proof strategy: byte-equality of the two encodings yields the
    eight big-endian byte equations; rewriting shifts as division and
    the `0xFF` mask as `% 256` turns them into linear div/mod facts
    `omega` can combine with the width bounds to conclude `n₁ = n₂`.

    The bound is not decorative — `uint64BE` truncates above it
    (`uint64BE (2 ^ 64) = uint64BE 0`), which is exactly why every
    consumer either carries a `< 2 ^ 64` hypothesis or reads the
    value out of a `UInt64`. -/
theorem uint64BE_inj {n₁ n₂ : Nat} (h₁ : n₁ < 2 ^ 64) (h₂ : n₂ < 2 ^ 64)
    (h : uint64BE n₁ = uint64BE n₂) : n₁ = n₂ := by
  -- ByteArray → Array → List → per-byte equations.
  unfold uint64BE at h
  injection h with harr
  have hlist := congrArg Array.toList harr
  simp only [List.cons.injEq, and_true] at hlist
  obtain ⟨e7, e6, e5, e4, e3, e2, e1, e0⟩ := hlist
  -- UInt8 equality → Nat-mod equality per byte.
  have toNat8 : ∀ {a b : Nat}, a.toUInt8 = b.toUInt8 → a % 256 = b % 256 := by
    intro a b hab
    have := congrArg UInt8.toNat hab
    simpa [Nat.toUInt8, UInt8.toNat_ofNat] using this
  have m7 := toNat8 e7
  have m6 := toNat8 e6
  have m5 := toNat8 e5
  have m4 := toNat8 e4
  have m3 := toNat8 e3
  have m2 := toNat8 e2
  have m1 := toNat8 e1
  have m0 := toNat8 e0
  -- Stage 1: shifts → division; mask → mod (`0xFF = 2 ^ 8 - 1`).
  -- Kept SEPARATE from the pow-reduction stage: in one pass the
  -- `Nat.reducePow` simproc rewrites `2 ^ 8 - 1` straight back to a
  -- numeral before the mask lemma can see the `&&& (2 ^ 8 - 1)`
  -- shape, the `&&&`s survive, and `omega` silently drops every
  -- hypothesis containing one.
  simp only [Nat.shiftRight_eq_div_pow,
             show (0xFF : Nat) = 2 ^ 8 - 1 from rfl,
             Nat.and_two_pow_sub_one_eq_mod] at m7 m6 m5 m4 m3 m2 m1 m0
  -- Stage 2: pows → numerals so `omega` sees plain div/mod facts.
  simp only [Nat.reducePow] at m7 m6 m5 m4 m3 m2 m1 m0 h₁ h₂
  -- Eight base-256 digit equations + the width bounds pin the value.
  omega

/-- Size of `uint256BE` is exactly 32. -/
theorem uint256BE_size (n : Nat) : (uint256BE n).size = 32 := by
  unfold uint256BE
  rfl

/-- The constructor-index dispatcher byte for an `Action`.  Mirrors
    the Solidity `ActionKind` enum and `Encoding.Action.encode`'s
    leading-tag emission.  Frozen, append-only: a new variant takes
    the next index (currently `0..25`; `25` = `reserveSwap`). -/
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
  | .depositWithFee _ _ _ _ _ _ _ _  => 19
  | .topUpActionBudget _ _ _ _     => 20
  -- Workstream GP (GP.3.4): delegated top-up.  Dispatcher index 21.
  -- GP.5.3 wired the L1 step-VM execution arm + Solidity `_step21`
  -- decoder + cross-stack fixtures, so this kind is now
  -- L1-fault-proof-executable (see `stepVMHash`'s kind-21 arm).
  | .topUpActionBudgetFor _ _ _ _ _ => 21
  -- Workstream GP (GP.9.1): refund-on-exit.  Dispatcher index 22.
  -- The `stepVMHash` EXECUTION arm (kind 22, `stepCommitClaimBudgetRefund`),
  -- the Solidity `_stepClaimBudgetRefund` decoder, and the cross-stack
  -- fixtures all ship, so kind 22 is L1-fault-proof-*executable* (the
  -- `actionFieldsForL1` layout + `readOnlyCells` / `writeCells` cell sets
  -- ship here too, so the cell-proof bundle is well-formed).  `stepVMHash`
  -- now returns the empty-hash sentinel only for kinds `≥ 23` (see
  -- `stepVMHash_unknown_kind_empty`).
  | .claimBudgetRefund _ _ _ _      => 22
  -- Index 23 (`ammSwap`) is RETIRED with the excised L1 embedded AMM;
  -- the dispatcher slot stays reserved and no kind may reuse it.
  -- Workstream GP (GP.11.10): post-disable reserve sweep.  Dispatcher
  -- index 24.  The `stepVMHash` execution arm (kind 24,
  -- `stepCommitReclaimAmmReserves`), the Solidity
  -- `_stepReclaimAmmReserves` decoder, and the cross-stack fixtures
  -- ship alongside, so kind 24 is L1-fault-proof-*executable*.
  | .reclaimAmmReserves _ _ _ _     => 24
  -- Workstream SB: the user-facing L2 swap.  Dispatcher index 25.
  -- The verifier-side derivation (`VerifierWrites`) and the Solidity
  -- root-computing kind-25 arm re-derive the constant-product quote
  -- from the opened pre-value cells at the shared
  -- `AmmMath.swapFeeBps`.
  | .reserveSwap _ _ _ _ _ _        => 25

/-! ## `actionFieldsForL1` — canonical byte layout per variant

For STRUCTURED variants (Transfer, Mint, Burn, FreezeResource,
ReplaceKey, Reward, DistributeOthers, ProportionalDilute,
RegisterIdentity, Deposit, Withdraw): the layout is a sequence of
fixed-width big-endian fields followed by any variable-length
trailing payload.  Field width is set by what the field *is*:
identifiers, log indices, deposit ids and budget-unit counts are
`uint64BE` (8 bytes); value-carrying amounts are `uint256BE`
(32 bytes).  This matches the Solidity `_stepXX` decoder's
`readFieldUint` reads byte-for-byte.

The amount width is not the CBE codec's.  `actionFieldsForL1` is a
*separate* encoding — untagged, big-endian, fixed-width — read only
by the L1 step VM, so it carried its own independent `2^64`
truncation boundary.  Widening the CBE head alone would have left
the fault proof unable to adjudicate an action whose amount the L2
can represent.

For OPAQUE variants (Dispute, DisputeWithdraw, Verdict, Rollback,
DeclareLocalPolicy, RevokeLocalPolicy, FaultProofChallenge,
FaultProofResolution): the L1's `_stepXX` only hashes the bytes
(`keccak256(actionFields)`); the internal structure is opaque.  We
use the Lean-side `Encodable.encode` payload directly, which is
the most natural cross-stack convention.

**Width discipline.**  Each `uint64BE` produces exactly 8 bytes;
each `uint256BE` exactly 32;
variable-length trailers (newKey, pk, recipientL1) are appended
as-is. -/

/-- The canonical byte layout the L1 step VM's `_stepXX` decoder
    consumes.  For structured variants this is a sequence of
    big-endian fixed-width fields plus any variable-length trailing
    payload; for opaque variants this is the Lean-side
    `Encodable.encode` payload (the L1 step VM only hashes it). -/
def actionFieldsForL1 : Action → ByteArray
  -- Structured variants: identifiers on `uint64BE`, amounts on
  -- `uint256BE`, e.g. `uint64BE r || uint64BE sender || ...`
  | .transfer r sender receiver amount =>
      uint64BE r.toNat ++ uint64BE sender.toNat ++
      uint64BE receiver.toNat ++ uint256BE amount
  | .mint r to amount =>
      uint64BE r.toNat ++ uint64BE to.toNat ++ uint256BE amount
  | .burn r fromActor amount =>
      uint64BE r.toNat ++ uint64BE fromActor.toNat ++ uint256BE amount
  | .freezeResource r =>
      uint64BE r.toNat
  | .replaceKey actor newKey =>
      -- `uint64BE actor || newKey-bytes` (variable trailer).
      uint64BE actor.toNat ++ newKey
  | .reward r to amount =>
      uint64BE r.toNat ++ uint64BE to.toNat ++ uint256BE amount
  | .distributeOthers r excluded amount =>
      uint64BE r.toNat ++ uint64BE excluded.toNat ++ uint256BE amount
  | .proportionalDilute r excluded totalReward =>
      uint64BE r.toNat ++ uint64BE excluded.toNat ++ uint256BE totalReward
  | .registerIdentity actor pk =>
      uint64BE actor.toNat ++ pk
  | .deposit r recipient amount depositId =>
      uint64BE r.toNat ++ uint64BE recipient.toNat ++
      uint256BE amount ++ uint64BE depositId
  | .withdraw r sender amount recipientL1 =>
      uint64BE r.toNat ++ uint64BE sender.toNat ++
      uint256BE amount ++ Bridge.EthAddress.toBytes recipientL1
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
  -- uint256BE userAmount || uint256BE poolAmount || uint64BE budgetGrant
  -- || uint64BE depositId || uint256BE seedAmount`.  Mirrors the
  -- Solidity `_step19` decoder's byte-for-byte field reads.
  -- `budgetGrant` is a budget UNIT count and `depositId` an
  -- identifier, so both stay 8 bytes.  Workstream SB APPENDS the
  -- wei-denominated `seedAmount` (104 → 136 bytes), so every
  -- pre-existing field offset survives.
  | .depositWithFee r recipient poolActor userAmount poolAmount budgetGrant depositId
                     seedAmount =>
      uint64BE r.toNat ++ uint64BE recipient.toNat ++ uint64BE poolActor.toNat ++
      uint256BE userAmount ++ uint256BE poolAmount ++ uint64BE budgetGrant ++
      uint64BE depositId ++ uint256BE seedAmount
  -- topUpActionBudget is a structured variant:
  -- `uint64BE gasResource || uint256BE gasAmount || uint64BE budgetIncrement ||
  -- uint64BE poolActor`.  `gasAmount` is wei-denominated and so rides the
  -- wide field; `budgetIncrement` is a UNIT count and stays 8 bytes.  The
  -- signer is provided separately to the L1 step VM via the SignedAction
  -- payload, not encoded in the action fields.
  | .topUpActionBudget gasResource gasAmount budgetIncrement poolActor =>
      uint64BE gasResource.toNat ++ uint256BE gasAmount ++
      uint64BE budgetIncrement ++ uint64BE poolActor.toNat
  -- Workstream GP (GP.3.4 / GP.5.3): delegated top-up is a structured
  -- variant: `uint64BE recipient || uint64BE gasResource ||
  -- uint256BE gasAmount || uint64BE budgetIncrement || uint64BE
  -- poolActor`.  The kernel-state effect mirrors `topUpActionBudget`
  -- (debit signer at gasResource, credit poolActor); `recipient` and
  -- `budgetIncrement` are admission-layer fields (recipient consent +
  -- budget grant), decoded for layout symmetry but excluded from the
  -- step-VM hash by design.  GP.5.3 wired the matching Solidity
  -- `_step21` decoder + cross-stack fixtures + the `stepVMHash` kind-21
  -- execution arm.
  | .topUpActionBudgetFor recipient gasResource gasAmount budgetIncrement poolActor =>
      uint64BE recipient.toNat ++ uint64BE gasResource.toNat ++
      uint256BE gasAmount ++ uint64BE budgetIncrement ++ uint64BE poolActor.toNat
  -- Workstream GP (GP.9.1): claimBudgetRefund is a structured variant:
  -- `uint64BE gasResource || uint64BE budgetUnits ||
  -- uint256BE weiPerBudgetUnit || uint64BE poolActor`.  The kernel-state
  -- effect (debit poolActor at gasResource by `budgetUnits ×
  -- weiPerBudgetUnit`, credit the signer/claimant) is the MIRROR of
  -- `topUpActionBudget`; `weiPerBudgetUnit` is decoded for layout
  -- symmetry (it determines the refund amount) while the signer
  -- (claimant) is provided to the L1 step VM via the SignedAction
  -- payload, not encoded in the action fields.  This frozen layout is
  -- what the GP.9.1 `stepVMHash`/Solidity `_step22` follow-on consumes.
  -- OVERFLOW NOTE for that follow-on: `budgetUnits` is `fieldsBounded`
  -- to < 2^64 and `weiPerBudgetUnit` (a wei-denominated rate) to
  -- < 2^128, so their PRODUCT (the payout) can reach ~2^192 — the
  -- Solidity `_step22` MUST compute `budgetUnits * weiPerBudgetUnit` in
  -- `uint256`, never a narrower type (as `_stepTopUpActionBudget`
  -- handles its own gas-transfer amount).
  | .claimBudgetRefund gasResource budgetUnits weiPerBudgetUnit poolActor =>
      uint64BE gasResource.toNat ++ uint64BE budgetUnits ++
      uint256BE weiPerBudgetUnit ++ uint64BE poolActor.toNat
  -- Workstream GP (GP.11.10): reclaimAmmReserves is a structured
  -- variant: `uint64BE r || uint256BE amount || uint64BE reserveActor
  -- || uint64BE poolActor`.  The kernel-state effect (debit
  -- reserveActor at r by amount — its entire balance under the
  -- exact-sweep precondition — and credit poolActor the same amount)
  -- is mirrored byte-for-byte by the Solidity
  -- `_stepReclaimAmmReserves`.
  | .reclaimAmmReserves r amount reserveActor poolActor =>
      uint64BE r.toNat ++ uint256BE amount ++
      uint64BE reserveActor.toNat ++ uint64BE poolActor.toNat
  -- Workstream SB: reserveSwap is a structured variant:
  -- `uint64BE fromResource || uint64BE toResource || uint64BE user ||
  -- uint256BE amountIn || uint256BE minAmountOut || uint64BE
  -- reserveActor` (96 bytes: fromResource@0, toResource@8, user@16,
  -- amountIn@24, minAmountOut@56, reserveActor@88).  The kernel-state
  -- effect (the four chained balance writes priced by the
  -- constant-product quote over the reserve's opened pre-values) is
  -- re-derived — not read from the fields — by both stacks'
  -- verifier-side write derivations; `minAmountOut` is decoded so the
  -- evaluated precondition can check the slippage floor exactly as
  -- the law does.
  | .reserveSwap fromResource toResource user amountIn minAmountOut reserveActor =>
      uint64BE fromResource.toNat ++ uint64BE toResource.toNat ++
      uint64BE user.toNat ++ uint256BE amountIn ++ uint256BE minAmountOut ++
      uint64BE reserveActor.toNat

/-! ## The L1 log-entry chain

The L1 mirror of `Runtime.LogFile.LogEntry.hash`.  Both chain a log
entry to its predecessor, and both commit to the ACTION that produced
the entry — but over different encodings, because the L1 never sees a
CBE-encoded `SignedAction`.  It sees the
`(actionKindByte, signer, actionFieldsForL1)` triple, so that is what
it commits to.

Mirrored byte-for-byte by `solidity/src/lib/LogChain.sol`, which is
where the encoding's design constraints are recorded, and pinned
per-entry by the `step_vm.json` cross-stack corpus. -/

/-- The L1 commitment to a signed action's step-VM form:
    `hash(actionKindByte ‖ uint64BE signer ‖ actionFieldsForL1)`.

    The variable-length field goes LAST.  The concatenation carries no
    length prefixes, so a leading variable-length component would make
    the encoding ambiguous; with the fields last, the first nine bytes
    are fixed-width and the remainder is exactly the fields, which
    makes the encoding injective on the triple.

    This is what `KnomosisStateRootSubmission.submitStateRoot` binds
    into the chain and what
    `KnomosisFaultProofGame.terminateOnSingleStep` re-derives from the
    action it is handed. -/
def l1ActionCommitBytes (kind : UInt8) (signer : Nat) (fields : ByteArray) :
    ByteArray :=
  LegalKernel.Runtime.hashBytes
    (ByteArray.mk #[kind] ++ uint64BE signer ++ fields)

/-- The same commitment over an `Action`, projecting the triple. -/
def l1ActionCommit (action : Action) (signer : ActorId) : ByteArray :=
  l1ActionCommitBytes (actionKindByte action) signer.toNat
    (actionFieldsForL1 action)

/-- Extend the L1 log-entry chain by one entry:
    `hash(prevLogEntryHash ‖ stateCommit ‖ actionCommit)`.

    Solidity spells this `keccak256(abi.encode(a, b, c))`, which for
    three `bytes32` values is their plain 96-byte concatenation — no
    offsets, no padding — so the mirror is a concatenation. -/
def l1NextEntryHash
    (prevLogEntryHash stateCommit actionCommit : ByteArray) : ByteArray :=
  LegalKernel.Runtime.hashBytes (prevLogEntryHash ++ stateCommit ++ actionCommit)

/-- The action commitment is 32 bytes, as every `hashBytes` output is
    — so it fits the `bytes32` the L1 chain stores it in. -/
theorem l1ActionCommit_size (action : Action) (signer : ActorId) :
    (l1ActionCommit action signer).size = 32 :=
  LegalKernel.Runtime.hashBytes_size _

/-- ...and so is the chain value it feeds. -/
theorem l1NextEntryHash_size (p s a : ByteArray) :
    (l1NextEntryHash p s a).size = 32 :=
  LegalKernel.Runtime.hashBytes_size _

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

    **Concrete decoder — exact-width, tag-dispatched.**  The payload
    width is derived from the leading CBE type byte, and the slice
    must match it exactly.  This mirrors Solidity's `_decodeNat`
    arm-for-arm:
      * `bytes.size == 0` → return 0.  Matches Solidity's
        `if (data.length == 0) return 0` early-out.  This is the
        canonical-absent path: when a balance cell is absent from
        the bundle, `readCellValue` returns
        `canonicalAbsentValue` (= empty bytes), and both sides
        treat the absent cell as a 0 pre-balance.
      * tag `cbeTagUint` with exactly 9 bytes → read the 8-byte
        little-endian payload.  Identifier-width cells (nonces, the
        next-withdrawal id).
      * tag `cbeTagAmount` with exactly 33 bytes → read the 32-byte
        little-endian payload.  Balance cells, which are
        wei-denominated and therefore cross `2^64`.
      * anything else — unknown tag, or a length that does not match
        its tag → return 0.  Solidity reverts here; see the section
        above on why this returns 0 rather than modelling a revert in
        a pure `Nat`-valued function.  Both outcomes mean "the
        dispatcher cannot produce the responsible party's claim".

    Deriving the width from the tag rather than assuming 8 bytes is
    load-bearing.  A fixed 8-byte read against a 33-byte amount cell
    returns the low 64 bits — a *wrong balance*, silently, on exactly
    the values a bisection game settles against. -/
def decodeCellNat (bytes : ByteArray) : Nat :=
  if bytes.size = 0 then 0
  else
    let tag := bytes.data[0]!
    let width :=
      if tag = Encoding.cbeTagUint then 8
      else if tag = Encoding.cbeTagAmount then 32
      else 0
    if width = 0 ∨ bytes.size ≠ 1 + width then 0
    else
      -- Read `bytes[1 .. 1+width]` little-endian.  Mirrors Solidity's
      -- `result |= uint256(uint8(data[1 + i])) << (8 * i)` loop.
      (List.range width).foldl
        (fun acc i => acc ||| (bytes.data[1 + i]!.toNat <<< (8 * i))) 0

/-! ## `stepVMHash` — unified dispatcher

The Lean reference for what Solidity's `executeStep` returns.  Given
the dispatcher byte, the action fields' bytes, the signer's id,
and the cell-proof bundle, computes the per-variant step-VM hash.

**Failure modes.**  For an unknown `kind` (≥ 22), returns
`canonicalAbsentValue` (0 bytes).  Solidity-side reverts with
`UnknownActionKind`; the Lean side surfaces it as an empty hash
that won't match any L1-produced commit.  Production callers
(`stepVMHashFromAction`) construct `kind` from `actionKindByte`,
which is provably in 0..21 — so the catch-all path is unreachable
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

/-- Read a big-endian `uint256` (32 bytes) from `bytes` at offset `o`.

    **Cross-stack contract.**  The 32-byte counterpart of
    `readUint64BE`, mirroring Solidity's
    `StepWrites.readFieldUint(fields, offset, 32)`, with the same
    out-of-bounds convention (Lean returns 0; Solidity reverts — both
    map to "dispatcher cannot produce the responsible party's claim",
    so the success domains still match byte-for-byte).

    Used for every value-carrying amount field.  Identifiers, log
    indices, deposit ids and budget-unit counts keep `readUint64BE`.

    The 16-byte `readUint128BE` that sat here is gone along with its
    encoder: a too-narrow amount reader is the same footgun on the
    decode side, and it would silently return a truncated value
    rather than fail. -/
def readUint256BE (bytes : ByteArray) (offset : Nat) : Nat :=
  if offset + 32 > bytes.size then 0
  else
    (readUint64BE bytes offset) <<< 192 |||
    (readUint64BE bytes (offset + 8)) <<< 128 |||
    (readUint64BE bytes (offset + 16)) <<< 64 |||
    (readUint64BE bytes (offset + 24))

/-- Slice a byte array from `offset` to its end.  Mirrors
    Solidity's `actionFields[offset:]` slice expression. -/
def sliceFrom (bytes : ByteArray) (offset : Nat) : ByteArray :=
  bytes.extract offset bytes.size

/-! ## The retired step-VM hash

`stepVMHash` lived here: a 25-arm dispatcher returning a bespoke
per-variant hash, mirrored by `KnomosisStepVM.executeStep`, with 37
theorems pinning each arm to its `actionKindByte`.  Both stacks
computed it identically, on all 278 corpus entries — and their
agreement said nothing about whether either equalled a published state
root, which is the only property the fault-proof game needs.  The
terminal comparison was between two different constructions, so an
honest sequencer lost every game it correctly defended.

`KnomosisStepVMRoot.executeStepToRoot` and
`FaultProof.verifierPostRoot` replaced it: they DERIVE a step's cell
writes from proven pre-values and fold them onto the pre-state root,
so the value they return IS a state root.  Nothing referenced the old
recipe when it was removed.

What survives from this module is the L1 FIELD LAYOUT —
`actionKindByte`, `actionFieldsForL1`, the big-endian readers, and the
log-entry chain's `l1ActionCommit`.  Those were never recipe-bound.
`docs/planning/state_root_merkleisation_plan.md` §5's S7. -/

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
