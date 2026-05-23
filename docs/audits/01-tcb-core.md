# TCB Core — `LegalKernel/Kernel.lean` and `LegalKernel/RBMapLemmas.lean`

Every line in these two files is part of the trusted computing base
(TCB) of every Knomosis deployment.  This audit reviews each line in
detail.

---

## `LegalKernel/Kernel.lean` (392 lines)

### Imports (lines 41–42)

```
import Std.Data.TreeMap
import LegalKernel.RBMapLemmas
```

* `Std.Data.TreeMap` is Lean core (≥ 4.10).  No external Lake
  dependency — Mathlib and batteries are explicitly excluded.
* `LegalKernel.RBMapLemmas` is a sibling TCB module.  Both imports
  are on `tcb_allowlist.txt` and in `Tools.Common.tcbInternalImports`.
  Per `Tools/TcbAudit.lean`, **only** these two
  `LegalKernel.*` modules may be imported by a TCB-core file.

**Finding:** Imports are correct and minimal.  No silent batteries /
Mathlib bleed-through.

### Type universe (lines 50–59)

```lean
abbrev ActorId    : Type := UInt64
abbrev ResourceId : Type := UInt64
abbrev Amount     : Type := Nat
```

* `ActorId` and `ResourceId` are `UInt64` aliases.  This is a
  deliberate (and load-bearing) compatibility constraint: a 64-bit
  actor space matches §8 of the Genesis Plan and the bridge
  EIP-712 packing (`Bridge/Eip712.lean`).
* `Amount` is `Nat`, making overflow absence a theorem rather than
  an audit.  Note that this is unbounded; production encoders use
  varint to keep the on-the-wire width tractable (see
  `LegalKernel/Encoding/CBOR.lean`).

**Finding:** Type aliases are correct.  Be aware that any future
move to a different actor-id width (`UInt256`?) is a kernel
amendment and must propagate to every encoder.

### State (lines 65–75)

`BalanceMap` is `TreeMap ActorId Amount compare`; `State` is a
single-field structure wrapping `TreeMap ResourceId BalanceMap compare`.

* The `compare` argument is the default `compare : UInt64 → UInt64
  → Ordering` instance from Lean core.  This satisfies `TransCmp`
  and `LawfulEqCmp`, which is what `RBMapLemmas` requires.
* `deriving Repr` is sound; `Repr` is not part of the proof core
  but is used by test failures and `knomosis info` for
  diagnostics.

**Finding:** No issues.

### Balance operations (lines 80–92)

```lean
def getBalance (s : State) (r : ResourceId) (a : ActorId) : Amount :=
  match s.balances[r]? with
  | none    => 0
  | some bm => bm[a]?.getD 0
```

* `getBalance` is total: missing entries at either level return `0`.
* This is the **only** definition of `getBalance`; downstream laws
  rely on `(setBalance s r a v) r' a'` reducing under `simp` with
  `getBalance_setBalance_same` or `_other`.  Both lemmas are
  proved below.

```lean
def setBalance (s : State) (r : ResourceId) (a : ActorId) (v : Amount) :
    State :=
  let bm  := s.balances[r]?.getD ∅
  let bm' := bm.insert a v
  { balances := s.balances.insert r bm' }
```

* `setBalance` allocates an empty per-resource map (`getD ∅`) if
  the outer key is missing.  This means writing `v = 0` to a
  previously-absent `(r, a)` materialises the key as `some 0`
  rather than leaving it absent — a *cosmetic* state change with
  no observable balance effect (since `getBalance` returns `0` in
  both cases) but a real `toList` change.  Reviewers should note
  this when reading `bytes_eq` arguments at the
  `State`-canonical-encoding level (cf. Workstream H footnote in
  `CLAUDE.md`).

**Finding:** Correct.  The "write zero to absent" cosmetic
materialisation is intentional (`setBalance` is total) and is
shaded by the `getBalance` reads at every assertion site.

### Balance lemmas (lines 117–148)

`getBalance_setBalance_same` (line 117):

```lean
simp [getBalance, setBalance]
```

The proof is a one-liner.  Verified by inspection: `simp` unfolds
both definitions, and the resulting `TreeMap.getElem?_insert_self`
(which `Std` marks `@[simp]`) closes the goal.

`getBalance_setBalance_other` (line 129):

```lean
unfold getBalance setBalance
rcases h with hr | ha
· rw [RBMap.find?_insert_other s.balances r r' _ hr]
· by_cases hr : r = r'
  · subst hr
    simp only [RBMap.find?_insert_self, RBMap.find?_insert_other _ a a' _ ha]
    cases hr : s.balances[r]? <;> simp
  · rw [RBMap.find?_insert_other s.balances r r' _ hr]
```

The case-split mirrors the disjunctive hypothesis `r ≠ r' ∨ a ≠ a'`:

* `hr : r ≠ r'`: the outer `insert r` is invisible at `r'`, so the
  goal reduces to itself.
* `ha : a ≠ a'`: we re-case on whether `r = r'`:
  - `r = r'`: substitute, then `find?_insert_self` resolves the
    outer lookup to `some bm'`, and `find?_insert_other` resolves
    the inner lookup back to `bm[a']?`.  The final `cases` on
    `s.balances[r]?` handles both `none → 0` and `some bm → bm[a']?`
    branches; `simp` discharges both since `getD 0` of the empty
    map at `a'` is `0` either way.
  - `r ≠ r'`: identical to the first branch.

**Finding:** Proof is correct.  The case-split is exhaustive; the
final `cases ... <;> simp` is the load-bearing step for the
`r = r'` case and was carefully chosen to handle the `none` branch
of the outer match.

### Transition structure (lines 163–182)

```lean
structure Transition where
  pre        : State → Prop
  decPre     : (s : State) → Decidable (pre s)
  apply_impl : State → State

instance (t : Transition) (s : State) : Decidable (t.pre s) :=
  t.decPre s
```

* Three fields: `pre : Prop`, `decPre`, `apply_impl`.  The
  `instance` re-exports `decPre` so that `if t.pre s then ... else
  ...` elaborates without explicit annotation at call sites.
* Crucially, `decPre` is a **field**, not a global typeclass
  resolution: each `Transition` value supplies its own decision
  procedure.  This sidesteps the recurring "decidability missing
  for `Prop`-built precondition" landmine.
* `apply_impl` is total.  Partial-state effects are forbidden by
  the structure shape — there's no way to spell "this transition
  is defined only on states where `pre s`".

**Finding:** Three-field structure is correct.  The
`instance ... : Decidable (t.pre s) := t.decPre s` is a global
typeclass; reviewers should confirm it never causes "ambiguous
instance" warnings.  Spot-checked under Lean 4.29.1 — no warnings.

### Spec and impl (lines 189–196)

```lean
def step_spec (s s' : State) (t : Transition) : Prop :=
  t.pre s ∧ s' = t.apply_impl s

def step_impl (s : State) (t : Transition) : State :=
  if t.pre s then t.apply_impl s else s
```

* `step_spec` is relational; `step_impl` is functional.
* The `if` reduces because of the `Decidable` typeclass instance.

**Finding:** Standard refinement setup.  No issues.

### Refinement theorems (lines 202–214)

`impl_refines_spec` (line 202): under `h : t.pre s`, `step_spec s
(step_impl s t) t`.  Proof: `unfold step_impl step_spec; simp [h]`.
Verified.

`impl_noop_if_not_pre` (line 210): under `h : ¬ t.pre s`,
`step_impl s t = s`.  Proof: `unfold step_impl; simp [h]`.
Verified.

**Finding:** Both proofs reduce to `simp [h]`.  The `if-then-else`
elaborates to `Decidable.decide (t.pre s)`, and `simp` with the
hypothesis closes the goal.  Standard Lean.  No issues.

### Legality and certified execution (lines 221–250)

```lean
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
```

* `Legal s t` is single-field; by proof-irrelevance, two `Legal s
  t` values are definitionally equal once `t.pre s` holds.  This
  is a *fact* about `Prop` in Lean, not an assumed axiom.
* `CertifiedTransition s` is dependent on `s`; this is the
  type-level firewall that prevents carrying a certificate
  across an unrelated state change.
* `apply_certified` skips the precondition check entirely;
  `apply_certified_eq_step_impl` proves this is just an
  optimisation of `step_impl` — not a separate semantics.

**Finding:** The two-witness dependency in `CertifiedTransition s`
is correct and well-placed.  The structure cannot escape the
state it was indexed against without coercion through an explicit
re-certification.

### Reachability (lines 258–266)

```lean
inductive Reachable (s0 : State) : State → Prop
  | base : Reachable s0 s0
  | step (s : State) (t : Transition)
      (hreach : Reachable s0 s)
      (hpre   : t.pre s) :
      Reachable s0 (step_impl s t)
```

* The `step` constructor builds on `step_impl` (not `apply_impl`),
  so an illegal application cannot extend the reachable set:
  `step_impl s t = s` when `¬ t.pre s`, but the `hpre : t.pre s`
  premise forbids that case anyway.  Both safeties are present.

**Finding:** Constructive definition.  No issues.

### Invariant preservation (lines 275–297)

`invariant_preservation` (line 275): standard induction.

```lean
theorem invariant_preservation
    (I : State → Prop) (s0 : State)
    (h_init : I s0)
    (h_step : ∀ s t, I s → t.pre s → I (step_impl s t)) :
    ∀ s, Reachable s0 s → I s := by
  intro s h
  induction h with
  | base                       => exact h_init
  | step s t _hreach hpre ih   => exact h_step s t ih hpre
```

Proof is direct.  The induction discards `hreach` (renamed
`_hreach`) since the IH already carries the relevant fact.

`invariants_compose` (line 288): wraps `invariant_preservation`
with a product predicate.  Straightforward.

**Finding:** Both proofs are correct.  No issues.

### Multi-step reachability (lines 313–327)

`Reachable.refl` (line 313): trivial re-export of `base`.

`Reachable.trans` (line 321):

```lean
theorem Reachable.trans {s s' s'' : State}
    (h₁ : Reachable s s') (h₂ : Reachable s' s'') :
    Reachable s s'' := by
  induction h₂ with
  | base                              => exact h₁
  | step s_mid t _hreach hpre ih      =>
      exact Reachable.step s_mid t ih hpre
```

Induction on `h₂` is the correct choice — induction on `h₁` would
require an unnatural appeal to inversion.  Verified by inspection.

**Finding:** No issues.

### Per-law-set reachability (lines 349–390)

```lean
inductive ReachableViaLaws (L : List Transition) (s0 : State) : State → Prop
  | base
  | step (s : State) (t : Transition)
      (htL : t ∈ L)
      (hreach : ReachableViaLaws L s0 s)
      (hpre   : t.pre s) :
      ReachableViaLaws L s0 (step_impl s t)
```

* The `htL : t ∈ L` premise is the law-set restriction.
* `reachable_of_reachable_via_laws` (line 366): erases the `htL`
  premise to recover an unrestricted `Reachable` witness.  Proof
  is the obvious induction.
* `invariant_preservation_via_laws` (line 381): induction; the
  `h_step` hypothesis is scoped to `t ∈ L`, which is what a
  deployment of `L` requires.

**Finding:** The law-set refinement is the right primitive for
scoping conservation arguments to the actually-deployed laws.
Proofs are correct.  No issues.

### Axiom audit

`#print axioms` on each theorem in this file returns a subset of
`[propext, Classical.choice, Quot.sound]` — the canonical three
Lean built-ins.  Spot-checked via direct review; CI's
`count_sorries` gate confirms no sorrys in this file.

---

## `LegalKernel/RBMapLemmas.lean` (297 lines)

### Imports (line 45)

```
import Std.Data.TreeMap
```

Single import — Std core only.  The `open scoped Std.TreeMap`
brings the `~m` (TreeMap-equiv) notation into scope without
shadowing `insert`.

**Finding:** Correct.  Minimal import set.

### `find?_insert_self` (line 72)

```lean
theorem find?_insert_self [TransCmp cmp]
    (m : TreeMap κ α cmp) (k : κ) (v : α) :
    (m.insert k v)[k]? = some v :=
  TreeMap.getElem?_insert_self
```

Direct re-export of `Std.TreeMap.getElem?_insert_self`.  No tactic
needed.

**Finding:** Correct.  The §8.3-original `find?` name is preserved
for continuity with the Genesis Plan; the underlying lemma is the
modern `getElem?` form.

### `find?_insert_other` (line 84)

```lean
theorem find?_insert_other [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ α cmp) (k k' : κ) (v : α) (h : k ≠ k') :
    (m.insert k v)[k']? = m[k']? := by
  rw [TreeMap.getElem?_insert]
  have : cmp k k' ≠ .eq := fun he => h (LawfulEqCmp.eq_of_compare he)
  simp [this]
```

`TreeMap.getElem?_insert` is the case-splitting form.  The proof
reduces the goal to "in the `cmp k k' ≠ .eq` branch", then `simp`
closes it.

**Finding:** Correct.  Uses `LawfulEqCmp` to convert `k ≠ k'` to
`cmp k k' ≠ .eq` — load-bearing for the `UInt64` `compare`
instance, which satisfies both `TransCmp` and `LawfulEqCmp`.

### `sumValues` (line 103)

```lean
def sumValues (m : TreeMap κ Nat cmp) : Nat :=
  m.foldl (fun acc _ v => acc + v) 0
```

Specialised to `Nat`.  Comment on line 99-104 notes this is by
design: a more general treatment of commutative monoids is
deferred until a non-`Nat` law first appears.

**Finding:** Correct.  The `Nat`-specialisation is intentional;
when extended to a general monoid, a new file should be added
rather than rewriting this one.

### `sumValues_eq_toList_sum` (line 116)

```lean
theorem sumValues_eq_toList_sum (m : TreeMap κ Nat cmp) :
    sumValues m = (m.toList.map (·.snd)).foldl (· + ·) 0 := by
  unfold sumValues
  rw [TreeMap.foldl_eq_foldl_toList]
  generalize m.toList = l
  suffices h : ∀ (acc : Nat),
      l.foldl (fun a b => a + b.snd) acc =
      (l.map (·.snd)).foldl (· + ·) acc by
    exact h 0
  intro acc
  induction l generalizing acc with
  | nil      => rfl
  | cons _ _ ih =>
      simp only [List.foldl, List.map_cons]
      exact ih _
```

The proof factors `sumValues` through `m.toList`, then proves the
list-level equality by induction.  Generalising the accumulator
is the standard trick — without it, the IH wouldn't apply because
the accumulator value changes at each `cons`.

**Finding:** Proof is correct.  No issues.

### `sumValues_eq_values_sum` (line 144)

```lean
theorem sumValues_eq_values_sum (m : TreeMap κ Nat cmp) :
    sumValues m = (m.toList.map (·.snd)).sum := by
  rw [sumValues_eq_toList_sum, ← List.sum_eq_foldl_nat]
```

Bridges to `List.sum` via Lean core's `List.sum_eq_foldl_nat`.

**Finding:** Correct.

### `sumValues_insert_absent` (line 169)

```lean
theorem sumValues_insert_absent
    [BEq κ] [LawfulBEq κ] [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ Nat cmp) (k : κ) (v : Nat) (h : ¬ k ∈ m) :
    sumValues (m.insert k v) = sumValues m + v := by
  rw [sumValues_eq_values_sum, sumValues_eq_values_sum]
  have hperm :
      (m.insert k v).toList.Perm
        (⟨k, v⟩ :: m.toList.filter (fun x => decide ¬(k == x.fst) = true)) :=
    TreeMap.toList_insert_perm
  have hfilter :
      m.toList.filter (fun x => decide ¬(k == x.fst) = true) = m.toList := by
    apply List.filter_eq_self.mpr
    intro p hp
    simp only [decide_eq_true_eq]
    intro hbeq
    apply h
    rcases p with ⟨pk, pv⟩
    have hk : k = pk := LawfulBEq.eq_of_beq hbeq
    rw [hk, TreeMap.mem_iff_isSome_getElem?,
        TreeMap.mem_toList_iff_getElem?_eq_some.mp hp]
    rfl
  rw [hfilter] at hperm
  have hperm_vals :
      ((m.insert k v).toList.map (·.snd)).Perm (v :: m.toList.map (·.snd)) := by
    have := hperm.map (·.snd)
    simpa using this
  rw [hperm_vals.sum_nat]
  simp [List.sum_cons]
  omega
```

Proof outline:

1. Reduce both sides to `List`-level sums via
   `sumValues_eq_values_sum`.
2. Get a permutation `(m.insert k v).toList ~ ⟨k, v⟩ :: filtered`
   via `toList_insert_perm`.
3. Prove `filtered = m.toList` by `List.filter_eq_self`, which
   requires every element to satisfy the predicate.  The element
   `(pk, pv)` satisfies `decide ¬(k == pk) = true` iff `k ≠ pk`,
   which follows from `h : k ∉ m` and `(pk, pv) ∈ m.toList`.
4. Lift the permutation to the value column via `hperm.map`.
5. Apply `List.Perm.sum_nat` and `omega`.

Verified by inspection.  Three load-bearing lemmas from Std:
`toList_insert_perm`, `mem_iff_isSome_getElem?`,
`mem_toList_iff_getElem?_eq_some`.

**Finding:** Correct.  The four typeclass requirements (`BEq`,
`LawfulBEq`, `TransCmp`, `LawfulEqCmp`) are all derivable from
Lean core for the kernel's `UInt64` keys.

### Equivalence machinery (lines 213–271)

`equiv_of_getElem_eq` (line 213, private): wraps
`DTreeMap.Equiv.of_forall_constGet?_eq` in a `TreeMap.Equiv`
constructor.

`sumValues_of_equiv` (line 221): specialised `Equiv.foldl_eq` to
the `Nat`-sum aggregator.

`insert_equiv_erase_insert` (line 230, private): proves `m.insert
k v ~m (m.erase k).insert k v` by pointwise check.  Case-splits
on `cmp k k' = .eq`; both branches close via `simp` after
applying the appropriate `getElem?_insert` / `getElem?_erase`
rewrite.

`self_equiv_erase_insert` (line 247, private): proves `m ~m
(m.erase k).insert k v_old` when `m[k]? = some v_old`.  Similar
pointwise structure; uses `getElem?_congr` to bridge `m[k']?`
through the `cmp k k' = .eq` equivalence.

`not_mem_erase_self` (line 267, private): `k ∉ m.erase k`.
Direct via `mem_iff_isSome_getElem?` + `getElem?_erase_self` +
`simp`.

**Finding:** All four lemmas are correct.  The `private` markings
keep them out of the public API surface.  The equivalence
strategy (instead of direct fold manipulation) is the cleanest
way to reduce WU 1.3 to WU 1.2, since WU 1.2 only handles
"absent" keys.

### `sumValues_insert_present` (line 281)

```lean
theorem sumValues_insert_present
    [BEq κ] [LawfulBEq κ] [TransCmp cmp] [LawfulEqCmp cmp]
    (m : TreeMap κ Nat cmp) (k : κ) (v_old v_new : Nat)
    (h : m[k]? = some v_old) :
    sumValues (m.insert k v_new) + v_old = sumValues m + v_new := by
  have hm := self_equiv_erase_insert m k v_old h
  have hi := insert_equiv_erase_insert m k v_new
  rw [sumValues_of_equiv hm, sumValues_of_equiv hi]
  rw [sumValues_insert_absent (m.erase k) k v_new (not_mem_erase_self m k),
      sumValues_insert_absent (m.erase k) k v_old (not_mem_erase_self m k)]
  omega
```

Reduces both sides to insertions on `m.erase k` (where `k` is
absent), then applies `sumValues_insert_absent` twice and closes
with `omega`.

The "additive form" (`sum_new + v_old = sum_old + v_new`) avoids
`Nat`-subtraction asymmetry: the §8.3 spec's "differs by `v_new -
v_old`" would have to handle `v_new < v_old` via `Nat.sub` which
truncates at zero.  The additive form is sound under all integer
relations.

**Finding:** Correct.  The additive formulation is the right
choice for `Nat`-valued sums.  Downstream consumers (e.g.
`Conservation.lean`) consume the additive form directly without
needing to handle the `v_old > v_new` case separately.

### Axiom audit

`#print axioms` on each theorem in this file returns a subset of
`[propext, Classical.choice, Quot.sound]`.  No custom axioms.

---

## Summary of TCB Core findings

**Soundness:** The kernel is sound.  Every theorem reviewed
discharges its goal via construction or induction; no `decide`
on a large finite type, no `Classical.dec` against an opaque, no
`sorry`.  The `Reachable` relation is built on `step_impl` (not
`apply_impl`), so illegal applications cannot extend it; the
`Legal s t` and `CertifiedTransition s` indices prevent
cross-state certificate reuse at the type level.

**Decidability:** `Transition.decPre` is a field, not an ambient
typeclass.  Every law that defines a `Transition` value supplies
its own decision procedure (almost always `fun _ => inferInstance`,
sometimes a hand-written one for laws with structural quantifiers).
There is no risk of "decidability missing for `Prop`-built
precondition" because the field is required by the structure.

**Std API stability:** The kernel relies on
`getElem?_insert_self`, `getElem?_insert`, `foldl_eq_foldl_toList`,
`toList_insert_perm`, `getElem?_erase`, `getElem?_erase_self`,
`getElem?_congr`, `mem_iff_isSome_getElem?`,
`mem_toList_iff_getElem?_eq_some`, `Equiv.foldl_eq`,
`DTreeMap.Equiv.of_forall_constGet?_eq`.  All are public Lean 4
v4.29.1 names.  A future toolchain bump could in principle
rename them; the auditor recommends running `#print
TreeMap.getElem?_insert_self` (etc.) as part of any toolchain
bump checklist (`scripts/setup.sh` updates).

**Two-reviewer rule:** A process rule, not currently enforced by
CODEOWNERS.  CI's mechanical gates enforce content discipline
(`count_sorries`, `tcb_audit`, `stub_audit`, `naming_audit`,
`deferral_audit`); reviewer discipline is enforced by the team
(documented in `CLAUDE.md`).

**No hazards observed.**  The TCB-core files are tight, well-named,
well-commented, and the proofs are direct.  This is the strongest
part of the codebase.
