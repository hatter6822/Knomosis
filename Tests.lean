-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Tests — root of the `lake test` driver.

Imports every test module, runs them in sequence, and exits non-zero
if any test failed.  The test driver is wired to this binary via
`@[test_driver]` in `lakefile.lean`.

Suite history:

* Phase 0 — kernel-level (12 cases), umbrella-level, and transfer-law
  tests.  Wired the test framework.
* Phase 1 — added the `RBMapLemmasTests` suite for §8.3 fold lemmas
  plus extra `KernelTests` cases for the §4.3 balance lemmas (WU 1.5)
  and §4.9 multi-step / law-set reachability (WU 1.7 – 1.8).
* Phase 2 — added the `ConservationTests` suite for `TotalSupply`,
  `IsConservative`, `ConservativeLawSet`, and `total_supply_global`;
  plus per-law suites for `mint`, `burn`, and `freezeResource` (with
  the `FrozenForResource` invariant).  Extended the existing
  `TransferTests` suite with `transfer_conserves` and the
  `IsConservative` instance check.
* Phase 3 — added the `Authority.{Action, Identity, Nonce, SignedAction}`
  suites covering the §4.13 Action layer, the §8.2
  `AuthorityPolicy` / `KeyRegistry`, the §8.5 `expectsNonce` /
  `advanceNonce` machinery, and the headline §8.5.2
  `nonce_uniqueness` / `replay_impossible` theorems plus the
  WU 3.10 `replaceKey` rotation chain.

Later phases will append modules here as new laws and invariants
land.
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.KernelTests
import LegalKernel.Test.RBMapLemmasTests
import LegalKernel.Test.Umbrella
import LegalKernel.Test.ConservationTests
import LegalKernel.Test.Laws.Transfer
import LegalKernel.Test.Laws.Mint
import LegalKernel.Test.Laws.Burn
import LegalKernel.Test.Laws.Freeze
import LegalKernel.Test.Laws.Reward
import LegalKernel.Test.Laws.DistributeOthers
import LegalKernel.Test.Laws.ProportionalDilute
import LegalKernel.Test.Laws.Deposit
import LegalKernel.Test.Laws.Withdraw
import LegalKernel.Test.Laws.DepositWithFee
import LegalKernel.Test.Laws.TopUpActionBudget
import LegalKernel.Test.Laws.AmmSwap
import LegalKernel.Test.Laws.ReclaimAmmReserves
import LegalKernel.Test.Authority.Action
import LegalKernel.Test.Authority.Identity
import LegalKernel.Test.Authority.LocalPolicy
import LegalKernel.Test.Authority.LocalPolicyAdmissibility
import LegalKernel.Test.Authority.Nonce
import LegalKernel.Test.Authority.ActorBudget
import LegalKernel.Test.Authority.SignedAction
import LegalKernel.Test.Authority.SignedActionHappyPath
import LegalKernel.Test.Authority.SignedActionBudget
import LegalKernel.Test.Authority.DelegatedTopup
import LegalKernel.Test.MockCrypto
import LegalKernel.Test.Property
import LegalKernel.Test.Properties.Encoding
import LegalKernel.Test.Properties.Bridge
import LegalKernel.Test.Properties.LocalPolicy
import Lex.Test.Properties
import Lex.Test.AutoGenProperties
import LegalKernel.Test.Encoding.CBOR
import LegalKernel.Test.Encoding.Encodable
import LegalKernel.Test.Encoding.Action
import LegalKernel.Test.Encoding.Event
import LegalKernel.Test.Encoding.SignedAction
import LegalKernel.Test.Encoding.State
import LegalKernel.Test.Encoding.SignInput
import LegalKernel.Test.Encoding.Disputes
import LegalKernel.Test.Encoding.LocalPolicy
import LegalKernel.Test.Encoding.Injectivity
import LegalKernel.Test.LocalPolicy.LawClassification
import LegalKernel.Test.DSL.Law
import Lex.Test.DSL.Law
import Lex.Test.DSL.ImplLowering
import Lex.Test.DSL.Property
import Lex.Test.Tools.Common
import Lex.Test.Tools.Codegen
import Lex.Test.Tools.Diff
import Lex.Test.Tools.Format
import Lex.Test.Tools.DiagnosticCoverage
import Lex.Test.DSL.Deployment
import LegalKernel.Test.Deployments.UsdClearing
import LegalKernel.Test.Deployments.GasPoolExample
import Lex.Test.ExampleLex
import Lex.Test.M2
import LegalKernel.Test.Events.Types
import LegalKernel.Test.Events.Extract
import LegalKernel.Test.Runtime.Hash
import LegalKernel.Test.Runtime.LogFile
import LegalKernel.Test.Runtime.Replay
import LegalKernel.Test.Runtime.Snapshot
import LegalKernel.Test.Runtime.AttestedSnapshot
import LegalKernel.Test.Runtime.Loop
import LegalKernel.Test.Runtime.LoopHappyPath
import LegalKernel.Test.Runtime.BudgetSidecar
import LegalKernel.Test.Runtime.GasPoolSidecar
import LegalKernel.Test.Runtime.RefundRateSidecar
import LegalKernel.Test.Runtime.BridgeAdmission
import LegalKernel.Test.Runtime.ExtractEvents
import LegalKernel.Test.Disputes.Filing
import LegalKernel.Test.Disputes.Evidence
import LegalKernel.Test.Disputes.Verdict
import LegalKernel.Test.Disputes.EndToEnd
import LegalKernel.Test.Disputes.LawClassification
import LegalKernel.Test.Disputes.MonotonicDeployment
import LegalKernel.Test.Disputes.Rewards
import LegalKernel.Test.Disputes.Staking
import LegalKernel.Test.Disputes.IncentivizedEndToEnd
import LegalKernel.Test.Disputes.WitnessHelpers
import LegalKernel.Test.Bridge.VerifyAdaptor
import LegalKernel.Test.Bridge.HashAdaptor
import LegalKernel.Test.Bridge.Eip712
import LegalKernel.Test.Bridge.AddressBook
import LegalKernel.Test.Bridge.BridgeActor
import LegalKernel.Test.Bridge.AmmMath
import LegalKernel.Test.Bridge.GasPoolPolicy
import LegalKernel.Test.Bridge.AmmReservePolicy
import LegalKernel.Test.Bridge.PoolDrainBound
import LegalKernel.Test.Bridge.BudgetRefund
import LegalKernel.Test.Bridge.Ingest
import LegalKernel.Test.Bridge.State
import LegalKernel.Test.Bridge.Admissible
import LegalKernel.Test.Bridge.Accounting
import LegalKernel.Test.Bridge.WithdrawalRoot
import LegalKernel.Test.Bridge.WithdrawalProof
import LegalKernel.Test.Bridge.WithdrawalProofCLI
import LegalKernel.Test.Bridge.Finalisation
import LegalKernel.Test.Bridge.WithdrawalRootGoldens
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Bridge.CrossCheck.EcdsaVerify
import LegalKernel.Test.Bridge.CrossCheck.Keccak256
import LegalKernel.Test.Bridge.CrossCheck.DepositReceiptHash
import LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplit
import LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplitBold
import LegalKernel.Test.Bridge.CrossCheck.DepositWithFeeAction
import LegalKernel.Test.Bridge.CrossCheck.BoldDeposit
import LegalKernel.Test.Bridge.CrossCheck.AmmMath
import LegalKernel.Test.Bridge.CrossCheck.AmmSwap
import LegalKernel.Test.Bridge.CrossCheck.EventCbe
import LegalKernel.Test.Bridge.CrossCheck.WithdrawalProof
import LegalKernel.Test.Bridge.CrossCheck.DisputeEvidence
import LegalKernel.Test.Bridge.CrossCheck.MigrationAttestation
import LegalKernel.Test.Bridge.CrossCheck.Goldens
-- Workstream H — fault-proof migration test suites.
import LegalKernel.Test.FaultProof.Cell
import LegalKernel.Test.FaultProof.Smt
import LegalKernel.Test.FaultProof.Commit
import LegalKernel.Test.FaultProof.AmmCommit
import LegalKernel.Test.FaultProof.Step
import LegalKernel.Test.FaultProof.Game
import LegalKernel.Test.FaultProof.LawClassification
import LegalKernel.Test.FaultProof.Encoding
import LegalKernel.Test.FaultProof.EventEmission
import LegalKernel.Test.FaultProof.Witness
import LegalKernel.Test.FaultProof.Verify
import LegalKernel.Test.FaultProof.Trust
import LegalKernel.Test.FaultProof.PerVariantCoherence
import LegalKernel.Test.FaultProof.EncodeInjectivity
import LegalKernel.Test.FaultProof.AbsentCellCreation
import LegalKernel.Test.FaultProof.GameTransitionEdgeCases
import LegalKernel.Test.FaultProof.SolidityStepVMCommit
import LegalKernel.Test.FaultProof.Transcript
import LegalKernel.Test.FaultProof.Coherence
import LegalKernel.Test.FaultProof.Settlement
import LegalKernel.Test.FaultProof.MigrationFreeze
import LegalKernel.Test.Bridge.CrossCheck.StepVM
import LegalKernel.Test.Bridge.CrossCheck.BisectionGame
import LegalKernel.Test.Bridge.CrossCheck.FaultProofScenarios
import LegalKernel.Test.Bridge.CrossCheck.SmtCellProof
import LegalKernel.Test.Bridge.CrossCheck.ObserverGameTraces
import LegalKernel.Test.Properties.FaultProof
import LegalKernel.Test.Properties.FaultProofExtended
import LegalKernel.Test.Properties.FaultProofDeep
-- AR.23: end-to-end integration regression suite.
import LegalKernel.Test.Integration.CrossDeployment
import LegalKernel.Test.Integration.SnapshotBootstrap
import LegalKernel.Test.Integration.AttestedSnapshotCli
import LegalKernel.Test.Integration.ReplayUpToCli
import LegalKernel.Test.Integration.ExportCellProofsCli
import LegalKernel.Test.Integration.ExportTerminateBundleCli
-- Workstream SVC (step-VM cross-stack coherence).
import LegalKernel.Test.FaultProof.StepVMCoherence
import LegalKernel.Test.FaultProof.TerminateBundle

open LegalKernel.Test

-- The `maxRecDepth` bump is necessary because the long chain of
-- `failed := failed + (← runAll …)` statements exceeds Lean's
-- default elaboration recursion limit when Phase 6 / Workstreams
-- LP and LX add their suites.  An alternative would be to split
-- the chain into multiple `def`s, but the linear-chain form is
-- clearer and the bump is harmless.
set_option maxRecDepth 1024

/-- Test-driver entry point.  Returns `0` when every suite passes,
    `1` when any test fails. -/
def main : IO UInt32 := do
  let mut failed : Nat := 0
  failed := failed + (← runAll "kernel"             KernelTests.tests)
  failed := failed + (← runAll "rbmap"              RBMapLemmasTests.tests)
  failed := failed + (← runAll "umbrella"           Umbrella.tests)
  failed := failed + (← runAll "conservation"       ConservationTests.tests)
  failed := failed + (← runAll "transfer"           Laws.TransferTests.tests)
  failed := failed + (← runAll "mint"               Laws.MintTests.tests)
  failed := failed + (← runAll "burn"               Laws.BurnTests.tests)
  failed := failed + (← runAll "freeze"             Laws.FreezeTests.tests)
  failed := failed + (← runAll "reward"              Laws.RewardTests.tests)
  failed := failed + (← runAll "distributeOthers"    Laws.DistributeOthersTests.tests)
  failed := failed + (← runAll "proportionalDilute"  Laws.ProportionalDiluteTests.tests)
  failed := failed + (← runAll "deposit"             Laws.DepositTests.tests)
  failed := failed + (← runAll "withdraw"            Laws.WithdrawTests.tests)
  failed := failed + (← runAll "amm-swap"            Laws.AmmSwapTests.tests)
  failed := failed + (← runAll "reclaim-amm-reserves" Laws.ReclaimAmmReservesTests.tests)
  failed := failed + (← runAll "authority-action"   Authority.ActionTests.tests)
  failed := failed + (← runAll "authority-identity" Authority.IdentityTests.tests)
  failed := failed + (← runAll "authority-localpolicy"
                                    Authority.LocalPolicyTests.tests)
  failed := failed + (← runAll "authority-localpolicy-admissibility"
                                    Authority.LocalPolicyAdmissibility.tests)
  failed := failed + (← runAll "authority-nonce"    Authority.NonceTests.tests)
  failed := failed + (← runAll "authority-actorbudget" Authority.ActorBudgetTests.tests)
  failed := failed + (← runAll "authority-signed"   Authority.SignedActionTests.tests)
  failed := failed + (← runAll "authority-signed-happy-path"
                                    Authority.SignedActionHappyPath.tests)
  failed := failed + (← runAll "authority-signed-budget"
                                    Authority.SignedActionBudget.tests)
  failed := failed + (← runAll "authority-delegated-topup"
                                    Authority.DelegatedTopup.tests)
  failed := failed + (← runAll "encoding-cbor"      Encoding.CBORTests.tests)
  failed := failed + (← runAll "encoding-encodable" Encoding.EncodableTests.tests)
  failed := failed + (← runAll "encoding-action"    Encoding.ActionTests.tests)
  failed := failed + (← runAll "encoding-event"     Encoding.EventTests.tests)
  failed := failed + (← runAll "encoding-signed"    Encoding.SignedActionTests.tests)
  failed := failed + (← runAll "encoding-state"     Encoding.StateTests.tests)
  failed := failed + (← runAll "encoding-signinput" Encoding.SignInputTests.tests)
  failed := failed + (← runAll "encoding-localpolicy"
                                    Encoding.LocalPolicyTests.tests)
  failed := failed + (← runAll "encoding-injectivity"
                                    Encoding.InjectivityTests.tests)
  failed := failed + (← runAll "localpolicy-lawclass"
                                    LocalPolicy.LawClassificationTests.tests)
  failed := failed + (← runAll "dsl-law"            DSL.LawTests.tests)
  failed := failed + (← runAll "dsl-lex-law"
                                    Lex.Test.DSL.LawTests.tests)
  failed := failed + (← runAll "dsl-lex-impl-lowering"
                                    Lex.Test.DSL.ImplLoweringTests.tests)
  failed := failed + (← runAll "dsl-lex-property"
                                    Lex.Test.DSL.PropertyTests.tests)
  failed := failed + (← runAll "tools-lex-common"
                                    Lex.Test.Tools.CommonTests.tests)
  failed := failed + (← runAll "tools-lex-codegen"
                                    Lex.Test.Tools.CodegenTests.tests)
  failed := failed + (← runAll "tools-lex-diff"
                                    Lex.Test.Tools.DiffTests.tests)
  failed := failed + (← runAll "tools-lex-format"
                                    Lex.Test.Tools.FormatTests.tests)
  failed := failed + (← runAll "tools-lex-diagnostic-coverage"
                                    Lex.Test.Tools.DiagnosticCoverage.tests)
  failed := failed + (← runAll "dsl-lex-deployment"
                                    Lex.Test.DSL.DeploymentTests.tests)
  failed := failed + (← runAll "deployments-usd-clearing"
                                    Deployments.UsdClearingTests.tests)
  failed := failed + (← runAll "deployments-gas-pool-example"
                                    Deployments.GasPoolExampleTests.tests)
  failed := failed + (← runAll "laws-example-lex"
                                    Lex.Test.ExampleLex.tests)
  failed := failed + (← runAll "laws-lex-m2"
                                    Lex.Test.M2.tests)
  failed := failed + (← runAll "events-types"      Events.TypesTests.tests)
  failed := failed + (← runAll "events-extract"    Events.ExtractTests.tests)
  failed := failed + (← runAll "runtime-hash"      Runtime.HashTests.tests)
  failed := failed + (← runAll "runtime-logfile"   Runtime.LogFileTests.tests)
  failed := failed + (← runAll "runtime-replay"    Runtime.ReplayTests.tests)
  failed := failed + (← runAll "runtime-snapshot"  Runtime.SnapshotTests.tests)
  failed := failed + (← runAll "runtime-attested-snapshot"
                                    Runtime.AttestedSnapshotTests.tests)
  failed := failed + (← runAll "runtime-loop"      Runtime.LoopTests.tests)
  failed := failed + (← runAll "runtime-loop-happy-path"
                                    Runtime.LoopHappyPath.tests)
  failed := failed + (← runAll "runtime-budget-sidecar"
                                    Runtime.BudgetSidecarTests.tests)
  failed := failed + (← runAll "runtime-gas-pool-sidecar"
                                    Runtime.GasPoolSidecarTests.tests)
  failed := failed + (← runAll "runtime-refund-rate-sidecar"
                                    Runtime.RefundRateSidecarTests.tests)
  failed := failed + (← runAll "runtime-bridge-admission"
                                    Runtime.BridgeAdmission.tests)
  failed := failed + (← runAll "runtime-extract-events"
                                    Runtime.ExtractEvents.tests)
  failed := failed + (← runAll "encoding-disputes" Encoding.DisputesTests.tests)
  failed := failed + (← runAll "disputes-filing"   Disputes.FilingTests.tests)
  failed := failed + (← runAll "disputes-evidence" Disputes.EvidenceTests.tests)
  failed := failed + (← runAll "disputes-verdict"  Disputes.VerdictTests.tests)
  failed := failed + (← runAll "disputes-e2e"      Disputes.EndToEndTests.tests)
  failed := failed + (← runAll "disputes-lawclass" Disputes.LawClassificationTests.tests)
  failed := failed + (← runAll "disputes-monodepl" Disputes.MonotonicDeploymentTests.tests)
  failed := failed + (← runAll "disputes-rewards"  Disputes.RewardsTests.tests)
  failed := failed + (← runAll "disputes-staking"  Disputes.StakingTests.tests)
  failed := failed + (← runAll "disputes-incentivized-e2e"
                                    Disputes.IncentivizedEndToEndTests.tests)
  failed := failed + (← runAll "disputes-witness-helpers"
                                    Disputes.WitnessHelpers.tests)
  failed := failed + (← runAll "property-encoding"
                                    Properties.Encoding.tests)
  failed := failed + (← runAll "property-bridge"
                                    Properties.Bridge.tests)
  failed := failed + (← runAll "property-localpolicy"
                                    Properties.LocalPolicy.tests)
  failed := failed + (← runAll "property-lex"
                                    Lex.Test.Properties.tests)
  failed := failed + (← runAll "property-autogen"
                                    Lex.Test.AutoGenProperties.tests)
  failed := failed + (← runAll "bridge-verify-adaptor"
                                    Bridge.VerifyAdaptorTests.tests)
  failed := failed + (← runAll "bridge-hash-adaptor"
                                    Bridge.HashAdaptorTests.tests)
  failed := failed + (← runAll "bridge-eip712"
                                    Bridge.Eip712Tests.tests)
  failed := failed + (← runAll "bridge-address-book"
                                    Bridge.AddressBookTests.tests)
  failed := failed + (← runAll "bridge-actor"
                                    Bridge.BridgeActorTests.tests)
  failed := failed + (← runAll "bridge-amm-math"
                                    Bridge.AmmMathTests.tests)
  failed := failed + (← runAll "bridge-gas-pool-policy"
                                    Bridge.GasPoolPolicyTests.tests)
  failed := failed + (← runAll "bridge-amm-reserve-policy"
                                    Bridge.AmmReservePolicyTests.tests)
  failed := failed + (← runAll "bridge-pool-drain-bound"
                                    Bridge.PoolDrainBoundTests.tests)
  failed := failed + (← runAll "bridge-budget-refund"
                                    Bridge.BudgetRefundTests.tests)
  failed := failed + (← runAll "bridge-ingest"
                                    Bridge.IngestTests.tests)
  failed := failed + (← runAll "bridge-state"
                                    Bridge.StateTests.tests)
  failed := failed + (← runAll "bridge-admissible"
                                    Bridge.AdmissibleTests.tests)
  failed := failed + (← runAll "bridge-accounting"
                                    Bridge.AccountingTests.tests)
  failed := failed + (← runAll "bridge-withdrawal-root"
                                    Bridge.WithdrawalRootTests.tests)
  failed := failed + (← runAll "bridge-withdrawal-proof"
                                    Bridge.WithdrawalProofTests.tests)
  failed := failed + (← runAll "bridge-withdrawal-proof-cli"
                                    Bridge.WithdrawalProofCLI.tests)
  failed := failed + (← runAll "bridge-finalisation"
                                    Bridge.FinalisationTests.tests)
  failed := failed + (← runAll "bridge-withdrawal-goldens"
                                    Bridge.WithdrawalRootGoldens.tests)
  failed := failed + (← runAll "crosscheck-framework"
                                    Bridge.CrossCheck.tests)
  failed := failed + (← runAll "crosscheck-ecdsa-verify"
                                    Bridge.CrossCheck.EcdsaVerify.tests)
  failed := failed + (← runAll "crosscheck-keccak256"
                                    Bridge.CrossCheck.Keccak256.tests)
  failed := failed + (← runAll "crosscheck-deposit-receipt"
                                    Bridge.CrossCheck.DepositReceiptHash.tests)
  failed := failed + (← runAll "crosscheck-deposit-fee-split"
                                    Bridge.CrossCheck.DepositFeeSplit.tests)
  failed := failed + (← runAll "crosscheck-deposit-fee-split-bold"
                                    Bridge.CrossCheck.DepositFeeSplitBold.tests)
  failed := failed + (← runAll "crosscheck-deposit-with-fee-action"
                                    Bridge.CrossCheck.DepositWithFeeAction.tests)
  failed := failed + (← runAll "crosscheck-bold-deposit"
                                    Bridge.CrossCheck.BoldDeposit.tests)
  failed := failed + (← runAll "crosscheck-amm-getamountout"
                                    Bridge.CrossCheck.AmmMathCrossCheck.tests)
  failed := failed + (← runAll "crosscheck-amm-swap"
                                    Bridge.CrossCheck.AmmSwapCrossCheck.tests)
  failed := failed + (← runAll "crosscheck-event-cbe"
                                    Bridge.CrossCheck.EventCbe.tests)
  failed := failed + (← runAll "crosscheck-withdrawal-proof"
                                    Bridge.CrossCheck.WithdrawalProof.tests)
  failed := failed + (← runAll "crosscheck-dispute-evidence"
                                    Bridge.CrossCheck.DisputeEvidence.tests)
  failed := failed + (← runAll "crosscheck-migration-attestation"
                                    Bridge.CrossCheck.MigrationAttestation.tests)
  failed := failed + (← runAll "crosscheck-goldens"
                                    Bridge.CrossCheck.Goldens.tests)
  -- Workstream H — fault-proof migration suites.
  failed := failed + (← runAll "faultproof-cell"
                                    LegalKernel.Test.FaultProof.Cell.tests)
  failed := failed + (← runAll "faultproof-smt"
                                    LegalKernel.Test.FaultProof.Smt.tests)
  failed := failed + (← runAll "faultproof-commit"
                                    LegalKernel.Test.FaultProof.Commit.tests)
  failed := failed + (← runAll "faultproof-amm-commit"
                                    LegalKernel.Test.FaultProof.AmmCommit.tests)
  failed := failed + (← runAll "faultproof-step"
                                    LegalKernel.Test.FaultProof.Step.tests)
  failed := failed + (← runAll "faultproof-game"
                                    LegalKernel.Test.FaultProof.Game.tests)
  failed := failed + (← runAll "faultproof-lawclass"
                                    LegalKernel.Test.FaultProof.LawClassification.tests)
  failed := failed + (← runAll "faultproof-encoding"
                                    LegalKernel.Test.FaultProof.Encoding.tests)
  failed := failed + (← runAll "faultproof-events"
                                    LegalKernel.Test.FaultProof.EventEmission.tests)
  failed := failed + (← runAll "faultproof-witness"
                                    LegalKernel.Test.FaultProof.Witness.tests)
  failed := failed + (← runAll "faultproof-verify"
                                    LegalKernel.Test.FaultProof.Verify.tests)
  failed := failed + (← runAll "faultproof-trust"
                                    LegalKernel.Test.FaultProof.Trust.tests)
  failed := failed + (← runAll "faultproof-pervariant-coherence"
                                    LegalKernel.Test.FaultProof.PerVariantCoherence.tests)
  failed := failed + (← runAll "faultproof-encode-injectivity"
                                    LegalKernel.Test.FaultProof.EncodeInjectivity.tests)
  failed := failed + (← runAll "faultproof-absent-cell-creation"
                                    LegalKernel.Test.FaultProof.AbsentCellCreation.tests)
  failed := failed + (← runAll "faultproof-game-transition-edge-cases"
                                    LegalKernel.Test.FaultProof.GameTransitionEdgeCases.tests)
  failed := failed + (← runAll "faultproof-solidity-stepvm-commit"
                                    LegalKernel.Test.FaultProof.SolidityStepVMCommit.tests)
  failed := failed + (← runAll "faultproof-transcript"
                                    LegalKernel.Test.FaultProof.Transcript.tests)
  failed := failed + (← runAll "faultproof-coherence"
                                    LegalKernel.Test.FaultProof.Coherence.tests)
  failed := failed + (← runAll "faultproof-settlement"
                                    LegalKernel.Test.FaultProof.Settlement.tests)
  failed := failed + (← runAll "faultproof-migration-freeze"
                                    LegalKernel.Test.FaultProof.MigrationFreeze.tests)
  failed := failed + (← runAll "crosscheck-step-vm"
                                    Bridge.CrossCheck.StepVM.tests)
  failed := failed + (← runAll "crosscheck-bisection-game"
                                    Bridge.CrossCheck.BisectionGame.tests)
  failed := failed + (← runAll "crosscheck-fault-proof-scenarios"
                                    Bridge.CrossCheck.FaultProofScenarios.tests)
  failed := failed + (← runAll "crosscheck-smt-cell-proof"
                                    Bridge.CrossCheck.SmtCellProof.tests)
  failed := failed + (← runAll "crosscheck-observer-game-traces"
                                    Bridge.CrossCheck.ObserverGameTraces.tests)
  failed := failed + (← runAll "property-faultproof"
                                    LegalKernel.Test.Properties.FaultProof.tests)
  failed := failed + (← runAll "property-faultproof-extended"
                                    LegalKernel.Test.Properties.FaultProofExtended.tests)
  failed := failed + (← runAll "property-faultproof-deep"
                                    LegalKernel.Test.Properties.FaultProofDeep.tests)
  -- AR.23 — end-to-end integration regression suite.
  failed := failed + (← runAll "integration-cross-deployment"
                                    LegalKernel.Test.Integration.CrossDeployment.tests)
  failed := failed + (← runAll "integration-snapshot-bootstrap"
                                    LegalKernel.Test.Integration.SnapshotBootstrap.tests)
  failed := failed + (← runAll "integration-attested-snapshot-cli"
                                    LegalKernel.Test.Integration.AttestedSnapshotCli.tests)
  failed := failed + (← runAll "integration-replay-up-to-cli"
                                    LegalKernel.Test.Integration.ReplayUpToCli.tests)
  failed := failed + (← runAll "integration-export-cell-proofs-cli"
                                    LegalKernel.Test.Integration.ExportCellProofsCli.tests)
  failed := failed + (← runAll "integration-export-terminate-bundle-cli"
                                    LegalKernel.Test.Integration.ExportTerminateBundleCli.tests)
  -- Workstream SVC — step-VM cross-stack coherence.
  failed := failed + (← runAll "faultproof-stepvm-coherence"
                                    LegalKernel.Test.FaultProof.StepVMCoherence.tests)
  failed := failed + (← runAll "faultproof-terminate-bundle"
                                    LegalKernel.Test.FaultProof.TerminateBundle.tests)
  if failed = 0 then
    IO.println "ALL TESTS PASSED"
    pure 0
  else
    IO.println s!"{failed} TESTS FAILED"
    pure 1
