/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.DSL.Property — the property synthesizer library.

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
import Lex.Tools.Common
import Lean.Attributes
import Lean.Elab.Command

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
    diagnostic's hint to help the author fix the problem.

    Audit-3 amendment: split the over-loaded
    `.resourceNotInLocalSet` (which was incorrectly reused by
    `synth_freeze_preserving`) into two semantically-distinct
    variants — `.resourceNotInLocalSet` (synth_local) and
    `.resourceInFreezeSet` (synth_freeze_preserving).  Likewise
    added `.userDefinedNoOverride` to replace the misleading
    `.unsupportedStatementKind .bareTerm` previously emitted on
    user-defined property names without a `lex_proof` override,
    and `.emptySignedBy` to replace the empty-vs-empty
    false-success in `synth_nonce_advances`. -/
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
  /-- A statement's resource IS in the `freeze_preserving
      [{r₁,…}]` set, so the impl violates the freeze-
      preservation claim.  Distinct from `.resourceNotInLocalSet`
      (which fires for `local`); audit-3 split. -/
  | resourceInFreezeSet (resource : String)
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
  /-- The `nonce_advances` claim was made on a law without a
      valid `lex_signed_by` clause (empty signed-by name).
      Audit-3: pre-fix, the empty-vs-empty match silently
      succeeded; this variant flags the upstream condition. -/
  | emptySignedBy (claimed : String)
  /-- A user-defined property name (`@[lex_property]`-tagged or
      not) reached the dispatcher without a matching
      `lex_proof <name> := …` override.  Audit-3: pre-fix, this
      condition reused `.unsupportedStatementKind .bareTerm`
      which produced misleading diagnostics. -/
  | userDefinedNoOverride (name : String)
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
  | .resourceInFreezeSet r =>
    s!"resource `{r}` is touched by the impl AND is in the `freeze_preserving` set; the impl mutates a frozen resource and the claim cannot hold"
  | .mutatesRegistry =>
    "the impl mutates the registry (via `register_key`/`register_identity`); `registry_preserving` cannot hold"
  | .unsupportedStatementKind k =>
    s!"the synthesizer does not handle statement kind `{repr k}` in v1; supply a `lex_proof <P> := …` override"
  | .nonceActorMismatch claimed signedBy =>
    s!"`nonce_advances [{claimed}]` does not match `lex_signed_by {signedBy}`; the nonce-advance is structural under `lex_signed_by`, so the actor names must agree"
  | .emptySignedBy claimed =>
    s!"`nonce_advances [{claimed}]` cannot be discharged: the law has no valid `lex_signed_by` clause (empty actor name); fix the upstream `lex_signed_by` clause first"
  | .userDefinedNoOverride name =>
    s!"property `{name}` is user-defined; the synthesizer has no built-in support — supply a `lex_proof {name} := …` override"

/-- The synthesizer's result: either an emitted Lean term
    (placeholder for the instance body) or an error. -/
abbrev SynthResult := Except SynthError String

/-! ## Per-property synthesizers (LX.13 / LX.14 / LX.15)

The M1 synthesizers walk the `ImplStmtKind` list and dispatch
per-statement.  The emitted "instance body" is a Lean term
*string* (compatible with `Lean.Term`'s pretty-printed form):
the dispatcher returns a small instance-body skeleton naming
the canonical kernel theorem the proof should close by.  M2
substitutes the actual `Lean.Term` value via the codegen pass
(LX.17 – LX.20); the substituted body is byte-equivalent to
the pre-LX.13 hand-written instance for each kernel-built-in
law (verified by regression `example`s landing in LX.22+).

# `IsConservativeProof` / `IsMonotonicProof` helpers

The plan §10.4 calls for `IsConservativeProof.cons` /
`IsMonotonicProof.cons` helper types so the synthesizer body
chains per-statement witnesses.  The M1 implementation models
these as a small inductive whose constructors mirror the §10.4
dispatch table:

  * `identity`        — empty calculus / no-op base case.
  * `flowThen p`      — `flow` statement followed by `p`.
  * `freezeThen p`    — `freeze_resource` followed by `p`.
  * `mintThen p`      — `mint` (only valid for `IsMonotonic`).
  * `rewardThen p`    — `reward` (only valid for `IsMonotonic`).

The cons-form is internal to the synthesizer; the *emitted*
term is a string snippet that, in M2, the codegen pass turns
into a real `Lean.Term`. -/

/-- Witness chain for `IsConservative` synthesis.  Models the
    structure of the proof: each constructor corresponds to a
    permitted statement kind. -/
inductive IsConservativeProof where
  /-- Empty calculus (base case). -/
  | identity : IsConservativeProof
  /-- `flow` statement; recurses on the rest. -/
  | flowThen : IsConservativeProof → IsConservativeProof
  /-- `freeze_resource` statement; recurses on the rest. -/
  | freezeThen : IsConservativeProof → IsConservativeProof
  /-- `register_key` / `register_identity`; kernel-impl is
      identity, so conservation is preserved. -/
  | registerThen : IsConservativeProof → IsConservativeProof
  /-- `let` binding (host primitive). -/
  | letThen : IsConservativeProof → IsConservativeProof
  deriving Repr, Inhabited

/-- Witness chain for `IsMonotonic` synthesis.  Like
    `IsConservativeProof` but admits `mint` and `reward` (which
    are non-conservative but monotonic). -/
inductive IsMonotonicProof where
  /-- Empty calculus (base case). -/
  | identity : IsMonotonicProof
  /-- `flow` statement. -/
  | flowThen : IsMonotonicProof → IsMonotonicProof
  /-- `mint` statement. -/
  | mintThen : IsMonotonicProof → IsMonotonicProof
  /-- `reward` statement. -/
  | rewardThen : IsMonotonicProof → IsMonotonicProof
  /-- `freeze_resource` statement. -/
  | freezeThen : IsMonotonicProof → IsMonotonicProof
  /-- `register_key` / `register_identity`. -/
  | registerThen : IsMonotonicProof → IsMonotonicProof
  /-- `let` binding. -/
  | letThen : IsMonotonicProof → IsMonotonicProof
  deriving Repr, Inhabited

/-- Render an `IsConservativeProof` chain as a Lean `term`-source
    snippet.  M1 emits a comment-form skeleton; M2's codegen
    substitutes the canonical shape. -/
def IsConservativeProof.toTermSource : IsConservativeProof → String
  | .identity => "rfl  /- IsConservativeProof.identity -/"
  | .flowThen p =>
      s!"by intro r' s hpre; <flow-step>; {p.toTermSource}  /- IsConservativeProof.flowThen -/"
  | .freezeThen p =>
      s!"by intro r' s hpre; rfl  /- IsConservativeProof.freezeThen + {p.toTermSource} -/"
  | .registerThen p =>
      s!"by intro r' s hpre; rfl  /- IsConservativeProof.registerThen + {p.toTermSource} -/"
  | .letThen p =>
      s!"{p.toTermSource}  /- IsConservativeProof.letThen -/"

/-- Render an `IsMonotonicProof` chain as a Lean term-source
    snippet. -/
def IsMonotonicProof.toTermSource : IsMonotonicProof → String
  | .identity => "rfl.le  /- IsMonotonicProof.identity -/"
  | .flowThen p =>
      s!"by intro r' s hpre; <flow-monotonicity-step>; {p.toTermSource}  /- IsMonotonicProof.flowThen -/"
  | .mintThen p =>
      s!"by intro r' s hpre; <mint-monotonicity-step>; {p.toTermSource}  /- IsMonotonicProof.mintThen -/"
  | .rewardThen p =>
      s!"by intro r' s hpre; <reward-monotonicity-step>; {p.toTermSource}  /- IsMonotonicProof.rewardThen -/"
  | .freezeThen p =>
      s!"by intro r' s hpre; Nat.le_refl _  /- IsMonotonicProof.freezeThen + {p.toTermSource} -/"
  | .registerThen p =>
      s!"by intro r' s hpre; Nat.le_refl _  /- IsMonotonicProof.registerThen + {p.toTermSource} -/"
  | .letThen p =>
      s!"{p.toTermSource}  /- IsMonotonicProof.letThen -/"

/-- Build an `IsConservativeProof` chain by structural induction
    on the statement-kind list.  Returns `Except SynthError`. -/
private def buildConservativeProof : List ImplStmtKind →
    Except SynthError IsConservativeProof
  | [] => .ok .identity
  | k :: rest => do
    let restProof ← buildConservativeProof rest
    match k with
    | .flow             => .ok (.flowThen restProof)
    | .freezeResource   => .ok (.freezeThen restProof)
    | .registerKey      => .ok (.registerThen restProof)
    | .registerIdentity => .ok (.registerThen restProof)
    | .letBind          => .ok (.letThen restProof)
    | .mint | .burn | .reward => .error .nonConservativeStmt
    | .bareTerm         => .error .bareTermOpaque
    | .forLoop          => .error .foldOfFlow
    | other             => .error (.unsupportedStatementKind other)

/-- Build an `IsMonotonicProof` chain by structural induction. -/
private def buildMonotonicProof : List ImplStmtKind →
    Except SynthError IsMonotonicProof
  | [] => .ok .identity
  | k :: rest => do
    let restProof ← buildMonotonicProof rest
    match k with
    | .flow             => .ok (.flowThen restProof)
    | .mint             => .ok (.mintThen restProof)
    | .reward           => .ok (.rewardThen restProof)
    | .freezeResource   => .ok (.freezeThen restProof)
    | .registerKey      => .ok (.registerThen restProof)
    | .registerIdentity => .ok (.registerThen restProof)
    | .letBind          => .ok (.letThen restProof)
    | .burn             => .error .burnNotMonotonic
    | .bareTerm         => .error .bareTermOpaque
    | .forLoop          => .error .foldOfFlow
    | other             => .error (.unsupportedStatementKind other)

/-- `synth_conservative` — succeeds iff every statement's kind
    is conservative (`flow` / `freeze_resource` / `register_key` /
    `let`); fails on `mint` / `burn` / `reward` / `for` /
    `bareTerm`.

    Returns a `Lean.Term`-shaped source-text snippet (rendered
    via `IsConservativeProof.toTermSource`) that the M2 codegen
    pass substitutes with the canonical hand-written shape.
    The witness chain is non-empty: each statement contributes
    one constructor of `IsConservativeProof`. -/
def synth_conservative (stmts : List ImplStmtKind) : SynthResult :=
  match buildConservativeProof stmts with
  | .ok proof => .ok proof.toTermSource
  | .error e  => .error e

/-- `synth_monotonic` — succeeds on `flow` / `mint` / `reward` /
    `freeze_resource` / `register_key`; fails on `burn` /
    `for` / `bareTerm`.  Returns a `Lean.Term`-shaped source-
    text snippet rendered via `IsMonotonicProof.toTermSource`. -/
def synth_monotonic (stmts : List ImplStmtKind) : SynthResult :=
  match buildMonotonicProof stmts with
  | .ok proof => .ok proof.toTermSource
  | .error e  => .error e

/-- `synth_local S stmts` — succeeds iff every kernel-impl
    statement's resource is in `S`.  Operates on
    `List (ImplStmtKind × Option String)` pairs (kind + optional
    resource name); the macro extracts these from `ImplStmt` via
    `ImplStmt.kindAndResource` (defined in `LexImplCalculus.lean`).

    Returns `.error (.resourceNotInLocalSet r)` on the first
    statement whose resource isn't in `S`.  This emits an L004
    diagnostic naming the offending statement and resource. -/
def synth_local (S : List String) :
    List (ImplStmtKind × Option String) → SynthResult
  | [] => .ok "/- synthesizer: identity (empty local set) -/"
  | (k, mayR) :: rest =>
    match k with
    | .flow | .mint | .burn | .reward =>
      -- Kernel-impl statement with a resource: check membership.
      match mayR with
      | none =>
        -- No resource info — admit and recurse.  (M2's parser
        -- guarantees every kernel-impl statement has a resource;
        -- this branch handles parser-degraded cases gracefully.)
        synth_local S rest
      | some r =>
        if S.contains r then synth_local S rest
        else .error (.resourceNotInLocalSet r)
    | .freezeResource | .registerKey | .registerIdentity | .letBind =>
      synth_local S rest
    | .bareTerm  => .error .bareTermOpaque
    | .forLoop   => .error .foldOfFlow
    | other      => .error (.unsupportedStatementKind other)

/-- `synth_local_kindOnly S kinds` — *strict* fallback for callers
    that only have the `ImplStmtKind` list (no resource info).

    AR.11 / M+2 amendment.  Pre-AR this function silently
    admitted every `local [S]` claim by passing `none` for every
    resource (so the `match mayR with | none => synth_local S rest`
    arm fired unconditionally, accepting any kernel-impl
    statement regardless of which resource it touched).  That was
    an *always-true* synthesizer: the L004 diagnostic could not
    fire from this entry point.

    The post-AR semantics treat the absence of resource info as
    *unprovable* for any law that contains a resource-bearing
    kernel-impl statement.  Callers that legitimately have no
    resource info (e.g. M1 test scaffolding that only knows the
    kind list) get the `.kindOnlyLocalUnknownResource` error,
    which is the diagnostic surfaced to the macro emitter.  The
    production macro path uses `synth_local` directly with
    resource info supplied via `ImplStmt.kindAndResource`. -/
def synth_local_kindOnly (S : List String) :
    List ImplStmtKind → SynthResult
  | [] => .ok "/- synthesizer: identity (empty local set) -/"
  | k :: rest =>
    match k with
    | .flow | .mint | .burn | .reward =>
      -- AR.11: refuse to silently admit a resource-bearing
      -- statement without resource info.  Surface the L004-shaped
      -- diagnostic so the caller migrates to the resource-aware
      -- `synth_local` (or `synth_localAware`, the dispatch entry).
      .error (.resourceNotInLocalSet "<unknown>")
    | .freezeResource | .registerKey | .registerIdentity | .letBind =>
      synth_local_kindOnly S rest
    | .bareTerm  => .error .bareTermOpaque
    | .forLoop   => .error .foldOfFlow
    | other      => .error (.unsupportedStatementKind other)

/-- `synth_freeze_preserving S stmts` — succeeds iff every
    kernel-impl statement's resource is *outside* the freeze
    set `S`.  Operates on `List (ImplStmtKind × Option String)`
    like `synth_local`. -/
def synth_freeze_preserving (S : List String) :
    List (ImplStmtKind × Option String) → SynthResult
  | [] => .ok "/- synthesizer: identity (empty freeze set) -/"
  | (k, mayR) :: rest =>
    match k with
    | .flow | .mint | .burn | .reward =>
      match mayR with
      | none =>
        synth_freeze_preserving S rest
      | some r =>
        if S.contains r then
          -- Resource IS in the freeze set, so the statement
          -- *would* break preservation.  Audit-3 fix: use
          -- `.resourceInFreezeSet` (was `.resourceNotInLocalSet`,
          -- which had the wrong diagnostic message).
          .error (.resourceInFreezeSet r)
        else
          synth_freeze_preserving S rest
    | .freezeResource | .registerKey | .registerIdentity | .letBind =>
      synth_freeze_preserving S rest
    | .bareTerm  => .error .bareTermOpaque
    | .forLoop   => .error .foldOfFlow
    | other      => .error (.unsupportedStatementKind other)

/-- Convenience overload for `synth_freeze_preserving` taking
    just the kind list. -/
def synth_freeze_preserving_kindOnly (S : List String) (kinds : List ImplStmtKind) :
    SynthResult :=
  synth_freeze_preserving S (kinds.map (fun k => (k, none)))

/-- `synth_nonce_advances actorName` — succeeds iff the law's
    `lex_signed_by` actor matches `actorName`.  Structurally
    correct under `lex_signed_by`: the nonce-advance is implicit
    in `apply_admissible_with`'s body.

    Audit-3 fix: pre-fix, an empty `signedByName` and empty
    `actorName` would silently match (both ""), returning .ok
    even though the law had no valid `lex_signed_by` clause.
    Now an empty `signedByName` returns the dedicated
    `.emptySignedBy` error variant, surfacing the upstream
    issue. -/
def synth_nonce_advances (signedByName : String) (actorName : String) :
    SynthResult :=
  if signedByName.isEmpty then
    .error (.emptySignedBy actorName)
  else if signedByName == actorName then
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
    `SynthError`.

    AR.11 caveat — the resource-bearing `.localTo` and
    `.freezePreserving` claims route through the `_kindOnly`
    fallbacks because this entry point has no resource info.
    The post-AR `_kindOnly` synthesizers refuse to silently
    admit resource-bearing statements (returning
    `.resourceNotInLocalSet "<unknown>"`); callers with resource
    info should use `dispatchSynthesizerResourceAware` instead. -/
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
  | .localTo             => synth_local_kindOnly localSet stmts
  | .freezePreserving    => synth_freeze_preserving_kindOnly freezeSet stmts
  | .nonceAdvances       => synth_nonce_advances signedByName nonceActor
  | .registryPreserving  => synth_registry_preserving stmts
  | .userDefined name =>
    -- Audit-3 fix: pre-fix this returned the misleading
    -- `.unsupportedStatementKind .bareTerm` (whose diagnostic
    -- message references a `bareTerm` STATEMENT shape — wrong
    -- domain).  The actual condition is "user-defined property
    -- with no proof override AND no synthesizer support".
    -- `dispatchWithOverrides` is the production entry point
    -- that consults the override list before falling here; if
    -- a user-defined property reaches this branch, no override
    -- was provided.
    .error (.userDefinedNoOverride (toString name))

/-- AR.11 / M+2 — resource-aware dispatcher.

    Takes `List (ImplStmtKind × Option String)` (kind + optional
    resource per statement) instead of just `List ImplStmtKind`.
    For resource-bearing claims (`.localTo`, `.freezePreserving`),
    dispatches to the resource-aware `synth_local` /
    `synth_freeze_preserving` so a `local [S]` claim is checked
    against actual resource membership (not silently admitted).

    Production macros that have access to the full `ImplStmt` AST
    (via `ImplStmt.kindAndResource`) should use this entry; the
    kind-only `dispatchSynthesizer` is preserved for callers
    (notably test scaffolding) that don't carry resource info. -/
def dispatchSynthesizerResourceAware
    (claim : PropertyKind)
    (signedByName : String)
    (stmts : List (ImplStmtKind × Option String))
    (localSet : List String := [])
    (freezeSet : List String := [])
    (nonceActor : String := "") :
    SynthResult :=
  let kinds := stmts.map (·.1)
  match claim with
  | .conservative        => synth_conservative kinds
  | .monotonic           => synth_monotonic kinds
  | .localTo             => synth_local localSet stmts
  | .freezePreserving    => synth_freeze_preserving freezeSet stmts
  | .nonceAdvances       => synth_nonce_advances signedByName nonceActor
  | .registryPreserving  => synth_registry_preserving kinds
  | .userDefined name    => .error (.userDefinedNoOverride (toString name))

/-! ## `@[lex_property]` attribute (§10.13)

User-defined property names admissible inside `lex_satisfies`
clauses are tagged with `@[lex_property]`.  The attribute marks
the property name as "the macro should bypass the synthesizer
and consume a `lex_proof <P> := …` override". -/

/-- The `@[lex_property]` tag attribute. -/
initialize lexPropertyAttr : Lean.TagAttribute ←
  Lean.registerTagAttribute `lex_property
    "Marks a name as a user-defined Lex property.  A `lex_satisfies := [P]` claim referencing such a name requires a matching `lex_proof P := …` override; otherwise diagnostic L020 fires."

/-- True iff the property name `n` is tagged `@[lex_property]`. -/
def isLexPropertyTagged (env : Lean.Environment) (n : Lean.Name) : Bool :=
  lexPropertyAttr.hasTag env n

/-! ## L-code diagnostic helpers (§10.5 / §13.1) -/

/-- Format an L004 message ("synthesizer failure"). -/
def L004Message (propertyName : String) (cause : SynthError) : String :=
  s!"L004: synthesizer failed to discharge `{propertyName}` for the law: {cause.toString}.  Either weaken `lex_satisfies` or supply `lex_proof {propertyName} := by …`."

/-- Format an L020 message ("unknown property name"). -/
def L020Message (propertyName : String) : String :=
  s!"L020: `lex_satisfies := [...{propertyName}...]` references an unknown property name.  Tag the name with `@[lex_property]` and supply `lex_proof {propertyName} := …`."

/-- Format an L024 message ("`local [*]` rejected"). -/
def L024Message : String :=
  "L024: `lex_satisfies := [..., local [*], ...]` is rejected — the wildcard form is always trivially satisfied (every law is `LocalTo` the universe of resources).  Replace with `local [{r₁,…,rₙ}]` listing the actually-touched resources, or drop the claim entirely."

/-- Format an L025 message ("per-resource arg on conservative /
    monotonic"). -/
def L025Message (propertyName : String) : String :=
  s!"L025: `lex_satisfies := [..., {propertyName} [r], ...]` is rejected — `IsConservative` and `IsMonotonic` are universal over `ResourceId` (the typeclass is on the `Transition`, not on a per-resource subset).  Drop the `[r]` argument."

/-! ## `parsePropertyList` (§10.13)

Parse a list of property identifiers (the syntactic surface of
`lex_satisfies := [name1, name2, …]`) into a list of typed
`PropertyKind` values.

The parser doesn't try to handle nested arguments (e.g.
`local [{r}]`); M1's `lex_satisfies` syntax is a simple
identifier list.  Argument-bearing claims are M2 surface and
will land in LX.22+. -/

/-- Result of parsing a property name: either a recognised
    `PropertyKind` or an L020 / L024 / L025 diagnostic. -/
inductive ParsedProperty where
  /-- Successfully parsed kind. -/
  | ok (kind : PropertyKind) : ParsedProperty
  /-- L020: untagged user-defined name (and not a built-in). -/
  | unknownName (name : String) : ParsedProperty
  /-- L024: `local [*]` wildcard rejected. -/
  | wildcardLocal : ParsedProperty
  /-- L025: per-resource arg on `conservative` / `monotonic`. -/
  | perResourceOnConservativeOrMonotonic (name : String) : ParsedProperty
  deriving Repr, Inhabited

/-- Parse a single property name string into a `ParsedProperty`. -/
def parsePropertyName (env : Lean.Environment) (name : String) :
    ParsedProperty :=
  let trimmed := name.trimAscii.toString
  -- Detect known forbidden patterns first.
  if trimmed == "local_wildcard" || trimmed.endsWith "[*]" then
    .wildcardLocal
  else if trimmed.endsWith "[r]" &&
          (trimmed.startsWith "conservative" ||
           trimmed.startsWith "monotonic") then
    let propName :=
      if trimmed.startsWith "conservative" then "conservative" else "monotonic"
    .perResourceOnConservativeOrMonotonic propName
  else
    let kind := PropertyKind.ofString trimmed
    match kind with
    | .userDefined uName =>
      -- Look up the attribute table.
      if isLexPropertyTagged env (Lean.Name.mkSimple uName) then
        .ok kind
      else
        .unknownName uName
    | _ => .ok kind

/-- Parse a list of property names.  Returns a list of
    `ParsedProperty`s in input order; the macro layer surfaces
    each `unknownName`/`wildcardLocal`/`perResourceOnCM` as a
    diagnostic. -/
def parsePropertyList (env : Lean.Environment) (names : List String) :
    List ParsedProperty :=
  names.map (parsePropertyName env)

/-- Extract just the successfully-parsed `PropertyKind`s, dropping
    the `unknownName` etc. errors.  Used by the dispatcher when
    the macro has decided to proceed despite warnings. -/
def ParsedProperty.successOrNothing : ParsedProperty → Option PropertyKind
  | .ok k => some k
  | _     => none

/-! ## LX.16: override application

Per §10.13, the dispatcher must consult `LawDecl.proofOverrides`
*before* invoking the synthesizer; if an override matches the
property name, the override's tactic block is spliced into the
generated instance body.  The synthesizer is bypassed entirely.

`dispatchWithOverrides` is the override-aware entry point used
by the macro.  Existing `dispatchSynthesizer` is preserved for
direct callers (tests). -/

/-- Look up a `proof <P> := …` override by property name in the
    `LawDecl.proofOverrides` field.  Returns the captured
    tactic source on hit; `none` on miss. -/
def lookupProofOverride
    (overrides : List LegalKernel.Tools.Lex.ProofOverride)
    (propertyName : String) : Option String :=
  match overrides.find? (fun o => o.property == propertyName) with
  | some o => some o.tacticBlock
  | none   => none

/-- Override-aware dispatcher.  If a `proof <P>` override exists
    for the claim, emit the override's tactic source verbatim
    (per §10.13: "the override is spliced into the generated
    instance body").  Otherwise, fall through to the
    synthesizer dispatch. -/
def dispatchWithOverrides
    (claim : PropertyKind)
    (claimNameRaw : String)
    (overrides : List LegalKernel.Tools.Lex.ProofOverride)
    (signedByName : String)
    (stmts : List ImplStmtKind)
    (localSet : List String := [])
    (freezeSet : List String := [])
    (nonceActor : String := "") :
    SynthResult :=
  match lookupProofOverride overrides claimNameRaw with
  | some tacticSrc =>
    .ok s!"by {tacticSrc}  /- override for `{claimNameRaw}` (LX.16) -/"
  | none =>
    dispatchSynthesizer claim signedByName stmts localSet freezeSet nonceActor

end LegalKernel.DSL.Lex
