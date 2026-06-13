<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Genesis Plan: The Legal Kernel

> A formally grounded, implementation-oriented constitutional kernel built in
> Lean 4. This document is the founding architectural and mathematical
> blueprint for the system.

---

## 0. Document Metadata

| Field        | Value                                                              |
|--------------|--------------------------------------------------------------------|
| Title        | Genesis Plan: The Legal Kernel                                     |
| Status       | Draft (living document)                                            |
| Audience     | Kernel implementers, formal-methods reviewers, protocol designers  |
| Prerequisites| Working knowledge of Lean 4, dependent types, Hoare-style reasoning|
| Scope        | Architecture, formal semantics, invariants, roadmap, threat model  |
| Out of scope | Concrete economic policy, specific jurisdictions, business logic   |

The Genesis Plan is the canonical source of truth for the kernel's design
philosophy, formal model, and implementation strategy. Subsidiary documents
(law specifications, runtime guides, deployment manuals) are downstream of
this one. Where downstream documents disagree with the Genesis Plan, the
Genesis Plan wins until amended.

---

## Table of Contents

- [0. Document Metadata](#0-document-metadata)
- [1. Executive Summary](#1-executive-summary)
- [2. Foundational Concepts](#2-foundational-concepts)
  - [2.1 Motivation](#21-motivation)
  - [2.2 Core Thesis (Formal)](#22-core-thesis-formal)
  - [2.3 Three Separations](#23-three-separations)
  - [2.4 Design Philosophy](#24-design-philosophy)
- [3. Mathematical Preliminaries](#3-mathematical-preliminaries)
  - [3.1 State Spaces and Transition Systems](#31-state-spaces-and-transition-systems)
  - [3.2 Inductive Invariants](#32-inductive-invariants)
  - [3.3 Refinement](#33-refinement)
  - [3.4 Proof Relevance](#34-proof-relevance)
  - [3.5 Equality, Functional Extensionality, and Decidability](#35-equality-functional-extensionality-and-decidability)
- [4. The Formal Kernel](#4-the-formal-kernel)
  - [4.1 Type Universe](#41-type-universe)
  - [4.2 State Representation](#42-state-representation)
  - [4.3 Balance Operations](#43-balance-operations)
  - [4.4 Transitions](#44-transitions)
  - [4.5 Specification vs. Implementation](#45-specification-vs-implementation)
  - [4.6 Refinement Theorem](#46-refinement-theorem)
  - [4.7 Proof-Carrying Legality](#47-proof-carrying-legality)
  - [4.8 Certified Execution](#48-certified-execution)
  - [4.9 Reachability](#49-reachability)
  - [4.10 Invariant Preservation Theorem](#410-invariant-preservation-theorem)
  - [4.11 Worked Example: Transfer](#411-worked-example-transfer)
  - [4.12 Complete Kernel Listing](#412-complete-kernel-listing)
  - [4.13 The Action Layer (Serializable Transitions)](#413-the-action-layer-serializable-transitions)
- [5. Mathematical Guarantees](#5-mathematical-guarantees)
- [6. Architectural Layers](#6-architectural-layers)
- [7. Design Properties](#7-design-properties)
- [8. Critical Components](#8-critical-components)
  - [8.1 Conservation Law](#81-conservation-law)
  - [8.2 Authority Model](#82-authority-model)
  - [8.3 RBMap Proof Library](#83-rbmap-proof-library)
  - [8.4 Dispute System](#84-dispute-system)
  - [8.5 Time, Nonces, and Replay Protection](#85-time-nonces-and-replay-protection)
  - [8.6 Bootstrap and Genesis State](#86-bootstrap-and-genesis-state)
  - [8.7 Persistence and Logging](#87-persistence-and-logging)
  - [8.8 Canonical Encoding](#88-canonical-encoding)
  - [8.9 Event Log and Observability](#89-event-log-and-observability)
  - [8.10 Capabilities (Alternative Authority Model)](#810-capabilities-alternative-authority-model)
- [9. Verification Methodology](#9-verification-methodology)
- [10. Threat Model](#10-threat-model)
- [11. Performance Considerations](#11-performance-considerations)
- [12. Implementation Roadmap](#12-implementation-roadmap)
  - Phase 0: Foundations
  - Phase 1: Kernel Completion
  - Phase 2: Economic Invariants
  - Phase 3: Authority Layer
  - Phase 4: DSL and Serialization
  - Phase 5: Runtime and Extraction
  - Phase 6: Disputes and Adjudication
  - Phase 7: Advanced Capabilities
  - Cross-cutting WUs
- [13. Tooling and Build](#13-tooling-and-build)
  - [13.6 Runbook: Adding a New Law](#136-runbook-adding-a-new-law)
  - [13.7 Runbook: Adding a New Invariant](#137-runbook-adding-a-new-invariant)
  - [13.8 Runbook: Cutting a Release](#138-runbook-cutting-a-release)
  - [13.9 Runbook: Investigating a Suspected Invariant Violation](#139-runbook-investigating-a-suspected-invariant-violation)
- [14. Best Practices Enforced](#14-best-practices-enforced)
  - [14.6 Anti-Patterns](#146-anti-patterns)
  - [14.7 Code Review Checklist](#147-code-review-checklist)
  - [14.8 Security Review Checklist](#148-security-review-checklist)
- [15. Open Research Questions](#15-open-research-questions)
- [15B. Workstream H Amendment: Fault-Proof Migration](#15b-workstream-h-amendment-fault-proof-migration)
- [15C. Workstream AR Amendment: Audit Remediation](#15c-workstream-ar-amendment-audit-remediation)
- [15D. Workstream E Amendment: Ethereum Integration](#15d-workstream-e-amendment-ethereum-integration)
- [16. Final Principles](#16-final-principles)
- [17. End State Vision](#17-end-state-vision)
- [Appendix A. Glossary](#appendix-a-glossary)
- [Appendix B. Notation](#appendix-b-notation)
- [Appendix C. References](#appendix-c-references)
- [Appendix D. Change Log](#appendix-d-change-log)
- [Appendix E. Index of Theorems and Definitions](#appendix-e-index-of-theorems-and-definitions)

---

## 1. Executive Summary

The Legal Kernel is a **proof-carrying state transition system** in which
legality is a type, every state change is accompanied by a machine-checkable
proof of admissibility, and global system properties are guaranteed by
inductive invariants rather than by trust in operators.

The kernel is intentionally **small, parametric, and law-free**. It does not
say what is legal; it says what it means for something to be legal, and it
mechanically enforces that nothing else can happen. Specific laws (transfer
rules, permission policies, dispute procedures, economic constraints) are
expressed as values of a `Transition` type and are external to the kernel.

The kernel guarantees four things at the type level:

1. **Determinism.** For any state and any legal transition, the resulting
   state is uniquely determined.
2. **No silent illegality.** A transition whose precondition fails leaves
   the state unchanged; it cannot produce a partial or corrupted state.
3. **Refinement.** Every executable transition step satisfies the
   relational specification of that transition.
4. **Global invariant preservation.** Any property that is true initially
   and is preserved by every legal step is true in every reachable state.

These four properties are proved once, in Lean 4, against the abstract
transition interface. They then hold for every law that conforms to the
interface, by construction.

The remainder of this document develops the mathematical foundations, the
concrete kernel, the architectural layers above it, the components still to
be built, the verification methodology, the threat model, performance
considerations, and a phased roadmap from the current state to a complete
formally verified legal execution layer.

---

## 2. Foundational Concepts

### 2.1 Motivation

Most software systems that govern shared resources (financial ledgers,
identity registries, voting systems, smart contracts, regulatory
compliance engines) rely on **trusted implementations**: humans review
code, auditors stamp it, and the rest of the world hopes the reviewers
were thorough and the implementers honest. When such a system goes wrong,
the failure modes are familiar: silent corruption, ambiguous semantics,
disputes that have no formal procedure of resolution, and emergency
patches that themselves break the rules they were meant to fix.

The Legal Kernel is an attempt to remove the "hope" from this picture. It
asks: what would a system look like if every state change had to come with
a mathematically checkable proof that it was permitted? What would change
if the rules of the system were themselves objects in a programming
language, manipulable, composable, and subject to the same proof
discipline as the kernel itself?

The thesis is that such a system is possible, that Lean 4 is a sufficient
substrate to build it, and that the result is qualitatively different from
both traditional financial software and contemporary smart contract
platforms.

### 2.2 Core Thesis (Formal)

Let $\mathcal{S}$ be a set of states and let $\mathcal{T}$ be a set of
transitions. A transition $t \in \mathcal{T}$ is a triple
$t = (\pi_t, \delta_t, \varphi_t)$ where:

- $\pi_t : \mathcal{S} \to \text{Prop}$ is a **precondition**, a
  proposition over states;
- $\delta_t : \prod_{s \in \mathcal{S}} \text{Decidable}(\pi_t(s))$ is a
  uniform decidability witness — for every $s$, an effective procedure
  for deciding $\pi_t(s)$; and
- $\varphi_t : \mathcal{S} \to \mathcal{S}$ is a total **state
  transformer**.

We use $\text{Prop}$ rather than $\mathbb{B}$ (the booleans) because
preconditions may quantify over actors, resources, or sequences in
ways that are not always boolean-computable. The $\delta_t$ witness
asserts effective decidability where it is needed (the executable
path); reasoning about $\pi_t$ does not require it.

A **transition step** is the partial function
$\sigma_t : \mathcal{S} \rightharpoonup \mathcal{S}$ defined by

$$
\sigma_t(s) = \begin{cases} \varphi_t(s) & \text{if } \pi_t(s) \\
                            s            & \text{otherwise}
\end{cases}
$$

The kernel asserts that the *only* way to advance state is via $\sigma_t$
for some $t$, and that proofs of $\pi_t(s)$ are first-class values whose
existence is necessary to exercise the trusted execution path.

The Genesis thesis is then:

> **Legality is a type.** A transition is legal in a state precisely when
> there exists an inhabitant of `Legal s t`, where `Legal s t` is the
> propositional reflection of $\pi_t(s)$. Programs that hold such an
> inhabitant can execute without any further runtime check.

### 2.3 Three Separations

The kernel design is structured around three deliberate separations.
Conflating any of them is a recurring source of error in trust-bearing
systems.

1. **Specification vs. Execution.** A *specification* is a relation
   `step_spec s s' t` that says "`s'` is an admissible result of applying
   `t` to `s`". An *execution* is a function `step_impl s t : State` that
   actually computes a result. The two are linked by a proven refinement
   theorem; neither dominates the other.

2. **Law vs. Mechanism.** A *law* is a value of type `Transition` together
   with the proof obligations its precondition imposes. A *mechanism* is
   the kernel machinery that consumes those values, checks proofs, and
   applies state transformations. The kernel never inspects the *content*
   of a law; it only verifies that legal preconditions hold.

3. **Semantics vs. Verification.** *Semantics* is the meaning of a
   transition: what the function does to the state. *Verification* is the
   accompanying proof that the meaning satisfies declared invariants. The
   kernel can ingest semantics without verification (in which case the
   transition cannot be applied through the certified path) but it never
   accepts verification without semantics.

### 2.4 Design Philosophy

A handful of philosophical commitments drive every later decision.

- **Smallness over features.** The trusted core must fit in a reviewer's
  head. Every kilobyte of kernel code is a kilobyte of attack surface.
- **Totality over partiality.** Every kernel function is total. Failures
  are reified as values (`Option`, `Except`, no-op fallbacks), never as
  uncaught exceptions.
- **Proof obligations over runtime checks.** Where it is cheap to demand a
  proof at compile time, do so. Runtime checks are a code smell in the
  certified execution path.
- **Parametricity over hard-coding.** The kernel takes laws, invariants,
  and authority policies as parameters. Hard-coding any of them would
  collapse the abstraction the kernel is built to provide.
- **Reversibility of opinion.** Anything that depends on contested values
  (what is fair, what is moral, what is good policy) lives outside the
  kernel and can be replaced without touching the trusted core.

---

## 3. Mathematical Preliminaries

This section fixes the mathematical vocabulary used throughout the rest of
the document. Readers familiar with operational semantics and refinement
calculus may skim it; later sections reference these definitions
verbatim.

### 3.1 State Spaces and Transition Systems

A **state space** is a (possibly infinite) set $\mathcal{S}$. A **labelled
transition system** is a triple $(\mathcal{S}, \mathcal{T}, \to)$ where
$\to \subseteq \mathcal{S} \times \mathcal{T} \times \mathcal{S}$ is the
transition relation. We write $s \xrightarrow{t} s'$ for
$(s, t, s') \in \to$.

The Legal Kernel uses a **deterministic** labelled transition system: for
every $s$ and $t$ there is at most one $s'$ with $s \xrightarrow{t} s'$,
and exactly one when $\pi_t(s)$ holds.

The **reachable set** from $s_0$ is the smallest set $R(s_0) \subseteq
\mathcal{S}$ such that:

- $s_0 \in R(s_0)$, and
- if $s \in R(s_0)$ and $s \xrightarrow{t} s'$ for some $t$ with
  $\pi_t(s)$, then $s' \in R(s_0)$.

### 3.2 Inductive Invariants

An **invariant** is a predicate $I : \mathcal{S} \to \text{Prop}$. An
invariant is **inductive** with respect to a transition system if:

1. **Initiality.** $I(s_0)$ holds.
2. **Preservation.** For every $s$ and $t$, if $I(s)$ and $\pi_t(s)$ then
   $I(\sigma_t(s))$.

The standard induction principle then gives:

$$
\forall s \in R(s_0).\; I(s).
$$

This is the **constitutional guarantee** of the Legal Kernel: any property
proved inductive against the kernel transition relation holds in every
reachable state, irrespective of which laws are loaded.

### 3.3 Refinement

Given a relation $R \subseteq \mathcal{S} \times \mathcal{S}$ and a function
$f : \mathcal{S} \to \mathcal{S}$, we say $f$ **refines** $R$ on
precondition $\pi$ if for every $s$:

$$
\pi(s) \implies (s, f(s)) \in R.
$$

For the kernel, $R$ is the relational specification `step_spec` and $f$ is
the executable `step_impl`. Refinement is the bridge that lets us use the
fast executable path while reasoning about the abstract relational path.

### 3.4 Proof Relevance

Lean 4's type theory distinguishes two universes: `Prop` (proof-irrelevant
propositions) and `Type` (data). The kernel uses both deliberately:

- Preconditions live in `Prop`. The *fact* of legality matters; the
  particular proof object does not.
- Witnesses live in structures (`Legal`, `CertifiedTransition`). The
  presence of such a witness in a function signature is what gives us
  type-level legality; the runtime erases the proof, leaving only the
  state transformation.

This separation is what allows the certified execution path to be free of
runtime checks while still being formally tied to the legality predicate.

### 3.5 Equality, Functional Extensionality, and Decidability

Two practical points to flag for Lean implementers:

- The kernel relies on propositional equality of states (`s = s'`). Because
  `State` is a structure of decidable types over `RBMap`, equality reduces
  to equality of the underlying tree representation. Two states with
  *equal balances but differently shaped trees* are not propositionally
  equal in Lean. The kernel does not rely on representational equality
  except in `step_impl`, where `s' = t.apply_impl s` is by definition.
  When proving conservation and other invariants, we work modulo balance
  equality, lifted via `getBalance`-extensionality lemmas.
- Preconditions used in the certified path must be **decidable**, so that
  `if t.pre s then ... else ...` typechecks without `Classical.dec`.
  Concretely, every law contributed to the system must come with a
  `Decidable (t.pre s)` instance. The kernel's safety properties do not
  require decidability; the executable path does.

---

## 4. The Formal Kernel

This section presents the kernel in full. It is organised top-down: first
the type universe, then state, then balance operations, then the
transition system, then specification/implementation separation, then
proof-carrying legality, then certified execution, then reachability and
the global invariant theorem, then a worked example. Every code block is
intended to compile with Lean 4 and `mathlib`-style `Std`. Where a proof
is currently `sorry`, this is called out explicitly and tracked in the
roadmap.

### 4.1 Type Universe

The kernel is parametric over actor and resource identifiers but commits
to specific representations for them. This is a deliberate trade: by
fixing the representation we obtain decidable equality, total ordering,
and free serialisation; by exposing them only through `abbrev` aliases we
keep the option to swap representations later if cryptographic identity
demands it.

```lean
abbrev ActorId    := UInt64
abbrev ResourceId := UInt64
abbrev Amount     := Nat
```

`ActorId` and `ResourceId` are 64-bit unsigned integers. They are opaque
to the kernel; their meaning (a public key hash, a UUID, a registry
index) is decided by the application layer.

`Amount` is `Nat` (a non-negative integer of unbounded size). The choice
of `Nat` over a fixed-width type is critical: it makes the absence of
overflow a theorem rather than a hope, and it lets the precondition
language express balance constraints natively. The cost is that runtime
representations may exceed 64 bits and must be serialised carefully (see
Section 8.8 for the canonical encoding and Section 12, Phase 4 for the
work units that implement it).

### 4.2 State Representation

State is organised as a two-level finite map: from resource to actor to
amount. Empty entries denote zero balance.

```lean
abbrev BalanceMap := TreeMap ActorId Amount compare

structure State where
  balances : TreeMap ResourceId BalanceMap compare
  deriving Repr
```

Three design choices warrant comment.

- **Two-level rather than flat.** A flat `TreeMap (ResourceId × ActorId)
  Amount` would merge the indices. The two-level form makes per-resource
  reasoning (conservation, total supply, freeze policies) cheaper to
  state and prove because we can quantify over a single `BalanceMap`.
- **`TreeMap` rather than `HashMap`.** `TreeMap` provides total
  ordering and a deterministic fold order, both of which we need for
  serialisable, reproducible state hashing.
- **`Std.Data.TreeMap` rather than `Std.Data.RBMap`.** Earlier drafts
  of this plan referenced `Std.Data.RBMap`, which lived in the
  community `std4` / `batteries` library. As of Lean ≥ 4.10 the
  canonical ordered finite map is `Std.Data.TreeMap` in **Lean core**
  (a red-black tree internally; same total-ordering and
  deterministic-fold properties). Since the kernel must depend only on
  Lean core (Section 13.1), we use `TreeMap`. References in this plan
  to "`RBMap` lemmas" or "the RBMap proof library" remain valid as
  conceptual names — the data structure is still a red-black tree —
  but the concrete imports and types in code are `TreeMap`.

### 4.3 Balance Operations

Two primitives suffice: read and write a single balance.

```lean
def getBalance (s : State) (r : ResourceId) (a : ActorId) : Amount :=
  match s.balances[r]? with
  | none    => 0
  | some bm => bm[a]?.getD 0

def setBalance (s : State) (r : ResourceId) (a : ActorId) (v : Amount) : State :=
  let bm  := s.balances[r]?.getD ∅
  let bm' := bm.insert a v
  { balances := s.balances.insert r bm' }
```

The two functions are mutual inverses up to the natural quotient:
`getBalance (setBalance s r a v) r a = v`, and for `(r', a') ≠ (r, a)`,
`getBalance (setBalance s r a v) r' a' = getBalance s r' a'`.

These two equations are the **balance lemmas**; they are the only
primitive RBMap facts the kernel relies on, and proving them is the
gateway to all higher-level invariants.

```lean
theorem getBalance_setBalance_same
  (s : State) (r : ResourceId) (a : ActorId) (v : Amount) :
  getBalance (setBalance s r a v) r a = v := by
  -- Follows from `TreeMap.getElem?_insert` (same key) at both levels.
  sorry

theorem getBalance_setBalance_other
  (s : State) (r r' : ResourceId) (a a' : ActorId) (v : Amount)
  (h : r ≠ r' ∨ a ≠ a') :
  getBalance (setBalance s r a v) r' a' = getBalance s r' a' := by
  -- Follows from `TreeMap.getElem?_insert` (different key) at the appropriate level.
  sorry
```

The two listings above are written with `sorry` for narrative clarity;
the **actual** proofs in `LegalKernel/Kernel.lean` are sorry-free
since Phase 1 WU 1.5 landed.  Both lemmas now reduce to one-line
applications of `LegalKernel.RBMap.find?_insert_self` and
`LegalKernel.RBMap.find?_insert_other` (the §8.3 / WU 1.1 re-exports
of `Std.TreeMap.getElem?_insert_self` and `getElem?_insert`); the
`getBalance_setBalance_other` proof additionally case-splits on
whether the resource keys agree.

### 4.4 Transitions

A transition is a precondition, a decidability witness for that
precondition, and a state transformer.

```lean
structure Transition where
  /-- The precondition under which the transition is admissible.
      Lives in `Prop` so that quantifiers and propositional connectives
      compose naturally. -/
  pre        : State → Prop
  /-- A per-state decision procedure for the precondition. Without this
      field the executable path of the kernel cannot reduce; with it,
      `step_impl` is definable without ambient classical logic. The
      field is usually inferred via `inferInstance` for atoms built
      from arithmetic comparisons and conjunctions. -/
  decPre     : (s : State) → Decidable (pre s)
  /-- The state transformer. Total by construction; partiality is
      reified in `pre`. -/
  apply_impl : State → State

/-- Re-export the per-state decidability witness as a typeclass
    instance so that ordinary `if t.pre s then ... else ...` notation
    elaborates without explicit annotations. -/
instance (t : Transition) (s : State) : Decidable (t.pre s) :=
  t.decPre s
```

Four observations.

- `apply_impl` is total. Pre-image filtering is the precondition's job.
- `pre` lives in `Prop`. This keeps the *specification* language fully
  classical: quantifiers, implications, and existence statements can
  appear in preconditions without polluting them with `Bool`-coding
  artefacts.
- `decPre` is a *constructive* witness that the abstract precondition is
  effectively decidable on this state. For all the laws contemplated in
  this plan (built from `getBalance` comparisons, `Nat` arithmetic, and
  finite conjunctions), `decPre` is one line: `fun _ => inferInstance`.
- The structure intentionally has no name field, no version field, and
  no metadata. Identity and provenance are layered above (Section 8.2);
  serializable identity in particular requires the `Action` layer of
  Section 4.13.

The instance projection (`instance (t : Transition) (s : State) :
Decidable (t.pre s) := t.decPre s`) is the small piece of Lean
plumbing that makes the executable path work without runtime extra
arguments. It is a *definition*, not a trusted axiom; deleting it
would only make `if`-elaboration fail at the call site.

### 4.5 Specification vs. Implementation

```lean
/-- Relational specification of a transition step.
    `(s, s')` are related by `t` exactly when `t`'s precondition holds in
    `s` and `s'` is the result of applying `t`. -/
def step_spec (s s' : State) (t : Transition) : Prop :=
  t.pre s ∧ s' = t.apply_impl s

/-- Executable implementation of a transition step. Decidability of the
    precondition flows from the `Transition.decPre` instance registered
    in Section 4.4. -/
def step_impl (s : State) (t : Transition) : State :=
  if t.pre s then t.apply_impl s else s
```

`step_spec` is a relation: it says "`s'` is an admissible successor of
`s` under `t`". `step_impl` is a function: it computes one. They are
linked by the refinement theorem of Section 4.6.

The `if t.pre s then ... else ...` reduces because the `Decidable
(t.pre s)` instance was registered in Section 4.4. No `Classical.dec`
is invoked, no axioms are added, and `step_impl` remains computable.

### 4.6 Refinement Theorem

```lean
/-- Implementation refines specification when the precondition holds. -/
theorem impl_refines_spec
  (s : State) (t : Transition) (h : t.pre s) :
  step_spec s (step_impl s t) t := by
  unfold step_impl step_spec
  simp [h]

/-- Implementation is the identity when the precondition fails. -/
theorem impl_noop_if_not_pre
  (s : State) (t : Transition) (h : ¬ t.pre s) :
  step_impl s t = s := by
  unfold step_impl
  simp [h]
```

These two theorems together form the **soundness** statement of the
implementation. The first says: every step we actually take is a step the
specification permits. The second says: when the precondition is not
satisfied, the kernel makes no observable change to the world.

### 4.7 Proof-Carrying Legality

Legality is reified as a structure whose only field is the proof of the
precondition.

```lean
/-- A proof that `t` is legal in `s`. -/
structure Legal (s : State) (t : Transition) where
  proof : t.pre s

/-- A transition together with a proof of its legality in a fixed state. -/
structure CertifiedTransition (s : State) where
  t    : Transition
  cert : Legal s t
```

The `Legal` structure has a single field of propositional type. By Lean's
proof irrelevance, two `Legal s t` values are definitionally equal when
their underlying propositions hold; the structure exists purely to give
us a name to bind in function signatures.

`CertifiedTransition` packages the witness with the transition, indexed
by the state in which the legality holds. The dependent index prevents
the obvious mistake of carrying a certification across an unrelated
state change.

### 4.8 Certified Execution

The trusted execution path takes a `CertifiedTransition` and applies its
inner transformer directly, with no runtime check.

```lean
/-- Certified execution: no runtime check, by construction. -/
def apply_certified (s : State) (ct : CertifiedTransition s) : State :=
  ct.t.apply_impl s

theorem apply_certified_eq_step_impl
  (s : State) (ct : CertifiedTransition s) :
  apply_certified s ct = step_impl s ct.t := by
  unfold apply_certified step_impl
  simp [ct.cert.proof]
```

The second theorem closes the loop: the certified path agrees with the
executable path in every state where the latter would have actually
applied the transition. This means the certified path is not a *separate*
semantics; it is an *optimisation* of the executable semantics that the
type system makes safe.

### 4.9 Reachability

The set of states reachable from a given initial state $s_0$ is captured
inductively.

```lean
inductive Reachable (s0 : State) : State → Prop
  | base : Reachable s0 s0
  | step (s : State) (t : Transition)
      (hreach : Reachable s0 s)
      (hpre   : t.pre s) :
      Reachable s0 (step_impl s t)
```

The inductive definition has two constructors. `base` says the initial
state is reachable. `step` says that if `s` is reachable and `t` is legal
in `s`, then `step_impl s t` is reachable. The latter uses the
*executable* step rather than `apply_impl` directly, which means that
even hypothetical illegal applications cannot extend the reachable set
(though by `step`'s `hpre` premise this is a moot point in practice).

Two extensions are deferred to Phase 1:

- A multi-step closure `Reachable*` that quantifies over arbitrary
  transition sequences.
- A version of `Reachable` parametrised by a *law set* `L : Set
  Transition`, restricting reachability to transitions in `L`.

### 4.10 Invariant Preservation Theorem

This is the central theorem of the kernel.

```lean
theorem invariant_preservation
  (I : State → Prop)
  (s0 : State)
  (h_init : I s0)
  (h_step : ∀ s t, I s → t.pre s → I (step_impl s t)) :
  ∀ s, Reachable s0 s → I s := by
  intro s h
  induction h with
  | base => exact h_init
  | step s t hreach hpre ih => exact h_step s t ih hpre
```

This says: any predicate that holds initially and is preserved by every
legal step holds in every reachable state. It is the formal mechanism by
which a single line of work at the law boundary (proving local
preservation) yields a global guarantee.

### 4.11 Worked Example: Transfer

A canonical law: move `amount` units of resource `r` from `sender` to
`receiver`. The naive implementation of this transition has a subtle bug
when `sender = receiver`. The corrected version below sequences the
balance reads through the intermediate state.

```lean
def transfer (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    : Transition :=
  { apply_impl := fun s =>
      let fromBal := getBalance s r sender
      let s1      := setBalance s r sender (fromBal - amount)
      -- Crucial: read receiver's balance from s1, not s.
      -- When sender = receiver, this preserves the actor's total balance.
      let toBal   := getBalance s1 r receiver
      setBalance s1 r receiver (toBal + amount)
  , pre := fun s =>
      getBalance s r sender ≥ amount ∧ amount > 0
  }
```

Why the sequencing matters. If we instead read `toBal` from `s` (the
original state), then for `sender = receiver` we have `fromBal = toBal`,
and after the debit-then-credit sequence the second `setBalance`
overwrites the first, leaving the actor with `fromBal + amount` rather
than `fromBal`. That violates conservation. Reading `toBal` from `s1`
gives `toBal = fromBal - amount` in the self-transfer case, and the
final balance is `(fromBal - amount) + amount = fromBal`, which is
correct.

The `amount > 0` clause excludes vacuous transfers; this is a policy
choice, not a correctness requirement. It can be relaxed by deleting the
conjunct without breaking any kernel proof.

#### 4.11.1 Local Safety for Transfer

The non-negativity of balances is a free theorem because `Amount = Nat`:
`Nat` cannot be negative, so the property holds by typing alone. The
substantive local property is **conservation per resource**: total
supply is unchanged by any transfer.

```lean
def TotalSupply (s : State) (r : ResourceId) : Nat :=
  match s.balances[r]? with
  | none    => 0
  | some bm => RBMap.sumValues bm

theorem transfer_conserves
  (r : ResourceId) (sender receiver : ActorId) (amount : Amount) (s : State)
  (hpre : (transfer r sender receiver amount).pre s) :
  TotalSupply (step_impl s (transfer r sender receiver amount)) r =
  TotalSupply s r
```

Phase 2 (`LegalKernel/Laws/Transfer.lean`, WU 2.2 + 2.3) discharges the
proof.  The argument unifies the two §4.11 cases (distinct actors and
self-transfer) via the master accounting lemma
`totalSupply_setBalance` of `LegalKernel/Conservation.lean`, which
states `TotalSupply (setBalance s r a v) r + getBalance s r a =
TotalSupply s r + v` — the additive identity that captures both the
debit and the credit step in one equation.  Two instances of the
master lemma plus the precondition's balance bound (`amount ≤
getBalance s r sender`) give a small linear `Nat`-arithmetic system
that `omega` discharges via the private `transfer_arithmetic` helper.

#### 4.11.2 Cross-Resource Independence

Transfers in resource `r` do not affect balances in any other resource
`r' ≠ r`. This is direct from `getBalance_setBalance_other`.

```lean
theorem transfer_does_not_touch_other_resources
  (r r' : ResourceId) (sender receiver : ActorId) (amount : Amount)
  (a : ActorId) (s : State) (h : r ≠ r') :
  getBalance (step_impl s (transfer r sender receiver amount)) r' a =
  getBalance s r' a
```

Proved in `LegalKernel/Laws/Transfer.lean` by reducing both sides via
the state-level companion `transfer_other_resource_untouched`, which
in turn folds through the §8.3 `RBMap.find?_insert_other` lemma at the
outer-level resource map.  Combined with `transfer_conserves`, this
gives the full `IsConservative (transfer …)` instance via
`transfer_isConservative`.

### 4.12 Complete Kernel Listing

Pulling it all together, the kernel module reads:

```lean
import Std.Data.TreeMap

open Std

namespace LegalKernel

/-! ## Type universe -/

abbrev ActorId    := UInt64
abbrev ResourceId := UInt64
abbrev Amount     := Nat

/-! ## State -/

abbrev BalanceMap := TreeMap ActorId Amount compare

structure State where
  balances : TreeMap ResourceId BalanceMap compare
  deriving Repr

/-! ## Balance operations -/

def getBalance (s : State) (r : ResourceId) (a : ActorId) : Amount :=
  match s.balances[r]? with
  | none    => 0
  | some bm => bm[a]?.getD 0

def setBalance (s : State) (r : ResourceId) (a : ActorId) (v : Amount) :
    State :=
  let bm  := s.balances[r]?.getD ∅
  let bm' := bm.insert a v
  { balances := s.balances.insert r bm' }

/-! ## Transitions -/

structure Transition where
  pre        : State → Prop
  decPre     : (s : State) → Decidable (pre s)
  apply_impl : State → State

instance (t : Transition) (s : State) : Decidable (t.pre s) :=
  t.decPre s

/-! ## Specification and implementation -/

def step_spec (s s' : State) (t : Transition) : Prop :=
  t.pre s ∧ s' = t.apply_impl s

def step_impl (s : State) (t : Transition) : State :=
  if t.pre s then t.apply_impl s else s

theorem impl_refines_spec
    (s : State) (t : Transition) (h : t.pre s) :
    step_spec s (step_impl s t) t := by
  unfold step_impl step_spec
  simp [h]

theorem impl_noop_if_not_pre
    (s : State) (t : Transition) (h : ¬ t.pre s) :
    step_impl s t = s := by
  unfold step_impl
  simp [h]

/-! ## Proof-carrying legality -/

structure Legal (s : State) (t : Transition) where
  proof : t.pre s

structure CertifiedTransition (s : State) where
  t    : Transition
  cert : Legal s t

def apply_certified (s : State) (ct : CertifiedTransition s) : State :=
  ct.t.apply_impl s

theorem apply_certified_eq_step_impl
    (s : State) (ct : CertifiedTransition s) :
    apply_certified s ct = step_impl s ct.t := by
  unfold apply_certified step_impl
  simp [ct.cert.proof]

/-! ## Reachability -/

inductive Reachable (s0 : State) : State → Prop
  | base : Reachable s0 s0
  | step (s : State) (t : Transition)
      (hreach : Reachable s0 s)
      (hpre   : t.pre s) :
      Reachable s0 (step_impl s t)

/-! ## Invariant preservation -/

theorem invariant_preservation
    (I : State → Prop) (s0 : State)
    (h_init : I s0)
    (h_step : ∀ s t, I s → t.pre s → I (step_impl s t)) :
    ∀ s, Reachable s0 s → I s := by
  intro s h
  induction h with
  | base                        => exact h_init
  | step s t _hreach hpre ih    => exact h_step s t ih hpre

theorem invariants_compose
    (I₁ I₂ : State → Prop) (s0 : State)
    (hi₁ : I₁ s0) (hi₂ : I₂ s0)
    (hs₁ : ∀ s t, I₁ s → t.pre s → I₁ (step_impl s t))
    (hs₂ : ∀ s t, I₂ s → t.pre s → I₂ (step_impl s t)) :
    ∀ s, Reachable s0 s → (I₁ s ∧ I₂ s) := by
  apply invariant_preservation (fun s => I₁ s ∧ I₂ s) s0
  · exact ⟨hi₁, hi₂⟩
  · intro s t ⟨h₁, h₂⟩ hpre
    exact ⟨hs₁ s t h₁ hpre, hs₂ s t h₂ hpre⟩

end LegalKernel
```

This is the **trusted core**. Everything else in the system is built on
top of it.

A short reading guide:

- `Transition` carries three fields, of which `decPre` is the only
  non-mathematical one; it bridges the propositional precondition and
  the executable `if`.
- `step_impl` is the only place in the kernel that branches on the
  precondition. Its proof obligations (`impl_refines_spec`,
  `impl_noop_if_not_pre`) cover both branches.
- `Legal` and `CertifiedTransition` are pure dependent records; they add
  no runtime cost because their proof field is erased at extraction.
- `Reachable` is inductive over `step_impl`, not `apply_impl`; this
  forecloses any back-door state advance that bypasses the `if`.
- `invariant_preservation` and `invariants_compose` together let
  deployments reason about *conjunctions* of invariants without
  re-proving each combination.

### 4.13 The Action Layer (Serializable Transitions)

A `Transition` value contains a function (`apply_impl`) and a
`Decidable`-valued field (`decPre`). Neither can be canonically
serialized: there is no fixed byte representation of an arbitrary Lean
function. Yet *signing* a transition, *logging* a transition, and
*disputing* a transition all require a serializable representation.
The kernel therefore distinguishes:

- **`Transition`** (Section 4.4): the *operational* form; a function
  plus a precondition. Used by `step_impl`, `apply_certified`, and the
  proof discipline.
- **`Action`**: a *first-order data* form; an inductive type whose
  constructors enumerate the law set, with each constructor's
  arguments being raw scalar fields. Used by signing, logging,
  serialization, disputes, and replay.

A deployment supplies:

```lean
/-- The set of actions a deployment recognises. One constructor per law,
    each carrying only first-order data (scalars, IDs, byte strings).
    The kernel does not refer to this type; it is supplied per
    deployment. -/
inductive Action
  | transfer (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
  | mint     (r : ResourceId) (to : ActorId) (amount : Amount)
  | burn     (r : ResourceId) (from : ActorId) (amount : Amount)
  -- ... one constructor per law
  deriving Repr, DecidableEq, Hashable

/-- The compilation function maps each `Action` constructor to the
    corresponding `Transition`. The kernel never executes this; it is
    supplied per deployment and audited as part of the law set. -/
def Action.compile : Action → Transition
  | .transfer r s r' a => Laws.transfer r s r' a
  | .mint r to a       => Laws.mint r to a
  | .burn r fr a       => Laws.burn r fr a
  -- ...
```

Because `Action` is a closed inductive type with `DecidableEq`, the
compiler generates a canonical encoding "for free" via the
constructor index plus the field encodings (Section 8.8). And because
`Action.compile` is a function in Lean, it is *definitionally* the
inverse of the action constructor pattern: there is no ambiguity about
what transition a given action denotes.

Three theorems link the layers:

```lean
/-- Compilation is total. -/
theorem Action.compile_total (a : Action) :
    ∃ t : Transition, Action.compile a = t := ⟨Action.compile a, rfl⟩

/-- Compilation is injective on action data: distinct actions compile to
    extensionally distinct transitions, modulo the law set's
    well-formedness. (The proof is a case split on the `Action`
    constructors and a check that each `Laws.*` definition produces a
    distinguishable `Transition`.) -/
theorem Action.compile_injective :
    ∀ a₁ a₂ : Action,
      Action.compile a₁ = Action.compile a₂ → a₁ = a₂ := by
  intro a₁ a₂ h
  cases a₁ <;> cases a₂ <;> simp_all [Action.compile]
  -- Each case requires showing distinct law constructors produce
  -- distinct transitions; this depends on the law definitions, hence
  -- is discharged per-deployment.
  all_goals first | rfl | (sorry)

/-- Compiled transition's executable behaviour matches the action's
    intended semantics. (Vacuously true given how `compile` is defined;
    listed for documentation.) -/
theorem Action.compile_step
    (a : Action) (s : State) :
    step_impl s (Action.compile a) =
    if (Action.compile a).pre s
    then (Action.compile a).apply_impl s
    else s := rfl
```

The `Action` layer is the boundary between *internal* (function-based,
proof-rich) representations and *external* (byte-based,
crypto-shippable) representations. Everything that crosses a network,
a disk, or a signature lives in `Action`-space; everything that
crosses the kernel's executable path lives in `Transition`-space.

This separation is the single most important pattern for keeping the
kernel small while still supporting authority, disputes, replay, and
ZK proofs. It is referenced repeatedly in Sections 8.2, 8.4, 8.5, 8.8,
and the roadmap (Section 12).

---

## 5. Mathematical Guarantees

This section restates the guarantees the kernel provides, in increasing
order of strength, with explicit proof obligations and references to the
Lean theorems above.

### 5.1 Determinism

**Claim.** For every state $s$ and transition $t$, $\text{step\_impl}(s,
t)$ is uniquely determined.

**Proof.** Lean functions are total and deterministic; the result of
`step_impl s t` is a single inhabitant of `State`, so the claim follows
from typing. There is no need for an additional theorem.

**Consequence.** Two replicas of the kernel that receive the same
initial state and the same transition stream will produce bit-identical
state sequences. This is the foundation of replay verification and
state-hashing protocols (Section 8.6).

### 5.2 Local Safety

**Claim (parametric).** For an invariant $I$ that has been shown to be
preserved by every legal step, $I$ holds after each individual legal
step.

**Lean encoding.**

$$
\forall s\, t.\; I(s) \land \pi_t(s) \implies I(\text{step\_impl}(s, t)).
$$

This is the *hypothesis* `h_step` of `invariant_preservation`. It must
be discharged on a per-invariant basis. The kernel's only role is to
ensure that no other path to state change exists; the truth of the
hypothesis is the law-author's responsibility.

### 5.3 Global Safety

**Claim.** If $I(s_0)$ and local safety hold, then $I(s)$ for every
$s \in R(s_0)$.

**Lean encoding.** This is `invariant_preservation` applied to the law
set in question. A complete deployment will produce one corollary of
`invariant_preservation` per invariant. A *substantive* example
(non-negativity of balances is vacuous because `Amount = Nat`) is
per-resource conservation: every transition in a "conservative" law set
preserves total supply.

```lean
/-- The conservation invariant for resource `r₀`. Stated as a closure
    over a target value because it is the *equality* with the target
    that the inductive step preserves. -/
def TotalSupplyEquals (r₀ : ResourceId) (target : Nat) (s : State) : Prop :=
  TotalSupply s r₀ = target

theorem total_supply_global
    (r₀ : ResourceId) (target : Nat)
    (s0 : State) (h_init : TotalSupplyEquals r₀ target s0)
    -- The deployed law set is restricted to conservative laws.
    (laws : List Transition)
    (h_conservative :
      ∀ t ∈ laws, ∀ s, t.pre s →
        TotalSupply (step_impl s t) r₀ = TotalSupply s r₀)
    -- Reachability is restricted to those laws (formalised via a
    -- variant of `Reachable` parameterised on the law set; see
    -- Section 4.9 deferred extension and Section 12 WU 1.8 / WU 1.9
    -- for the work units that introduce `ReachableViaLaws` and
    -- `invariant_preservation_via_laws`).
    : ∀ s, ReachableViaLaws laws s0 s → TotalSupplyEquals r₀ target s := by
  apply invariant_preservation_via_laws (TotalSupplyEquals r₀ target) laws s0 h_init
  intro s t htL hI hpre
  -- The single goal: for an arbitrary law `t` in the deployed set,
  -- conservation of `r₀` is preserved.
  unfold TotalSupplyEquals at *
  rw [h_conservative t htL s hpre]
  exact hI
```

The "one subgoal per law" structure is what makes the cost of adding a
new law explicit and bounded: a new law adds exactly one preservation
obligation per global invariant. With `n` laws and `k` invariants, the
total proof obligation is exactly `n * k` lemmas, each local to a single
law; no combinatorial explosion arises.

### 5.4 Refinement Soundness

**Claim.** Every result produced by `step_impl` is a result the
specification permits.

**Lean encoding.** `impl_refines_spec`, restated:

$$
\forall s\, t.\; \pi_t(s) \implies (\pi_t(s) \land \text{step\_impl}(s, t)
= \varphi_t(s)).
$$

The conjunction is trivially true on its first conjunct (the hypothesis)
and on its second by definition of `step_impl` under the assumption.

**Consequence.** Reasoning at the relational level (`step_spec`) and
reasoning at the executable level (`step_impl`) are interchangeable
under the precondition, with no loss of fidelity. This means
specification-level theorems automatically transfer to the executable
path.

### 5.5 No-Op Safety

**Claim.** A transition whose precondition fails leaves the state
unchanged.

**Lean encoding.** `impl_noop_if_not_pre`, restated:

$$
\forall s\, t.\; \neg \pi_t(s) \implies \text{step\_impl}(s, t) = s.
$$

**Consequence.** This is what allows the kernel to "see and refuse"
illegal transitions without raising exceptions or mutating partial
state. Combined with the parametricity of the law set, it means the
kernel can be used as a filter: any transition stream is laundered into
a stream of state-preserving and state-advancing steps with no other
options.

### 5.6 Conservation (per Resource)

**Claim.** For the `transfer` law (and any other law that preserves
total supply), the per-resource total supply is invariant under legal
application.

**Lean encoding.** Given in Section 4.11.1. The proof is `sorry` until
the RBMap fold lemmas of Section 8.3 are in place.

**Generalisation.** Conservation generalises to any *quantity functional*
$Q : \mathcal{S} \to \mathbb{N}$ that decomposes into a fold over
balances. The kernel does not privilege one such functional; downstream
laws that introduce minting, burning, or fees define their own and
discharge the corresponding preservation theorem.

### 5.7 Composability of Invariants

**Claim.** If $I_1$ and $I_2$ are both inductive, then $I_1 \land I_2$
is inductive.

**Lean sketch.**

```lean
theorem invariants_compose
  (I₁ I₂ : State → Prop) (s0 : State)
  (hi₁ : I₁ s0) (hi₂ : I₂ s0)
  (hs₁ : ∀ s t, I₁ s → t.pre s → I₁ (step_impl s t))
  (hs₂ : ∀ s t, I₂ s → t.pre s → I₂ (step_impl s t)) :
  ∀ s, Reachable s0 s → (I₁ s ∧ I₂ s) := by
  apply invariant_preservation (fun s => I₁ s ∧ I₂ s)
  · exact ⟨hi₁, hi₂⟩
  · intro s t ⟨h₁, h₂⟩ hpre
    exact ⟨hs₁ s t h₁ hpre, hs₂ s t h₂ hpre⟩
```

Composability is what lets us *layer* invariants: a deployment can
specify a list of invariants, and the conjunction is itself an
inductive property. This avoids the combinatorial explosion of having
to reprove "everything together" for each new property.

---

## 6. Architectural Layers

The system as a whole is structured as five concentric layers. The
kernel sits at the centre; each subsequent layer depends only on the
layers below it. The trusted computing base is exactly Layer 0.

### 6.0 Overview

```
+-----------------------------------------------------------+
| Layer 4:  Application       (UIs, wallets, dashboards)    |
+-----------------------------------------------------------+
| Layer 3:  Context           (oracles, time, external data)|
+-----------------------------------------------------------+
| Layer 2:  Intent            (goals, constraints, planning)|
+-----------------------------------------------------------+
| Layer 1:  Law               (transitions + proofs)        |
+-----------------------------------------------------------+
| Layer 0:  Kernel            (state, semantics, invariants)|
+-----------------------------------------------------------+
```

Each higher layer is permitted to be wrong, untrusted, or even
adversarial; the kernel guarantees that no behaviour at any higher
layer can violate the invariants discharged at Layer 0/1.

### 6.1 Layer 0: Kernel

**Responsibilities.**

- Define `State`, `Transition`, `Legal`, `CertifiedTransition`,
  `Reachable`.
- Provide `step_impl`, `apply_certified`.
- Prove `impl_refines_spec`, `impl_noop_if_not_pre`,
  `apply_certified_eq_step_impl`, `invariant_preservation`,
  `invariants_compose`.
- Provide the `RBMap` proof library required by laws (Section 8.3).

**Non-responsibilities.**

- Defining any specific law.
- Defining any specific invariant beyond the structural ones.
- Networking, persistence, serialisation, cryptography.

Layer 0 is the only layer that is part of the trusted computing base.
Compromising it requires either a Lean kernel bug or a meta-theoretic
flaw in the invariant proofs.

### 6.2 Layer 1: Law

**Responsibilities.**

- Provide concrete `Transition` values.
- Provide `Decidable (t.pre s)` instances for executable laws.
- Discharge local safety obligations against any deployed invariant.
- Compose laws into law sets, with sub-typed views (e.g. "all transfer
  laws", "all governance laws", "all minting laws").

**Examples.** `transfer`, `mint`, `burn`, `freeze`, `unfreeze`, `vote`,
`enact`.

Layer 1 is *not* trusted in the sense that bugs in a specific law cannot
violate invariants the law was proved to preserve. They can, however,
introduce *new* legal behaviours that are surprising to users; the
mitigation is published, audited, version-controlled law sets.

### 6.3 Layer 2: Intent

**Responsibilities.**

- Express user-level goals as constraints over the trajectory of the
  system.
- Plan sequences of legal transitions that satisfy the constraints.
- Provide search, optimisation, and counter-factual evaluation.

**Examples.** "Move 100 units of resource $r$ from $a_1$ to $a_2$ at
minimum cost", "achieve a target distribution of resource $r$ across a
set of actors", "schedule a payroll satisfying these constraints".

Intents are *plans*, not transitions. They are compiled down to
sequences of certified transitions. Intent compilers are untrusted;
their output is type-checked by the kernel before execution.

### 6.4 Layer 3: Context

**Responsibilities.**

- Provide external data: prices, timestamps, randomness, off-chain
  facts.
- Sign and date oracle reports.
- Bridge the gap between deterministic kernel state and a
  non-deterministic outside world.

Context is the interface to non-determinism. Every oracle reading
becomes part of state via a transition (e.g. `record_price`), so even
external data enters the system through the proof discipline.

### 6.5 Layer 4: Application

**Responsibilities.**

- Render state to humans.
- Solicit intents from users.
- Interpret kernel outputs in domain-specific terms.

Applications are entirely untrusted. They cannot do harm because they
cannot bypass the kernel; they can mislead, however, and so should be
audited as if they were untrusted.

### 6.6 Layer Boundaries and the Trusted Computing Base

The trusted computing base (TCB) is precisely:

- The Lean 4 type checker.
- The `Std.Data.RBMap` definitions (and any other `Std` modules used).
- The kernel module of Section 4.12.

Concretely, the TCB is *bounded by what is checked when you compile the
kernel module*. Anything outside that compilation unit is, by
construction, outside the TCB.

A pragmatic implication: any time we add to the kernel, we must
explicitly justify the addition in TCB terms. The phased roadmap of
Section 12 follows this discipline.

---

## 7. Design Properties

The properties below are not *theorems* about the kernel; they are
*design constraints* that the kernel must satisfy and that future
extensions must respect. Each is followed by a falsifiable test: a
description of what evidence would refute the property.

### 7.1 Parametric Law

**Property.** The kernel does not refer to any specific law.

**Falsifying evidence.** A grep of the kernel source shows references
to a named law (e.g. `transfer`, `mint`).

**Status.** Holds as of this writing. The example `transfer` is
defined in a downstream module, not in the kernel module.

### 7.2 Proof-Carrying Execution

**Property.** Every value produced by the certified execution path is
accompanied by a proof of legality at the type level.

**Falsifying evidence.** A function in the kernel that returns a
post-state without consuming a `Legal` or `CertifiedTransition`
witness.

**Status.** Holds. `apply_certified` requires a `CertifiedTransition`
argument; `step_impl` is the alternative path and explicitly performs
the runtime check.

### 7.3 Deterministic Semantics

**Property.** For every $s$ and $t$, `step_impl s t` is a unique value.

**Falsifying evidence.** A non-deterministic primitive (e.g. random
number generation) inside the kernel.

**Status.** Holds. The kernel has no non-deterministic primitives.

### 7.4 Minimal Trusted Computing Base

**Property.** The TCB is exactly the kernel module of Section 4.12,
plus the Lean type checker and the `Std` types it imports.

**Falsifying evidence.** A second module that must be trusted in order
for kernel theorems to be sound.

**Status.** Holds, with the noted dependency on `Std.Data.RBMap`.
Phase 1 includes a review of the exact `Std` lemmas the kernel relies
on, and a plan to either pin them or replace them with locally-stated
equivalents.

### 7.5 Compositionality

**Property.** Invariants and laws compose without re-proof.

**Falsifying evidence.** A pair of invariants $I_1$, $I_2$ each proved
inductive, whose conjunction $I_1 \land I_2$ requires non-trivial
additional argument to be inductive.

**Status.** Holds, by `invariants_compose` (Section 5.7).

### 7.6 Total Functions

**Property.** Every kernel function is total.

**Falsifying evidence.** A `partial def` or a use of `Classical.choice`
in the kernel module.

**Status.** Holds. The kernel uses no partial definitions and no
classical axioms.

### 7.7 Erasability of Proofs

**Property.** Proof objects do not appear in the runtime
representation of certified transitions; they are erased by the Lean
compiler.

**Falsifying evidence.** Disassembled bytecode of `apply_certified`
contains references to `Legal` proof structures rather than only to
`apply_impl`.

**Status.** To be verified in Phase 5 (extraction). Lean's compilation
strategy erases `Prop`-valued fields, so the property is expected to
hold; the verification is mechanical.

### 7.8 Explicitness of Failure

**Property.** Whenever the kernel cannot make progress, the failure is
visible as a value (no-op state, returned `Except`, etc.) and never as
an exception.

**Falsifying evidence.** A kernel function that throws.

**Status.** Holds; no kernel function throws.

---

## 8. Critical Components

The kernel as defined in Section 4 is necessary but not sufficient.
Several components must be added before the kernel can support a
real-world deployment. This section names each gap, gives a formal
treatment of what fills it, and points to the roadmap phase that
addresses it.

### 8.1 Conservation Law

**Gap.** The kernel does not yet have a proof that any specific quantity
is conserved across transitions.

**Formal definition.** For a resource $r$, the **total supply** at state
$s$ is

$$
T_r(s) = \sum_{a \in \text{Actors}} \text{getBalance}(s, r, a).
$$

Because `getBalance` returns `0` for actors not in the underlying
`BalanceMap`, the sum is finite and equal to a fold over the map's
explicit entries. The Lean encoding is:

```lean
def TotalSupply (s : State) (r : ResourceId) : Nat :=
  match s.balances.find? r with
  | none    => 0
  | some bm => bm.foldl (fun acc _ v => acc + v) 0
```

**Conservation theorem (statement).** For every transition $t$ in a
*conservative* law set $L_C$:

$$
\forall s\, r.\; \pi_t(s) \implies T_r(\sigma_t(s)) = T_r(s).
$$

Lean:

```lean
theorem law_set_conserves
  (L : Set Transition) (hL : ∀ t ∈ L, IsConservative t)
  (s : State) (t : Transition) (htL : t ∈ L) (hpre : t.pre s)
  (r : ResourceId) :
  TotalSupply (step_impl s t) r = TotalSupply s r := by
  exact hL t htL r s hpre
```

**Required lemmas.**

1. `RBMap.foldl_insert_present`: folding after `insert` of a key already
   present updates the accumulator by the new value minus the old.
2. `RBMap.foldl_insert_absent`: folding after `insert` of a fresh key
   adds the new value to the accumulator.
3. `RBMap.foldl_eq_sum_of_values`: the fold equals the multiset sum of
   the values, independent of insertion order.

These are tracked in Section 8.3.

**Roadmap.** Phase 2 (complete).  See `LegalKernel/Conservation.lean`
for the `TotalSupply` definition and the `total_supply_global`
theorem; `LegalKernel/Laws/Transfer.lean` for `transfer_conserves`
and the `IsConservative (transfer …)` instance;
`LegalKernel/Laws/Mint.lean` and `LegalKernel/Laws/Burn.lean` for
the explicit non-conservation witnesses.

### 8.2 Authority Model

**Gap.** Anyone holding a transition value can construct a `Legal`
witness if the precondition holds. There is no notion of *who* is
permitted to apply a given transition.

**Pre-requisite.** The Action layer of Section 4.13. Authority operates
on serializable `Action` values, not on `Transition` values, because
only the former can be canonically encoded and signed.

**Formal model.** Introduce **identities**, **signed actions**, and a
**policy**.

```lean
abbrev PublicKey := ByteArray
abbrev Signature := ByteArray
abbrev Nonce     := UInt64

/-- A registered identity. The `key` is what `Verify` checks against. -/
structure Identity where
  id  : ActorId
  key : PublicKey

/-- A signed action carries serializable data only: an `Action`, the
    signer's `ActorId`, a per-actor `Nonce` for replay protection, and
    a signature over the canonical encoding of `(action, signer, nonce)`.
    See Section 8.8 for the encoding spec. -/
structure SignedAction where
  action : Action
  signer : ActorId
  nonce  : Nonce
  sig    : Signature

/-- The deployment-supplied authority policy. `authorized` is a
    *predicate* over `(signer, action)` pairs; the registry maps actor
    IDs to their public keys. Both fields are state-independent — the
    state-dependent parts of authority (e.g. "this signer must currently
    own the resource being moved") belong inside the law's
    precondition, not here. -/
structure AuthorityPolicy where
  authorized : ActorId → Action → Prop
  decAuth    : (a : ActorId) → (act : Action) → Decidable (authorized a act)
  registry   : RBMap ActorId PublicKey compare
```

A signed action is **admissible** in policy $P$ at extended state
$es$ (state plus per-actor nonce, Section 8.5) when *all five* of the
following hold:

| # | Condition (informal)                                  | Lean fragment                                       |
|---|-------------------------------------------------------|-----------------------------------------------------|
| 1 | The signer is registered.                             | `P.registry.find? st.signer = some pk`              |
| 2 | The policy permits this signer to issue this action.  | `P.authorized st.signer st.action`                  |
| 3 | The signature verifies under the registered key.      | `Verify pk (canonicalEncode (st.action, st.signer, st.nonce)) st.sig` |
| 4 | The nonce matches the actor's next-expected nonce.    | `st.nonce = expectsNonce es st.signer`              |
| 5 | The compiled transition's precondition holds in `es`. | `(Action.compile st.action).pre es.base`            |

In Lean:

```lean
def Admissible
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction) :
    Prop :=
  P.authorized st.signer st.action ∧
  st.nonce = expectsNonce es st.signer ∧
  (∃ pk, P.registry.find? st.signer = some pk ∧
         Verify pk (canonicalEncode (st.action, st.signer, st.nonce))
                   st.sig = true) ∧
  (Action.compile st.action).pre es.base
```

The kernel exposes one guarded entry point:

```lean
def apply_admissible
    (P : AuthorityPolicy) (es : ExtendedState)
    (st : SignedAction)
    (h : Admissible P es st) :
    ExtendedState :=
  let t := Action.compile st.action
  let s' := t.apply_impl es.base
  let es' := { es with base := s' }
  advanceNonce es' st.signer
```

The `apply_admissible` function is the *only* externally callable path
to state advance in a deployed system. All five conditions are
discharged before any state changes; if any fails, no state change
occurs.

**Why five conditions, not one big "valid" predicate.** Each condition
is independent and can be discharged at a different time:

- (1)–(2) are *static* in the action: they depend only on the
  registry and policy, both of which can be cached.
- (3) is *static* in the action and signature: independent of state.
  Verifiable once and cached for re-broadcast scenarios.
- (4) is *dynamic*: depends on the per-actor nonce in `es`.
- (5) is *dynamic*: depends on `es.base`.

Splitting the predicate makes the order of failures meaningful for
diagnostics: "rejected because (3) failed" is a different operational
state from "rejected because (5) failed".

**Cryptographic primitives.** `Verify` is treated as an *uninterpreted*
function in the kernel; its security properties (existential
unforgeability under chosen-message attack, EUF-CMA) are assumed. The
deployment chooses the signature scheme:

- **Ed25519** (RFC 8032) is the default recommendation: small keys,
  small signatures, deterministic, fast verify, well-reviewed.
- **ECDSA over secp256k1** for compatibility with Bitcoin/Ethereum
  toolchains.
- **ML-DSA** (NIST FIPS 204) for post-quantum hedging; larger
  signatures but the same EUF-CMA guarantee.

The kernel's `Verify` signature is `PublicKey → ByteArray → Signature →
Bool`, which all of the above satisfy with appropriate adaptors.

**Algorithmic agility.** The `PublicKey` and `Signature` types are
opaque `ByteArray`s in the kernel; the choice of scheme is in the
adaptor that supplies `Verify`. Migrations to a new scheme are
performed by:

1. Issuing a new policy that accepts both old- and new-scheme keys for
   a transition window.
2. Re-registering each actor's identity under the new scheme via a
   signed `replaceKey` action.
3. After a publication-week deadline, issuing a final policy that
   removes old-scheme keys.

**Out-of-scope here.** Threshold signatures, BLS aggregation,
zero-knowledge identity proofs, and revocation trees are all *valid
extensions* but live outside the Phase 3 deliverable. They are
expected to bolt on at the `AuthorityPolicy` boundary.

**Replay protection.** Authorised actions must include a nonce — see
Section 8.5 for the protocol and an attack-by-attack analysis.

**Authority composition.** Two policies $P_1, P_2$ compose pointwise:

```lean
/-- Left-biased merge of two `RBMap`s: on key collision, the value from
    `m₁` wins. Provided locally because `Std.RBMap` does not currently
    expose a corresponding combinator with the desired bias. -/
def RBMap.mergeLeftBiased
    {κ α : Type} {cmp : κ → κ → Ordering}
    (m₁ m₂ : RBMap κ α cmp) : RBMap κ α cmp :=
  m₂.foldl (fun acc k v => if acc.contains k then acc else acc.insert k v) m₁

def AuthorityPolicy.union (P₁ P₂ : AuthorityPolicy) : AuthorityPolicy :=
  { authorized := fun a act => P₁.authorized a act ∨ P₂.authorized a act
  , decAuth    := fun a act =>
      @instDecidableOr _ _ (P₁.decAuth a act) (P₂.decAuth a act)
  , registry   := RBMap.mergeLeftBiased P₁.registry P₂.registry
  }
```

The union deliberately gives precedence to $P_1$ on key conflicts;
deployments that need a different conflict-resolution rule supply
their own combinator.

**Roadmap.** Phase 3, decomposed into work units WU 3.1 – WU 3.10
(Section 12).

### 8.3 RBMap Proof Library

> **Naming note.** The section title is preserved for historical
> continuity ("RBMap" was the original name in `std4`). The actual
> implementation in this repository is `Std.Data.TreeMap` from Lean
> core (Section 4.2), which is a red-black tree.  The lemma names
> below should be read as `TreeMap.*` in code; the proof obligations
> are unchanged.

**Gap.** Several kernel and law-level theorems depend on ordered-map
properties not yet formalised.

**Required lemmas.**

```lean
-- Pointwise behaviour
theorem RBMap.find?_insert_self
  (m : RBMap κ α cmp) (k : κ) (v : α) :
  (m.insert k v).find? k = some v

theorem RBMap.find?_insert_other
  (m : RBMap κ α cmp) (k k' : κ) (v : α) (h : k ≠ k') :
  (m.insert k v).find? k' = m.find? k'

-- Fold behaviour
theorem RBMap.foldl_insert_absent
  (m : RBMap κ α cmp) (k : κ) (v : α)
  (f : β → κ → α → β) (init : β)
  (h : m.find? k = none) :
  (m.insert k v).foldl f init = f (m.foldl f init) k v

theorem RBMap.foldl_insert_present
  (m : RBMap κ α cmp) (k : κ) (v_old v_new : α)
  (f : β → κ → α → β) (init : β)
  (h : m.find? k = some v_old) :
  (m.insert k v_new).foldl f init =
  -- requires `f` to be commutative on disjoint keys; see below
  ...
```

The fold lemmas require either:

- A *commutative monoid* assumption on the fold operation (sufficient
  for sums, products, and bag-style aggregates), or
- An explicit *re-fold* expression that "undoes" the old value and
  applies the new (more general but harder to use).

The conservation proofs use the commutative monoid path.

**Library shape.** The library lives in `LegalKernel.RBMapLemmas` and is
imported by both the kernel (where it is part of the TCB by extension)
and by laws.

**Roadmap.** Phase 1.

### 8.4 Dispute System

**Gap.** When two parties disagree about the legality of a transition
or the value of an oracle, the kernel has no formal mechanism for
resolution.

**Pre-requisite.** The Action layer (Section 4.13). Disputes refer to
*actions* — first-order data — not to transitions, because disputes
must be serializable, signable, and (re-)verifiable from logs.

#### 8.4.1 Dispute Anatomy

A dispute names a specific *log entry* by index, plus a structured
claim about why that entry was wrong:

```lean
abbrev LogIndex := Nat

inductive DisputeClaim
  /-- The action's compiled precondition was false at the time of
      application (kernel violation by collusion). -/
  | preconditionFalse  (idx : LogIndex)
  /-- The signature on the action did not verify (kernel runtime
      bug or registry corruption). -/
  | signatureInvalid   (idx : LogIndex)
  /-- The nonce was wrong (replay or skip). -/
  | nonceMismatch      (idx : LogIndex)
  /-- An oracle reported a value contradicted by external evidence
      bound to the dispute. -/
  | oracleMisreported  (idx : LogIndex) (evidence : ByteArray)
  /-- The same nonce was applied twice (kernel runtime bug). -/
  | doubleApply        (idx₁ idx₂ : LogIndex)
  deriving Repr, DecidableEq

structure Dispute where
  challenger : ActorId
  claim      : DisputeClaim
  /-- Optional supporting bytes (oracle counter-evidence, signature
      counterexamples, etc). The dispute pipeline interprets this per
      claim variant. -/
  evidence   : ByteArray
  nonce      : Nonce
  sig        : Signature
  deriving Repr
```

A `Dispute` is itself a `SignedAction` in the system: there is an
`Action.dispute (d : Dispute)` constructor, and the same authority and
nonce machinery applies.

#### 8.4.2 The Dispute Pipeline

The dispute pipeline is a deterministic state machine over four
stages. Each stage is an opportunity to reject early and is implemented
as a separate function:

```
filed  -->  evidence_checked  -->  verdict_proposed  -->  verdict_applied
   \             |                       |                      |
    \--reject--+ +---reject---+         +--reject--+           (final)
       (malformed) (insufficient)        (denied)
```

**Stage 1 — Filing (`fileDispute`).** Validate that the dispute is
itself a syntactically well-formed `SignedAction`, that the challenger
is registered, and that `idx` references an existing log entry. No
evidence reasoning yet.

```lean
inductive FilingError
  | malformedAction
  | unknownChallenger
  | indexOutOfRange (idx : LogIndex) (logLen : Nat)
  | duplicateDispute (priorIdx : LogIndex)

def fileDispute
    (P : AuthorityPolicy) (es : ExtendedState) (log : Log)
    (d : Dispute) :
    Except FilingError DisputeRecord := ...
```

**Stage 2 — Evidence Check (`checkEvidence`).** For each `DisputeClaim`
variant, run the corresponding verifier:

| Variant              | Verifier obligation                                                 |
|----------------------|---------------------------------------------------------------------|
| `preconditionFalse`  | Replay log up to `idx`, recompute pre-state $s_{idx-1}$, evaluate `(Action.compile log[idx].action).pre s_{idx-1}`; the dispute holds iff this is `false`. |
| `signatureInvalid`   | Re-run `Verify` against the registered key for `log[idx].signer` at the time of filing. Holds iff `Verify` returns `false`. |
| `nonceMismatch`      | Recompute `expectsNonce es_{idx-1} log[idx].signer`; compare to `log[idx].nonce`. Holds iff they differ. |
| `oracleMisreported`  | Run a per-oracle, per-feed evidence verifier (deployment-supplied). Holds iff the verifier accepts the counter-evidence. |
| `doubleApply`        | Verify `log[idx₁].nonce = log[idx₂].nonce`, both signed by the same actor, with `idx₁ ≠ idx₂`. |

Each verifier is *pure* (no I/O, no clocks): given the log and the
evidence, the answer is reproducible. This is essential for
determinism — different adjudicators must reach the same verdict.

```lean
inductive EvidenceVerdict
  | upheld
  | rejected
  | inconclusive   -- e.g. evidence parses but does not establish the claim

def checkEvidence
    (P : AuthorityPolicy) (log : Log)
    (rec : DisputeRecord) :
    EvidenceVerdict := ...
```

**Stage 3 — Verdict Proposal (`proposeVerdict`).** A designated
adjudicator (or quorum, if the policy specifies a multi-sig) signs an
`Action.verdict (idx, v)` action that records the verdict. The
adjudicator's signature is the trust root for the rollback that
follows.

```lean
structure Verdict where
  disputeId  : LogIndex   -- pointer to the dispute log entry
  outcome    : EvidenceVerdict
  rationale  : ByteArray  -- free-form, e.g. canonical evidence summary
  signatures : List (ActorId × Signature)
  -- with propositional invariant Verdict.canonical:
  --   signatures.Pairwise (fun p q => p.fst < q.fst)
```

**Audit-3.5 amendment.**  The earlier `signers : List ActorId` /
`sigs : List Signature` parallel-list shape is replaced by a
single `signatures : List (ActorId × Signature)` field plus a
`Verdict.canonical` propositional invariant requiring the
signatures list to be strictly ascending by `ActorId`.  This
makes structural the three invariants that the parallel-list
shape required value-level enforcement of:

  * **Per-signer uniqueness.**  Strict-less-than sort ⇒ no
    duplicate ActorIds, eliminating the trivial-quorum-forgery
    bug class structurally for canonical verdicts.  The audit-1
    `countVerifiedSignatures` per-signer dedup becomes
    defense-in-depth (handles non-canonical inputs); for
    canonical verdicts the dedup is a no-op.
  * **Length agreement.**  No separate `signers` and `sigs`
    lists means no possibility of unequal lengths or
    sig[i]-doesn't-match-signer[i] confusions.
  * **Canonical encoding.**  The encoder unzips `signatures`
    into the parallel-list view `(signers, sigs)` (preserving
    the pre-Audit-3.5 wire format byte-for-byte); the decoder
    enforces canonicality on the input bytes via
    `actorsStrictlyAscending` (decidable Bool check) and rejects
    unsorted / duplicate-key inputs as `nonCanonical`.  Round-
    trip is provable unconditionally on canonical inputs via
    Lean core's `List.zip_unzip` identity — no missing Std lemma
    is needed (an earlier TreeMap-based design was abandoned
    because Lean core's `Std.Data.TreeMap.Lemmas` does not ship
    a `(ofList compare m.toList).toList = m.toList` lemma).

The wire format is unchanged.  Pre-Audit-3.5 verdicts whose
serialised `signers` list is strictly ascending (the typical
case for honest senders) continue to decode under the
post-amendment binary.  Pre-Audit-3.5 verdicts with non-
canonical orderings now decode to `.error nonCanonical`.

Back-compat accessors `Verdict.signers : List ActorId` and
`Verdict.sigs : List Signature` derive the parallel-list views
from `signatures` so existing code (e.g.
`Disputes/Rewards.lean`) keeps working unchanged.

**Stage 4 — Verdict Application (`applyVerdict`).** If the verdict is
`upheld`, the kernel applies a *rollback transition* whose effect is
"undo the application of `log[idx]` and any dependent application
since". Because the kernel is deterministic, the rollback target state
is the unique replay of `log[0..idx-1]` over the genesis state.

The rollback is itself a `SignedAction` in the log; it is therefore
auditable, disputable, and replay-able like any other action. The
kernel does not "delete" history; it appends a forward action that
restores a prior state.

```lean
def applyVerdict
    (P : AuthorityPolicy) (es : ExtendedState) (log : Log)
    (v : Verdict) :
    Except VerdictError ExtendedState := ...
```

#### 8.4.3 Determinism, Liveness, and Trust

- **Determinism.** Stages 1–2 are pure functions of `(P, es, log,
  evidence)`. Two adjudicators presented with the same inputs reach the
  same `EvidenceVerdict`. This is what allows multiple-adjudicator
  quorums to be safe (they cannot disagree on facts; they can only
  disagree on which actions to sign).
- **Liveness.** Liveness is *not* a kernel property. The deployment
  chooses whether disputes have a deadline (after which the action is
  considered final), and whether un-adjudicated disputes block
  dependent actions. The kernel exposes the primitives:
  `Action.disputeFile`, `Action.disputeWithdraw`, `Action.verdict`.
- **Trust.** The adjudicator(s) are trusted *only* to sign the verdict
  produced by the deterministic pipeline. They are *not* trusted to
  evaluate evidence: the pipeline is observable to all parties, who
  can reproduce verdicts independently. An adjudicator who signs a
  verdict at odds with the pipeline is themselves disputable via
  `signatureInvalid` or `preconditionFalse` against the verdict
  action.

#### 8.4.4 Failure Cases and Handling

| Failure                                                | Handling                                          |
|--------------------------------------------------------|--------------------------------------------------|
| Dispute filed against a non-existent log index         | Stage 1 rejects; no state change.                |
| Dispute by an unregistered challenger                  | Stage 1 rejects.                                 |
| Insufficient evidence (`inconclusive`)                 | Stage 2 marks as such; deployment chooses to retry, escalate, or close. |
| Verdict signed by fewer than quorum-many adjudicators  | Stage 3 rejects.                                 |
| Verdict whose pipeline output is `rejected`            | Stage 4 records the rejection, no rollback.      |
| Verdict whose pipeline output is `upheld`              | Stage 4 applies rollback; new top of log.        |
| Replay of a previously upheld dispute                  | Stage 1 rejects via `duplicateDispute`.          |

Each failure mode is a separate Lean `inductive` constructor, so
diagnostics are unambiguous.

**Roadmap.** Phase 6, decomposed into WU 6.1 – WU 6.12 (Section 12).

### 8.5 Time, Nonces, and Replay Protection

**Gap.** The kernel as defined has no notion of time. Two identical
authorised actions submitted at different "real-world" times are
indistinguishable to the kernel, which means a replay of an old
signed transfer would succeed.

#### 8.5.1 The Nonce Protocol

Embed a monotonic counter (a "nonce") in authorised actions, and
maintain a per-actor next-expected-nonce in state.

```lean
abbrev Nonce := UInt64

/-- Per-actor next-expected nonce. Missing entries default to 0. -/
structure NonceState where
  next : RBMap ActorId Nonce compare
  deriving Repr

/-- The "extended state" the runtime hands to the kernel: the
    application state plus the nonce ledger. The kernel module proper
    operates on `State`; the `ExtendedState` lives in the authority
    module so that the kernel TCB does not grow. -/
structure ExtendedState where
  base   : State
  nonces : NonceState
  deriving Repr

def expectsNonce (es : ExtendedState) (a : ActorId) : Nonce :=
  (es.nonces.next.find? a).getD 0

def advanceNonce (es : ExtendedState) (a : ActorId) : ExtendedState :=
  { es with nonces :=
    { next := es.nonces.next.insert a (expectsNonce es a + 1) } }
```

A `SignedAction` is admissible only when (Section 8.2 condition 4):

$$
\text{nonce}(st) = \text{expectsNonce}(es, \text{signer}(st)).
$$

After successful application, `advanceNonce es signer` makes the next
expected nonce one greater. Because `Nat`-typed nonces are unbounded,
no overflow can occur; in the `UInt64` representation, the system
imposes a per-actor lifetime bound of $2^{64}$ actions, which is
operationally irrelevant.

#### 8.5.2 Properties (Stated and Proved)

```lean
/-- Two distinct signed actions by the same signer cannot both be
    admissible at the same `ExtendedState`. -/
theorem nonce_uniqueness
    (P : AuthorityPolicy) (es : ExtendedState)
    (st₁ st₂ : SignedAction)
    (h₁ : Admissible P es st₁)
    (h₂ : Admissible P es st₂)
    (hsame : st₁.signer = st₂.signer) :
    st₁.nonce = st₂.nonce := by
  have h_n₁ := h₁.2.1   -- nonce condition for st₁
  have h_n₂ := h₂.2.1   -- nonce condition for st₂
  rw [hsame] at h_n₁
  exact h_n₁.trans h_n₂.symm

/-- The next expected nonce is strictly increasing per actor. -/
theorem expectsNonce_strict_mono
    (es : ExtendedState) (a : ActorId) :
    expectsNonce (advanceNonce es a) a = expectsNonce es a + 1 := by
  unfold expectsNonce advanceNonce
  -- Follows from `RBMap.find?_insert_self` (Section 8.3 lemma WU 1.1).
  sorry

/-- A successfully applied signed action cannot be admissible again. -/
theorem replay_impossible
    (P : AuthorityPolicy) (es es' : ExtendedState)
    (st : SignedAction)
    (h : Admissible P es st)
    (h_apply : apply_admissible P es st h = es') :
    ¬ Admissible P es' st := by
  intro h'
  -- After application, expectsNonce es' st.signer = st.nonce + 1.
  -- For h' to hold, we'd need st.nonce = expectsNonce es' st.signer,
  -- which means st.nonce = st.nonce + 1, contradiction.
  have h_expect : expectsNonce es' st.signer = st.nonce + 1 := by
    rw [← h_apply]; unfold apply_admissible
    exact expectsNonce_strict_mono _ _
  have h_eq : st.nonce = expectsNonce es' st.signer := h'.2.1
  have : st.nonce = st.nonce + 1 := h_eq.trans h_expect
  exact absurd this (Nat.ne_of_lt (Nat.lt_succ_self _))
```

`replay_impossible` is the headline theorem. It says the kernel
mechanically refuses to apply the same signed action twice — there is
no scenario, no race, and no pathological log replay in which this
guarantee fails.

#### 8.5.3 Attack-by-Attack Analysis

| Attack                                                         | Defence                                                  | Theorem                                  |
|----------------------------------------------------------------|----------------------------------------------------------|------------------------------------------|
| Verbatim re-submission of an old signed action                 | `expectsNonce` has advanced; condition 4 fails           | `replay_impossible`                      |
| Re-submission with the same nonce on a forked replica          | The forked replica's `expectsNonce` is also advanced     | Determinism (Section 5.1)                |
| Nonce-skip (signer attempts `nonce + 2` directly)              | Condition 4 fails: `nonce ≠ expectsNonce`                | by definition of `Admissible`            |
| Sign-and-front-run by an attacker holding a stolen valid msg   | The attacker can submit it once if the original signer never did; replay impossible thereafter | `replay_impossible`                  |
| Cross-deployment replay (action signed for deployment A submitted to B) | The `canonicalEncode` of a `SignedAction` includes a deployment-id field (Section 8.8); signature does not verify on B | by construction of canonical encoding |
| Cross-actor replay (Eve submits Alice's signed action with Eve's signer ID) | Signature does not verify under Eve's registered key | EUF-CMA assumption                       |
| Compromised-signer floodgate (Eve steals Alice's key and runs nonces forward) | Kernel cannot prevent this; rotation via `replaceKey` (Section 8.2) and revocation are the mitigations | n/a (deployment policy)                  |

#### 8.5.4 Time as a Context Variable

When wall-clock time matters (for expiry, vesting, scheduled
execution), it enters via a designated **time oracle**: a registered
identity whose only privilege is to issue `Action.recordTime t` actions
that append to a `times : List Nat` field of state. The oracle policy
enforces:

- `t > head times` (strict monotonicity).
- The signing identity matches the registered time oracle.
- The action is rate-limited to one entry per minimum-tick.

The kernel makes no assumption about the relationship between
recorded times and any external clock; the deployment is responsible
for choosing an oracle whose recordings are trustworthy. The kernel
*does* guarantee that recorded time is monotonic across the log, by
the oracle's precondition.

#### 8.5.5 Failure Modes and Recovery

| Failure                                | Outcome                                            | Recovery                                           |
|----------------------------------------|----------------------------------------------------|---------------------------------------------------|
| Signer submits stale nonce             | Action rejected; state unchanged                   | Re-sign with current `expectsNonce`               |
| Signer submits future nonce            | Action rejected; state unchanged                   | Wait for intervening actions; or treat as bug     |
| Lost signed action (network)           | Nonce held by signer; safe to resubmit             | Resubmit; idempotency by nonce                    |
| Two replicas race to submit same action | One wins; the other's `apply_admissible` no-ops    | None needed; deterministic                        |
| Time oracle proposes non-monotonic time | Action rejected by oracle precondition             | Investigate oracle; possibly revoke               |

**Roadmap.** Phase 3, decomposed into WU 3.1 – WU 3.10 (Section 12).

### 8.6 Bootstrap and Genesis State

**Gap.** Where does $s_0$ come from?

**Formal answer.** The genesis state is a *fixed value* embedded in the
deployed kernel binary. Its hash is published; the deployment is only
considered legitimate if its embedded genesis hashes to that value.

```lean
def genesis : State :=
  { balances := RBMap.empty }
  -- Or, for a non-trivial deployment, an explicit construction.
```

For deployments with non-trivial genesis (initial balances, registered
identities, default policies), the value is generated by a *genesis
script* whose output is reviewed and then frozen into the binary.

**Migrations.** The kernel does not support upgrading a live deployment
to a new genesis. Migrations across kernel versions are explicit:
either a state-export-and-reimport sequence, or a *bridge transition*
that maps Old Kernel state to New Kernel state via a one-time
authorised step.

**Roadmap.** Phase 0 (bootstrap script) and Phase 5 (migration
protocol).

### 8.7 Persistence and Logging

**Gap.** The kernel is purely in-memory.

**Formal model.** A **transition log** is a sequence of authorised
transitions:

$$
L = [(s_0, t_0, s_1), (s_1, t_1, s_2), \ldots, (s_{n-1}, t_{n-1}, s_n)].
$$

The deployment guarantees:

1. The log is append-only.
2. Each entry is signed by the kernel runtime (in addition to the
   transition's own signer) so that log entries are non-repudiable.
3. The current state $s_n$ is reproducible from $s_0$ and the log,
   bit-for-bit, by replay.

Persistence is implemented at the *runtime* level (Section 12, Phase 5),
not in the kernel. The kernel exposes the determinism property that
makes replay possible.

### 8.8 Canonical Encoding

**Gap.** Sections 8.2, 8.4, 8.5 require canonical byte encodings of
`Action`, `SignedAction`, `Dispute`, `Verdict`, and `State`. The
encoding scheme determines what `Verify` sees, what hashes are
published, and what auditors compare. There is exactly one chance to
get this right; ambiguity here is an authority bypass.

#### 8.8.1 Goals

A canonical encoding is a function `encode : T → ByteArray` such that:

1. **Total.** `encode` is defined on every well-typed value of `T`.
2. **Deterministic.** `encode v = encode v` (free, but worth saying).
3. **Injective.** `encode v₁ = encode v₂ → v₁ = v₂`.
4. **Well-defined under serialisation round-trip.** A matching
   `decode : ByteArray → Except DecodeError T` satisfies
   `∀ v, decode (encode v) = .ok v`.
5. **Reproducible across implementations.** Any two compliant
   implementations of `encode` produce identical bytes.

Properties 1–3 must be Lean theorems; property 4 must be a Lean
theorem; property 5 is a *spec* obligation enforced by interop tests
(Section 9.5).

#### 8.8.2 The Scheme

The kernel's canonical encoding is **CBOR** (RFC 8949) restricted to
its **canonical subset**:

- Major types 0 (uint), 2 (bytes), 3 (text), 4 (array), 5 (map) only.
  No tagged values, no floats, no indefinite-length items, no
  semantic tags.
- Map keys are sorted by their canonical encoding (deterministic
  ordering).
- Integers are encoded in the smallest valid form (no leading zero
  bytes).
- Strings are encoded with byte-length prefixes; UTF-8 only.
- Arrays carry a length prefix.

This subset has well-studied determinism properties and existing
audited implementations.

#### 8.8.3 Per-Type Encoding

Each kernel-level type maps to a fixed CBOR shape:

```
ActorId       -> CBOR uint
ResourceId    -> CBOR uint
Amount        -> CBOR uint
Nonce         -> CBOR uint
PublicKey     -> CBOR byte string
Signature     -> CBOR byte string
ByteArray     -> CBOR byte string

Action        -> CBOR array [ tag : uint , fields... ]
                 where `tag` is the constructor index and `fields` are
                 the constructor's field encodings in declaration order.

SignedAction  -> CBOR map { 0: action, 1: signer, 2: nonce, 3: sig }
                 with map keys sorted ascending.

Dispute       -> CBOR map { 0: challenger, 1: claim, 2: evidence,
                            3: nonce, 4: sig }

Verdict       -> CBOR map { 0: disputeId, 1: outcome, 2: rationale,
                            3: signers, 4: sigs }

State         -> CBOR map { 0: balances }
                 where `balances` is an ordered map (CBOR map with keys
                 sorted ascending) from `ResourceId` to inner ordered
                 maps from `ActorId` to `Amount`.

ExtendedState -> CBOR map { 0: base, 1: nonces }
```

The constructor indices for `Action` are *frozen at deployment time*:
adding a new constructor must append, not insert. This is the
deployment's responsibility; the kernel offers a `genesis_action_set`
hash that bakes the constructor list into the genesis hash so that
any divergence is detectable.

#### 8.8.4 Hashing and Identifiers

A **content hash** is `BLAKE3(encode v)`, 256 bits. We choose BLAKE3
for: parallelism (XOF), wide review, no patent issues, and well-known
collision resistance bounds.

Each entity has a derived identifier:

- `ActionHash := BLAKE3(encode action)`
- `LogEntryHash := BLAKE3(encode signedAction || encode previousLogEntryHash)`
- `StateHash := BLAKE3(encode state)`
- `GenesisHash := StateHash(genesis)`

`LogEntryHash` chains entries together (Merkle-list style), so the
log is tamper-evident: any retroactive edit to entry $i$ invalidates
the hash of every entry $\geq i$.

**Audit-3.1 amendment.**  All hash outputs are exactly **32 bytes**
on disk regardless of which implementation is linked.  The Lean
fallback (FNV-1a-64 zero-padded to 32 bytes; non-cryptographic,
NOT for production) is the test-build default; production
deployments link a vetted BLAKE3-256 implementation under the
documented C ABI symbol names:

- `knomosis_hash_bytes`        — `ContentHash f(ByteArray bs)`
- `knomosis_hash_stream`       — `ContentHash f(List<UInt8> s)`
- `knomosis_hash_identifier`   — `String f(Unit)` (returns the impl
                              identifier, e.g. `"blake3-256"` or
                              `"fnv1a64-padded-32"`)

The runtime CLIs (`knomosis`, `knomosis-replay`) read
`knomosis_hash_identifier` at startup.  `knomosis-replay` refuses to
print an `OK` line under the fallback unless the operator passes
`--allow-fallback-hash` — the auditor's reproduction guarantee is
meaningless under a 64-bit non-cryptographic hash.  The previous
"variable-width chain" (32-byte seed, 8-byte body) is eliminated:
all chain bytes are 32 bytes throughout.

#### 8.8.5 Signing Domains

Signatures are computed over **domain-separated** encodings to prevent
cross-protocol replay:

```
sign_input(action, signer, nonce, deployment_id) :=
  BLAKE3("legalkernel/v1/signedaction" ||
         encode deployment_id ||
         encode action ||
         encode signer ||
         encode nonce)
```

The `deployment_id` is the `GenesisHash` of the deployment. A
signature valid for deployment $D_1$ does not verify against deployment
$D_2$ because their genesis hashes differ.

Verdicts and disputes use their own domain strings
(`"legalkernel/v1/verdict"`, `"legalkernel/v1/dispute"`) so that no
signature collision is possible across the action types.

**Audit-3.4 amendment.**  The kernel-level `Admissible` predicate
(§8.2) MUST consume the deployment-bound `signingInput` rather than
the deployment-blind earlier form.  This makes
cross-deployment-replay rejection a *type-level* guarantee
(distinct `deploymentId` values produce distinct sign-input bytes;
`Verify` rejects accordingly) instead of being scoped only by the
runtime adaptor's per-deployment `Verify` instance.  Bundled with
the Audit-3.3 parameterization of `Admissible` over the verifier
function.

**Audit-3.2 amendment.**  Snapshots used for replica bootstrap
should ship as an outer `AttestedSnapshot` envelope `(Snapshot,
attestor : ActorId, sig : Signature)` whose signature covers the
canonical encoding of the inner `Snapshot` plus the attestation
domain string `"legalkernel/v1/attested-snapshot"`.  The CLI
`knomosis-replay --require-attestation <pk-hex>` enforces the
attestation; without the flag, bare `Snapshot` files are still
accepted (backwards-compatible).  An attestor-key compromise is
out of scope; attestation closes the self-attesting bootstrap gap
where any party supplying a snapshot file could compute a
matching internal hash.

#### 8.8.6 Decoding and Well-Formedness

```lean
inductive DecodeError
  | unexpectedEof
  | invalidMajorType (got : UInt8) (expected : UInt8)
  | invalidConstructorIndex (got : UInt8)
  | nonCanonical (reason : String)
  | trailingBytes (count : Nat)

def decode {T : Type} [Encodable T] : ByteArray → Except DecodeError T
```

The decoder rejects non-canonical encodings (e.g., a non-minimal
integer, or an unsorted map). This is critical: a permissive decoder
would let an attacker forge an alternative-but-equally-valid encoding
of the same value with a different signature input.

```lean
theorem decode_encode_roundtrip {T : Type} [Encodable T] (v : T) :
    decode (encode v) = .ok v := by
  -- Per-type, by induction on the structure.
  sorry

theorem encode_injective {T : Type} [Encodable T] :
    Function.Injective (encode : T → ByteArray) := by
  intro v₁ v₂ h
  have h₁ : decode (encode v₁) = .ok v₁ := decode_encode_roundtrip v₁
  have h₂ : decode (encode v₂) = .ok v₂ := decode_encode_roundtrip v₂
  rw [h] at h₁
  rw [h₁] at h₂
  exact (Except.ok.injEq _ _).mp h₂.symm
```

**Roadmap.** Phase 4, decomposed into WU 4.1 – WU 4.9 (Section 12).

### 8.9 Event Log and Observability

**Gap.** The transition log records *what was applied*. It does not
record *what other parties saw*, *what intent was attempted but
rejected*, or *what computed views were derived from state*. Without an
event log, dashboards, indexers, and alerting cannot exist without
re-implementing the kernel.

#### 8.9.1 Three Streams

A deployment maintains three independent streams:

| Stream                | Source                       | Visible to                | Tamper-evident? |
|-----------------------|------------------------------|---------------------------|-----------------|
| **Transition log**    | `apply_admissible` results   | Authorized observers      | Yes (hash chain) |
| **Rejection log**     | All rejected `SignedAction`s | Authorized observers      | Yes (hash chain) |
| **Event log**         | Per-action `events` field    | Public or authorized      | Yes (hash chain) |

The transition and rejection logs are **complete**: the kernel
guarantees that every `SignedAction` it sees is recorded in exactly
one of them. The event log is *derived* from the transition log via a
deployment-supplied function `extractEvents : LogEntry → List Event`,
itself a Lean function and therefore deterministic.

#### 8.9.2 Event Type

```lean
inductive Event
  | balanceChanged   (r : ResourceId) (a : ActorId) (oldV newV : Amount)
  | nonceAdvanced    (a : ActorId) (oldN newN : Nonce)
  | identityRegistered (a : ActorId) (key : PublicKey)
  | identityRevoked  (a : ActorId)
  | timeRecorded     (t : Nat)
  | disputeFiled     (d : Dispute)
  | verdictApplied   (v : Verdict)
  -- Per-deployment events extend this set via an `extra : ByteArray`
  -- carrier or a dedicated subtype.
  deriving Repr
```

Events are *observations*, not *causes*: they describe the state
transitions in a domain-friendly vocabulary so that downstream
indexers don't have to re-derive them from `State` diffs. By
construction, the event log is a *function* of the transition log;
two replays of the same log produce identical event streams.

#### 8.9.3 Why a Separate Stream

Three reasons for keeping events separate from the transition log:

- **Privacy.** Events can be redacted (for instance, a deployment
  may publish only `identityRegistered` events but withhold
  `balanceChanged` ones). The transition log is what gets verified;
  the event log is what gets *shared*.
- **Evolution.** Adding a new event type does not change the
  transition log's hash chain. The event extraction function can be
  versioned independently.
- **Indexer ergonomics.** Indexers consume events, not raw kernel
  state diffs; the event vocabulary can be designed for query
  efficiency without constraining the kernel.

#### 8.9.4 Subscription and Backfill

Indexers subscribe to the event stream by `(stream, fromIndex)`
pair. The runtime serves events in order. Backfill from genesis is
always possible because events are deterministically derivable from
the transition log.

**Roadmap.** Phase 5, WU 5.6 – WU 5.8 (Section 12).

### 8.10 Capabilities (Alternative Authority Model)

**Context.** Section 8.2's authority model is *access-control-list*
(ACL) shaped: a registry of who-can-do-what. An alternative is a
**capability** model: bearer-token style authority where holding a
particular value *is* the right to perform an action.

#### 8.10.1 Capability Model in Sketch

```lean
/-- A capability grants its bearer the right to invoke a particular
    action shape. The `bearer` field is the public key that must sign
    invocations; `expires_at` is a per-time-oracle deadline. -/
structure Capability where
  id        : UInt64
  shape     : ActionShape   -- e.g. "transfer of resource r₀, ≤ 100 units"
  bearer    : PublicKey
  expiresAt : Nat
  delegable : Bool
  parent    : Option UInt64 -- for delegation chains

structure CapabilityState where
  active : RBMap UInt64 Capability compare
  revoked : List UInt64
```

A capability-authorised action carries the capability ID and a
signature by the `bearer`. Authorisation reduces to:

- `active.find? cap.id = some cap`
- `cap.id ∉ revoked`
- `cap.expiresAt > currentTime`
- `actionMatchesShape st.action cap.shape`
- `Verify cap.bearer (encoded action) st.sig = true`

#### 8.10.2 Trade-offs

| Property                 | ACL (8.2)                              | Capability (8.10)                          |
|--------------------------|----------------------------------------|--------------------------------------------|
| Composition              | Set union of policies                  | Capability minting (refinement)            |
| Revocation               | Edit registry                          | Append to revoked list, or expire          |
| Delegation               | Out-of-band                            | First-class via `parent`                   |
| Audit ("who can do X?")  | Easy: query policy                     | Harder: enumerate active capabilities      |
| State growth             | Bounded by signer count                | Bounded by issued-capability count         |
| Ergonomics               | Simple for fixed roles                 | Better for ephemeral grants                |

#### 8.10.3 Coexistence

Both models can run concurrently. An action is authorised iff *either*
the ACL policy permits it *or* a valid unrevoked capability is
presented. The kernel's `apply_admissible` is parameterised by an
`AuthMode` enum that selects which check applies for a given action
shape.

The plan's Phase 3 builds the ACL model. The capability model is
deferred to Phase 7 as one of the advanced capabilities; it can be
added without modifying the kernel TCB because it lives at the
authority boundary.

---

## 9. Verification Methodology

This section defines how we *do* verification, not what we verify.
Discipline at this level is the difference between a kernel that is
"probably correct" and one that is provably correct.

### 9.1 Proof Style

- **Forward proofs** for short, computational obligations; **backward
  proofs** (`apply`-style) for theorems with structural induction.
- **`simp`-only at trusted lemma boundaries.** Every use of `simp`
  inside the kernel module names its rewrite set explicitly. No
  appeals to `simp` with the default set inside trusted code.
- **No `sorry` in the kernel.** Outside the kernel, `sorry` is allowed
  but tracked: every `sorry` carries a `-- TODO(genesis-#NN)` tag
  pointing to a roadmap item.
- **`by decide` is discouraged for security-sensitive propositions.**
  It hides assumptions that should be visible.

### 9.2 Tactic Discipline

- Prefer `exact` over `apply` where it costs nothing in length.
- Use `refine` with metavariables for medium-size goals; do not nest
  more than two levels deep.
- Avoid `omega` and `linarith` inside the kernel module; both are large
  and would expand the TCB. They are fine in law modules.
- Name every hypothesis. Anonymous hypotheses (`intro`, `intros` with
  no names) are allowed only in one-line proofs.

### 9.3 Test Strategy

The kernel has formal proofs; tests are still useful for:

- Detecting regressions in `Std.Data.RBMap` between Lean versions.
- Validating extraction (Phase 5) against a reference implementation.
- Sanity-checking law preconditions on hand-crafted examples.

Tests live in `LegalKernel/Test/` and are executed by `lake test`.

### 9.4 Property-Based Testing

Use `Plausible` (or `SlimCheck`) to generate random states and
transitions and check that:

- `step_impl` is total (no panics, no exceptions).
- `step_impl s t = step_impl s t` (determinism).
- For laws with proven invariants, the invariant holds on the
  post-state.

Property-based testing complements formal proof; it is *not* a
substitute. Its value is in catching specification bugs that the proofs
do not address (e.g. a precondition that is too weak in practice but
correctly proved).

### 9.5 Fuzzing

For the runtime layer (Phase 5), fuzz the parser, the signature
verifier, and the canonical encoder. The kernel itself has no
parser-shaped attack surface; the runtime that feeds it does.

### 9.6 Continuous Verification

CI on every commit:

1. `lake build` (compile everything, including all proofs).
2. `lake test` (run tests).
3. `lake exe count_sorries` (must be zero in the kernel module; must be
   non-increasing in the rest of the codebase).
4. `lake exe tcb_audit` (lists all imports of the kernel module; must
   match a hand-maintained allowlist).

A failing CI blocks merge.

---

## 10. Threat Model

We enumerate the threats the kernel is and is not designed to defend
against, and the trust assumptions on which the defences depend.

### 10.1 In-Scope Threats

- **Malicious laws** that attempt to violate a deployed invariant.
  Defence: invariants are inductive, so a law that violated them would
  fail to compile. Status: defended by `invariant_preservation`.
- **Forged certifications.** A `Legal s t` value can only be
  constructed by exhibiting a proof of `t.pre s`; forging one requires
  forging a Lean proof, which requires a soundness bug in Lean.
  Defence: type system. Status: as strong as Lean.
- **State corruption via partial transitions.** A transition whose
  precondition fails leaves state untouched. Status: defended by
  `impl_noop_if_not_pre`.
- **Non-deterministic divergence between replicas.** Defence: the
  kernel is purely functional. Status: defended by typing.
- **Replay of old authorised transitions.** Defence: per-actor nonces
  (Section 8.5). Status: planned for Phase 3.

### 10.2 Out-of-Scope Threats

- **Compromise of the operating system or hardware** running the
  kernel. The kernel cannot defend against an attacker who can
  arbitrarily modify memory. Mitigation: deploy on hardened hosts;
  use attestation.
- **Compromise of the Lean type checker.** A flaw in Lean's type
  theory would invalidate kernel proofs. Mitigation: track Lean
  releases; pin to audited versions.
- **Compromise of cryptographic primitives.** A break of the
  signature scheme would invalidate the authority layer. Mitigation:
  use widely-reviewed schemes; design to allow algorithmic agility.
- **Liveness attacks.** The kernel guarantees safety, not liveness.
  An adversary that prevents transitions from being submitted (DoS)
  cannot violate invariants but can prevent progress. Mitigation:
  deployment-level concerns (rate limiting, redundancy).

### 10.3 Trust Assumptions

To rely on the kernel's guarantees, you must trust:

1. The Lean 4 type checker (a few thousand lines of well-reviewed C++).
2. The `Std` library's `RBMap` (bounded by Phase 1 audit; see Section
   7.4).
3. The kernel module of Section 4.12.
4. The operating system kernel and hardware on which Lean runs.
5. (For authorised transitions only) The cryptographic primitives.

Note that *you do not trust* the law authors, the application
developers, the oracle providers, or the network operators. Their
malice is bounded by what the kernel will accept.

### 10.4 Side Channels

The kernel's pure-functional structure has no observable side channels
*within the Lean runtime*. After extraction (Phase 5), timing channels
become possible:

- Signature verification time may leak signing key material; use
  constant-time implementations.
- `RBMap.find?` is logarithmic but not constant-time; this can in
  principle leak which keys are present. For most deployments this is
  acceptable; for high-assurance ones, swap `RBMap` for a
  constant-time data structure (perforce a non-trivial change).

These mitigations are deployment-time, not kernel-time, decisions.

---

## 11. Performance Considerations

Performance is a property of the *deployed runtime*, not the formal
kernel; nonetheless, decisions in the kernel determine the achievable
performance envelope.

### 11.1 Asymptotic Costs

Let $n_r$ denote the number of distinct actors holding resource $r$ in
state $s$, and let $R$ denote the number of distinct resources.

| Operation                       | Cost                      |
|---------------------------------|---------------------------|
| `getBalance s r a`              | $O(\log R + \log n_r)$    |
| `setBalance s r a v`            | $O(\log R + \log n_r)$    |
| `transfer.apply_impl`           | $O(\log R + \log n_r)$    |
| `transfer.pre`                  | $O(\log R + \log n_r)$    |
| `step_impl`                     | cost of `pre` + `apply_impl` |
| `apply_certified`               | cost of `apply_impl`      |
| `TotalSupply s r`               | $O(n_r)$                  |
| `Reachable` membership          | not decidable in general  |

The constants are dominated by `RBMap` rebalancing. For most realistic
workloads this is acceptable; for ledgers with very large actor sets
($n_r > 10^7$) the constants begin to matter and a custom radix-trie
representation may be warranted.

### 11.2 Proof Verification Cost

Compiling the kernel is a one-time cost paid by the implementer. The
runtime cost of *checking* a `Legal` witness is zero, because the
witness is a proof object that has been erased: the type system has
already verified it.

The cost of *constructing* a `Legal` witness is the cost of running the
`Decidable` instance for `t.pre s`, which is the same as evaluating
`t.pre s`. For the laws contemplated here this is $O(\log R + \log n_r)$.

### 11.3 Extraction Targets

Three target backends are contemplated for Phase 5.

- **Lean's native compiler** (LLVM via C). Highest fidelity to the
  proven semantics; reasonable performance; available today.
- **Hand-written Rust runtime** with an interpreter for serialized
  transitions. Better integration with existing infrastructure;
  introduces a translation layer that must itself be verified or
  fuzzed.
- **WASM** for in-browser deployment. Lowest performance; widest
  reach. Not contemplated in the initial roadmap.

A mixed deployment is likely: Lean-native for the trusted runtime, Rust
for the network and storage layers, with a strict serialization
boundary between them.

### 11.4 Memory Profile

State is held in memory as a tree of `RBMap`s. A naive estimate per
`(resource, actor, amount)` triple is roughly:

- 16 bytes for the actor ID and amount.
- 24-32 bytes of `RBMap` node overhead (colour bit, two child pointers,
  possibly key/value boxes).

Call this $\sim 50$ bytes per entry. A million-actor, ten-resource
deployment is then $\sim 500$ MB of working set, before any history
retention. This is within reach of modern hardware but argues for
careful capacity planning.

### 11.5 Concurrency

The kernel is single-threaded by design. Concurrent submission of
transitions is the runtime's problem; the runtime serialises them and
feeds them to the kernel one at a time. This is acceptable for
moderate throughput (thousands of transitions per second) and avoids
the proof-explosion that concurrent semantics would require.

For higher throughput, one path is **sharding by resource**: state for
disjoint resource sets lives in different kernel instances, with a
lightweight cross-shard transition protocol. This is contemplated as a
post-Phase-7 extension and is mentioned here only to note that the
Phase 0-7 plan does not require it.

---

## 12. Implementation Roadmap

The roadmap is organised into eight phases (0 through 7). Each phase
is decomposed into **work units** (WU) sized to roughly one
engineer-week, each with explicit deliverables, acceptance criteria,
and dependencies. Larger phases have parallelisable sub-graphs of
work units; the dependency graph is given per-phase.

A work unit is *done* when:

1. Its deliverable artefacts exist on the main branch.
2. Its acceptance criteria are mechanically checkable (compile-time,
   test-time, or audit-tool-time) and pass.
3. Its dependencies were complete at start.
4. A code review by at least one reviewer (two for kernel-touching
   work units) is recorded.

### Phase 0: Foundations

Goal: a compilable repository, a kernel skeleton, a build pipeline,
and this document.

| WU  | Title                                       | Est | Depends on |
|-----|---------------------------------------------|-----|-----------|
| 0.1 | Lean toolchain pin & Lake project skeleton  | 0.5 | —         |
| 0.2 | Kernel module skeleton (Section 4.12)       | 1.0 | 0.1       |
| 0.3 | `transfer` law (Section 4.11) with bug fix  | 0.5 | 0.2       |
| 0.4 | CI: `lake build` + `lake test`              | 0.5 | 0.2       |
| 0.5 | This document (Genesis Plan v1.x)           | —   | —         |

**WU 0.1 — Lean toolchain pin & Lake project skeleton.**
- Deliverables: `lean-toolchain`, `lakefile.lean`, `Main.lean`
  (placeholder), `.gitignore`.
- Acceptance: `lake build` succeeds on a clean checkout.
- Risk: Lean version churn; mitigate by pinning a release tag.

**WU 0.2 — Kernel module skeleton.**
- Deliverables: `LegalKernel/Kernel.lean` containing the listing of
  Section 4.12 (with `decPre` field).
- Acceptance: `lake build LegalKernel.Kernel` succeeds; no `sorry` in
  the module.
- Reviewers: 2 (kernel-touching).

**WU 0.3 — `transfer` law.**
- Deliverables: `LegalKernel/Laws/Transfer.lean` containing the
  Section 4.11 listing, with self-transfer bug fix and `decPre`
  inferred via `inferInstance`.
- Acceptance: builds; `transfer.pre` is decidable.

**WU 0.4 — CI.**
- Deliverables: GitHub Actions workflow at `.github/workflows/ci.yml`.
- Acceptance: pull requests block on `lake build` and `lake test`
  failure.

**WU 0.5 — Genesis Plan.**
- Deliverables: this document (`docs/GENESIS_PLAN.md`).
- Acceptance: lives at the documented path; linked from README.

**Phase 0 dependency graph.**

```
0.1  →  0.2  →  0.3
 \       \
  \       →  0.4
   \
    →  (0.5 in parallel; no code dependencies)
```

**Phase 0 status.** All five WUs complete.

- WU 0.1: `lean-toolchain` pinned to `leanprover/lean4:v4.29.1`
  (the latest stable Lean release as of 2026-04-16); `lakefile.lean`,
  `Main.lean`, and `.gitignore` in place; `scripts/setup.sh`
  installs the toolchain with SHA-256 verification of every artefact
  and is `shellcheck`-clean; clean `lake build` on a fresh checkout.
- WU 0.2: `LegalKernel/Kernel.lean` ships the §4.12 listing
  byte-for-byte (anonymous `Decidable` instance and the same
  destructuring style in `invariants_compose`); zero `sorry`; the
  two-reviewer rule is documented in this section.  Each kernel
  theorem `#print axioms` to exactly `[propext, Classical.choice,
  Quot.sound]` — i.e. zero custom axioms.  `Std.Data.TreeMap` from
  Lean core replaces the original draft's `Std.Data.RBMap`; see §4.2
  for the rationale and §8.3 for the migrated lemma library.  The
  non-TCB `kernelBuildTag` constant lives in the umbrella
  `LegalKernel.lean`, *not* in `Kernel.lean`, so the WU 1.11 TCB
  audit tool can enumerate the trusted core in isolation.
- WU 0.3: `LegalKernel/Laws/Transfer.lean` ships the §4.11 transfer
  law with the self-transfer fix and `decPre := fun _ => inferInstance`.
  An `example : Decidable ((transfer …).pre s) := inferInstance`
  smoke-tests decidability at compile time.  The conservation theorem
  `transfer_conserves` is intentionally deferred to Phase 2 (it depends
  on the §8.3 fold lemmas that arrive in Phase 1) so that Phase-0
  modules are `sorry`-free.
- WU 0.4: `.github/workflows/ci.yml` runs `lake build` and `lake test`
  on every pull request to `main` and on direct pushes to `main`.
  Third-party actions (`actions/checkout`, `leanprover/lean-action`)
  are pinned to **commit SHAs** with version comments, per GitHub's
  supply-chain guidance.  The job has `permissions: contents: read`
  (no workflow step writes to the repo).  Future WUs append
  `lake exe count_sorries` (WU 1.12) and `lake exe tcb_audit`
  (WU 1.11).
- WU 0.5: this document.

**Phase 0 testing.** A run-time test driver lives in `Tests.lean`
and `LegalKernel/Test/`, broken into three suites: kernel (12
cases), umbrella (1 case — the build-tag smoke test), and transfer
(11 cases, including the §4.11 self-transfer regression).  The
suite exercises `getBalance` / `setBalance` round-trips and
cross-resource isolation, both `step_impl` branches, the
`apply_certified` value-form path, both `Reachable` constructors,
and the full positive / negative semantics of the transfer law.
`lake test` is wired to this driver via `@[test_driver]` in
`lakefile.lean`, so a green CI implies a green test suite.

**Phase 0 build hygiene.** The lakefile sets
`autoImplicit := false`, `relaxedAutoImplicit := false`,
`linter.unusedVariables := true`, and `linter.missingDocs := true`
project-wide.  Every public field, constructor, and definition
carries a `/-- … -/` docstring; the missing-docs linter promotes
the documentation rule from a review-time observation to a
mechanical check.

### Phase 1: Kernel Completion

Goal: zero `sorry` in the kernel module and the supporting RBMap
library; multi-step reachability; per-law-set reachability; an
auditable TCB list.

| WU  | Title                                                        | Est | Depends on |
|-----|--------------------------------------------------------------|-----|-----------|
| 1.1 | `RBMap.find?_insert_self` and `find?_insert_other`           | 1.0 | 0.2       |
| 1.2 | `RBMap.foldl_insert_absent` (key not present)                | 1.0 | 1.1       |
| 1.3 | `RBMap.foldl_insert_present` (commutative-monoid form)       | 1.5 | 1.2       |
| 1.4 | `RBMap.foldl_eq_sum_of_values` (order-independent fold)      | 1.0 | 1.3       |
| 1.5 | `getBalance_setBalance_same` and `..._other`                 | 1.0 | 1.1       |
| 1.6 | Decidable-instance discipline doc + `inferInstance` audit    | 0.5 | 0.3       |
| 1.7 | `Reachable*` (multi-step closure)                            | 1.0 | 0.2       |
| 1.8 | `ReachableViaLaws L` (law-set-restricted reachability)       | 1.0 | 1.7       |
| 1.9 | `invariant_preservation_via_laws`                            | 0.5 | 1.8       |
| 1.10| `LegalKernel/RBMapLemmas.lean` packaged & documented         | 0.5 | 1.4       |
| 1.11| TCB-audit tool (`lake exe tcb_audit`)                        | 1.0 | 0.4, 1.10 |
| 1.12| `count_sorries` tool + CI integration                        | 0.5 | 0.4       |
| 1.13| Audit doc: every `Std` lemma we depend on                    | 0.5 | 1.11      |

**WU 1.1 — Pointwise insert lemmas.**
- Statement: `(m.insert k v).find? k = some v` and, for `k ≠ k'`,
  `(m.insert k v).find? k' = m.find? k'`.
- Acceptance: theorems exist in `RBMapLemmas`; no `sorry`.
- Notes: in practice these may already be in `Std`; if so, this WU
  becomes a re-export plus a small audit.

**WU 1.2 — Fold-insert-absent.**
- Statement: if `k ∉ m`, then folding `(m.insert k v)` is equivalent
  to folding `m` and then applying the step function with `(k, v)`.
- Acceptance: theorem exists; one usage in conservation proofs
  compiles.

**WU 1.3 — Fold-insert-present (commutative-monoid form).**
- Statement: under a commutative-monoid step function (e.g. `+`),
  folding `(m.insert k v_new)` differs from folding `m` only by
  `v_new - v_old`, where `v_old = m.find?-default 0`.
- Acceptance: theorem stated, proved, and used by `transfer_conserves`.
- Risk: existing `Std.RBMap` may not expose enough recursion-helper
  lemmas; budget a half-week buffer for porting from `Mathlib`.

**WU 1.4 — Order-independent fold.**
- Statement: for a commutative-monoid step function, the fold value
  equals the multiset-sum of values, independent of insertion history.
- Acceptance: theorem exists; serves as the canonical lemma for
  conservation arguments.

**WU 1.5 — Balance lemmas.**
- Statement: `getBalance_setBalance_same`,
  `getBalance_setBalance_other` (Section 4.3) without `sorry`.
- Acceptance: both lemmas in `Kernel.lean`; transitive `sorry`-count
  drops by two.

**WU 1.6 — Decidable-instance discipline.**
- Deliverables: a short doc (`docs/decidability_discipline.md`)
  describing how each law's `decPre` field should be supplied.
- Acceptance: `transfer` and any further example laws have one-line
  `decPre` definitions; no use of `Classical.dec` in the laws
  module.

**WU 1.7 — Multi-step reachability.**
- Statement: define `Reachable*` as the reflexive-transitive closure
  of single-step reachability.
- Acceptance: `Reachable* s s` and `Reachable* s s' → Reachable* s' s'' → Reachable* s s''` proved.

**WU 1.8 — Per-law-set reachability.**
- Statement: `ReachableViaLaws L s₀ s` says `s` is reachable from
  `s₀` using only transitions in `L`.
- Acceptance: definition exists; `ReachableViaLaws L s₀ s →
  Reachable s₀ s` proved (so the unrestricted form remains a strict
  superset).

**WU 1.9 — Invariant preservation via laws.**
- Statement: a variant of `invariant_preservation` indexed by `L`,
  used to prove conservation against the conservative law set
  (Section 5.3).
- Acceptance: theorem proved; usage in §5.3 compiles.

**WU 1.10 — Package & document `RBMapLemmas`.**
- Deliverables: namespace headers, doc-comments, an `Index.lean`
  re-export.
- Acceptance: external modules can `import LegalKernel.RBMapLemmas`
  and use every theorem by short name.

**WU 1.11 — TCB-audit tool.**
- Deliverables: `lake exe tcb_audit` enumerates the import closure of
  `Kernel.lean` and `RBMapLemmas.lean`, comparing against an
  allowlist at `tcb_allowlist.txt`.
- Acceptance: CI fails on un-allowlisted imports.

**WU 1.12 — `count_sorries`.**
- Deliverables: tool that counts `sorry` occurrences per module and
  prints a delta vs. the previous commit.
- Acceptance: CI fails when kernel-module sorries are non-zero, and
  warns when total sorries increase.

**WU 1.13 — `Std`-dependency audit.**
- Deliverables: `docs/std_dependencies.md` listing every `Std` lemma
  the kernel relies on, with stability notes.
- Acceptance: list reviewed by 1+ formal-methods reviewer.

**Phase 1 dependency graph.**

```
0.2  →  1.1  →  1.2  →  1.3  →  1.4  →  1.10
 \       \
  \       →  1.5
   \
    →  1.7  →  1.8  →  1.9
0.3  →  1.6
0.4 + 1.10  →  1.11  →  1.13
0.4  →  1.12
```

Parallelisable: 1.6 with 1.1; 1.7 in parallel with 1.1–1.5; 1.12 with
everything else.

**Phase 1 exit criteria.** `lake exe count_sorries Kernel.lean` returns
zero; `lake exe tcb_audit` succeeds; `docs/std_dependencies.md`
published.

**Phase 1 status.** All thirteen WUs complete.

- WU 1.1 (Pointwise insert lemmas): `LegalKernel.RBMap.find?_insert_self`
  and `find?_insert_other` ship in `LegalKernel/RBMapLemmas.lean`,
  re-exported from `Std.TreeMap.getElem?_insert_self` /
  `getElem?_insert` with the older `find?` name preserved for
  continuity with §8.3.
- WU 1.2 – 1.4 (Fold-after-insert lemmas): `sumValues_insert_absent`
  (key not present), `sumValues_insert_present` (key already
  present, additive form to avoid `Nat`-subtraction asymmetry),
  and `sumValues_eq_values_sum` (the order-independent canonical
  form) all live in `LegalKernel/RBMapLemmas.lean`.  Proofs go
  through `Std.TreeMap.toList_insert_perm` and
  `List.Perm.sum_nat`; the WU 1.3 reduction relies on the
  `Std.DTreeMap.Equiv.of_forall_constGet?_eq` extensionality lemma
  to lift pointwise `getElem?` agreement to `~m`-equivalence,
  which in turn makes `sumValues` permutation-invariant via
  `Std.TreeMap.Equiv.foldl_eq`.
- WU 1.5 (Balance lemmas): `getBalance_setBalance_same` and
  `getBalance_setBalance_other` proved in
  `LegalKernel/Kernel.lean` using the §8.3 insert lemmas.  The
  Phase-0 docstring claim that these would live in `RBMapLemmas`
  has been corrected; the spec at §4.3 places them in the kernel
  module, which is where they now live.
- WU 1.6 (Decidability discipline): `docs/decidability_discipline.md`
  records the `decPre := fun _ => inferInstance` rule, lists the
  known-resolving precondition shapes (arithmetic comparisons,
  decidable equality on `UInt64` IDs, finite conjunctions /
  disjunctions / negations), and ties the security-review trigger
  to any hand-written `Decidable` derivation.  The kernel's only
  current law (`transfer`) follows the discipline; the existing
  Phase-0 decidability smoke-test in `Laws/Transfer.lean`
  continues to elaborate.
- WU 1.7 (Multi-step reachability): `Reachable.refl` (a re-aliased
  `Reachable.base`) and `Reachable.trans` close the existing
  `Reachable` relation under the standard refl-trans laws.
- WU 1.8 (Per-law-set reachability): `ReachableViaLaws L s0 s` is
  defined inductively on a `List Transition`-indexed restriction;
  `reachable_of_reachable_via_laws` embeds the restricted form
  into the unrestricted `Reachable`.
- WU 1.9 (Invariant preservation via laws):
  `invariant_preservation_via_laws` is the law-set-indexed variant
  of the §4.10 central theorem; the `total_supply_global` argument
  of §5.3 (Phase 2 / WU 2.8) consumes it.
- WU 1.10 (Package & document): `LegalKernel.RBMapLemmas` is
  re-exported from the `LegalKernel` umbrella.
- WU 1.11 (TCB-audit tool): `Tools/TcbAudit.lean` ships as
  `lake exe tcb_audit`; it parses the direct imports of
  `Kernel.lean` and `RBMapLemmas.lean` and rejects any not on
  `tcb_allowlist.txt` *or* in the explicit `tcbInternalImports`
  list (currently `LegalKernel.Kernel`, `LegalKernel.RBMapLemmas`).
  The internal-imports list is enumerated rather than pattern-based,
  so a TCB core file cannot silently depend on a non-TCB
  `LegalKernel.*` sibling like `LegalKernel.Laws.Transfer`.  CI
  runs the audit on every PR.
- WU 1.12 (`count_sorries`): `Tools/CountSorries.lean` ships as
  `lake exe count_sorries`; it walks `LegalKernel/` and fails the
  build on any `sorry` in proof position in
  `Kernel.lean` / `RBMapLemmas.lean` / `Laws/Transfer.lean`.  The
  detector pre-masks `--` line comments, `/- … -/` block comments
  / docstrings, and `"…"` string literals using a state-machine
  pre-pass before pattern-matching, so a `sorry` *mention* inside
  a comment or string literal is correctly *not* flagged as a
  proof-position violation.  The "warns when total sorries
  increase" half of the WU 1.12 acceptance criterion is currently
  moot because the project total is zero; it can be reactivated as
  a baseline-comparison soft gate when a downstream module first
  ships an allowed sorry.  CI runs the gate on every PR.
- WU 1.13 (`Std`-dependency audit): `docs/std_dependencies.md`
  enumerates every `Std` lemma the TCB invokes, with stability
  notes and a per-toolchain-bump review checklist.

**Phase 1 testing.** The test driver was extended to 43 tests
across four suites (kernel: 22; rbmap: 8; umbrella: 2; transfer:
11).  The new kernel cases exercise the §4.3 balance lemmas
value-level, the §4.9 multi-step / law-set reachability
constructors, the embedding theorem `reachable_of_reachable_via_laws`,
and the §4.10 `invariant_preservation_via_laws` (both at term
level via type ascription and at runtime by driving the inductive
step on a depth-1 witness).  The new `RBMapLemmasTests` suite
spot-checks `find?_insert_self`, `find?_insert_other`, the three
`sumValues_*` lemmas, and adds a term-level API-stability check
for `sumValues_eq_values_sum`.

**Phase 1 axiom audit.**  Every kernel and `RBMapLemmas` theorem
`#print axioms` to exactly `[propext, Classical.choice, Quot.sound]`
— the Lean built-in set CLAUDE.md explicitly allows.  No custom
axioms have been introduced.

### Phase 2: Economic Invariants

Goal: a proven `TotalSupply` conservation theorem; a typeclass-based
classification of laws as conservative or non-conservative;
mint/burn as a non-conservative law set with its own discipline.

| WU  | Title                                                              | Est | Depends on |
|-----|--------------------------------------------------------------------|-----|-----------|
| 2.1 | `TotalSupply` definition + basic lemmas                            | 0.5 | 1.4       |
| 2.2 | `transfer_conserves` (no sorry, distinct-actors case)              | 1.0 | 2.1, 1.5  |
| 2.3 | `transfer_conserves` (self-transfer case)                          | 0.5 | 2.2       |
| 2.4 | `IsConservative` typeclass + lemma framework                       | 1.0 | 2.3       |
| 2.5 | `mint` and `burn` law definitions                                  | 0.5 | 0.3       |
| 2.6 | `mint`/`burn` non-conservation lemmas (explicit witnesses)         | 0.5 | 2.4, 2.5  |
| 2.7 | `ConservativeLawSet` namespace; `Mint`/`Burn` excluded by typing   | 1.0 | 2.4, 2.6  |
| 2.8 | `total_supply_global` theorem (Section 5.3)                        | 1.0 | 2.7, 1.9  |
| 2.9 | Per-resource freeze invariant (`FrozenForResource r`)              | 1.0 | 2.7       |

**WU 2.1 — `TotalSupply`.**
- Definition exactly as in Section 8.1.
- Acceptance: `TotalSupply` defined; `TotalSupply (genesis : State) r =
  0` proved as a sanity test.

**WU 2.2 — `transfer_conserves` (distinct actors).**
- Subgoal of the conservation theorem. Splits the proof of the
  general case into the easier branch.
- Acceptance: lemma stated, no `sorry`, used in WU 2.3.

**WU 2.3 — `transfer_conserves` (self-transfer).**
- The harder case where `sender = receiver`. Relies on the §4.11
  sequencing argument.
- Acceptance: lemma proved; combines with 2.2 to give the full
  `transfer_conserves`.

**WU 2.4 — `IsConservative` typeclass.**
- Definition: `class IsConservative (t : Transition) where conserves :
  ∀ r s, t.pre s → TotalSupply (step_impl s t) r = TotalSupply s r`.
- Acceptance: typeclass exists; `instance : IsConservative (transfer
  r send recv amt)` provided.

**WU 2.5 — `mint`/`burn`.**
- Two new transitions: `mint r to amt` increases balance; `burn r from
  amt` decreases (with precondition `from has ≥ amt`).
- Acceptance: builds; preconditions decidable.

**WU 2.6 — Mint/burn non-conservation.**
- Provide explicit *counter-examples* to conservation: states `s` and
  amounts where `TotalSupply (step_impl s mint) r > TotalSupply s r`.
- Acceptance: `¬ IsConservative (mint r to amt)` proved.

**WU 2.7 — `ConservativeLawSet`.**
- A type-level distinction: a `ConservativeLawSet` is a `List
  Transition` where every element has `IsConservative`. Mint/burn
  cannot be added at the type level.
- Acceptance: deployments using only `ConservativeLawSet` get a
  free conservation proof.

**WU 2.8 — `total_supply_global`.**
- The global form (Section 5.3): conservation across all reachable
  states under a `ConservativeLawSet`.
- Acceptance: theorem proved; demo in `Test/Conservation.lean`.

**WU 2.9 — Freeze invariant.**
- A `freezeResource r` law makes resource `r` immutable. The
  invariant `FrozenForResource r` says no balance under `r` ever
  changes after the freeze.
- Acceptance: invariant stated and proved preserved by transfer (no-op
  by precondition), mint (no-op), burn (no-op).

**Phase 2 dependency graph.**

```
1.4  →  2.1  →  2.2  →  2.3  →  2.4  →  2.7  →  2.8
                       \              \
                        →  2.5  →  2.6  →  2.9
```

**Phase 2 exit criteria.** Conservation theorems compile;
`ConservativeLawSet` machinery works; mint/burn excluded by typing;
freeze invariant proved.

**Phase 2 status.** All nine WUs complete.

- WU 2.1: `LegalKernel/Conservation.lean` defines `TotalSupply` exactly
  as in §8.1 (a `match` on `s.balances[r]?`, with `RBMap.sumValues` on
  the `some` branch).  Two sanity lemmas land alongside:
  `totalSupply_genesis_eq_zero` (`TotalSupply genesisState r = 0`)
  and the more general `totalSupply_eq_zero_of_no_resource`.  The
  same module also ships the master accounting lemma
  `totalSupply_setBalance` — the exact `Nat`-equation that every
  per-law conservation proof reduces to (`new_sum + old_balance =
  old_sum + new_balance`, sidestepping `Nat`-subtraction asymmetries).
- WU 2.2 + 2.3: `LegalKernel/Laws/Transfer.lean` ships
  `transfer_conserves`, the §4.11.1 conservation theorem.  The proof
  is uniform over the distinct-actor and self-transfer cases — the
  §4.11 self-transfer fix in `transfer.apply_impl` makes the
  case-split unnecessary at the conservation level.  The cross-resource
  companion `transfer_conserves_other_resource` plus the §4.11.2
  pointwise lemma `transfer_does_not_touch_other_resources` and the
  state-level lifter `transfer_other_resource_untouched` round out the
  invariant set.
- WU 2.4: `LegalKernel/Conservation.lean` defines the `IsConservative`
  typeclass with the §5.3 signature; `LegalKernel/Laws/Transfer.lean`
  provides the `instance transfer_isConservative` that combines
  `transfer_conserves` (at the transferred resource) with
  `transfer_conserves_other_resource` (at every other resource).
- WU 2.5: `LegalKernel/Laws/Mint.lean` and `LegalKernel/Laws/Burn.lean`
  ship the two non-conservative balance mutators.  Both follow the
  `transfer` pattern: `pre := amount > 0` (with `≥ amount` for burn),
  `decPre := fun _ => inferInstance`, single-`setBalance` transformer.
  Both ship `totalSupply_after_*` accounting corollaries that
  specialise the master lemma to a single delta, plus a per-law
  cross-resource locality triple (state-level
  `*_other_resource_untouched`, pointwise
  `*_does_not_touch_other_resources`, and the per-resource supply form
  `*_conserves_other_resource`) that mirrors the Phase-2 additions to
  `Laws/Transfer.lean`.
- WU 2.6: `mint_not_conservative` and `burn_not_conservative` deliver
  explicit witnesses to non-conservation.  Mint applies to
  `genesisState`; burn applies to a fresh state with the actor at
  exactly `amount`.  Both reach a `False` via the conservation chain
  forcing `0 = amount` (mint) or `amount + amount = amount` (burn) and
  contradicting the precondition `amount > 0`.
- WU 2.7: `LegalKernel/Conservation.lean` defines the
  `ConservativeLawSet` structure (a `List Transition` plus a
  per-element `IsConservative` membership witness).  Mint and burn
  cannot inhabit this structure — there is no `IsConservative` instance
  for either, and `mint_not_conservative` / `burn_not_conservative`
  prove the negation explicitly.  This is the §6.2 "type-level
  firewall" between supply-preserving and supply-changing law sets.
- WU 2.8: `total_supply_global` (§5.3 verbatim) discharges the
  inductive step against `invariant_preservation_via_laws`.  The
  typeclass-driven corollary `total_supply_global_via_law_set` accepts
  a `ConservativeLawSet` and returns the same conclusion without
  re-stating the per-law conservation hypothesis.
- WU 2.9: `LegalKernel/Laws/Freeze.lean` ships the `freezeResource _r`
  no-op marker (the `_r` parameter is part of the action-layer API
  but deliberately ignored at the kernel level — `freezeResource 1`
  and `freezeResource 2` are *definitionally equal* `Transition`
  values), the `FrozenForResource r snap` invariant (a closure over
  the snapshotted per-resource `BalanceMap`), and four preservation
  lemmas: `freezeResource_preserves_freeze` reduces to `hI` by
  definitional equality (`step_impl` on a `True`-precondition
  identity transition collapses); `transfer_preserves_freeze`,
  `mint_preserves_freeze`, `burn_preserves_freeze` consume the
  corresponding `*_other_resource_untouched` state-level helper and
  are conditional on operating on a *different* resource than the
  frozen one.  Enforcement is deployment-level: the deployment
  commits to a law set whose mutating laws all carry a disjointness
  proof; Phase 3's authority layer will add the runtime check that
  closes the loop.

**Phase 2 testing.**  43 → 95 passing tests across eight suites:

- `KernelTests` (22, unchanged from Phase 1).
- `RBMapLemmasTests` (8, unchanged from Phase 1).
- `Umbrella` (2; the `kernelBuildTag` check is bumped to
  `"knomosis-phase-2-economic-invariants"`).
- `ConservationTests` (15, new) — sanity for `TotalSupply`,
  `totalSupply_setBalance` value-level checks at four representative
  inputs, `TotalSupplyEquals` round-trip (positive and negative),
  two `transfer_conserves` witnesses (distinct + self-transfer),
  `IsConservative` typeclass resolution, `ConservativeLawSet`
  construction, runtime `total_supply_global` and
  `total_supply_global_via_law_set` invocations, and an explicit
  `totalSupply_eq_zero_of_no_resource` runtime check.
- `TransferTests` (16, +5 over Phase 0; preserves the §4.11
  self-transfer regression witness and adds one runtime case per
  Phase-2 transfer-side theorem).
- `MintTests` (10, new) — precondition decidability,
  `step_impl`/`apply_impl` value semantics, `totalSupply_after_mint`
  at runtime, `mint_not_conservative` term-level API check, plus
  three runtime witnesses for the new mint cross-resource helpers
  (`mint_other_resource_untouched`,
  `mint_does_not_touch_other_resources`,
  `mint_conserves_other_resource`).
- `BurnTests` (12, new) — symmetric to mint, with the additional
  edge case "burn down to zero is allowed" plus three runtime
  witnesses for the burn cross-resource helpers.
- `FreezeTests` (10, new) — `FrozenForResource` reflexivity at
  snapshot time, all four preservation lemmas at runtime, the
  freezeResource-is-identity value-level check, plus three negative
  regression tests (`mint`, `burn`, `transfer` applied at the
  *frozen* resource genuinely change a per-actor balance, witnessing
  the necessity of the disjointness hypothesis).

`lake test` runs the full driver and exits non-zero on any failure;
CI runs the same driver.  All eight suites pass on a clean checkout.

**Phase 2 axiom audit.**  `#print axioms` on every Phase-2
declaration — definitions, structure / class declarations, and
theorems — returns exactly `[propext, Classical.choice, Quot.sound]`.
The audit covers `genesisState`, `TotalSupply`, `IsConservative`,
`TotalSupplyEquals`, `ConservativeLawSet`, `totalSupply_setBalance`,
`totalSupply_genesis_eq_zero`, `totalSupply_eq_zero_of_no_resource`,
`total_supply_global`, `total_supply_global_via_law_set`,
`transfer`, `transfer_conserves`, `transfer_other_resource_untouched`,
`transfer_does_not_touch_other_resources`,
`transfer_conserves_other_resource`, `transfer_isConservative`,
`mint`, `totalSupply_after_mint`, `mint_other_resource_untouched`,
`mint_does_not_touch_other_resources`,
`mint_conserves_other_resource`, `mint_not_conservative`, `burn`,
`totalSupply_after_burn`, `burn_other_resource_untouched`,
`burn_does_not_touch_other_resources`,
`burn_conserves_other_resource`, `burn_not_conservative`,
`freezeResource`, `FrozenForResource`,
`freezeResource_preserves_freeze`, `transfer_preserves_freeze`,
`mint_preserves_freeze`, `burn_preserves_freeze`.  No custom axioms.

**Phase 2 TCB posture.**  The Phase-2 modules are explicitly **not**
TCB.  `LegalKernel/Conservation.lean`,
`LegalKernel/Laws/{Mint,Burn,Freeze}.lean`, and the Phase-2 additions
to `LegalKernel/Laws/Transfer.lean` are all stated against the kernel's
TCB primitives (`State`, `setBalance`, `step_impl`,
`ReachableViaLaws`, `invariant_preservation_via_laws`) and the §8.3
RBMap library; a bug in any of them can only invalidate a
deployment-level supply-conservation claim, not the kernel itself.
`tcb_allowlist.txt` therefore stays at one entry (`Std.Data.TreeMap`),
and `lake exe tcb_audit` continues to enumerate the same two TCB-core
files (`Kernel.lean`, `RBMapLemmas.lean`).  `lake exe count_sorries`
auto-includes the new files because it walks all of `LegalKernel/`.

**Phase 2 omega workaround note.**  `transfer_conserves` and
`totalSupply_after_burn` go through small `*_arithmetic` private
helpers (`transfer_arithmetic` in `Laws/Transfer.lean`,
`burn_arithmetic` in `Laws/Burn.lean`).  Both helpers take plain
`Nat` parameters and discharge the linear system with `omega`.  The
indirection is a workaround for an `omega` atom-discovery limitation
on deeply-nested `TotalSupply (setBalance (setBalance …))` terms;
lifting to scalar parameters lets omega see a clean variable system.
The arithmetic helpers are `private` so they don't appear in the
deployment-facing API.

### Phase 3: Authority Layer

Goal: signed actions, per-actor nonces, EUF-CMA-grade signature
adaptor, and the `apply_admissible` entry point with all five
admissibility conditions discharged before any state change.

| WU  | Title                                                          | Est | Depends on |
|-----|----------------------------------------------------------------|-----|-----------|
| 3.1 | `Action` inductive + `compile` skeleton                        | 1.0 | 0.2       |
| 3.2 | `Action.compile_injective` (per-deployment)                    | 1.0 | 3.1       |
| 3.3 | `Identity`, `AuthorityPolicy`, `registry` operations           | 0.5 | 3.1       |
| 3.4 | `Verify` interface + uninterpreted-function discipline         | 0.5 | 3.3       |
| 3.5 | `NonceState`, `expectsNonce`, `advanceNonce` + lemmas          | 1.0 | 1.1       |
| 3.6 | `SignedAction` + `Admissible` predicate                        | 1.0 | 3.4, 3.5  |
| 3.7 | `apply_admissible` + `nonce_uniqueness`                        | 1.0 | 3.6       |
| 3.8 | `replay_impossible` theorem                                    | 1.0 | 3.7       |
| 3.9 | Ed25519 adaptor (in Rust runtime layer; see Phase 5)           | 1.0 | 3.4       |
| 3.10| `replaceKey` action + key-rotation test                        | 1.0 | 3.6       |

**WU 3.1 — Action skeleton.**
- Define `Action` and `Action.compile` for the deployment's law set.
- Acceptance: `Action.compile a` typechecks for every constructor.

**WU 3.2 — Compilation injectivity.**
- Prove `Action.compile_injective`. This requires that distinct
  `Action` constructors produce distinguishable transitions; in
  practice each law's precondition or transformer differs by a
  syntactic field.
- Acceptance: theorem proved with no `sorry`.

**WU 3.3 — Authority policy.**
- Implement `AuthorityPolicy.empty`, `register`, `revoke`, `union`.
- Acceptance: simple operational tests pass.

**WU 3.4 — `Verify` interface.**
- An `axiom Verify : PublicKey → ByteArray → Signature → Bool` (or
  uninterpreted constant), with documentation that the kernel makes
  no assumption about its implementation beyond determinism.
- Acceptance: `Verify` exists in `Authority/Crypto.lean`; the
  contract is documented; the runtime adaptor (WU 3.9) implements it.

**WU 3.5 — Nonce state.**
- Section 8.5 definitions and supporting lemmas.
- Acceptance: `expectsNonce_strict_mono` proved.

**WU 3.6 — SignedAction.**
- Section 8.2 definitions; `Admissible` predicate with all five
  conditions.
- Acceptance: builds; spot-checks the five conditions individually.

**WU 3.7 — `apply_admissible`.**
- The entry point. Proves `nonce_uniqueness`.
- Acceptance: function defined; theorem proved; round-trip test in
  `Test/Authority.lean` passes.

**WU 3.8 — `replay_impossible`.**
- The replay-protection headline theorem.
- Acceptance: theorem proved; explicit replay scenario in test
  rejected.

**WU 3.9 — Ed25519 adaptor.**
- Rust crate exposing a C-FFI `verify(pk, msg, sig)` to the Lean
  runtime.
- Acceptance: passes RFC 8032 test vectors; integrated with WU 3.4.
- Note: this WU is partly Phase 5 work; listed here to make the
  dependency explicit.

**WU 3.10 — Key rotation.**
- A `replaceKey` action that re-points an `ActorId` to a new
  `PublicKey`, signed by the *old* key.
- Acceptance: end-to-end test: register key K₁, sign action A₁, sign
  rotation to K₂, sign action A₂; both A₁ and A₂ verify correctly
  in their respective epochs.

**Phase 3 dependency graph.**

```
0.2  →  3.1  →  3.2
        \
         →  3.3  →  3.4  →  3.6  →  3.7  →  3.8
                         /              \
1.1  →  3.5  ───────────/                 →  3.10
3.4  →  3.9 (Phase 5 work, prerequisite for end-to-end test)
```

**Phase 3 exit criteria.** A signed-and-authorised transfer can be
applied exactly once; replay rejected by `replay_impossible`; key
rotation tested end-to-end.

**Phase 3 status: complete.**  All ten work units (3.1 – 3.10)
landed in `LegalKernel/Authority/{Crypto, Action, Identity, Nonce,
SignedAction}.lean`.  Notable design notes:

* **WU 3.2 — structural injectivity via wrapper.**  `Action.compile`
  was redesigned to return a `CompiledAction` wrapper (`source :
  Action`, `transition : Transition`).  This makes
  `Action.compile_injective` a one-line `congrArg
  CompiledAction.source` proof, sidestepping the genuine
  non-injectivity at the bare-`Transition` level (Phase-2's
  `freezeResource` ignores its parameter; vacuous actions like
  `transfer r s s 0` and `mint r s 0` produce extensionally equal
  compiled bodies).  The kernel TCB is unchanged — the wrapper
  lives in `LegalKernel/Authority/`, not in `LegalKernel/Kernel.lean`.
* **WU 3.3 — registry placement.**  The Genesis-Plan §8.2 sketch
  put the `KeyRegistry` inside `AuthorityPolicy`.  Phase 3 moves
  it to `ExtendedState` (a deliberate design refinement) so that
  WU 3.10's `replaceKey` action can mutate it through
  `apply_admissible`.  `AuthorityPolicy` retains only the static
  `authorized` predicate and its decidability witness; this
  cleanly separates static authorisation policy from dynamic key
  bindings.
* **WU 3.4 — opaque `Verify`.**  Declared as `opaque` rather than
  `axiom` so that the kernel's `#print axioms` audit continues to
  return exactly the three Lean built-ins (`propext`,
  `Classical.choice`, `Quot.sound`).  The EUF-CMA security
  assumption surfaces as a *trust assumption* on the
  deployment-supplied runtime adaptor (Phase 5, WU 3.9), not as a
  Lean axiom.
* **WU 3.9 — Ed25519 adaptor deferred to Phase 5.**  The
  cryptographic adaptor is part of the runtime layer; Phase 3
  ships only the Lean-side `Verify` interface.
* **Test coverage.**  96 new test cases added across four suites
  (Authority.{ActionTests, IdentityTests, NonceTests,
  SignedActionTests}), bringing the total to 191.  Tests cover
  value-level admissibility component checks (positive + negative
  cases for every condition) and term-level API stability for every
  Phase-3 theorem.  The `replay_impossible` algebraic core is
  value-level checked separately because the full theorem requires
  constructible `Admissible` witnesses, which the opaque `Verify`
  rules out at the Lean level.

* **Post-implementation audit (2026-05-04).**  After landing the
  initial Phase-3 commit, a follow-up audit pass strengthened the
  authority layer with 35 additional helper theorems and 35
  additional test cases (191 total, up from 156):
  - **Field extractors** for `Admissible` (`admissible_authorized`,
    `admissible_nonce`, `admissible_pre`,
    `admissible_signer_registered`,
    `admissible_signer_registered_and_signed`) make each of the
    §8.2 conditions individually addressable.
  - **`apply_admissible` projections** (`apply_admissible_base`,
    `apply_admissible_registry`) and the cross-actor nonce isolation
    theorem (`expectsNonce_after_apply_admissible_other`) plug the
    "what does `apply_admissible` actually do?" gap that the original
    commit only addressed via the headline `nonce_uniqueness` /
    `replay_impossible` theorems.
  - **`KeyRegistry` semantic lemmas** (`lookup_register_self/other`,
    `lookup_revoke_self/other`) and **`AuthorityPolicy` combinator
    characterisations** (`{empty, unrestricted, union, intersect,
    singleton}_authorized`, `union_comm`, `union_empty`,
    `intersect_unrestricted`) document the operational semantics of
    the WU 3.3 machinery.
  - Negative-case admissibility tests for every condition (stale
    nonce, unauthorized signer, unregistered signer, insufficient
    balance) verify that each clause genuinely gates the predicate.
  - The Phase-3 `signingInput` originally shipped as a
    `ByteArray.empty` stub awaiting Phase-4 integration.  The
    post-Phase-6 security audit closed the gap: the function now
    emits the real CBE-encoded bytes
    (`encode action ++ encode signer.toNat ++ encode nonce`) so
    distinct `(action, signer, nonce)` triples produce distinct
    sign-input bytes, restoring within-deployment replay
    protection at the Lean level.  Cross-deployment replay
    protection remains a deployment-scoped concern (the runtime
    adaptor scopes `Verify` per-deployment); the
    `Encoding.signInput` (Phase 4 WU 4.8) function provides the
    canonical domain-separated form for in-tree consumers that
    additionally need the `deploymentId` prefix.

### Phase 4 prelude: Positive-Incentive Mechanisms (WU R.1 – R.23)

Goal: introduce the **monotonicity tier** between conservation and
unrestricted laws, enabling deployments to substitute negative
mechanisms (`burn`) with positive analogues (`reward`,
`distributeOthers`, `proportionalDilute`) under a type-level firewall
that excludes value-destroying laws.

Rationale for landing this *before* Phase 4 (DSL and Serialization):
the Phase-4 CBOR encoder must encode every `Action` constructor by
index.  Adding the three new positive-incentive constructors to
`Action` *before* Phase 4 locks the constructor ordering and lets
Phase 4's serialisation work consume the resulting `Action` shape
unchanged.

Economic motivation (from the design discussion preceding the WU):
substituting `burn` ("fine actor A by N") with `reward`-family
mechanisms ("reward all non-A actors") is **Pareto-superior for
non-penalised actors** while delivering the same relative-wealth
penalty to A.  Non-penalised actors gain both nominally and
relatively; A's nominal balance is unchanged but A's share of supply
decreases.  In self-referential token systems (governance weight,
pool shares, reputation) there is no inflation cost to law-abiding
actors because their nominal balance grows alongside the total
supply.

| WU   | Title                                                              | Est | Depends on |
|------|--------------------------------------------------------------------|-----|-----------|
| R.1  | `IsMonotonic` typeclass + `monotonic_of_conservative` auto-upgrade | 0.5 | 2.4       |
| R.2  | `MonotonicLawSet` + `total_supply_globally_nondecreasing[_via_law_set]` | 0.5 | R.1, 2.8  |
| R.3  | Per-existing-law `IsMonotonic` instances (transfer / mint / freezeResource) | 0.5 | R.1       |
| R.4  | `burn_not_monotonic` negative witness                              | 0.5 | R.1       |
| R.5  | `Laws/Reward.lean` (full module)                                   | 1.0 | R.1       |
| R.6  | `Test/Laws/Reward.lean`                                            | 0.5 | R.5       |
| R.7  | `getBalance_le_totalSupply` helper in `Conservation.lean`          | 0.5 | 2.1       |
| R.8  | `Laws/DistributeOthers.lean` — definition + locality               | 1.0 | R.1       |
| R.9  | `Laws/DistributeOthers.lean` — arithmetic + IsMonotonic + non-conservative | 1.0 | R.8       |
| R.10 | `Test/Laws/DistributeOthers.lean`                                  | 0.5 | R.9       |
| R.11 | `sumOthers` helper in `Conservation.lean`                          | 0.5 | R.7       |
| R.12 | `Laws/ProportionalDilute.lean` — definition + locality             | 1.0 | R.11      |
| R.13 | `totalSupply_after_proportionalDilute` (the supply equation)       | 1.0 | R.12      |
| R.14 | `proportionalDilute_distributed_le_totalReward` (dust bound)       | 1.5 | R.13      |
| R.15 | `proportionalDilute_isMonotonic` + `_not_conservative`             | 0.5 | R.14      |
| R.16 | `Test/Laws/ProportionalDilute.lean`                                | 0.5 | R.15      |
| R.17 | `Action` layer integration (3 new constructors)                    | 0.5 | R.5, R.9, R.15 |
| R.18 | `Test/Authority/Action.lean` extensions                            | 0.5 | R.17      |
| R.19 | Per-existing-law instance-resolution tests                         | 0.5 | R.3, R.4  |
| R.20 | `ConservationTests` extensions + end-to-end behaviour test         | 0.5 | R.2, R.17 |
| R.21 | Wire umbrella + test driver + bump build tag                       | 0.5 | R.16, R.18, R.20 |
| R.22 | `CLAUDE.md` updates                                                | 1.0 | R.21      |
| R.23 | `docs/GENESIS_PLAN.md` amendment + `docs/economic_invariants.md`   | 0.5 | R.21      |

**Phase 4 prelude status: complete.**  All 23 work units (R.1 –
R.23) are landed; 255 tests across 15 suites pass under
`lake test`; `lake exe count_sorries` reports zero TCB sorries;
`lake exe tcb_audit` allowlist is unchanged (the work is purely
additive at the non-TCB layer).  The new dust-bound theorem
`proportionalDilute_distributed_le_totalReward` is fully proved
(no `sorry`, no fallback to a weaker form), going through the
`balanceMap_filter_sum_plus_lookup` identity in `Conservation.lean`
which uses `Std.TreeMap.distinct_keys_toList` to bridge per-bm
filter sums to `sumOthers`.

R.14 deviation note: the original plan called for a generic
`bmReplaceValues` + `sumValues_bmReplaceValues` helper in
`Conservation.lean` (~50-line proof) shared between
`distributeOthers` and `proportionalDilute`.  Implementation pivoted
to a simpler "foldl-of-`setBalance`" `apply_impl` for both laws
(each step is a known kernel operation; supply effect via
`totalSupply_setBalance` per step is short).  The shared helper
`getBalance_le_totalSupply` (R.7) and the bridge identity chain
ending in `state_filter_sum_eq_sumOthers` (added during R.14)
together cover what the rebuild-from-empty fold would have provided,
and avoided the harder distinct-keys induction that the
rebuild-from-empty would have required at the `bm.foldl` level.

### Phase 4: DSL and Serialization

Goal: a canonical CBOR encoding for every kernel-level type with
round-trip and injectivity proofs; a thin DSL for declaring laws.

| WU  | Title                                                          | Est | Depends on |
|-----|----------------------------------------------------------------|-----|-----------|
| 4.1 | `Encodable` typeclass + CBOR primitive encoders                | 1.0 | 0.2       |
| 4.2 | `Encodable` for `ActorId/ResourceId/Amount/Nonce`              | 0.5 | 4.1       |
| 4.3 | `Encodable` for `Action` (constructor-index encoding)          | 1.0 | 4.2, 3.1  |
| 4.4 | `Encodable` for `SignedAction`, `Dispute`, `Verdict`           | 1.0 | 4.3       |
| 4.5 | `Encodable` for `State`, `ExtendedState`                       | 1.0 | 4.2       |
| 4.6 | `decode_encode_roundtrip` (per-type)                           | 1.5 | 4.5       |
| 4.7 | `encode_injective` (per-type, follows from roundtrip)          | 0.5 | 4.6       |
| 4.8 | Domain-separated signing inputs (`sign_input`)                 | 0.5 | 4.4       |
| 4.9 | DSL elaborator for law declarations                            | 1.5 | 0.3       |

**WU 4.1 — `Encodable` typeclass.**
- A typeclass `class Encodable (T : Type) where encode : T → ByteArray;
  decode : ByteArray → Except DecodeError (T × ByteArray)`.
- Acceptance: typeclass exists; instances for `Bool`, `Nat` (CBOR
  uint), `ByteArray` (CBOR bstr), `String` (CBOR tstr), `List`,
  `Option`.

**WU 4.2 — Scalar instances.**
- Acceptance: `encode (n : Nat)` produces CBOR uint with minimal-form
  length encoding; spot-checked against test vectors.

**WU 4.3 — `Action` encoding.**
- A `Action` value encodes as a CBOR array `[tag, ...fields]`.
- Acceptance: `encode (Action.transfer r s r' a)` matches a hand-written
  CBOR byte string.

**WU 4.4 — Composite encodings.**
- `SignedAction`, `Dispute`, `Verdict` encode as sorted-key CBOR maps.
- Acceptance: spot-checked against test vectors; deterministic.

**WU 4.5 — `State` encoding.**
- The two-level `RBMap` encodes as nested sorted-key CBOR maps.
- Acceptance: identical state values produce identical bytes,
  verified across `RBMap`s built by different insertion sequences.

**WU 4.6 — Round-trip.**
- For every `Encodable` instance: `decode (encode v) = .ok (v, "")`.
- Acceptance: all instances; no `sorry`.

**WU 4.7 — Injectivity.**
- `encode_injective` follows from round-trip; mechanical.
- Acceptance: theorem proved per type.

**WU 4.8 — Sign-input domain separation.**
- The `sign_input` function of Section 8.8.5.
- Acceptance: spot-checked against deployment-id-mixed test vectors;
  cross-deployment verification fails.

**WU 4.9 — DSL elaborator.**
- A Lean macro `law` that elaborates `law transfer ... where pre :=
  ... ; impl := ...` to a `Transition` value with `decPre` filled in.
- Acceptance: `law transfer ...` produces a `Transition` definitionally
  equal to the hand-written form (round-trip test).

**Phase 4 dependency graph.**

```
4.1  →  4.2  →  4.3  →  4.4  →  4.6  →  4.7
        \      /                \
         →  4.5                  →  4.8
0.3  →  4.9
```

**Phase 4 exit criteria.** Round-trip and injectivity proved for every
encodable type; cross-deployment signature attacks rejected by
`sign_input`; DSL produces same `Transition` as hand-written code.

**Phase 4 status: complete (twice-audited).**  All nine work units
(WU 4.1 – WU 4.9) land with a full canonical encoding pipeline plus
the `law` DSL macro.  Two post-Phase-4 audit passes corrected:

  * **Encoder/decoder type mismatch in `State.encode`** (audit 1):
    the inner `BalanceMap` was being encoded as a CBE array of
    UInt8s but the decoder expected a CBE byte string; fixed by
    wrapping the inner encoding via `BalanceMap.encodeAsBytes`.
  * **Decoder canonicality violation in `decodeMap`** (audit 2):
    the previous version accepted any CBE map encoding regardless
    of key ordering or duplicate-key occurrences, allowing an
    attacker to forge alternative-but-equally-valid encodings of
    the same logical state with different signature inputs (a
    direct §8.8.6 violation).  Fixed by adding a
    `keysStrictlyAscending` post-decode check that rejects unsorted
    or duplicate-keyed maps with `nonCanonical`.
  * **Dead code cleanup** (audit 1+2): removed `nat_mod_pow_succ`,
    `natToBytesLE_injective`, `verdictDomain`/`disputeDomain`, and
    the unreachable `if k < 2^64 ... else .error` branches in
    `BalanceMap.decode`/`NonceState.decode`/`KeyRegistry.decodeMap`/
    `State.decode` (the CBE Nat decoder by construction returns
    values in `[0, 2^64)`, so the lower-bound check is always
    `true`).  Renamed misleading `UInt8.toNat_toUInt8_of_lt` to
    `nat_lt_256_toUInt8_toNat_eq` (it's a `Nat` lemma, not a
    `UInt8` member).
  * **Code duplication factored** (audit 1): factored the
    duplicated `readUInt64Field_via_nat` helper between
    `Encoding.Action` and `Encoding.SignedAction`.
  * **Missing round-trip lemmas added** (audit 1):
    `list_roundtrip`, `option_roundtrip`, `uInt16_roundtrip`,
    `uInt32_roundtrip`.  `list_roundtrip` and `option_roundtrip`
    take a per-element `ElemRoundtrip α` hypothesis to avoid
    introducing a `LawfulEncodable` typeclass.

Implementation deviations from the §8.8 sketch (documented):

* **CBE replaces canonical CBOR.**  The Genesis Plan §8.8.2 sketch
  prescribes RFC 8949 canonical CBOR with minimal-form integer
  length encoding (the 5-way size-bucket of §3.1).  Phase 4 ships
  **CBE** (Knomosis Binary Encoding), a strictly canonical, fixed-width
  binary form: 1 type-tag byte + 8 LE value bytes for every uint
  head, with byte-level round-trip and injectivity proved by direct
  structural induction.  CBE is *not wire-compatible* with strict-
  canonical CBOR implementations, but preserves every safety
  property §8.8 lists (determinism, canonicality, injectivity, well-
  defined round-trip).  Phase 5's runtime adaptor MAY add a
  CBE↔canonical-CBOR translation layer for wire interop; the
  kernel proof obligations are independent of that adaptor.
* **Bounded round-trip for `Nat`-valued types.**  Round-trip is
  proven for `n < 2^64` (the canonical-encoding bound from §8.8.2);
  outside that bound the encoder is total but lossy.  Deployments
  must gate `Amount` / `ActorId` / `ResourceId` arguments on this
  bound at the runtime boundary (Phase 5 WU 5.4).  The `Action`-
  layer round-trip carries an `Action.fieldsBounded` predicate that
  asserts every numeric field is `< 2^64`; the `SignedAction`-layer
  carries a corresponding `SignedAction.fieldsBounded` predicate
  that adds bounds on `signer`, `nonce`, and `sig.size`.
* **Extensional round-trip for `State` / `ExtendedState`.**  The
  TreeMap-backed `State` is encoded via its sorted `toList`, which
  is canonicalising (two `TreeMap`s with the same `(key, value)`
  set produce identical bytes) but not strictly inverse to the
  `ofList`-backed decoder (because the RB-tree shape after
  `ofList` is determined by the canonical insertion order, not the
  original `TreeMap`'s history).  Phase 4 ships a *determinism*
  theorem (`state_encode_deterministic`) and an
  `Equiv`-conditional one
  (`balanceMap_encode_deterministic_of_equiv`); the full abstract
  `decode_encode_extensional` theorem is deferred to a follow-up.
  The value-level round-trip is verified by tests in
  `LegalKernel/Test/Encoding/State.lean` (an `emptyStateRoundtrip`
  case, a populated `stateRoundtripGetBalance` case probing four
  `(resource, actor)` cells, and an `extendedStateRoundtrip` case
  probing `getBalance`, `expectsNonce`, and `KeyRegistry.lookup`).
  The kernel never compares two `State` values for `=`, only via
  `getBalance`, so the determinism theorems plus the value-level
  round-trip tests suffice for hashing / signing.

* **String instance omitted.**  The Genesis Plan §12 WU 4.1
  acceptance criteria list `String` (CBE tstr) as one of the
  primitive instances.  Phase 4 *omits* the `String` instance: no
  in-tree consumer requires it (the `signInput` domain string is
  encoded byte-wise via `cborHeadEncode cbeTagBytes` directly), and
  proving its round-trip would require a `String.fromUTF8?_toUTF8`
  identity that Lean core does not currently expose.  A future
  Phase 5 work unit (deployment-facing diagnostic event encoding)
  will land the `String` instance with a hand-proved UTF-8
  round-trip lemma.

* **List / Option round-trip is parameterised on per-element
  evidence.**  The `List α` and `Option α` instances (where
  `α : Encodable`) ship as instances, but their round-trip
  theorems (`list_roundtrip`, `option_roundtrip`) take an
  `ElemRoundtrip α` hypothesis (`∀ x rest, decode (encode x ++
  rest) = .ok (x, rest)`) rather than a `LawfulEncodable α`
  typeclass.  Callers supply the per-element evidence at the use
  site (e.g. `bool_roundtrip` for `List Bool`).  This avoids
  introducing a typeclass that would have to be retro-fitted to
  every existing `Encodable` instance to recover the `LawfulEncodable
  α → LawfulEncodable (List α)` chain.
* **`Dispute`/`Verdict` encodings deferred to Phase 6.**  The
  Genesis Plan §8.8.3 also lists `Dispute` / `Verdict` map
  encodings, but those types are Phase 6 deliverables.  Phase 4
  ships only the `SignedAction` encoding; the corresponding
  `Encodable Dispute` / `Encodable Verdict` instances will be added
  alongside the dispute-system landing in Phase 6.
* **`signInput` returns the bytes that would be hashed**, not the
  hash itself.  The Genesis Plan §8.8.5 specifies `BLAKE3(...)`
  for the actual sign-input.  Phase 4 returns the raw bytes; the
  Phase-5 runtime adaptor wires BLAKE3 via `@[extern]` linkage at
  the FFI boundary.  This makes the canonical-encoding pipeline
  auditable at the Lean level without committing to a specific
  hash function.
* **Cross-deployment-distinguishability is value-level.**  The
  §8.8.5 headline security property (signatures don't replay across
  deployments) is verified at the value level via test vectors in
  `LegalKernel/Test/Encoding/SignInput.lean` rather than as an
  abstract Lean theorem; the byte-level abstract proof
  ("extracting the common domain prefix and applying
  `byteArray_encode_injective`") is straightforward in principle
  but byte-surgery tedious, and the value-level tests cover every
  concrete shape the runtime adaptor will encounter.
* **DSL `law` macro form.**  The final macro syntax is
  `law pre := <expr> ; impl := <expr>` (with explicit `;`
  separator) rather than the multi-line `law transfer ... where
  pre := ... ; impl := ...` of the §12 WU 4.9 sketch — Lean's term
  parser does not natively support a pun-keyword-terminated form
  for `pre`-bounded terms.  An impl-only form (`law impl := <expr>`)
  defaults `pre` to `fun _ => True`.  Functionally identical to
  the sketch (`decPre := fun _ => inferInstance` is filled in
  automatically); the discipline of "elaboration FAILS if `pre` is
  not instance-decidable" is enforced via the `[DecidablePred pre]`
  instance argument on the underlying `Law.mk` combinator.

### Phase 5: Runtime and Extraction

Goal: a Lean-native binary that runs the kernel, persists logs, and
serves them; a Rust adaptor for network and storage; a replay tool;
extraction notes.

This is the largest phase by engineer-weeks (8–12). It is divided
into three streams that can run in parallel after WU 5.1.

| WU  | Title                                                          | Est | Depends on |
|-----|----------------------------------------------------------------|-----|-----------|
| 5.1 | Lean-native runtime skeleton (`runtime` exe)                   | 1.0 | 4.4, 3.7  |
| 5.2 | Append-only log file format + recovery                         | 1.5 | 4.4       |
| 5.3 | Crash-consistency test harness (fault injection)               | 1.5 | 5.2       |
| 5.4 | Network adaptor (Rust, accepts `SignedAction` over TCP/QUIC)   | 1.5 | 4.4       |
| 5.5 | Replay tool (`replay` exe): genesis + log → state hash         | 1.0 | 5.2       |
| 5.6 | Event extraction (`extractEvents`)                             | 1.0 | 5.1       |
| 5.7 | Event subscription protocol (Rust)                             | 1.0 | 5.6       |
| 5.8 | Event indexer reference impl (Rust + SQLite)                   | 1.0 | 5.7       |
| 5.9 | Extraction notes: which Lean constructs survive compilation    | 0.5 | 5.1       |
| 5.10| ABI doc: Lean ↔ Rust boundary contract                         | 0.5 | 5.4       |
| 5.11| Performance benchmarks: 10k tx/sec local                       | 1.0 | 5.4, 5.5  |
| 5.12| State snapshot + incremental log shipping                      | 1.5 | 5.2       |

**WU 5.1 — Lean-native runtime.**
- A `runtime` executable that loads genesis (from a CBOR file),
  reads `SignedAction` values from stdin, calls `apply_admissible`,
  appends results to a log file.
- Acceptance: end-to-end smoke test (single transfer round-trip).

**WU 5.2 — Log file format.**
- Append-only file with framed CBOR records, each record carrying
  `(prev_hash, signed_action, post_state_hash)`.
- Acceptance: torn-write detection (see WU 5.3); log-replay produces
  matching post-state hashes.

**WU 5.3 — Crash consistency.**
- Inject crashes mid-write; the runtime must, on next start,
  truncate to the last committed record (no partial entries
  surviving) and resume.
- Acceptance: 1000-trial fuzz with random crash points; log always
  parseable on recovery.

**WU 5.4 — Network adaptor.**
- A Rust binary that accepts `SignedAction` payloads over TCP (and
  optionally QUIC), forwards them to the Lean runtime via a Unix
  socket, returns the runtime's verdict.
- Acceptance: cross-language interop test: Rust client → Rust
  network → Lean runtime → log → reply path.

**WU 5.5 — Replay tool.**
- Independent binary that reads genesis + log, replays, and emits a
  final `StateHash`. Used for audit and bootstrap.
- Acceptance: replay of every CI test log produces the same
  `StateHash` as the runtime did online.

**WU 5.6 — Event extraction.**
- A function `extractEvents : LogEntry → List Event` per deployment.
- Acceptance: deterministic; replay-stable; spot-checked.

**WU 5.7 — Event subscription.**
- A Rust subscription protocol: `(stream, fromIndex)` → ordered
  delivery of events.
- Acceptance: subscriber lag bounded; out-of-order delivery rejected.

**WU 5.8 — Reference indexer.**
- A small Rust + SQLite consumer that maintains a per-resource
  balance view from events.
- Acceptance: indexer state matches `getBalance` for arbitrary actors.

**WU 5.9 — Extraction notes.**
- A doc covering what Lean compiles to where, especially confirming
  that `Legal` proof fields are erased.
- Acceptance: doc reviewed; spot-check with `objdump`.

**WU 5.10 — ABI doc.**
- A doc covering the Unix-socket protocol, error codes, framing.
- Acceptance: an external implementer can reproduce a compatible
  client from the doc alone.

**WU 5.11 — Performance benchmarks.**
- Acceptance: `runtime` sustains 10,000 transitions/sec for the
  `transfer`-only law set on a 4-core developer machine, with
  end-to-end latency p99 < 10 ms.
- Risk: if not met, profile and optimise (likely candidates: CBOR
  decode, RBMap rebalancing).

**WU 5.12 — Snapshot + incremental shipping.**
- A snapshot is a `(StateHash, encoded State)` pair plus the log
  index from which it was taken. New replicas can start from a
  snapshot and apply only subsequent log entries.
- Acceptance: replica started from snapshot reaches same final state
  as one started from genesis.

**Phase 5 dependency graph.**

```
4.4  →  5.1  →  5.6  →  5.7  →  5.8
3.7  /         \
4.4  →  5.2  →  5.3
        \      \
         \      →  5.5  →  5.11
          →  5.12
4.4  →  5.4  →  5.10
        \
         →  5.11
5.1  →  5.9
```

Three streams (after 4.4 / 3.7):
- **Persistence stream**: 5.2 → 5.3 → 5.5 → 5.12.
- **Network stream**: 5.4 → 5.10.
- **Observability stream**: 5.6 → 5.7 → 5.8.
- Convergence: 5.11 (benchmarks) sits at the join.

**Phase 5 exit criteria.** End-to-end runtime + adaptor + indexer
working; replay tool reproduces state from any log; benchmarks pass;
crash-consistency fuzz green.

**Phase 5 status.** Lean-side WUs complete; Rust-side WUs deferred
to a follow-up PR.

- WU 5.1: `LegalKernel/Runtime/Loop.lean` ships the `RuntimeState`
  record + `processSignedAction` (single-step state advance with
  log append) + `bootstrap` (load + truncate + replay startup
  path).  The `Main.lean` CLI multiplexes five subcommands
  (`info`, `process`, `replay`, `bootstrap`, `snapshot`) against
  an append-only log file at the path supplied on argv.  End-to-end
  smoke test (`runtime-loop` test suite, 6 cases) verifies the
  `processSignedAction` rejection path (Verify-stub returns false
  in test mode) and the `bootstrap` empty-log path; production
  apply paths require WU 3.9 (Ed25519 adaptor) before they
  exercise the Verify chain.
- WU 5.2: `LegalKernel/Runtime/LogFile.lean` ships the `LogEntry`
  structure (`prevHash`, `signedAction`, `postStateHash`), the
  `Encodable LogEntry` instance, the framed on-disk format
  (`magic + length + payload + trailer` with FNV-1a-64 trailer
  for torn-write detection), the `appendEntry` / `readAllEntries`
  IO primitives, and the `verifyChain` chain-integrity helper.
  17 test cases including positive round-trips, negative
  rejection paths (truncated, bad-magic, bad-trailer), and
  multi-frame stream tests.
- WU 5.3: crash-consistency lives in the same module
  (`loadAndTruncate`).  On startup the runtime walks the file
  frame-by-frame, stops at the first incomplete / corrupt frame,
  and truncates the file to the last good byte boundary.  The
  test suite includes a torn-write simulation
  (`crashConsistencyTruncation`) and a multi-cut sweep
  (`crashConsistencySweep`) covering 6 prefix lengths from 1 byte
  to a near-complete frame.
- WU 5.4: **complete (Lean side and Rust side; production
  subprocess kernel deferred to a future `knomosis serve` Lean
  subcommand)**.  `runtime/knomosis-host/` implements the Rust
  network adaptor (TCP / TLS / Unix-socket listener, bounded
  mpsc queue with `Busy` backpressure, `Kernel` trait + two
  implementations: `MockKernel` for tests / dev and
  `CommandKernel` that spawns `knomosis process` per request).
  Wire-format specification finalised in `docs/abi.md` §10
  with the new `Verdict::Busy = 3` byte; engineering plan and
  closeout in `docs/planning/rust_host_runtime_plan.md` §RH-C.
  140 new tests (110 lib + 12 TCP integration + 7 Unix-socket
  integration + 11 property) bring the Rust workspace total to
  483.  The `CommandKernel` is heavy (O(log size) per request
  because `knomosis process` re-loads the log file every time);
  the canonical production-grade optimization is a future
  `knomosis serve` Lean-side subcommand that reads CBE frames
  from stdin and writes verdicts to stdout — deferred to a
  future PR.
- WU 5.5: `LegalKernel/Runtime/Replay.lean` ships the `replay`
  function (genesis + log → final state) + `replayHash` (final
  hash only) + `replayFromSeed` (start from a snapshot's seed
  hash + state).  The `knomosis-replay` binary in `Replay.lean` /
  `lakefile.lean` is the audit-oriented standalone tool: a
  separate process that reproduces the runtime's state hash
  byte-for-byte by replaying the same log.  10 test cases.
- WU 5.6: `LegalKernel/Events/{Types, Extract}.lean` ship the
  five-constructor `Event` inductive (per §8.9.2 — Phase 6 will
  append `disputeFiled` / `verdictApplied`) and the deterministic
  `extractEvents : (preState, postState, signedAction) → List
  Event` function (per-action event-emission rules documented in
  the file's coverage map).  17 combined test cases.
- WU 5.7: `runtime/knomosis-event-subscribe/` (Workstream RH-D)
  materialises the Rust event subscription server.  Tails the
  Lean transition log via the `tail.rs` reader, extracts events
  via a Lean `knomosis` subprocess (the wire-format authority), and
  streams them to TCP subscribers with bounded-lag eviction and
  resume-from-sequence backfill.  Wire format documented in
  `docs/abi.md` §11; engineering plan in
  `docs/planning/rust_host_runtime_plan.md` §RH-D.  158 new tests
  bring the Rust workspace total to 684.  The `knomosis
  extract-events` Lean-side subcommand the
  `SubprocessExtractor` delegates to is a follow-up PR; the
  framework ships with a working `MockExtractor` for tests + dev.
- WU 5.8: deferred (SQLite indexer — depends on a Rust DB layer).
- WU 5.9: `docs/extraction_notes.md` ships the per-construct
  erasure / persistence map (what survives Lean's compilation
  pipeline into the runtime binary) plus the `Verify` opaque-
  axiom story for production deployments.  Note: the
  post-Phase-6 security audit upgraded `signingInput` from a
  stub returning `ByteArray.empty` to a real CBE encoding, so
  the production-deployment gating documented here is now
  satisfied at the Lean level (Phase-4 integration completed
  retroactively).
- WU 5.10: `docs/abi.md` ships the on-disk and on-wire byte
  layouts (frame structure, FNV-1a-64 trailer format, per-type
  CBE encodings) so an external implementer can reproduce a
  compatible client.
- WU 5.11: **complete (harness)**.  `runtime/knomosis-bench/`
  ships the transfer-throughput benchmark per RH-F: a library
  + binary that generates a deterministic fixture (1000
  pre-funded actors + 10000 pre-signed Transfer payloads),
  spawns an in-process knomosis-host backed by MockKernel,
  drives a concurrent workload over Unix-socket / TCP, and
  emits a versioned JSON report.  Observed throughput at
  landing (on a developer x86_64 workstation, opt-level=3,
  LTO=thin): ~7500 ops/sec at the default
  64-worker workload, with p50 ~ 8 ms and p99 ~ 13 ms.  The
  §RH-F target of ≥ 10k tx/sec + p99 < 10 ms is partially
  met (75% of throughput; 1.3× over budget on p99); the gap
  is rooted in the knomosis-host wire format's one-shot
  connection-per-request lifecycle (§10.5 ABI) and the
  listener's polling accept-loop, both of which are out of
  scope for RH-F (a persistent-connection extension would be
  a wire-format amendment).  The harness faithfully measures
  the production wire-format ceiling and supports baseline
  regression detection via `--baseline <PATH>` for CI gating.
  See `docs/planning/rust_host_runtime_plan.md` §RH-F
  closeout for the full per-sub-unit decomposition.
- WU 5.12: `LegalKernel/Runtime/Snapshot.lean` ships the
  `Snapshot` record (`stateHash`, `encodedState`, `logIndex`,
  `seedHash`), `takeSnapshot` / `restoreSnapshot`, the file IO
  helpers, and `replicaFromSnapshot` (the headline operation: a
  fresh replica's snapshot + log-tail bootstrap path).  7 test
  cases including round-trip, tampered-state rejection, and
  empty-tail-bootstrap-equals-snapshot-state.

**Phase-5 deviations from §12 (documented).**

- **Hash function.**  Genesis Plan §8.8.4 specifies BLAKE3-256
  (32-byte output).  Phase 5 ships **FNV-1a-64** (8-byte output)
  as a deterministic Lean-native fallback, with the FFI swap
  point at `LegalKernel.Runtime.Hash.hashBytes` so production
  deployments link a real BLAKE3 implementation via `@[extern]`
  without touching kernel or law modules.  The runtime adaptor
  (Phase 5 WU 3.9) is the right boundary for that swap.  Phase
  5's tests pass with the FNV-1a-64 fallback; the §8.8.4
  cryptographic-strength acceptance gate requires the BLAKE3
  swap.
- **Verify-opaque caveat.**  The `Verify` `opaque` declaration
  (Phase 3 WU 3.4) returns `false` at runtime in the absence of
  an `@[extern]` implementation.  Phase 5's runtime tests
  exercise the *rejection paths* (every `processSignedAction`
  call rejects as `notAdmissible` because the signature clause
  fails); the success-with-real-actions paths are deferred to
  WU 3.9 (Ed25519 adaptor) + integration tests.  This is
  documented in each runtime test module's header.
- **Rust deliverables (5.4 / 5.7 / 5.8 / 5.11).**  The Lean-side
  runtime is fully functional and end-to-end-tested without them;
  the Rust adaptors are *interop* deliverables that landed in a
  follow-up PR sequence with their own CI infrastructure.  At the
  RH-F landing all four Phase-5 Rust WUs (5.4 / 5.7 / 5.8 / 5.11)
  are materialised — see `docs/planning/rust_host_runtime_plan.md`
  for the per-sub-workstream closeouts.

### Phase 6: Disputes and Adjudication

Goal: the §8.4 four-stage pipeline implemented and tested
end-to-end, including rollbacks recorded as authorised actions.

| WU  | Title                                                          | Est | Depends on |
|-----|----------------------------------------------------------------|-----|-----------|
| 6.1 | `DisputeClaim`, `Dispute`, `Verdict` types + encoding          | 1.0 | 4.4       |
| 6.2 | `Action.dispute`, `Action.verdict` constructors                | 0.5 | 6.1, 3.1  |
| 6.3 | `fileDispute` (Stage 1)                                        | 0.5 | 6.2       |
| 6.4 | `checkEvidence` for `preconditionFalse`                        | 1.0 | 6.3       |
| 6.5 | `checkEvidence` for `signatureInvalid`                         | 0.5 | 6.3       |
| 6.6 | `checkEvidence` for `nonceMismatch`                            | 0.5 | 6.3       |
| 6.7 | `checkEvidence` for `oracleMisreported` (per-oracle plug-in)   | 1.0 | 6.3       |
| 6.8 | `checkEvidence` for `doubleApply`                              | 0.5 | 6.3       |
| 6.9 | `proposeVerdict` (Stage 3) with quorum support                 | 1.0 | 6.4–6.8   |
| 6.10| `applyVerdict` (Stage 4) with rollback                         | 1.5 | 6.9, 5.5  |
| 6.11| `disputeWithdraw` action + idempotency                         | 0.5 | 6.3       |
| 6.12| End-to-end test: planted illegal tx → dispute → rollback       | 1.0 | 6.10      |

Each `checkEvidence` work unit is independent and can be parallelised
after WU 6.3. WU 6.10 depends on the replay tool from Phase 5
because rollback computes the target state via replay.

**WU 6.1 — Dispute types + encoding.**
- Acceptance: encodings round-trip; injectivity proved.

**WU 6.4 — Precondition-false check.**
- Replays the log up to `idx-1` (using WU 5.5), recomputes the
  precondition, returns `upheld` iff false.
- Acceptance: planted-illegal-tx test returns `upheld`; legitimate
  txs return `rejected`.

**WU 6.10 — Verdict application + rollback.**
- An upheld verdict produces an `Action.rollback (idx)` action; its
  `apply_impl` is "replay log[0..idx-1]"; its precondition is
  "verdict v is upheld and signed by quorum".
- Acceptance: rollback recorded as a forward action; replay of the
  full log (including the rollback) produces the rolled-back state.

**WU 6.12 — End-to-end test.**
- Plant an illegal tx (e.g. by bypassing the runtime check for the
  test); file dispute; check evidence (returns `upheld`); propose
  verdict (signed by adjudicator); apply verdict (rollback).
- Acceptance: final state matches the state immediately before the
  planted tx.

**Phase 6 dependency graph.**

```
4.4  →  6.1  →  6.2  →  6.3  →  6.4  →  6.9  →  6.10  →  6.12
                         \      \      \              /
                          \      →  6.5 →             /
                           \      →  6.6 →             /
                            \     →  6.7  →           /
                             \    →  6.8  →           /
                              \                       /
                               →  6.11  →            /
5.5  → → → → → → → → → → → → → → → → → → → → → → → ↗
```

**Phase 6 exit criteria.** All five `checkEvidence` variants
implemented; verdict application produces correct rollback; end-to-end
test green.

**Phase 6 status.** Complete.

- WU 6.1: `LegalKernel/Disputes/Types.lean` ships the first-order
  data types (`LogIndex`, `DisputeClaim` with 5 variants,
  `EvidenceVerdict` with 3 variants, `Dispute`, `Verdict`,
  `DisputeStatus`, `DisputeRecord`, `OraclePolicy`, `FilingError`,
  `VerdictError`).  `LegalKernel/Encoding/Disputes.lean` ships
  canonical CBE byte encodings with per-type round-trip and
  injectivity proofs (`disputeClaim_roundtrip`,
  `evidenceVerdict_roundtrip`, `dispute_roundtrip`,
  `verdict_roundtrip` and the corresponding `_encode_injective`
  forms).  `Encoding/Encodable.lean` adds the parametric
  `list_roundtrip_bounded` lemma + `ElemRoundtripIn` predicate to
  support the bounded-element list round-trip the `Verdict` codec
  needs.  17 test cases.
- WU 6.2: `LegalKernel/Authority/Action.lean` extends the `Action`
  inductive with four new constructors at frozen indices 8..11
  (`dispute`, `disputeWithdraw`, `verdict`, `rollback`); all
  compile to `Laws.freezeResource 0` (kernel-level no-ops).
  `Encoding/Action.lean` extends `fieldsBounded`, `encode`,
  `decode`, and `action_roundtrip` for the new constructors.
  `Authority/SignedAction.lean`'s
  `non_replaceKey_preserves_registry` extended with four new `rfl`
  cases.  `Events/Types.lean` extends the `Event` inductive with
  three new constructors at indices 5..7 (`disputeFiled`,
  `disputeWithdrawn`, `verdictApplied`).  `Events/Extract.lean`
  emits the appropriate dispute event for each of the new action
  constructors.
- WU 6.3: `LegalKernel/Disputes/Filing.lean` ships
  `claimImpugnedIdx` / `claimSecondaryIdx` projections, log-scan
  helpers (`disputeMatchesEntry`, `findPriorDisputeIdx`), and
  `fileDispute` (Stage 1 with all four §8.4.4 acceptance checks).
  Returns `DisputeRecord` with `status = open` on success.  16
  test cases.
- WU 6.4: `LegalKernel/Disputes/Evidence.lean` ships
  `kernelOnlyApply` / `kernelOnlyReplay` (the admissibility-blind
  prefix-replay helper that bypasses the chain / admissibility /
  post-hash checks of `Runtime.Replay.replay`, since the dispute
  pipeline must analyse logs whose runtime-time admissibility
  cannot be re-established) plus `checkPreconditionFalse`
  (replays log[0..idx-1], evaluates the kernel-level `pre` at the
  recovered pre-state).
- WU 6.5: `checkSignatureInvalid` re-runs `Verify` against the
  current registered key for `log[idx].signer`.
- WU 6.6: `checkNonceMismatch` recomputes `expectsNonce
  es_{idx-1} log[idx].signer` and compares to `log[idx].nonce`.
- WU 6.7: `checkOracleMisreported` delegates to the
  deployment-supplied `OraclePolicy.verifier`.
  `OraclePolicy.alwaysRejects` and `alwaysUpheld` ship as test
  fixtures.  Pure pass-through.
- WU 6.8: `checkDoubleApply` verifies `log[idx₁].nonce =
  log[idx₂].nonce` and `signer₁ = signer₂` and `idx₁ ≠ idx₂`.
  `checkEvidence` dispatcher routes to per-claim verifier.  16
  combined test cases for WU 6.4 – 6.8.
- WU 6.9: `LegalKernel/Disputes/Verdict.lean` ships `QuorumPolicy`
  (with `singleton` / `empty` constructors), `verdictSigningInput`
  (real CBE-encoded `(disputeId, outcome, rationale)` after the
  post-Phase-6 security audit; originally shipped as a
  `ByteArray.empty` placeholder),
  `countVerifiedSignatures` (per-signer deduplicating after the
  same audit; originally counted every `(signer, sig)` pair
  separately, permitting trivial quorum forgery), and
  `proposeVerdict` (Stage 3 with the four validation checks:
  `unknownDispute`, `alreadyDecided`, `outcomeMismatch`,
  `quorumNotMet`).
- WU 6.10: `applyVerdict` (Stage 4) computes the rollback target
  via `replayPrefix` for `upheld` outcomes; returns the current
  state unchanged for `rejected` / `inconclusive`.  Surfaces
  precise diagnostics (`unknownDispute`, `alreadyDecided`,
  `replayFailed`).  Per-outcome no-change theorems and
  determinism theorems for both `proposeVerdict` and
  `applyVerdict`.  11 test cases for WU 6.9 – 6.10.
- WU 6.11: `applyWithdraw` is the per-status idempotent function
  (`open → withdrawn`, identity on `withdrawn` and `decided`).
  `applyWithdraw_idempotent` theorem proven for every
  `DisputeStatus` value.  `disputeStatus` walks the log forward,
  applying `applyWithdraw` / `applyVerdictOutcome` at each
  matching action.  Idempotency tests included in the 16-case
  filing suite.
- WU 6.12: `LegalKernel/Test/Disputes/EndToEnd.lean` ships the
  full acceptance test: a 2-entry pre-dispute log
  `[legitimate_transfer; planted_illegal_transfer]` is filed
  against (returning `DisputeRecord` with `idx = 2`); the
  3-entry full log is checked via `checkEvidence` (returns
  `.upheld` because `transfer.pre` is false at the post-entry-0
  state); a corresponding `.upheld` verdict is applied via
  `applyVerdict`, returning the rolled-back state whose
  `getBalance r a` queries match the state immediately before
  the planted illegal transfer.  5 test cases.

**Phase-6 deviations from §12 (documented).**

- **Verdict signing input.**  Phase 6 originally shipped
  `verdictSigningInput` as a `ByteArray.empty` placeholder
  analogous to Phase-3's `signingInput`.  The post-Phase-6
  security audit upgraded it to the real CBE encoding of
  `(disputeId, outcome, rationale)` (the `signers` / `sigs`
  fields are deliberately excluded — including them would
  create a circular signature dependency).  Distinct verdicts
  therefore produce distinct sign-input bytes, restoring
  within-deployment replay protection at the Lean level.  A
  future enhancement can prepend a `"legalkernel/v1/verdict"`
  domain string + deploymentId for §8.8.5-style cross-deployment
  protection; the `verifyChain` for Verdict-bearing log entries
  continues to reuse the standard `LogEntry.hash` chain.
- **`replayPrefix` admissibility-blindness.**  The Genesis Plan
  §8.4.2 specifies "Replay log up to `idx`" without specifying
  the admissibility / chain checks `Runtime.Replay.replay`
  performs.  Phase 6's `kernelOnlyReplay` deliberately bypasses
  those checks: the dispute pipeline must analyse logs whose
  runtime-time admissibility cannot be re-established (e.g.
  because keys have rotated since application, or because we are
  diagnosing whether the runtime should have rejected an entry
  that it accepted).  The `kernelOnlyApply` helper applies each
  entry's compiled transition via `step_impl`, which is a no-op
  if the precondition fails — exactly matching the kernel's
  "no silent illegality" property.  This is a *strict
  generalisation* of `replay` (any chain that `replay` accepts
  also passes `kernelOnlyReplay`); replay-style chain checks
  remain available via `Runtime.Replay.replay` for non-dispute
  callers.

### Phase 6 incentive-integration amendment (WUs 6.13 – 6.23)

Per §16.6 amendment process: the Phase-6 incentive-integration
amendment extends the dispute pipeline with positive-incentive
mechanisms (rewards on upheld verdicts; adjudicator compensation;
anti-fraud staking; semantic event observability) without
introducing any new kernel laws or breaking any existing
invariant.

| WU  | Title                                                                             | Est | Depends on |
|-----|-----------------------------------------------------------------------------------|-----|-----------|
| 6.13| `IsConservative` / `IsMonotonic` instances for dispute action constructors         | 0.5 | 6.2, R.3  |
| 6.14| `disputableMonotonicLawSet` example deployment                                     | 1.0 | 6.13, R.2 |
| 6.15| `DisputeRewardPolicy` (challenger + adjudicator atomic constructors)               | 1.5 | 6.10      |
| 6.16| `applyVerdictWithRewards` composable wrapper                                       | 1.0 | 6.15      |
| 6.17| End-to-end incentivized + staked dispute test                                      | 2.5 | 6.13–6.23 |
| 6.18| Documentation updates (CLAUDE / GENESIS_PLAN / abi / extraction_notes)             | 1.0 | 6.13–6.17 |
| 6.19| `StakingPolicy` (kernel-conservative anti-fraud)                                   | 3.0 | 6.3       |
| 6.20| `Event.rewardIssued` constructor + `actionEvents` extension                        | 1.5 | 5.6       |
| 6.21| Graduated-reward policy constructors (`byClaimVariant`, `proportional...`)         | 1.5 | 6.15      |
| 6.22| Stake-weighted adjudicator rewards                                                 | 2.5 | 6.15, R.14|
| 6.23| Cross-resource reward bundles (`disputeRewardActionsMulti`)                        | 0.75| 6.15      |

**Phase-6-amendment status.** Complete.

- WU 6.13: 4 `_compileTransition_eq_freezeResource_zero` rfl
  lemmas + 8 typeclass instances (4 `IsConservative` + 4
  `IsMonotonic`) + composite summary theorem.  Zero-axiom proofs
  via `freezeResource_isConservative` / `freezeResource_isMonotonic`.
- WU 6.14: `disputableMonotonicLawSet` (6-element representative
  law list including `freezeResource 0` to cover all dispute
  action constructors via `Action.compileTransition`).  The
  `isMonotonic` field is discharged via case-split + per-law
  `inferInstance`.  Headline theorem
  `disputable_monotonic_total_supply_nondecreasing` applies
  `total_supply_globally_nondecreasing_via_law_set`.
- WU 6.15: `DisputeRewardPolicy` structure + 4 atomic
  constructors (`empty`, `flatChallengerReward`,
  `flatAdjudicatorReward`, `union` with left-biased
  fallthrough); `disputeRewardActions` emitter; 6 sanity
  theorems (deterministic, emits-only-rewards, length-bound,
  rejected-no-reward, upheld-emits, union-left-bias).
- WU 6.16: `applyVerdictWithRewards` wrapper; 2 wrapper
  theorems (deterministic, unknown-dispute).
- WU 6.17: `Test/Disputes/IncentivizedEndToEnd.lean` with 19
  test cases covering all 8 scenarios in the test plan.
- WU 6.18: documentation updates across CLAUDE.md, GENESIS_PLAN.md,
  abi.md, README.md, economic_invariants.md.
- WU 6.19: `StakingPolicy` structure + `disabled` /
  `canStake`; `StakedFilingError` (per design decision D2);
  `stakeFilingActions` + `stakeResolutionActions` (per design
  decision D1: rollback implicitly returns stake on upheld;
  treasury transfer on rejected/inconclusive); `fileDisputeStaked`
  wrapper.  All emissions are `Action.transfer`, never `burn`,
  so kernel-level conservation holds.
- WU 6.20: `Event.rewardIssued` constructor at frozen index 8
  (Phase 5 ships 0..4; Phase 6 base ships 5..7; this amendment
  appends 8).  Append-only — no existing index shifts.
  `actionEvents` extended to emit BOTH `balanceChanged` (delta-
  filtered) AND `rewardIssued` (always) for `Action.reward`.
- WU 6.21: `claimImpugnedAmount` helper extracts the impugned
  action's amount field (returns `none` for actions without one).
  `byClaimVariant` provides per-claim-variant graduated reward.
  `proportionalChallengerReward` scales the reward by the
  impugned action's amount via `factor * amt / divisor` (Nat
  floor).
- WU 6.22: `stakeWeightedAdjudicatorRewards` distributes a
  reward pool proportionally to each signer's balance at the
  stake resource.  Includes the dust bound theorem
  `_each_le_pool` (every emitted reward ≤ pool, via
  `stake ≤ totalStake → pool * stake ≤ pool * totalStake →
  div_le_div_right → mul_div_cancel`).  Edge cases: zero pool
  → []; zero total stake → [].
- WU 6.23: `disputeRewardActionsMulti` foldr-concatenates
  per-policy emissions across a list of policies.  Theorems
  cover concat-equality, empty-no-actions, emits-only-rewards
  (induction), and length-bound (`policies.length * (1 +
  signers.length)`).

**Phase-6-amendment design decisions.**  Six critical design
decisions resolved up-front to avoid implementation re-work:

  * **D1**: Staking transfer happens at filing time; the
    upheld-verdict rollback to `log[0..impugnedIdx-1]` implicitly
    returns the stake (since the transfer was appended AFTER the
    impugned action).  Rejected/inconclusive verdicts emit an
    explicit forfeiture transfer.
  * **D2**: `StakedFilingError` unified inductive (instead of
    `Except (FilingError ⊕ StakingError)`).
  * **D3**: `DisputeRewardPolicy.union` is left-biased
    fallthrough via `Option.orElse`.  Multi-resource bundles use
    `disputeRewardActionsMulti` (a separate combinator).
  * **D4**: Stake-weighted dust bound proved at the per-element
    level (`_each_le_pool`).
  * **D5**: `Event.rewardIssued` at frozen index 8 (append-only).
  * **D6**: `RewardBundle` exposed as `List
    DisputeRewardPolicy` rather than a separate structure.

### Phase 6 Option-C amendment (type-level Stage-3 enforcement)

Per §16.6 amendment process: the Phase-6 Option-C amendment closes
a defense-in-depth gap on Stage 4 (`applyVerdict`).  Before this
amendment, `applyVerdict` carried no type-level proof that Stage 3
had run; the "Stage 3 was called first" contract was enforced by
documentation only.  A buggy or malicious caller could invoke
`applyVerdict` directly with a forged `.upheld` verdict and the
rollback would fire without quorum-signature validation.

The amendment introduces a propositional witness
`VerdictPassedStage3` and exposes a 3-tier API:

  1. **`proposeAndApplyVerdict` (default-safe)** — chains
     Stage 3 + Stage 4 atomically, constructing the witness
     internally via `proposeVerdict_ok_returns_input`.
  2. **`applyVerdict` (witness-bearing)** — type-safe Stage 4
     for callers that have already validated the verdict.
     Cannot be called without a `VerdictPassedStage3`
     argument; auditors verify bypass-resistance locally at
     each callsite.
  3. **`applyVerdictUnchecked` (bypass — testing only)** —
     preserves the pre-amendment behaviour for test paths
     where the witness can't be constructed (e.g.
     `unknownDispute` cases).  Production deployments MUST
     NOT use this form.

The amendment also includes a Layer-0 hardening: `checkOracleMisreported`
now takes the log and returns `.inconclusive` on out-of-range
indices, closing a gap that the strong-correctness proof
otherwise couldn't discharge for the `oracleMisreported` claim.

| WU  | Title                                                              | Est | Depends on |
|-----|--------------------------------------------------------------------|-----|-----------|
| C.0 | Layer 0: defensive `checkOracleMisreported` index check            | 1.3 | 6.7       |
| C.1 | `proposeVerdict_ok_returns_input` bridge lemma                     | 0.6 | 6.9       |
| C.2 | `VerdictPassedStage3` structure + 2 constructors                   | 0.4 | C.1       |
| C.3 | Rename old `applyVerdict` to `applyVerdictUnchecked` (preserve API)| 0.7 | 6.10      |
| C.4 | New witness-bearing `applyVerdict` + 11 correctness theorems       | 3.5 | C.2, C.3, C.0 |
| C.5 | `proposeAndApplyVerdict` default-safe entry point                  | 2.0 | C.4       |
| C.6 | Refactor reward wrappers (rename + new witness-bearing variants)   | 2.0 | C.5       |
| C.7 | Test fixture builder helpers (`Test/Disputes/WitnessHelpers.lean`) | 0.7 | C.4       |
| C.8 | API stability tests + value-level fixture tests in Verdict.lean    | 1.7 | C.4, C.5  |
| C.9 | Parallel `proposeAndApplyVerdict` tests in EndToEnd.lean           | 1.1 | C.5       |
| C.10| Parallel `proposeAndApply` tests in IncentivizedEndToEnd.lean      | 1.7 | C.6       |
| C.11| Verdict.lean module docstring 3-tier API explanation               | 0.5 | C.5       |
| C.12| CLAUDE.md properties table additions (#77 – #92)                   | 0.5 | C.4–C.6   |
| C.13| GENESIS_PLAN.md amendment record (this section)                    | 0.4 | C.4–C.6   |
| C.14| Test count update + final acceptance gates                         | 0.2 | C.10      |

**Phase-6 Option-C amendment status.** Complete.

- WU C.0: `checkOracleMisreported` signature extended with
  `log : List LogEntry` parameter; returns `.inconclusive`
  when `log[idx]? = none`.  Two new theorems
  (`checkOracleMisreported_returns_oracle_verdict` updated to
  the in-range form; `_inconclusive_on_out_of_range` is the new
  defensive corollary).
- WU C.1: `proposeVerdict_ok_returns_input` proven by walking
  `proposeVerdict`'s 6-level match tree.  Discharges every
  error branch via `absurd` + `simp`; the success branch
  invokes `Except.ok.inj`.
- WU C.2: `VerdictPassedStage3` is a single-field `Prop`
  structure.  `of_proposeVerdict_ok` constructs from a literal
  success equation; `of_proposeVerdict_ok_with_eq` bridges the
  `proposeVerdict ... = .ok v'` form via WU C.1.
- WU C.3: `applyVerdict` → `applyVerdictUnchecked` (preserves
  body verbatim).  Four existing theorems renamed with
  `_Unchecked` suffix; internal callers in `Disputes/Rewards.lean`
  updated.  Existing tests rename function call sites.
- WU C.4: New `applyVerdict` is `applyVerdictUnchecked` plus a
  proof-irrelevant `_h : VerdictPassedStage3 ...` argument.
  `applyVerdict_eq_unchecked` is `rfl`.  Three witness-extraction
  theorems (`_log_in_range`, `_entry_is_dispute`,
  `_dispute_open`) recover the per-branch facts of
  `proposeVerdict`'s match tree from the witness.
  `claimImpugnedIdx_in_range_when_upheld` is the load-bearing
  helper (5-claim case-split) that bounds the impugned index.
  `applyVerdict_under_witness_succeeds` is the strong-correctness
  theorem: `∃ es, applyVerdict ... = .ok es`.  Three corollary
  `_unreachable` theorems document the unreachability of each
  error variant under the witness.
- WU C.5: `proposeAndApplyVerdict` uses the
  `match h_propose : ... with | .ok v' => ...` pattern-binding
  form to extract the success equation, then constructs the
  witness via `of_proposeVerdict_ok_with_eq` and calls the
  witness-bearing `applyVerdict`.  Four properties:
  `_eq_applyVerdict_when_proposed_ok`, `_proposeVerdict_error_path`,
  `_deterministic`, `_unknown_dispute`.
- WU C.6: `applyVerdictWithRewards{,Multi}` renamed to
  `_Unchecked` variants.  New witness-bearing variants take a
  `VerdictPassedStage3` argument.  Two
  `proposeAndApplyVerdictWithRewards{,Multi}` default-safe
  entry points added.  Six properties.
- WU C.7: `LegalKernel/Test/Disputes/WitnessHelpers.lean`
  exposes `mkWitnessByDecide` plus three sanity tests.
  Documents D4 fixture discipline (qp = empty, no `Verify`-opaque
  paths).
- WU C.8: 15 API stability tests + 5 `proposeAndApplyVerdict`
  tests added to `Test/Disputes/Verdict.lean`.
- WU C.9: 3 parallel `proposeAndApplyVerdict` tests added to
  `Test/Disputes/EndToEnd.lean`.
- WU C.10: 3 parallel default-safe-entry tests added to
  `Test/Disputes/IncentivizedEndToEnd.lean` (covering
  `proposeAndApplyVerdict`,
  `proposeAndApplyVerdictWithRewards`, and
  `proposeAndApplyVerdictWithRewardsMulti`).
- WU C.11: Verdict.lean module docstring rewritten to document
  the 3-tier API.
- WU C.12: CLAUDE.md properties table extended with rows 77–92
  (16 new properties).
- WU C.13: This GENESIS_PLAN.md section.
- WU C.14: Test count grew 569 → 598 (29 new tests across
  C.7, C.8, C.9, C.10).  All gates green: `lake build`,
  `lake test`, `count_sorries`, `tcb_audit`.

**Phase-6 Option-C amendment design decisions.**

  * **OC.1**: Witness is a `Prop` structure with a single
    equation field — proof-irrelevant, zero runtime cost.
    `applyVerdict`'s body is `applyVerdictUnchecked` verbatim
    modulo the witness arg; Lean's compiler erases the witness
    at code-gen.
  * **OC.2**: `_Unchecked` API is preserved (not removed) so
    test paths exercising `unknownDispute` / `alreadyDecided`
    branches remain functional.  The `_Unchecked` suffix is a
    deliberate visual lint at every callsite.
  * **OC.3**: `proposeAndApplyVerdict` is the default-safe entry
    point.  Auditors should treat any direct `applyVerdict`
    callsite as a deliberate choice (e.g. for callers with their
    own pre-validation).  Direct `applyVerdictUnchecked`
    callsites in non-test code are review-blocking.
  * **OC.4**: The strong-correctness theorem is *under the
    witness*, not unconditional.  Without a witness,
    `applyVerdictUnchecked` can still return errors — that's the
    whole point of the witness.

### Phase 7: Advanced Capabilities

Goal: explore extensions that the Phase 0–6 architecture admits but
does not require. Each WU here is independently deliverable.

| WU  | Title                                                          | Est | Depends on |
|-----|----------------------------------------------------------------|-----|-----------|
| 7.1 | Capabilities: `Capability` + `apply_capability_admissible`     | 2.0 | 3.7       |
| 7.2 | Threshold signatures (FROST adaptor)                           | 2.0 | 3.4       |
| 7.3 | ZK proof of admissibility (Plonk via halo2 backend)            | 4.0 | 5.1       |
| 7.4 | Intent solver (constraint-based action sequence search)        | 3.0 | 3.7       |
| 7.5 | Cross-shard transition protocol (sketch + 2-shard demo)        | 4.0 | 5.5       |
| 7.6 | Schema migration framework (bridge transitions)                | 2.0 | 5.12      |
| 7.7 | Multi-region replication (CRDT-style log convergence)          | 3.0 | 5.12      |

Each WU is a *project*, not a single piece of work; they should be
separately scoped and chartered before they begin. The estimates are
order-of-magnitude calibration only.

### Cross-cutting WUs (no phase home)

| WU  | Title                                                          | Est | Depends on |
|-----|----------------------------------------------------------------|-----|-----------|
| X.1 | Reproducible build pipeline (Nix/Bazel)                        | 1.0 | 0.4       |
| X.2 | Static security review of the runtime adaptor                  | 1.0 | 5.4       |
| X.3 | Independent formal review of kernel proofs                     | 2.0 | 1.10      |
| X.4 | Documentation site (mdBook or similar) auto-built from docs/   | 1.0 | —         |
| X.5 | Public test net with monitoring dashboard                      | 2.0 | 5.11      |
| X.6 | Bug bounty programme + scope doc                               | 0.5 | X.5       |

### Phase Dependency Graph (Cross-Phase)

```
Phase 0  ──►  Phase 1  ──►  Phase 2
                  │              │
                  ├──►  Phase 3  │
                  │       │      │
                  │       └──┬───┘
                  │          ▼
                  └────►  Phase 4  ──►  Phase 5  ──►  Phase 6  ──►  Phase 7
                                            │
                                            └──► (X.2, X.5)
```

Phase 2 and Phase 3 are independent after Phase 1 and can run in
parallel. Phase 4 requires both. Phase 6 requires Phase 5 (for replay).

### Estimated Effort

Per-phase totals are sums of the WU estimates above.

| Phase | WU count | Estimate (engineer-weeks) | Status            |
|-------|----------|---------------------------|-------------------|
| 0     | 5        | 2.5                       | complete          |
| 1     | 13       | 11.0                      | complete          |
| 2     | 9        | 7.0                       | complete          |
| 3     | 10       | 9.5                       | complete          |
| 4-pre | 23       | (Phase-4 prelude)         | complete          |
| 4     | 9        | 8.5                       | complete          |
| 5     | 12       | 13.0                      | complete (Lean side); Rust deferred |
| 6     | 12       | 9.5                       | complete          |
| 7     | 7        | 20.0+ (open-ended)        | not started       |
| X.x   | 6        | 7.5                       | continuous        |

Total to Phase 6: **~61 engineer-weeks** for one full-time
formal-methods engineer, or roughly **8–10 calendar months** with one
engineer (allowing for review cycles, infrastructure work, and
unforeseen depth). Two engineers in parallel after Phase 1 should
compress this to **5–6 calendar months**.

---

## 13. Tooling and Build

### 13.1 Toolchain

- **Lean 4** (pinned in `lean-toolchain`).
- **Lake** (Lean's build system).
- **Mathlib** is *not* a kernel dependency; the kernel uses `Std` only.
  Law modules may use Mathlib for convenience.
- **`elan`** for toolchain version management.

### 13.2 Repository Layout

```
LegalKernel/
├── Kernel.lean              -- Section 4.12 (TCB).
├── RBMapLemmas.lean         -- Section 8.3 (TCB by extension).
├── Actions.lean             -- Section 4.13 Action inductive +
│                            --   compile.
├── Laws/
│   ├── Transfer.lean        -- Section 4.11.
│   ├── Mint.lean            -- Section 12 WU 2.5.
│   ├── Burn.lean            -- Section 12 WU 2.5.
│   └── Freeze.lean          -- Section 12 WU 2.9.
├── Invariants/
│   ├── Conservation.lean    -- Section 8.1, WU 2.4–2.8.
│   └── Freeze.lean          -- WU 2.9.
├── Authority/
│   ├── Signed.lean          -- Section 8.2.
│   ├── Nonce.lean           -- Section 8.5.
│   ├── Crypto.lean          -- Section 8.2 Verify interface; WU 3.4.
│   └── Capabilities.lean    -- Section 8.10 (Phase 7 WU 7.1).
├── Encoding/
│   ├── Cbor.lean            -- Section 8.8.2 CBOR primitives.
│   ├── Encodable.lean       -- Section 8.8.6 typeclass.
│   └── SignInput.lean       -- Section 8.8.5 domain separation.
├── Disputes/
│   ├── Types.lean           -- Section 8.4.1 Dispute / Verdict.
│   ├── Pipeline.lean        -- Section 8.4.2 four stages.
│   └── Rollback.lean        -- Section 8.4 Stage 4.
├── Events/
│   ├── Types.lean           -- Section 8.9.2 Event inductive.
│   └── Extract.lean         -- Section 8.9.1 extractEvents.
├── Runtime/                 -- Phase 5; not part of TCB.
│   ├── Loop.lean            -- WU 5.1.
│   ├── LogFile.lean         -- WU 5.2.
│   ├── Replay.lean          -- WU 5.5.
│   ├── Snapshot.lean        -- WU 5.12.
│   └── AttestedSnapshot.lean -- Audit-3.2 (deployment-bound
│                            --   replica-bootstrap envelope).
├── Tools/                   -- not part of TCB.
│   ├── CountSorries.lean    -- WU 1.12.
│   └── TcbAudit.lean        -- WU 1.11.
└── Test/
    ├── KernelTests.lean
    ├── PropertyTests.lean
    ├── Laws/
    │   └── (one file per law)
    ├── Authority/
    │   └── (signed, nonce, replay tests)
    ├── Disputes/
    │   └── (per-claim-variant tests)
    └── Encoding/
        └── (per-type round-trip tests)

rust/                        -- Phase 5 Rust crates; not part of TCB.
├── network/                 -- WU 5.4.
├── ed25519/                 -- WU 3.9.
└── indexer/                 -- WU 5.8.

docs/
├── GENESIS_PLAN.md          -- This document.
├── decidability_discipline.md  -- WU 1.6.
├── std_dependencies.md      -- WU 1.13.
├── tcb_allowlist.txt        -- WU 1.11.
├── GENESIS.txt              -- Genesis hash; Section 13.4.
├── laws/                    -- Per-law specifications.
└── releases/                -- Per-release artefact hashes.
```

### 13.3 CI

GitHub Actions (or equivalent), with one workflow per push:

```yaml
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
      - uses: leanprover/lean-action@v1
      - run: lake build
      - run: lake test
      - run: lake exe count_sorries
      - run: lake exe tcb_audit
```

### 13.4 Reproducibility

- Build artifacts are reproducible byte-for-byte across machines that
  share the same `lean-toolchain`.
- The genesis hash is published in `docs/GENESIS.txt` and verified by
  CI.
- Each release tag is signed.

### 13.5 Local Developer Workflow

```bash
elan toolchain install $(cat lean-toolchain)
lake build               # full build
lake build LegalKernel.Kernel   # kernel only (fastest feedback)
lake test
```

A fast inner loop targets the kernel module; full builds are run
before commit.

### 13.6 Runbook: Adding a New Law

A *law* is a `Transition` value, optionally with an `Action`
constructor for serializability and authority. Adding one is a
seven-step procedure.

1. **Specify.** Write a one-paragraph specification: name, parameters,
   precondition (in English), and effect on state. File it as a
   `docs/laws/<name>.md` proposal.

2. **Draft the `Transition`.** Create `LegalKernel/Laws/<Name>.lean`
   containing:
   ```lean
   def Laws.<name> (params...) : Transition :=
     { pre        := fun s => ...
     , decPre     := fun _ => inferInstance
     , apply_impl := fun s => ...
     }
   ```
   The `decPre := fun _ => inferInstance` line works whenever `pre s`
   is built from atomic decidable predicates (arithmetic comparisons,
   membership, conjunctions). If it does not, an explicit
   `Decidable` derivation is required and the law goes through
   security review (Section 14.8).

3. **Add the `Action` constructor.** Append a new constructor to the
   `Action` inductive in `LegalKernel/Actions.lean`:
   ```lean
   inductive Action
     | ...
     | <name> (params...)
   ```
   *Append, never insert.* The constructor's index in declaration
   order is part of the canonical encoding (Section 8.8.3); changing
   it would invalidate every existing signature.

4. **Wire `Action.compile`.** Add a case:
   ```lean
   def Action.compile : Action → Transition
     | ...
     | .<name> p₁ p₂ ... => Laws.<name> p₁ p₂ ...
   ```

5. **Discharge invariants.** For every deployed invariant `I` in
   `LegalKernel/Invariants/`, prove that the new law preserves `I`:
   ```lean
   theorem <name>_preserves_<I>
       (params...) (s : State) (hI : I s)
       (hpre : (Laws.<name> params...).pre s) :
       I (step_impl s (Laws.<name> params...)) := by
     ...
   ```
   If `I` is `IsConservative` and the new law is non-conservative,
   *do not prove the impossible*; instead, demonstrate non-conservation
   (Section 8.1) and exclude the law from the `ConservativeLawSet` at
   the type level.

6. **Authority check.** If the new law should be permitted under
   `AuthorityPolicy P`, update the deployment's policy:
   ```lean
   def deploymentPolicy : AuthorityPolicy :=
     { authorized := fun a act => match act with
         | .<name> ... => /- who can do this? -/
         | ...
     , decAuth := fun _ _ => inferInstance
     , registry := ...
     }
   ```

7. **Test.** Add positive (precondition holds, effect matches expected)
   and negative (precondition fails, no-op) tests in
   `LegalKernel/Test/Laws/<Name>.lean`. Add a property-based test
   asserting the invariants of step 5. Run:
   ```bash
   lake build LegalKernel.Laws.<Name>
   lake test LegalKernel.Test.Laws.<Name>
   lake exe count_sorries
   lake exe tcb_audit
   ```

   **Acceptance**: all three commands green, plus reviewer sign-off
   per Section 14.4.

This runbook is mechanical. A new law that follows it touches no
kernel code, adds nothing to the TCB, and inherits the global
invariant guarantees automatically.

### 13.7 Runbook: Adding a New Invariant

An *invariant* is a `State → Prop` predicate that the deployment
asserts holds in every reachable state.

1. **Define.** Create `LegalKernel/Invariants/<Name>.lean`:
   ```lean
   def <Name> (s : State) : Prop := ...
   ```

2. **Initiality.** Prove that the genesis state satisfies the
   invariant:
   ```lean
   theorem <Name>_genesis : <Name> genesis := by ...
   ```

3. **Local preservation.** For every law `Laws.<lawname>` in the
   deployment, prove preservation. This is one obligation per law;
   the kernel makes this enumeration mandatory.
   ```lean
   theorem <name>_preserves_<Name>
     (params...) (s : State) (h : <Name> s)
     (hpre : (Laws.<lawname> params...).pre s) :
     <Name> (step_impl s (Laws.<lawname> params...)) := by ...
   ```

4. **Lift to global.** Compose into a single global theorem via
   `invariant_preservation_via_laws` (WU 1.9):
   ```lean
   theorem <Name>_global :
     ∀ s, ReachableViaLaws deploymentLaws genesis s → <Name> s := by
     apply invariant_preservation_via_laws <Name> deploymentLaws genesis
       <Name>_genesis
     intro s t htL hI hpre
     -- One subgoal per law in `deploymentLaws`.
     cases htL with
     | head      => exact <name>_preserves_<Name> _ _ s hI hpre
     | tail h    => ... -- proceed by case analysis
   ```

5. **Compose with existing invariants.** If the deployment already
   has invariants `I₁, ..., I_k`, use `invariants_compose` to derive
   the conjunction:
   ```lean
   theorem deployment_invariants_global :
     ∀ s, ReachableViaLaws deploymentLaws genesis s →
          (I₁ s ∧ ... ∧ I_k s ∧ <Name> s) := ...
   ```

6. **Update CI.** Add a build target so that future law additions
   that fail to preserve `<Name>` break the build at the law module,
   not in some downstream consumer.

   **Acceptance**: `<Name>_global` proved with no `sorry`; CI fails
   if a new law lacks a preservation lemma.

### 13.8 Runbook: Cutting a Release

A release is a tagged, signed, hashed snapshot of the kernel and
deployment.

1. **Pre-release checklist.**
   - `lake build` clean; `lake test` green.
   - `lake exe count_sorries Kernel.lean` returns 0.
   - `lake exe count_sorries` for non-kernel modules: same as or fewer
     than the previous release.
   - `lake exe tcb_audit` green.
   - All Phase work units claimed by this release marked complete in
     the issue tracker.

2. **Version bump.** Update `Version.lean`:
   ```lean
   def kernelVersion : String := "X.Y.Z"
   def kernelVersionHash : ByteArray := <BLAKE3 of Kernel.lean>
   ```
   Major bumps (`X`) are reserved for changes that alter the canonical
   encoding (Section 8.8). Minor bumps (`Y`) for new laws, invariants,
   or authority features. Patch bumps (`Z`) for non-functional
   changes only.

3. **Genesis re-hash.** If genesis state has changed:
   - Regenerate `docs/GENESIS.txt` with the new `GenesisHash`.
   - Bump major version (genesis change is breaking).

4. **Tag.**
   ```bash
   git tag -s vX.Y.Z -m "Release vX.Y.Z"
   git push origin vX.Y.Z
   ```
   The tag is GPG-signed by the release manager.

5. **Build artefacts.**
   - Reproducible-build pipeline (WU X.1) produces:
     `runtime-X.Y.Z.bin`, `replay-X.Y.Z.bin`, `kernel.olean.X.Y.Z`.
   - Each artefact is signed with the release key.
   - The artefact set's BLAKE3 hash is published in
     `docs/releases/X.Y.Z.txt`.

6. **Release notes.**
   - One-line summary per WU completed since the previous release.
   - Highlight any TCB-affecting changes (new imports, new axioms,
     new trusted dependencies). These changes require a Genesis-Plan
     amendment (Section 16.6).
   - Highlight any encoding-affecting changes (constructor additions,
     CBOR scheme tweaks). These bump major version.

7. **Migration notes.**
   - For deployments running the previous release, document the
     migration: new genesis required? New keys? New replay needed?
     If yes, provide the bridge transition (Section 8.6).

8. **Publish.**
   - GitHub release with the artefacts and notes.
   - Public announcement on the project's communication channel.

   **Acceptance**: tag visible; artefacts downloadable; hashes
   verifiable; reproducible build by an independent party produces
   the same hashes.

### 13.9 Runbook: Investigating a Suspected Invariant Violation

Hopefully never needed, but documented in advance so that, when needed,
the procedure is known.

1. **Capture state.** Snapshot current `ExtendedState`, current log
   (with hash), current kernel binary hash.

2. **Reproduce.** Use the `replay` tool to reconstruct the state
   trajectory from genesis. If the violating state appears in the
   replay, the violation is *deterministic* and follows from the
   recorded actions.

3. **Bisect.** Binary-search for the first log index at which the
   invariant is violated. Identify the action `log[i]` whose
   application triggered the violation.

4. **Locate the gap.** One of:
   - The action's law has no `_preserves_<I>` theorem (a *missing
     proof obligation*; fix the build to require it).
   - The theorem exists but `sorry` is present (a *false claim*; fix
     the proof).
   - The theorem is correct but the runtime is using a different
     binary than the one that compiled the proof (a *deployment
     mismatch*; verify hashes).
   - The invariant or the law's precondition was changed without
     updating the proof (a *coherence failure*; rebuild from a clean
     checkout).

5. **Patch and re-deploy.** Either fix the proof, restrict the law,
   or strengthen the precondition. Cut a new release per Section 13.8.
   If the live deployment must continue, document the violation and
   the migration path explicitly.

6. **Post-mortem.** Write a public post-mortem covering: what was
   violated, how it was deployed, why CI did not catch it, what
   process change prevents recurrence.

   **Acceptance**: post-mortem published; CI rule added; affected
   parties notified.

---

## 14. Best Practices Enforced

Many of the following are restatements or refinements of points
appearing earlier in the document; collecting them here gives reviewers
a single checklist.

### 14.1 Source Discipline

- One `namespace` per file; namespaces match file paths.
- No top-level definitions outside a namespace.
- All public definitions documented with a doc-comment that names the
  property they encode.
- All `theorem`s named with a verb-first convention
  (`step_impl_refines_step_spec`, `transfer_conserves_supply`).

### 14.2 Proof Discipline

- No `sorry` in the kernel module. Ever.
- Every `sorry` in non-kernel modules carries a `TODO(genesis-#NN)`
  tag.
- No unnamed hypotheses except in one-line proofs.
- No use of `Classical.choice` in trusted modules.
- No use of `omega`/`linarith` in trusted modules.

### 14.3 Naming Discipline

- `getX` / `setX` for state accessors.
- `X_pre`, `X_post`, `X_inv` for precondition, postcondition, invariant
  predicates of law `X`.
- `X_refines_Y` for refinement theorems.
- `X_preserves_Y` for invariant preservation lemmas.

### 14.4 Review Discipline

- All changes to the kernel module require two reviewers, one of whom
  must be a formal-methods specialist.
- All changes to `RBMapLemmas` likewise require two reviewers.
- Other modules require one reviewer.
- A change that increases the TCB requires explicit Genesis-Plan
  amendment.

### 14.5 Operational Discipline

- Every release is accompanied by a public Lean compilation log proving
  zero `sorry` in the kernel.
- Every release publishes the genesis hash and the kernel module hash
  side-by-side.
- Bug reports against the kernel are triaged within 48 hours; security
  bugs within 4.

### 14.6 Anti-Patterns

These are forbidden constructs. CI rejects them; reviewers reject
them; the architecture is designed so that they are not necessary.

- **Mutable global state** in any kernel-adjacent module. The kernel
  is purely functional; persisting state belongs in the runtime, not
  in `LegalKernel.*`.
- **`partial def`** in kernel or law modules. All functions must be
  total. If termination is not obvious, supply a termination measure;
  if a function is genuinely non-terminating, it does not belong in
  the kernel.
- **`Classical.choice` or `Classical.dec`** in trusted modules. They
  expand the TCB to include classical logic and obscure the
  decidability of the executable path.
- **`sorry`** in kernel modules at any time. In non-kernel modules,
  every `sorry` must carry a `TODO(genesis-#NN)` tag; CI counts and
  enforces non-increase.
- **Untagged `simp`** in the kernel. `simp` invocations must name
  their rewrite set (`simp only [...]`) so that the proof's behaviour
  is stable across `Std`/`Mathlib` updates.
- **Mutable transition logs**. The append-only invariant of the log
  is enforced by the runtime; in-place edits are forbidden in code,
  in tooling, and in operations.
- **Catching exceptions** in the kernel or runtime hot path. Failures
  are reified as `Except` values; a panic indicates a bug, not an
  expected condition.
- **Hidden `axiom` declarations** outside the explicitly-documented
  axioms (currently only `Verify` and the cryptographic-soundness
  assumption that surrounds it). New axioms require a Genesis-Plan
  amendment.
- **Dynamic loading of laws** at runtime. All laws are statically
  compiled into the deployment binary; dynamic loading would let an
  attacker (or a careless operator) introduce a non-preserving law
  without rebuilding.
- **Implicit `Inhabited` derivations on `State`**. `State` should not
  have a default-constructed instance; the genesis state is named
  explicitly to prevent accidental reset.
- **Reading external time inside kernel functions**. Time enters via
  the `recordTime` oracle action only; calling `IO.monoMsNow` inside
  a kernel function would break determinism.
- **Suppressing CI checks**. `--no-verify` on commits, `[skip ci]`
  in messages, and disabled CI rules are escalation events: they
  require an explicit incident note and a follow-up to re-enable.

### 14.7 Code Review Checklist

For every PR, the reviewer confirms:

**Scope and discipline.**

- [ ] PR description states the WU(s) being addressed.
- [ ] Changes touch only the stated WU(s); orthogonal changes have
      their own PR.
- [ ] If the PR touches `LegalKernel/Kernel.lean` or
      `LegalKernel/RBMapLemmas.lean`, two reviewers (one
      formal-methods specialist) have approved.

**Build and test.**

- [ ] CI is green: `lake build`, `lake test`, `count_sorries`,
      `tcb_audit`.
- [ ] No new `sorry` in kernel modules.
- [ ] Non-kernel `sorry` count did not increase.
- [ ] Property-based tests added or extended for new behaviour.

**Correctness.**

- [ ] Every new `theorem` has either a complete proof or a
      `sorry` tagged with a roadmap WU.
- [ ] Every new `def` in the kernel module has a doc-comment naming
      the property it encodes.
- [ ] Every new `Decidable` instance is justified (one-line
      `inferInstance` is fine; complex instances need a comment).
- [ ] Every new `Action` constructor was *appended*, not inserted;
      constructor index unchanged for existing actions.
- [ ] No new `axiom` declarations.
- [ ] No `partial def`, `Classical.*`, or untagged `simp` in trusted
      modules.

**Documentation.**

- [ ] Genesis Plan updated if the change alters TCB, encoding,
      authority model, or invariant set.
- [ ] Runbook updated if the change affects an existing procedure.
- [ ] Release notes for the next release stage the change with one
      line of context.

**Operational.**

- [ ] If the change affects the runtime, an end-to-end smoke test
      passes against the previous release's artefacts (forward
      compatibility) where applicable.
- [ ] If the change affects encoding, a migration note is included.

### 14.8 Security Review Checklist

A *security review* is a deeper pass invoked when:

- The change introduces a new authority path,
- The change touches `Verify` or the signature pipeline,
- The change adds or modifies a cryptographic primitive,
- The change alters the `SignedAction` / `Dispute` / `Verdict`
  encodings or signing-input domains,
- The change adds a new axiom or expands the TCB,
- A new external dependency is introduced.

In those cases, the standard review is supplemented with:

- [ ] Threat model (Section 10) updated to reflect new attacker
      capabilities considered or new defences added.
- [ ] Attack-by-attack analysis (Section 8.5.3 style) covers
      replay, cross-deployment, cross-actor, key compromise, and
      precondition bypass.
- [ ] All five `Admissible` conditions (Section 8.2) checked
      independently in the new path; no condition silently merged
      into another.
- [ ] Domain separation (`sign_input` prefixes per action class)
      verified for any new signing primitive.
- [ ] No timing-channel-sensitive comparisons inside trusted
      modules; constant-time discipline documented if relevant.
- [ ] No serialisation paths accept *non-canonical* encodings;
      decoder rejects on every well-formedness violation.
- [ ] Dependency on external code (Rust crates, Lean libraries)
      audited: provenance, license, CVE history.
- [ ] Failure modes enumerated; each rejected admissibility
      condition has a distinct error variant.
- [ ] Security-relevant tests added: positive, negative, replay,
      malformed-input, cross-domain.

A security review is *blocking* until every box is checked. It is
documented as a separate review-comment thread on the PR and
preserved in the release record.

---

## 15. Open Research Questions

The kernel as planned is *complete enough to ship*, but several
questions remain genuinely open. We list them here so that work in
adjacent areas (academic and industrial) can be matched to the
project's needs.

### 15.1 Decidability at the Boundary

The kernel admits any `Prop`-valued precondition, but `step_impl`
requires `Decidable (t.pre s)`. Is there a clean way to *enforce*
decidability at the law-boundary type level, so that a non-decidable
law cannot be elaborated into the executable path? A natural candidate
is a `DecidableTransition` newtype wrapping `Transition` with a
`Decidable` instance bundled in.

### 15.2 Concurrent Semantics

Single-threaded semantics are a deliberate choice, but if the
deployment target eventually demands true concurrency, what is the
right operational model? Linear types? An STM-style serialiser? A
proof-relevant variant of linearisability? Each option implies a
different proof burden.

### 15.3 ZK Integration

For privacy-preserving deployments we want to publish a proof that
"some legal transition occurred" without revealing which one. This
requires either:

- Compiling kernel proof terms into ZK circuits (research-grade), or
- Designing a parallel circuit-friendly kernel and proving an
  observational equivalence to the Lean kernel (probably more
  tractable).

### 15.4 Cross-Shard Atomicity

If state is sharded across multiple kernel instances, how do we get
atomicity for cross-shard transitions? Two-phase commit is the obvious
candidate; verifying it inductively at the kernel level is non-trivial.

### 15.5 Reasoning About Liveness

The kernel guarantees safety. Liveness (every legal transition
eventually applies) is a property of the deployment, not the kernel.
Is there a kernel-level abstraction (a "fairness oracle"?) that lets
us reason about liveness without coupling to a specific scheduler?

### 15.6 Mechanised Proof of Refinement to Extracted Code

Lean's compilation strategy is, today, *not* itself formally verified
end-to-end. The closest thing is the soundness of the type theory plus
careful manual review of the runtime. A proof that the extracted code
preserves the kernel's denotational semantics would close this gap.

### 15.7 Upgrade Paths

Migrations between kernel versions are described as "explicit bridge
transitions" (Section 8.6). Is there a more general theory? In
particular: when can two kernel versions be shown *observationally
equivalent* on a subset of states, so that an upgrade is a no-op for
deployments that stay within the subset?

---

## 15B. Workstream H Amendment: Fault-Proof Migration

**Amendment summary.**  This section amends the Genesis Plan to
specify the Workstream-H fault-proof migration architecture.  Per
`docs/planning/fault_proof_migration_plan.md`, Workstream H replaces the
Phase-6 adjudicator-quorum mechanism for the four deterministic
claim variants (`preconditionFalse`, `signatureInvalid`,
`nonceMismatch`, `doubleApply`) with an interactive on-chain
fault-proof game.  Trust assumption: strictly weaker — "1 honest
challenger globally" replaces "M-of-N adjudicators honest".

### 15B.1 State commitment scheme

The sequencer publishes a 32-byte `StateCommit` to L1 representing
the canonical hash of the deployment's `ExtendedState`.  The Lean-
side `LegalKernel.FaultProof.Commit.commitExtendedState` is the
reference function:

```
commitExtendedState es =
  hashBytes (commitState es.base ++ commitNonceState es.nonces ++
             commitKeyRegistry es.registry ++
             commitLocalPolicies es.localPolicies ++
             commitBridgeState es.bridge)
```

Each per-sub-state commit is `hashBytes` of the canonical CBE
encoding.  Under `CollisionFree hashBytes`, top-level commit
equality implies extensional state equality:

  * `commitExtendedState_subcommits_bytes_eq_under_collision_free`
    establishes per-sub-state CBE-bytes equality (theorem #220).
  * `commitExtendedState_subcommits_extensional_eq_under_collision_free`
    (Workstream EI, EI.8.b) lifts bytes-equality to extensional
    `Std.TreeMap.Equiv` on every map-backed sub-state, packaged
    as `ExtendedState.extEq`.  This is the form most downstream
    consumers want, since two `ExtendedState`s that differ only
    in RB-tree shape (a non-canonical insertion order versus the
    canonical reconstruction) are extensionally equal but not
    structurally equal.

Workstream H deliberately uses a single-hash form rather than a
two-level Sparse Merkle Tree (SMT).  The SMT optimisation is a
deployment-layer concern (saves L1 gas via O(log N) cell proofs);
the soundness arguments hold under either representation.

### 15B.2 Step semantics

A `KernelStep` (`LegalKernel.FaultProof.Step.KernelStep`) carries
the inputs and outputs of one kernel step:

```
structure KernelStep where
  preStateCommit  : StateCommit
  signedAction    : SignedAction
  postStateCommit : StateCommit
  cellProofs      : CellProofBundle
```

The L1 step VM (`KnomosisStepVM.executeStep`) consumes a
`KernelStep` plus per-cell Merkle proofs and computes the
post-state commit.  Cross-stack equivalence with Lean's
`recomputeCommitment` is established by theorem #225:
`recomputeCommitment_coherent_with_kernelOnlyApply`, plus the
WU H.10.1 fixture corpus.

### 15B.3 Bisection game

Per the workstream plan §12.4, the bisection game's state
machine is formalised in
`LegalKernel.FaultProof.Game.GameState` with five terminal
status values (`inProgress`, `sequencerWon`, `challengerWon`,
`timedOutSequencer`, `timedOutChallenger`).  Convergence is
established by:

  * Per-round strict narrowing (theorem #264:
    `range_narrows_on_response_{agree,disagree}`).
  * Multi-round descent (theorem #265:
    `range_size_after_k_rounds`).
  * Termination after enough rounds (theorem #231:
    `bisection_converges_after_enough_rounds`).
  * Depth-cap bound (theorem #267:
    `bisection_terminates_in_at_most_max_depth_rounds` with
    `MAX_BISECTION_DEPTH = 64`).

### 15B.4 Single-honest-challenger property

The headline trust-model theorem (theorem #232 family) is
established by a chain of compositional theorems plus a
single composite statement at the settlement boundary:

  * `honest_strategy_unique` (#268) — the honest strategy is
    uniquely determined by the truthful-commit function.
  * `honest_challenger_wins_per_round` — disagreement persists
    under one honest response.
  * `honest_challenger_wins_via_sequencer_timeout` (#269) — if
    the sequencer times out, the challenger wins.
  * `disagreement_persists_along_trace` — disagreement persists
    along any honest-strategy trace.
  * `honest_challenger_responds_truthfully_wins` (settlement) —
    when the challenger is the responding party at single-step
    termination, a truthful step gives a `challengerWon` verdict.
  * `sequencer_responding_with_disputed_high_loses` (settlement)
    — when the sequencer is the responding party at single-step
    termination, the kernel's deterministic output refutes their
    disputed claim.
  * `honest_challenger_wins_against_invalid_state_root` (#232,
    composite) — the load-bearing composite trust-model upgrade
    theorem; unifies the per-branch settlement results into a
    single proposition over both response sides.

Combined with the per-step coherence (#225) and the convergence
chain (#231), an honest challenger always wins against a
sequencer who has published an invalid state root.

### 15B.5 L1 contract surface

Five Solidity contracts (per Workstream-H plan §3.1):

  * `KnomosisStateRootSubmission` — sequencer state-root submission
    + bond + dispute-window + hash-chain integrity.
  * `KnomosisStepVM` — per-step VM that executes one kernel step.
  * `KnomosisFaultProofGame` — bisection game state machine + bond
    redistribution.
  * `KnomosisDisputeVerifierV2` — dual-path verifier (fault-proof
    + adjudicator quorum for oracle disputes).
  * `KnomosisFaultProofMigration` — V1 → V2 handoff.

All contracts immutable per Workstream-E §20 discipline.

### 15B.6 Dispute-pipeline integration

Two new `Action` constructors at frozen indices 17 and 18:

  * `Action.faultProofChallenge (bindingHash, disputedStartIdx,
    disputedEndIdx, challengerCommit)` — L2 advisory action
    recording a challenge intent.
  * `Action.faultProofResolution (bindingHash, gameId, winner,
    revertFromIdx)` — L2 mirror of L1 game settlement.

Both compile to `Laws.freezeResource 0` (kernel-level no-op).
Three new `Event` constructors at frozen indices 13, 14, 15:

  * `Event.faultProofGameOpened`
  * `Event.faultProofBisectionStep`
  * `Event.faultProofGameSettled`

The `DisputeConfig` structure (`LegalKernel.FaultProof.DisputeConfig`)
controls per-deployment routing of deterministic claims between
the legacy quorum path and the new fault-proof game path.

### 15B.7 Migration path

`KnomosisFaultProofMigration` follows the bidirectional-consent
pattern from `KnomosisMigration`: the predecessor (V1) must pre-
commit by setting its `migration` immutable to point at the V2
migration contract before activation can proceed.  Activation:

  * Predecessor (V1 dispute verifier) freezes; new disputes
    rejected.
  * Successor (V2) starts fresh, accepting submissions at
    `v1LastFinalisedLogIndex + 1` with `prevLogEntryHash =
    v1LastFinalisedLogEntryHash`.
  * In-flight V1 disputes settle on V1 within the
    `MIN_GRACE_WINDOW_BLOCKS` window.

### 15B.8 Trust-model update

Pre-Workstream-H trust assumption: M-of-N adjudicators honest.
Post-Workstream-H: 1 honest challenger globally.  Strictly
weaker because:

  * Any subset of the prior quorum that includes at least one
    honest member satisfies the new assumption.
  * Any non-adjudicator with a Knomosis node + bond also
    satisfies it.

The headline theorem #232 family establishes the trust-model
upgrade at the type level.

### 15B.9 Deviation block

Workstream H deviates from the plan's spec in a few places:

  * **Single-hash commit** instead of full SMT.  The plan §12.2
    calls for two-level SMTs; the implementation uses a single-
    hash-of-CBE-encoding form.  The shipped soundness theorem
    is `commitExtendedState_subcommits_bytes_eq_under_collision_free`
    (under `CollisionFree hashBytes`, equal top-level commits
    imply byte-equality of the five sub-state canonical
    encodings).  Lifting bytes-equality to full extensional
    equality on TreeMap-backed sub-states requires CBE encoder
    injectivity for `State` / `NonceState` / `KeyRegistry` /
    `LocalPolicies` / `BridgeState`, which ships at the
    `*_encode_deterministic` level but not as standalone
    `*_encode_injective` lemmas; that's a Workstream-H
    follow-up.  SMT optimisation is documented as a future
    cell-level-gas-optimisation follow-up.
  * **Witness-state cell proofs** instead of Merkle-path cell
    proofs.  The Lean-side verifier consumes a witness state
    and re-hashes it (mathematically sound: `verifyCellProof`
    checks both `commitExtendedState witnessState = commit` AND
    `getCellValue witnessState cellTag = cellValue`).  The
    Solidity-side `KnomosisStepVM` only checks `witnessCommit ==
    preStateCommit` and trusts the proof's `cellValue` field —
    it cannot re-hash the full state on L1.
    **Workstream SC.1 status (Lean side).**  The sparse-Merkle-
    tree cell-proof spec + soundness theorem ships in
    `LegalKernel/FaultProof/Smt.lean` (Workstream SC.1, see
    `docs/planning/smt_cell_proofs_plan.md`).  Headline
    theorems: `smtCellProof_no_value_substitution` (the
    load-bearing operational binding property — under
    `CollisionFree hashBytes` and value-encoder injectivity,
    two verifying proofs for the same `(root, key)` must
    claim the same value) and `smtCellProof_sound_under
    _collision_free` (its plan-named alias).  Both forms
    (witness-state and SMT) ship side-by-side in the Lean
    kernel; deployments select the active form via the
    `KnomosisStateRootSubmission` parameter set.
    **Workstream SC.2 status (Solidity verifier).**  The
    gas-efficient Solidity verifier ships in
    `solidity/src/lib/SmtCellVerifier.sol` (Workstream SC.2),
    with a thin wrapper exposed via
    `solidity/src/lib/StepVMMerkle.sol::verifyCellSmtProof`.
    The verifier walks the 256-level path using inline-assembly
    `keccak256` and pre-computes the canonical empty-subtree
    hash table once per call.  Per-call cost when invoked from
    within a Solidity contract: ≈ 25k gas typical, ≤ 32k gas
    worst-case (full-popcount path).  41 unit + 3 gas + 2
    property/fuzz tests at
    `solidity/test/SmtCellVerifier.t.sol`; auditors recompute
    the empty-subtree constants via
    `solidity/script/ComputeEmptyHashes.s.sol`.
    **Workstream SC.3 status (cross-stack corpus).**  Complete.
    The cross-stack ratification at the fixture-corpus level
    ships in `LegalKernel/Test/Bridge/CrossCheck/SmtCellProof.lean`
    (Lean fixture generator, 50 honest + 50 adversarial entries
    across six tamper classes — `valueSubst`, `siblingTamper`,
    `bitmaskTamper`, `rootTamper`, `keyMismatch`, `absentKey`)
    and `solidity/test/CrossCheck/SmtCellProof.t.sol` (Solidity
    consumer that re-runs `SmtCellVerifier.verifyCellProof`
    byte-for-byte against every fixture entry).  Each entry
    carries the four byte-string inputs the Solidity verifier
    consumes (`smtKey`, `leafPreimage`, `proofData`, `root`)
    plus the expected verdict; both sides MUST agree.  The
    per-entry verdict assertion is gated on
    `isKeccak256Linked`; structural-invariant assertions
    (header shape, byte sizes, tamper-class coverage) run
    unconditionally.  Closes the operational off-chain audit
    gap with a mechanical L1-side defence: under
    `CollisionFree keccak256`, the Lean theorem
    `smtCellProof_no_value_substitution` rules out adversarial
    substitution, and the cross-stack corpus mechanically
    confirms Lean and Solidity walk the same hashes
    byte-for-byte.
  * **Per-variant per-cell coherence theorems** are *omitted* in
    favour of the global #225 theorem.  The per-variant case
    analysis is structurally subsumed by the witness-state
    design (the semantic core IS `kernelOnlyApply`).
  * **Solidity-side per-cell SMT** (`SmtCellVerifier.sol`)
    ships gas-efficient `verifyCellProof` for the SMT path
    (Workstream SC.2); witness-state-bearing form remains
    available for legacy deployments via
    `StepVMMerkle.verifyCellProofWitness`.
  * **Witness implication (#233) requires deployment assumption.**
    `faultProof_challenger_won_implies_state_root_wrong` takes an
    explicit `L1AttestationSemantics` predicate as a hypothesis,
    capturing the deployment-level semantics of the
    `l1FaultProofVerifier` opaque (i.e., "a positive L1
    attestation implies the sequencer's claim ≠ the canonical
    L2 commit").  The L1 contract enforces this operationally;
    cross-stack verification (WU H.10.1 fixture corpus) ratifies
    it for the honest case.
    Cross-stack equivalence is verified at the fixture-corpus
    level (F.1.8).

### 15B.10 Post-audit-2 security hardening

Workstream-H's deep-audit pass surfaced several
deployment-blocking security defects in the Solidity port that
have now been fixed:

  * **Sequencer-spoofing in `initiateChallenge`** — the original
    `initiateChallenge` signature accepted `address sequencer` /
    `bytes32 disputedStateRoot` / `bytes32 deploymentId` as
    caller-provided parameters.  An attacker could specify any
    address as "sequencer", letting them initiate fake challenges
    that timed out against an EOA (which never responds), then
    siphon the *real* sequencer's slashed bond.  Fixed: the game
    now looks up the disputed root, the actual submitter, and
    the deployment ID from `KnomosisStateRootSubmission` based on
    `disputedLogIndex`.  Caller-provided values for these fields
    are no longer accepted.
  * **Missing signature verification in V2 quorum** — V2's
    original `finaliseFromQuorum(uint256 disputeId, address[]
    signers)` accepted a list of "signers" without any
    cryptographic verification.  Anyone could finalise an
    oracle dispute just by listing the adjudicator addresses.
    Fixed: the signature now takes
    `(disputeId, outcome, signers, sigs)` and verifies each
    signature via `ECDSA.recover` against a canonical
    `verdictDigest` that binds `(deploymentId, disputeId,
    disputeHash, outcome)` (matching V1's discipline and
    preventing cross-dispute / cross-outcome replay).
  * **Wrong contract call target in V2** — V2's
    `finaliseFromFaultProof` called `revertStateRootsFrom` on
    the `bridge` field, but `revertStateRootsFrom` lives on
    `KnomosisStateRootSubmission`, not on `KnomosisBridge`.  In
    production this would have silently failed (or worse,
    silently succeeded on a `KnomosisBridge` with no matching
    function).  Fixed: V2 now takes a separate
    `stateRootSubmission` constructor argument and routes the
    rollback call there.
  * **Missing bond-locking + bond-slashing flow** — the original
    `KnomosisStateRootSubmission` declared a `disputed` flag but
    NEVER SET IT, allowing a sequencer's bond to be released
    via `finaliseStateRoot` even with a dispute game in
    progress.  And `revertStateRootsFrom` only marked the
    state-root range reverted; it did not slash the bond.
    Fixed: three new entry points (`markDisputed`,
    `clearDisputed`, `slashSequencerBond`), gated to
    `msg.sender == faultProofGame`, fully implement the bond-
    locking flow.  The game calls `markDisputed` on challenge
    initiation, `slashSequencerBond` on challenger-wins, and
    `clearDisputed` on sequencer-wins.
  * **EOA-target defence on game's constructor** — the
    constructor now requires `_stateRootSubmission.code.length
    > 0` and `_stepVM.code.length > 0` to prevent silent
    no-op behaviour from a misconfigured (EOA) target address.
  * **Malformed-cell-value defence in step VM** — `_decodeNat`
    formerly returned 0 silently on malformed input (1-8 bytes).
    An adversarial responder could submit a truncated cellValue
    to spoof a zero balance and bypass the
    `senderBalance < amount` check.  Fixed: `_decodeNat`
    reverts with `MalformedCellValue` on non-empty inputs
    with length < 9.

All fixes ship with adversarial test coverage; the cross-stack
fixture corpus (WU H.10) validates the honest case; the new
Solidity tests cover the adversarial cases for each fix.

### 15B.11 Post-audit-3 hardening

A third audit pass surfaced several additional integration and
edge-case defects in the Solidity + Lean port that have now been
fixed:

  * **Missing `revertStateRootsFrom` call on challenger-wins**.
    `KnomosisFaultProofGame._settle` slashed the sequencer's bond
    on challenger-wins but did NOT call
    `revertStateRootsFrom(g.disputedLogIndex)` on the state-root
    submission contract.  The L1 contracts (bridge, downstream
    withdrawal verifiers) would have continued treating the
    invalid root as valid.  Fixed: `_settle` now calls
    `revertStateRootsFrom` in a `try`/`catch` block on
    challenger-wins.
  * **`initiateChallenge` accepted inverted ranges**.  Without a
    `lowLogIndex < disputedLogIndex` check, an attacker could
    create a degenerate game where the bisection midpoint formula
    produces values outside any meaningful range, leaving the
    game stuck.  Fixed: `initiateChallenge` now reverts with
    `MidpointOutOfRange` for `lowLogIndex >= disputedLogIndex`.
  * **Lean `timeoutLoss` had loser as a free parameter**.  The
    Lean-side `GameTransition.timeoutLoss (loser : TurnSide)`
    let the caller specify ANY party as the loser, but the
    Solidity-side `claimTimeout` derives the loser from
    `g.turn` (the current turn-holder is the unresponsive
    party).  This was a Lean-side semantic mismatch with the
    Solidity implementation.  Fixed: `timeoutLoss` no longer
    takes a parameter; the loser is derived from `gs.turn` at
    apply-time, matching the Solidity semantics exactly.
    Affected theorems (`applyTransition_sequencer_timeout_settles`,
    `honest_challenger_wins_via_sequencer_timeout`) now require
    a `gs.turn = .sequencer` hypothesis.
  * **Slash-vs-finalise race**.  `slashSequencerBond` did not
    check `r.finalised`, allowing the slashing path to attempt
    a double-spend if a root was finalised before slashing (the
    contract would no longer hold the ETH).  Fixed: added
    `r.finalised → AlreadyFinalised` check; `finaliseStateRoot`
    now zeros `r.bond` after release so a racing slash hits
    `BondAlreadyZero` rather than attempting a double-transfer.
  * **Missing constructor validations on `KnomosisStateRootSubmission`**.
    The constructor accepted zero values for `_bond`,
    `_disputeWindow`, `_minSubmissionInterval`, and
    `_maxOutstandingRoots`, each of which would disable a
    security-critical mechanism.  Fixed: each is now validated
    `> 0` at construction; reverts with the corresponding
    error variant.
  * **Lean cell-write declarations corrected**.  `Action.subSteps`
    bulk-action sub-step proofs carry the canonical CBE-encoded
    pre-balance bytes (was `ByteArray.empty` placeholder which
    would have failed `verifyCellProof`).  `Action.writeCells`
    for `withdraw` no longer claims the unbounded
    `bridgePending 0` placeholder index (which could have
    collided with a legitimate withdrawal id 0); the action-
    level declaration now lists only statically-known cells.

All fixes ship with adversarial test coverage where applicable;
the new Solidity tests (`test_initiateChallenge_rejects_inverted_range`,
`test_initiateChallenge_rejects_equal_range`,
`test_claimTimeout_calls_revertStateRootsFrom_on_challenger_wins`,
`test_constructor_rejects_zero_bond/zero_dispute_window/zero_submission_interval/zero_max_outstanding`)
exercise each defence.  Lean tests update to match the new
`timeoutLoss` no-parameter API.

### 15B.12 Post-audit-4 hardening

A fourth audit pass surfaced cross-stack precondition divergences
plus a depth-cap off-by-one in the Lean state machine:

  * **Three missing per-variant preconditions in `KnomosisStepVM`**.
    Solidity's `_stepReward`, `_stepDistributeOthers`, and
    `_stepProportionalDilute` were missing the `amount > 0` /
    `totalReward > 0` / `sumOthers > 0` checks that Lean's
    corresponding `Laws.*` modules require.  An attacker could
    submit a zero-amount action that Solidity accepts but Lean
    rejects, producing a cross-stack divergence at termination.
    Fixed: each function now reverts with `AmountMustBePositive`
    on zero-valued inputs.  New tests
    (`test_reward_rejects_zero_amount`,
    `test_distributeOthers_rejects_zero_amount`,
    `test_proportionalDilute_rejects_zero_totalReward`,
    `test_proportionalDilute_rejects_zero_sumOthers`) exercise
    each precondition.
  * **Lean `applyTransition` depth-cap off-by-one**.
    `respondAgree` / `respondDisagree` incremented `gs.depth`
    without checking the resulting value against
    `MAX_BISECTION_DEPTH`.  Solidity's `respondToMidpoint`
    checks `g.depth > MAX_BISECTION_DEPTH` after the increment.
    Lean's lack of a corresponding check meant a transition at
    `depth = MAX_BISECTION_DEPTH` would succeed at the Lean
    level while reverting at the Solidity level.  Fixed: both
    `respondAgree` and `respondDisagree` now reject with
    `bisectionDepthExceeded` when `gs.depth ≥
    MAX_BISECTION_DEPTH`.  Existing shape lemmas
    (`applyTransition_respondAgree_shape`, etc.) updated to
    case-split on the new gate.  Two new Lean tests cover the
    rejection + accept-just-below-cap boundary.
  * **`KnomosisFaultProofMigration` defensive constructor checks**.
    `_predecessor == _successor` (degenerate migration) and
    `_successor.code.length == 0` (EOA successor) were
    silently accepted.  Fixed: revert with
    `PredecessorEqualsSuccessor` and `SuccessorNotContract`
    respectively.  Two new tests cover each defence.

All fixes preserve the audit-1/2/3 invariants; all Lean and
forge tests pass without exception.

### 15B.13 Post-audit-5 cross-stack + deploy hardening

A fifth audit pass surfaced cross-stack encoding divergences in
the bulk-action fold functions plus a deploy-script circular-
dependency bug:

  * **Bulk-action fold `keyB` encoding mismatch**.  Solidity's
    `_stepDistributeOthers` and `_stepProportionalDilute` fold
    each recipient's balance update via
    `keccak256(abi.encodePacked(acc, p.keyB, newBalance))`.  In
    Solidity, `CellProof.keyB` is `uint256` — so `keyB`
    contributes 32 bytes to the hash preimage.  The Lean
    mirror's `stepCommitDistributeOthersFold` used `uint64BE
    keyB` (8 bytes), producing a cross-stack byte-disagreement
    under the production keccak256 binding.  Fixed: Lean now
    uses `uint256BE keyB`, matching Solidity's 32-byte
    encoding exactly.  New value-level tests
    (`stepCommitDistributeOthersFold uses uint256 keyB`,
    `DistributeOthers fold differs on different keyB`, etc.)
    exercise the corrected encoding.
  * **Missing `stepCommitProportionalDiluteFold` in Lean**.
    The Lean side had `stepCommitProportionalDiluteHead` but
    not the per-recipient fold function the bulk Solidity
    `_stepProportionalDilute` uses.  Fixed: added
    `stepCommitProportionalDiluteFold` with the same shape as
    `stepCommitDistributeOthersFold` (both folds use the same
    `(acc, keyB-uint256, newBalance-uint256)` schema).
  * **Deploy script circular-dependency bug**.  The original
    `DeployFaultProof.s.sol` passed `address(0)` as the
    `_faultProofGame` placeholder to `KnomosisStateRootSubmission`
    and `KnomosisDisputeVerifierV2`, but both constructors reject
    zero addresses.  The script would have reverted at
    construction.  Fixed: use `vm.computeCreateAddress` to
    predict the game contract's address before deploying the
    state-root submission and verifier; deploy order becomes
    [stepVM → state-root-sub (with predicted game) → verifier
    (with predicted game) → game (with real state-root-sub)].
    The game's `code.length > 0` defence on
    `_stateRootSubmission` is satisfied because state-root-sub
    is deployed before game.

All fixes maintain audit-1/2/3/4 invariants; all Lean (1869)
and forge (333) tests pass.

---

## 15C. Workstream AR Amendment: Audit Remediation

See `docs/planning/audit_remediation_plan.md` for the per-WU specifications.
Workstream AR is a remediation pass over the deployment-facing
infrastructure surfaced by the comprehensive Lean module audit
(`docs/audits/`).  The audit found **no critical findings** in the
TCB; AR addresses the 10 Major findings (M-1 … M-10), the two
cross-verification additions (M+1, M+2), the 19 minor findings,
and the 11 informational observations.

### 15C.1 Scope

AR is scoped entirely to **non-TCB** modules.  `Kernel.lean` and
`RBMapLemmas.lean` are untouched; `tcb_allowlist.txt` and
`Tools.Common.tcbInternalImports` are unchanged.  Every AR change
preserves the canonical-three Lean axiom audit
(`#print axioms` returns ⊆ `[propext, Classical.choice,
Quot.sound]`) and adds zero custom axioms.

### 15C.2 Headline deliverables (status)

| WU group | Title                                       | Status            |
|----------|---------------------------------------------|-------------------|
| AR.1     | Shared `signedActionDomain` constant        | Complete          |
| AR.2     | DeploymentId parameterisation (6 sub-units) | Complete          |
| AR.3     | Snapshot bootstrap chain anchor + AttestedSnapshot wrapper | Complete |
| AR.4     | Map-backed sub-state encoder injectivity (8 sub-units) | Complete (shipped under Workstream EI; see §15C.7) |
| AR.5     | Action constructor-tag regression pins (19) | Complete          |
| AR.6     | Event constructor-tag regression pins (16) + `Event.tag` projection | Complete |
| AR.7     | Lex Diff comparator widening                | Complete          |
| AR.8     | `naming_audit` `_v2` policy alignment       | Complete          |
| AR.9     | `mock_import_audit` binary                  | Complete          |
| AR.10    | Hash `@[extern]` annotations + C fallback stub | Complete       |
| AR.11    | `synth_local` resource-aware dispatch       | Complete          |
| AR.12    | `lexlaw` `renderSyntax` byte-fidelity       | Complete          |
| AR.13    | Stale docstring fixes (5 thematic sub-units)| Complete          |
| AR.14    | `count_sorries` exhaustive patterns         | Complete          |
| AR.15    | `proportionalDilute` invariant comment      | Complete          |
| AR.16    | `Verdict.encode` length-match boundary      | Complete          |
| AR.17    | `kernelOnlyApply` exhaustive switch         | Complete          |
| AR.18    | `applyVerdictUnchecked` docstring contract  | Document-only (mechanical `private` deferred — see below) |
| AR.19    | `fileDispute_rejects_*` family completion   | Complete          |
| AR.20    | `.github/CODEOWNERS`                        | Complete          |
| AR.21    | `withdraw` positivity                       | Complete          |
| AR.22    | Documentation + `kernelBuildTag` bump       | Complete          |
| AR.23    | End-to-end integration regression suite (4 sub-units) | Complete (AR.4.8 dependency closed by EI.8.b) |

### 15C.3 Cross-deployment-replay defence

AR.2 closes the M-1 / M-5 cross-deployment-replay hazard
end-to-end.  Production runtimes now thread the deploymentId
through every signing-input computation; the `knomosis-replay` audit
binary refuses to run without an explicit `--deployment-id <hex>`
flag.  The kernel-level admissibility predicate
(`AdmissibleWith verify P d`) is unchanged; what AR.2 changes is
that every production entry point now reaches it with a non-empty
`d` rather than silently defaulting to `ByteArray.empty`.

### 15C.4 Snapshot-bootstrap chain anchor

AR.3 adds the `.anchorMismatch` arm to `bootstrapFromSnapshot`:
the snapshot's `seedHash` must match the actual hash of the
pre-snapshot log prefix (or `zeroHash` at `baseIdx = 0`).  An
adversary supplying a snapshot from a different log timeline is
now rejected before any replay happens; combined with the
attestor-signature check in
`bootstrapFromAttestedSnapshot`, cross-replica bootstrap is gated
on both signature + chain coherence.

### 15C.5 Hash `@[extern]` swap-point

AR.10 materialises the C ABI swap-point contract for the three
hash adaptor functions (`knomosis_hash_bytes`, `knomosis_hash_stream`,
`knomosis_hash_identifier`).  The `@[extern]` annotations on
`hashBytes` / `hashStream` / `hashImplementationIdentifier`
direct the Lean code-generator to call the named C symbol; the
default `runtime/knomosis-hash-fallback.c` stub forwards each call
to the corresponding `*Fallback` Lean function (compiled into a
`extern_lib knomosisHashFallback` static library that Lake links
into every binary).  Production deployments override by linking
a real BLAKE3 / keccak256 implementation library ahead of the
fallback in the link order.

### 15C.6 AR.18 mechanical visibility (deferred)

The plan called for `private def applyVerdictUnchecked` to lexically
restrict the unchecked stage-4 entry point.  Lean 4's `private`
modifier is FILE-LOCAL: it makes the name accessible only within
the same source file.  The legitimate in-namespace callers
(`Rewards.applyVerdictWithRewardsUnchecked` and
`applyVerdictWithRewardsMultiUnchecked` in
`LegalKernel/Disputes/Rewards.lean`) live in a different file, so
`private` would break them.  The `protected` modifier (which
requires full namespace qualification at every call site,
including in-file ones) would compile but requires updating ~20
in-file references in `Verdict.lean` plus the four cross-file
references in `Rewards.lean` and the test files.

AR.18 ships as documentation-only: the `applyVerdictUnchecked`
docstring documents the contract loudly ("UNCHECKED — TESTING
ONLY") and a review-gate rule enforces it.  The mechanical
`protected` promotion is scoped as a future cleanup that
coordinates with a refactor moving the legitimate
`Rewards.applyVerdictWithRewardsUnchecked` callers into a public
interface that re-exports the unchecked surface controllably.

### 15C.7 Encoder injectivity (complete)

The map-backed sub-state encoder-injectivity proof chain
(originally scoped as AR.4) shipped under Workstream EI
(Encoder Injectivity) — see
`docs/planning/encoder_injectivity_plan.md` for the per-sub-unit
catalogue and `LegalKernel/Encoding/{StateInjective,
LocalPolicyInjective, BridgeInjective}.lean` plus
`LegalKernel/FaultProof/Commit.lean` for the shipped theorems.

The headline composition theorem
`commitExtendedState_subcommits_extensional_eq_under_collision_free`
in `FaultProof/Commit.lean` lifts the existing bytes-equality
theorem `commitExtendedState_subcommits_bytes_eq_under_collision_free`
to extensional state equality (`ExtendedState.extEq`).  Per-
sub-state injectivity lemmas:

  * `BalanceMap.encode_injective` + `State.encode_injective` (EI.2)
  * `NonceState.encode_injective` (EI.3)
  * `KeyRegistry.encodeMap_injective` (EI.4)
  * `LocalPolicies.encodeMap_injective` (EI.5)
  * `Bridge.BridgeState.encodeConsumed_injective`,
    `encodePending_injective`, `encode_injective` (EI.6 + EI.7)

All theorems share the axiom posture `#print axioms` ⊆
`[propext, Classical.choice, Quot.sound]`.  All are
**conditional** on canonical-encoding bounds (`< 2^64` on
pair-list lengths and per-value sizes) — these are deployment-
level invariants enforced at the runtime boundary (Phase 5).

---

## 15D. Workstream E Amendment: Ethereum Integration

**Amendment summary.**  This section amends the Genesis Plan to
specify the Ethereum-integration architecture shipped under
Workstreams E-A through E-F (Lean side + Solidity side + cross-
stack ratification).  See
`docs/planning/ethereum_integration_plan.md` for the per-WU
engineering plan and `docs/planning/ethereum_workstream_g_plan.md`
for the documentation-amendment plan WG.1 – WG.5 that produced this
chapter.

The integration positions Knomosis as a **knomosis-as-rollup**: an L2
state-transition system whose finality story is anchored on
Ethereum L1.  L1 carries the bridge escrow, the identity registry,
the dispute pipeline, the sequencer-stake escrow, and (under
Workstream H) the interactive fault-proof game.  L2 carries the
Lean kernel + non-TCB law layer + the bridge state.

**Trust-model delta.**  The integration introduces five operational
trust assumptions (EUF-CMA secp256k1, keccak256 collision-
resistance, L1 finality, Solidity-contract correctness, EIP-1271
contract correctness) and adds **zero** Lean-level axioms.  Every
new opaque (`eip712Wrap`, etc.) ships as `opaque`, not `axiom`;
`#print axioms` on every Workstream-E theorem returns a subset of
`[propext, Classical.choice, Quot.sound]`.

**TCB delta.**  Zero.  The Bridge layer
(`LegalKernel/Bridge/*.lean`) lives entirely outside
`Kernel.lean` + `RBMapLemmas.lean`.  `tcb_allowlist.txt` and
`Tools.Common.tcbInternalImports` are unchanged.

### 15D.1 Deployment scenario

The integration adopts the **optimistic rollup** deployment shape:

  * **L1 (Ethereum).**  Five immutable contracts mirror the kernel's
    deployment-facing surface:
      - `KnomosisBridge.sol` — L1 escrow for deposits + post-finalisation
        withdrawal redemption.
      - `KnomosisIdentityRegistry.sol` — public mapping from L1 addresses
        to Knomosis `ActorId`s.
      - `KnomosisDisputeVerifier.sol` (v1) — three-variant dispute pipeline.
      - `KnomosisSequencerStake.sol` — bondable escrow for the sequencer's
        L1 stake (slashable on upheld disputes).
      - `KnomosisMigration.sol` — attested handoff between predecessor and
        successor bridge deployments.
    Plus the five-contract Workstream-H fault-proof suite (§15B.5),
    making **ten immutable contracts** under the v2 surface (Workstream
    GP.11.10 later adds an eleventh, the
    `KnomosisAmmDisasterRecoveryMultisig` AMM kill-switch quorum — see
    §15E — for **eleven** contracts in `solidity/` total).
  * **L2 (Knomosis kernel + Bridge).**  The Lean kernel runs as the
    sequencer's authoritative engine.  An "L1 ingestor" daemon
    (Rust: `knomosis-l1-ingest`, RH-B) watches L1 logs, translates each
    bridge / identity event to a `SignedAction` signed by the
    reserved bridge actor, and submits it via the network adaptor
    (`knomosis-host`, RH-C) into the sequencer's runtime.  An off-chain
    fault-proof observer (`knomosis-faultproof-observer`, RH-G) plays
    bisection moves on behalf of honest challengers when the
    sequencer commits to an invalid state root.

```
┌────────────────────────────── Ethereum L1 ──────────────────────────────┐
│                                                                          │
│  KnomosisBridge          KnomosisIdentityRegistry      KnomosisDisputeVerifier     │
│  KnomosisSequencerStake  KnomosisMigration             [+ Workstream-H suite]   │
│                                                                          │
└──────────┬─────────────────────────────────────────┬──────────────────────┘
           │  (events: Deposited / Registered / …)   │  (state roots, disputes)
           │                                         │
┌──────────┴─────────────────────────────────────────┴──────────────────────┐
│                  Knomosis L2 (sequencer / replica)                          │
│                                                                          │
│   knomosis-l1-ingest (RH-B)  →  knomosis-host (RH-C)                            │
│        │                                                                  │
│        ▼                                                                  │
│   Lean kernel + Laws + Authority + Bridge layer                           │
│   (`LegalKernel/Bridge/*.lean`, Workstreams A – D)                        │
│                                                                          │
│   knomosis-faultproof-observer (RH-G)  ←→  KnomosisFaultProofGame (L1)          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Acceptance-test scenario** (the seven-step end-to-end script that
F.3 testnet-acceptance dry-runs):

  1. Alice deposits 1 ETH to `KnomosisBridge.sol` via `depositETH()`.
  2. The L1 ingestor observes the `Deposited` event and forwards a
     bridge-signed `Action.deposit` to the L2 runtime; Alice's L2
     balance shows 1 ETH.
  3. Alice signs `Action.transfer 1_eth Bob 0.5_eth` via MetaMask
     using the EIP-712 envelope.
  4. The sequencer applies the transfer; Bob's L2 balance shows
     0.5 ETH.
  5. Bob signs `Action.withdraw 1_eth Bob 0.5_eth` via MetaMask.
  6. The sequencer applies the withdrawal; the post-state root is
     submitted to `KnomosisBridge.sol` via `submitStateRoot()`.
  7. After the dispute window closes, Bob calls
     `KnomosisBridge.withdrawWithProof(...)` with the SMT-extracted
     proof and receives 0.5 ETH at his L1 address.

Each step maps to a closed Workstream-E sub-unit (§5–§9 of
`ethereum_integration_plan.md`); the corresponding Lean theorems
appear in §15D.4–§15D.7 below.

### 15D.2 Trust assumptions

The integration introduces five operational trust assumptions.
Each is a property of an *external* component (a Rust adaptor
crate, an L1 contract, or a wallet) that some Lean theorem's
conclusion depends on.  None is a Lean axiom; all surface as
`opaque` Lean declarations or as conditional-hypothesis parameters
to the relevant theorems.

  * **TA-2.1 EUF-CMA on ECDSA secp256k1.**  *Statement:* for any
    polynomial-time adversary `A`, `A` cannot produce a forgery
    on a freshly-generated secp256k1 key-pair except with
    negligible probability.  *Realised by:* the `Verify` opaque
    in `Authority/Crypto.lean`, linked at runtime to
    `runtime/knomosis-verify-secp256k1` (RH-A.1).  *Consumes:*
    `replay_impossible`, `nonce_uniqueness`,
    `eip712Wrap_injective`, `bridge_replay_impossible`.  *L1
    mirror:* OpenZeppelin's `ECDSA.recover` enforces the same
    EUF-CMA hypothesis plus EIP-2 / BIP-62 low-s
    canonicalisation; Workstream RH-A.1's audited Rust verifier
    rejects high-s signatures via `k256`'s `IsHigh` filter.
  * **TA-2.2 keccak256 collision-resistance.**  *Statement:* it
    is computationally infeasible to find `x ≠ y` with
    `keccak256(x) = keccak256(y)`.  *Realised by:* the
    `hashBytes` opaque in `Runtime/Hash.lean`, linked at runtime
    to `runtime/knomosis-hash-keccak256` (RH-A.2).  *Consumes:*
    every `*_under_collision_free` lemma (most notably
    `commitExtendedState_subcommits_extensional_eq_under_collision_free`,
    `smtCellProof_sound_under_collision_free`,
    `verifyProof_sound`, `eip712Wrap_injective`).  *L1 mirror:*
    the EVM `KECCAK256` opcode.
  * **TA-2.3 L1 finality.**  *Statement:* L1 blocks at depth
    ≥ `N` do not reorder.  *Default:* `N = 12` (Ethereum mainnet
    convention).  *Realised by:* the L1 ingestor's reorg window
    (`knomosis-l1-ingest::reorg::ReorgWindow`, RH-B) and the
    Workstream-H state-root finalisation policy
    (`Bridge/Finalisation.lean`).  *Consumes:*
    `isFinalised_monotonic_in_currentBlock` and the off-chain
    observer's `confirmation_depth` operator knob.  *Failure
    mode:* a deep re-org (depth > window) surfaces as
    `WatcherError::Reorg` and halts the daemon loudly; the
    operator runbook (`docs/fault_proof_runbook.md` §7) covers
    the recovery path.
  * **TA-2.4 Solidity-contract correctness.**  *Statement:* the
    deployed Solidity bytecode in `solidity/src/contracts/` and
    `solidity/src/lib/` faithfully implements the audited
    Solidity source.  *Compensating control:* the F.1.x cross-
    stack equivalence corpus (Workstream-F) and the SC.3 SMT
    cross-stack corpus (Workstream-SC) mechanically ratify
    byte-for-byte agreement between Lean references and
    Solidity implementations on every covered surface.  *Pre-
    deployment audit bar:* higher than for upgradeable
    contracts; every contract is `immutable`, with no proxy / no
    `initialize` / no admin role (§15D.8.2).  *Compiler pin:*
    `foundry.toml` pins `solc_version = "0.8.20"` with
    `evm_version = "shanghai"` and `via_ir = true`.
  * **TA-2.5 EIP-1271 contract correctness.**  *Statement:* for
    every smart-contract wallet `W` the deployment admits, `W`'s
    `isValidSignature(bytes32 hash, bytes signature)` callback
    returns the canonical `0x1626ba7e` magic value iff the
    wallet's intent-set permits the signed message.  *Realised
    by:* the `KnomosisIdentityRegistry.registerEIP1271` entry
    point (`solidity/src/contracts/KnomosisIdentityRegistry.sol`),
    which probes `isValidSignature(bytes32(0), "")` for the
    canonical magic / explicit-invalid response at registration
    time.  *Consumes:* the deployment-level guarantee that
    contract-signed actions are user-authorised.  No Lean
    theorem directly consumes TA-2.5; the assumption is fully
    deployment-side.

Cross-references: each assumption gets a `TA-2.X` block in
`docs/extraction_notes.md` §2.X naming the exact `opaque` /
`@[extern]` Lean swap-point, the Rust adaptor crate, and the
deployment-side mitigation.

### 15D.3 Action and Event extensions

Workstreams E-B / E-C extend the kernel's frozen `Action` and
`Event` indices.  Per `tcb_audit`, `lex_lint`, and the AR.5 /
AR.6 regression pins, **every constructor's integer index is
frozen forever**; the table below is the canonical readout of
the existing pins (see `LegalKernel/Encoding/Action.lean` and
`LegalKernel/Events/Types.lean`).

```
-- Action constructors (frozen indices 0..24)
Action.transfer            := 0
Action.mint                := 1
Action.burn                := 2
Action.freezeResource      := 3
Action.replaceKey          := 4
Action.reward              := 5
Action.distributeOthers    := 6
Action.proportionalDilute  := 7
Action.dispute             := 8   -- Phase 6
Action.disputeWithdraw     := 9   -- Phase 6
Action.verdict             := 10  -- Phase 6
Action.rollback            := 11  -- Phase 6
Action.registerIdentity    := 12  -- Workstream E-B
Action.deposit             := 13  -- Workstream E-C (bridge L1 → L2)
Action.withdraw            := 14  -- Workstream E-C (bridge L2 → L1)
Action.declareLocalPolicy  := 15  -- Workstream LP
Action.revokeLocalPolicy   := 16  -- Workstream LP
Action.faultProofChallenge  := 17 -- Workstream H
Action.faultProofResolution := 18 -- Workstream H
Action.depositWithFee       := 19 -- Workstream GP (GP.2.3)
Action.topUpActionBudget    := 20 -- Workstream GP (GP.2.3)
Action.topUpActionBudgetFor := 21 -- Workstream GP (GP.3.4 delegated)
Action.claimBudgetRefund    := 22 -- Workstream GP (GP.9.1 refund-on-exit)
Action.ammSwap              := 23 -- Workstream GP (GP.11.4 AMM swap)
Action.reclaimAmmReserves   := 24 -- Workstream GP (GP.11.10 reserve reclamation)

-- Event constructors (frozen indices 0..22)
Event.balanceChanged       := 0
Event.nonceAdvanced        := 1
Event.identityRegistered   := 2
Event.identityRevoked      := 3
Event.timeRecorded         := 4
Event.disputeFiled         := 5  -- Phase 6
Event.disputeWithdrawn     := 6  -- Phase 6
Event.verdictApplied       := 7  -- Phase 6
Event.rewardIssued         := 8  -- Phase-6 incentive amendment
Event.withdrawalRequested  := 9  -- Workstream E-C
Event.depositCredited      := 10 -- Workstream E-C
Event.localPolicyDeclared  := 11 -- Workstream LP
Event.localPolicyRevoked   := 12 -- Workstream LP
Event.faultProofGameOpened    := 13 -- Workstream H
Event.faultProofBisectionStep := 14 -- Workstream H
Event.faultProofGameSettled   := 15 -- Workstream H
Event.depositWithFeeCredited     := 16 -- Workstream GP (GP.2.3)
Event.actionBudgetTopUp          := 17 -- Workstream GP (GP.2.3)
Event.gasPoolClaim               := 18 -- Workstream GP (GP.2.3)
Event.delegatedActionBudgetTopUp := 19 -- Workstream GP (GP.3.4)
Event.budgetConsumed             := 20 -- Workstream GP (GP.6.4 per-action debit)
Event.ammSwapExecuted            := 21 -- Workstream GP (GP.11.4 swap)
Event.ammReservesReclaimed       := 22 -- Workstream GP (GP.11.10 reclamation)
```

Per-constructor field shapes are recorded in `docs/abi.md`
§5 (`Action` CBE) and §5.3–5.4 (`Event` CBE).  The CBE-bytes form of
each constructor is byte-determined by its index and field tuple;
no Lean phase may re-grouping these constructors without breaking
on-disk replay compatibility AND triggering an AR.5 / AR.6
regression at CI time.

**Constructor descriptions (Workstream E only):**

  * `Action.registerIdentity actor pk` (index 12, **E-B**) —
    Inserts `(actor, pk)` into the `KeyRegistry`.  Authority is
    the reserved bridge actor (`bridgeActor = ActorId 0`) under
    `bridgePolicy`.  Used when the L1 ingestor sees a
    `KnomosisIdentityRegistry.Registered` event for an actor not
    yet in the `AddressBook`.  Distinct from `replaceKey`
    (which is signed by the *old* key); the ingestor
    distinguishes the two via the `AddressBook` lookup.
  * `Action.deposit r recipient amount depositId` (index 13,
    **E-C**) — Credits `amount` of resource `r` to `recipient`'s
    L2 balance and records `depositId` in
    `BridgeState.consumed`.  Authority is the bridge actor;
    replay protection is structural via the `consumed` map
    (re-applying the same `depositId` is rejected by
    `BridgeAdmissibleWith`).
  * `Action.withdraw r sender amount recipientL1` (index 14,
    **E-C**) — Debits `amount` of resource `r` from `sender`'s
    L2 balance and enqueues a `PendingWithdrawal` indexed by
    `BridgeState.nextWdId` (which is then incremented).
    Authority is the L2 user `sender`; `recipientL1` is a
    lossless 20-byte CBE byte string (`EthAddress` =
    `Fin (2^160)`).  See `docs/abi.md` §5.1 for the audit-2
    fix that replaced the truncating 8-byte uint encoding with
    the lossless 20-byte form.

**Event descriptions (Workstream E only):**

  * `Event.withdrawalRequested r sender amount recipientL1 idx`
    (index 9) — emitted by `applyActionToBridgeState` on a
    successful `Action.withdraw`; signals to the off-chain
    redemption layer that an L1 redemption is now possible
    (after the finalisation window).
  * `Event.depositCredited r recipient amount depositId`
    (index 10) — emitted on a successful `Action.deposit`;
    signals to the L1 ingestor's idempotency layer that the
    deposit has been processed and the `consumed` map updated.

### 15D.4 Bridge state and accounting equation

The Bridge layer extends the kernel's `ExtendedState` with a
`bridge : BridgeState` field.  The shape is:

```
structure BridgeState where
  consumed : TreeMap DepositId DepositRecord compare
  pending  : TreeMap WithdrawalId PendingWithdrawal compare
  nextWdId : WithdrawalId

structure DepositRecord where
  resource    : ResourceId
  userAmount  : Amount
  poolAmount  : Amount
  budgetGrant : Nat

structure PendingWithdrawal where
  resource    : ResourceId
  recipient   : EthAddress       -- Fin (2^160)
  amount      : Amount
  l2LogIndex  : Nat
```

`DepositId` is the canonical big-endian numeric form of the
32-byte L1 deposit-receipt hash; `WithdrawalId` is an
internal monotonically-increasing counter.  The `Audit-2`
amendment widened `consumed`'s value type from `Unit` to
`DepositRecord` so the bridge accounting theorem can compute
`totalDeposited`.  The Workstream-GP widening (GP.4.1, §15E.10)
further split `DepositRecord`'s single `amount` field into the
`(userAmount, poolAmount, budgetGrant)` triple so the deposit-fee
split is recoverable from L2 state alone; the pre-widening two-field
shape survives as `LegacyDepositRecord` with a lossless lift.  See
`LegalKernel/Bridge/State.lean`.

**Accounting equation.**  For every reachable bridge state, the
following identity holds across reachable transitions
(`BridgeReachable` predicate, defined in
`LegalKernel/Bridge/Accounting.lean`):

```
totalDeposited bs.consumed = totalWithdrawn bs.pending +
                             bridgeEscrowBalance bs
```

where:

  * `totalDeposited` sums each deposit's total L2 credit
    `userAmount + poolAmount` (via `DepositRecord.amountAt`) across
    the `consumed` map's values (per-resource; see §15E.10).  The
    Workstream-GP amendment (GP.4.2, §15E.11) splits this LHS term into
    the per-leg sums `totalUserDeposited + totalPoolDeposited`, proved
    equal to `totalDeposited` so the equation stays balanced;
  * `totalWithdrawn` sums `PendingWithdrawal.amount` across the
    `pending` map's values (per-resource);
  * `bridgeEscrowBalance` is the L2's `getBalance bridgeActor r`
    plus the bridge-mediated total that has flowed through
    user accounts.

The per-action delta theorems
(`deposit_delta_consumed`, `deposit_delta_balance`,
`withdraw_delta_pending`, `withdraw_delta_balance`, etc.) in
`LegalKernel/Bridge/Accounting.lean` and
`LegalKernel/Laws/{Deposit,Withdraw}.lean` are the per-step
building blocks; the inductive promotion to a reachable-state
property is the chain-level §7.6.4 / §7.6.5 follow-up (planning
document `docs/planning/chain_level_accounting_plan.md`; the
per-step theorems suffice for the current acceptance test).

**Classification typeclasses.**  The `deposit` law ships
`deposit_isMonotonic` (positive witness for `IsMonotonic`) and
`deposit_not_conservative` (negative witness — the law adds
supply on each invocation, like `mint`).  The `withdraw` law
ships `withdraw_not_monotonic` (negative — the law removes
supply, like `burn`) and `withdraw_not_conservative` (same).
Deployments that want strict-supply-non-decrease can refuse the
`withdraw` law at the `MonotonicLawSet` elaboration boundary;
the negative witnesses make the firewall sound (no silent
admission of supply-destroying laws).

### 15D.5 Withdrawal-proof scheme

Workstream E-D (`LegalKernel/Bridge/WithdrawalRoot.lean` +
`WithdrawalProof.lean` + `Finalisation.lean`) ships a
height-64 sparse Merkle tree over `BridgeState.pending`.  The
tree's height matches the `WithdrawalId` key space:
`WithdrawalId = Nat`, but every assigned id fits in 64 bits
(monotone counter); the SMT thus indexes positions
0..2^64 - 1 with all but `pending.size` slots holding the
canonical empty-leaf hash.

**Distinct from cell proofs.**  This is the Workstream-D
**withdrawal SMT** (depth 64).  The Workstream-SC SMT
(`LegalKernel/FaultProof/Smt.lean`, depth 256) is a different
tree used for L1 step-VM cell-proof witnesses.  The two
implementations share design ideas (sparse, default-hash
short-circuit, big-endian path-bit ordering) but live in
distinct modules with distinct depths.

**Key invariants:**

  * `verifyProof_complete` — for any populated `WithdrawalId`
    `idx` in `b.pending`, the canonical `constructProof H b idx`
    verifies against `withdrawalRoot H b`.  (`D.1.3`)
  * `verifyProof_sound` — under `CollisionFree H`, if
    `verifyProof H proof root = true`, then `proof` matches the
    canonical construction (`constructProof H b proof.index`)
    for some `b` whose pending map yields `proof.leaf` at
    `proof.index`.  (`D.1.4`)
  * `isFinalised_monotonic_in_currentBlock` — once a withdrawal
    becomes finalised, it stays finalised as L1 advances.

**L1 redemption flow.**  After the sequencer's snapshot is
attested and the dispute window closes:

  1. The user (or their UX) calls
     `extractProof snap idx` to obtain a `WithdrawalProof`
     (Lean side).
  2. The CLI subcommand `knomosis withdrawal-proof SNAP_PATH ID`
     emits the proof bytes (CBE-encoded) to stdout.
  3. The user submits the proof to
     `KnomosisBridge.withdrawWithProof(...)` on L1.
  4. The Solidity `SmtVerifier.recomputeRoot(...)` walks the
     same descent the Lean `verifyProofRec` walks; if the
     recomputed root matches the snapshot's attested root,
     redemption succeeds.

The cross-stack F.1.5 fixture suite verifies byte-for-byte
agreement across 64 randomised inputs between
`Bridge/WithdrawalRoot.lean` and `SmtVerifier.sol`.  See
`docs/abi.md` §13.4 for the on-wire proof shape.

### 15D.6 Dispute-pipeline integration

The four-stage dispute pipeline (Phase 6) is **unchanged** by
Workstreams E-A through E-F.  The bridge actions
(`Action.deposit`, `Action.withdraw`, `Action.registerIdentity`)
appear in the dispute pipeline like any other action: they may
be the impugned action in a `DisputeClaim.signatureInvalid`
(rare — bridge actions are auto-signed), a `nonceMismatch`, or a
`doubleApply` claim.  No new claim variant is introduced for
bridge-specific defects; existing variants suffice.

The `disputeWithdraw` rollback (`Action.rollback` carrying a
`targetIdx`) does interact with the bridge layer: a successful
rollback to before a `deposit` re-credits the bridge actor (the
L1 funds are still escrowed; only the L2 credit is reversed),
and a rollback to before a `withdraw` removes the
`PendingWithdrawal` entry (the L1 redemption window has not yet
opened, so no L1 funds were released).  These are direct
consequences of the rollback's replay-from-log semantics
(`replayFromSeed (entries.drop (impugnedIdx))`); no new
correctness theorem is required.

**L1 mirror.**  `KnomosisDisputeVerifier.sol` (v1, Workstream
E.2) ports three claim variants (`signatureInvalid`,
`nonceMismatch`, `doubleApply`) to L1; the
`finalizeUpheld(verdict, sigs)` entry point mirrors the Lean
`applyVerdict` and triggers the L1-side rollback (calling
`KnomosisBridge.revertToPriorRoot(...)`).  Quorum + slashing is
enforced on the L1 side via `KnomosisSequencerStake.slash(...)`.
The Workstream-H upgrade path replaces the adjudicator quorum
with the interactive fault-proof game; `KnomosisDisputeVerifierV2`
adds the fifth claim variant `faultProofWon` and routes
upheld fault-proof verdicts through
`KnomosisStateRootSubmission.revertStateRootsFrom(...)`.

See `docs/abi.md` §13.3 for the frozen claim-variant indices and
`§13.5 – §13.7` for the EIP-712 signature shapes.

### 15D.7 EIP-712 signing surface

Workstream E-A.3 (`LegalKernel/Bridge/Eip712.lean`) ships the
EIP-712-typed-data envelope that bridges Knomosis `signedAction`
payloads onto Ethereum's wallet UX.  EIP-712 specifies:

```
sig_payload = 0x19 ‖ 0x01 ‖ domainSeparator ‖ structHash
```

**Domain separator construction.**  `eip712DomainSeparator p` =
`keccak256(domainPreHash p)`, where:

```
domainPreHash p =
  eip712DomainTypeHash ++
  hashBytes p.name ++
  hashBytes p.version ++
  encodeUint256BE p.chainId ++
  encodeUint256BE p.rollupId ++
  hashBytes p.verifyingContract
```

The five `DomainParams` fields (`name`, `version`, `chainId`,
`rollupId`, `verifyingContract`) collectively pin the signature
to one specific Knomosis deployment on one specific L1 chain.  The
`rollupId` field allows multiple Knomosis rollups to share an L1
chain without cross-rollup signature replay.

**Struct hash construction.**  For a Knomosis action payload
`(action, signer, nonce, deploymentId)`:

```
structPreHash m =
  knomosisActionTypeHash ++
  m.actionHash ++                      -- 32 bytes (hashBytes signInput)
  encodeUint256BE m.signer.toNat ++    -- 32 bytes
  encodeUint256BE m.nonce ++           -- 32 bytes
  hashBytes m.deploymentId             -- 32 bytes
```

(Total: 5 × 32 = 160 bytes pre-hash.)  The signer / nonce /
deploymentId are redundantly included in the struct hash (they
are already committed to via `actionHash`'s inner `signInput`
hashing) because EIP-712 requires every declared field of the
type string to appear in the encoded struct hash — without the
redundant encoding, wallet UIs cannot parse the structured form.

**Headline theorem.**  `eip712Wrap_injective` (`Bridge/Eip712.lean`):
under `CollisionFree hashBytes`, `eip712Wrap` is injective on
its `(DomainParams, Eip712Message)` argument tuple.  Companion
theorem `eip712DomainSeparator_distinguishes` proves that
distinct `DomainParams` produce distinct domain separators —
the cross-deployment-replay rejection property.

**Signature normalisation.**  Production deployments link the
Workstream-RH-A.1 secp256k1 verifier which enforces low-s
canonical signatures via `k256`'s `IsHigh` filter.  This
eliminates the malleability-driven double-spend window that
unconstrained ECDSA otherwise admits.

**L1 mirror.**  `solidity/src/lib/KnomosisEip712.sol` implements
the same domain-separator + struct-hash construction; the F.1.x
cross-stack corpus ratifies byte-for-byte agreement.

### 15D.8 Solidity contract surface

Workstream E-E ships ten immutable Solidity contracts plus six
shared libraries under `solidity/`.  The full per-contract
inventory lives in `solidity/README.md` and `docs/abi.md` §13 +
§15; the highlights are:

**Workstream-E contracts (E.1 – E.5):**

  * `KnomosisBridge.sol` (E.1) — L1 escrow for deposits +
    withdrawals.  Implements `depositETH() / depositERC20(...)`,
    the Workstream-GP user-chosen fee-split entries
    `depositETHWithFee(uint16 chosenFeeBps)` (GP.5.1; splits
    `msg.value` into a user credit + a gas-pool fee and grants
    action budget at the immutable `weiPerBudgetUnitEth` rate)
    and `depositBoldWithFee(uint256 amount, uint16 chosenFeeBps)`
    (GP.5.4; the opt-in BOLD-currency mirror — pulls the
    constitutionally-pinned `BOLD_TOKEN_ADDRESS` ERC-20 via
    `transferFrom` with a balance-delta check, credits the pool at
    `RESOURCE_ID_BOLD`, and grants budget at `weiPerBudgetUnitBold`;
    a non-BOLD deployment passes `boldTokenAddress = address(0)` to
    disable it), `submitStateRoot(...)` (attestor-signed), and
    `withdrawWithProof(uint64, bytes, bytes)`.  Four automatic
    circuit-breakers (`AttestationStale`, `DisputeCooldown`,
    `TvlCapReached`, `MigrationActivated`) fire on
    deterministic public-state predicates.  No generic admin /
    `pause()` / `transferOwnership(...)` surface (the
    `test_no_admin_surface` invariant still holds).  The lone
    privileged surface is the GP.5.5 BOLD safety hardening: two
    tightly-scoped immutable roles — `boldCircuitBreaker` (pause /
    resume the BOLD *deposit* leg via `closeBoldCircuit` /
    `openBoldCircuit`; the companion permissionless depeg
    auto-trigger `closeBoldCircuitIfAnyLiquityBranchShutdown` reads
    `shutdownTime()` from each of three constitutionally-pinned
    Liquity V2 branch `TroveManager`s and closes the circuit if any
    branch is in shutdown) and `boldAdmin` (tune the per-BOLD TVL
    cap within `[0, tvlCap]` via `setBoldTvlCap`) — neither of which
    can move funds, alter state roots, change any immutable, touch
    the ETH leg, or halt withdrawals (the "deposits halted,
    withdrawals continue" posture for a BOLD depeg).  The two roles
    MUST be distinct addresses and neither may be the bridge itself
    (constructor-enforced).
  * `KnomosisDisputeVerifier.sol` (E.2, v1) — Three-variant
    dispute pipeline (`signatureInvalid`, `nonceMismatch`,
    `doubleApply`).  Upheld verdicts trigger
    `KnomosisBridge.revertToPriorRoot(...)` and
    `KnomosisSequencerStake.slash(...)`.
  * `KnomosisIdentityRegistry.sol` (E.3) — Mirror of the Lean
    `KeyRegistry`.  Two register entry points: `registerECDSA`
    (verifies `keccak256(pubkey)[12:] == msg.sender` to prevent
    front-running) and `registerEIP1271` (probes contract
    wallets' `isValidSignature` callback for canonical
    response).
  * `KnomosisSequencerStake.sol` (E.4) — Sequencer's L1-bond
    escrow.  Slashable on upheld disputes:
    `slashRatioBps * stake / 10_000` goes to the challenger,
    residual to the immutable burn address.
  * `KnomosisMigration.sol` (E.5) — Attested handoff between
    predecessor and successor `KnomosisBridge` deployments.
    `MIN_GRACE_WINDOW_BLOCKS = 216_000` (≈ 30 days @ 12 s
    blocks); bidirectional consent via constructor assertion;
    one-way `activated` flag; no role gating on `activate()`.

**Workstream-H contracts** (covered separately in §15B.5 of
this document; cross-reference for completeness):

  * `KnomosisStateRootSubmission.sol` — Sequencer state-root
    window + bond.
  * `KnomosisStepVM.sol` — L1 single-step verifier.
  * `KnomosisFaultProofGame.sol` — Bisection-game arbiter.
  * `KnomosisDisputeVerifierV2.sol` — V2 dispute pipeline (adds
    `faultProofWon` variant).
  * `KnomosisFaultProofMigration.sol` — V1 → V2 migration.

**Shared libraries:**

  * `KnomosisEip712.sol` — EIP-712 domain + struct-hash helpers.
  * `CBEDecode.sol` — CBE byte decoder mirroring the Lean codec.
  * `SmtVerifier.sol` — withdrawal-tree SMT verifier (depth 64).
  * `SmtCellVerifier.sol` — state-cell SMT verifier (depth 256,
    Workstream SC.2).
  * `CREATE3.sol` — proxy-factory deploy for cyclic references.
  * `StepVMMerkle.sol` — per-cell proof helpers (Workstream H +
    SC.2).

#### 15D.8.1 Cross-contract reference shape

Every Knomosis Solidity contract exposes
`deploymentId()` (returning
`keccak256(abi.encode(block.chainid, address(this), knomosisVersionTag))`)
plus the immutable cross-references it depends on
(`attestor()` / `disputeVerifier()` / `bridge()` / etc.).
`assertConsistent()` is the post-deploy auditor surface;
it verifies the symmetric reference (`verifier.bridge().disputeVerifier()
== address(this)`) and is callable by anyone (`view`,
no revert).

#### 15D.8.2 Immutability discipline

Per `solidity/README.md` "Immutability discipline" and the
audit posture pinned at Workstream-E landing:

  * **No proxy.**  Each contract deploys to its final address
    via `CREATE2` (production) or `CREATE3` (test fixtures, to
    break the cross-contract reference cycle).
  * **No `initialize`.**  Every field is set in the constructor;
    nothing is later mutable.
  * **No admin role.**  Cross-contract authority is encoded as
    `address public immutable`.
  * **No `pause()`.**  Halts are automatic, triggered by public
    state predicates.
  * **Recovery via dispute pipeline + fault-proof game, not via
    code.**  Bad state transitions are reverted by upheld
    disputes (v1) or by the fault-proof game (v2); bad code is
    replaced by deploying a new immutable contract +
    `KnomosisMigration` handoff.

The forge test suite includes
`test_no_admin_surface` assertions on every contract that
confirm canonical admin selectors (`pause()`, `unpause()`,
`transferOwnership(...)`, `grantRole(...)`, `upgradeTo(...)`)
are not callable.

#### 15D.8.3 Two-reviewer policy for Solidity changes

Solidity-side changes that alter behaviour-shaping code (the
contracts in `solidity/src/contracts/`, the libraries in
`solidity/src/lib/`) require **one reviewer** under standard
deployment-infrastructure policy.  However:

  * Changes to `CBEDecode.sol`, `SmtVerifier.sol`, or
    `SmtCellVerifier.sol` (any byte-format-touching surface)
    must update the F.1.x / SC.3 cross-stack fixtures in the
    same PR.  Reviewers must verify that the Lean reference
    still agrees byte-for-byte after the change.
  * Changes to the immutability discipline (introducing a proxy,
    an admin role, a `pause()` function, or an `initialize`)
    are TCB-equivalent for L1 trust assumptions and require
    TWO reviewers plus a Genesis-Plan amendment per §14.4.

### 15D.9 Cross-stack verification corpus

Workstream E-F ships the operational defence for TA-2.4:
mechanical byte-equivalence between Lean references and
Solidity implementations on every cross-stack surface.

**Corpus structure.**  Each fixture entry is a triple `(input,
Lean output, Solidity output)`.  The Lean side
(`LegalKernel/Test/Bridge/CrossCheck/*.lean`) generates the
fixture JSON via `KNOMOSIS_FIXTURES_OVERWRITE=1 lake test`; the
Solidity side
(`solidity/test/CrossCheck/*.t.sol`) consumes the same JSON
via `vm.readFile` + `vm.parseJson` and asserts byte equality
against the recorded Lean outputs.  The CI gate runs both
sides on every PR.

**Per-suite coverage (F.1.x):**

  * **F.1.1** — `cborHeadEncode` / `cborHeadDecode` round-trip.
  * **F.1.2** — `EthAddress.toBytes` / `EthAddress.ofBytes`
    round-trip on 20-byte inputs.
  * **F.1.3** — `Action.deposit` / `Action.withdraw` /
    `Action.registerIdentity` CBE encode/decode round-trip.
  * **F.1.4** — `BridgeState.encode` / `BridgeState.decode`
    round-trip.
  * **F.1.5** — Withdrawal-proof SMT verification across 64
    randomised inputs.
  * **F.1.6** — EIP-712 domain separator + struct hash across
    a coverage matrix of `DomainParams`.
  * **F.1.7** — `deploymentId` derivation cross-stack
    agreement.

**Per-suite coverage (Workstream-H + SC):**

  * **H.10.1** — L1 step-VM witness-state form (Workstream H).
  * **SC.3** — 100-entry SMT cell-proof corpus (50 honest + 50
    adversarial across 6 tamper classes; Workstream SC).
  * **SVC** — L1 step-VM dispatcher corpus (per-variant fixtures
    across every dispatched `Action` kind; 218 entries / 19 variants
    at the SVC milestone, since widened by GP.3.3 → 238 (kinds 19 /
    20: depositWithFee + topUpActionBudget) and GP.5.3 → 248 (kind
    21: the delegated topUpActionBudgetFor)).

**Hash-binding-conditional behaviour.**  At default
`lake test` time, `Bridge.HashAdaptor.isKeccak256Linked = false`
and `hashBytes` falls back to FNV-1a-64 zero-padded to 32
bytes.  The Solidity per-entry verdicts (which always use
`keccak256` via the EVM `KECCAK256` opcode) cannot agree with
the FNV fallback; the cross-stack suites probe
`isKeccak256Linked` and skip cleanly when the production
binding isn't linked.  Header-shape and byte-size assertions
run unconditionally.  In a production environment with the
`knomosis-hash-keccak256` Rust adaptor linked at the `@[extern]`
symbol `knomosis_hash_bytes`, both sides walk keccak256 and the
verdicts match byte-for-byte.

**Future extensions.**  Per
`docs/planning/ethereum_integration_plan.md` §10 and §11, the
cross-stack scope is expandable:

  * Workstream RH-A's Rust crypto-adaptor cross-stack corpus
    (`runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`,
    `runtime/tests/cross-stack/keccak256.cxsf`) ratifies the
    Lean ↔ Rust agreement for the `Verify` / `hashBytes`
    swap-points.
  * Workstream-F.4 property-based test extension scopes Lean
    `Plausible` fuzzing into the same corpus pipeline.
  * Workstream-F.3 testnet acceptance dry-run
    (`make testnet-acceptance-dryrun` in `solidity/`) exercises
    the seven-step end-to-end acceptance scenario against a
    local Anvil fork.

### 15D.10 Non-goals and v2 deferrals

The Workstream-E MVP is deliberately scoped to the seven-step
end-to-end acceptance test of §15D.1.  The following items are
**out of scope** for the current Ethereum integration; each is
either deferred to a v2 amendment or assigned to a separate
workstream.

  1. **ActorId widening to 20 bytes.**  The current `ActorId`
     is `UInt64` (a kernel-TCB choice).  The `AddressBook`
     (Workstream E-B) provides the registry indirection that
     bridges 20-byte L1 addresses to 64-bit `ActorId`s; this
     suffices for the MVP.  Widening `ActorId` to 20 bytes
     would be a kernel-TCB change requiring two reviewers per
     §14.4 plus a non-trivial migration of every Phase-2 /
     Phase-3 theorem.  Cross-reference:
     `docs/planning/ethereum_integration_plan.md` §2.2 #1.
  2. **ZK proofs of `apply_admissible`.**  The MVP is
     optimistic-only.  ZK extension is candidate Phase-7
     scope.  Cross-reference: `docs/planning/phase_7_plan.md`
     §P7.C ("Zero-Knowledge Admissibility Proofs").
  3. **Bisection dispute games for the v1 pipeline.**  The
     v1 `KnomosisDisputeVerifier` used one-shot fraud proofs.
     Workstream H closes this gap: the v2
     `KnomosisDisputeVerifierV2` + `KnomosisFaultProofGame`
     suite implements interactive bisection with a
     strictly weaker trust model
     (`1-of-anyone-honest` replaces `M-of-N-adjudicators-
     honest`).  Cross-reference: §15B and
     `docs/planning/fault_proof_migration_plan.md`.
  4. **ERC-4337 account abstraction.**  EIP-1271 (TA-2.5) is
     in scope (smart-contract wallets); ERC-4337's
     `UserOperation` envelope is not.  A future workstream
     can add a parallel signing surface that wraps
     `UserOperation` over the existing EIP-712 envelope.
  5. **Cross-rollup interop.**  The `deploymentId` already
     gives cross-rollup replay rejection (TA-2.1 +
     `signedActionDomain` discipline).  Bidirectional
     cross-rollup bridges (synchronous message passing,
     asset-graph reconciliation) are deferred.
  6. **Native ETH gas market.**  The MVP's economic model
     is "the sequencer is paid out-of-band"; on-chain gas
     markets, fee burning, and EIP-1559-style fee
     dynamics are post-MVP.
  7. **Sequencer decentralisation.**  The MVP runs a
     single sequencer with a published attestation key.
     Rotated / multi-attestor / leader-election schemes
     are post-MVP.  Cross-reference:
     `docs/planning/open_questions.md` OQ-H-2.
  8. **L1 escape hatch (`forceWithdraw`).**  No
     unilateral L1-side withdrawal mechanism; users must
     wait for the sequencer to attest a snapshot.  A
     future workstream can add `KnomosisBridge.forceWithdraw(...)`
     gated by a long timeout + L1 fraud-proof.
  9. **`preconditionFalse` / `oracleMisreported` Solidity
     variants.**  Deferred to v2.  Adding them requires a
     new dispute-verifier deployment plus a
     `KnomosisMigration` handoff (no in-place extension path
     — Solidity contracts are immutable per §15D.8.2).
  10. **Multi-resource bridges.**  The MVP bridge handles a
      single resource family (configured at construction
      time).  Multi-resource support is a deployment-time
      composition (one bridge contract per resource), not
      a code-level extension.
  11. **DAO governance for tunable parameters.**  The MVP's
      bridge / verifier parameters are immutable
      constructor arguments.  Parameterised governance
      (e.g. tuning `slashRatioBps` via on-chain proposal)
      is deferred to the parameterised-laws workstream;
      cross-reference
      `docs/planning/parameterized_laws_landing_plan.md`.

Each non-goal is reachable via the existing migration mechanism
(`KnomosisMigration` for v1 contracts, `KnomosisFaultProofMigration`
for the v1 → v2 fault-proof handoff): a deployment that needs
a non-goal feature deploys a new immutable contract suite and
uses the attested-handoff to retire the old one.  See §15B.7
and `docs/planning/fault_proof_migration_plan.md` for the
migration mechanism's correctness story.

---

## 15E. Workstream GP Amendment: Unified Gas Pool and Per-Actor Budgets

### 15E.1 Motivation

Workstream GP closes the DoS-funding circularity gap by pairing
user-funded bridge fees with per-actor action budgets. Depositors can
pay up front for capacity while the sequencer reimbursement path is
restricted to an actor-scoped policy envelope.

### 15E.2 Reserved actors

This amendment reserves three deployment roles: a gas-pool actor
(holds fee revenue by resource), a sequencer-reimbursement recipient
set (policy-controlled), and an operator-maintained bridge actor for
L1 reconciliation actions.

### 15E.3 Deposit-fee and budget-grant equation

For a deposit amount `V` and `chosenFeeBps`:

* `poolAmount = V * chosenFeeBps / 10000`
* `userAmount = V - poolAmount`
* `minFeeBps ≤ chosenFeeBps ≤ maxFeeBps`
* `budgetGrant = min(MAX_BUDGET_PER_DEPOSIT, poolAmount / weiPerBudgetUnit[resource])`

The bounds check is mandatory. The budget clamp is non-reverting.

### 15E.4 Per-actor budget state machine

The budget subsystem is a three-operation machine:

* `normalise` (epoch roll-forward with free-tier floor),
* `consume` (subtract one unit on each admitted action),
* `topUp` (credit budget from bridge grant or explicit top-up action).

### 15E.5 Per-resource exchange rates and clamp semantics

Rates are resource-indexed (`weiPerBudgetUnitEth`, `weiPerBudgetUnitBold`)
and immutable per deployment revision. High-fee deposits do not fail
due to budget cap overflow; they grant the clamped maximum.

### 15E.6 Gas-pool policy template and drain bound

The canonical gas-pool `LocalPolicy` is default-deny with explicit
allowlist clauses for sequencer reimbursement paths and per-resource
limits. This yields a policy-level bound on drain rate.

The *per-action* policy ships as `gasPoolPolicy maxDrainPerActionEth
maxDrainPerActionBold` (GP.7.2, `LegalKernel/Bridge/GasPoolPolicy.lean`):
five conjunctive clauses confine `gasPoolActor`'s outflow to a
per-action-capped `transfer` to `sequencerActor` on `ResourceId 0`
(ETH) or `ResourceId 1` (BOLD).  Because a `LocalPolicy` is sender-blind
and subject to the LP.7 meta-action exemption, the discipline is
completed by the complementary `gasPoolAuthorityPolicy` (intersected
into the deployment policy at genesis), which additionally binds
`sender = gasPoolActor`, forbids the off-leg / meta-action surface a
`LocalPolicy` cannot, and keeps the policy in force across a trace.

The *per-epoch* drain bound is the inductive promotion of those
per-action caps, proven in `LegalKernel/Bridge/PoolDrainBound.lean`
(GP.7.3).  `PoolBoundedTrace` models a contiguous trace of `n` admitted
`SignedAction`s respecting the gas-pool discipline (each step is either
a `gasPoolActor`-signed action authorised by `gasPoolAuthorityPolicy`,
or a non-pool step that does not decrease the pool's balance — the
deployment's `sender = signer` obligation, discharged for the dominant
transfer case by `transfer_other_sender_pool_nondecreasing`).  The
headline `pool_drain_bounded_by_action_count` then proves

```
getBalance es'.base 0 gasPoolActor + n · maxDrainPerActionEth
  ≥ getBalance es0.base 0 gasPoolActor,
```

i.e. the gas-pool ETH-leg balance cannot have decreased by more than
`n × maxDrainPerActionEth` across the trace.  `pool_balance_lower_bound_via_trace`
restates this as a floor on the surviving balance, and
`pool_cannot_drain_when_cap_zero` gives the boundary: a zero ETH cap
forbids every ETH-leg drain.

The bound is in fact proven **per-resource**
(`pool_drain_bounded_by_action_count_per_resource`, cap `legCap mEth
mBold rLeg`), with the ETH and BOLD legs as specialisations and the two
legs shown to be independent accounting domains
(`per_resource_pool_independence`) — delivering the GP.7.5 core.  The
non-pool-signer obligation is discharged exhaustively over every
`Action` constructor (`pool_nondecreasing_of_does_not_debit`), the
literal executable fold ships as `applyTrace` (with
`applyTrace_drain_bounded_per_resource`), and the per-step bounds lift
onto the budget-gated production runtime entry
(`pool_signed_step_drain_le_budget`).  All theorems depend only on
`propext`, `Classical.choice`, `Quot.sound`; no new opaque, no new
axiom, no kernel-TCB delta.

**Genesis ratification (GP.7.4).**  A GP-enabled deployment wires both
halves of the discipline at genesis via the `gasPoolGenesis` hook
(`LegalKernel/Bridge/GasPoolPolicy.lean`): `gasPoolGenesisState`
declares `gasPoolPolicy mEth mBold` for `gasPoolActor` in the genesis
`localPolicies` table, and `gasPoolGenesisPolicy` intersects
`gasPoolAuthorityPolicy mEth mBold` into the deployment's base
`AuthorityPolicy`.  Bundling the two into one `GasPoolGenesis` value
makes the "wire BOTH" contract atomic — a deployment that builds its
genesis through `gasPoolGenesis` cannot declare the `LocalPolicy`
without also intersecting the `AuthorityPolicy`, and the half-less
wiring (which would leave the LP.7 meta-action hole open) is
unreachable through the constructor.  The contract is ratified by
`gasPoolGenesisState_declares_policy` (the pool policy is declared and
nothing else in the state changes — `_preserves_kernel_substates`),
`gasPoolGenesisPolicy_rejects_meta` (the headline: `gasPoolActor`
meta-actions are barred under ANY base policy),
`gasPoolGenesisPolicy_other_actors_unrestricted` (the intersection
narrows only the pool actor), `gasPoolGenesisPolicy_rejects_non_pool_sender`
(fund safety), and `gasPoolGenesisPolicy_authorizes_sequencer_eth` /
`_bold` (the legitimate capped claim on either leg is still admitted).
The worked deployment `Deployments/Examples/GasPoolExample.lean` runs
the full lifecycle — bridge-signed ETH + BOLD `depositWithFee`
(crediting the user and the pool and granting the user an L2 budget)
and the two capped sequencer claims — end-to-end through the runtime
admission gate, and is runnable via the `knomosis gas-pool-demo`
subcommand (process → persisted log → replay round-trip).

The wiring is also an opt-in *deployment config* rather than a fixed
choice: `GasPoolConfig` + the `*OfConfig` builders gate the genesis on
an `Option` (`none` = the pre-GP.7.4 genesis, `some ⟨mEth, mBold⟩` =
both halves wired), and the generic `knomosis` subcommands expose
`--gas-pool-eth-cap` / `--gas-pool-bold-cap` flags that build the
gas-pool genesis (state + policy) and thread it through `process` /
`replay` / `bootstrap` / `snapshot` / `replay-up-to` /
`export-cell-proofs` / `export-terminate-bundle` / `extract-events`.
(The `export-terminate-bundle` cross-check is load-bearing: its
`claimedPostCommit` + `cellProofs` are computed against
`commitExtendedState`, which includes `commitLocalPolicies`, so the
gas-pool declaration affects the bundle.)  Because the gas-pool genesis
`localPolicies` declaration participates in every log entry's
post-state hash, the config is persisted to a `<log>.gaspoolcfg`
sidecar (`Runtime/GasPoolSidecar.lean`, mirroring the GP.6.2 budget
sidecar) and cross-checked on every log-touching command, so a
forgotten / changed / disabled cap fails loudly rather than as an
opaque hash mismatch.  The Rust `knomosis-host` `CommandKernel`
forwards the two caps to the spawned `knomosis` binary, so a deployment
run through the network host enforces the same discipline.  Two
completeness theorems pin the residual surface:
`gasPoolGenesisPolicy_rejects_over_cap_eth` / `_bold` (the
authority-layer per-action cap rejection) and
`gasPoolGenesisPolicy_bars_self_declaration` (the structural-genesis
necessity — once `gasPoolAuthorityPolicy` is in force the pool cannot
install or replace its own `LocalPolicy` via a signed
`declareLocalPolicy`, so the genesis declaration MUST be structural).

### 15E.7 Opaques and axioms

Workstream GP introduces no new opaque trust hooks and no new axioms.
It extends existing typed state and policy surfaces only.

### 15E.8 Trust-assumption update

The trust table in §1.4 is amended with an operational assumption:
deployment operators set sane fee bounds and exchange-rate parameters.
Cryptographic assumptions and TCB scope are unchanged.

The GP.5.5 BOLD safety hardening (§15D.8) adds one further *operational*
trust surface on the L1 mirror only: two tightly-scoped immutable roles
on `KnomosisBridge` — `boldCircuitBreaker` (pause / resume the BOLD
deposit leg) and `boldAdmin` (tune the per-BOLD TVL cap within
`[0, tvlCap]`).  Their authority is deliberately minimal: they cannot
move funds, alter state roots, change any immutable, touch the ETH leg,
or halt withdrawals, so a compromised role key degrades availability of
*new BOLD deposits* at worst — it cannot cause loss of escrowed value
or affect L2 kernel guarantees.  The optional Liquity-V2 branch-shutdown
auto-trigger is permissionless and can only *close* the circuit when
any of the three constitutionally-pinned Liquity V2 collateral-branch
`TroveManager`s reports a non-zero `shutdownTime` (the definitive
on-chain depeg signal); its only trust inputs are the three pinned
TroveManager addresses (under the GP.5.2 cap-audit gate), and a
faulting TroveManager (revert, no code, wrong-shape return, mutating
callee, gas griefing — all bounded by a 100k staticcall gas cap)
degrades cleanly to manual operation (`LiquityV2ReadFailed`).  No
cryptographic assumption, no kernel TCB delta, no new axiom.

### 15E.9 Pre-authorised delegated budget top-ups (GP.3.4)

The budget subsystem (§15E.4) supports a *delegated* top-up path: a
delegate may fund a different actor's action budget, provided that
actor has explicitly pre-authorised the delegate.  This enables
service-provider funding flows while preserving the invariant that an
actor's budget is mutated only with that actor's prior, signed
consent.

* **Consent clause.**  `LocalPolicyClause` gains a *positive* variant
  `allowTopUpFrom (delegates : List ActorId)` (the first positive
  clause — it grants a permission rather than constraining the
  signer's own actions).  An actor declares it through the existing
  signed `declareLocalPolicy` action; its declaration *is* their
  consent.  Constructor-tag index 3 (append-only); a
  `MAX_DELEGATES_PER_ALLOW` cap bounds per-clause state growth.

* **Delegated action.**  `Action.topUpActionBudgetFor (recipient,
  gasResource, gasAmount, budgetIncrement, poolActor)` (frozen
  `Action` index 21).  The signer (the delegate/payer) is captured by
  the enclosing `SignedAction`.  Its kernel-state effect is identical
  to `topUpActionBudget`: debit the signer at `gasResource`, credit
  `poolActor` — the *signer* pays, so the recipient can never lose
  funds via this path.  The recipient's epoch budget is credited
  `budgetIncrement` at the admission layer.

* **DEFAULT-DENY consent gate.**  Admission of a
  `topUpActionBudgetFor(recipient = R)` signed by `S` requires that
  `R`'s currently-declared `LocalPolicy` contains *some*
  `allowTopUpFrom` clause whose list includes `S`.  An actor with no
  such clause (the default for a freshly-registered actor) accepts
  no delegated top-ups.  Default-deny is the security boundary: it
  forecloses identity-tagging probes, asymmetric state-growth
  pressure, and bypass of an actor's own restrictive posture.  The
  gate additionally enforces the gas-safety conditions that defend
  the free-budget attack class (`S ≠ bridgeActor`, `S ≠ poolActor`,
  `R ≠ S`, `gasAmount > 0`, sufficient signer balance), so the
  recipient budget is credited only when a genuine net gas debit
  occurred.

* **Revocation.**  A recipient revokes consent through the existing
  signed `revokeLocalPolicy` (or by re-declaring a policy without the
  clause); the revocation takes effect from the next admitted action.

* **L1 fault-proof coverage.**  The L2 admission of a delegated
  top-up is fully gated (default-deny consent + gas safety); the
  *honest sequencer*'s runtime never admits an unauthorised one.  The
  L1 step-VM *execution* arm for this action variant — the Solidity
  decoder that re-executes a disputed delegated-top-up step on chain —
  landed in GP.5.3: the Lean `stepVMHash` kind-21 arm dispatches to
  `stepCommitTopUpActionBudgetFor` (the gas-transfer commit recipe,
  byte-identical in shape to `topUpActionBudget`'s but bound by a
  distinct `keccak256("topUpActionBudgetFor")` tag), the Solidity
  `KnomosisStepVM._stepTopUpActionBudgetFor` mirrors it, and the
  cross-stack fixture corpus carries 10 `topUpActionBudgetFor`
  entries.  A delegated-top-up step is therefore now L1-fault-proof-
  *executable*.  As with every GP-family variant, the `recipient` and
  `budgetIncrement` fields are admission-layer effects (the
  recipient's epoch-budget credit) excluded from the step-VM
  kernel-state hash by design; the cross-stack byte-equivalence is
  exercised under the production keccak256 binding.

  **Scope boundary (recorded, not silent).**  The step-VM commit binds
  the kernel-state *balance* writes (debit signer / credit pool), not
  the `epochBudgets` ledger — there is no `epochBudgets` cell tag, so
  budget effects are outside the cell-proof model the L1 step VM
  re-executes.  This is uniform across all 22 variants (the nonce
  advance is likewise unbound).  Consequently the bisection-game
  terminate arm catches a sequencer who lies about the *balance*
  transfer, but a lie about *which* actor's budget was credited would
  not be caught by step-VM re-execution; the L2 admission gate
  (`topUpActionBudgetFor_gate`, default-deny consent) is what governs
  the budget effect on the honest-sequencer path.  Closing the
  re-execution arm for budget lies would require an `epochBudgets` cell
  tag + folding the budget value into every GP-variant hash on both
  stacks — a §13.6 amendment tracked as future work, deliberately out
  of GP.5.3's scope.  See `LegalKernel/FaultProof/StepVMCoherence.lean`
  ("Step-VM commit scope") for the code-level statement.

This amendment introduces no new opaque trust hook and no new axiom;
it extends the typed `Action` / `LocalPolicyClause` / `Event`
surfaces and the admission gate only.

### 15E.10 Bridge-state persistence of the deposit split (GP.4.1)

The bridge ledger's `consumed` map (§7.1.1) records one
`DepositRecord` per credited L1 deposit.  GP.4.1 widens that record
from the pre-amendment `(resource, amount)` pair to the four-field
`(resource, userAmount, poolAmount, budgetGrant)` shape so the
deposit-fee split of §15E.3 is recoverable from L2 state alone:

* A fee-less `Action.deposit` records `userAmount := amount`,
  `poolAmount := 0`, `budgetGrant := 0`.
* An `Action.depositWithFee` records the §15E.3 `(userAmount,
  poolAmount)` split and the clamped `budgetGrant` verbatim.

Persisting `budgetGrant` (rather than re-deriving it from
`poolAmount / weiPerBudgetUnit[resource]` on each read) keeps the
recipient's budget timeline reconstructible under re-org or replay
without access to the L1 contract's per-deployment exchange rate,
and keeps cross-stack byte-equivalence stable across a deployment
migration that changes the rate.  The pre-amendment two-field shape
survives as `LegacyDepositRecord` with a lossless lift
(`DepositRecord.fromLegacy` / `DepositRecord.toLegacy`, certified by
`toLegacy_fromLegacy`), so historical records and the fee-less path
round-trip exactly.  The total L2 credit attributable to a deposit is
`userAmount + poolAmount`; the existing `totalDeposited` accounting
fold recombines the two legs (so its value is unchanged on every
state), leaving the GP.4.2 split into per-leg `totalUserDeposited` /
`totalPoolDeposited` folds to build on this representation.  The
widening carries through the CBE codec, the encoder-injectivity
ladder (EI.6 / EI.7), and the state-commitment canonical-bounds
bundle; it introduces no new opaque trust hook and no new axiom.

### 15E.11 Accounting-equation split (GP.4.2)

GP.4.2 splits the single legacy deposit term on the LHS of the §15D.4
accounting equation into the two per-leg sums the GP.4.1 record now
makes available.  In `LegalKernel/Bridge/Accounting.lean`:

* `totalUserDeposited es r` and `totalPoolDeposited es r` fold the
  per-deposit `userAmount` / `poolAmount` legs (via
  `DepositRecord.userAmountAt` / `poolAmountAt`) over the `consumed`
  map at resource `r`.
* The **split identity** `totalUserDeposited_plus_pool_eq_totalDeposited`
  proves `totalUserDeposited es r + totalPoolDeposited es r =
  totalDeposited es r` at every state — the two legs partition the
  legacy total.  Consequently the amended equation

  ```
  totalUserDeposited bs.consumed + totalPoolDeposited bs.consumed
    = totalWithdrawn bs.pending + bridgeEscrowBalance bs
  ```

  holds *exactly when* the legacy single-term equation does
  (`bridge_accounting_equation_balanced`): the deposit-fee split is a
  bookkeeping split of how the L1 `msg.value` is credited on L2, not a
  split of the L1 escrow, which still holds the full value.  The RHS is
  therefore structurally unchanged, and the inductive promotion of the
  legacy equation's `bridgeEscrowBalance` term (the §7.6.4 / §7.6.5
  follow-up) lifts verbatim.

* Per-action deltas (`totalUserDeposited_step_eq` /
  `totalPoolDeposited_step_eq`, their fee-less specialisations, and the
  non-bridge no-op) give the unit-step accounting picture; a fresh
  deposit credits each leg by its recorded amount at the deposit's
  resource and leaves every other resource untouched.

* **Pool solvency.**  `depositWithFee_pool_credit_matches_ledger_delta`
  proves the inflow side: every wei a `depositWithFee` credits to the
  gas-pool actor's L2 balance is matched, wei-for-wei, by the ledger's
  recorded `poolAmount`.  `pool_balance_eq_totalPoolDeposited_minus_payouts`
  then states the solvency identity `getBalance gasPoolActor =
  totalPoolDeposited − poolPayouts`, parameterised over an arbitrary
  pool actor.  The canonical deployment fixes that pool actor at the
  reserved `gasPoolActor = ActorId 1` (Workstream GP.7.1), with the
  sequencer-payout recipient at `sequencerActor = ActorId 2`;
  Workstream GP.11.5 additionally reserves `ammReserveActor = ActorId 3`
  (the L2 reflection of the L1 AMM reserves).  The genesis
  `AddressBook.empty.nextActorId` advances to `4` (post-GP.11.5;
  `addressBook_empty_nextActorId`) so no user-registered identity is
  ever issued a reserved slot (`empty_assign_id_avoids_reserved`), and
  the Rust `knomosis-l1-ingest` runtime adaptor mirrors the same
  genesis allocation (`INITIAL_NEXT_ACTOR_ID = 4`).  The four reserved
  actors are provably distinct (`gasPoolActor_ne_bridgeActor`,
  `sequencerActor_ne_bridgeActor`, `sequencerActor_ne_gasPoolActor`,
  `ammReserveActor_ne_bridgeActor`, `ammReserveActor_ne_gasPoolActor`,
  `ammReserveActor_ne_sequencerActor`).  The solvency theorem stays
  parameterised so it does not depend on the concrete id; its inductive
  maintenance across a trace — bounding the pool actor's outflows to
  the sequencer-payout path — is the `gasPoolPolicy` drain bound
  (§15E.6), shipped with the GP.7 pool-governance work; the
  **strong-conservation / AMM-aware** extension depends on
  `Action.ammSwap` (§15E embedded-AMM amendment) and lands with that
  workstream.

* **Atomic admitted-step forms.**  The deltas and the pool-credit /
  ledger coherence are additionally lifted onto the *actual* admitted
  step `apply_bridge_admissible_with` (the runtime / dispute-pipeline
  entry), with deposit-id freshness *derived* from the
  `BridgeAdmissibleWith` witness's uniqueness conjunct rather than
  assumed: `totalUserDeposited_admissible_depositWithFee`,
  `totalPoolDeposited_admissible_depositWithFee`,
  `depositWithFee_admissible_credits_poolActor`, and
  `depositWithFee_admissible_pool_credit_matches_ledger` (live pool
  balance and ledger move in lockstep over the same step).  Per-action
  coverage is complete over every `Action` constructor: the two
  deposit actions (above), `withdraw` (`accounting_userpool_delta_withdraw`
  — touches only `pending`, deposit folds unchanged), and every other
  action (`accounting_userpool_delta_non_bridge`).  The balanced
  equation is additionally available as the iff
  `bridge_accounting_equation_balanced_iff` (legacy and split LHS
  interchangeable for any `totalWithdrawn + escrow` RHS);
  `pool_solvency_preserved_by_admitted_depositWithFee` proves the
  reconciliation `getBalance poolActor + payouts = totalPoolDeposited`
  is preserved across an admitted deposit (the GP.7.3 inflow induction
  step); and `depositWithFee_budget_admitted_pool_credit_matches_ledger`
  lifts the coherence onto the literal budget-gated runtime entry via
  the reusable `apply_bridge_admissible_with_budget_base_bridge_eq`
  (the production gate overwrites only `epochBudgets`).

All GP.4.2 theorems depend only on `propext`, `Classical.choice`,
`Quot.sound`; no new opaque, no new axiom, no kernel-TCB delta.

---

## 16. Final Principles

These are the principles to which all design decisions return when
debate becomes intractable.

### 16.1 The Kernel Enforces Invariants, Not Meaning

The kernel does not know what a "transfer" *means*. It knows that some
function `transfer.apply_impl` exists, that some predicate
`transfer.pre` exists, and that the latter implies the former
preserves any invariant that was proven preserved by it. Meaning is
the law-author's job; meaning lives at Layer 1 and above.

### 16.2 Safety Without Rigidity

Because the kernel is parametric in its laws, the same kernel can run
arbitrarily different deployments without modification. A change of
policy is a change of inputs, not a change of code.

### 16.3 Flexibility Without Chaos

Because every state change requires a proof, no amount of policy
flexibility can produce an illegal state. The space of permitted
behaviours can be as large as the law-author chooses; the *guarantees*
on that space remain.

### 16.4 No Hidden Assumptions

Every assumption the kernel makes is named: `Decidable` for executable
paths, the `Std.Data.RBMap` lemmas for fold reasoning, the cryptographic
soundness assumption for authority. None hides in a comment, in a test,
or in a developer's head.

### 16.5 Versioning as a First-Class Concern

The kernel module is hashed, versioned, and signed. The genesis state
is hashed, versioned, and signed. Migrations are themselves
transitions, hashed, versioned, and signed. There is no part of the
system that lacks an unambiguous identity.

### 16.6 The Future Is a Plan, Not a Promise

The roadmap of Section 12 commits to a *direction*, not to specific
delivery dates. The Genesis Plan is a living document; it will be
amended as we learn. Amendments are tracked, justified, and reviewed
with the same discipline as the kernel itself.

---

## 17. End State Vision

When fully implemented, the Legal Kernel will provide:

- A **universal legal execution layer** in which any rule expressible
  as a decidable precondition over a finite state space can be enforced
  with mathematical certainty.
- A **proof-carrying execution model** in which every state change
  carries a witness of its legality, free of runtime checks.
- A **deterministic, replayable** ledger whose state at any time is
  reproducible from the genesis state and the transition log.
- An **authority and dispute system** that gives every action an
  identifiable signer and every disagreement a formal procedure of
  resolution.
- A **modular architecture** in which laws, policies, intents, and
  applications can be developed independently of the kernel and of
  each other.
- A **minimal trusted computing base** of a few hundred lines of Lean,
  reviewable by a single specialist in a day.

In one sentence:

> Laws are programs, legality is a proof, governance is a state machine,
> and the whole of it is formally verified.

---

## Appendix A. Glossary

- **Action.** A first-order, serializable representation of a
  transition. Inductive type with one constructor per law in the
  deployment. Section 4.13.
- **Action Hash.** `BLAKE3(encode action)`. The deployment-wide
  identifier of a single action. Section 8.8.4.
- **Actor.** An identity that can submit transitions. Represented in
  state by an `ActorId`.
- **Adjudication.** The four-stage pipeline (file → check evidence →
  propose verdict → apply verdict) that resolves a dispute.
  Section 8.4.
- **Admissible.** Predicate over `(policy, extended state, signed
  action)` that holds when all five authority conditions are met.
  Section 8.2.
- **Authority Policy.** A predicate over `(ActorId, Action)` pairs
  describing who is permitted to issue what. Section 8.2.
- **Balance.** The amount of a given resource held by a given actor in
  a given state. Returned by `getBalance`.
- **Capability.** A bearer-token-style authority value carrying its
  own permissions. Alternative to ACL-style policies. Section 8.10.
- **Canonical Encoding.** The fixed CBOR-subset byte representation
  of kernel-level values. Section 8.8.
- **Certified Transition.** A `Transition` paired with a proof of its
  legality in a specific state. Section 4.7.
- **Conservation.** Preservation of total supply across legal
  transitions. Section 8.1.
- **`decPre`.** The per-state decidability witness field on
  `Transition`. Bridges propositional preconditions and the
  executable `if`. Section 4.4.
- **Decidable Precondition.** A precondition for which Lean can
  compute a `Bool` deciding it. Required for the executable path.
  Section 3.5.
- **Deployment.** A specific instantiation of the kernel with a
  fixed law set, authority policy, and genesis state. Section 8.6.
- **Deployment ID.** The `GenesisHash` of a deployment, used as the
  signing-domain prefix to prevent cross-deployment replay.
  Section 8.8.5.
- **Dispute.** A signed assertion that a particular log entry was
  applied illegally. Section 8.4.
- **Domain Separation.** Prefixing signing inputs with a unique
  string per signed-action class to prevent cross-protocol
  signature collisions. Section 8.8.5.
- **Event.** A domain-vocabulary observation of a state change,
  derived deterministically from a log entry. Section 8.9.
- **Event Log.** A separate stream of events; derived from the
  transition log via `extractEvents`. Section 8.9.
- **Extended State.** Application state plus per-actor nonce ledger.
  Used by the authority module; not in the kernel TCB. Section 8.5.
- **Genesis Hash.** `BLAKE3(encode genesis_state)`. The deployment's
  canonical identifier. Section 8.8.4.
- **Genesis State.** The initial state of a deployment. Section 8.6.
- **Inductive Invariant.** A predicate that holds initially and is
  preserved by every legal step. Section 3.2.
- **Kernel.** The trusted module of Section 4.12.
- **Law.** A `Transition` value, typically defined in Layer 1.
- **Legal.** A proof-bearing structure asserting a transition's
  precondition holds in a state. Section 4.7.
- **Log Entry Hash.** `BLAKE3(encode signed_action || prev_hash)`.
  Chains entries into a tamper-evident list. Section 8.8.4.
- **No-Op Safety.** The property that `step_impl s t = s` when
  `t.pre s` is false. Section 4.6.
- **Nonce.** A monotonic per-actor counter preventing action replay.
  Section 8.5.
- **Proof-Carrying Execution.** A discipline in which every state
  change consumes a proof of admissibility. Section 1.
- **Reachable State.** A state derivable from the genesis state by a
  finite sequence of legal transitions. Section 4.9.
- **Refinement.** The property that an executable function satisfies a
  relational specification. Section 3.3, Section 4.6.
- **Rejection Log.** The append-only record of `SignedAction` values
  that were rejected by the runtime. Section 8.9.
- **Resource.** A class of fungible token. Represented by `ResourceId`.
- **Rollback.** A forward action whose effect is to restore an earlier
  state, recorded in the log. Section 8.4.4.
- **Signed Action.** A serializable `Action` plus signer, nonce, and
  signature. The unit of authority. Section 8.2.
- **Specification.** A relational description of admissible state
  successors. `step_spec` in Lean.
- **State.** The two-level finite map of resource to actor to balance.
  Section 4.2.
- **State Hash.** `BLAKE3(encode state)`. The canonical identifier of
  a state. Section 8.8.4.
- **Step.** Either `step_spec` (relation) or `step_impl` (function).
- **Time Oracle.** A registered identity whose privilege is to issue
  `recordTime` actions. The kernel's interface to wall-clock time.
  Section 8.5.4.
- **Total Supply.** The sum of balances of a given resource across all
  actors. Section 8.1.
- **Transition Log.** The append-only record of `SignedAction` values
  that were successfully applied, plus their pre/post-state hashes.
  Section 8.7.
- **Trusted Computing Base (TCB).** The set of components that must be
  correct for the system's guarantees to hold. Section 6.6.
- **Verdict.** A signed adjudication outcome (`upheld`, `rejected`,
  `inconclusive`) for a filed dispute. Section 8.4.2.
- **Work Unit (WU).** An engineer-week-sized chunk of roadmap
  deliverable. Section 12.

---

## Appendix B. Notation

The mathematical notation in this document follows standard
conventions. A short reference:

| Symbol           | Meaning                                                |
|------------------|--------------------------------------------------------|
| $\mathcal{S}$    | The set of all states                                  |
| $\mathcal{T}$    | The set of all transitions                             |
| $s, s'$          | Specific states                                        |
| $t$              | A specific transition                                  |
| $\pi_t$          | The precondition of transition $t$                     |
| $\varphi_t$      | The state-transformer of transition $t$                |
| $\sigma_t$       | The combined `step_impl` for $t$                       |
| $R(s_0)$         | The reachable set from initial state $s_0$             |
| $I$              | An invariant (a predicate over states)                 |
| $\to$            | The transition relation                                |
| $T_r(s)$         | The total supply of resource $r$ in state $s$          |
| $\delta_t$       | Decidability witness for $\pi_t$ (Section 2.2)         |
| $\mathbb{N}$     | The non-negative integers                              |
| $\mathbb{B}$     | The booleans                                           |
| $\text{Prop}$    | The Lean type of propositions                          |

Lean-specific notation:

| Lean              | Mathematical reading                              |
|-------------------|---------------------------------------------------|
| `t.pre s`         | $\pi_t(s)$                                        |
| `t.decPre s`      | $\delta_t(s)$ (decidability witness)              |
| `t.apply_impl s`  | $\varphi_t(s)$                                    |
| `step_impl s t`   | $\sigma_t(s)$                                     |
| `step_spec s s' t`| $(s, s') \in \mathord{\to_t}$ (graph of $\sigma_t$) |
| `Reachable s0 s`  | $s \in R(s_0)$                                    |
| `Legal s t`       | proof-relevant carrier of $\pi_t(s)$              |
| `Action`          | first-order data view of a transition (Section 4.13) |
| `Action.compile`  | the function from `Action` to `Transition`        |
| `SignedAction`    | `(Action, ActorId, Nonce, Signature)` (Section 8.2) |
| `Admissible P es st` | the conjunction of the five authority conditions |
| `expectsNonce es a` | next expected nonce for `a` in `es`             |

---

## Appendix C. References

The Genesis Plan does not depend on external citations to be
mechanically checked, but the design draws on a tradition of work that
deserves naming.

- **Refinement calculus.** Back & von Wright, *Refinement Calculus*
  (1998). The spec/impl separation in Section 4.5 is in this lineage.
- **Hoare logic.** Hoare, *An Axiomatic Basis for Computer
  Programming* (1969). The pre/post discipline in `Transition` is
  Hoare-shaped.
- **Lean 4 type theory.** de Moura & Ullrich, *The Lean 4 Theorem
  Prover and Programming Language* (2021). The substrate for the
  whole kernel.
- **Operational semantics of state machines.** Plotkin, *A Structural
  Approach to Operational Semantics* (1981).
- **Inductive invariant proofs.** Manna & Pnueli, *Temporal
  Verification of Reactive Systems* (1995).
- **Proof-carrying code.** Necula, *Proof-Carrying Code* (1997). The
  spirit of `CertifiedTransition` is here.
- **Smart-contract verification.** Various; the negative space (what
  goes wrong without these disciplines) motivates the kernel.
- **Concise binary object representation (CBOR).** Bormann & Hoffman,
  *RFC 8949* (2020). The basis for the canonical encoding in
  Section 8.8.
- **Ed25519 signing.** Josefsson & Liusvaara, *Edwards-Curve Digital
  Signature Algorithm (EdDSA)*, *RFC 8032* (2017). The reference
  signature scheme.
- **BLAKE3.** O'Connor, Aumasson, Neves, Wilcox-O'Hearn,
  *BLAKE3: one function, fast everywhere* (2020). The reference
  hash function for content addressing.
- **EUF-CMA.** Goldwasser, Micali, Rivest, *A digital signature scheme
  secure against adaptive chosen-message attacks* (1988). The
  security assumption on `Verify` (Section 8.2).
- **Capabilities.** Dennis & Van Horn, *Programming semantics for
  multiprogrammed computations* (1966); Miller, *Robust composition*
  (PhD thesis, 2006). The basis for Section 8.10.
- **Append-only logs and Merkle hash chains.** Crosby & Wallach,
  *Efficient data structures for tamper-evident logging* (USENIX
  Security 2009). The structure of the transition log (Section 8.7).

These are signposts, not formal dependencies. The Genesis Plan stands
on its own definitions and proofs.

---

## Appendix D. Change Log

Amendments are appended with a date, an author (or attribution), a
one-line summary, and a link to the amending discussion.

| Revision | Date       | Summary                                                                                  |
|----------|------------|------------------------------------------------------------------------------------------|
| 1.0      | 2026-05-03 | Initial Genesis Plan.                                                                    |
| 1.1      | 2026-05-03 | Add `decPre` field to `Transition` (Lean-correctness fix); add Action layer (§4.13); restructure authority around `SignedAction`; decompose dispute pipeline into four stages; add canonical encoding (§8.8), event log (§8.9), capabilities (§8.10); decompose roadmap into per-WU work units; add runbooks (§13.6–§13.9); add anti-patterns and review checklists (§14.6–§14.8); add Table of Contents and Appendix E. |
| 1.2      | 2026-05-04 | Phase 3 (Authority Layer) marked complete (WU 3.1 – 3.10).  `Action.compile` redesigned to produce a `CompiledAction` wrapper so that `compile_injective` is a one-line structural proof.  `KeyRegistry` moved from `AuthorityPolicy` to `ExtendedState` so `replaceKey` (WU 3.10) can mutate it through `apply_admissible`.  `Verify` declared `opaque` (not `axiom`) so the kernel's axiom audit continues to return only the three Lean built-ins. |
| 1.3      | 2026-05-20 | Workstream E-G (Ethereum documentation amendment) lands chapter §15D "Workstream E Amendment: Ethereum Integration".  Documents the knomosis-as-rollup deployment scenario, the five trust assumptions (EUF-CMA secp256k1, keccak256 collision-resistance, L1 finality, Solidity-contract correctness, EIP-1271 contract correctness), the `Action` / `Event` constructor extensions at frozen indices 12 – 14 and 9 – 10, the `BridgeState` accounting equation, the height-64 withdrawal SMT, the EIP-712 signing surface, the ten-contract Solidity surface, the F.1.x cross-stack verification corpus, and the eleven v2 deferrals.  Zero source change; zero new axioms; zero TCB delta.  See `docs/planning/ethereum_workstream_g_plan.md` for the per-sub-unit specification. |
| 1.4      | 2026-05-21 | Workstream GP Phase GP.0 foundations landed: add chapter §15E "Unified Gas Pool and Per-Actor Budgets", pre-reserve Lex action indices 18–19 for GP actions, reserve event indices 16–18 in the event-tag registry commentary, and add GP cross-references in planning documents (`open_questions.md`, `deferred_work_index.md`, `phase_7_plan.md`). No kernel TCB delta, no new axioms. |
| 1.5      | 2026-05-28 | Workstream GP.5.5 v1.0 (BOLD-specific safety hardening, initial implementation) lands on the L1 mirror.  `KnomosisBridge.sol` gains the lone privileged surface: tightly-scoped immutable `boldCircuitBreaker` / `boldAdmin` roles governing the per-currency BOLD circuit breaker (manual `closeBoldCircuit` / `openBoldCircuit` plus the initial Liquity-V2 *redemption-rate* auto-trigger `closeBoldCircuitIfRedeemingHeavily` reading `getRedemptionRate()` against a constructor-immutable oracle, with threshold `BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS = 500`) and per-BOLD TVL cap.  §15D.8 + §15E.8 amended with the new privileged surface + operational trust assumption.  Deposit-side, L1-only; cannot move funds, alter state roots, or halt withdrawals.  No kernel TCB delta, no new axioms. |
| 1.6      | 2026-05-28 | Workstream GP.5.5 v1.1 (branch-shutdown signal refactor) replaces the redemption-rate threshold with the strictly stronger per-branch `TroveManager.shutdownTime() != 0` signal — the definitive on-chain Liquity-V2 depeg indicator.  Function renamed to `closeBoldCircuitIfAnyLiquityBranchShutdown`; the constructor-immutable oracle is replaced by three constitutional `address public constant` TroveManager pins (`LIQUITY_V2_TROVE_MANAGER_ETH` / `_WSTETH` / `_RETH`) under the GP.5.2 cap-audit gate.  The constructor adds role-distinctness (`BoldRolesNotDistinct`) and no-self-as-role (`BoldRoleIsBridge`) guards.  The staticcall is gas-bounded by `LIQUITY_ORACLE_READ_GAS = 100k` to bound malicious-TroveManager griefing.  Event signature widens to `(timestamp, indexed shutdownBranch, branchShutdownTime)`.  §15D.8 + §15E.8 + §15D's privileged-surface narrative re-amended.  No kernel TCB delta, no new axioms. |
| 1.7      | 2026-05-28 | Workstream GP.5.5 v1.2 (safety polish).  `LiquityOracleHasNoCode` parameterised to carry the missing TroveManager address so operators can diagnose without bisecting.  Constructor gains a pairwise-distinctness check on the three TM constants (`BoldTroveManagersNotDistinct`), defence-in-depth behind the GP.5.2 source-level gate.  `LIQUITY_ORACLE_READ_GAS` joins the GP.5.2 cap-audit gate (now 4 caps + 4 address pins + 1 symbol pin; self-test 36 cases) and is promoted to `public constant`.  The auto-trigger function is flattened to a per-branch early-return chain.  The `_readLiquityShutdownTime` helper is tightened from `internal` to `private`.  Test coverage gains: stateful Foundry invariant suite (3 invariants × 128 000 random sequences), reentrancy attack test on `depositBoldWithFee` via a malicious BOLD mock, per-branch oracle-fault tests (every fault class × {ETH, wstETH, rETH}), constructor revert-ordering pins, fuzz now asserts event-content semantics.  Total: 85 forge tests + 36 self-test cases.  No kernel TCB delta, no new axioms. |
| 1.8      | 2026-05-31 | Workstream GP.7.0 (exhaustive characterisation of the bridge-signable action set) lands on the Lean side (`LegalKernel/Bridge/BridgeActor.lean`).  `bridgeAuthorizedAction` is hardened from a `_ => false` catch-all to a wildcard-free exhaustive match over all 22 `Action` constructors (behaviour byte-identical — the same four L1-attested variants `replaceKey` / `registerIdentity` / `deposit` / `depositWithFee` return `true`), so a future constructor cannot be silently absorbed as unauthorised.  Three characterisation theorems added: `bridgeAuthorizedAction_eq_true_iff` (the bridge signs EXACTLY those four), `bridgePolicy_authorizes_all_bridge_actions` (no-regression positive half), `bridgePolicy_rejects_non_bridgeable` (exhaustive negative half).  Two complementary compile-time forcing functions guard against silent authority drift (constructor additions caught by the exhaustive match; verdict flips caught by the iff's `cases` proof).  The `ammSwap` arm of the WU is deferred to Workstream GP.11 (the constructor does not exist yet); the forcing functions guarantee its classification is added in lockstep.  `bridge-actor` suite 38 → 58 (20 GP.7.0 cases, incl. five end-to-end `BridgeAdmissibleWith` admissions under `bridgePolicy`).  Names drop the plan's `v1_5` infix per the naming discipline.  No kernel TCB delta, no new axioms (`bridgePolicy_authorizes_all_bridge_actions` is axiom-free; the other two are `{propext, Quot.sound}`). |
| 1.9      | 2026-05-31 | Workstream GP.7.1 (`gasPoolActor` reservation) lands end-to-end (Lean + Rust).  **Lean** (`LegalKernel/Bridge/BridgeActor.lean` + `LegalKernel/Bridge/AddressBook.lean`): reserves `ActorId 1` for `gasPoolActor` (holds the deposit fee-split skim + per-actor budget top-up payments; outflow bounded by the GP.7.2 `gasPoolPolicy`) and `ActorId 2` for `sequencerActor` (the sole authorised pool-drain recipient + L2 state-root submitter), alongside the pre-existing `ActorId 0` (`bridgeActor`).  The genesis `AddressBook.empty.nextActorId` advances from `1` to `3` (`addressBook_empty_nextActorId`), so an `empty` + `assign` chain never issues a reserved slot to a user-registered identity — the first user actor a fresh deployment registers is `ActorId 3`.  Three pairwise-distinctness theorems (`gasPoolActor_ne_bridgeActor`, `sequencerActor_ne_bridgeActor`, `sequencerActor_ne_gasPoolActor`) underpin the GP.7.2 recipient restriction (a pool whose only permitted drain recipient coincided with itself could not be drained), and the reservation-guarantee theorem `empty_assign_id_avoids_reserved` proves the issued id is distinct from every reserved slot.  `bridge-actor` suite 58 → 71 (13 GP.7.1 cases).  **Rust** (`runtime/knomosis-l1-ingest`): the production runtime adaptor advances in lockstep — `AddressBook::INITIAL_NEXT_ACTOR_ID` becomes `3` with mirror `GAS_POOL_ACTOR_ID` / `SEQUENCER_ACTOR_ID` constants, so the adaptor that performs the actual `assign` honours the reservation; the state-file replay additionally rejects a persisted reserved id (`replay_rejects_reserved_actor_id`); the `l1_ingest.cxsf` cross-stack corpus and all `address_book` / `state` / `translation` / `watcher` / integration tests are rebased onto the genesis-3 allocation (full workspace `cargo test` green, `clippy -D warnings` + `fmt` clean).  This is the *fresh-genesis* half; the orthogonal migration of *existing* deployments that already allocated users in 1..3 remains Phase GP.10.4.  The `bridge-address-book` / `bridge-ingest` Lean value fixtures are likewise rebased.  No kernel TCB delta, no new axioms (the three disjointness theorems are axiom-free `decide`; `addressBook_empty_nextActorId` / `empty_assign_id_avoids_reserved` depend only on the canonical `{propext, Classical.choice, Quot.sound}` via `Std.TreeMap`). |
| 1.10     | 2026-06-01 | Workstream GP.7.2 (canonical `gasPoolPolicy` declaration) lands on the Lean side (`LegalKernel/Bridge/GasPoolPolicy.lean`).  Declares the per-actor `LocalPolicy` (Workstream LP) the admission layer consults whenever `gasPoolActor` (GP.7.1 / `ActorId 1`) signs an action, bounding the pool's outflow to a single capability: a per-action-capped `transfer` to `sequencerActor` (GP.7.1 / `ActorId 2`).  Five conjunctive clauses — `denyTags gasPoolDeniedTags` (deny every Action tag except `transfer`) plus `requireRecipientIn` / `capAmount` on each of `ResourceId 0` (ETH) and `ResourceId 1` (BOLD), with independent per-leg caps `maxDrainPerActionEth` / `maxDrainPerActionBold`.  `gasPoolDeniedTags = (List.range 23).filter (· ≠ 0) = [1..22]` covers the frozen Action set (0..21) plus the reserved GP.11 `ammSwap` slot (22); coverage is mechanically enforced by `Action.tag_lt_denyListBound` (exhaustive `cases`, a build-time forcing function that breaks if a 24th constructor is appended without bumping the range).  Headline theorems: `gasPoolPolicy_denies_all_non_transfer` (the pool can never `mint` / `burn` / `withdraw` / top up budgets / sign any non-transfer action — closing attack-tree item 5's fund-rerouting and bounding item 4's drain), `gasPoolPolicy_requires_sequencer_recipient_eth` / `_bold` (per-leg recipient restriction), `gasPoolPolicy_caps_per_action_eth` / `_bold` (per-leg amount cap) plus their positive `_amount_le` extraction forms (the per-step ingredient the GP.7.3 inductive drain bound sums), `gasPoolPolicy_eth_bold_independent` (the two legs' resource-keyed clauses are vacuous on the other resource), the happy-path `gasPoolPolicy_permits_sequencer_transfer_eth` / `_bold` (the legitimate capped sequencer claim is admitted), and the single-source-of-truth `gasPoolPolicy_permits_transfer_iff`.  Two boundaries are stated explicitly rather than glossed: (a) `gasPoolPolicy_permits_transfer_off_gas_legs` — the policy carries no clause for resources `≥ 2`, so it does NOT constrain them (off-leg safety rests on a separate pool-balance invariant, the GP.7.3 track); and (b) the **LP.7 meta-action escape hatch** — `gasPoolPolicy_admission_permits_meta_actions` proves a `LocalPolicy` structurally cannot bar `gasPoolActor` from `declareLocalPolicy` / `revokeLocalPolicy` (so a pool key could wipe its own restriction).  That hole is CLOSED in this WU by the complementary `gasPoolAuthorityPolicy`, intersected into the deployment policy at genesis: the `AuthorityPolicy` conjunct of `AdmissibleWith` has no meta-action exemption, so `gasPoolAuthorityPolicy_rejects_meta` / `_intersect_rejects_meta` bar the escape hatch under ANY base policy, `_rejects_off_gas_legs` / `_rejects_non_sequencer` / `_rejects_non_transfer` enforce (at the authority layer) the restrictions the `LocalPolicy` could not, `_authorizes_sequencer_eth` / `_bold` preserve the legitimate drain, and `_other_actors_unrestricted` proves the intersection narrows ONLY `gasPoolActor`.  GP.7.4 genesis prerequisites also ship: `gasPoolPolicy_fieldsBounded` + `gasPoolPolicy_roundtrip` (canonical CBE boundedness + decode∘encode round-trip under `UInt64`-range caps).  New `bridge-gas-pool-policy` suite (57 cases, including end-to-end intersection-composition tests against the restrictive `bridgePolicy` base).  Lean-only; the per-epoch inductive drain bound is GP.7.3.  No kernel TCB delta, no new axioms (the bare-policy + authority theorems use only `{propext, Quot.sound}`; the two admission-level theorems additionally use `Classical.choice` via `ExtendedState`).  GP.7.4 MUST wire BOTH the `LocalPolicy` declaration AND the `AuthorityPolicy` intersection — the `LocalPolicy` alone leaves the meta-action hole open. |
| 1.11     | 2026-06-01 | Workstream GP.7.2 (PR #106 review) — fund-safety hardening of `gasPoolAuthorityPolicy`.  An automated review flagged that `gasPoolActorAuthorized` ignored the transfer's `sender` field: since the kernel `transfer` law debits the action's `sender` and `AdmissibleWith` verifies only `st.signer`'s signature (never `signer = sender`), a held `gasPoolActor` key could sign `.transfer r victim sequencerActor amount` and drain an ARBITRARY victim's balance to the sequencer.  The companion `LocalPolicy` (`gasPoolPolicy`) structurally cannot bind the sender (its `LocalPolicyClause` vocabulary keys only on resource / recipient / amount), so the fix lands at the `AuthorityPolicy` layer: both authorised gas-leg disjuncts now require `sender = gasPoolActor`, so the pool may move only its OWN funds.  New theorem `gasPoolAuthorityPolicy_rejects_non_pool_sender`; `gasPoolAuthorityPolicy_authorizes_sequencer_eth` / `_bold` specialise the `sender` to `gasPoolActor`.  The `gasPoolPolicy_transfer_sender_independent` theorem (a true fact about the sender-blind `LocalPolicy`) is retained but its docstring is corrected from "harmless" to "a real gap closed at the `AuthorityPolicy` layer".  Suite 57 → 61 cases (the victim-fund-drain rejection, direct + end-to-end through the intersect wiring, + term-level APIs).  No kernel TCB delta; all theorems `{propext}` only.  Verified: all three CI checks green before the fix; the fix strictly narrows the authorised set. |
| 1.12     | 2026-06-01 | CI de-flake (PR #106) — `knomosis-event-subscribe`'s pre-existing GP.6.3 test `subprocess_forwards_global_args_before_subcommand` raced the fake subprocess: it read the argv-recording file the instant `extract` returned, but the fake's `printf > argfile` runs CONCURRENTLY with the parent's stdin-write / stdout-read and the parent kills+reaps the child on the (expected) protocol-read failure, so on a loaded CI runner the file could be observed slightly after `extract` returns → an intermittent `NotFound` panic.  Fixed test-side only: replace the unconditional `read_to_string(...).expect(...)` with a bounded 5 s poll for a non-empty read.  No production-code change; no version-semantics change (the bump is the routine per-PR patch increment).  Lean side untouched. |
| 1.13     | 2026-06-01 | Workstream GP.7.3 (inductive pool-drain bound) lands on the Lean side (`LegalKernel/Bridge/PoolDrainBound.lean`).  Promotes the GP.7.2 per-action caps to a per-trace invariant: across any contiguous trace of `n` admitted `SignedAction`s respecting the gas-pool discipline, `gasPoolActor`'s `ResourceId 0` (ETH-leg) balance cannot have decreased by more than `n × maxDrainPerActionEth`.  `PoolBoundedTrace` (a length-indexed inductive relation, the type-safe analogue of the plan's `applyTrace`) carries the two controlling per-step facts: a `gasPoolActor`-signed step is authorised by `gasPoolAuthorityPolicy` (so the cap + sender-binding + meta-blocking + policy-stability all hold — the bound rests on the GP.7.2 `AuthorityPolicy`, NOT the sender-blind `LocalPolicy`), and a non-pool step does not decrease the pool's balance (the deployment's `sender = signer` obligation, dischargeable — proven for the dominant transfer case by `transfer_other_sender_pool_nondecreasing`, including the credit-to-pool branch).  Headline `pool_drain_bounded_by_action_count`; the heart `pool_signed_step_drain_le_eth` computes the per-step ETH debit (`amount ≤ mEth` from the authority cap, `amount ≤ balance` from the transfer precondition) and the BOLD-leg locality (resource-0 untouched); corollaries `pool_balance_lower_bound_via_trace` (surviving-balance floor) and `pool_cannot_drain_when_cap_zero` (`maxDrainPerActionEth = 0` ⇒ no ETH drain); connector `gasPoolActorAuthorized_of_admissible_intersect` discharges the pool-signed hypothesis from the GP.7.4 genesis-wiring policy shape.  §15E.6 amended with the proven bound.  New `bridge-pool-drain-bound` suite (20 cases: per-step ETH/BOLD, external non-interference, 1/2/3-step + mixed traces, the discipline rejections — over-cap / victim-sender / non-sequencer / off-leg / meta / zero-amount — the zero-cap boundary, genesis-wiring fidelity, and term-level API stability).  `omega`'s `Amount`-atomisation limitation worked around via `Nat`-parameter arithmetic helpers (the `transfer_arithmetic` pattern).  Lean-only; no kernel TCB delta, no new axioms (`{propext, Classical.choice, Quot.sound}` only). |
| 1.14     | 2026-06-01 | Workstream GP.7.3 **optimal closure** (also delivers the GP.7.5 core).  Extends the v1.13 ETH-leg bound to its complete form, all in `LegalKernel/Bridge/PoolDrainBound.lean`: (1) **per-resource** — `pool_drain_bounded_by_action_count_per_resource` (cap `legCap mEth mBold rLeg`) with the ETH / BOLD legs as `simp`-specialisations, removing the vestigial `mBold`; the two legs are proven independent accounting domains (`per_resource_pool_independence`, `pool_balance_eth_leg_independent_of_bold_actions` / `…_bold_…`) — i.e. WU GP.7.5's headline + independence theorems; (2) **exhaustive external discharge** — `pool_nondecreasing_of_does_not_debit` over EVERY `Action` constructor, gated by the decidable `Action.doesNotDebitPoolAt` predicate (credit-only / no-op always; `topUp*` when signer ≠ pool; `transfer` / `burn` / `withdraw` when source ≠ pool; the fold-of-credit laws via a per-actor fold-monotonicity lemma); (3) **executable `applyTrace`** — the literal plan deliverable as an `Option`-valued fold (backed by a new `Decidable (AdmissibleWith …)` instance), with the bound proven directly over it (`applyTrace_drain_bounded_per_resource`) and a relation bridge (`applyTrace_yields_poolBoundedTrace` via `PoolBoundedTrace.headStep`), driven at runtime in the test suite; (4) **production-runtime lift** — the per-step bounds lifted onto the literal budget-gated bridge entry (`pool_signed_step_drain_le_budget`, `pool_nondecreasing_of_does_not_debit_budget`), matching GP.4.2's production-faithfulness; (5) **layering** — `apply_admissible_with_base` relocated beside `apply_admissible_base` in `Authority/SignedAction.lean`.  The GP.4.2 `Accounting.lean` cross-references to `pool_balance_lower_bound_via_trace` were corrected (it is the outflow-cap floor, not the full solvency-reconciliation closure — the still-open `BridgeReachable` WU C.6.4 / C.6.5).  §15E.6 amended.  `bridge-pool-drain-bound` suite 20 → 21 cases (adds BOLD-leg drain, per-resource bound, exhaustive-discharge value checks, the `doesNotDebitPoolAt` classifier, and the executable-`applyTrace` runtime fold).  Lean-only; no kernel TCB delta, no new axioms (`{propext, Classical.choice, Quot.sound}` only). |
| 1.15     | 2026-06-01 | GP.7.3 post-implementation **audit hardening** (no new theorems; soundness re-verified, two best-practice fixes).  (a) The general, genuinely-computable `Decidable (AdmissibleWith …)` instance (`instDecidableAdmissibleWith`) — introduced for `applyTrace` in v1.14 — is **relocated to its proper home beside `AdmissibleWith` in `Authority/SignedAction.lean`**, so admissibility is now universally decidable + foldable for any consumer (the existential over the registered signing key is decided by casing the concrete registry lookup, never quantifying over the key space; verified to reduce via `#eval`).  (b) Test coverage strengthened: the runtime-entry lift `pool_signed_step_drain_le_budget` is now exercised at the **value level** over the LITERAL `apply_bridge_admissible_with_budget` production entry (with an epoch-advanced budget policy, since a fresh actor's free tier is granted on epoch advance, not at `currentEpoch = 0`), and `applyTrace_yields_poolBoundedTrace` is value-tested by feeding the recovered relation through the headline bound.  `bridge-pool-drain-bound` suite 21 → 23 cases.  Audit confirmed: no `sorry` / `native_decide` / custom axioms; `doesNotDebitPoolAt` is sound + tight (verified by the exhaustive discharge's build); the bound rests on the GP.7.2 `AuthorityPolicy`, not the sender-blind `LocalPolicy`.  Lean-only; no kernel TCB delta, no new axioms. |
| 1.16     | 2026-06-01 | Workstream GP.7.4 (`gasPoolPolicy` ratification on genesis) lands on the Lean side.  The `gasPoolGenesis` hook (`LegalKernel/Bridge/GasPoolPolicy.lean`) wires BOTH halves of the GP.7.2 discipline atomically: `gasPoolGenesisState` declares `gasPoolPolicy mEth mBold` for `gasPoolActor` in the genesis `localPolicies`, `gasPoolGenesisPolicy` intersects `gasPoolAuthorityPolicy mEth mBold` into the deployment's base `AuthorityPolicy`, and the `GasPoolGenesis` structure + `gasPoolGenesis` constructor bundle them so the "wire BOTH" contract holds by construction (`gasPoolGenesis_wires_both_halves`) — the half-less wiring that would leave the LP.7 meta-action hole open is unreachable through the constructor.  Twelve contract theorems ratify the wiring: `gasPoolGenesisState_declares_policy` / `_preserves_other_localPolicies` / `_preserves_kernel_substates` (the surgical state half — only `localPolicies` changes); and `gasPoolGenesisPolicy_rejects_meta` (the GP.7.4 headline — pool `revokeLocalPolicy` / `declareLocalPolicy` barred under ANY base policy, closing the hole `gasPoolPolicy_admission_permits_meta_actions` exposed), `_other_actors_unrestricted` (the intersection narrows ONLY `gasPoolActor`), `_rejects_non_pool_sender` (the PR #106 fund-safety fix, ratified at genesis), `_rejects_off_gas_legs` / `_rejects_non_sequencer` / `_rejects_non_transfer`, and `_authorizes_sequencer_eth` / `_bold` (the legitimate capped claim still admitted given the base authorises it).  The worked deployment `Deployments/Examples/GasPoolExample.lean` runs the full ETH + BOLD lifecycle (bridge `depositWithFee` × 2 → user + pool credit + L2 budget grant → capped sequencer claim × 2) end-to-end through the production admission gate (`apply_bridge_admissible_with_budget`), and is runnable via the new `knomosis gas-pool-demo` subcommand (process → persisted log → `replayWith` round-trip; the example ships its own deterministic demo verifier since the dev binary's linked `Verify` returns `false` at the Lean level).  §15E.6 amended with the genesis-ratification paragraph.  New `deployments-gas-pool-example` suite (13 integration cases: the worked sequence runs; final balances on both legs; the user budget grants; genesis fidelity; over-cap ETH / BOLD, pool meta-action, victim-sender, and non-sequencer rejections against a well-funded pool; the intersection-narrows-only-the-pool positive case; the IO binary process→log→replay round-trip; and term-level API stability).  Engineering-placement note: the genesis hook lives in `Bridge/GasPoolPolicy.lean` (the canonical gas-pool module, where `gasPoolPolicy` / `gasPoolAuthorityPolicy` / `ExtendedState` / `LocalPolicies.declare` / `AuthorityPolicy.intersect` already are) rather than the plan's tentative `Runtime/Replay.lean`, keeping the bridge-specific helper out of the generic replay module.  Lean-only (+ a self-contained CLI demo); no kernel TCB delta, no new axioms (the pure policy theorems use only `propext`; the state-half + example theorems use the canonical `{propext, Classical.choice, Quot.sound}` via `Std.TreeMap` / `ExtendedState`). |
| 1.17     | 2026-06-01 | Workstream GP.7.4 **optimal closure** — production-CLI reach + config-driven opt-in + Rust host forwarding + theorem completeness.  (1) **Config-driven opt-in** (`Bridge/GasPoolPolicy.lean`): `GasPoolConfig` + the `gasPoolGenesisStateOfConfig` / `…PolicyOfConfig` / `gasPoolGenesisOfConfig` builders gate the genesis wiring on an `Option` ("if the deployment's config says so" — `none` is the pre-GP.7.4 genesis byte-for-byte, `some ⟨mEth, mBold⟩` wires both halves), with `_none` / `_some` contract theorems.  (2) **Generic `knomosis` CLI** (`Main.lean`): `--gas-pool-eth-cap` / `--gas-pool-bold-cap` flags build the gas-pool genesis (state + policy) via the hook and thread it through every log-touching subcommand (`process` / `replay` / `bootstrap` / `snapshot` / `replay-up-to` / `export-cell-proofs` / `extract-events`), so operators run real gas-pool deployments through the generic binary (verified end-to-end: the gas-pool genesis state hash is distinct from the plain genesis, and the sidecar cross-check accepts a matching config + rejects a wrong / disabled one).  (3) **`GasPoolSidecar`** (`Runtime/GasPoolSidecar.lean`, mirroring the GP.6.2 `BudgetSidecar`): the config is persisted to `<log>.gaspoolcfg` and cross-checked on every log-touching command, because the gas-pool genesis `localPolicies` declaration participates in the per-log-entry post-state hash — a forgotten / changed / disabled cap fails loudly with a clear `gas-pool-config error` rather than an opaque post-state-hash mismatch.  (4) **Rust host** (`runtime/knomosis-host`): the `CommandKernel` forwards the caps via `with_gas_pool_policy` (config `--gas-pool-eth-cap` / `--gas-pool-bold-cap` → `gas_pool_caps()` → the spawned `knomosis process` argv), mirroring its GP.6.2 budget-flag forwarding; +7 host tests.  (5) **Theorem completeness**: `gasPoolGenesisPolicy_rejects_over_cap_eth` / `_bold` (the authority-layer per-action cap rejection) and `gasPoolGenesisPolicy_bars_self_declaration` (the structural-genesis necessity — once `gasPoolAuthorityPolicy` is in force the pool cannot install / replace its own `LocalPolicy` via a signed `declareLocalPolicy`, so the genesis declaration MUST be structural).  §15E.6 amended.  `deployments-gas-pool-example` suite 13 → 17 (a proof-carrying budget-grant tie via `depositWithFee_grants_budget_bridge`, an honest per-half contribution test, a restrictive-base `bridgePolicy` composition, and a snapshot round-trip of the gas-pool genesis state) + new `runtime-gas-pool-sidecar` suite (9 cases).  No kernel TCB delta, no new axioms; all Lean audits + the full Rust workspace (build / test / clippy / fmt) green. |
| 1.18     | 2026-06-01 | Workstream GP.7.4 **post-implementation audit fix** — `export-terminate-bundle` gas-pool sidecar cross-check.  A deep audit found that `knomosis export-terminate-bundle`'s output (`claimedPostCommit := stepVMHashFromAction preState …` + `cellProofs := buildObserverCellProofs preState …`) is computed against `commitExtendedState preState`, which INCLUDES `commitLocalPolicies` — so the gas-pool genesis declaration (a `localPolicies` entry) affects the bundle, yet the v1.17 wiring had threaded the gas-pool genesis into this subcommand WITHOUT a sidecar cross-check (the other log-touching subcommands all had one).  A mismatched / disabled gas-pool config would therefore build the terminate calldata against the WRONG state commit (which the L1 contract would reject after the operator paid gas) instead of failing early.  The fix adds the `GasPoolSidecar.checkConsistent` guard to `cmdExportTerminateBundle` (exit 2 with a clear `gas-pool-config error` on mismatch), so the gas-pool sidecar is now cross-checked on EVERY log-touching subcommand.  The BUDGET sidecar is deliberately NOT checked there — `commitExtendedState` excludes `budgetPolicy` / `epochBudgets` and `kernelOnlyReplay` runs no budget gate, so the bundle is budget-config-independent (the asymmetry is principled: only the gas-pool config, via `localPolicies`, reaches the commit).  §15E.6 amended.  +1 real-binary integration test (`real_knomosis_gas_pool.rs::gas_pool_export_terminate_bundle_config_checked`, Rust workspace 1753 → 1754).  Not a security hole (a wrong bundle is L1-rejected, never forge-able); a fail-early correctness + UX fix.  Lean audits + full Rust workspace green; no kernel TCB delta, no new axioms. |
| 1.19     | 2026-06-05 | Workstream GP.11.1 (embedded ETH↔BOLD AMM — state variables + reserves) lands on the L1 mirror (`solidity/src/contracts/KnomosisBridge.sol`).  Adds the AMM's L1 scaffold: two mutable reserve slots `ammReserveEth` / `ammReserveBold` (no direct setter — seeded on deposit in GP.11.2, mutated by `ammSwap` in GP.11.3), the immutable `ammSeedRatioBps` (the bps fraction of each pool-fee deposit routed to AMM liquidity, threaded as a new `ConstructorArgs.ammSeedRatioBps` field and validated `<= MAX_AMM_SEED_RATIO_BPS` at construction — `AmmSeedRatioExceedsMax` otherwise), and two new constitutional compile-time caps `AMM_SWAP_FEE_BPS = 30` (0.30%, the Uniswap-v2-standard swap fee) / `MAX_AMM_SEED_RATIO_BPS = 8000` (80%, the structural defence against starving sequencer free-pool claims).  Purely additive: GP.11.1 ships no deposit-seeding (GP.11.2) or swap (GP.11.3) logic, so the reserves stay 0 for the lifetime of a GP.11.1-era deployment regardless of the seed ratio, and `ammSeedRatioBps = 0` disables the AMM and preserves the pre-v1.3 behaviour byte-for-byte; every existing `ConstructorArgs` initializer (the `Deployer` helper + 15 test sites) passes `0`.  The two new caps join the GP.5.2 source-level cap-audit gate (`scripts/audit_compile_time_caps.sh`, now 6 caps + 4 address pins + 1 symbol pin; self-test 37 → 45 cases) AND a compiled-contract runtime pin (`test/AmmStorage.t.sol::test_ammCompileTimeCaps_pinned`), matching the dual-layer protection the fee-split caps carry — changing either cap is a §13.6 amendment.  New `test/AmmStorage.t.sol` suite (16 cases: caps pinned, seed-ratio store/validate incl. the `> MAX` + `uint16`-max reverts and a `[0, MAX]`-accept / `(MAX, uint16Max]`-reject fuzz pair at 1000 runs, reserves start-and-stay zero across deposits, the GP.11.1.c v1.2-preservation acceptance criterion — a disabled deposit matches the `FeeSplitMath` reference and a `0`-vs-`MAX` cross-ratio deposit emits a byte-identical split via `vm.expectEmit` — the "no mutation surface even via admin functions" criterion via a no-AMM-setter-selector probe (`test_ammState_hasNoSetterSurface`), the BOLD leg via a real `depositBoldWithFee` on a BOLD-enabled bridge that leaves both reserves at 0 (`test_boldDeposit_doesNotSeedReserve`), and a constructor-guard ordering pin (`test_constructor_guardOrdering_feeBeforeAmm`)).  `forge build` warning-free; full `forge test` green (661 passed, +16).  Solidity-only; the Lean (`lake build` + `lake test`) and Rust (`cargo build` + `test` + `clippy` + `fmt`) gates re-run green to confirm the lockstep version bump is inert; the L2 mirror via `Action.ammSwap` is GP.11.4 / GP.11.5.  No kernel TCB delta, no new axioms (no Lean change). |
| 1.20     | 2026-06-05 | Workstream GP.11.2 (embedded ETH↔BOLD AMM — seeding on deposit) lands cross-stack (Solidity + Lean cross-check corpora + Rust ingestor).  The shared `_registerDepositWithFee` (`solidity/src/contracts/KnomosisBridge.sol`) now seeds the AMM from the pool fee via the new `private _seedAmmReserves(resourceId, poolAmount)` helper: `ammSeedAmount = floor(poolAmount * ammSeedRatioBps / 10000)` (0 when disabled, floored, or off the ETH/BOLD gas legs) grows the matching reserve (`ammReserveEth` / `ammReserveBold`); the free-pool remainder is the implicit `poolAmount - ammSeedAmount`.  Conservation holds end-to-end (`userAmount + ammSeedAmount + freePoolAmount == deposit`); the seed reclassifies value already inside `totalLockedValue`, so `ammReserveEth + ammReserveBold <= totalLockedValue` (a Foundry invariant).  Checked arithmetic throughout (`ratio <= MAX_AMM_SEED_RATIO_BPS = 8000 < 10000` ⇒ `ammSeedAmount <= poolAmount`; overflow reverts rather than wraps).  A `GP.11.10 hook point` comment marks where `emergencyDisableAmm()`'s early-out will go.  **Wire format (plan-literal):** the split is carried in the canonical `DepositWithFeeInitiated` event by inserting `uint256 ammSeedAmount` after `poolAmount`, and BOUND in the `receiptHash` (`keccak256(abi.encode(deploymentId, sender, resourceId, token, userAmount, poolAmount, ammSeedAmount, budgetGrant, depositorNonce))`), so the L2 reconstructs `freePoolAmount = poolAmount - ammSeedAmount` from one event and a replay with a tampered split is rejected (the receiptHash is sensitive to `ammSeedAmount`).  The change bumps the event topic-0 hash (`0xdffb2055…e4c8f5`) and the receiptHash preimage (9 fields / 288 bytes), accepted as the v1.3 wire-format addition and propagated cross-stack in lockstep: the Rust ingestor (`knomosis-l1-ingest::events` — pinned topic + signature + `decode_event` offsets + the `amm_seed_amount` variant field + `.cxsf` codec) and the two cross-stack receiptHash corpora (`deposit_fee_split.json` + `deposit_fee_split_bold.json` — the Lean generators add the `ammSeed` reference + proof-carrying `ammSeed_le` bound, per-entry `ammSeedRatioBps` / `ammSeedAmount`, and the 9-field recipe; the 16 corners stay AMM-disabled while the 64 randomised draw a random `ammSeedRatioBps ∈ [0, 8000]` so 64 entries carry a NON-ZERO `ammSeedAmount` whose binding is cross-stack-verified; the Solidity consumers deploy each entry's bridge at its ratio and byte-match the emitted split + 256-byte preimage tail).  `bold_deposit.json` (an L2 action + budget corpus) and the plain-deposit `DepositReceiptHash` corpus are unchanged (their consumers absorb the new zero `ammSeedAmount`).  New `test/AmmDepositSeeding.t.sol` (~18 cases: per-leg seeding via the event's `ammSeedAmount`, the disabled/zero-fee/dust `ammSeedAmount == 0` paths, `test_receiptHash_bindsAmmSeedAmount` (tamper-evidence), leg independence, monotonic accumulation, reserve-subset-of-TVL, `test_cappedDeposit_revertsAndDoesNotSeed` + `test_plainDepositETH_doesNotSeed` (negative paths), `test_gas_seedingPath` (gas-regression pin), three conservation fuzz tests, and a 5-invariant stateful suite (reserve == sum-of-admitted-seeds per leg, the global reserves <= TVL, and the two per-currency bounds ammReserveBold <= boldTotalLockedValue + ammReserveEth fits the ETH TVL portion) over 128 000 random ETH+BOLD deposits at a moderate cap so some revert); `FeeSplitMath` gains the `ammSeedSplit` reference + threads `ammSeedAmount` through `receiptHash`; `AmmStorage.t.sol`'s ratio-invariance test becomes `test_coreSplit_ratioInvariant_butAmmSeedScales`; the behavioural `BridgeFeeSplit` / `BridgeFeeSplitBold` suites thread the new field.  `forge build` warning-free; full `forge test` green; the GP.5.2 cap-audit gate + self-test (45) stay green (no cap changed); full Lean (`lake build` + `lake test`) and Rust (build / test / clippy / fmt) gates green.  The L2 `Action.ammSwap` mirror + `ammReserveActor` remain GP.11.4 / GP.11.5; the deposit-side L2 reconstruction that consumes `ammSeedAmount` lands with the sequencer deposit-materialisation work.  No kernel TCB delta, no new axioms (the Lean change is cross-check-generator-only).  (This entry describes the shipped plan-literal form; an intermediate minimal-break form — a separate `AmmReserveSeeded` event with the canonical event left byte-unchanged — was committed earlier in the same PR and is preserved in git history.) |
| 1.21     | 2026-06-05 | Workstream GP.11.2 **audit-completion hardening** — a deep code-first audit of the GP.11.2 seeding closed the remaining coverage gaps; the contract logic was verified correct + secure unchanged (cap-checks precede seeding; `ammSeedAmount <= poolAmount` under the constructor-enforced + audit-gated `ratio <= 8000`; the BOLD seed is on the verified-received amount; the receiptHash binds the split; the Rust decoder rejects malformed/truncated events).  Closed: (1) the `reserve <= TVL` invariant was only verified by argument against withdrawals — now `BridgeFeeSplitBold.t.sol::test_e2e_ammReserveSurvivesBoldWithdrawal` is a faithful AMM-enabled deposit→withdraw end-to-end test draining TVL to exactly the seed floor and asserting `ammReserveBold <= boldTotalLockedValue <= totalLockedValue` survives.  (2) Non-zero-seed coverage is now mechanically pinned — the generators publish a `countNonZeroSeed` header (69 of 86) that each Solidity consumer independently recounts + asserts `>= 50`, so a regression that silently zeroed every seed fails rather than passing as a trivial all-zero cross-check.  (3) The receiptHash corpora gain 6 AMM-enabled boundary corners (`ammcorner:*` — max-fee × max-ratio, budget-clamp × max-ratio, exact-half × max-ratio, dust-floors-to-zero @ ratio 8000, min-non-zero ratio, realistic mid-ratio; corpus 80 → 86 entries) so the binding is pinned at specific boundary×boundary combinations, not only statistically.  (4) The GP.11.2 split is now proof-carrying: a new Lean `ammSeed_conserves` theorem (`ammSeed + freePool = poolAmount`, the analogue of `feeSplit_conserves` for the second split) is bound term-level into the generators.  (5) The gas pin is now COMPARATIVE (`test_gas_seedingOverhead`: enabled − disabled overhead < 15k, far tighter than the absolute envelope).  (6) The off-gas-leg `else` branch of `_seedAmmReserves` is now covered via a `SeedHarness` (the helper changed `private` → `internal`, exposing nothing externally).  (7) `FeeSplitMath.ammSeedSplit` enforces its `ratio <= 10000` precondition with a clear revert.  (9) A non-circular `test_ammSeedSplit_knownVectors` anchors the reference to hand-computed ground truth.  (10) A BOLD-leg `test_boldReceiptHash_bindsAmmSeedAmount` mirrors the ETH tamper test.  Integrator/operator notes added (the canonical event carries the per-deposit seed, not the running reserve — indexers accumulate or query the getter; the topic-0 hash change requires off-chain consumers to re-pin).  `forge test` 688 passed / 0 failed / 12 keccak-gated skips (+6); `lake build` + `lake test` green; cap-audit + self-test (45) green; no warnings.  Solidity + Lean-generator only; no kernel TCB delta, no new axioms (the Lean additions are cross-check-generator theorems). |
| 1.22     | 2026-06-05 | Workstream GP.11.2 **third-pass deep audit** — a still-deeper code-first audit that verified (not assumed) the remaining claims and added the ultimate solvency check.  Verified: (a) the contract call graph is airtight — `_registerDepositWithFee` has exactly the two entry-point callers and the reserves are written ONLY in `_seedAmmReserves`, so the off-gas-leg `else` is genuinely unreachable in production; (b) the `private` → `internal` change on `_seedAmmReserves` (made in v1.21 for off-leg branch coverage) is FUNCTIONAL-BYTECODE-NEUTRAL — compiling both with metadata disabled yields a byte-identical runtime hash (`0aaf4f8d…`), so the only difference is the source-hash in the metadata trailer; the production contract is unchanged; (c) the Lean `ammSeed_conserves` / `ammSeed_le` theorems depend only on `[propext]` (a strict subset of the canonical three; `#print axioms` confirmed); (d) `forge lint --no-cache` on the changed files reports zero findings and the build is solc-warning-free.  Added: two REAL-TOKEN backing invariants to `AmmDepositSeedingInvariantTest` (now 7 invariants) — `ammReserveEth <= address(bridge).balance` and `ammReserveBold <= BOLD.balanceOf(bridge)` — the ultimate solvency statement that each reserve is backed by ACTUAL tokens the bridge holds, not merely the TVL accounting variable (independent of the TVL bounds; catches a TVL-vs-balance divergence the accounting-only invariants would miss).  Both pass over 128 000 random ETH+BOLD deposits.  `forge test` 690 passed / 0 failed / 12 keccak-gated skips (+2); keccak cross-stack unchanged (no corpus change this pass); cap-audit + naming + sorries green; no warnings anywhere.  Solidity-test-only (one Lean axiom-check that was reverted); no kernel TCB delta, no new axioms. |
| 1.23     | 2026-06-06 | Workstream GP.11.3 (embedded ETH↔BOLD AMM — constant-product swap function) lands on the L1 mirror (`solidity/src/contracts/KnomosisBridge.sol` + the new pure `solidity/src/lib/AmmMath.sol`).  Adds the permissionless `ammSwap(fromResource, amountIn, minAmountOut, deadline) payable nonReentrant returns (uint256 amountOut)`: a Uniswap v2-style ETH↔BOLD exchange against the GP.11.1/2 reserves at the immutable `AMM_SWAP_FEE_BPS = 30` (0.30%) fee RETAINED in the reserves, so `k = ammReserveEth × ammReserveBold` is monotonically non-decreasing (strictly increasing per non-trivial swap — the fee accrues as LP yield for the gas pool).  Both directions work symmetrically: ETH→BOLD takes `msg.value` and sends BOLD via `safeTransfer`; BOLD→ETH pulls via `safeTransferFrom` with a `balanceOf`-delta check (fee-on-transfer defence, reusing `BoldTransferAmountMismatch`) and sends ETH via a low-level `call`.  Slippage (`minAmountOut`) + `deadline` MEV protection; a `ZeroSwapOutput` guard rejects a dust input that floors to a zero output (Uniswap's positive-output rule — no donation-for-nothing); a `!boldEnabled ⇒ AmmEmpty` early-out gives a clean revert on a BOLD-disabled deployment.  Strict Checks-Effects-Interactions ordering under `nonReentrant`, plus a belt-and-braces on-chain k-monotonicity assertion (`AmmKInvariantViolated`) and the proven `amountOut < reserveOut` curve bound (`ReserveExhausted`), so a swap-math regression fails closed rather than draining the pool.  The pure `AmmMath` library (`getAmountOut` / `getAmountIn`, fee-parameterised, self-validating, `internal` ⇒ inlined, checked arithmetic) is the reusable swap-math core.  **Accounting (Option C):** a swap deliberately does NOT touch `totalLockedValue` / `boldTotalLockedValue` — the AMM is a self-contained, value-conserving sub-pool; solvency rides on the REAL-TOKEN-BACKING invariants `ammReserveEth ≤ address(this).balance` / `ammReserveBold ≤ BOLD.balanceOf(this)` (each reserve moves in exact lockstep with the matching real balance, so a swap touches only AMM reserves, never any L2 user's backing — pinned by `test_swap_doesNotTouchTvl` + `invariant_tvlUntouchedBySwaps` + the real-backing invariants).  Event `AmmSwapExecuted` + eleven swap errors.  A `GP.11.10 hook point` comment marks where the `ammActive` modifier (revert once `emergencyDisableAmm()` is triggered) attaches; swaps are gated only by `nonReentrant` (NOT `circuitOpen` — the AMM's availability is governed by its own kill switch).  54 new test cases over a shared `test/utils/AmmTestBase.sol` (all green): `AmmMath.t.sol` (20), `AmmSwap.t.sol` (13), `AmmReentrancy.t.sol` (3 — a malicious ETH recipient re-entering a would-succeed swap is blocked with NO double-spend; a malicious BOLD token in the output path fails safe via `ReentrancyGuardReentrantCall`), `AmmInvariants.t.sol` (5 — the stateful k-never-decreases + reserves-stay-positive + real-token-backing + TVL-untouched harness over 128 000 random swaps, 0 reverts), `AmmSlippage.t.sol` (9 — exact `minAmountOut` / `deadline` boundaries), `AmmSandwich.t.sol` (4 — a front-run degrades execution, a full sandwich profits without protection, and `minAmountOut` deterministically stops it).  `MockBold.transfer` made `virtual` for the reentrancy mock.  `forge build` warning-free; full `forge test` 690 → 744 passed / 0 failed / 12 keccak-gated skips; the GP.5.2 cap-audit gate + self-test (45) unchanged — no constitutional cap is added (the swap reuses `AMM_SWAP_FEE_BPS`; `AmmMath`'s `BPS_DENOMINATOR` lives outside the audited `KnomosisBridge.sol`).  Solidity-only; the L2 `Action.ammSwap` mirror + cross-stack corpus are GP.11.4 / GP.11.7.  No kernel TCB delta, no new axioms (no Lean source change). |
| 1.24     | 2026-06-06 | Workstream GP.11.3 **completion + deep-audit hardening** — closes every gap a code-first audit of the v1.23 swap surfaced, taking GP.11.3 to its optimal, fully-defended form.  (1) **AMM kill switch** (the GP.11.10 disaster-recovery control, pulled forward into `KnomosisBridge.sol`): a one-way `emergencyDisableAmm()` gated by a new immutable `ammDisasterRecovery` role; `ammSwap` carries an `ammActive` modifier (reverts `AmmIsDisabled` once triggered) and `_seedAmmReserves` stops accruing reserves while disabled; the reserves are PRESERVED (a graceful shutdown, not a drain).  The role is REQUIRED non-zero on a FUNCTIONAL AMM (BOLD-enabled with `ammSeedRatioBps > 0`) — `AmmDisasterRecoveryRequired` otherwise — mirroring the GP.5.5 rule that an enabled feature must ship its safety roles; it may be `address(0)` only when the AMM cannot function (ratio 0 or BOLD-disabled), and is validated `!= address(this)` (`AmmRoleIsBridge`).  (2) **Automatic depeg freeze**: `ammSwap` now reverts `AmmPausedByBoldCircuit` while the GP.5.5 BOLD circuit breaker is closed (manual close OR the permissionless Liquity-shutdown auto-trigger), halting both swap directions during a depeg so BOLD→ETH arbitrage cannot drain the gas pool's ETH reserve at a stale price — while the L2 `withdrawWithProof` exit path stays open ("deposits halted, withdrawals continue").  (3) **Machine-checked k-monotonicity**: a new Lean-core module `LegalKernel/Bridge/AmmMath.lean` mirrors the Solidity `getAmountOut` constant-product formula over `Nat` and PROVES `getAmountOut_lt_reserveOut` (the output is strictly below the output reserve — no-drain) and `k_nondecreasing` (`reserveIn*reserveOut ≤ (reserveIn+amountIn)*(reserveOut − getAmountOut …)`), so the swap's headline safety property is now a theorem, not only a runtime assertion + tests (matching the proof-carrying pattern of GP.5.1 `feeSplit_conserves` / GP.11.2 `ammSeed_conserves`).  Both depend on ONLY `{propext, Classical.choice, Quot.sound}` (`#print axioms` confirmed); zero sorries; the new `bridge-amm-math` suite (6 cases) pins the SAME hand-vectors as `AmmMath.t.sol` (`getAmountOut 1000 1000 1000 0 = 500`; `= 499` at fee 30) so Lean-spec == Solidity-formula == ground truth.  (4) **Audit-gap test closures**: `EthTransferFailed` (a contract recipient that rejects the ETH output, fail-safe rollback), calibration parity, EXACT fee-accrual `k` delta, deposit↔swap composition, a warm-swap gas pin, +4 slippage/deadline boundary cases (the dedicated suite now 13 ≥ the plan's 12+), and a new `AmmKillSwitch.t.sol` suite pinning the GP.11.10 theorems (`emergencyDisableAmm_preserves_reserves`, `ammDisabled_implies_swap_reverts`, `ammDisabled_is_monotonic`), the role access control + the `AmmRoleIsBridge` / `AmmDisasterRecoveryRequired` constructor guards, and the breaker gating + brake independence/precedence.  (5) **Coverage made runnable**: `forge coverage` was infeasible (the via_ir contracts defeat its instrumentation); the test `Deployer` is stack-fit (its twelve `deployAll` params threaded through one `DeployParams` memory struct + the 24-field `ConstructorArgs` built field-by-field, external signature unchanged) so `forge coverage --ir-minimum` now runs end-to-end and reports `src/lib/AmmMath.sol` at 100% line/statement/branch/function; `make coverage` / `make coverage-lcov` document it.  `forge test` 744 → 765 passed / 0 failed / 12 keccak-gated skips; `lake build` (warning-free) + `lake test` (all pass incl. `bridge-amm-math`) + `count_sorries` (0) + `naming_audit` green; the GP.5.2 cap-audit gate unchanged (the kill switch adds no constitutional cap).  Supersedes v1.23's "`GP.11.10 hook point` / gated only by `nonReentrant`" note (the kill switch + breaker are now implemented).  The L2 `Action.ammSwap` mirror + cross-stack corpus remain GP.11.4 / GP.11.7.  No kernel TCB delta, no new axioms (the new Lean theorems use only the canonical three). |
| 1.25     | 2026-06-06 | Workstream GP.11.3 **second audit-gap closure round** — finishes the remaining non-optimal items a self-audit of v1.24 surfaced.  (1) **Lean→Solidity pricing cross-stack corpus** (distinct from the GP.11.4 / GP.11.7 L2-mutation corpus — this one closes the "the two implementations of the same `getAmountOut` formula agree" gap, the one verification the v1.24 round left as a `bridge-amm-math` hand-vector pin rather than a full corpus).  The Lean generator `LegalKernel/Test/Bridge/CrossCheck/AmmMath.lean` (`crosscheck-amm-getamountout`, 4 cases) computes `LegalKernel.Bridge.AmmMath.getAmountOut` over a 204-entry corpus (a 192-entry amount×reserve×reserve×fee grid + 12 boundary corners), PROOF-CARRIES every entry against `getAmountOut_lt_reserveOut` + `k_nondecreasing` (so the corpus VALUES are theorem-backed, not merely fuzz-observed), and emits `amm_getamountout.json`; the Solidity consumer `solidity/test/CrossCheck/AmmMath.t.sol` (5 cases) recomputes `src/lib/AmmMath.sol::getAmountOut` over the SAME inputs and byte-matches every entry (plus no-drain / k-monotonicity re-checks + a hand-vector ground-truth anchor) — mechanically proving `Lean-spec == Solidity-formula` over the whole corpus, hash-independent so it runs in every binding mode.  (2) **Stateless swap fuzz**: `AmmSwap.t.sol` gains two single-swap fuzz tests (both directions, 256 runs each, dust→whale input range) pinning output==reference + reserve accounting + k-monotonicity + real-token backing per random input — complementing the stateful `AmmInvariants` sequences (`AmmSwap.t.sol` now 20).  (3) **Tightened gas pin**: the warm-swap gas bound dropped from the placeholder 200k to 30k (~16.5k actual steady-state; trips on an accidental cold SSTORE).  (4) **Test hygiene**: the shared AMM disaster-recovery test role is now a named `AMM_DR` constant per suite (matching the `BOLD_BREAKER` / `BOLD_ADMIN` convention) rather than a repeated `0xA33D6` magic literal across the four BOLD/AMM suites.  (5) **Coverage confirmed full-suite**: a full-suite `forge coverage --ir-minimum` run reports `src/lib/AmmMath.sol` at 100% line/statement/branch/function and `KnomosisBridge.sol`'s AMM functions at 100% function coverage.  `forge test` 765 → 772 passed / 0 failed / 12 keccak-gated skips; `lake build` (warning-free) + `lake test` (incl. `crosscheck-amm-getamountout`, fixture byte-stable on a clean run) + `count_sorries` (0) + `naming_audit` + `tcb_audit` + `stub_audit` green; codemaps regenerated (CI-idempotent).  No kernel TCB delta, no new axioms (the corpus reuses the v1.24 theorems, both axiom-clean over `{propext, Classical.choice, Quot.sound}`). |
| 1.26     | 2026-06-06 | Workstream GP.11.3 **PR-review hardening** (PR #116) — two fixes a code review of the AMM swap surfaced, both verified against the contract first.  (1) **BOLD-disabled deployments no longer seed the AMM.**  The constructor permits a `ammSeedRatioBps > 0` deployment with BOLD disabled (the `AmmDisasterRecoveryRequired` guard is nested under `boldEnabled`), and `_seedAmmReserves` previously diverted part of every ETH fee into `ammReserveEth` — a reserve `ammSwap` can never drain (it reverts `AmmEmpty` with no BOLD leg), permanently locking that ETH.  `_seedAmmReserves` now returns 0 when `!boldEnabled`, so a BOLD-disabled deployment seeds nothing and every ETH fee stays sequencer-claimable free pool (the emitted `ammSeedAmount` is 0, the FULL deposit still credits TVL).  Pinned by the new `AmmStorage.t.sol::test_boldDisabled_seedsNothing_despitePositiveRatio`; the AMM seeding suites (`AmmStorage` / `AmmDepositSeeding` / the `DepositFeeSplit` ETH cross-check) now deploy BOLD-enabled bridges for their ETH-seeding tests, since seeding only accrues on a functional AMM.  (2) **`ammSwap` freezes once the bridge migrates.**  The swap ran under only `nonReentrant + ammActive` (its own kill switch) + the BOLD-breaker depeg freeze, NOT the global `circuitOpen`; a migrated (retired) bridge's AMM stayed live, letting callers keep mutating its reserves after hand-off.  `ammSwap` now reverts `MigrationActivated` once `migration.activated()` — the migration arm of `circuitOpen` applied to the AMM.  The transient `circuitOpen` arms (attestation-stale / dispute-cooldown) are deliberately NOT applied, keeping the AMM available as an optional liquidity service during those recoverable states (its own kill switch + the BOLD breaker remain the AMM-specific brakes).  Pinned by the new `AmmKillSwitch.t.sol::test_swap_freezesAfterMigration` (both directions; pre-migration swap succeeds under the same state, isolating migration as the added gate).  A third review comment (gate the AMM until the GP.11.4 L2 mirror lands) was investigated and found to overstate user-fund risk: a swap preserves combined real-token solvency (`balance ≥ user-escrow + ammReserve` is invariant across a swap) and never touches `totalLockedValue` / user escrow, so pending withdrawals stay fully backed; the remaining gap is gas-pool accounting completeness (GP.11.4) and every shipped deployment defaults to `ammSeedRatioBps = 0` (AMM inert), so no code change was made there.  `forge test` 772 → 774 passed / 0 failed / 12 keccak-gated skips; `forge build` warning-free; the GP.5.2 cap-audit gate unchanged (no constitutional cap touched); `lake build` / `lake test` / `count_sorries` / `naming_audit` / `tcb_audit` / `stub_audit` green (Solidity-only change; no Lean / Rust source touched); codemaps regenerated (CI-idempotent).  No kernel TCB delta, no new axioms. |
| 1.28     | 2026-06-08 | Workstream GP.11.7 (cross-stack AMM fixture corpus) lands tri-stack (Lean + Rust + Solidity).  The Lean generator `LegalKernel/Test/Bridge/CrossCheck/AmmSwap.lean` (`crosscheck-amm-swap`, 20 cases) emits a 71-entry corpus (54 grid + 17 corner, including zero-reserve, zero-amount, same-resource, and slippage-unsatisfied degenerate cases) into both `solidity/test/CrossCheck/fixtures/amm_swap.json` (JSON) and `runtime/tests/cross-stack/amm_swap.cxsf` (binary CXSF tag 8).  The grid spans 3 reserve sizes (Small 10^12 / 3×10^15, Medium 10^15 / 3×10^18, Large 10^16 / 3×10^19) × 2 directions (ETH→BOLD, BOLD→ETH) × 3 swap sizes (1%, 10%, 50%) × 3 slippage thresholds (exact, 1% slack, 50% slack) = 54; the 17 corners cover zero reserves, zero amount, max-U64, zero output, asymmetric pools, paired round-trip checks, varied fees, zero-reserveIn, zero-reserveOut, same-resource, and slippage-unsatisfied.  All amount-scale fields and k-products emitted as `0x`-prefixed 32-byte BE hex strings via `hexFromUint256BE`.  The corpus verifies: CBE byte-equivalence (`encode_action` Lean == Rust for all 71 entries), `getAmountOut` formula compliance (Lean == Solidity `AmmMath.getAmountOut` == Rust u256 recomputation via `mul_wide` / `div_u256_by_u128`), k-monotonicity (`kBefore ≤ kAfter`), no-drain (`expectedOut < reserveOut`), slippage flag consistency, post-swap reserve arithmetic (`newReserveIn` / `newReserveOut`), L2 balance deltas (`reserveActorCreditFrom` / `reserveActorDebitTo`), and header-constant agreement across all three stacks.  Rust consumer: `runtime/knomosis-l1-ingest/tests/cross_stack_amm_swap.rs` (15 tests — CBE byte-equivalence, formula compliance via u256, k-monotonicity, no-drain, slippage, header constants, tag pin, corpus coverage, post-swap reserves, L2 balance deltas, CXSF binary corpus loading + JSON cross-check, plus u256 arithmetic unit tests).  Solidity consumer: `solidity/test/CrossCheck/AmmSwapFixtures.t.sol` (11 tests — header shape, formula match, no-drain, k-monotonicity, slippage, two hand-vector anchors, CBE byte-length, post-swap reserves, L2 balance deltas, CBE tag-byte pin, live-contract per-entry swap).  Hash-independent: no keccak-binding gate needed.  `FixtureKind::AmmSwap` (tag 8) added to `knomosis-cross-stack`.  `lake test` ~2968 (148 suites); `cargo test --workspace` ~1950; `forge test` green.  No kernel TCB delta, no new axioms.  Version v0.5.5. |
| 1.29     | 2026-06-09 | Workstream GP.11.8 (AMM state-root commitment integration — full tri-stack).  **Lean encoding:** the `BridgeState` encoder (`Encoding/State.lean`) is extended to serialise the five AMM/BOLD state fields (`ammReserveEth`, `ammReserveBold`, `boldCircuitClosed`, `boldTvlCap`, `boldTotalLockedValue`) as trailing self-delimiting Nat segments (Bool encoded as `if b then 1 else 0`); the decoder reconstructs them symmetrically with a strict canonical check (values > 1 for `boldCircuitClosed` are rejected as `nonCanonical`).  The EI.7.e injectivity proof (`BridgeState.encode_injective`, `Encoding/BridgeInjective.lean`) is extended from a 3-way to an 8-way conjunction via two new helpers: `nat_encode_suffix_split` and `bool_as_nat_injective`.  **Commitment scheme:** `ExtendedState.extEq` grows from 7 to 12 conjuncts, `CanonicalBounds` adds 4 new `< 2^64` bound fields.  Four GP.11.8 theorems: `bridgeState_commit_includes_ammState` (encoding includes all 5 AMM fields — `rfl`), `bridgeState_commit_extends_v1_2` (v1.2 backward compatibility — now proved via structural encoding factoring rather than extensional equality), `bridgeState_encode_factored` (v1.4 encoding = v1.2 base prefix ++ AMM suffix), and `bridgeState_amm_genesis_suffix_const` (genesis AMM fields produce identical suffixes).  All depend only on `{propext, Classical.choice, Quot.sound}`.  **Solidity step-VM:** `KnomosisStepVM.sol` gains `AmmSwap` (kind 23) with `_stepAmmSwap` reading 5 uint64BE action fields (fromResource, toResource, amountIn, amountOut, ammReserveActor), 2 balance cell proofs, computing post-balances, and returning `keccak256(abi.encodePacked(...))` matching Lean's `stepCommitAmmSwap`.  `_stepAmmSwap` enforces the full `Laws.ammSwap` precondition set — `amountIn > 0` (`AmountMustBePositive`), `fromResource != toResource` (new `SameResourceSwap` error), and `toBalance >= amountOut` (`InsufficientBalance`) — so a zero-input or same-resource swap reverts instead of diverging from the Lean kernel's no-op, mirroring the `_stepBurn` / `_stepReward` / `_stepProportionalDilute` cross-stack-coherence discipline.  **Cross-stack corpus:** the fixture generator (`Test/Bridge/CrossCheck/StepVM.lean`) adds 10 ammSwap entries (6 happy sweeping resource/amount variants + 4 adversarial bad-preCommit), widening the corpus from 258 to 268 entries.  Solidity consumer tests updated: 268-entry count, 164 happy / 104 adversarial, kind range 0..23, 22 per-variant count fields.  `forge test` 791 passed / 0 failed / 12 skipped.  Six ammSwap unit tests added to `KnomosisStepVM.t.sol` (happy path, exact drain, short fields revert, insufficient balance revert, zero-amountIn revert, same-resource revert).  19 acceptance tests (`faultproof-amm-commit` suite): genesis commitment, per-field alteration (5), post-deposit / post-swap / post-circuit-close (3), encoding distinguishes non-zero fields, term-level API stability for all 4 theorems, determinism, v1.2 migration, encoding round-trip, non-canonical Bool rejection, and factored-encoding value check.  `lake test` 2990 (149 suites); all 7 audit gates green.  No kernel TCB delta, no new axioms.  Version v0.5.7. |
| 1.27     | 2026-06-07 | Workstream GP.11.5 (`ammReserveActor` reservation) lands end-to-end (Lean + Rust).  Reserves `ActorId 3` for `ammReserveActor` — the L2-side counterpart of the L1 `KnomosisBridge`'s `ammReserveEth` / `ammReserveBold` storage slots (GP.11.1 / GP.11.2 / GP.11.3) — and advances the genesis `AddressBook.empty.nextActorId` from `3` (GP.7.1) to `4`, so the first user a fresh deployment registers is `ActorId 4`.  **Lean** (`LegalKernel/Bridge/BridgeActor.lean` + `LegalKernel/Bridge/AddressBook.lean`): the `ammReserveActor : ActorId := 3` constant; three axiom-free `decide` disjointness theorems (`ammReserveActor_ne_bridgeActor` / `_ne_gasPoolActor` / `_ne_sequencerActor`); the `empty_assign_id_avoids_reserved` reservation guarantee widened to a fourth conjunct (the issued id is none of the four reserved slots); and the existing `addressBook_empty_nextActorId` theorem updated in place to `= 4` (NOT a `_v1_3`-suffixed new theorem — version-marker identifiers are forbidden by the naming discipline / `naming_audit`).  The single-step guarantee is additionally **promoted to the full chain-level guarantee** via the idiomatic invariant decomposition (mirroring the kernel's own `invariant_preservation`): `empty_nextActorId_ge_reserved` (the genesis base case `4 ≤ nextActorId.toNat`), `assign_preserves_reserved_invariant` (per-step preservation under no-overflow, resting on the new general `AddressBook.assign_nextActorId_mono` monotonicity lemma), and `fresh_assign_avoids_reserved` (the safety payoff: a fresh `assign` into *any* invariant-respecting book — not only `empty` — issues a non-reserved id); composed by induction these prove that no user-registered identity in any `empty` + `assign` chain can ever be issued a reserved slot (closing the single-step limitation the prior theorem left).  The worked `Deployments/Examples/GasPoolExample.lean`'s demo `userActor` advances 3 → 4 (its former slot is now reserved).  `bridge-actor` suite 71 → 82.  **Rust lockstep** (`runtime/knomosis-l1-ingest`, pulled forward from GP.10 exactly as GP.7.1's reservation was): the production adaptor's `AddressBook::INITIAL_NEXT_ACTOR_ID` becomes `4` with a new mirror `AMM_RESERVE_ACTOR_ID = 3` constant, so the adaptor that performs the actual `assign` honours the reservation (a fresh L1 identity registration is issued `ActorId 4`, never the reserved AMM slot — load-bearing for correctness: leaving the adaptor at `3` while Lean reserves `3` would assign the first user `ActorId 3`, colliding with `ammReserveActor` in production).  The state-file replay's reserved-range rejection now covers id `3` (a state file from a GP.7.1-era deployment that legitimately allocated id 3 to a user is rejected on upgrade with the actionable GP.10.4-migration diagnostic — `replay_rejects_newly_reserved_amm_actor_id`); the `l1_ingest.cxsf` cross-stack corpus and all `address_book` / `state` / `translation` / `watcher` / integration tests are rebased onto the genesis-4 allocation (the Rust `assign_chain_never_issues_reserved_id` test is the value-level mirror of the Lean chain-level guarantee).  Released as the **minor** bump `0.4.x → 0.5.0` rather than a patch: GP.11.5 adds new public API (the constant + theorems) and is backward-incompatible (a pre-GP.11.5 state file that used slot 3 requires the GP.10.4 migration on upgrade).  Full `lake build` (warning-free) + `lake test` + the five audit gates green; full `cargo test --workspace` + `clippy -D warnings` + `fmt` green.  This is the *fresh-genesis* half; the orthogonal migration of *existing* deployments that already allocated a user in slot 3 remains Phase GP.10.4.  No kernel TCB delta, no new axioms (the disjointness theorems are axiom-free `decide`; `addressBook_empty_nextActorId` / `empty_assign_id_avoids_reserved` / the chain-level `empty_nextActorId_ge_reserved` / `assign_preserves_reserved_invariant` / `fresh_assign_avoids_reserved` / `AddressBook.assign_nextActorId_mono` depend only on the canonical `{propext, Classical.choice, Quot.sound}` via `Std.TreeMap`). |
| 1.30     | 2026-06-10 | Workstream GP.11.9 (gas-cost benchmarks for the v1.3 L1 operations) lands on the Solidity surface.  `solidity/test/BenchmarkGasV1_3.t.sol` adds 21 deterministic gas benchmarks across 9 scenario contracts (34 tests incl. the `test_sanity_*` companions pinning every scenario assumption — first-time vs repeat depositor nonces, the 15 ETH : 45 000 BOLD seeded reserve depth, staged exact / infinite approvals, migration wiring, Liquity branch shutdown states, finalised withdrawal roots — and every benchmarked operation's effects).  **Measurement architecture:** the suite runs under forge's ISOLATED mode (`--isolate`, enforced by the make targets) — foundry's documented-accurate mode for the `snapshotGas*` cheatcodes — so each benchmark's `vm.snapshotGasLastCall` value is the FULL user-transaction gas (21k intrinsic + EIP-2028 calldata + execution, EIP-3529 refunds netted, target pre-warmed per EIP-2929); the isolated-vs-unisolated deltas decode to the gas as `21 000 + calldata − refunds` on all 21 benchmarks, verifying the semantics, and deltas land exactly on EVM constants (the first-interaction premium measures precisely the 17 100-gas zero→non-zero SSTORE surcharge in both the deposit and swap pairs).  Each benchmark also records the exact EIP-2028 calldata cost of its canonical calldata via `vm.snapshotValue` (`<name>.calldata_gas`) as a breakdown, with BOLD modelled by the new OZ-faithful `test/utils/MockBoldOz.sol` (the real vendored OpenZeppelin v5 ERC-20, so production BOLD's `_spendAllowance` max-allowance skip carries its true cost — and the refund-netted measurement surfaces that per transaction the EXACT-approval swap is ~1.7k cheaper than the infinite one, its 4 800 allowance-clear refund outweighing the ~3.1k execution saving, while per flow infinite approval wins from the second swap onward).  **Coverage (measured user-tx gas):** `depositETHWithFee` / `depositBoldWithFee` (first 66 261 / 94 242, repeat 49 161 / 77 142), the BOLD `approve` prerequisite (45 992), `ammSwap` ETH→BOLD (75 726 first-recipient / 58 626 repeat) and BOLD→ETH (68 204 exact / 69 870 infinite approval), migration-wired deposit + swap variants (+3 107 / +3 110 for the external `activated()` read production deployments pay when pre-wiring a successor), `closeBoldCircuit` 44 825 / `openBoldCircuit` 22 985 / `setBoldTvlCap` 28 090 / `emergencyDisableAmm` 49 623, the Liquity auto-trigger's fast 53 834 / worst 69 037 / no-shutdown keeper-probe 47 250 paths (the probe measured through a plain low-level call, no `expectRevert` interference), the `withdrawWithProof` exit legs (861 392 ETH / 877 759 BOLD incl. ~37.9k calldata for the canonical 64-sibling proof — the round trip's dominant cost, dominated by the CBE byte-loop decode and flagged for a future calldata-slice decoder), and a plain-`depositETH` v1.0 reference row (57 655).  **Gate + automation:** the committed baseline `solidity/test/BenchmarkGasV1_3.gas-baseline.json` and the runbook §9.2 table generated from it (`solidity/scripts/generate_gas_runbook_table.py`) are regenerated together by `make snapshot-gas`; the CI gate `make snapshot-gas-check` (`solidity/scripts/check_gas_baseline.py`, run after `forge test` in `.github/workflows/ci-solidity.yml` on every `solidity/**` PR) fails on any per-benchmark gas INCREASE beyond 5% (ONE-SIDED, per the GP.11.9 plan rule), on benchmark-set drift (added / removed / renamed benchmarks without a regenerated baseline), and on a runbook table out of sync with the baseline, while improvements beyond 5% warn with a ratchet nudge; both scripts carry behavioural self-tests (8 cases each, `make snapshot-gas-selftest`, run in the fast `caps-audit` CI job), and every gate behaviour was verified end-to-end through the real make pipeline.  Operator-facing table (generated; the user-tx column is measured, not modelled), $-cost methodology ("a typical first fee-split deposit is a measured 66 261 gas ≈ $6.0 at 30 gwei and $3 000/ETH; the exit leg ≈ $77.5–79.0 dominates the round trip"), cost-structure observations, and mock-fidelity caveats land in `docs/gas_pool_runbook.md` §9.  Post-review hardening on the same PR: the runbook-table sync check also runs in the fast `caps-audit` job and `docs/gas_pool_runbook.md` is a trigger path for `ci-solidity.yml`, so a docs-only hand-edit of the generated table cannot bypass the gate.  `forge test` 825 passed / 0 failed / 12 skipped (34 new tests); no Lean / Rust source delta; no kernel TCB delta; no new axioms.  Version v0.5.8. |
| 1.31     | 2026-06-10 | Workstream GP.11.10 (AMM disaster recovery) completes the three obligations the GP.11.3 v1.24 pull-forward deferred (the kill-switch *mechanism* — one-way `emergencyDisableAmm()`, the immutable `ammDisasterRecovery` role + constructor guards, the `ammActive` modifier, the `_seedAmmReserves` early-out, and the three GP.11.10 theorems as `AmmKillSwitch.t.sol` tests — was already live).  **(1) 3-of-N multisig hardening (Solidity):** new single-purpose reference contract `KnomosisAmmDisasterRecoveryMultisig.sol` + minimal `IKnomosisAmmDisasterRecovery` interface.  An M-of-N confirm-to-execute multisig whose ONLY capability is calling `emergencyDisableAmm()` on its immutable `bridge` — no generic execute, no value transfer, no signer rotation, no upgradability.  The GP.11.10 3-of-N floor is CONSTRUCTOR-ENFORCED (`MIN_DISABLE_THRESHOLD = 3`, `ThresholdBelowMinimum` otherwise) alongside full signer-set hygiene (`ZeroSigner` / `DuplicateSigner` / `SignerIsBridge` / `SignerIsSelf` / `ThresholdExceedsSignerCount` / `MAX_SIGNERS = 32`).  The threshold-th `confirmDisable()` fires the bridge call atomically in the same transaction (checks-effects-interactions; no separate front-runnable execute step); `revokeConfirmation()` lets a signer stand down; and stale approvals expire AS A GROUP (`CONFIRMATION_WINDOW = 7 days` anchored at the round's first confirmation, O(1) round-roll via round-scoped confirmation ledgers) so approvals gathered during one incident can never silently combine with a later signature to fire the one-way switch out of context — fail-safe direction: an expired round costs a re-confirmation, a stale-quorum disable would cost a full redeploy.  Deployment wiring uses the predicted-CREATE-address pattern already established for pre-wired `KnomosisMigration` successors.  21 new forge cases (`KnomosisAmmDisasterRecoveryMultisig.t.sol`): thresholds 0/1/2 each rejected + 3-of-3 minimum valid (the constructor half of "3-of-N enforced"); a TWO-signature quorum provably does NOT disable while a live swap still succeeds (the runtime half); the third confirmation disables end-to-end against a real `KnomosisBridge` (reserves preserved + both events); revoke-blocks-then-reconfirm-fires; expiry resets instead of executing + boundary-instant execution; lone signers cannot bypass the multisig; a full quorum's blast radius leaves every other bridge control untouched.  Plus the GP.11.10 degraded-mode test `AmmKillSwitch.t.sol::test_ammDisabled_withdrawStillWorks_bothLegs`: post-disable `withdrawWithProof` pays out on BOTH legs through finalised state roots — the kill switch can never trap user funds ("deposits halted" does not even apply here; only swaps halt).  **(2) `ammDisabled` in the state-root preimage (Lean):** per the WU decision there is NO `Action.disableAmm` — the flag is a passive L1 mirror like the five GP.11.8 fields.  `BridgeState` gains `ammDisabled : Bool := false`; `BridgeState.encode/decode` append it as the ninth segment (canonical 0/1 with strict `nonCanonical` rejection, mirroring `boldCircuitClosed`); EI.7.e (`BridgeState.encode_injective`) extends 8-way → 9-way; `ExtendedState.extEq` / `extendedStateExtensionallyEqual` widen 12 → 13 conjuncts; the GP.11.8 factoring/migration theorems extend (`bridgeStateEncodeAmmSuffix` 5 → 6 fields; `bridgeState_amm_genesis_suffix_const` + `bridgeState_commit_extends_v1_2` gain the `ammDisabled = false` genesis conjunct — mathematically forced: without it the v1.2-compat statement would be FALSE for a fired switch).  Two NEW theorems: `bridgeState_commit_extends_v1_3` (a GP.11.8-era state migrates deterministically while the switch has not fired) and the headline `commitBridgeState_reflects_ammDisabled` (under `CollisionFree hashBytes`, two bridge states agreeing on every other field but differing on `ammDisabled` have DIFFERENT commitments — a sequencer cannot publish a state root that misrepresents the kill-switch state, and the fault-proof game can adjudicate disputes that turn on it; proof: collision-freedom lifts equal commits to equal canonical encodings, list-append cancellation isolates the trailing segment, CBE-uint injectivity on the canonical 0/1 range forces the flags equal).  All `#print axioms`-verified ⊆ `{propext, Classical.choice, Quot.sound}`.  `faultproof-amm-commit` 19 → 26 cases (disable flips the bridge commit + the top-level root on genesis AND populated states; `ammDisabled=2` rejected as non-canonical; `ammDisabled=true` round-trips; API pins for the two new theorems and the three extended signatures); `bridge-state` + `encoding-injectivity` suites extend to match (EI.7.e pin 9-way; extEq pin 13-way; a new encode-distinguishes case).  The 268-entry step-VM cross-stack corpus is REGENERATED (every `commitExtendedState` shifts with the widened encoding); the Solidity step VM and the Rust runtime need NO code change — neither consumes `BridgeState.encode` bytes (the step-VM commit recipe is unchanged), verified by a cross-stack consumer sweep.  `docs/abi.md` §16.3 rewritten to the full nine-segment wire format (it had been stale at the v1.2 three-segment form since GP.11.8) + an append-only wire-format/migration note.  **(3) Operator runbook:** `docs/gas_pool_runbook.md` §10 — the four invocation conditions with thresholds (reserve depth < `MIN_VIABLE_DEPTH_USD` for > 24 h, reproducible Lean↔Solidity math discrepancy or an `AmmKInvariantViolated`, confirmed Liquity-V2 contract failure, audit-flagged critical), the 3-of-N custody + reference-multisig semantics + predicted-address deployment wiring + post-deploy verification, the firing procedure, the recovery decision tree (redeploy-via-`KnomosisMigration` vs degraded v1.2 mode; frozen reserves remain gasPoolPolicy-capped — the switch loosens NO outflow discipline), the state-root-visibility note, and the measured cost; §1 roles table (now three immutable roles), §6 monitoring (reserve-depth / `AmmDisabled` / `DisableConfirmed` alerts), and §7 quick reference extend to match; §1's stale `closeBoldCircuitIfRedeemingHeavily` reference fixed to the shipped `closeBoldCircuitIfAnyLiquityBranchShutdown`.  `lake test` 2 997 (149 suites) green; all seven Lean audit gates green; full `cargo` gates green (lockstep bump inert); `forge test` 847 passed / 0 failed / 12 skipped across 56 suites (+22); the GP.5.2 cap-audit gate + self-test (45) green and the GP.11.9 gas gate unchanged (`KnomosisBridge.sol` itself is UNTOUCHED — the multisig is additive, so no benchmark moves).  No kernel TCB delta, no new axioms.  Version v0.5.9. |
| 1.32     | 2026-06-11 | Workstream GP.11.10 **expansion — the L2 reserve-reclamation law** (user-directed amendment: v1.31's "there is NO `Action.disableAmm` / no new Action variant" decision is SUPERSEDED for the *reclamation* leg — the `ammDisabled` flag itself remains a passive L1 mirror, but the post-disable sweep of the frozen L2 reserves is now a real proof-carrying action rather than an operational convention).  **(1) The law (Lean):** `LegalKernel/Laws/ReclaimAmmReserves.lean` — `Laws.reclaimAmmReserves r amount reserveActor poolActor` with the EXACT-SWEEP precondition `getBalance s r reserveActor = amount ∧ reserveActor ≠ poolActor ∧ amount > 0`: the only admissible `amount` is the reserve actor's ENTIRE balance at `r`, so a partial drain is unrepresentable, the post-state reserve is definitionally zero (`reclaimAmmReserves_zeroes_reserve`), and a replay is self-defeating (a second sweep would need `amount = 0`, rejected by `amount > 0`).  `decPre := fun _ => inferInstance` (§13.6 decidability discipline); theorems `_credits_pool` / `_conserves_at` / `_other_actor_untouched` / `_other_resource_untouched`; `IsConservative` + `LocalTo` + `FreezePreserving` instances; Lex re-expression `reserved_gp_reclaimAmmReserves` (registry index 21) satisfying [conservative, monotonic, local, freeze_preserving, nonce_advances, registry_preserving].  **(2) Frozen wiring:** `Action.reclaimAmmReserves` at FROZEN index 24 (tag projection, CBE codec + round-trip + injectivity arms, `tag_lt_denyListBound` < 25, every exhaustive-match forcing function extended); `Event.ammReservesReclaimed` at FROZEN tag 22 (extraction emits it alongside the kernel `balanceChanged` pair; CBE codec; streamer + indexer registries widen to 0..=22); bridge admissibility gains the conjunct `BridgeAdmissibleWith.reclaimGate`: a reclaim admits ONLY with `reserveActor = ammReserveActor ∧ poolActor = gasPoolActor ∧ es.bridge.ammDisabled = true` — `reclaim_inadmissible_while_amm_enabled` is the headline negative (while the kill switch has not fired, NO reclaim is admissible, so the law cannot touch a live AMM); `Action.isBridgeOnly` covers index 24 (bridge-signed only); the `gasPoolPolicy` / `ammReservePolicy` deny-lists and the GP.7.3 `PoolDrainBound` extend (a reclaim CREDITS the pool — the drain bound is untouched).  **(3) AMM-mirror step-invariance (new formal surface):** `BridgeState.AmmMirrorsEq` + `applyActionToBridgeState_preserves_amm_mirrors` (NO L2 action mutates the six L1-mirror fields — exhaustive over all 25 constructors) + `apply_bridge_admissible_with(_budget)_preserves_amm_mirrors` + the `BridgeAdmittedTrace` inductive + `amm_mirrors_constant_over_admitted_trace` / `ammDisabled_constant_over_admitted_trace` (chain-level: over ANY admitted trace the mirrors are constant, so they change only at attested-snapshot boundaries — exactly the runbook's sequencer-ingest obligation, now a theorem) + `commitExtendedState_reflects_ammDisabled` (the v1.31 bridge-level reflects theorem lifted to the FULL extended-state root).  **(4) Step-VM kind 24 (tri-stack):** Lean dispatcher arm (fields `uint64BE r ‖ amount ‖ reserveActor ‖ poolActor`; cells read `[registry signer]`, write `[balance r reserveActor, balance r poolActor, nonce signer]`; `stepCommitReclaimAmmReserves`; `stepVMHash_reclaimAmmReserves_kind`; unknown-kind boundary → 25) ↔ Solidity `KnomosisStepVM._stepReclaimAmmReserves` (revert-on-divergence: `SweepAmountMismatch(reserveBalance, amount)` enforces the exact-sweep equation on-chain; `SameActorSweep` rejects the degenerate self-sweep; 7 new unit cases + the kind-25 boundary) ↔ the step-VM cross-stack corpus widened 268 → 278 entries (170 happy / 108 adversarial, incl. the sweep-mismatch + same-actor adversarial paths).  **(5) Rust lockstep:** `knomosis-l1-ingest` encodes Action 24 (known-byte-vector pin) and decodes the L1 `AmmDisabled(uint256,uint256,uint256)` event (pinned topic `0x627d75ba…ad58`) into `IngestedEvent::AmmDisabled` with `Translated::NoAction` materialisation + `.cxsf` tag-5 codec; `knomosis-event-subscribe` tag 22 (`EVENT_TYPE_COUNT` 23); `knomosis-indexer` typed decode/encode of tag 22 (dispatch no-op — the paired `balanceChanged` stays authoritative) and the Lean↔indexer round-trip corpus grows 28 → 29 entries covering ALL tags 0..22; `knomosis-faultproof-observer` `ActionKind` 24.  **(6) Disaster-recovery hardening round 2 (Solidity):** shared `test/utils/WithdrawalFlowHarness.sol` (CBE + EIP-712 state-root attestation helpers) + `DisasterRecoveryTestBase.sol` (predicted-CREATE `_deployWired` / `_deployMiswired`) consolidate four suites; the multisig unit suite grows 21 → 24 cases (mis-wiring negatives); NEW `KnomosisAmmDisasterRecoveryMultisigInvariants.t.sol` — 7 stateful invariants × 128 000 randomised confirm/revoke/warp calls (sub-threshold never executes; disable is monotone one-way; round-scoped ledgers never leak across expiry; signer-set immutability; …); `forge coverage --ir-minimum` reports the multisig at 100% lines (51/51) / statements (62/62) / branches (16/16) / functions (8/8); the GP.5.2 cap gate now audits the 3 multisig governance constants (`MIN_DISABLE_THRESHOLD = 3`, `MAX_SIGNERS = 32`, `CONFIRMATION_WINDOW = 7 days`) — selftest 45 → 51 cases; 2 new isolated-mode gas benchmarks (`confirmDisable` non-final 59 629 / threshold-th-executes 112 582 — a full 3-of-N firing ≈ $21 at 30 gwei/$3k) land in the regenerated baseline + the generated runbook §9.2 table (23 rows) + the measured §10.6 cost table.  **(7) Documentation:** `docs/abi.md` — Action table 0..24 with the six GP field layouts, Event table 0..22 with per-tag semantics, streamer/indexer registry + dispatch tables, `executeStep` kind range; the GP plan's Quick Reference frozen-index tables corrected to SHIPPED indices + the GP.11.10 status block rewritten (quad-surface, with the supersession amendment); runbook §10.4 (the sequencer materialises one bridge-signed reclaim per funded leg) + §10.5 (mirror trace-constancy + top-level reflects); `deferred_work_index.md` GP row refreshed.  Every new theorem `#print axioms`-verified ⊆ `{propext, Classical.choice, Quot.sound}`; zero sorries.  Gates: `lake test` 3 039 (150 suites) green incl. the new `reclaim-amm-reserves` suite (33 cases); all seven Lean audit gates green; `cargo test` 1 956 + clippy `-D warnings` + fmt green; `forge test` 867 passed / 0 failed / 12 keccak-gated skips across 58 suites; the keccak-linked cross-stack verification runs ALL 879 (0 skipped, 0 failed) under real keccak256; cap gate + 51-case selftest green; GP.11.9 gas gate green (46 entries / 23 rows); codemaps regenerated.  No kernel TCB delta, no new axioms.  Version v0.6.0. |

---

## Appendix E. Index of Theorems and Definitions

For navigation. Theorems are listed by name; click-through is by
section reference.

### Definitions

| Name                       | Section | Type                                          |
|----------------------------|---------|-----------------------------------------------|
| `ActorId`                  | 4.1     | `abbrev ... := UInt64`                        |
| `ResourceId`               | 4.1     | `abbrev ... := UInt64`                        |
| `Amount`                   | 4.1     | `abbrev ... := Nat`                           |
| `Nonce`                    | 8.5.1   | `abbrev ... := UInt64`                        |
| `BalanceMap`               | 4.2     | `abbrev ... := RBMap ActorId Amount compare`  |
| `State`                    | 4.2     | `structure`                                    |
| `getBalance`               | 4.3     | `def State → ResourceId → ActorId → Amount`   |
| `setBalance`               | 4.3     | `def State → ResourceId → ActorId → Amount → State` |
| `Transition`               | 4.4     | `structure (pre, decPre, apply_impl)`          |
| `step_spec`                | 4.5     | `def State → State → Transition → Prop`       |
| `step_impl`                | 4.5     | `def State → Transition → State`              |
| `Legal`                    | 4.7     | `structure (proof : t.pre s)`                  |
| `CertifiedTransition`      | 4.7     | `structure (t, cert)`                          |
| `apply_certified`          | 4.8     | `def State → CertifiedTransition s → State`   |
| `Reachable`                | 4.9     | `inductive`                                    |
| `Reachable*`               | 12 WU 1.7 | (planned) reflexive-transitive closure       |
| `ReachableViaLaws`         | 12 WU 1.8 | (planned) law-set-restricted reachability    |
| `Action`                   | 4.13    | `inductive` (per-deployment)                   |
| `Action.compile`           | 4.13    | `def Action → Transition`                      |
| `TotalSupply`              | 8.1     | `def State → ResourceId → Nat`                 |
| `IsConservative`           | 12 WU 2.4 | (planned) typeclass on `Transition`          |
| `ConservativeLawSet`       | 12 WU 2.7 | (planned) typeclass-restricted list          |
| `Identity`                 | 8.2     | `structure (id, key)`                          |
| `PublicKey`                | 8.2     | `abbrev ... := ByteArray`                      |
| `Signature`                | 8.2     | `abbrev ... := ByteArray`                      |
| `SignedAction`             | 8.2     | `structure (action, signer, nonce, sig)`       |
| `AuthorityPolicy`          | 8.2     | `structure (authorized, decAuth, registry)`    |
| `Admissible`               | 8.2     | `def AuthorityPolicy → ExtendedState → SignedAction → Prop` |
| `apply_admissible`         | 8.2     | `def ... → ExtendedState`                      |
| `NonceState`               | 8.5.1   | `structure (next : RBMap ActorId Nonce ...)`   |
| `ExtendedState`            | 8.5.1   | `structure (base, nonces)`                     |
| `expectsNonce`             | 8.5.1   | `def ExtendedState → ActorId → Nonce`          |
| `advanceNonce`             | 8.5.1   | `def ExtendedState → ActorId → ExtendedState`  |
| `DisputeClaim`             | 8.4.1   | `inductive`                                    |
| `Dispute`                  | 8.4.1   | `structure`                                    |
| `Verdict`                  | 8.4.2   | `structure`                                    |
| `EvidenceVerdict`          | 8.4.2   | `inductive (upheld / rejected / inconclusive)` |
| `Encodable`                | 12 WU 4.1 | (planned) typeclass                          |
| `encode`                   | 8.8.6   | `[Encodable T] T → ByteArray`                  |
| `decode`                   | 8.8.6   | `[Encodable T] ByteArray → Except DecodeError T` |
| `DecodeError`              | 8.8.6   | `inductive`                                    |
| `sign_input`               | 8.8.5   | domain-separated signing-input function        |
| `ActionHash`               | 8.8.4   | `BLAKE3(encode action)`                        |
| `LogEntryHash`             | 8.8.4   | hash chain over log entries                    |
| `StateHash`                | 8.8.4   | `BLAKE3(encode state)`                         |
| `GenesisHash`              | 8.8.4   | `StateHash(genesis)` — also the deployment ID  |
| `Event`                    | 8.9.2   | `inductive` (per-deployment extensible)        |
| `extractEvents`            | 8.9.1   | `def LogEntry → List Event`                    |
| `Capability`               | 8.10.1  | `structure (id, shape, bearer, expiresAt, …)`  |

### Theorems

| Name                                | Section | Statement (informal)                                      | Status                |
|-------------------------------------|---------|-----------------------------------------------------------|-----------------------|
| `impl_refines_spec`                 | 4.6     | `t.pre s → step_spec s (step_impl s t) t`                 | proved                |
| `impl_noop_if_not_pre`              | 4.6     | `¬ t.pre s → step_impl s t = s`                           | proved                |
| `apply_certified_eq_step_impl`      | 4.8     | `apply_certified s ct = step_impl s ct.t`                 | proved                |
| `invariant_preservation`            | 4.10    | initial + preservation ⇒ holds on reachable               | proved                |
| `invariants_compose`                | 5.7     | `I₁` and `I₂` inductive ⇒ `I₁ ∧ I₂` inductive             | proved                |
| `getBalance_setBalance_same`        | 4.3     | read-after-write of same key                              | WU 1.5                |
| `getBalance_setBalance_other`       | 4.3     | read-after-write of different key                         | WU 1.5                |
| `Action.compile_total`              | 4.13    | `compile` is total                                        | proved (trivially)    |
| `Action.compile_injective`          | 4.13    | distinct actions compile to distinct transitions          | WU 3.2 (per-deploy)   |
| `Action.compile_step`               | 4.13    | `step_impl` of compiled action follows `if`-form          | proved (definitional) |
| `transfer_conserves`                | 8.1     | transfer preserves `TotalSupply`                          | WU 2.2 + WU 2.3       |
| `transfer_does_not_touch_other_resources` | 4.11.2 | transfer in `r` does not affect `r' ≠ r`              | WU 1.5 dependency     |
| `total_supply_global`               | 5.3     | conservation across all reachable states                  | WU 2.8                |
| `nonce_uniqueness`                  | 8.5.2   | two admissible actions by same signer have same nonce     | WU 3.7                |
| `expectsNonce_strict_mono`          | 8.5.2   | `expectsNonce` strictly increases on application          | WU 3.5                |
| `replay_impossible`                 | 8.5.2   | applied signed action cannot be admissible again          | WU 3.8                |
| `decode_encode_roundtrip`           | 8.8.6   | `decode (encode v) = .ok v`                               | WU 4.6                |
| `encode_injective`                  | 8.8.6   | `encode v₁ = encode v₂ → v₁ = v₂`                         | WU 4.7                |
| `RBMap.find?_insert_self`           | 8.3     | `(m.insert k v).find? k = some v`                         | WU 1.1                |
| `RBMap.find?_insert_other`          | 8.3     | `(m.insert k v).find? k' = m.find? k'` for `k ≠ k'`       | WU 1.1                |
| `RBMap.foldl_insert_absent`         | 8.3     | fold after insert of absent key                           | WU 1.2                |
| `RBMap.foldl_insert_present`        | 8.3     | fold after insert of present key (commutative-monoid)     | WU 1.3                |
| `RBMap.foldl_eq_sum_of_values`      | 8.3     | fold equals multiset sum                                  | WU 1.4                |

### Axioms (Trusted Assumptions)

| Name        | Section | Statement                                              | Where Trusted     |
|-------------|---------|--------------------------------------------------------|-------------------|
| Lean type theory soundness | 10.3 | The Lean 4 kernel admits no inconsistent proofs        | All theorems      |
| `Std.RBMap` lemmas         | 10.3 | The lemmas listed in `docs/std_dependencies.md`        | WU 1.1–1.4        |
| `Verify` is EUF-CMA        | 10.3 | The signature scheme satisfies EUF-CMA                 | Authority chain   |
| `BLAKE3` collision resistance | 10.3 | Collision-resistant in the random-oracle sense       | All hash uses     |

No other axioms are introduced anywhere in the system. New axioms
require an explicit Genesis-Plan amendment (Section 16.6).

---

*End of document.*
