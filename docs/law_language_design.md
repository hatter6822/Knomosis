<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon Law Language: A Design for Code-As-Law

This document specifies the design of a high-level surface language
for writing **laws** in Canon — the deployment-facing complement of
the Phase 0–6 kernel.  It supersedes the minimal Phase-4 `law` macro
(`LegalKernel/DSL/Law.lean`, WU 4.9) by extending it with mandatory
authority binding, structured property claims, frozen wire indices,
literate-program intent blocks, and a deployment-manifest layer.

The language is non-TCB.  Its elaborator is a Lean 4 macro family
that produces ordinary `Transition` and `Action` declarations passing
through the existing kernel typing rules; the trusted core
(`Kernel.lean` + `RBMapLemmas.lean`) does not grow.

> **Working name.**  This document refers to the language as "Lex"
> (Latin: *law*) for brevity.  The name is provisional; the
> repository commits to no marketing brand at this stage.

---

## Table of Contents

  1. [Purpose and scope](#1-purpose-and-scope)
  2. [The two-audience problem](#2-the-two-audience-problem)
  3. [Architectural choice: embedded elaboration to Lean](#3-architectural-choice-embedded-elaboration-to-lean)
  4. [Design principles](#4-design-principles)
  5. [Surface syntax](#5-surface-syntax)
  6. [Elaboration semantics](#6-elaboration-semantics)
     * 6.1. [The decidable precondition grammar (`Pre`)](#61-the-decidable-precondition-grammar-pre)
     * 6.2. [The flow calculus (`impl`)](#62-the-flow-calculus-impl)
     * 6.3. [Authority binding (`signed_by` / `authorized_by`)](#63-authority-binding-signed_by--authorized_by)
     * 6.4. [Property dispatch (`satisfies`)](#64-property-dispatch-satisfies)
     * 6.5. [Action registration (`action_index`)](#65-action-registration-action_index)
     * 6.6. [Event emission (`events`)](#66-event-emission-events)
     * 6.7. [Resource roles (deferred to v3)](#67-resource-roles-deferred-to-v3)
  7. [Deployment manifests](#7-deployment-manifests)
  8. [Governance and amendment](#8-governance-and-amendment)
  9. [Tooling](#9-tooling)
  10. [Diagnostics](#10-diagnostics)
  11. [Deliberate exclusions](#11-deliberate-exclusions)
  12. [Migration plan](#12-migration-plan)
  13. [Roadmap](#13-roadmap)
  14. [Open questions](#14-open-questions)
  15. [Worked examples](#15-worked-examples)
  16. [Audit-1 changelog](#16-audit-1-changelog)

---

## 1. Purpose and scope

Lex is the surface language a deployment uses to **declare a new law**.
A law is a state-transition rule: a precondition, a deterministic
implementation, and a bundle of provable properties (conservation,
monotonicity, locality, freeze-preservation, …).  The language exists
to compress what is currently 7 mechanical edits per law into a
single declaration:

  1. add a constructor to `Action` (Genesis Plan §4.13);
  2. add a `compileTransition` branch (`Authority/Action.lean`);
  3. add CBE encode / decode branches (`Encoding/Action.lean`);
  4. add a `fieldsBounded` branch (`Encoding/Action.lean`);
  5. add an `extractEvents` branch (`Events/Extract.lean`);
  6. add a `non_replaceKey_preserves_registry` branch
     (`Authority/SignedAction.lean`);
  7. supply `IsConservative` / `IsMonotonic` instances (or negative
     witnesses) (`Conservation.lean` consumers).

Each of these is a *consequence* of the law's behaviour, not an
independent design choice.  Lex captures the law once and emits all
seven artefacts.

**In scope:**

  * Single-deployment laws that extend the global `Action` inductive
    (§4.13) at a freshly-allocated frozen index ≥ 12.
  * Re-expression of the existing 12 kernel-built-in laws (`transfer`,
    `mint`, `burn`, `freezeResource`, `replaceKey`, `reward`,
    `distributeOthers`, `proportionalDilute`, `dispute`,
    `disputeWithdraw`, `verdict`, `rollback`) in Lex form, as a
    correctness check that the language can express what the kernel
    already ships.
  * Deployment manifests that bind a law set, an authority
    configuration, a deployment ID, and a list of invariant claims.

**Out of scope (this revision):**

  * Deployment-private laws that do **not** appear in the global
    `Action` inductive.  Per-deployment Action extension is a Phase-7
    runtime-adaptor change; Lex v1 ships kernel-extension laws only.
    The mechanism is sketched in §6.5 and §13 but not specified here.
  * Resource roles (phantom-typed `Currency` / `VotingPower` / …
    markers).  Specified at sketch level in §6.7 and deferred to v3
    once a deployment surfaces a concrete need.
  * Custom dispute-claim variants.  Phase 6 froze the five §8.4.1
    claim variants; new variants are a Genesis-Plan amendment, not a
    Lex feature.

Lex is **not** a vehicle for changing the kernel's threat model, its
TCB, or its on-wire formats.  Every Lex declaration produces output
within the existing surface; the language adds expressiveness, not
trust.

## 2. The two-audience problem

A law is *both* executable code (it runs in the runtime,
deterministically, against `ExtendedState`) and a *governance
artefact* (it is reviewed by people who decide whether it encodes
the policy they want).  These audiences want incompatible things:

| Audience      | Wants                                                                  |
|---------------|------------------------------------------------------------------------|
| Runtime       | precision, type safety, decidability, performance, no ambiguity        |
| Governance    | readability, version-stable identity, amendment trail, semantic diff   |
| Auditors      | a one-screen contract surface that names the proven properties         |
| Operators     | a manifest that says exactly which laws this deployment runs           |
| Counterparties| a way to verify they sign against the same law text the operator runs  |

The current Phase-4 macro (`law pre := … ; impl := …`) addresses only
the runtime audience.  It produces a `Transition` with the
`decPre := fun _ => inferInstance` discipline filled in, and stops
there.  The other audiences are served, today, by 1100 lines of
hand-written `Authority/Action.lean` plus `Encoding/Action.lean` plus
`Events/Extract.lean` plus per-law instance proofs — all of which
must be kept in lock-step by review-time discipline.

Lex resolves the tension by being **a literate-program surface where
the law text is its own documentation**.  Each law carries:

  * a canonical natural-language statement of intent (`intent` block,
    versioned and covered by the manifest signature);
  * the formal precondition (`pre`) and implementation (`impl`) — the
    executable surface;
  * a declarative bridge (`satisfies` block) that names the formal
    properties the natural-language intent informally guarantees.

The reviewer's job is to read the `intent` block and decide whether
the `pre` / `impl` / `satisfies` bundle correctly encodes it.  The
elaborator's job is to mechanically check that the `satisfies`
properties really hold.  Neither audience has to read the other's
material.

## 3. Architectural choice: embedded elaboration to Lean

Lex is a Lean 4 macro family.  It is **not** a standalone language
with its own parser and elaborator.  This choice closes three risks:

  1. **TCB hygiene.**  A standalone elaborator becomes trusted by
     virtue of producing the kernel's input.  The current TCB
     (`Kernel.lean` + `RBMapLemmas.lean`) is ~700 lines of Std-only
     Lean (`Kernel.lean` 392 + `RBMapLemmas.lean` 297 = 689 at the
     time of writing).  An external parser / elaborator would either
     need a comparable correctness audit or would expand the TCB by
     an unbounded amount.  Embedded macros run *before* type-checking,
     produce ordinary Lean declarations, and the kernel's existing
     `lake exe count_sorries` / `lake exe tcb_audit` gates apply
     unchanged.
  2. **Proof-search reuse.**  The `decPre := fun _ => inferInstance`
     discipline (WU 1.6, `docs/decidability_discipline.md`) only
     works because Lean's instance-resolution sees the precondition
     in its native form.  A standalone language would have to
     re-implement decidability inference and the typeclass database.
  3. **Property dispatch.**  `IsConservative` and `IsMonotonic`
     (Phase-2 / Phase-4-prelude WUs R.1–R.4) are typeclasses
     dispatched by Lean's instance synthesizer.  Generating instance
     declarations from outside Lean is feasible but requires
     reproducing a non-trivial fragment of the Lean elaborator.
     Lex additionally proposes new typeclasses
     (`FreezePreserving`, `LocalTo`, `RegistryPreserving`; see §6.4)
     that landing the synthesizer library introduces; these are
     non-TCB additions to `Conservation.lean` and the Laws modules.

The cost of embedding is that Lex inherits Lean 4's macro syntax
constraints and Lean's error messages.  Section 10 specifies the
diagnostic-translation layer that addresses the second.  The first
is mitigated by careful syntax design (§5).

> **Why not a standalone configuration format (e.g. JSON / YAML /
> CBOR) that the runtime parses?**  A configuration format describes
> *which* laws to run; it cannot describe *what a law does* without
> shipping the law's compiled bytes — which makes the format itself
> the surface that needs review.  Once the format is reviewable, it
> needs typed primitives, decidability, and property declarations,
> at which point it has reinvented Lex.  The shorter path is to
> start from a real type system.

## 4. Design principles

Six principles drive every concrete choice in §5 and §6.  Each is
stated tersely; the justification follows.

  1. **Decidability is enforced by grammar.**  Preconditions are
     built only from shapes that `inferInstance` can discharge.  The
     elaborator does not attempt to *prove* decidability for novel
     predicates; it requires that the precondition expression
     parse-fits the grammar of §6.1.  Predicates that do not fit are
     a parse error, not a "failed to synthesize Decidable" error
     buried 60 lines into the macro expansion.

  2. **Flows are first-class; everything else is suspect.**  A
     primitive `flow r amt from a to b` desugars to the §4.11
     transfer pattern verbatim, including the self-transfer fix
     (post-debit re-read of the receiver), and emits
     `IsConservative` and `IsMonotonic` mechanically.  Operations
     that create or destroy supply use distinct keywords (`mint`,
     `burn`, `reward`).  The asymmetry is the point: a reviewer
     scanning a 200-line law file wants `mint` and `burn` to be
     visually jarring, and wants `flow` to be unremarkable.

  3. **Contracts are mandatory, machine-checked, and one-screen.**
     Every law declares a `satisfies` block listing the formal
     properties it claims.  The elaborator either discharges each
     item or fails with a precise residual obligation.  A law
     without a `satisfies` block is a parse error.  The contract is
     the reviewer's primary surface — the proof is hidden until
     needed.

  4. **Authority binding is structural, not optional.**  Every law
     declares `signed_by <actor>` and (for any non-trivial mutation)
     `authorized_by <policy>`.  The elaborator wires both into the
     §8.2 `Admissible` predicate automatically.  There is no "I
     forgot to advance the nonce" failure mode because the macro
     forbids omitting the binding.

  5. **Frozen indices are immovable.**  Each law commits to an
     `action_index: N` that becomes a wire-format commitment forever
     (CBE constructor tag, Genesis Plan §8.8).  The elaborator
     refuses any change that would break replay of historical logs.
     Version bumps within a fixed index are allowed only if they
     refine the old behaviour (provable refinement obligation).

  6. **Natural-language intent is part of the artefact.**  Every law
     carries an `intent` block — a markdown-typed natural-language
     statement that the deployment manifest's signature covers.  An
     amendment to the `intent` block without a corresponding code
     change requires the same governance signature as a code change.
     This prevents "policy laundering" where the executable
     behaviour stays put while the human-readable description
     silently drifts.

These principles compose: (1) and (2) make the executable layer
tractable; (3) and (4) make the contract layer mandatory; (5) and
(6) make amendment safe.  Drop any one and the others lose force.

## 5. Surface syntax

A Lex law is a single Lean `command` that opens with the `law`
keyword.  The body is a sequence of named *clauses*; clause order
inside the body is fixed (so reviewers always read the manifest
fields, then the formal text, then the contract, in the same
order).

### 5.1. Grammar

```ebnf
law             ::= "law" ident "(" params ")" "where" clause+

params          ::= (binder ("," binder)*)?
binder          ::= ident+ ":" type

clause          ::= header_clause
                  | body_clause

header_clause   ::= "identifier"   ident_path
                  | "version"      string_lit
                  | "action_index" nat_lit
                  | "intent"       md_block

body_clause     ::= "signed_by"     actor_expr           -- no `:=`; takes a single expression
                  | "authorized_by"  policy_expr          -- no `:=`; takes a single expression
                  | "pre"           ":=" pre_expr
                  | "impl"          ":=" impl_block
                  | "satisfies"     ":=" property_list
                  | "events"        ":=" event_block
                  | "proof"          ident ":=" tactic_block

ident_path      ::= ident ("." ident)*
md_block        ::= "{" raw_text_until_balanced_close "}"
pre_expr        ::= <restricted, see §6.1>
impl_block      ::= "do" do_stmt (";" do_stmt)*       -- statement-separated; semicolons explicit
                  | "[]"                              -- empty (no-op kernel-impl, no authority effect)
do_stmt         ::= "flow"   resource_expr amount_expr "from" actor_expr "to" actor_expr
                  | "mint"   resource_expr amount_expr "to"   actor_expr
                  | "burn"   resource_expr amount_expr "from" actor_expr
                  | "reward" resource_expr amount_expr "to"   actor_expr
                  | "for"    ident "in" bounded_iter "do" do_stmt
                  | "if"     pre_expr "then" do_stmt ("else" do_stmt)?
                  | "let"    ident ":=" term
                  | "register_key"   actor_expr "as" key_expr
                  | "freeze_resource" resource_expr
                  | <bare term, must have type State → State>
-- Note: `revoke_key` is intentionally omitted; the kernel ships
-- `KeyRegistry.revoke` but no corresponding `Action` constructor
-- (see §6.2 callout box).  Diagnostic L022 catches use.
-- Note: the `flow / mint / burn / reward` statements use *space-
-- separated* arguments (no colon mid-statement).  The earlier
-- proposal `flow r: amt from a to b` was rejected because a colon
-- between `r` and `amt` collides with Lean's type-ascription
-- syntax.

property_list   ::= "[" (property ("," property)*)? "]"
property        ::= "conservative"                          -- universal: claims `IsConservative t`
                  | "monotonic"                             -- universal: claims `IsMonotonic t`
                  | "local"             "[" resource_set "]"
                  | "freeze_preserving" "[" resource_set "]"
                  | "nonce_advances"    "[" actor_expr   "]"
                  | "registry_preserving"
                  | ident                                   -- user-defined

resource_set    ::= "{" (resource_expr ("," resource_expr)*)? "}"   -- finite, possibly empty
                  | "*"                                              -- all manifest-declared resources

event_block     ::= "do" emit_stmt (";" emit_stmt)*
                  | "[]"                                             -- no events
emit_stmt       ::= "emit" event_ctor (term)*
                  | "for" ident "in" bounded_iter "do" emit_stmt
                  | "if" pred_expr "then" emit_stmt ("else" emit_stmt)?
                  | "let" ident ":=" term

-- `pred_expr` (events-block predicate) is the §6.1 PreExpr grammar
-- extended with `getBalance postState …` references; events read
-- both pre- and post-state, while `pre_expr` reads only pre-state.
```

`bounded_iter` is any expression of type `List α` produced by
`BalanceMap.toList`, `KeyRegistry.toList`, `NonceState.toList`, or
the user's own helpers — concretely, anything Lean can recognise as
a finite list.  Streams, infinite sequences, and `IO`-monad iterators
are forbidden.

`tactic_block` is raw Lean tactic syntax.  It is the escape hatch
for `satisfies` items that the property-discharge library cannot
handle on its own (§6.4).

### 5.2. Worked example: `transfer` in Lex

```
law transfer (r : ResourceId) (sender receiver : ActorId) (amount : Nat)
where
  identifier   legalkernel.transfer
  version      "1.0.0"
  action_index 0

  intent {
    Move `amount` units of resource `r` from `sender` to `receiver`.
    Sender must have at least `amount` and `amount` must be positive.
    Self-transfer (sender = receiver) is a no-op on net balance and
    is permitted; the precondition still requires `amount > 0` and
    sufficient balance.
  }

  signed_by      sender
  authorized_by  deployment.transfer_policy sender r

  pre := fun s =>
    getBalance s r sender ≥ amount ∧ amount > 0

  impl := do
    flow r amount from sender to receiver

  satisfies := [
    conservative,
    monotonic,
    local             [{r}],
    freeze_preserving [*],
    nonce_advances    [sender],
    registry_preserving
  ]

  events := do
    let pre_sender   := getBalance preState r sender
    let pre_receiver := getBalance preState r receiver
    if amount > 0 then emit balanceChanged r sender   pre_sender   (pre_sender   - amount)
    if amount > 0 then emit balanceChanged r receiver pre_receiver (pre_receiver + amount)
```

This declaration is the *complete* source of truth for the
`transfer` law.  The current 7-edit hand-written form
(`Authority/Action.lean`'s `transfer` constructor + `compileTransition`
case + `Encoding/Action.lean` encode / decode / fieldsBounded cases
+ `Events/Extract.lean` event case + `Conservation.lean` /
`Laws/Transfer.lean`'s `IsConservative` and `IsMonotonic` instances)
is generated mechanically from it.  The `intent` block is the prose
the manifest signs.

### 5.3. Worked example: `mint` in Lex

```
law mint (r : ResourceId) (minter receiver : ActorId) (amount : Nat)
where
  identifier   legalkernel.mint
  version      "1.0.0"
  action_index 1

  intent {
    Create `amount` units of resource `r` in `receiver`'s balance.
    Authorised actors only; signature by `minter`.  Non-conservative
    by design — issues new supply.
  }

  signed_by      minter
  authorized_by  deployment.mint_policy minter r

  pre := fun _s => amount > 0

  impl := do
    mint r amount to receiver

  satisfies := [
    monotonic,
    local             [{r}],
    freeze_preserving [{r}],   -- minting on a frozen `r` is rejected by the deployment's freeze invariant
    nonce_advances    [minter],
    registry_preserving
  ]
  -- conservative is *not* claimed; mint is not IsConservative.
  -- Adding `conservative` to the list above would fail
  -- elaboration with diagnostic L004.

  events := do
    let pre_balance := getBalance preState r receiver
    if amount > 0 then emit balanceChanged r receiver pre_balance (pre_balance + amount)
```

### 5.4. Worked example: `replaceKey` in Lex

```
law replaceKey (actor : ActorId) (newKey : PublicKey)
where
  identifier   legalkernel.replaceKey
  version      "1.0.0"
  action_index 4

  intent {
    Rotate `actor`'s public key in the deployment's KeyRegistry.
    Signed by the actor's previous key (verified at admissibility
    time); the post-state has `newKey` registered for `actor`.
  }

  signed_by      actor
  authorized_by  deployment.identity_policy actor

  pre := fun _s => True

  impl := do
    register_key actor as newKey
    -- `register_key` is an *authority-layer* effect: it routes to
    -- `applyActionToRegistry`, not to `apply_impl`.  The kernel-level
    -- `apply_impl` is the identity here, matching the existing
    -- `Action.replaceKey` compiles-to-`Laws.freezeResource 0` design
    -- (see `LegalKernel/Authority/Action.lean` line 215).  The
    -- authority-layer effect is what the §6.5 elaboration generates.

  satisfies := [
    conservative,
    monotonic,
    local             [{}],       -- touches no resource at the kernel level
    freeze_preserving [*],
    nonce_advances    [actor]
    -- registry_preserving is *not* claimed; this law mutates the registry.
  ]

  events := do
    emit identityRegistered actor newKey
```

### 5.5. Lexical conventions

  * **Comments.**  Lean's `--` and `/- -/` work inside Lex as in any
    Lean file.  The `intent` block is *not* a comment; its content
    is captured into the elaborated declaration as a docstring.
  * **Whitespace.**  Significant only inside the `impl` and `events`
    `do` blocks (Lean 4 `do`-block alignment rules apply).  Header
    clauses are insensitive to indentation.
  * **Binders.**  Lex parameters use Lean binder syntax verbatim;
    instance binders (`[…]`), implicit binders (`{…}`), and strict
    implicit binders (`⦃…⦄`) are all valid.  This is what enables
    role-typed laws (§6.7) to be expressed without new syntax.
  * **Naming.**  Lex law names follow the project naming convention
    (CLAUDE.md: `snake_case`, no provenance tokens).  The `identifier`
    field is a fully-qualified path; conventionally
    `<organization>.<lawName>`, e.g. `legalkernel.transfer` for the
    kernel-shipped laws.

## 6. Elaboration semantics

A `law` declaration elaborates to **eight** Lean artefacts:

  1. a `def` of type `Transition` (the §4.4 record);
  2. an `Action` constructor at the declared `action_index`;
  3. a `compileTransition` branch (`Authority/Action.lean`);
  4. an `Action.encode` / `decode` branch pair
     (`Encoding/Action.lean`);
  5. a `fieldsBounded` branch (`Encoding/Action.lean`);
  6. an `extractEvents` branch (`Events/Extract.lean`);
  7. a `non_replaceKey_preserves_registry` branch
     (`Authority/SignedAction.lean`), unless the law is
     `replaceKey`-shaped;
  8. one `instance` per item of the `satisfies` list.

For v1, artefacts (2)–(7) are produced by a code-generation pass
(`lake exe lex_codegen`, §9) that *appends* into the existing
hand-written modules.  This preserves the closed-inductive shape of
`Action` without requiring Lean's macro system to extend an
inductive declaration in another module.  Artefacts (1) and (8) are
produced directly by the macro at the law's declaration site.

The cross-module nature of (2)–(7) is the reason §12's migration
plan is non-trivial.  V2 reorganises the kernel so the generated
file *is* `Authority/Action.lean` and a single source of truth lives
in the law declarations themselves.

### 6.1. The decidable precondition grammar (`Pre`)

The `pre` clause must elaborate to a value of type `State → Prop`
*and* the resulting predicate must satisfy `[DecidablePred pre]` via
`inferInstance`.  The macro emits

```lean
decPre := fun _ => inferInstance
```

verbatim and lets Lean's instance synthesizer fail loudly if the
precondition is not decidable.

To prevent the failure from being a 60-line elaboration trace, Lex
*restricts* the surface grammar to shapes that are guaranteed
instance-discharable.  The grammar is defined inductively:

```text
PreExpr  ::= true | false
           | PreExpr "∧" PreExpr | PreExpr "∨" PreExpr | "¬" PreExpr
           | "if" PreExpr "then" PreExpr "else" PreExpr
           | NatExpr ("≤" | "<" | "=" | "≠" | "≥" | ">") NatExpr
           | ActorExpr  ("=" | "≠") ActorExpr
           | ResourceExpr ("=" | "≠") ResourceExpr
           | "∀" ident "∈" BoundedIter "," PreExpr
           | "∃" ident "∈" BoundedIter "," PreExpr
           | UserPredicate Args                       -- must be tagged @[lex_pre]
NatExpr  ::= literal | ident | NatExpr ("+" | "-" | "*" | "/" | "%") NatExpr
           | "getBalance" Term Term Term
           | "expectsNonce" Term Term
           | UserNatFn Args                            -- must be tagged @[lex_pre]

BoundedIter ::= Term                                  -- Lean term of type List α
                                                      -- (caller's responsibility
                                                      -- that it is finite)
```

Forbidden in `pre`:

  * `∀ x : T, …` and `∃ x : T, …` without an `∈ <list>` bound;
  * `Classical.choose`, `Classical.byContradiction`, or any
    classical-logic primitive;
  * any term whose elaborated type is `Prop` but not
    `Decidable`-friendly (e.g. an opaque user predicate without
    `[Decidable …]`);
  * any expression that touches `IO`, `Task`, `IORef`, etc.;
  * recursive function calls (use bounded iteration over a list
    instead).

The grammar is enforced by a **post-parse pass** in the macro: after
elaborating `pre` to a `Term`, Lex walks the resulting expression
tree and rejects any node not in the grammar.  This produces a
diagnostic at the offending sub-expression's source location, not a
"failed to synthesize Decidable" error inside the generated `def`.

User-defined predicates and Nat-valued functions can be admitted to
the grammar via the `@[lex_pre]` attribute, which the elaborator
consults during the post-parse pass:

```lean
@[lex_pre]
def actor_is_compliant (registry : ComplianceRegistry) (a : ActorId) : Prop :=
  registry.contains a

instance (registry : ComplianceRegistry) (a : ActorId) :
    Decidable (actor_is_compliant registry a) := by
  unfold actor_is_compliant; infer_instance
```

A predicate annotated `@[lex_pre]` may then appear inside a `pre`
clause; absent the annotation, the post-parse pass refuses it with
diagnostic L003.  This makes the trust boundary explicit: every
extension to the precondition grammar is a typed, named addition
that a deployment can audit by `grep '^@\[lex_pre\]'`.

### 6.2. The flow calculus (`impl`)

`impl` is a `do`-block whose every statement is either a *kernel-
impl* mutator (a `State → State` function elaborated into the
generated `Transition.apply_impl`) or an *authority-layer* effect
(a `KeyRegistry → KeyRegistry` function elaborated into the
generated `applyActionToRegistry` branch).  The macro statically
classifies each statement and routes it accordingly; mixing both
kinds in one `impl` is supported (the `replaceKey` law is the
canonical example — its `apply_impl` is the identity, while its
authority-layer effect rotates the key).

The macro composes kernel-impl statements left-to-right via state
threading:

```text
impl := do f₁; f₂; …; fₙ        ↦       apply_impl s := fₙ (… (f₂ (f₁ s)))
```

Authority-layer statements thread analogously through the
registry.  At least one of the two effect kinds must be present for
every law (a law with no effects whatsoever is rejected with
diagnostic L021).

Using the actual kernel signatures (`getBalance s r a`,
`setBalance s r a v`), the primitives are:

| Primitive                                       | Effect kind   | Desugars to                                                                                  |
|-------------------------------------------------|---------------|----------------------------------------------------------------------------------------------|
| `flow r amt from a to b`                        | kernel-impl   | post-debit re-read pattern (§4.11 self-transfer fix preserved verbatim; see code block below) |
| `mint r amt to b`                               | kernel-impl   | `fun s => setBalance s r b (getBalance s r b + amt)`                                          |
| `burn r amt from a`                             | kernel-impl   | `fun s => setBalance s r a (getBalance s r a - amt)` (truncated `Nat` subtraction)            |
| `reward r amt to b`                             | kernel-impl   | identical to `mint` at the kernel level (definitionally equal); separate Action constructor   |
| `freeze_resource r`                             | kernel-impl   | `fun s => s` (identity; the freeze marker's effect is observed by other laws' `pre`)          |
| `register_key a as k`                           | authority     | `fun reg => KeyRegistry.register reg a k` (kernel-impl is identity for this branch)           |
| `for x in <list>: <stmt>`                       | host          | `(<list>).foldl (fun s' x => <stmt-as-fn> s') s`                                              |
| `if <pre> then <stmt₁> else <stmt₂>`            | host          | `if <decidable-pre> then <stmt₁-as-fn> s else <stmt₂-as-fn> s` (precondition decidable per §6.1) |
| `let x := e`                                    | host          | local binding; no state advance                                                               |

The `flow r amt from sender to receiver` desugaring is fixed to
the verbatim §4.11 pattern from `LegalKernel/Laws/Transfer.lean`
(lines 63–70):

```lean
fun s =>
  let fromBal := getBalance s r sender
  let s₁      := setBalance s r sender (fromBal - amt)
  -- Crucial: read receiver from s₁ (post-debit), not s.
  -- Self-transfer (sender = receiver) preserves the actor's balance.
  let toBal   := getBalance s₁ r receiver
  setBalance s₁ r receiver (toBal + amt)
```

This is the **one** place in the language where a user could choose
to deviate (by writing the raw `setBalance` calls themselves).  Lex
forbids that: a `do` block whose statements are bare `setBalance`
calls is rejected with diagnostic L010.  The reasoning is that the
self-transfer fix is subtle, has bitten the project before, and
should be enforced by macro rather than by review-time alertness.

> **Why no `revoke_key` primitive?**  The kernel ships
> `KeyRegistry.revoke` as a function but ships no corresponding
> `Action` constructor (`Authority/Action.lean` has only
> `replaceKey`; `Event.identityRevoked` is documented as "reserved
> for a future `revokeKey` Action constructor").  Adding `revoke_key`
> to Lex would require simultaneously adding the `Action`
> constructor and an `Event` constructor; that is a kernel
> amendment, not a Lex feature.  V3 admits it (§13.3); v1 forbids
> it (diagnostic L022).

For laws that need shapes outside the calculus (e.g. a per-resource
fold like `proportionalDilute`'s share computation), the law author
writes a *helper function* outside the `law` block, tags it
`@[lex_impl]`, and calls it from `impl`:

```lean
@[lex_impl]
def proportionalShare (totalReward myStake totalStake : Nat) : Nat :=
  totalReward * myStake / totalStake
```

The `@[lex_impl]` attribute marks the function as part of the
deployment-trusted impl surface.  It carries no theorem obligation
(the obligation lives in the calling law's `satisfies` block); the
attribute exists so tooling can list every term that contributes to
state mutation, and so `lex_lint` can refuse calls into untagged
helpers (diagnostic L023).

The bare-term escape hatch (`<bare term, must have type State →
State>` in §5.1's grammar) is the v1 escape hatch for laws not
expressible in the calculus.  V2 plans to remove it; see §13.

### 6.3. Authority binding (`signed_by` / `authorized_by`)

`signed_by <actor-expr>` is **mandatory**.  Its semantics are
two-fold:

  1. **Nonce-advance binding.**  The elaborator emits the `nonces :=
     advanceNonce es.nonces st.signer` step after `apply_impl`,
     wiring the per-actor monotonic-nonce guarantee
     (`expectsNonce_strict_mono` in `Authority/Nonce.lean`) without
     manual book-keeping.
  2. **Signer-identity strengthening.**  Lex *strengthens* the §8.2
     `Admissible` predicate beyond what the kernel currently
     enforces.  The kernel's existing `AdmissibleWith` checks the
     authorization policy and signature-under-registered-key but
     does not by itself enforce that `st.signer` equals any
     particular field of the action (that constraint lives in the
     deployment's `AuthorityPolicy`).  Lex's `signed_by sender`
     emits an additional propositional conjunct
     `st.signer = sender` that the elaborator inserts into the
     generated admissibility-check shim (the `myLaw_apply` wrapper
     below).  This closes a class of "actor X signs a transfer FROM
     actor Y" attacks that would otherwise depend on review-time
     diligence in the `AuthorityPolicy`.  The added constraint is
     decidable (via `DecidableEq ActorId`).

The generated apply wrapper has the shape (kernel-impl branch
only; the authority-layer branch threads the registry analogously
when `register_key` appears):

```lean
-- generated, elided from the user's view
def myLaw_apply
    (st : SignedAction) (es : ExtendedState)
    (h : Admissible … es st)
    (h_signer : st.signer = sender)            -- from `signed_by sender`
    : ExtendedState :=
  { es with
    base     := myLaw_impl es.base                -- from `impl := do …`
    nonces   := advanceNonce es.nonces st.signer
    registry := applyActionToRegistry st.action es.registry }   -- identity unless `register_key` appears
```

The `h_signer` hypothesis is supplied at the call site by the
deployment's authority policy (when the policy permits this signer
to issue this action with this `sender` field, the policy must
also imply `st.signer = sender`).  V2 lifts this from a side
condition into a kernel-level conjunct of `AdmissibleWith` so the
implication is structural, not policy-dependent.

`authorized_by <policy-expr>` is **mandatory** for any law that
mutates state observable to a third party (the kernel's `transfer`,
`mint`, `burn`, `reward`, `replaceKey`, `distributeOthers`,
`proportionalDilute`, `dispute`, `disputeWithdraw`, `verdict`,
`rollback` all qualify).  The expression evaluates to a
`Prop`-valued predicate of `(ActorId × Action)` resolved against
the deployment's `AuthorityPolicy` (Phase 3 WU 3.3).

A small number of laws affect only the signer's own state and may
omit `authorized_by` by writing `authorized_by self_only`.  The
elaborator allows this only when the `impl` block's static analysis
shows that every mutated balance / registry slot is keyed by the
signer.  Concretely: every `flow … from sender to …`,
`burn … from sender`, and `register_key sender …` is permitted; a
`flow … from <other>` or `mint … to <other>` while `self_only` is
declared is rejected with diagnostic L011.

A law without **any** `authorized_by` clause (not even `self_only`)
is a parse error.  The repeated forgetfulness around authorisation
in distributed systems is the headline lesson of the last fifteen
years of permissioned-ledger CVEs; Lex makes it impossible to ship a
law without confronting the question.

### 6.4. Property dispatch (`satisfies`)

The `satisfies` block is a list of property claims, each of which
the elaborator must discharge.  Discharge proceeds by matching the
property against a fixed library of *flow-pattern synthesizers*; if
no synthesizer matches, the elaborator emits diagnostic L004 naming
the property and the law.  The user can override by supplying a
`proof <property-name> := by …` clause for that specific property,
in which case the synthesizer is skipped and the user's tactic is
used as the instance body.

#### 6.4.1. Property vocabulary

The kernel's existing typeclasses
(`Conservation.lean`) are *universal over `ResourceId`*: an
`IsConservative t` instance asserts conservation at *every*
resource simultaneously, with the per-resource case-split handled
inside the synthesizer (combining a "preserves at `r`" theorem for
the law's primary resource with a "does not touch other resources"
theorem for every other `r' ≠ r`).  Lex's surface vocabulary
mirrors this universal shape:

  * `conservative` — claims `IsConservative t`; valid iff the
    `impl` is structurally non-supply-changing at every resource.
  * `monotonic` — claims `IsMonotonic t`; valid iff the `impl` is
    structurally non-supply-decreasing at every resource.

For properties whose natural shape is per-resource (locality,
freeze-preservation), Lex uses an *explicit set parameter*:

  * `local [{r₁, …, rₙ}]` — claims the `impl` touches no resource
    outside the named set.  Empty set `{}` is a registry-only law.
    The wildcard form `local [*]` is rejected (always trivially
    true; carries no information; diagnostic L024).
  * `freeze_preserving [{r₁, …, rₙ}]` — claims the law preserves
    the `FrozenForResource` invariant at each `rᵢ`.  Wildcard
    `freeze_preserving [*]` is shorthand for "every resource the
    deployment knows about" and is the common case.

For authority-layer properties:

  * `nonce_advances [a]` — derived from `signed_by a`; the
    synthesizer succeeds by definition.
  * `registry_preserving` — claims the `impl` contains no
    authority-layer effect.

The grammar consequently supports two property shapes (§5.1's
`property_list` is updated to match): unparameterised property
names (`conservative`, `monotonic`, `registry_preserving`) and
property-with-resource-set forms (`local [{…}]`,
`freeze_preserving [{…}]`).  An attempt to write `conservative
[r]` (with a per-resource argument) is rejected with diagnostic
L025 and the hint "the kernel's `IsConservative t` is universal
over `ResourceId`; drop the `[r]`".

#### 6.4.2. Underlying typeclasses

Lex's synthesizer uses the existing `IsConservative` and
`IsMonotonic` typeclasses unchanged.  Three new non-TCB
typeclasses are introduced as part of the v1 landing (§12.1's M1
checkpoint):

```lean
/-- `LocalTo S t` — applying `t` mutates only resources in `S`.  The
    structural analogue of the existing `*_does_not_touch_other_resources`
    family of lemmas (`Laws/Transfer.lean`, etc.). -/
class LocalTo (S : Std.TreeSet ResourceId compare) (t : Transition) : Prop where
  local_to : ∀ (r : ResourceId) (a : ActorId) (s : State),
             r ∉ S → t.pre s →
             getBalance (step_impl s t) r a = getBalance s r a

/-- `FreezePreserving S t` — `t` preserves `FrozenForResource` at every
    `r ∈ S`.  Wraps the existing `*_preserves_freeze` lemma family
    (`Laws/Freeze.lean`) into a typeclass. -/
class FreezePreserving (S : Std.TreeSet ResourceId compare) (t : Transition) : Prop where
  preserves : ∀ (r : ResourceId), r ∈ S →
              ∀ (snap : Option BalanceMap) (s : State),
              FrozenForResource r snap s → t.pre s →
              FrozenForResource r snap (step_impl s t)

/-- `RegistryPreserving t` — `t`'s authority-layer effect is the
    identity on `KeyRegistry`.  Trivial for every `Action`
    constructor except `replaceKey`. -/
class RegistryPreserving (t : Transition) : Prop where
  preserves : ∀ (es : ExtendedState) (st : SignedAction),
              -- (precise statement deferred; placeholder shape)
              True
```

These are *additions* to `Conservation.lean` and `Laws/Freeze.lean`,
not modifications of the kernel TCB.  The `tcb_audit` allowlist is
unchanged because the new typeclasses live in non-TCB modules.

#### 6.4.3. Synthesizer table

The v1 synthesizer library:

| Property                        | Discharge strategy                                                                                                                                                                  |
|---------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `conservative`                  | succeeds iff every kernel-impl statement of `impl` is `flow` / `freeze_resource` / `register_key`-as-no-op-on-balances OR `for` body that itself discharges; **fails** on any `mint`, `burn`, `reward`, or fold-of-non-conservative. |
| `monotonic`                     | succeeds on `flow` / `mint` / `reward` / `freeze_resource` / `register_key`; **fails** on `burn` (witnessed by `burn_not_monotonic`).                                              |
| `local [{r₁, …, rₙ}]`           | static analysis of `impl` collects the set of resources mentioned in `flow` / `mint` / `burn` / `reward` statements; succeeds iff this set is a subset of `{r₁, …, rₙ}`.            |
| `freeze_preserving [{r₁, …, rₙ}]` | succeeds iff every kernel-impl statement is on a resource ∉ `{r₁, …, rₙ}`, OR the precondition `pre` is decidable-incompatible with `FrozenForResource r snap s` for each `rᵢ`.   |
| `freeze_preserving [*]`         | shorthand for `freeze_preserving [{r}]` where `r` ranges over every resource the deployment manifest declares.  Resolved at manifest-elaboration time.                              |
| `nonce_advances [a]`            | derived: succeeds iff `signed_by a` is the law's binding.                                                                                                                           |
| `registry_preserving`           | succeeds iff the `impl` contains no `register_key` (or any other authority-layer mutator).                                                                                          |
| user-defined property `P`       | requires `proof P := by …` clause.  See §6.4.5.                                                                                                                                     |

Each synthesizer emits a Lean `instance` declaration whose body is
either a direct call to a known kernel theorem (e.g. for
`conservative` on a single-flow `impl`, the body is built from
`transfer_conserves` + `transfer_does_not_touch_other_resources`)
or a tactic block constructing the witness from the kernel-shipped
lemmas (`getBalance_setBalance_other`,
`transfer_does_not_touch_other_resources`, etc.).

#### 6.4.4. Synthesizer limitations

The synthesizers are **deliberately conservative**.  A law shaped
as `flow r amt₁ from x to y; flow r amt₂ from y to x` (a round
trip) is *informally* conservative but the structural-induction
synthesizer will not detect that.  A user who wants to claim
conservation in such a case provides a `proof conservative := by …`
override.  Similarly, fold-of-flow shapes
(`for x in <list>: flow …`) are not handled by the v1 monotonicity
synthesizer because the structural induction does not commute with
list folding without case-splitting on list emptiness;
`distributeOthers` is the canonical example
(see open question §14.4 and the worked example in §15.3 which
demonstrates the `proof monotonic := by exact distributeOthers_isMonotonic …`
override).

The point of the synthesizer is not to be clever — it is to be
*predictable* so reviewers can trust automatic discharge without
reading the proof.  V2 will extend the synthesizer to handle
fold-of-flow via the `List.foldl`-induction lemma already used in
`Laws/DistributeOthers.lean`.

#### 6.4.5. User-defined properties

User-defined properties are admissible:

```
satisfies := [
  conservative,
  KYC_compliant
]

proof KYC_compliant := by
  unfold KYC_compliant
  -- arbitrary Lean tactic block; the elaborator splices it in
  exact ⟨…⟩
```

The user-defined property must be a `Prop`-valued predicate over
the generated `def` (the `Transition` value), tagged with the
`@[lex_property]` attribute so that `lex_lint` can refuse references
to untagged identifiers (diagnostic L020):

```lean
@[lex_property]
def KYC_compliant (t : Transition) : Prop := …
```

User-defined properties are **not** required to be decidable.  They
do not enter the executable path; they are obligations the
deployment chooses to prove for governance reasons.

### 6.5. Action registration (`action_index`)

Every `law` declaration commits to an `action_index : N`.  The
elaborator enforces three rules:

  1. **Reserved range.**  Indices 0..11 are reserved for the
     kernel-built-in laws (the current 12 constructors of `Action`).
     A new law with `action_index < 12` is rejected with diagnostic
     L006.
  2. **Per-deployment uniqueness.**  Within a deployment manifest's
     law set, no two laws may share an `action_index`.  Collision
     produces diagnostic L005.
  3. **Immutability across versions.**  Once a law has been included
     in a tagged release of the deployment, its `action_index` is
     committed forever.  An attempt to renumber it produces
     diagnostic L007 (which is escalated to a build failure if the
     release is signed).

The mechanism for enforcing immutability across versions is a
checked-in registry file `lex_index_registry.txt`, structured as

```text
# format: <identifier>  <action_index>  <first_release>
legalkernel.transfer            0   v0.1.0
legalkernel.mint                1   v0.1.0
…
legalkernel.rollback           11   v0.6.0
my_deployment.staking_lock     12   v1.0.0
```

`lake exe lex_codegen` reads this file before emitting code; if a
`law` declaration's `action_index` disagrees with the registry, the
build fails.  Adding a new law adds a registry entry in the same
PR; removing a law removes the entry but leaves the index reserved
forever (a tombstone) so historical replay is unaffected.

The closed-inductive shape of `Action` is preserved through a
two-stage process.  Lean macros run *per-file* — there is no
global "accumulate all declarations" hook in Lean 4 — so the
elaborator cannot directly extend the `Action` inductive from a
sibling module.  Instead:

  1. **Per-file macro pass.**  Each `law` declaration emits its
     non-cross-module artefacts (the `Transition` `def`, the
     `satisfies` instance declarations, the `intent` docstring,
     and a small *codegen-input* file at
     `LegalKernel/_lex_inputs/<identifier>.json` capturing the
     declaration's metadata).
  2. **Build-time codegen pass.**  `lake exe lex_codegen` reads
     every codegen-input file, sorts them by `action_index`, and
     emits a single regenerated `Authority/Action.lean` (in v2)
     or a diff (in v1).  Constructor names are `Action.<lawName>`
     per the registry, so wire compatibility hinges on the index,
     not the surface name.

CI runs `lake exe lex_codegen --check` (§9.2) to ensure the
checked-in `Authority/Action.lean` matches the codegen output;
divergence fails the build with diagnostic L026.

For laws whose `impl` mutates the registry (currently only
`replaceKey`), the elaborator omits the auto-generated
`non_replaceKey_preserves_registry` branch and instead emits
explicit `replaceKey_*_registry` theorems modelled on the existing
WU 3.10 set.  V1 hand-codes these for `replaceKey` and refuses any
other registry-mutating law (diagnostic L012); v3 plans to admit
arbitrary registry-mutating laws once the dispatch over registry
effects is generalised (§13).

### 6.6. Event emission (`events`)

The `events` block is a `do`-style sequence of `emit <constructor>
<args>…` statements that elaborate to a branch of `actionEvents` in
`LegalKernel/Events/Extract.lean`.  The actual signature is

```lean
def actionEvents (preState postState : LegalKernel.State) (action : Action) :
    List Event
```

— the state arguments are `LegalKernel.State`, not `ExtendedState`,
because event extraction reads only balance / mutated cells; the
authority-layer `nonces` and `registry` views are surfaced via the
auto-emitted `nonceAdvanced` / `identityRegistered` events at the
top-level `extractEvents` wrapper.  Existing `Event` constructors
are camelCase per kernel convention (`balanceChanged`,
`nonceAdvanced`, `identityRegistered`); the argument order for
`balanceChanged` is `(r, actor, oldV, newV)` — old first, new
second — matching `Events/Types.lean` line 79.

A typical `events` block:

```text
events := do
  emit balanceChanged r sender   pre_sender   (pre_sender   - amount)
  emit balanceChanged r receiver pre_receiver (pre_receiver + amount)
```

elaborates to (roughly):

```lean
fun (preState postState : LegalKernel.State) =>
  let pre_sender   := getBalance preState r sender
  let pre_receiver := getBalance preState r receiver
  let evS := if amount > 0 then
               [Event.balanceChanged r sender   pre_sender   (pre_sender   - amount)]
             else []
  let evR := if amount > 0 then
               [Event.balanceChanged r receiver pre_receiver (pre_receiver + amount)]
             else []
  evS ++ evR
```

Lex's event block enforces three invariants:

  1. **Pre / post-state availability.**  The block has `preState`
     and `postState` in scope as `LegalKernel.State`.  References
     to a bare `s` are an error (diagnostic L027); use the explicit
     name to make the read site unambiguous.
  2. **Determinism.**  All event-emission expressions must be free
     of `IO` and `Task`.  This is statically checked.
  3. **Event-impl alignment (warning level).**  The elaborator
     computes the set of `(resource, actor)` cells the `impl`
     touches and warns (diagnostic L013) if the `events` block
     either omits an event for a touched cell or emits one for an
     untouched cell.  The warning is *not* an error in v1 because
     the existing `actionEvents` machinery already filters
     zero-deltas (every `balanceChanged` emission is conditional
     on `oldV != newV`; see `Events/Extract.lean` lines 122–123).
     A follow-up release may promote the warning to an error.

Events implicit from the authority layer are auto-emitted at the
top-level `extractEvents` wrapper, *not* in the per-action
`actionEvents` branch:
`Event.nonceAdvanced signer oldN newN` is always emitted (since
`signed_by` is mandatory).  A user `emit nonceAdvanced …` inside
an `events` block is allowed but produces a warning (L014)
recommending removal in favor of the wrapper's emission.

For a law with no per-action events (e.g. `freezeResource`), the
empty form `events := []` is permitted (and is the canonical
spelling — `events := do pure ()` and `events := do nothing` both
elaborate to the same empty list, but L013 prefers the explicit
empty list for clarity).

### 6.7. Resource roles (deferred to v3)

In a deployment with mixed resource types (e.g. currency vs voting
power vs allowance quota), it is desirable to enforce at parse time
that a payment law cannot be invoked with a voting-power resource.

The mechanism — *resource roles* — is a phantom-typed wrapper around
`ResourceId`:

```lean
structure Roled (ρ : Role) where
  raw : ResourceId

inductive Role where
  | currency
  | votingPower
  | allowance
  | custom (id : ByteArray)
```

A law parameterised on `(r : Roled .currency)` accepts only resources
the deployment tagged as currency.  At the kernel level, `Roled` is
a wrapper that erases to `ResourceId`; the role is purely a
parse-time / typecheck-time concern.

V1 defers this.  The current 12 kernel-built-in laws are all
`(r : ResourceId)`-shaped; introducing roles requires either a
breaking change to those signatures (rejected: too disruptive) or a
new layer of wrapper laws (acceptable, but not a v1 priority).
V3 will revisit once a deployment surfaces the mixed-role need
concretely.

The `intent` block of every v1 law should already document the
expected role of each resource parameter; this preserves the
human-language signal pending machine enforcement.

## 7. Deployment manifests

A **deployment manifest** is the second top-level Lex command.  It
binds a law set, an authority configuration, a deployment ID, a
list of invariant claims, and (in v2) an attestor key.  Manifests
are the auditor's entry point: they fit on one screen and name every
moving part the deployment depends on.

### 7.1. Manifest grammar

```ebnf
deployment ::= "deployment" ident "where" deployment_clause+

deployment_clause
   ::= "identifier"      ident_path
     | "deployment_id"   bytes_lit                      -- 32 bytes; flows into signInput
     | "version"         string_lit
     | "resources"       ":=" resource_list
     | "laws"            ":=" law_binding_list
     | "authority"       ":=" authority_binding_list
     | "invariant_claims" ":=" claim_list
     | "attestor"        ident                          -- v2: attestor key handle

resource_list
   ::= "[" (resource_decl ("," resource_decl)*)? "]"
resource_decl ::= ident "=" nat_lit ("as" Role)?

law_binding_list
   ::= "[" (law_binding ("," law_binding)*)? "]"
law_binding   ::= ident "=" ident_path "@" version_lit

authority_binding_list
   ::= "[" (authority_binding ("," authority_binding)*)? "]"
authority_binding ::= ident "=" policy_expr

claim_list
   ::= "[" (claim ("," claim)*)? "]"
claim ::= "monotonic_law_set"      "[" ident ("," ident)* "]"
        | "conservative_law_set"   "[" ident ("," ident)* "]"
        | "freeze_preserving_law_set"  "[" ident ("," ident)* "]"
        | ident                                          -- user-defined claim
```

### 7.2. Worked example: a USD-clearing manifest

```
deployment usd_clearing where
  identifier      example.usd_clearing
  deployment_id   0xDEADBEEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567
  version         "1.0.0"

  resources := [
    USD = 0  -- as currency  (role wrappers are v3)
  ]

  laws := [
    Transfer    = legalkernel.transfer    @ "1.0.0",
    Mint        = legalkernel.mint        @ "1.0.0",
    Freeze      = legalkernel.freeze      @ "1.0.0",
    ReplaceKey  = legalkernel.replaceKey  @ "1.0.0"
    -- explicitly absent:
    --   * legalkernel.burn (deflation forbidden)
    --   * legalkernel.reward (positive incentives forbidden)
    --   * legalkernel.proportionalDilute (no equity-style dilution)
  ]

  authority := [
    transfer_policy  = federation.transfer_policy_v2,
    mint_policy      = central_bank_only,
    identity_policy  = self_only_with_central_bank_recovery
  ]

  invariant_claims := [
    monotonic_law_set [Transfer, Mint, Freeze, ReplaceKey]
    -- conservative_law_set is *not* claimed: Mint is not IsConservative.
    -- Adding it here would fail elaboration with diagnostic L008.
  ]
```

### 7.3. Elaboration semantics

A `deployment` declaration elaborates to:

  1. a `def deployment_<name> : Deployment` (a record bundling all
     the manifest fields);
  2. one `def` per `invariant_claims` item, synthesising
     `MonotonicLawSet` / `ConservativeLawSet` / etc. values;
  3. a `def deployment_<name>_manifest_hash : ByteArray :=
     <CBE-hash of the manifest source bytes>` that the
     attestor signs in v2.

The most important elaboration step is the invariant-claim
synthesis.  Note that `MonotonicLawSet.laws : List Transition`
takes *transitions*, not law-name identifiers, so the manifest's
`laws := [Transfer, Mint, …]` block must first translate each
local name to its `Transition` value via the law's parameter
binding.  For a `monotonic_law_set [L₁, …, Lₙ]` claim where each
`Lᵢ` is a Lex-bound name with parameters `(p_i^1, …, p_i^{kᵢ})`,
the elaborator emits

```lean
def deployment_<name>_monotonic_law_set
    (params_for_each_Lᵢ_in_scope) : MonotonicLawSet where
  laws        := [L₁ p_1^1 … p_1^{k₁}, …, Lₙ p_n^1 … p_n^{kₙ}]
  isMonotonic := by
    intro t htL
    simp [List.mem_cons] at htL
    rcases htL with ⟨…⟩ | ⟨…⟩ | …
    all_goals (first | exact (L₁_isMonotonic …) | … | exact (Lₙ_isMonotonic …))
```

The `isMonotonic` field name (per `Conservation.lean` line 620)
matches the existing `MonotonicLawSet` structure exactly.

If any `Lᵢ` lacks the `IsMonotonic` instance, synthesis fails with
diagnostic L008 naming the offending law.  This is the type-level
firewall (§2 of `docs/economic_invariants.md`) made *deployment-time*
rather than per-PR-checklist.

For per-resource laws whose parameter binding is awkward at the
manifest level (transfer takes `r sender receiver amount`; the
manifest cannot pre-bind these without knowing the actions a-priori),
the manifest claims a *family* of monotonicity:

```lean
def deployment_<name>_monotonic_law_set : ∀ ps, MonotonicLawSet := …
```

with `ps` ranging over the action parameters.  The runtime adaptor
selects the appropriate instantiation per processed action.  V1
elides this complexity by having the manifest claim
`monotonic_law_set [Transfer, Mint, Freeze, ReplaceKey]` as a
*declarative* assertion (every constructor of these laws inhabits
`IsMonotonic`); the actual `MonotonicLawSet` value is constructed
on demand.

### 7.4. Cross-deployment-replay protection

The `deployment_id` field is a 32-byte unique identifier that flows
into Audit-3.3/3.4's `signingInput` parameterisation
(`Authority/SignedAction.lean` line 169):

```lean
def signingInput
    (action : Action) (signer : ActorId) (nonce : Nonce)
    (deploymentId : ByteArray) : SigningInput := …
```

A signature produced for `deployment_id = 0xDEAD…` will not verify
against any other deployment's `Verify` invocation because the
deployment-ID bytes are part of the message under signature
(via the length-prefixed concatenation that makes `signingInput`
injective in `(action, signer, nonce, deploymentId)`).

Concretely, the manifest elaborator emits two declarations that
together pin the deployment's admissibility predicate:

```lean
-- Generated from the manifest:
def deployment_<name>_id : ByteArray := <32-byte literal>

def deployment_<name>_admissible :
    ExtendedState → SignedAction → Prop :=
  AdmissibleWith Verify deployment_<name>_authority_policy deployment_<name>_id
```

The runtime adaptor (Phase 5's `Runtime.Loop.processSignedAction`)
is configured per-deployment to use `deployment_<name>_admissible`
in place of the back-compat `Admissible := AdmissibleWith Verify P
ByteArray.empty` alias.  Replay (`Runtime.Replay`) and snapshot
(`Runtime.Snapshot`) consumers thread the same identifier.

V1 ships the manifest's `deployment_id` field as a literal
`ByteArray` whose 32-byte length is checked at parse time
(diagnostic L018).  V2 may ship a "deployment-ID derivation"
sub-language (e.g. `BLAKE3(manifest_source_bytes)`) for deployments
that prefer derived IDs; whichever scheme is chosen, the canonical
form must be a pure function of inputs the manifest itself
records, so a counterparty can recompute it.

### 7.5. Manifest signing

In v1, the manifest is a Lean source file checked into the
deployment's repository.  Its identity is the source bytes; review
is by ordinary code review.

In v2, the manifest's CBE-hash is signed by an **attestor key**
(reusing the Audit-3.2 `AttestedSnapshot` machinery
`LegalKernel/Runtime/AttestedSnapshot.lean`).  The runtime checks
the attestation before bootstrapping; an unsigned or
incorrectly-signed manifest is refused.  This gives counterparties
a cryptographic anchor: they can verify that the operator runs the
manifest the attestor signed.

The `intent` blocks of every law in the manifest's law set are
*included in the bytes the attestor signs*.  Editing the prose
without re-attesting is detectable.

## 8. Governance and amendment

Amendments are the hardest part of any law-as-code system.  Lex
codifies five rules:

### 8.1. The five amendment rules

  1. **Action indices are immutable forever.**  Once a law has
     appeared in any tagged release of the deployment, its
     `action_index` is committed to the wire format.  Renumbering
     is rejected by `lake exe lex_lint` (diagnostic L007).  Removed
     laws leave their indices reserved as tombstones.

  2. **Versions follow semver, mechanically checked.**

     * **Patch** (`1.0.0 → 1.0.1`) — proof refactors only.  No
       change to `pre`, `impl`, `signed_by`, `authorized_by`,
       `satisfies`, `events`, or `intent`.  The `lex_diff` tool
       verifies this.
     * **Minor** (`1.0.1 → 1.1.0`) — refining changes.  The new
       `pre` must imply the old `pre` (the new behaviour is more
       restrictive); the new `impl` must agree with the old on the
       intersection of preconditions.  Refinement is a proof
       obligation discharged in a `proof refinement_v1.0.x := by …`
       clause that elaborates to a theorem of type
       `∀ s, oldPre s → newPre s ∧ (oldPre s → newImpl s = oldImpl s)`.
     * **Major** (`1.1.0 → 2.0.0`) — breaking changes.  Requires
       coordinated migration: deployments must opt in by bumping
       their manifest's law binding to the new version.  Old logs
       can still replay (the old version's `Action` constructor is
       preserved as a tombstone, separately registered at a
       different index).

  3. **`intent` covered by signature.**  The `intent` block is part
     of the manifest's signed bytes.  Editing it without bumping at
     least the patch version produces diagnostic L015 and is
     rejected by `lex_lint`.

  4. **`satisfies` weakening is breaking.**  Removing a property
     from `satisfies` is a major version bump (downstream consumers
     may be relying on it).  Adding a property is a minor version
     bump if synthesis succeeds, or a major bump if the new
     property requires an `impl` change.

  5. **Two-reviewer gate on TCB-touching changes.**  A change to a
     law whose generated artefacts include a TCB module
     (`Kernel.lean`, `RBMapLemmas.lean`) — currently impossible
     under the §6 design but enforced as a forward-protection rule
     — requires two reviewers per CLAUDE.md.

### 8.2. Amendment workflow

A typical amendment to `legalkernel.transfer` proceeds:

  1. Author edits the `law transfer` declaration.
  2. `lake exe lex_lint` runs, producing either a clean diff or
     diagnostics L001–L015.
  3. `lake exe lex_diff <old-sha> <new-sha>` produces a semantic
     diff:
     ```
     legalkernel.transfer:
       version: 1.0.0 → 1.1.0   (minor)
       pre:                     (refinement)
         + amount ≤ 2^32        (new bound)
       impl: unchanged
       satisfies: unchanged
       events: unchanged
       intent: unchanged
     ```
  4. The author supplies the refinement proof as `proof
     refinement_v1.0.x := …` in the new version.
  5. PR review proceeds with the semantic diff as the primary
     artefact, not the textual diff.
  6. On merge, the manifest of every consuming deployment must be
     re-attested (v2).

### 8.3. Sunset of laws

Removing a law from a deployment requires:

  1. The deployment's manifest is amended to omit the law from its
     `laws` block.
  2. The law's `Action` constructor remains in the kernel forever
     (tombstone) so historical logs can replay.
  3. New `SignedAction`s carrying the removed law's constructor are
     rejected at admissibility time (the deployment no longer
     authorises it).

This preserves the "no rewriting history" principle: replay of any
log written under any version of any manifest produces the same
state, even if the laws referenced have since been retired.

## 9. Tooling

Lex ships with a small CLI surface, modelled on the existing
`count_sorries` / `tcb_audit` / `stub_audit` tooling and added to
`lakefile.lean` as audit binaries.

### 9.1. `lake exe lex_lint`

The headline gate.  Walks every `.lean` file under
`LegalKernel/Laws/` and `Deployments/` (v2), parses the `law` and
`deployment` declarations, and checks:

  * mandatory clauses are present (`signed_by`, `authorized_by`,
    `satisfies`, `intent`, `action_index`);
  * `pre` expressions fit the §6.1 grammar;
  * `impl` blocks fit the §6.2 calculus;
  * `action_index` uniqueness and registry consistency
    (`lex_index_registry.txt`);
  * `satisfies` synthesizers terminate;
  * `intent` blocks are non-empty.

Exit non-zero on any failure with a precise location.  Run by CI
on every PR, modelled on the `lake exe count_sorries` pattern.

### 9.2. `lake exe lex_codegen`

The code-generation pass.  Reads every `law` declaration, emits the
seven supporting artefacts (constructors, encoding cases, event
cases, instance declarations) into the appropriate kernel modules,
and writes the result.

V1 mode: **append-only**.  Existing hand-written constructors are
preserved; new laws append.  The kernel-built-in laws are *not* yet
re-expressed in Lex form, so `lex_codegen` is purely additive.

V2 mode: **canonical regeneration**.  The kernel-built-in laws are
re-expressed in Lex; `lex_codegen` regenerates `Authority/Action.lean`
in full.  At this point, manual edits to that module are rejected
by CI.

### 9.3. `lake exe lex_diff <ref-a> <ref-b>`

Semantic diff of two repository revisions.  Outputs per-law and
per-deployment changes in a format intended for PR descriptions:

```
legalkernel.transfer:
  version: 1.0.0 → 1.1.0   (minor — refinement)
  pre:                     diff:
    @@ -1,2 +1,3 @@
       amount > 0
       ∧ getBalance s r sender ≥ amount
    +  ∧ amount ≤ 2^32
  impl: unchanged
  satisfies: unchanged
  events: unchanged
  intent: unchanged
```

The diff is computed on the *parsed* AST, not the source bytes,
so reformatting and comment changes do not appear.

### 9.4. `lake exe lex_format`

Pretty-printer.  Rewrites a `.lean` file containing `law` /
`deployment` declarations into the canonical form (clause order,
indentation, blank-line conventions).  Idempotent.  Run by `pre-
commit` hooks if a deployment elects.

### 9.5. LSP integration (deferred to v3)

A Lean LSP extension that surfaces:

  * surface-error red squiggles (with diagnostic codes);
  * hover tooltips showing the discharged `satisfies` instances;
  * "go-to-impl-of-flow" navigation;
  * `intent`-block markdown rendering.

Deferred because it requires extending Lean's LSP server, a
non-trivial standalone PR that is best landed once the v1 macro
syntax is stable.

### 9.6. Property-test harness (auto-generation)

The Audit-3.9 in-tree property harness
(`LegalKernel/Test/Property.lean`) can auto-generate property tests
from `satisfies` claims:

  * `conservative` ⇒ a property test that draws random
    `(state, sender, receiver, amount, resource)` tuples, applies
    the law, and asserts `totalSupply post r = totalSupply pre r`
    for every resource `r` (the universal-over-`r` shape of the
    `IsConservative` typeclass).
  * `monotonic` ⇒ the same shape with `≥` instead of `=`.
  * `local [{r₁, …, rₙ}]` ⇒ a test that asserts every resource ∉
    `{r₁, …, rₙ}` is pointwise-unchanged.

`lake exe lex_codegen` emits an auto-generated test file
(`LegalKernel/Test/Properties/AutoGen.lean`) with one harness call
per `(law, property)` pair.  The CI gate runs them at a default
sample count of 100 (overrideable via `CANON_PROPERTY_ITERATIONS`).

## 10. Diagnostics

Lex emits structured diagnostics with stable, numbered codes so CI
can pin specific failure modes and so deployment authors can search
documentation by code.

### 10.1. Diagnostic catalogue

| Code  | Meaning                                                      | Severity | Remediation                                                                       |
|-------|--------------------------------------------------------------|----------|-----------------------------------------------------------------------------------|
| L001  | Missing `signed_by` clause                                   | error    | Add `signed_by <actor>` naming the actor whose nonce should advance.              |
| L002  | Missing `satisfies` clause                                   | error    | Add `satisfies := […]` listing at least the properties relevant to your law.      |
| L003  | Precondition contains undecidable subexpression `<expr>`     | error    | Replace `<expr>` with a §6.1-grammar shape, or tag the helper `@[lex_pre]`.       |
| L004  | Property `<P>` not synthesizable for law `<L>`               | error    | Either weaken `satisfies` or supply `proof <P> := by …` with a manual witness.    |
| L005  | Action index `<N>` already used by law `<L>`                 | error    | Allocate a fresh index ≥ 12 and update `lex_index_registry.txt`.                  |
| L006  | Action index `<N>` reserved (kernel-built-in range 0..11)    | error    | Allocate `<N> ≥ 12`.                                                              |
| L007  | Action index renumbered from `<old>` to `<new>` for `<L>`    | error    | Restore the original index; renumbering is forbidden.                             |
| L008  | Manifest invariant claim `<C>` not satisfiable               | error    | Either drop the claim or add the missing law's instance.                          |
| L009  | Missing `authorized_by` clause                               | error    | Add `authorized_by <policy>` or, if appropriate, `authorized_by self_only`.       |
| L010  | Bare `setBalance` call in `impl`                             | error    | Use `flow` / `mint` / `burn` / `reward` primitives.                               |
| L011  | `self_only` declared but `impl` mutates non-signer state     | error    | Add an `authorized_by` policy or restrict `impl` to signer-keyed mutations.       |
| L012  | Registry-mutating law other than `replaceKey` (v1)           | error    | Defer to v3, or hand-write the registry-effect theorems and disable lex_codegen.  |
| L013  | `events` block omits or duplicates a balance change          | warning  | Align `events` with the cells `impl` touches, or accept the auto-filter.          |
| L014  | Manual emission of an auto-emitted event                     | warning  | Remove the manual `emit`; the elaborator will add the canonical form.             |
| L015  | `intent` block edited without version bump                   | error    | Bump at least the patch version when editing `intent`.                            |
| L016  | Refinement proof missing for minor version bump              | error    | Supply `proof refinement_v<old> := by …`.                                         |
| L017  | Major version bump without action-index reservation          | error    | Allocate a new tombstone index or use a major-bump mechanism documented in §8.    |
| L018  | Manifest `deployment_id` not 32 bytes                        | error    | Pad to exactly 32 bytes; deployment IDs are fixed-width.                          |
| L019  | `for x in <iter>:` body's iter is not statically a `List α`  | error    | Convert via `.toList` or use a different bounded iterator.                        |
| L020  | Unknown property `<P>` referenced in `satisfies`             | error    | Tag a `def <P>` with `@[lex_property]` and provide a `proof <P> := …` clause.     |
| L021  | Law has no kernel-impl effects and no authority-layer effects | error    | Add at least one statement to `impl`; a no-effect law is not expressible.         |
| L022  | `revoke_key` used but no `Action.revokeKey` constructor      | error    | Defer to v3; the kernel does not yet ship a `revokeKey` Action constructor.       |
| L023  | `impl` calls a helper not tagged `@[lex_impl]`               | error    | Tag the helper with `@[lex_impl]` so the deployment-trusted-impl surface is auditable. |
| L024  | `local [*]` claim (always trivially satisfied)               | error    | Replace with `local [{r₁, …, rₙ}]` naming the touched resources, or drop the claim. |
| L025  | Per-resource argument `[r]` to `conservative` / `monotonic`  | error    | Drop the `[r]`; the kernel's `IsConservative` / `IsMonotonic` are universal over `ResourceId`. |
| L026  | `lex_codegen --check` finds checked-in artefact divergence   | error    | Run `lake exe lex_codegen` and commit the regenerated files.                      |
| L027  | Bare `s` reference inside `events := do …`                   | error    | Use the explicit `preState` or `postState` name; `s` is ambiguous.                |

### 10.2. Diagnostic format

Each diagnostic prints in a consistent format:

```text
<file>:<line>:<col>: error: L004: Property `conservative` not synthesizable for law `myLaw`
  --> note: structural induction on `impl` failed; offending statement is
  --> note:   mint r amount to receiver
  --> note: at <file>:<line>:<col>.
  --> hint: `mint` is non-conservative by design.  Consider:
  --> hint:   - dropping `conservative` from `satisfies`;
  --> hint:   - replacing `mint` with `flow`;
  --> hint:   - supplying `proof conservative := by …` with a manual witness.
```

The file/line/col is anchored at the *surface syntax* (the user's
`law` declaration), not at the macro-expanded Lean term.  This is
the diagnostic-translation layer §3 referenced; it works by walking
the macro-expansion tree, finding the nearest source-mapped node,
and re-emitting the diagnostic at that location.

### 10.3. CI gates

The Lex CI gate set extends the existing kernel gates:

```bash
lake build                # existing
lake test                 # existing
lake exe count_sorries    # WU 1.12 — kernel-TCB sorry count
lake exe tcb_audit        # WU 1.11 — TCB import allowlist
lake exe stub_audit       # Audit-3.8 — stub-detection
lake exe lex_lint         # NEW — Lex parse, grammar, registry, claims
lake exe lex_codegen --check  # NEW — generated artefacts up to date
```

`--check` mode runs `lex_codegen` and fails if its output differs
from what is checked in.  This is the equivalent of
`gofmt -d -check`: regeneration is mechanical, but the generated
files are committed so that reviewers can diff them directly.

## 11. Deliberate exclusions

The following are *deliberately* not in Lex.  Each was considered
and rejected for a specific reason; this section is the project's
record of those rejections so they are not relitigated in
unstructured GitHub comments.

  * **I/O.**  Laws are pure state functions.  Reading from external
    sources is the runtime adaptor's responsibility (Phase 5);
    laws receive `(preState, action)` and produce `postState`.
    Allowing `IO` would break determinism, reproducibility, and the
    replay-for-audit property.

  * **Wall-clock time.**  Time enters the kernel only as data via
    signed `timeRecorded` events.  A law that wants to compare
    against "now" reads from a designated time-bearing actor's
    state.  This makes time auditable and replayable.

  * **Randomness.**  Cryptographic operations are part of the trust-
    assumption stack (the `Verify` opaque, Phase 5's `Runtime.Hash`),
    not the law surface.  Randomness in laws would either be fake
    (PRNG seeded by state — useless) or non-deterministic
    (forbidden).

  * **Exceptions.**  Lex preconditions and `Result`-typed checks
    cover what exceptions would.  Exception flow control is hard to
    reason about under refinement and would obscure the
    Genesis-Plan §4.5 `step_impl` semantics.

  * **Mutation outside the kernel-allowed set.**  `setBalance` is
    the only balance mutator; `KeyRegistry.register` / `revoke` are
    the only registry mutators; `advanceNonce` is auto-emitted.
    Lex's calculus exposes wrappers; the bare primitives are not
    callable from `impl` (§6.2 diagnostic L010).

  * **Reflection / introspection of kernel state.**  Lex laws cannot
    enumerate `BalanceMap.toList` of the entire `State`.  They can
    bound-iterate a deployment-specific actor list provided as a
    parameter.  This preserves the per-action-cost discipline (the
    runtime can bound the work per action).

  * **Turing-completeness in `pre`.**  `pre` is a decidable
    predicate built from a closed grammar.  Recursion is forbidden.
    Bounded iteration over a known-finite list is allowed.  This
    keeps `decide`-driven evaluation tractable and rules out
    decidability-undermining shapes.

  * **Floating-point.**  All amounts are `Nat`.  Floating-point's
    well-known associativity and rounding pathologies make refinement
    proofs unreasonable.

  * **Strings beyond bare necessities.**  CBE encodes strings as
    bounded byte arrays; the kernel does not depend on Unicode
    semantics.  Strings appear only in user-facing fields like
    `intent` (which is text but not interpreted at runtime).

  * **Ambient `Classical.choice`.**  Already forbidden in `pre` by
    §6.1.  Lex laws may use `Classical.choice` in their *proofs*
    (the kernel admits the three Lean built-in axioms), but never
    in executable `apply_impl` paths.

## 12. Migration plan

The Lex v1 implementation lands in three checkpoints.  Each is a
separable PR with its own CI gate.

### 12.1. Checkpoint M1: macro skeleton + v1-additive `lex_codegen`

  * Add `LegalKernel/DSL/LexLaw.lean` exposing the new `law` macro
    (alongside the existing Phase-4 macro, which keeps working).
  * Add `LegalKernel/DSL/LexProperty.lean` with the synthesizer
    library (§6.4).
  * Add `Tools/LexLint.lean` and `Tools/LexCodegen.lean` (audit
    binaries with the same shape as `Tools/CountSorries.lean`).
  * Add `lex_index_registry.txt` initialised with the 12 existing
    constructors.
  * No existing law is touched; the new macro runs in parallel with
    the old.
  * CI adds `lake exe lex_lint` (no-op until a Lex law is added).

Acceptance: a stub `legalkernel.example_lex_only_law` declared in
`LegalKernel/Laws/ExampleLex.lean` elaborates cleanly, generates
the seven artefacts, passes `lex_lint`, and `lake test` passes.

### 12.2. Checkpoint M2: re-express the 12 kernel-built-ins in Lex

  * Migrate `transfer`, `mint`, `burn`, `freezeResource`,
    `replaceKey`, `reward`, `distributeOthers`, `proportionalDilute`,
    `dispute`, `disputeWithdraw`, `verdict`, `rollback` to Lex
    declarations.
  * `lex_codegen` flips to **canonical regeneration** mode for the
    files it now owns:
    * `Authority/Action.lean` (constructors + `compileTransition`);
    * `Encoding/Action.lean` (encode / decode / fieldsBounded);
    * `Events/Extract.lean` (event branches);
    * `Authority/SignedAction.lean`'s
      `non_replaceKey_preserves_registry`.
  * The hand-written instance proofs (`transfer_isConservative`
    etc.) are replaced by synthesizer-generated equivalents; the
    *theorem statements* and their use sites are unchanged so the
    rest of the kernel sees no API drift.
  * The Phase-4 `Law.mk` macro and its `transferDSL` example are
    deprecated (kept compiling for one minor version, then removed).

Acceptance: every existing test passes byte-for-byte; the test
count is unchanged; `#print axioms` on every kernel theorem still
returns `[propext, Classical.choice, Quot.sound]`; the diff is
removal of hand-written cases plus addition of the Lex declarations
plus regenerated artefact files.

### 12.3. Checkpoint M3: deployment manifests + governance tooling

  * Add `LegalKernel/DSL/LexDeployment.lean` with the `deployment`
    macro.
  * Add `Tools/LexDiff.lean` (semantic diff) and `Tools/LexFormat.lean`
    (pretty-printer).
  * Wire `lex_lint` to validate `deployment_id` length, registry
    consistency, claim synthesis.
  * Add a worked-example deployment under `Deployments/Examples/`
    (USD-clearing-style, illustrative only).
  * Document the amendment workflow (§8) with a checked-in
    walkthrough of bumping `legalkernel.transfer` from `1.0.0` to
    `1.1.0` (refinement adding an upper bound on `amount`).

Acceptance: the example deployment elaborates, attestations are
valid, the worked-example minor-bump exercises the refinement-proof
mechanism end-to-end.

### 12.4. Risk and rollback

The high-risk step is M2: it *replaces* the hand-written
`Authority/Action.lean` etc. with generated versions.  If the
synthesizer is buggy, the kernel could silently lose an
`IsConservative` instance, breaking downstream refinement proofs.
Mitigations:

  1. M2 lands behind a `lex_codegen --check` CI gate that rejects
     any divergence between hand-written and generated forms during
     the migration window.
  2. The migration proceeds law-by-law (one Lex declaration per
     PR), so any regression is bisectable.
  3. The post-M2 commit retains the pre-M2 hand-written files in
     `legacy/Authority_Action_pre_lex.lean` for a release window;
     the rollback is `git revert`.

If a serious problem is discovered post-M2, the rollback path is to
revert the M2 PR and continue maintaining hand-written code.  M1
and M3 are independent and remain useful even without M2.

## 13. Roadmap

### 13.1. v1 (this document)

  * `law` macro extended with mandatory `signed_by`,
    `authorized_by`, `satisfies`, `intent`, `action_index`.
  * `flow` / `mint` / `burn` / `reward` / `register_key` /
    `freeze_resource` primitives in `impl`.  (`revoke_key` is
    deferred to v3; the kernel does not yet ship a `revokeKey`
    Action constructor — see §6.2 callout box.)
  * Property synthesizer library covering `conservative`,
    `monotonic`, `local`, `freeze_preserving`, `nonce_advances`,
    `registry_preserving`.
  * `deployment` manifest macro with `invariant_claims`.
  * `lex_lint`, `lex_codegen` (additive mode), `lex_diff`,
    `lex_format` audit binaries.
  * Migration plan M1 + M2 + M3 (§12).
  * Diagnostics L001–L020 with stable codes.

### 13.2. v2

  * Manifest signing via attestor key (Audit-3.2 reuse).
  * `lex_codegen` canonical-regeneration mode.
  * Removal of the bare `<term : State → State>` escape hatch in
    `impl` (§5.1) — every law expressible in the calculus.
  * Cross-deployment-replay protection at the manifest level
    (deployment-ID derivation sub-language).
  * LSP integration (basic — error squiggles, instance hovers).
  * Auto-generated property test harness (§9.6) wired by default.

### 13.3. v3

  * Resource roles (§6.7).  Phantom-typed `Roled ρ` wrappers; per-
    deployment role table.
  * Deployment-private laws (Action-extension via per-deployment
    Action types; runtime-adaptor dispatch).
  * Admission of arbitrary registry-mutating laws beyond `replaceKey`.
  * LSP integration (advanced — `intent`-block markdown rendering,
    "go-to-impl-of-flow" navigation).
  * Custom dispute-claim variants declared in Lex (Genesis-Plan
    §8.4 amendment, requires kernel review).

### 13.4. Beyond v3

Speculative; not committed:

  * Cross-language client-side library that consumes the manifest
    bytes and produces code in a host language (Rust, Python,
    TypeScript).  This is the "external implementer" of
    `docs/abi.md` §1, lifted to the law level.
  * Incremental property re-discharge: when a law's `impl` changes,
    re-run only the affected synthesizers.
  * Property-rich CHIP-style proposals: a deployment proposes an
    amendment; tooling generates the semantic diff, the proof
    obligations, and the migration path automatically.

## 14. Open questions

The design above is concrete and shippable, but several questions
remain genuinely unresolved.  Listing them here keeps the document
honest.

  1. **Refinement of `pre` across versions.**  §8.1 says a minor
     bump's new `pre` must imply the old `pre` (the new behaviour is
     more restrictive).  Is this right?  Some refinements *weaken*
     `pre` (the law accepts more inputs); the implementation
     constraint then is that the *behaviour* on the old domain is
     unchanged.  V1 may need both directions.  Open: which
     direction is the *default*, and how does the macro syntax
     distinguish them?

  2. **In-flight signed actions across amendments.**  A signed
     action admissible at law version 1.0.0 may not be admissible
     at version 1.1.0 if `pre` strengthens.  The deployment must
     either reject in-flight actions on amendment (operational pain)
     or queue them for replay against the new version (correctness
     hazard).  Open: does Lex specify a default policy?

  3. **Cross-law invariant synthesis.**  Many invariants are
     statements about *the law set*, not individual laws (e.g. "no
     two laws can grant the same actor minting authority").  These
     belong in the manifest's `invariant_claims` block, but the
     synthesizer library is empty for them in v1.  Open: what is
     the v2 vocabulary for cross-law claims?

  4. **Compositional property dispatch over fold-of-flow.**  A
     law whose `impl` is a sequence of `flow`s on different
     resources is `conservative` if each flow individually
     conserves its own resource (the synthesizer handles this via
     structural induction).  But a law whose `impl` is `for x in
     <list>: flow …` is not handled by the v1 synthesizer because
     the structural induction does not commute with list folding
     without case-splitting on list emptiness.
     `Laws/DistributeOthers.lean` has this exact proof structure
     (a `List.foldl`-induction over `mint` calls); v1 falls back
     to `proof monotonic := by exact distributeOthers_isMonotonic …`.
     Open: in v2, can the synthesizer auto-discharge fold-of-flow
     by emitting a tactic block that performs the same
     `List.foldl`-induction the existing kernel proofs use?

  5. **Property-test seed reproducibility across hosts.**
     Audit-3.9's harness is deterministic given a seed; auto-
     generated tests should record the seed in the test output so
     CI failures are reproducible locally.  Open: where does the
     seed live — env var, embedded literal, or a separate seeds
     file?

  6. **Deployment-ID derivation.**  V2's planned derivation sub-
     language is unspecified.  Should the deployment ID be `SHA-256
     (organisation || version || nonce)`?  `BLAKE3 (manifest source
     bytes)`?  A user-selected scheme?  Open: what is the canonical
     form, and how does it interact with manifest signing?

  7. **Role types vs role values.**  §6.7 sketches phantom-typed
     `Roled ρ`.  An alternative is a runtime predicate `HasRole r ρ`
     decided against a deployment table, with no type-level
     wrapping.  The runtime form integrates more cleanly with the
     existing `(r : ResourceId)` signatures; the phantom form
     catches errors at parse time.  Open: which approach is the v3
     default?

  8. **`pre`-grammar extensibility through `@[lex_pre]`.**  The
     `@[lex_pre]` attribute makes the trust boundary explicit, but
     a malicious deployment could tag a non-decidable predicate
     with `@[lex_pre]` and rely on instance synthesis to fail
     opaquely.  Open: should `@[lex_pre]` require a `Decidable`
     instance to be present at the *attribute* level (rejected if
     the instance fails to synthesize for any input)?

  9. **Signer-identity-strengthening lift to the kernel.**  §6.3
     adds an `st.signer = <named-actor>` propositional conjunct
     at every law's call site, supplied by the deployment's
     authority policy.  This works but is structurally
     side-conditional: the constraint depends on the policy
     implying it, not on the kernel enforcing it.  V2 should
     consider lifting this into `AdmissibleWith` itself — for
     example by extending `Action` constructors with an
     "intended signer" field that the kernel checks against
     `st.signer` directly.  Open: does this break wire
     compatibility with existing logs, and if so, is a major
     bump tolerable for the security gain?

These questions do not block v1.  They are open in the sense of
"resolve before committing to v2" — none of them require breaking
the v1 surface.

## 15. Worked examples

This section sketches additional laws beyond §5.2–5.4 to exercise
the language.  These are illustrative; they correspond to existing
kernel modules and are intended to demonstrate that Lex captures
each one without losing fidelity.

### 15.1. `burn` — non-monotonic

```
law burn (r : ResourceId) (burner : ActorId) (amount : Nat)
where
  identifier   legalkernel.burn
  version      "1.0.0"
  action_index 2

  intent {
    Destroy `amount` units of resource `r` from `burner`'s balance.
    Authorised actors only; signature by `burner`.  Non-monotonic
    by design — reduces supply.
  }

  signed_by      burner
  authorized_by  deployment.burn_policy burner r

  pre := fun s => getBalance s r burner ≥ amount ∧ amount > 0

  impl := do
    burn r amount from burner

  satisfies := [
    local             [{r}],
    freeze_preserving [{r}],
    nonce_advances    [burner],
    registry_preserving
  ]
  -- Neither `conservative` nor `monotonic` is claimed.
  -- The kernel ships `burn_not_conservative` and `burn_not_monotonic`
  -- as negative witnesses.

  events := do
    let pre_balance := getBalance preState r burner
    if amount > 0 then emit balanceChanged r burner pre_balance (pre_balance - amount)
```

### 15.2. `freezeResource` — registry- and balance-preserving marker

```
law freezeResource (governanceActor : ActorId) (r : ResourceId)
where
  identifier   legalkernel.freezeResource
  version      "1.0.0"
  action_index 3

  intent {
    Mark resource `r` as frozen.  Future `transfer` / `mint` / `burn`
    invocations on `r` are rejected by their preconditions in any
    deployment that consumes the `FrozenForResource` invariant.
    This law itself is a no-op on the underlying `BalanceMap`.
  }

  signed_by      governanceActor
  authorized_by  deployment.governance_policy governanceActor r

  pre := fun _s => True

  impl := do
    freeze_resource r

  satisfies := [
    conservative,
    monotonic,
    local             [{}],          -- touches no balance cell
    freeze_preserving [*],
    nonce_advances    [governanceActor],
    registry_preserving
  ]

  events := []
  -- No per-action events; the freeze marker is observable only via
  -- the auto-emitted `nonceAdvanced` from `signed_by` and via
  -- subsequent laws' `pre` rejections.  The §6.6 canonical empty
  -- form is `events := []`.
```

Note that the actual `Action.freezeResource` constructor takes only
`(r : ResourceId)` (`Authority/Action.lean` line 134); the
`governanceActor` parameter above is *Lex-level only* and is bound
into the `signed_by` constraint via the macro's
`st.signer = governanceActor` strengthening (§6.3.2).  The
generated `Action.freezeResource` constructor remains unchanged
on the wire.

### 15.3. `distributeOthers` — fold-of-flow

```
law distributeOthers
    (rewarder : ActorId) (r : ResourceId) (excluded : ActorId) (amount : Nat)
where
  identifier   legalkernel.distributeOthers
  version      "1.0.0"
  action_index 6

  intent {
    Issue `amount` units of `r` to every actor with a non-zero
    balance at `r`, except `excluded`.  Each recipient receives
    the same flat `amount`; this is *not* proportional to existing
    balance.  The recipient list is computed from
    `affectedActors preState r excluded` (which extracts the
    non-excluded keys of the resource's `BalanceMap`); the kernel
    bounds the work per action by the size of that map.
  }

  signed_by      rewarder
  authorized_by  deployment.reward_policy rewarder r

  pre := fun _s => amount > 0

  impl := do
    -- `affectedActors preState r excluded` is the bounded
    -- iterator: the non-excluded keys of `preState.balances[r]?`.
    -- This matches `Events/Extract.lean`'s `affectedActors` helper.
    for recipient in affectedActors_at r excluded:
      mint r amount to recipient

  satisfies := [
    monotonic,
    local             [{r}],
    freeze_preserving [{r}],
    nonce_advances    [rewarder],
    registry_preserving
  ]

  proof monotonic := by
    -- The structural-induction synthesizer does not (in v1) handle
    -- fold-of-mint over a list.  We discharge it manually via
    -- `Laws.distributeOthers_isMonotonic` (`Laws/DistributeOthers.lean`
    -- line 254) from the existing kernel.
    exact distributeOthers_isMonotonic r excluded amount

  events := do
    -- `actionEvents` for `distributeOthers` (Extract.lean line 148–149)
    -- delegates to `balanceChangeEvents preState postState r
    -- (affectedActors preState r excluded)`.  Lex's elaborator
    -- generates the equivalent inline form below.
    for recipient in affectedActors_at r excluded:
      let oldV := getBalance preState  r recipient
      let newV := getBalance postState r recipient
      if oldV ≠ newV then emit balanceChanged r recipient oldV newV
```

The `Action.distributeOthers` constructor itself takes only
`(r : ResourceId) (excluded : ActorId) (amount : Amount)` per
`Authority/Action.lean` line 148; the Lex-level `rewarder`
parameter is bound by `signed_by` into the
`st.signer = rewarder` constraint as described in §6.3.2.

This example exercises four mechanisms simultaneously:

  * the `for x in <bounded-list>:` loop construct, where the
    bounded iterator is the deployment-defined helper
    `affectedActors_at` reading the pre-state's `BalanceMap` keys;
  * a `proof <P> := by …` override for a property the v1 synthesizer
    cannot mechanically discharge (open question §14.4);
  * unconditional event emission inside a loop, with the
    elaborator-generated zero-delta filter (`if oldV ≠ newV`)
    matching the existing `actionEvents` semantics.

### 15.4. `dispute` — claim-bearing administrative law

```
law dispute (d : Dispute)
where
  identifier   legalkernel.dispute
  version      "1.0.0"
  action_index 8

  intent {
    File a §8.4 dispute against an existing log entry.  The kernel-
    level mutation is a no-op (the dispute is a structured marker
    written to the log; subsequent verdict actions consume it).
    The dispute pipeline's stage-1 acceptance is enforced at the
    runtime layer (`Disputes.fileDispute`), not by this law's
    `pre`.
  }

  signed_by      d.challenger
  authorized_by  deployment.dispute_policy d.challenger

  pre := fun _s => True

  impl := do
    -- All four dispute-pipeline action ctors compile to a no-op at
    -- the kernel level; the dispute's effects are observed via the
    -- `disputeStatus` log walk and the `applyVerdict` flow.
    freeze_resource 0    -- marker no-op (matches the existing
                         -- `Action.dispute` compileTransition at
                         -- `Authority/Action.lean` line 224)

  satisfies := [
    conservative,
    monotonic,
    local             [{}],
    freeze_preserving [*],
    nonce_advances    [d.challenger],
    registry_preserving
  ]

  events := do
    -- The actual `Event.disputeFiled` (Events/Types.lean line 108)
    -- carries the challenger plus the *primary* impugned log
    -- index extracted from the claim variant; matches
    -- `Events/Extract.lean` lines 152–164.
    let targetIdx := match d.claim with
                     | .preconditionFalse i      => i
                     | .signatureInvalid i       => i
                     | .nonceMismatch i          => i
                     | .oracleMisreported i _    => i
                     | .doubleApply i _          => i
    emit disputeFiled d.challenger targetIdx
```

This example shows how the four §8.4 dispute-pipeline action
constructors (`dispute`, `disputeWithdraw`, `verdict`, `rollback`)
are uniformly representable: each is a kernel-level no-op whose
*observable effect* is mediated by the dispute-pipeline modules
(`Disputes/Filing.lean`, `Disputes/Verdict.lean`, etc.).  Lex's
`signed_by` / `authorized_by` discipline applies uniformly.

### 15.5. A speculative deployment-private law: `staking_lock`

This law does not exist in the kernel today; it is sketched to show
how a deployment would add a new law.

```
law staking_lock (r : ResourceId) (staker : ActorId) (amount : Nat) (unlock_height : Nat)
where
  identifier   my_deployment.staking_lock
  version      "1.0.0"
  action_index 12

  intent {
    Lock `amount` units of `r` belonging to `staker` for use as
    voting weight or anti-fraud collateral.  The locked amount
    moves into a deployment-managed escrow account
    (`my_deployment.escrow_actor`).  The `unlock_height` is recorded
    for off-chain consumption; the kernel does not interpret it.
  }

  signed_by      staker
  authorized_by  deployment.staking_policy staker r

  pre := fun s =>
    amount > 0
    ∧ getBalance s r staker ≥ amount

  impl := do
    flow r amount from staker to deployment.escrow_actor

  satisfies := [
    conservative,
    monotonic,
    local             [{r}],
    freeze_preserving [{r}],
    nonce_advances    [staker],
    registry_preserving
  ]

  events := do
    let pre_staker := getBalance preState r staker
    let pre_escrow := getBalance preState r deployment.escrow_actor
    emit balanceChanged r staker                  pre_staker (pre_staker - amount)
    emit balanceChanged r deployment.escrow_actor pre_escrow (pre_escrow + amount)
    emit stakingLocked  staker amount unlock_height        -- user-defined event
```

The `unlock_height` field is captured into the event but does not
affect the kernel state.  Off-chain processes read the event log
and act on `unlock_height` (e.g. by submitting an `unstake`
SignedAction at the right height); the kernel itself never compares
heights.

This example demonstrates two things:

  1. The same `flow` calculus that captures `transfer` captures any
     escrow-style law verbatim.  The `satisfies` synthesizers
     discharge `conservative` mechanically because the underlying
     `impl` is a single `flow`.  (Recall: `IsConservative` is
     universal-over-`r`; the synthesizer combines a per-resource
     proof at `r` with a "does not touch other resources" proof
     for every `r' ≠ r`.)
  2. User-defined events (`stakingLocked`) compose with the
     auto-emitted `balanceChanged` and `nonceAdvanced` events; the
     deployment registers `Event.stakingLocked` as a constructor
     in its private event vocabulary (a v3 feature; see §13.3).

---

## 16. Audit-1 changelog

This document was audited against the Canon codebase shortly after
its initial commit.  The audit found a number of factual errors
and design inconsistencies that were corrected in-place.  This
section records what changed so that follow-up readers can
distinguish the audited (current) form from the pre-audit form.

### 16.1. Factual corrections

  * **TCB size**: corrected from "~1100 lines" to "~700 lines"
    (`Kernel.lean` 392 + `RBMapLemmas.lean` 297 = 689 at audit
    time).  §3.
  * **`getBalance` / `setBalance` argument orders**: pre-audit
    desugarings used `setBalance b r v s` and `setBalance receiver
    r (bReceiver + amount) s₁`; the kernel's actual signature is
    `setBalance (s : State) (r : ResourceId) (a : ActorId) (v :
    Amount)`.  All `flow` / `mint` / `burn` desugaring code blocks
    in §6.2, §15 corrected.
  * **`Event.balanceChanged` argument order**: pre-audit emitted
    `balanceChanged r actor newV oldV`; actual signature
    (`Events/Types.lean` line 79) is `balanceChanged (r : ResourceId)
    (a : ActorId) (oldV newV : Amount)` — old first, new second.
    All `events` blocks in §5.2, §5.3, §5.4, §6.6, §15 corrected.
  * **Event constructor casing**: pre-audit used PascalCase
    (`BalanceChanged`, `IdentityRegistered`, `DisputeFiled`);
    actual constructors are camelCase
    (`balanceChanged`, `identityRegistered`, `disputeFiled`).
    All `emit` statements corrected.
  * **`actionEvents` state type**: pre-audit said
    `(preState postState : ExtendedState)`; actual signature is
    `(preState postState : LegalKernel.State)`.  §6.6 corrected.
  * **`MonotonicLawSet` field name**: pre-audit said `monotonicity
    := …`; actual field name is `isMonotonic` (`Conservation.lean`
    line 620).  §7.3 corrected.
  * **`Action.distributeOthers` signature**: pre-audit had 5
    parameters including `rewarder` and `recipients`; actual
    constructor takes only `(r : ResourceId) (excluded : ActorId)
    (amount : Amount)`.  §15.3 corrected; the `rewarder` parameter
    moved to a Lex-level binding consumed by `signed_by`, the
    recipient list is computed from `affectedActors_at`.
  * **`Event.disputeFiled` argument shape**: pre-audit emitted the
    raw `Dispute` record; actual constructor takes
    `(challenger : ActorId) (targetIdx : Nat)` per `Events/Types.lean`
    line 108.  §15.4 updated to extract the target index from the
    claim variant.
  * **`transfer` precondition order**: pre-audit had `amount > 0 ∧
    getBalance s r sender ≥ amount`; actual `Laws/Transfer.lean`
    line 61 has `getBalance s r sender ≥ amount ∧ amount > 0`.
    Worked examples updated to match.
  * **`§5.6 of Events/Extract.lean`**: pre-audit reference; actual
    is "WU 5.6 documented in `Events/Extract.lean`".  §6.6 fixed.
  * **`Authority/Action.lean` line 215 reference**: §5.4
    `replaceKey` example now points to the actual line for
    `Action.replaceKey → Laws.freezeResource 0` mapping.
  * **`§5.6 of Events/Extract.lean`**: pre-audit reference; actual
    is "WU 5.6 documented in `Events/Extract.lean`".  §6.6 fixed.

### 16.2. Design corrections

  * **`FreezePreserving` typeclass nonexistence**: pre-audit §3
    listed `FreezePreserving` alongside `IsConservative` and
    `IsMonotonic` as a Phase-4-prelude typeclass.  The kernel does
    not ship `FreezePreserving` as a typeclass; it ships per-law
    named theorems (`transfer_preserves_freeze` etc.).  §3 now
    explicitly notes that Lex *proposes* three new non-TCB
    typeclasses (`FreezePreserving`, `LocalTo`, `RegistryPreserving`)
    as additions to `Conservation.lean` / `Laws/Freeze.lean`, and
    §6.4.2 specifies their full Lean signatures.

  * **Per-resource property syntax incoherence**: pre-audit §5
    examples and §6.4 synthesizer table claimed
    `conservative [r]`, `monotonic [r]`, etc. as per-resource
    forms.  The kernel's existing `IsConservative t` and
    `IsMonotonic t` are *universal over `ResourceId`* — there are
    no per-resource typeclasses.  Lex syntax now uses
    unparameterised `conservative` / `monotonic` claims; only
    `local [{…}]` and `freeze_preserving [{…}]` carry resource-set
    parameters.  Diagnostic L025 flags the old syntax with a
    precise hint.  §5.2 / §5.3 / §5.4 / §6.4 / §15 examples
    updated.

  * **`register_key` effect routing**: pre-audit §6.2 listed
    `register_key` alongside kernel-impl mutators as if it were
    `State → State`.  The actual `Action.replaceKey` compiles to
    `Laws.freezeResource 0` at the kernel-transition level
    (`Authority/Action.lean` line 215); the registry mutation
    happens in `applyActionToRegistry` (the *authority-layer*
    effect).  §6.2 now distinguishes "kernel-impl mutator" from
    "authority-layer effect" and routes `register_key`
    accordingly.  The `replaceKey` worked example in §5.4 has an
    in-line comment explaining the duality.

  * **`signed_by` semantics omission**: pre-audit §6.3 said the
    elaborator "wires `signed_by` into the §8.2 Admissible
    predicate" without clarifying that this *strengthens*
    Admissible beyond the kernel's existing form.  The kernel's
    `AdmissibleWith` checks the authorization policy and
    signature-under-registered-key but does not by itself enforce
    that `st.signer` matches a particular field of the action.
    §6.3 now explicitly documents that `signed_by sender` adds an
    `st.signer = sender` propositional conjunct (decidable via
    `DecidableEq ActorId`), and the generated `myLaw_apply`
    wrapper carries this hypothesis.  The added constraint closes
    a class of "actor X signs a transfer FROM actor Y" attacks.

  * **`revoke_key` removal**: pre-audit §6.2 listed `revoke_key` as
    a primitive.  The kernel ships `KeyRegistry.revoke` but no
    `Action.revokeKey` constructor; `Event.identityRevoked` is
    documented as "reserved for a future `revokeKey` Action
    constructor".  Adding `revoke_key` to Lex would require a
    kernel amendment.  V1 removes it from the grammar; diagnostic
    L022 catches use; v3 may admit it (§13.3).

  * **Codegen ordering**: pre-audit §6.5 said the elaborator
    "accumulates all `law` declarations in the build, sorts them
    by `action_index`, and emits a single `Authority/Action.lean`
    file".  Lean 4 macros run *per-file*; there is no global
    accumulation hook.  §6.5 now describes a two-stage process:
    per-file macro emits non-cross-module artefacts plus a
    codegen-input metadata file, and `lake exe lex_codegen` (a
    separate build pass) reads all such files and regenerates the
    cross-module artefacts.

  * **Manifest hash declaration kind**: pre-audit §7.3 called the
    manifest-hash "a `theorem` … : ByteArray := …".  A hash value
    is a `def`, not a `theorem`.  Corrected.

  * **`Admissible` instantiation wiring**: pre-audit §7.4 said the
    runtime "is configured per-deployment with a single
    `deployment_id`" but did not show *how* the deployment_id
    flows into the kernel's `AdmissibleWith` parameterisation.
    §7.4 now shows the explicit generated declarations
    (`deployment_<name>_admissible := AdmissibleWith Verify P
    deployment_<name>_id`) that the Phase-5 runtime adaptor
    consumes.

  * **`local [*]` reformulation**: pre-audit grammar admitted
    `local [*]` as "all resources".  This claim is always
    trivially satisfied (every kernel-impl `do`-block touches some
    finite set of resources) and carries no auditable
    information.  §6.4.1 now rejects `local [*]` (diagnostic
    L024); `freeze_preserving [*]` remains valid as shorthand for
    "every manifest-declared resource".

  * **Empty events syntax**: pre-audit §15.2 used `events := do
    pure ()` for laws with no per-action events.  The grammar did
    not include `pure ()`.  §6.6 / §5.1 now make `events := []`
    the canonical empty form; `do pure ()` and `do nothing` are
    accepted but `lex_format` rewrites to `[]`.

  * **`flow` colon syntax**: pre-audit used `flow r: amt from a to
    b` with a colon between `r` and `amt`.  In Lean 4 surface
    syntax, a colon mid-expression collides with type ascription
    (`r : ResourceId`).  The grammar in §5.1 now uses
    space-separated arguments (`flow r amt from a to b`).  All
    examples updated.

### 16.3. Diagnostic catalogue extensions

The audit added seven new diagnostic codes (L021–L027) for the
new constraints:

  * L021 — law with no effects whatsoever
  * L022 — `revoke_key` used (deferred to v3)
  * L023 — `impl` calls a non-`@[lex_impl]`-tagged helper
  * L024 — `local [*]` claim (always trivially true)
  * L025 — per-resource `[r]` argument on `conservative` /
    `monotonic` (kernel typeclasses are universal-over-r)
  * L026 — `lex_codegen --check` divergence
  * L027 — bare `s` reference inside `events`

### 16.4. Open questions added

  * §14.4 (compositional property dispatch over fold-of-flow) was
    pre-audit; the audit clarified that v1 falls back to a `proof`
    override (the §15.3 worked example demonstrates this) and v2
    plans a `List.foldl`-induction extension to the synthesizer.

  * **New §14.9 (signer-identity strengthening lift)**: §6.3 now
    documents that `signed_by sender` adds an `st.signer =
    sender` constraint at the *call site* (the policy must imply
    it).  V2 should lift this from a side condition into a
    kernel-level conjunct of `AdmissibleWith` so the constraint is
    structural rather than policy-dependent.  Tracked in §14.

This audit changes no kernel artefact; the corrections are
entirely within this design document.  A v0.2 audit pass — once
the Lex implementation lands the M1 checkpoint (§12.1) — will
produce a §17 changelog with whatever further corrections the
implementation surfaces.

---

## Appendix A: Comparison to the Phase-4 `law` macro

| Aspect                               | Phase-4 macro (current)           | Lex (proposed)                                     |
|--------------------------------------|-----------------------------------|----------------------------------------------------|
| Output                               | `Transition` only                 | `Transition` + `Action` ctor + 5 supporting branches + instances |
| Mandatory clauses                    | `pre`, `impl`                     | + `signed_by`, `authorized_by`, `satisfies`, `intent`, `action_index` |
| Property synthesis                   | none                              | typeclass-driven library + `proof` overrides       |
| Authority binding                    | hand-written elsewhere            | macro-required, structural                         |
| Decidability discipline              | enforced via `[DecidablePred pre]` failure | + grammar restriction, structured diagnostics |
| Action-index management              | hand-managed in `Authority/Action.lean` | mechanically enforced via `lex_index_registry.txt` |
| Versioning                           | none                              | semver, mechanically checked, refinement obligations |
| Manifest                             | none                              | `deployment` macro with `invariant_claims`         |
| Documentation                        | docstring on the `def`            | `intent` block + `lex_diff` semantic diff          |
| TCB impact                           | none (non-TCB)                    | none (non-TCB; macros only)                        |

Phase-4's macro is a *primitive*; Lex is the *language built on
that primitive plus the rest of the kernel*.

## Appendix B: Relationship to existing project artefacts

Lex builds on the following existing components.  This appendix
gives reviewers a single index for cross-checking specific claims
against existing modules.

| Existing component                                 | Used by Lex for…                                                            |
|----------------------------------------------------|-----------------------------------------------------------------------------|
| `LegalKernel/Kernel.lean`                          | the `Transition` record, the `step_impl` semantics, the §4.10 invariants    |
| `LegalKernel/RBMapLemmas.lean`                     | the `find?_insert_*` lemmas the `flow` desugaring relies on                 |
| `LegalKernel/Conservation.lean`                    | `IsConservative` / `IsMonotonic` typeclasses; `MonotonicLawSet`             |
| `LegalKernel/Authority/Action.lean`                | the closed `Action` inductive Lex extends                                   |
| `LegalKernel/Authority/SignedAction.lean`          | the `Admissible` predicate Lex wires `signed_by` / `authorized_by` into     |
| `LegalKernel/DSL/Law.lean` (Phase-4 WU 4.9)        | the existing `law` macro Lex supersedes (kept compiling for one minor)      |
| `LegalKernel/Encoding/Action.lean`                 | the encode / decode / fieldsBounded branches Lex generates                  |
| `LegalKernel/Encoding/SignInput.lean`              | the cross-deployment-replay layer Lex's `deployment_id` flows into          |
| `LegalKernel/Events/Extract.lean`                  | the `actionEvents` branches Lex generates                                   |
| `LegalKernel/Test/Property.lean` (Audit-3.9)       | the property-test harness Lex's auto-generation builds on                   |
| `LegalKernel/Runtime/AttestedSnapshot.lean` (Audit-3.2) | the attestation pattern Lex manifests reuse for governance signing     |
| `Tools/CountSorries.lean`, `Tools/TcbAudit.lean`   | the audit-binary template Lex's `lex_lint` / `lex_codegen` follow           |
| `tcb_allowlist.txt`                                | the TCB-import gate; Lex modules go on a non-TCB list, no allowlist edits   |
| `lex_index_registry.txt`                           | new file Lex introduces; tracks frozen action indices                       |
| `docs/decidability_discipline.md` (WU 1.6)         | the decidability rule §6.1 enforces by grammar                              |
| `docs/economic_invariants.md`                      | the firewall semantics §7.3's `MonotonicLawSet` synthesis preserves         |
| `docs/abi.md`                                      | the on-disk format the action-index commitments surface in                  |

No existing artefact is modified incompatibly by Lex.  M2 (§12.2)
regenerates four files, but the regenerated content is byte-
equivalent (modulo formatting) to the hand-written form they replace.

---

*End of document.*  See `docs/GENESIS_PLAN.md` §12 for the wider
implementation roadmap; this document fits between Phase 6
(Disputes) and Phase 7 (Advanced capabilities) as a deployment-
ergonomics deliverable that is itself non-TCB.
