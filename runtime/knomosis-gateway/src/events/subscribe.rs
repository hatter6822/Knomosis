// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.1 resilient event-subscribe upstream client.
//!
//! Wraps `knomosis_indexer::client::SubscribeClient` (which owns the wire
//! framing, §11.3) with the durability the gateway needs to tail the
//! stream indefinitely:
//!
//!   * **Reconnect with backoff.**  A connection drop, server shutdown,
//!     lag-eviction, or staleness timeout transparently reconnects (with
//!     exponential backoff, reset on success) — always **resuming from
//!     the maintained cursor** so no delivered event is re-sent and none
//!     is skipped.
//!   * **No silent gaps (§2 principle 7).**  If the server's history no
//!     longer covers the resume point ([`ServerFrame::Truncated`]),
//!     events were *lost*; the subscription surfaces a
//!     [`StreamItem::Gap`] (it never silently skips) and resumes from the
//!     oldest still-available seq.
//!   * **Staleness watchdog.**  The upstream read has no idle timeout by
//!     default; an optional read timeout bounds how long a *dead* (but
//!     not closed) connection can hang before we reconnect.  A timeout
//!     reconnects rather than continuing a possibly mid-frame stream, so
//!     it can never desync.
//!
//! The cursor (`resume_from`) is the seq of the last **delivered** event;
//! `0` means "start from the live tail" (§11.3).

use std::net::SocketAddr;
use std::time::Duration;

use knomosis_indexer::client::{ClientError, ClientOptions, ServerFrame, SubscribeClient};

/// Lower bound of the reconnect backoff (the first retry delay).
const BACKOFF_BASE: Duration = Duration::from_millis(100);
/// Upper bound of the reconnect backoff.
const BACKOFF_CAP: Duration = Duration::from_secs(5);

/// Why the subscription is (re)connecting — informational, for the
/// consumer's logs / metrics; functionally all are transparently
/// recovered.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReconnectReason {
    /// The connection dropped (clean EOF or an I/O error).
    ConnectionDropped,
    /// The server is shutting down.
    ServerShutdown,
    /// The subscriber fell too far behind and was evicted.
    LagExceeded,
    /// The staleness read timeout fired (a possibly-dead connection).
    StaleTimeout,
    /// A reconnect attempt itself failed to establish a connection.
    ConnectFailed,
    /// The server sent a malformed / oversize / unknown frame.
    ProtocolError,
}

/// One item yielded by [`UpstreamSubscription::recv`].
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StreamItem {
    /// A delivered event — forward it; the resume cursor has advanced to
    /// `seq`.
    Event {
        /// The event's sequence number.
        seq: u64,
        /// The CBE-encoded event payload.
        payload: Vec<u8>,
    },
    /// Events were **lost**: the resume point predated the server's
    /// history.  The consumer MUST surface this (no silent gap); the
    /// subscription resumes from `oldest_available_seq`.
    Gap {
        /// The oldest seq the server still has — where the stream resumes.
        oldest_available_seq: u64,
    },
    /// A recoverable interruption; the subscription will transparently
    /// reconnect from the maintained cursor on the next call.  The
    /// consumer may ignore it or use it to emit a keepalive.
    Reconnecting {
        /// What prompted the reconnect.
        reason: ReconnectReason,
    },
    /// The server rejected the subscription handshake — a **terminal**
    /// error; the consumer should stop.
    Rejected,
}

/// Exponential reconnect backoff (reset on a successful connect).
struct Backoff {
    next: Duration,
}

impl Backoff {
    fn new() -> Self {
        // The first connect attempt is immediate.
        Self {
            next: Duration::ZERO,
        }
    }

    /// The delay to sleep before the next attempt, then grow toward the
    /// cap.
    fn take(&mut self) -> Duration {
        let delay = self.next;
        self.next = if self.next.is_zero() {
            BACKOFF_BASE
        } else {
            (self.next * 2).min(BACKOFF_CAP)
        };
        delay
    }

    fn reset(&mut self) {
        self.next = Duration::ZERO;
    }
}

/// A durable tail of the event-subscribe upstream.
pub struct UpstreamSubscription {
    addr: SocketAddr,
    max_frame_size: usize,
    /// The optional staleness read timeout (`None` = block indefinitely).
    options: ClientOptions,
    /// The current connection, or `None` when (re)connecting.
    client: Option<SubscribeClient>,
    /// The seq of the last delivered event (`0` = live tail) — the resume
    /// cursor every reconnect uses.
    resume_from: u64,
    backoff: Backoff,
}

impl std::fmt::Debug for UpstreamSubscription {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UpstreamSubscription")
            .field("addr", &self.addr)
            .field("resume_from", &self.resume_from)
            .field("connected", &self.client.is_some())
            .finish_non_exhaustive()
    }
}

impl UpstreamSubscription {
    /// A subscription to `addr` starting from `resume_from` (`0` = live
    /// tail), bounding event payloads at `max_frame_size`, with an
    /// optional `stale_timeout` watchdog on the upstream read.
    #[must_use]
    pub fn new(
        addr: SocketAddr,
        resume_from: u64,
        max_frame_size: usize,
        stale_timeout: Option<Duration>,
    ) -> Self {
        Self {
            addr,
            max_frame_size,
            options: ClientOptions {
                read_timeout: stale_timeout,
                ..ClientOptions::default()
            },
            client: None,
            resume_from,
            backoff: Backoff::new(),
        }
    }

    /// The current resume cursor (the last delivered seq).
    #[must_use]
    pub fn resume_from(&self) -> u64 {
        self.resume_from
    }

    /// Read the next [`StreamItem`], (re)connecting transparently as
    /// needed.  **Blocking**: waits for the backoff delay + a frame.  Each
    /// call yields exactly one item, so the consumer drives the loop.
    pub fn recv(&mut self) -> StreamItem {
        // (Re)connect if needed; a failed attempt is itself an item so the
        // consumer keeps control of the loop cadence.
        if self.client.is_none() {
            let delay = self.backoff.take();
            if !delay.is_zero() {
                std::thread::sleep(delay);
            }
            match SubscribeClient::connect_with_options(
                self.addr,
                self.resume_from,
                self.max_frame_size,
                self.options,
            ) {
                Ok(client) => {
                    self.backoff.reset();
                    self.client = Some(client);
                }
                Err(_) => {
                    return StreamItem::Reconnecting {
                        reason: ReconnectReason::ConnectFailed,
                    };
                }
            }
        }

        let client = self.client.as_mut().expect("connected above");
        match client.read_frame() {
            Ok(ServerFrame::Event { seq, payload }) => {
                self.resume_from = seq;
                StreamItem::Event { seq, payload }
            }
            Ok(ServerFrame::Truncated {
                oldest_available_seq,
            }) => {
                // History no longer covers the resume point — events were
                // lost.  Resume from the oldest available so we do not
                // re-request the missing range, and surface the gap.
                self.resume_from = oldest_available_seq;
                self.client = None;
                StreamItem::Gap {
                    oldest_available_seq,
                }
            }
            Ok(ServerFrame::LagExceeded { last_delivered_seq }) => {
                self.resume_from = last_delivered_seq;
                self.client = None;
                StreamItem::Reconnecting {
                    reason: ReconnectReason::LagExceeded,
                }
            }
            Ok(ServerFrame::ServerShutdown { last_delivered_seq }) => {
                self.resume_from = last_delivered_seq;
                self.client = None;
                StreamItem::Reconnecting {
                    reason: ReconnectReason::ServerShutdown,
                }
            }
            Ok(ServerFrame::InvalidRequest) => {
                self.client = None;
                StreamItem::Rejected
            }
            Err(err) => {
                self.client = None;
                StreamItem::Reconnecting {
                    reason: classify_error(&err),
                }
            }
        }
    }
}

/// Classify a [`ClientError`] into a reconnect reason (a read-timeout
/// staleness signal vs a hard connection / protocol failure).
fn classify_error(err: &ClientError) -> ReconnectReason {
    match err {
        ClientError::Io(io) if is_timeout(io) => ReconnectReason::StaleTimeout,
        ClientError::Io(_) | ClientError::Eof | ClientError::Truncated { .. } => {
            ReconnectReason::ConnectionDropped
        }
        ClientError::UnknownKind { .. } | ClientError::OversizeFrame { .. } => {
            ReconnectReason::ProtocolError
        }
    }
}

/// Whether an I/O error is the read-timeout watchdog firing.
fn is_timeout(io: &std::io::Error) -> bool {
    matches!(
        io.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    )
}

#[cfg(test)]
mod tests {
    use super::{ReconnectReason, StreamItem, UpstreamSubscription};
    use knomosis_indexer::client::{
        KIND_EVENT, KIND_INVALID_REQUEST, KIND_LAG_EXCEEDED, KIND_SERVER_SHUTDOWN, KIND_TRUNCATED,
    };
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc};
    use std::thread;
    use std::time::Duration;

    /// One server-frame to script the mock upstream with.
    #[derive(Clone)]
    enum Frame {
        Event {
            seq: u64,
            payload: Vec<u8>,
        },
        LagExceeded(u64),
        Truncated(u64),
        ServerShutdown(u64),
        InvalidRequest,
        /// Close the connection without a frame (a drop).
        Close,
    }

    impl Frame {
        fn encode(&self) -> Vec<u8> {
            match self {
                Frame::Event { seq, payload } => {
                    let mut v = vec![KIND_EVENT];
                    v.extend_from_slice(&seq.to_be_bytes());
                    #[allow(clippy::cast_possible_truncation)]
                    v.extend_from_slice(&(payload.len() as u32).to_be_bytes());
                    v.extend_from_slice(payload);
                    v
                }
                Frame::LagExceeded(s) => one_u64(KIND_LAG_EXCEEDED, *s),
                Frame::Truncated(s) => one_u64(KIND_TRUNCATED, *s),
                Frame::ServerShutdown(s) => one_u64(KIND_SERVER_SHUTDOWN, *s),
                Frame::InvalidRequest => one_u64(KIND_INVALID_REQUEST, 0),
                Frame::Close => Vec::new(),
            }
        }
    }

    fn one_u64(kind: u8, v: u64) -> Vec<u8> {
        let mut out = vec![kind];
        out.extend_from_slice(&v.to_be_bytes());
        out
    }

    /// A mock event-subscribe server: each accepted connection is served
    /// the next scripted batch of frames (reporting the handshake
    /// `resume_from` over `handshakes`), then closed.  It uses a
    /// non-blocking accept loop with a stop flag, so dropping the
    /// [`MockServer`] tears it down cleanly (no accept-loop / join
    /// deadlock when a test makes fewer connections than there are
    /// scripts).
    struct MockServer {
        addr: SocketAddr,
        handshakes: mpsc::Receiver<u64>,
        stop: Arc<AtomicBool>,
        handle: Option<thread::JoinHandle<()>>,
    }

    impl Drop for MockServer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    fn mock_server(scripts: Vec<Vec<Frame>>) -> MockServer {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let halt = Arc::clone(&stop);
        let handle = thread::spawn(move || {
            let mut scripts = scripts.into_iter();
            while !halt.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        // Read the 9-byte handshake (1 tag + 8 BE resume_from).
                        let mut handshake = [0u8; 9];
                        if stream.read_exact(&mut handshake).is_err() {
                            continue;
                        }
                        let resume_from = u64::from_be_bytes(handshake[1..9].try_into().unwrap());
                        let _ = tx.send(resume_from);
                        for frame in scripts.next().unwrap_or_default() {
                            if matches!(frame, Frame::Close) {
                                break;
                            }
                            if stream.write_all(&frame.encode()).is_err() {
                                break;
                            }
                        }
                        // Drop `stream` → the client sees EOF / the terminal frame.
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });
        MockServer {
            addr,
            handshakes: rx,
            stop,
            handle: Some(handle),
        }
    }

    #[test]
    fn delivers_events_and_advances_resume_cursor() {
        let server = mock_server(vec![vec![
            Frame::Event {
                seq: 10,
                payload: b"a".to_vec(),
            },
            Frame::Event {
                seq: 11,
                payload: b"bb".to_vec(),
            },
            Frame::Close,
        ]]);
        let mut sub = UpstreamSubscription::new(server.addr, 0, 1 << 20, None);
        assert_eq!(
            sub.recv(),
            StreamItem::Event {
                seq: 10,
                payload: b"a".to_vec()
            }
        );
        assert_eq!(sub.resume_from(), 10);
        assert_eq!(
            sub.recv(),
            StreamItem::Event {
                seq: 11,
                payload: b"bb".to_vec()
            }
        );
        assert_eq!(sub.resume_from(), 11);
        // The (single) handshake resumed from 0 (live tail).
        assert_eq!(server.handshakes.recv().unwrap(), 0);
    }

    #[test]
    fn reconnects_with_right_resume_from_after_drop() {
        // First connection delivers seq 5 then drops; the wrapper must
        // reconnect resuming from 5.
        let server = mock_server(vec![
            vec![
                Frame::Event {
                    seq: 5,
                    payload: b"x".to_vec(),
                },
                Frame::Close,
            ],
            vec![Frame::Event {
                seq: 6,
                payload: b"y".to_vec(),
            }],
        ]);
        let mut sub = UpstreamSubscription::new(server.addr, 0, 1 << 20, None);
        assert!(matches!(sub.recv(), StreamItem::Event { seq: 5, .. }));
        // The drop surfaces as a transparent reconnect.
        assert_eq!(
            sub.recv(),
            StreamItem::Reconnecting {
                reason: ReconnectReason::ConnectionDropped
            }
        );
        // The next read reconnects + delivers seq 6.
        assert!(matches!(sub.recv(), StreamItem::Event { seq: 6, .. }));
        assert_eq!(server.handshakes.recv().unwrap(), 0); // first connect
        assert_eq!(server.handshakes.recv().unwrap(), 5); // reconnect resumes from 5
    }

    #[test]
    fn lag_and_shutdown_reconnect_from_last_delivered() {
        let server = mock_server(vec![
            vec![Frame::LagExceeded(42)],
            vec![Frame::ServerShutdown(50)],
        ]);
        let mut sub = UpstreamSubscription::new(server.addr, 7, 1 << 20, None);
        assert_eq!(
            sub.recv(),
            StreamItem::Reconnecting {
                reason: ReconnectReason::LagExceeded
            }
        );
        assert_eq!(sub.resume_from(), 42);
        assert_eq!(
            sub.recv(),
            StreamItem::Reconnecting {
                reason: ReconnectReason::ServerShutdown
            }
        );
        // The cursor advanced to the shutdown's last-delivered seq; the
        // *next* reconnect would resume from it.
        assert_eq!(sub.resume_from(), 50);
        assert_eq!(server.handshakes.recv().unwrap(), 7); // initial resume_from
        assert_eq!(server.handshakes.recv().unwrap(), 42); // after lag → 42
    }

    #[test]
    fn truncated_surfaces_a_gap_and_resumes_from_oldest() {
        let server = mock_server(vec![vec![Frame::Truncated(100)]]);
        let mut sub = UpstreamSubscription::new(server.addr, 3, 1 << 20, None);
        assert_eq!(
            sub.recv(),
            StreamItem::Gap {
                oldest_available_seq: 100
            }
        );
        assert_eq!(sub.resume_from(), 100, "resumes from the oldest available");
        assert_eq!(server.handshakes.recv().unwrap(), 3);
    }

    #[test]
    fn invalid_request_is_terminal() {
        let server = mock_server(vec![vec![Frame::InvalidRequest]]);
        let mut sub = UpstreamSubscription::new(server.addr, 0, 1 << 20, None);
        assert_eq!(sub.recv(), StreamItem::Rejected);
    }

    #[test]
    fn connect_failure_is_a_reconnecting_item() {
        // Bind then drop a listener → an address nothing listens on.
        let probe = TcpListener::bind("127.0.0.1:0").unwrap();
        let dead: SocketAddr = probe.local_addr().unwrap();
        drop(probe);
        let mut sub = UpstreamSubscription::new(dead, 0, 1 << 20, Some(Duration::from_millis(50)));
        assert_eq!(
            sub.recv(),
            StreamItem::Reconnecting {
                reason: ReconnectReason::ConnectFailed
            }
        );
    }
}
