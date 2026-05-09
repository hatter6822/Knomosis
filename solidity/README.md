# Canon Solidity contracts

Workstream E of the Canon ↔ Ethereum integration plan.  This directory
hosts the L1 mirror of Canon's kernel: five immutable contracts
that anchor deposits, state-root submissions, withdrawals, the
dispute pipeline, sequencer staking, and the attested-handoff
migration mechanism.

The full design rationale lives in
[`docs/ethereum_integration_plan.md`](../docs/ethereum_integration_plan.md)
§9 (workstream E) and §20 (immutability amendment).  Read those
sections first; this README is the day-to-day developer guide.

## Layout

```
solidity/
├── foundry.toml             — toolchain + remappings + via_ir
├── lib/                     — vendored OpenZeppelin + forge-std
├── src/
│   ├── contracts/
│   │   ├── CanonBridge.sol             (E.1.1 – E.1.5)
│   │   ├── CanonDisputeVerifier.sol    (E.2.1 – E.2.5)
│   │   ├── CanonIdentityRegistry.sol   (E.3)
│   │   ├── CanonSequencerStake.sol     (E.4)
│   │   └── CanonMigration.sol          (E.5)
│   ├── interfaces/
│   │   ├── ICanonBridge.sol
│   │   ├── ICanonDisputeVerifier.sol
│   │   ├── ICanonIdentityRegistry.sol
│   │   ├── ICanonMigration.sol
│   │   └── ICanonSequencerStake.sol
│   └── lib/
│       ├── CanonEip712.sol      — EIP-712 domain / struct hash helpers
│       ├── CBEDecode.sol        — CBE byte decoder (mirrors Lean)
│       ├── CREATE3.sol          — proxy-factory deployment for cyclic refs
│       └── SmtVerifier.sol      — SMT verifier (mirrors Lean D.1)
└── test/
    ├── CanonBridge.t.sol           (39 tests)
    ├── CanonDisputeVerifier.t.sol  (34 tests)
    ├── CanonIdentityRegistry.t.sol (19 tests)
    ├── CanonMigration.t.sol        (9 tests + 2 audit-3 type-string pins)
    ├── CanonSequencerStake.t.sol   (19 tests)
    ├── CBEDecode.t.sol             (23 tests)
    ├── CREATE3.t.sol               (3 tests)
    ├── SmtVerifier.t.sol           (20 tests)
    ├── CrossCheck/
    │   ├── Framework.t.sol         (4 tests)
    │   ├── EcdsaVerify.t.sol       (3 tests; 2 conditionally-skipped)
    │   ├── Keccak256.t.sol         (3 tests; 1 conditionally-skipped)
    │   ├── DepositReceiptHash.t.sol (4 tests; 1 conditionally-skipped)
    │   ├── WithdrawalProof.t.sol   (3 tests; 1 conditionally-skipped)
    │   ├── DisputeEvidence.t.sol   (5 tests; 2 conditionally-skipped)
    │   ├── MigrationAttestation.t.sol (4 tests; 1 conditionally-skipped)
    │   └── Goldens.t.sol           (5 tests)
    └── utils/
        ├── Deployer.sol     — CREATE3-based deploy harness
        └── MockERC20.sol    — minimal ERC-20 for tests
```

Total: **191 forge tests + 8 conditionally-skipped across 16 suites**
(post-Workstream-F audit-2).  The `CrossCheck/*` sub-suites pin
behavioural equivalence with the Lean reference implementation per
Workstream F.1.x, gated on the production keccak256 binding being
linked (the `conditionally-skipped` cases run only when
`isKeccak256Linked` is true on the Lean side).

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

# Build + test (run from this dir):
forge build
forge test
```

`foundry.toml` pins:

* `solc_version = "0.8.20"` (with `evm_version = "shanghai"`).
* `via_ir = true` — required because `CanonBridge.withdrawWithProof`
  and a few other functions are stack-too-deep without it.
* `optimizer_runs = 200`.

## Immutability discipline

Per §4.8 / §20 of the integration plan, every contract here is
deployed immutably:

* **No proxy.**  Each contract goes straight to its final address
  (mainnet via `CREATE2` with deterministic salts; tests via
  `CREATE3` to break the bridge ↔ verifier ↔ stake reference cycle).
* **No `initialize`.**  Constructors set every field; nothing is
  later mutable.
* **No admin role.**  Each cross-contract authority is encoded as
  `address public immutable`.
* **No `pause()` function.**  Whole-system halts use the four
  automatic circuit breakers in `CanonBridge.sol` (§9.1.4):
  `AttestationStale`, `DisputeCooldown`, `TvlCapReached`,
  `MigrationActivated`.  Each fires on a deterministic public-state
  predicate; no privileged caller is involved.
* **Recovery via the dispute pipeline, not via code.**  Bad state
  transitions are reverted by upheld disputes; bad code is replaced
  by deploying a new immutable contract and using `CanonMigration`
  to attest the handoff.

The forge test suite includes a `test_no_admin_surface` assertion
on every contract that confirms the canonical admin selectors
(`pause()`, `unpause()`, `transferOwnership(...)`, `grantRole(...)`,
`upgradeTo(...)`) are not callable.

## CREATE3 deployment

The bridge / verifier / stake cycle is broken at deployment time
using `CREATE3` (see `src/lib/CREATE3.sol`), which derives each
contract's address from `(deployer, salt)` alone — independent of
init-code.  This lets us bake the predicted addresses into each
contract's `immutable` constructor arguments before deploying.

The standard CREATE3 proxy (the `0x67363d3d37363d34f03d5260086018f3`
init-code) does not propagate inner constructor reverts: a failed
inner CREATE returns 0 from the proxy, and our `deploy` helper
detects that with a post-deploy `code.length == 0` check.  This is
the documented behaviour of every standard CREATE3 implementation
(Solady, Solmate).  Production deployment scripts that need
bubbled revert reasons must use a bespoke proxy; the Canon
`CanonMigration` test fixtures use direct `new ...(...)`
deployment so constructor revert reasons propagate verbatim.

## Cross-stack equivalence

Per workstream F.1 of the integration plan, the Solidity contracts
must produce byte-identical results to the Lean reference
implementation.  Specifically:

* `CBEDecode` decodes byte-for-byte the same way as
  `LegalKernel.Encoding.cborHeadDecode`.
* `SmtVerifier.verifyProof` accepts exactly the same proofs as
  `LegalKernel.Bridge.WithdrawalRoot.verifyProof`.
* `CanonEip712`'s digest matches `LegalKernel.Bridge.Eip712.digest`.
* `CanonBridge`'s `receiptHash` derivation matches
  `LegalKernel.Laws.Deposit.depositId`.

The F.1 cross-stack fixture suite has landed.  Lean side
(`LegalKernel/Test/Bridge/CrossCheck/*`) generates 656 fixture
inputs across seven sub-suites: `ecdsa_verify.json` (128 entries),
`keccak256.json` (104), `deposit_receipt_hash.json` (128),
`withdrawal_proof.json` (96), `dispute_evidence.json` (168),
`migration_attestation.json` (32).  Solidity side
(`solidity/test/CrossCheck/*`) consumes the JSON fixtures via
`vm.readFile` + `vm.parseJson` and asserts byte equality against
the recorded Lean outputs.  Per-entry assertions are gated on the
production keccak256 binding being linked (the Lean-side
`isKeccak256Linked` flag); when running with the FNV fallback,
the Solidity-side cross-checks log a skip line and exit cleanly.

`make test-cross-stack` runs the cross-check suite only;
`make testnet-acceptance-dryrun` runs the F.3 testnet acceptance
script against a local Anvil fork.

## Key contracts

### `CanonBridge.sol` (E.1)

The L1 escrow for deposits and withdrawals.  Five sub-WUs:

| WU    | Function                                             |
|-------|------------------------------------------------------|
| E.1.1 | `depositETH()` / `depositERC20(...)` — deposit entry |
| E.1.2 | `submitStateRoot(...)` — attestor-signed state root  |
| E.1.3 | `withdrawWithProof(...)` — proof-gated redemption    |
| E.1.4 | `circuitOpen` modifier — automatic state-driven halt |
| E.1.5 | `revertToPriorRoot(...)` — dispute-triggered rollback |

### `CanonDisputeVerifier.sol` (E.2)

The L1 dispute pipeline.  Three claim variants ship in MVP
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

### `CanonIdentityRegistry.sol` (E.3)

Mirror of the Lean `KeyRegistry` (Authority/Identity.lean).  Two
register entry points (`registerECDSA` for EOAs;
`registerEIP1271` for contract signers) with front-running
protection (the EOA path verifies that
`keccak256(pubkey)[12:] == msg.sender`) and an EIP-1271 probe
(the contract path calls `isValidSignature(bytes32(0), "")`
and accepts only if the contract returns the canonical magic
or a proper "invalid" response).

### `CanonSequencerStake.sol` (E.4)

The sequencer's ETH stake escrow.  Slashed by the dispute
verifier on `.upheld` finalisation: `slashRatioBps * stake / 10_000`
goes to the challenger; the residual is sent to the immutable
burn address.  Withdrawal lock-up is enforced via the bridge's
`hasOpenDisputeOlderThan` getter.

### `CanonMigration.sol` (E.5)

The one-shot, attested handoff between a predecessor and a
successor `CanonBridge`.  Replaces the upgradeable-proxy mechanism
that other rollup designs use for code-level recovery.  Key
properties:

* `MIN_GRACE_WINDOW_BLOCKS = 216_000` (≈ 30 days @ 12s blocks) —
  a Solidity `constant` baked into the bytecode; cannot be
  weakened by any constructor argument.
* Constructor verifies the predecessor's attestor's ECDSA
  signature over the canonical EIP-712 wrap of the migration
  record.
* Bidirectional consent: the constructor asserts
  `successor.migration() == address(this)`.
* `activated` is one-way; once `true`, never reverts.
* Anyone can call `activate()` after the grace window; no role
  gating.

## Audit-1 hardening summary

A deep post-PR audit of the workstream-E contracts identified
eight defects across the five contracts; all are now closed.
Cross-reference: the audit changelog in
[`docs/ethereum_integration_plan.md` §21](../docs/ethereum_integration_plan.md)
and [`CLAUDE.md`](../CLAUDE.md)'s active-development status
section.

  1. **`checkSignatureInvalid` signer-id resolution** — the
     pre-audit code synthesized an "address" by zero-padding
     the uint64 signer-id, which never matched any registered
     entry.  Fix: function now takes an explicit
     `address signerHint` parameter; the dispute filer
     supplies the actor-id ↔ address resolution.
  2. **EIP-712 domain mismatch** in `checkSignatureInvalid` —
     pre-audit code used `("CanonDisputeVerifier", "1")` as
     the domain when the user signed against
     `("CanonAction", "1")`.  Fix: split into
     `ACTION_DOMAIN_NAME` (per-action signing) and
     `VERDICT_DOMAIN_NAME` (verdict signing) constants.
  3. **`verdictHash` unbinding** — adjudicator signatures over
     verdictHash X could be replayed for ANY dispute Y
     because the contract never bound the hash to the
     dispute.  Fix: the contract derives the canonical digest
     on-chain via `verdictDigest(disputeId, outcome)` and
     adjudicators must sign that exact value (binds
     `(disputeId, outcome, deploymentId)`).
  4. **`revertToPriorRoot` O(N) DoS** — the per-record
     iterate-and-mark loop could OOG when there were many
     state-root submissions between the disputed index and
     `latestSubmittedLogIndexHigh`.  Fix: replaced with O(1)
     `lowestRevertedLogIndexHigh` floor; `isStateRootReverted(idx)`
     view computes status on-the-fly.
  5. **`signers[]` unbounded** in `_countVerifiedSignatures` →
     memory-allocation DoS.  Fix: `MAX_VERDICT_SIGNERS = 64`
     constant; `TooManySigners` revert above the bound.
  6. **`evidenceBlob` unbounded** in `fileDispute` → griefing
     via huge blob storage.  Fix: `MAX_EVIDENCE_BLOB_BYTES =
     100_000` constant; `EvidenceBlobTooLarge` revert above
     the bound.
  7. **`evidenceBlob` wasted storage** — file-time blob was
     stored on-chain but never read at finalisation.  Fix:
     removed from `DisputeRecord`; emitted in `DisputeFiled`
     event instead (~60× cheaper per byte than storage).
  8. **Wrong custom-error name** — TVL underflow check at
     withdrawal time reused `InvariantViolation_DisputeWindowVsRedemption`
     (a constructor-time error name).  Fix: separate
     `BridgeAccountingMismatch(uint256, uint256)` error for
     the underflow case.

## Audit-3 hardening summary

A third deep audit found one HIGH-severity semantic bug in the
migration mechanism plus several smaller defensive fixes.
Cumulative test count: 164 → **166** (+2 audit-3 tests; one
existing lifecycle test refactored to verify post-activation
successor operability).

  1. **HIGH: CanonMigration constructor's bidirectional
     consent check was inverted.**  Pre-audit-3 asserted
     `successor.migration() == address(this)`, which silently
     froze the SUCCESSOR (the OPPOSITE of the intended
     user-exit behaviour).  Per the integration plan §20, the
     PREDECESSOR is what freezes; the successor remains
     operational so users can interact with it post-migration.
     Fix: swap to `predecessor.migration() == address(this)`;
     renamed error to
     `PredecessorDoesNotReferenceThisMigration`.  The
     lifecycle test now verifies the successor remains
     operational post-activation
     (`successor.depositETH` succeeds).
  2. **LOW: missing zero-recipient check in
     `withdrawWithProof`.**  Defensive; `InvalidRecipient()`
     revert added.
  3. **LOW: `_runDoubleApplyFromConcat` decoder didn't
     assert fully-consumed and didn't validate array count.**
     Fix: count must equal 2 (`DoubleApplyConcatBadCount`
     revert); `assertFullyConsumed` post-decode.
  4. **LOW: redundant length check in `withdrawWithProof`** —
     `keccak256` equality already implies length equality
     under collision-resistance.  Removed.
  5. **Test coverage gaps closed:**
     - REJECTED-path test for `checkSignatureInvalid` (audit-2
       missed it).
     - Cross-signer-mismatch UPHELD test.
     - Predecessor-does-not-reference revert regression test.
     - Successor-still-operational post-activation assertion
       in the lifecycle test.

## Audit-2 hardening summary

A second deep audit found six additional defects that the
first audit missed; all are now closed.  Cumulative test count:
156 → **164** (+8 audit-2 tests; SmtVerifier suite
refactored from 18 to 20 tests using the new variable-size
API).

  1. **CRITICAL: SMT cross-stack leaf-format mismatch** — the
     pre-audit-2 Solidity port used `bytes32` for the SMT
     leaf and siblings, but Lean's `WithdrawalProof` allows
     variable-size `ByteArray` for both.  In the dense-pair
     case (sequentially-assigned WithdrawalIds 0 and 1 share
     a deepest pair, so the leaf-adjacent sibling for id 0
     is `leafBytes wd_1` ≈ 56 bytes), the Solidity verifier
     could not represent the sibling.  Fix: SmtVerifier
     accepts `bytes memory leaf` and `bytes[] memory
     siblings`; the bridge's `_decodeWithdrawalProof` reads
     variable-size bytes.
  2. **HIGH: revertToPriorRoot floor-only auto-reverted
     post-revert submissions** — after `revertToPriorRoot(N)`,
     every future submission at idx >= N was auto-marked
     reverted.  Fix: track `(floor, ceiling)` pair; future
     submissions at idx > ceiling are NOT in the reverted
     range.
  3. **HIGH: missing zero-address check on sequencerStake**
     in CanonBridge constructor.  Fix: `ZeroSequencerStake()`
     revert.
  4. **MEDIUM: duplicate token addresses allowed in resource
     map** — two distinct resourceIds could be mapped to the
     same ERC-20.  Fix: quadratic uniqueness check;
     `DuplicateResourceToken(token)` revert.
  5. **MEDIUM: fee-on-transfer / rebasing ERC-20s desynced
     L1/L2 accounting** — the bridge used the declared
     amount, not the received amount.  Fix: balance-delta
     accounting; `TransferAmountMismatch(declared, received)`
     revert.
  6. **MEDIUM: missing nonReentrant on
     finalizeUpheld/Rejected** (defense-in-depth) — CEI
     ordering was correct but reentry from a malicious
     challenger could call other verifier entry points
     during the slash.  Fix: import OZ ReentrancyGuard, mark
     both functions `nonReentrant`.

The audit also documented several low-severity items
investigated but deliberately not changed:

  * **`receive()` reverts** on all bridge contracts; ETH can
    still arrive via `selfdestruct(target)`.  Accounting uses
    `totalLockedValue`, not `address(this).balance`, so
    correctness is preserved; documented as a known property.
  * **`hasOpenDisputeOlderThan` is conservative** (returns
    `true` if any state root is within the dispute window
    regardless of open-dispute count).  Future enhancement:
    have the dispute verifier maintain an authoritative
    per-state-root open-dispute index.
  * **`withdrawWithProof` recipient self-DoS** — a contract
    recipient that reverts on `receive()` cannot redeem its
    own withdrawal.  Accepted as a known property of
    `Address.sendValue` semantics.
  * **`receive()` rejection of bare ETH** is necessary so
    deposit accounting doesn't drift; intentional.

## Production deployment notes

* Use `CREATE3` for all four cyclic contracts (bridge, verifier,
  stake) so the cross-references resolve to predictable addresses.
* The bridge's `migration` immutable should be set to a
  *predicted* `CanonMigration` `CREATE3` address at the time of
  the predecessor's deployment.  At the initial deployment the
  predicted address can be `address(0)` (no migration planned);
  future deployments override.
* Run the full forge test suite (`forge test`) on the deployment
  artefacts as a smoke check before proposing on-chain.
* The "no admin surface" assertion in F.3 (testnet acceptance)
  doubles as a safety check that no upgradeable-proxy bytecode
  has accidentally crept in.

## Future: actor-scoped policies (Workstream LP)

Workstream LP (actor-scoped policies) is a Lean-side workstream
that adds per-actor on-chain mutable policy filters.  The
Solidity-side mirror is **not yet implemented**; this section
documents the future shape so an implementer can land it as a
focused follow-up without re-litigating the Lean-side decisions.

The Lean-side workstream introduces:

  * `Action.declareLocalPolicy (policy : LocalPolicy)` at
    frozen index 15.
  * `Action.revokeLocalPolicy` at frozen index 16.
  * `Event.localPolicyDeclared (actor, policy)` at frozen
    index 11.
  * `Event.localPolicyRevoked (actor)` at frozen index 12.
  * A 5th admissibility conjunct: the signer's declared
    policy (defaulting to empty) must permit the action, with
    a structural meta-action exemption for the two LP action
    constructors.

The `LocalPolicy` data type is a list of
`LocalPolicyClause` values combined by conjunction.  The MVP
clause set has three variants:

  * `denyTags (tags : List Nat)` — deny actions whose
    constructor tag is in `tags`.
  * `requireRecipientIn (resource, allowed)` — for
    balance-mutating actions on `resource`, require the
    recipient field to be in `allowed`.
  * `capAmount (resource, max)` — for actions on `resource`
    with an `amount` field, require `amount ≤ max`.

DoS bounds (frozen):

  * `MAX_CLAUSES_PER_POLICY = 64`
  * `MAX_TAGS_PER_DENY = 64`
  * `MAX_RECIPIENTS_PER_REQUIRE = 64`
  * `MAX_POLICY_ENCODE_BYTES = 16_384`

When the Solidity side lands, it will require:

  1. A CBE decoder in `solidity/src/lib/CBEDecode.sol` for
     the `LocalPolicy` and `LocalPolicyClause` types,
     mirroring the Lean codec line-for-line with the same
     DoS bounds.
  2. An admissibility-check call in
     `CanonBridge.depositETH` / `depositERC20` that consults
     the depositor's L2 `localPolicies` lookup before
     crediting (defensive layer; the L2 admissibility check
     already enforces this — the Solidity-side check is for
     fast L1 user feedback).
  3. Two new event-listener mappings for
     `LocalPolicyDeclared` / `LocalPolicyRevoked` in the
     indexer.

A future `CanonDisputeVerifier` extension may add a sixth
claim variant (`localPolicyMisreported`) for adjudicating
disputes about whether a particular L2 transaction violated
the actor's declared policy; this is reserved for
post-LP-MVP work.

See `docs/actor_scoped_policies_plan.md` for the full
engineering plan and `docs/abi.md` §5.4 for the canonical
on-disk byte layouts.
