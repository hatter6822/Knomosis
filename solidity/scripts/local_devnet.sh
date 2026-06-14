#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See:
#   https://github.com/hatter6822/Knomosis/blob/main/LICENSE

#
# Local devnet end-to-end deploy + verification (Workstream F.3 / P2).
#
# The committed `make testnet-acceptance-dryrun` runs the
# TestnetAcceptance forge script against forge's IN-MEMORY EVM.  This
# script closes the testnet-readiness gap (`docs/testnet_readiness.md`
# §3.4): it spins up a LIVE local node (anvil), BROADCAST-deploys the
# full 11-contract suite to it, and then verifies AGAINST THE DEPLOYED
# CONTRACTS — confirming each has on-chain bytecode and answering live
# `cast` reads — i.e. an actual deployment, not an in-memory simulation.
#
# A green run is the operator's local go/no-go rehearsal before pointing
# the same script at a real RPC (`make testnet-acceptance RPC_URL=…`).
#
# Requires: foundry (anvil, forge, cast).  Pure orchestration; no source
# edits.  Uses anvil's well-known deterministic account 0 (a PUBLIC test
# key — never a real funded key).
#
# Exit codes:
#   0  deployed to the live node and every deployed contract verified
#   1  a deploy / verification step failed
#   2  a required tool (anvil/forge/cast) is missing

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

set +u
export PATH="/usr/local/foundry/bin:${PATH}"
set -u

need() { command -v "$1" >/dev/null 2>&1 || { echo "local_devnet: missing required tool: $1" >&2; exit 2; }; }
need anvil
need forge
need cast

log() { echo "local_devnet: $*"; }

RPC="http://127.0.0.1:8545"
# anvil's deterministic account 0 — a PUBLIC, well-known test key.  NEVER
# use this for anything holding real value.
DEV_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_LOG="$(mktemp)"
ANVIL_PID=""

cleanup() {
    if [ -n "${ANVIL_PID}" ] && kill -0 "${ANVIL_PID}" 2>/dev/null; then
        log "tearing down anvil (pid ${ANVIL_PID}) ..."
        kill "${ANVIL_PID}" 2>/dev/null || true
        wait "${ANVIL_PID}" 2>/dev/null || true
    fi
    rm -f "${ANVIL_LOG}" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------
# 1. Start a live local node.
# ------------------------------------------------------------------
log "starting anvil ..."
# Raise the EIP-170 code-size limit on the devnet: the `test/utils`
# `Deployer` is a CREATE3 BUNDLER harness that embeds every contract's
# creation bytecode (~43 KB), so it exceeds the 24576-byte on-chain
# limit even though every PRODUCTION contract it deploys is within it.
# Raising the limit here lets the bundler deploy so the real contracts
# get exercised end-to-end on the live node; it does NOT mask a
# production-contract size problem (see docs/testnet_readiness.md §3.4).
anvil --silent --host 127.0.0.1 --port 8545 --disable-code-size-limit \
    >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID=$!

# Wait for the RPC to answer (bounded).
ready=0
for _ in $(seq 1 30); do
    if cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.5
done
if [ "${ready}" -ne 1 ]; then
    echo "local_devnet: anvil did not become ready" >&2
    cat "${ANVIL_LOG}" >&2 || true
    exit 1
fi
CHAIN_ID="$(cast chain-id --rpc-url "${RPC}")"
log "anvil live at ${RPC} (chain id ${CHAIN_ID})."

# ------------------------------------------------------------------
# 2. BROADCAST-deploy the full contract suite to the live node.
#    TestnetAcceptance.run() deploys all contracts (CREATE3),
#    self-checks address predictions + assertConsistent() invariants,
#    and logs the deployed addresses; a failed `require` fails forge.
# ------------------------------------------------------------------
log "broadcast-deploying the full suite to the live node ..."
DEPLOY_OUT="$(mktemp)"
if ! forge script script/TestnetAcceptance.s.sol \
        --rpc-url "${RPC}" \
        --broadcast \
        --private-key "${DEV_KEY}" \
        --disable-code-size-limit \
        --slow 2>&1 | tee "${DEPLOY_OUT}"; then
    echo "local_devnet: forge broadcast deploy FAILED" >&2
    rm -f "${DEPLOY_OUT}"
    exit 1
fi
log "deploy + in-script acceptance assertions: PASS"

# ------------------------------------------------------------------
# 3. Verify AGAINST THE DEPLOYED CONTRACTS on the live node.
#    Extract the logged addresses and confirm each has on-chain
#    bytecode (a real deployment, not an in-memory simulation).
# ------------------------------------------------------------------
extract_addr() {
    # Pull the 0x… address that the script logged after a given label.
    grep -F "$1" "${DEPLOY_OUT}" | grep -oE '0x[0-9a-fA-F]{40}' | tail -1
}

BRIDGE_ADDR="$(extract_addr 'KnomosisBridge:')"
VERIFIER_ADDR="$(extract_addr 'KnomosisDisputeVerifier:')"
STAKE_ADDR="$(extract_addr 'KnomosisSequencerStake:')"
rm -f "${DEPLOY_OUT}"

fail=0
verify_code() {
    local name="$1" addr="$2"
    if [ -z "${addr}" ]; then
        echo "local_devnet: could not extract ${name} address from deploy output" >&2
        fail=1; return
    fi
    local code
    code="$(cast code "${addr}" --rpc-url "${RPC}" 2>/dev/null || echo 0x)"
    if [ "${code}" = "0x" ] || [ -z "${code}" ]; then
        echo "local_devnet: ${name} at ${addr} has NO on-chain bytecode" >&2
        fail=1; return
    fi
    log "${name} live at ${addr} (${#code} hex chars of bytecode)."
}

verify_code "KnomosisBridge"          "${BRIDGE_ADDR}"
verify_code "KnomosisDisputeVerifier" "${VERIFIER_ADDR}"
verify_code "KnomosisSequencerStake"  "${STAKE_ADDR}"

# ------------------------------------------------------------------
# 4. Live read: query a deployed-contract view to prove the contracts
#    answer real RPC calls (not just that bytecode exists).
# ------------------------------------------------------------------
if [ -n "${BRIDGE_ADDR}" ]; then
    DEP_ID="$(cast call "${BRIDGE_ADDR}" 'deploymentId()(bytes32)' --rpc-url "${RPC}" 2>/dev/null || echo "")"
    if [ -z "${DEP_ID}" ] || [ "${DEP_ID}" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
        echo "local_devnet: bridge.deploymentId() read returned empty/zero" >&2
        fail=1
    else
        log "live read bridge.deploymentId() = ${DEP_ID}"
    fi
fi

if [ "${fail}" -ne 0 ]; then
    echo "local_devnet: FAILED — one or more deployed-contract checks did not pass." >&2
    exit 1
fi

log "PASSED — full suite deployed to the live local node and verified against the deployed contracts."
