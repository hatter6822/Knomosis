/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.Ingest — Workstream B.2 test suite.

Exercises the L1-event ingestor (`LegalKernel/Bridge/Ingest.lean`).
Coverage:

  * **L1Event.address projection.**  Each variant projects to its
    address field.
  * **`ingest` per-variant behaviour.**
      - `identityRegistered` (fresh): emits `registerIdentity`.
      - `identityRegistered` (rotation): emits `replaceKey`.
      - `identityRevoked`: returns `(b, none)`.
      - `depositInitiated`: returns `(b, none)`.
  * **AddressBook update.**  Fresh registrations update the book;
    rotations leave it unchanged; non-identity events are no-ops.
  * **Locality.**  `ingest_preserves_lookup_for_other_addresses`
    holds at concrete fixtures.
  * **Cross-address commutativity.**
    `ingest_lookup_equivalent_for_distinct_addresses` and
    `ingest_isSome_equivalent_for_distinct_addresses` hold at
    concrete fixtures.
  * **Bridge-actor pinning.**  `ingest_emits_bridge_actor` always
    yields signer = `bridgeActor`.
  * **Term-level API stability** for the §12.8 theorems.
-/

import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Bridge.Ingest
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Bridge
namespace IngestTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Bridge.AddressBook
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-- A small concrete `EthAddress`: `0x00...01`. -/
def addr1 : EthAddress := ⟨1, by unfold ethAddressBound; decide⟩

/-- A second concrete `EthAddress`: `0x00...02`. -/
def addr2 : EthAddress := ⟨2, by unfold ethAddressBound; decide⟩

/-- A sample public key for fixture construction (first key). -/
def pk1 : PublicKey := ⟨#[0x11, 0x22]⟩

/-- A second sample public key for fixture construction. -/
def pk2 : PublicKey := ⟨#[0x33, 0x44]⟩

/-- Tests for `L1Event` and `ingest`. -/
def tests : List TestCase :=
  [ -- ## L1Event.address projection
    { name := "L1Event.address: identityRegistered"
    , body := do
        assertEq (expected := addr1)
          (actual := (L1Event.identityRegistered addr1 pk1 0 0).address)
          "address"
    }
  , { name := "L1Event.address: identityRevoked"
    , body := do
        assertEq (expected := addr2)
          (actual := (L1Event.identityRevoked addr2 0 0).address)
          "address"
    }
  , { name := "L1Event.address: depositInitiated"
    , body := do
        assertEq (expected := addr1)
          (actual := (L1Event.depositInitiated addr1 5 100 ⟨#[]⟩ 0 0).address)
          "address"
    }
  , -- ## ingest per-variant behaviour
    { name := "ingest fresh identity: emits registerIdentity"
    , body := do
        let (b', maybeUb) := ingest empty 0 (.identityRegistered addr1 pk1 0 0)
        match maybeUb with
        | none =>
            throw <| IO.userError "ingest unexpectedly returned none"
        | some ub =>
            assertEq (expected := bridgeActor) (actual := ub.signer) "signer"
            assertEq (expected := (.registerIdentity 1 pk1 : Action))
              (actual := ub.action) "action"
            assertEq (expected := (0 : Nonce)) (actual := ub.nonce) "nonce"
            assertEq (expected := (some (1 : ActorId)))
              (actual := b'.lookup addr1) "book updated"
    }
  , { name := "ingest rotation: emits replaceKey"
    , body := do
        -- Pre-register addr1 as actor 1.
        let (b1, _) := empty.assign addr1
        -- Now ingest a rotation event with a new pk.
        let (b2, maybeUb) := ingest b1 5 (.identityRegistered addr1 pk2 0 0)
        match maybeUb with
        | none =>
            throw <| IO.userError "ingest unexpectedly returned none on rotation"
        | some ub =>
            assertEq (expected := bridgeActor) (actual := ub.signer) "signer"
            assertEq (expected := (.replaceKey 1 pk2 : Action))
              (actual := ub.action) "action"
            -- Book should be unchanged on rotation.
            assertEq (expected := b1.nextActorId) (actual := b2.nextActorId)
              "nextActorId unchanged"
            assertEq (expected := b1.lookup addr1) (actual := b2.lookup addr1)
              "lookup unchanged"
    }
  , { name := "ingest revocation: emits none"
    , body := do
        let (b', maybeUb) := ingest empty 0 (.identityRevoked addr1 0 0)
        assertEq (expected := empty.nextActorId) (actual := b'.nextActorId)
          "book unchanged"
        match maybeUb with
        | none      => pure ()
        | some _    => throw <| IO.userError "revocation should emit none"
    }
  , { name := "ingest deposit: emits none"
    , body := do
        let (b', maybeUb) := ingest empty 0 (.depositInitiated addr1 5 100 ⟨#[]⟩ 0 0)
        assertEq (expected := empty.nextActorId) (actual := b'.nextActorId)
          "book unchanged"
        match maybeUb with
        | none      => pure ()
        | some _    => throw <| IO.userError "deposit should emit none in MVP"
    }
  , -- ## AddressBook update behaviour
    { name := "ingest fresh registration: nextActorId increments"
    , body := do
        let (b1, _) := ingest empty 0 (.identityRegistered addr1 pk1 0 0)
        assertEq (expected := (2 : ActorId)) (actual := b1.nextActorId)
          "nextActorId after one registration"
    }
  , { name := "ingest two fresh registrations: distinct ids"
    , body := do
        let (b1, _) := ingest empty 0 (.identityRegistered addr1 pk1 0 0)
        let (b2, _) := ingest b1 1 (.identityRegistered addr2 pk2 1 0)
        assertEq (expected := (some (1 : ActorId))) (actual := b2.lookup addr1)
          "addr1 → 1"
        assertEq (expected := (some (2 : ActorId))) (actual := b2.lookup addr2)
          "addr2 → 2"
    }
  , -- ## Locality
    { name := "ingest_preserves_lookup_for_other_addresses: addr2 unchanged after addr1 register"
    , body := do
        let b' := (ingest empty 0 (.identityRegistered addr1 pk1 0 0)).fst
        assertEq (expected := empty.lookup addr2) (actual := b'.lookup addr2)
          "addr2 lookup unchanged"
    }
  , { name := "ingest_preserves_lookup_for_other_addresses: revocation no-op"
    , body := do
        let b' := (ingest empty 0 (.identityRevoked addr1 0 0)).fst
        assertEq (expected := empty.lookup addr2) (actual := b'.lookup addr2)
          "addr2 lookup unchanged"
    }
  , { name := "ingest_preserves_lookup_for_other_addresses: deposit no-op"
    , body := do
        let b' := (ingest empty 0 (.depositInitiated addr1 5 100 ⟨#[]⟩ 0 0)).fst
        assertEq (expected := empty.lookup addr2) (actual := b'.lookup addr2)
          "addr2 lookup unchanged"
    }
  , -- ## Cross-address commutativity (concrete fixture)
    { name := "ingest commutativity: register addr1 then addr2 vs reverse — both register both"
    , body := do
        let e1 := L1Event.identityRegistered addr1 pk1 0 0
        let e2 := L1Event.identityRegistered addr2 pk2 1 0
        -- Order 1: e1 then e2.
        let b₁  := (ingest empty 0 e1).fst
        let b₂  := (ingest b₁    1 e2).fst
        -- Order 2: e2 then e1.
        let b₁' := (ingest empty 0 e2).fst
        let b₂' := (ingest b₁'   1 e1).fst
        -- Both books register both addresses.
        assert (b₂.lookup addr1 |>.isSome) "order1: addr1 registered"
        assert (b₂.lookup addr2 |>.isSome) "order1: addr2 registered"
        assert (b₂'.lookup addr1 |>.isSome) "order2: addr1 registered"
        assert (b₂'.lookup addr2 |>.isSome) "order2: addr2 registered"
    }
  , -- ## Bridge-actor pinning
    { name := "ingest_emits_bridge_actor: registerIdentity → bridge actor"
    , body := do
        let (_, maybeUb) := ingest empty 0 (.identityRegistered addr1 pk1 0 0)
        match maybeUb with
        | none => throw <| IO.userError "ingest returned none unexpectedly"
        | some ub =>
            assertEq (expected := bridgeActor) (actual := ub.signer)
              "signer is bridge actor"
    }
  , { name := "ingest_emits_bridge_actor: replaceKey → bridge actor"
    , body := do
        let (b1, _) := empty.assign addr1
        let (_, maybeUb) := ingest b1 5 (.identityRegistered addr1 pk2 0 0)
        match maybeUb with
        | none => throw <| IO.userError "ingest returned none unexpectedly"
        | some ub =>
            assertEq (expected := bridgeActor) (actual := ub.signer)
              "signer is bridge actor"
    }
  , -- ## Term-level API stability
    { name := "ingest_emits_bridge_actor: term-level API"
    , body := do
        let _f : (b : AddressBook) → (n : Nonce) → (e : L1Event) →
                 (ub : UnsignedBridgeAction) →
                 (ingest b n e).snd = some ub →
                 ub.signer = bridgeActor :=
          ingest_emits_bridge_actor
        pure ()
    }
  , { name := "ingest_preserves_lookup_for_other_addresses: term-level API"
    , body := do
        let _f : (b : AddressBook) → (n : Nonce) → (e : L1Event) →
                 (addr : EthAddress) → e.address ≠ addr →
                 (ingest b n e).fst.lookup addr = b.lookup addr :=
          ingest_preserves_lookup_for_other_addresses
        pure ()
    }
  , { name := "ingest_lookup_equivalent_for_distinct_addresses: term-level API"
    , body := do
        let _f : (b : AddressBook) → (n : Nonce) → (e₁ e₂ : L1Event) →
                 e₁.address ≠ e₂.address →
                 (addr : EthAddress) → addr ≠ e₁.address → addr ≠ e₂.address →
                 (ingest (ingest b n e₁).fst (n + 1) e₂).fst.lookup addr =
                 (ingest (ingest b n e₂).fst (n + 1) e₁).fst.lookup addr :=
          ingest_lookup_equivalent_for_distinct_addresses
        pure ()
    }
  , { name := "ingest_isSome_equivalent_for_distinct_addresses: term-level API (full per plan)"
    , body := do
        -- Plan §6.2 / §12.8 #30: the full version covers EVERY address,
        -- including those touching either event.
        let _f : (b : AddressBook) → (n : Nonce) → (e₁ e₂ : L1Event) →
                 e₁.address ≠ e₂.address →
                 (addr : EthAddress) →
                 ((ingest (ingest b n e₁).fst (n + 1) e₂).fst.lookup addr).isSome =
                 ((ingest (ingest b n e₂).fst (n + 1) e₁).fst.lookup addr).isSome :=
          ingest_isSome_equivalent_for_distinct_addresses
        pure ()
    }
  , -- ## Strong locality lemma (work-horse for the full theorem)
    { name := "ingest_lookup_isSome_pre_invariant: term-level API"
    , body := do
        let _f : (b₁ b₂ : AddressBook) → (n₁ n₂ : Nonce) → (e : L1Event) →
                 (addr : EthAddress) →
                 (b₁.lookup addr).isSome = (b₂.lookup addr).isSome →
                 ((ingest b₁ n₁ e).fst.lookup addr).isSome =
                 ((ingest b₂ n₂ e).fst.lookup addr).isSome :=
          ingest_lookup_isSome_pre_invariant
        pure ()
    }
  , -- ## Value-level cross-address commutativity at e_i.address
    { name := "Value-level: ingest commutes (isSome) at e₁.address"
    , body := do
        -- Two addresses, e₁ at addr1, e₂ at addr2.
        let e₁ := L1Event.identityRegistered addr1 pk1 0 0
        let e₂ := L1Event.identityRegistered addr2 pk2 1 0
        -- At addr1 (= e₁.address), both orderings register addr1.
        let b₁ := (ingest empty 0 e₁).fst
        let b₂ := (ingest b₁ 1 e₂).fst
        let b₁' := (ingest empty 0 e₂).fst
        let b₂' := (ingest b₁' 1 e₁).fst
        -- Both b₂ and b₂' have addr1 mapped (to some id, but possibly different ones).
        assert (b₂.lookup addr1 |>.isSome) "order1: addr1 mapped"
        assert (b₂'.lookup addr1 |>.isSome) "order2: addr1 mapped"
        -- The ids might differ: order1 assigns addr1 first (id=1), order2 assigns
        -- addr2 first (id=1) then addr1 second (id=2).
        -- So order1: addr1 → 1, order2: addr1 → 2.
        assertEq (expected := (some (1 : ActorId))) (actual := b₂.lookup addr1)
          "order1 id"
        assertEq (expected := (some (2 : ActorId))) (actual := b₂'.lookup addr1)
          "order2 id"
        -- Both have isSome = true, demonstrating the theorem.
    }
  , -- ## ingest_preserves_consistent
    { name := "ingest_preserves_consistent: term-level API"
    , body := do
        let _f : (b : AddressBook) → (n : Nonce) → (e : L1Event) →
                 b.Consistent → b.reverse[b.nextActorId]? = none →
                 (ingest b n e).fst.Consistent :=
          ingest_preserves_consistent
        pure ()
    }
  , { name := "Value-level: ingest of identityRegistered preserves Consistent"
    , body := do
        let hFresh : empty.reverse[empty.nextActorId]? = none := by
          show (∅ : Std.TreeMap ActorId EthAddress compare)[(1 : ActorId)]? = none
          exact Std.TreeMap.getElem?_emptyc
        let e := L1Event.identityRegistered addr1 pk1 0 0
        let b' := (ingest empty 0 e).fst
        let h : b'.Consistent :=
          ingest_preserves_consistent empty 0 e empty_consistent hFresh
        let _ := h  -- API stability
        -- Verify the consistency at the value level:
        -- After registering addr1, addr1 ↔ id 1.
        assertEq (expected := (some (1 : ActorId))) (actual := b'.lookup addr1)
          "lookup forward"
        assertEq (expected := (some addr1)) (actual := b'.lookupRev 1)
          "lookup reverse"
    }
  , -- ## L1Event DecidableEq (per plan)
    { name := "L1Event DecidableEq: equal events compare equal"
    , body := do
        let e₁ := L1Event.identityRegistered addr1 pk1 0 0
        let e₂ := L1Event.identityRegistered addr1 pk1 0 0
        if decide (e₁ = e₂) then pure () else
          throw <| IO.userError "equal events compared unequal"
    }
  , { name := "L1Event DecidableEq: distinct events compare unequal"
    , body := do
        let e₁ := L1Event.identityRegistered addr1 pk1 0 0
        let e₂ := L1Event.identityRegistered addr2 pk1 0 0  -- different addr
        if decide (e₁ = e₂) then
          throw <| IO.userError "distinct events compared equal"
        else pure ()
    }
  , -- ## L1Event.address determinism
    { name := "L1Event.address is deterministic (same input → same output)"
    , body := do
        let e := L1Event.identityRegistered addr1 pk1 0 0
        assertEq (expected := e.address) (actual := e.address) "deterministic"
    }
  , -- ## End-to-end shape verification: ingest → action shape suitable for apply_admissible
    { name := "End-to-end: ingest output shape suitable for apply_admissible"
    , body := do
        -- This test verifies that the `UnsignedBridgeAction` produced
        -- by `ingest` has the correct structural shape to be wrapped
        -- into a `SignedAction` and fed into `apply_admissible_with`.
        -- It does NOT exercise the full apply path (which requires
        -- value-level construction of an `AdmissibleWith` witness;
        -- that is exercised by the SignedActionHappyPath suite for
        -- the existing action constructors).
        let e := L1Event.identityRegistered addr1 pk1 0 0
        let (_, maybeUb) := ingest empty 0 e
        match maybeUb with
        | none =>
            throw <| IO.userError "ingest returned none"
        | some ub =>
            -- 1. signer is bridgeActor (so bridgePolicy authorises this action).
            assertEq (expected := bridgeActor) (actual := ub.signer)
              "signer is bridgeActor"
            -- 2. action is registerIdentity (so applyActionToRegistry
            --    will insert into the registry).
            match ub.action with
            | .registerIdentity actor pk =>
                assertEq (expected := (1 : ActorId)) (actual := actor)
                  "fresh actor id is 1"
                assertEq (expected := pk1.size) (actual := pk.size)
                  "pk size matches"
            | _ =>
                throw <| IO.userError s!"expected registerIdentity, got {repr ub.action}"
            -- 3. nonce is the supplied currentNonce.
            assertEq (expected := (0 : Nonce)) (actual := ub.nonce) "nonce is 0"
            -- 4. The action's compiled transition is the kernel-level
            --    no-op `Laws.freezeResource 0` (verified by inspection
            --    of `Action.compileTransition` for `.registerIdentity`).
            pure ()
    }
  , { name := "End-to-end: bridgePolicy authorises the action ingest emits"
    , body := do
        -- The action emitted by `ingest` for an identityRegistered
        -- event is always authorized by `bridgePolicy` (since it's
        -- always registerIdentity or replaceKey, both of which are
        -- in `bridgeAuthorizedAction`).
        let e_fresh := L1Event.identityRegistered addr1 pk1 0 0
        let (_, mUb1) := ingest empty 0 e_fresh
        match mUb1 with
        | none => throw <| IO.userError "ingest returned none on fresh"
        | some ub =>
            -- Demonstrate authorisation type-level.
            -- ub.action = .registerIdentity 1 pk1 (verified above).
            -- bridgePolicy authorises bridgeActor on registerIdentity.
            match ub.action with
            | .registerIdentity actor pk =>
                let h : bridgePolicy.authorized bridgeActor (.registerIdentity actor pk) :=
                  bridgePolicy_authorizes_registerIdentity actor pk
                let _ := h
                pure ()
            | _ => throw <| IO.userError "unexpected ingest action"
        -- Same check for rotation case.
        let (b1, _) := empty.assign addr1
        let e_rot := L1Event.identityRegistered addr1 pk2 0 0
        let (_, mUb2) := ingest b1 5 e_rot
        match mUb2 with
        | none => throw <| IO.userError "ingest returned none on rotation"
        | some ub =>
            match ub.action with
            | .replaceKey actor newKey =>
                let h : bridgePolicy.authorized bridgeActor (.replaceKey actor newKey) :=
                  bridgePolicy_authorizes_replaceKey actor newKey
                let _ := h
                pure ()
            | _ => throw <| IO.userError "unexpected ingest action"
    }
  ]

end IngestTests
end LegalKernel.Test.Bridge
