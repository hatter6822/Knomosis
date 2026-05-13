/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.Hash — deterministic content hash for the
runtime's log-chain, snapshot identifiers, and torn-write detection.

Phase 5 WU 5.1 (foundation) / WU 5.2 / WU 5.5 / WU 5.12.

Genesis Plan §8.8.4 (post-Audit-3 amendment) calls for **BLAKE3**
(256-bit output) for `ActionHash`, `LogEntryHash`, `StateHash`, and
`GenesisHash`.  BLAKE3 is not part of Lean core and the kernel's
"Std core only" rule forbids pulling in a third-party crypto
library.  This module ships a **deterministic Lean-native fallback**
— FNV-1a-64 zero-padded to 32 bytes — so that the runtime, replay
tool, and snapshot machinery can compose end-to-end without an
external dependency, and so that every chain-related theorem
(`hashBytes_deterministic`, `hashStream_deterministic`,
`hashBytes_size`, `hashStream_size`) is provable inside Lean.

Audit-3.1 unifies the on-disk hash width to a fixed 32 bytes
(matching BLAKE3-256), eliminates the variable-width chain
transition, and adds a real `@[extern]` swap-point.  Production
deployments link a BLAKE3-256 implementation under the
`canon_hash_bytes` / `canon_hash_stream` symbols; if absent, the
Lean fallback runs.  The `canon_hash_identifier` symbol returns the
implementation name (`"fnv1a64-padded-32"` for the fallback,
`"blake3-256"` for the BLAKE3 adaptor); `Main.lean` reads it to
decide whether to emit the fallback warning, and `Replay.lean`
reads it to fail-fast on the auditor binary unless the operator
explicitly opts in via `--allow-fallback-hash`.

The link-time ABI contract (AR.10):

  @[extern "canon_hash_bytes"]       def hashBytes
  @[extern "canon_hash_stream"]      def hashStream
  @[extern "canon_hash_identifier"]  def hashImplementationIdentifier

Production deployments supply C functions matching these symbol
names with the documented argument / return shapes; the Lean
compiler emits calls to the linked symbol in compiled native
code while keeping the Lean body as the in-proof reduction.

The fallback's collision-resistance is **64 bits** (vs BLAKE3's 256).
This is sufficient for:

  * **Torn-write detection.**  WU 5.2 / 5.3's framing uses the hash
    to detect partial writes; an attacker would have to find a
    pre-image, not a collision, and torn-write detection only needs
    to distinguish the truncation point from a complete frame.
  * **Replay verification.**  WU 5.5 compares the runtime's
    on-the-fly state hash with the replay tool's recomputed hash;
    both call into the same Lean function, so any discrepancy
    indicates a non-deterministic computation (a kernel bug), not a
    hash collision.
  * **Snapshot identification.**  WU 5.12's snapshots are identified
    by their state hash; the same in-Lean-only verification applies.

The fallback is **NOT** sufficient for adversarial settings (an
attacker could construct two `LogEntry`s with the same `LogEntryHash`
and bypass the chain's tamper-evidence in 2³² operations).
Production deployments swap to BLAKE3 to recover the §8.8.4 security
bound.

This module is **not** part of the trusted computing base: bugs here
produce wrong on-disk hashes, but cannot violate any kernel
invariant.  The kernel's correctness theorems do not depend on
hashing at all.
-/

import LegalKernel.Encoding.CBOR
import LegalKernel.Encoding.Encodable

namespace LegalKernel
namespace Runtime

open Encoding

/-! ## FNV-1a-64 constants

The standard FNV-1a-64 constants from
<http://www.isthe.com/chongo/tech/comp/fnv/>.  These are not secret
parameters; they are part of the FNV-1a specification and any other
FNV-1a implementation produces identical bytes for the same input
(determinism across compatible implementations is the only property
the runtime relies on). -/

/-- FNV-1a-64 offset basis: 14695981039346656037 = 0xcbf29ce484222325. -/
def fnvOffsetBasis : UInt64 := 0xcbf29ce484222325

/-- FNV-1a-64 prime: 1099511628211 = 0x100000001b3. -/
def fnvPrime : UInt64 := 0x100000001b3

/-! ## Core hash function

FNV-1a-64 over a `List UInt8` (= `Stream` in the Encoding namespace):
fold the standard `(acc XOR byte) * prime` step from the offset basis.
-/

/-- FNV-1a-64 of a byte stream.  Returns the 64-bit hash as a `UInt64`.

    The fold step is `acc' := (acc XOR b.toUInt64) * fnvPrime`, run
    over each byte of the input.  `UInt64` arithmetic wraps modulo
    `2^64`, which is exactly the FNV-1a-64 specification.

    Determinism: `fnv1a64Stream` is a `def`, so equal inputs trivially
    produce equal outputs (`fnv1a64Stream_deterministic`). -/
def fnv1a64Stream (bs : Stream) : UInt64 :=
  bs.foldl (fun acc b => (acc ^^^ b.toUInt64) * fnvPrime) fnvOffsetBasis

/-- FNV-1a-64 of a `ByteArray`.  Forwards to `fnv1a64Stream` via
    `ByteArray.toList`. -/
def fnv1a64Bytes (bs : ByteArray) : UInt64 :=
  fnv1a64Stream bs.toList

/-! ## Content hash type

A `ContentHash` is the runtime-layer identifier for a hashed value.
Audit-3.1 unifies the on-disk hash width to a fixed 32 bytes
(matching BLAKE3-256's output width).  The Lean fallback emits
FNV-1a-64 as 8 little-endian bytes followed by 24 zero bytes; the
production `@[extern]` adaptor emits 32 bytes directly.  The
chain-comparison logic compares byte sequences verbatim, so the
fixed width eliminates the variable-width transition that earlier
phases documented. -/

/-- A content hash: 32 bytes for both fallback (FNV-1a-64
    zero-padded to 32) and production (BLAKE3-256). -/
abbrev ContentHash : Type := ByteArray

/-- Pack a `UInt64` as 8 little-endian bytes.  Used as the FNV-1a-64
    payload that `padTo32` extends to a full 32-byte `ContentHash`. -/
def uint64ToBytesLE (n : UInt64) : ByteArray :=
  ByteArray.mk (natToBytesLE n.toNat 8).toArray

/-- Pad an 8-byte FNV-1a-64 payload to a full 32-byte `ContentHash`
    by appending 24 zero bytes.  Audit-3.1 fixes the on-disk hash
    width at 32 bytes regardless of which hash implementation is
    linked; the production `@[extern]` adaptor produces 32 bytes
    directly and bypasses this padding. -/
def padTo32 (n : UInt64) : ByteArray :=
  uint64ToBytesLE n ++ ByteArray.mk (Array.replicate 24 (0 : UInt8))

/-! ## Lean fallback implementations (AR.10)

The fallback hashing functions live below as ordinary Lean `def`s
(no `@[extern]`), so the Lean compiler emits standalone C code for
each one.  The C stub `runtime/canon-hash-fallback.c` then
*defines* the deployment-facing C ABI symbols (`canon_hash_bytes`,
`canon_hash_stream`, `canon_hash_identifier`) as forwarders to
these Lean-compiled fallback functions.  Production deployments
link a real BLAKE3 implementation under the same C ABI symbol names
*ahead of* the stub object file, which overrides the forwarders
and routes the runtime to the production hash.

The public-facing entry points (`hashBytes`, `hashStream`,
`hashImplementationIdentifier`) carry `@[extern]` annotations so
the deployment swap-point is materialised at the Lean level rather
than buried in a comment.  Their Lean bodies are kept as
`hashBytesFallback bs` / `hashStreamFallback bs` / the constant
fallback identifier — these are what Lean uses for proof-time
reduction (e.g. in `decide`, `rfl`), so every theorem in this file
remains provable by structural induction on the fallback chain. -/

/-- AR.10 Lean fallback for `hashStream`.  Compiles to a regular C
    function (`lp_canon_LegalKernel_Runtime_hashStreamFallback`)
    that the C stub at `runtime/canon-hash-fallback.c` forwards to
    when no production hash adaptor is linked. -/
def hashStreamFallback (bs : Stream) : ContentHash :=
  padTo32 (fnv1a64Stream bs)

/-- AR.10 Lean fallback for `hashBytes`.  Compiles to a regular C
    function (`lp_canon_LegalKernel_Runtime_hashBytesFallback`)
    that the C stub at `runtime/canon-hash-fallback.c` forwards
    to. -/
def hashBytesFallback (bs : ByteArray) : ContentHash :=
  padTo32 (fnv1a64Bytes bs)

/-- Hash a byte stream and return the 32-byte `ContentHash`.
    Top-level entry point used by `Runtime/LogFile.lean`,
    `Runtime/Replay.lean`, and `Runtime/Snapshot.lean`.

    Audit-3.1 swap-point contract (AR.10): `@[extern
    "canon_hash_stream"]` makes the link contract explicit.  When
    the binary is linked against the default
    `runtime/canon-hash-fallback.c` stub (the research-repo case),
    `canon_hash_stream` forwards to `hashStreamFallback` so the
    Lean fallback runs at runtime.  Production deployments link a
    BLAKE3-256 implementation that exports `canon_hash_stream`
    ahead of the stub, overriding the forwarder.

    The annotation does not affect Lean's logical model: theorems
    about `hashStream` reason about the Lean body
    (`hashStreamFallback bs`); the size + determinism contracts
    hold for any production implementation respecting the same
    width / purity contract.  See `docs/extraction_notes.md` for
    the full swap-point discipline. -/
@[extern "canon_hash_stream"]
def hashStream (bs : Stream) : ContentHash :=
  hashStreamFallback bs

/-- Hash a `ByteArray` and return the 32-byte `ContentHash`.

    Audit-3.1 swap-point contract (AR.10): production C ABI symbol
    name is `canon_hash_bytes`.  See `hashStream` docstring for the
    swap-point discipline; the `@[extern]` annotation here makes
    the link contract explicit, with `runtime/canon-hash-fallback.c`
    supplying the default forwarder to `hashBytesFallback`. -/
@[extern "canon_hash_bytes"]
def hashBytes (bs : ByteArray) : ContentHash :=
  hashBytesFallback bs

/-- Hash an `Encodable` value via its CBE bytes.  Convenience wrapper
    that composes `Encodable.encode` with `hashStream`.  Avoids the
    `Stream → ByteArray → List` round-trip that `hashBytes` would
    require (`hashStream` operates directly on the encoder's
    `List UInt8` output). -/
def hashEncodable {T : Type} [Encodable T] (v : T) : ContentHash :=
  hashStream (Encodable.encode v)

/-! ## The empty / "zero" content hash

A 32-byte zero array — distinguishable from any genuine
`hashBytes` output (which is at least one byte and computes through
the FNV chain).  Used as the `prevHash` of the genesis log entry
(no predecessor exists). -/

/-- The zero content hash: 32 zero bytes.  Used as the `prevHash`
    seed of the chain (the value written into the first log entry's
    `prevHash` field). -/
def zeroHash : ContentHash :=
  ByteArray.mk (Array.replicate 32 (0 : UInt8))

/-! ## Determinism (the headline property)

`hashBytes` and friends are pure Lean functions, so equal inputs
trivially produce equal outputs.  Stated explicitly so the Phase-5
acceptance gate ("the replay tool reproduces the runtime's state
hash") is documented. -/

/-- Determinism: equal byte inputs produce equal hashes. -/
theorem hashBytes_deterministic (bs₁ bs₂ : ByteArray) (h : bs₁ = bs₂) :
    hashBytes bs₁ = hashBytes bs₂ :=
  h ▸ rfl

/-- Determinism: equal stream inputs produce equal hashes. -/
theorem hashStream_deterministic (s₁ s₂ : Stream) (h : s₁ = s₂) :
    hashStream s₁ = hashStream s₂ :=
  h ▸ rfl

/-- Determinism: equal `Encodable` inputs produce equal hashes. -/
theorem hashEncodable_deterministic {T : Type} [Encodable T]
    (v₁ v₂ : T) (h : v₁ = v₂) :
    hashEncodable v₁ = hashEncodable v₂ :=
  h ▸ rfl

/-! ## Output-shape lemma

The hash output is exactly 32 bytes.  Audit-3.1 unifies the
fallback (FNV-1a-64 zero-padded to 32) and the production
(BLAKE3-256) widths.  Consumers can assume 32 bytes when packing /
unpacking hash values into log entries. -/

/-- The 8-byte FNV payload precedes 24 zero bytes; the padded
    output has size 8 + 24 = 32. -/
theorem padTo32_size (n : UInt64) : (padTo32 n).size = 32 := by
  show (uint64ToBytesLE n ++ ByteArray.mk (Array.replicate 24 (0 : UInt8))).size = 32
  rw [ByteArray.size_append]
  show (uint64ToBytesLE n).size + (ByteArray.mk (Array.replicate 24 (0 : UInt8))).size = 32
  unfold uint64ToBytesLE
  rw [show (ByteArray.mk (List.toArray (natToBytesLE n.toNat 8))).size
        = (List.toArray (natToBytesLE n.toNat 8)).size from rfl,
      List.size_toArray, natToBytesLE_length]
  rfl

/-- The hash output is exactly 32 bytes. -/
theorem hashBytes_size (bs : ByteArray) : (hashBytes bs).size = 32 :=
  padTo32_size _

/-- Same shape lemma for `hashStream`. -/
theorem hashStream_size (bs : Stream) : (hashStream bs).size = 32 :=
  padTo32_size _

/-- The zero hash has the documented shape (32 bytes — matching the
    unified hash width). -/
theorem zeroHash_size : zeroHash.size = 32 := rfl

/-! ## Hash-implementation introspection (Audit-3.1)

A runtime-introspectable identifier reporting which hash
implementation is linked into the binary.  The Lean fallback
returns `"fnv1a64-padded-32"`; production deployments override
the `canon_hash_identifier` symbol via `@[extern]` to return e.g.
`"blake3-256"`.

`isProductionHash` derives a Bool from the identifier — used by
`Main.lean` and `Replay.lean` to decide whether to emit the
fallback warning or fail-fast on the auditor binary. -/

/-- AR.10 Lean fallback for `hashImplementationIdentifier`.
    Compiles to a regular C function
    (`lp_canon_LegalKernel_Runtime_hashImplementationIdentifierFallback`)
    that the C stub at `runtime/canon-hash-fallback.c` forwards to
    when no production hash adaptor is linked. -/
def hashImplementationIdentifierFallback (_ : Unit) : String :=
  "fnv1a64-padded-32"

/-- The identifier reported by the linked hash implementation.
    Lean fallback returns `"fnv1a64-padded-32"`; production runtime
    overrides this function's compiled implementation under the C
    ABI symbol name `canon_hash_identifier` to return the
    production identifier (e.g. `"blake3-256"`).  The `@[extern]`
    annotation (AR.10) materialises the swap-point at link time:
    the default stub `runtime/canon-hash-fallback.c` forwards to
    `hashImplementationIdentifierFallback`, and production
    deployments link a real implementation ahead of the stub.

    Read at startup; the binary warns / errors if the identifier
    indicates the fallback and `--allow-fallback-hash` was not
    supplied. -/
@[extern "canon_hash_identifier"]
def hashImplementationIdentifier (u : Unit) : String :=
  hashImplementationIdentifierFallback u

/-- The fallback identifier, exposed as a constant for callers
    that need to compare against it directly. -/
def fallbackHashIdentifier : String := "fnv1a64-padded-32"

/-- True iff the linked implementation reports a non-fallback
    identifier.  Used by the CLI to decide whether to emit the
    fallback warning or fail-fast. -/
def isProductionHash : Bool :=
  decide (hashImplementationIdentifier () ≠ fallbackHashIdentifier)

end Runtime
end LegalKernel
