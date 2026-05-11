# LocalPolicy — `LegalKernel/LocalPolicy/LawClassification.lean`

**File:** `LegalKernel/LocalPolicy/LawClassification.lean` (137 lines)
**TCB:** No.  Non-TCB; bugs are type-level only.
**Imports:** `LegalKernel.Authority.Action`,
`LegalKernel.Authority.LocalPolicy`, `LegalKernel.Conservation`,
`LegalKernel.Laws.Freeze`.

---

## Surface and intent

This module materialises four `IsConservative` / `IsMonotonic`
typeclass instances for the two LP-introduced action constructors
(`declareLocalPolicy`, `revokeLocalPolicy`).  Both actions compile
to `Laws.freezeResource 0` at the kernel level, which is itself
conservative (Phase 2) and monotonic (Phase-4-prelude); these
instances surface that fact for typeclass resolution.

The module is small and self-contained.  Its purpose is the LP-9
work-unit deliverable: let deployments build `ConservativeLawSet` /
`MonotonicLawSet` values that include LP actions without manually
proving classification per-deployment.

### Identification lemmas (lines 67–73)

```lean
theorem declareLocalPolicy_compileTransition_eq_freezeResource_zero
    (p : Authority.LocalPolicy) :
    Action.compileTransition (.declareLocalPolicy p) = Laws.freezeResource 0 := rfl

theorem revokeLocalPolicy_compileTransition_eq_freezeResource_zero :
    Action.compileTransition .revokeLocalPolicy = Laws.freezeResource 0 := rfl
```

Both proven by `rfl`, meaning the equation holds *definitionally*.
This is the key: any non-`rfl` proof would indicate the
`compileTransition` table in `Authority/Action.lean` had drifted
from "compile to freezeResource 0" for these constructors.

**Hazard observation:** These lemmas are load-bearing for all four
instance synthesis below.  If `compileTransition`'s case for
`declareLocalPolicy` ever stops being literally `Laws.freezeResource
0`, both the `rfl` here and all four `instance` proofs break.  A
future PR that wants to add observability into the compile path
(e.g. recording the policy hash in the apply transition) would
need to either:
* Maintain the `rfl` by routing through a wrapper that's
  definitionally `Laws.freezeResource 0`; or
* Replace these instances with hand-proven ones that don't depend
  on the equality.

Both paths are tractable; flagging for any future LP authorship.

### `IsConservative` instances (lines 83–93)

```lean
instance declareLocalPolicy_compiled_isConservative
    (p : Authority.LocalPolicy) :
    IsConservative (Action.compileTransition (.declareLocalPolicy p)) := by
  rw [declareLocalPolicy_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

instance revokeLocalPolicy_compiled_isConservative :
    IsConservative (Action.compileTransition .revokeLocalPolicy) := by
  rw [revokeLocalPolicy_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0
```

Each is two lines: rewrite via the identification lemma, then apply
`freezeResource_isConservative 0`.  Correct.

### `IsMonotonic` instances (lines 101–111)

Mirror-image of the conservative instances; uses
`freezeResource_isMonotonic 0`.

**Finding:** Same two-line structure.  Correct.

### Composite summary (line 124)

```lean
theorem local_policy_actions_classification :
    (∀ p : Authority.LocalPolicy,
        IsConservative (Action.compileTransition (.declareLocalPolicy p))) ∧
    (∀ p : Authority.LocalPolicy,
        IsMonotonic (Action.compileTransition (.declareLocalPolicy p))) ∧
    IsConservative (Action.compileTransition .revokeLocalPolicy) ∧
    IsMonotonic (Action.compileTransition .revokeLocalPolicy) :=
  ⟨fun _ => inferInstance,
   fun _ => inferInstance,
   inferInstance,
   inferInstance⟩
```

A single tuple of typeclass-resolved instances.  Useful for
deployment-level proofs that want to assert classification at one
place.

**Finding:** Correct.  The `inferInstance` resolutions go to the
four `instance` declarations above.

## Module-level findings

* **Correctness:** All four instances are correctly synthesised.
* **No `sorry`, no custom axioms.**
* **Hazards:**
  * The `rfl` proofs of the identification lemmas pin the LP
    compile path.  Future LP additions must preserve this.
  * The classification is only about the **kernel-level effect**
    (state.balances).  The authority-level effect
    (ExtendedState.localPolicies mutation) is a separate concern
    and is NOT classified here.  This is correct (those mutations
    don't touch balances), but reviewers should be careful not to
    over-apply the classification.
* **Scope boundary:** Per the module docstring, "Bugs here would
  be type-level only".  Confirmed: an incorrect instance would
  fail to compile when used (`ConservativeLawSet.cons` would fail
  to resolve the instance), so the type system catches errors at
  definition site rather than at deployment.
