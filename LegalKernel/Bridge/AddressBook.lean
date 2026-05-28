/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.AddressBook — Workstream B.1
(Ethereum integration plan §6.1).

Maps Ethereum 20-byte addresses to Knomosis `ActorId`s, allowing the
runtime layer to translate L1 events into Knomosis-side actions
without changing the kernel's `ActorId : UInt64` abbreviation.

Design notes:

  * `EthAddress` is `Fin (2^160)` rather than `ByteArray` so that:

      1. The 20-byte width is enforced at the *type level* rather
         than by runtime checks (`Fin n` proves `i < n`
         constructively).
      2. The default `Ord (Fin n)` instance (Lean core, derived
         from `Ord Nat`) gives a numeric comparator usable directly
         with `Std.TreeMap`.  We do not depend on a custom
         `Ord ByteArray` instance (which Lean core does not ship).
      3. `DecidableEq` is automatic.

    `EthAddress.ofBytes : ByteArray → Option EthAddress` converts a
    20-byte ByteArray (interpreted big-endian) to an `EthAddress`,
    returning `none` if the byte array is not exactly 20 bytes; the
    runtime adaptor performs this validation at the deployment
    boundary.

  * The plan sketch suggests bundling a propositional invariant
    inside the `AddressBook` structure itself.  In practice the
    dependent `match` form needed to construct such a proof from
    `assign` runs into Lean's "motive is not type correct" wall
    (the proof field's type depends on the runtime lookup result).
    Phase B therefore separates the *raw* `AddressBook` structure
    (three plain fields) from the *propositional* `Consistent`
    predicate, and proves that operations preserve `Consistent`.

  * `Consistent` is the inverse-pair invariant: forward and reverse
    maps agree key-by-key.  `assign_preserves_consistent` is
    conditional on a *freshness* hypothesis `b.reverse[b.nextActorId]?
    = none`: the runtime adaptor verifies that the next id is not
    yet assigned.  This keeps the invariant stable under UInt64
    overflow concerns (the kernel's `ActorId : UInt64` would
    otherwise force the freshness clause to bake in a no-overflow
    bound, which is fragile under structural induction).  The
    runtime adaptor's `assign` loop maintains freshness by
    monotonically increasing `nextActorId` from `1` and never
    overflowing under any practical workload (max 2^64 unique
    addresses).

  * The forward map is `EthAddress → ActorId`; the reverse map is
    `ActorId → EthAddress`.  `lookup` walks the forward map,
    `lookupRev` walks the reverse map, and `assign` adds an
    `(addr, nextActorId)` pair to both — bumping `nextActorId` so
    that the freshness invariant is preserved given the runtime
    adaptor's monotonic assignment discipline.

This module is **not** part of the kernel TCB.  Bugs here would
weaken the bridge's identity-translation guarantees but cannot
violate any kernel invariant.

Coverage map:

  * §6.1 (WU B.1) — `EthAddress`, `AddressBook`, `Consistent`,
    `addressBook_invariant`, `assign_fresh_actorId`,
    `assign_idempotent_for_known`, `empty_consistent`,
    `assign_preserves_consistent`.
  * §12.7 — three theorems above (`addressBook_invariant`,
    `assign_fresh_actorId`, `assign_idempotent_for_known`),
    plus the supporting preservation lemma.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Authority.Crypto

open Std

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## EthAddress

A 20-byte (160-bit) Ethereum address, stored as `Fin (2^160)`.

The numeric width is enforced at the type level: the elaborator
rejects any `EthAddress` value whose underlying `Nat` is
≥ 2^160.  Decidable equality and the canonical numeric `Ord`
instance follow from Lean core's `Fin` library. -/

/-- The numeric upper bound for a 20-byte Ethereum address (`2^160`).
    Exposed as a named constant so downstream call sites can refer to
    the bound without re-deriving the literal. -/
def ethAddressBound : Nat := 2 ^ 160

/-- An Ethereum 20-byte (160-bit) address.

    Implemented as `Fin (2^160)` rather than `ByteArray` for the
    reasons documented in the module header (type-level width,
    automatic `Ord` / `DecidableEq`, no custom `ByteArray`
    comparator). -/
abbrev EthAddress : Type := Fin ethAddressBound

/-- The zero address (`0x0000...0000`).  Useful as a sentinel for
    "no address" or for fixture construction. -/
def EthAddress.zero : EthAddress := ⟨0, by
  unfold ethAddressBound
  exact Nat.pos_of_ne_zero (by decide)⟩

/-- A `Repr` instance that prints the underlying numeric value as a
    decimal `Nat`.  The runtime adaptor's serialiser is responsible
    for the canonical `0x…` hex rendering at the network boundary;
    this instance is for test diagnostics only.

    The decimal form was chosen over hex because Lean core's
    `Nat.toDigits` for hex requires a manual implementation; the
    decimal form is unambiguous given the surrounding `EthAddress(.)`
    wrapper and matches the underlying `Fin (2^160)` representation
    directly. -/
instance : Repr EthAddress where
  reprPrec a _ := s!"EthAddress({a.val})"

/-! ### `EthAddress` ↔ `ByteArray` conversion (big-endian)

The runtime adaptor parses an Ethereum log's `address` field as a
20-byte big-endian byte array; it then calls `EthAddress.ofBytes`
to lift the bytes into Knomosis's `EthAddress` type.  The reverse
direction (`toBytes`) is used by the runtime adaptor when emitting
log records that include the original L1 address. -/

/-- Decode a big-endian 20-byte `ByteArray` into an `EthAddress`.
    Returns `none` if the byte array is not exactly 20 bytes long.

    The big-endian interpretation matches Ethereum's address
    convention: byte 0 is the most-significant byte.

    Uses `bs.data.toList` (the underlying Array's list view) rather
    than `bs.toList` because the latter uses a custom `loop`
    definition that is not definitionally equal to the Array
    projection.  The `data.toList` form is the canonical way to
    decompose `bs` into its byte list and is what every codec
    helper uses (e.g. `Encoding.signingInput`'s
    `signedActionDomain.toUTF8.data.toList`). -/
def EthAddress.ofBytes (bs : ByteArray) : Option EthAddress :=
  if bs.size = 20 then
    -- BE-decode the 20 bytes into a Nat.
    let n : Nat := bs.data.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
    if h : n < ethAddressBound then some ⟨n, h⟩ else none
  else
    none

/-- The inverse of `EthAddress.ofBytes`: produce a 20-byte BE
    `ByteArray` for an `EthAddress`.  Used by the runtime adaptor
    when emitting log records that include the original L1
    address. -/
def EthAddress.toBytes (a : EthAddress) : ByteArray :=
  let rec go (k : Nat) (n : Nat) (acc : List UInt8) : List UInt8 :=
    match k with
    | 0     => acc
    | k + 1 => go k (n / 256) ((n % 256).toUInt8 :: acc)
  ⟨(go 20 a.val []).toArray⟩

/-- `EthAddress.toBytes.go k n []` produces a list of length `k`.
    Internal helper for the size theorem on `EthAddress.toBytes`. -/
private theorem EthAddress.toBytes_go_length :
    ∀ (k n : Nat) (acc : List UInt8),
      (EthAddress.toBytes.go k n acc).length = acc.length + k
  | 0,     _, acc => by
      unfold EthAddress.toBytes.go
      simp
  | k + 1, n, acc => by
      unfold EthAddress.toBytes.go
      have ih := EthAddress.toBytes_go_length k (n / 256) ((n % 256).toUInt8 :: acc)
      simp only [ih, List.length_cons]
      omega

/-- `EthAddress.toBytes` always produces a 20-byte `ByteArray`.
    Matches the Ethereum address format. -/
theorem EthAddress.toBytes_size (a : EthAddress) :
    (EthAddress.toBytes a).size = 20 := by
  unfold EthAddress.toBytes
  show (EthAddress.toBytes.go 20 a.val []).toArray.size = 20
  rw [List.size_toArray]
  rw [EthAddress.toBytes_go_length]
  decide

/-! ### EthAddress BE-byte round-trip (audit-2)

The `toBytes / ofBytes` pair is a true inverse on every `EthAddress`
value, not just on a subset.  The round-trip lemma is what closes
the §C-audit-2 signature-forgery concern: encoding the recipient-L1
address losslessly is what binds the user's signature to the *full*
20-byte address rather than a 64-bit truncation. -/

/-- Helper: `go k n acc` factors as `go k n [] ++ acc` for any
    accumulator.  Direct induction on `k`. -/
private theorem EthAddress.toBytes_go_append (k : Nat) :
    ∀ (n : Nat) (acc : List UInt8),
      EthAddress.toBytes.go k n acc = EthAddress.toBytes.go k n [] ++ acc := by
  induction k with
  | zero =>
    intro n acc
    unfold EthAddress.toBytes.go
    simp
  | succ k ih =>
    intro n acc
    show EthAddress.toBytes.go k (n / 256) ((n % 256).toUInt8 :: acc) =
         EthAddress.toBytes.go k (n / 256) ((n % 256).toUInt8 :: []) ++ acc
    rw [ih (n / 256) ((n % 256).toUInt8 :: acc)]
    rw [ih (n / 256) ((n % 256).toUInt8 :: [])]
    rw [List.append_assoc]
    rfl

/-- UInt8 conversion round-trip: for `m < 256`, `m.toUInt8.toNat = m`.
    Direct invocation of Lean core's `UInt8.toNat_ofNat_of_lt'`
    (with `UInt8.size = 256`). -/
private theorem EthAddress.toUInt8_toNat_of_lt (m : Nat) (h : m < 256) :
    (m.toUInt8).toNat = m := by
  show (UInt8.ofNat m).toNat = m
  exact UInt8.toNat_ofNat_of_lt' h

/-- BE-decoder applied to the BE-encoder output recovers the input,
    provided the input is bounded by `256^k`. -/
private theorem EthAddress.foldl_decode_go (k n : Nat) (h : n < 256 ^ k) :
    (EthAddress.toBytes.go k n []).foldl (fun acc b => acc * 256 + b.toNat) 0 = n := by
  induction k generalizing n with
  | zero =>
    have h0 : n = 0 := by
      have : (256 : Nat) ^ 0 = 1 := by decide
      omega
    subst h0
    show List.foldl (fun acc b => acc * 256 + b.toNat) 0 (EthAddress.toBytes.go 0 0 []) = 0
    rfl
  | succ k ih =>
    -- Bound: n / 256 < 256^k.
    have hex : (256 : Nat) ^ (k + 1) = 256 ^ k * 256 := Nat.pow_succ 256 k
    have h_bound : n / 256 < 256 ^ k := by
      have h_n : n < 256 ^ k * 256 := by rw [← hex]; exact h
      have h_div : 256 * (n / 256) + n % 256 = n := Nat.div_add_mod n 256
      have h_mod : n % 256 < 256 := Nat.mod_lt n (by decide)
      omega
    -- Reduce go (k+1) n [] to go k (n/256) [] ++ [(n%256).toUInt8].
    have hgo : EthAddress.toBytes.go (k + 1) n [] =
               EthAddress.toBytes.go k (n / 256) [] ++ [(n % 256).toUInt8] := by
      show EthAddress.toBytes.go k (n / 256) ((n % 256).toUInt8 :: []) =
           EthAddress.toBytes.go k (n / 256) [] ++ [(n % 256).toUInt8]
      exact EthAddress.toBytes_go_append k (n / 256) [(n % 256).toUInt8]
    rw [hgo, List.foldl_append, ih (n / 256) h_bound]
    -- Now: List.foldl f (n/256) [(n%256).toUInt8] = n
    -- which reduces to (n/256) * 256 + (n%256).toUInt8.toNat = n
    show n / 256 * 256 + (n % 256).toUInt8.toNat = n
    have hmod_lt : n % 256 < 256 := Nat.mod_lt n (by decide)
    rw [EthAddress.toUInt8_toNat_of_lt (n % 256) hmod_lt]
    have h_div_mod : 256 * (n / 256) + n % 256 = n := Nat.div_add_mod n 256
    omega

/-- §C-audit-2 / §12.6.4: `EthAddress.ofBytes` is a left-inverse of
    `EthAddress.toBytes`.  The round-trip closes the signature-
    forgery concern: encoding the recipient-L1 address as a 20-byte
    ByteArray (rather than a truncated 64-bit Nat) commits the
    user's signature to the *full* 160-bit address.

    Used by the `Action.withdraw` and `PendingWithdrawal` encoders
    (Workstream-C audit-2 hardening) for content-distinguishing
    canonical encoding. -/
theorem EthAddress.ofBytes_toBytes (a : EthAddress) :
    EthAddress.ofBytes (EthAddress.toBytes a) = some a := by
  unfold EthAddress.ofBytes
  rw [if_pos (EthAddress.toBytes_size a)]
  -- Now we need to compute the BE-decode of `EthAddress.toBytes a`.
  show (
    let n : Nat :=
      (EthAddress.toBytes a).data.toList.foldl (fun acc b => acc * 256 + b.toNat) 0
    if h : n < ethAddressBound then some ⟨n, h⟩ else none)
    = some a
  -- The data.toList of toBytes a is exactly `go 20 a.val []`.
  -- Direct definitional equality after unfolding EthAddress.toBytes
  -- (which exposes the `(go 20 a.val []).toArray` shape) plus
  -- Lean core's `Array.toList_toArray` (which is `rfl` for List.toArray).
  have h_toList : (EthAddress.toBytes a).data.toList =
                  EthAddress.toBytes.go 20 a.val [] := by
    unfold EthAddress.toBytes
    rfl
  -- And go 20 a.val [] decodes back to a.val (since a.val < 2^160 = 256^20).
  have h_bound : a.val < 256 ^ 20 := by
    have h1 : a.val < ethAddressBound := a.isLt
    have h2 : ethAddressBound = 256 ^ 20 := by
      unfold ethAddressBound
      decide
    omega
  have h_decode : (EthAddress.toBytes a).data.toList.foldl
                    (fun acc b => acc * 256 + b.toNat) 0 = a.val := by
    rw [h_toList]
    exact EthAddress.foldl_decode_go 20 a.val h_bound
  -- The let-binding's value reduces to a.val.
  show (let n : Nat := (EthAddress.toBytes a).data.toList.foldl
                          (fun acc b => acc * 256 + b.toNat) 0
        if h : n < ethAddressBound then some ⟨n, h⟩ else none) = some a
  rw [h_decode]
  show (if h : a.val < ethAddressBound then some ⟨a.val, h⟩ else none) = some a
  rw [dif_pos a.isLt]

/-! ## AddressBook structure -/

/-- An L1-address ↔ Knomosis-`ActorId` registry.

    `forward` maps each registered Ethereum address to the Knomosis
    `ActorId` it has been assigned; `reverse` is the inverse
    mapping.  `nextActorId` is the id that will be assigned to the
    next first-time-registered address.

    The `Consistent` predicate (defined below) is the inverse-pair
    invariant: forward and reverse maps agree key-by-key.  Both
    halves of the invariant are preserved by `empty` and by
    `assign` (under a freshness hypothesis on `nextActorId`); the
    §12.7 theorems below use `Consistent b` as a hypothesis. -/
structure AddressBook where
  /-- Mapping from Ethereum 20-byte addresses to Knomosis ActorIds. -/
  forward     : TreeMap EthAddress ActorId compare
  /-- Inverse mapping for log-extraction.  Maintained as the
      key-by-key inverse of `forward`. -/
  reverse     : TreeMap ActorId    EthAddress compare
  /-- The next `ActorId` to assign on first-time registration.
      The runtime adaptor maintains the (external) freshness
      invariant `reverse[nextActorId]? = none` by monotonic
      assignment from the initial value `1`. -/
  nextActorId : ActorId

namespace AddressBook

/-- The bookkeeping invariant for `AddressBook`: forward and reverse
    maps are key-by-key inverses.

    The freshness condition (`reverse[nextActorId]? = none`) is
    *not* part of this predicate; it is supplied as a separate
    hypothesis at `assign_preserves_consistent` call sites.
    Decoupling avoids the UInt64-overflow bookkeeping that a fully
    bundled invariant would require. -/
def Consistent (b : AddressBook) : Prop :=
  ∀ (addr : EthAddress) (id : ActorId),
    b.forward[addr]? = some id ↔ b.reverse[id]? = some addr

/-! ## Constructors and accessors -/

/-- The empty address book.  Both maps are empty; `nextActorId` is
    `1` so that any assigned id is strictly greater than `0` (the
    reserved bridge actor — see §6.3).  The bridge actor itself is
    NOT registered here; deployments register the bridge's identity
    in `KeyRegistry` directly at bootstrap time. -/
def empty : AddressBook where
  forward     := ∅
  reverse     := ∅
  nextActorId := 1  -- reserve `0` for the bridge actor (§6.3)

/-- Look up the `ActorId` assigned to an Ethereum address. -/
@[inline] def lookup (b : AddressBook) (addr : EthAddress) : Option ActorId :=
  b.forward[addr]?

/-- Look up the Ethereum address that an `ActorId` was assigned for.
    Returns `none` if the actor was not assigned via `assign` (e.g.
    the reserved bridge actor `0` is never present in the reverse
    map of an `AddressBook` built up via `empty` + `assign`). -/
@[inline] def lookupRev (b : AddressBook) (id : ActorId) : Option EthAddress :=
  b.reverse[id]?

/-! ## `assign`

`assign b addr` adds `addr` to the address book if it is not already
present, returning the (possibly updated) book and the `ActorId`
that `addr` is now mapped to.  If `addr` is already present, the
book is returned unchanged and the existing id is returned.

The function is defined via a non-dependent match on
`b.forward[addr]?`; the `Consistent` invariant is preserved
externally by `assign_preserves_consistent`. -/

/-- Assign an Ethereum address to a Knomosis `ActorId`.  Returns the
    (possibly updated) `AddressBook` and the assigned `ActorId`.

    If the address is already in the book, the book is returned
    unchanged and the previously-assigned id is returned.  Otherwise,
    the address is added with `nextActorId` and the next id is
    bumped.  Pure (no `IO`), deterministic, terminating. -/
def assign (b : AddressBook) (addr : EthAddress) : AddressBook × ActorId :=
  match b.forward[addr]? with
  | some id => (b, id)
  | none    =>
    ({ forward     := b.forward.insert addr b.nextActorId
       reverse     := b.reverse.insert b.nextActorId addr
       nextActorId := b.nextActorId + 1 },
     b.nextActorId)

/-! ### `assign` evaluation lemmas -/

/-- Evaluation lemma: `assign` returns `(b, id)` unchanged when
    `addr` is already mapped to `id`.  Direct consequence of the
    `some id` branch of the match. -/
theorem assign_eq_of_lookup_some
    (b : AddressBook) (addr : EthAddress) (id : ActorId)
    (h : b.forward[addr]? = some id) :
    b.assign addr = (b, id) := by
  unfold assign
  rw [h]

/-- Evaluation lemma: `assign` returns the freshly-constructed
    `AddressBook` and `b.nextActorId` when `addr` is unmapped. -/
theorem assign_eq_of_lookup_none
    (b : AddressBook) (addr : EthAddress)
    (h : b.forward[addr]? = none) :
    b.assign addr =
      ({ forward     := b.forward.insert addr b.nextActorId
         reverse     := b.reverse.insert b.nextActorId addr
         nextActorId := b.nextActorId + 1 },
       b.nextActorId) := by
  unfold assign
  rw [h]

/-! ## Consistency: preservation by every operation -/

/-- The empty AddressBook is consistent.  Both maps are empty so
    forward and reverse lookups are vacuously inverse. -/
theorem empty_consistent : empty.Consistent := by
  intro addr id
  have hf : empty.forward[addr]? = none := TreeMap.getElem?_emptyc
  have hr : empty.reverse[id]?   = none := TreeMap.getElem?_emptyc
  rw [hf, hr]
  constructor
  · intro h; cases h
  · intro h; cases h

/-- `assign` preserves the consistency invariant under a freshness
    hypothesis.  Two cases on `b.forward[addr]?`:

      * `some id`: `b.assign addr = (b, id)`, so the result book
        equals `b` and consistency is unchanged.
      * `none`: the new book has `addr ↦ nextActorId` in forward and
        `nextActorId ↦ addr` in reverse.  The freshness hypothesis
        `b.reverse[b.nextActorId]? = none` plus the case-by-case
        argument over the new pair (and over previously-assigned
        pairs) closes the new invariant. -/
theorem assign_preserves_consistent
    (b : AddressBook) (h : b.Consistent) (addr : EthAddress)
    (hFresh : b.reverse[b.nextActorId]? = none) :
    (b.assign addr).fst.Consistent := by
  -- Split on b.forward[addr]?.
  cases hv : b.forward[addr]? with
  | some id =>
    -- assign returns (b, id) unchanged.
    rw [assign_eq_of_lookup_some b addr id hv]
    exact h
  | none =>
    -- assign produces the freshly-extended book.
    rw [assign_eq_of_lookup_none b addr hv]
    -- New book's fields:
    --   forward'     = b.forward.insert addr b.nextActorId
    --   reverse'     = b.reverse.insert b.nextActorId addr
    intro addr' id'
    show
      (b.forward.insert addr b.nextActorId)[addr']? = some id' ↔
      (b.reverse.insert b.nextActorId addr)[id']? = some addr'
    -- Case-split on (addr' = addr) and (id' = b.nextActorId).  We use
    -- `Decidable.byCases` rather than `subst`-based destructuring so
    -- that both branch-equalities remain available as explicit
    -- hypotheses in subsequent rewrites.
    by_cases haddr : addr' = addr
    all_goals by_cases hid : id' = b.nextActorId
    -- Case 1: addr' = addr, id' = b.nextActorId.  Both freshly inserted.
    · rw [haddr, hid]
      rw [LegalKernel.RBMap.find?_insert_self,
          LegalKernel.RBMap.find?_insert_self]
      simp
    -- Case 2: addr' = addr, id' ≠ b.nextActorId.
    · rw [haddr]
      have hidNe : b.nextActorId ≠ id' := fun heq => hid heq.symm
      rw [LegalKernel.RBMap.find?_insert_self,
          LegalKernel.RBMap.find?_insert_other _ b.nextActorId id' addr hidNe]
      constructor
      · intro h_eq
        -- some b.nextActorId = some id' implies b.nextActorId = id', contra hid.
        exact absurd (Option.some.inj h_eq) (fun heq => hid heq.symm)
      · intro h_eq
        -- reverse[id']? = some addr would imply forward[addr]? = some id'
        -- by old invariant, but hv says forward[addr]? = none.
        have hcontra : b.forward[addr]? = some id' := (h addr id').mpr h_eq
        rw [hv] at hcontra
        cases hcontra
    -- Case 3: addr' ≠ addr, id' = b.nextActorId.
    · have haddrNe : addr ≠ addr' := fun heq => haddr heq.symm
      rw [hid, LegalKernel.RBMap.find?_insert_other _ addr addr' b.nextActorId haddrNe,
          LegalKernel.RBMap.find?_insert_self]
      constructor
      · intro h_eq
        -- forward[addr']? = some b.nextActorId implies (by old inv)
        -- reverse[b.nextActorId]? = some addr', but hFresh says it's none.
        have hrev : b.reverse[b.nextActorId]? = some addr' :=
          (h addr' b.nextActorId).mp h_eq
        rw [hFresh] at hrev
        cases hrev
      · intro h_eq
        -- some addr = some addr' but addr' ≠ addr.
        exact absurd (Option.some.inj h_eq) (fun heq => haddr heq.symm)
    -- Case 4: addr' ≠ addr, id' ≠ b.nextActorId.  Both reduce to old invariant.
    · have haddrNe : addr ≠ addr' := fun heq => haddr heq.symm
      have hidNe   : b.nextActorId ≠ id' := fun heq => hid heq.symm
      rw [LegalKernel.RBMap.find?_insert_other _ addr addr' b.nextActorId haddrNe,
          LegalKernel.RBMap.find?_insert_other _ b.nextActorId id' addr hidNe]
      exact h addr' id'

/-! ## Genesis Plan §12.7 theorems -/

/-- §12.7 #27 — the bookkeeping invariant: forward and reverse maps
    are key-by-key inverses, for any consistent `AddressBook`.

    The unconditional form on the spec sketch is recovered when
    `b` arises from `empty` + `assign` chains: `empty` is consistent
    (`empty_consistent`) and `assign` preserves consistency
    (`assign_preserves_consistent` under freshness), so every
    `AddressBook` value that the runtime adaptor produces satisfies
    `Consistent`. -/
theorem addressBook_invariant
    (b : AddressBook) (h : b.Consistent) :
    ∀ addr id, b.lookup addr = some id ↔ b.lookupRev id = some addr := by
  intro addr id
  exact h addr id

/-- §12.7 #28 — assigning a fresh address yields a `some` id and
    structurally bumps `nextActorId` by one.

    The conjunction encodes both halves of the spec:
      1. After `assign`, the address is now mapped to the returned id.
      2. `nextActorId` is structurally `b.nextActorId + 1`.  Stating
         the exact equality (rather than the spec's `≤`) is more
         precise and unconditionally true under the structural
         definition of `assign`; the `≤` form is exposed below
         (`assign_fresh_actorId_le`) for spec-compatibility callers,
         under a Nat-projected formulation that avoids UInt64-
         overflow concerns. -/
theorem assign_fresh_actorId
    (b : AddressBook) (addr : EthAddress) (h : b.lookup addr = none) :
    let result := b.assign addr
    result.fst.lookup addr = some result.snd ∧
    result.fst.nextActorId = b.nextActorId + 1 := by
  rw [assign_eq_of_lookup_none b addr h]
  refine ⟨?_, ?_⟩
  · -- The new forward has `addr ↦ b.nextActorId`.
    show (b.forward.insert addr b.nextActorId)[addr]? = some b.nextActorId
    exact LegalKernel.RBMap.find?_insert_self _ addr b.nextActorId
  · -- nextActorId is exactly bumped by one (definitional).
    rfl

/-- The plan's `≤`-form of `assign_fresh_actorId`, in `Nat`-projected
    form to avoid the UInt64 overflow concerns that the bare-`≤`
    version would inherit.

    Says: under no-overflow at the `nextActorId` boundary, the
    new `nextActorId.toNat` is exactly one more than the old.  This
    is the cleanest formulation of "nextActorId monotonically
    increases" that is sound under UInt64.  Production deployments
    are well within the no-overflow regime (max 2^64 - 1 unique
    addresses; practical workloads stay below 2^40 or so). -/
theorem assign_fresh_actorId_le
    (b : AddressBook) (addr : EthAddress) (h : b.lookup addr = none)
    (hNoOverflow : b.nextActorId.toNat + 1 < 2 ^ 64) :
    let result := b.assign addr
    b.nextActorId.toNat ≤ result.fst.nextActorId.toNat := by
  rw [assign_eq_of_lookup_none b addr h]
  -- Goal: b.nextActorId.toNat ≤ (b.nextActorId + 1).toNat
  -- Under no-overflow, (b.nextActorId + 1).toNat = b.nextActorId.toNat + 1.
  show b.nextActorId.toNat ≤ (b.nextActorId + 1).toNat
  have : (b.nextActorId + 1).toNat = b.nextActorId.toNat + 1 := by
    have := UInt64.toNat_add b.nextActorId 1
    -- toNat_add: (a + b).toNat = (a.toNat + b.toNat) % UInt64.size
    rw [this]
    have h1 : (1 : UInt64).toNat = 1 := by decide
    rw [h1]
    have hmod : (b.nextActorId.toNat + 1) % UInt64.size = b.nextActorId.toNat + 1 :=
      Nat.mod_eq_of_lt hNoOverflow
    exact hmod
  omega

/-- §12.7 #29 — assigning a known address is the identity: the
    book is returned unchanged and the existing id is returned. -/
theorem assign_idempotent_for_known
    (b : AddressBook) (addr : EthAddress) (id : ActorId)
    (h : b.lookup addr = some id) :
    let result := b.assign addr
    result.fst = b ∧ result.snd = id := by
  rw [assign_eq_of_lookup_some b addr id h]
  exact ⟨rfl, rfl⟩

/-! ## Cross-actor independence

The two lemmas below pin the per-address locality of `assign`: the
operation only changes the entry for the assigned address, leaving
all other entries unchanged. -/

/-- Assigning a fresh address `addr` does not affect lookups at any
    other address `addr' ≠ addr`. -/
theorem assign_other_address_untouched
    (b : AddressBook) (addr addr' : EthAddress) (h : addr ≠ addr')
    (hAbsent : b.lookup addr = none) :
    (b.assign addr).fst.lookup addr' = b.lookup addr' := by
  rw [assign_eq_of_lookup_none b addr hAbsent]
  show (b.forward.insert addr b.nextActorId)[addr']? = b.forward[addr']?
  exact LegalKernel.RBMap.find?_insert_other _ addr addr' b.nextActorId h

/-- Assigning a fresh address `addr` does not affect reverse
    lookups at any id `id' ≠ b.nextActorId`. -/
theorem assign_other_id_untouched
    (b : AddressBook) (addr : EthAddress) (id' : ActorId)
    (h : id' ≠ b.nextActorId) (hAbsent : b.lookup addr = none) :
    (b.assign addr).fst.lookupRev id' = b.lookupRev id' := by
  rw [assign_eq_of_lookup_none b addr hAbsent]
  show (b.reverse.insert b.nextActorId addr)[id']? = b.reverse[id']?
  exact LegalKernel.RBMap.find?_insert_other _ b.nextActorId id' addr h.symm

/-! ## Sanity smoke checks -/

example : (empty.lookup EthAddress.zero) = none := by
  show (∅ : TreeMap EthAddress ActorId compare)[EthAddress.zero]? = none
  exact TreeMap.getElem?_emptyc

example : (empty.lookupRev 0) = none := by
  show (∅ : TreeMap ActorId EthAddress compare)[(0 : ActorId)]? = none
  exact TreeMap.getElem?_emptyc

example : empty.nextActorId = 1 := rfl

end AddressBook
end Bridge
end LegalKernel
