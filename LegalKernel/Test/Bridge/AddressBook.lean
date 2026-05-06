/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.AddressBook — Workstream B.1 test suite.

Exercises the Workstream-B address-book infrastructure
(`LegalKernel/Bridge/AddressBook.lean`).  Coverage:

  * **Empty fixture properties.**  `empty.lookup` and
    `empty.lookupRev` return `none`; `empty.nextActorId = 1`;
    `empty.Consistent` holds.
  * **`assign` happy paths.**  Assigning a fresh address yields a
    `some` lookup at the new id; assigning a known address is the
    identity.
  * **`assign` cross-actor independence.**  Other addresses /
    other ids are unaffected by an `assign` call on a fresh
    address.
  * **Consistency preservation.**  Every consistent input book
    produces a consistent output book under `assign` (given the
    freshness hypothesis).
  * **Term-level API stability.**  The three §12.7 headline
    theorems are referenced via `let _f : T := theorem` patterns
    so any signature change at the source breaks elaboration here.
-/

import LegalKernel.Bridge.AddressBook
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace AddressBookTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Bridge.AddressBook
open LegalKernel.Test

/-- A small concrete `EthAddress`: `0x00...01`. -/
def addr1 : EthAddress := ⟨1, by unfold ethAddressBound; decide⟩

/-- A second concrete `EthAddress`: `0x00...02`. -/
def addr2 : EthAddress := ⟨2, by unfold ethAddressBound; decide⟩

/-- A third concrete `EthAddress`: `0x00...03`. -/
def addr3 : EthAddress := ⟨3, by unfold ethAddressBound; decide⟩

/-- A sample public key for fixture construction (first key). -/
def pk1 : PublicKey := ⟨#[0x11, 0x22]⟩

/-- A second sample public key for fixture construction. -/
def pk2 : PublicKey := ⟨#[0x33, 0x44]⟩

/-- Tests for `AddressBook` and `EthAddress`. -/
def tests : List TestCase :=
  [ -- ## Empty fixture
    { name := "empty.lookup returns none for any address"
    , body := do
        assert (empty.lookup addr1 = none) "addr1 not in empty"
        assert (empty.lookup addr2 = none) "addr2 not in empty"
    }
  , { name := "empty.lookupRev returns none for any id"
    , body := do
        assert (empty.lookupRev 0 = none) "id 0 not in empty"
        assert (empty.lookupRev 1 = none) "id 1 not in empty"
    }
  , { name := "empty.nextActorId = 1 (reserves id 0 for bridge actor)"
    , body := do
        assertEq (expected := (1 : ActorId)) (actual := empty.nextActorId) "nextActorId"
    }
  , -- ## EthAddress conversions
    { name := "EthAddress.zero has underlying value 0"
    , body := do
        assertEq (expected := (0 : Nat)) (actual := EthAddress.zero.val) "zero.val"
    }
  , { name := "EthAddress.toBytes produces 20-byte output"
    , body := do
        let bs := EthAddress.toBytes addr1
        assertEq (expected := 20) (actual := bs.size) "toBytes size"
    }
  , { name := "EthAddress.ofBytes rejects wrong-size input"
    , body := do
        let bs := ByteArray.mk (Array.mk (List.replicate 19 (0 : UInt8)))
        assert (EthAddress.ofBytes bs = none) "19-byte input rejected"
        let bs' := ByteArray.mk (Array.mk (List.replicate 21 (0 : UInt8)))
        assert (EthAddress.ofBytes bs' = none) "21-byte input rejected"
    }
  , -- ## Assign happy paths
    { name := "assign on empty: addr1 → id = 1"
    , body := do
        let (b', id) := empty.assign addr1
        assertEq (expected := (1 : ActorId)) (actual := id) "assigned id"
        assertEq (expected := (some 1 : Option ActorId)) (actual := b'.lookup addr1) "lookup"
        assertEq (expected := (some addr1)) (actual := b'.lookupRev 1) "lookupRev"
    }
  , { name := "assign on empty: nextActorId increments"
    , body := do
        let (b', _) := empty.assign addr1
        assertEq (expected := (2 : ActorId)) (actual := b'.nextActorId) "nextActorId after one assign"
    }
  , { name := "assign known address is idempotent"
    , body := do
        let (b', id1) := empty.assign addr1
        let (b'', id1') := b'.assign addr1
        assertEq (expected := id1) (actual := id1') "same id"
        -- The book should be unchanged (same forward / reverse / nextActorId).
        assertEq (expected := b'.nextActorId) (actual := b''.nextActorId) "nextActorId unchanged"
        assertEq (expected := b'.lookup addr1) (actual := b''.lookup addr1) "lookup unchanged"
    }
  , { name := "assign two distinct addresses gets distinct ids"
    , body := do
        let (b', id1) := empty.assign addr1
        let (b'', id2) := b'.assign addr2
        assertEq (expected := (1 : ActorId)) (actual := id1) "first id"
        assertEq (expected := (2 : ActorId)) (actual := id2) "second id"
        assertEq (expected := (3 : ActorId)) (actual := b''.nextActorId) "nextActorId after two"
    }
  , { name := "assign three distinct addresses, each unique"
    , body := do
        let (b1, _) := empty.assign addr1
        let (b2, _) := b1.assign addr2
        let (b3, _) := b2.assign addr3
        assert (b3.lookup addr1 = some 1) "addr1 → 1"
        assert (b3.lookup addr2 = some 2) "addr2 → 2"
        assert (b3.lookup addr3 = some 3) "addr3 → 3"
        assert (b3.lookupRev 1 = some addr1) "rev 1"
        assert (b3.lookupRev 2 = some addr2) "rev 2"
        assert (b3.lookupRev 3 = some addr3) "rev 3"
    }
  , -- ## Cross-actor independence
    { name := "assign addr1, then addr2: addr1 still mapped"
    , body := do
        let (b1, _) := empty.assign addr1
        let (b2, _) := b1.assign addr2
        assertEq (expected := (some (1 : ActorId))) (actual := b2.lookup addr1) "addr1 still mapped"
    }
  , { name := "assign addr1: addr2 still unmapped"
    , body := do
        let (b1, _) := empty.assign addr1
        assertEq (expected := (none : Option ActorId)) (actual := b1.lookup addr2) "addr2 unmapped"
    }
  , -- ## Consistency
    { name := "empty is consistent"
    , body := do
        let _ : empty.Consistent := empty_consistent
        pure ()
    }
  , { name := "addressBook_invariant on empty"
    , body := do
        -- For any addr / id, lookup ↔ lookupRev gives an empty equivalence.
        let h := addressBook_invariant empty empty_consistent addr1 (1 : ActorId)
        -- The iff is between two `none`-options, so both sides are False.
        assert (¬ (empty.lookup addr1 = some 1)) "lookup is none"
        assert (¬ (empty.lookupRev 1 = some addr1)) "lookupRev is none"
        let _ := h  -- API stability: theorem applies
        pure ()
    }
  , -- ## Term-level API stability for the §12.7 theorems
    { name := "addressBook_invariant: term-level API"
    , body := do
        let _f : (b : AddressBook) → b.Consistent →
                 ∀ addr id, b.lookup addr = some id ↔ b.lookupRev id = some addr :=
          addressBook_invariant
        pure ()
    }
  , { name := "assign_fresh_actorId: term-level API"
    , body := do
        let _f : (b : AddressBook) → (addr : EthAddress) → b.lookup addr = none →
                 (b.assign addr).fst.lookup addr = some (b.assign addr).snd ∧
                 (b.assign addr).fst.nextActorId = b.nextActorId + 1 :=
          assign_fresh_actorId
        pure ()
    }
  , { name := "assign_idempotent_for_known: term-level API"
    , body := do
        let _f : (b : AddressBook) → (addr : EthAddress) → (id : ActorId) →
                 b.lookup addr = some id →
                 (b.assign addr).fst = b ∧ (b.assign addr).snd = id :=
          assign_idempotent_for_known
        pure ()
    }
  , { name := "empty_consistent: term-level API"
    , body := do
        let _f : empty.Consistent := empty_consistent
        pure ()
    }
  , { name := "assign_preserves_consistent: term-level API"
    , body := do
        let _f : (b : AddressBook) → b.Consistent → (addr : EthAddress) →
                 b.reverse[b.nextActorId]? = none →
                 (b.assign addr).fst.Consistent :=
          assign_preserves_consistent
        pure ()
    }
  , { name := "assign_other_address_untouched: term-level API"
    , body := do
        let _f : (b : AddressBook) → (addr addr' : EthAddress) → addr ≠ addr' →
                 b.lookup addr = none →
                 (b.assign addr).fst.lookup addr' = b.lookup addr' :=
          assign_other_address_untouched
        pure ()
    }
  , { name := "assign_other_id_untouched: term-level API"
    , body := do
        let _f : (b : AddressBook) → (addr : EthAddress) → (id' : ActorId) →
                 id' ≠ b.nextActorId → b.lookup addr = none →
                 (b.assign addr).fst.lookupRev id' = b.lookupRev id' :=
          assign_other_id_untouched
        pure ()
    }
  , -- ## EthAddress.toBytes size theorem
    { name := "EthAddress.toBytes always produces 20 bytes"
    , body := do
        assertEq (expected := 20) (actual := (EthAddress.toBytes addr1).size)
          "addr1 toBytes size"
        assertEq (expected := 20) (actual := (EthAddress.toBytes addr2).size)
          "addr2 toBytes size"
        assertEq (expected := 20) (actual := (EthAddress.toBytes EthAddress.zero).size)
          "zero toBytes size"
    }
  , { name := "EthAddress.toBytes_size: term-level API"
    , body := do
        let _f : (a : EthAddress) → (EthAddress.toBytes a).size = 20 :=
          @EthAddress.toBytes_size
        pure ()
    }
  , -- ## Value-level Consistent preservation
    { name := "After assigning addr1, the book is still Consistent"
    , body := do
        -- Verify the freshness hypothesis at empty: reverse[1]? = none.
        let hFresh : empty.reverse[empty.nextActorId]? = none := by
          show (∅ : Std.TreeMap ActorId EthAddress compare)[(1 : ActorId)]? = none
          exact Std.TreeMap.getElem?_emptyc
        -- Apply assign_preserves_consistent.
        let h_post : (empty.assign addr1).fst.Consistent :=
          assign_preserves_consistent empty empty_consistent addr1 hFresh
        let _ := h_post  -- term-level check the proof typechecks
        pure ()
    }
  , { name := "Value-level: after assign, addressBook_invariant holds"
    , body := do
        let hFresh : empty.reverse[empty.nextActorId]? = none := by
          show (∅ : Std.TreeMap ActorId EthAddress compare)[(1 : ActorId)]? = none
          exact Std.TreeMap.getElem?_emptyc
        let b' := (empty.assign addr1).fst
        let h_post : b'.Consistent :=
          assign_preserves_consistent empty empty_consistent addr1 hFresh
        -- addressBook_invariant b' h_post: ∀ addr id, ...
        let h_inv := addressBook_invariant b' h_post
        -- Demonstrate the iff at addr1, id 1.  Both directions
        -- typecheck against b''s post-assign state.
        let _mp  : b'.lookup addr1 = some 1 → b'.lookupRev 1 = some addr1 :=
          (h_inv addr1 1).mp
        let _mpr : b'.lookupRev 1 = some addr1 → b'.lookup addr1 = some 1 :=
          (h_inv addr1 1).mpr
        -- Verify the value-level claims:
        assertEq (expected := (some (1 : ActorId))) (actual := b'.lookup addr1)
          "lookup addr1"
        assertEq (expected := (some addr1)) (actual := b'.lookupRev 1)
          "lookupRev 1"
        pure ()
    }
  , -- ## ≤-form of assign_fresh_actorId
    { name := "assign_fresh_actorId_le: term-level API (no-overflow form)"
    , body := do
        let _f : (b : AddressBook) → (addr : EthAddress) → b.lookup addr = none →
                 b.nextActorId.toNat + 1 < 2 ^ 64 →
                 b.nextActorId.toNat ≤ (b.assign addr).fst.nextActorId.toNat :=
          assign_fresh_actorId_le
        pure ()
    }
  -- Audit-2: EthAddress byte round-trip (closes signature-forgery
  -- vulnerability via the lossless 20-byte ByteArray encoding).
  , { name := "EthAddress.ofBytes_toBytes: term-level API (audit-2)"
    , body := do
        let _f : (a : EthAddress) →
                 EthAddress.ofBytes (EthAddress.toBytes a) = some a :=
          EthAddress.ofBytes_toBytes
        pure ()
    }
  , { name := "EthAddress.ofBytes_toBytes: zero address round-trips"
    , body := do
        let a : EthAddress := EthAddress.zero
        match EthAddress.ofBytes (EthAddress.toBytes a) with
        | some a' => assertEq a.val a'.val "round-trip preserves value"
        | none => throw <| IO.userError "round-trip failed"
    }
  , { name := "EthAddress.ofBytes_toBytes: 160-bit-max address round-trips"
    , body := do
        -- An EthAddress with high bits set (requires more than 64 bits).
        let a : EthAddress := ⟨18446744073709551616 + 12345, by decide⟩
        match EthAddress.ofBytes (EthAddress.toBytes a) with
        | some a' => assertEq a.val a'.val "round-trip preserves value"
        | none => throw <| IO.userError "round-trip failed"
    }
  , { name := "EthAddress.ofBytes_toBytes: distinct high-bit addresses round-trip distinctly"
    , body := do
        -- Two addresses sharing low 64 bits — the bytes MUST differ.
        let a : EthAddress := ⟨18446744073709551616 + 42, by decide⟩
        let b : EthAddress := ⟨2 * 18446744073709551616 + 42, by decide⟩
        let bytesA := EthAddress.toBytes a
        let bytesB := EthAddress.toBytes b
        if bytesA.data == bytesB.data then
          throw <| IO.userError
            "audit-2 regression: high-bit addresses with shared low 64 bits collided"
        else pure ()
    }
  ]

end AddressBookTests
end LegalKernel.Test.Bridge
