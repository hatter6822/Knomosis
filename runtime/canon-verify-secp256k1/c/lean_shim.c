/*
 * Canon — A Societal Kernel
 * Copyright (C) 2026  Adam Hall
 * This program comes with ABSOLUTELY NO WARRANTY.
 * This is free software, and you are welcome to redistribute it under
 * certain conditions.  See:
 *   https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
 *
 * runtime/canon-verify-secp256k1/c/lean_shim.c
 *
 * RH-A.1.b — Lean ABI bridge helpers for the secp256k1 verify
 * adaptor.
 *
 * ## Design rationale
 *
 * Lean's `lean.h` exposes most of its runtime API as `static
 * inline` C functions (e.g. `lean_sarray_size`,
 * `lean_sarray_cptr`).  These cannot be called directly from
 * Rust via `extern "C"` because they have no linker symbols.
 * This file ships small non-inline wrappers (`canon_lean_*`)
 * whose ONLY job is to forward to the underlying inlines so the
 * Rust side has a stable symbol surface to bind to.
 *
 * The actual Lean ABI entry point `canon_verify_ecdsa` is
 * defined in Rust (`src/verify.rs`) via `#[no_mangle] pub
 * unsafe extern "C" fn`.  Defining it on the Rust side rather
 * than in C is required because:
 *
 *   1. `rustc`'s cdylib export discipline uses a version script
 *      that hides every symbol not declared via Rust's
 *      `#[no_mangle] pub`.  C symbols defined in a linked
 *      static archive are visible inside the binary but get
 *      stripped from the dynamic-symbol table.
 *   2. Pinning the entry point to Rust gives us a single,
 *      consistent place for the input-validation discipline
 *      and the `unsafe` audit surface.
 *
 * ## Reference-counting discipline
 *
 * The wrappers below are pure forwards; they do NOT decrement
 * reference counts on their arguments (the caller is the
 * owner).  The Rust-side `canon_verify_ecdsa` decrements the
 * three `lean_object *` arguments after reading their data, per
 * the standard Lean `@[extern]` owned-transfer ABI.
 */

#include <lean/lean.h>
#include <stddef.h>
#include <stdint.h>

/* Wrapper: return the byte-length of a Lean ByteArray (sarray
 * with `elem_size == 1`).  Forwards to `lean_sarray_size` which
 * is `static inline` and therefore not directly callable from
 * Rust. */
LEAN_EXPORT size_t canon_lean_sarray_size(lean_object *o) {
    return lean_sarray_size(o);
}

/* Wrapper: return a pointer to the byte payload of a Lean
 * ByteArray.  Forwards to `lean_sarray_cptr`. */
LEAN_EXPORT uint8_t *canon_lean_sarray_cptr(lean_object *o) {
    return lean_sarray_cptr(o);
}

/* Wrapper: allocate a Lean sarray with `elem_size = 1` (a
 * ByteArray).  Returns an owned `lean_object *`. */
LEAN_EXPORT lean_object *canon_lean_alloc_byte_array(size_t size, size_t capacity) {
    return lean_alloc_sarray(1, size, capacity);
}

/* Wrapper: decrement a Lean object's reference count.  Forwards
 * to `lean_dec`, which is the safe-on-scalars variant (no-op
 * for scalar boxes like nil / unit). */
LEAN_EXPORT void canon_lean_dec(lean_object *o) {
    lean_dec(o);
}

/* Wrapper: increment a Lean object's reference count.  Forwards
 * to `lean_inc`. */
LEAN_EXPORT void canon_lean_inc(lean_object *o) {
    lean_inc(o);
}

/* Wrapper: get the tag of a Lean object.  Used by streaming
 * hashers walking a `List UInt8` (nil = 0, cons = 1). */
LEAN_EXPORT unsigned canon_lean_obj_tag(lean_object *o) {
    return lean_obj_tag(o);
}

/* Wrapper: read field `i` from a Lean constructor object.  Used
 * by streaming hashers to walk `cons` cells' head and tail
 * fields. */
LEAN_EXPORT lean_object *canon_lean_ctor_get(lean_object *o, unsigned i) {
    return lean_ctor_get(o, i);
}

/* Wrapper: unbox a Lean scalar object to a usize.  Used to
 * extract `UInt8` values from a `List UInt8`'s cons-head cells. */
LEAN_EXPORT size_t canon_lean_unbox(lean_object *o) {
    return lean_unbox(o);
}

/* Wrapper: create a Lean String from a (bytes, length) pair.
 * Forwards to the LEAN_EXPORT `lean_mk_string_from_bytes`. */
LEAN_EXPORT lean_object *canon_lean_mk_string_from_bytes(const char *s, size_t sz) {
    return lean_mk_string_from_bytes(s, sz);
}
