/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
import LegalKernel.Test.Authority.Action
import LegalKernel.Test.Authority.Identity
import LegalKernel.Test.Authority.Nonce
import LegalKernel.Test.Authority.SignedAction
import LegalKernel.Test.Authority.SignedActionHappyPath
import LegalKernel.Test.MockCrypto
import LegalKernel.Test.Property
import LegalKernel.Test.Properties.Encoding
import LegalKernel.Test.Properties.Bridge
import LegalKernel.Test.Encoding.CBOR
import LegalKernel.Test.Encoding.Encodable
import LegalKernel.Test.Encoding.Action
import LegalKernel.Test.Encoding.SignedAction
import LegalKernel.Test.Encoding.State
import LegalKernel.Test.Encoding.SignInput
import LegalKernel.Test.Encoding.Disputes
import LegalKernel.Test.DSL.Law
import LegalKernel.Test.Events.Types
import LegalKernel.Test.Events.Extract
import LegalKernel.Test.Runtime.Hash
import LegalKernel.Test.Runtime.LogFile
import LegalKernel.Test.Runtime.Replay
import LegalKernel.Test.Runtime.Snapshot
import LegalKernel.Test.Runtime.AttestedSnapshot
import LegalKernel.Test.Runtime.Loop
import LegalKernel.Test.Runtime.LoopHappyPath
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
import LegalKernel.Test.Bridge.CrossCheck.WithdrawalProof
import LegalKernel.Test.Bridge.CrossCheck.DisputeEvidence
import LegalKernel.Test.Bridge.CrossCheck.MigrationAttestation
import LegalKernel.Test.Bridge.CrossCheck.Goldens

open LegalKernel.Test

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
  failed := failed + (← runAll "authority-action"   Authority.ActionTests.tests)
  failed := failed + (← runAll "authority-identity" Authority.IdentityTests.tests)
  failed := failed + (← runAll "authority-nonce"    Authority.NonceTests.tests)
  failed := failed + (← runAll "authority-signed"   Authority.SignedActionTests.tests)
  failed := failed + (← runAll "authority-signed-happy-path"
                                    Authority.SignedActionHappyPath.tests)
  failed := failed + (← runAll "encoding-cbor"      Encoding.CBORTests.tests)
  failed := failed + (← runAll "encoding-encodable" Encoding.EncodableTests.tests)
  failed := failed + (← runAll "encoding-action"    Encoding.ActionTests.tests)
  failed := failed + (← runAll "encoding-signed"    Encoding.SignedActionTests.tests)
  failed := failed + (← runAll "encoding-state"     Encoding.StateTests.tests)
  failed := failed + (← runAll "encoding-signinput" Encoding.SignInputTests.tests)
  failed := failed + (← runAll "dsl-law"            DSL.LawTests.tests)
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
  failed := failed + (← runAll "crosscheck-withdrawal-proof"
                                    Bridge.CrossCheck.WithdrawalProof.tests)
  failed := failed + (← runAll "crosscheck-dispute-evidence"
                                    Bridge.CrossCheck.DisputeEvidence.tests)
  failed := failed + (← runAll "crosscheck-migration-attestation"
                                    Bridge.CrossCheck.MigrationAttestation.tests)
  failed := failed + (← runAll "crosscheck-goldens"
                                    Bridge.CrossCheck.Goldens.tests)
  if failed = 0 then
    IO.println "ALL TESTS PASSED"
    pure 0
  else
    IO.println s!"{failed} TESTS FAILED"
    pure 1
