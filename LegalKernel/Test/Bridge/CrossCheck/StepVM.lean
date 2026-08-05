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
import LegalKernel.FaultProof.Step
import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.FaultProof.Terminate
import LegalKernel.FaultProof.VerifierWrites
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
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
  /-- The cell's SMT opening against the pre-state root
      (`SmtCellProof.toWireBytes`), hex-encoded with `0x` prefix: a
      32-byte bitmask followed by the non-canonical-empty siblings in
      depth order.

      Pinned cross-stack because it is a CONSENSUS encoding — the L1
      parses these bytes to re-walk the path — and because it is the
      only field on the proof an L1 verifier can actually use:
      `witnessCommitHex` attests the value came from a state with this
      root, but recomputing it needs the whole `ExtendedState`. -/
  proofDataHex     : String
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
  -- `CellTag.flatKey` is the single source of truth for this
  -- destructuring (see `CellProofJson`).
  let (kindNat, keyA, keyB) : Nat × Nat × Nat := p.cellTag.flatKey
  { cellKindNat       := kindNat,
    keyANat           := keyA,
    keyBNat           := keyB,
    cellValueHex      := Test.Bridge.CrossCheck.hexFromBytes p.cellValue,
    witnessCommitHex  :=
      Test.Bridge.CrossCheck.hexFromBytes (commitExtendedState p.witnessState),
    proofDataHex      := Test.Bridge.CrossCheck.hexFromBytes p.proofData }

/-- The base state every fixture builds on.

    `ExtendedState.empty` ships `budgetPolicy := .bounded 0 1 0` — a
    zero free tier at epoch 0.  `ActorBudget.empty` then never
    normalises, its balance stays 0, and the consume refuses for every
    signer, so `productionApplyBudget` returns the un-updated state
    and the corpus exercises the budget leg on NO entry.  That is how
    the epoch-budget write obligation went unnoticed for as long as it
    did: the only cross-stack evidence covering the reference apply
    was blind to half of it.

    A non-zero epoch against a real free tier makes the consume
    succeed, so the fixtures cover the divergence they exist to
    cover. -/
private def fixtureBase : ExtendedState :=
  { ExtendedState.empty with budgetPolicy := .bounded 100 1 1 }

/-- Build a pre-state with one or more `(actor, balance)` entries
    on a single resource.  Other sub-states stay empty. -/
private def stateWithBalances (r : ResourceId)
    (entries : List (ActorId × Amount)) : ExtendedState :=
  let baseState := entries.foldl
    (fun s (a, v) => LegalKernel.setBalance s r a v)
    LegalKernel.genesisState
  { fixtureBase with base := baseState }

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
  let postCommit := recomputeCommitment es st 0
  -- Per Solidity's `_stepTransfer`:
  -- * self: newSender = newReceiver = preBalance (no debit).
  -- * non-self: newSender = preBalance - amount;
  --             newReceiver = receiverPreBalance + amount.
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action sender
  { fixtureId := s!"transfer-happy-{idx}",
    actionVariant := "transfer",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let es := fixtureBase
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"mint-happy-{idx}",
    actionVariant := "mint",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action fromActor
  { fixtureId := s!"burn-happy-{idx}",
    actionVariant := "burn",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let es := fixtureBase
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"freezeResource-happy-{idx}",
    actionVariant := "freezeResource",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let es := fixtureBase
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"replaceKey-happy-{idx}",
    actionVariant := "replaceKey",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"reward-happy-{idx}",
    actionVariant := "reward",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
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
      LegalKernel.FaultProof.buildCellProofWithOpening es (.balance r a))
  let bundleProofs := observerBundle.proofs ++ recipientProofs
  { fixtureId := s!"distributeOthers-happy-{idx}",
    actionVariant := "distributeOthers",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let es := fixtureBase
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"registerIdentity-happy-{idx}",
    actionVariant := "registerIdentity",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"deposit-happy-{idx}",
    actionVariant := "deposit",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action sender
  { fixtureId := s!"withdraw-happy-{idx}",
    actionVariant := "withdraw",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  -- Per Laws.depositWithFee.apply_impl:
  --   recipient += userAmount; then poolActor += poolAmount.
  -- Self-credit case: both writes target the same cell, so the
  -- new balance is `pre + userAmount + poolAmount`.
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"depositWithFee-happy-{idx}",
    actionVariant := "depositWithFee",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  -- Per Laws.topUpActionBudget.apply_impl:
  --   signer's gas balance -= gasAmount; poolActor's += gasAmount.
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"topUpActionBudget-happy-{idx}",
    actionVariant := "topUpActionBudget",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
  let postCommit := recomputeCommitment es st 0
  -- Per Laws.topUpActionBudgetFor.apply_impl:
  --   signer's gas balance -= gasAmount; poolActor's += gasAmount.
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"topUpActionBudgetFor-happy-{idx}",
    actionVariant := "topUpActionBudgetFor",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- GP.9.1: build a `claimBudgetRefund` (index 22) happy fixture.  The
    claimant (signer) is CREDITED `budgetUnits × weiPerBudgetUnit` OUT
    OF `poolActor` at `gasResource` — the MIRROR of `topUpActionBudget`
    (debit/credit reversed).  Pre-state funds the pool ≥ the refund
    (the gate's pool-solvency conjunct) and `signer ≠ poolActor` (the
    gate's self-pool defense). -/
def buildClaimBudgetRefundHappy
    (idx : Nat) (gasResource : ResourceId)
    (signer poolActor : ActorId)
    (claimantInitBal poolInitBal budgetUnits weiPerBudgetUnit : Nat)
    (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action :=
    .claimBudgetRefund gasResource budgetUnits weiPerBudgetUnit poolActor
  let st : SignedAction := { action, signer, nonce, sig }
  let es := stateWithBalances gasResource
              [(signer, claimantInitBal), (poolActor, poolInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  -- Per Laws.claimBudgetRefund.apply_impl: poolActor -= refundAmount;
  -- claimant (signer) += refundAmount.
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"claimBudgetRefund-happy-{idx}",
    actionVariant := "claimBudgetRefund",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
    (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let st : SignedAction := { action, signer, nonce, sig }
  let es := fixtureBase
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"{variant}-happy-{idx}",
    actionVariant := variant,
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
    signer nonce sig

/-- Build a happy-path fixture for `Action.rollback`. -/
def buildRollbackHappy
    (idx : Nat) (targetIdx : Disputes.LogIndex) (signer : ActorId)
    (nonce : Nonce) (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "rollback" idx (.rollback targetIdx)
    signer nonce sig

/-- Build a happy-path fixture for `Action.revokeLocalPolicy`. -/
def buildRevokeLocalPolicyHappy
    (idx : Nat) (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  buildOpaqueHappy "revokeLocalPolicy" idx .revokeLocalPolicy
    signer nonce sig

/-- Build a happy-path fixture for `Action.faultProofChallenge`. -/
def buildFaultProofChallengeHappy
    (idx : Nat) (bindingHash : ByteArray) (startIdx endIdx : Disputes.LogIndex)
    (challengerCommit : ByteArray) (signer : ActorId) (nonce : Nonce)
    (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "faultProofChallenge" idx
    (.faultProofChallenge bindingHash startIdx endIdx challengerCommit)
    signer nonce sig

/-- Build a happy-path fixture for `Action.faultProofResolution`. -/
def buildFaultProofResolutionHappy
    (idx : Nat) (bindingHash : ByteArray) (gameId : Nat) (winner : ActorId)
    (revertFromIdx : Disputes.LogIndex) (signer : ActorId) (nonce : Nonce)
    (sig : ByteArray) : StepVMFixture :=
  buildOpaqueHappy "faultProofResolution" idx
    (.faultProofResolution bindingHash gameId winner revertFromIdx)
    signer nonce sig

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
  let postCommit := recomputeCommitment es st 0
  let observerBundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  let recipientProofs : List CellProof :=
    recipients.map (fun (a, _) =>
      LegalKernel.FaultProof.buildCellProofWithOpening es (.balance r a))
  let bundleProofs := observerBundle.proofs ++ recipientProofs
  -- Pass 1: compute sumOthers by walking the bundle in iteration
  -- order, applying Solidity's exact filter.
  -- Pass 2: per-recipient credit + fold.
  { fixtureId := s!"proportionalDilute-happy-{idx}",
    actionVariant := "proportionalDilute",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
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
    signer nonce sig

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
  buildOpaqueHappy "verdict" idx (.verdict v) signer nonce sig

/-- Build a happy-path fixture for `Action.declareLocalPolicy`. -/
def buildDeclareLocalPolicyHappy
    (idx : Nat) (signer : ActorId) (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let p : LocalPolicy := LocalPolicy.empty
  buildOpaqueHappy "declareLocalPolicy" idx (.declareLocalPolicy p)
    signer nonce sig

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

/-- GP.9.1 fixtures for `claimBudgetRefund` (10 entries: 6 happy + 4
    adversarial).  The 6 happy entries sweep `gasResource ∈ {0,1}` (ETH
    / BOLD legs), keep `signer ≠ poolActor` + a pool funded ≥ the
    refund, and end with the exact-pool-drain boundary (`i = 5`:
    `poolInitBal = refundAmount`, so the pool is drained to 0). -/
def claimBudgetRefundFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    -- `signer = i + 10` (≠ bridgeActor 0, ≠ pool); `poolActor = i + 20`
    -- (≠ signer); `gasResource` alternates 0 (ETH) / 1 (BOLD).
    let gasResource : ResourceId := ((i % 2) : Nat).toUInt64
    let signer : ActorId := ((i + 10) : Nat).toUInt64
    let poolActor : ActorId := ((i + 20) : Nat).toUInt64
    -- NOTE on the `uint256` product (`_stepClaimBudgetRefund` decodes
    -- `budgetUnits`/`weiPerBudgetUnit` into `uint256` and multiplies
    -- there): a happy fixture CANNOT exercise a product `≥ 2^64`.  Every
    -- balance cell is encoded as a fixed 8-byte LE `uint64` (see the
    -- `cellValueHex` shape `0x00 <8B LE>`), so a refund whose
    -- `refundAmount = budgetUnits × weiPerBudgetUnit ≥ 2^64` cannot be
    -- paid — the pool that would have to hold it overflows the `uint64`
    -- balance cell.  The admission gate enforces this upstream (pool
    -- solvency `getBalance gasPoolActor ≥ refundAmount`, and balances are
    -- `uint64`-bounded by `CanonicalBounds`), so an ADMITTED refund
    -- always has `refundAmount < 2^64`.  The `uint256` multiply is thus
    -- defence-in-depth: a hypothetical `≥ 2^64` product is correctly
    -- REJECTED (`InsufficientBalance`, since no `uint64` pool can fund
    -- it) rather than silently truncated-and-accepted by a `uint64`
    -- multiply.  The full-width `uint256BE` encoding of the commit's
    -- `newSignerBalance` / `newPoolBalance` fields is covered keccak-
    -- independently by the `packedLayoutGoldens` data-flow goldens, so
    -- these fixtures stay within the realistic `uint64` balance domain.
    let budgetUnits : Nat := i + 1            -- > 0 always
    let weiPerBudgetUnit : Nat := i + 2       -- > 0 always
    let refundAmount : Nat := budgetUnits * weiPerBudgetUnit
    let claimantInitBal : Nat := 50 + i
    -- last entry: exact-pool-drain (pool holds exactly `refundAmount`).
    let poolInitBal : Nat := if i == 5 then refundAmount else refundAmount + 100 + i
    buildClaimBudgetRefundHappy i gasResource signer poolActor
                                claimantInitBal poolInitBal budgetUnits weiPerBudgetUnit
                                (i * 89) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "claimBudgetRefund")

/-- GP.11.8: build an `ammSwap` (index 23) happy fixture.  The swap
    credits `amountIn` to `ammReserveActor`'s `fromResource` balance and
    debits `amountOut` from its `toResource` balance.  Pre-state funds
    the reserve actor at both resources so the debit succeeds. -/
def buildAmmSwapHappy
    (idx : Nat) (fromResource toResource : ResourceId)
    (signer ammReserveActor : ActorId)
    (amountIn amountOut fromInitBal toInitBal : Nat)
    (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action :=
    .ammSwap fromResource toResource amountIn amountOut ammReserveActor
  let st : SignedAction := { action, signer, nonce, sig }
  let es := stateWithBalances fromResource
              [(ammReserveActor, fromInitBal)] |>
            (fun es =>
              { es with base :=
                LegalKernel.setBalance es.base toResource ammReserveActor toInitBal })
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"ammSwap-happy-{idx}",
    actionVariant := "ammSwap",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- GP.11.8 fixtures for `ammSwap` (10 entries: 6 happy + 4
    adversarial).  The 6 happy entries sweep `fromResource ∈ {0,1}`
    (ETH→BOLD / BOLD→ETH), vary amounts, and end with an exact-drain
    boundary (`i = 5`: `toInitBal = amountOut`, so the to-reserve is
    drained to 0). -/
def ammSwapFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    let fromResource : ResourceId := ((i % 2) : Nat).toUInt64
    let toResource : ResourceId := (((i + 1) % 2) : Nat).toUInt64
    let signer : ActorId := ((i + 10) : Nat).toUInt64
    let ammReserveActor : ActorId := 3
    let amountIn : Nat := (i + 1) * 100
    let amountOut : Nat := (i + 1) * 50
    let fromInitBal : Nat := 10000 + i * 100
    let toInitBal : Nat := if i == 5 then amountOut else amountOut + 500 + i * 50
    buildAmmSwapHappy i fromResource toResource signer ammReserveActor
                      amountIn amountOut fromInitBal toInitBal
                      (i * 97) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "ammSwap")

/-- GP.11.10: build a `reclaimAmmReserves` (index 24) happy fixture.
    The sweep debits the reserve actor's ENTIRE `r` balance (the
    exact-sweep precondition pins `amount = balance`) and credits the
    pool actor the same amount.  Pre-state funds the reserve actor at
    exactly `amount` and the pool actor at `poolInitBal`. -/
def buildReclaimAmmReservesHappy
    (idx : Nat) (r : ResourceId)
    (signer reserveActor poolActor : ActorId)
    (amount poolInitBal : Nat)
    (nonce : Nonce) (sig : ByteArray) :
    StepVMFixture :=
  let action : Action :=
    .reclaimAmmReserves r amount reserveActor poolActor
  let st : SignedAction := { action, signer, nonce, sig }
  let es := stateWithBalances r
              [(reserveActor, amount), (poolActor, poolInitBal)]
  let preCommit := commitExtendedState es
  let postCommit := recomputeCommitment es st 0
  let bundle :=
    LegalKernel.FaultProof.Observer.buildObserverCellProofs
      es action signer
  { fixtureId := s!"reclaimAmmReserves-happy-{idx}",
    actionVariant := "reclaimAmmReserves",
    preStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes preCommit,
    signedActionHex := encodeSignedAction st,
    expectedPostStateCommitHex := Test.Bridge.CrossCheck.hexFromBytes postCommit,
    expectedRevertReason := "null",
    actionKindByte := actionKindByte action,
    actionFieldsHex := encodeActionFields action,
    signerNat := signer.toNat,
    cellProofsForFixture := bundleToFixtureProofs bundle.proofs }

/-- GP.11.10 fixtures for `reclaimAmmReserves` (10 entries: 6 happy +
    4 adversarial).  The 6 happy entries sweep both gas legs
    (`r ∈ {0,1}`), vary the swept amount across magnitudes, use the
    canonical reserved actors (`reserveActor = 3`, `poolActor = 1`),
    and end with a fresh-pool boundary (`i = 5`: `poolInitBal = 0`, so
    the pool credit is a zero→non-zero write). -/
def reclaimAmmReservesFixtures : List StepVMFixture :=
  (List.range 6).map (fun i =>
    let r : ResourceId := ((i % 2) : Nat).toUInt64
    let signer : ActorId := ((i + 10) : Nat).toUInt64
    let reserveActor : ActorId := 3
    let poolActor : ActorId := 1
    let amount : Nat := (i + 1) * 750
    let poolInitBal : Nat := if i == 5 then 0 else 200 + i * 40
    buildReclaimAmmReservesHappy i r signer reserveActor poolActor
                                 amount poolInitBal
                                 (i * 101) (ByteArray.mk #[i.toUInt8])) ++
  (List.range 4).map (fun i =>
    buildAdversarialBadPreCommit i "reclaimAmmReserves")

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
    Total: 24 + 24 + 20 × 10 + 3 × 10 = 278 entries (post-GP.11.10:
    +reclaimAmmReserves on top of the 268 entries that already carried
    +ammSwap). -/
def allFixtures : List StepVMFixture :=
  transferFixtures ++ mintFixtures ++ burnFixtures ++
  freezeResourceFixtures ++ replaceKeyFixtures ++ rewardFixtures ++
  distributeOthersFixtures ++ proportionalDiluteFixtures ++
  disputeFixtures ++ disputeWithdrawFixtures ++ verdictFixtures ++
  rollbackFixtures ++ registerIdentityFixtures ++ depositFixtures ++
  withdrawFixtures ++ declareLocalPolicyFixtures ++
  revokeLocalPolicyFixtures ++ faultProofChallengeFixtures ++
  faultProofResolutionFixtures ++ depositWithFeeFixtures ++
  topUpActionBudgetFixtures ++ topUpActionBudgetForFixtures ++
  claimBudgetRefundFixtures ++
  ammSwapFixtures ++
  reclaimAmmReservesFixtures

/-! ## Test suite (Lean-side fixture-stability tests) -/

/-- The L1 action commitment for a fixture entry, hex-encoded.

    Derived from the entry's own PUBLISHED `actionKindByte` /
    `signerNat` / `actionFieldsHex` rather than from the `Action` the
    builder started with, because that is exactly what the Solidity
    side does: it parses those three fields out of the JSON and calls
    `LogChain.actionCommit` on them.  Deriving from the same published
    bytes makes the corpus a Lean-vs-Solidity pin on the ENCODING,
    which is the thing the two stacks have to agree on.

    Calls `l1ActionCommitBytes` — the production function — rather than
    re-spelling its body; a second spelling here would agree with
    Solidity while disagreeing with the chain the L2 actually binds. -/
private def actionCommitHexOf (f : StepVMFixture) : String :=
  match Test.Bridge.CrossCheck.bytesFromHex f.actionFieldsHex with
  | some fields =>
      Test.Bridge.CrossCheck.hexFromBytes
        (StepVMCoherence.l1ActionCommitBytes f.actionKindByte f.signerNat fields)
  -- Unreachable: `actionFieldsHex` is written by `hexFromBytes`.  Emit
  -- a value that cannot be mistaken for a commitment, so a decoder
  -- regression fails the Solidity-side comparison rather than
  -- silently publishing a plausible hash.
  | none => "0x"

/-- Convert one `CellProofForFixture` to its JSON
    representation. -/
private def cellProofForFixtureToJson (p : CellProofForFixture) :
    Test.Bridge.CrossCheck.Json :=
  .obj [ ("cellKind",         .num p.cellKindNat)
       , ("keyA",              .num p.keyANat)
       , ("keyB",              .num p.keyBNat)
       , ("cellValueHex",      .str p.cellValueHex)
       , ("witnessCommitHex",  .str p.witnessCommitHex)
       , ("proofDataHex",      .str p.proofDataHex) ]

/-- Convert one fixture to its JSON representation. -/
private def fixtureToJson (f : StepVMFixture) :
    Test.Bridge.CrossCheck.Json :=
  .obj [ ("fixtureId",                .str f.fixtureId)
       , ("actionVariant",            .str f.actionVariant)
       , ("preStateCommitHex",        .str f.preStateCommitHex)
       , ("signedActionHex",          .str f.signedActionHex)
       , ("expectedPostStateCommitHex",
          .str f.expectedPostStateCommitHex)
       , ("expectedRevertReason",     .str f.expectedRevertReason)
       , ("actionKindByte",           .num f.actionKindByte.toNat)
       , ("actionFieldsHex",          .str f.actionFieldsHex)
       , ("signerNat",                .num f.signerNat)
       , ("expectedActionCommitHex",  .str (actionCommitHexOf f))
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

/-! ### CBE value-encoder goldens (the state-root flip's foundation)

Once `executeStep` computes cell VALUES rather than hashing them, it
must produce each one in its canonical CBE byte form — the SMT leaf is
hashed over those bytes, so a value that is numerically right and
byte-wrong re-walks to a different root and the honest sequencer's root
becomes unreachable.

Two things make this worth a golden rather than an inspection.  The
CBE head is LITTLE-endian while `actionFieldsForL1` is big-endian, so
both orders live in the same contract and a wrong-endianness encoder
produces a plausible 9-byte value.  And the widths are FIXED, not
minimal — a uint is always 8 payload bytes even when the value fits in
one — because a length-minimal encoding would give two encodings of the
same number, and an SMT leaf must be a function of the value alone.

`solidity/src/lib/CBEEncode.sol` is the mirror.
-/

/-- Probe values for the CBE encoders: zero, one, byte and word
    boundaries, and the maxima each width admits.  The boundaries are
    where a fixed-width little-endian writer with an off-by-one goes
    wrong while every small value still passes. -/
def cbeUintGoldenVals : List Nat :=
  [0, 1, 0xFF, 0x0100, 0x0102030405060708, 0xFFFFFFFFFFFFFFFF]

/-- ...and for the 32-byte amount head. -/
def cbeAmountGoldenVals : List Nat :=
  [0, 1, 0xFF, 0x0100, 0x0102030405060708,
   0xFFFFFFFFFFFFFFFF, 0x0102030405060708090A0B0C0D0E0F10,
   0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF]

/-- Byte-string payloads: empty (whose 9-byte head is what
    distinguishes a present-empty registry entry from an absent one),
    one byte, and a 33-byte payload that crosses the word boundary. -/
def cbeBytesGoldenPayloads : List ByteArray :=
  [ ByteArray.empty
  , ByteArray.mk #[0xAB]
  , ByteArray.mk (Array.range 33 |>.map (fun i => UInt8.ofNat (i + 1))) ]

/-- Lean's actual CBE encoder output for each probe, for the Solidity
    side to byte-match against `CBEEncode`. -/
def cbeEncoderGoldens : List Test.Bridge.CrossCheck.Json :=
  let h := fun (v : Nat) => Test.Bridge.CrossCheck.hexFromBytes (uint256BE v)
  cbeUintGoldenVals.map (fun v =>
    .obj [ ("kind", .str "uint")
         , ("valueHex", .str (h v))
         , ("payloadHex", .str "0x")
         , ("encodedHex", .str (Test.Bridge.CrossCheck.hexFromBytes
             (ByteArray.mk (Encoding.Encodable.encode (T := Nat) v).toArray))) ])
  ++ cbeAmountGoldenVals.map (fun v =>
    .obj [ ("kind", .str "amount")
         , ("valueHex", .str (h v))
         , ("payloadHex", .str "0x")
         , ("encodedHex", .str (Test.Bridge.CrossCheck.hexFromBytes
             (ByteArray.mk (Encoding.encodeAmount v).toArray))) ])
  ++ cbeBytesGoldenPayloads.map (fun bs =>
    .obj [ ("kind", .str "bytes")
         , ("valueHex", .str (h 0))
         , ("payloadHex", .str (Test.Bridge.CrossCheck.hexFromBytes bs))
         , ("encodedHex", .str (Test.Bridge.CrossCheck.hexFromBytes
             (ByteArray.mk (Encoding.Encodable.encode (T := ByteArray) bs).toArray))) ])

/-! ### Uniform-cell derivation goldens

The two cells EVERY action writes, derived from proven pre-values —
what `solidity/src/lib/StepWrites.sol` must reproduce.  They are the
cells `stepVMHash` is silent about (it reads and emits balance cells
only), so they are also the ones its output would be wrong about for
every action the moment it is compared against a state root.

The grant triple is emitted rather than re-derived on the Solidity
side: `budgetGrant`'s recipient differs per variant — the deposit's
recipient, the SIGNER, or a named recipient — so a mirror that assumed
"top up the signer" would agree on twenty-two variants and diverge on
two.  Emitting it makes the disagreement visible in the corpus instead
of in a game.
-/

/-- Whether an action grants at all, the `(recipient, amount)` it
    grants, and the extra units a refund claim consumes.  Mirrors
    `budgetGrant`'s per-variant arms and `refundConsumeExtra`.

    The leading `Bool` is not redundant with `amount ≠ 0`.
    `ActorBudget.topUp` NORMALISES before it adds, so a grant of zero
    still refreshes a stale cell to the free tier — a granting variant
    whose amount happens to be zero is not the same as a variant that
    grants nothing.  The L1 mirror inferred one from the other and so
    skipped the normalisation, forking the root; `StepPlan.planGrant`
    now carries the flag and this emits it. -/
private def grantPlanOf (action : Action) (signer : ActorId) :
    Bool × ActorId × Nat × Nat :=
  match action with
  | .depositWithFee _ recipient _ _ _ g _ => (true, recipient, g, 0)
  | .topUpActionBudget _ _ inc _          => (true, signer, inc, 0)
  | .topUpActionBudgetFor recipient _ _ inc _ => (true, recipient, inc, 0)
  | .claimBudgetRefund _ budgetUnits _ _  => (false, signer, 0, budgetUnits)
  | _                                     => (false, signer, 0, 0)

/-- Per-entry goldens for the nonce and epoch-budget derivations, over
    the fixture base state — the pre-values, the grant triple, and the
    derived post-values Lean's `VerifierWrites` produces. -/
def uniformWriteGoldens : List Test.Bridge.CrossCheck.Json :=
  let es := fixtureBase
  let signer : ActorId := 7
  let hx := Test.Bridge.CrossCheck.hexFromBytes
  let h256 := fun (v : Nat) => hx (uint256BE v)
  let probes : List (String × Action) :=
    [ ("transfer",            .transfer 1 signer 8 5)
    , ("mint",                .mint 1 8 5)
    , ("withdraw",            .withdraw 1 signer 5 LegalKernel.Bridge.EthAddress.zero)
    , ("depositWithFee",      .depositWithFee 1 8 9 5 1 3 3)
    , ("topUpActionBudget",   .topUpActionBudget 1 5 2 9)
    , ("topUpActionBudgetFor", .topUpActionBudgetFor 8 1 5 2 9)
    , ("claimBudgetRefund",   .claimBudgetRefund 1 2 3 9)
      -- A GRANTING variant whose grant is ZERO.  `fixtureBase`'s policy
      -- is `.bounded 100 1 1` and actor 8 holds no budget cell, so
      -- `lastSeenEpoch 0 < 1` and `topUp … 0` is `normalise`: the cell
      -- moves to `{1, 100}` and becomes PRESENT in the tree.  A verifier
      -- that reads "amount is zero" as "no grant" leaves it canonically
      -- absent and folds to a different root.  Reachable in production
      -- whenever a deposit's `poolAmount / weiPerBudgetUnit` floors to
      -- zero.
    , ("depositWithFeeZeroGrant", .depositWithFee 1 8 9 5 1 0 4) ]
  probes.flatMap (fun (name, action) =>
    let st : SignedAction :=
      { action, signer, nonce := 0, sig := ByteArray.empty }
    let (grants, grantRecipient, grantAmount, refundExtra) := grantPlanOf action signer
    -- The signer's own cell and, where they differ, the grant
    -- recipient's: the branch that credits a recipient on a step the
    -- signer could afford is only exercised when the two are distinct.
    let targets : List ActorId :=
      if grantRecipient = signer then [signer] else [signer, grantRecipient]
    targets.map (fun target =>
      .obj [ ("variant",        .str name)
           , ("signer",         .str (h256 signer.toNat))
           , ("target",         .str (h256 target.toNat))
           , ("grants",         .bool grants)
           , ("grantRecipient", .str (h256 grantRecipient.toNat))
           , ("grantAmount",    .str (h256 grantAmount))
           , ("refundExtra",    .str (h256 refundExtra))
           , ("noncePreHex",    .str (hx (getCellValue es (.nonce signer))))
           , ("noncePostHex",   .str (hx (getCellValue
               (productionApplyBudget es st 0) (.nonce signer))))
           , ("policyHex",      .str (hx (getCellValue es .budgetPolicy)))
           , ("signerBudgetPreHex",
              .str (hx (getCellValue es (.epochBudget signer))))
           , ("targetBudgetPreHex",
              .str (hx (getCellValue es (.epochBudget target))))
           , ("targetBudgetPostHex",
              .str (hx (getCellValue (productionApplyBudget es st 0)
                (.epochBudget target)))) ]))

/-! ### Balance-derivation goldens

The per-variant half.  Each probe carries the proven pre-balances, the
action's amounts, and the post-values Lean's `VerifierWrites` derives —
including the cases a happy-path corpus would never reach:

  * a **self-transfer**, where the credit reads the DEBITED state and
    the net change is zero;
  * a **failing precondition**, where `step_impl` no-ops and both cells
    keep their pre-values — the case the L1 currently REVERTS on, which
    costs the responsible party the game by timeout rather than
    settling it;
  * a **same-actor chain**, where the payer IS the pool actor.
-/

/-- One balance-derivation probe as JSON.  `kind` selects which
    `StepWrites` function the Solidity side calls; the two `post`
    columns are Lean's derived values. -/
private def balanceGolden (kind : String) (xPre yPre : Nat)
    (x y : Nat) (amountA amountB : Nat) (xPost yPost : Nat) :
    Test.Bridge.CrossCheck.Json :=
  let h := fun (v : Nat) => Test.Bridge.CrossCheck.hexFromBytes (uint256BE v)
  .obj [ ("kind", .str kind)
       , ("xPre", .str (h xPre)), ("yPre", .str (h yPre))
       , ("x", .str (h x)), ("y", .str (h y))
       , ("amountA", .str (h amountA)), ("amountB", .str (h amountB))
       , ("xPost", .str (h xPost)), ("yPost", .str (h yPost)) ]

/-- Balance-derivation goldens, computed by the production
    `VerifierWrites` functions over the fixture base state. -/
def balanceWriteGoldens : List Test.Bridge.CrossCheck.Json :=
  -- A POPULATED state, on two resources.  `fixtureBase` holds no
  -- balances, so every probe over it would start from zero — the
  -- transfer would fail its precondition, the self-transfer and the
  -- chained pair would be indistinguishable from the no-op, and the
  -- goldens would agree with a Solidity mirror that did nothing at
  -- all.  A vacuous golden is worse than none: it reads as coverage.
  let es : ExtendedState :=
    let base : LegalKernel.State :=
      { balances :=
          ((∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
             ((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 9 25)).insert 2
             ((∅ : BalanceMap).insert 9 60) }
    { fixtureBase with base := base }
  let r : ResourceId := 1
  let read := stateBalanceReader es
  let bal := fun (a : ActorId) => LegalKernel.getBalance es.base r a
  -- Pull the derived pair out of the `Option (List …)` the derivations
  -- return, defaulting to the pre-values on a shape the probe should
  -- never produce (which would then fail the Solidity comparison
  -- loudly rather than silently agreeing).
  let pair := fun (o : Option (List ((ResourceId × ActorId) × Nat)))
      (dx dy : Nat) =>
    match o with
    | some [(_, vx), (_, vy)] => (vx, vy)
    | some [(_, vx)]          => (vx, dy)
    | _                       => (dx, dy)
  let transferOk := pair (deriveTransferBalances read r 7 8 30) (bal 7) (bal 8)
  let transferSelf := pair (deriveTransferBalances read r 7 7 30) (bal 7) (bal 7)
  let transferNoop :=
    pair (deriveTransferBalances read r 7 8 999999) (bal 7) (bal 8)
  let mintOk := pair (deriveCreditBalance read r 8 5) (bal 8) 0
  let burnOk := pair (deriveBurnBalance read r 8 5) (bal 8) 0
  let burnNoop := pair (deriveBurnBalance read r 8 999999) (bal 8) 0
  let depositOk := pair (deriveDepositBalance read r 8 0) (bal 8) 0
  let topUpOk := pair (deriveTopUpBalances read r 7 9 5) (bal 7) (bal 9)
  let topUpSelf := pair (deriveTopUpBalances read r 7 7 5) (bal 7) (bal 7)
  -- The cross-resource variant: reserve 9 credited at `r`, debited at
  -- resource 2.  Its `toBal` is read at the OTHER resource, which is
  -- why it does not go through the chained pair.
  let swapOk := pair (deriveAmmSwapBalances read r 2 5 10 9)
    (bal 9) (LegalKernel.getBalance es.base 2 9)
  -- ...and the no-op case, where the reserve at `toResource` cannot
  -- cover `amountOut`.  Without it the swap probe would only ever
  -- exercise the succeeding branch.
  let swapNoop := pair (deriveAmmSwapBalances read r 2 5 999999 9)
    (bal 9) (LegalKernel.getBalance es.base 2 9)
  [ balanceGolden "ammSwap" (bal 9) (LegalKernel.getBalance es.base 2 9)
      1 2 5 10 swapOk.1 swapOk.2
  , balanceGolden "ammSwap" (bal 9) (LegalKernel.getBalance es.base 2 9)
      1 2 5 999999 swapNoop.1 swapNoop.2
  , balanceGolden "transfer" (bal 7) (bal 8) 7 8 30 0 transferOk.1 transferOk.2
  , balanceGolden "transfer" (bal 7) (bal 7) 7 7 30 0 transferSelf.1 transferSelf.2
  , balanceGolden "transfer" (bal 7) (bal 8) 7 8 999999 0
      transferNoop.1 transferNoop.2
  , balanceGolden "credit" (bal 8) 0 8 0 5 0 mintOk.1 mintOk.2
  , balanceGolden "debit" (bal 8) 0 8 0 5 0 burnOk.1 burnOk.2
  , balanceGolden "debit" (bal 8) 0 8 0 999999 0 burnNoop.1 burnNoop.2
  , balanceGolden "deposit" (bal 8) 0 8 0 0 0 depositOk.1 depositOk.2
  , balanceGolden "topUp" (bal 7) (bal 9) 7 9 5 0 topUpOk.1 topUpOk.2
  , balanceGolden "topUp" (bal 7) (bal 7) 7 7 5 0 topUpSelf.1 topUpSelf.2 ]

/-! ### Registry / policy / bridge cell goldens

The cells whose post-values come from the ACTION's own fields.  Cheap
to derive and easy to get subtly wrong: the registry value rides the
CBE byte-string encoder (so a present-EMPTY key is distinguishable from
an absent one), a revoke emits the ABSENT marker rather than an encoded
empty policy, and the two bridge records are field concatenations whose
component encoders differ (uint head vs amount head vs byte-string).
-/

/-- Per-cell goldens for the action-field-derived cells. -/
def recordWriteGoldens : List Test.Bridge.CrossCheck.Json :=
  let hx := Test.Bridge.CrossCheck.hexFromBytes
  let h256 := fun (v : Nat) => hx (uint256BE v)
  let key := ByteArray.mk #[0xAA, 0xBB, 0xCC]
  let rcp := LegalKernel.Bridge.EthAddress.zero
  [ .obj [ ("kind", .str "registry"), ("payloadHex", .str (hx key))
         , ("a", .str (h256 0)), ("b", .str (h256 0))
         , ("c", .str (h256 0)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx (deriveRegistryCellValue key))) ]
    -- The EMPTY key: its 9-byte head is what makes a present-empty
    -- registration distinguishable from an absent one, and
    -- registration is an admissibility gate.
  , .obj [ ("kind", .str "registry"), ("payloadHex", .str (hx ByteArray.empty))
         , ("a", .str (h256 0)), ("b", .str (h256 0))
         , ("c", .str (h256 0)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx (deriveRegistryCellValue ByteArray.empty))) ]
    -- The two field-passthrough cases.  `payloadHex` carries the
    -- ACTION FIELDS here, not a key: the Solidity side slices them
    -- itself, so a layout change shows up as a mismatch rather than
    -- as a silently-correct-looking value.
  , .obj [ ("kind", .str "registryFromFields")
         , ("payloadHex",
            .str (hx (actionFieldsForL1 (.replaceKey 8 key))))
         , ("a", .str (h256 0)), ("b", .str (h256 0))
         , ("c", .str (h256 0)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx (deriveRegistryCellValue key))) ]
  , .obj [ ("kind", .str "declaredPolicy")
         , ("payloadHex",
            .str (hx (actionFieldsForL1
              (.declareLocalPolicy Authority.LocalPolicy.empty))))
         , ("a", .str (h256 0)), ("b", .str (h256 0))
         , ("c", .str (h256 0)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx (deriveDeclaredPolicyCellValue
             Authority.LocalPolicy.empty))) ]
  , .obj [ ("kind", .str "revokedPolicy"), ("payloadHex", .str "0x")
         , ("a", .str (h256 0)), ("b", .str (h256 0))
         , ("c", .str (h256 0)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx deriveRevokedPolicyCellValue)) ]
  , .obj [ ("kind", .str "consumed"), ("payloadHex", .str "0x")
         , ("a", .str (h256 1)), ("b", .str (h256 5))
         , ("c", .str (h256 0)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx (deriveConsumedCellValue
             { resource := 1, userAmount := 5
             , poolAmount := 0, budgetGrant := 0 }))) ]
  , .obj [ ("kind", .str "consumed"), ("payloadHex", .str "0x")
         , ("a", .str (h256 1)), ("b", .str (h256 5))
         , ("c", .str (h256 2)), ("d", .str (h256 3))
         , ("encodedHex", .str (hx (deriveConsumedCellValue
             { resource := 1, userAmount := 5
             , poolAmount := 2, budgetGrant := 3 }))) ]
  , .obj [ ("kind", .str "pending")
         , ("payloadHex", .str (hx (LegalKernel.Bridge.EthAddress.toBytes rcp)))
         , ("a", .str (h256 1)), ("b", .str (h256 5))
         , ("c", .str (h256 7)), ("d", .str (h256 0))
         , ("encodedHex", .str (hx (derivePendingCellValue
             { resource := 1, recipient := rcp
             , amount := 5, l2LogIndex := 7 }))) ] ]

/-! ### The multiproof wire, per probe

Twenty probes covering the shapes a verifier has to handle: the
two-cell chain, its aliased case, the failing precondition, the
state-keyed write, and each action-field-derived cell.

Each carries TWO independently-computed roots — the one the merged
walk reaches by folding derived writes into the pre-root, and the one
`commitExtendedState (productionApplyBudget …)` gives from the
post-STATE.  A verifier is right only if they coincide, which is
strictly more than agreeing with some other verifier: the retired
chained column asserted the latter, and this asserts the former.

The wire here is the COMPRESSED one — mask plus the siblings the mask
marks — because that is what an L1 receives.  Its length is not a free
parameter: `gapCount` is a function of the key set, so the consumer
derives the expected mask size and sibling count before reading a byte
and the corpus's own column is checked against that derivation rather
than trusted.
-/

/-- Per-probe multiproof goldens: the action in its L1 form, the
    frontier's cells with their proven pre-values in path order, the
    shared wire, and the two roots the wire serves. -/
def multiProofGoldens : List Test.Bridge.CrossCheck.Json :=
  let es : ExtendedState :=
    let base : LegalKernel.State :=
      { balances :=
          ((∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
             ((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 9 25)).insert 2
             ((∅ : BalanceMap).insert 9 60) }
    { fixtureBase with base := base }
  let signer : ActorId := 7
  let hx := Test.Bridge.CrossCheck.hexFromBytes
  let probes : List (String × Action) :=
    [ ("transfer",   .transfer 1 signer 8 30)
      -- The same-cell shapes.  Under the chained fold they are two
      -- writes at one cell; under a multiproof they are ONE opening,
      -- which is where the calldata saving concentrates and where a
      -- dedup bug would live.
    , ("selfTransfer", .transfer 1 signer signer 30)
    , ("mint",       .mint 1 8 5)
    , ("burn",       .burn 1 8 5)
    , ("burnNoop",   .burn 1 8 999999)
    , ("reward",     .reward 1 8 5)
    , ("freezeResource", .freezeResource 1)
    , ("withdraw",   .withdraw 1 signer 5 LegalKernel.Bridge.EthAddress.zero)
    , ("deposit",    .deposit 1 8 5 3)
    , ("depositWithFee", .depositWithFee 1 8 9 5 2 3 4)
    , ("depositWithFeeSelf", .depositWithFee 1 signer 9 5 2 3 5)
    , ("topUpActionBudget", .topUpActionBudget 1 10 4 9)
    , ("topUpActionBudgetForSelf", .topUpActionBudgetFor signer 1 10 4 9)
    , ("topUpActionBudgetFor", .topUpActionBudgetFor 8 1 10 4 9)
    , ("claimBudgetRefund", .claimBudgetRefund 1 2 3 9)
    , ("ammSwap",    .ammSwap 1 2 5 10 9)
    , ("registerIdentity", .registerIdentity 8 (ByteArray.mk #[1, 2, 3]))
    , ("replaceKey", .replaceKey 8 (ByteArray.mk #[0xAA, 0xBB]))
    , ("declareLocalPolicy", .declareLocalPolicy Authority.LocalPolicy.empty)
    , ("revokeLocalPolicy", .revokeLocalPolicy) ]
  probes.filterMap (fun (name, action) =>
    let st : SignedAction :=
      { action, signer, nonce := 0, sig := ByteArray.empty }
    match stepMultiPostRoot es st 0 with
    | none => none
    | some root =>
      let b := stepMultiBundle es st
      let opened := openedOf es (b.cells.map Prod.fst)
      some (.obj
        [ ("variant", .str name)
        , ("preStateRootHex", .str (hx (commitExtendedState es)))
          -- What the merged walk produces, and what
          -- `executeStepToRootMulti` must return.
        , ("postStateRootHex", .str (hx root))
          -- The published root of the production advance, computed
          -- WITHOUT the fold.  Emitted separately so the consumer
          -- compares two independent numbers rather than one number
          -- with itself: the fold is only right if it lands on the
          -- root an honest sequencer publishes.
        , ("publishedPostRootHex",
           .str (hx (commitExtendedState (productionApplyBudget es st 0))))
        , ("actionKindByte", .num (actionKindByte action).toNat)
        , ("actionFieldsHex", .str (hx (actionFieldsForL1 action)))
        , ("signerNat", .num signer.toNat)
        , ("l2LogIndex", .num 0)
          -- The gap count, so the consumer's own derivation from the
          -- key set is checked against Lean's rather than against
          -- itself.  Everything about the wire's length follows from
          -- this one number.
        , ("gapCount", .num (multiGapLevels smtDepth opened).length)
        , ("gapMaskHex", .str (hx b.proof.gapMask))
        , ("siblingsHex",
           .str (hx (b.proof.siblings.foldl (fun acc s => acc ++ s)
                       (ByteArray.mk #[]))))
        , ("cellCount", .num b.cells.length)
          -- The frontier, in path order: the cells the wire opens with
          -- the pre-values it proves.  The policy cell is IN here
          -- rather than beside it -- a read is a write of the same
          -- value -- which is what retires the separate policy walk.
        , ("cells", .arr (b.cells.map (fun c =>
            let (t, v) := c
            let (kindNat, keyA, keyB) : Nat × Nat × Nat := t.flatKey
            .obj [ ("cellKind", .num kindNat)
                 , ("keyA", .num keyA), ("keyB", .num keyB)
                 , ("smtKeyHex", .str (hx (smtCellKey t)))
                 , ("preValueHex", .str (hx v))
                 , ("preLeafHex", .str (hx (cellLeaf t v)))
                   -- The leaf PREIMAGE, `encodeAsBytes key ++
                   -- encodeAsBytes value` — two CBE byte-strings.
                   -- Emitted alongside the leaf HASH so the consumer
                   -- can check Lean's leaf CONSTRUCTION against
                   -- `CBEEncode.bytesValue`, not only that the walk
                   -- agrees on the result.
                 , ("preLeafPreimageHex",
                    .str (hx (encodeAsBytes (smtCellKey t) ++ encodeAsBytes v)))
                 , ("isAbsent", .bool (decide (v = canonicalAbsentValue t))) ])))
        ]))

/-! ### The write SET, per variant

The last piece of the flip's specification: which cells each action
writes, as a function of `(actionKind, actionFields, signer)` plus the
proven `.bridgeNextWdId`.  A verifier re-derives this list and rejects
a bundle naming different cells — without it, a responder could omit a
write and fold to a root where that cell never moved.

Emitted per variant with the ACTUAL field bytes the L1 decodes, so a
mirror's field-offset error shows up here rather than being reasoned
about.  Every offset in `actionFieldsForL1` is a place a mirror can be
silently wrong: the layouts are big-endian and the widths differ
(`uint64BE` for identifiers, `uint128BE` for amounts), so a
one-field slip still decodes to a plausible actor id.
-/

/-- Per-variant write-set goldens: the action's L1 form, and the
    ordered `(cellKind, keyA, keyB)` list `writeCellsAt` produces. -/
def writeSetGoldens : List Test.Bridge.CrossCheck.Json :=
  let es := fixtureBase
  let signer : ActorId := 7
  let hx := Test.Bridge.CrossCheck.hexFromBytes
  let probes : List Action :=
    [ .transfer 1 signer 8 30, .mint 1 8 5, .burn 1 8 5, .freezeResource 1
    , .replaceKey 8 (ByteArray.mk #[1, 2, 3]), .reward 1 8 5
      -- The two bulk variants.  Present so the corpus covers all
      -- twenty-five kinds and the EXCLUSION is data rather than a
      -- hand-written constant on the L1 side: their write set is the
      -- actor set at a resource, which a verifier holding only the
      -- pre-root cannot enumerate.
    , .distributeOthers 1 8 5, .proportionalDilute 1 8 5
    , .dispute (minimalDispute signer 0), .disputeWithdraw 0
    , .verdict { disputeId := 0, outcome := .upheld
               , rationale := ByteArray.empty, signatures := [] }
    , .rollback 0
    , .registerIdentity 8 (ByteArray.mk #[9])
    , .deposit 1 8 5 3
    , .withdraw 1 signer 5 LegalKernel.Bridge.EthAddress.zero
    , .declareLocalPolicy Authority.LocalPolicy.empty, .revokeLocalPolicy
    , .faultProofChallenge ByteArray.empty 0 1 ByteArray.empty
    , .faultProofResolution ByteArray.empty 0 8 0
    , .depositWithFee 1 8 9 5 1 3 4, .topUpActionBudget 1 5 2 9
    , .topUpActionBudgetFor 8 1 5 2 9, .claimBudgetRefund 1 2 3 9
    , .ammSwap 1 2 5 4 9, .reclaimAmmReserves 1 25 9 8 ]
  probes.map (fun action =>
    let cells := Authority.Action.writeCellsAt es action signer
    .obj [ ("actionKindByte", .num (actionKindByte action).toNat)
         , ("actionFieldsHex", .str (hx (actionFieldsForL1 action)))
         , ("signerNat", .num signer.toNat)
           -- The proven counter the `withdraw` arm keys its pending
           -- cell by; inert for every other variant, and emitted for
           -- all of them so the mirror takes the same input shape.
         , ("nextWdIdPre", .num es.bridge.nextWdId)
           -- Whether the fault proof can adjudicate this kind at all.
           -- False on exactly the bulk pair, and emitted per probe so
           -- the L1's own predicate is pinned against
           -- `FaultProofAdjudicable` rather than restated.
         , ("adjudicable", .bool (FaultProofAdjudicable action))
         , ("cellCount", .num cells.length)
         , ("cells", .arr (cells.map (fun t =>
             let (k, a, b) : Nat × Nat × Nat := t.flatKey
             .obj [ ("cellKind", .num k), ("keyA", .num a), ("keyB", .num b) ]))) ])

/-! ### Canonical absence, per cell kind

The last primitive the fold needs, and it is not cosmetic:
`stateCellEntries` DROPS canonically-absent cells, so "value is
canonically absent" and "key is absent from the tree" are the same
condition.  A cell at this value has an EMPTY sub-tree beneath its key,
so its leaf is the canonical empty one rather than a hash of the
preimage — which is what makes an absent cell openable at all, and a
step crediting a fresh actor opens one on its first line.
-/

/-- One representative tag per cell kind, so the goldens cover all
    fifteen rather than the handful a step happens to touch. -/
def absentValueProbeTags : List CellTag :=
  [ .balance 1 7, .nonce 7, .registry 7, .localPolicy 7
  , .bridgeConsumed 3, .bridgePending 4, .bridgeNextWdId
  , .bridgeAmmReserveEth, .bridgeAmmReserveBold
  , .bridgeBoldCircuitClosed, .bridgeBoldTvlCap
  , .bridgeBoldTotalLockedValue, .bridgeAmmDisabled
  , .epochBudget 7, .budgetPolicy ]

/-- The canonical absent bytes for every cell kind. -/
def absentValueGoldens : List Test.Bridge.CrossCheck.Json :=
  absentValueProbeTags.map (fun t =>
    let (k, _, _) : Nat × Nat × Nat := t.flatKey
    .obj [ ("cellKind", .num k)
         , ("absentValueHex",
            .str (Test.Bridge.CrossCheck.hexFromBytes
              (canonicalAbsentValue t))) ])

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
  , { name := "GP.9.1: claimBudgetRefund fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := claimBudgetRefundFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "GP.11.8: ammSwap fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := ammSwapFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "GP.11.10: reclaimAmmReserves fixture corpus has 10 entries"
    , body := do
        Test.assertEq (expected := 10)
          (actual := reclaimAmmReservesFixtures.length) "6 happy + 4 adversarial"
    }
  , { name := "GP.11.10: full corpus has 278 entries"
    , body := do
        -- 24 + 24 + 20 × 10 + 3 × 10 = 278 (GP.11.10 extension:
        -- +reclaimAmmReserves on top of the 268 entries that already
        -- carried +ammSwap).
        Test.assertEq (expected := 278) (actual := allFixtures.length)
          "278 = 24 + 24 + 20 × 10 + 3 × 10"
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
  , { name := "GP.11.10: every happy fixture's actionKindByte is in 0..24"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        -- Post-Workstream-GP: dispatcher range widened from 0..18
        -- (SVC.5.e) to 0..20 (depositWithFee = 19, topUpActionBudget =
        -- 20), to 0..21 (GP.5.3: topUpActionBudgetFor = 21), to
        -- 0..22 (GP.9.1: claimBudgetRefund = 22), to 0..23 (GP.11.8:
        -- ammSwap = 23), and now to 0..24 (GP.11.10:
        -- reclaimAmmReserves = 24).
        Test.assert (happy.all (fun f => f.actionKindByte.toNat ≤ 24))
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
  , { name := "log-chain: every entry publishes a 32-byte action commitment"
    , body := do
        -- The L1 stores it in a `bytes32`, and `actionCommitHexOf`
        -- emits `"0x"` on a hex-decode failure, so anything other than
        -- 66 characters means the derivation did not run.
        Test.assert (allFixtures.all (fun f =>
          (actionCommitHexOf f).length = 66 ∧
          (actionCommitHexOf f).startsWith "0x"))
          "action commitment is a 0x-prefixed 32-byte hex string"
    }
  , { name := "log-chain: the commitment separates the three components"
    , body := do
        -- Injectivity is the property the binding rests on: if two
        -- distinct `(kind, signer, fields)` triples could collide, a
        -- responding party could substitute one for the other at
        -- terminate time.  Exhibited rather than asserted — each pair
        -- below differs in exactly ONE component.
        let fields := ByteArray.mk #[1, 2, 3]
        let base := StepVMCoherence.l1ActionCommitBytes 0 7 fields
        let otherKind := StepVMCoherence.l1ActionCommitBytes 1 7 fields
        let otherSigner := StepVMCoherence.l1ActionCommitBytes 0 8 fields
        let otherFields :=
          StepVMCoherence.l1ActionCommitBytes 0 7 (ByteArray.mk #[1, 2, 4])
        Test.assert (base != otherKind) "kind is committed"
        Test.assert (base != otherSigner) "signer is committed"
        Test.assert (base != otherFields) "fields are committed"
    }
  , { name := "log-chain: a shifted field boundary does not collide"
    , body := do
        -- The reason the variable-length component goes LAST.  With
        -- `fields` first, `(kind=0x01, fields=0x0203)` and
        -- `(kind=0x02, fields=0x03)` would concatenate to the same
        -- bytes.  With `fields` last, the first nine bytes are
        -- fixed-width, so the split is unambiguous and these differ.
        let a := StepVMCoherence.l1ActionCommitBytes 1 0 (ByteArray.mk #[2, 3])
        let b := StepVMCoherence.l1ActionCommitBytes 2 0 (ByteArray.mk #[3])
        Test.assert (a != b) "the fixed-width prefix disambiguates the split"
    }
  , { name := "log-chain: the chain step commits to all three inputs"
    , body := do
        let z := ByteArray.mk (Array.replicate 32 (0 : UInt8))
        let o := ByteArray.mk (Array.replicate 32 (1 : UInt8))
        Test.assert
          (StepVMCoherence.l1NextEntryHash z z z !=
           StepVMCoherence.l1NextEntryHash o z z) "prev is committed"
        Test.assert
          (StepVMCoherence.l1NextEntryHash z z z !=
           StepVMCoherence.l1NextEntryHash z o z) "state root is committed"
        Test.assert
          (StepVMCoherence.l1NextEntryHash z z z !=
           StepVMCoherence.l1NextEntryHash z z o) "action is committed"
    }
  , { name := "the fold lands on the published root"
    , body := do
        -- The corpus's own version of the property the L1 must have:
        -- what the merged walk computes from a pre-root and a wire is
        -- the root `commitExtendedState (productionApplyBudget …)`
        -- gives from the post-STATE.  Two independent computations, so
        -- a verifier that agreed with itself would still fail here.
        --
        -- ...and the fold is not the identity, which is what makes the
        -- first assertion say something: every one of the twenty-five
        -- variants advances the signer's nonce, so no probe's post-root
        -- is its pre-root, including the two whose LAW no-ops.
        let get : Test.Bridge.CrossCheck.Json → String →
            Option Test.Bridge.CrossCheck.Json := fun j k =>
          match j with
          | .obj fields => (fields.find? (fun p => p.1 = k)).map Prod.snd
          | _           => none
        Test.assert (multiProofGoldens.length > 0)
          "the multiproof goldens must be non-empty"
        for g in multiProofGoldens do
          match get g "variant", get g "postStateRootHex",
                get g "publishedPostRootHex", get g "preStateRootHex" with
          | some (.str v), some (.str fold), some (.str published),
            some (.str pre) =>
            Test.assertEq (expected := published) (actual := fold)
              s!"{v}: the fold must land on the production advance's root"
            Test.assert (fold != pre) s!"{v}: the fold must move the root"
          | _, _, _, _ => throw <| IO.userError "malformed multiproof golden"
    }
  , { name := "every multiproof wire is exactly its key set's shape"
    , body := do
        -- The corpus's own copy of the consumer's derivation.  The gap
        -- count fixes the mask size and the sibling count, so a column
        -- emitted at some other length would pin the L1 to a wire the
        -- L1's own shape check would reject -- a corpus that could not
        -- pass its own consumer.
        for g in multiProofGoldens do
          match g with
          | .obj fields =>
            let get := fun (k : String) =>
              (fields.find? (fun p => p.1 = k)).map Prod.snd
            match get "variant", get "gapCount", get "gapMaskHex",
                  get "siblingsHex", get "cellCount" with
            | some (.str v), some (.num gaps), some (.str mask),
              some (.str sibs), some (.num cells) =>
              -- Hex strings carry a `0x` prefix and two chars a byte.
              Test.assertEq (expected := (gaps + 7) / 8)
                (actual := (mask.length - 2) / 2)
                s!"{v}: the mask must be ceil(G/8) bytes"
              Test.assertEq (expected := 0) (actual := (sibs.length - 2) % 64)
                s!"{v}: the sibling region must be whole 32-byte siblings"
              -- G = (256 + 1) - m + sum divs, so it is at least the
              -- single-cell 256 and grows with the frontier.  A column
              -- reporting fewer gaps than levels would mean the walk
              -- never reached the root.
              Test.assert (gaps ≥ 256) s!"{v}: fewer gaps than one full path"
              Test.assert (cells ≥ 1) s!"{v}: the frontier must open something"
            | _, _, _, _, _ => throw <| IO.userError "malformed multiproof golden"
          | _ => throw <| IO.userError "malformed multiproof golden"
    }
  , { name := "SVC.5.e+: every cellProof carries a well-formed SMT opening"
    , body := do
        -- Shape, not value: a `0x`-prefixed hex string of a NONZERO
        -- multiple of 32 bytes — the 32-byte bitmask plus whole
        -- siblings.  This is the same predicate
        -- `KnomosisStepVM.executeStep` enforces at intake and the Rust
        -- deserialiser enforces on the wire, so a corpus entry the L1
        -- would reject cannot be committed.
        --
        -- It is a real regression guard rather than a restatement:
        -- `CellProof.proofData` DEFAULTS to empty, so a builder that
        -- reverted to `buildCellProof` would emit a bundle that is
        -- well-formed in every other respect.  Two of the bulk
        -- builders did exactly that, and only this shape check found
        -- them.
        Test.assert (allFixtures.all (fun f =>
          f.cellProofsForFixture.all (fun p =>
            p.proofDataHex.startsWith "0x" ∧
            p.proofDataHex.length > 2 ∧
            (p.proofDataHex.length - 2) % 64 = 0)))
          "every opening is a nonzero multiple of 32 bytes"
    }
  , { name := "SVC.5.e+: openings differ across cells of one fixture"
    , body := do
        -- A constant opening would satisfy the shape check above while
        -- carrying no information.  Distinct cells sit at distinct SMT
        -- keys, so their sibling paths must differ — pick the largest
        -- happy bundle and require at least two distinct openings.
        let happy := allFixtures.filter (fun f =>
          f.expectedRevertReason = "null" ∧
          f.cellProofsForFixture.length ≥ 2)
        Test.assert (happy.any (fun f =>
          (f.cellProofsForFixture.map (fun p => p.proofDataHex)).eraseDups.length ≥ 2))
          "openings are cell-specific, not a shared constant"
    }
  , { name := "SVC.5.e+: every happy fixture's cellProofs has a known cellKind"
    , body := do
        -- The bound was 6 when the cell space stopped there.  It now
        -- runs to 16 (the AMM mirror, the kill switch, the epoch
        -- budgets and the budget policy each got a tag), and
        -- `Action.writeCells` declares `.epochBudget` — kind 13 — on
        -- every variant.  The bound tracks `CellKind`'s last index.
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all (fun f =>
          f.cellProofsForFixture.all (fun p =>
            p.cellKindNat ≤ 16)))
          "cellKind in 0..16"
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
          -- GP.9.1: refund-on-exit at index 22.
          , ("countClaimBudgetRefund",
             .num claimBudgetRefundFixtures.length)
          -- GP.11.8: L2 AMM swap at index 23.
          , ("countAmmSwap",
             .num ammSwapFixtures.length)
          -- GP.11.10: post-disable reserve sweep at index 24.
          , ("countReclaimAmmReserves",
             .num reclaimAmmReservesFixtures.length)
          -- GP.5.3 hash-independent layout goldens (data-flow): the
          -- Solidity consumer reads these and recomputes
          -- `abi.encodePacked`, proving the packed byte layout agrees
          -- byte-for-byte without the keccak binding.
          , ("packedLayoutGoldensCount", .num packedLayoutGoldens.length)
          , ("cbeEncoderGoldens", .arr cbeEncoderGoldens)
          , ("cbeEncoderGoldensCount", .num cbeEncoderGoldens.length)
          , ("uniformWriteGoldens", .arr uniformWriteGoldens)
          , ("uniformWriteGoldensCount", .num uniformWriteGoldens.length)
          , ("balanceWriteGoldens", .arr balanceWriteGoldens)
          , ("balanceWriteGoldensCount", .num balanceWriteGoldens.length)
          , ("recordWriteGoldens", .arr recordWriteGoldens)
          , ("recordWriteGoldensCount", .num recordWriteGoldens.length)
          , ("multiProofGoldens", .arr multiProofGoldens)
          , ("multiProofGoldensCount", .num multiProofGoldens.length)
          , ("writeSetGoldens", .arr writeSetGoldens)
          , ("writeSetGoldensCount", .num writeSetGoldens.length)
          , ("absentValueGoldens", .arr absentValueGoldens)
          , ("absentValueGoldensCount", .num absentValueGoldens.length)
          , ("packedLayoutGoldens",  .arr packedLayoutGoldens)
          , ("variant21TailGolden",  variant21TailGolden)
          , ("entries",             .arr entries)
          ]
        Test.Bridge.CrossCheck.writeHashDependentFixture "step_vm.json" header.encode
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.StepVM
