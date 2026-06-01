-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Deployments.Examples.GasPoolExample — Workstream GP.7.4 worked
example deployment: a unified-gas-pool deployment ratified at genesis.

`docs/planning/unified_gas_pool_plan.md` WU GP.7.4.

This is the canonical GP.7.4 acceptance gate: a complete, runnable
deployment that wires the gas-pool discipline at genesis via the
`gasPoolGenesis` hook (`LegalKernel/Bridge/GasPoolPolicy.lean`) and
exercises the full lifecycle through BOTH currency legs:

  1. A bridge-signed ETH `depositWithFee` credits the user, skims the
     fee to `gasPoolActor` (resource 0), and grants the user an
     L2 action budget.
  2. A bridge-signed BOLD `depositWithFee` does the same on resource 1.
  3. The sequencer (holding the `gasPoolActor` pool-control key) claims
     accrued ETH-leg revenue with a capped `transfer` to
     `sequencerActor`.
  4. … and the same on the BOLD leg.

The deployment's `AuthorityPolicy` is the GP.7.4 genesis wiring
`AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy mEth
mBold)` — an otherwise-permissive base narrowed solely on
`gasPoolActor` — and its genesis `ExtendedState` declares
`gasPoolPolicy mEth mBold` for `gasPoolActor`.  Both halves are wired
by the single `gasPoolGenesis` constructor, so the GP.7.4 "wire BOTH"
contract holds by construction (`gasPoolGenesis_wires_both_halves`).

`runGasPoolExamplePure` runs the four-step sequence through the
SAME bridge-aware admission gate the `knomosis` runtime uses
(`apply_bridge_admissible_with_budget`), deterministically and without
IO; the integration test (`LegalKernel/Test/Deployments/GasPoolExample.lean`)
asserts the resulting balances + budget grants and the negative cases
(over-cap / meta-action / victim-sender claims rejected).
`runGasPoolExample` is the IO entry point the `knomosis gas-pool-demo`
subcommand dispatches to: it drives the steps through
`processSignedActionWith`, persists a log, and replays it via
`replayWith` to confirm the genesis wiring survives the runtime's
process → log → replay round-trip end-to-end.

**Demo crypto.**  This module ships its own deterministic toy verifier
(`exampleVerify`) and signer (`exampleSign`).  Like every Knomosis
deployment, a real one links a production `Verify` (ECDSA secp256k1
via `@[extern]`, Workstream RH-A.1); the toy verifier here exists ONLY
so the worked example is self-contained and runnable in the dev binary
(whose linked-at-runtime `Verify` opaque returns `false` at the Lean
level).  It accepts a structurally-distinct signature shape (64 bytes,
first byte `0xFF`) that no real signature scheme produces, so demo
signatures can never be confused with production ones.

This module is **non-TCB**: a bug here is scoped to this worked
example and cannot violate any kernel invariant.
-/

import LegalKernel
import LegalKernel.Bridge.GasPoolPolicy

namespace Deployments.Examples.GasPoolExample

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Runtime

/-! ## Deployment configuration -/

/-- The ETH-leg (`ResourceId 0`) per-action drain cap.  Calibrated so a
    single sequencer claim reimburses roughly one L1 batch-publishing
    transaction (≈ 1 ETH in the narrative; the demo uses round units). -/
def maxDrainPerActionEth : Amount := 1000

/-- The BOLD-leg (`ResourceId 1`) per-action drain cap.  Independent of
    the ETH cap so a deployment can calibrate the two legs for USD
    parity (a BOLD claim of 3000 BOLD ≈ an ETH claim of 1 ETH ≈ $3000). -/
def maxDrainPerActionBold : Amount := 3000

/-- The first non-reserved `ActorId`: a regular L2 user.  The reserved
    slots are `bridgeActor` (0), `gasPoolActor` (1), `sequencerActor`
    (2); a fresh deployment's first registered user is `ActorId 3`
    (`AddressBook.empty.nextActorId = 3`, GP.7.1). -/
def userActor : ActorId := 3

/-- The deployment's domain-separation tag (a short demo value; a
    production deployment supplies a 32-byte id via `--deployment-id`). -/
def exampleDeploymentId : ByteArray := ByteArray.mk #[0x67, 0x70, 0x37, 0x34]

/-- The deployment's per-actor epoch-budget policy: a free tier of 100
    action-budget units per epoch, an action cost of 1, at epoch 1.
    The free tier lets `gasPoolActor` (the sequencer's pool-control key,
    not budget-exempt) sign its capped claims; a production deployment
    calibrates the free tier to the sequencer's expected claim cadence. -/
def exampleBudgetPolicy : BudgetPolicy := .bounded 100 1 1

/-! ## Demo cryptography (toy verifier; NOT for production)

A deterministic, structurally-distinct toy verifier so the worked
example is self-contained and runnable.  A real deployment links a
production `Verify` via `@[extern]` (Workstream RH-A.1); this toy
scheme exists only because the dev binary's linked `Verify` returns
`false` at the Lean level. -/

/-- DEMO verifier: accepts any 64-byte signature whose first byte is
    `0xFF`.  Ignores the key and message — the worked example exercises
    admissibility, not signature security.  Structurally distinct from
    any real signature scheme (no real ECDSA / Ed25519 / ML-DSA
    signature begins with `0xFF` with non-trivial probability), so demo
    signatures can never be mistaken for production signatures. -/
def exampleVerify (_pk : PublicKey) (_msg : ByteArray) (sig : Signature) : Bool :=
  decide (sig.size = 64 ∧ sig.toList.head? = some 0xFF)

/-- DEMO signer: a canonical 64-byte signature (first byte `0xFF`, the
    rest `0x00`) that always passes `exampleVerify`. -/
def exampleSign (_pk : PublicKey) (_msg : ByteArray) : Signature :=
  ByteArray.mk ((List.replicate 64 (0 : UInt8)).set 0 0xFF).toArray

/-- DEMO public key for actor `id`: 32 bytes encoding the actor id in
    the first 8 little-endian bytes.  `exampleVerify` ignores the key,
    but the registry needs SOME `PublicKey` per registered actor. -/
def examplePubKey (id : Nat) : PublicKey :=
  let head := (List.range 8).map fun i => (UInt8.ofNat ((id / (256 ^ i)) % 256))
  ByteArray.mk (head ++ List.replicate 24 (0 : UInt8)).toArray

/-! ## Genesis state + policy (the GP.7.4 wiring) -/

/-- The base genesis state before the gas-pool wiring: the four actors
    (bridge / gas-pool / sequencer / user) registered with demo public
    keys, the `exampleBudgetPolicy` budget mode, and otherwise empty
    (no balances, no nonces, no declared local policies — the deposits
    materialise balances; the hook declares `gasPoolPolicy`). -/
def exampleBaseState : ExtendedState :=
  { base     := genesisState
  , nonces   := NonceState.empty
  , registry := KeyRegistry.empty.register bridgeActor (examplePubKey bridgeActor.toNat)
                  |>.register gasPoolActor (examplePubKey gasPoolActor.toNat)
                  |>.register sequencerActor (examplePubKey sequencerActor.toNat)
                  |>.register userActor (examplePubKey userActor.toNat)
  , budgetPolicy := exampleBudgetPolicy }

/-- The GP.7.4 genesis configuration: declares `gasPoolPolicy` for
    `gasPoolActor` AND intersects `gasPoolAuthorityPolicy` into the
    (otherwise unrestricted) deployment policy — both halves wired
    atomically by `gasPoolGenesis`. -/
def exampleGenesis : GasPoolGenesis :=
  gasPoolGenesis exampleBaseState AuthorityPolicy.unrestricted
    maxDrainPerActionEth maxDrainPerActionBold

/-- The deployment's genesis `ExtendedState` (with `gasPoolPolicy`
    declared for `gasPoolActor`). -/
def exampleState : ExtendedState := exampleGenesis.state

/-- The deployment's `AuthorityPolicy` (the unrestricted base narrowed
    by `gasPoolAuthorityPolicy`). -/
def examplePolicy : AuthorityPolicy := exampleGenesis.policy

/-! ## The worked action sequence -/

/-- Step 1 — a bridge-signed ETH `depositWithFee`: credit `userActor`
    9000 ETH and skim a 1000-ETH fee to `gasPoolActor` (resource 0),
    granting the user 50 action-budget units; deposit id 1. -/
def ethDepositAction : Action :=
  .depositWithFee 0 userActor gasPoolActor 9000 1000 50 1

/-- Step 2 — a bridge-signed BOLD `depositWithFee`: credit `userActor`
    27000 BOLD and skim a 3000-BOLD fee to `gasPoolActor` (resource 1),
    granting the user 150 action-budget units; deposit id 2. -/
def boldDepositAction : Action :=
  .depositWithFee 1 userActor gasPoolActor 27000 3000 150 2

/-- Step 3 — the sequencer's ETH-leg claim: a capped `transfer` of 800
    ETH from `gasPoolActor`'s own balance to `sequencerActor` (within
    the 1000-ETH cap). -/
def ethClaimAction : Action :=
  .transfer 0 gasPoolActor sequencerActor 800

/-- Step 4 — the sequencer's BOLD-leg claim: a capped `transfer` of 2500
    BOLD from `gasPoolActor`'s own balance to `sequencerActor` (within
    the 3000-BOLD cap). -/
def boldClaimAction : Action :=
  .transfer 1 gasPoolActor sequencerActor 2500

/-- The four worked steps as `(signer, action)` pairs, in order. -/
def exampleSteps : List (ActorId × Action) :=
  [ (bridgeActor, ethDepositAction)
  , (bridgeActor, boldDepositAction)
  , (gasPoolActor, ethClaimAction)
  , (gasPoolActor, boldClaimAction) ]

/-- Build a demo-signed `SignedAction` for `action` by `signer` at the
    nonce `es` expects, against `exampleDeploymentId`. -/
def mkExampleSignedAction (action : Action) (signer : ActorId) (es : ExtendedState) :
    SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce exampleDeploymentId
  { action := action
  , signer := signer
  , nonce  := nonce
  , sig    := exampleSign (examplePubKey signer.toNat) msg }

/-! ## Pure runner (deterministic; drives the runtime admission gate) -/

/-- Apply one worked step under the demo verifier + genesis policy via
    the production bridge-aware admission gate
    (`apply_bridge_admissible_with_budget`).  Returns the advanced state,
    or a diagnostic if the step was inadmissible or budget-rejected. -/
def applyExampleStep (es : ExtendedState) (signer : ActorId) (action : Action) (idx : Nat) :
    Except String ExtendedState :=
  let st := mkExampleSignedAction action signer es
  if h : BridgeAdmissibleWith exampleVerify examplePolicy exampleDeploymentId es st then
    match apply_bridge_admissible_with_budget exampleVerify examplePolicy exampleDeploymentId
            es st idx h with
    | some es' => .ok es'
    | none     => .error s!"step {idx} (signer {signer}): admissible but budget gate rejected"
  else
    .error s!"step {idx} (signer {signer}): not bridge-admissible under the genesis policy"

/-- Fold the worked steps through `applyExampleStep`, threading the
    state and log index; the first failing step aborts with its
    diagnostic. -/
def runExampleSteps (es : ExtendedState) (steps : List (ActorId × Action)) (idx : Nat) :
    Except String ExtendedState :=
  match steps with
  | []                      => .ok es
  | (signer, action) :: rest =>
    match applyExampleStep es signer action idx with
    | .ok es'  => runExampleSteps es' rest (idx + 1)
    | .error e => .error e

/-- Run the full worked sequence from the genesis state through the
    bridge-aware admission gate.  Returns the fully-advanced state on
    success.  Pure + deterministic: this is what the integration test
    asserts against. -/
def runGasPoolExamplePure : Except String ExtendedState :=
  runExampleSteps exampleState exampleSteps 0

/-! ## Proof-carrying demonstrations of the GP.7.4 contract

These are pure facts about the deployment's genesis wiring — no
signatures, no runtime.  They make the example proof-carrying: the
genesis declares the pool policy, and the two legitimate sequencer
claims are authorised by the deployment policy. -/

/-- The genesis state declares `gasPoolPolicy` for `gasPoolActor`. -/
theorem example_declares_gas_pool_policy :
    exampleState.localPolicies.lookup gasPoolActor =
      gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold :=
  gasPoolGenesisState_declares_policy exampleBaseState
    maxDrainPerActionEth maxDrainPerActionBold

/-- The deployment policy authorises the ETH-leg sequencer claim (it is
    a capped pool→sequencer transfer of the pool's own funds). -/
theorem example_eth_claim_authorized :
    examplePolicy.authorized gasPoolActor ethClaimAction :=
  gasPoolGenesisPolicy_authorizes_sequencer_eth AuthorityPolicy.unrestricted
    maxDrainPerActionEth maxDrainPerActionBold 800 trivial (by decide)

/-- The deployment policy authorises the BOLD-leg sequencer claim. -/
theorem example_bold_claim_authorized :
    examplePolicy.authorized gasPoolActor boldClaimAction :=
  gasPoolGenesisPolicy_authorizes_sequencer_bold AuthorityPolicy.unrestricted
    maxDrainPerActionEth maxDrainPerActionBold 2500 trivial (by decide)

/-- The deployment policy bars `gasPoolActor` meta-actions (the GP.7.4
    headline: a held pool key cannot revoke its own `gasPoolPolicy`). -/
theorem example_rejects_pool_meta :
    ¬ examplePolicy.authorized gasPoolActor .revokeLocalPolicy :=
  (gasPoolGenesisPolicy_rejects_meta AuthorityPolicy.unrestricted
    maxDrainPerActionEth maxDrainPerActionBold).1

/-! ## IO runner (the `knomosis gas-pool-demo` entry point)

Drives the worked sequence through `processSignedActionWith` — the
runtime's per-action entry — persisting a log, then replays it via
`replayWith` to confirm the genesis wiring survives the runtime's
process → log → replay round-trip byte-for-byte. -/

/-- Render the user / pool / sequencer balances + the user's granted
    budget from a final state, one per line. -/
def formatExampleReport (fs : ExtendedState) : String :=
  let line (label : String) (v : Nat) : String := s!"    {label} = {v}\n"
  "  final balances + budget:\n" ++
  line "user    ETH " (getBalance fs.base 0 userActor) ++
  line "user    BOLD" (getBalance fs.base 1 userActor) ++
  line "pool    ETH " (getBalance fs.base 0 gasPoolActor) ++
  line "pool    BOLD" (getBalance fs.base 1 gasPoolActor) ++
  line "seq     ETH " (getBalance fs.base 0 sequencerActor) ++
  line "seq     BOLD" (getBalance fs.base 1 sequencerActor) ++
  line "user budget " (EpochBudgetState.currentBudget fs.epochBudgets userActor 1 100)

/-- Process the worked steps through `processSignedActionWith`,
    threading the `RuntimeState`; the first rejection aborts with its
    diagnostic. -/
def processExampleSteps (rs : RuntimeState) (steps : List (ActorId × Action)) (step : Nat) :
    IO (Except String RuntimeState) := do
  match steps with
  | []                       => return .ok rs
  | (signer, action) :: rest =>
    let st := mkExampleSignedAction action signer rs.state
    match (← processSignedActionWith exampleVerify exampleDeploymentId rs st) with
    | .ok pr =>
      IO.println s!"  step {step}: admitted ({pr.events.length} event(s))"
      processExampleSteps pr.state rest (step + 1)
    | .error e =>
      return .error s!"step {step} rejected: {repr e}"

/-- The `knomosis gas-pool-demo` entry point: run the GP.7.4 worked
    deployment end-to-end through the runtime (process → log → replay)
    and report the result.  Returns exit code 0 on success, 1 on any
    rejection or replay mismatch. -/
def runGasPoolExample : IO UInt32 := do
  IO.println "knomosis gas-pool-demo — GP.7.4 unified-gas-pool deployment"
  IO.println "  genesis wires gasPoolPolicy (LocalPolicy) + gasPoolAuthorityPolicy"
  IO.println s!"    caps: ETH ≤ {maxDrainPerActionEth}/action, BOLD ≤ {maxDrainPerActionBold}/action"
  IO.println "  (DEMO crypto: a deterministic toy verifier; production links a real Verify)"
  let tmp := s!"/tmp/knomosis-gas-pool-demo-{(← IO.monoNanosNow)}.log"
  let logPath := System.FilePath.mk tmp
  let rs0 : RuntimeState :=
    { policy       := examplePolicy
    , state        := exampleState
    , prevHash     := zeroHash
    , logIndex     := 0
    , logPath      := logPath
    , deploymentId := exampleDeploymentId
    , epochLength  := 0 }
  match (← processExampleSteps rs0 exampleSteps 0) with
  | .error e =>
    IO.eprintln s!"gas-pool-demo: {e}"
    (try IO.FS.removeFile logPath catch _ => pure ())
    return 1
  | .ok rsFinal =>
    let fs := rsFinal.state
    IO.print (formatExampleReport fs)
    -- Replay the persisted log to confirm the genesis wiring is
    -- deterministic across the process → log → replay round-trip.
    let (entries, _, _) ← readAllEntries logPath
    match replayWith exampleVerify exampleDeploymentId examplePolicy exampleState entries 0 with
    | .ok replayed =>
      let hashesAgree := (hashEncodable replayed).toList = (hashEncodable fs).toList
      (try IO.FS.removeFile logPath catch _ => pure ())
      if hashesAgree then
        IO.println "  replay round-trip: state hash matches ✓"
        IO.println "gas-pool-demo: PASS"
        return 0
      else
        IO.eprintln "gas-pool-demo: replay state-hash MISMATCH"
        return 1
    | .error e =>
      (try IO.FS.removeFile logPath catch _ => pure ())
      IO.eprintln s!"gas-pool-demo: replay failed ({repr e})"
      return 1

end Deployments.Examples.GasPoolExample
