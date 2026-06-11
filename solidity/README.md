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
│   │   ├── KnomosisFaultProofMigration.sol (H)   — v1 → v2 migration
│   │   └── KnomosisAmmDisasterRecoveryMultisig.sol (GP.11.10) — 3-of-N AMM kill-switch quorum
│   ├── interfaces/                            — public interface files (E.1-E.5, GP.11.10)
│   └── lib/
│       ├── KnomosisEip712.sol      — EIP-712 domain + struct-hash helpers
│       ├── CBEDecode.sol        — CBE byte decoder (mirrors Lean)
│       ├── SmtVerifier.sol      — withdrawal-tree SMT verifier (D.1, depth 64)
│       ├── SmtCellVerifier.sol  — state-cell SMT verifier (SC.2, depth 256)
│       ├── CREATE3.sol          — proxy-factory deploy for cyclic refs
│       └── StepVMMerkle.sol     — per-cell proof helpers (H + SC.2)
├── scripts/
│   ├── audit_compile_time_caps*.sh   — GP.5.2 cap gate + self-test
│   ├── check_gas_baseline.py         — GP.11.9 gas-regression gate
│   ├── generate_gas_runbook_table.py — GP.11.9 runbook-table generator
│   └── vendor-deps.sh                — pinned dependency vendoring
└── test/
    ├── *.t.sol                  — per-contract unit suites (incl. the
    │                               GP.11.9 BenchmarkGasV1_3 gas benchmarks)
    ├── BenchmarkGasV1_3.gas-baseline.json — committed GP.11.9 gas baseline
    ├── CrossCheck/*.t.sol       — cross-stack suites (Lean ↔ Solidity)
    └── utils/                   — Deployer.sol (CREATE3 harness),
                                    MockERC20.sol, MockBold.sol,
                                    MockBoldOz.sol, MockLiquityV2.sol
```

Total: **~825 forge tests passing across 55 suites** (`forge test`;
fuzz and property tests additionally report per-test run counts). A
subset is conditionally skipped when the production keccak256 binding
is not linked (the cross-check suites probe `isKeccak256Linked` on
the Lean side and skip on the fallback).

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
make snapshot-gas-check           # GP.11.9 gas-benchmark regression gate
make snapshot-gas                 # regenerate the GP.11.9 baseline + runbook table
make snapshot-gas-selftest        # self-tests for the GP.11.9 gate + generator
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
`[profile.ci]` (`FOUNDRY_PROFILE=ci`, fuzz = 1000), followed by the
GP.11.9 gas-benchmark regression gate (`make snapshot-gas-check` —
re-runs the deterministic `BenchmarkGasV1_3` suite and fails on any
per-benchmark gas increase beyond 5% over the committed
`test/BenchmarkGasV1_3.gas-baseline.json`, on benchmark-set drift, or
on a runbook table out of sync with the baseline; improvements beyond
5% warn).  The gate's behavioural self-tests
(`make snapshot-gas-selftest`; pure python3) run in the fast
`caps-audit` job.  The split keeps the fast tripwires independent of
the slower contract build.

## Immutability discipline

Per §4.8 / §20 of the integration plan, every contract here is
deployed immutably:

* **No proxy.** Each contract goes straight to its final address
  (mainnet via `CREATE2` with deterministic salts; tests via
  `CREATE3` to break cyclic references between bridge, verifier,
  stake, and the fault-proof game).
* **No `initialize`.** Constructors set every field; nothing is
  later mutable.
* **No generic admin role.** Each cross-contract authority is
  encoded as `address public immutable`.  The one human-operator
  surface is the GP.5.5 BOLD safety hardening: the immutable
  `boldCircuitBreaker` / `boldAdmin` roles can pause/resume the BOLD
  *deposit* leg (`closeBoldCircuit` / `openBoldCircuit`) and tune the
  per-BOLD TVL cap within `[0, tvlCap]` (`setBoldTvlCap`) — and
  nothing else.  They cannot move funds, alter state roots, change
  any immutable, touch the ETH leg, or halt withdrawals.  This is a
  tightly-scoped guardian, not an owner; least privilege is enforced
  by separate roles (the breaker cannot set the cap; the admin cannot
  pause).
* **No `pause()` function.** Whole-system halts use the automatic
  circuit breakers in `KnomosisBridge.sol` (§9.1.4): `AttestationStale`,
  `DisputeCooldown`, `TvlCapReached`, `MigrationActivated`. Each
  fires on a deterministic public-state predicate; no privileged
  caller is involved.  (The GP.5.5 `boldCircuitClosed` breaker above
  is BOLD-deposit-scoped and operator-toggleable; it deliberately
  does *not* halt withdrawals — the standard "deposits halted,
  withdrawals continue" posture during a BOLD depeg incident.)
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
| GP.5.5 | `closeBoldCircuit()` / `openBoldCircuit()` / `closeBoldCircuitIfAnyLiquityBranchShutdown()` / `setBoldTvlCap(uint256)` — BOLD circuit breaker + per-BOLD TVL cap |
| GP.11.1 | `ammReserveEth()` / `ammReserveBold()` / `ammSeedRatioBps()` — embedded-AMM L1 state scaffold (reserves + immutable seed ratio) |
| GP.11.2 | deposit-side AMM seeding — `_registerDepositWithFee` routes `floor(poolAmount * ammSeedRatioBps / 10000)` of each fee-split deposit into the matching reserve; the split is carried in `DepositWithFeeInitiated.ammSeedAmount` and bound in the `receiptHash` |
| GP.11.3 | `ammSwap(uint64 fromResource, uint256 amountIn, uint256 minAmountOut, uint256 deadline)` — permissionless constant-product ETH↔BOLD swap over the embedded reserves; `emergencyDisableAmm()` — one-way AMM kill switch (`ammDisasterRecovery` role) |
| GP.11.9 | gas-cost benchmarks — `test/BenchmarkGasV1_3.t.sol` (per-call gas + exact calldata cost) + committed `test/BenchmarkGasV1_3.gas-baseline.json` + `make snapshot-gas{,-check,-selftest}` + one-sided >5%-increase CI gate + generated runbook table |

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
gate's `CAPS` table must be updated in the same PR.  GP.5.5 extends the
same gate with three address pins for the constitutional Liquity V2
per-branch TroveManagers (`LIQUITY_V2_TROVE_MANAGER_ETH /
_WSTETH / _RETH` — the contracts whose `shutdownTime()` the BOLD
auto-trigger reads) AND a fourth uintN cap
(`LIQUITY_ORACLE_READ_GAS = 100k` — the per-TroveManager staticcall
gas cap that bounds malicious-callee griefing), all under the
identical dual-layer protection (source gate + runtime pins
`test_troveManagerConstants_pinned` / `test_liquityOracleReadGas_pinned`);
the self-test grows to 37 cases (includes a multi-line-declaration
tolerance check that confirms the gate handles forge-fmt-wrapped
address pins correctly).  GP.11.1 adds two more constitutional caps to
the same gate — `AMM_SWAP_FEE_BPS = 30` (the 0.30% Uniswap-v2-standard
embedded-AMM swap fee) and `MAX_AMM_SEED_RATIO_BPS = 8000` (the 80% cap
on the deposit→AMM seed ratio) — bringing it to 6 caps + 4 address
pins + 1 symbol pin, with the runtime pin
`test/AmmStorage.t.sol::test_ammCompileTimeCaps_pinned` and the
self-test at 45 cases.

**GP.11.1 embedded-AMM state scaffold.**  `KnomosisBridge.sol` declares
the embedded ETH↔BOLD AMM's L1 state: the two mutable reserve slots
`ammReserveEth` / `ammReserveBold` (no direct setter — seeded on deposit
in GP.11.2, mutated by `ammSwap` in GP.11.3), the immutable
`ammSeedRatioBps` (the bps fraction of each pool-fee deposit routed to
AMM liquidity, a new `ConstructorArgs` field validated
`<= MAX_AMM_SEED_RATIO_BPS` at construction — `AmmSeedRatioExceedsMax`
otherwise), and the two constitutional caps above.  GP.11.1 added only
the storage scaffold (the seeding lands in GP.11.2, below); a value of
`ammSeedRatioBps = 0` disables the AMM and preserves the pre-v1.3
behaviour byte-for-byte (every existing `ConstructorArgs` initializer
passes `0`).  Coverage: `test/AmmStorage.t.sol` (16 cases — caps pinned,
seed-ratio store/validate incl. the `> MAX` reverts and an accept/reject
fuzz pair, reserves start at zero with the seed as their sole write path,
a no-AMM-setter-selector probe for the "no admin mutation surface"
criterion, the ratio-invariance of the canonical deposit event, and a
constructor-guard ordering pin).

**GP.11.2 deposit-side AMM seeding.**  The shared `_registerDepositWithFee`
now seeds the AMM from each fee-split deposit's pool fee via the
`private _seedAmmReserves(resourceId, poolAmount)` helper:
`ammSeedAmount = floor(poolAmount * ammSeedRatioBps / 10000)` (0 when the
AMM is disabled, the seed floors to zero, or the resource is off the
ETH/BOLD gas legs) is added to the matching reserve, leaving the implicit
free-pool remainder `poolAmount - ammSeedAmount`.  Conservation is exact
(`userAmount + ammSeedAmount + freePoolAmount = deposit`), and the seed is
a reclassification of value already in `totalLockedValue`, so
`ammReserveEth + ammReserveBold <= totalLockedValue` (a Foundry invariant).
Checked arithmetic throughout (`ammSeedRatioBps <= MAX_AMM_SEED_RATIO_BPS =
8000 < 10000` ⇒ the seed never exceeds the pool fee).  The split is carried
in the canonical `DepositWithFeeInitiated` event — Workstream GP.11.2
inserts a `uint256 ammSeedAmount` field after `poolAmount` — and BOUND in
the `receiptHash` (`keccak256(abi.encode(deploymentId, sender, resourceId,
token, userAmount, poolAmount, ammSeedAmount, budgetGrant, depositorNonce))`),
so the L2 reconstructs `freePoolAmount = poolAmount - ammSeedAmount` from one
event and a replay with a tampered split is rejected (the receiptHash is
sensitive to `ammSeedAmount`).  This bumps the event's topic-0 hash and the
receiptHash preimage (a v1.3 wire addition), propagated cross-stack in
lockstep to the Rust ingestor (`knomosis-l1-ingest`: pinned topic +
`decode_event` offsets + `amm_seed_amount` variant field) and the
`deposit_fee_split{,_bold}.json` receiptHash corpora (whose 64 randomised
entries now draw a random `ammSeedRatioBps ∈ [0, 8000]`, so the binding is
cross-stack-verified with non-zero seeds — and pinned against a generator
regression by the `countNonZeroSeed` header, which each consumer
independently recounts and asserts).  Coverage:
`test/AmmDepositSeeding.t.sol` (~26 cases — per-leg seeding via the event's
`ammSeedAmount`, the disabled / zero-fee / dust `ammSeedAmount == 0` paths,
`test_receiptHash_bindsAmmSeedAmount` + the BOLD-leg
`test_boldReceiptHash_bindsAmmSeedAmount` (tamper-evidence), leg
independence, monotonic accumulation, the reserve-subset-of-TVL bound,
`test_cappedDeposit_revertsAndDoesNotSeed` + `test_plainDepositETH_doesNotSeed`
(negative paths), `test_seedAmmReserves_offLeg_seedsNothing` (the off-gas-leg
branch via a harness), `test_ammSeedSplit_knownVectors` (a non-circular
hand-computed anchor for the reference), `test_gas_seedingOverhead` (a
COMPARATIVE gas pin: enabled − disabled overhead, far tighter than an
absolute envelope), three conservation fuzz tests, and a 7-invariant
stateful suite (reserve == sum-of-admitted-seeds per leg, global reserves <=
TVL, two per-currency reserve <= per-currency TVL bounds, + two REAL-TOKEN
backing bounds — `ammReserveEth <= bridge ETH balance` / `ammReserveBold <=
bridge BOLD balance`, proving the reserve is backed by actual tokens, not
just the TVL accounting) over 128 000 random ETH+BOLD deposits at a moderate
cap), plus the AMM-enabled
`BridgeFeeSplitBold.t.sol::test_e2e_ammReserveSurvivesBoldWithdrawal`
end-to-end test (deposit seeds the reserve; a withdrawal drains all non-seed
value, proving `ammReserveBold <= boldTotalLockedValue <= totalLockedValue`
survives a withdrawal with the seed as the irreducible TVL floor) and the
`ammSeedSplit`
reference in `test/utils/FeeSplitMath.sol`.

*Integrator / operator notes.*  (1) The canonical event carries the
per-deposit seed (`ammSeedAmount`), not the resulting reserve balance; an
indexer tracking the reserve CURVE accumulates `ammSeedAmount` across
deposits, or reads the current reserve from the `ammReserveEth()` /
`ammReserveBold()` getters (the design deliberately folds the split into the
single canonical event rather than emitting a separate Uniswap-style
`Sync`).  (2) GP.11.2 changed the `DepositWithFeeInitiated` topic-0 hash
(`0xdffb2055…e4c8f5`) and its `receiptHash` preimage (the v1.3 wire
addition).  Any off-chain consumer pinned to the pre-GP.11.2 topic must
re-pin to the new one (the bundled Rust `knomosis-l1-ingest` already does);
an AMM-disabled deployment emits the same new event with `ammSeedAmount ==
0`, so there is no behavioural difference beyond the wire format.

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
with address / string checks).

**GP.5.5 BOLD safety hardening.**  Three BOLD-specific defence-in-depth
mechanisms not present for the ETH leg, all gated by tightly-scoped
immutable operator roles with strict least-privilege separation
(`boldCircuitBreaker` — hot pause key — and `boldAdmin` — cold
cap-tuning key — MUST be distinct addresses AND neither may be the
bridge itself; `BoldRolesNotDistinct` / `BoldRoleIsBridge` enforce):

1. **Per-currency circuit breaker.**  `closeBoldCircuit()` /
   `openBoldCircuit()` (`onlyBoldCircuitBreaker`) toggle
   `boldCircuitClosed`, which the `boldCircuitOpen` modifier on
   `depositBoldWithFee` enforces.  A closed BOLD circuit halts *only*
   BOLD deposits — ETH deposits and *all* withdrawals (including BOLD)
   keep working (the "deposits halted, withdrawals continue" posture
   used by established bridges during a depeg event).
2. **Liquity-V2 branch-shutdown auto-trigger.**
   `closeBoldCircuitIfAnyLiquityBranchShutdown()` is permissionless and
   opt-in per deployment (`enableLiquityAutoCircuitTrigger`): it reads
   `shutdownTime()` from each of the three constitutionally-pinned
   Liquity V2 collateral-branch TroveManagers
   (`LIQUITY_V2_TROVE_MANAGER_ETH` / `_WSTETH` / `_RETH` — addresses
   pinned as compile-time `address public constant` under the GP.5.2
   audit gate) and closes the circuit if *any* branch reports a
   non-zero `shutdownTime` (the canonical Liquity-V2 on-chain signal
   that a collateral branch has been wound down — oracle failure,
   governance vote, etc.).  Early-return on first detection saves gas
   on the close path and records the first-detected branch's address
   + `shutdownTime` in the event for monitoring.  Each read is made
   via low-level `staticcall` with strict `success` +
   `returndata.length == 32` guards AND a 100k-gas forwarding cap
   (`LIQUITY_ORACLE_READ_GAS`), so EVERY oracle fault (revert, absent
   code, wrong / oversized return, mutating-callee under staticcall,
   gas griefing) routes uniformly to a clean `LiquityV2ReadFailed` —
   a single auditable signal to fall back to manual mode.  The
   staticcall context also forbids any SSTORE in the inner frame, so
   a re-entrant TroveManager cannot corrupt bridge state by EVM
   construction.  The call is idempotent when already closed.
3. **Per-BOLD TVL cap.**  `boldTotalLockedValue` tracks net BOLD
   (deposits − withdrawals) separately from the global
   `totalLockedValue`; `_registerDepositWithFee` rejects a BOLD
   deposit that would push it past `boldTvlCap`, and
   `withdrawWithProof` decrements it on a BOLD redemption.  `boldTvlCap`
   is set initially in the constructor and adjustable by `boldAdmin`
   via `setBoldTvlCap`, bounded above by the global `tvlCap` so the
   per-BOLD cap can only *tighten* the deployment's reserve
   commitment; it defaults to 0 (fails closed) when a deployer leaves
   it unset.

Coverage: `test/BoldCircuitBreaker.t.sol` (85 cases incl. a stateful
Foundry-invariant suite — manual + auto circuit toggling, access
control + least-privilege separation + roles-not-distinct +
role-is-bridge + TM-distinctness constructor guards, per-branch
shutdown detection across all three Liquity branches, multi-shutdown
short-circuit, all-healthy revert, the per-BOLD cap composing with
the global cap, fail-closed at cap 0, the per-branch oracle-fault /
idempotency paths, two end-to-end tests proving withdrawals continue
while the circuit is closed and that the per-BOLD counter decrements
on withdrawal, four fuzz tests (cap invariant + any-branch-shutdown
with event-content assertion + setter bounds + constructor bounds),
per-branch oracle-fault tests for FOUR fault classes (wrong-size /
oversized / revert / code-removed) × three branches = 12 cases,
three mutating-callee tests proving the staticcall context blocks
SSTORE, three constructor-revert-ordering pins, a malicious-BOLD
reentrancy attack test on `depositBoldWithFee`, two grief-bounded
gas tests pinning the `LIQUITY_ORACLE_READ_GAS` cap, seven
gas-regression smoke tests, and three Foundry-invariant tests
(`boldTotalLockedValue <= totalLockedValue`,
`boldTotalLockedValue == sum of admitted deposits`,
`boldTvlCap <= tvlCap`) driven by a `BoldHandler` over 128 000 random
call sequences), with the programmable Liquity oracles in
`test/utils/MockLiquityV2.sol` (five variants:
`MockLiquityV2TroveManager`, `WrongSizeLiquityV2`, `OversizedLiquityV2`,
`ReentrantLiquityV2`, `MutatingLiquityV2`) and the `ReentrantBold`
mock in `test/utils/MockBold.sol`.  The operator runbook
(`docs/gas_pool_runbook.md`) documents when to close / reopen the
circuit and the branch-shutdown signal calibration.

**GP.11.9 gas-cost benchmarks.**  `test/BenchmarkGasV1_3.t.sol` pins a
deterministic gas baseline for every v1.3 L1 operation and the
round-trip exit legs: `depositETHWithFee` / `depositBoldWithFee` in
first-deposit and repeat shapes, the BOLD `approve` prerequisite,
`ammSwap` in both directions and BOTH approval shapes (exact, and
infinite — measured against the OZ-faithful `MockBoldOz`, whose
`_spendAllowance` skips the allowance write at max allowance exactly
like production BOLD), migration-wired variants (a deployment that
pre-wires a `KnomosisMigration` successor pays an external
`activated()` read per `circuitOpen` operation and per swap — measured
at ~3.1k gas), the BOLD circuit-breaker surface, the Liquity
auto-trigger's fast / worst / no-shutdown paths, `emergencyDisableAmm`,
`withdrawWithProof` on both legs (canonical 64-sibling SMT proof), and
a plain-`depositETH` v1.0 reference row — 21 benchmarks across 9
scenario contracts.  The suite runs under forge's
isolated mode (`--isolate`, enforced by the make targets), so each
`vm.snapshotGasLastCall` value is the FULL user-transaction gas
(intrinsic + calldata + execution, EIP-3529 refunds netted; deltas
land exactly on EVM constants, e.g. the first-interaction premium is
precisely the 17 100-gas zero→non-zero SSTORE surcharge), plus the
exact EIP-2028 calldata cost of its canonical calldata
(`vm.snapshotValue`, `<name>.calldata_gas`) as a breakdown, with
companion `test_sanity_*` tests pinning every scenario assumption.  The
committed baseline (`test/BenchmarkGasV1_3.gas-baseline.json`) and the
runbook §9.2 table generated from it
(`scripts/generate_gas_runbook_table.py`) are regenerated together by
`make snapshot-gas`; the `make snapshot-gas-check` CI gate
(`scripts/check_gas_baseline.py`) fails on any per-benchmark gas
increase beyond 5% (one-sided, per the GP.11.9 plan rule), on
benchmark-set drift, and on a stale runbook table, while improvements
beyond 5% warn (ratchet them in).  Both scripts carry behavioural
self-tests (`make snapshot-gas-selftest`).  Operator-facing numbers
and the $-cost methodology live in `docs/gas_pool_runbook.md` §9.

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

## Workstream GP.11.10 contract (AMM disaster recovery)

### `KnomosisAmmDisasterRecoveryMultisig.sol`

The reference 3-of-N multisig for the bridge's `ammDisasterRecovery`
kill-switch role (operator + community representatives + auditor per
the GP.11.10 custody spec).  Single-purpose by construction: its only
capability is calling `emergencyDisableAmm()` on the immutable
`bridge` once `threshold` distinct signers confirm within one
7-day confirmation round.

* `MIN_DISABLE_THRESHOLD = 3` — the 3-of-N floor is
  constructor-enforced (`ThresholdBelowMinimum` otherwise), not a
  deployment-checklist promise.
* The threshold-th `confirmDisable()` fires the bridge call
  atomically — in a disaster the final signature IS the trigger; no
  separate execute step to forget, grief, or front-run.
* `revokeConfirmation()` lets a signer stand down; stale approvals
  additionally expire as a group (`CONFIRMATION_WINDOW = 7 days`,
  O(1) round-roll), so approvals from one incident can never combine
  with a later signature to fire the one-way switch out of context.
* Wiring: deploy the multisig against the *predicted* bridge CREATE
  address, then the bridge with
  `ammDisasterRecovery = address(multisig)` — the same pre-wiring
  pattern as predicted `KnomosisMigration` successors.  Operator
  procedure: `docs/gas_pool_runbook.md` §10.

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
