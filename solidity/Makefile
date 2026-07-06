# Knomosis Solidity contracts — operator-facing build / test / deploy targets.
# Pinned toolchain: Foundry v1.7.0, solc 0.8.20.

.PHONY: all
all: build test

.PHONY: build
build:
	forge build

.PHONY: test
test:
	forge test

.PHONY: test-cross-stack
test-cross-stack:
	forge test --match-path 'test/CrossCheck/*'

# Line/statement/branch/function coverage.
#
# `--ir-minimum` is REQUIRED: the production contracts (e.g.
# KnomosisStepVM, KnomosisBridge) need `via_ir` to compile (stack-too-deep
# otherwise), but forge's coverage instrumentation cannot rewrite fully
# optimized via_ir output — so `forge coverage` without a flag falls back
# to legacy codegen and dies stack-too-deep.  `--ir-minimum` enables
# via_ir at minimum optimization, which forge CAN instrument.  The test
# harness was made stack-fit for that reduced-optimization path (see
# `test/utils/Deployer.sol`'s `DeployParams` struct + `_deployAll`), so
# this target compiles + runs end-to-end.  `coverage-lcov` emits
# `lcov.info` for CI / IDE consumption.
.PHONY: coverage
coverage:
	forge coverage --ir-minimum --report summary

.PHONY: coverage-lcov
coverage-lcov:
	forge coverage --ir-minimum --report lcov

# Workstream GP.11.9 — gas-cost benchmarks for the v1.3 L1 operations.
#
# The deterministic `BenchmarkGasV1_3` suite (test/BenchmarkGasV1_3.t.sol)
# runs under forge's ISOLATED mode (`--isolate`), in which every
# benchmarked call executes as its own EVM transaction — foundry's
# documented-accurate mode for the `snapshotGas*` cheatcodes.  The
# recorded value is therefore the TRUE end-user transaction gas:
# 21 000 intrinsic + EIP-2028 calldata + execution, with EIP-3529
# refunds netted and the transaction target pre-warmed (EIP-2929),
# exactly as on L1.  (Empirically verified: isolated-vs-unisolated
# deltas decode to the gas to `21 000 + calldata − refunds` on every
# benchmark.)  Each benchmark also records the exact EIP-2028 calldata
# cost of its canonical calldata (`vm.snapshotValue`,
# `<name>.calldata_gas`) so the runbook table can break the total down.
# Both land in the forge scratch file `snapshots/BenchmarkGasV1_3.json`
# (gitignored; a PARTIAL or non-isolated forge run rewrites it, so it
# is never committed directly).  The committed baseline is the
# verified isolated full-run copy below.
#
#   make snapshot-gas          — re-run the suite (isolated), promote
#                                the fresh snapshot to the committed
#                                baseline, and regenerate the runbook
#                                §9.2 table derived from it (one
#                                command keeps measurement and
#                                documentation in lockstep)
#   make snapshot-gas-check    — CI gate: re-runs the suite, then
#                                (a) fails on any per-benchmark gas
#                                INCREASE beyond 5% (the GP.11.9 rule;
#                                one-sided — improvements only WARN, with
#                                a nudge to ratchet them in),
#                                (b) fails on benchmark-set drift (a
#                                benchmark added/removed/renamed without a
#                                regenerated baseline), and
#                                (c) fails if the runbook table is out of
#                                sync with the committed baseline
#   make snapshot-gas-selftest — behavioural self-tests for the gate and
#                                the table generator (pure python3, no
#                                forge), proving the tripwires cannot be
#                                silently disabled
#
# `FORGE_SNAPSHOT_CHECK=false` guards against an exported environment
# override flipping forge's cheatcode snapshots from record mode into its
# built-in exact-match compare mode.  Baselines are stable for the pinned
# (forge 1.7.0, solc 0.8.20, foundry.toml) toolchain; regenerating with a
# different toolchain may shift numbers and fail the check.
SNAPSHOT_GAS_BASELINE = test/BenchmarkGasV1_3.gas-baseline.json
SNAPSHOT_GAS_FRESH    = snapshots/BenchmarkGasV1_3.json
SNAPSHOT_GAS_RUN      = --match-contract BenchmarkGasV1_3 --isolate

.PHONY: snapshot-gas
snapshot-gas:
	rm -f $(SNAPSHOT_GAS_FRESH)
	FORGE_SNAPSHOT_CHECK=false forge test $(SNAPSHOT_GAS_RUN)
	cp $(SNAPSHOT_GAS_FRESH) $(SNAPSHOT_GAS_BASELINE)
	python3 scripts/generate_gas_runbook_table.py

.PHONY: snapshot-gas-check
snapshot-gas-check:
	rm -f $(SNAPSHOT_GAS_FRESH)
	FORGE_SNAPSHOT_CHECK=false forge test $(SNAPSHOT_GAS_RUN)
	python3 scripts/check_gas_baseline.py --baseline $(SNAPSHOT_GAS_BASELINE) --fresh $(SNAPSHOT_GAS_FRESH) --max-increase-pct 5
	python3 scripts/generate_gas_runbook_table.py --check

.PHONY: snapshot-gas-selftest
snapshot-gas-selftest:
	python3 scripts/check_gas_baseline.py --selftest
	python3 scripts/generate_gas_runbook_table.py --selftest

# Workstream GP.5.2 — constitutional fee-split-cap audit gate.
# Pure grep/sed/awk; no solc/forge dependency.  Fails if MAX_FEE_BPS_CAP,
# MIN_WEI_PER_BUDGET_UNIT, or MAX_BUDGET_PER_DEPOSIT drift from their
# canonical values in KnomosisBridge.sol.  Changing any value is a
# Genesis-Plan §13.6 amendment + two-reviewer rule.
.PHONY: audit-caps
audit-caps:
	./scripts/audit_compile_time_caps.sh

# Self-test for the cap audit gate: proves the tripwire ACCEPTS the
# canonical source and REJECTS every drift class (value / type /
# missing / duplicate), guarding against a future edit that silently
# disables the gate.  Pure bash; no solc/forge dependency.
.PHONY: audit-caps-selftest
audit-caps-selftest:
	./scripts/audit_compile_time_caps_selftest.sh

.PHONY: vendor-deps
vendor-deps:
	./scripts/vendor-deps.sh

# Workstream F.3 — testnet acceptance.
#
# Required environment variables for a real testnet run:
#   RPC_URL         — Sepolia / Holesky RPC endpoint
#   PRIVATE_KEY     — deployer EOA's private key
#   KNOMOSIS_ATTESTOR  — production attestor address
#   KNOMOSIS_SEQUENCER — production sequencer address
#   KNOMOSIS_ADJUDICATOR — production adjudicator-multisig base address
#                       (the script derives 3 from this base)
#
# Optional tuning variables (defaults match testnet):
#   KNOMOSIS_DISPUTE_WINDOW    (default 50,400 blocks ≈ 7d)
#   KNOMOSIS_MAX_REDEMPTION    (default 2,628,000 blocks ≈ 1y)
#   KNOMOSIS_ATTEST_STALE      (default 7,200 blocks ≈ 1d)
#   KNOMOSIS_COOLDOWN          (default 7,200 blocks ≈ 1d)
#   KNOMOSIS_TVL_CAP           (default 100,000 ether)
#   KNOMOSIS_SLASH_BPS         (default 5,000 = 50%)
.PHONY: testnet-acceptance
testnet-acceptance:
	@if [ -z "$$RPC_URL" ]; then \
		echo "error: RPC_URL not set" >&2; exit 1; \
	fi
	forge script script/TestnetAcceptance.s.sol \
		--rpc-url $$RPC_URL \
		--broadcast \
		--slow

# Local dry-run against an in-memory anvil fork.  Useful for
# operator validation before committing to a broadcast.
.PHONY: testnet-acceptance-dryrun
testnet-acceptance-dryrun:
	forge script script/TestnetAcceptance.s.sol

# Local devnet end-to-end: spins up a LIVE anvil node, BROADCAST-deploys
# the full suite to it, and verifies against the DEPLOYED contracts
# (on-chain bytecode + live reads) — the live-node counterpart to the
# in-memory dry-run above (closes docs/testnet_readiness.md §3.4).
.PHONY: devnet
devnet:
	./scripts/local_devnet.sh

# ---------------------------------------------------------------------------
# Unified public-testnet deployment (Sepolia) — see
# docs/sepolia_deployment_runbook.md.
#
# `DeploySepolia.s.sol` deploys the FULL production suite (9 genesis
# contracts) as individual transactions via plain-nonce CREATE prediction —
# no `test/utils/Deployer` bundler, so NO `--disable-code-size-limit` — and
# emits a machine-readable manifest at `deployments/<network>.json` that the
# L2 daemon stack, the gateway, and the Licio client consume.
#
# Required env for a real broadcast:
#   SEPOLIA_RPC_URL   — Sepolia JSON-RPC endpoint (resolved by the `sepolia`
#                       rpc alias in foundry.toml)
#   PRIVATE_KEY       — funded deployer EOA key (or edit for --account/--ledger)
#   ETHERSCAN_API_KEY — for --verify source-verification
# Actor addresses (attestor/sequencer/treasury/adjudicator/BOLD roles) and the
# economic parameters are env-driven with testnet-sane defaults; size them per
# docs/deployment_parameters.md.  Set KNOMOSIS_BOLD_TOKEN to the Sepolia BOLD
# test token to enable the BOLD + AMM legs (off-mainnet the chain-conditional
# bridge accepts an operator-supplied symbol-validated token).
.PHONY: deploy-sepolia-dryrun
deploy-sepolia-dryrun:
	mkdir -p deployments
	forge script script/DeploySepolia.s.sol

# Signer selection keeps the funded key OUT of argv / `ps` / `/proc`:
#   KNOMOSIS_DEPLOYER_ACCOUNT — a Foundry keystore account name (RECOMMENDED;
#     import once with `cast wallet import <name> --interactive`; forge prompts
#     for the password, so the key never enters the process listing).
#   PRIVATE_KEY — a raw hex key.  FALLBACK for a NO-VALUE shadow testnet ONLY
#     (it is visible via `ps`/`/proc` for the duration of the broadcast) —
#     never use it for a key holding real value.
.PHONY: deploy-sepolia
deploy-sepolia:
	@if [ -z "$$SEPOLIA_RPC_URL" ]; then echo "error: SEPOLIA_RPC_URL not set" >&2; exit 1; fi
	mkdir -p deployments
	@if [ -n "$$KNOMOSIS_DEPLOYER_ACCOUNT" ]; then \
		forge script script/DeploySepolia.s.sol --rpc-url sepolia --broadcast --verify --slow --account "$$KNOMOSIS_DEPLOYER_ACCOUNT"; \
	elif [ -n "$$PRIVATE_KEY" ]; then \
		echo "WARNING: PRIVATE_KEY is passed on the command line (ps/proc-visible). Prefer KNOMOSIS_DEPLOYER_ACCOUNT (a forge keystore) for a funded key." >&2; \
		forge script script/DeploySepolia.s.sol --rpc-url sepolia --broadcast --verify --slow --private-key "$$PRIVATE_KEY"; \
	else \
		echo "error: set KNOMOSIS_DEPLOYER_ACCOUNT (a forge keystore, recommended) or PRIVATE_KEY (raw key, shadow-testnet only)" >&2; exit 1; \
	fi

# Local live-anvil deploy of the FULL BOLD+AMM suite against an in-script
# MockBold (non-mainnet only).  Requires a running `anvil` on 127.0.0.1:8545.
.PHONY: deploy-local
deploy-local:
	mkdir -p deployments
	forge script script/DeploySepoliaLocal.s.sol \
		--rpc-url anvil --broadcast \
		--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.PHONY: clean
clean:
	forge clean
