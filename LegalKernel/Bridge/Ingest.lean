/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.Ingest — Workstream B.2
(Ethereum integration plan §6.2).

Translates Ethereum L1 events into Canon-side `UnsignedBridgeAction`
values, ready for the runtime adaptor to sign and feed into
`processSignedAction`.  The Lean side is pure (no `IO`), so
determinism is automatic; the non-trivial properties are
order-independence across distinct addresses
(`ingest_lookup_equivalent_for_distinct_addresses`) and the
type-level pinning of the bridge actor's authority boundary
(`ingest_emits_bridge_actor`).

Design notes:

  * `L1Event` enumerates the three event variants Canon ingests
    from L1: identity registration, identity revocation, and
    deposit initiation.  Each variant carries the originating
    block number / log index so the runtime adaptor can
    deduplicate by `(blockHash, logIndex)`.

  * `UnsignedBridgeAction` is the *unsigned* envelope that
    `ingest` produces.  The runtime adaptor (Rust side) takes the
    envelope, computes the canonical `signingInput` bytes, and
    signs them with the bridge's private key.  The Lean side
    never sees the private key.

  * `ingest` is total over `L1Event`, returning either:
      - `(b', some unsigned)` — the address book was updated (for
        first-time registrations) and the unsigned action is ready
        to be signed.
      - `(b, none)`           — the event has no Canon-side effect
        (revocations and deposits in MVP scope; revocations are a
        deployment-policy concern, deposits are reserved for
        Workstream C where `Action.deposit` lands at frozen index
        13).

  * The runtime adaptor's pseudocode for end-to-end ingest:

    ```
    loop:
        e := next finalised L1 event
        let (b', some ub) := Bridge.ingest current_addressbook current_nonce e
        let signing_bytes := signingInput ub.action ub.signer ub.nonce deploymentId
        let sig := canon_sign(bridge_private_key, signing_bytes)  -- in Rust
        let sa : SignedAction :=
            { action := ub.action, signer := ub.signer,
              nonce := ub.nonce, sig := sig }
        processSignedAction sa
        current_addressbook := b'
        current_nonce := current_nonce + 1
    ```

This module is **not** part of the kernel TCB.  Bugs here would
weaken the bridge's L1-translation guarantees but cannot violate
any kernel invariant.

Coverage map:

  * §6.2 (WU B.2) — `L1Event`, `UnsignedBridgeAction`, `ingest`,
    `L1Event.address`,
    `ingest_preserves_lookup_for_other_addresses`,
    `ingest_lookup_equivalent_for_distinct_addresses`,
    `ingest_emits_bridge_actor`.
  * §12.8 — three theorems above (the simpler
    `_preserves_lookup_for_other_addresses` is the structural
    locality lemma; the full `_lookup_equivalent_for_distinct_addresses`
    follows from it via case analysis).
-/

import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Authority.Action
import LegalKernel.Authority.Crypto

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## L1Event inductive

The set of L1 (Ethereum) events Canon's bridge runtime ingests.
Each variant carries the originating L1 metadata so that the
runtime adaptor can deduplicate (by `(blockNum, logIdx)`) and
preserve the deterministic ordering required for cross-stack
verification.

Constructors are listed in append-only order; future event types
(e.g. governance, snapshot finalization) would extend this
enumeration without renumbering existing constructors. -/

/-- An Ethereum L1 event the bridge translates into a Canon-side
    `UnsignedBridgeAction`.  Three MVP variants: identity
    registration, identity revocation, and deposit initiation. -/
inductive L1Event
  /-- Identity-registration event from the L1
      `CanonIdentityRegistry.sol` contract.  Logged when an EOA
      registers a Canon public key (`pk`) for their address
      (`addr`).  May represent either a first-time registration
      (no prior `addr ↦ id` mapping in the `AddressBook`) or a
      rotation (existing mapping).  The bridge's `ingest`
      function dispatches accordingly. -/
  | identityRegistered (addr : EthAddress) (pk : PublicKey)
                        (blockNum : Nat) (logIdx : Nat)
  /-- Identity-revocation event from the L1 contract.  Workstream
      B's `ingest` returns `none` for this variant; deployment-
      level revocation policy is configured at the
      `AuthorityPolicy` level (e.g. `intersect` with a no-revoked-
      actors predicate). -/
  | identityRevoked    (addr : EthAddress) (blockNum : Nat) (logIdx : Nat)
  /-- Deposit-initiation event from the L1 `CanonBridge.sol`
      contract.  Workstream B's `ingest` returns `none` for this
      variant; deposit translation is reserved for Workstream C
      where the `Action.deposit` constructor lands at frozen
      index 13. -/
  | depositInitiated   (addr : EthAddress) (resource : ResourceId)
                        (amount : Amount)  (receiptHash : ByteArray)
                        (blockNum : Nat)   (logIdx : Nat)
  deriving Repr, DecidableEq

/-- The Ethereum address an L1 event touches.  Used by the per-
    address-commutativity theorem
    `ingest_lookup_equivalent_for_distinct_addresses`. -/
def L1Event.address : L1Event → EthAddress
  | .identityRegistered addr _ _ _    => addr
  | .identityRevoked    addr _ _      => addr
  | .depositInitiated   addr _ _ _ _ _ => addr

/-! ## UnsignedBridgeAction

The unsigned envelope that `ingest` produces.  The runtime adaptor
(Rust) packages this into a fully-formed `SignedAction` by
computing the signature externally.  The bridge actor's private
key lives in the runtime adaptor process and is never seen by the
Lean side. -/

/-- An unsigned bridge action: an `Action` plus the signer (always
    `bridgeActor`) and nonce, awaiting the runtime adaptor's
    signature operation. -/
structure UnsignedBridgeAction where
  /-- The `Action` to be signed.  Lives in `Action`-space (first-
      order data) so the canonical `signingInput` encoding (Phase
      4) is well-defined. -/
  action : Action
  /-- The signer's `ActorId`.  Always equal to `bridgeActor` by
      construction; pinned by `ingest_emits_bridge_actor`. -/
  signer : ActorId
  /-- The signer's per-actor nonce.  Supplied by the runtime
      adaptor as the bridge actor's next-expected nonce at ingest
      time. -/
  nonce  : Nonce
  deriving Repr

/-! ## The ingest function

`ingest b currentNonce e` translates an L1 event `e` into either
an updated `AddressBook` and an `UnsignedBridgeAction`, or just an
updated `AddressBook` (for events that have no Canon-side effect
in MVP scope).

Determinism is automatic (no `IO`); the non-trivial property is
locality-across-addresses. -/

/-- Translate an L1 event into a Canon-side `UnsignedBridgeAction`.

    Per-variant behaviour:

      * `identityRegistered addr pk _ _`:
          - If `addr` is unknown to `b`: `assign` produces a fresh
            `ActorId` and the emitted action is
            `Action.registerIdentity id pk`.
          - If `addr` is known: the emitted action is
            `Action.replaceKey id pk` (key rotation).
        The address book is updated only in the first case (the
        rotation case leaves the AddressBook unchanged because the
        `id ↔ addr` mapping is unchanged).

      * `identityRevoked _ _ _`: returns `(b, none)`.  Revocation
        handling is a deployment-policy concern; the kernel-level
        action layer does not have a dedicated "revoke" action.

      * `depositInitiated _ _ _ _ _ _`: returns `(b, none)`.
        Deposit translation is reserved for Workstream C where
        `Action.deposit` lands.

    The function is pure (no `IO`), deterministic, and total. -/
def ingest (b : AddressBook) (currentNonce : Nonce) (e : L1Event) :
    AddressBook × Option UnsignedBridgeAction :=
  match e with
  | .identityRegistered addr pk _ _ =>
    -- Determine whether this is a first-time registration or a
    -- rotation BEFORE running `assign` (which would update the
    -- AddressBook regardless).
    match b.lookup addr with
    | none =>
      -- First-time registration: assign a fresh id and emit
      -- `Action.registerIdentity`.
      let (b', id) := b.assign addr
      (b', some { action := .registerIdentity id pk
                  signer := bridgeActor
                  nonce  := currentNonce })
    | some id =>
      -- Rotation: address already known; emit
      -- `Action.replaceKey` and leave the book unchanged.
      (b, some { action := .replaceKey id pk
                 signer := bridgeActor
                 nonce  := currentNonce })
  | .identityRevoked _ _ _ =>
    -- Revocation handling: no Canon-side action.  Deployments
    -- enforce revocation via per-actor authority-policy
    -- intersection (e.g. `AuthorityPolicy.intersect` with a
    -- no-revoked-actors predicate).
    (b, none)
  | .depositInitiated _ _ _ _ _ _ =>
    -- Deposit handling reserved for Workstream C (where
    -- `Action.deposit` is added at frozen index 13).  The
    -- runtime adaptor's L1 → Canon pipeline routes deposit
    -- events through this branch in MVP scope; the actual
    -- balance-credit semantics live in C.2 / C.4.
    (b, none)

/-! ## §12.8 theorems -/

/-- §12.8 #31 — `ingest`'s emitted unsigned action's signer is
    always the bridge actor (`ActorId 0`).  This pins the bridge's
    authority boundary at the type level.

    Proof: case analysis on the L1 event variant.  Only the
    `identityRegistered` case emits a `some` envelope; both
    sub-cases (first-time / rotation) construct the envelope with
    `signer := bridgeActor`. -/
theorem ingest_emits_bridge_actor
    (b : AddressBook) (n : Nonce) (e : L1Event) (ub : UnsignedBridgeAction) :
    (ingest b n e).snd = some ub →
    ub.signer = bridgeActor := by
  intro h
  unfold ingest at h
  cases e with
  | identityRegistered addr pk blockNum logIdx =>
    cases hLookup : b.lookup addr with
    | none =>
      simp only [hLookup] at h
      injection h with h_eq
      rw [← h_eq]
    | some id =>
      simp only [hLookup] at h
      injection h with h_eq
      rw [← h_eq]
  | identityRevoked addr blockNum logIdx =>
    simp at h
  | depositInitiated addr resource amount receiptHash blockNum logIdx =>
    simp at h

/-! ## Locality of `ingest` across addresses -/

/-- Locality lemma: for any L1 event whose address differs from
    `addr`, ingesting the event preserves the lookup at `addr`.

    Proof: case analysis on the event variant.  The
    `identityRegistered addr' _ _ _` case uses
    `assign_other_address_untouched` for the fresh-registration
    branch and leaves the book unchanged in the rotation branch.
    The `identityRevoked` and `depositInitiated` cases are
    no-ops on the AddressBook. -/
theorem ingest_preserves_lookup_for_other_addresses
    (b : AddressBook) (n : Nonce) (e : L1Event) (addr : EthAddress)
    (h : e.address ≠ addr) :
    (ingest b n e).fst.lookup addr = b.lookup addr := by
  unfold ingest L1Event.address at *
  cases e with
  | identityRegistered addr' pk _ _ =>
    -- e.address = addr'; h : addr' ≠ addr.
    cases hLookup : b.lookup addr' with
    | none =>
      -- First-time registration: AddressBook gains `addr' ↦ ...`.
      -- Locality follows from `assign_other_address_untouched`.
      simp only [hLookup]
      show (b.assign addr').fst.lookup addr = b.lookup addr
      exact AddressBook.assign_other_address_untouched b addr' addr h hLookup
    | some _ =>
      -- Rotation: AddressBook unchanged.
      simp only [hLookup]
  | identityRevoked _ _ _    => rfl
  | depositInitiated _ _ _ _ _ _ => rfl

/-- Strong locality lemma: applying the same event to two books that
    agree on `addr.isSome` produces books that agree on `addr.isSome`.

    This is the work-horse for `ingest_isSome_equivalent_for_distinct_addresses`:
    it says the *isSome status* at any address depends only on the
    pre-state's isSome status at that address (and the event variant),
    NOT on the id values.

    Proof sketch:
      * `identityRegistered addr' _ _ _` with addr' = addr:
        post.isSome = true (always — fresh registration assigns
        a new id; rotation preserves the existing one).
      * `identityRegistered addr' _ _ _` with addr' ≠ addr:
        post.lookup addr = pre.lookup addr (locality), so
        post.isSome = pre.isSome.
      * `identityRevoked _ _ _`: book unchanged; post.isSome = pre.isSome.
      * `depositInitiated _ _ _ _ _ _`: same.

    All cases preserve isSome equality from pre to post. -/
theorem ingest_lookup_isSome_pre_invariant
    (b₁ b₂ : AddressBook) (n₁ n₂ : Nonce) (e : L1Event) (addr : EthAddress)
    (h : (b₁.lookup addr).isSome = (b₂.lookup addr).isSome) :
    ((ingest b₁ n₁ e).fst.lookup addr).isSome =
    ((ingest b₂ n₂ e).fst.lookup addr).isSome := by
  cases e with
  | identityRegistered addr' pk blockNum logIdx =>
    by_cases hEq : addr' = addr
    · -- addr' = addr: ingest produces some _ regardless of pre.
      subst hEq
      unfold ingest
      -- Match on the lookup at addr in each book.
      cases hLk1 : b₁.lookup addr' with
      | none =>
        cases hLk2 : b₂.lookup addr' with
        | none =>
          -- Both fresh: both produce some _ via assign.
          simp only [hLk1, hLk2]
          -- Goal: ((b₁.assign addr').fst.lookup addr').isSome =
          --       ((b₂.assign addr').fst.lookup addr').isSome
          -- Both sides reduce to `true` via assign_fresh_actorId.
          rw [(AddressBook.assign_fresh_actorId b₁ addr' hLk1).1,
              (AddressBook.assign_fresh_actorId b₂ addr' hLk2).1]
          rfl
        | some _ =>
          -- Pre disagree on isSome: hLk1 = none has isSome = false,
          -- hLk2 = some _ has isSome = true.  But h says they agree.  Contradiction.
          rw [hLk1, hLk2] at h
          exact absurd h (by simp)
      | some _ =>
        cases hLk2 : b₂.lookup addr' with
        | none =>
          rw [hLk1, hLk2] at h
          exact absurd h (by simp)
        | some _ =>
          -- Both rotation: book unchanged, lookup unchanged, post.isSome = true on both.
          simp only [hLk1, hLk2]
          -- Goal: (some _).isSome = (some _).isSome — both are true.
          rfl
    · -- addr' ≠ addr: locality preserves the lookup, so isSome is unchanged.
      have hNe : (L1Event.identityRegistered addr' pk blockNum logIdx).address ≠ addr := by
        unfold L1Event.address
        exact hEq
      rw [ingest_preserves_lookup_for_other_addresses b₁ n₁
            (L1Event.identityRegistered addr' pk blockNum logIdx) addr hNe,
          ingest_preserves_lookup_for_other_addresses b₂ n₂
            (L1Event.identityRegistered addr' pk blockNum logIdx) addr hNe]
      exact h
  | identityRevoked addr' blockNum logIdx =>
    -- Book unchanged; post.lookup = pre.lookup; isSome unchanged.
    show ((ingest b₁ n₁ (L1Event.identityRevoked addr' blockNum logIdx)).fst.lookup addr).isSome =
         ((ingest b₂ n₂ (L1Event.identityRevoked addr' blockNum logIdx)).fst.lookup addr).isSome
    unfold ingest
    exact h
  | depositInitiated addr' resource amount receiptHash blockNum logIdx =>
    show ((ingest b₁ n₁
            (L1Event.depositInitiated addr' resource amount receiptHash blockNum logIdx)).fst.lookup
            addr).isSome =
         ((ingest b₂ n₂
            (L1Event.depositInitiated addr' resource amount receiptHash blockNum logIdx)).fst.lookup
            addr).isSome
    unfold ingest
    exact h

/-- §12.8 #30 — per-address `lookup`-equivalence after two
    independent ingests, restricted to addresses NOT touching either
    event.  At those addresses, the two orderings produce books that
    agree on the lookup at the *value* level (not just isSome).

    For addresses that DO touch one of the events, the id values may
    differ (the address that arrived first gets the lower id), but
    the isSome status agrees — that property is captured by
    `ingest_isSome_equivalent_for_distinct_addresses` below. -/
theorem ingest_lookup_equivalent_for_distinct_addresses
    (b : AddressBook) (n : Nonce) (e₁ e₂ : L1Event)
    (_hAddr : e₁.address ≠ e₂.address)
    (addr : EthAddress) (hNe₁ : addr ≠ e₁.address) (hNe₂ : addr ≠ e₂.address) :
    (ingest (ingest b n e₁).fst (n + 1) e₂).fst.lookup addr =
    (ingest (ingest b n e₂).fst (n + 1) e₁).fst.lookup addr := by
  -- Both sides reduce to `b.lookup addr` via `ingest_preserves_lookup_for_other_addresses`
  -- applied twice.
  have hNe₁' : e₁.address ≠ addr := fun heq => hNe₁ heq.symm
  have hNe₂' : e₂.address ≠ addr := fun heq => hNe₂ heq.symm
  -- LHS chain: b → b₁ → b₂.
  -- e₁ doesn't touch addr (hNe₁'), so b₁.lookup addr = b.lookup addr.
  -- e₂ doesn't touch addr (hNe₂'), so b₂.lookup addr = b₁.lookup addr.
  -- Hence b₂.lookup addr = b.lookup addr.
  -- Similarly b₂'.lookup addr = b.lookup addr.
  rw [ingest_preserves_lookup_for_other_addresses _ (n + 1) e₂ addr hNe₂']
  rw [ingest_preserves_lookup_for_other_addresses _ n e₁ addr hNe₁']
  rw [ingest_preserves_lookup_for_other_addresses _ (n + 1) e₁ addr hNe₁']
  rw [ingest_preserves_lookup_for_other_addresses _ n e₂ addr hNe₂']

/-- §12.8 #30 — the plan's full per-address `isSome`-equivalence after
    two independent ingests.  Holds for *every* address, including
    those touching either event.

    Independent L1 events (touching distinct addresses) compose in
    either order to AddressBooks whose `lookup` returns `some` at
    exactly the same set of addresses.  The specific ids may differ
    between orderings (the address that arrived first gets the lower
    id), but the registration *status* matches universally.

    Proof: case-split on `addr` vs each event's address.
      * Case `addr ≠ e₁.address ∧ addr ≠ e₂.address`: reduce via
        `ingest_lookup_equivalent_for_distinct_addresses`.
      * Case `addr = e₁.address`: applying e₂ to b₁ vs b₁'
        preserves isSome at addr (e₂ doesn't touch addr).  Then both
        sides reduce to applying e₁ to a state whose lookup at addr
        equals `b.lookup addr`.  Apply
        `ingest_lookup_isSome_pre_invariant` to conclude.
      * Case `addr = e₂.address`: symmetric. -/
theorem ingest_isSome_equivalent_for_distinct_addresses
    (b : AddressBook) (n : Nonce) (e₁ e₂ : L1Event)
    (hAddr : e₁.address ≠ e₂.address) (addr : EthAddress) :
    ((ingest (ingest b n e₁).fst (n + 1) e₂).fst.lookup addr).isSome =
    ((ingest (ingest b n e₂).fst (n + 1) e₁).fst.lookup addr).isSome := by
  by_cases h₁ : addr = e₁.address
  · -- addr = e₁.address; from hAddr, addr ≠ e₂.address.
    have h₂ne : addr ≠ e₂.address := fun heq => hAddr (h₁.symm.trans heq)
    have h₂ne' : e₂.address ≠ addr := fun heq => h₂ne heq.symm
    -- LHS: applies e₂ (locality on addr) then e₁ implicitly applied earlier on b.
    -- Specifically:
    --   LHS = (ingest b₁ (n+1) e₂).fst.lookup addr
    --       = b₁.lookup addr (by locality on e₂; e₂.address ≠ addr).
    --       = (ingest b n e₁).fst.lookup addr.
    -- RHS = (ingest b₁' (n+1) e₁).fst.lookup addr
    --       = result of applying e₁ to b₁' (which has lookup at addr = b.lookup addr).
    rw [ingest_preserves_lookup_for_other_addresses _ (n + 1) e₂ addr h₂ne']
    -- Now LHS = (ingest b n e₁).fst.lookup addr.
    -- RHS = (ingest b₁' (n+1) e₁).fst.lookup addr.
    -- We need: ((ingest b n e₁).fst.lookup addr).isSome =
    --          ((ingest b₁' (n+1) e₁).fst.lookup addr).isSome
    -- Apply hLookup_isSome_pre_invariant with b₁ := b, b₂ := b₁'.
    -- Pre-condition: b.lookup addr = b₁'.lookup addr.
    apply ingest_lookup_isSome_pre_invariant
    -- Goal: (b.lookup addr).isSome = (b₁'.lookup addr).isSome
    --     = ((ingest b n e₂).fst.lookup addr).isSome.
    rw [ingest_preserves_lookup_for_other_addresses _ n e₂ addr h₂ne']
  · by_cases h₂ : addr = e₂.address
    · -- addr = e₂.address; symmetric.
      have h₁ne : addr ≠ e₁.address := h₁
      have h₁ne' : e₁.address ≠ addr := fun heq => h₁ne heq.symm
      -- LHS: (ingest b₁ (n+1) e₂).fst.lookup addr — e₂ touches addr.
      -- RHS: (ingest b₁' (n+1) e₁).fst.lookup addr — e₁ doesn't touch addr.
      rw [ingest_preserves_lookup_for_other_addresses (ingest b n e₂).fst (n + 1)
            e₁ addr h₁ne']
      -- Now RHS = b₁'.lookup addr = (ingest b n e₂).fst.lookup addr.
      -- LHS = (ingest b₁ (n+1) e₂).fst.lookup addr.
      -- We need:
      --   ((ingest b₁ (n+1) e₂).fst.lookup addr).isSome =
      --   ((ingest b n e₂).fst.lookup addr).isSome.
      -- Apply ingest_lookup_isSome_pre_invariant with two books that
      -- agree on isSome at addr.  Pre-condition: b₁.lookup addr =
      -- b.lookup addr (by locality on e₁).
      apply ingest_lookup_isSome_pre_invariant
      rw [ingest_preserves_lookup_for_other_addresses _ n e₁ addr h₁ne']
    · -- addr ≠ e₁.address ∧ addr ≠ e₂.address: reduce via the
      -- value-level equality lemma.
      rw [ingest_lookup_equivalent_for_distinct_addresses b n e₁ e₂ hAddr addr h₁ h₂]

/-! ## Consistency preservation by `ingest`

`ingest` updates the `AddressBook` only via `assign`; therefore the
`Consistent` invariant is preserved given the same freshness
hypothesis that `assign_preserves_consistent` requires.  Bridge-
runtime callers that maintain `Consistent` and `freshness` invariants
externally rely on this lemma to argue that those invariants survive
each ingestion step. -/

/-- `ingest` preserves the AddressBook's `Consistent` invariant
    under a freshness hypothesis on `nextActorId`.

    For the `identityRegistered` fresh-registration case, this
    follows from `AddressBook.assign_preserves_consistent`.  For the
    rotation, revocation, and deposit cases, the AddressBook is
    unchanged and consistency transfers trivially. -/
theorem ingest_preserves_consistent
    (b : AddressBook) (n : Nonce) (e : L1Event)
    (hCons : b.Consistent) (hFresh : b.reverse[b.nextActorId]? = none) :
    (ingest b n e).fst.Consistent := by
  cases e with
  | identityRegistered addr pk _ _ =>
    unfold ingest
    cases hLk : b.lookup addr with
    | none =>
      -- Fresh registration: AddressBook is updated via `assign`.
      simp only [hLk]
      -- (b.assign addr).fst is the new book.
      show (b.assign addr).fst.Consistent
      exact AddressBook.assign_preserves_consistent b hCons addr hFresh
    | some _ =>
      -- Rotation: book unchanged.
      simp only [hLk]
      exact hCons
  | identityRevoked _ _ _ =>
    -- Revocation: book unchanged.
    unfold ingest
    exact hCons
  | depositInitiated _ _ _ _ _ _ =>
    -- Deposit: book unchanged (in MVP scope).
    unfold ingest
    exact hCons

/-! ## Sanity smoke checks -/

example (b : AddressBook) (n : Nonce) :
    (ingest b n (.identityRevoked EthAddress.zero 0 0)).snd = none := rfl

example (b : AddressBook) (n : Nonce) :
    (ingest b n (.depositInitiated EthAddress.zero 1 100 ⟨#[]⟩ 0 0)).snd = none := rfl

end Bridge
end LegalKernel
