-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.ReplayCli

/-!
LegalKernel.Test.Integration.ReplayCliFlags — the `knomosis-replay`
flag parser.

**Why this module exists.**  The auditor binary's whole value is that
a non-zero exit means "this log does not reproduce".  Its flag
handling was fail-OPEN in two ways:

  * An unrecognised `--`-prefixed token fell through the parser's
    catch-all into the positional arguments.  The resulting argument
    shape matched no dispatch arm, so `main` fell to `usage` — which
    returns exit **0**.  An operator following a stale docstring (for
    instance the `--require-attestation` flag documented in
    `AttestedSnapshot.lean` and the Genesis Plan but implemented
    nowhere) therefore got a silent PASS.
  * A malformed `--deployment-id <hex>` decoded to `none`, which is
    the same state as "flag absent", so the diagnostic blamed a
    missing flag rather than the malformed value.

These cases are pure-function tests on `parseGlobalFlags`, which is
why the parser now lives in a library module rather than in the
executable root.

This module is test-only and non-TCB.
-/

open LegalKernel.Test
open LegalKernel.Authority
open LegalKernel.Runtime.ReplayCli

namespace LegalKernel.Test.Integration.ReplayCliFlags

/-- An unrecognised flag is an error, not a positional argument. -/
def rejectsUnknownFlag : TestCase := {
  name := "replay flags: an unrecognised flag is rejected, not passed through"
  body := do
    for bad in ["--require-attestion", "--nope", "--allow-fallback-hashh"] do
      let f := parseGlobalFlags [bad, "log.bin"]
      if f.flagError.isNone then
        throw <| IO.userError
          s!"BUG: `{bad}` was accepted; it would reach `usage` and exit 0"
      -- It must NOT have leaked into the positional arguments.
      if f.positional.contains bad then
        throw <| IO.userError s!"BUG: `{bad}` leaked into the positional arguments"
}

/-- A malformed flag VALUE is distinguished from an absent flag. -/
def rejectsMalformedValues : TestCase := {
  name := "replay flags: a malformed flag value is its own error"
  body := do
    -- Odd-length hex.
    let f := parseGlobalFlags ["--deployment-id", "abc", "log.bin"]
    if f.flagError.isNone then
      throw <| IO.userError "BUG: odd-length --deployment-id hex was accepted"
    if f.deploymentId.isSome then
      throw <| IO.userError "BUG: a malformed --deployment-id produced a value"
    -- Non-hex characters.
    let f2 := parseGlobalFlags ["--deployment-id", "zzzz", "log.bin"]
    if f2.flagError.isNone then
      throw <| IO.userError "BUG: non-hex --deployment-id was accepted"
    -- Missing value entirely.
    let f3 := parseGlobalFlags ["--deployment-id"]
    if f3.flagError.isNone then
      throw <| IO.userError "BUG: --deployment-id with no value was accepted"
    -- Same three for --require-attestation.
    let f4 := parseGlobalFlags ["--require-attestation", "abc", "log.bin"]
    if f4.flagError.isNone then
      throw <| IO.userError "BUG: odd-length --require-attestation hex was accepted"
    let f5 := parseGlobalFlags ["--require-attestation"]
    if f5.flagError.isNone then
      throw <| IO.userError "BUG: --require-attestation with no value was accepted"
}

/-- Well-formed flags parse, in any order, and leave exactly the
    positional arguments behind. -/
def parsesWellFormedFlags : TestCase := {
  name := "replay flags: well-formed flags parse and positional order is preserved"
  body := do
    let f := parseGlobalFlags
      ["--allow-fallback-hash", "--deployment-id", "00ff",
       "--require-attestation", "aabb", "log.bin", "snap.bin"]
    assertEq (expected := true) (actual := f.flagError.isNone) "no flag error"
    assertEq (expected := true) (actual := f.allowFallbackHash) "fallback-hash flag set"
    assertEq (expected := true) (actual := f.deploymentId.isSome) "deployment id parsed"
    assertEq (expected := true) (actual := f.requiredAttestor.isSome) "attestor parsed"
    assertEq (expected := ["log.bin", "snap.bin"]) (actual := f.positional)
      "positional arguments preserved in order"
    -- Flags after the positional arguments parse too.
    let f2 := parseGlobalFlags ["log.bin", "--deployment-id", "00ff"]
    assertEq (expected := true) (actual := f2.flagError.isNone) "no flag error (trailing flag)"
    assertEq (expected := ["log.bin"]) (actual := f2.positional) "positional preserved"
}

/-- `--require-attestation` is a real flag, not just a docstring.
    `AttestedSnapshot.lean`, `docs/GENESIS_PLAN.md` §13.2 and
    `docs/audits/06-runtime.md` all documented it while no binary
    implemented it. -/
def requireAttestationIsImplemented : TestCase := {
  name := "replay flags: --require-attestation is implemented, not just documented"
  body := do
    let f := parseGlobalFlags ["--require-attestation", "0011223344", "log.bin", "snap.bin"]
    match f.requiredAttestor with
    | none =>
      throw <| IO.userError
        "BUG: --require-attestation parsed to no attestor key — the flag is documented \
         in AttestedSnapshot.lean and the Genesis Plan and must actually work"
    | some pk =>
      assertEq (expected := 5) (actual := pk.size) "attestor key decoded to 5 bytes"
    -- Pin the driver's arity: the attestor key is a real parameter,
    -- so the parsed flag has somewhere to go.  `@` bypasses the
    -- default-argument elaboration that would otherwise hide it.
    let _sig : System.FilePath → Option System.FilePath → ByteArray →
        Option PublicKey → IO UInt32 := @runReplay
    pure ()
}

/-- An empty argument list is not an error at the parser level — the
    dispatch layer reports the wrong positional count. -/
def emptyArgsParseCleanly : TestCase := {
  name := "replay flags: an empty argument list has no flag error"
  body := do
    let f := parseGlobalFlags []
    assertEq (expected := true) (actual := f.flagError.isNone) "no flag error"
    assertEq (expected := ([] : List String)) (actual := f.positional) "no positional arguments"
}

/-- All replay-CLI flag tests. -/
def tests : List TestCase :=
  [ rejectsUnknownFlag
  , rejectsMalformedValues
  , parsesWellFormedFlags
  , requireAttestationIsImplemented
  , emptyArgsParseCleanly
  ]

end LegalKernel.Test.Integration.ReplayCliFlags
