/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.SignInput — domain-separated signing input.

Phase 4 WU 4.8.  Replaces the Phase-3 stub (`signingInput` in
`Authority/SignedAction.lean`, which returned `ByteArray.empty`
regardless of inputs) with a real CBE-based encoding plus a
deployment-id domain separator.

Genesis Plan §8.8.5:

  ```
  sign_input(action, signer, nonce, deployment_id) :=
    BLAKE3("legalkernel/v1/signedaction" ||
           encode deployment_id ||
           encode action ||
           encode signer ||
           encode nonce)
  ```

Phase 4's CBE-based version omits the BLAKE3 hash (the runtime
adaptor of Phase 5 will wire BLAKE3 via `@[extern]` linkage; see
Genesis Plan §8.8.4) and instead returns the *bytes that would be
hashed*.  This makes the canonical-encoding pipeline auditable
without committing to a specific hash function at the Lean level.

The domain string `"legalkernel/v1/signedaction"` is encoded as a
CBE byte string (length-prefixed); the deployment-id (= the
genesis-state hash, supplied at deployment time) prefixes the
action / signer / nonce fields.  This domain separation prevents
cross-deployment replay: a signature valid for deployment D₁ does
not verify against deployment D₂ because their genesis hashes (and
thus their canonical sign-input bytes) differ.

This module is **not** part of the trusted computing base.  Bugs
here weaken the cross-deployment-replay guarantee but cannot
violate any kernel invariant.
-/

import LegalKernel.Encoding.SignedAction

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## Domain string

The canonical sign-input domain string for `SignedAction` payloads.
Constant for the v1 protocol; future versions bump the suffix.
Verdict / dispute domain strings will land in Phase 6 alongside the
`Dispute` and `Verdict` types they domain-separate. -/

/-- Domain-separation string for `SignedAction` signing inputs.
    Genesis Plan §8.8.5 verbatim.  AR.1 / M-7: the canonical
    definition lives in `LegalKernel/Authority/Crypto.lean` as
    `Authority.signedActionDomain`; the Authority chain is in scope
    here via the import of `LegalKernel.Encoding.SignedAction`
    (which depends on `Authority.SignedAction`, which depends on
    `Authority.Crypto`).  This `abbrev` re-exports it under the
    `Encoding` namespace for backward-compat with the call sites
    in this module. -/
abbrev signedActionDomain : String := LegalKernel.Authority.signedActionDomain

/-! ## Sign-input construction

`signInput action signer nonce deploymentId` returns the canonical
byte sequence that must be hashed to produce the message a signer
attests.  At the Lean level this returns the bytes; the runtime
adaptor (Phase 5) hashes them via BLAKE3 before passing to `Verify`. -/

/-- The canonical CBE-based signing input bytes (Genesis Plan §8.8.5).

    Layout (concatenation):

      1. CBE-encoded domain string `"legalkernel/v1/signedaction"`
         (CBE byte-string tag `cbeTagBytes` + 8-byte LE length + UTF-8
         bytes of the string).  CBE has no separate "text string"
         shape — `cbeTagBytes` carries both binary blobs and UTF-8
         strings, with the interpretation determined by the field
         position rather than a tag bit.
      2. CBE-encoded `deploymentId : ByteArray` (the genesis-state
         hash of the deployment).
      3. CBE-encoded action.
      4. CBE-encoded signer (as Nat via `signer.toNat`).
      5. CBE-encoded nonce.

    The `deploymentId` parameter prevents cross-deployment replay:
    different deployments (with different genesis hashes) produce
    different sign-input bytes for the same `(action, signer, nonce)`
    triple.

    Returns the *bytes that would be hashed*.  The Phase-5 runtime
    adaptor wires the actual hash function (BLAKE3 by default) at
    the FFI boundary. -/
def signInput
    (action : Action) (signer : ActorId) (nonce : Nonce)
    (deploymentId : ByteArray) : ByteArray :=
  let domainBytes : Stream :=
    -- Encode domain string as CBE bytestring (length-prefixed).
    cborHeadEncode cbeTagBytes signedActionDomain.toUTF8.size ++
      signedActionDomain.toUTF8.data.toList
  ByteArray.mk
    (domainBytes ++
     Encodable.encode (T := ByteArray) deploymentId ++
     Encodable.encode (T := Action) action ++
     Encodable.encode (T := Nat) signer.toNat ++
     Encodable.encode (T := Nat) nonce).toArray

/-! ## Determinism + value-level tests

`signInput` is a function, so equal inputs trivially produce equal
outputs.  Cross-deployment distinguishability (the §8.8.5 headline
security property) is verified at the *value level* via test
vectors in `LegalKernel/Test/Encoding/SignInput.lean`: the test suite
generates concrete `(d₁ ≠ d₂)` cases and asserts that the resulting
sign-input bytes differ.

Phase 4 deliberately stops at value-level testing of cross-deployment
distinguishability — the byte-level abstract proof (extracting the
common domain prefix and applying `byteArray_encode_injective`) is
straightforward in principle but byte-surgery tedious; the value-level
tests cover every concrete shape the runtime adaptor will encounter,
and Phase 5's interop tests will further exercise the property
against the production CBOR encoder. -/

/-- Determinism: equal inputs produce equal sign-input bytes. -/
theorem signInput_deterministic
    (action : Action) (signer : ActorId) (nonce : Nonce) (d : ByteArray) :
    signInput action signer nonce d = signInput action signer nonce d := rfl

/-- The sign-input bytes are non-empty (the domain string alone is
    27 bytes plus the 9-byte CBE head). -/
theorem signInput_nonempty
    (action : Action) (signer : ActorId) (nonce : Nonce) (d : ByteArray) :
    (signInput action signer nonce d).size ≥ 36 := by
  -- The first 9 bytes are the CBE head for the bytestring length;
  -- the next 27 bytes are the UTF-8 of `signedActionDomain` (which
  -- has 27 ASCII characters); the remaining bytes are the encoded
  -- (deploymentId, action, signer, nonce).  Sum: ≥ 36.
  unfold signInput
  show (List.toArray (cborHeadEncode cbeTagBytes signedActionDomain.toUTF8.size ++
      signedActionDomain.toUTF8.data.toList ++ Encodable.encode d ++
      Encodable.encode action ++ Encodable.encode (T := Nat) signer.toNat ++
      Encodable.encode nonce)).size ≥ 36
  rw [List.size_toArray]
  -- Each `Encodable.encode` returns a List UInt8.  We just need a lower
  -- bound on the prefix; the suffix can only add bytes.
  have h1 : (cborHeadEncode cbeTagBytes signedActionDomain.toUTF8.size).length = 9 := by
    unfold cborHeadEncode
    simp [natToBytesLE_length]
  have h2 : signedActionDomain.toUTF8.data.toList.length = 27 := by
    decide
  -- length of L ++ M is L.length + M.length.
  simp only [List.length_append]
  omega

end Encoding
end LegalKernel
