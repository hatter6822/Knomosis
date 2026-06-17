// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.2 event decode → JSON: render a CBE event payload to the §6.2 /
//! §11A.5 `Event` contract shape.
//!
//! **Classification (additive-extension policy, §11.1).**
//!   * A **known** tag (`0..=22`) is decoded (`knomosis_indexer::decoder`)
//!     and rendered to typed JSON.  A decode *failure* on a known tag is a
//!     corruption signal and **fails closed** ([`DecodeError::Corrupt`]) —
//!     never silently skipped, never mislabelled (§2 principle 7).
//!   * An **unknown** tag (`≥23`, a future constructor) is forwarded
//!     verbatim as `type:"unknown"` + base64 `raw` — never rejected.
//!   * An **unparseable** head fails closed ([`DecodeError::Unparseable`]).
//!
//! **§6.2 value rules.**  Big integers (amounts, budget units, nonces) and
//! ids render as **decimal strings**; byte fields (keys, policies, commit
//! hashes, the L1 address) as **`0x`-hex**; a verdict `outcome` as its
//! **name**.  Payload keys are the lowerCamelCase of the event's fields;
//! the top-level `actor` / `resource` denormalise the event's subject for
//! filtering (null when it has none).

use serde::Serialize;
use serde_json::{json, Value};

use knomosis_event_subscribe::event_type::EventClass;
use knomosis_indexer::decoder::decode_event;
use knomosis_indexer::event::Event;

use crate::submit::base64;

/// The §6.2 `Event` JSON envelope.
#[derive(Clone, Debug, Serialize)]
pub struct EventJson {
    /// The event's log sequence number (decimal string).
    pub seq: String,
    /// 0-based position within the `seq` group.
    pub index: u32,
    /// The event-type name (§11A.5 registry), or `"unknown"`.
    #[serde(rename = "type")]
    pub event_type: String,
    /// The subject actor, if the event has one (decimal string).
    pub actor: Option<String>,
    /// The subject resource, if the event has one (decimal string).
    pub resource: Option<String>,
    /// The event-type-specific fields.
    pub payload: Value,
}

/// Errors rendering an event to JSON.  A decode failure on a **known** tag
/// is corruption and fails closed; the consumer drops the SSE stream with
/// a `decode_error` event / fails the REST page with a problem.
#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    /// A known-tag payload could not be decoded (truncated / over-long /
    /// malformed) — a corruption signal.
    #[error("event decode failed (tag {tag}): {reason}")]
    Corrupt {
        /// The known tag whose payload failed to decode.
        tag: u64,
        /// The decoder's diagnostic.
        reason: String,
    },
    /// The event head itself could not be parsed.
    #[error("event head unparseable: {reason}")]
    Unparseable {
        /// The head-parse diagnostic.
        reason: String,
    },
}

/// Render an event `payload` to its §6.2 JSON envelope at `(seq, index)`.
///
/// # Errors
///
/// [`DecodeError::Corrupt`] when a recognised tag's payload fails to
/// decode (fail closed); [`DecodeError::Unparseable`] when the head itself
/// cannot be parsed.  An unknown (future) tag is **not** an error — it is
/// forwarded as `type:"unknown"`.
pub fn render_event(payload: &[u8], seq: u64, index: u32) -> Result<EventJson, DecodeError> {
    match EventClass::classify(payload) {
        EventClass::Known(event_type) => {
            let event = decode_event(payload).map_err(|e| DecodeError::Corrupt {
                tag: event_type.tag(),
                reason: e.to_string(),
            })?;
            let rendered = render_known(&event);
            Ok(EventJson {
                seq: seq.to_string(),
                index,
                event_type: event_type.name().to_string(),
                actor: rendered.actor,
                resource: rendered.resource,
                payload: rendered.payload,
            })
        }
        EventClass::Unknown { tag } => Ok(EventJson {
            seq: seq.to_string(),
            index,
            event_type: "unknown".to_string(),
            actor: None,
            resource: None,
            payload: json!({ "tag": tag.to_string(), "raw": base64::encode(payload) }),
        }),
        EventClass::Unparseable(err) => Err(DecodeError::Unparseable {
            reason: err.to_string(),
        }),
    }
}

/// A rendered known event: its subject `actor` / `resource` (for the
/// top-level filter fields) and its typed `payload`.
struct Rendered {
    actor: Option<String>,
    resource: Option<String>,
    payload: Value,
}

/// `0x`-hex encode a byte field (§6.2).
fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    for b in bytes {
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// The verdict-outcome name (§6.2 "outcome name").
fn outcome_name(tag: u64) -> &'static str {
    match tag {
        0 => "upheld",
        1 => "rejected",
        2 => "inconclusive",
        _ => "unknown",
    }
}

/// Render a decoded [`Event`] to its §6.2 payload + subject fields.
#[allow(clippy::too_many_lines)] // a flat 23-arm render table; splitting hurts readability
fn render_known(event: &Event) -> Rendered {
    match *event {
        Event::BalanceChanged {
            resource,
            actor,
            old_value,
            new_value,
        } => Rendered {
            actor: Some(actor.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "actor": actor.to_string(),
                "oldValue": old_value.to_string(),
                "newValue": new_value.to_string(),
            }),
        },
        Event::NonceAdvanced {
            actor,
            old_nonce,
            new_nonce,
        } => Rendered {
            actor: Some(actor.to_string()),
            resource: None,
            payload: json!({
                "actor": actor.to_string(),
                "oldNonce": old_nonce.to_string(),
                "newNonce": new_nonce.to_string(),
            }),
        },
        Event::IdentityRegistered { actor, ref key } => Rendered {
            actor: Some(actor.to_string()),
            resource: None,
            payload: json!({ "actor": actor.to_string(), "key": hex(key) }),
        },
        // Both revocations carry only their subject actor, so the §6.2
        // payload shape is identical (the `type` discriminant — set by
        // the caller from `event_type.name()` — keeps them distinct on
        // the wire).
        Event::IdentityRevoked { actor } | Event::LocalPolicyRevoked { actor } => Rendered {
            actor: Some(actor.to_string()),
            resource: None,
            payload: json!({ "actor": actor.to_string() }),
        },
        Event::TimeRecorded { time } => Rendered {
            actor: None,
            resource: None,
            payload: json!({ "time": time.to_string() }),
        },
        Event::DisputeFiled {
            challenger,
            target_idx,
        } => Rendered {
            actor: None,
            resource: None,
            payload: json!({
                "challenger": challenger.to_string(),
                "targetIdx": target_idx.to_string(),
            }),
        },
        Event::DisputeWithdrawn { dispute_idx } => Rendered {
            actor: None,
            resource: None,
            payload: json!({ "disputeIdx": dispute_idx.to_string() }),
        },
        Event::VerdictApplied {
            dispute_idx,
            outcome_tag,
        } => Rendered {
            actor: None,
            resource: None,
            payload: json!({
                "disputeIdx": dispute_idx.to_string(),
                "outcome": outcome_name(outcome_tag),
            }),
        },
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        } => Rendered {
            actor: Some(recipient.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "recipient": recipient.to_string(),
                "amount": amount.to_string(),
            }),
        },
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            ref recipient_l1,
            withdrawal_id,
        } => Rendered {
            actor: Some(sender.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "sender": sender.to_string(),
                "amount": amount.to_string(),
                "recipientL1": hex(recipient_l1),
                "withdrawalId": withdrawal_id.to_string(),
            }),
        },
        Event::DepositCredited {
            resource,
            recipient,
            amount,
            deposit_id,
        } => Rendered {
            actor: Some(recipient.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "recipient": recipient.to_string(),
                "amount": amount.to_string(),
                "depositId": deposit_id.to_string(),
            }),
        },
        Event::LocalPolicyDeclared { actor, ref policy } => Rendered {
            actor: Some(actor.to_string()),
            resource: None,
            payload: json!({ "actor": actor.to_string(), "policy": hex(policy) }),
        },
        Event::FaultProofGameOpened {
            game_id,
            challenger,
            disputed_start_idx,
            disputed_end_idx,
            ref binding_hash,
        } => Rendered {
            actor: None,
            resource: None,
            payload: json!({
                "gameId": game_id.to_string(),
                "challenger": challenger.to_string(),
                "disputedStartIdx": disputed_start_idx.to_string(),
                "disputedEndIdx": disputed_end_idx.to_string(),
                "bindingHash": hex(binding_hash),
            }),
        },
        Event::FaultProofBisectionStep {
            game_id,
            round,
            party,
            idx,
            ref commit,
        } => Rendered {
            actor: None,
            resource: None,
            payload: json!({
                "gameId": game_id.to_string(),
                "round": round.to_string(),
                "party": party.to_string(),
                "idx": idx.to_string(),
                "commit": hex(commit),
            }),
        },
        Event::FaultProofGameSettled {
            game_id,
            winner,
            loser,
            payout,
        } => Rendered {
            actor: None,
            resource: None,
            payload: json!({
                "gameId": game_id.to_string(),
                "winner": winner.to_string(),
                "loser": loser.to_string(),
                "payout": payout.to_string(),
            }),
        },
        Event::DepositWithFeeCredited {
            resource,
            recipient,
            pool_actor,
            user_amount,
            pool_amount,
            budget_grant,
            deposit_id,
        } => Rendered {
            actor: Some(recipient.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "recipient": recipient.to_string(),
                "poolActor": pool_actor.to_string(),
                "userAmount": user_amount.to_string(),
                "poolAmount": pool_amount.to_string(),
                "budgetGrant": budget_grant.to_string(),
                "depositId": deposit_id.to_string(),
            }),
        },
        Event::ActionBudgetTopUp {
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => Rendered {
            actor: Some(signer.to_string()),
            resource: None,
            payload: json!({
                "signer": signer.to_string(),
                "gasResource": gas_resource.to_string(),
                "gasAmount": gas_amount.to_string(),
                "budgetIncrement": budget_increment.to_string(),
                "poolActor": pool_actor.to_string(),
            }),
        },
        Event::GasPoolClaim {
            resource,
            sequencer,
            amount,
        } => Rendered {
            actor: Some(sequencer.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "sequencer": sequencer.to_string(),
                "amount": amount.to_string(),
            }),
        },
        Event::DelegatedActionBudgetTopUp {
            recipient,
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => Rendered {
            actor: Some(recipient.to_string()),
            resource: None,
            payload: json!({
                "recipient": recipient.to_string(),
                "signer": signer.to_string(),
                "gasResource": gas_resource.to_string(),
                "gasAmount": gas_amount.to_string(),
                "budgetIncrement": budget_increment.to_string(),
                "poolActor": pool_actor.to_string(),
            }),
        },
        Event::BudgetConsumed { actor, amount } => Rendered {
            actor: Some(actor.to_string()),
            resource: None,
            payload: json!({ "actor": actor.to_string(), "amount": amount.to_string() }),
        },
        Event::AmmSwapExecuted {
            from_resource,
            to_resource,
            amount_in,
            amount_out,
            amm_reserve_actor,
        } => Rendered {
            actor: Some(amm_reserve_actor.to_string()),
            resource: None,
            payload: json!({
                "fromResource": from_resource.to_string(),
                "toResource": to_resource.to_string(),
                "amountIn": amount_in.to_string(),
                "amountOut": amount_out.to_string(),
                "ammReserveActor": amm_reserve_actor.to_string(),
            }),
        },
        Event::AmmReservesReclaimed {
            resource,
            amount,
            reserve_actor,
            pool_actor,
        } => Rendered {
            actor: Some(pool_actor.to_string()),
            resource: Some(resource.to_string()),
            payload: json!({
                "resource": resource.to_string(),
                "amount": amount.to_string(),
                "reserveActor": reserve_actor.to_string(),
                "poolActor": pool_actor.to_string(),
            }),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{render_event, DecodeError, EventJson};
    use knomosis_event_subscribe::event_type::ALL_EVENT_TYPES;
    use knomosis_indexer::decoder::encode_event;
    use knomosis_indexer::event::Event;
    use serde_json::{json, Value};

    /// Encode an `Event`, render the bytes, and return the JSON value.
    fn render(event: &Event) -> EventJson {
        let bytes = encode_event(event);
        render_event(&bytes, 104_233, 0).expect("renders")
    }

    #[test]
    fn balance_changed_matches_the_contract_example() {
        let json = render(&Event::BalanceChanged {
            resource: 0,
            actor: 161,
            old_value: 1000,
            new_value: 950,
        });
        assert_eq!(json.seq, "104233");
        assert_eq!(json.index, 0);
        assert_eq!(json.event_type, "balanceChanged");
        assert_eq!(json.actor.as_deref(), Some("161"));
        assert_eq!(json.resource.as_deref(), Some("0"));
        assert_eq!(json.payload["oldValue"], "1000");
        assert_eq!(json.payload["newValue"], "950");
        assert_eq!(json.payload["resource"], "0");
        assert_eq!(json.payload["actor"], "161");
    }

    #[test]
    fn bigints_render_as_decimal_strings() {
        // Amounts are bounded `< 2^64` by the encoder's `fieldsBounded`
        // predicate (the field head is an 8-byte LE value), but a value
        // beyond JS's 2^53 safe-integer ceiling must still render
        // losslessly — which is precisely why §6.2 mandates a decimal
        // *string* (a JSON number would round-trip imprecisely in a
        // browser).
        let big: u128 = u128::from(u64::MAX); // 18_446_744_073_709_551_615
        assert!(big > (1u128 << 53), "exercises a beyond-2^53 magnitude");
        let json = render(&Event::RewardIssued {
            resource: 1,
            recipient: 7,
            amount: big,
        });
        assert_eq!(json.payload["amount"], big.to_string());
        assert!(
            json.payload["amount"].is_string(),
            "a decimal STRING, never a lossy JSON number"
        );
        assert_eq!(json.actor.as_deref(), Some("7"));
        assert_eq!(json.resource.as_deref(), Some("1"));
    }

    #[test]
    fn byte_fields_render_as_0x_hex() {
        let json = render(&Event::IdentityRegistered {
            actor: 3,
            key: vec![0xde, 0xad, 0xbe, 0xef],
        });
        assert_eq!(json.payload["key"], "0xdeadbeef");
        // The 20-byte L1 address also renders as 0x-hex.
        let json = render(&Event::WithdrawalRequested {
            resource: 0,
            sender: 9,
            amount: 100,
            recipient_l1: [0xAB; 20],
            withdrawal_id: 4,
        });
        assert_eq!(
            json.payload["recipientL1"],
            format!("0x{}", "ab".repeat(20))
        );
        assert_eq!(json.payload["withdrawalId"], "4");
    }

    #[test]
    fn verdict_outcome_renders_as_a_name() {
        for (tag, name) in [(0u64, "upheld"), (1, "rejected"), (2, "inconclusive")] {
            let json = render(&Event::VerdictApplied {
                dispute_idx: 5,
                outcome_tag: tag,
            });
            assert_eq!(json.payload["outcome"], name);
            assert_eq!(json.payload["disputeIdx"], "5");
        }
    }

    #[test]
    fn every_known_tag_renders_with_its_registry_name() {
        // A representative value per tag, asserting each renders without
        // error and carries the registry type name.  Constructed by
        // round-tripping a default-ish event through the real encoder.
        let samples: Vec<Event> = sample_events();
        assert_eq!(samples.len(), ALL_EVENT_TYPES.len(), "one sample per tag");
        for (event, ty) in samples.iter().zip(ALL_EVENT_TYPES) {
            let json = render(event);
            assert_eq!(json.event_type, ty.name(), "tag {}", ty.tag());
            assert!(json.payload.is_object());
        }
    }

    /// Golden §6.2 pin: every event tag renders to its **exact** contract
    /// envelope — the denormalised `actor` / `resource` subject *and* the
    /// full typed `payload` (key names + value formats: bigints/ids as
    /// decimal strings, byte fields as `0x`-hex, a verdict outcome as a
    /// name).  This is the complete BFF-contract regression guard the
    /// per-field tests above only sample: a `render_known` refactor that
    /// dropped, renamed, or mistyped a payload field for **any** tag fails
    /// here.  (The type name is cross-checked against the §11A.5 registry,
    /// so it need not be re-transcribed.)
    ///
    /// NOTE: the bytes come from the Rust `encode_event` (the canonical CBE
    /// format by convention — see `knomosis-indexer::decoder`).  The true
    /// cross-stack pin against `knomosis extract-events` output (plan G3.2c)
    /// remains blocked on the Lean side shipping an `Encodable Event`
    /// instance, which is deferred (RH-D.2); this pin closes the
    /// gateway-side §6.2 shape guarantee in the meantime.
    #[test]
    fn every_tag_pins_the_full_v62_envelope() {
        let samples = sample_events();
        let expected = expected_envelopes();
        assert_eq!(
            samples.len(),
            expected.len(),
            "one expected envelope per tag"
        );
        assert_eq!(samples.len(), ALL_EVENT_TYPES.len(), "one sample per tag");
        for ((event, ty), (actor, resource, payload)) in
            samples.iter().zip(ALL_EVENT_TYPES).zip(expected)
        {
            let json = render(event);
            assert_eq!(json.event_type, ty.name(), "tag {} type", ty.tag());
            assert_eq!(json.actor.as_deref(), actor, "tag {} actor", ty.tag());
            assert_eq!(
                json.resource.as_deref(),
                resource,
                "tag {} resource",
                ty.tag()
            );
            assert_eq!(json.payload, payload, "tag {} payload", ty.tag());
        }
    }

    /// The expected §6.2 `(actor, resource, payload)` for each tag, in tag
    /// order — paired one-to-one with [`sample_events`].  Transcribed from
    /// the contract, *independent* of `render_known`, so the two cannot
    /// drift together.
    #[allow(clippy::too_many_lines)] // a flat 23-entry golden table; splitting hurts the pin
    fn expected_envelopes() -> Vec<(Option<&'static str>, Option<&'static str>, Value)> {
        let l1 = format!("0x{}", "01".repeat(20));
        vec![
            (
                Some("1"),
                Some("0"),
                json!({"resource":"0","actor":"1","oldValue":"1","newValue":"2"}),
            ),
            (
                Some("1"),
                None,
                json!({"actor":"1","oldNonce":"0","newNonce":"1"}),
            ),
            (Some("1"), None, json!({"actor":"1","key":"0x010203"})),
            (Some("1"), None, json!({"actor":"1"})),
            (None, None, json!({"time":"99"})),
            (None, None, json!({"challenger":"1","targetIdx":"2"})),
            (None, None, json!({"disputeIdx":"2"})),
            (None, None, json!({"disputeIdx":"2","outcome":"upheld"})),
            (
                Some("1"),
                Some("0"),
                json!({"resource":"0","recipient":"1","amount":"5"}),
            ),
            (
                Some("1"),
                Some("0"),
                json!({"resource":"0","sender":"1","amount":"5","recipientL1":l1,"withdrawalId":"1"}),
            ),
            (
                Some("1"),
                Some("0"),
                json!({"resource":"0","recipient":"1","amount":"5","depositId":"1"}),
            ),
            (Some("1"), None, json!({"actor":"1","policy":"0x09"})),
            (Some("1"), None, json!({"actor":"1"})),
            (
                None,
                None,
                json!({"gameId":"1","challenger":"2","disputedStartIdx":"3","disputedEndIdx":"4","bindingHash":"0x0707"}),
            ),
            (
                None,
                None,
                json!({"gameId":"1","round":"2","party":"3","idx":"4","commit":"0x0808"}),
            ),
            (
                None,
                None,
                json!({"gameId":"1","winner":"2","loser":"3","payout":"4"}),
            ),
            (
                Some("1"),
                Some("0"),
                json!({"resource":"0","recipient":"1","poolActor":"2","userAmount":"5","poolAmount":"1","budgetGrant":"3","depositId":"1"}),
            ),
            (
                Some("1"),
                None,
                json!({"signer":"1","gasResource":"0","gasAmount":"5","budgetIncrement":"3","poolActor":"2"}),
            ),
            (
                Some("1"),
                Some("0"),
                json!({"resource":"0","sequencer":"1","amount":"5"}),
            ),
            (
                Some("1"),
                None,
                json!({"recipient":"1","signer":"2","gasResource":"0","gasAmount":"5","budgetIncrement":"3","poolActor":"4"}),
            ),
            (Some("1"), None, json!({"actor":"1","amount":"5"})),
            (
                Some("2"),
                None,
                json!({"fromResource":"0","toResource":"1","amountIn":"5","amountOut":"4","ammReserveActor":"2"}),
            ),
            (
                Some("3"),
                Some("0"),
                json!({"resource":"0","amount":"5","reserveActor":"2","poolActor":"3"}),
            ),
        ]
    }

    #[test]
    fn unknown_tag_is_forwarded_as_base64_raw() {
        // A well-formed 9-byte CBE uint head (the 0x00 marker byte + an
        // 8-byte little-endian tag) carrying a future tag (99 ≥ 23)
        // classifies Unknown → forwarded verbatim, never rejected.
        let mut payload = vec![0x00];
        payload.extend_from_slice(&99u64.to_le_bytes());
        let json = render_event(&payload, 7, 2).expect("forwards unknown");
        assert_eq!(json.event_type, "unknown");
        assert_eq!(json.payload["tag"], "99");
        assert_eq!(json.payload["raw"], crate::submit::base64::encode(&payload));
        assert!(json.actor.is_none());
        assert!(json.resource.is_none());
    }

    #[test]
    fn corrupt_known_tag_fails_closed() {
        // A valid 9-byte head for tag 0 (balanceChanged) with NO field
        // bytes following: a decode failure on a KNOWN tag is corruption,
        // never silently skipped or mislabelled (§2 principle 7).
        let payload = vec![0x00; 9]; // head tag 0, zero-length body
        assert!(matches!(
            render_event(&payload, 1, 0),
            Err(DecodeError::Corrupt { tag: 0, .. })
        ));
    }

    #[test]
    fn empty_payload_is_unparseable() {
        // Too short to even hold a 9-byte head → Unparseable, not Corrupt
        // (we cannot attribute a tag to it).
        assert!(matches!(
            render_event(&[], 1, 0),
            Err(DecodeError::Unparseable { .. })
        ));
    }

    /// One sample event per tag, in tag order.
    #[allow(clippy::too_many_lines)] // a flat 23-entry fixture; splitting hurts readability
    fn sample_events() -> Vec<Event> {
        vec![
            Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 1,
                new_value: 2,
            },
            Event::NonceAdvanced {
                actor: 1,
                old_nonce: 0,
                new_nonce: 1,
            },
            Event::IdentityRegistered {
                actor: 1,
                key: vec![1, 2, 3],
            },
            Event::IdentityRevoked { actor: 1 },
            Event::TimeRecorded { time: 99 },
            Event::DisputeFiled {
                challenger: 1,
                target_idx: 2,
            },
            Event::DisputeWithdrawn { dispute_idx: 2 },
            Event::VerdictApplied {
                dispute_idx: 2,
                outcome_tag: 0,
            },
            Event::RewardIssued {
                resource: 0,
                recipient: 1,
                amount: 5,
            },
            Event::WithdrawalRequested {
                resource: 0,
                sender: 1,
                amount: 5,
                recipient_l1: [1; 20],
                withdrawal_id: 1,
            },
            Event::DepositCredited {
                resource: 0,
                recipient: 1,
                amount: 5,
                deposit_id: 1,
            },
            Event::LocalPolicyDeclared {
                actor: 1,
                policy: vec![9],
            },
            Event::LocalPolicyRevoked { actor: 1 },
            Event::FaultProofGameOpened {
                game_id: 1,
                challenger: 2,
                disputed_start_idx: 3,
                disputed_end_idx: 4,
                binding_hash: vec![7, 7],
            },
            Event::FaultProofBisectionStep {
                game_id: 1,
                round: 2,
                party: 3,
                idx: 4,
                commit: vec![8, 8],
            },
            Event::FaultProofGameSettled {
                game_id: 1,
                winner: 2,
                loser: 3,
                payout: 4,
            },
            Event::DepositWithFeeCredited {
                resource: 0,
                recipient: 1,
                pool_actor: 2,
                user_amount: 5,
                pool_amount: 1,
                budget_grant: 3,
                deposit_id: 1,
            },
            Event::ActionBudgetTopUp {
                signer: 1,
                gas_resource: 0,
                gas_amount: 5,
                budget_increment: 3,
                pool_actor: 2,
            },
            Event::GasPoolClaim {
                resource: 0,
                sequencer: 1,
                amount: 5,
            },
            Event::DelegatedActionBudgetTopUp {
                recipient: 1,
                signer: 2,
                gas_resource: 0,
                gas_amount: 5,
                budget_increment: 3,
                pool_actor: 4,
            },
            Event::BudgetConsumed {
                actor: 1,
                amount: 5,
            },
            Event::AmmSwapExecuted {
                from_resource: 0,
                to_resource: 1,
                amount_in: 5,
                amount_out: 4,
                amm_reserve_actor: 2,
            },
            Event::AmmReservesReclaimed {
                resource: 0,
                amount: 5,
                reserve_actor: 2,
                pool_actor: 3,
            },
        ]
    }
}
