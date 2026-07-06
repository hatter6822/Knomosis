<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis — Sepolia Deployment + Licio Gateway Integration Runbook

**Status:** operator runbook for a **shadow / test** deployment of the full
Knomosis stack to the **Ethereum Sepolia testnet** (chain id `11155111`), so
the [Licio](https://github.com/hatter6822/Licio) client (a React 19 PWA + Hono
BFF) can implement full integration testing against the Knomosis **gateway**.

This runbook is a sibling of `docs/fault_proof_runbook.md`,
`docs/gas_pool_runbook.md`, and `docs/gateway_runbook.md`.  It owns the
end-to-end operator procedure; the design lives in
`docs/GENESIS_PLAN.md`, parameter sizing in `docs/deployment_parameters.md`,
the go/no-go gate in `docs/testnet_readiness.md`, and the gateway API in
`docs/api/gateway.openapi.yaml`.  `docs/DEVELOPMENT.md` §11 is the short
overview that points here.

---

## 0. Topology — what talks to what

```
      L1 (Ethereum Sepolia)                    L2 (Knomosis)                 Client
 ┌──────────────────────────────┐      ┌────────────────────────────┐   ┌──────────┐
 │ KnomosisBridge (custody)      │◄─────┤ knomosis-host (sequencer)  │   │  Licio   │
 │ KnomosisIdentityRegistry      │      │   admit → append event log │   │  Hono    │
 │ KnomosisStateRootSubmission   │◄────►│ knomosis-l1-ingest         │   │  BFF     │
 │ KnomosisFaultProofGame + StepVM│     │ knomosis-event-subscribe   │   │ (:3001)  │
 │ KnomosisDisputeVerifier{,V2}  │      │ knomosis-indexer (SQLite)  │   └────┬─────┘
 │ KnomosisSequencerStake        │      │ knomosis-gateway (HTTP+SSE)│◄───────┘ bearer
 │ AmmDisasterRecoveryMultisig*  │      └────────────────────────────┘   server-to-server
 └──────────────────────────────┘             │  replay/audit           ┌──────────┐
        ▲ watch + challenge                    └── knomosis-faultproof-  │  Licio   │
        └──── knomosis-faultproof-observer ────────  observer           │  PWA     │
                                                                        │ (:5173)  │
                                          * only on a functional-AMM     └──────────┘
                                            (BOLD-enabled) deployment       (via BFF)
```

**Licio is not a blockchain client.** Its integration surface is the
**gateway** HTTP/JSON + SSE API. The gateway is fronted by the L2 daemon
stack, which is anchored to the Sepolia L1 contracts. So "deploy + test on
Sepolia" = (1) deploy the L1 contracts + emit a manifest, (2) run the L2
stack against that manifest, (3) expose the gateway to Licio's BFF.

---

## 1. Prerequisites

| Need | How |
|------|-----|
| Toolchains | `./scripts/setup.sh --build` (Lean + Foundry + solc 0.8.20); `cd runtime && cargo build --release` (the Rust daemons) |
| A funded **Sepolia deployer EOA** | ~0.5 test-ETH covers the 9 deploys (~5–6M gas total). Get test-ETH from a Sepolia faucet. |
| A **Sepolia RPC endpoint** | Alchemy / Infura / a public endpoint → `SEPOLIA_RPC_URL` |
| An **Etherscan API key** (Sepolia) | For `--verify` source-verification → `ETHERSCAN_API_KEY` (one Etherscan v2 key verifies on every chain) |
| Production **actor addresses** | attestor, sequencer, treasury, adjudicator set, and — if BOLD-enabled — the BOLD circuit-breaker/admin and the AMM disaster-recovery multisig signer set. See §4. |
| A **bridge-actor keystore** | A 32-byte secp256k1 key `knomosis-l1-ingest` signs L1→L2 ingress actions with (§6). |

Never put a funded private key in a committed file or in shell history for a
value-bearing deployment.  `make deploy-sepolia` therefore prefers a Foundry
**keystore account** (`KNOMOSIS_DEPLOYER_ACCOUNT`, imported once via
`cast wallet import <name> --interactive`) so the key is never passed on the
command line (`ps`/`/proc`-visible).  A raw `PRIVATE_KEY` env var is a fallback
for a shadow/no-value testnet only (the target warns and forwards it to
`--private-key`, which is `ps`-visible for the broadcast).

---

## 2. Pre-deploy trust-binding gates (F-1 / F-2 — REQUIRED)

The kernel ships fail-closed fallbacks for its two off-chain trust
assumptions (the hash function and the signature verifier). Run these in the
deploy pipeline so a fallback can **never** reach a value-bearing deployment
(security review F-1/F-2; `docs/testnet_readiness.md` §3.2):

```bash
.lake/build/bin/knomosis hash-check      # exit 1 on the FNV-1a-64 fallback
.lake/build/bin/knomosis verify-check    # exit 1 on the Lean-opaque verifier fallback
./scripts/verify_secp256k1_link.sh --check   # SHA-256 pin of the secp256k1 cdylib
./scripts/verify_keccak_link.sh      --check   # SHA-256 pin of the keccak cdylib
./scripts/verify_release_crypto.sh             # BOTH adaptors linked in one binary
```

A green run of all five is the go signal for a value-bearing deployment. For
a pure shadow/no-value testnet they are advisory but recommended.

---

## 3. Sizing the parameters (do not guess)

Every fund-holding constructor value is **deployment-immutable**. Size them
with the calibration harness before the broadcast:

```bash
python3 scripts/economic_simulation.py       # IC-1..IC-6 envelope + asserts
```

Then set the environment for the deploy per `docs/deployment_parameters.md`
(challenge bond, sequencer stake, TVL cap, fee band, drain caps, timeouts).
The deploy script's env vars are enumerated in §4; every one has a
testnet-sane default, so a bare dry-run runs with zero env, but a real
deployment should set the actor addresses and the sized economics explicitly.

---

## 4. Deploy the L1 contracts (`make deploy-sepolia`)

`solidity/script/DeploySepolia.s.sol` deploys the **full 9-contract genesis
suite** as individual transactions via plain-nonce CREATE prediction (no
CREATE3 bundler → **no `--disable-code-size-limit`** needed; every production
contract is under EIP-170, the largest being `KnomosisBridge` at 17 195 B),
verifies the post-deploy invariants (`assertConsistent()` on both clusters,
`bridge.migration() == address(0)`, and `deploymentId` self-consistency), and
writes the manifest to `solidity/deployments/sepolia.json`.

### 4.1 Dry-run first (in-memory, no broadcast)

```bash
cd solidity
make deploy-sepolia-dryrun          # simulates the full deploy, writes the manifest
```

### 4.2 The real Sepolia broadcast + source-verification

```bash
cd solidity
export SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<KEY>
export ETHERSCAN_API_KEY=<KEY>
export KNOMOSIS_DEPLOYER_ACCOUNT=my-sepolia-deployer  # forge keystore (recommended; key off argv)
# export PRIVATE_KEY=0x<funded-key>                   # raw-key fallback (ps-visible; shadow testnet only)
# Production actors (examples — use YOUR addresses):
export KNOMOSIS_ATTESTOR=0x...        # bridge off-chain signer EOA
export KNOMOSIS_SEQUENCER=0x...       # the L2 sequencer EOA
export KNOMOSIS_TREASURY=0x...        # fault-proof 5% skim recipient
export KNOMOSIS_ADJUDICATOR=0x...     # base of the adjudicator set (3-of-3 default)
make deploy-sepolia                   # broadcasts + verifies on Etherscan
```

### 4.3 BOLD + AMM on Sepolia (optional)

BOLD is **chain-conditional** (Genesis-Plan §13.6 amendment; see
`docs/deployment_parameters.md` §5): on **mainnet** the bridge requires the
canonical `BOLD_TOKEN_ADDRESS` pin; on **Sepolia** (or any non-mainnet chain)
it accepts an **operator-supplied** BOLD token that has code and whose
`symbol()` is `"BOLD"`. To enable the BOLD + AMM legs, deploy or point at a
Sepolia BOLD test token and set:

```bash
export KNOMOSIS_BOLD_TOKEN=0x...            # a Sepolia ERC-20 with symbol() == "BOLD"
export KNOMOSIS_BOLD_CIRCUIT_BREAKER=0x...  # hot pause role (multisig recommended)
export KNOMOSIS_BOLD_ADMIN=0x...            # cold cap-tuning role (distinct address)
export KNOMOSIS_AMM_SEED_RATIO_BPS=1000     # >0 makes the AMM functional (10%)
export KNOMOSIS_AMM_MULTISIG_SIGNER=0x...   # base of the 3-of-N recovery signer set
export KNOMOSIS_AMM_MULTISIG_COUNT=5
export KNOMOSIS_AMM_MULTISIG_THRESHOLD=3    # >= 3 (MIN_DISABLE_THRESHOLD)
make deploy-sepolia
```

When `KNOMOSIS_BOLD_TOKEN` is unset the deployment is **ETH-only** (the BOLD
entry point and the AMM are disabled) — a fully valid first-testnet shape. The
Liquity auto-trigger stays off off-mainnet automatically (its TroveManager
oracles are mainnet-only). To rehearse the full BOLD + AMM deploy path with no
real BOLD token, use `make deploy-local` (a live anvil node) or
`forge script script/DeploySepoliaLocal.s.sol` (in-memory), which stands up a
`MockBold` and deploys the full BOLD + AMM suite against it.

### 4.4 Full env-var reference

| Variable | Default | Meaning |
|----------|---------|---------|
| `KNOMOSIS_VERSION_TAG` | `keccak256("knomosis-sepolia-v1")` | deployment-namespacing tag (must match the L2 kernel's tag) |
| `KNOMOSIS_ATTESTOR` / `_SEQUENCER` / `_TREASURY` | placeholders | core actors (set for a real deploy) |
| `KNOMOSIS_ADJUDICATOR` / `_ADJUDICATOR_COUNT` / `_ADJUDICATOR_QUORUM` | base / 3 / 3 | dispute-verifier adjudicator set |
| `KNOMOSIS_DISPUTE_WINDOW` / `_MAX_REDEMPTION` / `_ATTEST_STALE` / `_COOLDOWN` | 50 400 / 36 000 / 7 200 / 7 200 | bridge block windows (`disputeWindow ≥ maxRedemption`, both `> 0`) |
| `KNOMOSIS_TVL_CAP` / `_MIN_FEE_BPS` / `_MAX_FEE_BPS` / `_WEI_PER_BUDGET_UNIT_ETH` | 100 000e / 0 / 5000 / 1e9 | bridge economics |
| `KNOMOSIS_BOLD_TOKEN` / `_WEI_PER_BUDGET_UNIT_BOLD` / `_BOLD_TVL_CAP` | 0 / 1e9 / =tvlCap | BOLD leg (0 ⇒ ETH-only) |
| `KNOMOSIS_BOLD_CIRCUIT_BREAKER` / `_BOLD_ADMIN` | placeholders | BOLD safety roles (required + distinct when BOLD-enabled) |
| `KNOMOSIS_AMM_SEED_RATIO_BPS` | 0 | AMM seed fraction (`>0` ⇒ functional AMM ⇒ multisig deployed) |
| `KNOMOSIS_AMM_MULTISIG_SIGNER` / `_COUNT` / `_THRESHOLD` | base / 5 / 3 | AMM disaster-recovery 3-of-N multisig |
| `KNOMOSIS_SLASH_BPS` | 5000 | sequencer-stake slash ratio |
| `KNOMOSIS_STATE_ROOT_BOND` / `_STATE_ROOT_DISPUTE_WINDOW` / `_WITHDRAWAL_WINDOW_BLOCKS` | 1e / 216 000 / 216 000 | state-root submission |
| `KNOMOSIS_MIN_SUBMISSION_INTERVAL` / `_MAX_OUTSTANDING_ROOTS` | 100 / 100 | submission cadence + cap |
| `KNOMOSIS_BISECTION_TIMEOUT_BLOCKS` / `_MIN_CHALLENGE_BOND` / `_MIN_BISECTION_STEP_INTERVAL` | 21 600 / 0.05e / 5 | fault-proof game (`bond > 0`, `timeout > stepInterval`) |
| `KNOMOSIS_MANIFEST_OUT` | `deployments/<network>.json` | manifest output path |

---

## 5. The deployment manifest

`make deploy-sepolia` writes `solidity/deployments/sepolia.json` — the single
source of truth the L2 daemons, the gateway, and the Licio client read (it
closes the `docs/testnet_readiness.md` §3 "no addresses manifest" gap; nothing
in the repo consumed contract addresses from a file before):

```json
{
  "network": "sepolia",
  "chainId": 11155111,
  "deploymentId": "0x…",
  "knomosisVersionTag": "0x…",
  "deployedAtBlock": 1234567,
  "deployer": "0x…",
  "boldEnabled": true,
  "boldToken": "0x…",
  "contracts": {
    "KnomosisIdentityRegistry": "0x…",
    "KnomosisBridge": "0x…",
    "KnomosisDisputeVerifier": "0x…",
    "KnomosisSequencerStake": "0x…",
    "KnomosisAmmDisasterRecoveryMultisig": "0x…",
    "KnomosisStepVM": "0x…",
    "KnomosisStateRootSubmission": "0x…",
    "KnomosisDisputeVerifierV2": "0x…",
    "KnomosisFaultProofGame": "0x…"
  },
  "actors": { "attestor": "0x…", "sequencer": "0x…", "treasury": "0x…",
              "boldCircuitBreaker": "0x…", "boldAdmin": "0x…" }
}
```

Consumers: `knomosis-l1-ingest` reads `.contracts.KnomosisBridge` +
`.contracts.KnomosisIdentityRegistry` + `.deploymentId`;
`knomosis-faultproof-observer` reads `.contracts.KnomosisFaultProofGame` +
`.contracts.KnomosisStateRootSubmission` + `.deploymentId`; every
deploymentId-scoped daemon reads `.deploymentId`. Commit the manifest (or
publish it to your ops store) so the whole team wires to the same addresses.

---

## 6. Bring up the L2 stack

`scripts/knomosis_l2_sepolia_stack.sh` reads the manifest and launches the L2
daemons in dependency order. Build the daemons first:

```bash
./scripts/setup.sh --build                 # builds .lake/build/bin/knomosis
cd runtime && cargo build --release && cd ..
```

Then start the **core** stack (host → event-subscribe → indexer → gateway) —
the surface Licio consumes:

```bash
MANIFEST=solidity/deployments/sepolia.json \
  ./scripts/knomosis_l2_sepolia_stack.sh
```

It prints the gateway URL + the path to a `chmod 600` bearer-token file (the
raw token is **not** echoed to stdout — read it with `cat "$TOKEN_FILE"`) and
holds the stack up until Ctrl-C. To also **anchor to Sepolia** (bridge L1
deposits into L2 and
run an independent watchtower), provide the RPC + keystores:

```bash
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<KEY> \
BRIDGE_ACTOR_KEYSTORE=/secure/bridge-actor.key \
OBSERVER_KEYSTORE=/secure/observer.key \
MANIFEST=solidity/deployments/sepolia.json \
  ./scripts/knomosis_l2_sepolia_stack.sh
```

Daemon roles + the exact per-daemon flags are in
`docs/planning/rust_host_runtime_plan.md` and each crate's `--help`.

**Budget policy — default OFF (ungated), which Licio needs.** By default the
launcher passes **no** budget flags to `knomosis-host`, so a signed action is
admitted on its §8.2 precondition + signature alone — a **test actor needs no
budget to submit** (ideal for initial Licio testing). This is deliberate:
`knomosis-host` assembles a *bounded* budget gate whenever ANY of
`--free-tier` / `--action-cost` / `--current-epoch` is passed, and
`mk_bounded(free-tier 0, action-cost 1)` is **deny-all** (a fresh actor has 0
budget and needs 1) — which would silently reject every ordinary submission.
To opt into per-actor budgets set `BUDGET_POLICY=bounded` (with `FREE_TIER` /
`ACTION_COST` / `EPOCH_LENGTH`); the launcher then wires `--budget-policy
bounded` consistently across the host, event-subscribe, and gateway echoes so
`/v1/info` and the budget views do not drift. See `docs/gas_pool_runbook.md`
§8.

---

## 7. The gateway for the Licio client

The **gateway** (`runtime/knomosis-gateway/`, contract
`docs/api/gateway.openapi.yaml`) is Licio's whole integration surface. It owns
its own HTTP/1.1 + native-TLS stack (no `tiny_http`) and is **fail-closed**:
no token file ⇒ every non-exempt request is denied.

### 7.1 Recommended topology: server-to-server via the Licio Hono BFF

The Licio **Hono BFF** (Node, `:3001`) holds the bearer token and calls the
gateway; the browser never talks to the gateway directly, so **no browser
CORS** is needed and the token stays server-side. Read the token from the
launcher's printed token file (`cat "$TOKEN_FILE"`) and wire it into the BFF:

```ts
// Licio Hono BFF → Knomosis gateway
const KNOMOSIS_GATEWAY = process.env.KNOMOSIS_GATEWAY_URL;   // http://127.0.0.1:8080
const KNOMOSIS_TOKEN   = process.env.KNOMOSIS_GATEWAY_TOKEN; // the printed bearer token
const h = { Authorization: `Bearer ${KNOMOSIS_TOKEN}` };

await fetch(`${KNOMOSIS_GATEWAY}/v1/info`, { headers: h });
await fetch(`${KNOMOSIS_GATEWAY}/v1/actors/${actorId}/balances`, { headers: h });
```

### 7.2 Alternative: browser-direct (CORS + TLS)

To let the Licio PWA (`http://localhost:5173`) call the gateway directly, set
`GW_CORS_ORIGIN=http://localhost:5173` for the launcher (adds the OPTIONS
preflight + `Access-Control-*` headers) and terminate TLS — either in-process
(`--tls-listen`/`--tls-cert`/`--tls-key`, see `docs/gateway_runbook.md`) or at
a co-located edge. Note this exposes the bearer token to the browser; the
server-to-server topology (§7.1) is preferred.

### 7.3 The endpoints Licio exercises (reads + submit + SSE)

| Method + path | Purpose |
|---------------|---------|
| `GET /readyz` | readiness (auth-exempt) — 200 once host+subscribe+indexer are reachable |
| `GET /v1/info` | deploymentId, admission stage, wire-protocol versions, indexer cursor, budget policy |
| `GET /v1/actors/{id}/balances` · `…/balances/{resource}` | per-actor balances (ETag/304 revalidation) |
| `GET /v1/actors/{id}/budget` | current-epoch budget view |
| `GET /v1/pools/{pool}?resource={0\|1}` | gas-pool ledger (0=ETH, 1=BOLD) |
| `POST /v1/actions` | submit a client-signed `SignedAction` (octet-stream or json+base64) → §5 verdict; `Idempotency-Key` dedups |
| `GET /v1/events?since&limit&type` | cursor-paginated event backfill |
| `GET /v1/events/stream?since&type` | live Server-Sent-Events stream (`id: <seq>.<index>`, `Last-Event-ID` resume) |

**Submit path (no key custody):** the client signs a `SignedAction` and Licio
forwards the **opaque bytes** to `POST /v1/actions`; the gateway never holds a
signing key. See `docs/abi.md` §5 for the action set and §10 for the host wire
protocol; verdict → HTTP mapping is in the OpenAPI (`Ok`/`NotAdmissible` → 200,
`ParseError` → 400, `Busy` → 503+`Retry-After`, deadline → 504, oversize →
413).

### 7.4 Smoke test

```bash
GW=http://127.0.0.1:8080 ; TOK=<printed-token>
curl -s $GW/readyz                                             # {"ready":true,...}
curl -s -H "Authorization: Bearer $TOK" $GW/v1/info | jq .
curl -s -H "Authorization: Bearer $TOK" "$GW/v1/events?since=0&limit=10" | jq .
curl -sN -H "Authorization: Bearer $TOK" $GW/v1/events/stream   # live SSE (Ctrl-C)
```

---

## 8. Licio integration checklist

- [ ] `make deploy-sepolia` succeeded; contracts **source-verified** on
      Sepolia Etherscan; `deployments/sepolia.json` committed/published.
- [ ] L2 core stack up; `GET /readyz` returns `{"ready":true}`.
- [ ] Licio BFF has `KNOMOSIS_GATEWAY_URL` + `KNOMOSIS_GATEWAY_TOKEN`
      (server-side only); the token file is **not** world-readable.
- [ ] BFF proxies reads (`/v1/actors/*`, `/v1/pools/*`, `/v1/info`), submit
      (`POST /v1/actions`), and the SSE stream (`/v1/events/stream`).
- [ ] Licio generates its actor `SignedAction`s client-side and forwards the
      opaque bytes (no key custody in Knomosis).
- [ ] (browser-direct only) `--cors-origin http://localhost:5173` set + TLS
      terminated; else server-to-server via the Hono BFF.
- [ ] (L1-anchored testing) `knomosis-l1-ingest` running so L1 deposits appear
      as L2 balances; ≥1 independent `knomosis-faultproof-observer` funded.

---

## 9. Closing the `docs/testnet_readiness.md` §3 checklist

This runbook drives §3.1 (all contracts deployed + verified),
§3.4 (`make deploy-sepolia` against a real RPC — the non-bundling
`DeploySepolia` removes the `--disable-code-size-limit` caveat that the F.3
`Deployer` bundler carried), and adds the client-integration row (gateway
auth-token file perms, optional `--tls-listen` / `--cors-origin`, read-only
`--indexer-db`, `/readyz` probes). §3.2 (F-1/F-2) is §2 above; §3.3
(watchtower liveness) is the observer in §6; §3.5 (key custody + monitoring)
remains an operator responsibility.

---

## 10. Teardown

Ctrl-C the launcher (it stops every daemon in reverse order). The run
directory (`.knomosis-l2-run/` by default: the event log, the indexer SQLite,
the generated token file, daemon logs) persists for inspection — delete it to
reset. The L1 contracts are **immutable**; there is no on-chain teardown (a
fresh deployment mints new addresses + a new `deploymentId`).
