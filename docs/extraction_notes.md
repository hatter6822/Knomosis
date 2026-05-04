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
  build tag: canon-phase-5-runtime-extraction
  Phase 5: Runtime and Extraction (WU 5.1 – 5.6, 5.9 – 5.12)
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

Following the initial Phase-5 landing, an audit pass identified and
fixed several issues — none required code regeneration of the
existing binaries, but all touched modules that are shipped to
production:

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

## 9. References

  * Genesis Plan §11.3 (Extraction Targets)
  * Genesis Plan §12 WU 5.9 (Extraction Notes — this document)
  * Genesis Plan §13.4 (Reproducibility)
  * `docs/abi.md` (the on-wire and on-disk contracts)
