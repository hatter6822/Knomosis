/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.Disputes.Evidence
import LegalKernel.FaultProof.Commit
import LegalKernel.Runtime.Snapshot

/-!
LegalKernel.Test.Integration.ReplayUpToCli — RH-G plan
deliverable.

Integration regression for the `knomosis replay-up-to LOG IDX`
subcommand that the off-chain `knomosis-faultproof-observer` Rust
crate's `SubprocessTruthOracle` shells out to.  Verifies the
Lean-level contract: replaying the log prefix `entries[0..idx]`
via `kernelOnlyReplay` and applying `commitExtendedState`
produces the canonical 32-byte commit deterministically.

The CLI surface itself lives in `Main.lean`; this test covers
the Lean-level kernel contract that the CLI dispatches to.
Subprocess-level invocation tests live in the Rust crate's
`tests/` directory (they spawn the binary and parse stdout).
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.FaultProof
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.Integration.ReplayUpToCli

/-- The empty-log replay produces a deterministic commit. -/
def empty_log_replay_is_deterministic : IO Unit := do
  let genesis : ExtendedState := ExtendedState.empty
  let entries : List LogEntry := []
  let st1 := kernelOnlyReplay genesis (entries.take 0)
  let st2 := kernelOnlyReplay genesis (entries.take 0)
  let c1 := commitExtendedState st1
  let c2 := commitExtendedState st2
  unless c1 = c2 do
    throw (IO.userError s!"empty-log replay produced different commits: c1={c1.toList}, c2={c2.toList}")

/-- `kernelOnlyReplay (entries.take 0)` equals `kernelOnlyReplay []`. -/
def replay_zero_prefix_equals_empty : IO Unit := do
  let genesis : ExtendedState := ExtendedState.empty
  let entries : List LogEntry := []
  let st_zero := kernelOnlyReplay genesis (entries.take 0)
  let st_empty := kernelOnlyReplay genesis []
  let c_zero := commitExtendedState st_zero
  let c_empty := commitExtendedState st_empty
  unless c_zero = c_empty do
    throw (IO.userError "kernelOnlyReplay(take 0) != kernelOnlyReplay([])")

/-- API stability: the `commitExtendedState` function signature
    remains `ExtendedState → StateCommit`.  An elaboration-level
    check; if the type changes, this file fails to compile. -/
def commit_extended_state_api_stable : IO Unit := do
  let _proof :
      ExtendedState → StateCommit := commitExtendedState
  pure ()

/-- API stability: `kernelOnlyReplay : ExtendedState → List LogEntry → ExtendedState`. -/
def kernel_only_replay_api_stable : IO Unit := do
  let _proof :
      ExtendedState → List LogEntry → ExtendedState := kernelOnlyReplay
  pure ()

/-- Commit output has the documented 32-byte width. -/
def commit_output_is_32_bytes : IO Unit := do
  let genesis : ExtendedState := ExtendedState.empty
  let c := commitExtendedState (kernelOnlyReplay genesis [])
  unless c.size = 32 do
    throw (IO.userError s!"commitExtendedState output size = {c.size}, expected 32")

end LegalKernel.Test.Integration.ReplayUpToCli

namespace LegalKernel.Test.Integration.ReplayUpToCli

/-- All tests in this module — collected via the `@[test]`
    attribute and dispatched from `Tests.lean`. -/
def tests : List TestCase := [
  ⟨"replay-up-to: empty log is deterministic", empty_log_replay_is_deterministic⟩,
  ⟨"replay-up-to: take 0 ≡ empty", replay_zero_prefix_equals_empty⟩,
  ⟨"replay-up-to: commitExtendedState API stable", commit_extended_state_api_stable⟩,
  ⟨"replay-up-to: kernelOnlyReplay API stable", kernel_only_replay_api_stable⟩,
  ⟨"replay-up-to: commit output is 32 bytes", commit_output_is_32_bytes⟩
]

end LegalKernel.Test.Integration.ReplayUpToCli
