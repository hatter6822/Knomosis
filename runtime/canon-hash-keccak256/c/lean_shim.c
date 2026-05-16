/*
 * Canon — A Societal Kernel
 * Copyright (C) 2026  Adam Hall
 * This program comes with ABSOLUTELY NO WARRANTY.
 * This is free software, and you are welcome to redistribute it under
 * certain conditions.  See:
 *   https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
 *
 * runtime/canon-hash-keccak256/c/lean_shim.c
 *
 * RH-A.2 — Lean ABI bridge helpers for the keccak-256 hash adaptor.
 *
 * Same design as the ECDSA crate's `lean_shim.c`: non-inline
 * wrappers around `lean.h`'s `static inline` API so the Rust side
 * has a linker-visible symbol surface.  The Lean ABI entry points
 * (`canon_hash_bytes`, `canon_hash_stream`,
 * `canon_hash_identifier`) live in Rust (`src/hash.rs`) so
 * rustc's cdylib export discipline keeps them in the dynamic
 * symbol table.
 */

#include <lean/lean.h>
#include <stddef.h>
#include <stdint.h>

/* See `canon-verify-secp256k1/c/lean_shim.c` for the wrapper
 * rationale (each entry forwards to a `static inline` from
 * lean.h that cannot be called directly from Rust). */

LEAN_EXPORT size_t canon_lean_sarray_size(lean_object *o) {
    return lean_sarray_size(o);
}

LEAN_EXPORT uint8_t *canon_lean_sarray_cptr(lean_object *o) {
    return lean_sarray_cptr(o);
}

LEAN_EXPORT lean_object *canon_lean_alloc_byte_array(size_t size, size_t capacity) {
    return lean_alloc_sarray(1, size, capacity);
}

LEAN_EXPORT void canon_lean_dec(lean_object *o) {
    lean_dec(o);
}

LEAN_EXPORT void canon_lean_inc(lean_object *o) {
    lean_inc(o);
}

LEAN_EXPORT unsigned canon_lean_obj_tag(lean_object *o) {
    return lean_obj_tag(o);
}

LEAN_EXPORT lean_object *canon_lean_ctor_get(lean_object *o, unsigned i) {
    return lean_ctor_get(o, i);
}

LEAN_EXPORT size_t canon_lean_unbox(lean_object *o) {
    return lean_unbox(o);
}

LEAN_EXPORT lean_object *canon_lean_mk_string_from_bytes(const char *s, size_t sz) {
    return lean_mk_string_from_bytes(s, sz);
}
