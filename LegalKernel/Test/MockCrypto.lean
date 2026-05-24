/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.MockCrypto — deterministic test verifier for Audit-3.3.

Test-only `mockVerify` and `mockSign` functions that lift the
"happy-path admissibility" coverage gap.  The production
`Verify` opaque returns `false` at the Lean level (it is wired
to a real signature scheme via `@[extern]` only at runtime), so
without this module the entire admissibility happy-path can be
exercised only at the term level, never at the value level.

`mockVerify` accepts any 64-byte signature whose first byte is
`0xFF`; `mockSign` produces such a signature.  The test verifier
is structurally distinct from any real signature scheme (no real
Ed25519 / ECDSA / ML-DSA signature begins with `0xFF` for an
arbitrary message under an arbitrary key with non-trivial
probability), so test-only signatures cannot be confused with
production signatures by any shape check.

Usage in a test:

```lean
let pk : PublicKey := mockPubKey 10  -- some public key for actor 10
let sig : Signature := mockSign pk msg
-- Now mockVerify pk msg sig = true.
let h : AdmissibleWith mockVerify P d es st := ⟨...⟩
let es' := apply_admissible_with mockVerify P d es st h
```

This module is **test-only**.  It must NOT be imported from any
non-test module.  The `mock_import_audit` binary (AR.9 / M-10)
mechanically enforces this: every `.lean` file outside the
`LegalKernel/Test/`, `Lex/Test/`, and per-test allowlist is
scanned for `import LegalKernel.Test.*` lines, and any match
fails the CI gate.
-/

import LegalKernel
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.SignedAction

namespace LegalKernel.Test
namespace MockCrypto

open LegalKernel.Authority

/-! ## mockVerify

Accepts any 64-byte signature whose first byte is `0xFF`.
Deterministic, easy to construct in tests, structurally distinct
from any real Ed25519 signature shape. -/

/-- Test-only verifier.  Returns `true` iff `sig` is a 64-byte
    array whose first byte is `0xFF`.  Ignores `pk` and `msg` —
    the test goal is to exercise admissibility happy paths, not to
    audit the signature scheme.

    Audit-3.3: enables value-level construction of
    `AdmissibleWith mockVerify P d es st` witnesses, which the
    production `Verify` makes impossible (it returns `false`). -/
def mockVerify (_pk : PublicKey) (_msg : ByteArray) (sig : Signature) : Bool :=
  decide (sig.size = 64 ∧ sig.toList.head? = some 0xFF)

/-- A canonical mock signature: 64 bytes, first byte `0xFF`,
    remaining bytes `0x00`.  Always passes `mockVerify`. -/
def mockSign (_pk : PublicKey) (_msg : ByteArray) : Signature :=
  ByteArray.mk
    ((List.replicate 64 (0 : UInt8)).set 0 0xFF).toArray

/-- A canonical mock public key for actor `id`: 32 bytes
    encoding the actor id in the first 8 LE bytes; remaining
    bytes zero.  `mockVerify` ignores `pk`, but the registry
    needs *some* `PublicKey` value per registered actor. -/
def mockPubKey (id : Nat) : PublicKey :=
  let head := (List.range 8).map fun i =>
    (UInt8.ofNat ((id / (256 ^ i)) % 256))
  let tail := List.replicate 24 (0 : UInt8)
  ByteArray.mk (head ++ tail).toArray

/-! ## Self-tests for the mock primitives

These value-level tests are exercised by the
`Test/Authority/SignedActionHappyPath.lean` and
`Test/Runtime/LoopHappyPath.lean` suites; they're the load-bearing
guarantees that the mock crypto behaves as documented.  We do
NOT prove them as theorems here — `decide` on `ByteArray.toList`
of `List.replicate _ _ |>.toArray` does not unfold cleanly, and
the test suite is the appropriate venue for the value-level
check anyway. -/

end MockCrypto
end LegalKernel.Test
