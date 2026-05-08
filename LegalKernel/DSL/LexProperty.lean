/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.DSL.LexProperty — the property synthesizer library.

LX.12 / LX.13 / LX.14 / LX.15 / LX.16 of
`docs/lex_implementation_plan.md`.

Exports:

  * `inductive PropertyClaim` — the seven v1 property names
    (`conservative`, `monotonic`, `local`, `freeze_preserving`,
    `nonce_advances`, `registry_preserving`) plus the user-defined
    escape hatch via `proof <P>` overrides.
  * `inductive ImplStmtKind` — the kernel-impl stmtsulus
    primitives the synthesizers dispatch on (`flow`, `mint`,
    `burn`, `reward`, `freeze_resource`, `register_key`,
    `register_identity`, `for`, `if`, `let`, `bareTerm`).
  * `inductive SynthError` — the per-synthesizer failure modes
    (mint-non-conservative, burn-non-monotonic, fold-of-flow,
    bare-term-opaque, etc.).
  * `def synth_*` — six synthesizers, one per property name.
    Each returns either a Lean `Term`-typed instance body or a
    `SynthError`.

The synthesizers are *deliberately conservative* (per design-doc
§6.4.4): they reject `for`-loops, bare terms, and any
non-structural shape, falling back to `proof` overrides.  M1's
synthesizer library is a skeleton — the dispatch table and per-
property entry points are correct, but the emitted instance
bodies are placeholder stubs that the M2 codegen pass will
replace with the canonical hand-written shapes (per
`docs/lex_implementation_plan.md` §10.4).

For M1 acceptance, the example Lex-only law uses
`lex_satisfies := []` — no synthesis is triggered.  The
synthesizers are exercised in M2 when the kernel-built-in laws
are re-expressed in Lex.
-/

import LegalKernel.Conservation
import LegalKernel.Authority.SignedAction
import Tools.LexCommon

namespace LegalKernel.DSL.Lex

/-! ## Property claim kinds (§10.1) -/

/-- The v1 property names admissible inside a `lex_satisfies`
    block.  User-defined property names go through the
    `userDefined` constructor; their discharge is via a
    `lex_proof <P> := …` override (the synthesizer is bypassed). -/
inductive PropertyKind where
  /-- `conservative` — claims `IsConservative t`. -/
  | conservative
  /-- `monotonic` — claims `IsMonotonic t`. -/
  | monotonic
  /-- `local [{r₁,…,rₙ}]` — claims `LocalTo {r₁,…,rₙ} t`. -/
  | localTo
  /-- `freeze_preserving [{r₁,…,rₙ}]` — claims
      `FreezePreserving {r₁,…,rₙ} t`. -/
  | freezePreserving
  /-- `nonce_advances [a]` — claims the signer's nonce is
      advanced.  Structurally satisfied under `signed_by` so
      this synthesizer succeeds whenever the law has a valid
      `signed_by` clause; the property's witness is an `Iff`
      with `expectsNonce_after_apply_admissible`. -/
  | nonceAdvances
  /-- `registry_preserving` — claims the action's authority-
      layer effect on `KeyRegistry` is identity. -/
  | registryPreserving
  /-- User-defined property name; discharged via a
      `lex_proof <P> := …` override. -/
  | userDefined (name : String)
  deriving Repr, DecidableEq, Inhabited

/-- Parse a property name string into a `PropertyKind`.  Unknown
    names default to `userDefined name`, leaving discharge to
    the override path. -/
def PropertyKind.ofString (name : String) : PropertyKind :=
  match name with
  | "conservative"        => .conservative
  | "monotonic"           => .monotonic
  | "local"               => .localTo
  | "freeze_preserving"   => .freezePreserving
  | "nonce_advances"      => .nonceAdvances
  | "registry_preserving" => .registryPreserving
  | other                 => .userDefined other

/-! ## Impl-stmtsulus statement kinds (§8.1) -/

/-- The kernel-impl stmtsulus primitives the synthesizers
    dispatch on.  M1 lifts the design-doc §6.2 primitive set
    verbatim — every concrete `lex_impl` block can be classified
    by walking its statement list and tagging each with a kind. -/
inductive ImplStmtKind where
  /-- `flow r amt from a to b` — the post-debit re-read pattern
      (§4.11 self-transfer fix). -/
  | flow
  /-- `mint r amt to b` — additive supply increase. -/
  | mint
  /-- `burn r amt from a` — Nat-truncated supply decrease. -/
  | burn
  /-- `reward r amt to b` — definitionally equal to `mint` at
      the kernel level; distinguished at the `Action` layer. -/
  | reward
  /-- `freeze_resource r` — kernel-level identity. -/
  | freezeResource
  /-- `register_key a as k` — authority-layer registry update. -/
  | registerKey
  /-- `register_identity a as k` — first-time-registration
      analogue of `register_key` (signed by the bridge). -/
  | registerIdentity
  /-- `for x in <list>: <body>` — bounded-iteration host
      primitive. -/
  | forLoop
  /-- `if <pred> then <stmt₁> else <stmt₂>` — conditional host
      primitive. -/
  | ifStmt
  /-- `let x := e` — local binding. -/
  | letBind
  /-- `<bare term : State → State>` — escape hatch (v1 only). -/
  | bareTerm
  deriving Repr, DecidableEq, Inhabited

/-! ## Synthesizer errors (L004 family) -/

/-- A synthesizer's failure cause.  Mapped to diagnostic L004
    by the dispatcher; the cause string is included in the
    diagnostic's hint to help the author fix the problem. -/
inductive SynthError where
  /-- The statement is `mint`/`burn`/`reward` and the property
      is `conservative`. -/
  | nonConservativeStmt
  /-- The statement is `burn` and the property is `monotonic`. -/
  | burnNotMonotonic
  /-- The synthesizer doesn't handle fold-of-flow shapes; the
      author must supply a `lex_proof <P> := …` override. -/
  | foldOfFlow
  /-- The statement is `<bare term>` (v1 escape hatch); the
      synthesizer cannot reason about arbitrary `State → State`
      functions. -/
  | bareTermOpaque
  /-- A statement's resource is not in the `local [{r₁,…}]` set. -/
  | resourceNotInLocalSet (resource : String)
  /-- The statement is `register_key`/`register_identity` and
      the property is `registry_preserving`. -/
  | mutatesRegistry
  /-- The synthesizer doesn't recognise the statement's kind
      (e.g. `if`/`let` in M1 — host primitives are deferred). -/
  | unsupportedStatementKind (kind : ImplStmtKind)
  /-- The `nonce_advances [actor]` claim references an actor
      different from the law's `lex_signed_by`.  The nonce-
      advance is structural under `lex_signed_by`, so the actor
      name must match. -/
  | nonceActorMismatch (claimed : String) (signedBy : String)
  deriving Repr, Inhabited

/-- Format a synthesizer error as a human-readable diagnostic
    hint string (used as the L004 message body). -/
def SynthError.toString : SynthError → String
  | .nonConservativeStmt =>
    "structural induction failed at a non-conservative statement (`mint` / `burn` / `reward`)"
  | .burnNotMonotonic =>
    "structural induction failed: `burn` is non-monotonic by design"
  | .foldOfFlow =>
    "the synthesizer does not handle `for`-loop bodies in v1; supply a `lex_proof <P> := …` override"
  | .bareTermOpaque =>
    "the synthesizer cannot reason about a bare-term escape hatch; supply a `lex_proof <P> := …` override"
  | .resourceNotInLocalSet r =>
    s!"resource `{r}` is touched by the impl but not declared in the `local` set"
  | .mutatesRegistry =>
    "the impl mutates the registry (via `register_key`/`register_identity`); `registry_preserving` cannot hold"
  | .unsupportedStatementKind k =>
    s!"the synthesizer does not handle statement kind `{repr k}` in v1; supply a `lex_proof <P> := …` override"
  | .nonceActorMismatch claimed signedBy =>
    s!"`nonce_advances [{claimed}]` does not match `lex_signed_by {signedBy}`; the nonce-advance is structural under `lex_signed_by`, so the actor names must agree"

/-- The synthesizer's result: either an emitted Lean term
    (placeholder for the instance body) or an error. -/
abbrev SynthResult := Except SynthError String

/-! ## Per-property synthesizers (LX.13 / LX.14 / LX.15)

The M1 synthesizers are *skeleton-form*: they walk the
`ImplStmtKind` list and dispatch per-statement, but the emitted
instance body is a placeholder string that the M2 codegen pass
substitutes with a canonical hand-written shape.  The dispatch
logic itself is the load-bearing piece — the M2 substitution
preserves it exactly. -/

/-- `synth_conservative` — succeeds iff every statement's kind
    is conservative (`flow` / `freeze_resource` / `register_key` /
    `let`); fails on `mint` / `burn` / `reward` / `for` /
    `bareTerm`.  `if` is handled by recursing into both branches
    (caller's responsibility); v1 short-circuits and treats `if`
    as `unsupportedStatementKind`. -/
def synth_conservative : List ImplStmtKind → SynthResult
  | [] => .ok "/- synthesizer: identity (empty stmtsulus) -/"
  | k :: rest =>
    match k with
    | .flow | .freezeResource | .registerKey | .registerIdentity | .letBind =>
      synth_conservative rest
    | .mint | .burn | .reward => .error .nonConservativeStmt
    | .bareTerm                => .error .bareTermOpaque
    | .forLoop                 => .error .foldOfFlow
    | other                    => .error (.unsupportedStatementKind other)

/-- `synth_monotonic` — succeeds on `flow` / `mint` / `reward` /
    `freeze_resource` / `register_key`; fails on `burn` /
    `for` / `bareTerm`. -/
def synth_monotonic : List ImplStmtKind → SynthResult
  | [] => .ok "/- synthesizer: identity (empty stmtsulus) -/"
  | k :: rest =>
    match k with
    | .flow | .mint | .reward | .freezeResource | .registerKey
    | .registerIdentity | .letBind =>
      synth_monotonic rest
    | .burn      => .error .burnNotMonotonic
    | .bareTerm  => .error .bareTermOpaque
    | .forLoop   => .error .foldOfFlow
    | other      => .error (.unsupportedStatementKind other)

/-- `synth_local S stmts` — succeeds iff every kernel-impl
    statement's resource is in `S`.  M1's skeleton form treats
    every kernel-impl statement uniformly (by kind); the per-
    statement resource check lives in M2 when impl statements
    carry their resource arg. -/
def synth_local (_S : List String) :
    List ImplStmtKind → SynthResult
  | [] => .ok "/- synthesizer: identity (empty local set) -/"
  | k :: rest =>
    match k with
    | .flow | .mint | .burn | .reward | .freezeResource
    | .registerKey | .registerIdentity | .letBind =>
      -- M2 will check `s.resource ∈ S` per statement; M1 admits
      -- every kernel-impl statement structurally.
      synth_local _S rest
    | .bareTerm  => .error .bareTermOpaque
    | .forLoop   => .error .foldOfFlow
    | other      => .error (.unsupportedStatementKind other)

/-- `synth_freeze_preserving S stmts` — succeeds iff every
    kernel-impl statement's resource is *outside* the freeze
    set `S`.  M1's skeleton form treats every kernel-impl
    statement uniformly. -/
def synth_freeze_preserving (_S : List String) :
    List ImplStmtKind → SynthResult
  | [] => .ok "/- synthesizer: identity (empty freeze set) -/"
  | k :: rest =>
    match k with
    | .flow | .mint | .burn | .reward | .freezeResource
    | .registerKey | .registerIdentity | .letBind =>
      synth_freeze_preserving _S rest
    | .bareTerm  => .error .bareTermOpaque
    | .forLoop   => .error .foldOfFlow
    | other      => .error (.unsupportedStatementKind other)

/-- `synth_nonce_advances actorName` — succeeds iff the law's
    `lex_signed_by` actor matches `actorName`.  Structurally
    correct under `lex_signed_by`: the nonce-advance is implicit
    in `apply_admissible_with`'s body. -/
def synth_nonce_advances (signedByName : String) (actorName : String) :
    SynthResult :=
  if signedByName == actorName then
    .ok s!"/- synthesizer: nonce_advances [{actorName}] under signed_by {signedByName} -/"
  else
    .error (.nonceActorMismatch actorName signedByName)

/-- `synth_registry_preserving` — succeeds iff the impl
    contains no `register_key` / `register_identity` statement.
    Returns `mutatesRegistry` on failure. -/
def synth_registry_preserving : List ImplStmtKind → SynthResult
  | [] => .ok "/- synthesizer: identity (no registry mutation) -/"
  | k :: rest =>
    match k with
    | .registerKey | .registerIdentity => .error .mutatesRegistry
    | .bareTerm                        => .error .bareTermOpaque
    | .forLoop                         => .error .foldOfFlow
    | _                                => synth_registry_preserving rest

/-! ## Synthesizer dispatcher (§10.13) -/

/-- The dispatcher: given a `PropertyKind` and the law's
    impl-calculus statement list, dispatch to the appropriate
    synthesizer.  Returns the emitted instance body string, or a
    `SynthError`. -/
def dispatchSynthesizer
    (claim : PropertyKind)
    (signedByName : String)
    (stmts : List ImplStmtKind)
    (localSet : List String := [])
    (freezeSet : List String := [])
    (nonceActor : String := "") :
    SynthResult :=
  match claim with
  | .conservative        => synth_conservative stmts
  | .monotonic           => synth_monotonic stmts
  | .localTo             => synth_local localSet stmts
  | .freezePreserving    => synth_freeze_preserving freezeSet stmts
  | .nonceAdvances       => synth_nonce_advances signedByName nonceActor
  | .registryPreserving  => synth_registry_preserving stmts
  | .userDefined _    =>
    .error (.unsupportedStatementKind .bareTerm)
    -- M2 routes user-defined property names to the override.

end LegalKernel.DSL.Lex
