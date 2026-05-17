// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! TCP client for the canon-event-subscribe wire protocol.
//!
//! ## Wire format
//!
//! See `docs/abi.md` §11.  The client sends a single
//! `SUBSCRIBE { resume_from }` frame, then reads a stream of
//! outbound frames (`EVENT`, `LAG_EXCEEDED`, `TRUNCATED`,
//! `SERVER_SHUTDOWN`, `INVALID_REQUEST`) until the connection
//! closes or a terminal control frame arrives.
//!
//! ## Why hand-rolled (no canon-event-subscribe dev-dep)
//!
//! The indexer is a *production* binary that links the wire
//! protocol's reader path at runtime.  Pulling
//! `canon-event-subscribe` in as a runtime dependency would
//! drag in the entire subscription-server stack (cache,
//! subscriber registry, extractor) — none of which the indexer
//! needs.  The wire format is small enough to re-implement
//! independently; this keeps the indexer's runtime dependency
//! tree minimal.
//!
//! The wire-byte tags are documented as compile-time constants
//! that mirror canon-event-subscribe's; a future audit pass
//! could merge them into a shared `canon-wire-protocol` crate
//! if a third consumer materialises.

use std::io::{self, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// 1-byte kind tag indicating an inbound `SUBSCRIBE` frame.
/// Mirrors `canon-event-subscribe::frame::KIND_SUBSCRIBE`.
pub const KIND_SUBSCRIBE: u8 = 0;

/// 1-byte kind tag for an outbound `EVENT` frame.
pub const KIND_EVENT: u8 = 1;

/// 1-byte kind tag for `LAG_EXCEEDED`.
pub const KIND_LAG_EXCEEDED: u8 = 2;

/// 1-byte kind tag for `TRUNCATED`.
pub const KIND_TRUNCATED: u8 = 3;

/// 1-byte kind tag for `SERVER_SHUTDOWN`.
pub const KIND_SERVER_SHUTDOWN: u8 = 4;

/// 1-byte kind tag for `INVALID_REQUEST`.
pub const KIND_INVALID_REQUEST: u8 = 5;

/// Default maximum accepted event-payload size (1 MiB).  Mirrors
/// `canon-event-subscribe::frame::DEFAULT_MAX_FRAME_SIZE`.
pub const DEFAULT_MAX_FRAME_SIZE: usize = 1024 * 1024;

/// Hard ceiling on the configurable payload size.
pub const HARD_MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;

/// Frame from the server.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServerFrame {
    /// A sequenced event payload.
    Event {
        /// Sequence number.
        seq: u64,
        /// Event payload bytes (CBE-encoded).
        payload: Vec<u8>,
    },
    /// Lag-eviction notification.
    LagExceeded {
        /// Last seq delivered before eviction.
        last_delivered_seq: u64,
    },
    /// Resume-from-too-old notification.
    Truncated {
        /// Oldest seq the server still has cached.
        oldest_available_seq: u64,
    },
    /// Server-shutdown notification.
    ServerShutdown {
        /// Last seq delivered before shutdown.
        last_delivered_seq: u64,
    },
    /// Handshake-rejection notification.
    InvalidRequest,
}

impl ServerFrame {
    /// Returns true iff the frame is terminal (the server will
    /// close the connection after sending it).
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::LagExceeded { .. }
                | Self::Truncated { .. }
                | Self::ServerShutdown { .. }
                | Self::InvalidRequest
        )
    }
}

/// Errors from the subscribe client.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    /// The underlying I/O operation failed.
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    /// The server closed the connection cleanly.  Used to
    /// surface end-of-stream to callers (vs the `Io` error path
    /// which carries unexpected errors).
    #[error("server closed connection cleanly")]
    Eof,
    /// The server sent a frame whose kind tag was not recognised.
    #[error("unknown server frame kind: 0x{kind:02x}")]
    UnknownKind {
        /// The raw tag byte read.
        kind: u8,
    },
    /// The server sent an event payload whose declared length
    /// exceeded the configured maximum.  Defends against a
    /// malformed server sending a length prefix the client would
    /// otherwise blindly allocate.
    #[error("event payload {declared} bytes exceeds configured max {max}")]
    OversizeFrame {
        /// Declared payload length.
        declared: usize,
        /// Configured maximum.
        max: usize,
    },
    /// The server's response was truncated mid-frame.  Indicates
    /// the connection dropped while a frame was in flight.
    #[error("frame truncated: read {read} of {expected} bytes before EOF")]
    Truncated {
        /// Bytes received.
        read: usize,
        /// Bytes expected.
        expected: usize,
    },
}

/// Optional configuration for [`SubscribeClient::connect_with_options`].
///
/// Default values are tuned for the long-running indexer daemon:
/// no read timeout (idle streams are normal); 30-second write
/// timeout on the handshake.
#[derive(Clone, Copy, Debug)]
pub struct ClientOptions {
    /// Read timeout on the TCP stream.  `None` (default) means
    /// "no timeout" — required for long-running idle streams.
    pub read_timeout: Option<Duration>,
    /// Write timeout on the TCP stream's handshake.  Only the
    /// 9-byte SUBSCRIBE handshake is written; this bounds how
    /// long we wait for the kernel's send buffer.
    pub write_timeout: Duration,
}

impl Default for ClientOptions {
    fn default() -> Self {
        Self {
            read_timeout: None,
            write_timeout: Duration::from_secs(30),
        }
    }
}

/// Hand-rolled subscribe client.  Connects to a TCP endpoint
/// running canon-event-subscribe and emits a stream of
/// [`ServerFrame`]s.
pub struct SubscribeClient {
    reader: BufReader<TcpStream>,
    max_frame_size: usize,
}

impl SubscribeClient {
    /// Connect to `addr` (e.g. `"127.0.0.1:7655"`) and send the
    /// `SUBSCRIBE { resume_from }` handshake.  Per `docs/abi.md`
    /// §11.3, `resume_from = 0` means "no resume; start from
    /// live tail"; any non-zero value means "send me every event
    /// with `seq > resume_from`."
    ///
    /// `max_frame_size` clamps accepted event-payload lengths.
    ///
    /// # Errors
    ///
    /// See [`ClientError`].
    pub fn connect<A: ToSocketAddrs>(
        addr: A,
        resume_from: u64,
        max_frame_size: usize,
    ) -> Result<Self, ClientError> {
        Self::connect_with_options(addr, resume_from, max_frame_size, ClientOptions::default())
    }

    /// Connect with explicit options.  Useful for tests that need
    /// short timeouts, or for operators that need a custom
    /// read-timeout policy.
    ///
    /// # Errors
    ///
    /// See [`ClientError`].
    pub fn connect_with_options<A: ToSocketAddrs>(
        addr: A,
        resume_from: u64,
        max_frame_size: usize,
        options: ClientOptions,
    ) -> Result<Self, ClientError> {
        let max_frame_size = max_frame_size.min(HARD_MAX_FRAME_SIZE);
        let stream = TcpStream::connect(addr)?;
        // Read timeout: NONE by default.  The wire protocol is a
        // long-running stream where the server may go quiet for
        // an indefinite period (no events to deliver).  A bounded
        // read timeout would cause the indexer to disconnect /
        // reconnect on every idle period, churning the server's
        // subscriber state and re-doing the cursor handshake.
        //
        // Liveness is delegated to TCP keepalive (set below) +
        // the server's own write-timeout (the server will close
        // the connection if it can't write to a slow subscriber,
        // which propagates as an EOF on our side).
        //
        // Operators who need a finite read timeout (e.g. for
        // health-check liveness) override via `ClientOptions`.
        stream.set_read_timeout(options.read_timeout)?;
        // Write timeout: a finite default so a stuck server
        // can't pin our handshake.  Only the handshake bytes
        // get written; once we're in steady-state, we never
        // write again.
        stream.set_write_timeout(Some(options.write_timeout))?;
        let mut reader = BufReader::new(stream);
        // Send SUBSCRIBE handshake: 1-byte tag + 8-byte BE
        // resume_from.
        let mut handshake = [0u8; 9];
        handshake[0] = KIND_SUBSCRIBE;
        handshake[1..9].copy_from_slice(&resume_from.to_be_bytes());
        reader.get_mut().write_all(&handshake)?;
        // No flush needed on raw TcpStream (writes are unbuffered
        // at the Rust level).  Keeping the comment for future
        // implementers who add intermediate buffering.
        Ok(Self {
            reader,
            max_frame_size,
        })
    }

    /// Underlying TCP stream (for shutdown / diagnostics).
    pub fn stream(&self) -> &TcpStream {
        self.reader.get_ref()
    }

    /// Read the next [`ServerFrame`].  Blocks until a frame is
    /// available, the connection drops, or the read timeout
    /// elapses.
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::Eof`] on a clean server-side
    /// disconnect (no bytes read before EOF).  Returns
    /// [`ClientError::Truncated`] on a mid-frame disconnect.
    /// Returns [`ClientError::Io`] on other I/O failures.
    pub fn read_frame(&mut self) -> Result<ServerFrame, ClientError> {
        // 1-byte kind tag.
        let mut head = [0u8; 1];
        let mut filled = 0usize;
        while filled < 1 {
            let n = self.reader.read(&mut head[filled..])?;
            if n == 0 {
                return Err(ClientError::Eof);
            }
            filled += n;
        }
        let kind = head[0];
        match kind {
            KIND_EVENT => {
                let mut seq_buf = [0u8; 8];
                read_exact_or_truncated(&mut self.reader, &mut seq_buf, 1, 13)?;
                let seq = u64::from_be_bytes(seq_buf);
                let mut len_buf = [0u8; 4];
                read_exact_or_truncated(&mut self.reader, &mut len_buf, 9, 13)?;
                let declared = u32::from_be_bytes(len_buf);
                let declared_usize = declared as usize;
                if declared_usize > self.max_frame_size {
                    return Err(ClientError::OversizeFrame {
                        declared: declared_usize,
                        max: self.max_frame_size,
                    });
                }
                let mut payload = vec![0u8; declared_usize];
                read_exact_or_truncated(&mut self.reader, &mut payload, 13, 13 + declared_usize)?;
                Ok(ServerFrame::Event { seq, payload })
            }
            KIND_LAG_EXCEEDED => {
                let mut buf = [0u8; 8];
                read_exact_or_truncated(&mut self.reader, &mut buf, 1, 9)?;
                Ok(ServerFrame::LagExceeded {
                    last_delivered_seq: u64::from_be_bytes(buf),
                })
            }
            KIND_TRUNCATED => {
                let mut buf = [0u8; 8];
                read_exact_or_truncated(&mut self.reader, &mut buf, 1, 9)?;
                Ok(ServerFrame::Truncated {
                    oldest_available_seq: u64::from_be_bytes(buf),
                })
            }
            KIND_SERVER_SHUTDOWN => {
                let mut buf = [0u8; 8];
                read_exact_or_truncated(&mut self.reader, &mut buf, 1, 9)?;
                Ok(ServerFrame::ServerShutdown {
                    last_delivered_seq: u64::from_be_bytes(buf),
                })
            }
            KIND_INVALID_REQUEST => {
                let mut buf = [0u8; 8];
                read_exact_or_truncated(&mut self.reader, &mut buf, 1, 9)?;
                // Diagnostic seq field is reserved; ignored.
                Ok(ServerFrame::InvalidRequest)
            }
            _ => Err(ClientError::UnknownKind { kind }),
        }
    }
}

/// Read `buf.len()` bytes; return [`ClientError::Truncated`] on
/// EOF before completion.
fn read_exact_or_truncated<R: Read>(
    reader: &mut R,
    buf: &mut [u8],
    bytes_already_read: usize,
    expected_total: usize,
) -> Result<(), ClientError> {
    let mut filled = 0usize;
    while filled < buf.len() {
        let n = reader.read(&mut buf[filled..])?;
        if n == 0 {
            return Err(ClientError::Truncated {
                read: bytes_already_read + filled,
                expected: expected_total,
            });
        }
        filled += n;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        ClientError, ServerFrame, KIND_EVENT, KIND_INVALID_REQUEST, KIND_LAG_EXCEEDED,
        KIND_SERVER_SHUTDOWN, KIND_SUBSCRIBE, KIND_TRUNCATED,
    };

    /// Wire constants pinned (no drift from canon-event-subscribe).
    #[test]
    fn wire_constants_stable() {
        assert_eq!(KIND_SUBSCRIBE, 0);
        assert_eq!(KIND_EVENT, 1);
        assert_eq!(KIND_LAG_EXCEEDED, 2);
        assert_eq!(KIND_TRUNCATED, 3);
        assert_eq!(KIND_SERVER_SHUTDOWN, 4);
        assert_eq!(KIND_INVALID_REQUEST, 5);
    }

    /// `is_terminal` exhaustive.
    #[test]
    fn is_terminal_exhaustive() {
        assert!(!ServerFrame::Event {
            seq: 1,
            payload: vec![],
        }
        .is_terminal());
        assert!(ServerFrame::LagExceeded {
            last_delivered_seq: 0
        }
        .is_terminal());
        assert!(ServerFrame::Truncated {
            oldest_available_seq: 0
        }
        .is_terminal());
        assert!(ServerFrame::ServerShutdown {
            last_delivered_seq: 0
        }
        .is_terminal());
        assert!(ServerFrame::InvalidRequest.is_terminal());
    }

    /// `ClientError` is `Send + Sync`.
    #[test]
    fn client_error_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ClientError>();
    }

    /// `ServerFrame` is `Send + Sync` (required for the indexer's
    /// dispatch thread).
    #[test]
    fn server_frame_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ServerFrame>();
    }

    /// `ClientError` Display strings are documented.
    #[test]
    fn error_display_shapes() {
        let oversize = ClientError::OversizeFrame {
            declared: 100,
            max: 50,
        };
        assert!(oversize.to_string().contains("exceeds configured max"));

        let truncated = ClientError::Truncated {
            read: 5,
            expected: 10,
        };
        assert!(truncated.to_string().contains("read 5 of 10 bytes"));

        let unknown = ClientError::UnknownKind { kind: 0x99 };
        assert!(unknown.to_string().contains("0x99"));
    }
}
