<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Phase 5 Extraction Notes (WU 5.9)

This document records what survives Lean's compilation pipeline into
the runtime binary.  It is the WU 5.9 deliverable per Genesis Plan
§12.

## 1. Goal

Phase 5's `canon` and `canon-replay` binaries are produced by Lean's
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

  * `LegalKernel.Authority.Verify` — body is `false` at runtime.  The
    deployment adaptor wires Ed25519 (or the chosen scheme) via
    `@[extern verify_impl]` linkage at link time.  See
    `LegalKernel/Authority/Crypto.lean` for the spec; Phase 5 ships
    the placeholder body so that `canon` builds and runs in
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
ABI symbol names: `canon_hash_bytes`, `canon_hash_stream`, and
`canon_hash_identifier`.  See `docs/abi.md §11`.

The Lean fallback (FNV-1a-64 zero-padded to 32 bytes) is the
test-build default.  Production deployments substitute a vetted
BLAKE3-256 implementation under the same C symbol names at link
time.  The substitution discipline is identical to `Verify`'s:

  * Theorems about hash determinism + output width hold for the
    Lean fallback; production implementations must respect the
    same contract (`size = 32`; deterministic across invocations;
    no IO side effects).
  * The CLI binaries (`canon`, `canon-replay`) read
    `hashImplementationIdentifier ()` at startup to determine
    whether the production swap occurred.  The fallback returns
    `"fnv1a64-padded-32"`; production returns e.g.
    `"blake3-256"`.
  * `canon-replay` refuses to print an `OK` line under the
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

`Main.lean` and `Replay.lean` compile to the `canon` and
`canon-replay` executables respectively.  Lean's `def main : IO
UInt32` is the entry point; the platform's libc handles process
startup.

## 4. Spot-check: what the binary does

The following observations were made on a debug build of the
Phase-5 `canon` binary:

```bash
$ file .lake/build/bin/canon
.lake/build/bin/canon: ELF 64-bit LSB pie executable, x86-64 ...

$ .lake/build/bin/canon info
canon: legal-kernel runtime
  build tag: canon-phase-6-disputes-adjudication
  Phase 6: Disputes and Adjudication (WU 6.1 – 6.12)
```

`objdump -t .lake/build/bin/canon | grep _verify` shows the
expected `Verify`-related symbols routed through the opaque-stub
implementation; production deployments link against a Rust
`verify_impl.o` that overrides them.

## 5. Determinism caveat

Lean's compiler may emit different machine code on different
architectures (x86_64 vs ARM64), but every call to a kernel
function still produces the same `Bool` / `State` / `ContentHash`
output.  The acceptance gate (Genesis Plan §13.2) is *byte-for-byte
state-hash reproducibility across machines* — this is verified by
running `canon-replay` on a log produced by a different machine and
comparing the printed hash.

Floating-point operations would break determinism here; the kernel
uses `Nat` / `UInt64` exclusively, so this concern does not apply.
The encoder and hash function are similarly integer-only.

## 6. Build sizes (informational)

A debug build of the Phase-5 binaries weighs roughly:

  * `canon` — ~7 MB (Lean runtime + standard library + project code)
  * `canon-replay` — ~7 MB (same; the binary delta is small)

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
  * **`canon-replay` fail-fast on bad snapshot (security).**  An
    earlier draft silently continued with empty genesis on snapshot
    failure, masking the failure and printing `OK <wrong-hash>`.
    Now the binary refuses to proceed and exits non-zero.
  * **`loadSnapshot` graceful missing-file handling.**  Previously
    threw an uncaught IO exception; now returns
    `.error .unexpectedEof`.

**Audit 2 (correctness):**

  * **`bootstrapFromSnapshot` and `canon-replay` snapshot-slicing
    fix.**  Both code paths previously passed the full log file to
    `replayFromSeed`, even when the snapshot's `logIndex > 0`.
    This broke the Genesis Plan §13.2 acceptance criterion ("apply
    only subsequent log entries") for any non-empty pre-snapshot
    history.  Now both paths slice `entries.drop snap.logIndex`
    before replay.
  * **`BootstrapError.logIndexOverrun`** new variant for the case
    where `snap.logIndex > entries.length`; previously this was
    undetectable.
  * **`canon-replay` `SNAPSHOT_INDEX_OVERRUN` output line** —
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

## 10. References

  * Genesis Plan §11.3 (Extraction Targets)
  * Genesis Plan §12 WU 5.9 (Extraction Notes — this document)
  * Genesis Plan §13.4 (Reproducibility)
  * `docs/abi.md` (the on-wire and on-disk contracts)
