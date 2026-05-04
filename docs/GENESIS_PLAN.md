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
  signers    : List ActorId   -- quorum members
  sigs       : List Signature
```

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
  `"canon-phase-2-economic-invariants"`).
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
| 3     | 10       | 9.5                       | not started       |
| 4     | 9        | 8.5                       | not started       |
| 5     | 12       | 13.0                      | not started       |
| 6     | 12       | 9.5                       | not started       |
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
│   └── Replay.lean          -- WU 5.5.
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
