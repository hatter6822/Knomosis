# Conservation — `LegalKernel/Conservation.lean`

**File:** `LegalKernel/Conservation.lean` (846 lines)
**TCB:** No.  Non-TCB; bugs here invalidate deployment-level claims
about supply conservation but cannot violate kernel invariants.
**Imports:** `LegalKernel.Kernel`, `LegalKernel.RBMapLemmas`.  Both
are TCB modules; this file does not pull anything else.

---

## Genesis state and TotalSupply (lines 64–102)

`genesisState` (line 64): `{ balances := ∅ }`.  Used by
non-conservation witnesses for `mint` / `burn` to construct a
fully-determined initial state without depending on the test
framework.

`TotalSupply` (line 78):

```lean
def TotalSupply (s : State) (r : ResourceId) : Nat :=
  match s.balances[r]? with
  | none    => 0
  | some bm => RBMap.sumValues bm
```

* Returns `0` for missing resources; otherwise folds the per-resource
  `BalanceMap` via `RBMap.sumValues`.
* The "missing actor = 0 balance" convention from §4.3 is preserved:
  both per-actor `0` and per-resource `0` flow from the same
  finite-map convention.

`totalSupply_genesis_eq_zero` (line 89): trivial via `simp`.
`totalSupply_eq_zero_of_no_resource` (line 98): direct rewrite.

**Finding:** Definitions correct.  The fold is order-independent by
`RBMap.sumValues_eq_values_sum` (TCB lemma).

## The master `setBalance` accounting lemma (lines 126–187)

`sumValues_emptyc` (line 126, private): `sumValues ∅ = 0`.  Proof
goes through `foldl_eq_foldl_toList` + `isEmpty_toList` + `isEmpty_emptyc`
+ `List.isEmpty_iff` to reduce `(∅ : BalanceMap).toList` to `[]`, then
`rfl` discharges the empty-fold.

**Finding:** Could in principle be more direct (Std *probably* has
`foldl_emptyc` as a `simp` lemma), but the explicit form makes the
ordering of rewrites obvious to a reviewer and is robust to changes
in Std's `simp` set.  No correctness issue.

`totalSupply_setBalance` (line 155, headline lemma):

```lean
TotalSupply (setBalance s r a v) r + getBalance s r a =
TotalSupply s r + v
```

The "additive form" sidesteps `Nat.sub` truncation.  Proof:

1. Unfold all three definitions.
2. Reduce the outer-level `s.balances.insert r ...` lookup at `r`
   to `some bm'` via `RBMap.find?_insert_self`.
3. Case-split on `s.balances[r]?`:
   - `none`: inner map is `∅`; `getBalance = 0`; use
     `sumValues_insert_absent ∅ a v` + `sumValues_emptyc`; `omega`.
   - `some bm`: case-split on `bm[a]?`:
     - `none`: `getBalance = 0`; `sumValues_insert_absent bm a v`;
       `simp` closes.
     - `some v_old`: `getBalance = v_old`;
       `sumValues_insert_present bm a v_old v ha` gives
       `sumValues (bm.insert a v) + v_old = sumValues bm + v`;
       `omega` closes.

**Finding:** Proof is correct.  The case-tree is exhaustive (four
combinations of resource-present/absent × actor-present/absent).
The `omega` at each leaf is closing a small linear `Nat` system, not
hiding any decidability hazard.

## `IsConservative` typeclass (lines 205–211)

```lean
class IsConservative (t : Transition) : Prop where
  conserves : ∀ (r : ResourceId) (s : State),
              t.pre s →
              TotalSupply (step_impl s t) r = TotalSupply s r
```

* `Prop`-valued typeclass; no data, just a proof obligation.
* Quantification is per-`r` (every resource), per-`s` (every
  state), conditional on `t.pre s`.

**Finding:** The classification is total: every law that admits an
`IsConservative` instance must preserve supply at *every* resource,
not just a single distinguished one.  This is stronger than the
default `total_supply_global` (which is per-resource); a
"partially-conservative" law would need a separate per-resource
classification scheme.  The current shape is correct for `transfer`
(which conserves every resource) but means `mint` and `burn` —
which conserve every resource *except* the one being minted/burned
— cannot inhabit `IsConservative` at all.  This is the intended
type-level firewall.

## `sumOthers` and `getBalance ≤ TotalSupply` (lines 222–281)

`sumOthers` (line 222):

```lean
def sumOthers (s : State) (r : ResourceId) (excluded : ActorId) : Nat :=
  TotalSupply s r - getBalance s r excluded
```

* Truncated `Nat` subtraction, but bounded by
  `getBalance_le_totalSupply`.

`nat_le_sum_of_mem` (line 236, public): standard inductive lemma.
Proof by induction; head case via `Nat.le_add_right`, tail case via
`ih` + `Nat.le_trans` + `Nat.le_add_left`.

**Finding:** Correct.  The author notes Lean core doesn't have this
under the same name (the closest is `min_mul_length_le_sum_nat`);
the local lemma is fine.

`getBalance_le_totalSupply` (line 257): reduces to the list-level
helper.  Three-way case-split:

* Outer `none`: both sides 0.
* Outer `some bm`, inner `none`: LHS 0, trivially ≤.
* Outer `some bm`, inner `some v`: use `sumValues_eq_values_sum`,
  then convert membership `(a, v) ∈ bm.toList` to `v ∈
  bm.toList.map (·.snd)` via `List.mem_map`, then apply
  `nat_le_sum_of_mem`.

**Finding:** Correct.  Three-way case-split is exhaustive; the
membership conversion is clean.

## Filter-sum lemmas (lines 285–496)

These are the load-bearing lemmas for the `proportionalDilute` dust
bound.  Three internal private helpers plus one public bridge:

`list_partition_sum_by_key` (line 291, private): for any list of
`(ActorId × Nat)` pairs and any key `k`,

```
(filter (≠ k)).map (·.2)).sum + (filter (== k)).map (·.2)).sum
  = (xs.map (·.2)).sum
```

Proof by induction on `xs`; at each step, case-split on whether the
head matches `k`, use `List.filter_cons_of_{pos,neg}` to push the
filter through, then `omega`.

**Hazard observation:** The use of `unfold bne; rw [h]; rfl` (lines
302, 315) is fragile to changes in the `bne` notation expansion in
Lean core.  A future Lean version that simplifies `bne` differently
could break this proof.  Workaround if it breaks: `simp [bne, h]`.
Not currently broken; flagged for toolchain-bump checklist.

`list_filter_eq_singleton_of_distinct` (line 335, private): for a
list with distinct first-projection keys (Pairwise `(fun a b => a.1
≠ b.1)`) and a member `(k, v)`, the `(·.1 == k)`-filter is
`[(k, v)]`.

The proof is long (lines 335–389) but follows a clean pattern:
induct on the list; at each step, case-split on whether the head's
first projection matches `k`.  Branches:

- Head matches `k` AND head IS `(k, v)`: filter keeps head; recurse
  shows tail's filter is `[]` because all tail entries have
  different keys by pairwise distinctness.  Closes by
  `List.filter_eq_nil_iff`.
- Head matches `k` AND `(k, v) ∈ tl`: contradiction via pairwise
  distinctness (head's key equals `k`, but `(k, v)` is in tail with
  the same key).
- Head doesn't match `k`: filter drops head; recurse on tail with
  the pairwise-distinctness tail-witness (`List.pairwise_cons.mp ...
  .2`).

**Finding:** Proof is correct.  The pairwise-distinctness handling
is the only delicate part; both contradiction and recursion are
discharged cleanly.

**Hazard observation:** Line 350 uses `rw [← h_kv_eq_hd]` to push
hd through `(k, v)` substitution.  This is sensitive to the exact
shape of `hd` (must be `(_, _)`-shape).  Reviewers should not
refactor this to `subst h_kv_eq_hd` without checking that hypothesis
direction matches.  Currently correct.

`balanceMap_toList_distinct` (line 396, private): converts
`Std.TreeMap.distinct_keys_toList` (stated in terms of `compare ≠
.eq`) to the `≠`-form required by `list_filter_eq_singleton_of_distinct`.

```lean
have h := Std.TreeMap.distinct_keys_toList (t := bm)
apply List.Pairwise.imp _ h
intro a b h_cmp h_eq
apply h_cmp
rw [h_eq]
exact Std.ReflCmp.compare_self
```

Uses `LawfulEqCmp` indirectly via `ReflCmp.compare_self` (which holds
for `UInt64`'s `compare`).

**Finding:** Correct.  The proof depends on `ReflCmp.compare_self`
being available as a public name in Lean core; spot-checked.

`balanceMap_filter_eq_sum_eq_lookup` (line 411, private): the bridge.
Case-splits on `bm[k]?`; `none` branch uses
`mem_toList_iff_getElem?_eq_some` to argue no list entry has key
`k`; `some v` branch uses `list_filter_eq_singleton_of_distinct`.

`balanceMap_filter_sum_plus_lookup` (line 451, private): combines
the partition lemma with the singleton-filter-sum lemma to give
`filter_sum (≠ k) + bm[k]?.getD 0 = sumValues bm`.

`state_filter_sum_eq_sumOthers` (line 466, public): state-level
form, with the `Nat.eq_sub_of_add_eq` discharge to bridge to
`sumOthers` (which uses truncated subtraction).  The safety
condition `getBalance ≤ TotalSupply` is implicit in the additive
form.

**Finding:** All four lemmas are correct.  The case-tree is
exhaustive, the conversions between
`Std.TreeMap.distinct_keys_toList` and `Pairwise (·.1 ≠ ·.1)` are
clean, and the bridge to `sumOthers` uses
`Nat.eq_sub_of_add_eq` which is exactly the right Nat lemma.

## `IsMonotonic` and `monotonic_of_conservative` (lines 513–532)

```lean
class IsMonotonic (t : Transition) : Prop where
  monotone : ∀ (r : ResourceId) (s : State),
             t.pre s →
             TotalSupply s r ≤ TotalSupply (step_impl s t) r

instance (priority := low) monotonic_of_conservative
    {t : Transition} [hc : IsConservative t] : IsMonotonic t where
  monotone := fun r s hpre => Nat.le_of_eq (hc.conserves r s hpre).symm
```

* `IsMonotonic` is strictly weaker than `IsConservative`: every
  conservative law is monotonic, but not vice-versa.
* The `priority := low` annotation is correct: explicit per-law
  `IsMonotonic` instances should win over the
  `monotonic_of_conservative` fallback.

**Finding:** Correct.  The low priority is the right choice;
otherwise, "ambiguous instance" diagnostics could appear when both
options exist.  Spot-checked under Lean 4.29.1: no warnings.

**Hazard observation:** `Nat.le_of_eq` takes an equality; the
`.symm` here is because `IsConservative.conserves` is stated as
`new = old`, but `IsMonotonic.monotone` needs `old ≤ new`.  If
`IsConservative.conserves` ever flips to `old = new`, this proof
breaks.  Not currently broken.

## `ConservativeLawSet` and `total_supply_global` (lines 539–600)

`TotalSupplyEquals` (line 539): closure form of "supply at `r₀`
equals `target`".

`ConservativeLawSet` (line 551): structure with `laws :
List Transition` and a per-element `IsConservative` witness.

`total_supply_global` (line 571): per-resource version.  Hypothesis
is `∀ t ∈ laws, ∀ s, t.pre s → TotalSupply (step_impl s t) r₀ =
TotalSupply s r₀` — i.e. preservation only at the specific resource
`r₀`.  Proof reduces to `invariant_preservation_via_laws`.

`total_supply_global_via_law_set` (line 593): typeclass-driven
corollary; pulls the conservation hypothesis from the `IsConservative`
instances in the `ConservativeLawSet`.

**Finding:** Both theorems correct.  The per-resource versus
per-law-set asymmetry is intentional: `total_supply_global` lets a
deployment hand-conservation a single resource (e.g. just USD) while
admitting mint / burn for other resources, while
`total_supply_global_via_law_set` demands all-resource
conservation.

## `MonotonicLawSet` and `total_supply_globally_nondecreasing` (lines 615–657)

Mirror-image of the `Conservative` family.  Structure +
per-resource theorem + typeclass-driven corollary.

`total_supply_globally_nondecreasing` (line 633): proof via
`invariant_preservation_via_laws (fun s => TotalSupply s0 r₀ ≤
TotalSupply s r₀)`; base case is `Nat.le_refl`, step case is
`Nat.le_trans hI (h_monotone ...)`.

**Finding:** Correct.  The invariant predicate "the initial supply
is bounded by the current supply" is preserved by `Nat.le_trans`
under each monotonic step.

## Workstream LX additions: `LocalTo`, `FreezePreserving`,
`FreezePreservingLawSet` (lines 705–777)

`LocalTo S t` (line 705): "applying `t` mutates only resources in
`S`".  Quantified over all resources `r ∉ S`, actors `a`, and
states `s` with `t.pre s`.

`FreezePreserving S t` (line 732): "applying `t` preserves
`s.balances[r]?` for every `r ∈ S`".  Quantified over `r ∈ S`,
snapshots `snap`, and states `s` with `s.balances[r]? = snap` and
`t.pre s`.

**Hazard observation:** `FreezePreserving` is phrased directly in
terms of `s.balances[r]?` rather than `Laws.FrozenForResource` to
avoid a circular import (`Laws/Freeze.lean` imports this module).
The docstring asserts the two formulations are equivalent
"definitionally" because `FrozenForResource` is a `def` returning
the equation.  Reviewers should confirm by reading the actual
`FrozenForResource` definition in `Laws/Freeze.lean` — this auditor
has not yet done so but will check during the Laws audit.  If
`FrozenForResource` ever becomes a `Prop` with additional content
(e.g. a `Decidable` field), the definitional equivalence breaks.

`FreezePreservingLawSet S` (line 755): structure with `laws` and
per-element `FreezePreserving S` witness.

`freeze_preservation_via_law_set` (line 767): per-resource freeze
preservation across all reachable states.  Proof via
`invariant_preservation_via_laws`.

**Finding:** All correct subject to confirming the
`FrozenForResource` definitional-equivalence claim.

## Typeclass-driven law-set builders (lines 798–844)

Six declarations (`{Conservative,Monotonic,FreezePreserving}LawSet.{empty,cons}`)
that let the Lex `deployment` macro construct law sets via inductive
typeclass resolution.  Each `cons` takes the head transition as a
typeclass-resolved instance; the `isXxx` field is built by induction
on the membership witness.

```lean
def ConservativeLawSet.cons (t : Transition) [hC : IsConservative t]
    (rest : ConservativeLawSet) : ConservativeLawSet where
  laws := t :: rest.laws
  isConservative := fun t' ht' => by
    cases ht' with
    | head => exact hC
    | tail _ ht'' => exact rest.isConservative t' ht''
```

**Finding:** Correct.  The `cases ht'` exhausts `List.Mem`; the
`head` branch returns the cons'd instance, the `tail` branch
recurses.

## Module-level findings

* **Soundness:** All theorems proved without `sorry`; the `omega`
  closes all happen on small linear `Nat` systems and are not
  load-bearing in any decidability argument.
* **No custom axioms:** `#print axioms` returns the canonical three.
* **Std API stability:** New names beyond the kernel's set —
  `isEmpty_toList`, `isEmpty_emptyc`, `distinct_keys_toList`,
  `mem_toList_iff_getElem?_eq_some`, `getElem?_erase_self`,
  `List.filter_cons_of_pos`, `List.filter_cons_of_neg`,
  `List.filter_eq_self`, `List.filter_eq_nil_iff`,
  `List.pairwise_cons`, `List.Pairwise.imp`, `Std.ReflCmp.compare_self`,
  `List.sum_eq_foldl_nat`, `List.Perm.sum_nat`.  All verified to
  exist in Lean 4 v4.29.1.
* **One hazard:** `unfold bne; rw [h]; rfl` in lines 302, 315 is
  fragile to changes in `bne` notation.  Flag for toolchain-bump
  checklist.
* **One claim to verify:** `FrozenForResource r snap s ↔
  s.balances[r]? = snap` definitionally.  Will check during Laws
  audit.

The module is well-organised: TCB-adjacent primitives at the top,
typeclasses in the middle, law-set machinery at the bottom.  The
six `LX`-targeted typeclass-resolution builders at the end are a
clean DSL ergonomics layer that doesn't bleed into the proof core.
