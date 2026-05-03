/-
Tests — root of the `lake test` driver.

Imports every test module, runs them in sequence, and exits non-zero
if any test failed.  The test driver is wired to this binary via
`@[test_driver]` in `lakefile.lean`.

Suite history:

* Phase 0 — kernel-level (12 cases), umbrella-level, and transfer-law
  tests.  Wired the test framework.
* Phase 1 — added the `RBMapLemmasTests` suite for §8.3 fold lemmas
  plus extra `KernelTests` cases for the §4.3 balance lemmas (WU 1.5)
  and §4.9 multi-step / law-set reachability (WU 1.7 – 1.8).
* Phase 2 — added the `ConservationTests` suite for `TotalSupply`,
  `IsConservative`, `ConservativeLawSet`, and `total_supply_global`;
  plus per-law suites for `mint`, `burn`, and `freezeResource` (with
  the `FrozenForResource` invariant).  Extended the existing
  `TransferTests` suite with `transfer_conserves` and the
  `IsConservative` instance check.

Later phases will append modules here as new laws and invariants
land.
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.KernelTests
import LegalKernel.Test.RBMapLemmasTests
import LegalKernel.Test.Umbrella
import LegalKernel.Test.ConservationTests
import LegalKernel.Test.Laws.Transfer
import LegalKernel.Test.Laws.Mint
import LegalKernel.Test.Laws.Burn
import LegalKernel.Test.Laws.Freeze

open LegalKernel.Test

/-- Test-driver entry point.  Returns `0` when every suite passes,
    `1` when any test fails. -/
def main : IO UInt32 := do
  let mut failed : Nat := 0
  failed := failed + (← runAll "kernel"       KernelTests.tests)
  failed := failed + (← runAll "rbmap"        RBMapLemmasTests.tests)
  failed := failed + (← runAll "umbrella"     Umbrella.tests)
  failed := failed + (← runAll "conservation" ConservationTests.tests)
  failed := failed + (← runAll "transfer"     Laws.TransferTests.tests)
  failed := failed + (← runAll "mint"         Laws.MintTests.tests)
  failed := failed + (← runAll "burn"         Laws.BurnTests.tests)
  failed := failed + (← runAll "freeze"       Laws.FreezeTests.tests)
  if failed = 0 then
    IO.println "ALL TESTS PASSED"
    pure 0
  else
    IO.println s!"{failed} TESTS FAILED"
    pure 1
