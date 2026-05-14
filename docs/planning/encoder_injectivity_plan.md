<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Encoder Injectivity (AR.4 Follow-Up) — Engineering Plan

This document plans the engineering effort to ship the deferred AR.4
work: per-sub-state `*_encode_injective` lemmas for the five
map-backed sub-states inside `ExtendedState`, plus the composition
theorem that retires CLAUDE.md footnote 1 and promotes the
fault-proof chain from bytes-equality to extensional state equality.

The work is the single largest residual Lean proof debt identified
by the audit-remediation pass.  The formal design (CBE canonicality
for map-backed types) lives in `docs/GENESIS_PLAN.md` §15B.1 / §15C.7
and `docs/planning/audit_remediation_plan.md` §4.4 / §15C.7.

## Status

  * **Workstream prefix:** `EI` (Encoder Injectivity).  Sub-units
    `EI.1` … `EI.8`.  Inherits the eight-sub-unit decomposition
    sketched in `docs/planning/audit_remediation_plan.md` §4.4 (formerly
    AR.4.1 – AR.4.8); `EI.k` corresponds to the AR plan's `AR.4.k`.
  * **Branch convention:** `claude/encoder-injectivity-<slug>`,
    landing in a single PR per sub-unit for bisection cleanliness.
    `EI.2` (the template sub-unit) may take two PRs (skeleton +
    closure) at reviewer discretion.
  * **Build-posture target:** `lake build`, `lake test`, plus all
    audit binaries (`count_sorries`, `tcb_audit`, `stub_audit`,
    `naming_audit`, `deferral_audit`, `lex_lint`,
    `lex_codegen --check`) green throughout.  **No new sorries**,
    **no new axioms**, **no new opaques**, **no TCB expansion**.
  * **TCB delta:** zero.  All new theorems land in
    `LegalKernel/Encoding/*.lean` (non-TCB).  `Kernel.lean` and
    `RBMapLemmas.lean` are untouched.
  * **Trust-assumption delta:** zero.  The injectivity proofs are
    closed-form; they depend only on `propext`, `Classical.choice`,
    `Quot.sound`, and the existing `Std.TreeMap` lemma set.
  * **Frozen indices reserved:** none.  EI does not add `Action`
    or `Event` constructors.

## Table of contents

  * §1 Goals and non-goals
    * §1.1 Goals
    * §1.2 Non-goals
    * §1.3 Reading guide
    * §1.4 Glossary
  * §2 Mathematical background
    * §2.1 What "encoder injectivity" means precisely
    * §2.2 The bytes-eq → toList-eq → extensional-eq lift
    * §2.3 CBE canonicality for map-backed types
    * §2.4 The proof recipe (one sub-state at a time)
  * §3 Work-unit dependencies
    * §3.1 Strict ordering
    * §3.2 Parallel-safe sub-units
    * §3.3 Critical path
  * §4 Work-unit specifications (EI.1 – EI.8)
  * §5 Sequencing and PR structure
  * §6 Quality gates, rollback, roll-forward
  * §7 Risk register
  * §8 Acceptance criteria for the workstream
  * §9 Out-of-scope items
  * §10 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Ship the five `*_encode_injective` lemmas** for the
     `ExtendedState` sub-states whose underlying carrier is
     `Std.TreeMap`: `BalanceMap` (`State.balances` substrate),
     `NonceState`, `KeyRegistry`, `LocalPolicies`,
     `BridgeState.consumed`, and `BridgeState.pending`.  Each
     theorem has the schema

     ```
     theorem <sub>_encode_injective :
       ∀ (m₁ m₂ : <Carrier>),
         <sub>.encode m₁ = <sub>.encode m₂ →
         ∀ k, m₁[k]? = m₂[k]?
     ```

     The conclusion is *extensional* equality (point-wise lookup
     equality), not structural map equality.  Extensional
     equality is the form the fault-proof chain consumes.

  2. **Promote `commitExtendedState_subcommits_bytes_eq_under_collision_free`
     to a full extensional-equality variant.**  The new theorem

     ```
     theorem commitExtendedState_subcommits_extensional_eq_under_collision_free :
       CollisionFree hashBytes →
       commitExtendedState s₁ = commitExtendedState s₂ →
       s₁ ~ext s₂
     ```

     where `~ext` is the per-sub-state extensional-equality
     conjunction.  This is the AR.23 lift point: the snapshot-
     bootstrap regression suite then promotes from "bytes match"
     to "states are extensionally equal".

  3. **Retire CLAUDE.md footnote 1.**  Update CLAUDE.md and the
     Genesis Plan in the EI.8 PR; the footnote's substance is
     replaced by the shipped theorem name.

  4. **Establish the proof template** so future sub-states
     inherit a turnkey injectivity proof.  EI.1 (the helper
     lemma) and EI.2 (the `BalanceMap` template) are the
     templates.  Two downstream workstreams plan to reuse
     them: PA (`docs/planning/parameterized_laws_landing_plan.md`
     PA.3) for the `parameters` substrate encoder, and any
     Phase 7 sub-workstream that adds a new map-backed
     sub-state (see `docs/planning/phase_7_plan.md` for the
     sub-workstreams).

### §1.2 Non-goals

  1. **No change to the encoder definition.**  The `*_encode`
     functions already canonicalise (encode sorted by key); EI
     proves that property, it does not change it.

  2. **No new `Encodable` instance.**  All five sub-states already
     have `Encodable` instances and round-trip lemmas.

  3. **No structural equality lemma.**  `m₁ = m₂` (Lean's `Eq` on
     `TreeMap`) is *strictly stronger* than extensional equality
     because two structurally-distinct red-black trees can
     represent the same logical map.  EI proves extensional
     equality only; structural-equality is intentionally out of
     scope and not needed by any downstream consumer.

  4. **No change to bytes-equality theorems.**  The existing
     `commitExtendedState_subcommits_bytes_eq_under_collision_free`
     stays in source as a load-bearing lemma; EI.8 *adds* the
     extensional variant alongside.

  5. **No CBE wire-format change.**  The encoder's byte output is
     untouched.  Existing log files remain replayable byte-for-byte.

### §1.3 Reading guide

  * **Implementer:** read §2 (mathematical background) then §4 in
    order EI.1 → EI.8.  Each sub-unit's "Implementation steps"
    section is self-contained.
  * **Reviewer:** read §1, §2, then the sub-unit being reviewed.
    The "Acceptance criteria" + "Reviewer checklist" sections
    define what to check.
  * **Future auditor:** read §1 + §8 (acceptance criteria for the
    overall workstream) + §10 (cross-references).  The shipped
    theorem names match the headline theorems table in CLAUDE.md.

### §1.4 Glossary

  * **Extensional equality** (`~ext`).  For `m₁ m₂ : TreeMap α β _`:
    `∀ k, m₁[k]? = m₂[k]?`.  Weaker than `Eq`, stronger than
    bytes-equality.
  * **Canonical encoding.**  An encoding such that two extensionally-
    equal inputs produce identical bytes.  Equivalent to:
    `m₁ ~ext m₂ → encode m₁ = encode m₂`.  Already shipped as
    `*_encode_deterministic`.
  * **Injective encoding.**  An encoding such that identical bytes
    imply extensionally-equal inputs.  Equivalent to:
    `encode m₁ = encode m₂ → m₁ ~ext m₂`.  This is the missing
    direction.
  * **Sorted-pair representation.**  The canonical `List (Key × Val)`
    form: ordered ascending by `compare`, no duplicate keys.
    Produced by `TreeMap.toList` on a tree of order `compare`.
  * **CBE (Canonical Binary Encoding).**  Canon's wire format;
    see `LegalKernel/Encoding/CBOR.lean` and §8.7 of the Genesis
    Plan.

## §2 Mathematical background

### §2.1 What "encoder injectivity" means precisely

For each sub-state `S` (the `BalanceMap`, `NonceState`, etc.) we
have an encoder `encode : S → ByteArray` and a decoder
`decode : ByteArray → Except DecodeError S`.  The existing
machinery gives:

  * **Round-trip (decode∘encode = ok).**  `decode (encode m) = .ok m'`
    where `m' ~ext m` (extensional, not structural — because the
    decoder builds a fresh tree by inserting pairs in order,
    which produces the same `toList` but possibly a different
    internal RB shape).
  * **Determinism / canonicality.**  `m₁ ~ext m₂ → encode m₁ = encode m₂`.

What is missing is the *injective* direction.  Formally:

```
theorem balanceMap_encode_injective :
  ∀ (m₁ m₂ : TreeMap ActorId Amount compare),
    BalanceMap.encode m₁ = BalanceMap.encode m₂ →
    ∀ k, m₁[k]? = m₂[k]?
```

(Substitute the appropriate carrier type for each sub-state.)

### §2.2 The bytes-eq → toList-eq → extensional-eq lift

The proof factors through three intermediate steps.  Let
`m₁ m₂ : TreeMap α β cmp` with the project's `compare`-order.

```
        encode m₁ = encode m₂        (hypothesis: bytes equal)
              │
              ▼  (CBE injectivity at the byte level)
   sortedPairs₁ = sortedPairs₂        (sorted (k, v) lists equal)
              │
              ▼  (m.toList = sortedPairs m for compare-ordered RB)
        m₁.toList = m₂.toList         (toList representations equal)
              │
              ▼  (toList-eq ⇒ pointwise lookup equal)
        ∀ k, m₁[k]? = m₂[k]?         (extensional equality)
```

Each arrow is a separate lemma.  The middle arrow
(`m.toList = sortedPairs m`) is the *insight*: the encoder's
deterministic ordering is exactly `TreeMap.toList`, which by
RB-balance invariants is the unique sorted-pair representation.
This is the load-bearing observation; once it is shipped as
EI.1, every per-sub-state proof reduces to a mechanical instance.

### §2.3 CBE canonicality for map-backed types

CBE encodes a map as `cbe_array(cbe_pair(k_1, v_1), …,
cbe_pair(k_n, v_n))` where the pairs are sorted ascending by `k`.
The full canonicality contract has four obligations:

  1. **Pair-list canonicality** (no duplicates, sorted).  Holds by
    construction of `TreeMap.toList`.
  2. **Per-key encoder injectivity** (`Encodable α` and `Encodable β`
    are injective).  Holds for all atomic carriers (`Nat`,
    `ByteArray`, `ActorId`, `Amount`, `PublicKey`, `Nonce`, etc.)
    because each has a shipped `_encode_injective` lemma in
    `Encoding/Encodable.lean`.
  3. **`cbe_pair` and `cbe_array` injectivity.**  Already shipped
    in `Encoding/CBOR.lean`.
  4. **No length-prefix ambiguity.**  CBE uses CBOR major-type
    discipline; the byte-stream is unambiguously segmented.

The encoder injectivity proof composes these four obligations.

### §2.4 The proof recipe (one sub-state at a time)

For each sub-state `S` with carrier `TreeMap α β`:

  1. **Step A.**  From `S.encode m₁ = S.encode m₂` extract
    `cbe_array_eq` (the CBE pair-list arrays are equal as bytes).
  2. **Step B.**  Apply the CBE-array injectivity lemma:
    `cbe_array_inj : encodeArray xs = encodeArray ys → xs = ys`
    (already in `Encoding/CBOR.lean`).
  3. **Step C.**  The resulting equality is over
    `List (encodedPair α β)`.  Apply CBE-pair injectivity
    point-wise to get `List (α × β)` equality.
  4. **Step D.**  Apply the helper lemma EI.1
    (`encodeSortedPairs_decodeMap_roundtrip`): both lists are
    `m.toList`-shaped, so the lists are `toList m₁ = toList m₂`.
  5. **Step E.**  Apply `toList_eq_iff_extensional` (a small new
    lemma, also under EI.1): `toList m₁ = toList m₂ → ∀ k, m₁[k]? = m₂[k]?`.
  6. **QED.**

The mechanical work per sub-state is therefore (A) wrap the
specific sub-state's encoder, (B) discharge the per-value
injectivity goal (e.g. `Amount.encode_injective`,
`LocalPolicy.encode_injective`).  Step (B) is the *only*
non-trivial cost; the rest is template instantiation.

## §3 Work-unit dependencies

### §3.1 Strict ordering

```
EI.1 ──► EI.2 ──► EI.3, EI.4, EI.5, EI.6, EI.7 (parallelisable)
                                                 │
                                                 ▼
                                              EI.8 (composition)
```

  * **EI.1 blocks everything else.**  EI.1 ships
    `encodeSortedPairs_decodeMap_roundtrip` and
    `toList_eq_iff_extensional`.  Every per-sub-state proof
    consumes EI.1.
  * **EI.2 (`BalanceMap`) is the template.**  It is the hardest
    sub-state because the value type is itself a map
    (`TreeMap ActorId (TreeMap ResourceId Amount _) _`).  Landing
    EI.2 first establishes the nested-map proof pattern and
    surfaces any unexpected obstacles before parallel work
    starts.
  * **EI.3 – EI.7 are parallel.**  Each is a different sub-state
    with a flat carrier; they share no internal dependency.
    Reviewers may merge them in any order.
  * **EI.8 is the closer.**  Composes the five injectivity
    lemmas into the headline `commitExtendedState_subcommits_extensional_eq_under_collision_free`
    theorem.  Lands after EI.2 – EI.7.

### §3.2 Parallel-safe sub-units

After EI.1 + EI.2 ship, EI.3 / EI.4 / EI.5 / EI.6 / EI.7 may be
implemented in parallel by separate contributors as long as each
PR is scoped to a single sub-state's `Encoding/*.lean` file.

### §3.3 Critical path

```
EI.1 (~1.5 days) ─► EI.2 (~3 days) ─► (parallel batch ~2 days) ─► EI.8 (~1 day)
                                       └─ critical path
```

Critical path: **~7.5 working days** for a single full-time
contributor.  The lower bound of the AR.4 9–16-day estimate
assumes serial execution; the upper bound includes review cycles
and any per-sub-state surprise (e.g. `LocalPolicy.encode_injective`
turning out to need its own sub-lemma).

## §4 Work-unit specifications

Each sub-unit follows the template:

  * **Finding map** — which audit finding(s) this closes.
  * **Scope** — files touched.
  * **Math / proof outline** — theorem statement + proof sketch.
  * **Implementation steps** — file-level edit plan.
  * **Acceptance criteria** — what must be true at landing.
  * **Test plan** — value- and term-level coverage.
  * **Definition of done (DoD)** — checklist.
  * **Verification commands** — Lake invocations.
  * **Reviewer checklist** — what to look for in code review.
  * **Risk** — likely failure modes.
  * **Effort** — engineer-days.

---

### EI.1 — Helper lemma foundation

**Finding map.**  Foundation for AR.4 (M-3) + CLAUDE.md footnote 1.

**Scope.**  `LegalKernel/Encoding/Encodable.lean`,
`LegalKernel/RBMapLemmas.lean` (only if `toList_canonical` is
absent), `LegalKernel/Test/Encoding/Injectivity.lean` (new).

**EI.1 decomposes into four sub-sub-units**, each landing as
its own PR for bisection cleanliness:

  * **EI.1.a** — `encodeSortedPairs_decodeMap_roundtrip`
    (the key insight; pure proof addition).
  * **EI.1.b** — `toList_eq_iff_extensional` (the extensional-
    equality lemma; depends on EI.1.a in only one direction).
  * **EI.1.c** — `TreeMap.toList_canonical` auxiliary (lands in
    `RBMapLemmas.lean` only if Std core does not already
    provide it; triggers the §13.6 two-reviewer rule).
  * **EI.1.d** — Test-file scaffolding: a new
    `Test/Encoding/Injectivity.lean` module with term-level API-
    stability tests for both helpers, plus shared fixtures used
    by EI.2 – EI.7.

#### EI.1.a — `encodeSortedPairs_decodeMap_roundtrip`

**Scope.**  `LegalKernel/Encoding/Encodable.lean`.

**Math.**  The lemma asserts that encoding a `TreeMap`'s sorted
pair-list and decoding it via `decodeMap` round-trips to a
map extensionally equal to the original.  Polymorphic over the
key/value carriers and `compare`:

```lean
theorem encodeSortedPairs_decodeMap_roundtrip
    {α β : Type*} {cmp : α → α → Ordering}
    [Encodable α] [Encodable β] [LawfulCmp cmp]
    (m : Std.TreeMap α β cmp) :
  decodeMap (encodeSortedPairs (Std.TreeMap.toList m)) = .ok m
```

**Proof structure (by induction on `Std.TreeMap.toList m`).**

  * **Empty case.**  `m.toList = []`; `encodeSortedPairs [] =
    cbe_array_empty`; `decodeMap cbe_array_empty = .ok
    (TreeMap.empty cmp)`; conclude by extensionality
    (`TreeMap.empty[k]? = none` for all `k`).
  * **Cons case.**  `m.toList = (k, v) :: rest`.  The encoder
    emits `cbe_pair(encode k, encode v) ++ encodeSortedPairs rest`.
    The decoder peels the leading pair, inserts `(k, v)` into
    the decoder's accumulator, recurses on `rest`.  By induction
    hypothesis, the recursive call round-trips to a map `m'`
    with `m'[k']? = m[k']?` for all `k' ≠ k`.  Insertion of
    `(k, v)` then makes the final result match `m` on `k` as
    well (`TreeMap.find?_insert_self`).  Conclude by
    extensionality.

**Key Std lemmas consumed.**

  * `TreeMap.toList_isSorted` (canonical sort order).
  * `TreeMap.find?_insert_self` (post-insert lookup).
  * `TreeMap.find?_insert_of_ne` (insert preserves other keys).
  * `Encodable.encode_injective` for `α` and `β` (per-carrier
    injectivity at the byte level).

**Implementation steps.**

  1. Add the theorem statement to `Encoding/Encodable.lean`
    after the existing per-type `_roundtrip` lemmas.
  2. Prove by `induction (Std.TreeMap.toList m)`.
  3. Discharge the cons-step via `simp [encodeSortedPairs, decodeMap]`
    plus the four Std lemmas listed above.
  4. Add a short Lean-level comment naming the lemma's role
    ("polymorphic round-trip; consumed by EI.2 – EI.7").

**Acceptance criteria.**

  * Theorem ships.
  * `#print axioms` prints a subset of
    `[propext, Classical.choice, Quot.sound]`.
  * `lake build LegalKernel.Encoding.Encodable` succeeds.

**Test plan.**

  * Term-level: `let _ : decodeMap (encodeSortedPairs (toList m)) =
    .ok m := encodeSortedPairs_decodeMap_roundtrip m` in
    `Test/Encoding/Injectivity.lean`.
  * Value-level: pick three concrete maps (empty, single,
    three-element) and `assertEq` the round-trip.

**Risk.**  Low.  Standard induction.

**Effort.**  ~0.5 engineer-day.

#### EI.1.b — `toList_eq_iff_extensional`

**Scope.**  `LegalKernel/Encoding/Encodable.lean`.

**Math.**

```lean
theorem toList_eq_iff_extensional
    {α β : Type*} {cmp : α → α → Ordering} [LawfulCmp cmp]
    (m₁ m₂ : Std.TreeMap α β cmp) :
  Std.TreeMap.toList m₁ = Std.TreeMap.toList m₂ ↔ ∀ k, m₁[k]? = m₂[k]?
```

**Proof structure.**

  * **Forward direction** (`toList m₁ = toList m₂ → ∀ k, m₁[k]? = m₂[k]?`).
    The `find?` operation is defined by sequential search through
    `toList`; equal lists produce equal `find?`s for every key.
    Discharged by `TreeMap.find?_eq_of_toList_eq` (a small
    auxiliary; if not in Std, prove inline via list induction on
    the canonical search shape).
  * **Reverse direction** (`(∀ k, m₁[k]? = m₂[k]?) → toList m₁ = toList m₂`).
    Both `toList`s are sorted-ascending with no duplicate keys
    (canonical RB invariant).  Two such lists with identical
    pointwise lookup are equal as lists.  Discharged by
    `TreeMap.toList_canonical` (the EI.1.c lemma, if not in
    Std).

**Implementation steps.**

  1. Add theorem statement.
  2. Forward proof by induction on `toList m₁`.
  3. Reverse proof by appeal to `toList_canonical`.

**Acceptance criteria.**

  * Theorem ships.
  * `#print axioms` clean.
  * Depends on EI.1.c if Std lacks `toList_canonical`.

**Test plan.**

  * Term-level API.
  * Value-level: two structurally-distinct same-content trees
    (different insertion order) — confirm `toList`s equal and
    pointwise-lookup equality holds.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### EI.1.c — `TreeMap.toList_canonical` (auxiliary if Std lacks)

**Scope.**  `LegalKernel/RBMapLemmas.lean` (TCB-tier; **two
reviewers required**).

**Math.**

```lean
theorem Std.TreeMap.toList_canonical
    {α β : Type*} {cmp : α → α → Ordering} [LawfulCmp cmp]
    (m₁ m₂ : Std.TreeMap α β cmp) :
  (∀ k, m₁[k]? = m₂[k]?) → Std.TreeMap.toList m₁ = Std.TreeMap.toList m₂
```

**Proof structure.**  Both `toList`s are sorted-ascending by
`cmp` (`TreeMap.toList_isSorted`) and have no duplicate keys
(`TreeMap.toList_nodup`).  Two such lists with identical
pointwise lookup are head-tail-identical: the smallest key in
either list is the same key (by lookup), the head values are
the same (by lookup), and recursion on the tail completes the
induction.

**Discovery / first-day audit.**  Before landing EI.1.c, run

```bash
grep -rn "toList_canonical\|toList_eq_of_eq" \
  ~/.elan/toolchains/$(cat lean-toolchain | tr -d ' ')/lib/lean4/library/Std
```

If a matching Std-core lemma exists, **skip EI.1.c entirely**:
EI.1.b imports the Std lemma directly.  Only if the audit
returns nothing does EI.1.c land in `RBMapLemmas.lean`.

**Implementation steps.**  Only if needed:

  1. Open `RBMapLemmas.lean`.
  2. Add the theorem after the existing `find?_insert_*` block.
  3. Prove via list induction (~8–15 lines).
  4. Update `docs/std_dependencies.md` with the new lemma
    and its justification.

**Acceptance criteria.**

  * If shipped: two reviewers on the `RBMapLemmas.lean` change.
  * `#print axioms` clean.
  * `tcb_audit` green (no new imports introduced).

**Reviewer checklist.**

  * The lemma is genuinely Std-flavoured (no project-specific
    dependencies).
  * The proof does not introduce any new opaque or axiom.
  * `docs/std_dependencies.md` updated.

**Risk.**  Low if Std core has the lemma; medium if EI.1.c
must land (touches TCB-tier file).

**Effort.**  0 days if Std covers; ~1 engineer-day if EI.1.c
lands.

#### EI.1.d — Test-file scaffolding

**Scope.**  `LegalKernel/Test/Encoding/Injectivity.lean` (new),
`Tests.lean` (umbrella registration).

**Implementation steps.**

  1. Create `LegalKernel/Test/Encoding/Injectivity.lean` with:
     - Term-level API tests for `encodeSortedPairs_decodeMap_roundtrip`
       and `toList_eq_iff_extensional`.
     - Shared fixtures consumed by EI.2 – EI.7 (a `genTreeMap`
       helper that produces representative test maps).
     - Three baseline value-level tests (empty / singleton /
       three-element map).
  2. Register the new test module in `Tests.lean`.

**Acceptance criteria.**

  * `lake test` passes.
  * The new file is imported by `Tests.lean`.
  * `mock_import_audit` passes (no production module imports
    test fixtures).

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

---

### EI.1 — Rolled-up acceptance criteria

  * EI.1.a / EI.1.b / (EI.1.c if needed) / EI.1.d all
    individually accepted.
  * The four sub-sub-units may land as 3 PRs (EI.1.a + EI.1.b
    together; EI.1.c separately if needed; EI.1.d separately).
  * **Aggregate effort:** ~1.5 engineer-days if Std covers
    `toList_canonical`; ~2.5 if EI.1.c lands.

---

### EI.2 — `BalanceMap.encode_injective` (template sub-unit)

**Finding map.**  AR.4.2 (template) + M-3.

**Scope.**  `LegalKernel/Encoding/BalanceMapInjective.lean`
(new file; isolated for review cleanliness).

**Why this is the template.**  `BalanceMap` is the *only*
nested-map sub-state.  EI.2 establishes the recursive-application
proof pattern that EI.3 – EI.7 specialise to flat-map carriers.
If the nested-map proof exposes any obstacle (e.g. a missing
auxiliary lemma), EI.2's review surfaces it before parallel work
on EI.3 – EI.7 starts.

**EI.2 decomposes into five sub-sub-units**, landing as 2–3
PRs depending on reviewer preference:

  * **EI.2.a** — Inner-map injectivity instance (a specialised
    application of EI.1 helpers for the
    `TreeMap ResourceId Amount` inner type).
  * **EI.2.b** — Outer-list pairwise decomposition lemma (from
    encoded-list equality, derive pointwise pair equality).
  * **EI.2.c** — `BalanceMap.encode_injective` headline theorem
    (nested extensional-equality form).
  * **EI.2.d** — Test fixtures + term-level API stability.
  * **EI.2.e** — Plan-level retrospective ("we found / didn't
    find unexpected obstacles"; informs EI.3 – EI.7 plan
    review).

#### EI.2.a — Inner-map injectivity instance

**Scope.**  `LegalKernel/Encoding/BalanceMapInjective.lean`.

**Math.**

```lean
private theorem innerBalanceMap_encode_injective :
  ∀ (m₁ m₂ : Std.TreeMap ResourceId Amount compare),
    innerBalanceEncode m₁ = innerBalanceEncode m₂ →
    ∀ r, m₁[r]? = m₂[r]?
```

where `innerBalanceEncode` is the inner-map encoder used inside
`BalanceMap.encode`'s fold body.  (If the codebase doesn't
already expose this as a named definition, EI.2.a lifts it out
of the BalanceMap encoder body as a small refactor; reviewer
should confirm the encoder output is byte-identical before and
after the refactor.)

**Proof.**  Direct application of EI.1.a + EI.1.b:

  1. From `innerBalanceEncode m₁ = innerBalanceEncode m₂`,
    extract the equality of CBE-array byte strings.
  2. Apply `cbe_array_inj` (already in `Encoding/CBOR.lean`).
  3. The resulting list equality is `toList m₁ = toList m₂`
    (by definition of `innerBalanceEncode`).
  4. Apply EI.1.b (`toList_eq_iff_extensional`) to conclude.

**Implementation steps.**

  1. Refactor the inner encoder out of `BalanceMap.encode` (if
    not already named).  Confirm byte-identical output via
    `BalanceMap.encode_unchanged` regression test (compare
    before/after on three fixtures).
  2. State and prove `innerBalanceMap_encode_injective`.

**Acceptance criteria.**

  * `lake build` succeeds.
  * `BalanceMap.encode`'s byte output unchanged on fixtures.
  * `#print axioms` clean.

**Risk.**  Low.  The refactor is the riskiest step; the proof
is a template instance.

**Effort.**  ~1 engineer-day.

#### EI.2.b — Outer-list pairwise decomposition

**Scope.**  `LegalKernel/Encoding/BalanceMapInjective.lean`.

**Math.**

```lean
private theorem outer_list_pairwise_eq
    (b₁ b₂ : BalanceMap) :
  BalanceMap.encode b₁ = BalanceMap.encode b₂ →
  List.length (Std.TreeMap.toList b₁) =
    List.length (Std.TreeMap.toList b₂) ∧
  ∀ i : Fin (List.length (Std.TreeMap.toList b₁)),
    ∃ (h : i.val < List.length (Std.TreeMap.toList b₂)),
      ((Std.TreeMap.toList b₁).get i).1 =
        ((Std.TreeMap.toList b₂).get ⟨i.val, h⟩).1 ∧
      innerBalanceEncode ((Std.TreeMap.toList b₁).get i).2 =
        innerBalanceEncode ((Std.TreeMap.toList b₂).get ⟨i.val, h⟩).2
```

Read: the two outer lists have the same length, and at every
index, the keys match and the inner-encoder outputs match.

**Proof.**

  1. From `BalanceMap.encode b₁ = BalanceMap.encode b₂`,
    extract the CBE-array byte equality.
  2. Apply `cbe_array_inj` to lift to list equality on
    pair-encodings.
  3. From list equality, derive index-wise equality.
  4. Apply CBE-pair injectivity to each index to split into
    key-equality and value-encoder-equality.

**Implementation steps.**

  1. State and prove the lemma.
  2. The proof leans on `List.get_eq` plus `cbe_pair_inj`.

**Risk.**  Low-medium.  Index-wise reasoning requires care; if
the proof gets unwieldy, switch to a `List.zipWith`-based
formulation.

**Effort.**  ~1 engineer-day.

#### EI.2.c — Headline theorem composition

**Scope.**  `LegalKernel/Encoding/BalanceMapInjective.lean`.

**Math.**

```lean
theorem BalanceMap.encode_injective :
  ∀ (b₁ b₂ : BalanceMap),
    BalanceMap.encode b₁ = BalanceMap.encode b₂ →
    ∀ a r, b₁[a]?.bind (·[r]?) = b₂[a]?.bind (·[r]?)
```

The conclusion is *nested* extensional equality.  The flat form
`∀ a, b₁[a]? = b₂[a]?` is **strictly weaker than what we want**:
it would compare inner `TreeMap`s as `Option`s, which fails when
two extensionally-equal inner trees are structurally distinct.
The nested form sidesteps this by binding through the inner
lookup.

**Proof.**

  1. Apply EI.2.b to get key-equality + inner-encoder-equality
    at every index of the outer lists.
  2. By EI.1.c (`toList_canonical`) plus key equality on every
    index, conclude `b₁[a]? = none ↔ b₂[a]? = none` (the outer
    presence-set is the same).
  3. For each `a` where `b₁[a]? = some m₁` and `b₂[a]? = some m₂`,
    apply EI.2.a to `m₁` and `m₂` (whose encoder outputs are
    equal by EI.2.b) to get `∀ r, m₁[r]? = m₂[r]?`.
  4. Compose: `b₁[a]?.bind (·[r]?) = b₂[a]?.bind (·[r]?)` by
    case-split on whether the outer entry is present.

**Implementation steps.**

  1. State the theorem.
  2. `intro b₁ b₂ h_encode a r`.
  3. `have h_pair := outer_list_pairwise_eq b₁ b₂ h_encode`.
  4. Case-split on `b₁[a]?` and `b₂[a]?`:
     - both `none` → conclude `none = none`.
     - both `some` → apply `innerBalanceMap_encode_injective`.
     - one some, one none → contradicts presence-set equality;
       discharge via `False.elim` from `h_pair`.

**Acceptance criteria.**

  * Theorem ships.
  * `#print axioms BalanceMap.encode_injective` ⊆ `[propext,
    Classical.choice, Quot.sound]`.

**Risk.**  Medium.  The Option-bind case-split is the most
fiddly part of the proof.

**Effort.**  ~1 engineer-day.

#### EI.2.d — Test fixtures + term-level API

**Scope.**  `LegalKernel/Test/Encoding/BalanceMapInjective.lean`
(new file).

**Test plan.**

  * **Three baseline fixtures.**  Empty, single-entry,
    five-entry × three-resource (a small typical pattern).
  * **Positive (injectivity direction):** for each pair of
    fixtures `(f₁, f₂)` that differ on at least one (actor,
    resource), assert `BalanceMap.encode f₁ ≠ BalanceMap.encode f₂`.
  * **Negative (determinism direction):** for each fixture
    `f`, build a structurally-distinct extensionally-equal
    variant `f'` (different insertion order); assert
    `BalanceMap.encode f = BalanceMap.encode f'`.
  * **Term-level:** `let _ : ∀ b₁ b₂, ... :=
    BalanceMap.encode_injective` ascription.
  * **Property test (if Lex codegen available):** generate 100
    random `BalanceMap`s, run the theorem on each pair.

**Implementation steps.**

  1. Create the test module.
  2. Register in `Tests.lean`.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### EI.2.e — Retrospective for EI.3 – EI.7 plan review

**Scope.**  This document.

**Activity.**  After EI.2.a – EI.2.d land, the implementer
writes a short (≤ 200 words) retrospective covering:

  * Were any auxiliary lemmas needed beyond EI.1's surface?
  * Did the `Option.bind` case-split formulation work cleanly?
  * Should EI.3 – EI.7's templates be revised in light of
    what EI.2 surfaced?

The retrospective lands as a small Edit to this plan's §3.3
"Critical path" section.  If revisions to EI.3 – EI.7 are
needed, they land *before* parallel work starts.

**Risk.**  Trivial.

**Effort.**  ~0.1 engineer-day.

---

### EI.2 — Rolled-up acceptance criteria

  * EI.2.a – EI.2.d all individually accepted.
  * EI.2.e retrospective committed.
  * **Aggregate effort:** ~3.6 engineer-days.

---

### EI.3 — `NonceState.encode_injective`

**Finding map.**  AR.4.3 + M-3.

**Scope.**  `LegalKernel/Encoding/State.lean` (where `NonceState`
encoder lives) or new `Encoding/NonceStateInjective.lean`.

**Math / proof outline.**

Flat map: `TreeMap ActorId Nonce compare`.  One application of
the §2.4 recipe.

```
theorem NonceState.encode_injective :
  ∀ (n₁ n₂ : NonceState),
    NonceState.encode n₁ = NonceState.encode n₂ →
    ∀ a, n₁.expectedNonce a = n₂.expectedNonce a
```

Note the conclusion is phrased in terms of `expectedNonce` (the
public NonceState accessor) rather than raw `m[k]?`, matching the
NonceState API surface.

**Implementation steps.**

  1. State and prove the theorem.  Apply §2.4 steps A – E with
    the trivial atomic value-encoder injectivity for `Nonce`
    (`Nonce` is a `Nat` wrapper; injectivity is by definition).
  2. Add a small bridge lemma `NonceState.expectedNonce_eq_of_extensional`
    if needed to translate from `[k]?` to `expectedNonce` (likely
    a one-liner).

**Acceptance criteria.**  As EI.2.

**Test plan.**  As EI.2 with NonceState fixtures.

**DoD.**  As EI.2.

**Verification.**  As EI.2 with `NonceStateInjective` paths.

**Reviewer checklist.**  As EI.2.

**Risk.**  Low.  Flat map, atomic value.

**Effort.**  ~1 engineer-day.

---

### EI.4 — `KeyRegistry.encode_injective`

**Finding map.**  AR.4.4 + M-3.

**Scope.**  `LegalKernel/Encoding/State.lean` (KeyRegistry
encoder) or new `Encoding/KeyRegistryInjective.lean`.

**Math / proof outline.**

Flat map: `TreeMap ActorId PublicKey compare`.  Same recipe as
EI.3.  `PublicKey` is a `ByteArray` wrapper with shipped
`ByteArray.encode_injective`.

```
theorem KeyRegistry.encode_injective :
  ∀ (k₁ k₂ : KeyRegistry),
    KeyRegistry.encode k₁ = KeyRegistry.encode k₂ →
    ∀ a, k₁.publicKeyOf a = k₂.publicKeyOf a
```

**Implementation steps + acceptance + test + DoD + verification.**
Same template as EI.3.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

---

### EI.5 — `LocalPolicies.encode_injective`

**Finding map.**  AR.4.5 + M-3.

**Scope.**  `LegalKernel/Encoding/LocalPoliciesInjective.lean`
(new file).  Auxiliary clause-level lemma may live in the
existing `Encoding/LocalPolicy.lean`.

**Why this is the second-hardest sub-state.**  Unlike EI.3 /
EI.4 / EI.6 / EI.7 (atomic value carriers), the value type is
an *inductive* (`LocalPolicyClause` has three constructors) and
the structure wrapping it (`LocalPolicy`) contains a `List` of
clauses.  This means injectivity factors through:

  1. CBE constructor-tag discrimination (different tags → different
     bytes).
  2. Per-arm field injectivity (each constructor's fields are
     CBE-injective).
  3. List-level injectivity (same-length, index-wise equal).
  4. Map-level injectivity (the EI.1 helpers).

**EI.5 decomposes into four sub-sub-units:**

  * **EI.5.a** — `LocalPolicyClause.encode_injective` (the
    constructor case-split).
  * **EI.5.b** — `LocalPolicy.encode_injective` (the List
    + struct fields wrap).
  * **EI.5.c** — `LocalPolicies.encode_injective` (the map
    lift; standard template).
  * **EI.5.d** — Test fixtures + term-level API.

#### EI.5.a — `LocalPolicyClause.encode_injective`

**Pre-implementation audit.**  Before coding, search for any
existing clause-level injectivity:

```bash
grep -rn "LocalPolicyClause.*injective\|encode_injective.*LocalPolicyClause" \
  LegalKernel/Encoding/ LegalKernel/Authority/ Lex/
```

M2's constructor-tag pinning machinery may already supply this
lemma.  If found, EI.5.a is a re-export (zero proof work);
otherwise, EI.5.a lands the proof.

**Math (if needed).**

```lean
theorem LocalPolicyClause.encode_injective :
  ∀ (c₁ c₂ : LocalPolicyClause),
    LocalPolicyClause.encode c₁ = LocalPolicyClause.encode c₂ →
    c₁ = c₂
```

Note this is *structural* equality (`c₁ = c₂` as Lean `Eq`),
not extensional.  Inductives admit structural equality directly;
the canonical Lean `Eq` is the right notion.

**Proof structure.**

  1. CBE encoding of an inductive prefixes a constructor tag
    byte (per `Encoding/CBOR.lean` discipline).
  2. From `encode c₁ = encode c₂`, the tag bytes match → both
    are the same constructor.
  3. Case-split on the constructor:
     - `denyTag t`: by CBE-pair injectivity, `t₁ = t₂`; conclude
       `denyTag t₁ = denyTag t₂`.
     - `requireRecipient a`: same pattern with `ActorId.encode_injective`.
     - `capAmount r a`: pair-injectivity twice; conclude.

**Implementation steps.**

  1. If audit finds existing lemma: add a re-export `attribute
    [reducible]` if needed; skip to EI.5.b.
  2. Else: state the theorem.  Proof by `cases c₁ <;> cases c₂`
    (3 × 3 = 9 cases); 6 cases discharge by tag-byte mismatch,
    3 by per-arm injectivity.

**Acceptance criteria.**

  * Theorem ships (or is re-exported).
  * `#print axioms` clean.

**Risk.**  Low.  Standard inductive case-split.

**Effort.**  0 days if reused; ~0.5 day if landed.

#### EI.5.b — `LocalPolicy.encode_injective`

**Math.**

```lean
theorem LocalPolicy.encode_injective :
  ∀ (p₁ p₂ : LocalPolicy),
    LocalPolicy.encode p₁ = LocalPolicy.encode p₂ →
    p₁ = p₂
```

Structural equality again; `LocalPolicy` is a struct, so two
LocalPolicies are equal iff their fields are equal.

**Pre-implementation audit.**  Check `LocalPolicy.lean` for
the exact field set.  If the struct has only a `clauses : List
LocalPolicyClause` field, the proof is single-field.  If
additional fields (e.g. `signerExempted : Bool`), each gets a
field-wise injectivity step.

**Proof structure.**

  1. From struct encoding, extract per-field byte equalities
    (CBE encodes struct fields as a sorted sequence).
  2. For each field, apply the corresponding atomic
    injectivity:
     - `clauses : List LocalPolicyClause`: apply
       `List.encode_injective` (which composes element-wise
       with EI.5.a).
     - other fields (Bool / Nat / etc.): atomic injectivity
       lemmas already in `Encoding/Encodable.lean`.
  3. Use `LocalPolicy.ext` (the struct extensionality lemma;
    Lean generates it for structures).

**Implementation steps.**

  1. State the theorem.
  2. `intro p₁ p₂ h`.
  3. `apply LocalPolicy.ext`.
  4. Discharge each field-equality goal via the appropriate
    atomic injectivity.

**Risk.**  Low-medium.  Field-list discipline matters; reviewer
should confirm the struct's actual field set.

**Effort.**  ~0.5 engineer-day.

#### EI.5.c — `LocalPolicies.encode_injective`

**Math.**

```lean
theorem LocalPolicies.encode_injective :
  ∀ (ps₁ ps₂ : LocalPolicies),
    LocalPolicies.encode ps₁ = LocalPolicies.encode ps₂ →
    ∀ a, ps₁.lookup a = ps₂.lookup a
```

**Proof.**  Standard map-injectivity template (the §2.4 recipe)
with `LocalPolicy.encode_injective` (EI.5.b) as the value-level
injectivity.  Because EI.5.b proves *structural* equality of
`LocalPolicy`, the conclusion's flat form (`∀ a, ps₁[a]? =
ps₂[a]?`) is valid here — there's no nested-extensional concern
because `LocalPolicy` does not contain a `TreeMap`.

**Implementation steps.**

  1. State the theorem.
  2. Apply §2.4 with EI.5.b as the inner injectivity.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### EI.5.d — Test fixtures + term-level API

**Test plan.**

  * Three baseline fixtures: empty `LocalPolicies`, single
    actor with single `denyTag`, three actors with mixed
    clause types.
  * Positive: each fixture pair with at least one differing
    clause; assert encoding differs.
  * Negative: structurally-distinct same-content `LocalPolicies`
    (different insertion order); assert encoding equal.
  * Term-level API for all three theorems.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

---

### EI.5 — Rolled-up acceptance criteria

  * EI.5.a (if needed) / EI.5.b / EI.5.c / EI.5.d individually
    accepted.
  * **Aggregate effort:** ~1.5–2.0 engineer-days.

---

### EI.6 — `BridgeState.consumed.encode_injective`

**Finding map.**  AR.4.6 + M-3.

**Scope.**  `LegalKernel/Encoding/Bridge.lean` or new
`Encoding/BridgeConsumedInjective.lean`.

**Math / proof outline.**

Set-like: `TreeMap DepositId Unit compare`.  Encoded as a sorted
list of `DepositId`s (the `Unit` value is encoded as zero bytes).
Injectivity reduces to `DepositId.encode_injective` (a `ByteArray`
wrapper) plus the helper lemma.

```
theorem BridgeState.consumed_encode_injective :
  ∀ (c₁ c₂ : TreeMap DepositId Unit compare),
    consumedEncode c₁ = consumedEncode c₂ →
    ∀ d, c₁.contains d = c₂.contains d
```

**Implementation steps + DoD.**  Trivial instance of the
template.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

---

### EI.7 — `BridgeState.pending.encode_injective`

**Finding map.**  AR.4.7 + M-3.

**Scope.**  `LegalKernel/Encoding/Bridge.lean` or new
`Encoding/BridgePendingInjective.lean`.

**Math / proof outline.**

Flat map with rich value: `TreeMap WithdrawalId PendingWithdrawal compare`.
`PendingWithdrawal` is a structure (`{ recipient, amount,
resourceId, l1Block }`).  Each field carrier has a shipped
`_encode_injective`.

```
theorem PendingWithdrawal.encode_injective :
  ∀ (p₁ p₂ : PendingWithdrawal),
    PendingWithdrawal.encode p₁ = PendingWithdrawal.encode p₂ →
    p₁ = p₂

theorem BridgeState.pending_encode_injective :
  ∀ (p₁ p₂ : TreeMap WithdrawalId PendingWithdrawal compare),
    pendingEncode p₁ = pendingEncode p₂ →
    ∀ w, p₁[w]? = p₂[w]?
```

**Implementation steps.**  Establish
`PendingWithdrawal.encode_injective` first (struct decomposition),
then apply the §2.4 recipe.

**Risk.**  Low-medium.

**Effort.**  ~1 engineer-day.

---

### EI.8 — Composition + documentation retirement

**Finding map.**  AR.4.8 + M-3 + CLAUDE.md footnote 1 retirement
+ AR.23 partial → complete + EI workstream closure.

**Scope.**  `LegalKernel/FaultProof/Commit.lean`,
`LegalKernel/Test/Integration/SnapshotBootstrap.lean`, CLAUDE.md,
GENESIS_PLAN.md, `docs/planning/audit_remediation_plan.md`,
`docs/planning/encoder_injectivity_plan.md` (this file).

**EI.8 decomposes into five sub-sub-units**, all landing in a
single coordinated PR (single-PR landing because the cross-doc
edits must be atomic; an interleaved partial landing would
leave the project's status surface inconsistent):

  * **EI.8.a** — `ExtendedState.extEq` definition + decidability
    instance.
  * **EI.8.b** — Composition theorem proof.
  * **EI.8.c** — Cross-document retirement (CLAUDE.md,
    GENESIS_PLAN.md, audit_remediation_plan.md, this plan).
  * **EI.8.d** — AR.23 lift in `SnapshotBootstrap.lean`.
  * **EI.8.e** — Build-tag bump + `Test/Umbrella.lean` pin.

#### EI.8.a — `ExtendedState.extEq` + decidability

**Scope.**  `LegalKernel/FaultProof/Commit.lean`.

**Math.**

```lean
def ExtendedState.extEq (s₁ s₂ : ExtendedState) : Prop :=
  (∀ a r, s₁.state.balances[a]?.bind (·[r]?) =
          s₂.state.balances[a]?.bind (·[r]?)) ∧
  (∀ a, s₁.state.nonces.expectedNonce a =
        s₂.state.nonces.expectedNonce a) ∧
  (∀ a, s₁.state.keys.publicKeyOf a =
        s₂.state.keys.publicKeyOf a) ∧
  (∀ a, s₁.state.policies.lookup a =
        s₂.state.policies.lookup a) ∧
  (∀ d, s₁.bridge.consumed.contains d =
        s₂.bridge.consumed.contains d) ∧
  (∀ w, s₁.bridge.pending[w]? =
        s₂.bridge.pending[w]?)
```

**Note on decidability.**  `ExtendedState.extEq` quantifies over
unbounded key sets (e.g. all `ActorId`s).  This is *not*
decidable in general; we do not need it to be — `extEq` is a
*propositional* relation used in proof goals, not in
executable predicates.  No `Decidable` instance is required.

Reviewers should confirm no consumer of `extEq` requires
`Decidable` (e.g. via `decide` tactic in some downstream proof).
If a consumer does, that consumer's proof needs an
`extEq → Eq` lift or a finite-range variant; flag in EI.8.a's
review.

**Implementation steps.**

  1. Add `ExtendedState.extEq` to `FaultProof/Commit.lean`.
  2. Add brief one-line docstring.
  3. No `Decidable` instance.

**Acceptance criteria.**

  * Definition lands.
  * `lake build` succeeds.

**Risk.**  Trivial.

**Effort.**  ~0.2 engineer-day.

#### EI.8.b — Composition theorem

**Math.**

```lean
theorem commitExtendedState_subcommits_extensional_eq_under_collision_free
    (h_cr : CollisionFree hashBytes)
    {s₁ s₂ : ExtendedState}
    (h_eq : commitExtendedState s₁ = commitExtendedState s₂) :
  ExtendedState.extEq s₁ s₂
```

**Proof structure.**

  1. From `h_eq` and `h_cr`, apply the existing
    `commitExtendedState_subcommits_bytes_eq_under_collision_free`
    to get six sub-state byte-equalities:
     - `balances.encode b₁ = balances.encode b₂`
     - `nonces.encode n₁ = nonces.encode n₂`
     - `keys.encode k₁ = keys.encode k₂`
     - `policies.encode p₁ = policies.encode p₂`
     - `consumed.encode c₁ = consumed.encode c₂`
     - `pending.encode q₁ = pending.encode q₂`
  2. Apply EI.2 to the first byte-equality to get the nested
    extensional equality for balances.
  3. Apply EI.3 / EI.4 / EI.5 / EI.6 / EI.7 to the remaining
    byte-equalities to get each sub-state's extensional form.
  4. Conjoin into `ExtendedState.extEq`.

**Implementation steps.**

  1. State the theorem alongside the existing bytes-eq lemma.
  2. Prove via the structure above; each step is one or two
    Lean lines (`have hX := EI.k h_byte_X` + `exact ⟨h1, …⟩`).

**Acceptance criteria.**

  * Theorem ships.
  * `#print axioms commitExtendedState_subcommits_extensional_eq_under_collision_free`
    ⊆ `[propext, Classical.choice, Quot.sound]`.

**Reviewer checklist.**

  * Each EI.k lemma is named explicitly in the proof body
    (not invoked via `simp`-magic; reviewers must see the
    composition).

**Risk.**  Low.  Pure composition.

**Effort.**  ~0.5 engineer-day.

#### EI.8.c — Cross-document retirement

**Scope.**  CLAUDE.md, GENESIS_PLAN.md,
`docs/planning/audit_remediation_plan.md`,
`docs/planning/encoder_injectivity_plan.md` (this file).

**Edits required.**

  1. **CLAUDE.md.**
     - Remove footnote 1 entirely.
     - Update the "Headline theorems" table row that currently
       cites `commitExtendedState_subcommits_bytes_eq_under_collision_free`
       to additionally cite the new extensional-eq theorem.
       Either (a) replace the row with the extensional-eq
       theorem (recommend; the bytes-eq lemma stays in source
       as a primitive but the headline is the extensional form),
       or (b) list both rows.
     - In the "Deferred from AR" section, retire AR.4.
  2. **GENESIS_PLAN.md.**
     - §15B.1: cite the new extensional-eq theorem alongside
       the bytes-eq lemma.
     - §15C.7 ("Encoder injectivity (deferred)"): replace
       the section body with "Complete; landed under
       Workstream EI".  Keep the §15C.7 anchor for
       cross-references.
  3. **`docs/planning/audit_remediation_plan.md`.**
     - §15C.2 status table: AR.4 "Deferred" → "Complete".
     - §15C.7 mirror: section heading from "(deferred)" to
       "(complete)".
  4. **`docs/planning/encoder_injectivity_plan.md`** (this file).
     - Move "Status" workstream from "in progress" to
       "complete" (when EI.8 lands).
     - Annotate every sub-unit (EI.1 – EI.7) as "Complete" in
       the per-sub-unit section.
  5. **`solidity/README.md`** (if it references the deferral
    note).  Run `grep -l "footnote 1\|encoder injectivity" docs/
    solidity/` first to find all cross-references.

**Implementation checklist.**

  - [ ] CLAUDE.md footnote 1 removed.
  - [ ] CLAUDE.md "Headline theorems" updated.
  - [ ] CLAUDE.md "Deferred from AR" updated.
  - [ ] GENESIS_PLAN.md §15B.1 cites new theorem.
  - [ ] GENESIS_PLAN.md §15C.7 marked complete.
  - [ ] audit_remediation_plan.md §15C.2 AR.4 marked complete.
  - [ ] audit_remediation_plan.md §15C.7 mirror updated.
  - [ ] This plan's Status section updated.
  - [ ] Cross-reference search completed; no stale references
    remaining.

**Reviewer checklist.**

  * Run `grep -rn "footnote 1\|AR\.4 follow-up\|encoder
    injectivity (deferred)\|9.16 working-day" docs/ CLAUDE.md`
    → zero hits after EI.8.c.

**Risk.**  Low-medium.  Cross-document edits drift easily;
exhaustive grep is the safety net.

**Effort.**  ~0.5 engineer-day.

#### EI.8.d — AR.23 lift

**Scope.**  `LegalKernel/Test/Integration/SnapshotBootstrap.lean`.

**Edit.**  Line 117 currently asserts bytes-equality of two
post-replay states.  Replace with `ExtendedState.extEq`
assertion via the new composition theorem.  Remove the
comment "requires the AR.4.8 extensional-equality lemma
(deferred)".

**Acceptance criteria.**

  * Test passes with the stronger assertion.
  * `audit_remediation_plan.md` §15C.2 AR.23 row marked
    "Complete" (in the same PR; cross-references EI.8.c).

**Reviewer checklist.**

  * The new assertion is `ExtendedState.extEq`-shaped, not a
    weaker variant.
  * Comment scrub: no remaining "AR.4.8 (deferred)" mention.

**Risk.**  Trivial.

**Effort.**  ~0.2 engineer-day.

#### EI.8.e — `kernelBuildTag` bump + Test/Umbrella pin

**Scope.**  `LegalKernel.lean`, `LegalKernel/Test/Umbrella.lean`.

**Edit.**  Bump `kernelBuildTag` (currently
`"canon-audit-remediation"`) to `"canon-encoder-injectivity"`
(or whatever naming convention the maintainers prefer; see
OQ-DOC-1 in `open_questions.md` for the cadence rule).
Update the regression test in `Test/Umbrella.lean` to pin the
new value.

**Reviewer checklist.**

  * Constant and test value match.
  * README's build-tag (per CL.1) updates in the same PR or
    in an immediately-following CL.1 PR.

**Risk.**  Trivial.

**Effort.**  ~0.1 engineer-day.

---

### EI.8 — Rolled-up acceptance criteria

  * EI.8.a – EI.8.e all land in a single coordinated PR.
  * **Single-PR rationale:** cross-document edits + build-tag
    bump + test lift form an atomic state change.  Interleaved
    partial landing would leave the project status surface
    transiently inconsistent (e.g. CLAUDE.md says "AR.4
    complete" but `audit_remediation_plan.md` still says
    "deferred").
  * **Aggregate effort:** ~1.5 engineer-days.

**Migration notes.**  The bytes-eq lemma stays in source as a
load-bearing primitive (other call sites consume it directly).
EI.8 *adds* the extensional variant; no breaking change.

## §5 Sequencing and PR structure

```
PR-1  ─ EI.1  ─ helper lemmas + RBMapLemmas auxiliary (2 reviewers if RBMapLemmas)
PR-2  ─ EI.2  ─ BalanceMap.encode_injective (template; 1 reviewer)
PR-3  ─ EI.3  ─ NonceState.encode_injective       \
PR-4  ─ EI.4  ─ KeyRegistry.encode_injective       \
PR-5  ─ EI.5  ─ LocalPolicies.encode_injective      ─ parallel landing
PR-6  ─ EI.6  ─ BridgeState.consumed.encode_injective /
PR-7  ─ EI.7  ─ BridgeState.pending.encode_injective /
PR-8  ─ EI.8  ─ Composition + footnote-1 retirement (1 reviewer)
```

Each PR title prefix: `EI.<n>: <one-line summary>`.  PR body
must include `#print axioms <new theorem>` output as a sanity
check.

## §6 Quality gates, rollback, roll-forward

### §6.1 Per-PR forcing functions (unchanged from AR)

  * `lake build` (full project)
  * `lake test`
  * `lake exe count_sorries`
  * `lake exe tcb_audit`
  * `lake exe stub_audit`
  * `lake exe naming_audit`
  * `lake exe deferral_audit`
  * `lake exe lex_lint`
  * `lake exe lex_codegen --check`

### §6.2 Two-reviewer gate

EI.1 if it touches `RBMapLemmas.lean` requires two reviewers
(§13.6).  No other sub-unit triggers the two-reviewer rule
because EI proofs live in non-TCB `Encoding/*.lean` files.

### §6.3 Rollback

Each sub-unit is a single PR.  Rollback is `git revert <sha>`.
Theorems are additive; reverting affects only downstream PRs
(e.g. reverting EI.1 forces revert of all EI.2 – EI.8).

### §6.4 Roll-forward

If a sub-unit lands with a defective proof (audit catches it),
the fix lands in a new PR titled `EI.<n>.fix: <description>`
that supersedes the defective theorem.  Do not amend; preserve
git history per CLAUDE.md policy.

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `Std.TreeMap.toList_canonical` (or equivalent) absent from Std core | Medium | Medium | Ship as auxiliary in `RBMapLemmas.lean` under EI.1; triggers two-reviewer gate |
| `LocalPolicyClause.encode_injective` already exists in a place that fights with the EI.5 namespace | Low | Low | Audit during EI.5 implementation; reuse or rename |
| EI.2 template surfaces a structural issue (e.g. nested-map encoder uses a non-canonical inner ordering) | Low | High | EI.2 lands first specifically to surface this; if found, redesign before EI.3 – EI.7 start |
| `PendingWithdrawal.encode_injective` requires per-field carrier proofs that are missing | Medium | Low | Audit `Encoding/*.lean` for shipped atomic injectivity lemmas first; ship missing carriers as EI.7 sub-lemmas |
| Footnote-1 retirement misses one cross-reference (CLAUDE.md, README.md, GENESIS_PLAN.md, audit_remediation_plan.md, fault_proof_design.md, audits/05-encoding.md, audits/09-fault-proof.md) | High | Low | EI.8 checklist explicitly enumerates each file; grep for the footnote text at landing |
| `deferral_audit` regression after footnote-1 removal (the audit doesn't currently scan CLAUDE.md but the project may extend it) | Low | Low | Run `deferral_audit` in the EI.8 PR's CI; the binary's scope is `LegalKernel/`, `Lex/`, `Tools/` per source, not `docs/` |

## §8 Acceptance criteria for the workstream

EI is **complete** when:

  1. Five `*_encode_injective` lemmas ship: `BalanceMap`,
    `NonceState`, `KeyRegistry`, `LocalPolicies`,
    `BridgeState.consumed`, `BridgeState.pending` (six lemmas
    because BridgeState has two sub-trees; the §1.1 schema
    counts them as one workstream item).
  2. `commitExtendedState_subcommits_extensional_eq_under_collision_free`
    ships in `FaultProof/Commit.lean`.
  3. CLAUDE.md footnote 1 is removed; the headline-theorems
    table cites the new composition theorem.
  4. GENESIS_PLAN.md §15B.1 cites the new theorem; §15C.7
    is updated to "Complete".
  5. `audit_remediation_plan.md` §15C.2 status table moves
    AR.4 from "Deferred" to "Complete" and AR.23 from
    "Partial" to "Complete".
  6. `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe deferral_audit` all pass.
  7. `#print axioms` on each new theorem prints a subset of
    `[propext, Classical.choice, Quot.sound]`.
  8. Every new theorem has a term-level API-stability test in
    `LegalKernel/Test/Encoding/Injectivity.lean` (or per-file
    test modules).
  9. The `kernelBuildTag` in `LegalKernel.lean` bumps to a new
    value reflecting EI landing; `Test/Umbrella.lean` is
    updated in the same PR.

## §9 Out-of-scope items

  * **Structural map equality** (`m₁ = m₂` as Lean `Eq`).
    Strictly stronger than what EI proves; unnecessary for any
    shipped consumer.  Future work if a consumer ever requires
    it.
  * **`Std.TreeMap` lemma library fork.**  EI uses Std as-is.
  * **Cross-format encoder injectivity** (e.g. proving a
    deployment that swaps CBE for protobuf has the same
    injectivity property).  EI is about the canonical CBE
    encoder; alternative encoders would need their own
    injectivity proofs.
  * **`@[extern]` adaptor swap-out injectivity.**  Production
    deployments may swap `hashBytes` via `@[extern]`.  The
    composition theorem is conditioned on `CollisionFree hashBytes`
    (a hypothesis, not a fact); deployments that swap a
    non-collision-free hash break the conclusion, by design.

## §10 References

  * `docs/planning/audit_remediation_plan.md` §4.4 (original AR.4 spec)
    and §15C.7 (deferral note).
  * `docs/GENESIS_PLAN.md` §15B.1 (state-commitment scheme),
    §15C.7 (encoder injectivity deferral).
  * `CLAUDE.md` footnote 1 (the gap being closed).
  * `LegalKernel/FaultProof/Commit.lean` — the existing bytes-eq
    theorem `commitExtendedState_subcommits_bytes_eq_under_collision_free`.
  * `LegalKernel/Encoding/Encodable.lean` — the existing
    `Encodable` class and per-carrier injectivity lemmas.
  * `LegalKernel/RBMapLemmas.lean` — the TCB-tier RB-map lemma
    library (touched only by EI.1 if `toList_canonical` is
    missing).
  * `docs/std_dependencies.md` — Std-library lemma audit.

---

**End of plan.**  Landing EI closes the headline residual proof
debt of the project and retires CLAUDE.md footnote 1.
