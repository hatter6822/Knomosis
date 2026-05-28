# Knomosis Solidity contracts

L1 mirror of Knomosis's kernel: **ten immutable contracts, six shared
libraries, five interfaces** that anchor deposits, state-root
submissions, withdrawals, the dispute pipeline, sequencer staking,
interactive fault proofs (Workstream H), SMT cell proofs (Workstream
SC.2), L1 step-VM coherence (Workstream SVC), and the attested-handoff
migration mechanism.

The full design rationale lives in
[`docs/planning/ethereum_integration_plan.md`](../docs/planning/ethereum_integration_plan.md)
§9 (Workstream E) and §20 (immutability amendment); the fault-proof
layer is specified in
[`docs/planning/fault_proof_migration_plan.md`](../docs/planning/fault_proof_migration_plan.md)
and motivated in
[`docs/fault_proof_design.md`](../docs/fault_proof_design.md); the SMT
cell-proof verifier is specified in
[`docs/planning/smt_cell_proofs_plan.md`](../docs/planning/smt_cell_proofs_plan.md);
the step-VM coherence corpus is specified in
[`docs/planning/step_vm_coherence_plan.md`](../docs/planning/step_vm_coherence_plan.md).
Read those first; this README is the day-to-day developer guide.

## Layout

```
solidity/
├── foundry.toml             — toolchain + remappings + via_ir
├── lib/                     — vendored OpenZeppelin + forge-std
├── src/
│   ├── contracts/
│   │   ├── KnomosisBridge.sol             (E.1)  — L1 escrow
│   │   ├── KnomosisDisputeVerifier.sol    (E.2)  — three-variant pipeline (v1)
│   │   ├── KnomosisDisputeVerifierV2.sol  (H)    — pipeline + fault-proof claim
│   │   ├── KnomosisIdentityRegistry.sol   (E.3)  — KeyRegistry mirror
│   │   ├── KnomosisSequencerStake.sol     (E.4)  — sequencer slash escrow
│   │   ├── KnomosisMigration.sol          (E.5)  — attested handoff
│   │   ├── KnomosisStateRootSubmission.sol (H)   — state-root window + bonds
│   │   ├── KnomosisFaultProofGame.sol     (H)    — bisection-game arbiter
│   │   ├── KnomosisStepVM.sol             (H)    — single-step verifier (pure)
│   │   └── KnomosisFaultProofMigration.sol (H)   — v1 → v2 migration
│   ├── interfaces/                            — public interface files (E.1-E.5)
│   └── lib/
│       ├── KnomosisEip712.sol      — EIP-712 domain + struct-hash helpers
│       ├── CBEDecode.sol        — CBE byte decoder (mirrors Lean)
│       ├── SmtVerifier.sol      — withdrawal-tree SMT verifier (D.1, depth 64)
│       ├── SmtCellVerifier.sol  — state-cell SMT verifier (SC.2, depth 256)
│       ├── CREATE3.sol          — proxy-factory deploy for cyclic refs
│       └── StepVMMerkle.sol     — per-cell proof helpers (H + SC.2)
└── test/
    ├── *.t.sol                  — 14 unit suites (per-contract + SmtCellVerifier)
    ├── CrossCheck/*.t.sol       — 12 cross-stack suites (Lean ↔ Solidity)
    └── utils/                   — Deployer.sol (CREATE3 harness),
                                    MockERC20.sol
```

Total: **~417 forge tests across 26 suites** (per-suite counts in each
`*.t.sol`; the static `function test*` count is the conservative
lower bound — fuzz and property tests report higher run counts at
`forge test` time). A subset is conditionally skipped when the
production keccak256 binding is not linked (the cross-check suites
probe `isKeccak256Linked` on the Lean side and skip on the fallback).

## Build & test

```bash
# Install Foundry (one-time):
curl -sSfL https://github.com/foundry-rs/foundry/releases/download/v1.7.0/foundry_v1.7.0_linux_amd64.tar.gz \
  -o /tmp/foundry.tar.gz
tar xzf /tmp/foundry.tar.gz -C /usr/local/foundry/bin
export PATH="/usr/local/foundry/bin:$PATH"

# Install solc 0.8.20 (one-time):
curl -sSfL https://github.com/ethereum/solidity/releases/download/v0.8.20/solc-static-linux \
  -o /usr/local/bin/solc
chmod +x /usr/local/bin/solc

# Vendor OpenZeppelin v5.0.2 + forge-std v1.9.4 (run from this dir):
./scripts/vendor-deps.sh

# Build + test:
forge build
forge test
make test-cross-stack             # CrossCheck/ only
make audit-caps                   # GP.5.2 fee-split-cap audit gate
make audit-caps-selftest          # self-test: prove the gate trips
make testnet-acceptance-dryrun    # F.3 testnet acceptance dry-run
```

`foundry.toml` pins:

* `solc_version = "0.8.20"` with `evm_version = "shanghai"`.
* `via_ir = true` — required because `KnomosisBridge.withdrawWithProof`
  and a few other functions are stack-too-deep without it.
* `optimizer_runs = 200`.

## Continuous integration

`.github/workflows/ci-solidity.yml` runs on every PR that touches
`solidity/**`.  Two independent jobs: `caps-audit` runs the GP.5.2
constitutional-cap gate + self-test (`make audit-caps` /
`make audit-caps-selftest`; pure bash, no toolchain), and `forge`
installs the pinned Foundry + solc, vendors dependencies, and runs
`forge build` + `forge test` over the full suite under the project's
`[profile.ci]` (`FOUNDRY_PROFILE=ci`, fuzz = 1000).  The split keeps the
fast cap-drift tripwire independent of the slower contract build.

## Immutability discipline

Per §4.8 / §20 of the integration plan, every contract here is
deployed immutably:

* **No proxy.** Each contract goes straight to its final address
  (mainnet via `CREATE2` with deterministic salts; tests via
  `CREATE3` to break cyclic references between bridge, verifier,
  stake, and the fault-proof game).
* **No `initialize`.** Constructors set every field; nothing is
  later mutable.
* **No admin role.** Each cross-contract authority is encoded as
  `address public immutable`.
* **No `pause()` function.** Whole-system halts use the automatic
  circuit breakers in `KnomosisBridge.sol` (§9.1.4): `AttestationStale`,
  `DisputeCooldown`, `TvlCapReached`, `MigrationActivated`. Each
  fires on a deterministic public-state predicate; no privileged
  caller is involved.
* **Recovery via the dispute pipeline, not via code.** Bad state
  transitions are reverted by upheld disputes or by the fault-proof
  game; bad code is replaced by deploying a new immutable contract
  and using `KnomosisMigration` / `KnomosisFaultProofMigration` to attest
  the handoff.

The forge test suite includes a `test_no_admin_surface` assertion
on every contract that confirms canonical admin selectors
(`pause()`, `unpause()`, `transferOwnership(...)`, `grantRole(...)`,
`upgradeTo(...)`) are not callable.

## CREATE3 deployment

The bridge ↔ verifier ↔ stake ↔ fault-proof-game cycle is broken
at deployment time using `CREATE3` (`src/lib/CREATE3.sol`), which
derives each contract's address from `(deployer, salt)` alone —
independent of init-code. This lets the predicted addresses be
baked into each contract's `immutable` constructor arguments before
deployment.

The standard CREATE3 proxy (init-code
`0x67363d3d37363d34f03d5260086018f3`) does not propagate inner
constructor reverts: a failed inner CREATE returns 0 from the
proxy, and the `deploy` helper detects that via a post-deploy
`code.length == 0` check. This is the documented behaviour of
every standard CREATE3 implementation (Solady, Solmate).
Production deployment scripts that need bubbled revert reasons
must use a bespoke proxy; the `KnomosisMigration` test fixtures use
direct `new ...(...)` deployment so constructor revert reasons
propagate verbatim.

## Cross-stack equivalence

Per Workstream F.1, the Solidity contracts must produce
byte-identical results to the Lean reference implementation.
Specifically:

* `CBEDecode` decodes byte-for-byte the same way as
  `LegalKernel.Encoding.cborHeadDecode`.
* `SmtVerifier.verifyProof` accepts exactly the same proofs as
  `LegalKernel.Bridge.WithdrawalRoot.verifyProof`.
* `KnomosisEip712`'s digest matches `LegalKernel.Bridge.Eip712.digest`.
* `KnomosisBridge`'s `receiptHash` derivation matches
  `LegalKernel.Laws.Deposit.depositId`.
* `KnomosisStepVM.executeStep` matches
  `LegalKernel.FaultProof.Step.kernelStep` byte-for-byte (H).
* `KnomosisFaultProofGame` state transitions match
  `LegalKernel.FaultProof.Game` (H).

The Lean side (`LegalKernel/Test/Bridge/CrossCheck/*` and
`LegalKernel/Test/FaultProof/CrossCheck/*`) generates JSON fixtures
across seven Workstream-F sub-suites plus three Workstream-H
sub-suites. The Solidity side (`solidity/test/CrossCheck/*`)
consumes the fixtures via `vm.readFile` + `vm.parseJson` and
asserts byte equality against the recorded Lean outputs. Per-entry
assertions are gated on the production keccak256 binding being
linked (`isKeccak256Linked`); when running with the FNV fallback
the cross-checks log a skip line and exit cleanly.

To regenerate fixtures (Lean side):

```bash
KNOMOSIS_FIXTURES_OVERWRITE=1 lake test
```

This writes updated fixtures under
`solidity/test/CrossCheck/fixtures/`.

## Workstream E contracts (E.1 – E.5)

### `KnomosisBridge.sol` (E.1)

The L1 escrow for deposits and withdrawals.

| WU     | Function                                             |
|--------|------------------------------------------------------|
| E.1.1  | `depositETH()` / `depositERC20(...)` — deposit entry |
| E.1.2  | `submitStateRoot(...)` — attestor-signed state root  |
| E.1.3  | `withdrawWithProof(...)` — proof-gated redemption    |
| E.1.4  | `circuitOpen` modifier — automatic state-driven halt |
| E.1.5  | `revertToPriorRoot(...)` — dispute-triggered rollback |
| GP.5.1 | `depositETHWithFee(uint16 chosenFeeBps)` — user-chosen fee-split deposit |
| GP.5.4 | `depositBoldWithFee(uint256 amount, uint16 chosenFeeBps)` — BOLD fee-split deposit |

**GP.5.1 fee-split deposit.**  `depositETHWithFee(chosenFeeBps)` lets
the caller pick a fee in basis points within the deployment's
immutable `[minFeeBps, maxFeeBps]` band (capped above by the
constitutional `MAX_FEE_BPS_CAP = 5000`).  `msg.value` splits into a
`userAmount` (credited to the caller on L2) and a `poolAmount` (the
gas-pool fee); the pool credit converts to an action-budget grant at
the immutable `weiPerBudgetUnitEth` rate, clamped at
`MAX_BUDGET_PER_DEPOSIT = 10^12`.  `userAmount + poolAmount =
msg.value` exactly (the floor-division residue favours the user).  The
shared `_registerDepositWithFee` helper is resource-generic so the
GP.5.4 BOLD entry point reuses it.  Coverage:
`test/BridgeFeeSplit.t.sol` (behavioural) and
`test/CrossCheck/DepositFeeSplit.t.sol` (byte-for-byte cross-stack
equivalence against the Lean `deposit_fee_split.json` fixture, via the
`test/utils/FeeSplitMath.sol` reference).

**GP.5.2 constitutional-cap audit gate.**  The three compile-time
fee-split caps — `MAX_FEE_BPS_CAP = 5000` (50% max fee),
`MIN_WEI_PER_BUDGET_UNIT = 1` (rules out divide-by-zero), and
`MAX_BUDGET_PER_DEPOSIT = 10^12` (per-deposit budget-grant ceiling) —
are protected by two independent layers.  The compiled-contract pin
`test/BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned` asserts each
value through the public getter; the source-level grep gate
`scripts/audit_compile_time_caps.sh` (run via `make audit-caps`) fails
before `solc` runs if any literal drifts in `KnomosisBridge.sol`.
The gate reads each cap's value *by name* (anchored on `constant
<name> =`), checks the declared `uintN` width, requires exactly one
declaration, and matches over a comment-stripped view of the source
(so a canonical-looking line hidden in a `//` or multi-line `/* */`
comment cannot mask a drifted real declaration) — so a value change, a
type narrowing, a missing / duplicated declaration, or a comment-masked
drift all fail closed, while a value-preserving underscore reformat
(`1_000_000_000_000` vs `1000000000000`) passes.
`scripts/audit_compile_time_caps_selftest.sh` (run via `make
audit-caps-selftest`) proves those behaviours reproducibly — it
asserts the gate accepts the canonical source and rejects every drift
class — so the tripwire cannot be silently disabled by a later edit.
Both layers run on every Solidity PR via
`.github/workflows/ci-solidity.yml`: the `caps-audit` job runs the gate
+ self-test (no toolchain, fast), and the `forge` job runs the runtime
pin alongside the full suite.  The gate audits `KnomosisBridge.sol` —
the authoritative source of these caps; the derived Solidity mirror in
`test/utils/FeeSplitMath.sol` is held equal to the contract getter by
`test_compileTimeCaps_pinned`, and the Lean mirror by the
`deposit_fee_split.json` cross-stack corpus.  Changing any cap is a
Genesis-Plan §13.6 amendment that triggers the two-reviewer rule; the
gate's `CAPS` table must be updated in the same PR.

**GP.5.4 BOLD fee-split deposit.**  `depositBoldWithFee(amount,
chosenFeeBps)` is the BOLD-currency mirror of `depositETHWithFee`:
identical fee-split arithmetic and the same resource-generic
`_registerDepositWithFee` bookkeeping, but value arrives as the pinned
BOLD ERC-20 via `safeTransferFrom` (with a balance-delta check that
rejects a fee-on-transfer / rebase token, reverting
`BoldTransferAmountMismatch`), the pool credit accrues at
`RESOURCE_ID_BOLD = 1`, and the budget grant uses the immutable
`weiPerBudgetUnitBold` rate.  BOLD support is **opt-in**: the
constructor takes a `boldTokenAddress` that is either `address(0)`
(BOLD disabled — the bridge still deploys on chains without BOLD, and
the entry point reverts `BoldNotEnabled`) or equals the constitutional
pin `BOLD_TOKEN_ADDRESS`
(`0x6440f144b7e50D6a8439336510312d2F54beB01D`), in which case the
constructor additionally cross-checks
`BOLD_TOKEN.symbol() == EXPECTED_BOLD_SYMBOL` (defence-in-depth behind
the address pin — a reverting, absent, or mismatched symbol fails
construction) and requires `weiPerBudgetUnitBold >=
MIN_WEI_PER_BUDGET_UNIT`.  Coverage:
`test/BridgeFeeSplitBold.t.sol` (behavioural mirror of the ETH suite
plus the non-conformant BOLD mocks — fee-on-transfer,
false-returning transfer, wrong / reverting / absent symbol, opt-out)
and `test/CrossCheck/DepositFeeSplitBold.t.sol` (byte-for-byte
cross-stack equivalence against the Lean `deposit_fee_split_bold.json`
fixture, including a live-contract per-entry deposit check), with the
BOLD mocks in `test/utils/MockBold.sol`, and a full end-to-end deposit
-> escrow -> attested-state-root -> finalise -> `withdrawWithProof` ->
replay-rejection lifecycle test.  When BOLD is enabled the constructor
AUTO-BINDS `(RESOURCE_ID_BOLD -> BOLD_TOKEN_ADDRESS)` in the resource map
and reserves both from the deployer's map (`BoldResourceReserved`), so
BOLD withdrawals via `withdrawWithProof` always resolve to the canonical
token with no deployer action and no way to misconfigure (the
`resourceToken(uint64)` getter exposes the binding).  The two BOLD
constitutional pins are guarded both at runtime (`test_boldConstants_pinned`)
and source-level (the GP.5.2 `audit_compile_time_caps.sh` gate, extended
with address / string checks).  The per-currency BOLD circuit breaker +
per-BOLD TVL cap are GP.5.5.

### `KnomosisDisputeVerifier.sol` (E.2)

The v1 L1 dispute pipeline. Three claim variants ship in MVP
(mirroring the Lean `Disputes.Evidence` machinery):

| WU    | Variant                                                      |
|-------|--------------------------------------------------------------|
| E.2.1 | `fileDispute(...)` + CBE-decode helper library               |
| E.2.2 | `checkSignatureInvalid(...)` — re-runs ECDSA recovery        |
| E.2.3 | `checkNonceMismatch(...)` — replays log prefix nonce-only    |
| E.2.4 | `checkDoubleApply(...)` — `(signer, nonce)` collision check  |
| E.2.5 | `finalizeUpheld(...)` — quorum + slash + rollback            |

`preconditionFalse` and `oracleMisreported` are deferred to v2;
adding them requires a new dispute-verifier deployment + migration.

### `KnomosisIdentityRegistry.sol` (E.3)

Mirror of the Lean `KeyRegistry` (Authority/Identity.lean). Two
register entry points: `registerECDSA` for EOAs (verifies
`keccak256(pubkey)[12:] == msg.sender` for front-running
protection); `registerEIP1271` for contract signers (probes
`isValidSignature(bytes32(0), "")` for the canonical magic /
explicit-invalid response).

### `KnomosisSequencerStake.sol` (E.4)

The sequencer's ETH stake escrow. Slashed by the dispute verifier
on `.upheld` finalisation: `slashRatioBps * stake / 10_000` goes
to the challenger; the residual is sent to the immutable burn
address. Withdrawal lock-up enforced via the bridge's
`hasOpenDisputeOlderThan` getter.

### `KnomosisMigration.sol` (E.5)

The one-shot, attested handoff between a predecessor and a
successor `KnomosisBridge`. Replaces the upgradeable-proxy mechanism
that other rollup designs use for code-level recovery.

* `MIN_GRACE_WINDOW_BLOCKS = 216_000` (≈ 30 days @ 12s blocks) —
  a Solidity `constant` baked into the bytecode; cannot be
  weakened by any constructor argument.
* Constructor verifies the predecessor's attestor's ECDSA
  signature over the canonical EIP-712 wrap of the migration
  record.
* Bidirectional consent: constructor asserts
  `predecessor.migration() == address(this)` (the predecessor
  freezes post-activation; the successor remains operational so
  users can interact with it).
* `activated` is one-way; once `true`, never reverts.
* Anyone can call `activate()` after the grace window — no role
  gating.

## Workstream H contracts (fault-proof migration)

Workstream H adds interactive fault proofs as a stronger
alternative to the v1 bot-quorum dispute model. The trust
assumption tightens from "M-of-N bots honest" to
"1-of-anyone honest". The Lean specification lives in
`LegalKernel/FaultProof/`; the operator-facing material is in
[`docs/fault_proof_runbook.md`](../docs/fault_proof_runbook.md).

### `KnomosisStepVM.sol`

The pure, stateless single-step verifier. Given a kernel sub-state
and a signed action, returns the canonical post sub-state. Mirrors
`LegalKernel.FaultProof.Step.kernelStep` byte-for-byte (cross-stack
fixture: `solidity/test/CrossCheck/StepVM.t.sol`).

### `KnomosisStateRootSubmission.sol`

The L1 state-root window. Sequencers post `(stateCommit, bond)`
records; bonds release after the dispute window if no fault proof
unseats them, or get slashed (95% to challenger, 5% to treasury)
if a fault proof wins. Rate-limited via `MIN_SUBMISSION_INTERVAL_BLOCKS`
and bounded by `outstandingRootsCount[sequencer]`.

### `KnomosisFaultProofGame.sol`

The on-chain bisection-game arbiter. Manages dispute rounds:
challenger and sequencer alternate `respond(hash)` calls,
narrowing the disputed interval by 2× each round until they
disagree on a single step. The arbiter then asks `KnomosisStepVM`
to recompute that step and declares the loser. Tracks per-game
bonds; settles `winnerTakesBond` on conclusion.

### `KnomosisDisputeVerifierV2.sol`

The v2 dispute pipeline. Adds a fifth claim variant
(`faultProofWon`) that lets an upheld fault-proof game directly
trigger a rollback in `KnomosisStateRootSubmission`, bypassing the
v1 adjudicator-quorum requirement.

### `KnomosisFaultProofMigration.sol`

The v1 → v2 migration contract. Same attested-handoff pattern as
`KnomosisMigration` but tailored for moving from the
`KnomosisDisputeVerifier` (v1) + `KnomosisBridge` deployment to the
`KnomosisDisputeVerifierV2` + `KnomosisStateRootSubmission` +
`KnomosisFaultProofGame` + `KnomosisStepVM` quartet.

## Production deployment notes

* Use `CREATE3` for all cyclic contracts so cross-references resolve
  to predictable addresses.
* The bridge's `migration` immutable should be set to a *predicted*
  `KnomosisMigration` `CREATE3` address at predecessor deployment time.
  At the initial deployment the predicted address can be
  `address(0)` (no migration planned); future deployments override.
* Run `forge test` on the deployment artefacts as a smoke check
  before proposing on-chain.
* The "no admin surface" assertion in F.3 (testnet acceptance)
  doubles as a safety check that no upgradeable-proxy bytecode has
  accidentally crept in.
* For Workstream-H deployment ordering, sequence is:
  `KnomosisStepVM → KnomosisStateRootSubmission → KnomosisFaultProofGame →
  KnomosisDisputeVerifierV2 → KnomosisFaultProofMigration` (see
  `docs/fault_proof_runbook.md` §2).

## Future: actor-scoped policies (Workstream LP)

Workstream LP (actor-scoped policies) is complete on the Lean side
but the Solidity-side mirror is **not yet implemented**. When
landed, it will require:

  1. A CBE decoder in `solidity/src/lib/CBEDecode.sol` for the
     `LocalPolicy` and `LocalPolicyClause` types, mirroring the
     Lean codec line-for-line with the same DoS bounds
     (`MAX_CLAUSES_PER_POLICY = 64`,
     `MAX_TAGS_PER_DENY = 64`,
     `MAX_RECIPIENTS_PER_REQUIRE = 64`,
     `MAX_POLICY_ENCODE_BYTES = 16_384`).
  2. An admissibility-check call in
     `KnomosisBridge.depositETH` / `depositERC20` that consults the
     depositor's L2 `localPolicies` lookup before crediting
     (defensive layer; the L2 admissibility check already enforces
     this — the Solidity-side check is for fast L1 user feedback).
  3. Two new event-listener mappings for `LocalPolicyDeclared` /
     `LocalPolicyRevoked` in the indexer.

A future `KnomosisDisputeVerifier` extension may add a sixth claim
variant (`localPolicyMisreported`) for adjudicating disputes about
whether a particular L2 transaction violated the actor's declared
policy. See
[`docs/planning/actor_scoped_policies_plan.md`](../docs/planning/actor_scoped_policies_plan.md)
for the full engineering plan and
[`docs/abi.md`](../docs/abi.md) §5.4 for the canonical on-disk byte
layouts.
