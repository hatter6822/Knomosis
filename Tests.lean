/-
Tests — root of the `lake test` driver.

Imports every test module, runs them in sequence, and exits non-zero
if any test failed.  The test driver is wired to this binary via
`@[test_driver]` in `lakefile.lean`.

Phase 0 shipped kernel-level, umbrella-level, and transfer-law tests.
Phase 1 (WU 1.1 – 1.13) adds the `RBMapLemmasTests` suite, which
spot-checks the §8.3 fold lemmas at runtime, plus extra cases in
`KernelTests` for the §4.3 balance lemmas (WU 1.5) and the §4.9
multi-step / law-set reachability extensions (WU 1.7 – 1.8).

Later phases will append modules here as new laws and invariants
land.
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.KernelTests
import LegalKernel.Test.RBMapLemmasTests
import LegalKernel.Test.Umbrella
import LegalKernel.Test.Laws.Transfer

open LegalKernel.Test

/-- Test-driver entry point.  Returns `0` when every suite passes,
    `1` when any test fails. -/
def main : IO UInt32 := do
  let mut failed : Nat := 0
  failed := failed + (← runAll "kernel"      KernelTests.tests)
  failed := failed + (← runAll "rbmap"       RBMapLemmasTests.tests)
  failed := failed + (← runAll "umbrella"    Umbrella.tests)
  failed := failed + (← runAll "transfer"    Laws.TransferTests.tests)
  if failed = 0 then
    IO.println "ALL TESTS PASSED"
    pure 0
  else
    IO.println s!"{failed} TESTS FAILED"
    pure 1
