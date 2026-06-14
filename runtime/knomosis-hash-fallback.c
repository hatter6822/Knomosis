/*
 * Knomosis — A Societal Kernel
 * Copyright (C) 2026  Adam Hall
 * This program comes with ABSOLUTELY NO WARRANTY.
 * This is free software, and you are welcome to redistribute it under
 * certain conditions.  See:
 *   https://github.com/hatter6822/Knomosis/blob/main/LICENSE
 *
 * runtime/knomosis-hash-fallback.c
 *
 * AR.10 — default fallback bindings for the three deployment-facing
 * hash adaptor C ABI symbols (`knomosis_hash_bytes`, `knomosis_hash_stream`,
 * `knomosis_hash_identifier`).  Each forwarder delegates back to the
 * matching Lean fallback function compiled by `Runtime/Hash.lean`.
 *
 * Production deployments override these forwarders by linking a real
 * implementation library (e.g. BLAKE3 or keccak256) AHEAD of this
 * object file in the link order; the linker resolves
 * `knomosis_hash_bytes` etc. to the production binding and the
 * `_Fallback` Lean function becomes dead code at runtime.
 *
 * Reference-counting discipline.  Inspecting the generated C output
 * (`.lake/build/ir/LegalKernel/Runtime/Hash.c`) shows two key
 * facts that make the direct pass-through correct:
 *
 *   1. The @[extern] wrapper for `hashBytes` is:
 *        x_2 = knomosis_hash_bytes(x_1);  return x_2;
 *      i.e. there is NO `lean_dec_ref(x_1)` after the call.  The
 *      caller's owned reference is transferred to knomosis_hash_bytes
 *      and the wrapper is no longer accountable for x_1.
 *
 *   2. The Lean fallback `lp_..._hashBytesFallback(x_1)` body is:
 *        x_2 = l_ByteArray_toList(x_1);   // CONSUMES x_1
 *        x_3 = fnv1a64Stream(x_2);  lean_dec(x_2);
 *        return x_3;
 *      i.e. the Fallback consumes x_1 transitively via
 *      `ByteArray.toList`.  Same applies to hashStreamFallback
 *      (consumes its `List UInt8` while folding) and to
 *      hashImplementationIdentifierFallback (which returns a closed
 *      constant — Unit's box(0) is rc-irrelevant).
 *
 * Combining (1) + (2): a direct pass-through preserves the
 * owned-transfer semantics exactly.  Adding `lean_dec_ref(bs)`
 * AFTER the Fallback call would be a use-after-free, because the
 * Fallback has already consumed the reference.
 */

#include <lean/lean.h>

/* Forward declarations of the Lean-generated Fallback functions.
 * Each takes one owned `lean_object*` argument (consumed
 * transitively by its body) and returns an owned result, exactly
 * matching the `@[extern]` calling convention these forwarders
 * stand in for. */
extern LEAN_EXPORT lean_object *
    lp_knomosis_LegalKernel_Runtime_hashBytesFallback(lean_object *bs);

extern LEAN_EXPORT lean_object *
    lp_knomosis_LegalKernel_Runtime_hashStreamFallback(lean_object *bs);

extern LEAN_EXPORT lean_object *
    lp_knomosis_LegalKernel_Runtime_hashImplementationIdentifierFallback(
        lean_object *u);

/* knomosis_hash_bytes(bs) — default forwarder.  Production deployments
 * override this with a BLAKE3-256 / keccak256 binding linked ahead of
 * this object file. */
LEAN_EXPORT lean_object *knomosis_hash_bytes(lean_object *bs) {
    return lp_knomosis_LegalKernel_Runtime_hashBytesFallback(bs);
}

/* knomosis_hash_stream(bs) — default forwarder.  `bs` is a `List UInt8`
 * value (boxed); the Lean fallback walks the list applying FNV-1a-64. */
LEAN_EXPORT lean_object *knomosis_hash_stream(lean_object *bs) {
    return lp_knomosis_LegalKernel_Runtime_hashStreamFallback(bs);
}

/* knomosis_hash_identifier(u) — default forwarder.  Always returns the
 * Lean fallback identifier `"fnv1a64-padded-32"`; production
 * deployments override with the linked implementation's identifier
 * (e.g. `"blake3-256"` or `"keccak256/EVM-compatible/v1"`). */
LEAN_EXPORT lean_object *knomosis_hash_identifier(lean_object *u) {
    return lp_knomosis_LegalKernel_Runtime_hashImplementationIdentifierFallback(u);
}

/* knomosis_verify_identifier(u) — default forwarder (security-review F-2).
 * Returns the Lean fallback identifier "lean-opaque-fallback"; production
 * deployments override this by linking the knomosis-verify-secp256k1
 * adaptor ahead of this object file (it provides a real
 * `knomosis_verify_identifier` returning the production identifier).
 * Same owned-transfer discipline as the hash forwarders above: the
 * Fallback consumes its `Unit` argument's box and returns an owned
 * String constant. */
extern LEAN_EXPORT lean_object *
    lp_knomosis_LegalKernel_Bridge_verifyImplementationIdentifierFallback(
        lean_object *u);

LEAN_EXPORT lean_object *knomosis_verify_identifier(lean_object *u) {
    return lp_knomosis_LegalKernel_Bridge_verifyImplementationIdentifierFallback(u);
}
