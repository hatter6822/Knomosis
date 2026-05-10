/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel — umbrella module.

Re-exports the trusted core (`Kernel.lean`), the §8.3 RBMap proof
library (`RBMapLemmas.lean`, also TCB), the Phase-2 economic
invariants framework (`Conservation.lean`, non-TCB), the deployed
law set, and the Phase-3 authority layer (`Authority/*`).

Phase status:

  * Phase 0: shipped exactly one law (the canonical `transfer` of §4.11).
  * Phase 1: added the §4.3 balance lemmas, the §4.9 multi-step /
    law-set reachability extensions, and the §8.3 fold lemmas.
  * Phase 2: added the `TotalSupply` quantity functional, the
    `IsConservative` typeclass, `transfer_conserves` (with the
    `IsConservative` instance), the `mint` / `burn` non-conservative
    laws (with explicit non-conservation witnesses), the
    `ConservativeLawSet` structure, the `total_supply_global`
    theorem, and the `freezeResource` / `FrozenForResource`
    immutability machinery.
  * Phase 3: added the `Action` data layer with `CompiledAction` for
    structural `compile_injective`; the `PublicKey` / `Signature` /
    opaque `Verify` cryptographic interface; `Identity`,
    `KeyRegistry`, and `AuthorityPolicy` with `empty` / `union` /
    `intersect` / `singleton` operations; the `NonceState` and
    `ExtendedState` extending kernel state with per-actor nonce
    ledger and key registry; the §8.5 `expectsNonce_strict_mono`
    lemma; the §8.2 five-condition `Admissible` predicate; the
    single guarded `apply_admissible` entry point; and the headline
    §8.5.2 `nonce_uniqueness` and `replay_impossible` theorems plus
    the `replaceKey` authority-layer effect (WU 3.10).
  * Phase 4 prelude (positive incentives): added the
    `IsMonotonic` typeclass + `monotonic_of_conservative` auto-upgrade
    and the `MonotonicLawSet` structure (the type-level firewall for
    "no value destruction" deployments); the
    `total_supply_globally_nondecreasing[_via_law_set]` headline
    theorems; three new positive-incentive laws (`reward`,
    `distributeOthers`, `proportionalDilute`) with full classification
    (per-law `IsMonotonic` instances, `_not_conservative` negative
    witnesses, locality + cross-resource lemmas, and for
    `proportionalDilute` the dust bound
    `_distributed_le_totalReward`); per-existing-law `IsMonotonic`
    instances for `transfer` / `mint` and the missing
    `freezeResource_isConservative` instance; the `burn_not_monotonic`
    negative witness; and three new `Action` constructors (`reward`,
    `distributeOthers`, `proportionalDilute`) with their compile
    branches.
  * Phase 4 (DSL and Serialization): added the `Encodable` typeclass +
    CBE byte codec; per-type round-trip and injectivity proofs for
    primitives and headline types (`Action`, `SignedAction`, `State`,
    `ExtendedState`); domain-separated `signInput` (§8.8.5); the `law`
    macro (`pre := ... ; impl := ...`).
  * Phase 5: added the deterministic `Runtime.Hash` (FNV-1a-64
    fallback for production BLAKE3); the Phase-5 `LogEntry` + framed
    log-file format with crash-consistent truncation
    (`Runtime.LogFile`); the standalone `replay` tool
    (`Runtime.Replay`); state snapshots + incremental shipping
    (`Runtime.Snapshot`); the `RuntimeState` + `processSignedAction`
    main loop (`Runtime.Loop`); the `Event` inductive (§8.9.2) and
    deterministic `extractEvents` (`Events.{Types, Extract}`); the
    `canon` runtime CLI (with `process` / `replay` / `bootstrap` /
    `snapshot` subcommands) and the focused `canon-replay` audit
    binary.
  * Phase 6 (Disputes and Adjudication): added the §8.4
    dispute pipeline data types (`DisputeClaim`, `Dispute`,
    `Verdict`, `DisputeRecord`, `DisputeStatus`, `OraclePolicy`,
    `QuorumPolicy`) with canonical CBE byte encodings; four new
    `Action` constructors (`dispute`, `disputeWithdraw`, `verdict`,
    `rollback`) at frozen indices 8..11; three new `Event`
    constructors (`disputeFiled`, `disputeWithdrawn`,
    `verdictApplied`) at frozen indices 5..7; the four-stage
    pipeline (`fileDispute`, `checkEvidence` with five per-claim
    verifiers, `proposeVerdict` with quorum support, `applyVerdict`
    with rollback computation); the `disputeStatus` walk-the-log
    derivation; `applyWithdraw` idempotency theorems; and the
    end-to-end planted-illegal-tx → file → check → rollback
    acceptance test.
  * Ethereum Workstream A (cryptographic adaptors): three new
    Lean-side modules (`Bridge/{VerifyAdaptor, HashAdaptor,
    Eip712}`) capturing the contract for the production Rust
    crypto bindings (ECDSA secp256k1 verify, keccak256 hash,
    EIP-712 typed-data wrap).  All three are non-TCB; the
    binding's correctness is a deployment-level trust assumption.
  * Ethereum Workstream B (identity and authority):
    three new Lean-side modules (`Bridge/{AddressBook, BridgeActor,
    Ingest}`) wiring Ethereum's address-based identity model into
    Canon's `KeyRegistry`.  Adds the `EthAddress = Fin (2^160)`
    type with BE-byte conversion; the `AddressBook` structure with
    forward / reverse maps and `Consistent` invariant; the
    `bridgeActor : ActorId := 0` reservation and `bridgePolicy`
    `AuthorityPolicy`; the `L1Event` inductive and `ingest`
    function translating L1 events into `UnsignedBridgeAction`
    envelopes for the runtime adaptor to sign.  Adds the
    `Action.registerIdentity (actor : ActorId) (pk : PublicKey)`
    constructor at frozen index 12 — the bridge-authored first-
    time-registration analogue of `replaceKey`.  Eight new
    headline theorems (§12.7 + §12.8 + §12.9) span the address-
    book invariant, the L1-translation locality, and the bridge-
    actor authorization predicate.  All Workstream-B modules are
    non-TCB.
  * Ethereum Workstream C (current; bridge laws): three new
    Lean-side modules (`Bridge/{State, Admissible, Accounting}`)
    plus two new laws (`Laws/{Deposit, Withdraw}`).  Embeds a
    `bridge : BridgeState` field into `ExtendedState` with a
    `BridgeState.empty` default, tracking consumed L1 deposit
    receipts (with per-deposit `(resource, amount)` metadata)
    and pending L2 withdrawals.  Adds `Action.deposit` (frozen
    index 13) and `Action.withdraw` (frozen index 14)
    constructors with full CBE encoding round-trip.  Adds two
    new `Event` constructors: `withdrawalRequested` (frozen
    index 9) and `depositCredited` (frozen index 10).  Defines
    a strengthened `BridgeAdmissibleWith` predicate adding
    three bridge-specific obligations (deposit-id uniqueness,
    first-time-registration, bridge-only signer) and a
    corresponding `apply_bridge_admissible_with` entry point
    via the `applyActionToBridgeState` helper, with
    pass-through preservation theorems
    (`apply_admissible_with_preserves_bridge`) and a
    `bridge_replay_impossible` lift via the
    `BridgeAdmissibleWith.toAdmissibleWith` projection.
    Defines `totalDeposited` / `totalWithdrawn` quantity
    functionals plus per-action accounting deltas covering
    every kernel `Action` constructor (transfer, freeze,
    replaceKey, registerIdentity, mint / burn / reward / etc.,
    deposit, withdraw).  Extends the `bridgePolicy`
    `AuthorityPolicy` to admit `deposit` / `withdraw` for the
    bridge actor.  All Workstream-C modules are non-TCB.

Importing `LegalKernel` is the recommended entry point for downstream
modules and tests; do *not* import `LegalKernel.Kernel` or
`LegalKernel.RBMapLemmas` directly except when you specifically need
the trusted-core surface in isolation (e.g. the `tcb_audit` tool of
WU 1.11).

This file may carry **non-TCB** convenience definitions (build tags,
deployment-wide constants).  Anything *trusted* belongs in
`LegalKernel.Kernel` or `LegalKernel.RBMapLemmas`.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Burn
import LegalKernel.Laws.Freeze
import LegalKernel.Laws.Reward
import LegalKernel.Laws.DistributeOthers
import LegalKernel.Laws.ProportionalDilute
import LegalKernel.Laws.Deposit
import LegalKernel.Laws.Withdraw
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Action
import LegalKernel.Authority.Identity
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Authority.Nonce
import LegalKernel.Authority.SignedAction
import LegalKernel.Disputes.Types
import LegalKernel.Disputes.Filing
import LegalKernel.Disputes.Evidence
import LegalKernel.Disputes.Verdict
import LegalKernel.Disputes.LawClassification
import LegalKernel.Disputes.MonotonicDeployment
import LegalKernel.Disputes.Rewards
import LegalKernel.Disputes.Staking
import LegalKernel.Encoding.LocalPolicy
import LegalKernel.LocalPolicy.LawClassification
import LegalKernel.Encoding.CBOR
import LegalKernel.Encoding.Encodable
import LegalKernel.Encoding.Disputes
import LegalKernel.Encoding.Action
import LegalKernel.Encoding.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Encoding.SignInput
import LegalKernel.DSL.Law
import LegalKernel.DSL.LawSyntax
import LegalKernel.DSL.LexPreGrammar
import LegalKernel.DSL.LexImplCalculus
import LegalKernel.DSL.LexEvents
import LegalKernel.DSL.LexShim
import LegalKernel.DSL.LexLaw
import LegalKernel.DSL.LexProperty
import LegalKernel.DSL.LexDeployment
-- LexImplLowering is intentionally NOT in the umbrella: it
-- registers `to`, `from`, `as`, `amt`, `nop` as global Lean
-- tokens (the §6.2 calculus keywords).  Files that consume the
-- calculus-form `lex_do <stmt>` import `LegalKernel.DSL.LexImplLowering`
-- explicitly; everywhere else (test suites, hand-written law
-- files using common `(to : ActorId)` parameters) is unaffected.
import LegalKernel.Laws.ExampleLex
-- Workstream LX (M2): Lex re-expressions of the 17 kernel-built-in
-- laws.  After the LX-M2 in-place migration, the Lex re-expressions
-- of the 9 hand-written laws (transfer, mint, burn, freezeResource,
-- reward, deposit, withdraw, distributeOthers, proportionalDilute)
-- live alongside their hand-written counterparts in the same files
-- under `Laws/`.  The 8 kernel-identity laws (replaceKey,
-- registerIdentity, dispute pipeline {dispute, disputeWithdraw,
-- verdict, rollback}, localPolicy {declareLocalPolicy,
-- revokeLocalPolicy}) are top-level Lex declarations in dedicated
-- files under `Laws/` (no hand-written counterpart, since their
-- kernel-level transition is `Laws.freezeResource 0`).
import LegalKernel.Laws.ReplaceKey
import LegalKernel.Laws.RegisterIdentity
import LegalKernel.Laws.Dispute
import LegalKernel.Laws.LocalPolicy
import LegalKernel.Events.Types
import LegalKernel.Events.Extract
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile
import LegalKernel.Runtime.Replay
import LegalKernel.Runtime.Snapshot
import LegalKernel.Runtime.AttestedSnapshot
import LegalKernel.Runtime.Loop
import LegalKernel.Bridge.VerifyAdaptor
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Bridge.Eip712
import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Bridge.Ingest
import LegalKernel.Bridge.State
import LegalKernel.Bridge.Admissible
import LegalKernel.Bridge.Accounting
import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Bridge.Finalisation
-- Workstream H — fault-proof migration.  Six new non-TCB
-- modules under `LegalKernel/FaultProof/` formalising the
-- step VM data shapes (KernelStep, CellTag, CellProof,
-- StateCommit), the per-action cell sets, the bisection-game
-- state machine, the law classification for the two new
-- Action constructors, and the witness-bearing
-- FaultProofChallengerWon predicate.  See
-- `docs/fault_proof_migration_plan.md` for the full plan.
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.LawClassification
import LegalKernel.FaultProof.StepVariants
import LegalKernel.FaultProof.Verify
import LegalKernel.FaultProof.Step
import LegalKernel.FaultProof.Game
import LegalKernel.FaultProof.Witness
import LegalKernel.FaultProof.Coherence
import LegalKernel.FaultProof.PerVariantCoherence
import LegalKernel.FaultProof.MissingTheorems
import LegalKernel.FaultProof.Transcript
import LegalKernel.FaultProof.Strategy
import LegalKernel.FaultProof.Convergence
import LegalKernel.FaultProof.Honesty
import LegalKernel.FaultProof.Trust
import LegalKernel.FaultProof.TypedCellProof
import LegalKernel.FaultProof.DisputeConfig
import LegalKernel.FaultProof.MigrationFreeze
import LegalKernel.FaultProof.Observer
import LegalKernel.FaultProof.SubStep
import LegalKernel.FaultProof.KeyDerivation
import LegalKernel.Encoding.KernelStep
import LegalKernel.Encoding.GameState

namespace LegalKernel

/-- A non-TCB build identification string.  Lets non-kernel callers
    (the `canon` placeholder runtime, the test driver) confirm at link
    time that the kernel module compiled, without exercising any
    actual transition.  Bumped by hand whenever the §4.12 surface
    changes or a Phase boundary is crossed; mirror in §13.8
    release-cutting runbook.

    Lives outside `LegalKernel.Kernel` so that the trusted-core file
    contains only the §4.12 listing — the WU-1.11 TCB audit tool can
    therefore enumerate `Kernel.lean` without seeing convenience
    constants. -/
def kernelBuildTag : String := "canon-fault-proof-migration"

end LegalKernel
