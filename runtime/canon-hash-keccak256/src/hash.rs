// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

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
//!   * [`canon_hash_keccak256_bytes_raw`] — one-shot hash of a
//!     byte slice.  Used for `canon_hash_bytes`.
//!   * [`canon_hash_keccak256_init`] — allocate a streaming
//!     context; returns an opaque `*mut c_void`.
//!   * [`canon_hash_keccak256_update_byte`] — feed one byte to
//!     a context.  Used for `canon_hash_stream` (which walks a
//!     Lean `List UInt8` one cons cell at a time).
//!   * [`canon_hash_keccak256_update_bulk`] — feed many bytes to
//!     a context.  Not currently used by the shim but provided
//!     for future expansion (e.g. a ByteArray-streamed path).
//!   * [`canon_hash_keccak256_finalize`] — emit the 32-byte
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
/// Never panics in well-typed inputs.  The workspace's release
/// profile sets `panic = "abort"` as a defence-in-depth measure
/// against unwinding into Lean's runtime.
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_keccak256_bytes_raw(
    in_ptr: *const u8,
    in_len: usize,
    out_ptr: *mut u8,
) {
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
/// pointer the caller passes to [`canon_hash_keccak256_update_byte`],
/// [`canon_hash_keccak256_update_bulk`], and
/// [`canon_hash_keccak256_finalize`].
///
/// The context is heap-allocated via `Box::into_raw`; ownership is
/// transferred to the caller, who MUST call
/// `canon_hash_keccak256_finalize` to release it.  `_finalize`
/// reads the digest and frees the context in one step.
///
/// This function never returns a null pointer: `Box::new` aborts
/// the process on allocator failure (under the workspace's
/// `panic = "abort"` release profile, the panic Box uses for OOM
/// becomes an abort).  Callers can safely treat the returned
/// pointer as non-null.
#[no_mangle]
#[allow(unsafe_code)]
pub extern "C" fn canon_hash_keccak256_init() -> *mut c_void {
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
///     [`canon_hash_keccak256_init`] and not yet passed to
///     [`canon_hash_keccak256_finalize`].
///   * `ctx` must not be null.
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_keccak256_update_byte(ctx: *mut c_void, byte: u8) {
    let hasher: &mut Keccak256 = &mut *ctx.cast::<Keccak256>();
    hasher.update([byte]);
}

/// Feed many bytes to a streaming context.  Equivalent to a
/// sequence of [`canon_hash_keccak256_update_byte`] calls but
/// avoids the per-byte virtual-call overhead.
///
/// # Safety
///
///   * `ctx` must be a pointer returned by
///     [`canon_hash_keccak256_init`] and not yet finalised.
///   * `in_ptr` must point to `in_len` initialised bytes (or
///     `in_len == 0` with a dangling pointer).
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_keccak256_update_bulk(
    ctx: *mut c_void,
    in_ptr: *const u8,
    in_len: usize,
) {
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
///     [`canon_hash_keccak256_init`] and not yet finalised.
///   * `out_ptr` must point to 32 initialised bytes of writeable
///     memory.
///   * The context is FREED by this call; the caller must NOT
///     use `ctx` afterwards.
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_keccak256_finalize(ctx: *mut c_void, out_ptr: *mut u8) {
    // Reclaim ownership and consume.
    let hasher: Box<Keccak256> = Box::from_raw(ctx.cast::<Keccak256>());
    let digest = hasher.finalize();
    core::ptr::copy_nonoverlapping(digest.as_ptr(), out_ptr, DIGEST_LEN);
}

// ============================================================
// Lean ABI entry points
// ============================================================
//
// The three Lean `@[extern]` swap-points
// (`canon_hash_bytes`, `canon_hash_stream`,
// `canon_hash_identifier`) materialise here as
// `#[no_mangle] extern "C"` Rust functions.  Each calls into
// the C shim's `canon_lean_*` non-inline wrappers to access
// Lean runtime helpers that are otherwise `static inline` in
// `lean.h` (see `c/lean_shim.c` for the wrapper rationale).
//
// Gating: this code only compiles when `build.rs` has located
// `lean.h` and the C shim has been built (cfg `canon_lean_ffi`).

/// Identifier returned by `canon_hash_identifier`.  Must match
/// the [`crate::IDENTIFIER`] constant byte-for-byte.
#[cfg(canon_lean_ffi)]
const IDENTIFIER_BYTES: &[u8] = b"keccak256/EVM-compatible/v1";

#[cfg(canon_lean_ffi)]
#[allow(unsafe_code)]
extern "C" {
    /// Non-inline wrapper around `lean_sarray_size`.
    fn canon_lean_sarray_size(o: *const u8) -> usize;
    /// Non-inline wrapper around `lean_sarray_cptr`.
    fn canon_lean_sarray_cptr(o: *const u8) -> *const u8;
    /// Non-inline wrapper around `lean_alloc_sarray(1, size, capacity)`.
    fn canon_lean_alloc_byte_array(size: usize, capacity: usize) -> *mut u8;
    /// Non-inline wrapper around `lean_dec`.
    fn canon_lean_dec(o: *const u8);
    /// Non-inline wrapper around `lean_inc`.
    fn canon_lean_inc(o: *const u8);
    /// Non-inline wrapper around `lean_obj_tag`.
    fn canon_lean_obj_tag(o: *const u8) -> u32;
    /// Non-inline wrapper around `lean_ctor_get`.
    fn canon_lean_ctor_get(o: *const u8, i: u32) -> *const u8;
    /// Non-inline wrapper around `lean_unbox`.
    fn canon_lean_unbox(o: *const u8) -> usize;
    /// Non-inline wrapper around `lean_mk_string_from_bytes`.
    fn canon_lean_mk_string_from_bytes(s: *const u8, sz: usize) -> *mut u8;
}

/// `canon_hash_bytes(bs : ByteArray) -> ByteArray` — Lean ABI
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
#[cfg(canon_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_bytes(bs: *const u8) -> *mut u8 {
    let in_len = canon_lean_sarray_size(bs);
    let in_ptr = canon_lean_sarray_cptr(bs);

    let out = canon_lean_alloc_byte_array(32, 32);
    let out_ptr = canon_lean_sarray_cptr(out.cast_const());

    canon_hash_keccak256_bytes_raw(in_ptr, in_len, out_ptr.cast_mut());

    canon_lean_dec(bs);
    out
}

/// `canon_hash_stream(bs : List UInt8) -> ByteArray` — Lean ABI
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
#[cfg(canon_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_stream(bs: *const u8) -> *mut u8 {
    let ctx = canon_hash_keccak256_init();

    let mut current = bs;
    while canon_lean_obj_tag(current) == 1 {
        let head = canon_lean_ctor_get(current, 0);
        let tail = canon_lean_ctor_get(current, 1);

        let byte =
            u8::try_from(canon_lean_unbox(head) & 0xff).expect("masked unbox always fits in u8");
        canon_hash_keccak256_update_byte(ctx, byte);

        // Take a reference to the tail before releasing the
        // parent cons.  `lean_inc` / `lean_dec` are no-ops for
        // scalar boxes (including the `nil` tail at the end of
        // the list), so the loop terminates safely.
        canon_lean_inc(tail);
        canon_lean_dec(current);
        current = tail;
    }
    // `current` is now the final `nil` (a scalar box).
    // `canon_lean_dec` is a no-op for scalars.
    canon_lean_dec(current);

    let out = canon_lean_alloc_byte_array(32, 32);
    let out_ptr = canon_lean_sarray_cptr(out.cast_const());
    canon_hash_keccak256_finalize(ctx, out_ptr.cast_mut());
    out
}

/// `canon_hash_identifier(u : Unit) -> String` — Lean ABI entry
/// point that returns this adaptor's implementation identifier
/// string.
///
/// The Unit argument is a scalar (`lean_box(0)`); the
/// `canon_lean_dec` call is a no-op for scalars but kept for
/// uniformity with the other entry points.
///
/// # Safety
///
/// `u` must be a valid Lean `lean_object *`.  In practice this
/// is always `lean_box(0)` for the Unit case.
#[cfg(canon_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn canon_hash_identifier(u: *const u8) -> *mut u8 {
    canon_lean_dec(u);
    canon_lean_mk_string_from_bytes(IDENTIFIER_BYTES.as_ptr(), IDENTIFIER_BYTES.len())
}

#[cfg(test)]
#[allow(unsafe_code)]
mod tests {
    use super::{
        canon_hash_keccak256_bytes_raw, canon_hash_keccak256_finalize, canon_hash_keccak256_init,
        canon_hash_keccak256_update_bulk, canon_hash_keccak256_update_byte, keccak256, DIGEST_LEN,
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

    /// `canon_hash_keccak256_bytes_raw` produces the same digest
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
                canon_hash_keccak256_bytes_raw(input.as_ptr(), input.len(), raw.as_mut_ptr());
            }
            assert_eq!(safe, raw, "raw output differs for input {input:?}");
        }
    }

    /// Streaming context produces the same digest as one-shot.
    #[test]
    fn streaming_matches_oneshot_byte_by_byte() {
        let input = b"the quick brown fox jumps over the lazy dog";
        let one_shot = keccak256(input);

        let ctx = canon_hash_keccak256_init();
        for &b in input {
            // SAFETY: ctx was just returned by init() and not finalised.
            unsafe {
                canon_hash_keccak256_update_byte(ctx, b);
            }
        }
        let mut streamed = [0u8; 32];
        // SAFETY: ctx is live; output buffer is 32 bytes.
        unsafe {
            canon_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Bulk update produces the same digest as one-shot.
    #[test]
    fn streaming_bulk_matches_oneshot() {
        let input = &[0xab; 1024];
        let one_shot = keccak256(input);

        let ctx = canon_hash_keccak256_init();
        // SAFETY: ctx is live; input buffer is initialised.
        unsafe {
            canon_hash_keccak256_update_bulk(ctx, input.as_ptr(), input.len());
        }
        let mut streamed = [0u8; 32];
        // SAFETY: ctx is live; output buffer is 32 bytes.
        unsafe {
            canon_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
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
        let ctx = canon_hash_keccak256_init();
        unsafe {
            canon_hash_keccak256_update_bulk(ctx, chunk1.as_ptr(), chunk1.len());
        }
        for &b in chunk2 {
            unsafe {
                canon_hash_keccak256_update_byte(ctx, b);
            }
        }
        let mut streamed = [0u8; 32];
        unsafe {
            canon_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Empty stream (init → finalize with no updates) produces
    /// the empty-string digest.
    #[test]
    fn empty_stream_matches_empty_oneshot() {
        let one_shot = keccak256(b"");

        let ctx = canon_hash_keccak256_init();
        let mut streamed = [0u8; 32];
        unsafe {
            canon_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        assert_eq!(one_shot, streamed);
    }

    /// Streaming with an empty bulk update is a no-op.
    #[test]
    fn empty_bulk_update_is_noop() {
        let one_shot = keccak256(b"abc");

        let ctx = canon_hash_keccak256_init();
        unsafe {
            // Empty bulk before any data.
            canon_hash_keccak256_update_bulk(ctx, std::ptr::null(), 0);
            canon_hash_keccak256_update_bulk(ctx, b"abc".as_ptr(), 3);
            // Empty bulk after data.
            canon_hash_keccak256_update_bulk(ctx, std::ptr::null(), 0);
        }
        let mut streamed = [0u8; 32];
        unsafe {
            canon_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
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
}
