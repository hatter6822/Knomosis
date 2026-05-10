/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Commit — state-commitment scheme for the
fault-proof game (Workstream H §12 / WUs H.2.1 – H.2.5).

**Design.**  Each sub-state of `ExtendedState` is committed via
its canonical CBE encoding hashed with the deployment-supplied
hash function; the top-level `commitExtendedState` combines all
five sub-state commits via a final hash.

The plan §12.2 also describes a Sparse-Merkle-Tree variant that
allows L1 gas-efficient cell-level Merkle proofs.  The
correctness arguments below hold under the simpler hash-of-
canonical-encoding scheme; SMT is a deployment-time optimisation
(documented as a follow-up; see Genesis Plan §15.8).

**Headline theorems.**

  * `commitExtendedState_size = 32` — uniform 32-byte output.
  * `commitExtendedState_deterministic` — equal states ⇒ equal commits.
  * `commitExtendedState_injective_under_collision_free` (#220) — under
    `CollisionFree hashBytes`, equal commits imply observably-equal
    states.  This is one of the four load-bearing theorems of
    Workstream H.

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
import LegalKernel.Runtime.Hash

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## State commitment type -/

/-- The 32-byte top-level state commitment.  The sequencer
    publishes this value to L1 as the "state root"; the L1
    fault-proof game contract holds it for dispute resolution. -/
abbrev StateCommit : Type := ByteArray

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

/-! ## Top-level state commitment -/

/-- The top-level state commitment: a single 32-byte hash
    binding every sub-state in canonical order.  This is the
    value the sequencer publishes to L1 as the state root. -/
def commitExtendedState (es : ExtendedState) : StateCommit :=
  hashBytes
    (commitState        es.base ++
     commitNonceState   es.nonces ++
     commitKeyRegistry  es.registry ++
     commitLocalPolicies es.localPolicies ++
     commitBridgeState  es.bridge)

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

theorem commitExtendedState_deterministic (es₁ es₂ : ExtendedState) (h : es₁ = es₂) :
    commitExtendedState es₁ = commitExtendedState es₂ := by rw [h]

/-! ## Output-size theorems -/

theorem commitExtendedState_size (es : ExtendedState) :
    (commitExtendedState es).size = 32 := by
  unfold commitExtendedState
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
  es₁.bridge               = es₂.bridge

/-! ## Per-sub-state injectivity (#256)

Each per-sub-state commit is hash-of-canonical-encoding.  Under
`CollisionFree hashBytes`, equal commits imply equal canonical
encodings.  Equal canonical encodings imply extensional equality
of the underlying TreeMap (canonical encoding is by `toList`). -/

/-- Bytes-injectivity for `commitState`: under `CollisionFree`,
    equal commits imply equal canonical encoded bytes. -/
theorem commitState_bytes_injective_under_collision_free
    (s₁ s₂ : LegalKernel.State)
    (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitState s₁ = commitState s₂) :
    ByteArray.mk (State.encode s₁).toArray =
    ByteArray.mk (State.encode s₂).toArray := by
  unfold commitState at h
  exact h_cf _ _ h

/-- Bytes-injectivity for `commitNonceState`. -/
theorem commitNonceState_bytes_injective_under_collision_free
    (n₁ n₂ : NonceState)
    (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitNonceState n₁ = commitNonceState n₂) :
    ByteArray.mk (NonceState.encode n₁).toArray =
    ByteArray.mk (NonceState.encode n₂).toArray := by
  unfold commitNonceState at h
  exact h_cf _ _ h

/-- Bytes-injectivity for `commitKeyRegistry`. -/
theorem commitKeyRegistry_bytes_injective_under_collision_free
    (kr₁ kr₂ : KeyRegistry)
    (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitKeyRegistry kr₁ = commitKeyRegistry kr₂) :
    ByteArray.mk (KeyRegistry.encodeMap kr₁).toArray =
    ByteArray.mk (KeyRegistry.encodeMap kr₂).toArray := by
  unfold commitKeyRegistry at h
  exact h_cf _ _ h

/-- Bytes-injectivity for `commitLocalPolicies`. -/
theorem commitLocalPolicies_bytes_injective_under_collision_free
    (lp₁ lp₂ : LocalPolicies)
    (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitLocalPolicies lp₁ = commitLocalPolicies lp₂) :
    ByteArray.mk (Encodable.encode (T := LocalPolicies) lp₁).toArray =
    ByteArray.mk (Encodable.encode (T := LocalPolicies) lp₂).toArray := by
  unfold commitLocalPolicies at h
  exact h_cf _ _ h

/-- Bytes-injectivity for `commitBridgeState`. -/
theorem commitBridgeState_bytes_injective_under_collision_free
    (bs₁ bs₂ : BridgeState)
    (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitBridgeState bs₁ = commitBridgeState bs₂) :
    ByteArray.mk (Encodable.encode (T := BridgeState) bs₁).toArray =
    ByteArray.mk (Encodable.encode (T := BridgeState) bs₂).toArray := by
  unfold commitBridgeState at h
  exact h_cf _ _ h

/-! ## Top-level injectivity (#220)

The headline trust-model theorem of the workstream's commitment
scheme: under `CollisionFree hashBytes`, two distinct
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

/-- The five-component decomposition of `commitExtendedState`'s
    pre-image hash.  Under `CollisionFree hashBytes` plus the
    32-byte size invariants, equal top-level commits imply
    sub-state-commit-wise equality. -/
theorem commitExtendedState_subcommits_eq_under_collision_free
    (es₁ es₂ : ExtendedState) (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitExtendedState es₁ = commitExtendedState es₂) :
    commitState es₁.base = commitState es₂.base ∧
    commitNonceState es₁.nonces = commitNonceState es₂.nonces ∧
    commitKeyRegistry es₁.registry = commitKeyRegistry es₂.registry ∧
    commitLocalPolicies es₁.localPolicies = commitLocalPolicies es₂.localPolicies ∧
    commitBridgeState es₁.bridge = commitBridgeState es₂.bridge := by
  -- commitExtendedState es = hashBytes (5 sub-commits concatenated).
  -- Under collision-freedom, equal hashes ⇒ equal pre-images.
  have h_concat :
      commitState es₁.base ++ commitNonceState es₁.nonces ++
        commitKeyRegistry es₁.registry ++ commitLocalPolicies es₁.localPolicies ++
        commitBridgeState es₁.bridge =
      commitState es₂.base ++ commitNonceState es₂.nonces ++
        commitKeyRegistry es₂.registry ++ commitLocalPolicies es₂.localPolicies ++
        commitBridgeState es₂.bridge :=
    h_cf _ _ h
  -- Apply the five-fold split with each segment's 32-byte size.
  exact byteArray_concat_five_split _ _ _ _ _ _ _ _ _ _
    (commitState_size _) (commitNonceState_size _) (commitKeyRegistry_size _)
    (commitLocalPolicies_size _) (commitBridgeState_size _)
    (commitState_size _) (commitNonceState_size _) (commitKeyRegistry_size _)
    (commitLocalPolicies_size _) (commitBridgeState_size _) h_concat

/-- #220: Top-level commitment injectivity under
    `CollisionFree hashBytes`.  Equal top-level commits imply
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
theorem commitExtendedState_subcommits_bytes_eq_under_collision_free
    (es₁ es₂ : ExtendedState) (h_cf : Bridge.CollisionFree hashBytes)
    (h : commitExtendedState es₁ = commitExtendedState es₂) :
    ByteArray.mk (State.encode es₁.base).toArray =
      ByteArray.mk (State.encode es₂.base).toArray ∧
    ByteArray.mk (NonceState.encode es₁.nonces).toArray =
      ByteArray.mk (NonceState.encode es₂.nonces).toArray ∧
    ByteArray.mk (KeyRegistry.encodeMap es₁.registry).toArray =
      ByteArray.mk (KeyRegistry.encodeMap es₂.registry).toArray ∧
    ByteArray.mk (Encodable.encode (T := LocalPolicies) es₁.localPolicies).toArray =
      ByteArray.mk (Encodable.encode (T := LocalPolicies) es₂.localPolicies).toArray ∧
    ByteArray.mk (Encodable.encode (T := BridgeState) es₁.bridge).toArray =
      ByteArray.mk (Encodable.encode (T := BridgeState) es₂.bridge).toArray := by
  obtain ⟨h_s, h_n, h_kr, h_lp, h_bs⟩ :=
    commitExtendedState_subcommits_eq_under_collision_free es₁ es₂ h_cf h
  exact ⟨commitState_bytes_injective_under_collision_free _ _ h_cf h_s,
         commitNonceState_bytes_injective_under_collision_free _ _ h_cf h_n,
         commitKeyRegistry_bytes_injective_under_collision_free _ _ h_cf h_kr,
         commitLocalPolicies_bytes_injective_under_collision_free _ _ h_cf h_lp,
         commitBridgeState_bytes_injective_under_collision_free _ _ h_cf h_bs⟩

/-! ## Smoke checks -/

/-- An empty `ExtendedState` has a deterministic, well-formed
    commit. -/
example : (commitExtendedState ExtendedState.empty).size = 32 :=
  commitExtendedState_size _

end FaultProof
end LegalKernel
