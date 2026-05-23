// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Daemon-mode event-consumption loop.
//!
//! Extracted into the library (rather than living in `main.rs`)
//! so the partial-batch / two-pass-dispatch behaviour can be
//! unit-tested without standing up a full binary process.
//!
//! ## What this module provides
//!
//!   * [`ConsumeOutcome`] — the terminal state of one consume
//!     loop iteration.  The daemon's outer loop dispatches on
//!     this to decide whether to reconnect, halt, etc.
//!   * [`consume_stream`] — the top-level entry that reads the
//!     first frame and delegates to [`consume_batched`] for
//!     event payloads.
//!   * [`consume_batched`] — multi-event-per-seq batch
//!     accumulator.  Commits a batch only when the next-seq
//!     frame arrives (the canonical "this batch is complete"
//!     signal).  Discards in-flight batches on any other
//!     terminator (EOF / ServerShutdown / LagExceeded /
//!     Truncated / InvalidRequest / protocol violation), so
//!     the server can replay them on reconnect.
//!
//! ## Why partial batches are discarded
//!
//! See [`consume_batched`]'s docstring.

use canon_storage::sqlite::SqliteStorage;

use crate::client::{ClientError, ServerFrame, SubscribeClient};
use crate::decoder::decode_event;
use crate::indexer::{Indexer, IndexerError};

/// Outcome of consuming the server's event stream for one
/// session (one TCP connection).
#[derive(Debug)]
pub enum ConsumeOutcome {
    /// Server closed cleanly without a terminal frame.
    CleanEof,
    /// Server sent `ServerShutdown { last_delivered_seq }`.
    /// The in-flight batch (if any) was discarded.
    ServerShutdown {
        /// Last seq the server reported delivering before
        /// shutdown.  May NOT match the last seq the client
        /// successfully committed (partial batches are
        /// discarded).
        last_seq: u64,
    },
    /// Server sent `LagExceeded { last_delivered_seq }`.  The
    /// in-flight batch was discarded; on reconnect the server
    /// will replay from cursor.
    LagExceeded {
        /// Last seq the server reported delivering.
        last_seq: u64,
    },
    /// Server sent `Truncated { oldest_available_seq }`.  The
    /// cursor is older than the server's keep-history; this is
    /// an operator-actionable failure.
    Truncated {
        /// Oldest seq the server still has cached.
        oldest_seq: u64,
    },
    /// Server sent `InvalidRequest` (handshake mismatch).
    InvalidRequest,
    /// Wire-level error.  In-flight batch was discarded.
    ClientError(ClientError),
    /// Indexer-level error (commit failure, decode failure,
    /// protocol violation).  In-flight batch was discarded.
    IndexerError(IndexerError),
}

/// Consume the server's event stream for one session.  Reads
/// the first frame, then delegates to [`consume_batched`] if it
/// was an event.  Returns when the connection drops or a
/// terminal frame arrives.
pub fn consume_stream(
    indexer: &mut Indexer<'_, SqliteStorage>,
    client: &mut SubscribeClient,
) -> ConsumeOutcome {
    let frame = match client.read_frame() {
        Ok(f) => f,
        Err(ClientError::Eof) => return ConsumeOutcome::CleanEof,
        Err(e) => return ConsumeOutcome::ClientError(e),
    };
    match frame {
        ServerFrame::Event { seq, payload } => {
            // Defensive: per docs/abi.md §11.4, the canonical
            // server emits events with seq ≥ 1.  seq=0 is the
            // wire-protocol's "no resume" sentinel and MUST NOT
            // appear in an EVENT frame.  A buggy or malicious
            // server sending seq=0 is a protocol violation.
            // (knomosis-event-subscribe's EventCache rejects seq=0
            // on push, so a well-behaved server already prevents
            // this; defence-in-depth on the client side.)
            if seq == 0 {
                tracing::error!("server delivered event with reserved seq=0");
                return ConsumeOutcome::IndexerError(IndexerError::ProtocolViolation {
                    current_seq: 0,
                    offending_seq: 0,
                });
            }
            consume_batched(indexer, client, seq, payload)
        }
        ServerFrame::ServerShutdown { last_delivered_seq } => ConsumeOutcome::ServerShutdown {
            last_seq: last_delivered_seq,
        },
        ServerFrame::LagExceeded { last_delivered_seq } => ConsumeOutcome::LagExceeded {
            last_seq: last_delivered_seq,
        },
        ServerFrame::Truncated {
            oldest_available_seq,
        } => ConsumeOutcome::Truncated {
            oldest_seq: oldest_available_seq,
        },
        ServerFrame::InvalidRequest => ConsumeOutcome::InvalidRequest,
    }
}

/// Consume an event batch that begins with `(first_seq,
/// first_payload)`.  Reads ahead one frame at a time; on a
/// seq-change frame (the canonical signal that the previous
/// seq's batch is complete), dispatches the accumulated batch
/// and starts a new one.  On any non-seq-change termination,
/// the in-flight batch is DISCARDED — the server will replay
/// from the committed cursor on the next subscribe.
///
/// ## Why partial batches are discarded
///
/// The wire protocol (`docs/abi.md` §11.4) guarantees that
/// multi-event-per-seq batches are delivered as a contiguous
/// sequence of frames sharing the same seq.  But the wire
/// format has no per-batch terminator — the only signal that
/// "seq N is complete" is the arrival of a frame with seq > N.
///
/// If the connection drops (TCP-level EOF, ServerShutdown,
/// LagExceeded, Truncated, InvalidRequest, or any other error)
/// while we're accumulating seq=N's events, we DO NOT KNOW if
/// we received all of N's events or only some.  Committing
/// a partial batch and advancing the cursor to N would
/// PERMANENTLY LOSE the remaining events: on next subscribe
/// we'd ask for events > N, and the server would skip N's
/// missing tail.
///
/// The safe behaviour is to NEVER commit the in-flight batch
/// on any non-seq-change termination.  The price is a slight
/// redundancy on reconnect (the server replays N's full batch),
/// which the indexer applies idempotently via the
/// [`Indexer::apply_batch`] cursor check.
pub fn consume_batched(
    indexer: &mut Indexer<'_, SqliteStorage>,
    client: &mut SubscribeClient,
    first_seq: u64,
    first_payload: Vec<u8>,
) -> ConsumeOutcome {
    let mut current_seq = first_seq;
    let mut batch = match decode_event(&first_payload) {
        Ok(e) => vec![e],
        Err(e) => {
            // Per audit L-4: log the partial-batch-discard
            // context for the first-frame decode case, matching
            // the EOF/client-error paths below.
            tracing::debug!(
                current_seq,
                in_flight_events = 0_usize,
                error = %e,
                "first-frame decode failed; no batch accumulated, cursor unchanged"
            );
            return ConsumeOutcome::IndexerError(IndexerError::Decode {
                seq: current_seq,
                source: e,
            });
        }
    };
    loop {
        let frame = match client.read_frame() {
            Ok(f) => f,
            Err(ClientError::Eof) => {
                tracing::debug!(
                    current_seq,
                    in_flight_events = batch.len(),
                    "connection EOF mid-batch; discarding in-flight batch (server will replay)"
                );
                return ConsumeOutcome::CleanEof;
            }
            Err(e) => {
                tracing::debug!(
                    current_seq,
                    in_flight_events = batch.len(),
                    error = %e,
                    "client error mid-batch; discarding in-flight batch"
                );
                return ConsumeOutcome::ClientError(e);
            }
        };
        match frame {
            ServerFrame::Event { seq, payload } => match seq.cmp(&current_seq) {
                std::cmp::Ordering::Equal => match decode_event(&payload) {
                    Ok(e) => batch.push(e),
                    Err(e) => {
                        return ConsumeOutcome::IndexerError(IndexerError::Decode {
                            seq,
                            source: e,
                        });
                    }
                },
                std::cmp::Ordering::Greater => {
                    // The previous seq's batch is now known to be
                    // complete (the server has moved on to a new
                    // seq).  Commit it, then start the new batch.
                    if let Err(e) = indexer.apply_batch(current_seq, &batch) {
                        return ConsumeOutcome::IndexerError(e);
                    }
                    current_seq = seq;
                    batch.clear();
                    match decode_event(&payload) {
                        Ok(e) => batch.push(e),
                        Err(e) => {
                            return ConsumeOutcome::IndexerError(IndexerError::Decode {
                                seq,
                                source: e,
                            });
                        }
                    }
                }
                std::cmp::Ordering::Less => {
                    tracing::error!(
                        current_seq,
                        offending_seq = seq,
                        "server delivered out-of-order event"
                    );
                    return ConsumeOutcome::IndexerError(IndexerError::ProtocolViolation {
                        current_seq,
                        offending_seq: seq,
                    });
                }
            },
            ServerFrame::ServerShutdown { last_delivered_seq } => {
                tracing::debug!(
                    current_seq,
                    in_flight_events = batch.len(),
                    "ServerShutdown mid-batch; discarding in-flight batch"
                );
                return ConsumeOutcome::ServerShutdown {
                    last_seq: last_delivered_seq,
                };
            }
            ServerFrame::LagExceeded { last_delivered_seq } => {
                tracing::debug!(
                    current_seq,
                    in_flight_events = batch.len(),
                    "LagExceeded mid-batch; discarding in-flight batch"
                );
                return ConsumeOutcome::LagExceeded {
                    last_seq: last_delivered_seq,
                };
            }
            ServerFrame::Truncated {
                oldest_available_seq,
            } => {
                return ConsumeOutcome::Truncated {
                    oldest_seq: oldest_available_seq,
                };
            }
            ServerFrame::InvalidRequest => return ConsumeOutcome::InvalidRequest,
        }
    }
}
