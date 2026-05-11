# Audit 10 — DSL Modules

Scope: the base law DSL (`LegalKernel/DSL/`) and the Lex language extension
(`Lex/DSL/`). All files were read line-by-line; macros are summarised by
emission semantics rather than quasi-quote text. Read-only audit.

---

## `LegalKernel/DSL/Law.lean` (86 lines)

### Imports
- `LegalKernel.Kernel` only — clean and minimal. Just enough to expose
  `Transition`, `State`, `DecidablePred`, `inferInstance`.

### Generated declarations
- A single `def Law.mk` (`LegalKernel/DSL/Law.lean:79-83`) producing a
  `Transition` with `decPre := fun _ => inferInstance`. The `[DecidablePred pre]`
  instance argument is the load-bearing piece — elaboration fails at the
  *call site* if the precondition is not instance-resolvable. This faithfully
  implements the §13.6 step-2 discipline.

### Decidability synthesis
- Delegated entirely to Lean's `inferInstance` via the `[DecidablePred pre]`
  argument. There is no custom synthesis here.

### Sharp points
1. The whole `def Law.mk` carries `@[deprecated]` (`LegalKernel/DSL/Law.lean:78`)
   with a `since := "lex-m2-canonical"` tag. Every direct call therefore emits
   a deprecation warning under the strict-warnings CI gate. Callers must wrap
   in `set_option linter.deprecated false in`. Code that previously used
   `Law.mk` directly will start warning until migrated.
2. The deprecated `Law.mk` body still uses `fun _ => inferInstance` literally
   for `decPre`, so the synthesised `Decidable` term is *not* shared between
   identical preconditions — every call site resynthesises. This is invisible
   but means `decPre` cannot be unfolded to a closed `Decidable` term at the
   definition site.

### Documentation drift
- Docstring mentions "the canonical surface for declaring laws is the `lexlaw`
  macro in `DSL/LexLaw.lean`". There is no `DSL/LexLaw.lean` file; the actual
  location is `Lex/DSL/Law.lean`. Minor drift.

---

## `LegalKernel/DSL/LawSyntax.lean` (165 lines)

### Imports
- `LegalKernel.DSL.Law` — fine.

### Macro definitions
- Two parse rules:
  - `lawMacroPre` (`LegalKernel/DSL/LawSyntax.lean:79-80`): `law pre := <term> ; impl := <term>`
  - `lawMacroNoPre` (`LegalKernel/DSL/LawSyntax.lean:83-84`): `law impl := <term>` (defaults `pre := fun _ => True`)
- Both expand via `macro_rules` (`LegalKernel/DSL/LawSyntax.lean:86-90`) to
  `Law.mk preExpr implExpr`.

### Hygiene / token leak (intentional but sharp)
- `syntax (name := lawMacroPre) "law" "pre" ":=" term ";" "impl" ":=" term : term`
  registers `pre` and `impl` as *global Lean tokens* whenever this module is
  transitively imported. This is the documented reason `Law.lean` was split
  from `LawSyntax.lean` (header at `LegalKernel/DSL/LawSyntax.lean:18-23`).
  Importing this module poisons `where pre := ...` structure-field syntax in
  any downstream file. Strictly opt-in by design, but a real footgun if a
  reviewer adds the import casually.
- All five `example`s in the file are wrapped in
  `set_option linter.deprecated false in` to suppress warnings from the
  `Law.mk` deprecation. Forgetting this wrapper breaks the strict-warnings
  build.

### Sharp points
- Macro rules use only the two recognised shapes. Any malformed `law` input
  triggers a "no `macro_rules` matched" error, which is bearable but lacks a
  custom diagnostic.

### Documentation drift
- Docstring (`LegalKernel/DSL/LawSyntax.lean:55-58`) refers to `lex_law`
  macro; the actual macro keyword (per `Lex/DSL/Law.lean:153`) is `lexlaw`
  (no underscore). Minor name drift.

---

## `Lex/DSL/PreGrammar.lean` (345 lines)

### Imports
- `Lean.Elab.Command`, `Lean.Elab.Term`, `Lean.Data.Position`,
  `Lean.Attributes` — all reasonable for syntax-walking.

### AST types (`PreNode` / `NatNode` / `ActorNode` / `ResourceNode` /
  `BoundedIter`)
- `PreNode` and `NatNode` are defined in a `mutual` block
  (`Lex/DSL/PreGrammar.lean:107-178`). Both have a `.unknown : String → _`
  catch-all and use `Inhabited` derivation only (no `DecidableEq`/`Repr` for
  the mutual pair — odd, given the singleton types have both).

### Macro / elaborator definitions
- `initialize lexPreAttr : Lean.TagAttribute` (`Lex/DSL/PreGrammar.lean:197-199`)
  registers `@[lex_pre]`. No decidability check is *enforced* by the attribute
  itself (per design note `Lex/DSL/PreGrammar.lean:182-190`) — `[DecidablePred pre]`
  at the call site is the authoritative gate.
- Two `partial def` walkers `parsePreExpr` / `parseNatExpr`
  (`Lex/DSL/PreGrammar.lean:238-314`) inside a `mutual` block.

### Walker semantics
- Walks the *surface* `Syntax` (before elaboration). Matches syntactic shapes
  like `` `($lhs ≤ $rhs) `` → `.leNat`, `` `(∀ $x:ident ∈ $iter, $body) `` →
  `.forallIn`, etc. Anything not matched becomes `.unknown text`.
- Lambdas are matched 4 ways (`Lex/DSL/PreGrammar.lean:255-258`):
  `fun x => body`, `fun (x : T) => body`, `fun (_ : T) => body`, `fun _ => body`.
- For Nat sort: literal parsing via `s.toNat?` (`Lex/DSL/PreGrammar.lean:291`).

### Sharp points
1. **Lambda-strip is one-deep only.** A nested `fun s => fun x => body`
   (rare but legal) only sheds the outer binder. Unlikely in practice.
2. **`.unknown` is a soft failure.** The macro layer (`Lex/DSL/Law.lean:758-762`)
   emits L003 as a *warning*, then defers to `inferInstance`. So a wrong
   walker recognition (false negative) doesn't break a valid law — it just
   surfaces a spurious warning. Conservative as designed.
3. **`String.toNat?` is checked on the *whole surface text* of the syntax
   node** (`Lex/DSL/PreGrammar.lean:289-292`). For `1 + 1` etc. this means
   `parseNatExpr` first falls back to the `add` arm because of the `match
   stx with` order. Note that `parseNatExpr` is `partial`, so non-terminating
   inputs are possible in principle (but the syntax is finite-depth).
4. **`isLexPreTagged` is read only by the walker.** The attached
   decidability instance the user supplies is what the elaborator actually
   uses. So tagging without a `Decidable` instance does nothing harmful — it
   just lets the walker emit `userPred` rather than `.unknown`.

### Documentation drift
- Header (`Lex/DSL/PreGrammar.lean:30`) says "the L003 diagnostic is anchored
  at the user's surface syntax via the macro's existing source-position
  threading"; in practice the macro anchors L003 at `name.raw`
  (`Lex/DSL/Law.lean:761`), not at the offending sub-expression, so the
  diagnostic position is the law name, not the bad clause.

---

## `Lex/DSL/ImplCalculus.lean` (333 lines)

### Imports
- `Lean.Elab.Command`, `Lean.Elab.Term`, `Lean.Attributes`. Reasonable.

### AST types
- `EffectKind` (kernelImpl/authority/host) at `Lex/DSL/ImplCalculus.lean:62-72`.
- `ImplStmt` (12 constructors including two forbidden shapes
  `revokeKey`, `bareSetBalance`) at `Lex/DSL/ImplCalculus.lean:80-111`.
- Each `ImplStmt` constructor's text fields are `String` (surface text),
  NOT typed terms — M1 captures raw text only. The synthesizer dispatches
  on the kind tag.

### Macro / elaborator definitions
- `initialize lexImplAttr : Lean.TagAttribute` (`Lex/DSL/ImplCalculus.lean:152-154`)
  registers `@[lex_impl]`. No decidability gate (intentional).

### Walker semantics (text-based)
- `stripImplWrappers` (`Lex/DSL/ImplCalculus.lean:211-224`): strips a leading
  `do` or `fun s =>`. The `fun`-stripping is suspect: it splits the entire
  string on `=>`, takes everything after the first arrow — a body containing
  `=>` (e.g. a nested lambda) would be truncated.
- `tokeniseStmts` (`Lex/DSL/ImplCalculus.lean:230-234`): splits on `;` AND `\n`,
  drops empty fragments. A semicolon *inside* a string literal would be
  split as if it were a statement separator (no string-literal awareness).
- `parseImplStmt` (`Lex/DSL/ImplCalculus.lean:272-305`): dispatches on
  `startsWithKeyword`. Crucially, the body of every keyword arm
  passes the *full statement text* as the first string argument (e.g.,
  `.flow s "" "" ""`). The remaining three params are empty strings — M1
  hasn't done field-level extraction.
- `revokeKey` arm (`Lex/DSL/ImplCalculus.lean:288-293`) is the only one that
  extracts a sub-token (the actor name) via `firstToken (stripKeyword s "revoke_key")`.
  Audit-2 comment cites a prior `"revoke_key revoke_key alice"` bug.

### Sharp points
1. **Text-based parser is fragile.** A user-friendly editor format that uses
   tabs instead of spaces, or CRLF endings, or string literals containing
   semicolons, can cause incorrect tokenisation. The audit-4 `\r` fix
   (`Lex/DSL/ImplCalculus.lean:265-268`) addresses one case.
2. **Forbidden shapes (L010, L022)** are not parser-level rejects — they
   parse to `.bareSetBalance` / `.revokeKey`. The macro layer
   (`Lex/DSL/Law.lean:735-742`) is what emits the hard error. A direct caller
   of `parseImplCalculus` who doesn't run `forbiddenWithCodes` will silently
   accept these.
3. **Effect-kind classification for the *forbidden* shapes** has
   `revokeKey ↦ .authority` and `bareSetBalance ↦ .kernelImpl`
   (`Lex/DSL/ImplCalculus.lean:126-127`). Since these are rejected upstream
   it doesn't matter, but if a downstream tool reads `effectKind` first the
   forbidden statements get routed.
4. **`fun s =>` strip is overly greedy.** `splitOn "=>"` then takes the *rest*
   of the *first* element of `.tail?`. For `fun s => let x := a => b; body`
   the second `=>` is inside the body and the strip discards everything up
   to its position. Fortunately, lex-grammar bodies don't contain literal
   `=>` outside the outermost binder, but this is brittle.

### Property classification
- This file does not generate typeclass instances. It only classifies impl
  statements; the typeclass instances are emitted by the synthesizer in
  `Property.lean` and consumed by the deployment macro in `Deployment.lean`.

---

## `Lex/DSL/ImplLowering.lean` (197 lines)

### Imports
- `LegalKernel.Kernel`, `Lean.Elab.Term`. Reasonable.

### Macro definitions
- Declares syntax category `lex_calc_stmt` (`Lex/DSL/ImplLowering.lean:86`)
  and eight constructor syntaxes (`lexCalcFlow` … `lexCalcNop`).
- The `lex_do` macro (`Lex/DSL/ImplLowering.lean:134`) accepts exactly one
  `lex_calc_stmt` and lowers via `lowerStmt`.

### Lower-level vs higher-level abstraction split (`PreGrammar` vs
  `ImplLowering`)
- `PreGrammar.lean` is a **classifier**: walks Lean `Syntax`, emits a
  data-only AST (`PreNode`/`NatNode`), never emits Lean terms.
- `ImplCalculus.lean` is also a **classifier**: walks *text* (not Syntax),
  emits `ImplStmt` data.
- `ImplLowering.lean` is the **emitter**: takes `lex_calc_stmt` Syntax and
  emits Lean `Term` syntax (a function `State → State`). The lowering arm
  uses `setBalance`/`getBalance` directly (`Lex/DSL/ImplLowering.lean:140-176`).

### Generated declarations (per `lex_do <stmt>`)
- `flow r amt v from a to b` lowers to a 4-line let-block matching
  hand-written `Laws.transfer.apply_impl` exactly (`Lex/DSL/ImplLowering.lean:140-149`):
  `fromBal`, `s1`, `toBal` variable names match Phase-2.
- `mint r amt v to b` and `reward r amt v to b` BOTH lower to
  `setBalance s r b (getBalance s r b + v)` (definitionally identical at
  kernel level; `reward` is distinguished at the action layer only).
- `freeze_resource`, `register_key`, `register_identity` all lower to
  `let _ := <arg>; s` — kernel-level identity with the parameter bound only
  to elaborate the syntax.
- `nop` lowers to `fun s => s`.
- Unrecognised forms raise `Macro.throwErrorAt stmt ...`
  (`Lex/DSL/ImplLowering.lean:178-182`).

### Sharp points
1. **`lex_do` is single-statement only** in M2 per its declared syntax
   (`Lex/DSL/ImplLowering.lean:134`). Multi-statement composition is
   deferred to M3 (audit-6 removed a dead `composeStmts` helper, per the
   comment at `Lex/DSL/ImplLowering.lean:184-190`).
2. **Token leak.** Declaring `flow`, `mint`, `burn`, `reward`, `to`, `from`,
   `as`, `amt`, `freeze_resource`, `register_key`, `register_identity`, `nop`
   as syntax tokens via the eight `syntax (name := ...)` blocks
   (`Lex/DSL/ImplLowering.lean:88-118`) registers these as *global* Lean
   tokens. This is precisely what `Lex/DSL/Law.lean:82-89` warns about —
   `to`, `from`, `as`, `amt` as parameter names in hand-written laws would
   break parsing. As a result, `ImplLowering` is *not* imported by
   `Lex/DSL/Law.lean`; users must opt in per file.
3. **`mint`/`reward` lower identically.** Definitional equivalence is
   correct for kernel-level conservation theorems, but if a deployment ever
   wants the action layer to distinguish them, the kernel-level def alone
   cannot.
4. **`freeze_resource` / `register_*` bind arguments only to elaborate them**
   — they're noops on State. If the user passes a side-effecting term (which
   `State → State` doesn't admit anyway), the `let _ :=` discards it.

---

## `Lex/DSL/Events.lean` (181 lines)

### Imports
- `Lean.Elab.Command`, `Lean.Attributes`. Lean parts are unused
  syntactically (no Syntax matching), so `Lean.Elab.Command` is heavier
  than needed — could be reduced to `Lean.Attributes` only since the file
  only walks `String`.

### AST + tag attribute
- `EventStmt` inductive (`Lex/DSL/Events.lean:43-58`) with six constructors
  including a wholly-distinct `.empty` (for canonicalised empty form).
- `initialize lexEventCtorAttr` (`Lex/DSL/Events.lean:72-74`) registers
  `@[lex_event_ctor]`. No `Event` constructor in the kernel is tagged in
  this file — the 13 built-in `Event` constructors are mentioned in prose
  but their tagging happens in the kernel's `Events` module.

### Walker semantics (text-based, mirrors `ImplCalculus`)
- `stripEventsWrappers` (`Lex/DSL/Events.lean:109-113`): strips leading `do`
  only. Less aggressive than the impl walker (no `fun s =>` strip).
- `parseEventBlock` (`Lex/DSL/Events.lean:148-156`): three empty-form
  variants (`[]`, `pure ()`, `nothing`) all canonicalise to `[.empty]`.
- `parseEventStmt` (`Lex/DSL/Events.lean:129-145`): same pattern as
  `parseImplStmt` — passes full statement text as the first parameter, no
  field-level extraction.

### Sharp points
1. **L013/L014/L020 checks are not invoked.** The macro layer
   (`Lex/DSL/Law.lean:766-768`) parses the events block but then `pure ()`s
   without surfacing any L-codes. So the formatter helpers `L013Message`,
   `L014Message`, `L020EmitMessage` exist but are dead code at present.
   Documented as M2 deferred (`Lex/DSL/Law.lean:763-765`).
2. **`empty` constructor doubles as "block contains nothing" and "this stmt
   is empty"** (`Lex/DSL/Events.lean:131`). `parseEventBlock` returns
   `[.empty]` for an empty block — semantically odd but consistent if
   downstream consumers know to special-case it.
3. **String comparisons** (`stripped == "[]" || ... == "pure ()" || ... == "nothing"`)
   are byte-exact. Any whitespace variation (`"pure( )"`, `"pure()"`) is
   missed. The trim is applied but only ASCII-trim; non-ASCII whitespace
   slips past.

---

## `Lex/DSL/Shim.lean` (127 lines)

### Imports
- `Lex.DSL.ImplCalculus` only. Reasonable.

### Generated declarations
- No macros / no syntax declarations. This is a pure-function analysis
  library exporting `selfOnlyCheckImplStmts`, `SignedByAnalysis`,
  `L011Message`, `shimDefName`.

### Self-only static-analysis semantics (§9.3)
- `stmtReferencesSignedBy` (`Lex/DSL/Shim.lean:78-85`) checks whether the
  `signedBy` name appears as a *substring* of the statement's text, with
  whitespace boundary. Three patterns: `text.endsWith " signedBy"`,
  `text.startsWith "signedBy "`, or `text.splitOn " signedBy "` returns
  more than one piece (i.e., the substring with whitespace boundaries
  appears).
- `selfOnlyCheckStmt` (`Lex/DSL/Shim.lean:90-111`): dispatches per
  `ImplStmt` constructor.
  - `.bareSetBalance` is unconditionally rejected.
  - `.freezeResource`, `.letBind`, `.ifStmt`, `.forLoop` are admissible
    (host primitives or no-actor).
  - The rest check `stmtReferencesSignedBy`.

### Sharp points
1. **Substring-match is a conservative under-approximation.** A statement
   `flow r amt from alice to bob` where `signed_by alice` will pass, *but*
   `flow r amt from bob to alice` will also pass (alice is *somewhere* in
   the text). The check accepts shapes where the actor name is anywhere in
   the statement, not strictly in the position the policy demands.
   Documented self-deprecating note at `Lex/DSL/Shim.lean:58-63`.
2. **Substring boundary checks miss in-bracket usage.** A statement
   `flow r amt from f(alice) to bob` — alice surrounded by parens — fails
   `stmtReferencesSignedBy` (no whitespace boundary), reporting a false
   L011 violation.
3. **Comparison is case-sensitive.** A signer named `Alice` and a binding
   `alice` won't match.

---

## `Lex/DSL/Law.lean` (799 lines) — the central `lexlaw` command

### Imports
- `LegalKernel.Kernel`, `LegalKernel.DSL.Law`, `Lex.DSL.PreGrammar`,
  `Lex.DSL.ImplCalculus`, `Lex.DSL.Events`, `Lex.DSL.Shim`, `Lex.DSL.Property`,
  `Lex.Tools.Common`, `Lean.Elab.Command`, `Lean.Elab.Term`, `Lean.Data.Json`.
- **Notably absent**: `Lex.DSL.ImplLowering`. Comment at
  `Lex/DSL/Law.lean:82-89` documents this — `ImplLowering` registers
  `to`/`from`/`as`/`amt` as global tokens that would clash with parameter
  names like `(to : ActorId)` in hand-written laws. So the calculus-form
  `lex_impl := lex_do ...` is opt-in per file.

### Syntax surface
- `declare_syntax_cat lawClause` (`Lex/DSL/Law.lean:111`) plus 13
  `syntax (name := ...)` clause-variants covering `lex_id`, `lex_version`,
  `lex_action_index`, `lex_intent`, `lex_signed_by`, `lex_authorized_by`,
  `lex_params`, `lex_pre`, `lex_impl`, `lex_satisfies`, `lex_events`,
  `lex_proof`, `lex_registry_effect`.
- Top-level `lexlaw <name> where <clause>+` command syntax at
  `Lex/DSL/Law.lean:153`.

### Generated declarations (per `lexlaw <name>`)
1. **`def <id>_transition : Transition`** (parameterless or
   `def <id>_transition $binders : Transition`) — the `Law.mk pre impl`
   construction wrapped in `set_option linter.deprecated false in` to
   suppress the `Law.mk` deprecation. Emitted via `elabCommand txnCmd`
   at `Lex/DSL/Law.lean:676-695`.
2. **JSON sidecar** at `Lex/Inputs/<id>.json` containing the
   `LawDecl`-formatted metadata (`Lex/DSL/Law.lean:717-719`). Emission is
   gated on the transition def elaborating cleanly (no new errors); this
   honours §6.11 "A failing law produces no JSON file."

### Diagnostic / hardening checks
- `parseClause` (`Lex/DSL/Law.lean:272-359`): every clause that is
  expected at most once now hard-errors on duplicates (audit-6 retrofit).
  Diagnostic anchored at the offending clause via `throwErrorAt clause`.
- `validateRequiredClauses` (`Lex/DSL/Law.lean:365-384`): L001/L002/L009
  diagnostics for missing mandatory clauses.
- `parsePreExpr` invoked at `Lex/DSL/Law.lean:758-762` — emits L003 as a
  `logWarningAt` (not error).
- `parseImplCalculus` + `forbiddenWithCodes` at `Lex/DSL/Law.lean:733-742`
  — L010 / L022 are *errors* (via `logErrorAt`), not warnings.
- L011 (self_only) static analysis at `Lex/DSL/Law.lean:744-752`.
- `parsePropertyList` at `Lex/DSL/Law.lean:771-783` — emits L020 / L024 /
  L025 as errors.

### Decidability synthesis
- Indirect — the emitted `def <id>_transition := Law.mk pre impl` carries
  `[DecidablePred pre]` as an instance argument on `Law.mk`. So
  elaboration fails at the `lexlaw` command site if Lean cannot synthesise
  the `Decidable` instance for the user's `lex_pre`.
- The L003 walker is **purely informational** and runs alongside, not
  instead of, instance resolution.

### Param-spec extraction (`paramSpecsFromBinder` /
  `paramSpecsFromBinders`)
- Walks `bracketedBinder` syntax by `isOfKind` checks against the four
  Lean core binder kinds (`explicitBinder`, `implicitBinder`,
  `strictImplicitBinder`, `instBinder`). For each, extracts ident list
  (arg index 1), type (arg index 2 last child).
- Audit-5 disambiguates `_`-named anonymous instance binders by
  positional suffix (`_2`, `_3`, ...).

### Sharp points
1. **Massive surface; many failure modes.** The `parseClause` function
   handles 13 distinct clause kinds with bespoke per-clause duplicate
   detection. Any new clause added without the duplicate check repeats
   the audit-6 silent-shadowing bug.
2. **The L003 walker's diagnostic is anchored at the *law name* (`name.raw`),
   not at the offending sub-expression** (`Lex/DSL/Law.lean:761`). Per
   PreGrammar's design note this is the intended-but-imprecise behaviour;
   a user with three subterms outside the §7.2 grammar gets one warning
   that points at the law name.
3. **`renderSyntax stx := toString stx`** (`Lex/DSL/Law.lean:203`)
   produces a Lean source serialisation that *may differ from the user's
   original source text* for some Syntax shapes (e.g. parentheses can be
   added or removed, whitespace is collapsed). The JSON sidecar
   `preExpr`/`implBlock` fields therefore can differ byte-for-byte from
   what the user wrote, breaking naive grep-based audits. Compare with
   `Deployment.lean`'s `syntaxToSourceText` which prefers `Syntax.reprint`.
   The `lexlaw` command is inconsistent here.
4. **The transition-def elaboration's error counter** (`stBefore`/
   `stAfter` at `Lex/DSL/Law.lean:690-700`) reads `Lean.Elab.Command.State`
   and counts `.error` severities. This is correct in principle but
   couples the macro to the Command-monad's message log layout; a Lean
   version bump that changes message reporting could silently corrupt the
   "no new errors → write JSON" gate, producing a JSON file for a failed
   law.
5. **`normaliseSourceFile`** at `Lex/DSL/Law.lean:217-260` includes a
   nested `String.mkString` helper (since `String.ofList` is the
   canonical one; the comment in the `where` block acknowledges this).
   The `findSubstr` helper uses `partial def` indirectly through the
   outer `partial`, and the recursive `scan` uses `rec` inside
   `where` — non-terminating inputs are syntactically possible but in
   practice the input is bounded.
6. **`elabCommand claimCmd` inside a `try ... catch`** does not exist
   in `Lex/DSL/Law.lean` — that pattern is in `Deployment.lean`. Worth
   noting: `lexlaw` does NOT catch elaboration errors when emitting
   the transition def. A failure surfaces as a normal Lean error at the
   `lexlaw` source position, which is correct.
7. **`signedByClause` matches against `toString sb`** at
   `Lex/DSL/Law.lean:748` — `toString` of a `Name` produces a
   dotted-string like `"Lean.Name.mkSimple ...".`. For unqualified
   identifiers it's a single segment. The substring match in
   `Shim.stmtReferencesSignedBy` is therefore comparing dotted-text
   against impl-statement-text, which works for unqualified names but
   could go wrong for `«spaces and dots»`-style identifiers.

### Documentation drift
- The header comment block (`Lex/DSL/Law.lean:35-63`) accurately documents
  the `lex_*` keyword-prefix deviation from §6.1.
- Comment at `Lex/DSL/Law.lean:91-99` honestly flags the namespace/path
  mismatch (`Lex.DSL.Law` lives in module path `Lex/DSL/Law.lean` but
  populates namespace `LegalKernel.DSL`).

---

## `Lex/DSL/Property.lean` (662 lines)

### Imports
- `LegalKernel.Conservation`, `Lex.Tools.Common`, `Lean.Attributes`,
  `Lean.Elab.Command`. Reasonable; the synthesizer needs `Conservation`
  for the `IsConservative`/`IsMonotonic` typeclass references in
  docstrings/comments only (no actual Lean term emission yet — see
  sharp point 1).

### Property kinds + dispatchers
- `PropertyKind` inductive (`Lex/DSL/Property.lean:60-82`): seven v1 kinds
  + `userDefined`. `PropertyKind.ofString` maps strings to kinds.
- `ImplStmtKind` (`Lex/DSL/Property.lean:103-131`): the eight kernel-impl
  primitive kinds + `forLoop`/`ifStmt`/`letBind`/`bareTerm`.
- `SynthError` (`Lex/DSL/Property.lean:149-191`): ten error variants.
  Audit-3 split: `.resourceInFreezeSet` (was `.resourceNotInLocalSet` in
  freeze-preserving context), `.userDefinedNoOverride` (was
  `.unsupportedStatementKind .bareTerm`), `.emptySignedBy` (was a silent
  empty-string match).

### Generated declarations (synthesizers)
- `IsConservativeProof` / `IsMonotonicProof` inductive witness-chain types
  (`Lex/DSL/Property.lean:256-288`). Both carry per-statement-kind
  constructors.
- `synth_conservative` / `synth_monotonic` / `synth_local{_kindOnly}` /
  `synth_freeze_preserving{_kindOnly}` / `synth_nonce_advances` /
  `synth_registry_preserving` (`Lex/DSL/Property.lean:368-486`).
- `dispatchSynthesizer` / `dispatchWithOverrides`
  (`Lex/DSL/Property.lean:494-659`).

### Critical caveat
1. **The synthesizers emit only `String`-typed source snippets, NOT Lean
   `Term` values.** `SynthResult := Except SynthError String`. The
   "synthesised proof body" is a comment-form skeleton like
   `"rfl  /- IsConservativeProof.identity -/"` — *not* a real Lean term.
   The header comment at `Lex/DSL/Property.lean:35-44` correctly flags
   this as "M1 skeleton — M2 codegen pass replaces with the canonical
   hand-written shape". As of audit, **no actual typeclass instances
   are emitted by the synthesizer**; the kernel-built-in laws keep their
   hand-written instance bodies (`mint_isMonotonic` etc.) and the
   synthesizer is exercised structurally but never produces shipping
   Lean code. The dispatch graph is correct as far as the *Except* /
   *string* return goes, but a consumer expecting an emitted instance
   gets only a placeholder.

### Property classification
- `parsePropertyName` (`Lex/DSL/Property.lean:581-602`): rejects
  `local [*]` wildcards (L024), `conservative [r]` / `monotonic [r]`
  per-resource args (L025), and `userDefined` names not tagged
  `@[lex_property]` (L020).

### `@[lex_property]` attribute
- Registered at `Lex/DSL/Property.lean:529-531` via
  `Lean.registerTagAttribute`. `isLexPropertyTagged` is consumed by
  `parsePropertyName`.

### Sharp points
1. **`synth_local_kindOnly` admits every kernel-impl statement unconditionally**
   (`Lex/DSL/Property.lean:418-420`) because the resource pair is `(k, none)`.
   So `local [S]` claims on impl blocks classified by kind-only never
   reject. The kind-only variant is the one invoked by the macro
   (`dispatchSynthesizer` calls `synth_local_kindOnly`), so currently
   `local` claims are *always* accepted regardless of the actual `S` set.
2. **`synth_nonce_advances` rule** (`Lex/DSL/Property.lean:467-474`):
   compares `signedByName == actorName` as raw strings. The empty-signedBy
   guard is good; the `nonceActorMismatch` diagnostic is helpful. But
   `signedByName` comes from `toString (Name)` and `actorName` from
   `parsePropertyList`'s string — case/qualification mismatch is possible.
3. **`dispatchWithOverrides` matches an override on `claimNameRaw`**
   (`Lex/DSL/Property.lean:655`). This is the property name as a string,
   so an override like `lex_proof Conservative` will match if the user
   spelled the claim `Conservative` (capitalised), but the
   `PropertyKind.ofString` only recognises the lowercase forms — they
   diverge in case. Inconsistent spellings between `lex_satisfies` and
   `lex_proof` won't reliably pair.
4. **The `IsConservativeProof` cons-chain emitted string** is internally
   tagged with comments like
   `"by intro r' s hpre; <flow-step>; ..."` — placeholder for M2. If anyone
   ever cuts and pastes this snippet expecting a working tactic, they get
   `<flow-step>` as an unbound identifier.

### Decidability synthesis
- The property synthesizers don't directly drive `Decidable` instances.
  They feed instance bodies for `IsConservative`/`IsMonotonic`/etc.
  *typeclasses* that the deployment macro consumes via
  `MonotonicLawSet.cons` etc. Decidability of `pre` is enforced upstream
  by `Law.mk`.

---

## `Lex/DSL/Deployment.lean` (1184 lines)

### Imports
- Heavy: `LegalKernel.Kernel`, `LegalKernel.Conservation`, three
  `Authority/*` modules, two `Encoding/*` modules, `Runtime.Hash`,
  `Lex.Tools.Common`, two `Lean.Elab.*`. Reasonable for the breadth of
  things emitted (admissibility predicates, manifest hashes, law-set
  values).

### Data types
- Public record types `LawBinding`, `AuthorityBinding`, `InvariantClaim`,
  `Deployment`, `DeploymentDecl` (`Lex/DSL/Deployment.lean:158-299`).
- `Deployment` is the canonical record; `DeploymentDecl` is the
  parser-time intermediate exposing `manifestSourceBytes` for hashing.

### Macro / elaborator definitions
- Declares two syntax categories for binding entries
  (`authorityBindingEntry`, `lawBindingEntry`) and one for scopes
  (`invariantClaimScopeStx`) — `Lex/DSL/Deployment.lean:505-532`.
- Declares `deployClause` category + 8 clause variants + the top-level
  `deployment <ident> where <deployClause>+` command.
- `elab_rules : command` at `Lex/DSL/Deployment.lean:937-1182` drives the
  whole emission pipeline.

### Generated declarations (per `deployment <name>`)
1. **`def <name>_id : ByteArray`** — the 32-byte deployment ID
   (`Lex/DSL/Deployment.lean:975-982`). Validated to be 64 hex chars before
   emission.
2. **`def <name>_manifest_hash : ByteArray`** — `Runtime.hashStream` over
   the canonical CBE-encoded manifest AST (`Lex/DSL/Deployment.lean:984-996`).
3. **`def <name>_authority_policy : AuthorityPolicy`** — folds user
   bindings via `AuthorityPolicy.intersect` (`Lex/DSL/Deployment.lean:998-1034`).
   Empty bindings → `AuthorityPolicy.unrestricted`. Crucially, the user's
   policy `Syntax` is spliced directly (not via toString) — comment at
   `Lex/DSL/Deployment.lean:565-572` explicitly calls out the prior
   round-trip-via-toString defect.
4. **`def <name>_admissible : ExtendedState → SignedAction → Prop`** —
   `AdmissibleWith Verify <name>_authority_policy <name>_id`
   (`Lex/DSL/Deployment.lean:1036-1061`).
5. **`def <name>_deployment : Deployment`** — the full record bundling
   everything (`Lex/DSL/Deployment.lean:1063-1114`).
6. **`def <name>_<claim_kind>_<idx> : <LawSet>`** per invariant claim
   (`Lex/DSL/Deployment.lean:1116-1182`), synthesised via
   `synth_monotonic_law_set` / `_conservative_law_set` /
   `_freeze_preserving_law_set` calling
   `<LawSet>.cons` chains. Wraps `elabCommand claimCmd` in `try ... catch`
   so a missing typeclass instance surfaces as an L008 diagnostic naming
   the offending claim.

### Manifest-hash canonicalisation
- `encodeManifestHashInput` (`Lex/DSL/Deployment.lean:325-403`) sorts
  every list before encoding to make the hash order-insensitive. Audit-5
  replaces the prior `intercalate ","` law-names key with a
  structural lexicographic comparator (`lexicographicListCompare`,
  `Lex/DSL/Deployment.lean:362-370`), eliminating a `["foo,bar"]` /
  `["foo","bar"]` collision class under `qsort` instability.

### Decidability synthesis
- Not relevant here directly — decidability lives at the law level. The
  deployment macro emits typeclass-driven law-set values, not `Decidable`
  instances.

### Sharp points
1. **`resolveLawName`** (`Lex/DSL/Deployment.lean:611-636`) tries 8
   candidate `Name`s in order. The candidate list includes the
   lowercased version (`legalkernel.<lowercased>`), so a law spelled
   `Transfer` in the manifest will resolve against `legalkernel_transfer_transition`
   *or* `LegalKernel.Laws.transfer` depending on which arrives first in
   `env.contains`. The first-hit-wins semantics is fragile if the same
   law has both a hand-written and a Lex-emitted form (which is the case
   for the 17 kernel laws under LX-M2).
2. **`buildLawSetConsChain`** (`Lex/DSL/Deployment.lean:879-885`) wraps
   `lawTerms.reverse` and right-folds: `T.cons L₁ (T.cons L₂ ... T.empty)`.
   The reverse is important so the source list `[L₁, L₂, L₃]` produces
   `cons L₁ (cons L₂ (cons L₃ empty))` and not the reverse. Easy to
   misread.
3. **`decodeHexString`** (`Lex/DSL/Deployment.lean:446-460`) uses a
   `while` loop with `csA[idx]!`/`csA[idx + 1]!` partial indexing. The
   bounds check is `idx < cs.length` only — the second index `idx + 1`
   is implicitly guarded by the even-length check at line 448. Correct
   but subtle; a future refactor that touches the loop arithmetic could
   introduce out-of-bounds.
4. **`byteArrayToTermSyntax`** (`Lex/DSL/Deployment.lean:869-875`) emits
   `ByteArray.mk #[u8₁, u8₂, …]` syntax. For a 32-byte deployment ID
   this is a 32-element array literal — readable. For a much larger
   `ByteArray` it would inflate the emitted term substantially.
5. **`elabCommand claimCmd` wrapped in `try ... catch`**
   (`Lex/DSL/Deployment.lean:1177-1182`): catches *all* exceptions during
   claim elaboration and reframes them as L008 diagnostics. This is
   correct behaviour for "missing typeclass instance" but it also
   swallows malformed-syntax errors (which would otherwise carry better
   diagnostic positions). The `msg ← e.toMessageData.toString` rewriter
   preserves the original message text, but the position becomes
   `name.raw` instead of the synthesised body's internal position.
6. **`syntaxToSourceText`** (`Lex/DSL/Deployment.lean:668-671`) uses
   `Lean.Syntax.reprint` with fallback to `toString` — note the
   inconsistency with `lexlaw`'s `renderSyntax := toString` only.
   `Deployment`'s approach is the more reliable one.
7. **`parseDeployment` runs `parseDeployClause` twice** — once in the
   elaborator block (`Lex/DSL/Deployment.lean:954-955`) and once inside
   `parseDeployment` itself (`Lex/DSL/Deployment.lean:802-804`). Comment
   at `Lex/DSL/Deployment.lean:956-963` explicitly acknowledges the 2x
   cost and asserts the parser is side-effect-free. Verified: clauses
   are parsed by pattern-matching, no `IO`, no env mutation. Safe but
   wasteful at compile time.
8. **L008 is emitted for both "law unresolved" and "claim synthesis
   failed".** Two distinct failure modes share the L-code. A user
   debugging an L008 has to read the message text to disambiguate.

### Documentation drift
- The header advertises `[* @ {*}]` as the spec wildcard syntax
  (`Lex/DSL/Deployment.lean:85-90`), but the actual implementation uses
  `[all_laws]` (`Lex/DSL/Deployment.lean:529-532`) — explained in the
  doc comment lines 521-527 because `*` is a Lean multiplication
  operator. The §LX.33 docstring still says `[* @ {*}]` in spots, which
  may confuse readers who don't notice the explanation.

---

## Cross-cutting findings

### Hygiene / token-leak landscape

| Module                | Tokens registered globally                    | Imported transitively into hand-written law files? |
|-----------------------|------------------------------------------------|----------------------------------------------------|
| `LegalKernel/DSL/Law.lean`         | none                                          | yes (no problem)                                  |
| `LegalKernel/DSL/LawSyntax.lean`   | `pre`, `impl`                                 | **NO** — opt-in only                              |
| `Lex/DSL/ImplLowering.lean`        | `to`, `from`, `as`, `amt`, `flow`, `mint`, `burn`, `reward`, `nop`, `freeze_resource`, `register_key`, `register_identity` | **NO** — opt-in only                              |
| `Lex/DSL/Law.lean`                 | `lexlaw`, `lex_*` (13 keywords)                | yes (broadly imported)                            |
| `Lex/DSL/Deployment.lean`          | `deployment`, `deploy_*` (8 keywords), `all_laws` | yes (for files that use it)                      |
| `Lex/DSL/PreGrammar.lean`          | none                                          | yes (no problem)                                  |
| `Lex/DSL/ImplCalculus.lean`        | none                                          | yes (no problem)                                  |
| `Lex/DSL/Events.lean`              | none                                          | yes (no problem)                                  |
| `Lex/DSL/Shim.lean`                | none                                          | yes (no problem)                                  |
| `Lex/DSL/Property.lean`            | none                                          | yes (no problem)                                  |

Token leak is real but well-managed via the two opt-in escape hatches
(`LawSyntax`, `ImplLowering`). The `lex_` keyword prefix throughout
`Lex/DSL/Law.lean` is the conscious mitigation for the structure-field-token
collision discussed in headers of `LegalKernel/DSL/Law.lean:18-32` and
`Lex/DSL/Law.lean:35-63`.

### Decidability synthesis (summary)

- **No DSL module synthesises a `Decidable` instance.** All paths defer to
  `inferInstance` at the call site via `Law.mk`'s `[DecidablePred pre]`
  argument. The `parsePreExpr` walker is purely diagnostic (L003 warnings),
  not gating.
- This matches the Genesis Plan §13.6 step-2 discipline (a `pre` is
  admissible iff `inferInstance` discharges decidability). Any user law
  whose `pre` is not instance-resolvable fails at the `lexlaw` command site.

### Property classification (summary)

- The "typeclass instances generated" by the DSL are:
  - `_transition` def per `lexlaw` (a `Transition` value, not a typeclass
    instance per se).
  - `_<claim_kind>_<idx>` defs per `deployment` (values of type
    `MonotonicLawSet` / `ConservativeLawSet` / `FreezePreservingLawSet [S]`,
    constructed via `<LawSet>.cons` chains that demand
    `IsMonotonic`/`IsConservative`/`FreezePreserving S` instances be in
    scope for each law).
- Per-law `IsMonotonic`/`IsConservative`/`FreezePreserving` instances are
  hand-written in `LegalKernel/Laws/*.lean` and *not* synthesised by the
  property synthesizer (`Lex/DSL/Property.lean`); the synthesizer is a
  Diagnostic / Skeleton M1 placeholder for M2's codegen pass per the
  header (`Lex/DSL/Property.lean:35-44`).

### Lower-level vs higher-level abstraction split

- **PreGrammar vs ImplCalculus**: PreGrammar operates on Lean `Syntax`
  (walker is structurally recursive on `Syntax` quasi-quote shape).
  ImplCalculus operates on the *string-rendered* impl block (text-based
  tokeniser + per-statement keyword dispatch). The split is justified:
  pre-clauses must be in-grammar Props, so the structural shape matters;
  impl-clauses are characterised by which keyword they begin with, so the
  text-based view is adequate.
- **ImplCalculus vs ImplLowering**: ImplCalculus only *classifies* (no
  Lean terms emitted). ImplLowering is the actual emitter that produces
  `fun s => ...` Lean terms. ImplLowering is opt-in (token leak
  containment) while ImplCalculus is import-safe.
- **Property vs Law/Deployment**: Property is the *synthesizer library*;
  Law/Deployment are the *macro elaborators* that orchestrate parsing →
  validation → synthesis → emission. Clean separation.

### Sharp points (top items consolidated)

1. **`Lex/DSL/Property.lean` synthesizers emit placeholder strings, not
   Lean terms.** The "typeclass instances" the synthesizer is documented
   to produce are M1 skeletons; M2 codegen substitutes the canonical
   shapes. Anyone who reads the synthesizer dispatcher and expects real
   `Decidable`/`IsConservative`/`IsMonotonic` term emission will be
   surprised. (`Lex/DSL/Property.lean:35-44`, `Lex/DSL/Property.lean:294-319`)
2. **`synth_local_kindOnly` is the only path the macro invokes**, and it
   unconditionally accepts every kernel-impl statement because the
   resource pair is always `(kind, none)`. `local [S]` claims are
   effectively always-true under the current macro. (`Lex/DSL/Property.lean:418-420`,
   `Lex/DSL/Property.lean:505`)
3. **`renderSyntax := toString` in `Lex/DSL/Law.lean:203`** vs
   `syntaxToSourceText` (using `Syntax.reprint`) in `Lex/DSL/Deployment.lean:668-671`
   is an inconsistency: the law macro's JSON sidecar can drift from the
   user's source byte-for-byte while the deployment macro preserves it
   faithfully.
4. **L003 / L008 / L011 diagnostics anchor at `name.raw` (the `lexlaw` /
   `deployment` keyword), not at the offending sub-expression**, in
   most cases (`Lex/DSL/Law.lean:761`, `Lex/DSL/Deployment.lean:1180-1182`).
   User experience: editor red squiggle points at the law name, the actual
   bad clause is unhighlighted.
5. **`Shim.stmtReferencesSignedBy` is a substring check**, not a
   position-aware match. `flow r amt from a to alice` and
   `flow r amt from alice to a` both pass when `signed_by alice`. A
   well-crafted impl can satisfy L011 without actually being
   self-keyed. (`Lex/DSL/Shim.lean:78-85`)
6. **Token-leak via `ImplLowering` and `LawSyntax`** is real but
   contained. Any reviewer adding `import Lex.DSL.ImplLowering` to
   `Lex/DSL/Law.lean` would silently break hand-written laws that use
   `to`/`from`/`as`/`amt` as parameter names.
7. **`parseImplCalculus` strips `fun s => body` by splitting on `=>`**
   and taking everything after the first match. A body containing `=>`
   (e.g. nested lambdas) silently loses content. Documented impl-calculus
   bodies don't, but the parser is brittle. (`Lex/DSL/ImplCalculus.lean:218-223`)
8. **`Law.mk` is `@[deprecated]`** but used universally by both DSL
   variants. Every `lex_law` invocation wraps its emitted `def` in
   `set_option linter.deprecated false in` to compensate
   (`Lex/DSL/Law.lean:678,682`). Removing `Law.mk` in v2 will require a
   coordinated migration of every `lexlaw`-emitted def.

### Documentation drift (consolidated)

- `LegalKernel/DSL/Law.lean:71` references a non-existent `DSL/LexLaw.lean`;
  the actual file is `Lex/DSL/Law.lean`.
- `LegalKernel/DSL/LawSyntax.lean:55-58` refers to a `lex_law` macro;
  actual keyword is `lexlaw` (no underscore) per
  `Lex/DSL/Law.lean:153`.
- `Lex/DSL/Deployment.lean:85-90` quotes the spec wildcard `[* @ {*}]`
  while the implementation uses `[all_laws]` (explained at lines 521-527
  but not echoed at the example block).
- `Lex/DSL/PreGrammar.lean:28-30` claims the L003 diagnostic is anchored
  at the user's surface syntax; the actual anchor is `name.raw` in the
  invoking `lexlaw` block.

### Comparison: PreGrammar walker vs ImplCalculus walker

| Aspect              | PreGrammar (`parsePreExpr`) | ImplCalculus (`parseImplStmt`) |
|---------------------|----------------------------|--------------------------------|
| Input type          | `Lean.Syntax`              | `String`                       |
| Recursive structure | Quasi-quote pattern match  | Linear keyword dispatch        |
| Failure mode        | `.unknown String`          | `.bareTerm String`             |
| Diagnostic severity | warning (L003)             | error for forbidden shapes (L010, L022) |
| Forbidden shapes    | None (all soft)            | `bareSetBalance`, `revokeKey`  |
| Tagged-helper opt-in | `@[lex_pre]`              | `@[lex_impl]`                  |

The asymmetry — pre-grammar soft, impl-calculus hard for forbidden — is
intentional: a non-decidable `pre` fails downstream via `inferInstance`
anyway, whereas a `bareSetBalance` would silently bypass the calculus
discipline if not hard-rejected.

---

## Summary

The DSL is two-tier: a single-function combinator base layer
(`LegalKernel.DSL.Law.mk`) and a much larger Lex extension that wraps it
in a metadata-rich `lexlaw` command + a top-level `deployment` command
that orchestrates law-set values and admissibility predicates. The split
between `PreGrammar.lean` (Syntax-tree walker for `pre`-clauses, soft
diagnostics) and `ImplCalculus.lean` + `ImplLowering.lean` (text-based
classifier + opt-in Lean-term emitter for `impl`-clauses) is clean and
deliberate, with token-leak containment achieved by *not* importing
`ImplLowering` into `Law.lean`. The most notable sharp points are
(a) the property synthesizers in `Property.lean` emit placeholder strings
rather than real Lean terms — they're M1 skeletons documented as such;
(b) `synth_local_kindOnly` is the dispatcher-invoked variant and is a
no-op gate for `local [S]` claims; (c) `Lex/DSL/Law.lean`'s
`renderSyntax := toString` produces source serialisations that may drift
byte-for-byte from the user's input, inconsistent with
`Deployment.lean`'s reprint-based approach; (d) `Shim.lean`'s self-only
analysis is a substring match with no position awareness.
