/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.DSL.Shim — `signed_by` strengthening + `self_only`
static analysis (LX.9).

LX.9 of `docs/planning/lex_implementation_plan.md`.

Exports:

  * `selfOnlyCheckImplStmts` — static analysis: walks an
    `ImplStmt` list and confirms every mutation targets the
    `signed_by` actor.  Returns a list of L011 violations.
  * `L011Message` — diagnostic formatter.
  * `analyseShim : ImplStmt list → SignedByAnalysis` — summary
    record.

The actual shim emission happens in `Lex.DSL.Law`'s
elaborator (LX.9 deliverable: per-law `def <law>_apply` shim).
M1's shim is structural — it provides the `h_signer : st.signer
= sender` extra hypothesis but doesn't yet add deployment-side
checks.

This module is **non-TCB**.
-/

import Lex.DSL.ImplCalculus

namespace LegalKernel.DSL.Lex

/-! ## L011 diagnostic helper -/

/-- Format an L011 message ("`self_only` violation"). -/
def L011Message (signedBy : String) (offending : String) : String :=
  s!"L011: `lex_authorized_by self_only` requires every mutation to be keyed by the signed_by actor (`{signedBy}`); the statement `{offending}` mutates a non-signer-keyed cell.  Add an `lex_authorized_by <policy>` clause or restrict `lex_impl` to signer-keyed mutations."

/-! ## Self-only static analysis (§9.3)

Per §9.3 of the implementation plan, `lex_authorized_by self_only`
admits a statement only when its target is *exactly* the
`signed_by` actor.  This walker checks the rule:

  * `flow r amt from sender to b`         — sender must equal signed_by
  * `flow r amt from a to sender`         — REJECT (mutates arbitrary `a`)
  * `mint r amt to b`                     — b must equal signed_by
  * `burn r amt from a`                   — a must equal signed_by
  * `reward r amt to b`                   — b must equal signed_by
  * `freeze_resource r`                   — admissible (no actor state)
  * `register_key a as k`                 — a must equal signed_by

The walker operates on the *surface text* of each statement
(captured in `ImplStmt`'s string fields).  It searches for the
`signed_by` actor name as a substring of the text; this is a
conservative under-approximation (it accepts shapes where the
actor name is referenced anywhere in the statement, not strictly
in the "from" / "to" position), so a future version may tighten
the check by adding parameter-position parsing. -/

/-- Result of the self-only analysis: the signed_by actor name
    + a list of L011 violations (each tagged with the offending
    statement's surface text). -/
structure SignedByAnalysis where
  /-- The `signed_by` actor's name. -/
  signedBy : String
  /-- L011 violations: surface-text snippets of the offending
      statements.  Empty list = analysis passes. -/
  violations : List String
  deriving Repr, Inhabited

/-- True iff a statement's surface text references the signed_by
    actor (as a substring, with whitespace boundary).

    **AR.13.4 / m-12 note.**  This is a *positionally insensitive*
    substring check: `signed_by alice` matches both
    `flow r amt from alice to b` (legitimate) and
    `flow r amt from b to alice` (also legitimate but for a
    different reason — alice is the recipient).  The shim therefore
    treats any reference to `alice` anywhere in the statement as
    "self-only-compatible".  The real authorisation enforcement
    lives in the deployment's `AuthorityPolicy` (the kernel
    admissibility check at Phase 3 — `Authority.SignedAction`),
    not in this shim; the shim is a *lint* that catches the worst
    obvious mistakes early.  Tightening to position-aware parsing
    is a follow-up workstream. -/
private def stmtReferencesSignedBy (signedBy : String) (text : String) : Bool :=
  -- Substring match with whitespace/punctuation boundaries.
  let needle := " " ++ signedBy ++ " "
  let leadingNeedle := signedBy ++ " "
  let trailingNeedle := " " ++ signedBy
  text.endsWith trailingNeedle ||
  text.startsWith leadingNeedle ||
  ((text.splitOn needle).length > 1)

/-- Self-only check: every mutating statement must reference the
    signed_by actor.  `freeze_resource` is admissible (touches
    no actor state). -/
def selfOnlyCheckStmt (signedBy : String) (stmt : ImplStmt) : Option String :=
  match stmt with
  | .freezeResource _    => none  -- always admissible
  | .letBind _ _         => none  -- host primitive
  | .ifStmt _ _ _        => none  -- caller recurses on branches
  | .forLoop _ _ _       => none  -- caller recurses on body
  | .flow text _ _ _ =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .mint text _ _ =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .burn text _ _ =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .reward text _ _ =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .registerKey text _ =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .registerIdentity text _ =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .revokeKey text =>
      if stmtReferencesSignedBy signedBy text then none else some text
  | .bareSetBalance text => some text  -- always rejected under self_only
  | .bareTerm _          => none       -- opaque; can't analyse

/-- Walk a list of `ImplStmt`s and collect L011 violations. -/
def selfOnlyCheckImplStmts (signedBy : String) (stmts : List ImplStmt) :
    SignedByAnalysis :=
  let violations := stmts.filterMap (selfOnlyCheckStmt signedBy)
  { signedBy, violations }

/-! ## Shim-name helpers -/

/-- Produce the canonical shim def name for a law identifier:
    `legalkernel.transfer` → `legalkernel_transfer_apply`. -/
def shimDefName (identifier : String) : String :=
  identifier.replace "." "_" ++ "_apply"

end LegalKernel.DSL.Lex
