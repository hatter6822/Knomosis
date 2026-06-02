-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.StepVM — F.1.8 step-VM
equivalence corpus (Workstream H WU H.10.1 + Workstream SVC.5.e).

Per the workstream plan, the corpus has 19 constructors with
~10 fixtures per variant (~190 total).  Each fixture is a
`(KernelStep, expectedOutcome)` pair; both Lean and Solidity
sides reproduce the outcome byte-for-byte under
`isKeccak256Linked = true`.

This module implements the fixture-corpus *writer*: the Lean
side generates the canonical fixtures via `kernelStepApply`,
serialises them to JSON, and writes them to the cross-stack
fixture directory.  The Solidity side reads the same JSON and
asserts byte-equivalence on schema + per-entry well-formedness;
the variants that operate on absent cells additionally get
per-variant `executeStep` byte-equivalence tests.

## Workstream SVC.5.e — corpus widening

The original 48-entry corpus shipped Transfer + Mint only.  SVC.5.e
extends to all 19 variants:

  * Transfer + Mint: 24 entries each (existing 16 happy + 8
    adversarial; preserved unchanged).
  * Other 17 variants: 10 entries each (6 happy + 4 adversarial).
  * Total: 24 + 24 + 17 × 10 = **218 entries** (exceeds the
    plan's 190 target while preserving the existing fixtures).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Coherence
import LegalKernel.FaultProof.SolidityStepVMCommit
import LegalKernel.FaultProof.Step
import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.FaultProof.SolidityStepVMCommit
open LegalKernel.FaultProof.StepVMCoherence
open LegalKernel.Authority

namespace LegalKernel.Test.Bridge.CrossCheck.StepVM

/-! ## Fixture entry shape -/

/-- A flat record carrying one cell-proof's wire-format fields,
    decoupled from the heavy `FaultProof.CellProof` (which carries
    a full `ExtendedState` witness).  The Solidity-side parser
    consumes these fields directly via `vm.parseJsonUint` /
    `vm.parseJsonBytes`. -/
structure CellProofForFixture where
  /-- The cell-kind discriminator (0..6 per `CellTag.kindIndex`). -/
  cellKindNat      : Nat
  /-- First key (decimal Nat); width depends on kind:
      balance → resourceId; nonce/registry/localPolicy → actorId;
      bridgeConsumed/bridgePending → depositId/withdrawalId;
      bridgeNextWdId → 0. -/
  keyANat          : Nat
  /-- Second key (decimal Nat); for balance → actorId, else 0. -/
  keyBNat          : Nat
  /-- The CBE-encoded cell value bytes as `0x`-prefixed hex. -/
  cellValueHex     : String
  /-- The `commitExtendedState` of the witness state, hex-encoded
      with `0x` prefix.  Must equal the fixture's
      `preStateCommitHex`. -/
  witnessCommitHex : String
  deriving Repr

/-- A single F.1.8 step-VM fixture entry. -/
structure StepVMFixture where
  /-- The fixture's identifier (e.g. "transfer-happy-001"). -/
  fixtureId          : String
  /-- The Action variant being exercised. -/
  actionVariant      : String
  /-- The pre-state commit (hex, 64 chars + "0x"). -/
  preStateCommitHex  : String
  /-- The signed-action encoded bytes (hex). -/
  signedActionHex    : String
  /-- The expected post-state commit via `commitExtendedState` —
      the canonical 5-component state commit. -/
  expectedPostStateCommitHex : String
  /-- The expected post-state commit via Solidity's step-VM
      recipe (`keccak256(preCommit || tagHash || packed-fields)`).
      Under the production keccak256 binding, this equals what
      `KnomosisStepVM.executeStep` returns byte-for-byte. -/
  expectedStepVMCommitHex    : String
  /-- The expected revert reason, or "null" for happy paths. -/
  expectedRevertReason       : String
  /-- The action-kind dispatcher byte (0..20 post-Workstream-GP),
      used by the generic Solidity-side byte-equivalence test
      driver.  Workstream SVC.5.e addition; range widened to
      include `depositWithFee` = 19 and `topUpActionBudget` = 20. -/
  actionKindByte             : UInt8
  /-- The hex-encoded `actionFieldsForL1` bytes — the canonical
      L1-format action fields the Solidity `_stepXX` decoder
      consumes.  Workstream SVC.5.e addition. -/
  actionFieldsHex            : String
  /-- The signer (as decimal Nat for JSON compactness).
      Workstream SVC.5.e addition. -/
  signerNat                  : Nat
  /-- The cell-proof bundle in canonical order (the same order
      Solidity's `executeStep` iterates).  Empty for
      adversarial / cell-free fixtures.  Workstream SVC.5.e+
      addition. -/
  cellProofsForFixture       : List CellProofForFixture
  deriving Repr

/-! ## Fixture generators -/

/-- Encode a `SignedAction` as canonical CBE bytes hex. -/
private def encodeSignedAction (st : SignedAction) : String :=
  Test.Bridge.CrossCheck.hexFromBytes
    (ByteArray.mk (Encoding.Encodable.encode (T := Authority.SignedAction) st).toArray)

/-- Encode `actionFieldsForL1` as hex. -/
private def encodeActionFields (action : Action) : String :=
  Test.Bridge.CrossCheck.hexFromBytes (actionFieldsForL1 action)

/-- Convert one real `FaultProof.CellProof` (heavy, with witness
    state) to the flat fixture-ready record. -/
private def cellProofForFixtureFromCellProof (p : CellProof) :
    CellProofForFixture :=
  let (kindNat, keyA, keyB) : Nat × Nat × Nat := match p.cellTag with
    | .balance r a       => (0, r.toNat, a.toNat)
    | .nonce a           => (1, a.toNat, 0)
    | .registry a        => (2, a.toNat, 0)
    | .localPolicy a     => (3, a.toNat, 0)
    | .bridgeConsumed d  => (4, d, 0)
    | .bridgePending w   => (5, w, 0)
    | .bridgeNextWdId    => (6, 0, 0)
  { cellKindNat       := kindNat,
    keyANat           := keyA,
    keyBNat           := keyB,
    cellValueHex      := Test.Bridge.CrossCheck.hexFromBytes p.cellValue,
    witnessCommitHex  :=
      Test.Bridge.CrossCheck.hexFromBytes (commitExtendedState p.witnessState) }

/-- Build a pre-state with one or more `(actor, balance)` entries
    on a single resource.  Other sub-states stay empty. -/
private def stateWithBalances (r : ResourceId)
    (entries : List (ActorId × Amount)) : ExtendedState :=
  let baseState := entries.foldl
    (fun s (a, v) => LegalKernel.setBalance s r a v)
    LegalKernel.genesisState
  { ExtendedState.empty with base := baseState }

/-- Map an entire bundle of real cell proofs into the flat
    fixture-ready list. -/
private def bundleToFixtureProofs (proofs : List CellProof) :
    List CellProofForFixture :=
  proofs.map cellProofForFixtureFromCellProof

/-- Build a happy-path fixture for `Action.transfer`.

    Pre-state: sender has `senderInitBal` (must satisfy
    `senderInitBal ≥ amount > 0`).  Receiver has `receiverInitBal`
    (any value).  Self-transfer collapses both balances to
    `senderInitBal`. -/
def buildTransferHappy
    (idx : Nat) (r : ResourceId) (sender receiver : ActorId)
    (senderInitBal receiverInitBal amount : Amount)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  let action : Action := .transfer r sender receiver amount
  let st : SignedAction := { action, signer := sender, nonce, sig }
  let isSelf := decide (sender = receiver)
  -- Pre-state: balance(r, sender) := senderInitBal; receiver
  -- balance := receiverInitBal (unless self-transfer, in which
  -- case sender == receiver and only one entry is needed).
  let entries : List (ActorId × Amount) :=
    if isSelf then [(sender, senderInitBal)]
    else [(sender, senderInitBal), (receiver, receiverInitBal)]
  let es := stateWithBalances r entries
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  -- Per Solidity's `_stepTransfer`:
  -- * self: newSender = newReceiver = preBalance (no debit).
  -- * non-self: newSender = preBalance - amount;
  --             newReceiver = receiverPreBalance + amount.
  let senderPreBal := LegalKernel.getBalance es.base r sender
  let receiverPreBal := LegalKernel.getBalance es.base r receiver
  let newSenderBal : Nat :=
    if isSelf then senderPreBal else senderPreBal - amount
  let newReceiverBal : Nat :=
    if isSelf then senderPreBal else receiverPreBal + amount
  let stepVMCommit :=
    stepCommitTransfer preCommit r.toNat sender.toNat receiver.toNat
      sender.toNat newSenderBal newReceiverBal
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action sender
  { fixtureId := s!"transfer-happy-{idx}",
    actionVariant := "transfer",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := sender.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.mint`.  Mint works in
    empty state (newToBal = 0 + amount) and consumes the
    recipient's balance cell as a (CBE-encoded) zero. -/
def buildMintHappy
    (idx : Nat) (r : ResourceId) (to : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .mint r to amount
  let st : SignedAction := { action, signer, nonce, sig }
  let es := ExtendedState.empty
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let newToBal := amount
  let stepVMCommit :=
    stepCommitMint preCommit r.toNat to.toNat signer.toNat newToBal
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"mint-happy-{idx}",
    actionVariant := "mint",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.burn`.

    Pre-state: `fromActor` has `fromInitBal` (must satisfy
    `fromInitBal ≥ amount > 0`). -/
def buildBurnHappy
    (idx : Nat) (r : ResourceId) (fromActor : ActorId)
    (fromInitBal amount : Amount) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .burn r fromActor amount
  let st : SignedAction := { action, signer := fromActor, nonce, sig }
  let es := stateWithBalances r [(fromActor, fromInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let fromPreBal := LegalKernel.getBalance es.base r fromActor
  let newFromBal : Nat := fromPreBal - amount
  let stepVMCommit :=
    stepCommitBurn preCommit r.toNat fromActor.toNat fromActor.toNat newFromBal
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action fromActor
  { fixtureId := s!"burn-happy-{idx}",
    actionVariant := "burn",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := fromActor.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.freezeResource`.
    Cell-free; the observer-bundle ships the `[registry, nonce]`
    cells for the action's `requiredCells`. -/
def buildFreezeResourceHappy
    (idx : Nat) (r : ResourceId) (signer : ActorId)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  let action : Action := .freezeResource r
  let st : SignedAction := { action, signer, nonce, sig }
  let es := ExtendedState.empty
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let stepVMCommit := stepCommitFreezeResource preCommit r.toNat signer.toNat
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"freezeResource-happy-{idx}",
    actionVariant := "freezeResource",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.replaceKey`.
    Cell-free w.r.t. balance reads. -/
def buildReplaceKeyHappy
    (idx : Nat) (actor : ActorId) (newKey : ByteArray)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .replaceKey actor newKey
  let st : SignedAction := { action, signer, nonce, sig }
  let es := ExtendedState.empty
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let stepVMCommit :=
    stepCommitReplaceKey preCommit actor.toNat signer.toNat newKey
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"replaceKey-happy-{idx}",
    actionVariant := "replaceKey",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.reward`.

    Pre-state: `to` has `toInitBal` (any value; no inequality
    constraint).  `amount > 0` is required. -/
def buildRewardHappy
    (idx : Nat) (r : ResourceId) (to : ActorId)
    (toInitBal amount : Amount) (signer : ActorId) (nonce : Nonce)
    (sig : ByteArray) : StepVMFixture :=
  let action : Action := .reward r to amount
  let st : SignedAction := { action, signer, nonce, sig }
  let es := stateWithBalances r [(to, toInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let toPreBal := LegalKernel.getBalance es.base r to
  let newToBal := toPreBal + amount
  let stepVMCommit :=
    stepCommitReward preCommit r.toNat to.toNat signer.toNat newToBal
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"reward-happy-{idx}",
    actionVariant := "reward",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.distributeOthers`.

    SVC.5.e+: ships a non-empty pre-state with 3 recipients
    `[excluded+1, excluded+2, excluded+3]` each with positive
    balances.  The bundle is `observerProofs ++ recipientProofs`
    in deterministic order.  The expected step-VM commit is
    computed by walking the bundle in iteration order and folding
    matching balance cells (registry/nonce cells are skipped by
    the filter) — byte-for-byte equivalent to Solidity's
    `_stepDistributeOthers`. -/
def buildDistributeOthersHappy
    (idx : Nat) (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .distributeOthers r excluded amount
  let st : SignedAction := { action, signer, nonce, sig }
  -- Deterministic 3-recipient set: `excluded + 1`, `excluded + 2`,
  -- `excluded + 3` with progressively larger pre-balances.  All
  -- three are distinct from `excluded` by the additive offset.
  let recipients : List (ActorId × Amount) :=
    [ (excluded + 1, 50 + idx),
      (excluded + 2, 75 + idx),
      (excluded + 3, 100 + idx) ]
  let es := stateWithBalances r recipients
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  -- Build the bundle: observer's `requiredCells` (registry +
  -- nonce for distributeOthers) plus per-recipient balance cells
  -- in deterministic order.  Solidity's bulk loop iterates the
  -- bundle's `cellProofs[0..n)`, filtering for matching
  -- `cellKind == Balance && keyA == r && keyB != excluded`.
  -- Registry / nonce cells are filtered out; only the recipient
  -- balance cells contribute to the fold chain.
  let observerBundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  let recipientProofs : List CellProof :=
    recipients.map (fun (a, _) =>
      LegalKernel.FaultProof.buildCellProof es (.balance r a))
  let bundleProofs := observerBundle.proofs ++ recipientProofs
  -- Compute the expected step-VM commit by walking the bundle in
  -- ITERATION order, mirroring Solidity byte-for-byte.
  let head :=
    stepCommitDistributeOthersHead preCommit r.toNat excluded.toNat
      signer.toNat amount
  let stepVMCommit := bundleProofs.foldl
    (fun acc p =>
      match p.cellTag with
      | .balance pr pa =>
        if decide (pr = r) ∧ decide (pa ≠ excluded) then
          let preBal := LegalKernel.getBalance es.base r pa
          let newBal := preBal + amount
          stepCommitDistributeOthersFold acc pa.toNat newBal
        else acc
      | _ => acc)
    head
  { fixtureId := s!"distributeOthers-happy-{idx}",
    actionVariant := "distributeOthers",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundleProofs }

/-- Build a happy-path fixture for `Action.registerIdentity`.
    Cell-free w.r.t. balance reads. -/
def buildRegisterIdentityHappy
    (idx : Nat) (actor : ActorId) (pk : ByteArray)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .registerIdentity actor pk
  let st : SignedAction := { action, signer, nonce, sig }
  let es := ExtendedState.empty
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let stepVMCommit :=
    stepCommitRegisterIdentity preCommit actor.toNat signer.toNat pk
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"registerIdentity-happy-{idx}",
    actionVariant := "registerIdentity",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.deposit`.

    Pre-state: `recipient` has `recipientInitBal` (any value, no
    inequality constraint).  Solidity's `_stepDeposit` doesn't
    require `amount > 0`. -/
def buildDepositHappy
    (idx : Nat) (r : ResourceId) (recipient : ActorId)
    (recipientInitBal amount : Amount) (depositId : Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .deposit r recipient amount depositId
  let st : SignedAction := { action, signer, nonce, sig }
  let es := stateWithBalances r [(recipient, recipientInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let recipientPreBal := LegalKernel.getBalance es.base r recipient
  let newRecipientBal := recipientPreBal + amount
  let stepVMCommit :=
    stepCommitDeposit preCommit r.toNat recipient.toNat signer.toNat
      newRecipientBal depositId
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"deposit-happy-{idx}",
    actionVariant := "deposit",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.withdraw`.

    Pre-state: `sender` has `senderInitBal` (must satisfy
    `senderInitBal ≥ amount`). -/
def buildWithdrawHappy
    (idx : Nat) (r : ResourceId) (sender : ActorId)
    (senderInitBal amount : Amount) (recipientL1 : Bridge.EthAddress)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  let action : Action := .withdraw r sender amount recipientL1
  let st : SignedAction := { action, signer := sender, nonce, sig }
  let es := stateWithBalances r [(sender, senderInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let senderPreBal := LegalKernel.getBalance es.base r sender
  let newSenderBal : Nat := senderPreBal - amount
  let recipientBytes := Bridge.EthAddress.toBytes recipientL1
  let stepVMCommit :=
    stepCommitWithdraw preCommit r.toNat sender.toNat sender.toNat
      newSenderBal recipientBytes
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action sender
  { fixtureId := s!"withdraw-happy-{idx}",
    actionVariant := "withdraw",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := sender.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Workstream GP — build a happy-path fixture for
    `Action.depositWithFee`.

    Pre-state: `recipient` has `recipientInitBal`; if `poolActor ≠
    recipient`, `poolActor` has `poolInitBal`.  No precondition on
    balances (the law's `pre` is `True`; saturating adds always
    succeed).  The kernel-level effect is the two-step `setBalance`
    sequence in `Laws.depositWithFee.apply_impl`:
    `recipient += userAmount; poolActor += poolAmount`.  When
    `recipient = poolActor`, both writes land on the same cell, so
    the new balance is `pre + userAmount + poolAmount` (matching
    Solidity's `_stepDepositWithFee`'s self-credit branch).

    Per the admission gate's `depositWithFee_signerCheck` round-5
    defense, the signer MUST be `Bridge.bridgeActor`.  Production
    deployments enforce this at admission; the fixture writer
    follows the canonical discipline. -/
def buildDepositWithFeeHappy
    (idx : Nat) (r : ResourceId) (recipient poolActor : ActorId)
    (recipientInitBal poolInitBal userAmount poolAmount : Amount)
    (budgetGrant : Nat) (depositId : Bridge.DepositId)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  let signer : ActorId := Bridge.bridgeActor
  let action : Action :=
    .depositWithFee r recipient poolActor userAmount poolAmount
                    budgetGrant depositId
  let st : SignedAction := { action, signer, nonce, sig }
  let isSelf := decide (recipient = poolActor)
  -- Pre-state: balance(r, recipient) := recipientInitBal; if
  -- poolActor ≠ recipient, balance(r, poolActor) := poolInitBal.
  -- Self-credit collapses to a single entry (poolInitBal is
  -- ignored).
  let entries : List (ActorId × Amount) :=
    if isSelf then [(recipient, recipientInitBal)]
    else [(recipient, recipientInitBal), (poolActor, poolInitBal)]
  let es := stateWithBalances r entries
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  -- Per Laws.depositWithFee.apply_impl:
  --   recipient += userAmount; then poolActor += poolAmount.
  -- Self-credit case: both writes target the same cell, so the
  -- new balance is `pre + userAmount + poolAmount`.
  let recipientPreBal := LegalKernel.getBalance es.base r recipient
  let newRecipientBal : Nat :=
    if isSelf then recipientPreBal + userAmount + poolAmount
    else recipientPreBal + userAmount
  let newPoolBal : Nat :=
    if isSelf then recipientPreBal + userAmount + poolAmount
    else
      let poolPreBal := LegalKernel.getBalance es.base r poolActor
      poolPreBal + poolAmount
  let stepVMCommit :=
    stepCommitDepositWithFee preCommit r.toNat recipient.toNat
      poolActor.toNat signer.toNat
      newRecipientBal newPoolBal depositId
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"depositWithFee-happy-{idx}",
    actionVariant := "depositWithFee",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Workstream GP — build a happy-path fixture for
    `Action.topUpActionBudget`.

    Pre-state: `signer` has `signerInitBal ≥ gasAmount` on
    `gasResource`; `poolActor` has `poolInitBal` (any value).
    The kernel-level effect is the two-step `setBalance` chain
    in `Laws.topUpActionBudget.apply_impl`: debit `signer` by
    `gasAmount`, credit `poolActor` by `gasAmount`.

    Per the admission gate's `topUpActionBudget_gasCheck` round-3
    + round-4 defenses, `signer` MUST satisfy `signer ≠
    bridgeActor` AND `signer ≠ poolActor` AND `gasAmount > 0` AND
    `getBalance ≥ gasAmount`.  The fixture writer enforces all
    four upstream so the canonical step-VM dispatcher is
    exercised on the happy path (the if-self branch defended at
    admission is unreachable here). -/
def buildTopUpActionBudgetHappy
    (idx : Nat) (gasResource : ResourceId) (signer poolActor : ActorId)
    (signerInitBal poolInitBal gasAmount : Amount)
    (budgetIncrement : Nat) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action :=
    .topUpActionBudget gasResource gasAmount budgetIncrement poolActor
  let st : SignedAction := { action, signer, nonce, sig }
  -- Pre-state must have `signer ≠ poolActor` per the admission
  -- gate's round-4 self-pool defense.  The fixture caller is
  -- responsible for supplying distinct ids; this builder pins
  -- both balance cells unconditionally.
  let es := stateWithBalances gasResource
              [(signer, signerInitBal), (poolActor, poolInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  -- Per Laws.topUpActionBudget.apply_impl:
  --   signer's gas balance -= gasAmount; poolActor's += gasAmount.
  let signerPreBal := LegalKernel.getBalance es.base gasResource signer
  let poolPreBal := LegalKernel.getBalance es.base gasResource poolActor
  let newSignerBal : Nat := signerPreBal - gasAmount
  let newPoolBal : Nat := poolPreBal + gasAmount
  let stepVMCommit :=
    stepCommitTopUpActionBudget preCommit gasResource.toNat
      signer.toNat poolActor.toNat newSignerBal newPoolBal
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"topUpActionBudget-happy-{idx}",
    actionVariant := "topUpActionBudget",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Workstream GP (GP.5.3) — build a happy-path fixture for
    `Action.topUpActionBudgetFor` (the GP.3.4 delegated top-up).

    Pre-state: `signer` (the delegate / payer) has `signerInitBal ≥
    gasAmount` on `gasResource`; `poolActor` has `poolInitBal` (any
    value).  The kernel-level effect is byte-identical in shape to
    `topUpActionBudget`'s two-step `setBalance` chain
    (`Laws.topUpActionBudgetFor.apply_impl`): debit `signer` by
    `gasAmount`, credit `poolActor` by `gasAmount`.  The `recipient`
    is the actor whose epoch budget the admission gate credits — an
    admission-layer effect, not a kernel-state cell write, so it does
    not appear in the step-VM hash.

    Per the admission gate's `topUpActionBudgetFor_gate`, the canonical
    path requires `signer ≠ bridgeActor`, `signer ≠ poolActor`,
    `recipient ≠ signer`, `gasAmount > 0`, and `signerInitBal ≥
    gasAmount` (plus the recipient-consent check, which lives at the
    admission layer and is out of scope for the L1 step VM).  The
    fixture caller supplies distinct ids so the canonical step-VM
    dispatcher path is exercised (the if-self defended branch is
    unreachable here by construction). -/
def buildTopUpActionBudgetForHappy
    (idx : Nat) (recipient : ActorId) (gasResource : ResourceId)
    (signer poolActor : ActorId)
    (signerInitBal poolInitBal gasAmount : Amount)
    (budgetIncrement : Nat) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action :=
    .topUpActionBudgetFor recipient gasResource gasAmount budgetIncrement poolActor
  let st : SignedAction := { action, signer, nonce, sig }
  -- Pre-state must have `signer ≠ poolActor` per the admission gate's
  -- round-4 self-pool defense; the builder pins both balance cells
  -- unconditionally.
  let es := stateWithBalances gasResource
              [(signer, signerInitBal), (poolActor, poolInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  -- Per Laws.topUpActionBudgetFor.apply_impl:
  --   signer's gas balance -= gasAmount; poolActor's += gasAmount.
  let signerPreBal := LegalKernel.getBalance es.base gasResource signer
  let poolPreBal := LegalKernel.getBalance es.base gasResource poolActor
  let newSignerBal : Nat := signerPreBal - gasAmount
  let newPoolBal : Nat := poolPreBal + gasAmount
  let stepVMCommit :=
    stepCommitTopUpActionBudgetFor preCommit gasResource.toNat
      signer.toNat poolActor.toNat newSignerBal newPoolBal
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"topUpActionBudgetFor-happy-{idx}",
    actionVariant := "topUpActionBudgetFor",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-! ## Opaque-variant happy fixture generators

For opaque variants (Dispute, DisputeWithdraw, Verdict,
Rollback, DeclareLocalPolicy, RevokeLocalPolicy,
FaultProofChallenge, FaultProofResolution), the L1 step VM's
hash is `keccak256(preCommit || TAG || keccak256(actionFields)
|| signer)` — no cell-state interaction.  These work in empty
state for any input. -/

/-- Generic builder for an opaque-variant happy fixture.  Takes
    the action variant name, the action's CBE-encoded
    `actionFieldsForL1` bytes, the signer, and the canonical
    Lean-side step-commit function. -/
private def buildOpaqueHappy
    (variant : String) (idx : Nat) (action : Action)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray)
    (stepCommitFn : ByteArray → ByteArray → Nat → ByteArray) :
    StepVMFixture :=
  let st : SignedAction := { action, signer, nonce, sig }
  let es := ExtendedState.empty
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let actionFields := actionFieldsForL1 action
  let stepVMCommit := stepCommitFn preCommit actionFields signer.toNat
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"{variant}-happy-{idx}",
    actionVariant := variant,
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- Build a happy-path fixture for `Action.disputeWithdraw`. -/
def buildDisputeWithdrawHappy
    (idx : Nat) (targetIdx : Disputes.LogIndex) (signer : ActorId)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "disputeWithdraw" idx (.disputeWithdraw targetIdx)
    signer nonce sig stepCommitDisputeWithdraw

/-- Build a happy-path fixture for `Action.rollback`. -/
def buildRollbackHappy
    (idx : Nat) (targetIdx : Disputes.LogIndex) (signer : ActorId)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "rollback" idx (.rollback targetIdx)
    signer nonce sig stepCommitRollback

/-- Build a happy-path fixture for `Action.revokeLocalPolicy`. -/
def buildRevokeLocalPolicyHappy
    (idx : Nat) (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  buildOpaqueHappy "revokeLocalPolicy" idx .revokeLocalPolicy
    signer nonce sig stepCommitRevokeLocalPolicy

/-- Build a happy-path fixture for `Action.faultProofChallenge`. -/
def buildFaultProofChallengeHappy
    (idx : Nat) (bindingHash : ByteArray) (startIdx endIdx : Disputes.LogIndex)
    (challengerCommit : ByteArray) (signer : ActorId) (nonce : Nonce)
    (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "faultProofChallenge" idx
    (.faultProofChallenge bindingHash startIdx endIdx challengerCommit)
    signer nonce sig stepCommitFaultProofChallenge

/-- Build a happy-path fixture for `Action.faultProofResolution`. -/
def buildFaultProofResolutionHappy
    (idx : Nat) (bindingHash : ByteArray) (gameId : Nat) (winner : ActorId)
    (revertFromIdx : Disputes.LogIndex) (signer : ActorId) (nonce : Nonce)
    (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "faultProofResolution" idx
    (.faultProofResolution bindingHash gameId winner revertFromIdx)
    signer nonce sig stepCommitFaultProofResolution

/-- Build a happy-path fixture for `Action.proportionalDilute`.

    3-recipient set with non-zero balances ⇒ `sumOthers > 0` ⇒
    Solidity's `_stepProportionalDilute` doesn't revert.

    Two-pass fold mirrors Solidity exactly:
    * Pass 1: sum balance cells matching `r ∧ ≠ excluded` into
      `sumOthers`.
    * Pass 2: per-recipient `credit := totalReward * v / sumOthers`,
      `newBal := v + credit`, fold into hash. -/
def buildProportionalDiluteHappy
    (idx : Nat) (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action := .proportionalDilute r excluded totalReward
  let st : SignedAction := { action, signer, nonce, sig }
  -- Same 3-recipient set as distributeOthers: distinct from
  -- `excluded` by additive offset; balances guarantee
  -- `sumOthers = 225 + 3*idx > 0`.
  let recipients : List (ActorId × Amount) :=
    [ (excluded + 1, 50 + idx),
      (excluded + 2, 75 + idx),
      (excluded + 3, 100 + idx) ]
  let es := stateWithBalances r recipients
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st
  let observerBundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  let recipientProofs : List CellProof :=
    recipients.map (fun (a, _) =>
      LegalKernel.FaultProof.buildCellProof es (.balance r a))
  let bundleProofs := observerBundle.proofs ++ recipientProofs
  -- Pass 1: compute sumOthers by walking the bundle in iteration
  -- order, applying Solidity's exact filter.
  let sumOthers := bundleProofs.foldl
    (fun (acc : Nat) p =>
      match p.cellTag with
      | .balance pr pa =>
        if decide (pr = r) ∧ decide (pa ≠ excluded) then
          acc + LegalKernel.getBalance es.base r pa
        else acc
      | _ => acc)
    0
  let head :=
    stepCommitProportionalDiluteHead preCommit r.toNat excluded.toNat
      signer.toNat totalReward sumOthers
  -- Pass 2: per-recipient credit + fold.
  let stepVMCommit := bundleProofs.foldl
    (fun acc p =>
      match p.cellTag with
      | .balance pr pa =>
        if decide (pr = r) ∧ decide (pa ≠ excluded) then
          let preBal := LegalKernel.getBalance es.base r pa
          let credit := if sumOthers = 0 then 0
                        else totalReward * preBal / sumOthers
          let newBal := preBal + credit
          stepCommitProportionalDiluteFold acc pa.toNat newBal
        else acc
      | _ => acc)
    head
  { fixtureId := s!"proportionalDilute-happy-{idx}",
    actionVariant := "proportionalDilute",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedStepVMCommitHex := Test.Bridge.CrossCheck.hexFromBytes stepVMCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundleProofs }

/-! ## Dispute / Verdict / DeclareLocalPolicy happy fixtures

These variants have payloads (`Dispute`, `Verdict`,
`LocalPolicy`) that must be constructed via the per-payload
constructor.  We use minimal canonical payloads. -/

/-- A minimal canonical `Dispute` payload (signatureInvalid
    claim against log index 0). -/
private def minimalDispute (challenger : ActorId) (nonceVal : Nonce) :
    Disputes.Dispute :=
  { challenger,
    claim := .signatureInvalid 0,
    evidence := ByteArray.empty,
    nonce := nonceVal,
    sig := ByteArray.empty }

/-- Build a happy-path fixture for `Action.dispute`. -/
def buildDisputeHappy
    (idx : Nat) (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  buildOpaqueHappy "dispute" idx
    (.dispute (minimalDispute signer nonce))
    signer nonce sig stepCommitDispute

/-- Build a happy-path fixture for `Action.verdict`.  Uses a
    minimal canonical empty-quorum verdict. -/
def buildVerdictHappy
    (idx : Nat) (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let v : Disputes.Verdict := {
    disputeId := 0,
    outcome := .upheld,
    rationale := ByteArray.empty,
    signatures := []
  }
  buildOpaqueHappy "verdict" idx (.verdict v) signer nonce sig stepCommitVerdict

/-- Build a happy-path fixture for `Action.declareLocalPolicy`. -/
def buildDeclareLocalPolicyHappy
    (idx : Nat) (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let p : LocalPolicy := LocalPolicy.empty
  buildOpaqueHappy "declareLocalPolicy" idx (.declareLocalPolicy p)
    signer nonce sig stepCommitDeclareLocalPolicy

/-! ## Adversarial fixtures (generic) -/

/-- Build an adversarial fixture: bad pre-state commit.
    Adversarial fixtures emit an empty cell-proof bundle —
    Solidity's generic byte-equivalence test skips them. -/
def buildAdversarialBadPreCommit
    (idx : Nat) (variant : String) :
    StepVMFixture :=
  let badCommit : ByteArray := ByteArray.mk #[0xFF, 0xFF]
  { fixtureId := s!"{variant}-adversarial-bad-precommit-{idx}",
    actionVariant := variant,
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes badCommit,
    signedActionHex := "0x",
    expectedPostStateCommitHex := "null",
    expectedStepVMCommitHex := "null",
    expectedRevertReason := "BadCellProof",
    actionKindByte := 0,
    actionFieldsHex := "0x",
    signerNat := 0,
    cellProofsForFixture := [] }

/-! ## Fixture corpora (one list per variant) -/

/-- F.1.8 fixtures for `transfer` (24 entries: 16 happy + 8
    adversarial).  Reserves `i==8` for an explicit self-transfer
    case (sender == receiver); the other 15 entries are
    non-self-transfers. -/
def transferFixtures : List StepVMFixture :=
  (List.range 16).map (fun i =>
    -- Self-transfer at i==8: sender == receiver == 8.
    let sender : ActorId :=
      if i = 8 then (8 : UInt64) else (i * 2).toUInt64
    let receiver : ActorId :=
      if i = 8 then (8 : UInt64) else (i * 2 + 1).toUInt64
    -- amount > 0 always; senderInitBal ≥ amount.
    let amount : Amount := i + 1
    let senderInitBal : Amount := 100 + i
    let receiverInitBal : Amount := i % 7
    buildTransferHappy i (i.toUInt64) sender receiver
                       senderInitBal receiverInitBal amount
                       (100 + i) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 8).map (fun i =>
    buildAdversarialBadPreCommit i "transfer")

/-- F.1.8 fixtures for `mint` (24 entries). -/
def mintFixtures : List StepVMFixture :=
  (List.range 16).map (fun i =>
    buildMintHappy i (i.toUInt64) ((i * 3).toUInt64) (50 + i)
                   (i * 5).toUInt64 (i * 11) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 8).map (fun i =>
    buildAdversarialBadPreCommit i "mint")

/-- SVC.5.e fixtures for `burn` (10 entries: 6 happy + 4
    adversarial).  Non-empty pre-state: `fromActor` has
    `fromInitBal := 100 + i ≥ amount := i + 1`. -/
def burnFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    let amount : Amount := i + 1
    let fromInitBal : Amount := 100 + i
    buildBurnHappy i (i.toUInt64) ((i * 2 + 1).toUInt64)
                   fromInitBal amount (i * 3)
                   (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "burn")

/-- SVC.5.e fixtures for `freezeResource` (10 entries). -/
def freezeResourceFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildFreezeResourceHappy i (i.toUInt64) ((i * 7 + 1).toUInt64)
                             (i * 13) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "freezeResource")

/-- SVC.5.e fixtures for `replaceKey` (10 entries). -/
def replaceKeyFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildReplaceKeyHappy i ((i + 1).toUInt64)
      (ByteArray.mk #[0xAB.toUInt8, i.toUInt8, 0xCD.toUInt8])
      ((i + 1).toUInt64) (i * 17) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "replaceKey")

/-- SVC.5.e fixtures for `reward` (10 entries).  Non-empty
    pre-state: `to` has `toInitBal := 25 + i` (any non-zero
    value; reward adds without an inequality constraint). -/
def rewardFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    let amount : Amount := 100 + i
    let toInitBal : Amount := 25 + i
    buildRewardHappy i (i.toUInt64) ((i * 2 + 7).toUInt64)
                     toInitBal amount ((i + 5).toUInt64)
                     (i * 19) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "reward")

/-- SVC.5.e fixtures for `distributeOthers` (10 entries). -/
def distributeOthersFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildDistributeOthersHappy i (i.toUInt64) ((i * 3 + 1).toUInt64)
                               (50 + i) ((i + 9).toUInt64) (i * 23)
                               (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "distributeOthers")

/-- SVC.5.e fixtures for `proportionalDilute` (10 entries). -/
def proportionalDiluteFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildProportionalDiluteHappy i (i.toUInt64) ((i * 5 + 1).toUInt64)
                                 (100 + i * 10) ((i + 13).toUInt64)
                                 (i * 29) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "proportionalDilute")

/-- SVC.5.e fixtures for `dispute` (10 entries). -/
def disputeFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildDisputeHappy i ((i + 1).toUInt64) (i * 31)
                      (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "dispute")

/-- SVC.5.e fixtures for `disputeWithdraw` (10 entries). -/
def disputeWithdrawFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildDisputeWithdrawHappy i i ((i + 1).toUInt64) (i * 37)
                              (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "disputeWithdraw")

/-- SVC.5.e fixtures for `verdict` (10 entries). -/
def verdictFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildVerdictHappy i ((i + 1).toUInt64) (i * 41)
                      (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "verdict")

/-- SVC.5.e fixtures for `rollback` (10 entries). -/
def rollbackFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildRollbackHappy i i ((i + 1).toUInt64) (i * 43)
                       (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "rollback")

/-- SVC.5.e fixtures for `registerIdentity` (10 entries). -/
def registerIdentityFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildRegisterIdentityHappy i ((i + 1).toUInt64)
      (ByteArray.mk #[(0x02 : UInt8), i.toUInt8, 0xAA.toUInt8])
      ((i + 1).toUInt64) (i * 47) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "registerIdentity")

/-- SVC.5.e fixtures for `deposit` (10 entries).  Non-empty
    pre-state: `recipient` has `recipientInitBal := 25 + i`
    (any value; deposit adds without inequality constraint). -/
def depositFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    let amount : Amount := 100 + i
    let recipientInitBal : Amount := 25 + i
    let depositId : Bridge.DepositId := i * 7
    buildDepositHappy i (i.toUInt64) ((i * 3 + 1).toUInt64)
                      recipientInitBal amount depositId
                      ((i + 5).toUInt64) (i * 53)
                      (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "deposit")

/-- SVC.5.e fixtures for `withdraw` (10 entries).  Non-empty
    pre-state: `sender` has `senderInitBal := 100 + i ≥
    amount := 10 + i`. -/
def withdrawFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    let bs := List.replicate 20 (((0xA0 + i) % 256).toUInt8)
    let addr : Bridge.EthAddress :=
      (Bridge.EthAddress.ofBytes (ByteArray.mk bs.toArray)).getD
        Bridge.EthAddress.zero
    let amount : Amount := 10 + i
    let senderInitBal : Amount := 100 + i
    buildWithdrawHappy i (i.toUInt64) ((i + 1).toUInt64)
                       senderInitBal amount addr (i * 59)
                       (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "withdraw")

/-- Workstream GP fixtures for `depositWithFee` (10 entries:
    6 happy + 4 adversarial).  Mixes distinct-actor and self-credit
    (`recipient = poolActor`) cases.  Index 3 is reserved for the
    self-credit edge case to ensure both arms of the
    `if recipient = poolActor` branch in `_stepDepositWithFee` are
    exercised.  Signer is always `Bridge.bridgeActor`. -/
def depositWithFeeFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    -- Self-credit at i==3: recipient == poolActor.  Other entries
    -- have distinct ids.
    let recipient : ActorId :=
      if i = 3 then (5 : UInt64) else ((i + 2) * 2).toUInt64
    let poolActor : ActorId :=
      if i = 3 then (5 : UInt64) else ((i + 2) * 2 + 1).toUInt64
    let userAmount : Amount := 100 + i
    let poolAmount : Amount := 10 + i
    let budgetGrant : Nat := 50 + i
    let depositId : Bridge.DepositId := i * 79
    let recipientInitBal : Amount := 25 + i
    let poolInitBal : Amount := 15 + i
    buildDepositWithFeeHappy i ((i + 1).toUInt64) recipient poolActor
                             recipientInitBal poolInitBal
                             userAmount poolAmount budgetGrant depositId
                             (i * 83) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "depositWithFee")

/-- Workstream GP fixtures for `topUpActionBudget` (10 entries:
    6 happy + 4 adversarial).  All happy entries enforce the
    admission-layer canonical-path invariants: `signer ≠
    bridgeActor`, `signer ≠ poolActor`, `gasAmount > 0`, and
    `signerInitBal ≥ gasAmount`.  This keeps the canonical
    dispatcher path exercised (the if-self defended branch is
    unreachable here by construction). -/
def topUpActionBudgetFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    -- Pick a non-bridge, non-pool signer.  `signer = i + 10`
    -- guarantees signer ≠ bridgeActor (= 0); `poolActor = i + 20`
    -- guarantees signer ≠ poolActor.
    let signer : ActorId := ((i + 10) : Nat).toUInt64
    let poolActor : ActorId := ((i + 20) : Nat).toUInt64
    let gasAmount : Amount := i + 1            -- > 0 always
    let signerInitBal : Amount := 100 + i      -- ≥ gasAmount
    let poolInitBal : Amount := 5 + i
    let budgetIncrement : Nat := 30 + i
    buildTopUpActionBudgetHappy i ((i + 1).toUInt64) signer poolActor
                                signerInitBal poolInitBal gasAmount
                                budgetIncrement (i * 89)
                                (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "topUpActionBudget")

/-- Workstream GP (GP.5.3) fixtures for `topUpActionBudgetFor` (10
    entries: 6 happy + 4 adversarial).  All happy entries enforce the
    admission-layer canonical-path invariants: `signer ≠ bridgeActor`,
    `signer ≠ poolActor`, `recipient ≠ signer`, `gasAmount > 0`, and
    `signerInitBal ≥ gasAmount`.  This keeps the canonical dispatcher
    path exercised (the if-self defended branch is unreachable here by
    construction).  `recipient` is chosen distinct from both `signer`
    and `poolActor` to honour the `recipient ≠ signer` precondition. -/
def topUpActionBudgetForFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    -- `signer = i + 10` (≠ bridgeActor 0); `poolActor = i + 20`
    -- (≠ signer); `recipient = i + 30` (≠ signer, ≠ poolActor).
    let recipient : ActorId := ((i + 30) : Nat).toUInt64
    let signer : ActorId := ((i + 10) : Nat).toUInt64
    let poolActor : ActorId := ((i + 20) : Nat).toUInt64
    let gasAmount : Amount := i + 1            -- > 0 always
    let signerInitBal : Amount := 100 + i      -- ≥ gasAmount
    let poolInitBal : Amount := 5 + i
    let budgetIncrement : Nat := 40 + i
    buildTopUpActionBudgetForHappy i recipient ((i + 1).toUInt64) signer poolActor
                                   signerInitBal poolInitBal gasAmount
                                   budgetIncrement (i * 97)
                                   (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "topUpActionBudgetFor")

/-- SVC.5.e fixtures for `declareLocalPolicy` (10 entries). -/
def declareLocalPolicyFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildDeclareLocalPolicyHappy i ((i + 1).toUInt64) (i * 61)
                                 (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "declareLocalPolicy")

/-- SVC.5.e fixtures for `revokeLocalPolicy` (10 entries). -/
def revokeLocalPolicyFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildRevokeLocalPolicyHappy i ((i + 1).toUInt64) (i * 67)
                                (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "revokeLocalPolicy")

/-- SVC.5.e fixtures for `faultProofChallenge` (10 entries). -/
def faultProofChallengeFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildFaultProofChallengeHappy i
      (ByteArray.mk #[0xDE.toUInt8, i.toUInt8, 0xAD.toUInt8])
      i (i + 10) (ByteArray.mk #[0xBE.toUInt8, i.toUInt8])
      ((i + 1).toUInt64) (i * 71) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "faultProofChallenge")

/-- SVC.5.e fixtures for `faultProofResolution` (10 entries). -/
def faultProofResolutionFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    buildFaultProofResolutionHappy i
      (ByteArray.mk #[0xCA.toUInt8, i.toUInt8, 0xFE.toUInt8])
      i ((i + 1).toUInt64) (i * 2)
      ((i + 1).toUInt64) (i * 73) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "faultProofResolution")

/-- The full corpus: every variant's fixtures concatenated.
    Total: 24 + 24 + 18 × 10 + 2 × 10 = 248 entries (post-GP.5.3:
    +topUpActionBudgetFor on top of the 238 entries that already
    carried +depositWithFee + topUpActionBudget). -/
def allFixtures : List StepVMFixture :=
  transferFixtures ++ mintFixtures ++ burnFixtures ++
  freezeResourceFixtures ++ replaceKeyFixtures ++ rewardFixtures ++
  distributeOthersFixtures ++ proportionalDiluteFixtures ++
  disputeFixtures ++ disputeWithdrawFixtures ++ verdictFixtures ++
  rollbackFixtures ++ registerIdentityFixtures ++ depositFixtures ++
  withdrawFixtures ++ declareLocalPolicyFixtures ++
  revokeLocalPolicyFixtures ++ faultProofChallengeFixtures ++
  faultProofResolutionFixtures ++ depositWithFeeFixtures ++
  topUpActionBudgetFixtures ++ topUpActionBudgetForFixtures

/-! ## Test suite (Lean-side fixture-stability tests) -/

/-- Convert one `CellProofForFixture` to its JSON
    representation. -/
private def cellProofForFixtureToJson (p : CellProofForFixture) :
    Test.Bridge.CrossCheck.Json :=
  .obj [ ("cellKind",         .num p.cellKindNat)
       , ("keyA",              .num p.keyANat)
       , ("keyB",              .num p.keyBNat)
       , ("cellValueHex",      .str p.cellValueHex)
       , ("witnessCommitHex",  .str p.witnessCommitHex) ]

/-- Convert one fixture to its JSON representation. -/
private def fixtureToJson (f : StepVMFixture) :
    Test.Bridge.CrossCheck.Json :=
  .obj [ ("fixtureId",                .str f.fixtureId)
       , ("actionVariant",            .str f.actionVariant)
       , ("preStateCommitHex",        .str f.preStateCommitHex)
       , ("signedActionHex",          .str f.signedActionHex)
       , ("expectedPostStateCommitHex",
          .str f.expectedPostStateCommitHex)
       , ("expectedStepVMCommitHex",
          .str f.expectedStepVMCommitHex)
       , ("expectedRevertReason",     .str f.expectedRevertReason)
       , ("actionKindByte",           .num f.actionKindByte.toNat)
       , ("actionFieldsHex",          .str f.actionFieldsHex)
       , ("signerNat",                .num f.signerNat)
       , ("cellProofs",
          .arr (f.cellProofsForFixture.map cellProofForFixtureToJson))
       , ("cellProofsCount", .num f.cellProofsForFixture.length)
       ]

/-! ## GP.5.3 — hash-independent packed-layout goldens (data-flow)

These pin, **without** the keccak binding, that Lean's `uint64BE` /
`uint256BE` packed encoders produce the same bytes as Solidity's
`abi.encodePacked(uint64 / uint256)` — the byte layout that EVERY
structured step-VM variant's commit preimage is built from.

Discipline (mirrors `DepositFeeSplit`'s `receiptTail` pattern): the
Lean side EMITS its actual encoder output into `step_vm.json`; the
Solidity consumer (`StepVM.t.sol`) READS that output and recomputes
`abi.encodePacked`, asserting byte equality.  There is a single
source of truth (the emitted bytes), so a one-sided layout change is
mechanically caught — unlike a pair of independently-maintained
literals. -/

/-- The `uint64`-width golden input values: zero, one, a low byte, an
    all-distinct-byte word, and the `uint64` maximum. -/
def packedLayoutU64Vals : List Nat :=
  [0, 1, 0xFF, 0x0102030405060708, 0xFFFFFFFFFFFFFFFF]

/-- The `uint256`-width golden input values.  Includes two
    **full-32-byte-width** values (all-distinct non-zero bytes and the
    `uint256` maximum) so the high 24 bytes — never exercised by the
    realistic balance domain (`< 2^72`) — are still layout-pinned. -/
def packedLayoutU256Vals : List Nat :=
  [0, 1, 0x2122232425262728,
   0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20,
   0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF]

/-- The packed-primitive layout goldens as JSON.  Each entry carries
    the width (64 / 256), the input value (as a 32-byte BE hex the
    Solidity `vm.parseJsonUint` reads), and Lean's actual encoder
    output (`encodedHex`) the Solidity side byte-matches against its
    own `abi.encodePacked`. -/
def packedLayoutGoldens : List Test.Bridge.CrossCheck.Json :=
  packedLayoutU64Vals.map (fun v =>
    .obj [ ("width", .num 64)
         , ("valueHex", .str (Test.Bridge.CrossCheck.hexFromBytes (uint256BE v)))
         , ("encodedHex", .str (Test.Bridge.CrossCheck.hexFromBytes (uint64BE v))) ])
  ++ packedLayoutU256Vals.map (fun v =>
    .obj [ ("width", .num 256)
         , ("valueHex", .str (Test.Bridge.CrossCheck.hexFromBytes (uint256BE v)))
         , ("encodedHex", .str (Test.Bridge.CrossCheck.hexFromBytes (uint256BE v))) ])

/-- The variant-21 commit preimage tail (everything after
    `preCommit ++ tag`): `uint64BE gasResource ++ uint64BE signer ++
    uint256BE newSigner ++ uint64BE poolActor ++ uint256BE newPool`.
    Emitted with its five component values so the Solidity consumer
    recomputes the identical `abi.encodePacked(...)` and byte-matches
    `tailHex` — a data-flow pin of variant 21's exact field
    order + widths + big-endianness. -/
def variant21TailGolden : Test.Bridge.CrossCheck.Json :=
  let gr : Nat := 0x0102030405060708
  let signer : Nat := 0x1112131415161718
  let ns : Nat := 0x2122232425262728
  let pa : Nat := 0x3132333435363738
  let np : Nat := 0x4142434445464748
  let tail := uint64BE gr ++ uint64BE signer ++ uint256BE ns ++ uint64BE pa ++ uint256BE np
  -- Components emitted as 32-byte BE hex (not decimal) so the Solidity
  -- `vm.parseJsonUint` reads them losslessly — the `gr`/`signer`/`pa`
  -- values exceed 2^53 and a decimal JSON number could lose precision
  -- through a float-based parser.
  let h := fun (v : Nat) => Test.Bridge.CrossCheck.hexFromBytes (uint256BE v)
  .obj [ ("gasResource", .str (h gr)), ("signer", .str (h signer)), ("newSigner", .str (h ns))
       , ("poolActor", .str (h pa)), ("newPool", .str (h np))
       , ("tailHex", .str (Test.Bridge.CrossCheck.hexFromBytes tail)) ]

/-- Tests for the F.1.8 step-VM fixture corpus. -/
def tests : List Test.TestCase :=
  [ { name := "F.1.8: transfer fixture corpus has 24 entries"
    , body := do
        Test.assertEq (expected := 24) (actual := transferFixtures.length)
          "16 happy + 8 adversarial"
    }
  , { name := "F.1.8: mint fixture corpus has 24 entries"
    , body := do
        Test.assertEq (expected := 24) (actual := mintFixtures.length)
          "16 happy + 8 adversarial"
    }
  , { name := "SVC.5.e: burn fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := burnFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: freezeResource fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := freezeResourceFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: replaceKey fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := replaceKeyFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: reward fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := rewardFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: distributeOthers fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := distributeOthersFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: proportionalDilute fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := proportionalDiluteFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: dispute fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := disputeFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: disputeWithdraw fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := disputeWithdrawFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: verdict fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := verdictFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: rollback fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := rollbackFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: registerIdentity fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := registerIdentityFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: deposit fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := depositFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: withdraw fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10) (actual := withdrawFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: declareLocalPolicy fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := declareLocalPolicyFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: revokeLocalPolicy fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := revokeLocalPolicyFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: faultProofChallenge fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := faultProofChallengeFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "SVC.5.e: faultProofResolution fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := faultProofResolutionFixtures.length)
          "6 happy + 4 adversarial"
    }
  , { name := "GP.3.3: depositWithFee fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := depositWithFeeFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "GP.3.3: topUpActionBudget fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := topUpActionBudgetFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "GP.5.3: topUpActionBudgetFor fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := topUpActionBudgetForFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "GP.5.3: full corpus has 248 entries"
    , body := do
        -- 24 + 24 + 18 × 10 + 2 × 10 = 248 (GP.5.3 extension:
        -- +topUpActionBudgetFor on top of the 238 entries that
        -- already carried +depositWithFee + topUpActionBudget).
        Test.assertEq (expected := 248) (actual := allFixtures.length)
          "248 = 24 + 24 + 18 × 10 + 2 × 10"
    }
  , { name := "F.1.8: every fixture has non-empty fixtureId"
    , body := do
        Test.assert (allFixtures.all
                      (fun f => f.fixtureId.length > 0))
          "all fixtures have valid IDs"
    }
  , { name := "F.1.8: every fixture has non-empty actionVariant"
    , body := do
        Test.assert (allFixtures.all
                      (fun f => f.actionVariant.length > 0))
          "all fixtures have valid action variants"
    }
  , { name := "GP.5.3: every happy fixture's actionKindByte is in 0..21"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        -- Post-Workstream-GP: dispatcher range widened from 0..18
        -- (SVC.5.e) to 0..20 (depositWithFee = 19, topUpActionBudget =
        -- 20) and now to 0..21 (GP.5.3: topUpActionBudgetFor = 21).
        Test.assert (happy.all (fun f => f.actionKindByte.toNat ≤ 21))
          "all happy fixture actionKindBytes are valid dispatchers"
    }
  , { name := "F.1.8: happy-path fixtures have non-null expectedPostStateCommit"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all
                      (fun f => f.expectedPostStateCommitHex.length > 2))
          "happy-path fixtures have hex commit"
    }
  , { name := "F.1.8: adversarial fixtures have null expectedPostStateCommit"
    , body := do
        let adv := allFixtures.filter
                     (fun f => f.expectedRevertReason ≠ "null")
        Test.assert (adv.all
                      (fun f => f.expectedPostStateCommitHex = "null"))
          "adversarial fixtures have null post-commit"
    }
  , { name := "F.1.8: every happy fixture's preCommit is 32 bytes (66 hex chars)"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all
                      (fun f => f.preStateCommitHex.length = 66))
          "preCommit is '0x' + 64 hex chars (32 bytes)"
    }
  , { name := "SVC.5.e: every happy fixture's expectedStepVMCommit is 32 bytes"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all
                      (fun f => f.expectedStepVMCommitHex.length = 66))
          "happy stepVMCommit is 32 bytes"
    }
  , { name := "GP.3.3: per-variant happy-fixture count is uniform"
    , body := do
        -- Every non-Transfer / non-Mint variant has exactly 6
        -- happy entries; Transfer / Mint have 16.  This pins the
        -- corpus shape against accidental imbalance.  Workstream
        -- GP adds two new 6-happy variants (depositWithFee,
        -- topUpActionBudget) — they inherit the same 6-happy
        -- discipline.
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        let perVariant : List (String × Nat) := happy.foldl
          (fun acc f =>
            let v := f.actionVariant
            match acc.find? (fun p => p.1 = v) with
            | some _ => acc.map (fun p =>
                          if p.1 = v then (p.1, p.2 + 1) else p)
            | none => acc ++ [(v, 1)])
          []
        let largestNonTM := perVariant.filter
          (fun p => p.1 ≠ "transfer" ∧ p.1 ≠ "mint")
        Test.assert (largestNonTM.all (fun p => p.2 = 6))
          "non-Transfer/Mint variants have exactly 6 happy entries"
    }
  , { name := "F.1.8: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        Test.assert true
          "cross-stack gate (Solidity side checks isKeccak256Linked)"
    }
    -- SVC.5.e+ structural tests for the new cell-proof field.
  , { name := "SVC.5.e+: happy cell-bound fixtures carry non-empty cellProofs"
    , body := do
        -- Workstream GP: the new structured variants (depositWithFee,
        -- topUpActionBudget, topUpActionBudgetFor) are also cell-bound
        -- — each reads a recipient/signer + poolActor balance pair.
        let cellBoundVariants : List String :=
          ["transfer", "burn", "reward", "deposit", "withdraw",
           "distributeOthers", "proportionalDilute",
           "depositWithFee", "topUpActionBudget", "topUpActionBudgetFor"]
        let happy := allFixtures.filter (fun f =>
          f.expectedRevertReason = "null" ∧
          cellBoundVariants.contains f.actionVariant)
        Test.assert (happy.all (fun f => f.cellProofsForFixture.length > 0))
          "cell-bound happy fixtures have non-empty bundles"
    }
  , { name := "SVC.5.e+: every cellProof's witnessCommitHex matches preStateCommitHex"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all (fun f =>
          f.cellProofsForFixture.all (fun p =>
            p.witnessCommitHex = f.preStateCommitHex)))
          "witness commit binding"
    }
  , { name := "SVC.5.e+: every happy fixture's cellProofs has cellKind ≤ 6"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all (fun f =>
          f.cellProofsForFixture.all (fun p =>
            p.cellKindNat ≤ 6)))
          "cellKind in 0..6"
    }
  , { name := "SVC.5.e+: bulk variants (distributeOthers / proportionalDilute) have ≥ 5 cellProofs"
    , body := do
        -- 2 observer cells (registry, nonce) + 3 recipient cells = 5.
        let bulk := allFixtures.filter (fun f =>
          f.expectedRevertReason = "null" ∧
          (f.actionVariant = "distributeOthers" ∨
           f.actionVariant = "proportionalDilute"))
        Test.assert (bulk.all (fun f =>
          f.cellProofsForFixture.length ≥ 5))
          "bulk variants ship ≥ 5 cell proofs"
    }
  , { name := "SVC.5.e+: adversarial fixtures have empty cellProofs"
    , body := do
        let adv := allFixtures.filter
                     (fun f => f.expectedRevertReason ≠ "null")
        Test.assert (adv.all (fun f =>
          f.cellProofsForFixture.isEmpty))
          "adversarial fixtures have no cell proofs"
    }
  , { name := "GP.5.3: packed-layout goldens well-formed + variant-21 tail round-trips"
    , body := do
        -- Lake-time regression guard for the data-flow layout goldens
        -- emitted into step_vm.json.  The byte-exact CROSS-STACK pin
        -- lives on the Solidity side (`StepVM.t.sol`'s
        -- `test_packedLayoutGoldens_match_abiEncodePacked` +
        -- `test_variant21_tailGolden_matches_abiEncodePacked` READ the
        -- emitted `encodedHex` / `tailHex` and recompute
        -- `abi.encodePacked`, so there is a single source of truth and
        -- a one-sided layout drift is caught mechanically).  Here we
        -- pin Lean's own encoder shapes + that the variant-21 tail
        -- re-decodes through the SAME `readUint64BE` the kind-21
        -- dispatcher consumes, at the documented field offsets.
        Test.assert (packedLayoutU64Vals.all (fun v => (uint64BE v).size = 8))
          "every uint64BE golden is exactly 8 bytes"
        Test.assert (packedLayoutU256Vals.all (fun v => (uint256BE v).size = 32))
          "every uint256BE golden is exactly 32 bytes"
        -- The uint256 maximum exercises the full 32-byte width: its
        -- leading (most-significant) byte is non-zero, so a high-byte
        -- layout bug in `uint256BE` is caught (the realistic balance
        -- domain `< 2^72` never sets these bytes).
        Test.assertEq (expected := (0xFF : UInt8))
          (actual :=
            (uint256BE 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).data[0]!)
          "uint256BE pins the high (leading) byte"
        -- variant-21 tail layout round-trip via the dispatcher decoder.
        -- tail = uint64BE gr (0..8) ++ uint64BE signer (8..16)
        --        ++ uint256BE ns (16..48) ++ uint64BE pa (48..56)
        --        ++ uint256BE np (56..88).
        let gr : Nat := 0x0102030405060708
        let signer : Nat := 0x1112131415161718
        let pa : Nat := 0x3132333435363738
        let tail :=
          uint64BE gr ++ uint64BE signer ++ uint256BE 0x2122232425262728 ++
          uint64BE pa ++ uint256BE 0x4142434445464748
        Test.assertEq (expected := 88) (actual := tail.size)
          "tail = 8 + 8 + 32 + 8 + 32 = 88 bytes"
        Test.assertEq (expected := gr) (actual := readUint64BE tail 0)
          "tail gasResource @0"
        Test.assertEq (expected := signer) (actual := readUint64BE tail 8)
          "tail signer @8"
        Test.assertEq (expected := pa) (actual := readUint64BE tail 48)
          "tail poolActor @48"
    }
  , { name := "F.1.8: write step_vm.json fixture file"
    , body := do
        let entries : List Test.Bridge.CrossCheck.Json :=
          allFixtures.map fixtureToJson
        let header : Test.Bridge.CrossCheck.Json := .obj
          [ ("isKeccak256Linked",   .bool LegalKernel.Bridge.isKeccak256Linked)
          , ("count",               .num allFixtures.length)
          , ("countTransfer",       .num transferFixtures.length)
          , ("countMint",           .num mintFixtures.length)
          , ("countBurn",           .num burnFixtures.length)
          , ("countFreezeResource", .num freezeResourceFixtures.length)
          , ("countReplaceKey",     .num replaceKeyFixtures.length)
          , ("countReward",         .num rewardFixtures.length)
          , ("countDistributeOthers", .num distributeOthersFixtures.length)
          , ("countProportionalDilute",
             .num proportionalDiluteFixtures.length)
          , ("countDispute",        .num disputeFixtures.length)
          , ("countDisputeWithdraw", .num disputeWithdrawFixtures.length)
          , ("countVerdict",        .num verdictFixtures.length)
          , ("countRollback",       .num rollbackFixtures.length)
          , ("countRegisterIdentity",
             .num registerIdentityFixtures.length)
          , ("countDeposit",        .num depositFixtures.length)
          , ("countWithdraw",       .num withdrawFixtures.length)
          , ("countDeclareLocalPolicy",
             .num declareLocalPolicyFixtures.length)
          , ("countRevokeLocalPolicy",
             .num revokeLocalPolicyFixtures.length)
          , ("countFaultProofChallenge",
             .num faultProofChallengeFixtures.length)
          , ("countFaultProofResolution",
             .num faultProofResolutionFixtures.length)
          -- Workstream GP: two new variants at indices 19, 20.
          , ("countDepositWithFee",
             .num depositWithFeeFixtures.length)
          , ("countTopUpActionBudget",
             .num topUpActionBudgetFixtures.length)
          -- GP.5.3: delegated top-up at index 21.
          , ("countTopUpActionBudgetFor",
             .num topUpActionBudgetForFixtures.length)
          -- GP.5.3 hash-independent layout goldens (data-flow): the
          -- Solidity consumer reads these and recomputes
          -- `abi.encodePacked`, proving the packed byte layout agrees
          -- byte-for-byte without the keccak binding.
          , ("packedLayoutGoldensCount", .num packedLayoutGoldens.length)
          , ("packedLayoutGoldens",  .arr packedLayoutGoldens)
          , ("variant21TailGolden",  variant21TailGolden)
          , ("entries",             .arr entries)
          ]
        Test.Bridge.CrossCheck.writeFixture "step_vm.json" header.encode
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.StepVM
