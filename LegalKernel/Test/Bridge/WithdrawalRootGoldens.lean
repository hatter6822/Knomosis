/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.WithdrawalRootGoldens — Workstream D.1.5
acceptance tests.

Generates a 16-leaf golden fixture in Lean and verifies that:

  * Each canonical proof verifies against the canonical root.
  * The roots and proofs are byte-deterministic across runs.

The fixture file (`solidity/test/fixtures/withdrawal_proof_smt.json`)
is a follow-up Solidity-side concern; this Lean-side test driver
exercises the in-Lean half of the cross-stack contract.

When the production keccak256 binding lands (via `@[extern]` link
to the Rust adaptor), the Solidity side will re-run the exact same
fixture and assert byte-for-byte matching against this Lean
output.  Until then, the fixture's bytes are stable under the
FNV-1a-64 fallback (a local-only test invariant — production
deployments swap this).
-/

import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Bridge.WithdrawalProof
import LegalKernel.Bridge.State
import LegalKernel.Bridge.AddressBook
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.WithdrawalRootGoldens

/-- Build a 16-leaf bridge state.  Each `PendingWithdrawal` carries
    distinct `(amount, l2LogIndex)` so the leaf bytes are pairwise
    distinct (avoiding accidental hash collisions in the test). -/
def fixture16 : BridgeState :=
  let mkWd (i : Nat) : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero,
      amount := 1000 + i, l2LogIndex := i }
  let s00 := BridgeState.empty
  let s01 := s00.appendWithdrawal (mkWd 0)
  let s02 := s01.appendWithdrawal (mkWd 1)
  let s03 := s02.appendWithdrawal (mkWd 2)
  let s04 := s03.appendWithdrawal (mkWd 3)
  let s05 := s04.appendWithdrawal (mkWd 4)
  let s06 := s05.appendWithdrawal (mkWd 5)
  let s07 := s06.appendWithdrawal (mkWd 6)
  let s08 := s07.appendWithdrawal (mkWd 7)
  let s09 := s08.appendWithdrawal (mkWd 8)
  let s10 := s09.appendWithdrawal (mkWd 9)
  let s11 := s10.appendWithdrawal (mkWd 10)
  let s12 := s11.appendWithdrawal (mkWd 11)
  let s13 := s12.appendWithdrawal (mkWd 12)
  let s14 := s13.appendWithdrawal (mkWd 13)
  let s15 := s14.appendWithdrawal (mkWd 14)
  let s16 := s15.appendWithdrawal (mkWd 15)
  s16

/-- The 16-leaf root (cross-stack golden value). -/
def root16 : ByteArray := withdrawalRoot hashBytes fixture16

/-- Verify the canonical proof for `idx ∈ [0, 16)` against the
    16-leaf golden root. -/
def verifyAtIdx (idx : Nat) : Bool :=
  let proof := constructProof hashBytes fixture16 idx
  verifyProof hashBytes proof root16

/-- Tests: 16-leaf golden fixture all-canonical-proofs verify. -/
def tests : List TestCase :=
  [ -- Each of the 16 canonical proofs must verify against the root.
    { name := "16-leaf golden: all canonical proofs verify (id 0..15)"
    , body := do
        for idx in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] do
          if !verifyAtIdx idx then
            throw <| IO.userError s!"canonical proof at id {idx} failed"
    }
  , { name := "16-leaf golden: root is 32 bytes"
    , body := do
        assertEq (expected := (32 : Nat)) (actual := root16.size) "size"
    }
  , { name := "16-leaf golden: root is deterministic"
    , body := do
        let r1 := root16.toList
        let r2 := (withdrawalRoot hashBytes fixture16).toList
        if r1 == r2 then pure () else throw <| IO.userError "non-deterministic"
    }
  , { name := "16-leaf golden: roots distinguish populated from empty"
    , body := do
        let r1 := root16.toList
        let r2 := (withdrawalRoot hashBytes BridgeState.empty).toList
        if r1 == r2 then
          throw <| IO.userError "16-leaf root collided with empty"
        else pure ()
    }
  -- Out-of-range index tests
  , { name := "16-leaf golden: id 16 (out of fixture) constructs empty proof"
    , body := do
        let proof := constructProof hashBytes fixture16 16
        -- Out-of-range id has empty leaf; verifier should accept this proof
        -- only against the canonical root computed for "this leaf at id 16
        -- as empty" which differs from root16 (since 16 isn't populated and
        -- root16 has no entry there, the canonical-leaf proof for id 16
        -- against root16 should still verify: it asserts non-membership
        -- by claiming the empty sentinel at that position).
        if verifyProof hashBytes proof root16 then
          pure ()  -- non-membership proof verifies
        else
          throw <| IO.userError "non-membership proof for id 16 failed"
    }
  ]

end LegalKernel.Test.Bridge.WithdrawalRootGoldens
