// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! L1 event → Knomosis `Action` translation.
//!
//! Rust mirror of Lean's `LegalKernel.Bridge.Ingest.ingest`.
//! Each L1 event variant maps to either:
//!
//!   * `Some(UnsignedAction)` — the translator emits an
//!     unsigned bridge action that the submitter will sign and
//!     forward to `knomosis-host`.
//!   * `None` — the L1 event has no Knomosis-side action effect
//!     (revocations; deposits in the default mode — see the
//!     deposit-materialisation section below).
//!
//! ## The mathematical contract
//!
//! For every `IngestedEvent` `e` and `AddressBook` `b`:
//!
//! ```text
//! let (b', maybe_unsigned) = ingest(&mut b, e, current_nonce);
//! ```
//!
//! must match the Lean side's
//!
//! ```text
//! let (b', maybe_unsigned) := Bridge.Ingest.ingest b current_nonce e
//! ```
//!
//! **byte-by-byte after CBE encoding**.  The cross-stack
//! `FixtureKind::L1Ingest` corpus enforces this contract for the
//! variants the ingestor actually emits (RegisteredECDSA,
//! optional RegisteredEIP1271 contract signer registration).
//!
//! ## The 3 cases
//!
//! Mirrors Lean's `ingest` function:
//!
//!   1. **First-time registration** (event is RegisteredECDSA or
//!      RegisteredEIP1271; address book has no prior mapping):
//!      - Assign a fresh `ActorId` via `AddressBook::assign`.
//!      - Emit `Action::RegisterIdentity { actor: fresh_id, pk }`.
//!   2. **Rotation** (event is RegisteredECDSA or
//!      RegisteredEIP1271; address book has prior mapping):
//!      - Look up existing `ActorId`.
//!      - Emit `Action::ReplaceKey { actor: existing_id, new_key: pk }`.
//!      - Do NOT bump the address book counter.
//!   3. **No-op** (event is Revoked or DepositInitiated):
//!      - Return `None`.
//!      - Address book unchanged.
//!
//! ## Deposit materialisation (Workstream SB.9; opt-in)
//!
//! [`preview_ingest_materialising`] is the deposit-materialising
//! extension of case 3: it translates `DepositInitiated` →
//! `Action::Deposit` and `DepositWithFeeInitiated` →
//! `Action::DepositWithFee` (the seed leg lifted verbatim from the
//! event) and delegates every other variant to [`preview_ingest`],
//! so the Lean-mirror contract above is untouched when the watcher's
//! `materialise_deposits` flag is off (the default; fail-closed).
//! The emitted deposit `Action`s themselves ARE Lean-pinned — their
//! CBE bytes ride the same `encoding::encode_action` the cross-stack
//! corpus verifies against `Encoding.Action.encode` for tags 13/19.
//! Lean's `Bridge.Ingest.ingest` docstring reserves exactly this
//! translation for the deposit workstream; the Rust extension is
//! that landing.
//!
//! Three load-bearing properties:
//!
//!   * **The deposit id is content-derived** ([`deposit_id_from_receipt`]):
//!     the first 8 bytes of the L1 `receiptHash`, big-endian.  A
//!     restart, a state-file wipe, or a re-org re-delivery re-derives
//!     the SAME id from the same L1 deposit, which is the property
//!     the kernel's replay backstop rests on — `BridgeAdmissibleWith`
//!     conjuncts 6/6b refuse a deposit id already in
//!     `BridgeState.consumed`, so a re-materialised duplicate is
//!     refused at admission rather than double-credited.  (The
//!     watcher's forwarded-set dedup is the optimisation; the
//!     consumed-set rejection is the correctness argument.)
//!   * **Amounts are range-checked, never truncated**
//!     ([`amount_from_be_bytes`]): a raw `uint256` field that does
//!     not fit the runtime's `u128` `Amount` is REFUSED with a typed
//!     error that halts the watcher for operator intervention.
//!   * **An unregistered depositor is assigned a fresh `ActorId`**
//!     (the same `EmitWithAssignment` machinery registrations use),
//!     so no deposit is ever silently dropped.  The assigned actor
//!     has NO key in the L2 registry until its owner registers on
//!     L1; that later registration finds the address in the book and
//!     lands as `ReplaceKey`, whose authority-layer effect
//!     (`applyActionToRegistry`) is the same registry insert.  The
//!     kernel's first-time-only conjunct (7) constrains only
//!     `registerIdentity`, which this path never emits for a
//!     book-known address.

use crate::action::{Action, ActorId, DepositId, EthAddress, Nonce, PublicKey};
use crate::address_book::{AddressBook, BRIDGE_ACTOR_ID, GAS_POOL_ACTOR_ID};
use crate::events::IngestedEvent;

/// The signer / nonce / action triple the translator emits
/// before signing.  Mirrors Lean's `Bridge.UnsignedBridgeAction`
/// structure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnsignedAction {
    /// The Knomosis action to sign.
    pub action: Action,
    /// The signer's `ActorId` — always [`BRIDGE_ACTOR_ID`] for
    /// translated events, pinned by Lean's
    /// `ingest_emits_bridge_actor` theorem.
    pub signer: ActorId,
    /// The signer's next-expected nonce.  Supplied by the
    /// translation caller; the watcher maintains it across
    /// iterations.
    pub nonce: Nonce,
}

impl UnsignedAction {
    /// The bridge actor's id — pinned by Lean's
    /// `ingest_emits_bridge_actor`.
    pub const SIGNER: ActorId = BRIDGE_ACTOR_ID;
}

/// Outcome of a translation step.  The watcher consumes one of
/// these per L1 event and decides whether to sign + submit.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Translated {
    /// No Knomosis-side action — drop the event.
    NoAction,
    /// Emit an `UnsignedAction` that does not mutate the address
    /// book (e.g. a `ReplaceKey` rotation).  Safe to retry on
    /// submission failure: replaying the same event yields the
    /// same Action.
    Emit(UnsignedAction),
    /// Emit an Action carrying a freshly-allocated `ActorId` (a
    /// first-time `RegisterIdentity`, or a materialised deposit
    /// whose depositor has no book entry yet) AND, after submission
    /// succeeds, commit the new `(EthAddress, ActorId)` assignment
    /// into the book.  The `pending_assignment` is the
    /// `(address, id)` pair the watcher must persist via the
    /// state store before relying on the `id` in any future
    /// translation.
    EmitWithAssignment {
        /// The unsigned action carrying the freshly-allocated
        /// `ActorId`.
        action: UnsignedAction,
        /// The L1 `EthAddress` that maps to `ActorId` once
        /// committed.
        address: EthAddress,
        /// The `ActorId` that will be assigned on commit.
        new_actor_id: ActorId,
    },
}

/// Peek at the translation of `event` against `book` WITHOUT
/// mutating the book.  Returns a `Translated` value that the
/// caller commits (via [`commit_assignment`]) only after
/// successful submission to `knomosis-host`.
///
/// This is the bug-fixing alternative to the previous
/// `ingest(&mut book, ...)` API — that API mutated the book
/// eagerly, which left the book in a half-updated state if
/// submission failed.  On retry (in-memory or after restart),
/// the watcher would emit `ReplaceKey` instead of
/// `RegisterIdentity`, silently corrupting the L2 identity
/// stream.
///
/// Matches Lean's `Bridge.Ingest.ingest` byte-for-byte under
/// CBE encoding (verified by the cross-stack fixture corpus).
pub fn preview_ingest(
    book: &AddressBook,
    event: &IngestedEvent,
    current_nonce: Nonce,
) -> Translated {
    match event {
        IngestedEvent::RegisteredEcdsa { actor, pubkey, .. } => {
            let pk = PublicKey::from_bytes(pubkey);
            preview_registration(book, actor, pk, current_nonce)
        }
        IngestedEvent::RegisteredEip1271 {
            actor,
            contract_signer,
            ..
        } => {
            // The Lean side's `Bridge.Ingest.ingest` MVP scope
            // does not distinguish contract signers from EOAs at
            // the translation layer — both map to
            // `RegisterIdentity` / `ReplaceKey` with the
            // signer's address-as-pubkey encoding.  We use the
            // 20-byte contract address as the "pubkey" payload.
            // Downstream deployment-side `AuthorityPolicy`
            // predicates classify the signer kind via the
            // `KeyRegistry`'s `SignerKind` enum.
            let pk = PublicKey::from_bytes(contract_signer.as_bytes());
            preview_registration(book, actor, pk, current_nonce)
        }
        IngestedEvent::Revoked { .. } => {
            // `Bridge.Ingest.ingest` returns `none` for revocations
            // in MVP scope.
            Translated::NoAction
        }
        IngestedEvent::DepositInitiated { .. } => {
            // `Bridge.Ingest.ingest` returns `none` for deposits;
            // this function IS that mirror.  The opt-in
            // materialising mode lives in
            // `preview_ingest_materialising` (Workstream SB.9).
            Translated::NoAction
        }
        IngestedEvent::DepositWithFeeInitiated { .. } => {
            // Same as `DepositInitiated`: `NoAction` in the
            // Lean-mirror default; `preview_ingest_materialising`
            // is the opt-in materialising path (SB.9).
            Translated::NoAction
        }
        IngestedEvent::AmmDisabled { .. } => {
            // GP.11.10: the one-way kill switch fired.  Like the
            // deposit events, the L2 follow-ups (the `ammDisabled`
            // state-root mirror; the `reclaimAmmReserves` sweeps) are
            // the SEQUENCER's responsibility — the translator emits no
            // `Action`.  The watcher's audit log (keyed on this
            // variant's name + origin) is the operator-visible
            // disaster marker.
            Translated::NoAction
        }
    }
}

/// Errors surfaced by the deposit-materialising translation
/// ([`preview_ingest_materialising`]).
///
/// Currently empty.  It carried one variant, `AmountOverflow`, raised
/// when a raw `uint256` amount field exceeded the runtime's `u128`
/// `Amount` representation — fail-closed, never truncating, which was
/// the right posture for a limit the runtime could not lift.  Widening
/// `Amount` to the kernel's own `2^256` bound lifted it: every L1
/// `uint256` word is now representable, so the refusal has no
/// remaining trigger.
///
/// The type is retained rather than removed because
/// `preview_ingest_materialising` is fallible in shape and the watcher
/// matches on it; a future materialisation check (a malformed address
/// book, an unassignable depositor) belongs here.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum MaterialiseError {}

/// Derive the L2 deposit id from an L1 deposit's `receiptHash`: the
/// first 8 bytes, big-endian.  Content-derived and deterministic —
/// the same L1 deposit re-derives the same id across restarts,
/// state-file wipes and re-org re-deliveries, which is what makes
/// the kernel's `consumed`-set replay rejection (conjuncts 6/6b of
/// `BridgeAdmissibleWith`) a sound backstop for this pipeline.
///
/// The 8-byte width is forced by the frozen encoding bound
/// (`Action.fieldsBounded` pins `depositId < 2^64`; the step-VM L1
/// wire carries it as `uint64BE`).  The receipt hash is keccak256
/// over the deployment-scoped deposit tuple, so the prefix behaves
/// uniformly: an accidental collision among `N` deposits has
/// probability ~`N²/2⁶⁵` (negligible at any realistic volume), and
/// a collision FAILS CLOSED — the second deposit is refused
/// admission by the consumed-set conjunct, never double-credited.
#[must_use]
pub fn deposit_id_from_receipt(receipt_hash: &[u8; 32]) -> DepositId {
    let mut prefix = [0u8; 8];
    prefix.copy_from_slice(&receipt_hash[0..8]);
    u64::from_be_bytes(prefix)
}

/// Decode an L1 `uint256` field into an [`crate::action::Amount`].
///
/// TOTAL: every 32-byte big-endian word denotes a valid amount, so
/// there is no rejection path.
///
/// It used to have one.  While an `Amount` was a `u128` this refused
/// any word with a non-zero high half, returning
/// `MaterialiseError::AmountOverflow` -- fail-closed rather than
/// truncating, which was the right call, but it meant a legitimate L1
/// deposit at or above `2^128` could not be materialised at all even
/// though the kernel admits anything below `2^256`.  Widening the
/// representation removes the refusal rather than relaxing it: the
/// values that used to be rejected are now representable.
///
/// `field` is retained in the signature for call-site readability and
/// to keep the diff at those sites empty; it no longer names anything
/// that can fail.
#[must_use]
pub fn amount_from_be_bytes(bytes: &[u8; 32], field: &'static str) -> crate::action::Amount {
    let _ = field;
    crate::action::Amount::from_be_bytes(*bytes)
}

/// The deposit-materialising translation (Workstream SB.9).  Like
/// [`preview_ingest`] — peek-only, never mutates the book — but the
/// two deposit events construct bridge-signed deposit `Action`s
/// instead of returning `NoAction`:
///
///   * `DepositInitiated` → `Action::Deposit { r, recipient,
///     amount, deposit_id }`;
///   * `DepositWithFeeInitiated` → `Action::DepositWithFee { r,
///     recipient, pool_actor: GAS_POOL_ACTOR_ID, user_amount,
///     pool_amount, budget_grant, deposit_id, seed_amount }` — the
///     seed leg lifted verbatim from the event's `ammSeedAmount`
///     (the L2 law splits the pool credit as `poolAmount −
///     seedAmount` to the pool actor and `seedAmount` to the AMM
///     reserve actor, matching the L1 event exactly).
///
/// The recipient is the book-resolved `ActorId` for the depositor;
/// an unknown depositor gets a fresh id via the same
/// `EmitWithAssignment` path first-time registrations use (see the
/// module docstring for why that is sound and why no deposit is
/// ever dropped).  Every other event variant delegates to
/// [`preview_ingest`] unchanged.
///
/// # Errors
///
/// Returns [`MaterialiseError::AmountOverflow`] if any amount field
/// exceeds the `u128` representation (fail-closed; never truncates).
pub fn preview_ingest_materialising(
    book: &AddressBook,
    event: &IngestedEvent,
    current_nonce: Nonce,
) -> Result<Translated, MaterialiseError> {
    match event {
        IngestedEvent::DepositInitiated {
            depositor,
            resource_id,
            amount,
            receipt_hash,
            ..
        } => {
            let amount = amount_from_be_bytes(amount, "DepositInitiated.amount");
            let deposit_id = deposit_id_from_receipt(receipt_hash);
            let r = *resource_id;
            Ok(materialise_deposit_for(
                book,
                depositor,
                current_nonce,
                |recipient| Action::Deposit {
                    r,
                    recipient,
                    amount,
                    deposit_id,
                },
            ))
        }
        IngestedEvent::DepositWithFeeInitiated {
            sender,
            resource_id,
            user_amount,
            pool_amount,
            amm_seed_amount,
            budget_grant,
            receipt_hash,
            ..
        } => {
            let user_amount =
                amount_from_be_bytes(user_amount, "DepositWithFeeInitiated.userAmount");
            let pool_amount =
                amount_from_be_bytes(pool_amount, "DepositWithFeeInitiated.poolAmount");
            let seed_amount =
                amount_from_be_bytes(amm_seed_amount, "DepositWithFeeInitiated.ammSeedAmount");
            let deposit_id = deposit_id_from_receipt(receipt_hash);
            let r = *resource_id;
            let budget_grant = *budget_grant;
            Ok(materialise_deposit_for(
                book,
                sender,
                current_nonce,
                |recipient| Action::DepositWithFee {
                    r,
                    recipient,
                    pool_actor: GAS_POOL_ACTOR_ID,
                    user_amount,
                    pool_amount,
                    budget_grant,
                    deposit_id,
                    seed_amount,
                },
            ))
        }
        other => Ok(preview_ingest(book, other, current_nonce)),
    }
}

/// Resolve the depositor's L2 recipient and wrap the built deposit
/// action: a book-known depositor emits directly; an unknown one
/// rides `EmitWithAssignment` with a previewed fresh id (committed
/// by the watcher only after submission succeeds, exactly like a
/// first-time registration).
fn materialise_deposit_for(
    book: &AddressBook,
    depositor: &EthAddress,
    current_nonce: Nonce,
    build: impl FnOnce(ActorId) -> Action,
) -> Translated {
    match book.lookup(depositor) {
        Some(existing_id) => Translated::Emit(UnsignedAction {
            action: build(existing_id),
            signer: UnsignedAction::SIGNER,
            nonce: current_nonce,
        }),
        None => {
            let fresh_id = book.next_actor_id();
            Translated::EmitWithAssignment {
                action: UnsignedAction {
                    action: build(fresh_id),
                    signer: UnsignedAction::SIGNER,
                    nonce: current_nonce,
                },
                address: *depositor,
                new_actor_id: fresh_id,
            }
        }
    }
}

/// Errors surfaced by [`commit_assignment`].
#[derive(Debug, thiserror::Error)]
pub enum CommitError {
    /// The book's monotone counter is exhausted.  Unreachable
    /// on any realistic workload (2⁶⁴ unique addresses).
    #[error("address-book counter overflow")]
    Overflow,
    /// The committed id does not match the previewed id.  This
    /// indicates the book mutated between `preview_ingest` and
    /// `commit_assignment` — a programmer error or concurrent-
    /// modification bug.  Surfaces as a hard error in production
    /// (not just a debug-only assertion), because silent
    /// divergence between the on-disk state and the in-memory
    /// book would corrupt the L2's identity stream.
    #[error(
        "commit_assignment: book changed between preview and commit \
         (expected actor_id {expected}, got {actual})"
    )]
    ExpectedIdMismatch {
        /// The id the caller expected (from the previously-
        /// emitted `Translated::EmitWithAssignment`).
        expected: ActorId,
        /// The id the book actually assigned at commit time.
        actual: ActorId,
    },
}

impl From<crate::address_book::AssignError> for CommitError {
    fn from(e: crate::address_book::AssignError) -> Self {
        match e {
            crate::address_book::AssignError::Overflow => Self::Overflow,
        }
    }
}

/// Commit a previously-previewed `(address, id)` assignment to
/// the book.  Caller is the watcher; this is invoked AFTER
/// successful submission so the book never goes out of sync with
/// the persisted state.
///
/// Returns the actually-assigned id; this is `expected_id` if
/// `address` was not previously in the book, or the existing id
/// otherwise.  Returns [`CommitError::Overflow`] if the book's
/// monotone counter has reached `u64::MAX`.  Returns
/// [`CommitError::ExpectedIdMismatch`] if the assigned id
/// differs from `expected_id` (indicates concurrent modification
/// or a programming bug — production-fatal because the on-disk
/// state has been written with `expected_id` already).
///
/// # Errors
///
/// See [`CommitError`].
pub fn commit_assignment(
    book: &mut AddressBook,
    address: &EthAddress,
    expected_id: ActorId,
) -> Result<ActorId, CommitError> {
    let (assigned, _was_new) = book.try_assign(address)?;
    if assigned != expected_id {
        return Err(CommitError::ExpectedIdMismatch {
            expected: expected_id,
            actual: assigned,
        });
    }
    Ok(assigned)
}

/// **Deprecated** eager-mutation translation, retained for the
/// fixture-generation example and for cross-stack regression
/// tests that build the corpus from scratch.  Production code
/// must use [`preview_ingest`] + [`commit_assignment`] to avoid
/// the state-corruption bug documented on `preview_ingest`.
///
/// Matches Lean's `Bridge.Ingest.ingest` byte-for-byte under
/// CBE encoding (verified by the cross-stack fixture corpus).
///
/// # Panics
///
/// Panics if the address-book commit fails with `Overflow`
/// (counter reached `u64::MAX`).  This is unreachable on any
/// realistic input — the cross-stack fixtures use at most ~16
/// addresses, well below the bound — but the panic is louder
/// than silently swallowing the error.  Production callers
/// MUST use `preview_ingest` + `commit_assignment` which
/// returns `Result` instead.
pub fn ingest(
    book: &mut AddressBook,
    event: &IngestedEvent,
    current_nonce: Nonce,
) -> Option<UnsignedAction> {
    match preview_ingest(book, event, current_nonce) {
        Translated::NoAction => None,
        Translated::Emit(action) => Some(action),
        Translated::EmitWithAssignment {
            action,
            address,
            new_actor_id,
        } => {
            // Panic on commit error — unreachable for the
            // controlled inputs `ingest` is used with (tests,
            // fixture generator).  The previous `let _ =`
            // pattern silently swallowed `Overflow` and
            // `ExpectedIdMismatch`, which would have hidden
            // bugs.
            commit_assignment(book, &address, new_actor_id)
                .expect("ingest: address-book commit failed");
            Some(action)
        }
    }
}

/// Common path for registration events (RegisteredECDSA and
/// RegisteredEIP1271).  Looks up the address; if unknown,
/// PREVIEWS a fresh-id assignment without mutating; if known,
/// emits `ReplaceKey` (no mutation needed).
fn preview_registration(
    book: &AddressBook,
    actor_address: &EthAddress,
    pk: PublicKey,
    current_nonce: Nonce,
) -> Translated {
    match book.lookup(actor_address) {
        None => {
            // First-time registration: PEEK the would-be id.
            // The caller commits via `commit_assignment` AFTER
            // submission succeeds.
            let fresh_id = book.next_actor_id();
            Translated::EmitWithAssignment {
                action: UnsignedAction {
                    action: Action::RegisterIdentity {
                        actor: fresh_id,
                        pk,
                    },
                    signer: UnsignedAction::SIGNER,
                    nonce: current_nonce,
                },
                address: *actor_address,
                new_actor_id: fresh_id,
            }
        }
        Some(existing_id) => {
            // Key rotation: emit ReplaceKey, leave book unchanged.
            Translated::Emit(UnsignedAction {
                action: Action::ReplaceKey {
                    actor: existing_id,
                    new_key: pk,
                },
                signer: UnsignedAction::SIGNER,
                nonce: current_nonce,
            })
        }
    }
}

/// Errors surfaced by the higher-level translation pipeline.
/// `ingest` itself is total; this enum is reserved for the
/// downstream `sign + submit` pipeline that consumes
/// `UnsignedAction`.
#[derive(Debug, thiserror::Error)]
pub enum TranslationError {
    /// The translator received an event variant it can't handle.
    /// Reserved for future event types not yet wired through.
    #[error("unsupported event variant: {0}")]
    UnsupportedEvent(&'static str),
}

#[cfg(test)]
mod tests {
    use super::{ingest, UnsignedAction};
    use crate::action::Amount;
    use crate::action::{Action, EthAddress};
    use crate::address_book::{AddressBook, BRIDGE_ACTOR_ID};
    use crate::events::IngestedEvent;

    /// First-time `RegisteredECDSA` emits `RegisterIdentity` with
    /// a fresh actor id.
    #[test]
    fn first_time_registration_emits_register_identity() {
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let pubkey = vec![0xab, 0xcd];
        let event = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: pubkey.clone(),
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let unsigned = ingest(&mut book, &event, 0).unwrap();
        match &unsigned.action {
            Action::RegisterIdentity { actor: id, pk } => {
                // Genesis `next_actor_id` is 4 post-GP.11.5 (0/1/2/3 reserved).
                assert_eq!(*id, 4, "first assignment yields id 4");
                assert_eq!(pk.as_bytes(), pubkey.as_slice());
            }
            _ => panic!("expected RegisterIdentity"),
        }
        assert_eq!(unsigned.signer, BRIDGE_ACTOR_ID);
        assert_eq!(unsigned.nonce, 0);
        // Address book was mutated (fresh id 4 post-GP.11.5).
        assert_eq!(book.lookup(&actor), Some(4));
    }

    /// Second `RegisteredECDSA` for the same address emits
    /// `ReplaceKey` with the existing id.
    #[test]
    fn rotation_emits_replace_key() {
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        // First registration.
        let e1 = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0xaa],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let _ = ingest(&mut book, &e1, 0);
        let next_id_before = book.next_actor_id();
        // Rotation.
        let new_pk = vec![0xbb, 0xcc];
        let e2 = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: new_pk.clone(),
            block_number: 2,
            tx_hash: [0; 32],
            log_index: 1,
        };
        let unsigned = ingest(&mut book, &e2, 1).unwrap();
        match &unsigned.action {
            Action::ReplaceKey { actor: id, new_key } => {
                // The first registration was issued id 4 (post-GP.11.5);
                // the rotation reuses it.
                assert_eq!(*id, 4, "rotation uses existing id");
                assert_eq!(new_key.as_bytes(), new_pk.as_slice());
            }
            _ => panic!("expected ReplaceKey"),
        }
        assert_eq!(unsigned.nonce, 1);
        // Address book did NOT mutate (no fresh id assigned).
        assert_eq!(book.next_actor_id(), next_id_before);
    }

    /// `Revoked` emits no Action and does not mutate the book.
    #[test]
    fn revoked_emits_no_action() {
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let event = IngestedEvent::Revoked {
            actor,
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = ingest(&mut book, &event, 0);
        assert!(result.is_none());
        assert!(book.is_empty());
    }

    /// `DepositInitiated` emits no Action and does not mutate the
    /// book in the DEFAULT (Lean-mirror) mode — the opt-in
    /// materialising mode is tested separately below.
    #[test]
    fn deposit_emits_no_action() {
        let mut book = AddressBook::new();
        let depositor = EthAddress::from_bytes(&[3u8; 20]).unwrap();
        let event = IngestedEvent::DepositInitiated {
            depositor,
            resource_id: 7,
            token: EthAddress::ZERO,
            amount: [0; 32],
            depositor_nonce: 0,
            receipt_hash: [0; 32],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = ingest(&mut book, &event, 0);
        assert!(result.is_none());
        assert!(book.is_empty());
    }

    /// `DepositWithFeeInitiated` translates to no action in the
    /// DEFAULT (Lean-mirror) mode, exactly like `DepositInitiated`;
    /// the opt-in materialising mode is tested separately below.
    #[test]
    fn deposit_with_fee_emits_no_action() {
        let mut book = AddressBook::new();
        let sender = EthAddress::from_bytes(&[3u8; 20]).unwrap();
        let event = IngestedEvent::DepositWithFeeInitiated {
            sender,
            resource_id: 7,
            token: EthAddress::ZERO,
            user_amount: [0; 32],
            pool_amount: [0; 32],
            amm_seed_amount: [0; 32],
            budget_grant: 0,
            depositor_nonce: 0,
            receipt_hash: [0; 32],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = ingest(&mut book, &event, 0);
        assert!(result.is_none());
        assert!(book.is_empty());
    }

    /// A BOLD fee-split deposit (`resourceId = 1`, Workstream GP.5.4)
    /// translates to no action just like the ETH one — the translation
    /// is resourceId-agnostic, so BOLD needs no per-resource branch.
    #[test]
    fn deposit_with_fee_bold_emits_no_action() {
        let mut book = AddressBook::new();
        let sender = EthAddress::from_bytes(&[3u8; 20]).unwrap();
        let event = IngestedEvent::DepositWithFeeInitiated {
            sender,
            resource_id: 1, // RESOURCE_ID_BOLD
            token: EthAddress::from_bytes(&[
                0x64, 0x40, 0xf1, 0x44, 0xb7, 0xe5, 0x0d, 0x6a, 0x84, 0x39, 0x33, 0x65, 0x10, 0x31,
                0x2d, 0x2f, 0x54, 0xbe, 0xb0, 0x1d,
            ])
            .unwrap(),
            user_amount: [0; 32],
            pool_amount: [0; 32],
            amm_seed_amount: [0; 32],
            budget_grant: 33,
            depositor_nonce: 7,
            receipt_hash: [0; 32],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = ingest(&mut book, &event, 0);
        assert!(result.is_none(), "BOLD fee-split deposit -> NoAction");
        assert!(book.is_empty());
    }

    /// `RegisteredEIP1271` translates analogously to
    /// `RegisteredECDSA` but with the contract address as the
    /// public key.
    #[test]
    fn eip1271_translates_via_contract_signer() {
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[4u8; 20]).unwrap();
        let contract = EthAddress::from_bytes(&[5u8; 20]).unwrap();
        let event = IngestedEvent::RegisteredEip1271 {
            actor,
            contract_signer: contract,
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let unsigned = ingest(&mut book, &event, 0).unwrap();
        match &unsigned.action {
            Action::RegisterIdentity { pk, .. } => {
                // The pubkey payload is the 20-byte contract address.
                assert_eq!(pk.as_bytes(), contract.as_bytes());
            }
            _ => panic!("expected RegisterIdentity"),
        }
    }

    /// The signer of every emitted UnsignedAction is the bridge
    /// actor id (mirrors Lean's `ingest_emits_bridge_actor`).
    #[test]
    fn signer_is_always_bridge_actor() {
        let mut book = AddressBook::new();
        let addr1 = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let addr2 = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let events = [
            IngestedEvent::RegisteredEcdsa {
                actor: addr1,
                pubkey: vec![0x01],
                block_number: 0,
                tx_hash: [0; 32],
                log_index: 0,
            },
            IngestedEvent::RegisteredEcdsa {
                actor: addr2,
                pubkey: vec![0x02],
                block_number: 0,
                tx_hash: [0; 32],
                log_index: 1,
            },
            IngestedEvent::RegisteredEcdsa {
                actor: addr1, // rotation
                pubkey: vec![0x03],
                block_number: 0,
                tx_hash: [0; 32],
                log_index: 2,
            },
        ];
        for (i, e) in events.iter().enumerate() {
            let u = ingest(&mut book, e, i as u128).unwrap();
            assert_eq!(u.signer, BRIDGE_ACTOR_ID);
            assert_eq!(u.signer, UnsignedAction::SIGNER);
        }
    }

    /// Locality: ingesting an event for a different address
    /// preserves the lookup of the original.
    #[test]
    fn other_address_lookup_preserved() {
        let mut book = AddressBook::new();
        let addr1 = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let addr2 = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let e1 = IngestedEvent::RegisteredEcdsa {
            actor: addr1,
            pubkey: vec![0x01],
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let _ = ingest(&mut book, &e1, 0);
        let id1 = book.lookup(&addr1).unwrap();
        let e2 = IngestedEvent::RegisteredEcdsa {
            actor: addr2,
            pubkey: vec![0x02],
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 1,
        };
        let _ = ingest(&mut book, &e2, 1);
        // Originals unchanged after second ingestion.
        assert_eq!(book.lookup(&addr1), Some(id1));
    }

    /// Distinct registrations get distinct ids; rotations do
    /// not.
    #[test]
    fn distinct_registrations_distinct_ids() {
        let mut book = AddressBook::new();
        let addr1 = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let addr2 = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let _ = ingest(
            &mut book,
            &IngestedEvent::RegisteredEcdsa {
                actor: addr1,
                pubkey: vec![0x01],
                block_number: 0,
                tx_hash: [0; 32],
                log_index: 0,
            },
            0,
        );
        let _ = ingest(
            &mut book,
            &IngestedEvent::RegisteredEcdsa {
                actor: addr2,
                pubkey: vec![0x02],
                block_number: 0,
                tx_hash: [0; 32],
                log_index: 1,
            },
            1,
        );
        let id1 = book.lookup(&addr1).unwrap();
        let id2 = book.lookup(&addr2).unwrap();
        assert_ne!(id1, id2);
    }

    /// The translation function honours the `current_nonce`
    /// passed in.
    #[test]
    fn nonce_passes_through() {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let event = IngestedEvent::RegisteredEcdsa {
            actor: addr,
            pubkey: vec![0x01],
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let u = ingest(&mut book, &event, 42).unwrap();
        assert_eq!(u.nonce, 42);
    }

    /// `preview_ingest` does NOT mutate the address book on a
    /// first-time registration.  This is the load-bearing
    /// property that fixes the state-corruption bug where a
    /// failed submission left the book half-mutated.
    #[test]
    fn preview_ingest_does_not_mutate_book() {
        use super::{preview_ingest, Translated};
        let book = AddressBook::new();
        let initial_next = book.next_actor_id();
        let initial_len = book.len();
        let actor = EthAddress::from_bytes(&[7u8; 20]).unwrap();
        let event = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0xab, 0xcd],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        let result = preview_ingest(&book, &event, 0);
        // Verify the preview reports the "would-be" assignment.
        match result {
            Translated::EmitWithAssignment {
                action: _,
                address: previewed_addr,
                new_actor_id,
            } => {
                assert_eq!(previewed_addr, actor);
                assert_eq!(new_actor_id, initial_next);
            }
            other => panic!("expected EmitWithAssignment, got {other:?}"),
        }
        // The book MUST be unchanged.
        assert_eq!(book.next_actor_id(), initial_next);
        assert_eq!(book.len(), initial_len);
        assert!(book.lookup(&actor).is_none());
    }

    /// `preview_ingest` followed by `commit_assignment`
    /// materialises the assignment.
    #[test]
    fn preview_then_commit_materialises_assignment() {
        use super::{commit_assignment, preview_ingest, Translated};
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[7u8; 20]).unwrap();
        let event = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0xab],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        if let Translated::EmitWithAssignment {
            address,
            new_actor_id,
            ..
        } = preview_ingest(&book, &event, 0)
        {
            let committed = commit_assignment(&mut book, &address, new_actor_id).unwrap();
            assert_eq!(committed, new_actor_id);
            assert_eq!(book.lookup(&actor), Some(new_actor_id));
        } else {
            panic!("expected EmitWithAssignment");
        }
    }

    /// REGRESSION: a previewed-but-not-committed assignment
    /// allows a retry to re-emit `RegisterIdentity` (rather than
    /// silently switching to `ReplaceKey`).  This is the
    /// behaviour the watcher relies on when a submission fails.
    #[test]
    fn preview_without_commit_allows_register_retry() {
        use super::{preview_ingest, Translated};
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[7u8; 20]).unwrap();
        let event = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0xab],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        // First preview: emits RegisterIdentity.
        match preview_ingest(&book, &event, 0) {
            Translated::EmitWithAssignment { action, .. } => match action.action {
                Action::RegisterIdentity { .. } => {}
                other => panic!("expected RegisterIdentity, got {other:?}"),
            },
            other => panic!("expected EmitWithAssignment, got {other:?}"),
        }
        // (Submission fails — no commit_assignment call.)
        // Second preview: must STILL emit RegisterIdentity (not
        // ReplaceKey), because the book is unchanged.
        match preview_ingest(&book, &event, 0) {
            Translated::EmitWithAssignment { action, .. } => match action.action {
                Action::RegisterIdentity { .. } => {}
                other => panic!(
                    "REGRESSION: retry emitted {other:?} instead of RegisterIdentity \
                     after a failed first attempt — this is the order-of-operations \
                     bug that motivated the preview_ingest API"
                ),
            },
            other => panic!("expected EmitWithAssignment, got {other:?}"),
        }
        // Sanity: the book is empty.
        assert!(book.is_empty());
        // Now actually commit the second preview.
        if let Translated::EmitWithAssignment {
            address,
            new_actor_id,
            ..
        } = preview_ingest(&book, &event, 0)
        {
            super::commit_assignment(&mut book, &address, new_actor_id).unwrap();
        }
        // A subsequent preview (with the book now mutated)
        // emits ReplaceKey.
        match preview_ingest(&book, &event, 0) {
            Translated::Emit(action) => match action.action {
                Action::ReplaceKey { .. } => {}
                other => panic!("expected ReplaceKey after commit, got {other:?}"),
            },
            other => panic!("expected Emit, got {other:?}"),
        }
    }

    /// Rotation through `preview_ingest` emits `Translated::Emit`
    /// (no pending assignment) and never an `EmitWithAssignment`.
    #[test]
    fn preview_rotation_does_not_emit_assignment() {
        use super::{commit_assignment, preview_ingest, Translated};
        let mut book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[7u8; 20]).unwrap();
        // Set up: assign actor first via preview+commit.
        let event1 = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0xab],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        if let Translated::EmitWithAssignment {
            address,
            new_actor_id,
            ..
        } = preview_ingest(&book, &event1, 0)
        {
            commit_assignment(&mut book, &address, new_actor_id).unwrap();
        }
        // Now retry the same address with a different pubkey.
        let event2 = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0xcd, 0xef],
            block_number: 2,
            tx_hash: [0; 32],
            log_index: 0,
        };
        match preview_ingest(&book, &event2, 1) {
            Translated::Emit(action) => match action.action {
                Action::ReplaceKey { .. } => {}
                other => panic!("expected ReplaceKey, got {other:?}"),
            },
            other => panic!("expected Emit (not EmitWithAssignment), got {other:?}"),
        }
    }

    /// `preview_ingest` on a `Revoked` event returns `NoAction`.
    #[test]
    fn preview_revoked_returns_no_action() {
        use super::{preview_ingest, Translated};
        let book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[7u8; 20]).unwrap();
        let event = IngestedEvent::Revoked {
            actor,
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        assert_eq!(preview_ingest(&book, &event, 0), Translated::NoAction);
    }

    // ---- SB.9 deposit materialisation ----

    use super::{
        amount_from_be_bytes, deposit_id_from_receipt, preview_ingest_materialising, Translated,
    };
    use crate::address_book::GAS_POOL_ACTOR_ID;

    /// A 32-byte big-endian amount holding `v` in the low 16 bytes.
    fn be_amount(v: u128) -> [u8; 32] {
        let mut out = [0u8; 32];
        out[16..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    /// Build a `DepositInitiated` event for `depositor` with the
    /// given content fields and origin metadata.
    fn deposit_event(
        depositor: EthAddress,
        amount: [u8; 32],
        receipt_hash: [u8; 32],
        block_number: u64,
        tx_hash: [u8; 32],
        log_index: u64,
    ) -> IngestedEvent {
        IngestedEvent::DepositInitiated {
            depositor,
            resource_id: 0,
            token: EthAddress::ZERO,
            amount,
            depositor_nonce: 0,
            receipt_hash,
            block_number,
            tx_hash,
            log_index,
        }
    }

    /// The deposit id is the receipt hash's first 8 bytes, big-endian
    /// (pinned against a hand-computed constant).
    #[test]
    fn deposit_id_is_receipt_prefix_big_endian() {
        let mut receipt = [0u8; 32];
        receipt[0..8].copy_from_slice(&[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
        receipt[8] = 0xff; // bytes past the prefix are ignored
        assert_eq!(deposit_id_from_receipt(&receipt), 0x0102_0304_0506_0708);
    }

    /// Round-trip: a `DepositInitiated` for a book-known depositor
    /// materialises a bridge-signed `Action::Deposit` with the exact
    /// event-derived fields.
    #[test]
    fn materialised_eth_deposit_round_trip() {
        let mut book = AddressBook::new();
        let depositor = EthAddress::from_bytes(&[9u8; 20]).unwrap();
        let (recipient_id, _) = book.try_assign(&depositor).unwrap();
        let mut receipt = [0u8; 32];
        receipt[0..8].copy_from_slice(&42u64.to_be_bytes());
        let event = deposit_event(depositor, be_amount(1_000_000), receipt, 5, [0xaa; 32], 2);
        match preview_ingest_materialising(&book, &event, 7).unwrap() {
            Translated::Emit(u) => {
                assert_eq!(u.signer, BRIDGE_ACTOR_ID);
                assert_eq!(u.nonce, 7);
                assert_eq!(
                    u.action,
                    Action::Deposit {
                        r: 0,
                        recipient: recipient_id,
                        amount: Amount::from_u64(1_000_000),
                        deposit_id: 42,
                    }
                );
            }
            other => panic!("expected Emit, got {other:?}"),
        }
    }

    /// Round-trip: a `DepositWithFeeInitiated` materialises
    /// `Action::DepositWithFee` with the seed leg lifted verbatim
    /// and the canonical gas-pool actor as `pool_actor`.
    #[test]
    fn materialised_fee_split_deposit_round_trip() {
        let mut book = AddressBook::new();
        let sender = EthAddress::from_bytes(&[8u8; 20]).unwrap();
        let (recipient_id, _) = book.try_assign(&sender).unwrap();
        let mut receipt = [0u8; 32];
        receipt[0..8].copy_from_slice(&99u64.to_be_bytes());
        let event = IngestedEvent::DepositWithFeeInitiated {
            sender,
            resource_id: 1,
            token: EthAddress::from_bytes(&[0x64; 20]).unwrap(),
            user_amount: be_amount(600),
            pool_amount: be_amount(400),
            amm_seed_amount: be_amount(320),
            budget_grant: 33,
            depositor_nonce: 3,
            receipt_hash: receipt,
            block_number: 6,
            tx_hash: [0xbb; 32],
            log_index: 1,
        };
        match preview_ingest_materialising(&book, &event, 11).unwrap() {
            Translated::Emit(u) => {
                assert_eq!(u.signer, BRIDGE_ACTOR_ID);
                assert_eq!(u.nonce, 11);
                assert_eq!(
                    u.action,
                    Action::DepositWithFee {
                        r: 1,
                        recipient: recipient_id,
                        pool_actor: GAS_POOL_ACTOR_ID,
                        user_amount: Amount::from_u64(600),
                        pool_amount: Amount::from_u64(400),
                        budget_grant: 33,
                        deposit_id: 99,
                        seed_amount: Amount::from_u64(320),
                    }
                );
            }
            other => panic!("expected Emit, got {other:?}"),
        }
    }

    /// An UNREGISTERED depositor is assigned a fresh id via the same
    /// `EmitWithAssignment` path registrations use — the book stays
    /// unmutated until the watcher commits post-submit, and the
    /// deposit is never dropped.
    #[test]
    fn materialised_deposit_unregistered_depositor_assigns_fresh_id() {
        let book = AddressBook::new();
        let depositor = EthAddress::from_bytes(&[0x77; 20]).unwrap();
        let expected_fresh = book.next_actor_id();
        let event = deposit_event(depositor, be_amount(5), [0x11; 32], 1, [0; 32], 0);
        match preview_ingest_materialising(&book, &event, 0).unwrap() {
            Translated::EmitWithAssignment {
                action,
                address,
                new_actor_id,
            } => {
                assert_eq!(address, depositor);
                assert_eq!(new_actor_id, expected_fresh);
                match action.action {
                    Action::Deposit { recipient, .. } => {
                        assert_eq!(recipient, expected_fresh);
                    }
                    other => panic!("expected Deposit, got {other:?}"),
                }
            }
            other => panic!("expected EmitWithAssignment, got {other:?}"),
        }
        // Peek-only: the book is unchanged.
        assert!(book.is_empty());
        assert_eq!(book.next_actor_id(), expected_fresh);
    }

    /// RE-ORG / RESTART STABILITY: the deposit id is derived from the
    /// event's CONTENT (the receipt hash), not its chain position —
    /// the same deposit re-delivered under a different block number,
    /// tx hash and log index materialises a byte-identical action, so
    /// the kernel's `consumed`-set conjunct refuses the replay.
    #[test]
    fn materialised_deposit_id_is_reorg_stable() {
        let mut book = AddressBook::new();
        let depositor = EthAddress::from_bytes(&[9u8; 20]).unwrap();
        book.try_assign(&depositor).unwrap();
        let receipt = [0x5a; 32];
        let before = deposit_event(depositor, be_amount(77), receipt, 10, [0x01; 32], 0);
        let after = deposit_event(depositor, be_amount(77), receipt, 13, [0x02; 32], 4);
        let a = preview_ingest_materialising(&book, &before, 3).unwrap();
        let b = preview_ingest_materialising(&book, &after, 3).unwrap();
        assert_eq!(a, b, "re-orged re-delivery derives an identical action");
    }

    /// OVERFLOW: an amount whose high 16 bytes are non-zero is
    /// REFUSED with the offending field named — never truncated.
    /// A deposit whose amount sits ABOVE the retired `u128` ceiling
    /// now materialises, exactly.
    ///
    /// This case used to assert the opposite: that such an amount was
    /// REFUSED with `MaterialiseError::AmountOverflow`, naming the
    /// offending field.  Refusing was right while the runtime could
    /// not represent the value -- truncating would have been finding
    /// C-3 all over again -- but it meant a legitimate L1 deposit the
    /// kernel admits could not be brought to L2 at all.  Widening
    /// removed the refusal by removing its cause, so the assertion
    /// inverts: the action is BUILT, and it carries the exact value.
    #[test]
    fn materialised_amount_above_the_retired_ceiling_is_carried_exactly() {
        let mut book = AddressBook::new();
        let depositor = EthAddress::from_bytes(&[9u8; 20]).unwrap();
        book.try_assign(&depositor).unwrap();
        let mut over = be_amount(1);
        over[15] = 0x01; // lowest bit of the high half -> 2^128 + 1
        let expected = Amount::from_be_bytes(over);
        assert_eq!(expected.to_u128(), None, "the probe is out of u128 range");

        let event = deposit_event(depositor, over, [0; 32], 1, [0; 32], 0);
        let translated = preview_ingest_materialising(&book, &event, 0)
            .expect("an amount past the retired ceiling must materialise");
        let action = match translated {
            Translated::Emit(u) => u.action,
            Translated::EmitWithAssignment { action, .. } => action.action,
            Translated::NoAction => panic!("expected a materialised deposit, got NoAction"),
        };
        match action {
            crate::action::Action::Deposit { amount, .. } => {
                assert_eq!(amount, expected, "the amount must survive intact");
            }
            other => panic!("expected a Deposit action, got {other:?}"),
        }
    }

    /// BOUNDARY: exactly `u128::MAX` (high half zero, low half all
    /// 0xff) converts losslessly.
    #[test]
    fn materialised_amount_u128_max_passes() {
        assert_eq!(
            amount_from_be_bytes(&be_amount(u128::MAX), "t"),
            Amount::from_u128(u128::MAX)
        );
    }

    /// The materialising preview DELEGATES non-deposit events to the
    /// plain Lean-mirror `preview_ingest` unchanged.
    #[test]
    fn materialising_preview_delegates_non_deposit_events() {
        use super::preview_ingest;
        let book = AddressBook::new();
        let actor = EthAddress::from_bytes(&[4u8; 20]).unwrap();
        let registration = IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey: vec![0x02, 0xab],
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 0,
        };
        assert_eq!(
            preview_ingest_materialising(&book, &registration, 5).unwrap(),
            preview_ingest(&book, &registration, 5)
        );
        let revoked = IngestedEvent::Revoked {
            actor,
            block_number: 1,
            tx_hash: [0; 32],
            log_index: 1,
        };
        assert_eq!(
            preview_ingest_materialising(&book, &revoked, 5).unwrap(),
            Translated::NoAction
        );
    }
}
