// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Pure-Rust Keccak-256 (Ethereum-flavoured) hashing core.
//!
//! ## Variant choice
//!
//! Keccak-256 — the *original* Keccak with `0x01` byte-level
//! padding — is the Ethereum-canonical hash.  This is NOT the
//! FIPS-202 SHA3-256 (which uses `0x06` padding).  The two
//! algorithms share the underlying Keccak-f[1600] permutation
//! but produce DIFFERENT digests for the same input; mistaking
//! one for the other is a documented common foot-gun.  This crate
//! uses `sha3::Keccak256` from the `sha3` crate, which is the
//! correct variant.  See `docs/planning/rust_host_runtime_plan.md`
//! §RH-A.2.a for the discussion.
//!
//! ## Output width
//!
//! Always 32 bytes.  Matches Lean's `ContentHash` width fixed by
//! Audit-3.1 (`LegalKernel/Runtime/Hash.lean`).
//!
//! ## C ABI surface
//!
//! Four `#[no_mangle] extern "C"` entry points are exported for
//! consumption by `c/lean_shim.c`:
//!
//!   * [`knomosis_hash_keccak256_bytes_raw`] — one-shot hash of a
//!     byte slice.  Used for `knomosis_hash_bytes`.
//!   * [`knomosis_hash_keccak256_init`] — allocate a streaming
//!     context; returns an opaque `*mut c_void`.
//!   * [`knomosis_hash_keccak256_update_byte`] — feed one byte to
//!     a context.  Used for `knomosis_hash_stream` (which walks a
//!     Lean `List UInt8` one cons cell at a time).
//!   * [`knomosis_hash_keccak256_update_bulk`] — feed many bytes to
//!     a context.  Not currently used by the shim but provided
//!     for future expansion (e.g. a ByteArray-streamed path).
//!   * [`knomosis_hash_keccak256_finalize`] — emit the 32-byte
//!     digest and free the context.
//!
//! ## Output-shape contract
//!
//! All `_raw` and `_finalize` entry points write exactly 32 bytes
//! to the caller-supplied output buffer.  Output buffers MUST be
//! at least 32 bytes; the C shim allocates them via
//! `lean_alloc_sarray(1, 32, 32)`.

use sha3::{Digest, Keccak256};
use std::os::raw::c_void;

/// Output digest size in bytes.  Matches Lean's `ContentHash`
/// width (Audit-3.1 unified 32-byte fixed width).
pub const DIGEST_LEN: usize = 32;

/// One-shot Keccak-256 over a byte slice.  Returns the 32-byte
/// digest as an owned `[u8; 32]`.  Safe Rust API.
#[must_use]
pub fn keccak256(input: &[u8]) -> [u8; DIGEST_LEN] {
    let mut hasher = Keccak256::new();
    hasher.update(input);
    let result = hasher.finalize();
    let mut out = [0u8; DIGEST_LEN];
    out.copy_from_slice(&result);
    out
}

/// Convenience: hash a byte slice and return as a `Vec<u8>` of
/// length 32.  Allocates; prefer [`keccak256`] for stack output.
#[must_use]
pub fn keccak256_vec(input: &[u8]) -> Vec<u8> {
    keccak256(input).to_vec()
}

// =====================================================================
// C ABI surface
// =====================================================================
//
// These functions are consumed by the Lean shim in `c/lean_shim.c`.
// Their signatures use raw pointers; safety contracts live in each
// function's docstring.

/// Largest length `core::slice::from_raw_parts` accepts
/// (`isize::MAX`).  Spelled `usize::MAX >> 1`, which equals
/// `isize::MAX` on every two's-complement platform Rust supports,
/// to keep the comparison cast-free.
const MAX_SLICE_LEN: usize = usize::MAX >> 1;

/// One-shot Keccak-256 with C-compatible signature.
///
/// Reads `in_len` bytes starting at `in_ptr`, computes the
/// Keccak-256 hash, and writes 32 bytes to `out_ptr`.
///
/// # Safety
///
///   * `in_ptr` must point to a contiguous `in_len`-byte region
///     of initialised memory valid for reads (or `in_len == 0`
///     with a dangling pointer).
///   * `out_ptr` must point to a writeable 32-byte region of
///     initialised memory.
///   * The two regions need not be disjoint (we read first, then
///     write).
///
/// As defence-in-depth, the two contract violations detectable
/// in-process never dereference: a null `out_ptr` makes the call a
/// no-op, and a null `in_ptr` with `in_len > 0` (or an `in_len`
/// exceeding `isize::MAX`) zero-fills `out_ptr` — a deterministic
/// "poison" digest no real Keccak-256 output ever equals, so any
/// downstream commitment comparison fails closed instead of reading
/// stale buffer bytes.  The contract above remains binding: a
/// *dangling non-null* pointer is still undefined behaviour (no
/// in-process check can detect it).
///
/// Never panics in well-typed inputs.  The workspace's release
/// profile sets `panic = "abort"` as a defence-in-depth measure
/// against unwinding into Lean's runtime.
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_keccak256_bytes_raw(
    in_ptr: *const u8,
    in_len: usize,
    out_ptr: *mut u8,
) {
    if out_ptr.is_null() {
        return;
    }
    if (in_len > 0 && in_ptr.is_null()) || in_len > MAX_SLICE_LEN {
        core::ptr::write_bytes(out_ptr, 0, DIGEST_LEN);
        return;
    }
    let input = if in_len == 0 {
        &[][..]
    } else {
        core::slice::from_raw_parts(in_ptr, in_len)
    };
    let digest = keccak256(input);
    // Caller guarantees `out_ptr` is valid for 32 bytes.
    core::ptr::copy_nonoverlapping(digest.as_ptr(), out_ptr, DIGEST_LEN);
}

/// Allocate a streaming Keccak-256 context.  Returns an opaque
/// pointer the caller passes to [`knomosis_hash_keccak256_update_byte`],
/// [`knomosis_hash_keccak256_update_bulk`], and
/// [`knomosis_hash_keccak256_finalize`].
///
/// The context is heap-allocated via `Box::into_raw`; ownership is
/// transferred to the caller, who MUST call
/// `knomosis_hash_keccak256_finalize` to release it.  `_finalize`
/// reads the digest and frees the context in one step.
///
/// This function never returns a null pointer: `Box::new` aborts
/// the process on allocator failure (under the workspace's
/// `panic = "abort"` release profile, the panic Box uses for OOM
/// becomes an abort).  Callers can safely treat the returned
/// pointer as non-null.
#[no_mangle]
#[allow(unsafe_code)]
pub extern "C" fn knomosis_hash_keccak256_init() -> *mut c_void {
    let ctx = Box::new(Keccak256::new());
    // `Box::into_raw` returns a `*mut Keccak256`.  Cast to
    // `*mut c_void` for the opaque-pointer convention; the
    // pointer round-trips back via the same cast in `_finalize`.
    Box::into_raw(ctx).cast()
}

/// Feed one byte to a streaming context.  Idempotent on the
/// context's address; the byte is incorporated into the hash
/// state.
///
/// # Safety
///
///   * `ctx` must be a pointer returned by
///     [`knomosis_hash_keccak256_init`] and not yet passed to
///     [`knomosis_hash_keccak256_finalize`].
///   * `ctx` must not be null.  (Defence-in-depth: a null `ctx` is
///     ignored — a no-op — rather than dereferenced; a dangling
///     non-null `ctx` remains undefined behaviour.)
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_keccak256_update_byte(ctx: *mut c_void, byte: u8) {
    if ctx.is_null() {
        return;
    }
    let hasher: &mut Keccak256 = &mut *ctx.cast::<Keccak256>();
    hasher.update([byte]);
}

/// Feed many bytes to a streaming context.  Equivalent to a
/// sequence of [`knomosis_hash_keccak256_update_byte`] calls but
/// avoids the per-byte virtual-call overhead.
///
/// # Safety
///
///   * `ctx` must be a pointer returned by
///     [`knomosis_hash_keccak256_init`] and not yet finalised.
///   * `in_ptr` must point to `in_len` initialised bytes (or
///     `in_len == 0` with a dangling pointer).
///
/// Defence-in-depth: a null `ctx`, a null `in_ptr` with
/// `in_len > 0`, or an `in_len` exceeding `isize::MAX` is ignored —
/// the hash state is left unchanged rather than dereferencing.  A
/// dangling non-null pointer remains undefined behaviour.
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_keccak256_update_bulk(
    ctx: *mut c_void,
    in_ptr: *const u8,
    in_len: usize,
) {
    if ctx.is_null() || (in_len > 0 && in_ptr.is_null()) || in_len > MAX_SLICE_LEN {
        return;
    }
    let hasher: &mut Keccak256 = &mut *ctx.cast::<Keccak256>();
    let input = if in_len == 0 {
        &[][..]
    } else {
        core::slice::from_raw_parts(in_ptr, in_len)
    };
    hasher.update(input);
}

/// Finalise a streaming context: write the 32-byte digest to
/// `out_ptr` and free the context.
///
/// # Safety
///
///   * `ctx` must be a pointer returned by
///     [`knomosis_hash_keccak256_init`] and not yet finalised.
///   * `out_ptr` must point to 32 initialised bytes of writeable
///     memory.
///   * The context is FREED by this call; the caller must NOT
///     use `ctx` afterwards.
///
/// Defence-in-depth: a null `ctx` zero-fills `out_ptr` (when
/// writable) instead of dereferencing — the deterministic "poison"
/// digest of [`knomosis_hash_keccak256_bytes_raw`]; a null `out_ptr`
/// still frees the context (no leak) and discards the digest.  A
/// dangling non-null pointer remains undefined behaviour.
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_keccak256_finalize(ctx: *mut c_void, out_ptr: *mut u8) {
    if ctx.is_null() {
        if !out_ptr.is_null() {
            core::ptr::write_bytes(out_ptr, 0, DIGEST_LEN);
        }
        return;
    }
    // Reclaim ownership and consume (frees the context even when
    // `out_ptr` is null, so a contract-violating caller leaks
    // nothing).
    let hasher: Box<Keccak256> = Box::from_raw(ctx.cast::<Keccak256>());
    if out_ptr.is_null() {
        return;
    }
    let digest = hasher.finalize();
    core::ptr::copy_nonoverlapping(digest.as_ptr(), out_ptr, DIGEST_LEN);
}

// ============================================================
// Lean ABI entry points
// ============================================================
//
// The three Lean `@[extern]` swap-points
// (`knomosis_hash_bytes`, `knomosis_hash_stream`,
// `knomosis_hash_identifier`) materialise here as
// `#[no_mangle] extern "C"` Rust functions.  Each calls into
// the C shim's `knomosis_lean_*` non-inline wrappers to access
// Lean runtime helpers that are otherwise `static inline` in
// `lean.h` (see `c/lean_shim.c` for the wrapper rationale).
//
// Gating: this code only compiles when `build.rs` has located
// `lean.h` and the C shim has been built (cfg `knomosis_lean_ffi`).

/// Identifier returned by `knomosis_hash_identifier`.  Must match
/// the [`crate::IDENTIFIER`] constant byte-for-byte.
#[cfg(knomosis_lean_ffi)]
const IDENTIFIER_BYTES: &[u8] = b"keccak256/EVM-compatible/v1";

#[cfg(knomosis_lean_ffi)]
#[allow(unsafe_code)]
extern "C" {
    /// Non-inline wrapper around `lean_sarray_size`.
    fn knomosis_lean_sarray_size(o: *const u8) -> usize;
    /// Non-inline wrapper around `lean_sarray_cptr`.
    fn knomosis_lean_sarray_cptr(o: *const u8) -> *const u8;
    /// Non-inline wrapper around `lean_alloc_sarray(1, size, capacity)`.
    fn knomosis_lean_alloc_byte_array(size: usize, capacity: usize) -> *mut u8;
    /// Non-inline wrapper around `lean_dec`.
    fn knomosis_lean_dec(o: *const u8);
    /// Non-inline wrapper around `lean_inc`.
    fn knomosis_lean_inc(o: *const u8);
    /// Non-inline wrapper around `lean_obj_tag`.
    fn knomosis_lean_obj_tag(o: *const u8) -> u32;
    /// Non-inline wrapper around `lean_ctor_get`.
    fn knomosis_lean_ctor_get(o: *const u8, i: u32) -> *const u8;
    /// Non-inline wrapper around `lean_unbox`.
    fn knomosis_lean_unbox(o: *const u8) -> usize;
    /// Non-inline wrapper around `lean_mk_string_from_bytes`.
    fn knomosis_lean_mk_string_from_bytes(s: *const u8, sz: usize) -> *mut u8;
}

/// `knomosis_hash_bytes(bs : ByteArray) -> ByteArray` — Lean ABI
/// entry point for one-shot Keccak-256 hashing of a Lean
/// `ByteArray`.
///
/// # Safety
///
/// `bs` must be a valid owned `lean_object *` of Lean type
/// `ByteArray`.  This function reads its byte payload, hashes
/// it, allocates a new 32-byte Lean `ByteArray` for the output,
/// and decrements the input's reference count.  Returns an
/// owned `lean_object *` the caller releases.
#[cfg(knomosis_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_bytes(bs: *const u8) -> *mut u8 {
    let in_len = knomosis_lean_sarray_size(bs);
    let in_ptr = knomosis_lean_sarray_cptr(bs);

    let out = knomosis_lean_alloc_byte_array(32, 32);
    let out_ptr = knomosis_lean_sarray_cptr(out.cast_const());

    knomosis_hash_keccak256_bytes_raw(in_ptr, in_len, out_ptr.cast_mut());

    knomosis_lean_dec(bs);
    out
}

/// `knomosis_hash_stream(bs : List UInt8) -> ByteArray` — Lean ABI
/// entry point for streaming Keccak-256 hashing of a Lean `List
/// UInt8`.
///
/// Walks the cons-list one byte at a time, feeding each byte to
/// a streaming Keccak-256 context.  Lean's `List α` is a
/// regular inductive type:
///   * `nil` → represented as `lean_box(0)` (scalar, tag 0).
///   * `cons head tail` → ctor with tag 1, field 0 = head,
///     field 1 = tail.
///
/// For `List UInt8`, the head is a boxed `UInt8` (scalar via
/// `lean_box(byte)`); we extract via `lean_unbox` and truncate
/// to `u8`.
///
/// # Safety
///
/// `bs` must be a valid owned `lean_object *` of Lean type
/// `List UInt8`.  This function consumes ownership of the
/// entire chain via the per-step `inc(tail); dec(current)`
/// pattern documented in the body.
#[cfg(knomosis_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_stream(bs: *const u8) -> *mut u8 {
    let ctx = knomosis_hash_keccak256_init();

    let mut current = bs;
    while knomosis_lean_obj_tag(current) == 1 {
        let head = knomosis_lean_ctor_get(current, 0);
        let tail = knomosis_lean_ctor_get(current, 1);

        let byte =
            u8::try_from(knomosis_lean_unbox(head) & 0xff).expect("masked unbox always fits in u8");
        knomosis_hash_keccak256_update_byte(ctx, byte);

        // Take a reference to the tail before releasing the
        // parent cons.  `lean_inc` / `lean_dec` are no-ops for
        // scalar boxes (including the `nil` tail at the end of
        // the list), so the loop terminates safely.
        knomosis_lean_inc(tail);
        knomosis_lean_dec(current);
        current = tail;
    }
    // `current` is now the final `nil` (a scalar box).
    // `knomosis_lean_dec` is a no-op for scalars.
    knomosis_lean_dec(current);

    let out = knomosis_lean_alloc_byte_array(32, 32);
    let out_ptr = knomosis_lean_sarray_cptr(out.cast_const());
    knomosis_hash_keccak256_finalize(ctx, out_ptr.cast_mut());
    out
}

/// `knomosis_hash_identifier(u : Unit) -> String` — Lean ABI entry
/// point that returns this adaptor's implementation identifier
/// string.
///
/// The Unit argument is a scalar (`lean_box(0)`); the
/// `knomosis_lean_dec` call is a no-op for scalars but kept for
/// uniformity with the other entry points.
///
/// # Safety
///
/// `u` must be a valid Lean `lean_object *`.  In practice this
/// is always `lean_box(0)` for the Unit case.
#[cfg(knomosis_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_hash_identifier(u: *const u8) -> *mut u8 {
    knomosis_lean_dec(u);
    knomosis_lean_mk_string_from_bytes(IDENTIFIER_BYTES.as_ptr(), IDENTIFIER_BYTES.len())
}

#[cfg(test)]
#[allow(unsafe_code)]
mod tests {
    use super::{
        keccak256, knomosis_hash_keccak256_bytes_raw, knomosis_hash_keccak256_finalize,
        knomosis_hash_keccak256_init, knomosis_hash_keccak256_update_bulk,
        knomosis_hash_keccak256_update_byte, DIGEST_LEN,
    };

    /// keccak256("") == c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    ///
    /// Provenance: Ethereum Yellow Paper, eq. (29).
    #[test]
    fn empty_input_canonical() {
        let h = keccak256(b"");
        let expected: [u8; 32] = [
            0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7,
            0x03, 0xc0, 0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04,
            0x5d, 0x85, 0xa4, 0x70,
        ];
        assert_eq!(h, expected);
    }

    /// keccak256("abc") == 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
    #[test]
    fn abc_canonical() {
        let h = keccak256(b"abc");
        let expected: [u8; 32] = [
            0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f, 0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8,
            0xd6, 0x67, 0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36, 0xec, 0x44, 0xf5, 0x8f,
            0xa1, 0x2d, 0x6c, 0x45,
        ];
        assert_eq!(h, expected);
    }

    /// Output length is always 32.
    #[test]
    fn digest_len_constant() {
        assert_eq!(DIGEST_LEN, 32);
        assert_eq!(keccak256(b"").len(), 32);
        assert_eq!(keccak256(&[0u8; 1024]).len(), 32);
        assert_eq!(keccak256(&[0xffu8; 10_000]).len(), 32);
    }

    /// `knomosis_hash_keccak256_bytes_raw` produces the same digest
    /// as the safe `keccak256` function.
    #[test]
    fn raw_matches_safe() {
        let inputs: &[&[u8]] = &[
            b"",
            b"a",
            b"abc",
            b"the quick brown fox jumps over the lazy dog",
            &[0xff; 256],
            &[0u8; 1024],
        ];
        for input in inputs {
            let safe = keccak256(input);
            let mut raw = [0u8; 32];
            // SAFETY: `safe`'s pointer is valid for `input.len()`
            // and `raw` is a 32-byte stack buffer.  Both regions
            // are properly sized and disjoint from each other.
            unsafe {
                knomosis_hash_keccak256_bytes_raw(input.as_ptr(), input.len(), raw.as_mut_ptr());
            }
            assert_eq!(safe, raw, "raw output differs for input {input:?}");
        }
    }

    /// Streaming context produces the same digest as one-shot.
    #[test]
    fn streaming_matches_oneshot_byte_by_byte() {
        let input = b"the quick brown fox jumps over the lazy dog";
        let one_shot = keccak256(input);

        let ctx = knomosis_hash_keccak256_init();
        for &b in input {
            // SAFETY: ctx was just returned by init() and not finalised.
            unsafe {
                knomosis_hash_keccak256_update_byte(ctx, b);
            }
        }
        let mut streamed = [0u8; 32];
        // SAFETY: ctx is live; output buffer is 32 bytes.
        unsafe {
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Bulk update produces the same digest as one-shot.
    #[test]
    fn streaming_bulk_matches_oneshot() {
        let input = &[0xab; 1024];
        let one_shot = keccak256(input);

        let ctx = knomosis_hash_keccak256_init();
        // SAFETY: ctx is live; input buffer is initialised.
        unsafe {
            knomosis_hash_keccak256_update_bulk(ctx, input.as_ptr(), input.len());
        }
        let mut streamed = [0u8; 32];
        // SAFETY: ctx is live; output buffer is 32 bytes.
        unsafe {
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Mixed byte + bulk updates produce the same digest as bulk
    /// over the concatenation.
    #[test]
    fn mixed_streaming_matches_concatenated() {
        let chunk1: &[u8] = b"hello, ";
        let chunk2: &[u8] = b"world";

        // One-shot over the concatenation.
        let mut concat = Vec::new();
        concat.extend_from_slice(chunk1);
        concat.extend_from_slice(chunk2);
        let one_shot = keccak256(&concat);

        // Streaming: chunk1 via bulk, chunk2 via per-byte.
        let ctx = knomosis_hash_keccak256_init();
        unsafe {
            knomosis_hash_keccak256_update_bulk(ctx, chunk1.as_ptr(), chunk1.len());
        }
        for &b in chunk2 {
            unsafe {
                knomosis_hash_keccak256_update_byte(ctx, b);
            }
        }
        let mut streamed = [0u8; 32];
        unsafe {
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Empty stream (init → finalize with no updates) produces
    /// the empty-string digest.
    #[test]
    fn empty_stream_matches_empty_oneshot() {
        let one_shot = keccak256(b"");

        let ctx = knomosis_hash_keccak256_init();
        let mut streamed = [0u8; 32];
        unsafe {
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Streaming with an empty bulk update is a no-op.
    #[test]
    fn empty_bulk_update_is_noop() {
        let one_shot = keccak256(b"abc");

        let ctx = knomosis_hash_keccak256_init();
        unsafe {
            // Empty bulk before any data.
            knomosis_hash_keccak256_update_bulk(ctx, std::ptr::null(), 0);
            knomosis_hash_keccak256_update_bulk(ctx, b"abc".as_ptr(), 3);
            // Empty bulk after data.
            knomosis_hash_keccak256_update_bulk(ctx, std::ptr::null(), 0);
        }
        let mut streamed = [0u8; 32];
        unsafe {
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Deterministic: hashing the same input twice produces the
    /// same digest.
    #[test]
    fn deterministic() {
        for size in [0, 1, 31, 32, 33, 1024, 10_000] {
            let input: Vec<u8> = (0..size)
                .map(|i| u8::try_from(i & 0xff).unwrap_or(0))
                .collect();
            let h1 = keccak256(&input);
            let h2 = keccak256(&input);
            assert_eq!(h1, h2, "non-deterministic at size {size}");
        }
    }

    /// Defence-in-depth: a null `out_ptr` makes the one-shot raw
    /// entry point a no-op instead of undefined behaviour.
    #[test]
    fn raw_null_out_ptr_is_a_no_op() {
        unsafe {
            knomosis_hash_keccak256_bytes_raw(b"abc".as_ptr(), 3, std::ptr::null_mut());
        }
    }

    /// Defence-in-depth: a null `in_ptr` with `in_len > 0` (a caller
    /// contract violation) zero-fills the output — the deterministic
    /// poison digest — instead of dereferencing.
    #[test]
    fn raw_null_input_zero_fills_out() {
        let mut out = [0xffu8; DIGEST_LEN];
        unsafe {
            knomosis_hash_keccak256_bytes_raw(std::ptr::null(), 5, out.as_mut_ptr());
        }
        assert_eq!(out, [0u8; DIGEST_LEN]);
    }

    /// Defence-in-depth: an `in_len` above `isize::MAX` (the
    /// `from_raw_parts` bound) zero-fills the output without
    /// dereferencing the (valid, small) input pointer.
    #[test]
    fn raw_oversize_len_zero_fills_out() {
        let input = [0u8; 4];
        let mut out = [0xffu8; DIGEST_LEN];
        unsafe {
            knomosis_hash_keccak256_bytes_raw(input.as_ptr(), usize::MAX, out.as_mut_ptr());
        }
        assert_eq!(out, [0u8; DIGEST_LEN]);
    }

    /// Defence-in-depth: streaming calls on a null context are
    /// no-ops, and finalising a null context poisons the output.
    #[test]
    fn streaming_null_ctx_calls_are_no_ops() {
        let mut out = [0xffu8; DIGEST_LEN];
        unsafe {
            knomosis_hash_keccak256_update_byte(std::ptr::null_mut(), 0xaa);
            knomosis_hash_keccak256_update_bulk(std::ptr::null_mut(), b"abc".as_ptr(), 3);
            knomosis_hash_keccak256_finalize(std::ptr::null_mut(), out.as_mut_ptr());
        }
        assert_eq!(out, [0u8; DIGEST_LEN]);
    }

    /// Defence-in-depth: a null-input bulk update with `in_len > 0`
    /// leaves the hash state UNCHANGED (deterministic), so the
    /// surrounding stream still matches the one-shot digest of the
    /// bytes that were actually delivered.
    #[test]
    fn streaming_null_input_bulk_leaves_state_unchanged() {
        let one_shot = keccak256(b"abc");
        let ctx = knomosis_hash_keccak256_init();
        let mut streamed = [0u8; DIGEST_LEN];
        unsafe {
            knomosis_hash_keccak256_update_bulk(ctx, b"ab".as_ptr(), 2);
            knomosis_hash_keccak256_update_bulk(ctx, std::ptr::null(), 3);
            knomosis_hash_keccak256_update_byte(ctx, b'c');
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Defence-in-depth: finalising into a null `out_ptr` still
    /// consumes (frees) the context without crashing; the digest is
    /// discarded.
    #[test]
    fn finalize_null_out_still_frees_ctx() {
        let ctx = knomosis_hash_keccak256_init();
        unsafe {
            knomosis_hash_keccak256_update_byte(ctx, 0x01);
            knomosis_hash_keccak256_finalize(ctx, std::ptr::null_mut());
        }
    }
}
