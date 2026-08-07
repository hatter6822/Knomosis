-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Commit — the RETIRED concatenation
state-commitment (Workstream H §12 / WUs H.2.1 – H.2.5).

**This is not the published root.**  `commitExtendedState`, the
value a sequencer publishes to L1, is the SMT root over the state's
cells (`FaultProof/StateCells.lean`).  `commitExtendedStateConcat`
below is the construction it replaced: each sub-state of
`ExtendedState` committed via its canonical CBE encoding, and the
seven sub-state commits hashed together.

**Why it was replaced, and why it is kept.**  Workstream H chose
the concatenation over a Sparse Merkle Tree on the grounds that the
SMT was a gas optimisation and the soundness arguments held under
either representation.  The first half was wrong: a concatenation
hash cannot be updated incrementally, so the L1 step VM — which
holds the root and the proven cells, never the sub-state encodings —
cannot recompute a post-root from a pre-root, and the fault-proof
game's terminal comparison was between two different constructions.
The representation was never a gas question.

The theorems below are true and are retained as the record of that
construction and as the migration reference for a deployment that
published concatenation roots.  They are NOT an equal alternative:
nothing computes `commitExtendedStateConcat` on any production
path.

**Headline theorems.**

  * `commitExtendedStateConcat_size = 32` — uniform 32-byte output.
  * `commitExtendedStateConcat_deterministic` — equal states ⇒ equal commits.
  * `commitExtendedStateConcat_injective_under_collision_free` (#220) — under
    collision-freeness of `hashBytes` on the commitment chain's own
    pre-images, equal commits imply observably-equal states.  The
    published root's counterpart is
    `commitExtendedState_determines_cells`
    (`FaultProof/StateCellsInjective.lean`), which concludes
    per-cell agreement — behavioural rather than `extEq`, because a
    cell root cannot separate states no cell read can separate.

This module is **not** part of the trusted computing base.  Bugs
here would weaken fault-proof game's correctness but cannot
violate any kernel invariant (every state advance still goes
through `apply_admissible`).
-/

import LegalKernel.Authority.Nonce
import LegalKernel.Bridge.Eip712
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Bridge.State
import LegalKernel.Encoding.State
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.StateCells
import LegalKernel.Encoding.StateInjective
import LegalKernel.Encoding.LocalPolicyInjective
import LegalKernel.Encoding.BridgeInjective
import LegalKernel.Runtime.Hash

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## Per-sub-state commit functions -/

/-- Commit the kernel's `State` (the outer balance maps).  Goes
    through the canonical `toList`-sorted encoding (via
    `State.encode`) so different RB-tree shapes canonicalise to
    the same bytes. -/
def commitState (s : LegalKernel.State) : ByteArray :=
  hashBytes (ByteArray.mk (State.encode s).toArray)

/-- Commit the nonce ledger (per-actor next-nonce table). -/
def commitNonceState (n : NonceState) : ByteArray :=
  hashBytes (ByteArray.mk (NonceState.encode n).toArray)

/-- Commit the key registry (per-actor public-key table).
    Uses `KeyRegistry.encodeMap` which canonicalises via the
    sorted-pair-list encoding. -/
def commitKeyRegistry (kr : KeyRegistry) : ByteArray :=
  hashBytes (ByteArray.mk (KeyRegistry.encodeMap kr).toArray)

/-- Commit the local-policies table (per-actor policy
    declarations). -/
def commitLocalPolicies (lp : LocalPolicies) : ByteArray :=
  hashBytes
    (ByteArray.mk (Encodable.encode (T := LocalPolicies) lp).toArray)

/-- Commit the bridge state. -/
def commitBridgeState (bs : BridgeState) : ByteArray :=
  hashBytes
    (ByteArray.mk (Encodable.encode (T := BridgeState) bs).toArray)

/-- Commit the per-actor epoch-budget ledger (H-1).

    `epochBudgets` is live, mutable state — `Bridge/Admissible.lean`
    rewrites it on admitted actions and the GP.3.2 admission gate
    meters spending against it — so leaving it outside the published
    root meant two executions could disagree on budget grants or
    consumption and still produce the same state root. -/
def commitEpochBudgets (ebs : EpochBudgetState) : ByteArray :=
  hashBytes
    (ByteArray.mk (Encodable.encode (T := EpochBudgetState) ebs).toArray)

/-- Commit the budget policy (H-1): the metering parameters
    (`freeTier`, `actionCost`, `epochLength`) the admission gate reads.
    Bound for the same reason as `epochBudgets` — a root that does not
    fix the policy does not fix what "within budget" means. -/
def commitBudgetPolicy (bp : BudgetPolicy) : ByteArray :=
  hashBytes
    (ByteArray.mk (Encodable.encode (T := BudgetPolicy) bp).toArray)

/-! ## Top-level state commitment -/

/-- The byte string `commitExtendedStateConcat` hashes: the seven
    sub-state commits concatenated in canonical order.  Named so the
    injectivity theorems can list it as a hash pre-image. -/
def extendedStatePreimage (es : ExtendedState) : ByteArray :=
  commitState        es.base ++
  commitNonceState   es.nonces ++
  commitKeyRegistry  es.registry ++
  commitLocalPolicies es.localPolicies ++
  commitBridgeState  es.bridge ++
  commitEpochBudgets es.epochBudgets ++
  commitBudgetPolicy es.budgetPolicy

/-- The top-level state commitment: a single 32-byte hash binding
    every sub-state in canonical order.  This is the value the
    sequencer publishes to L1 as the state root.

    "Every sub-state" is all SEVEN `ExtendedState` fields.  Before H-1
    this bound only five: `epochBudgets` and `budgetPolicy` were
    omitted, so the published root did not fix the per-actor budget
    ledger or the metering parameters, and a fault proof had nothing to
    challenge when they were forged. -/
def commitExtendedStateConcat (es : ExtendedState) : StateCommit :=
  hashBytes (extendedStatePreimage es)

/-- The seven sub-state encodings `commitExtendedStateConcat` hashes
    beneath its top-level pre-image, in commit order.  Naming them
    lets the injectivity chain state exactly which pre-images its
    collision-resistance hypothesis covers (see
    `Bridge.CollisionFreeOn`). -/
def subStatePreimages (es : ExtendedState) : List ByteArray :=
  [ ByteArray.mk (State.encode es.base).toArray
  , ByteArray.mk (NonceState.encode es.nonces).toArray
  , ByteArray.mk (KeyRegistry.encodeMap es.registry).toArray
  , ByteArray.mk (Encodable.encode (T := LocalPolicies) es.localPolicies).toArray
  , ByteArray.mk (Encodable.encode (T := BridgeState) es.bridge).toArray
  , ByteArray.mk (Encodable.encode (T := EpochBudgetState) es.epochBudgets).toArray
  , ByteArray.mk (Encodable.encode (T := BudgetPolicy) es.budgetPolicy).toArray ]

/-- Every pre-image the `commitExtendedStateConcat` injectivity chain
    feeds to `hashBytes` for a pair of states: the two top-level
    seven-commit concatenations, then each side's seven sub-state
    encodings. -/
def extendedStateCommitPreimages (es₁ es₂ : ExtendedState) : List ByteArray :=
  extendedStatePreimage es₁ :: extendedStatePreimage es₂ ::
    (subStatePreimages es₁ ++ subStatePreimages es₂)

/-! ## Determinism theorems -/

theorem commitState_deterministic (s₁ s₂ : LegalKernel.State) (h : s₁ = s₂) :
    commitState s₁ = commitState s₂ := by rw [h]

theorem commitNonceState_deterministic (n₁ n₂ : NonceState) (h : n₁ = n₂) :
    commitNonceState n₁ = commitNonceState n₂ := by rw [h]

theorem commitKeyRegistry_deterministic (kr₁ kr₂ : KeyRegistry) (h : kr₁ = kr₂) :
    commitKeyRegistry kr₁ = commitKeyRegistry kr₂ := by rw [h]

theorem commitLocalPolicies_deterministic (lp₁ lp₂ : LocalPolicies) (h : lp₁ = lp₂) :
    commitLocalPolicies lp₁ = commitLocalPolicies lp₂ := by rw [h]

theorem commitBridgeState_deterministic (bs₁ bs₂ : BridgeState) (h : bs₁ = bs₂) :
    commitBridgeState bs₁ = commitBridgeState bs₂ := by rw [h]

theorem commitExtendedStateConcat_deterministic (es₁ es₂ : ExtendedState) (h : es₁ = es₂) :
    commitExtendedStateConcat es₁ = commitExtendedStateConcat es₂ := by rw [h]

/-! ## Output-size theorems -/

theorem commitExtendedStateConcat_size (es : ExtendedState) :
    (commitExtendedStateConcat es).size = 32 := by
  unfold commitExtendedStateConcat
  exact hashAdaptor_thirty_two_byte_output _

theorem commitState_size (s : LegalKernel.State) :
    (commitState s).size = 32 := by
  unfold commitState
  exact hashAdaptor_thirty_two_byte_output _

theorem commitNonceState_size (n : NonceState) :
    (commitNonceState n).size = 32 := by
  unfold commitNonceState
  exact hashAdaptor_thirty_two_byte_output _

theorem commitKeyRegistry_size (kr : KeyRegistry) :
    (commitKeyRegistry kr).size = 32 := by
  unfold commitKeyRegistry
  exact hashAdaptor_thirty_two_byte_output _

theorem commitLocalPolicies_size (lp : LocalPolicies) :
    (commitLocalPolicies lp).size = 32 := by
  unfold commitLocalPolicies
  exact hashAdaptor_thirty_two_byte_output _

theorem commitBridgeState_size (bs : BridgeState) :
    (commitBridgeState bs).size = 32 := by
  unfold commitBridgeState
  exact hashAdaptor_thirty_two_byte_output _

/-- The epoch-budget sub-commit is 32 bytes (H-1). -/
theorem commitEpochBudgets_size (ebs : EpochBudgetState) :
    (commitEpochBudgets ebs).size = 32 := by
  unfold commitEpochBudgets
  exact hashAdaptor_thirty_two_byte_output _

/-- The budget-policy sub-commit is 32 bytes (H-1). -/
theorem commitBudgetPolicy_size (bp : BudgetPolicy) :
    (commitBudgetPolicy bp).size = 32 := by
  unfold commitBudgetPolicy
  exact hashAdaptor_thirty_two_byte_output _

/-! ## Extensional equality on `ExtendedState`

The `extendedStateExtensionallyEqual` predicate is the strongest
"observable equality" on `ExtendedState`s:
  * the `toList` of every TreeMap-backed sub-state agrees;
  * the standalone fields agree.

This is weaker than `ExtendedState`-level structural equality
(which is sensitive to RB-tree shape), but it is exactly what the
fault-proof game's correctness rests on — two states with the
same observable values produce the same kernel-step results. -/

/-- Extensional equality on `ExtendedState`.  Two states are
    extensionally equal iff every sub-state's canonical view
    agrees: balance maps' toLists, nonces' toLists, registry's
    toList, localPolicies' toList, plus structural equality on
    the bridge state. -/
def extendedStateExtensionallyEqual (es₁ es₂ : ExtendedState) : Prop :=
  es₁.base.balances.toList = es₂.base.balances.toList ∧
  es₁.nonces.next.toList   = es₂.nonces.next.toList ∧
  es₁.registry.toList      = es₂.registry.toList ∧
  es₁.localPolicies.toList = es₂.localPolicies.toList ∧
  es₁.bridge.consumed.toList = es₂.bridge.consumed.toList ∧
  es₁.bridge.pending.toList  = es₂.bridge.pending.toList ∧
  es₁.bridge.nextWdId        = es₂.bridge.nextWdId ∧
  es₁.bridge.boldCircuitClosed    = es₂.bridge.boldCircuitClosed ∧
  es₁.bridge.boldTvlCap           = es₂.bridge.boldTvlCap ∧
  es₁.bridge.boldTotalLockedValue = es₂.bridge.boldTotalLockedValue ∧
  es₁.bridge.ammDisabled          = es₂.bridge.ammDisabled

/-! ## Per-sub-state injectivity (#256)

Each per-sub-state commit is hash-of-canonical-encoding.  Under
collision-freeness on those encodings, equal commits imply equal canonical
encodings.  Equal canonical encodings imply extensional equality
of the underlying TreeMap (canonical encoding is by `toList`). -/

/-- Bytes-injectivity for `commitState`: under collision-freeness on the level's pre-images,
    equal commits imply equal canonical encoded bytes. -/
theorem commitState_bytes_injective_under_collision_free
    (s₁ s₂ : LegalKernel.State)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (State.encode s₁).toArray, ByteArray.mk (State.encode s₂).toArray] hashBytes)
    (h : commitState s₁ = commitState s₂) :
    ByteArray.mk (State.encode s₁).toArray =
    ByteArray.mk (State.encode s₂).toArray := by
  unfold commitState at h
  exact h_cf.apply (by simp) (by simp) h

/-- Bytes-injectivity for `commitNonceState`. -/
theorem commitNonceState_bytes_injective_under_collision_free
    (n₁ n₂ : NonceState)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (NonceState.encode n₁).toArray, ByteArray.mk (NonceState.encode n₂).toArray] hashBytes)
    (h : commitNonceState n₁ = commitNonceState n₂) :
    ByteArray.mk (NonceState.encode n₁).toArray =
    ByteArray.mk (NonceState.encode n₂).toArray := by
  unfold commitNonceState at h
  exact h_cf.apply (by simp) (by simp) h

/-- Bytes-injectivity for `commitKeyRegistry`. -/
theorem commitKeyRegistry_bytes_injective_under_collision_free
    (kr₁ kr₂ : KeyRegistry)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (KeyRegistry.encodeMap kr₁).toArray, ByteArray.mk (KeyRegistry.encodeMap kr₂).toArray] hashBytes)
    (h : commitKeyRegistry kr₁ = commitKeyRegistry kr₂) :
    ByteArray.mk (KeyRegistry.encodeMap kr₁).toArray =
    ByteArray.mk (KeyRegistry.encodeMap kr₂).toArray := by
  unfold commitKeyRegistry at h
  exact h_cf.apply (by simp) (by simp) h

/-- Bytes-injectivity for `commitLocalPolicies`. -/
theorem commitLocalPolicies_bytes_injective_under_collision_free
    (lp₁ lp₂ : LocalPolicies)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (Encodable.encode (T := LocalPolicies) lp₁).toArray, ByteArray.mk (Encodable.encode (T := LocalPolicies) lp₂).toArray] hashBytes)
    (h : commitLocalPolicies lp₁ = commitLocalPolicies lp₂) :
    ByteArray.mk (Encodable.encode (T := LocalPolicies) lp₁).toArray =
    ByteArray.mk (Encodable.encode (T := LocalPolicies) lp₂).toArray := by
  unfold commitLocalPolicies at h
  exact h_cf.apply (by simp) (by simp) h

/-- Bytes-injectivity for `commitBridgeState`. -/
theorem commitBridgeState_bytes_injective_under_collision_free
    (bs₁ bs₂ : BridgeState)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (Encodable.encode (T := BridgeState) bs₁).toArray, ByteArray.mk (Encodable.encode (T := BridgeState) bs₂).toArray] hashBytes)
    (h : commitBridgeState bs₁ = commitBridgeState bs₂) :
    ByteArray.mk (Encodable.encode (T := BridgeState) bs₁).toArray =
    ByteArray.mk (Encodable.encode (T := BridgeState) bs₂).toArray := by
  unfold commitBridgeState at h
  exact h_cf.apply (by simp) (by simp) h

/-- Bytes-injectivity for `commitEpochBudgets` (H-1). -/
theorem commitEpochBudgets_bytes_injective_under_collision_free
    (e₁ e₂ : EpochBudgetState)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (Encodable.encode (T := EpochBudgetState) e₁).toArray, ByteArray.mk (Encodable.encode (T := EpochBudgetState) e₂).toArray] hashBytes)
    (h : commitEpochBudgets e₁ = commitEpochBudgets e₂) :
    ByteArray.mk (Encodable.encode (T := EpochBudgetState) e₁).toArray =
    ByteArray.mk (Encodable.encode (T := EpochBudgetState) e₂).toArray := by
  unfold commitEpochBudgets at h
  exact h_cf.apply (by simp) (by simp) h

/-- Bytes-injectivity for `commitBudgetPolicy` (H-1). -/
theorem commitBudgetPolicy_bytes_injective_under_collision_free
    (p₁ p₂ : BudgetPolicy)
    (h_cf : Bridge.CollisionFreeOn
      [ByteArray.mk (Encodable.encode (T := BudgetPolicy) p₁).toArray, ByteArray.mk (Encodable.encode (T := BudgetPolicy) p₂).toArray] hashBytes)
    (h : commitBudgetPolicy p₁ = commitBudgetPolicy p₂) :
    ByteArray.mk (Encodable.encode (T := BudgetPolicy) p₁).toArray =
    ByteArray.mk (Encodable.encode (T := BudgetPolicy) p₂).toArray := by
  unfold commitBudgetPolicy at h
  exact h_cf.apply (by simp) (by simp) h

/-! ## Top-level injectivity (#220)

The headline trust-model theorem of the workstream's commitment
scheme: under collision-freeness of `hashBytes` on the pre-images below, two distinct
extensional state representations cannot share a top-level
commit.

The proof composes three layers:
  1. `hashBytes` is collision-free (hypothesis).
  2. The top-level commit is the hash of five sub-state commits
     concatenated.  Under collision-freedom, equal hashes ⇒ equal
     concatenations.
  3. Each sub-state commit has size 32; the concatenation of
     five 32-byte segments split-uniquely.  So equal
     concatenations ⇒ equal segment-wise sub-state commits.
  4. Each per-sub-state injectivity (above) lifts the equality to
     the canonical encoded bytes.
  5. The encoders' canonicalisation discipline (sorted toList +
     decoder canonicality enforcement) lifts byte-equality to
     extensional equality.

Step 3 is the load-bearing structural argument.  Steps 1 + 4 + 5
follow from the per-component lemmas. -/

/-- Helper: byte-array concatenation injectivity at a known
    left-side size.  Mirrors Workstream-D's private
    `byteArray_append_inj` lemma; published here so the five-fold
    split below can use it. -/
theorem byteArrayAppendInj
    {a₁ a₂ b₁ b₂ : ByteArray}
    (h_concat : a₁ ++ b₁ = a₂ ++ b₂)
    (h_size : a₁.size = a₂.size) :
    a₁ = a₂ ∧ b₁ = b₂ := by
  have h_data : (a₁ ++ b₁).data = (a₂ ++ b₂).data :=
    congrArg ByteArray.data h_concat
  rw [ByteArray.data_append, ByteArray.data_append] at h_data
  have h_data_list : (a₁.data ++ b₁.data).toList = (a₂.data ++ b₂.data).toList :=
    congrArg Array.toList h_data
  rw [Array.toList_append, Array.toList_append] at h_data_list
  have h_size_data : a₁.data.toList.length = a₂.data.toList.length := by
    rw [← Array.size_eq_length_toList, ← Array.size_eq_length_toList]
    show a₁.data.size = a₂.data.size
    exact h_size
  have ⟨h_a_list, h_b_list⟩ := List.append_inj h_data_list h_size_data
  have h_a : a₁ = a₂ :=
    ByteArray.ext_iff.mpr (Array.ext' h_a_list)
  have h_b : b₁ = b₂ :=
    ByteArray.ext_iff.mpr (Array.ext' h_b_list)
  exact ⟨h_a, h_b⟩

/-- Helper: split a 160-byte (5 × 32) ByteArray-backed
    concatenation into its five 32-byte components.  Under the
    canonical sub-state-commit shape (each commit is exactly 32
    bytes), the concatenation is uniquely decomposable. -/
private theorem byteArray_concat_five_split
    (a₁ a₂ a₃ a₄ a₅ b₁ b₂ b₃ b₄ b₅ : ByteArray)
    (s₁ : a₁.size = 32) (s₂ : a₂.size = 32)
    (s₃ : a₃.size = 32) (s₄ : a₄.size = 32) (_s₅ : a₅.size = 32)
    (t₁ : b₁.size = 32) (t₂ : b₂.size = 32)
    (t₃ : b₃.size = 32) (t₄ : b₄.size = 32) (_t₅ : b₅.size = 32)
    (h : a₁ ++ a₂ ++ a₃ ++ a₄ ++ a₅ = b₁ ++ b₂ ++ b₃ ++ b₄ ++ b₅) :
    a₁ = b₁ ∧ a₂ = b₂ ∧ a₃ = b₃ ∧ a₄ = b₄ ∧ a₅ = b₅ := by
  have h₁ : a₁.size = b₁.size := by rw [s₁, t₁]
  have _h₂ : a₂.size = b₂.size := by rw [s₂, t₂]
  have _h₃ : a₃.size = b₃.size := by rw [s₃, t₃]
  have _h₄ : a₄.size = b₄.size := by rw [s₄, t₄]
  -- Pull the five-fold concatenation apart layer-by-layer using
  -- the public `byteArrayAppendInj` lemma.
  have step1 :
      (a₁ ++ a₂ ++ a₃ ++ a₄) ++ a₅ = (b₁ ++ b₂ ++ b₃ ++ b₄) ++ b₅ := h
  have size_l :
      (a₁ ++ a₂ ++ a₃ ++ a₄).size = (b₁ ++ b₂ ++ b₃ ++ b₄).size := by
    rw [ByteArray.size_append, ByteArray.size_append, ByteArray.size_append,
        ByteArray.size_append, ByteArray.size_append, ByteArray.size_append]
    omega
  have ⟨e_l1, e_5⟩ := byteArrayAppendInj step1 size_l
  have step2 :
      (a₁ ++ a₂ ++ a₃) ++ a₄ = (b₁ ++ b₂ ++ b₃) ++ b₄ := by
    have := e_l1
    rwa [show a₁ ++ a₂ ++ a₃ ++ a₄ = (a₁ ++ a₂ ++ a₃) ++ a₄ from rfl,
         show b₁ ++ b₂ ++ b₃ ++ b₄ = (b₁ ++ b₂ ++ b₃) ++ b₄ from rfl] at this
  have size_l' :
      (a₁ ++ a₂ ++ a₃).size = (b₁ ++ b₂ ++ b₃).size := by
    rw [ByteArray.size_append, ByteArray.size_append, ByteArray.size_append,
        ByteArray.size_append]
    omega
  have ⟨e_l2, e_4⟩ := byteArrayAppendInj step2 size_l'
  have step3 :
      (a₁ ++ a₂) ++ a₃ = (b₁ ++ b₂) ++ b₃ := by
    have := e_l2
    rwa [show a₁ ++ a₂ ++ a₃ = (a₁ ++ a₂) ++ a₃ from rfl,
         show b₁ ++ b₂ ++ b₃ = (b₁ ++ b₂) ++ b₃ from rfl] at this
  have size_l'' :
      (a₁ ++ a₂).size = (b₁ ++ b₂).size := by
    rw [ByteArray.size_append, ByteArray.size_append]
    omega
  have ⟨e_l3, e_3⟩ := byteArrayAppendInj step3 size_l''
  have ⟨e_1, e_2⟩ := byteArrayAppendInj e_l3 h₁
  exact ⟨e_1, e_2, e_3, e_4, e_5⟩


/-- Helper: split a 224-byte (7 × 32) ByteArray-backed concatenation
    into its seven 32-byte components.  Composed from
    `byteArray_concat_five_split` by peeling the two trailing segments
    with `byteArrayAppendInj` — `++` is left-associated, so the
    seven-fold concatenation is `(five-fold ++ a₆) ++ a₇`. -/
private theorem byteArray_concat_seven_split
    (a₁ a₂ a₃ a₄ a₅ a₆ a₇ b₁ b₂ b₃ b₄ b₅ b₆ b₇ : ByteArray)
    (s₁ : a₁.size = 32) (s₂ : a₂.size = 32) (s₃ : a₃.size = 32)
    (s₄ : a₄.size = 32) (s₅ : a₅.size = 32) (s₆ : a₆.size = 32)
    (_s₇ : a₇.size = 32)
    (t₁ : b₁.size = 32) (t₂ : b₂.size = 32) (t₃ : b₃.size = 32)
    (t₄ : b₄.size = 32) (t₅ : b₅.size = 32) (t₆ : b₆.size = 32)
    (_t₇ : b₇.size = 32)
    (h : a₁ ++ a₂ ++ a₃ ++ a₄ ++ a₅ ++ a₆ ++ a₇ =
         b₁ ++ b₂ ++ b₃ ++ b₄ ++ b₅ ++ b₆ ++ b₇) :
    a₁ = b₁ ∧ a₂ = b₂ ∧ a₃ = b₃ ∧ a₄ = b₄ ∧ a₅ = b₅ ∧
      a₆ = b₆ ∧ a₇ = b₇ := by
  -- Peel `a₇` / `b₇`: the six-fold prefixes are both 192 bytes.
  have size6 :
      (a₁ ++ a₂ ++ a₃ ++ a₄ ++ a₅ ++ a₆).size =
      (b₁ ++ b₂ ++ b₃ ++ b₄ ++ b₅ ++ b₆).size := by
    simp [ByteArray.size_append, s₁, s₂, s₃, s₄, s₅, s₆, t₁, t₂, t₃, t₄, t₅, t₆]
  obtain ⟨h6, h_a₇⟩ := byteArrayAppendInj h size6
  -- Peel `a₆` / `b₆`: the five-fold prefixes are both 160 bytes.
  have size5 :
      (a₁ ++ a₂ ++ a₃ ++ a₄ ++ a₅).size =
      (b₁ ++ b₂ ++ b₃ ++ b₄ ++ b₅).size := by
    simp [ByteArray.size_append, s₁, s₂, s₃, s₄, s₅, t₁, t₂, t₃, t₄, t₅]
  obtain ⟨h5, h_a₆⟩ := byteArrayAppendInj h6 size5
  -- The remaining five-fold split is the existing lemma.
  obtain ⟨e₁, e₂, e₃, e₄, e₅⟩ :=
    byteArray_concat_five_split _ _ _ _ _ _ _ _ _ _
      s₁ s₂ s₃ s₄ s₅ t₁ t₂ t₃ t₄ t₅ h5
  exact ⟨e₁, e₂, e₃, e₄, e₅, h_a₆, h_a₇⟩

/-- The seven-component decomposition of `commitExtendedStateConcat`'s
    pre-image hash.  Under collision-freeness of `hashBytes` on the pre-images below plus the
    32-byte size invariants, equal top-level commits imply
    sub-state-commit-wise equality. -/
theorem commitExtendedStateConcat_subcommits_eq_under_collision_free
    (es₁ es₂ : ExtendedState)
    (h_cf : Bridge.CollisionFreeOn
      [extendedStatePreimage es₁, extendedStatePreimage es₂] hashBytes)
    (h : commitExtendedStateConcat es₁ = commitExtendedStateConcat es₂) :
    commitState es₁.base = commitState es₂.base ∧
    commitNonceState es₁.nonces = commitNonceState es₂.nonces ∧
    commitKeyRegistry es₁.registry = commitKeyRegistry es₂.registry ∧
    commitLocalPolicies es₁.localPolicies = commitLocalPolicies es₂.localPolicies ∧
    commitBridgeState es₁.bridge = commitBridgeState es₂.bridge ∧
    commitEpochBudgets es₁.epochBudgets = commitEpochBudgets es₂.epochBudgets ∧
    commitBudgetPolicy es₁.budgetPolicy = commitBudgetPolicy es₂.budgetPolicy := by
  -- commitExtendedStateConcat es = hashBytes (7 sub-commits concatenated).
  -- Under collision-freedom, equal hashes ⇒ equal pre-images.
  have h_concat :
      commitState es₁.base ++ commitNonceState es₁.nonces ++
        commitKeyRegistry es₁.registry ++ commitLocalPolicies es₁.localPolicies ++
        commitBridgeState es₁.bridge ++ commitEpochBudgets es₁.epochBudgets ++
        commitBudgetPolicy es₁.budgetPolicy =
      commitState es₂.base ++ commitNonceState es₂.nonces ++
        commitKeyRegistry es₂.registry ++ commitLocalPolicies es₂.localPolicies ++
        commitBridgeState es₂.bridge ++ commitEpochBudgets es₂.epochBudgets ++
        commitBudgetPolicy es₂.budgetPolicy :=
    h_cf.apply (by simp [extendedStatePreimage])
      (by simp [extendedStatePreimage]) h
  -- Apply the seven-fold split with each segment's 32-byte size.
  exact byteArray_concat_seven_split _ _ _ _ _ _ _ _ _ _ _ _ _ _
    (commitState_size _) (commitNonceState_size _) (commitKeyRegistry_size _)
    (commitLocalPolicies_size _) (commitBridgeState_size _)
    (commitEpochBudgets_size _) (commitBudgetPolicy_size _)
    (commitState_size _) (commitNonceState_size _) (commitKeyRegistry_size _)
    (commitLocalPolicies_size _) (commitBridgeState_size _)
    (commitEpochBudgets_size _) (commitBudgetPolicy_size _) h_concat

/-- #220: Top-level commitment injectivity under
    `CollisionFreeOn`.  Equal top-level commits imply
    extensional equality of the underlying states.

    **Important: this theorem proves the *encoded* sub-state
    bytes agree.**  Whether this lifts to extensional equality on
    the underlying TreeMaps depends on the encoder's
    canonicalisation discipline (`State.encode` and the rest go
    through `toList` which is sorted; the decoder's canonicality
    enforcement closes the gap on input).

    Under the existing Phase-4 canonical-encoding discipline:
    `state_encode_deterministic`, `extendedState_encode_deterministic`,
    and the §8.8.6 `keysStrictlyAscending` decoder check
    establish that the encoded bytes uniquely determine the
    extensional state.  This theorem is the cryptographic step
    that lifts equal hashes to equal bytes; the encoder
    canonicality is the deterministic step that lifts equal
    bytes to equal extensional state.

    The theorem statement uses extensional equality directly to
    make the consumer-side property visible.  The proof routes
    through bytes-equality (which is what the cryptographic
    argument gives) and then closes via the encoder's
    determinism + canonicalisation. -/
theorem commitExtendedStateConcat_subcommits_bytes_eq_under_collision_free
    (es₁ es₂ : ExtendedState)
    (h_cf : Bridge.CollisionFreeOn
      (extendedStateCommitPreimages es₁ es₂) hashBytes)
    (h : commitExtendedStateConcat es₁ = commitExtendedStateConcat es₂) :
    ByteArray.mk (State.encode es₁.base).toArray =
      ByteArray.mk (State.encode es₂.base).toArray ∧
    ByteArray.mk (NonceState.encode es₁.nonces).toArray =
      ByteArray.mk (NonceState.encode es₂.nonces).toArray ∧
    ByteArray.mk (KeyRegistry.encodeMap es₁.registry).toArray =
      ByteArray.mk (KeyRegistry.encodeMap es₂.registry).toArray ∧
    ByteArray.mk (Encodable.encode (T := LocalPolicies) es₁.localPolicies).toArray =
      ByteArray.mk (Encodable.encode (T := LocalPolicies) es₂.localPolicies).toArray ∧
    ByteArray.mk (Encodable.encode (T := BridgeState) es₁.bridge).toArray =
      ByteArray.mk (Encodable.encode (T := BridgeState) es₂.bridge).toArray ∧
    ByteArray.mk (Encodable.encode (T := EpochBudgetState) es₁.epochBudgets).toArray =
      ByteArray.mk (Encodable.encode (T := EpochBudgetState) es₂.epochBudgets).toArray ∧
    ByteArray.mk (Encodable.encode (T := BudgetPolicy) es₁.budgetPolicy).toArray =
      ByteArray.mk (Encodable.encode (T := BudgetPolicy) es₂.budgetPolicy).toArray := by
  -- Each step below draws its two pre-images from the full set, so
  -- the shared hypothesis restricts to every sub-call by `mono`.
  have sub : ∀ x y : ByteArray,
      x ∈ extendedStateCommitPreimages es₁ es₂ →
      y ∈ extendedStateCommitPreimages es₁ es₂ →
      Bridge.CollisionFreeOn [x, y] hashBytes := by
    intro x y hx hy
    refine h_cf.mono ?_
    intro z hz
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hz
    rcases hz with rfl | rfl
    · exact hx
    · exact hy
  have mem₁ : ∀ z ∈ subStatePreimages es₁,
      z ∈ extendedStateCommitPreimages es₁ es₂ := by
    intro z hz
    exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _
      (List.mem_append_left _ hz))
  have mem₂ : ∀ z ∈ subStatePreimages es₂,
      z ∈ extendedStateCommitPreimages es₁ es₂ := by
    intro z hz
    exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _
      (List.mem_append_right _ hz))
  obtain ⟨h_s, h_n, h_kr, h_lp, h_bs, h_eb, h_bp⟩ :=
    commitExtendedStateConcat_subcommits_eq_under_collision_free es₁ es₂
      (h_cf.mono (by
        intro z hz
        simp only [List.mem_cons, List.not_mem_nil, or_false] at hz
        simp only [extendedStateCommitPreimages, List.mem_cons]
        rcases hz with rfl | rfl
        · exact Or.inl rfl
        · exact Or.inr (Or.inl rfl))) h
  exact ⟨commitState_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_s,
         commitNonceState_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_n,
         commitKeyRegistry_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_kr,
         commitLocalPolicies_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_lp,
         commitBridgeState_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_bs,
         commitEpochBudgets_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_eb,
         commitBudgetPolicy_bytes_injective_under_collision_free _ _
           (sub _ _ (mem₁ _ (by simp [subStatePreimages]))
                    (mem₂ _ (by simp [subStatePreimages]))) h_bp⟩

/-! ## EI.8 — Extensional-equality lift of the subcommits theorem

The bytes-equality theorem
`commitExtendedStateConcat_subcommits_bytes_eq_under_collision_free`
establishes that under collision-freedom of `hashBytes`, equal
top-level commits imply equal sub-state CBE encodings (modulo
`ByteArray.mk ∘ .toArray` framing).  Workstream EI lifts this from
*bytes-equality* to *extensional state equality*: equal commits
imply that the underlying TreeMap-backed sub-states are
`Std.TreeMap.Equiv`-equivalent (i.e. share the same logical
`(key, value)` content, modulo RB-tree shape).

This sub-section ships:

  * **EI.8.a** `ExtendedState.extEq` — the per-sub-state `Equiv`
    conjunction.  Custom relation because the nested `State.balances`
    requires the EI.2 `State.Equiv` rather than a flat `Std.TreeMap.Equiv`.

  * **EI.8.b**
    `commitExtendedStateConcat_subcommits_extensional_eq_under_collision_free`
    — the headline composition theorem.  Routes the five sub-state
    bytes-equalities (from the existing theorem) through EI.2.d /
    EI.3.a / EI.4.a / EI.5.d / EI.7.e to derive the per-sub-state
    `Equiv` conjuncts.

The bytes-equality theorem stays in source as a load-bearing
primitive (used by sub-state-specific theorems and the runtime
audit binary); EI.8 *adds* the extensional variant alongside.

The composition theorem requires the deployment to bound every
encoded sub-state's pair-list lengths and per-value sizes by the
canonical CBE bound (`< 2^64`).  These bounds are deployment-level
invariants enforced at the runtime boundary (Phase 5 + §8.5);
operators that violate them open their deployment to bytes-collisions
on the encoder side, which is independent of (and orthogonal to) the
fault-proof game's correctness. -/

/-- Per-sub-state extensional equality on `ExtendedState`.  This is
    a `Prop`-valued relation that captures "two `ExtendedState`s
    encode to the same canonical bytes" through the EI.2 – EI.7
    `Equiv` conclusions.

    The shape mirrors the byte-decomposition of `commitExtendedStateConcat`:
    five conjuncts for the five sub-states (`base`, `nonces`,
    `registry`, `localPolicies`, `bridge`-as-three-fields).

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.8
    EI.8.a). -/
def ExtendedState.extEq (es₁ es₂ : ExtendedState) : Prop :=
  State.Equiv es₁.base es₂.base ∧
  es₁.nonces.next.Equiv es₂.nonces.next ∧
  es₁.registry.Equiv es₂.registry ∧
  es₁.localPolicies.Equiv es₂.localPolicies ∧
  es₁.bridge.consumed.Equiv es₂.bridge.consumed ∧
  es₁.bridge.pending.Equiv es₂.bridge.pending ∧
  es₁.bridge.nextWdId = es₂.bridge.nextWdId ∧
  es₁.bridge.boldCircuitClosed = es₂.bridge.boldCircuitClosed ∧
  es₁.bridge.boldTvlCap = es₂.bridge.boldTvlCap ∧
  es₁.bridge.boldTotalLockedValue = es₂.bridge.boldTotalLockedValue ∧
  es₁.bridge.ammDisabled = es₂.bridge.ammDisabled

/-- `ExtendedState.extEq` is reflexive.  Trivially derived from the
    per-sub-state `Equiv.refl` lemmas. -/
theorem ExtendedState.extEq.refl (es : ExtendedState) : ExtendedState.extEq es es := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · exact State.Equiv.refl es.base
  · exact Std.TreeMap.Equiv.rfl
  · exact Std.TreeMap.Equiv.rfl
  · exact Std.TreeMap.Equiv.rfl
  · exact Std.TreeMap.Equiv.rfl
  · exact Std.TreeMap.Equiv.rfl
  · rfl
  · rfl
  · rfl
  · rfl
  · rfl

/-- The canonical-bounds bundle for an `ExtendedState`.  Each
    deployment maintains these invariants at the runtime boundary;
    they are the explicit version of "all encoded sub-state widths
    fit in 64-bit fields".

    Bundled into a single `structure` so the composition theorem's
    signature stays tractable. -/
structure ExtendedState.CanonicalBounds (es : ExtendedState) : Prop where
  /-- The outer `balances` map's pair-list length fits. -/
  base_outer_len : es.base.balances.toList.length < 256 ^ 8
  /-- Each inner `BalanceMap` pair-list length fits. -/
  base_inner_len : ∀ p ∈ es.base.balances.toList, p.2.toList.length < 256 ^ 8
  /-- Each inner balance fits the 33-byte amount head's `2^256`
      range — the width of an EVM word, and the same ceiling
      `Laws.maxAmount` enforces as a precondition conjunct on every
      crediting law.  Not the `2^64` an identifier field would impose:
      a wei-denominated balance crosses `2^64` at ~18.45 ETH.  This
      field is DISCHARGED rather than assumed, by
      `FaultProof.canonicalBounds_base_amt_of_reachable`. -/
  base_amt : ∀ p ∈ es.base.balances.toList, ∀ q ∈ p.2.toList, q.2 < 256 ^ 32
  /-- Each inner-map framed-bytes size fits. -/
  base_inner_size : ∀ p ∈ es.base.balances.toList,
                    (BalanceMap.encodeAsBytes p.2).size < 256 ^ 8
  /-- The nonce-ledger pair-list length fits. -/
  nonces_len : es.nonces.next.toList.length < 256 ^ 8
  /-- Each per-actor nonce value fits. -/
  nonces_val : ∀ p ∈ es.nonces.next.toList, p.2 < 256 ^ 8
  /-- The key-registry pair-list length fits. -/
  registry_len : es.registry.toList.length < 256 ^ 8
  /-- Each per-actor public-key byte size fits. -/
  registry_size : ∀ p ∈ es.registry.toList, p.2.size < 256 ^ 8
  /-- The local-policies pair-list length fits. -/
  lp_len : es.localPolicies.toList.length < 256 ^ 8
  /-- Each per-actor policy framed-bytes size fits. -/
  lp_size : ∀ p ∈ es.localPolicies.toList,
            (LocalPolicy.encodeAsBytes p.2).size < 256 ^ 8
  /-- Each per-actor policy satisfies `fieldsBounded`. -/
  lp_pol : ∀ p ∈ es.localPolicies.toList, LocalPolicy.fieldsBounded p.2
  /-- The bridge consumed-map pair-list length fits. -/
  bs_cons_len : es.bridge.consumed.toList.length < 256 ^ 8
  /-- Each per-deposit-id fits. -/
  bs_cons_id : ∀ p ∈ es.bridge.consumed.toList, p.1 < 256 ^ 8
  /-- Each per-record framed-bytes size fits. -/
  bs_cons_size : ∀ p ∈ es.bridge.consumed.toList,
                 (Bridge.DepositRecord.encodeAsBytes p.2).size < 256 ^ 8
  /-- Each deposit record's fields fit. -/
  bs_cons_rec : ∀ p ∈ es.bridge.consumed.toList,
                p.2.resource.toNat < 256 ^ 8 ∧ p.2.userAmount < 256 ^ 32 ∧
                p.2.poolAmount < 256 ^ 32 ∧ p.2.budgetGrant < 256 ^ 8
  /-- The bridge pending-map pair-list length fits. -/
  bs_pend_len : es.bridge.pending.toList.length < 256 ^ 8
  /-- Each per-withdrawal-id fits. -/
  bs_pend_id : ∀ p ∈ es.bridge.pending.toList, p.1 < 256 ^ 8
  /-- Each per-withdrawal framed-bytes size fits. -/
  bs_pend_size : ∀ p ∈ es.bridge.pending.toList,
                 (Bridge.PendingWithdrawal.encodeAsBytes p.2).size < 256 ^ 8
  /-- Each pending withdrawal's fields fit. -/
  bs_pend_wd : ∀ p ∈ es.bridge.pending.toList,
               p.2.resource.toNat < 256 ^ 8 ∧
               p.2.amount < 256 ^ 32 ∧
               p.2.l2LogIndex < 256 ^ 8 ∧
               p.2.wdId < 256 ^ 8
  /-- The bridge nextWdId fits. -/
  bs_nxt : es.bridge.nextWdId < 256 ^ 8
  /-- GP.11.8: BOLD TVL cap fits. -/
  bs_tvlCap : es.bridge.boldTvlCap < 256 ^ 32
  /-- GP.11.8: BOLD total locked value fits. -/
  bs_totalLocked : es.bridge.boldTotalLockedValue < 256 ^ 32
  /-- The epoch-budget pair-list length fits. -/
  eb_len : es.epochBudgets.toList.length < 256 ^ 8
  /-- Each per-actor budget's epoch and balance fit. -/
  eb_val : ∀ p ∈ es.epochBudgets.toList,
           p.2.lastSeenEpoch < 256 ^ 8 ∧ p.2.budgetBalance < 256 ^ 8
  /-- The budget policy's three scalars fit, and its per-action cost is
      at least one.

      The `1 ≤ actionCost` conjunct is not a width bound and is not
      decoration: `BudgetPolicy.mkBounded` clamps the cost to that
      floor and `BudgetPolicy.decode` rejects a zero, so a policy with
      `actionCost = 0` is one no deployment can hold and no encoding
      round-trips.  A zero-cost policy would also make the admission
      budget gate vacuous, which is the reason the clamp exists. -/
  bp_val : ∀ ft ac ce, es.budgetPolicy = .bounded ft ac ce →
           ft < 256 ^ 8 ∧ ac < 256 ^ 8 ∧ ce < 256 ^ 8 ∧ 1 ≤ ac

/-! ### Reading the bounds off a cell

`CanonicalBounds` is stated over the sub-state maps' pair lists,
because that is the form the encoders consume.  A cell reader reaches
a value through `getElem?` with a default, so every consumer would
otherwise repeat the same membership translation — and the
`none` branches, where the default supplies the bound, are easy to get
subtly wrong.  These do it once. -/

/-- A balance read through `getBalance` fits the amount head, absent
    entries included: the default is `0`. -/
theorem getBalance_lt_of_canonicalBounds (es : ExtendedState)
    (r : ResourceId) (a : ActorId) (h : ExtendedState.CanonicalBounds es) :
    LegalKernel.getBalance es.base r a < 256 ^ 32 := by
  unfold LegalKernel.getBalance
  match h_outer : es.base.balances[r]? with
  | none    => exact Nat.pow_pos (by decide)
  | some bm =>
    show bm[a]?.getD 0 < 256 ^ 32
    match h_inner : bm[a]? with
    | none   => exact Nat.pow_pos (by decide)
    | some v =>
      simp only [Option.getD_some]
      exact h.base_amt (r, bm) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_outer)
        (a, v) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_inner)

/-- A nonce read through `expectsNonce` fits the uint head. -/
theorem expectsNonce_lt_of_canonicalBounds (es : ExtendedState) (a : ActorId)
    (h : ExtendedState.CanonicalBounds es) :
    Authority.expectsNonce es a < 256 ^ 8 := by
  unfold Authority.expectsNonce
  match h_n : es.nonces.next[a]? with
  | none   => exact Nat.pow_pos (by decide)
  | some n =>
    show (some n).getD 0 < 256 ^ 8
    simp only [Option.getD_some]
    exact h.nonces_val (a, n) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_n)

/-- A live registry key's size fits. -/
theorem registry_size_lt_of_canonicalBounds (es : ExtendedState) (a : ActorId)
    (pk : Authority.PublicKey) (h_r : es.registry[a]? = some pk)
    (h : ExtendedState.CanonicalBounds es) : pk.size < 256 ^ 8 :=
  h.registry_size (a, pk) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_r)

/-- A live local policy's fields are bounded. -/
theorem localPolicy_bounded_of_canonicalBounds (es : ExtendedState) (a : ActorId)
    (p : Authority.LocalPolicy) (h_p : es.localPolicies[a]? = some p)
    (h : ExtendedState.CanonicalBounds es) : LocalPolicy.fieldsBounded p :=
  h.lp_pol (a, p) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_p)

/-- A live consumed-deposit record's fields are bounded. -/
theorem depositRecord_bounded_of_canonicalBounds (es : ExtendedState)
    (d : Bridge.DepositId) (rec : Bridge.DepositRecord)
    (h_d : es.bridge.consumed[d]? = some rec)
    (h : ExtendedState.CanonicalBounds es) :
    rec.resource.toNat < 256 ^ 8 ∧ rec.userAmount < 256 ^ 32 ∧
      rec.poolAmount < 256 ^ 32 ∧ rec.budgetGrant < 256 ^ 8 :=
  h.bs_cons_rec (d, rec) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_d)

/-- A live pending withdrawal's fields are bounded. -/
theorem pendingWithdrawal_bounded_of_canonicalBounds (es : ExtendedState)
    (w : Bridge.WithdrawalId) (pw : Bridge.PendingWithdrawal)
    (h_w : es.bridge.pending[w]? = some pw)
    (h : ExtendedState.CanonicalBounds es) :
    pw.resource.toNat < 256 ^ 8 ∧ pw.amount < 256 ^ 32 ∧
      pw.l2LogIndex < 256 ^ 8 ∧ pw.wdId < 256 ^ 8 :=
  h.bs_pend_wd (w, pw) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_w)

/-- An actor's epoch budget is bounded, absent entries included: the
    default `ActorBudget.empty` is all zeros. -/
theorem actorBudget_bounded_of_canonicalBounds (es : ExtendedState) (a : ActorId)
    (h : ExtendedState.CanonicalBounds es) :
    (es.epochBudgets[a]?.getD Authority.ActorBudget.empty).lastSeenEpoch < 256 ^ 8 ∧
      (es.epochBudgets[a]?.getD Authority.ActorBudget.empty).budgetBalance < 256 ^ 8 := by
  match h_b : es.epochBudgets[a]? with
  | none   =>
    exact ⟨Nat.pow_pos (by decide), Nat.pow_pos (by decide)⟩
  | some b =>
    simp only [Option.getD_some]
    exact h.eb_val (a, b) (Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr h_b)

/-- The budget policy's width bounds, with the anti-spam floor
    separated out — a caller usually needs only one of the two. -/
theorem budgetPolicy_bounded_of_canonicalBounds (es : ExtendedState)
    (ft ac ce : Nat) (h_pol : es.budgetPolicy = .bounded ft ac ce)
    (h : ExtendedState.CanonicalBounds es) :
    ft < 256 ^ 8 ∧ ac < 256 ^ 8 ∧ ce < 256 ^ 8 :=
  let ⟨h₁, h₂, h₃, _⟩ := h.bp_val ft ac ce h_pol
  ⟨h₁, h₂, h₃⟩

/-- EI.8.b — Composition theorem.  Under
    `CollisionFreeOn` plus the canonical-bounds invariants
    on both `ExtendedState`s, equal top-level commits imply
    extensional state equality (the per-sub-state `Equiv`
    conjunction packaged as `ExtendedState.extEq`).

    **Proof.**  Compose the existing bytes-equality theorem
    `commitExtendedStateConcat_subcommits_bytes_eq_under_collision_free`
    with the per-sub-state EI lemmas:

      * `State.encode_injective` (EI.2.d) for `base`.
      * `NonceState.encode_injective` (EI.3.a) for `nonces`.
      * `KeyRegistry.encodeMap_injective` (EI.4.a) for `registry`.
      * `LocalPolicies.encodeMap_injective` (EI.5.d) for `localPolicies`.
      * `Bridge.BridgeState.encode_injective` (EI.7.e) for `bridge`.

    Each sub-state's bytes-equality is stripped of the
    `ByteArray.mk ∘ .toArray` framing (via the existing helpers in
    the bytes-eq theorem) and lifted to its `Equiv`/`Eq` conclusion
    via the corresponding EI lemma.

    Workstream EI (`docs/planning/encoder_injectivity_plan.md` §4.8
    EI.8.b).  Retires CLAUDE.md footnote 1. -/
theorem commitExtendedStateConcat_subcommits_extensional_eq_under_collision_free
    (es₁ es₂ : ExtendedState)
    (h_cf : Bridge.CollisionFreeOn
      (extendedStateCommitPreimages es₁ es₂) hashBytes)
    (h_b₁ : ExtendedState.CanonicalBounds es₁)
    (h_b₂ : ExtendedState.CanonicalBounds es₂)
    (h : commitExtendedStateConcat es₁ = commitExtendedStateConcat es₂) :
    ExtendedState.extEq es₁ es₂ := by
  -- Step 1: Apply the existing bytes-equality theorem to extract the
  -- five sub-state byte-array equalities.
  obtain ⟨h_b, h_n, h_kr, h_lp, h_bs, _h_eb, h_bp⟩ :=
    commitExtendedStateConcat_subcommits_bytes_eq_under_collision_free es₁ es₂ h_cf h
  -- Step 2: Strip the `ByteArray.mk ∘ .toArray` framing on each
  -- sub-state byte-equality to recover the underlying `Stream` (List
  -- UInt8) equality that the EI lemmas consume.
  have h_base_stream : State.encode es₁.base = State.encode es₂.base := by
    have h_arr : (State.encode es₁.base).toArray = (State.encode es₂.base).toArray := by
      injection h_b
    have h_list : (State.encode es₁.base).toArray.toList
                = (State.encode es₂.base).toArray.toList := by rw [h_arr]
    rw [List.toList_toArray, List.toList_toArray] at h_list
    exact h_list
  have h_nonces_stream : NonceState.encode es₁.nonces = NonceState.encode es₂.nonces := by
    have h_arr : (NonceState.encode es₁.nonces).toArray
               = (NonceState.encode es₂.nonces).toArray := by injection h_n
    have h_list : (NonceState.encode es₁.nonces).toArray.toList
                = (NonceState.encode es₂.nonces).toArray.toList := by rw [h_arr]
    rw [List.toList_toArray, List.toList_toArray] at h_list
    exact h_list
  have h_registry_stream :
      KeyRegistry.encodeMap es₁.registry = KeyRegistry.encodeMap es₂.registry := by
    have h_arr : (KeyRegistry.encodeMap es₁.registry).toArray
               = (KeyRegistry.encodeMap es₂.registry).toArray := by injection h_kr
    have h_list : (KeyRegistry.encodeMap es₁.registry).toArray.toList
                = (KeyRegistry.encodeMap es₂.registry).toArray.toList := by rw [h_arr]
    rw [List.toList_toArray, List.toList_toArray] at h_list
    exact h_list
  have h_lp_stream :
      Encodable.encode (T := LocalPolicies) es₁.localPolicies =
      Encodable.encode (T := LocalPolicies) es₂.localPolicies := by
    have h_arr : (Encodable.encode (T := LocalPolicies) es₁.localPolicies).toArray
               = (Encodable.encode (T := LocalPolicies) es₂.localPolicies).toArray := by
      injection h_lp
    have h_list : (Encodable.encode (T := LocalPolicies) es₁.localPolicies).toArray.toList
                = (Encodable.encode (T := LocalPolicies) es₂.localPolicies).toArray.toList := by
      rw [h_arr]
    rw [List.toList_toArray, List.toList_toArray] at h_list
    exact h_list
  have h_bridge_stream :
      Encodable.encode (T := BridgeState) es₁.bridge =
      Encodable.encode (T := BridgeState) es₂.bridge := by
    have h_arr : (Encodable.encode (T := BridgeState) es₁.bridge).toArray
               = (Encodable.encode (T := BridgeState) es₂.bridge).toArray := by
      injection h_bs
    have h_list : (Encodable.encode (T := BridgeState) es₁.bridge).toArray.toList
                = (Encodable.encode (T := BridgeState) es₂.bridge).toArray.toList := by
      rw [h_arr]
    rw [List.toList_toArray, List.toList_toArray] at h_list
    exact h_list
  -- Step 3: Apply each EI lemma to derive the corresponding Equiv/Eq.
  -- EI.2.d for base (nested map → State.Equiv).
  have h_base : State.Equiv es₁.base es₂.base :=
    State.encode_injective es₁.base es₂.base
      h_b₁.base_outer_len h_b₂.base_outer_len
      h_b₁.base_inner_len h_b₂.base_inner_len
      h_b₁.base_amt h_b₂.base_amt
      h_b₁.base_inner_size h_b₂.base_inner_size
      h_base_stream
  -- EI.3.a for nonces (flat map → Equiv on `.next`).
  have h_nonces : es₁.nonces.next.Equiv es₂.nonces.next :=
    NonceState.encode_injective es₁.nonces es₂.nonces
      h_b₁.nonces_len h_b₂.nonces_len
      h_b₁.nonces_val h_b₂.nonces_val
      h_nonces_stream
  -- EI.4.a for registry.
  have h_registry : es₁.registry.Equiv es₂.registry :=
    KeyRegistry.encodeMap_injective es₁.registry es₂.registry
      h_b₁.registry_len h_b₂.registry_len
      h_b₁.registry_size h_b₂.registry_size
      h_registry_stream
  -- EI.5.d for localPolicies.  Note: Encodable.encode (T := LocalPolicies)
  -- unfolds definitionally to LocalPolicies.encodeMap via the instance.
  have h_lp_stream' :
      LocalPolicies.encodeMap es₁.localPolicies = LocalPolicies.encodeMap es₂.localPolicies :=
    h_lp_stream
  have h_lp_equiv : es₁.localPolicies.Equiv es₂.localPolicies :=
    LocalPolicies.encodeMap_injective es₁.localPolicies es₂.localPolicies
      h_b₁.lp_len h_b₂.lp_len
      h_b₁.lp_size h_b₂.lp_size
      h_b₁.lp_pol h_b₂.lp_pol
      h_lp_stream'
  -- EI.7.e for bridge (seven-segment concatenation, GP.11.8 + GP.11.10).
  have h_bridge_stream' :
      Bridge.BridgeState.encode es₁.bridge = Bridge.BridgeState.encode es₂.bridge :=
    h_bridge_stream
  have ⟨h_consumed, h_pending, h_nextWdId,
        h_circuit, h_tvlCap, h_totalLocked, h_ammDisabled⟩ :=
    Bridge.BridgeState.encode_injective es₁.bridge es₂.bridge
      h_b₁.bs_cons_len h_b₂.bs_cons_len
      h_b₁.bs_cons_id h_b₂.bs_cons_id
      h_b₁.bs_cons_size h_b₂.bs_cons_size
      h_b₁.bs_cons_rec h_b₂.bs_cons_rec
      h_b₁.bs_pend_len h_b₂.bs_pend_len
      h_b₁.bs_pend_id h_b₂.bs_pend_id
      h_b₁.bs_pend_size h_b₂.bs_pend_size
      h_b₁.bs_pend_wd h_b₂.bs_pend_wd
      h_b₁.bs_nxt h_b₂.bs_nxt
      h_b₁.bs_tvlCap h_b₂.bs_tvlCap
      h_b₁.bs_totalLocked h_b₂.bs_totalLocked
      h_bridge_stream'
  -- Step 4: Assemble the per-sub-state conjuncts into ExtendedState.extEq.
  exact ⟨h_base, h_nonces, h_registry, h_lp_equiv, h_consumed, h_pending,
         h_nextWdId, h_circuit, h_tvlCap, h_totalLocked,
         h_ammDisabled⟩

/-! ## GP.11.8 / GP.11.10 — mirror state-root commitment integration theorems

The following theorems ratify that the GP.11.8 extension to
`BridgeState` (and its GP.11.10 `ammDisabled` widening) achieves its
goal: the state-root preimage covers every surviving L1-mirror
governance field — the BOLD deposit guards *and the disaster-recovery
kill switch* — and genesis states commit deterministically.  (The two
excised L1-AMM book mirrors are gone from the preimage entirely, so
the v1.2/v1.3 layout-migration theorems that reasoned about them are
gone too: with zero deployed contracts there is no layout to migrate
FROM.) -/

/-- GP.11.8 + GP.11.10: the state-root preimage covers
    `boldCircuitClosed`, `boldTvlCap`, `boldTotalLockedValue`, and
    `ammDisabled`.
    Proof: the `BridgeState.encode` definition includes all four
    fields in sequence after the v1.2 segments. -/
theorem bridgeState_commit_includes_mirrorState (bs : Bridge.BridgeState) :
    Bridge.BridgeState.encode bs =
      Bridge.BridgeState.encodeConsumed bs ++
      Bridge.BridgeState.encodePending bs ++
      Encodable.encode (T := Nat) bs.nextWdId ++
      Encodable.encode (T := Nat) (if bs.boldCircuitClosed then 1 else 0) ++
      encodeAmount bs.boldTvlCap ++
      encodeAmount bs.boldTotalLockedValue ++
      Encodable.encode (T := Nat) (if bs.ammDisabled then 1 else 0) := by
  rfl

/-- GP.11.8 helper: v1.2 base-encoding prefix — consumed deposits,
    pending withdrawals, and next-withdrawal-ID. -/
def bridgeStateEncodeBase (bs : Bridge.BridgeState) : Encoding.Stream :=
  Bridge.BridgeState.encodeConsumed bs ++
  Bridge.BridgeState.encodePending bs ++
  Encodable.encode (T := Nat) bs.nextWdId

/-- GP.11.8 / GP.11.10 helper: mirror suffix — the three BOLD
    deposit-guard fields plus the GP.11.10 `ammDisabled` kill-switch
    mirror.  At genesis defaults this suffix is a fixed constant,
    which is the structural reason genesis commitments are
    deterministic (see `bridgeState_mirror_genesis_suffix_const`). -/
def bridgeStateEncodeMirrorSuffix (bs : Bridge.BridgeState) : Encoding.Stream :=
  Encodable.encode (T := Nat) (if bs.boldCircuitClosed then 1 else 0) ++
  encodeAmount bs.boldTvlCap ++
  encodeAmount bs.boldTotalLockedValue ++
  Encodable.encode (T := Nat) (if bs.ammDisabled then 1 else 0)

/-- GP.11.8: the encoding factorizes as a v1.2 base prefix appended
    with the mirror suffix. -/
theorem bridgeState_encode_factored (bs : Bridge.BridgeState) :
    Bridge.BridgeState.encode bs =
    bridgeStateEncodeBase bs ++ bridgeStateEncodeMirrorSuffix bs := by
  simp only [Bridge.BridgeState.encode, bridgeStateEncodeBase,
             bridgeStateEncodeMirrorSuffix, List.append_assoc]

/-- GP.11.8 / GP.11.10: two bridge states whose mirror fields are all
    at genesis defaults (circuit open, caps zero, kill switch not
    fired) produce identical mirror encoding suffixes. -/
theorem bridgeState_mirror_genesis_suffix_const
    (bs₁ bs₂ : Bridge.BridgeState)
    (h₁ : bs₁.boldCircuitClosed = false ∧ bs₁.boldTvlCap = 0 ∧
           bs₁.boldTotalLockedValue = 0 ∧ bs₁.ammDisabled = false)
    (h₂ : bs₂.boldCircuitClosed = false ∧ bs₂.boldTvlCap = 0 ∧
           bs₂.boldTotalLockedValue = 0 ∧ bs₂.ammDisabled = false) :
    bridgeStateEncodeMirrorSuffix bs₁ = bridgeStateEncodeMirrorSuffix bs₂ := by
  obtain ⟨hc₁, ht₁, hl₁, hd₁⟩ := h₁
  obtain ⟨hc₂, ht₂, hl₂, hd₂⟩ := h₂
  simp only [bridgeStateEncodeMirrorSuffix, hc₁, ht₁, hl₁, hd₁,
             hc₂, ht₂, hl₂, hd₂]

/-- GP.11.8: genesis-mirror determinism.  Two `BridgeState`s that
    agree on the v1.2 fields (`consumed`, `pending`, `nextWdId`) and
    both have genesis mirror values produce the same commitment.

    **Structural argument:** the encoding factorizes as
    `encodeBase ++ encodeMirrorSuffix`.  When v1.2 fields agree the
    base prefixes are identical; when the mirror fields are at genesis
    the suffixes are identical; therefore the full encodings agree and
    `commitBridgeState` (which hashes the encoding) agrees. -/
theorem bridgeState_commit_extends_v1_2
    (bs₁ bs₂ : Bridge.BridgeState)
    (h_consumed : bs₁.consumed = bs₂.consumed)
    (h_pending  : bs₁.pending  = bs₂.pending)
    (h_nextWdId : bs₁.nextWdId = bs₂.nextWdId)
    (h_genesis₁ : bs₁.boldCircuitClosed = false ∧ bs₁.boldTvlCap = 0 ∧
                   bs₁.boldTotalLockedValue = 0 ∧ bs₁.ammDisabled = false)
    (h_genesis₂ : bs₂.boldCircuitClosed = false ∧ bs₂.boldTvlCap = 0 ∧
                   bs₂.boldTotalLockedValue = 0 ∧ bs₂.ammDisabled = false) :
    commitBridgeState bs₁ = commitBridgeState bs₂ := by
  have hbase : bridgeStateEncodeBase bs₁ = bridgeStateEncodeBase bs₂ := by
    simp only [bridgeStateEncodeBase, Bridge.BridgeState.encodeConsumed,
               Bridge.BridgeState.encodePending, h_consumed, h_pending, h_nextWdId]
  have hsuffix : bridgeStateEncodeMirrorSuffix bs₁ = bridgeStateEncodeMirrorSuffix bs₂ :=
    bridgeState_mirror_genesis_suffix_const bs₁ bs₂ h_genesis₁ h_genesis₂
  have henc : Bridge.BridgeState.encode bs₁ = Bridge.BridgeState.encode bs₂ := by
    rw [bridgeState_encode_factored, bridgeState_encode_factored, hbase, hsuffix]
  show commitBridgeState bs₁ = commitBridgeState bs₂
  unfold commitBridgeState
  rw [show Encodable.encode (T := BridgeState) bs₁ = Bridge.BridgeState.encode bs₁ from rfl,
      show Encodable.encode (T := BridgeState) bs₂ = Bridge.BridgeState.encode bs₂ from rfl,
      henc]

/-- GP.11.10 headline: `ammDisabled` is *reflected in the state-root
    preimage*.  Under collision-freeness of `hashBytes` on the pre-images below, two bridge states
    that agree on every other field but differ on the `ammDisabled`
    kill-switch mirror produce **different** bridge-state commitments
    — so a sequencer cannot publish a state root that silently
    misrepresents whether the L1 AMM has been emergency-disabled,
    and the fault-proof game can adjudicate a dispute that turns on
    the disabled state.

    **Proof.**  Equal commits lift (via collision-freedom) to equal
    canonical encodings; the six leading segments agree by
    hypothesis, so list-append cancellation isolates the trailing
    `ammDisabled` segment; CBE-uint injectivity on the canonical 0/1
    range then forces the two flags to agree — contradiction. -/
theorem commitBridgeState_reflects_ammDisabled
    (bs₁ bs₂ : Bridge.BridgeState)
    (h_cf : Bridge.CollisionFreeOn
      [ ByteArray.mk (Encodable.encode (T := BridgeState) bs₁).toArray
      , ByteArray.mk (Encodable.encode (T := BridgeState) bs₂).toArray ]
      hashBytes)
    (h_consumed : bs₁.consumed.toList = bs₂.consumed.toList)
    (h_pending  : bs₁.pending.toList  = bs₂.pending.toList)
    (h_nextWdId : bs₁.nextWdId = bs₂.nextWdId)
    (h_circuit  : bs₁.boldCircuitClosed = bs₂.boldCircuitClosed)
    (h_tvlCap   : bs₁.boldTvlCap = bs₂.boldTvlCap)
    (h_totalLocked : bs₁.boldTotalLockedValue = bs₂.boldTotalLockedValue)
    (h_ne : bs₁.ammDisabled ≠ bs₂.ammDisabled) :
    commitBridgeState bs₁ ≠ commitBridgeState bs₂ := by
  intro h_eq
  -- Step 1: collision-freedom lifts equal commits to equal framed bytes.
  have h_bytes :=
    commitBridgeState_bytes_injective_under_collision_free bs₁ bs₂ h_cf h_eq
  -- Step 2: strip the `ByteArray.mk ∘ .toArray` framing to recover the
  -- underlying `Stream` equality (same pattern as the EI.8 composition).
  have h_arr : (Encodable.encode (T := BridgeState) bs₁).toArray
             = (Encodable.encode (T := BridgeState) bs₂).toArray := by
    injection h_bytes
  have h_list : (Encodable.encode (T := BridgeState) bs₁).toArray.toList
              = (Encodable.encode (T := BridgeState) bs₂).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  have h_enc : Bridge.BridgeState.encode bs₁ = Bridge.BridgeState.encode bs₂ :=
    h_list
  -- Step 3: the six leading segments agree by hypothesis, so the
  -- whole-encoding equality cancels down to the trailing `ammDisabled`
  -- segment.  `BridgeState.encode` is left-associated, so the term is
  -- `(six-segment prefix) ++ encode (if ammDisabled then 1 else 0)`.
  have h_prefix :
      Bridge.BridgeState.encodeConsumed bs₁ ++
      Bridge.BridgeState.encodePending bs₁ ++
      Encodable.encode (T := Nat) bs₁.nextWdId ++
      Encodable.encode (T := Nat) (if bs₁.boldCircuitClosed then 1 else 0) ++
      encodeAmount bs₁.boldTvlCap ++
      encodeAmount bs₁.boldTotalLockedValue =
      Bridge.BridgeState.encodeConsumed bs₂ ++
      Bridge.BridgeState.encodePending bs₂ ++
      Encodable.encode (T := Nat) bs₂.nextWdId ++
      Encodable.encode (T := Nat) (if bs₂.boldCircuitClosed then 1 else 0) ++
      encodeAmount bs₂.boldTvlCap ++
      encodeAmount bs₂.boldTotalLockedValue := by
    simp only [Bridge.BridgeState.encodeConsumed, Bridge.BridgeState.encodePending,
               h_consumed, h_pending, h_nextWdId,
               h_circuit, h_tvlCap, h_totalLocked]
  rw [bridgeState_commit_includes_mirrorState, bridgeState_commit_includes_mirrorState,
      ← h_prefix] at h_enc
  have h_last :
      Encodable.encode (T := Nat) (if bs₁.ammDisabled then 1 else 0) =
      Encodable.encode (T := Nat) (if bs₂.ammDisabled then 1 else 0) :=
    List.append_cancel_left h_enc
  -- Step 4: CBE-uint injectivity on the canonical 0/1 range forces the
  -- two flags to agree, contradicting `h_ne`.
  have h_bound₁ : (if bs₁.ammDisabled then 1 else 0 : Nat) < 256 ^ 8 := by
    have : (1 : Nat) < 256 ^ 8 := by decide
    split <;> omega
  have h_bound₂ : (if bs₂.ammDisabled then 1 else 0 : Nat) < 256 ^ 8 := by
    have : (1 : Nat) < 256 ^ 8 := by decide
    split <;> omega
  have h_nat :
      (if bs₁.ammDisabled then 1 else 0 : Nat) =
      (if bs₂.ammDisabled then 1 else 0 : Nat) :=
    nat_encode_injective _ _ h_bound₁ h_bound₂ h_last
  have h_flag : bs₁.ammDisabled = bs₂.ammDisabled := by
    revert h_nat
    cases bs₁.ammDisabled <;> cases bs₂.ammDisabled <;> simp
  exact h_ne h_flag

/-- GP.11.10 top-level headline: `ammDisabled` is reflected in the
    published STATE ROOT itself.  Under collision-freeness of `hashBytes` on the pre-images below, two
    extended states whose bridge sub-states agree on every other
    field but differ on the `ammDisabled` kill-switch mirror produce
    **different** `commitExtendedStateConcat` roots — regardless of their
    kernel / nonce / registry / policy sub-states.

    **Proof.**  Equal top-level roots decompose (under
    collision-freedom) into equal per-sub-state commits
    (`commitExtendedStateConcat_subcommits_eq_under_collision_free`); the
    bridge sub-commit equality then contradicts
    `commitBridgeState_reflects_ammDisabled`. -/
theorem commitExtendedStateConcat_reflects_ammDisabled
    (es₁ es₂ : ExtendedState)
    (h_cf : Bridge.CollisionFreeOn
      (extendedStateCommitPreimages es₁ es₂) hashBytes)
    (h_consumed : es₁.bridge.consumed.toList = es₂.bridge.consumed.toList)
    (h_pending  : es₁.bridge.pending.toList  = es₂.bridge.pending.toList)
    (h_nextWdId : es₁.bridge.nextWdId = es₂.bridge.nextWdId)
    (h_circuit  : es₁.bridge.boldCircuitClosed = es₂.bridge.boldCircuitClosed)
    (h_tvlCap   : es₁.bridge.boldTvlCap = es₂.bridge.boldTvlCap)
    (h_totalLocked : es₁.bridge.boldTotalLockedValue = es₂.bridge.boldTotalLockedValue)
    (h_ne : es₁.bridge.ammDisabled ≠ es₂.bridge.ammDisabled) :
    commitExtendedStateConcat es₁ ≠ commitExtendedStateConcat es₂ := by
  intro h_eq
  obtain ⟨_, _, _, _, h_bs, _, _⟩ :=
    commitExtendedStateConcat_subcommits_eq_under_collision_free es₁ es₂
      (h_cf.mono (by
        intro z hz
        simp only [List.mem_cons, List.not_mem_nil, or_false] at hz
        simp only [extendedStateCommitPreimages, List.mem_cons]
        rcases hz with rfl | rfl
        · exact Or.inl rfl
        · exact Or.inr (Or.inl rfl))) h_eq
  refine commitBridgeState_reflects_ammDisabled es₁.bridge es₂.bridge
    (h_cf.mono (by
      intro z hz
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hz
      simp only [extendedStateCommitPreimages]
      rcases hz with rfl | rfl
      · exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _
          (List.mem_append_left _ (by simp [subStatePreimages])))
      · exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _
          (List.mem_append_right _ (by simp [subStatePreimages])))))
    h_consumed h_pending h_nextWdId h_circuit
    h_tvlCap h_totalLocked h_ne h_bs

/-! ## Smoke checks -/

/-- An empty `ExtendedState` has a deterministic, well-formed
    commit. -/
example : (commitExtendedStateConcat ExtendedState.empty).size = 32 :=
  commitExtendedStateConcat_size _

end FaultProof
end LegalKernel
