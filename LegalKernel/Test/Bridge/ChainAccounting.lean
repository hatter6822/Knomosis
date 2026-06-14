-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.ChainAccounting — Workstream CA acceptance tests.

Drives the chain-level bridge accounting surface (GENESIS_PLAN §7.6.4 /
§7.6.5; audit finding m-16):

  * value-level fixtures for `bridgeEscrowBalance` and the §7.6.4
    accounting identity `totalDeposited = totalWithdrawn +
    bridgeEscrowBalance` on concrete solvent ledgers, and genesis;
  * term-level API-stability pins for the chain headline theorems
    (`bridge_chain_conserves`, `bridgeReachable_solvent`,
    `bridge_chain_accounting_equation`), the per-action deltas, and the
    `BridgeReachable` / `BridgeAction` substrate.
-/

import LegalKernel.Bridge.ChainAccounting
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.ChainAccountingTests

/-- A ledger with one deposit (id 1, resource 1, amount 100). -/
def bsDep : BridgeState :=
  BridgeState.empty.markConsumed 1
    { resource := 1, userAmount := 100, poolAmount := 0, budgetGrant := 0 }

/-- The above, plus a withdrawal of 30 at resource 1. -/
def bsDepWd : BridgeState :=
  bsDep.appendWithdrawal
    { resource := 1, recipient := EthAddress.zero, amount := 30, l2LogIndex := 0 }

/-- A fee-bearing deposit (id 1, resource 1, user 60 + pool 40). -/
def bsFee : BridgeState :=
  BridgeState.empty.markConsumed 1
    { resource := 1, userAmount := 60, poolAmount := 40, budgetGrant := 9 }

/-- Wrap a `BridgeState` into a minimal `ExtendedState`. -/
def es (bs : BridgeState) : ExtendedState :=
  { ExtendedState.empty with bridge := bs }

/-- Tests for the chain-level bridge accounting surface. -/
def tests : List TestCase :=
  [ { name := "bridgeEscrowBalance: deposit-only escrow = deposited"
    , body := do
        assertEq (expected := (100 : Nat))
                 (actual := bridgeEscrowBalance (es bsDep) 1)
                 "escrow at r=1 after depositing 100"
        assertEq (expected := (0 : Nat))
                 (actual := bridgeEscrowBalance (es bsDep) 2)
                 "escrow at untouched r=2 is 0"
    }
  , { name := "bridgeEscrowBalance: deposit minus withdrawal"
    , body := do
        assertEq (expected := (70 : Nat))
                 (actual := bridgeEscrowBalance (es bsDepWd) 1)
                 "escrow = 100 deposited - 30 withdrawn"
    }
  , { name := "bridgeEscrowBalance: fee deposit escrows user + pool legs"
    , body := do
        assertEq (expected := (100 : Nat))
                 (actual := bridgeEscrowBalance (es bsFee) 1)
                 "escrow = userAmount 60 + poolAmount 40"
    }
  , { name := "§7.6.4 identity holds on a solvent ledger (deposit + withdraw)"
    , body := do
        -- totalDeposited = totalWithdrawn + bridgeEscrowBalance: 100 = 30 + 70.
        assertEq (expected := totalDeposited (es bsDepWd) 1)
                 (actual := totalWithdrawn (es bsDepWd) 1
                              + bridgeEscrowBalance (es bsDepWd) 1)
                 "deposited = withdrawn + escrow"
    }
  , { name := "bridgeEscrowBalance / BridgeConserves: genesis is empty & balanced"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual := bridgeEscrowBalance genesisExtended 1)
                 "genesis escrow is 0"
        assertEq (expected := totalDeposited genesisExtended 1)
                 (actual := totalWithdrawn genesisExtended 1
                              + TotalSupply genesisExtended.base 1)
                 "genesis: deposited = withdrawn + supply (0 = 0 + 0)"
    }
  , { name := "CA headline theorems: term-level API stability"
    , body := do
        -- The §7.6.4 / §7.6.5 chain headline: every state bridge-reachable
        -- from genesis conserves, is solvent, and satisfies the equation.
        let _conserves := @bridge_chain_conserves
        let _solvent := @bridgeReachable_solvent
        let _equation := @bridge_chain_accounting_equation
        let _preserves := @bridgeReachable_preserves
        let _step := @bridgeConserves_step
        let _mono := @withdrawalsMonotonic_step
        pure ()
    }
  , { name := "CA per-action deltas + substrate: term-level API stability"
    , body := do
        let _dS := @deposit_step_supply
        let _wS := @withdraw_step_supply
        let _fS := @depositWithFee_step_supply
        let _dD := @deposit_step_deposited
        let _wD := @withdraw_step_deposited
        let _fD := @depositWithFee_step_deposited
        let _dW := @deposit_step_withdrawn
        let _wW := @withdraw_step_withdrawn
        let _fW := @depositWithFee_step_withdrawn
        let _toAction := @BridgeAction.toAction_injective
        let _trans := @BridgeReachable.trans
        let _base := @apply_bridge_admissible_with_base
        pure ()
    }
  , { name := "bridge_accounting_equation (concrete escrow under solvency): term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (r : ResourceId),
                   totalWithdrawn es r ≤ totalDeposited es r →
                   totalDeposited es r = totalWithdrawn es r + bridgeEscrowBalance es r :=
          bridge_accounting_equation
        pure ()
    }
  ]

end LegalKernel.Test.Bridge.ChainAccountingTests
