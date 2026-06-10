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
# records each operation's PER-CALL gas (`vm.snapshotGasLastCall` — the
# call frame only, no test-harness overhead) plus the exact EIP-2028
# calldata cost of its canonical calldata (`vm.snapshotValue`,
# `<name>.calldata_gas`) into the forge scratch file
# `snapshots/BenchmarkGasV1_3.json` (gitignored; a PARTIAL forge run
# rewrites it with only the entries that ran, so it is never committed
# directly).  The committed baseline is the verified full-run copy below.
#
#   make snapshot-gas          — re-run the suite, promote the fresh
#                                snapshot to the committed baseline, and
#                                regenerate the runbook §9.2 table derived
#                                from it (one command keeps measurement
#                                and documentation in lockstep)
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
SNAPSHOT_GAS_MATCH    = --match-contract BenchmarkGasV1_3

.PHONY: snapshot-gas
snapshot-gas:
	rm -f $(SNAPSHOT_GAS_FRESH)
	FORGE_SNAPSHOT_CHECK=false forge test $(SNAPSHOT_GAS_MATCH)
	cp $(SNAPSHOT_GAS_FRESH) $(SNAPSHOT_GAS_BASELINE)
	python3 scripts/generate_gas_runbook_table.py

.PHONY: snapshot-gas-check
snapshot-gas-check:
	rm -f $(SNAPSHOT_GAS_FRESH)
	FORGE_SNAPSHOT_CHECK=false forge test $(SNAPSHOT_GAS_MATCH)
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

.PHONY: clean
clean:
	forge clean
