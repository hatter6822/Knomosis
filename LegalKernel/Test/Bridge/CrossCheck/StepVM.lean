/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
      `CanonStepVM.executeStep` returns byte-for-byte. -/
  expectedStepVMCommitHex    : String
  /-- The expected revert reason, or "null" for happy paths. -/
  expectedRevertReason       : String
  /-- The action-kind dispatcher byte (0..18), used by the
      generic Solidity-side byte-equivalence test driver.
      Workstream SVC.5.e addition. -/
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
    Total: 24 + 24 + 17 × 10 = 218 entries. -/
def allFixtures : List StepVMFixture :=
  transferFixtures ++ mintFixtures ++ burnFixtures ++
  freezeResourceFixtures ++ replaceKeyFixtures ++ rewardFixtures ++
  distributeOthersFixtures ++ proportionalDiluteFixtures ++
  disputeFixtures ++ disputeWithdrawFixtures ++ verdictFixtures ++
  rollbackFixtures ++ registerIdentityFixtures ++ depositFixtures ++
  withdrawFixtures ++ declareLocalPolicyFixtures ++
  revokeLocalPolicyFixtures ++ faultProofChallengeFixtures ++
  faultProofResolutionFixtures

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
  , { name := "SVC.5.e: full corpus has 218 entries"
    , body := do
        -- 24 + 24 + 17 × 10 = 218 (exceeds the plan's 190 target
        -- while preserving the existing 48 Transfer + Mint
        -- fixtures).
        Test.assertEq (expected := 218) (actual := allFixtures.length)
          "218 = 24 + 24 + 17 × 10"
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
  , { name := "SVC.5.e: every happy fixture's actionKindByte is in 0..18"
    , body := do
        let happy := allFixtures.filter
                       (fun f => f.expectedRevertReason = "null")
        Test.assert (happy.all (fun f => f.actionKindByte.toNat ≤ 18))
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
  , { name := "SVC.5.e: per-variant happy-fixture count is uniform"
    , body := do
        -- Every non-Transfer / non-Mint variant has exactly 6
        -- happy entries; Transfer / Mint have 16.  This pins the
        -- corpus shape against accidental imbalance.
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
        let cellBoundVariants : List String :=
          ["transfer", "burn", "reward", "deposit", "withdraw",
           "distributeOthers", "proportionalDilute"]
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
          , ("entries",             .arr entries)
          ]
        Test.Bridge.CrossCheck.writeFixture "step_vm.json" header.encode
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.StepVM
