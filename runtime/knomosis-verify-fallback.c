/*
 * Knomosis — A Societal Kernel
 * Copyright (C) 2026  Adam Hall
 * This program comes with ABSOLUTELY NO WARRANTY.
 * This is free software, and you are welcome to redistribute it under
 * certain conditions.  See:
 *   https://github.com/hatter6822/Knomosis/blob/main/LICENSE
 *
 * runtime/knomosis-verify-fallback.c
 *
 * Security-review F-2 — default fallback binding for the
 * `knomosis_verify_identifier` C-ABI symbol (the @[extern] backing
 * `LegalKernel.Bridge.verifyImplementationIdentifier`).  The forwarder
 * delegates back to the matching Lean fallback function compiled by
 * `Bridge/VerifyAdaptor.lean`, which returns the fallback identifier
 * `"lean-opaque-fallback"`.
 *
 * This lives in its OWN archive, separate from the hash-adaptor
 * fallback (`knomosis-hash-fallback.c`), so the verify symbol group is
 * a SINGLE-archive swap independent of the hash symbol group.  A
 * production deployment links a real secp256k1 adaptor staticlib
 * (`knomosis-verify-secp256k1`, which exports a real
 * `knomosis_verify_identifier` returning the production identifier)
 * IN PLACE OF this fallback archive — the lakefile `extern_lib
 * knomosisVerifyFallback` performs the swap when
 * `KNOMOSIS_VERIFY_STATICLIB` is set.  Because each symbol group has
 * exactly one defining archive, there is never a duplicate-symbol
 * clash even when BOTH a production hash adaptor and a production
 * verify adaptor are linked.
 *
 * `knomosis verify-check` (the F-2 deploy gate) reads this identifier:
 * it exits 1 on the fallback `"lean-opaque-fallback"` and 0 once a
 * production verifier is linked.
 *
 * Reference-counting discipline.  Identical to the hash forwarders:
 * the @[extern] wrapper for `verifyImplementationIdentifier` transfers
 * its owned `Unit` argument to this forwarder with NO post-call
 * `lean_dec_ref`, and the Lean Fallback consumes the `Unit`'s box (an
 * rc-irrelevant `box(0)`) while returning an owned String constant.  A
 * direct pass-through therefore preserves owned-transfer semantics
 * exactly; adding a `lean_dec_ref` after the call would be a
 * use-after-free.
 */

#include <lean/lean.h>

/* Forward declaration of the Lean-generated Fallback function.  Takes
 * one owned `lean_object*` (`Unit`, consumed by the body) and returns
 * an owned `String`, matching the `@[extern]` calling convention this
 * forwarder stands in for. */
extern LEAN_EXPORT lean_object *
    lp_knomosis_LegalKernel_Bridge_verifyImplementationIdentifierFallback(
        lean_object *u);

/* knomosis_verify_identifier(u) — default forwarder.  Returns the Lean
 * fallback identifier `"lean-opaque-fallback"`; production deployments
 * override by swapping in the knomosis-verify-secp256k1 staticlib. */
LEAN_EXPORT lean_object *knomosis_verify_identifier(lean_object *u) {
    return lp_knomosis_LegalKernel_Bridge_verifyImplementationIdentifierFallback(u);
}
