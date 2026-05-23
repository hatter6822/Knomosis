/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Commit — value-level tests for the
state-commitment scheme (Workstream H §12 / WUs H.2.1 – H.2.5).
-/

import LegalKernel.FaultProof.Commit
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Commit

/-- Tests for the state-commitment scheme. -/
def tests : List TestCase :=
  [ { name := "commitExtendedState yields 32 bytes"
    , body := do
        let c := commitExtendedState ExtendedState.empty
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "commitExtendedState is deterministic on equal states"
    , body := do
        let c1 := commitExtendedState ExtendedState.empty
        let c2 := commitExtendedState ExtendedState.empty
        assertEq (expected := c1) (actual := c2) "determinism"
    }
  , { name := "commitState yields 32 bytes"
    , body := do
        let c := commitState (ExtendedState.empty.base)
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "commitNonceState yields 32 bytes"
    , body := do
        let c := commitNonceState ExtendedState.empty.nonces
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "commitKeyRegistry yields 32 bytes"
    , body := do
        let c := commitKeyRegistry ExtendedState.empty.registry
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "commitLocalPolicies yields 32 bytes"
    , body := do
        let c := commitLocalPolicies ExtendedState.empty.localPolicies
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "commitBridgeState yields 32 bytes"
    , body := do
        let c := commitBridgeState ExtendedState.empty.bridge
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "Different sub-state commitments produce distinct top commits"
    , body := do
        let es0 := ExtendedState.empty
        let s1  := setBalance es0.base 1 42 100
        let es1 : ExtendedState := { es0 with base := s1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        -- Distinct underlying states should produce distinct commits
        -- under the production keccak256 binding.  Under FNV fallback
        -- we still expect distinct bytes for these specific fixtures.
        assert (c0 ≠ c1) "distinct states distinguishable"
    }
  , { name := "commitState_size theorem holds on populated state"
    , body := do
        let s0 := emptyState
        let s1 := setBalance s0 1 42 100
        let s2 := setBalance s1 2 99 50
        let c := commitState s2
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  , { name := "Modifying nonces alters the top-level commit"
    , body := do
        let es0 := ExtendedState.empty
        let es1 := advanceNonce es0 5
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "nonce advance changes commit"
    }
  , { name := "Modifying registry alters the top-level commit"
    , body := do
        let es0 := ExtendedState.empty
        let es1 : ExtendedState := { es0 with
          registry := es0.registry.insert 7 ByteArray.empty }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "registry change alters commit"
    }
  ]

end LegalKernel.Test.FaultProof.Commit
