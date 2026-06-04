-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.SolidityStepVMCommit — Lean-side mirror of
the L1 `KnomosisStepVM.executeStep` per-variant post-commit recipe.

The Solidity recipe uses a uniform `keccak256(preCommit || tagHash
|| packed-fields)` shape across every variant.  Each variant binds
its identity via a distinct `keccak256("variant-name")` 32-byte tag,
avoiding both `abi.encode`'s dynamic-offset complexity and
`abi.encodePacked`'s tag-collision risk:

  keccak256(abi.encodePacked(
      preCommit,                              // 32 bytes
      keccak256(bytes("variant-name")),       // 32 bytes (tag hash)
      [packed-fields...]
  ))

Where each field's byte width:
  * uint64    → 8 bytes big-endian
  * uint256   → 32 bytes big-endian
  * bytes32   → 32 bytes
  * bytes (variable) → keccak256(bytes) (32 bytes)

This module ships one `stepCommit<Variant>` function per Action
constructor that produces the **exact same bytes** Solidity's
`_step<Variant>` would.  Under the production keccak256 binding
(`Bridge.HashAdaptor.isKeccak256Linked = true`), Lean-side
`stepCommit<X> = Solidity's _stepX` output byte-for-byte; this
is the cross-stack equivalence claim, verified at the WU H.10.1
fixture-corpus level.

**Why this isn't `commitExtendedState`.**  The L1 step VM
operates over per-cell proofs without holding the full
ExtendedState; its post-commit is a step-VM-specific hash, not
the full 5-component `commitExtendedState`.  The bisection
game's chain of commits uses step-VM commits throughout (state-
root submission, midpoints, terminal disputation).  Cross-stack
correctness requires Lean and Solidity to agree on the step-VM
commit recipe; that agreement is what this module establishes.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Bridge.Eip712
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Runtime.Hash
import LegalKernel.Authority.Crypto

namespace LegalKernel
namespace FaultProof
namespace SolidityStepVMCommit

open LegalKernel.Authority

/-! ## Endian-encoding helpers

These match the byte layout `abi.encodePacked` produces in
Solidity 0.8.x: each integer is big-endian, fixed-width per its
declared type. -/

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
    a 32-element array literal so `rfl` can decide its size. -/
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

/-- Size of `uint256BE` is exactly 32. -/
theorem uint256BE_size (n : Nat) : (uint256BE n).size = 32 := by
  unfold uint256BE
  rfl

/-! ## Per-variant tag hashes

Each tag is the keccak256 of the ASCII bytes of the variant name,
matching Solidity's `keccak256("variant-name")` exactly.

At the Lean level we use `LegalKernel.Runtime.hashBytes` (which
under the production binding = keccak256; under the FNV-1a-64
fallback = FNV).  These are byte-equal to Solidity's tag hashes
ONLY under the production binding; the fallback produces
8-byte FNV outputs that won't match Solidity's 32-byte
keccak256.  The cross-stack test correctly skips when the
binding isn't linked. -/

/-- Hash a string's UTF-8 bytes via the production hash adaptor.
    `s.toUTF8` already returns a `ByteArray`. -/
def hashString (s : String) : ByteArray :=
  LegalKernel.Runtime.hashBytes s.toUTF8

/-- Tag hash for `transfer`. -/
def tagTransfer             : ByteArray := hashString "transfer"
/-- Tag hash for `mint`. -/
def tagMint                 : ByteArray := hashString "mint"
/-- Tag hash for `burn`. -/
def tagBurn                 : ByteArray := hashString "burn"
/-- Tag hash for `freezeResource`. -/
def tagFreezeResource       : ByteArray := hashString "freezeResource"
/-- Tag hash for `replaceKey`. -/
def tagReplaceKey           : ByteArray := hashString "replaceKey"
/-- Tag hash for `reward`. -/
def tagReward               : ByteArray := hashString "reward"
/-- Tag hash for `distributeOthers`. -/
def tagDistributeOthers     : ByteArray := hashString "distributeOthers"
/-- Tag hash for `proportionalDilute`. -/
def tagProportionalDilute   : ByteArray := hashString "proportionalDilute"
/-- Tag hash for `dispute`. -/
def tagDispute              : ByteArray := hashString "dispute"
/-- Tag hash for `disputeWithdraw`. -/
def tagDisputeWithdraw      : ByteArray := hashString "disputeWithdraw"
/-- Tag hash for `verdict`. -/
def tagVerdict              : ByteArray := hashString "verdict"
/-- Tag hash for `rollback`. -/
def tagRollback             : ByteArray := hashString "rollback"
/-- Tag hash for `registerIdentity`. -/
def tagRegisterIdentity     : ByteArray := hashString "registerIdentity"
/-- Tag hash for `deposit`. -/
def tagDeposit              : ByteArray := hashString "deposit"
/-- Tag hash for `withdraw`. -/
def tagWithdraw             : ByteArray := hashString "withdraw"
/-- Tag hash for `declareLocalPolicy`. -/
def tagDeclareLocalPolicy   : ByteArray := hashString "declareLocalPolicy"
/-- Tag hash for `revokeLocalPolicy`. -/
def tagRevokeLocalPolicy    : ByteArray := hashString "revokeLocalPolicy"
/-- Tag hash for `faultProofChallenge`. -/
def tagFaultProofChallenge  : ByteArray := hashString "faultProofChallenge"
/-- Tag hash for `faultProofResolution`. -/
def tagFaultProofResolution : ByteArray := hashString "faultProofResolution"
/-- Tag hash for `depositWithFee` (Workstream GP, action-index 19). -/
def tagDepositWithFee       : ByteArray := hashString "depositWithFee"
/-- Tag hash for `topUpActionBudget` (Workstream GP, action-index 20). -/
def tagTopUpActionBudget    : ByteArray := hashString "topUpActionBudget"
/-- Tag hash for `topUpActionBudgetFor` (Workstream GP, action-index 21). -/
def tagTopUpActionBudgetFor : ByteArray := hashString "topUpActionBudgetFor"
/-- Tag hash for `claimBudgetRefund` (Workstream GP.9.1, action-index 22). -/
def tagClaimBudgetRefund    : ByteArray := hashString "claimBudgetRefund"

/-! ## Per-variant commit functions (one per Action constructor) -/

/-- `transfer` step-VM commit.  Mirrors Solidity's `_stepTransfer`
    post-commit recipe exactly:
    `keccak256(preCommit || TAG_TRANSFER || r || sender || newSenderBal
              || receiver || newReceiverBal || signer)`.

    Self-transfer handling: when `sender == receiver`, both
    `newSenderBal` and `newReceiverBal` should equal the original
    pre-balance (per the §4.11 post-debit re-read pattern). -/
def stepCommitTransfer
    (preCommit : ByteArray)
    (r sender receiver signer : Nat)
    (newSenderBalance newReceiverBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagTransfer ++
     uint64BE r ++ uint64BE sender ++ uint256BE newSenderBalance ++
     uint64BE receiver ++ uint256BE newReceiverBalance ++
     uint64BE signer)

/-- `mint` step-VM commit.  Mirrors Solidity's `_stepMint`. -/
def stepCommitMint
    (preCommit : ByteArray)
    (r to signer : Nat) (newToBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagMint ++
     uint64BE r ++ uint64BE to ++ uint256BE newToBalance ++
     uint64BE signer)

/-- `burn` step-VM commit.  Mirrors Solidity's `_stepBurn`. -/
def stepCommitBurn
    (preCommit : ByteArray)
    (r fromActor signer : Nat) (newFromBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagBurn ++
     uint64BE r ++ uint64BE fromActor ++ uint256BE newFromBalance ++
     uint64BE signer)

/-- `freezeResource` step-VM commit. -/
def stepCommitFreezeResource
    (preCommit : ByteArray) (r signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagFreezeResource ++
     uint64BE r ++ uint64BE signer)

/-- `replaceKey` step-VM commit.  The variable-length newKey is
    hashed to 32 bytes for the uniform fixed-length packing. -/
def stepCommitReplaceKey
    (preCommit : ByteArray)
    (actor signer : Nat) (newKey : ByteArray) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagReplaceKey ++
     uint64BE actor ++ LegalKernel.Runtime.hashBytes newKey ++
     uint64BE signer)

/-- `reward` step-VM commit. -/
def stepCommitReward
    (preCommit : ByteArray)
    (r to signer : Nat) (newToBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagReward ++
     uint64BE r ++ uint64BE to ++ uint256BE newToBalance ++
     uint64BE signer)

/-- `distributeOthers` step-VM commit head.  The bulk loop's
    per-recipient hash chain follows. -/
def stepCommitDistributeOthersHead
    (preCommit : ByteArray)
    (r excluded signer : Nat) (amount : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagDistributeOthers ++
     uint64BE r ++ uint64BE excluded ++ uint256BE amount ++
     uint64BE signer)

/-- `distributeOthers` bulk-step per-recipient hash chain step.
    Each recipient's balance update is folded into the running
    accumulator hash.

    **Cross-stack discipline.**  Solidity's `CellProof.keyB` is
    declared as `uint256` (matching the per-cell-tag map's
    second-key type at the L1 storage layer), so Solidity's
    `abi.encodePacked(acc, p.keyB, newBalance)` encodes 32 bytes
    for `keyB`.  We mirror this with `uint256BE` (not the
    intuitive `uint64BE`) for byte-for-byte agreement under the
    production keccak256 binding. -/
def stepCommitDistributeOthersFold
    (acc : ByteArray) (keyB : Nat) (newBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (acc ++ uint256BE keyB ++ uint256BE newBalance)

/-- `proportionalDilute` step-VM commit head. -/
def stepCommitProportionalDiluteHead
    (preCommit : ByteArray)
    (r excluded signer : Nat) (totalReward sumOthers : Nat) :
    ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagProportionalDilute ++
     uint64BE r ++ uint64BE excluded ++
     uint256BE totalReward ++ uint256BE sumOthers ++
     uint64BE signer)

/-- `proportionalDilute` bulk-step per-recipient hash chain step.
    Identical shape to `distributeOthers`'s fold: each
    recipient's balance update is folded into the running
    accumulator hash via `keccak256(acc || keyB (uint256) ||
    newBalance (uint256))`.

    **Cross-stack discipline.**  Mirrors Solidity's
    `keccak256(abi.encodePacked(acc, p.keyB, newBalance))` where
    `p.keyB` is `uint256` (32 bytes), not `uint64`.  We use
    `uint256BE` for byte-for-byte agreement. -/
def stepCommitProportionalDiluteFold
    (acc : ByteArray) (keyB : Nat) (newBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (acc ++ uint256BE keyB ++ uint256BE newBalance)

/-- `dispute` step-VM commit.  Variable-length actionFields
    hashed for fixed-length packing. -/
def stepCommitDispute
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagDispute ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `disputeWithdraw` step-VM commit. -/
def stepCommitDisputeWithdraw
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagDisputeWithdraw ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `verdict` step-VM commit. -/
def stepCommitVerdict
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagVerdict ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `rollback` step-VM commit. -/
def stepCommitRollback
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagRollback ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `registerIdentity` step-VM commit. -/
def stepCommitRegisterIdentity
    (preCommit : ByteArray)
    (actor signer : Nat) (pk : ByteArray) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagRegisterIdentity ++
     uint64BE actor ++ LegalKernel.Runtime.hashBytes pk ++
     uint64BE signer)

/-- `deposit` step-VM commit. -/
def stepCommitDeposit
    (preCommit : ByteArray)
    (r recipient signer : Nat)
    (newRecipientBalance depositId : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagDeposit ++
     uint64BE r ++ uint64BE recipient ++
     uint256BE newRecipientBalance ++ uint256BE depositId ++
     uint64BE signer)

/-- `withdraw` step-VM commit. -/
def stepCommitWithdraw
    (preCommit : ByteArray)
    (r sender signer : Nat) (newSenderBalance : Nat)
    (recipientL1 : ByteArray) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagWithdraw ++
     uint64BE r ++ uint64BE sender ++ uint256BE newSenderBalance ++
     LegalKernel.Runtime.hashBytes recipientL1 ++ uint64BE signer)

/-- `declareLocalPolicy` step-VM commit. -/
def stepCommitDeclareLocalPolicy
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagDeclareLocalPolicy ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `revokeLocalPolicy` step-VM commit. -/
def stepCommitRevokeLocalPolicy
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagRevokeLocalPolicy ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `faultProofChallenge` step-VM commit. -/
def stepCommitFaultProofChallenge
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagFaultProofChallenge ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `faultProofResolution` step-VM commit. -/
def stepCommitFaultProofResolution
    (preCommit : ByteArray)
    (actionFields : ByteArray) (signer : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagFaultProofResolution ++
     LegalKernel.Runtime.hashBytes actionFields ++
     uint64BE signer)

/-- `depositWithFee` step-VM commit (Workstream GP, action-index 19).
    Mirrors the structured per-field layout of the `_step19` Solidity
    handler when it is added: `keccak256(preCommit || TAG_DEPOSITWITHFEE
    || r || recipient || poolActor || newRecipientBalance ||
    newPoolBalance || depositId || signer)`.  The cell-proof bundle
    supplies the pre-state balances of `recipient` and `poolActor`;
    the new balances are pre + (userAmount, poolAmount) respectively.
    `depositId` is included as a uint256BE field to match the
    `consumed` map's key encoding. -/
def stepCommitDepositWithFee
    (preCommit : ByteArray)
    (r recipient poolActor signer : Nat)
    (newRecipientBalance newPoolBalance depositId : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagDepositWithFee ++
     uint64BE r ++ uint64BE recipient ++ uint64BE poolActor ++
     uint256BE newRecipientBalance ++ uint256BE newPoolBalance ++
     uint256BE depositId ++ uint64BE signer)

/-- `topUpActionBudget` step-VM commit (Workstream GP, action-index 20).
    `keccak256(preCommit || TAG_TOPUPACTIONBUDGET || gasResource ||
    signer || newSignerGasBalance || poolActor || newPoolGasBalance)`.
    The pre-state gas balances of `signer` and `poolActor` come from
    the cell-proof bundle; the new balances are signer - gasAmount
    and poolActor + gasAmount respectively.  `budgetIncrement` is an
    admission-layer effect (the kernel-state writes are gas balances
    only), so it does not appear in the L1 step-VM hash. -/
def stepCommitTopUpActionBudget
    (preCommit : ByteArray)
    (gasResource signer poolActor : Nat)
    (newSignerBalance newPoolBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagTopUpActionBudget ++
     uint64BE gasResource ++ uint64BE signer ++
     uint256BE newSignerBalance ++ uint64BE poolActor ++
     uint256BE newPoolBalance)

/-- `topUpActionBudgetFor` step-VM commit (Workstream GP, action-index
    21 — the GP.3.4 delegated top-up).
    `keccak256(preCommit || TAG_TOPUPACTIONBUDGETFOR || gasResource ||
    signer || newSignerGasBalance || poolActor || newPoolGasBalance)`.
    The pre-state gas balances of `signer` and `poolActor` come from
    the cell-proof bundle; the new balances are signer - gasAmount and
    poolActor + gasAmount respectively — the kernel-state effect is
    identical in shape to `stepCommitTopUpActionBudget` (debit the
    delegate, credit the pool).  The `recipient` and `budgetIncrement`
    parameters are admission-layer effects (the kernel-state writes are
    gas balances only): `recipient`'s epoch budget is credited at the
    admission gate, not by a step-VM cell write, so neither appears in
    the L1 step-VM hash.  The DISTINCT tag (`tagTopUpActionBudgetFor`
    ≠ `tagTopUpActionBudget`) is what separates this variant's commit
    from the self-funded `topUpActionBudget` even when the gas-transfer
    fields coincide. -/
def stepCommitTopUpActionBudgetFor
    (preCommit : ByteArray)
    (gasResource signer poolActor : Nat)
    (newSignerBalance newPoolBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagTopUpActionBudgetFor ++
     uint64BE gasResource ++ uint64BE signer ++
     uint256BE newSignerBalance ++ uint64BE poolActor ++
     uint256BE newPoolBalance)

/-- `claimBudgetRefund` step-VM commit (Workstream GP.9.1, action-index
    22 — the refund-on-exit mirror of `topUpActionBudget`).
    `keccak256(preCommit || TAG_CLAIMBUDGETREFUND || gasResource ||
    signer || newSignerGasBalance || poolActor || newPoolGasBalance)`.
    The pre-state gas balances of `signer` (the claimant) and
    `poolActor` come from the cell-proof bundle; the new balances are
    signer + refundAmount and poolActor - refundAmount respectively
    (`refundAmount = budgetUnits × weiPerBudgetUnit`) — the same commit
    SHAPE as `stepCommitTopUpActionBudget`, but the debit/credit
    direction is REVERSED (the pool is debited, the claimant credited),
    computed by the `stepVMHash` dispatcher.  `budgetUnits` /
    `weiPerBudgetUnit` are admission-layer effects (the kernel-state
    writes are gas balances only — the claimant's epoch-budget consume
    happens at the admission gate, not by a step-VM cell write), so
    neither appears in the L1 step-VM hash.  The DISTINCT tag
    (`tagClaimBudgetRefund` ≠ `tagTopUpActionBudget`) separates this
    variant's commit from the top-up variants even when the gas-transfer
    fields coincide. -/
def stepCommitClaimBudgetRefund
    (preCommit : ByteArray)
    (gasResource signer poolActor : Nat)
    (newSignerBalance newPoolBalance : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (preCommit ++ tagClaimBudgetRefund ++
     uint64BE gasResource ++ uint64BE signer ++
     uint256BE newSignerBalance ++ uint64BE poolActor ++
     uint256BE newPoolBalance)

/-! ## Determinism + structural theorems -/

/-- Per-variant determinism: equal inputs ⇒ equal output bytes.
    Mechanical via `rfl`. -/
theorem stepCommitTransfer_deterministic
    (preCommit₁ preCommit₂ : ByteArray)
    (r₁ r₂ s₁ s₂ rc₁ rc₂ sg₁ sg₂ : Nat)
    (nsb₁ nsb₂ nrb₁ nrb₂ : Nat)
    (h_pre : preCommit₁ = preCommit₂)
    (h_r : r₁ = r₂) (h_s : s₁ = s₂) (h_rc : rc₁ = rc₂) (h_sg : sg₁ = sg₂)
    (h_nsb : nsb₁ = nsb₂) (h_nrb : nrb₁ = nrb₂) :
    stepCommitTransfer preCommit₁ r₁ s₁ rc₁ sg₁ nsb₁ nrb₁ =
    stepCommitTransfer preCommit₂ r₂ s₂ rc₂ sg₂ nsb₂ nrb₂ := by
  rw [h_pre, h_r, h_s, h_rc, h_sg, h_nsb, h_nrb]

/-- `stepCommitTransfer` produces 32 bytes (the runtime
    `hashBytes` adaptor returns 32 bytes by `hashBytes_size`). -/
theorem stepCommitTransfer_size
    (preCommit : ByteArray) (r sender receiver signer : Nat)
    (nsb nrb : Nat) :
    (stepCommitTransfer preCommit r sender receiver signer nsb nrb).size = 32 := by
  unfold stepCommitTransfer
  exact LegalKernel.Runtime.hashBytes_size _

/-- `stepCommitMint` produces 32 bytes. -/
theorem stepCommitMint_size
    (preCommit : ByteArray) (r to signer ntb : Nat) :
    (stepCommitMint preCommit r to signer ntb).size = 32 := by
  unfold stepCommitMint
  exact LegalKernel.Runtime.hashBytes_size _

/-- `stepCommitBurn` produces 32 bytes. -/
theorem stepCommitBurn_size
    (preCommit : ByteArray) (r fr signer nfb : Nat) :
    (stepCommitBurn preCommit r fr signer nfb).size = 32 := by
  unfold stepCommitBurn
  exact LegalKernel.Runtime.hashBytes_size _

/-- `hashString` is injective under `CollisionFree hashBytes`:
    equal hashes imply equal UTF-8 encodings.  This is the
    forward direction of CR lifted across the `hashString =
    hashBytes ∘ toUTF8` composition.  Each per-variant tag
    constant (`tagTransfer`, `tagMint`, ...) is
    `hashString "<name>"`, so this lemma gives per-tag
    distinguishability under CR. -/
theorem hashString_inj_under_collision_free
    (h_cf : LegalKernel.Bridge.CollisionFree
              LegalKernel.Runtime.hashBytes)
    (s₁ s₂ : String) :
    hashString s₁ = hashString s₂ → s₁.toUTF8 = s₂.toUTF8 := by
  intro h_eq
  exact h_cf _ _ h_eq

end SolidityStepVMCommit
end FaultProof
end LegalKernel
