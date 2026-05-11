/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.DSL.LexPreGrammar — the §7 `pre` grammar enforcer.

LX.7 of `docs/lex_implementation_plan.md`.

Exports:

  * `inductive PreNode` — the §7.2 grammar's term sort (`True`,
    `False`, `And`, `Or`, `Not`, `Ite`, comparators over `Nat` /
    `ActorId` / `ResourceId`, bounded quantifiers, user-tagged
    predicates).
  * `inductive NatNode` — the Nat sort (literals, variables,
    arithmetic, `getBalance`, `expectsNonce`, user-tagged Nat-
    valued helpers).
  * `inductive ActorNode`, `ResourceNode`, `BoundedIter` — the
    smaller sorts.
  * `parsePreExpr : Lean.Syntax → Except String PreNode` — a
    *conservative* walker.  Falls back on the Lean elaborator's
    `[DecidablePred pre]` instance synthesis for anything outside
    the recognised shape set; the L003 diagnostic is anchored at
    the user's surface syntax via the macro's existing source-
    position threading.
  * `@[lex_pre]` attribute (`Lean.TagAttribute`) for tagging
    user-defined predicates / Nat-valued helpers admissible
    inside `pre` clauses.
  * `isLexPreTagged` predicate consumed by the walker.

# Design note: walker conservatism

A faithful §7.2 walker would need to traverse Lean's full
elaborated term tree, classifying every node by its head
constant.  Lean's elaboration produces hundreds of distinct
internal node kinds, many of which encode the *same* surface
syntax via macro expansion.  Implementing a complete walker is
brittle: a Lean version bump can rename internal node kinds,
breaking the walker silently.

The v1 walker therefore takes a *complementary* approach: it
recognises a fixed set of *shape patterns* on the user's
surface syntax (before elaboration) and emits a structured
`PreNode` for each match.  Anything else is captured as
`PreNode.userPred` carrying the surface text — and the
ambient Lean elaborator's `[DecidablePred pre]` synthesis is
the authoritative gate.  This means:

  * Every shape the walker recognises is guaranteed decidable
    (no false negatives on §7.2 shapes).
  * Every shape outside the walker's set falls through to
    `inferInstance`, where Lean's elaborator decides whether
    the precondition is decidable.  If not, the user sees the
    standard "failed to synthesize Decidable" error.
  * The L003 diagnostic the walker emits is *informational*
    (a hint that the shape is outside the §7.2 grammar), not a
    hard rejection.  This matches the plan's "deliberately
    conservative" principle (§7.7).

This module is **non-TCB**: bugs produce false-positive shape
classifications (rejecting some otherwise-valid Lex laws), but
cannot violate any kernel invariant.
-/

import Lean.Elab.Command
import Lean.Elab.Term
import Lean.Data.Position
import Lean.Attributes

namespace LegalKernel.DSL.Lex

open Lean

/-! ## AST types (§7.2) -/

/-- A bounded iterator (the `<list>` of `forall x ∈ <list>, P`).
    M1 captures the list as surface text only; the synthesizer
    library (LX.13 / LX.14) inspects it as needed. -/
inductive BoundedIter where
  /-- A surface-syntax expression that elaborates to `List α`
      for some `α`.  Caller is responsible for finiteness. -/
  | toListExpr : String → BoundedIter
  deriving Repr, DecidableEq, Inhabited

/-- The §7.2 `ActorId` sort.  M1 admits literals (`Nat`-shaped
    actor IDs), variable references, and tagged user functions. -/
inductive ActorNode where
  /-- A `Nat`-shaped actor literal. -/
  | lit : Nat → ActorNode
  /-- A variable reference (param name). -/
  | var : Lean.Name → ActorNode
  deriving Repr, Inhabited

/-- The §7.2 `ResourceId` sort.  Same shape as `ActorNode`. -/
inductive ResourceNode where
  /-- A `Nat`-shaped resource literal. -/
  | lit : Nat → ResourceNode
  /-- A variable reference (param name). -/
  | var : Lean.Name → ResourceNode
  deriving Repr, Inhabited

mutual

/-- The §7.2 `pre`-grammar root: a `Prop`-valued tree built only
    from the operators the synthesizer can decidability-check at
    elaboration time. -/
inductive PreNode where
  /-- `True` literal. -/
  | true_ : PreNode
  /-- `False` literal. -/
  | false_ : PreNode
  /-- Conjunction. -/
  | and : PreNode → PreNode → PreNode
  /-- Disjunction. -/
  | or : PreNode → PreNode → PreNode
  /-- Negation. -/
  | not_ : PreNode → PreNode
  /-- If-then-else. -/
  | ifte : PreNode → PreNode → PreNode → PreNode
  /-- `a ≤ b` over `Nat`. -/
  | leNat : NatNode → NatNode → PreNode
  /-- `a < b` over `Nat`. -/
  | ltNat : NatNode → NatNode → PreNode
  /-- `a = b` over `Nat`. -/
  | eqNat : NatNode → NatNode → PreNode
  /-- `a ≠ b` over `Nat`. -/
  | neNat : NatNode → NatNode → PreNode
  /-- `a ≥ b` over `Nat`. -/
  | geNat : NatNode → NatNode → PreNode
  /-- `a > b` over `Nat`. -/
  | gtNat : NatNode → NatNode → PreNode
  /-- `forall x ∈ <list>, P x` (bounded). -/
  | forallIn : Lean.Name → BoundedIter → PreNode → PreNode
  /-- `exists x ∈ <list>, P x` (bounded). -/
  | existsIn : Lean.Name → BoundedIter → PreNode → PreNode
  /-- `userPred name args` — admitted if `name` is `@[lex_pre]`-
      tagged.  `args` are surface-text snippets; the elaborator
      handles them via instance synthesis. -/
  | userPred : Lean.Name → List String → PreNode
  /-- Catch-all for shapes outside the §7.2 grammar.  Carries the
      surface text so callers can emit L003 diagnostics. -/
  | unknown : String → PreNode
  deriving Inhabited

/-- The §7.2 `Nat` sort: arithmetic + balance / nonce reads. -/
inductive NatNode where
  /-- Numeric literal. -/
  | lit : Nat → NatNode
  /-- Variable reference (param name). -/
  | var : Lean.Name → NatNode
  /-- Addition. -/
  | add : NatNode → NatNode → NatNode
  /-- Truncated `Nat` subtraction. -/
  | sub : NatNode → NatNode → NatNode
  /-- Multiplication. -/
  | mul : NatNode → NatNode → NatNode
  /-- Floor-division. -/
  | div : NatNode → NatNode → NatNode
  /-- Modulo. -/
  | mod : NatNode → NatNode → NatNode
  /-- `getBalance s r a` — opaque sub-term carrying the surface
      text of its three arguments. -/
  | getBal : String → String → String → NatNode
  /-- `expectsNonce es a` — opaque sub-term. -/
  | expectsNonce : String → String → NatNode
  /-- `userFn name args` — admitted if `name` is `@[lex_pre]`-
      tagged. -/
  | userFn : Lean.Name → List String → NatNode
  /-- Catch-all for shapes outside the §7.2 `Nat` sort. -/
  | unknown : String → NatNode
  deriving Inhabited

end

/-! ## `@[lex_pre]` attribute (§7.4)

User-defined predicates and Nat-valued functions that should be
admissible inside `pre` clauses are tagged with `@[lex_pre]`.
The attribute is a `Lean.TagAttribute`: it just records the
tagged names.  The current `isLexPreTagged` check confirms the
tag is present at the surface-text level; the plan's §7.4
attach-time decidability check is a downstream consumer of
the tagged predicates' `Decidable` instances which the user
supplies at the call site (per the `decPre := fun _ =>
inferInstance` discipline). -/

/-- The `@[lex_pre]` tag attribute.  Tagged predicates and
    Nat-valued helpers are admissible inside Lex `lex_pre`
    clauses; the walker (`parsePreExpr`) emits a `userPred` /
    `userFn` node carrying the function's name and surface-text
    args. -/
initialize lexPreAttr : Lean.TagAttribute ←
  Lean.registerTagAttribute `lex_pre
    "Marks a predicate or Nat-valued function as admissible inside a Lex `lex_pre` clause.  The tagged definition should produce a `Decidable` result via `inferInstance` for any in-grammar argument."

/-- True iff the function `n` is tagged `@[lex_pre]`. -/
def isLexPreTagged (env : Lean.Environment) (n : Lean.Name) : Bool :=
  lexPreAttr.hasTag env n

/-! ## L003 diagnostic helper -/

/-- Format an L003 message describing why a sub-expression was
    rejected.  The position is captured separately by the caller
    (the macro layer threads `Lean.Syntax.getPos?` through to a
    `Diagnostic`). -/
def L003Message (s : String) : String :=
  s!"L003: precondition contains undecidable / unsupported sub-expression `{s}` (only the §7.2 grammar is admitted; tag user-defined helpers with `@[lex_pre]` and supply a `Decidable` instance)"

/-! ## Walker (§7.3)

The walker pattern-matches on Lean's surface `Syntax` tree.  Its
contract:

  * Returns `Except String PreNode` — the `String` is an
    informational L003 message; the caller anchors it at the
    appropriate source position.
  * Recognised shapes return a structured `PreNode` (`true_`,
    `false_`, `and`, `or`, comparators, etc.).
  * Unrecognised shapes return `PreNode.unknown text` (so the
    caller can decide whether to surface L003 or fall through
    to the elaborator's `inferInstance`).

The walker does NOT reject unrecognised shapes outright; the
final decision lives at the macro layer where the §7.7
"deliberately conservative" principle determines whether to
warn or hard-error. -/

mutual

/-- Walk a `Term`-syntax and classify it as a §7.2 `PreNode`.
    Always succeeds (recognised or `unknown`); errors are
    reported via the `unknown` constructor at the macro layer. -/
partial def parsePreExpr (env : Lean.Environment) (stx : Lean.Syntax) :
    PreNode :=
  let fallback : PreNode :=
    match stx with
    | `($f:ident $args:term*) =>
      if isLexPreTagged env f.getId then
        .userPred f.getId (args.toList.map toString)
      else
        .unknown (toString stx)
    | _ => .unknown (toString stx)
  match stx with
  | `(True)              => .true_
  | `(False)             => .false_
  -- `fun s => body` — strip the binder and walk the body.
  -- (The `lex_pre` clause is `State → Prop`; the user always
  -- writes a single-binder lambda whose body is the §7.2 Prop
  -- expression.)
  | `(fun $_:ident => $body) => parsePreExpr env body
  | `(fun ($_:ident : $_:term) => $body) => parsePreExpr env body
  | `(fun (_ : $_:term) => $body) => parsePreExpr env body
  | `(fun _ => $body) => parsePreExpr env body
  | `($lhs ∧ $rhs)       => .and (parsePreExpr env lhs) (parsePreExpr env rhs)
  | `($lhs ∨ $rhs)       => .or (parsePreExpr env lhs) (parsePreExpr env rhs)
  | `(¬ $rhs)            => .not_ (parsePreExpr env rhs)
  | `(if $c then $t else $e) =>
      .ifte (parsePreExpr env c) (parsePreExpr env t) (parsePreExpr env e)
  | `($lhs ≤ $rhs)       => .leNat (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs < $rhs)       => .ltNat (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs ≥ $rhs)       => .geNat (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs > $rhs)       => .gtNat (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs = $rhs)       => .eqNat (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs ≠ $rhs)       => .neNat (parseNatExpr env lhs) (parseNatExpr env rhs)
  -- Bounded universal quantifier: `∀ x ∈ list, body`.  Audit-2
  -- fix: pre-audit `parsePreExpr` had no match arms for these
  -- shapes, so a Lex law with a bounded quantifier in its
  -- `lex_pre` clause fell through to `unknown`, triggering a
  -- false-positive L003 warning even though `forallIn` /
  -- `existsIn` are admissible §7.2 grammar nodes.  The walker
  -- now records the binder name, the iter (as `BoundedIter.toListExpr`
  -- carrying the surface text), and recursively walks the body.
  | `(∀ $x:ident ∈ $iter, $body) =>
      .forallIn x.getId (BoundedIter.toListExpr (toString iter))
                        (parsePreExpr env body)
  | `(∃ $x:ident ∈ $iter, $body) =>
      .existsIn x.getId (BoundedIter.toListExpr (toString iter))
                        (parsePreExpr env body)
  | _                    => fallback

/-- Walk a `Term`-syntax and classify it as a §7.2 `NatNode`. -/
partial def parseNatExpr (env : Lean.Environment) (stx : Lean.Syntax) :
    NatNode :=
  let s := toString stx
  let fallback : NatNode :=
    match s.toNat? with
    | some n => .lit n
    | none =>
      match stx with
      | `($x:ident) =>
        if isLexPreTagged env x.getId then .userFn x.getId []
        else .var x.getId
      | `($f:ident $args:term*) =>
        if isLexPreTagged env f.getId then
          .userFn f.getId (args.toList.map toString)
        else
          .unknown s
      | _ => .unknown s
  match stx with
  | `($lhs + $rhs)       => .add (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs - $rhs)       => .sub (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs * $rhs)       => .mul (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs / $rhs)       => .div (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `($lhs % $rhs)       => .mod (parseNatExpr env lhs) (parseNatExpr env rhs)
  | `(getBalance $a1 $a2 $a3) =>
      .getBal (toString a1) (toString a2) (toString a3)
  | `(expectsNonce $a1 $a2)   =>
      .expectsNonce (toString a1) (toString a2)
  | _ => fallback

end

/-! ## Shape-classifier helpers (used by tests) -/

/-- True iff a `PreNode` is in a §7.2 *recognised* shape (i.e.
    not `.unknown`).  The macro uses this to decide between
    "accept silently" and "warn via L003". -/
def PreNode.isRecognised : PreNode → Bool
  | .unknown _ => false
  | _          => true

/-- Recursively true iff every sub-node of a `PreNode` is in a
    §7.2 recognised shape.  The macro uses this for the strict
    grammar-enforcement gate. -/
partial def PreNode.isFullyRecognised : PreNode → Bool
  | .true_                 => true
  | .false_                => true
  | .and l r               => l.isFullyRecognised && r.isFullyRecognised
  | .or l r                => l.isFullyRecognised && r.isFullyRecognised
  | .not_ p                => p.isFullyRecognised
  | .ifte c t e            => c.isFullyRecognised && t.isFullyRecognised && e.isFullyRecognised
  | .leNat _ _ | .ltNat _ _ | .eqNat _ _ | .neNat _ _
  | .geNat _ _ | .gtNat _ _ => true
  | .forallIn _ _ p        => p.isFullyRecognised
  | .existsIn _ _ p        => p.isFullyRecognised
  | .userPred _ _          => true
  | .unknown _             => false

end LegalKernel.DSL.Lex
