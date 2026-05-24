# Executables and umbrella modules

**Files:**
* `Main.lean` (354 lines) — `knomosis` runtime CLI
* `Replay.lean` (198 lines) — `knomosis-replay` auditor binary
* `Tests.lean` (364 lines) — `lake test` driver
* `LegalKernel.lean` (287 lines) — top-level umbrella
* `Lex.lean` (41 lines) — Lex DSL umbrella
* `Deployments.lean` (22 lines) — Deployments umbrella
* `NamingAudit.lean`, `DeferralAudit.lean` — covered in `15-tools.md`
* `lakefile.lean` (256 lines) — Lake package config (audit notes here)
* Four Lex Bin entry-point wrappers — covered briefly below

**TCB:** None.  Build / runtime infrastructure; bugs surface as CLI
failures or build failures, never as kernel-invariant violations.

---

## `lakefile.lean` — Lake build config

**Lean options (lines 35–40):**

```lean
leanOptions := #[
  ⟨`autoImplicit, false⟩,
  ⟨`relaxedAutoImplicit, false⟩,
  ⟨`linter.unusedVariables, true⟩,
  ⟨`linter.missingDocs, true⟩
]
```

* `autoImplicit := false`: no silent universe / type variable
  introduction.  Documented per Genesis Plan §13.6.
* `relaxedAutoImplicit := false`: same rule for section variables.
* `linter.unusedVariables := true`: dead bindings surface as warnings.
* `linter.missingDocs := true`: public surfaces must have docstrings.

**Finding:** Correct.  CI's strict-warnings gate fails the build on
any `: warning:` line, so these are forcing functions.

**Extra build dependencies (lines 47–59):**

```lean
extraDepTargets := #[`lexIndexRegistry, `lexCodegenInputs]

input_file lexIndexRegistry where
  path := "Lex/IndexRegistry.txt"

input_dir lexCodegenInputs where
  path := "Lex/Inputs"
```

This registers two non-`.lean` files / directories as build inputs.
Without these, editing `Lex/IndexRegistry.txt` or any file under
`Lex/Inputs/` wouldn't trigger a rebuild — the `lex_lint` /
`lex_codegen --check` gates would run against stale state in
incremental builds.

**Hazard observation:** The `input_dir` build dependency is at
*directory* granularity, not per-file.  If a future PR adds many
files under `Lex/Inputs/`, every modification of one file causes
every dependent target to rebuild.  Currently fine; flag for
scalability.

**Lean libraries:**

* `LegalKernel` (line 64): `@[default_target]`, roots = `[LegalKernel]`.
* `Lex` (line 72): roots = `[Lex]`.
* `Deployments` (line 79): roots = `[Deployments]`.
* `ToolsCommon` (line 110): roots = `[Tools.Common]`.
* `NamingAuditLib` (line 115): roots = `[Tools.NamingAudit]`.
* `DeferralAuditLib` (line 120): roots = `[Tools.DeferralAudit]`.
* `LexCommon` (line 196): roots = `[Lex.Tools.Common]`.
* `LexAudit` (line 206): roots = `[Lex.Tools.Lint, Lex.Tools.Codegen, Lex.Tools.Diff, Lex.Tools.Format]`.

**Lean executables:**

* `Tests` (line 86, `@[test_driver]`): root = `Tests`.
* `knomosis` (line 95): root = `Main`.
* `knomosis-replay` (line 103): root = `Replay` (the corner symbol `«knomosis-replay»` is correct Lean escape syntax).
* `tcb_audit` (line 129): root = `Tools.TcbAudit`.
* `count_sorries` (line 138): root = `Tools.CountSorries`.
* `stub_audit` (line 150): root = `Tools.StubAudit`.
* `naming_audit` (line 169): root = `NamingAudit`.
* `deferral_audit` (line 186): root = `DeferralAudit`.
* `lex_lint` (line 220): root = `Lex.Bin.Lint`.
* `lex_codegen` (line 236): root = `Lex.Bin.Codegen`.
* `lex_diff` (line 246): root = `Lex.Bin.Diff`.
* `lex_format` (line 254): root = `Lex.Bin.Format`.

All audit executables include `supportInterpreter := true`, which
allows them to run under `lake exe` rather than requiring a
pre-compiled binary.  Reasonable for diagnostic tools.

**Finding:** The lakefile is well-organised.  Each
library/executable has a docstring explaining its role.  The
separation of `Lex.Tools.*` (library) from `Lex.Bin.*` (thin
entry points) is documented and consistent.

---

## `Main.lean` — `knomosis` runtime CLI

**Imports (line 9):** `LegalKernel` (umbrella).

**Subcommands:** `info`, `process`, `replay`, `bootstrap`,
`snapshot`, `withdrawal-proof`, `help`.

### `decodeSignedActionStream` (line 91)

```lean
def decodeSignedActionStream :
    Nat → Stream → List SignedAction → Except DecodeError (List SignedAction)
  | _,        [],     acc => .ok acc.reverse
  | 0,        _ :: _, _   =>
    .error (.invalidLength "decodeSignedActionStream: fuel exhausted (internal bug)")
  | fuel + 1, s,      acc =>
    match Encodable.decode (T := SignedAction) s with
    | .ok (sa, rest) => decodeSignedActionStream fuel rest (sa :: acc)
    | .error e       => .error e
```

Three-case pattern match:
* Empty stream: success.
* Fuel exhausted on non-empty stream: internal-bug error.
* Decoder advances on success; bails on error.

**Hazard observation:** The pre-fuel is `bytes.size + 1`
(`readSignedActionsFromFile` line 107), which is a loose upper
bound: each successful `SignedAction.decode` consumes ≥ 9 bytes
(the CBE head of the embedded action), so the maximum iteration
count is `bytes.size / 9`.  But the fuel is correct in being a
safe upper bound; the docstring acknowledges this is "pre-fuel
the loop... to avoid needing a Lean termination proof."

**Finding:** Pattern match is correct.  Fuel exhaustion only
manifests on internal-bug paths (the stream actually shrinks
faster than the fuel decreases).

### `readSignedActionsFromFile` (line 107)

```lean
def readSignedActionsFromFile (path : System.FilePath) :
    IO (Except DecodeError (List SignedAction)) := do
  let bytes ← IO.FS.readBinFile path
  let lst := bytes.toList
  pure (decodeSignedActionStream (lst.length + 1) lst [])
```

Reads the binary file, converts to a `List UInt8`, pre-fuels with
`lst.length + 1`.

**Hazard observation:** `IO.FS.readBinFile` returns the entire
file in memory.  For large logs, this could exhaust memory.  The
runtime's intended use case (cross-stack tests, demo) keeps logs
small; production deployments should consider streaming.

### `formatHashHex` (line 116)

Manual hex formatting; converts each byte to two characters
(`0`-`9`, `a`-`f`).  Verified by inspection: `toChar (n+48)`
handles 0..9, `toChar (n-10+97)` handles 10..15.  Correct.

**Finding:** Could be replaced by `ByteArray.toHex` if Lean core
adds one, but the hand-roll is fine and matches the
`Replay.lean` duplicate (intentional).

### `cmdInfo` (line 131)

Prints build tag, phase, hash implementation, hash grade.  The
"hash-grade" check (`isProductionHash`) is what Audit-3.1
introduced to distinguish FNV-1a-64 fallback from production
BLAKE3/keccak256.

**Finding:** Correct.  The `WARN` line is helpful but does NOT
block execution — only chain-touching subcommands warn (via
`warnIfFallbackHash`).

### `warnIfFallbackHash` (line 147)

Stderr-warns if non-production hash and `--allow-fallback-hash`
not passed.  Does NOT exit; merely warns.

**Hazard observation:** This is *informational*, not blocking.
An operator who pipes stderr to `/dev/null` could miss the
warning entirely.  Contrast with `Replay.lean`'s
`checkHashGrade` which *refuses to run* without the flag.  The
asymmetry is intentional (the runtime CLI is for demo /
processing; the auditor binary is for production-grade
reproduction), but reviewers should note that `knomosis process`
can silently run with the wrong hash.

### `cmdProcess` (line 156)

1. Bootstrap (load log, truncate partial tail).
2. Read input `SignedAction` stream.
3. Process each action via `processBatch`.
4. Print per-action OK / FAIL diagnostics.
5. Print final state hash.
6. Optionally write hash to output file.

**Hazard observation:** The exit code is `1` if any action
failed.  Reviewers should not interpret exit 0 as "all actions
applied" — re-read the per-action lines for the actual count.

### `cmdReplay` (line 198), `cmdBootstrap` (line 214), `cmdSnapshot` (line 231)

Standard wrappers.  Each calls into the corresponding
`Runtime.*` library function and prints results.

### `cmdWithdrawalProof` (line 264)

Looks up a withdrawal proof in a snapshot and prints it.
Returns exit 0 on success, 1 on not-found, 2 on bad-Nat-parse.

**Finding:** Correct.  The "id not in snapshot" case prints to
stderr and exits 1, which is the right pessimistic posture.

### `parseGlobalFlags` (line 317)

Right-folds over args to strip `--allow-fallback-hash`.  Correct
for a single flag; would need to be extended for additional
flags.

### `main` (line 328)

Standard dispatch.  Falls through to `cmdHelp` on missing /
unknown subcommands.

**Finding:** Correct.  No issues.

---

## `Replay.lean` — `knomosis-replay` auditor binary

Mirror of `Main.lean` but:
* Single-purpose: replay a log + optional snapshot, print hash.
* Hard-rejects fallback hash without `--allow-fallback-hash`
  (`checkHashGrade` exits non-zero).
* Fails fast on snapshot errors (no silent fallback to empty
  genesis).

### `runReplay` (line 121)

Three-step state machine:

1. **Snapshot loading:** if a snapshot path is supplied, load
   and restore it; otherwise use `(zeroHash, replayGenesis, 0)`.
   On error, prints `SNAPSHOT_ERROR` or `SNAPSHOT_DECODE_ERROR`
   to stdout and exits 1.
2. **Read the log:** `readAllEntries logPath`.  Prints
   `LOG_TRUNCATED entries=N` if partial tail.
3. **Slice + replay:** drops `snapLogIndex` entries from the
   front, replays the rest via `replayFromSeed`.  Prints `OK`
   on success or `REPLAY_ERROR` on failure.

The output format is documented in the `usage` function:
`OK <hash> via=<id>`, `FALLBACK_HASH_NOT_PERMITTED`,
`REPLAY_ERROR <repr>`, `SNAPSHOT_ERROR <repr>`, etc.

**Hazard observation:** The output format is stable but
machine-parseable only via prefix matching.  An auditor CI
script that greps for `OK ` would need to anchor at line start
(or use `^OK `).  Currently no formal output schema; flag for
future structured-output extensions.

**Hazard observation:** The slice via `entries.drop snapLogIndex`
silently succeeds when `snapLogIndex > entries.length`...
*WAIT* — line 148 explicitly checks this case:

```lean
if snapLogIndex > entries.length then
  IO.println s!"SNAPSHOT_INDEX_OVERRUN snap_index={snapLogIndex} log_entries={entries.length}"
  pure 1
```

Good.  The check is in place.

**Security note (line 114):** The docstring explicitly calls out
the "snapshot errors silently fall back to empty genesis" hazard
that an earlier draft had.  The current implementation is
correct: failure prevents `OK` output entirely.

### `checkHashGrade` (line 166)

Audit-3.1 pre-flight check.  Returns `true` if production hash
or if `--allow-fallback-hash` was passed.  Otherwise prints
`FALLBACK_HASH_NOT_PERMITTED` to stdout and returns `false`.

`main` (line 191) exits 1 on `false` from `checkHashGrade`.

**Finding:** Correct.  The asymmetry between `knomosis` (warn but
proceed) and `knomosis-replay` (refuse) is intentional: the
auditor binary's reproduction guarantee is meaningless under a
non-cryptographic hash.

---

## `Tests.lean` — `lake test` driver

364 lines; nearly all is `import LegalKernel.Test.*` followed by
a single `main` function that calls `runAll` on ~100 test suites.

**Hazard observation:** The `set_option maxRecDepth 1024` (line
166) is necessary because the long `failed := failed + (← runAll
...)` chain exceeds Lean's default elaboration recursion limit.
The comment explains this; alternative would be to split into
multiple `def`s.

**Hazard observation:** The test names (`"kernel"`, `"rbmap"`,
etc.) are string-encoded.  Reviewers should not assume a 1:1
correspondence between test-suite-string-name and module path.
Currently consistent; if a refactor moves modules, the strings
will not auto-update.

**Finding:** No logic issues.  The test-suite list is
append-only by convention; each new module adds a new
`failed := failed + ...` line.

---

## `LegalKernel.lean` — top-level umbrella

287 lines; mostly `import` statements (lines 148–270) covering
every kernel module.

Note the explicit omission of `Lex.DSL.ImplLowering` (line 193):

```lean
-- LexImplLowering is intentionally NOT in the umbrella: it
-- registers `to`, `from`, `as`, `amt`, `nop` as global Lean
-- tokens (the §6.2 calculus keywords).
```

This is correct: those keywords would shadow common parameter
names in unrelated code.  Importing the umbrella should not
introduce surprising parser behaviour.

### `kernelBuildTag` (line 285)

```lean
def kernelBuildTag : String := "knomosis-fault-proof-migration"
```

Pinned by `Test/Umbrella.lean` regression.  CLAUDE.md notes:
"any phase / milestone bump must update both the constant and
the test in the same PR."

**Hazard observation:** The constant is hand-maintained.  A
forgotten update would be caught by the regression test, but
nothing prevents a typo.  The build tag is consumed by
`knomosis info` and external auditors; consistency with the
release / branch / commit metadata is the operator's
responsibility.

**Finding:** Correct.  No issues with the import list; the
omission is documented.

---

## `Lex.lean` — Lex umbrella

42 lines; imports 7 of the 8 Lex DSL modules (deliberately
omitting `ImplLowering` for the same reason as `LegalKernel.lean`).

**Finding:** Correct.

---

## `Deployments.lean` — Deployments umbrella

23 lines; imports `Deployments.Examples.UsdClearing`.

**Finding:** Correct.  Future deployments append imports here.

---

## Lex Bin entry-point wrappers

`Lex/Bin/{Lint, Codegen, Diff, Format}.lean` — each ~30 lines.
Single-purpose: import the corresponding `Lex.Tools.*` library
module, define a top-level `main` that delegates to the
library's `main`.

The split is documented: "Splitting the entry-point glue from
the library code lets tests import the helpers without
colliding on top-level `def main` declarations across multiple
audit binaries."

**Finding:** Correct.  All four wrappers follow the same pattern;
no logic.

---

## Module-level findings

* **CLI ergonomics:** Both `knomosis` and `knomosis-replay` have well-
  designed help text, exit codes, and per-line stderr/stdout
  output distinctions.  Auditor CI scripts can rely on the
  documented output formats.
* **Hash-grade discipline:** Audit-3.1's `--allow-fallback-hash`
  flag is present on both binaries.  `knomosis` warns; `knomosis-replay`
  refuses.  This is intentional and documented.
* **Snapshot security:** `knomosis-replay` correctly fails fast on
  snapshot errors and refuses to print `OK` unless the seed state
  was successfully recovered.  An earlier draft had the silent-
  fallback hazard; current implementation is correct.
* **No `sorry`, no custom axioms, no Mathlib.**
* **Hazards (all documented and bounded):**
  * `decodeSignedActionStream` fuel is a safe upper bound but
    not tight; OK in practice.
  * `IO.FS.readBinFile` reads the entire file in memory; OK for
    demo / test logs.
  * `parseGlobalFlags` handles one flag; would need extension.
  * `Tests.lean` `maxRecDepth` bump is needed for the long
    test-suite chain; documented.
  * `kernelBuildTag` is hand-maintained; regression test
    catches drift.
* **Test driver:** ~100 test suites enumerated; the linear
  `failed := failed + (← runAll ...)` chain is readable but
  long.  No issues with the structure.
