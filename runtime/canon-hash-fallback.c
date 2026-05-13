/*
 * Canon — A Societal Kernel
 * Copyright (C) 2026  Adam Hall
 * This program comes with ABSOLUTELY NO WARRANTY.
 * This is free software, and you are welcome to redistribute it under
 * certain conditions.  See:
 *   https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
 *
 * runtime/canon-hash-fallback.c
 *
 * AR.10 — default fallback bindings for the three deployment-facing
 * hash adaptor C ABI symbols (`canon_hash_bytes`, `canon_hash_stream`,
 * `canon_hash_identifier`).  Each forwarder delegates back to the
 * matching Lean fallback function compiled by `LegalKernel/Runtime/Hash.lean`
 * (which lives in the `LegalKernel.Runtime` namespace and is exported by
 * Lean's code generator under the mangled name
 * `lp_canon_LegalKernel_Runtime_<name>Fallback`).
 *
 * Production deployments override these forwarders by linking a real
 * implementation library (e.g. BLAKE3 or keccak256) AHEAD of this
 * object file in the link order; the linker resolves
 * `canon_hash_bytes` etc. to the production binding and the
 * `_Fallback` Lean function is dead code at runtime.
 *
 * The forwarders preserve Lean's reference-counting discipline: each
 * Lean fallback function uses the standard borrowed-reference
 * calling convention emitted for a `def` with no `@&` annotation
 * (the `___boxed` wrapper handles the rc bookkeeping for both the
 * @[extern] callsite and the fallback function), so a direct
 * pass-through is correct.
 */

#include <lean/lean.h>

/* Forward declarations of Lean-generated fallback functions.  Names
 * match the mangling Lean produces for `def hashBytesFallback`,
 * `def hashStreamFallback`, and `def hashImplementationIdentifierFallback`
 * inside the `LegalKernel.Runtime` namespace. */
extern LEAN_EXPORT lean_object *
    lp_canon_LegalKernel_Runtime_hashBytesFallback(lean_object *bs);

extern LEAN_EXPORT lean_object *
    lp_canon_LegalKernel_Runtime_hashStreamFallback(lean_object *bs);

extern LEAN_EXPORT lean_object *
    lp_canon_LegalKernel_Runtime_hashImplementationIdentifierFallback(
        lean_object *u);

/* canon_hash_bytes(bs) — default forwarder.  Production deployments
 * override this with a BLAKE3-256 / keccak256 binding linked ahead of
 * this object file. */
LEAN_EXPORT lean_object *canon_hash_bytes(lean_object *bs) {
    return lp_canon_LegalKernel_Runtime_hashBytesFallback(bs);
}

/* canon_hash_stream(bs) — default forwarder.  The `bs` parameter is
 * a `List UInt8` value; the Lean fallback walks the list and applies
 * FNV-1a-64. */
LEAN_EXPORT lean_object *canon_hash_stream(lean_object *bs) {
    return lp_canon_LegalKernel_Runtime_hashStreamFallback(bs);
}

/* canon_hash_identifier(u) — default forwarder.  Always returns the
 * Lean fallback identifier `"fnv1a64-padded-32"`; production
 * deployments override with the linked implementation's identifier
 * (e.g. `"blake3-256"` or `"keccak256/EVM-compatible/v1"`). */
LEAN_EXPORT lean_object *canon_hash_identifier(lean_object *u) {
    return lp_canon_LegalKernel_Runtime_hashImplementationIdentifierFallback(u);
}
