<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon — A Societal Kernel

Canon is a **proof-carrying state-transition system** built in Lean 4. The
kernel does not say *what* is legal; it defines *what it means* for a
state change to be legal, and mechanically rejects everything else.
Specific rules — transfers, mints, burns, freezes, rewards, signed
actions — are first-class values that compose with proof obligations
the build will not accept without discharge.

The result is a tiny, parametric core that gives every deployment four
type-level guarantees by construction: determinism, no silent
illegality, refinement of executable to specification, and inductive
preservation of any invariant proved against the abstract transition
interface.

The full architectural and mathematical blueprint lives in
[`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md). Start there for the
formal model, threat model, and phased roadmap.

## Novel design properties

Canon's distinguishing commitments — what the build mechanically
enforces that comparable systems leave to convention or audit:

- **Legality is a type.** A `Transition` carries a `Prop`-valued
  precondition, a constructive decidability witness, and a total state
  transformer. The `step_impl` function only advances state when
  `decPre` resolves; reading the kernel does not require classical
  logic.
- **Tiny TCB, three-axiom proof discipline.** The trusted core is two
  modules (`LegalKernel/Kernel.lean`, `LegalKernel/RBMapLemmas.lean`).
  Every kernel theorem `#print axioms` to exactly
  `[propext, Classical.choice, Quot.sound]` — the three Lean
  built-ins. No custom axioms; the only opaque declarations
  (`Verify`, `signingInput`) model deployment-supplied cryptography
  and are surfaced as trust assumptions, not Lean axioms.
- **Type-level economic firewalls.** Conservation and monotonicity are
  `IsConservative` / `IsMonotonic` typeclasses; deployments declare a
  `ConservativeLawSet` or `MonotonicLawSet` and typeclass resolution
  refuses to admit non-conservative or supply-destroying laws.
  `mint_not_conservative`, `burn_not_conservative`, and
  `burn_not_monotonic` ship as the *negative* witnesses that make the
  firewall sound.
- **Replay protection as a Lean theorem.** `replay_impossible` proves
  that a successfully applied signed action cannot be admissible at
  the post-state; `nonce_uniqueness` proves no two distinct
  admissible actions by the same signer share a nonce. Both follow
  from `expectsNonce_strict_mono` (per-actor monotone nonce ledger).
- **Structural action injectivity.** `Action.compile_injective` is a
  one-line `congrArg` on `CompiledAction.source`: the wrapper makes
  distinct serialised actions necessarily distinct compiled values,
  even when two laws happen to share an underlying transition.
- **Positive-incentive primitives.** `reward`, `distributeOthers`, and
  `proportionalDilute` give deployments Pareto-superior alternatives
  to `burn`-as-fine. `proportionalDilute_distributed_le_totalReward`
  formally pins the floor-division dust loss.
- **Canonical, injective serialisation.** Every `Action`,
  `SignedAction`, `State`, and `ExtendedState` value has a strictly
  canonical CBE byte encoding with mechanically-proved round-trip
  and injectivity (bounded by `< 2^64` on numeric fields).
  `signInput` domain-separates by deployment ID so signatures cannot
  replay across deployments (Genesis Plan §8.8.5).
- **DSL with built-in decidability discipline.** The `law pre := …
  ; impl := …` macro fills in `decPre := fun _ => inferInstance`;
  if the precondition is not instance-decidable, elaboration fails
  with a clear error rather than silently admitting a partial law.
- **Crash-consistent persistent log + replay.** Phase 5 ships an
  append-only `LogEntry` format with FNV-1a-64 framing trailers; on
  startup the runtime walks the file frame-by-frame and truncates
  the partial tail of any torn write.  The standalone `canon-replay`
  binary reconstructs the runtime's `StateHash` byte-for-byte from
  the same log, on a separate machine, with no shared mutable state.
- **Deterministic event extraction.** `extractEvents` is a pure Lean
  function from `(preState, postState, signedAction)` to a `List
  Event`; two replays of the same log produce byte-identical event
  streams.  Indexers consume events without re-deriving state diffs.
- **Snapshot + incremental shipping.** Phase 5 WU 5.12: a `(stateHash,
  encodedState, logIndex, seedHash)` snapshot lets fresh replicas
  resume processing without replaying from genesis.  A replica
  bootstrapped from a snapshot reaches the same final state as one
  that replayed the entire log.
- **Four-stage dispute pipeline.** Phase 6 ships the §8.4 four-stage
  pipeline (`fileDispute`, `checkEvidence`, `proposeVerdict`,
  `applyVerdict`) over a closed inductive of five claim variants
  (`preconditionFalse`, `signatureInvalid`, `nonceMismatch`,
  `oracleMisreported`, `doubleApply`).  Every verifier is a *pure*
  Lean function — different adjudicators reach the same verdict on
  the same log + evidence.  An upheld verdict computes the rollback
  target via prefix-replay; the rolled-back state is recorded as a
  forward `Action.rollback` in the log so replay continues working.
- **Incentivized dispute pipeline.** The Phase-6 incentive
  amendment composes the dispute pipeline with the Phase-4-prelude
  positive-incentive laws: the four dispute action constructors
  classify as both `IsConservative` and `IsMonotonic` (so a
  `MonotonicLawSet` deployment admits the dispute pipeline);
  `DisputeRewardPolicy` lets deployments issue `Action.reward` to
  challengers on upheld verdicts and to adjudicators on every
  verdict (with optional stake-weighted distribution
  `pool * stake / totalStake`); a kernel-conservative
  `StakingPolicy` provides anti-fraud staking via
  `Action.transfer`-to-escrow (no `burn`, so monotonicity holds at
  the kernel level); `Event.rewardIssued` gives indexers a
  semantic observable distinct from the kernel-level
  `balanceChanged` delta.
- **Withdrawal proofs (Workstream D).** A height-64 sparse Merkle
  tree over `BridgeState.pending` produces a 32-byte
  `withdrawalRoot` that an L1 redemption contract can verify
  against.  `constructProof` builds the canonical inclusion proof
  (leaf bytes + 64 sibling hashes, root-to-leaf), and `verifyProof`
  walks the path leaf-to-root.  Two headline theorems certify the
  pair: `verifyProof_complete` (unconditional — every populated
  withdrawal's canonical proof verifies) and `verifyProof_sound`
  (under collision-resistance and uniform-output-size hypotheses
  on the hash function — a verifying proof matches the canonical
  construction).  `extractProof` pulls a proof from a finalised
  snapshot via the `canon withdrawal-proof SNAP_PATH ID` CLI;
  `isFinalised` enforces the dispute-window finalisation policy
  (no upheld disputes against the snapshot's covered log range).


## Engineering posture

The build mechanically guarantees the following on every commit:

| Posture                                        | Mechanism                                |
|------------------------------------------------|------------------------------------------|
| 557 unit tests across 39 suites pass           | `lake test` (`Tests.lean` driver)        |
| Zero `sorry` in any kernel-TCB module          | `lake exe count_sorries`                 |
| TCB imports stay on the allowlist              | `lake exe tcb_audit`                     |
| Every public surface has a `/-- … -/` doc      | `linter.missingDocs := true` (lakefile)  |
| No silent universe / type-variable creation    | `autoImplicit := false` (lakefile)       |
| No dead bindings                               | `linter.unusedVariables := true`         |
| Build, tests, and audits run on every PR       | `.github/workflows/ci.yml`               |

CI blocks merges on any of the four `lake` gates above. The two
trusted-core files require two reviewers per PR (Genesis Plan §13.6);
non-TCB modules require one.

## Status

Canon is research-stage software. Phases 0 – 6 of the Genesis Plan are
complete (Phase 5's Rust-host WUs 5.4 / 5.7 / 5.8 / 5.11 are deferred
to a follow-up PR with their own CI infrastructure).  Phase 6 lands
the §8.4 four-stage dispute pipeline (file → check evidence →
propose verdict → apply verdict + rollback) with five per-claim
evidence verifiers and an end-to-end planted-illegal-tx → rollback
acceptance test.  Ethereum-integration Workstreams A (cryptographic
adaptors: ECDSA secp256k1, keccak256, EIP-712), B (identity and
authority: `EthAddress`, `AddressBook`, `bridgeActor`,
`bridgePolicy`, L1 event ingestor), C (bridge laws:
`BridgeState`, `BridgeAdmissibleWith`, `Action.deposit` /
`Action.withdraw`, `totalDeposited` / `totalWithdrawn` accounting),
and D (withdrawal proofs: sparse Merkle tree, verifier and
constructor with completeness + soundness theorems, snapshot-window
finalisation policy, `canon withdrawal-proof` CLI) are complete
on the Lean side; Workstreams E – G remain to be scoped per
[`docs/ethereum_integration_plan.md`](docs/ethereum_integration_plan.md).

| Phase       | Title                                | Status       |
|-------------|--------------------------------------|--------------|
| 0           | Foundations (kernel skeleton + CI)   | Complete     |
| 1           | Kernel completion (RBMap, §4.3, §4.9)| Complete     |
| 2           | Economic invariants (conservation)   | Complete     |
| 3           | Authority layer (signed actions)     | Complete     |
| 4-prelude   | Positive-incentive mechanisms        | Complete     |
| 4           | DSL and serialization                | Complete     |
| 5           | Runtime and extraction (Lean side)   | Complete     |
| 6           | Disputes and adjudication            | Complete     |
| 6-amend     | Phase-6 incentive integration        | Complete     |
| E-A         | Ethereum: cryptographic adaptors     | Complete (Lean side) |
| E-B         | Ethereum: identity and authority     | Complete (Lean side) |
| E-C         | Ethereum: bridge laws                | Complete (Lean side) |
| E-D         | Ethereum: withdrawal proofs          | Complete (Lean side) |
| 7           | Advanced capabilities                | Not started  |

A full per-WU changelog (Phase 0.1 onward) lives in [CLAUDE.md](CLAUDE.md);
the canonical phase scoping lives in
[`docs/GENESIS_PLAN.md` §12](docs/GENESIS_PLAN.md).

## Quickstart

Canon depends only on a pinned Lean 4 toolchain — no Mathlib, no
external Lake packages. The toolchain version is read from
`lean-toolchain` (currently `leanprover/lean4:v4.29.1`).

```bash
# Recommended: SHA-256-verified setup script.
./scripts/setup.sh           # idempotent, pins toolchain integrity
./scripts/setup.sh --build   # ... and runs `lake build` after setup

# Manual alternative (skips integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Daily commands (after setup):
source ~/.elan/env
lake build              # full project (default target)
lake test               # 1016 tests across 55 suites (post-Workstream-D audit-1)
lake exe count_sorries  # zero-sorry TCB gate
lake exe tcb_audit      # TCB allowlist gate
lake exe stub_audit     # placeholder-stub detection gate (Audit-3.8)

# Phase-5 runtime CLI smoke test:
.lake/build/bin/canon info                       # build tag + phase
.lake/build/bin/canon bootstrap /tmp/test.log    # init an empty log
.lake/build/bin/canon-replay /tmp/test.log       # reproduce state hash
```

A green CI run on the same commands is the authoritative signal that
all phase-acceptance criteria still hold.

## Repository layout

```
canon/
├── LegalKernel/            -- the library
│   ├── Kernel.lean         -- §4.12 trusted core (TCB)
│   ├── RBMapLemmas.lean    -- §8.3 RBMap proof library (TCB)
│   ├── Conservation.lean   -- TotalSupply, IsConservative,
│   │                          IsMonotonic, lawset firewalls
│   ├── Laws/               -- one file per deployable law:
│   │                          Transfer, Mint, Burn, Freeze,
│   │                          Reward, DistributeOthers,
│   │                          ProportionalDilute
│   ├── Authority/          -- Phase-3 signed-action layer:
│   │                          Crypto (Verify), Action,
│   │                          Identity (KeyRegistry +
│   │                          AuthorityPolicy), Nonce,
│   │                          SignedAction (Admissible +
│   │                          replay_impossible)
│   ├── Encoding/           -- Phase-4 CBE byte codec:
│   │                          CBOR, Encodable, Action,
│   │                          SignedAction, State, SignInput,
│   │                          Disputes (Phase-6 dispute encodings)
│   ├── DSL/                -- Phase-4 `law` macro
│   ├── Events/             -- Phase-5 deployment-facing event
│   │                          stream: Types (8 ctors), Extract
│   ├── Runtime/            -- Phase-5 runtime infrastructure:
│   │                          Hash, LogFile, Replay, Snapshot, Loop
│   ├── Disputes/           -- Phase-6 §8.4 dispute pipeline:
│   │                          Types, Filing, Evidence, Verdict
│   └── Test/               -- 34 test suites mirroring the
│                              source layout
├── LegalKernel.lean        -- umbrella: import this from downstream
├── Tools/                  -- audit executables
│   ├── Common.lean         -- shared TCB constants
│   ├── TcbAudit.lean       -- enforces tcb_allowlist.txt
│   └── CountSorries.lean   -- enforces zero `sorry` in TCB
├── Main.lean               -- Phase-5 `canon` runtime CLI (info /
│                              process / replay / bootstrap / snapshot)
├── Replay.lean             -- Phase-5 `canon-replay` audit binary
├── Tests.lean              -- @[test_driver] (`lake test` entry point)
├── lakefile.lean           -- Lake config + lean options
├── lean-toolchain          -- pinned Lean version
├── tcb_allowlist.txt       -- TCB import allowlist
├── scripts/setup.sh        -- SHA-256-verified toolchain installer
├── .github/workflows/ci.yml-- CI gates (build, test, audits)
├── CLAUDE.md               -- engineering conventions for contributors
├── README.md               -- this file
└── docs/
    ├── GENESIS_PLAN.md         -- canonical design document
    ├── decidability_discipline.md
    ├── economic_invariants.md  -- Phase 2 + Phase-4 prelude
    ├── std_dependencies.md     -- per-toolchain-bump audit
    ├── extraction_notes.md     -- Phase 5 WU 5.9: erasure / persistence map
    └── abi.md                  -- Phase 5 WU 5.10 + Phase 6 extensions:
                                   on-disk + CLI ABI; dispute / verdict
                                   constructor tags
```

### Reading order for new contributors

1. **Skim** `docs/GENESIS_PLAN.md` §1 – §4 for the formal model.
2. **Read** `LegalKernel/Kernel.lean` end-to-end — it is the §4.12
   listing in literal form, ~200 lines.
3. **Pick a law** under `LegalKernel/Laws/` and read its precondition,
   `apply_impl`, and `IsConservative` / `IsMonotonic` instance to see
   how the typeclass firewalls compose.
4. **Run** `lake test`; the test files under `LegalKernel/Test/`
   double as worked examples for every theorem.
5. **Read** `CLAUDE.md` before making any change — it owns the
   engineering conventions, naming rules, and the two-reviewer gate
   for kernel-touching work.

## Headline theorems

The build won't accept any of these with a `sorry`, and `#print axioms`
on each returns only the three Lean built-ins.

| Theorem                                  | What it proves                                          | Where                                |
|------------------------------------------|---------------------------------------------------------|--------------------------------------|
| `impl_refines_spec`                      | every executed step satisfies its relational spec       | `LegalKernel/Kernel.lean`            |
| `impl_noop_if_not_pre`                   | failing the precondition leaves state unchanged         | `LegalKernel/Kernel.lean`            |
| `invariant_preservation[_via_laws]`      | inductive invariants hold across all reachable states   | `LegalKernel/Kernel.lean`            |
| `transfer_conserves`                     | transfer preserves per-resource total supply (§4.11.1)  | `LegalKernel/Laws/Transfer.lean`     |
| `total_supply_global[_via_law_set]`      | per-resource conservation across reachable states (§5.3)| `LegalKernel/Conservation.lean`      |
| `total_supply_globally_nondecreasing`    | monotonic-law-set deployments cannot lose value         | `LegalKernel/Conservation.lean`      |
| `proportionalDilute_distributed_le_totalReward` | floor-division dust bound for proportional reward       | `LegalKernel/Laws/ProportionalDilute.lean` |
| `Action.compile_injective`               | distinct serialised actions are distinct compiled values| `LegalKernel/Authority/Action.lean`  |
| `expectsNonce_strict_mono`               | per-actor expected nonce strictly increases on advance  | `LegalKernel/Authority/Nonce.lean`   |
| `nonce_uniqueness`                       | no two admissible actions by the same signer share a nonce | `LegalKernel/Authority/SignedAction.lean` |
| `replay_impossible`                      | a successfully applied signed action is not re-admissible | `LegalKernel/Authority/SignedAction.lean` |
| `action_roundtrip`                       | every Action's CBE encoding decodes back to itself      | `LegalKernel/Encoding/Action.lean`   |
| `state_encode_deterministic`             | equal `State` values produce equal canonical bytes      | `LegalKernel/Encoding/State.lean`    |
| `signInput_deterministic`                | equal sign-input args produce equal sign-input bytes (§8.8.5) | `LegalKernel/Encoding/SignInput.lean` |
| `hashBytes_deterministic`                | equal byte inputs produce equal content-hash outputs    | `LegalKernel/Runtime/Hash.lean`      |
| `replay_deterministic`                   | equal `(genesis, log)` pairs produce equal replay outputs | `LegalKernel/Runtime/Replay.lean`    |

CLAUDE.md `#1` – `#43` is the complete table including every
non-headline lemma the deployment surface depends on.

## Contributing

Read [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md) end-to-end first.
Every change beyond the trivial must reference a work unit (`WU x.y`)
and follow the runbooks in §13.6 – §13.9. Kernel-touching work units
require two reviewers; deployment-infrastructure work units (laws,
authority, conservation) require one. See [`CLAUDE.md`](CLAUDE.md) for
the engineering conventions any human or AI contributor must follow.

## License

Canon is released under the GNU General Public License, version 3.
See [LICENSE](LICENSE) for the full text.
