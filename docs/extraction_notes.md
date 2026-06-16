<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Phase 5 Extraction Notes (WU 5.9)

This document records what survives Lean's compilation pipeline into
the runtime binary.  It is the WU 5.9 deliverable per Genesis Plan
§12.

## 1. Goal

Phase 5's `knomosis` and `knomosis-replay` binaries are produced by Lean's
native compiler (LLVM via C).  The kernel's correctness theorems
(`impl_refines_spec`, `impl_noop_if_not_pre`, `invariant_preservation`,
…) are *type-level* obligations: they constrain what the elaborator
accepts, not what the runtime executes.  Phase 5's contract is that
the executable behaviour matches the specified semantics.  This
document spot-checks the contract.

## 2. Erasure: what disappears

Lean compiles to LLVM via two intermediate forms (LCNF and IR).  The
following kernel constructs are erased before code generation; they
contribute zero bytes to the runtime binary.

### 2.1 `Prop`-typed values

Every value of type `T : Prop` is erased.  This includes:

  * Every `Legal s t` certificate (a `t.pre s` proof).
  * Every `Admissible P es st` witness (the dependent argument to
    `apply_admissible`).
  * Every `IsConservative` / `IsMonotonic` instance body.
  * Every Phase-2 / Phase-3 / Phase-4-prelude theorem that doesn't
    appear in `def`-position.

**Implication.**  A signed action is admissible *or* it isn't; the
runtime never carries the proof, only the decision (`Bool`-shaped
output of `decide`).

### 2.2 Universe `Sort` polymorphism

The kernel does not use `Type 1+`.  All kernel types are `Type 0`
and erasure is uniform.

### 2.3 `noncomputable` and unimplemented `opaque`s

`opaque` declarations without `@[extern]` linkage compile to a
placeholder body.  Two such declarations exist in the Phase-5 build:

  * `LegalKernel.Authority.Crypto.Verify` — body is `false` at runtime.  The
    deployment adaptor wires Ed25519 (or the chosen scheme) via
    `@[extern verify_impl]` linkage at link time.  See
    `LegalKernel/Authority/Crypto.lean` for the spec; Phase 5 ships
    the placeholder body so that `knomosis` builds and runs in
    test-only mode (where `Verify` returns `false` for every call,
    so every action is rejected as inadmissible — the runtime's
    rejection path).  Production deployments (Phase 5 WU 3.9) wire
    a real implementation; the runtime CLI is unchanged.
  * `LegalKernel.Authority.signingInput` — body is `ByteArray.empty`
    at runtime in the Phase-3 stub.  Phase 4's `signInput` (under
    `LegalKernel.Encoding.SignInput`) replaces this with the full
    domain-separated CBE encoding; `apply_admissible` calls the
    Phase-3 stub by default (because that's what the `Admissible`
    predicate references).  The runtime adaptor MUST patch
    `signingInput` to call `signInput` before running on real data.
    *Audit-1 status note:* the in-tree `signingInput` body now
    emits real CBE-encoded bytes (no longer a stub).  See
    `Authority/SignedAction.lean` for the post-audit body.

### 2.5 Hash-implementation extern discipline (Audit-3.1)

The runtime's content-hash function (`Runtime.Hash.hashBytes` /
`hashStream`) is declared as a regular `def` with documented C
ABI symbol names: `knomosis_hash_bytes`, `knomosis_hash_stream`, and
`knomosis_hash_identifier`.  See `docs/abi.md §11`.

The Lean fallback (FNV-1a-64 zero-padded to 32 bytes) is the
test-build default.  Production deployments substitute a vetted
cryptographic hash under the same C symbol names at link time.  Two
production targets are recognised:

  * **BLAKE3-256** — the Genesis Plan §8.8.4 abstract default;
    identifier `"blake3-256"`.
  * **keccak256** — the Ethereum-anchored path, used so that Lean
    state-commitments are byte-identical to the EVM `KECCAK256`
    opcode for cross-stack verification.  This is the adaptor that
    actually ships in-repo (`runtime/knomosis-hash-keccak256`,
    Workstream RH-A.2; opt-in via `KNOMOSIS_HASH_BACKEND=keccak256`);
    identifier `"keccak256/EVM-compatible/v1"`.  See TA-2.2 in §2.6.

The substitution discipline is identical to `Verify`'s:

  * Theorems about hash determinism + output width hold for the
    Lean fallback; production implementations must respect the
    same contract (`size = 32`; deterministic across invocations;
    no IO side effects).
  * The CLI binaries (`knomosis`, `knomosis-replay`) read
    `hashImplementationIdentifier ()` at startup to determine
    whether the production swap occurred.  The fallback returns
    `"fnv1a64-padded-32"`; production returns the linked adaptor's
    identifier (e.g. `"blake3-256"` or
    `"keccak256/EVM-compatible/v1"`).
  * `knomosis-replay` refuses to print an `OK` line under the
    fallback unless the operator explicitly opts in via
    `--allow-fallback-hash` — the auditor's reproduction
    guarantee is meaningless under a 64-bit non-cryptographic
    hash.

Audit-3.1 unifies the on-disk hash width to a fixed 32 bytes
(matching BLAKE3-256), eliminating the variable-width chain
transition that earlier phases documented.  This means logs and
snapshots produced by pre-Audit-3 binaries are unreadable by
post-Audit-3 binaries.  For research-stage software this is
acceptable; the migration path is "throw away the old log,
bootstrap fresh".

### 2.6 Trust Assumption Catalogue

This subsection (added by Workstream WG.4) enumerates the five
operational trust assumptions the **Ethereum integration**
(Workstreams E-A through E-G) introduces.  Each TA is a property
of an *external* component (a Rust adaptor crate, an L1 contract,
or a wallet) that some Lean theorem's conclusion depends on.
None is a Lean axiom; all surface as `opaque` Lean declarations
(linked via `@[extern]` to runtime adaptors) or as conditional-
hypothesis parameters to theorems.  Genesis Plan §15D.2
discusses these at the architectural level; the entries below
name the precise swap-points and consuming theorems.

#### TA-2.1 EUF-CMA on ECDSA secp256k1

  * **Statement.**  For any polynomial-time adversary `A` and any
    message space `M`, given access to a signing oracle for a
    freshly-generated secp256k1 key-pair, `A` cannot produce a
    valid signature on a previously-unsigned message except with
    negligible probability.
  * **Lean swap-point.**  `LegalKernel.Authority.Crypto.Verify`
    (`opaque`) — linked via `@[extern]` to the production
    secp256k1 verifier.
  * **Production runtime adaptor.**
    `runtime/knomosis-verify-secp256k1` (Workstream RH-A.1).
    Built on `k256 = "0.13"`; enforces strict 33-byte
    SEC1-compressed pubkey, 32-byte pre-hashed message, 64-byte
    `(r ‖ s)` signature, `1 ≤ r < n` and `1 ≤ s < n` bounds,
    AND the load-bearing EIP-2 / BIP-62 low-s canonicalisation
    (via `k256::IsHigh`).
  * **L1 mirror.**  OpenZeppelin's `ECDSA.recover` in
    `solidity/lib/openzeppelin-contracts/` enforces the same
    EUF-CMA hypothesis plus low-s canonicalisation.
  * **Consuming Lean theorems.**
    `Authority.SignedAction.replay_impossible` (Phase 3),
    `Authority.SignedAction.nonce_uniqueness` (Phase 3),
    `Bridge.Eip712.eip712Wrap_injective` (E-A.3),
    `Bridge.Admissible.bridge_replay_impossible` (E-C.0c).
  * **Originating workstream.**  Phase 3 (kernel-level Verify
    opaque); concretised by Workstream A.1.

#### TA-2.2 keccak256 collision-resistance

  * **Statement.**  It is computationally infeasible to find
    `x ≠ y` with `keccak256(x) = keccak256(y)`.  This is the
    standard collision-resistance hypothesis.
  * **Lean swap-point.**  `LegalKernel.Runtime.Hash.hashBytes`
    (`def` with `@[extern "knomosis_hash_bytes"]`) — linked via
    `@[extern]` to the production keccak256 binding.  The
    fallback FNV-1a-64 implementation is the test-build default
    (per §2.5); production deployments override at link time.
  * **Production runtime adaptor.**
    `runtime/knomosis-hash-keccak256` (Workstream RH-A.2).
    Built on `sha3 = "0.10"`; Ethereum-flavoured Keccak-256
    (NOT FIPS-202 SHA3-256).  Identifier:
    `"keccak256/EVM-compatible/v1"`.
  * **L1 mirror.**  The EVM `KECCAK256` opcode.
  * **Consuming Lean theorems.**  Every
    `*_under_collision_free` lemma, most notably:
    `commitExtendedState_subcommits_extensional_eq_under_collision_free`
    (Workstream EI.8.b / Workstream H),
    `smtCellProof_sound_under_collision_free` (SC.1.d),
    `smtCellProof_no_value_substitution` (SC.1.e),
    `Bridge.WithdrawalRoot.verifyProof_sound` (E-D.1.4),
    `Bridge.Eip712.eip712Wrap_injective` (E-A.3),
    `Bridge.Eip712.eip712DomainSeparator_distinguishes` (E-A.3).
  * **Originating workstream.**  Phase 5 WU 5.1 (hash swap-point);
    concretised by Workstream A.2.

#### TA-2.3 Ethereum L1 finality

  * **Statement.**  L1 blocks at depth ≥ `N` do not reorder.
    The default `N = 12` matches Ethereum mainnet's
    post-Casper finalisation convention.  Operators may
    configure deeper depths for higher-value deployments.
  * **Lean swap-point.**  Not a Lean opaque; surfaces as the
    confirmation-depth parameter consumed by
    `Bridge.Finalisation.isFinalised`
    (`LegalKernel/Bridge/Finalisation.lean`) and the L1
    ingestor's `--confirmation-depth` operator knob.
  * **Production runtime adaptor.**
    `runtime/knomosis-l1-ingest::reorg::ReorgWindow` (Workstream
    RH-B) implements a sliding-window re-org tracker; logs are
    fetched by **block hash** (EIP-234's
    `eth_getLogs.blockHash` parameter), not by number, so an
    L1 re-org racing the header→logs sequence resolves to a
    typed error rather than wrong-fork logs being processed.
    Deep re-orgs (depth > window) surface as
    `WatcherError::Reorg` and halt the daemon loudly.
  * **L1 contract surface.**
    `KnomosisBridge.submitStateRoot(...)` accepts only
    sequencer-attested state roots; `withdrawWithProof(...)`
    enforces the post-finalisation window via
    `block.number ≥ submissionBlock + FAULT_PROOF_DISPUTE_WINDOW`.
  * **Consuming Lean theorems.**
    `Bridge.Finalisation.isFinalised_monotonic_in_currentBlock`
    (E-D.3 monotonicity) and the cross-stack finalisation
    invariant in `solidity/test/KnomosisBridge.t.sol`.
  * **Originating workstream.**  Workstream D.3 (finalisation
    policy); operational mitigation in Workstream RH-B.
  * **Failure mode.**  A finality violation (re-org deeper
    than `N`) cannot retroactively undo a redeemed withdrawal
    because L1 redemption is itself an L1 transaction subject
    to the same re-org window; but it can cause the sequencer
    to attest contradictory state roots in the post-re-org
    timeline.  The operator runbook
    (`docs/fault_proof_runbook.md` §7) covers the recovery
    path; the Workstream-H fault-proof game is the long-term
    defence (challengers force the sequencer to either repair
    or accept a slash).

#### TA-2.4 Solidity-contract correctness

  * **Statement.**  The deployed Solidity bytecode in
    `solidity/src/contracts/` and `solidity/src/lib/`
    faithfully implements the audited Solidity source.
  * **Lean swap-point.**  None directly; this is a deployment-
    side trust assumption.  However, the
    `l1FaultProofVerifier` opaque
    (`LegalKernel/FaultProof/Witness.lean`) carries an
    `L1AttestationSemantics` predicate that encodes "the L1
    fault-proof game's settlement reflects the operational
    semantics of `KnomosisFaultProofGame.sol`".  Cross-stack
    ratification (per §15D.9) is the operational defence.
  * **Production runtime adaptor.**  Not applicable
    (Solidity-side).
  * **L1 mirror.**  Self.
  * **Compensating control.**  The Workstream-F cross-stack
    fixture corpus (F.1.x) and the Workstream-SC SMT corpus
    (SC.3) mechanically ratify byte-for-byte agreement
    between the Lean references and the Solidity
    implementations on every covered surface.  The
    `foundry.toml` pins `solc_version = "0.8.20"` with
    `evm_version = "shanghai"` and `via_ir = true`; any
    deployment that diverges from the pin must re-run the
    cross-stack suite under the new toolchain.
  * **Pre-deployment audit bar.**  Higher than for
    upgradeable contracts because every contract is
    `immutable`: no proxy, no `initialize`, no admin role
    (`solidity/README.md` "Immutability discipline").  There
    is no post-deployment patch path for code defects.
  * **Originating workstream.**  Workstream E (Solidity
    contracts); ratified by Workstream F (cross-stack).
  * **Failure mode.**  A bug in a deployed contract is
    addressed by:
      - For the v1 contracts, deploying a successor and using
        `KnomosisMigration.activate()` to retire the predecessor.
      - For the v2 (Workstream-H) contracts,
        `KnomosisFaultProofMigration.activate()` retires the v1
        suite and activates the v2 quartet.
    There is **no in-place upgrade path**; the immutability
    discipline is load-bearing.

#### TA-2.5 EIP-1271 contract-wallet correctness

  * **Statement.**  For every smart-contract wallet `W` the
    deployment admits, `W`'s
    `isValidSignature(bytes32 hash, bytes signature)`
    callback returns the canonical `0x1626ba7e` magic value
    iff the wallet's intent-set permits the signed message.
    The wallet itself is the authority for what its own
    signers can sign.
  * **Lean swap-point.**  None directly; EIP-1271 is
    deployment-side.  The kernel's `Verify` opaque
    (TA-2.1) is invoked for EOA-signed actions; contract-
    signed actions defer to the wallet's L1 callback.
  * **Production runtime adaptor.**  Not applicable
    (Solidity-side).
  * **L1 mirror.**  `KnomosisIdentityRegistry.registerEIP1271`
    (`solidity/src/contracts/KnomosisIdentityRegistry.sol`)
    probes the wallet's `isValidSignature(bytes32(0), "")`
    callback at registration time and rejects wallets that
    return non-canonical responses.  Per-signature
    verification (when the wallet authorises a Knomosis
    `SignedAction`) is performed by the dispute verifier's
    `checkSignatureInvalid` machinery (which dispatches to
    EIP-1271 when the registered key is a contract wallet).
  * **Consuming Lean theorems.**  None directly (deployment-
    side); the operational guarantee is that contract-signed
    actions are user-authorised.
  * **Originating workstream.**  Workstream A.1 (EIP-1271
    opt-in) + Workstream E.3 (`registerEIP1271`).
  * **Failure mode.**  A buggy or malicious EIP-1271 wallet
    can authorise actions its nominal user did not intend.
    The mitigation is that wallets must be opted in
    explicitly (via `registerEIP1271`); the deployment
    operator is responsible for vetting the wallet's source
    + bytecode before admission.  EIP-1271 v2 (recursive
    cross-contract auth) is explicitly out of scope
    (§15D.10 #4).

### 2.7 Cross-references for TA-2.X

The five TAs above are also documented in:

  * Genesis Plan §15D.2 (architectural framing).
  * `docs/abi.md` §16 (Ethereum ABI cross-reference).
  * `docs/planning/ethereum_workstream_g_plan.md` §WG.4
    (the engineering plan for this trust-assumption catalogue).

A toolchain bump, a re-deployment, or a new Solidity audit
amends the relevant TA-2.X entry in this section first, then
propagates through the cross-references.

## 3. Persistence: what survives

The following artefacts make it from Lean source to bytes the
runtime emits.

### 3.1 The kernel TCB

Every kernel `def` (notably `step_impl`, `apply_certified`,
`getBalance`, `setBalance`) compiles to LCNF, then to IR, then to
LLVM, then to optimized machine code.  The compiled forms are
*specialisations* of the Lean source:

  * `step_impl s t = if t.decPre s then t.apply_impl s else s` —
    compiled to a conditional branch on the `decide` result.
  * `getBalance` / `setBalance` — compile to `Std.TreeMap` operations,
    which themselves compile to inline RB-tree traversal/mutation.

### 3.2 The encoder modules

Every `Encodable` instance ships its `encode` and `decode` as
runtime-callable functions.  The CBE encoder is a tight loop over
the constructor tag + per-field encodings; no proof obligation
contributes to its bytes.

### 3.3 The runtime modules

`LegalKernel.Runtime.{Hash, LogFile, Replay, Snapshot, Loop}` all
compile to standard Lean IR.  In particular:

  * `fnv1a64Stream` — a `List.foldl` over `UInt64` arithmetic.  The
    Lean compiler specialises the fold to a tight loop; the
    `* fnvPrime` step is one IMUL.
  * `encodeFrame` — a `++`-chain over four `Stream`s; Lean's
    compiler typically specialises `List.append` to a loop.
  * `appendEntry` — an `IO.FS.Handle.write` call wrapped in `do`.

### 3.4 The runtime CLI

`Main.lean` and `Replay.lean` compile to the `knomosis` and
`knomosis-replay` executables respectively.  Lean's `def main : IO
UInt32` is the entry point; the platform's libc handles process
startup.

## 4. Spot-check: what the binary does

The following observations were made on a debug build of the
Phase-5 `knomosis` binary:

```bash
$ file .lake/build/bin/knomosis
.lake/build/bin/knomosis: ELF 64-bit LSB pie executable, x86-64 ...

$ .lake/build/bin/knomosis info
knomosis: legal-kernel runtime
  version:   0.8.4
  proof-carrying state-transition kernel (see CLAUDE.md for milestone status)
  hash:        fnv1a64-padded-32
  hash-grade:  fallback (FNV-1a-64 padded to 32, NOT FOR PRODUCTION)
```

`objdump -t .lake/build/bin/knomosis | grep _verify` shows the
expected `Verify`-related symbols routed through the opaque-stub
implementation; production deployments link against a Rust
`verify_impl.o` that overrides them.

## 5. Determinism caveat

Lean's compiler may emit different machine code on different
architectures (x86_64 vs ARM64), but every call to a kernel
function still produces the same `Bool` / `State` / `ContentHash`
output.  The acceptance gate (Genesis Plan §13.2) is *byte-for-byte
state-hash reproducibility across machines* — this is verified by
running `knomosis-replay` on a log produced by a different machine and
comparing the printed hash.

Floating-point operations would break determinism here; the kernel
uses `Nat` / `UInt64` exclusively, so this concern does not apply.
The encoder and hash function are similarly integer-only.

## 6. Build sizes (informational)

A debug build of the Phase-5 binaries weighs roughly:

  * `knomosis` — ~7 MB (Lean runtime + standard library + project code)
  * `knomosis-replay` — ~7 MB (same; the binary delta is small)

Release builds (`-O2 -DNDEBUG`) typically halve these numbers.  A
production deployment with FFI'd Verify and BLAKE3 would add a few
hundred kilobytes for the cryptographic libraries.

## 7. Audit-pass hardening (post-landing)

Following the initial Phase-5 landing, two audit passes identified
and fixed issues — none required code regeneration of the existing
binaries, but all touched modules that are shipped to production:

**Audit 1:**

  * **`partial def decodeAllFrames'` → terminating fueled def.**
    The original `partial def` was opaque to Lean's reducer; the
    fueled form is a normal `def` whose termination proof goes
    through structural induction on the fuel parameter.
  * **`BootstrapError` name collision with `Snapshot`'s.** Renamed
    `Snapshot`-flavoured one to `ReplicaError`; the `Loop`-flavoured
    one drops its tickled-prime suffix.
  * **`bootstrapFromSnapshot` snapshot-error precision.**
    Previously masked snapshot-restoration failures as a generic
    `chainBroken` replay error.  Now surfaces them as
    `.snapshot e` with the precise `SnapshotError`.
  * **`knomosis-replay` fail-fast on bad snapshot (security).**  An
    earlier draft silently continued with empty genesis on snapshot
    failure, masking the failure and printing `OK <wrong-hash>`.
    Now the binary refuses to proceed and exits non-zero.
  * **`loadSnapshot` graceful missing-file handling.**  Previously
    threw an uncaught IO exception; now returns
    `.error .unexpectedEof`.

**Audit 2 (correctness):**

  * **`bootstrapFromSnapshot` and `knomosis-replay` snapshot-slicing
    fix.**  Both code paths previously passed the full log file to
    `replayFromSeed`, even when the snapshot's `logIndex > 0`.
    This broke the Genesis Plan §13.2 acceptance criterion ("apply
    only subsequent log entries") for any non-empty pre-snapshot
    history.  Now both paths slice `entries.drop snap.logIndex`
    before replay.
  * **`BootstrapError.logIndexOverrun`** new variant for the case
    where `snap.logIndex > entries.length`; previously this was
    undetectable.
  * **`knomosis-replay` `SNAPSHOT_INDEX_OVERRUN` output line** —
    surfaces the same inconsistency at the CLI boundary.
  * **`LogEntry.hash` spec alignment** — changed from `encoded
    action ++ prev.toList` (raw bytes) to `encoded action ++
    encoded prev` (CBE-encoded), matching Genesis Plan §8.8.4
    `BLAKE3(encode signedAction || encode previousLogEntryHash)`.
  * **`hashEncodable` optimisation** — `hashStream (encode v)`
    directly, avoiding the `Stream → ByteArray → List` round-trip.
  * **Frame layout doc** — `"15 + N"` corrected to `"20 + N"`.
  * **Fuel-exhaustion handling** in multi-frame loaders — clarified
    that fuel-exhaustion (vs stream-exhaustion) is a programming
    bug; surfaces an explicit diagnostic instead of silently
    returning success.

## 8. Limitations

Phase 5's Lean-only implementation does *not* ship:

  * **Rust network adaptor (WU 5.4)** — would accept `SignedAction`
    payloads over TCP/QUIC and forward them to the Lean runtime via
    a Unix socket.  Documented in `docs/abi.md` (the on-wire
    contract).
  * **Rust event subscription protocol (WU 5.7)** — depends on
    Rust as the host language.
  * **SQLite indexer (WU 5.8)** — depends on a real DB layer.
  * **10k tx/sec benchmark suite (WU 5.11)** — depends on the
    network adaptor for end-to-end measurement.

These are *interop* deliverables: the in-Lean kernel + runtime is
fully functional and end-to-end-tested without them.  Future work
will land them as a separate PR with their own CI infrastructure.

## 9. Phase-6 dispute pipeline notes

Phase 6 adds the §8.4 four-stage dispute pipeline.  Like the Phase-3
authority layer, the dispute pipeline lives outside the kernel TCB
but within the runtime's compilation unit.  Notes:

  * **No new `opaque` declarations.**  The Phase-6 modules
    (`Disputes/{Types, Filing, Evidence, Verdict}` +
    `Encoding/Disputes`) introduce no new opaque-as-axiom
    declarations.  The `verdictSigningInput` placeholder follows
    the Phase-3 pattern: a `def` returning `ByteArray.empty` rather
    than an `opaque`.  Any deployment that wires a real signature
    chain on verdicts must replace it with a CBE-based domain-
    separated encoder.
  * **`kernelOnlyReplay` admissibility-blindness.**  The dispute
    pipeline's prefix-replay function (`Disputes/Evidence.lean`,
    `kernelOnlyReplay`) bypasses the chain / admissibility / post-
    hash checks of `Runtime/Replay.lean`'s `replay`.  This is
    intentional: the dispute pipeline must analyse logs whose
    runtime-time admissibility cannot be re-established (e.g.
    because the runtime was buggy and applied an inadmissible
    action — exactly the case the dispute is diagnosing).  The
    `step_impl` semantics ("no-op if precondition fails") mean
    `kernelOnlyReplay` cannot produce an inconsistent state: it
    simply records what would have happened if the kernel had
    been the only authority.
  * **Decidable `Admissible`.**  Phase 5's `Decidable Admissible`
    instance (in `Runtime/Replay.lean`) is consumed by Phase-6
    `proposeVerdict` to evaluate verdicts.  No new decidability
    obligations are introduced.
  * **Stage 4 rollback recording.**  An upheld verdict produces an
    `Action.rollback targetIdx` SignedAction that the runtime
    appends to the log AFTER `applyVerdict` returns the rolled-
    back state.  The kernel-level effect of `Action.rollback` is
    identity (it compiles to `Laws.freezeResource 0`); the
    state replacement is performed by the runtime layer
    *outside* `apply_admissible`.  This separation lets replay
    correctly reproduce the rollback: the runtime's main loop
    replaces the state at the rollback point, and replay tools
    detect the rollback by walking the log forward and applying
    the same replacement when an `Action.rollback` is seen.

## 10. Ethereum Workstream notes

The Ethereum-integration Workstreams A – D add modules under
`LegalKernel/Bridge/` and a new CLI subcommand
(`knomosis withdrawal-proof SNAP_PATH ID`).  All compile via the
same Lean → LLVM pipeline as the base kernel:

  * **Workstream A (`Bridge/{VerifyAdaptor, HashAdaptor, Eip712}`)**
    is pure type-level documentation: stability theorems, KAT
    vectors, and adaptor-identifier strings.  No new `opaque`
    declarations beyond the base `Verify` / `hashBytes` swap-points
    that the Rust adaptor crates target.
  * **Workstream B (`Bridge/{AddressBook, BridgeActor, Ingest}`)**
    is pure data: address ↔ actor-id translation, the bridge actor
    constant (id = 0), and the L1-event-to-`UnsignedBridgeAction`
    translator.  No IO at the Lean level; the runtime adaptor
    handles L1 RPC.
  * **Workstream C (`Bridge/{State, Admissible, Accounting}` +
    `Laws/{Deposit, Withdraw}`)** extends the kernel-level state
    transformer.  `applyActionToBridgeState` is a pure function
    over `BridgeState`; the runtime's main loop calls it after
    `apply_admissible`.
  * **Workstream D (`Bridge/{WithdrawalRoot, WithdrawalProof,
    Finalisation}`)** ships the SMT verifier / constructor / extractor
    and the new `knomosis withdrawal-proof` subcommand.  The
    32-byte hash output is the same as the runtime's content
    hash (linked to the same C symbols at production time).
  * **Workstream F (cross-stack verification)** is pure
    test-driver infrastructure under `LegalKernel/Test/Bridge/
    CrossCheck/*` plus golden fixtures under `solidity/test/`.
    None of it ships in the runtime binary; it exists to gate
    behavioural equivalence between the Lean and Solidity
    implementations.  CI runs both `lake test` and
    `forge test` on every PR.

## 11. Workstream-LP and Lex notes

**Workstream LP (actor-scoped policies)** lands the
`LocalPolicy` data layer (`Authority/LocalPolicy.lean`,
`Authority/LocalPolicySemantics.lean`), the `LocalPolicies` map
embedding into `ExtendedState`, and two new `Action`
constructors at frozen indices 15 / 16.  All surface
declarations are pure data; the only IO concern is that the
`ExtendedState` codec extension changes the on-disk format
(the `localPolicies` field is appended as a 5th segment).
Pre-LP snapshots cannot be decoded by the post-LP build (per
the strict-decoder design); operators upgrade by re-snapshotting
under the new build.  No new `opaque` declarations.

**Workstream LX (Lex law-declaration language)** is *macro
infrastructure*.  The `lexlaw` and `deployment` macros run at
elaboration time, emitting standard Lean `def`s that compile
through the same pipeline as hand-written declarations.  The
`Tools/Lex*.lean` audit binaries (`lex_lint`, `lex_codegen`,
`lex_diff`, `lex_format`) are standalone CLI executables built
by Lake; they do not contribute to the runtime binary's
behaviour.  None of the Lex tooling is `opaque`-bearing or
introduces new axioms.  The `_lex_inputs/*.json` codegen-input
sidecars are the cross-pass medium between the macro and the
codegen binary; they are checked into the repository for
deterministic CI behaviour.

## 12. References

  * Genesis Plan §11.3 (Extraction Targets)
  * Genesis Plan §12 WU 5.9 (Extraction Notes — this document)
  * Genesis Plan §13.4 (Reproducibility)
  * `docs/abi.md` (the on-wire and on-disk contracts)
  * `docs/planning/ethereum_integration_plan.md` (Workstream-by-workstream
    deliverables for the Bridge layer)
