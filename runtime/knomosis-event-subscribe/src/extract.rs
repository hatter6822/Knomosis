// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Event extraction abstraction.
//!
//! ## What this provides
//!
//! [`Extractor`] is a trait that abstracts "given a log-frame
//! payload, produce the list of CBE-encoded events that
//! `Events.extractEvents` would emit on the Lean side."
//!
//! Two implementations ship with this crate:
//!
//!   * [`mock::MockExtractor`] — in-memory test extractor.
//!     Records every submission and returns a programmable
//!     sequence of event lists.  Used by every test that doesn't
//!     need the actual Lean wire format.
//!   * [`subprocess::SubprocessExtractor`] — spawns the Lean
//!     `knomosis` binary via a future `knomosis extract-events`
//!     subcommand.  This is the load-bearing wire-format
//!     authority: the Lean side defines what an event's CBE
//!     bytes look like, so the production extractor delegates
//!     rather than re-implementing the encoder in Rust.
//!
//! ## Why a trait rather than a concrete type
//!
//! Two reasons:
//!
//!   1. **Testability.**  The subscription server's tests need
//!      to exercise the broadcast / lag-eviction / backfill
//!      logic without depending on a working Lean toolchain.
//!      `MockExtractor` makes this trivial.
//!   2. **Architectural seam.**  RH-D.2 explicitly delegates
//!      event extraction to the Lean side, but the exact
//!      subcommand spec is a future Lean-side PR.  The trait
//!      lets the Rust framework ship today with a working
//!      `MockExtractor` for tests + dev; the production
//!      `SubprocessExtractor` becomes operational the moment
//!      the Lean subcommand lands.
//!
//! ## Wire-format authority delegation
//!
//! Per the plan §RH-D.2:
//!
//! > Decision recorded: delegate event extraction to the Lean
//! > `knomosis` executable rather than reimplement
//! > `Events.extractEvents` in Rust.  Rationale: Lean is the
//! > wire-format authority; a Rust reimplementation would risk
//! > drift.
//!
//! ## Subprocess protocol (preliminary)
//!
//! The wire protocol between this crate and the future
//! `knomosis extract-events` subcommand:
//!
//! **Stdin (per request):**
//! ```text
//! offset  size  field
//! ------  ----  -------------------------------------------------
//!     0    8    sequence number (big-endian u64)
//!     8    4    payload length N (big-endian u32; ≤ HARD_MAX_PAYLOAD)
//!    12    N    CBE-encoded LogEntry payload bytes
//! ```
//!
//! **Stdout (per response):**
//! ```text
//! offset  size  field
//! ------  ----  -------------------------------------------------
//!     0    8    sequence number (big-endian u64; echoed)
//!     8    4    event count K (big-endian u32; ≤ HARD_MAX_EVENT_COUNT)
//!  12+0    P    event 0 (4-byte BE length + payload)
//!  12+P    ...  ...
//! ```
//!
//! Each event payload is a length-prefixed CBE-encoded `Event`
//! (the same byte sequence the wire protocol would put on the
//! socket).  The subprocess does NOT include a per-event
//! framing magic; the only framing is the 4-byte length
//! prefix.

use crate::event_cache::CachedEvent;

/// Hard ceiling on the number of events extracted per log frame.
///
/// Most actions produce a handful of events, but the multi-actor laws
/// `distributeOthers` / `proportionalDilute` emit one
/// `balanceChanged` per AFFECTED actor — bounded only by the
/// resource's balance-map size, which grows with the deployment.  So
/// this is a generous DoS ceiling (a malformed subprocess cannot
/// claim billions), NOT a kernel bound: legitimate large multi-actor
/// batches up to ~1M affected actors stream in a single frame.  A
/// count above this is treated as a subprocess protocol violation.
///
/// (Earlier this was 1024 with a "~10 events per action" rationale —
/// incorrect for the multi-actor laws, GP.6.3 review.)
pub const HARD_MAX_EVENT_COUNT: u32 = 1 << 20;

/// Cap on the up-front `Vec` capacity reserved for an extracted
/// batch.  The declared `count` is validated against
/// [`HARD_MAX_EVENT_COUNT`] first, but a (buggy / mid-crash)
/// subprocess could still declare a large count and then send fewer
/// events; reserving the full count up front would waste memory on
/// such an input.  Reserving a modest amount and letting the `Vec`
/// grow keeps the up-front allocation bounded while the read loop
/// still fails cleanly on a short stream.
const EVENT_BATCH_PREALLOC: usize = 4096;

/// Hard ceiling on the size of a single extracted event payload.
/// Matches the network ABI's `MAX_FRAME_SIZE` so an event whose
/// payload would not fit in the subscriber's outbound frame
/// surfaces as an extraction error instead of being silently
/// truncated.
pub const HARD_MAX_EVENT_PAYLOAD: usize = 1024 * 1024;

/// Errors from any [`Extractor`] implementation.
#[derive(Debug, thiserror::Error)]
pub enum ExtractError {
    /// The underlying I/O operation failed (subprocess pipe,
    /// stdin/stdout drop, etc.).
    #[error("I/O error during event extraction: {0}")]
    Io(#[from] std::io::Error),
    /// The subprocess (or mock) returned a malformed response.
    /// Includes the offending byte offset for diagnostics.
    #[error("malformed extractor response: {reason}")]
    MalformedResponse {
        /// Human-readable description of the violation.
        reason: String,
    },
    /// The subprocess returned a sequence number different from
    /// the one we sent.  Indicates a subprocess bug or a
    /// stuck-pipe ordering problem.
    #[error("extractor sequence mismatch: sent {sent}, got {got}")]
    SequenceMismatch {
        /// Sequence number we wrote on stdin.
        sent: u64,
        /// Sequence number we read on stdout.
        got: u64,
    },
    /// Event count exceeds `HARD_MAX_EVENT_COUNT`.  Defends
    /// against a malformed subprocess producing GB of output.
    #[error("extractor returned {count} events; max is {max}")]
    TooManyEvents {
        /// Event count claimed by the subprocess.
        count: u32,
        /// Configured ceiling.
        max: u32,
    },
    /// Event payload size exceeds `HARD_MAX_EVENT_PAYLOAD`.
    #[error("extracted event payload {payload_len} bytes exceeds max {max}")]
    EventPayloadOversize {
        /// Declared payload length.
        payload_len: u32,
        /// Configured ceiling.
        max: usize,
    },
    /// The subprocess exited unexpectedly.  Subprocess restart
    /// is the caller's responsibility.
    #[error("extractor subprocess unavailable: {reason}")]
    SubprocessUnavailable {
        /// Diagnostic reason.
        reason: String,
    },
}

/// Trait for event extractors.  See module docstring for the
/// architectural rationale.
pub trait Extractor: Send + Sync {
    /// Extract zero or more events from a log-frame payload.
    ///
    /// `seq` is the sequence number assigned by the tail reader;
    /// it's echoed in the diagnostic surface and used to verify
    /// subprocess ordering.
    ///
    /// Returns the list of cached events (each one with the
    /// seq carried over from the input — multiple events per
    /// log frame all share the seq, since the broadcast
    /// protocol delivers them as a single batch).
    ///
    /// # Errors
    ///
    /// See [`ExtractError`].
    fn extract(&self, seq: u64, payload: &[u8]) -> Result<Vec<CachedEvent>, ExtractError>;

    /// Identifier for diagnostics.  E.g. `"mock"` or
    /// `"subprocess[knomosis-extract-events]"`.
    fn identifier(&self) -> &str;
}

/// In-memory mock extractor for tests and dev.
pub mod mock {
    use std::sync::Mutex;

    use crate::event_cache::CachedEvent;

    use super::{ExtractError, Extractor};

    /// Configurable in-memory extractor.
    ///
    /// Default behaviour: returns an empty event list for every
    /// `extract` call.  Tests configure custom response sequences
    /// via [`MockExtractor::set_responses`] (which cycles when
    /// exhausted) or [`MockExtractor::push_response`] (which
    /// queues a single response).
    ///
    /// Records every `(seq, payload)` it was called with;
    /// retrievable via [`MockExtractor::recorded`].
    #[derive(Debug)]
    pub struct MockExtractor {
        inner: Mutex<MockInner>,
    }

    #[derive(Debug, Default)]
    struct MockInner {
        recorded: Vec<(u64, Vec<u8>)>,
        responses: Vec<MockResponse>,
        next_response: usize,
    }

    /// One response the mock returns for one `extract` call.
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub enum MockResponse {
        /// Return this list of event payload bytes for the next
        /// extract call.  Each payload is wrapped into a
        /// `CachedEvent` with the call's seq.
        Ok(Vec<Vec<u8>>),
        /// Return this error for the next extract call.
        Err(MockError),
    }

    /// Errors the mock can be programmed to return.
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub enum MockError {
        /// `ExtractError::MalformedResponse` with the given reason.
        Malformed(String),
        /// `ExtractError::SubprocessUnavailable` with the given reason.
        Unavailable(String),
    }

    impl Default for MockExtractor {
        fn default() -> Self {
            Self {
                inner: Mutex::new(MockInner::default()),
            }
        }
    }

    impl MockExtractor {
        /// Construct a default mock that returns empty event
        /// lists for every call.
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }

        /// Replace the response sequence.  Each `extract` call
        /// returns the next element of `responses`, cycling
        /// when exhausted.  Passing an empty `Vec` reverts to
        /// "always empty event list" behaviour.
        pub fn set_responses(&self, responses: Vec<MockResponse>) {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            inner.responses = responses;
            inner.next_response = 0;
        }

        /// Append a single response to the configured sequence.
        pub fn push_response(&self, response: MockResponse) {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            inner.responses.push(response);
        }

        /// Clone the recorded `(seq, payload)` submissions.
        #[must_use]
        pub fn recorded(&self) -> Vec<(u64, Vec<u8>)> {
            self.inner
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .recorded
                .clone()
        }

        /// Number of recorded submissions.
        #[must_use]
        pub fn call_count(&self) -> usize {
            self.inner
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .recorded
                .len()
        }
    }

    impl Extractor for MockExtractor {
        fn extract(&self, seq: u64, payload: &[u8]) -> Result<Vec<CachedEvent>, ExtractError> {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            inner.recorded.push((seq, payload.to_vec()));
            let response = if inner.responses.is_empty() {
                MockResponse::Ok(Vec::new())
            } else {
                let idx = inner.next_response % inner.responses.len();
                inner.next_response = inner.next_response.wrapping_add(1);
                inner.responses[idx].clone()
            };
            drop(inner);
            match response {
                MockResponse::Ok(payloads) => Ok(payloads
                    .into_iter()
                    .map(|payload| CachedEvent { seq, payload })
                    .collect()),
                MockResponse::Err(MockError::Malformed(reason)) => {
                    Err(ExtractError::MalformedResponse { reason })
                }
                MockResponse::Err(MockError::Unavailable(reason)) => {
                    Err(ExtractError::SubprocessUnavailable { reason })
                }
            }
        }

        fn identifier(&self) -> &str {
            "mock"
        }
    }
}

/// Production subprocess extractor.
pub mod subprocess {
    use std::io::{BufReader, Read, Write};
    use std::path::PathBuf;
    use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
    use std::sync::Mutex;

    use crate::event_cache::CachedEvent;

    use super::{
        ExtractError, Extractor, EVENT_BATCH_PREALLOC, HARD_MAX_EVENT_COUNT, HARD_MAX_EVENT_PAYLOAD,
    };

    /// Subprocess extractor that spawns the Lean `knomosis` binary
    /// in `extract-events` mode.
    ///
    /// ## Lifecycle
    ///
    /// On first `extract` call, spawns the subprocess.  Each
    /// subsequent call writes a request frame to the
    /// subprocess's stdin and reads the response frame from
    /// stdout.  If the subprocess dies (broken pipe, EOF on
    /// stdout, etc.), the next `extract` call respawns it.
    ///
    /// ## stderr handling (C-4 audit fix)
    ///
    /// The subprocess's stderr is redirected to the parent's
    /// stderr via `Stdio::inherit()`.  This avoids the
    /// deadlock that would occur if stderr were `piped()` and
    /// the parent never drained it: once the OS pipe buffer
    /// fills (Linux default ~64 KiB), the subprocess blocks
    /// on stderr writes, the parent blocks on stdout reads,
    /// and the daemon wedges.  Inheriting stderr lets the
    /// subprocess's diagnostics surface in the parent's logs
    /// for operator visibility without buffering risk.
    ///
    /// ## Operational status
    ///
    /// The `knomosis` binary exposes the `extract-events --log LOG`
    /// subcommand (WU GP.6.3; `Main.lean::cmdExtractEvents`), so this
    /// extractor is operational against a production-linked binary.
    /// The dev binary links the Lean-level `Verify` opaque (returns
    /// `false`), so it cannot admit signed frames — a production
    /// deployment must link the real signature verifier (as for
    /// `replay-up-to`).  The subprocess extractor returns
    /// `SubprocessUnavailable` if the binary cannot be spawned at
    /// all, rather than producing silently wrong events; a replay
    /// failure inside the subcommand surfaces as a non-zero exit,
    /// which this extractor observes as an `Io` EOF and propagates.
    ///
    /// ## Thread safety
    ///
    /// The subprocess is wrapped in a `Mutex`.  The extractor
    /// runs in a single thread anyway (the server's
    /// dedicated `extractor` thread), so the mutex is
    /// uncontested; the locking is for type-system reasons
    /// (`Extractor: Sync` requires interior mutability).
    pub struct SubprocessExtractor {
        binary: PathBuf,
        log_path: PathBuf,
        /// Global flags prepended before the `extract-events`
        /// subcommand (GP.6.3): the deployment config
        /// (`--deployment-id` + budget policy + epoch schedule) the
        /// log was produced under, so replay re-verifies signatures
        /// against the right domain and reconstructs the right budget
        /// epochs.  Empty for a default-config deployment.
        global_args: Vec<String>,
        identifier: String,
        state: Mutex<Option<SubprocessState>>,
        /// Consecutive-spawn-failure counter for backoff.
        /// Reset to 0 on a successful spawn.  Per M-3 audit.
        consecutive_spawn_failures: std::sync::atomic::AtomicU32,
    }

    /// Minimum delay between consecutive subprocess spawns when
    /// the previous spawn failed.  Doubles on each consecutive
    /// failure (capped at [`MAX_SPAWN_BACKOFF`]).  Reset on
    /// success.
    const MIN_SPAWN_BACKOFF: std::time::Duration = std::time::Duration::from_millis(100);

    /// Cap on the spawn backoff interval.  After this many
    /// failures the operator should investigate.
    const MAX_SPAWN_BACKOFF: std::time::Duration = std::time::Duration::from_secs(30);

    /// The live subprocess + its IO handles.  stderr is not
    /// captured (inherited to the parent — see crate docstring
    /// re: C-4 audit fix).
    struct SubprocessState {
        child: Child,
        stdin: ChildStdin,
        stdout: BufReader<ChildStdout>,
    }

    impl std::fmt::Debug for SubprocessExtractor {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            let running = self
                .state
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .is_some();
            let failures = self
                .consecutive_spawn_failures
                .load(std::sync::atomic::Ordering::Relaxed);
            f.debug_struct("SubprocessExtractor")
                .field("binary", &self.binary)
                .field("log_path", &self.log_path)
                .field("global_args", &self.global_args)
                .field("identifier", &self.identifier)
                .field("running", &running)
                .field("consecutive_spawn_failures", &failures)
                .finish()
        }
    }

    impl SubprocessExtractor {
        /// Construct a subprocess extractor that spawns
        /// `knomosis extract-events --log <log_path>`.
        ///
        /// The subprocess is NOT started until the first
        /// `extract` call.  Construction is cheap (just
        /// configuration capture).
        #[must_use]
        pub fn new(binary: PathBuf, log_path: PathBuf) -> Self {
            let identifier = format!("subprocess[{}]", binary.display());
            Self {
                binary,
                log_path,
                global_args: Vec::new(),
                identifier,
                state: Mutex::new(None),
                consecutive_spawn_failures: std::sync::atomic::AtomicU32::new(0),
            }
        }

        /// Set the global flags prepended before `extract-events`
        /// when spawning (GP.6.3): the deployment config
        /// (`--deployment-id` + budget policy + epoch schedule) the
        /// log was produced under.  Builder form so the default
        /// constructor stays 2-arg for the common / test case.
        #[must_use]
        pub fn with_global_args(mut self, global_args: Vec<String>) -> Self {
            self.global_args = global_args;
            self
        }

        /// Compute the spawn-backoff duration for the current
        /// consecutive-failure count.  Exponential: 100ms × 2^n,
        /// capped at 30s.  Per M-3 audit.
        fn backoff_duration(&self) -> std::time::Duration {
            let n = self
                .consecutive_spawn_failures
                .load(std::sync::atomic::Ordering::Acquire);
            if n == 0 {
                return std::time::Duration::ZERO;
            }
            // Saturating shift to avoid overflow at large n.
            let exp = n.saturating_sub(1).min(8);
            let ms = MIN_SPAWN_BACKOFF.as_millis() as u64 * (1u64 << exp);
            std::time::Duration::from_millis(ms).min(MAX_SPAWN_BACKOFF)
        }

        /// Spawn the subprocess and store it in `state_slot`.  On
        /// success, reset the consecutive-failure counter.  On
        /// failure, increment the counter and propagate the
        /// error.
        fn try_spawn_into(
            &self,
            state_slot: &mut std::sync::MutexGuard<'_, Option<SubprocessState>>,
        ) -> Result<(), ExtractError> {
            match self.spawn() {
                Ok(s) => {
                    self.consecutive_spawn_failures
                        .store(0, std::sync::atomic::Ordering::Release);
                    **state_slot = Some(s);
                    Ok(())
                }
                Err(e) => {
                    self.consecutive_spawn_failures
                        .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
                    Err(e)
                }
            }
        }

        /// Spawn the subprocess (or return `Err` if already
        /// spawned).  Called internally by `extract` when the
        /// subprocess slot is empty.
        fn spawn(&self) -> Result<SubprocessState, ExtractError> {
            let mut cmd = Command::new(&self.binary);
            // GP.6.3: deployment-config global flags FIRST (the
            // `knomosis` binary parses them anywhere, but this matches
            // the documented `knomosis [GLOBAL_FLAGS] extract-events
            // --log LOG` form), then the subcommand.
            cmd.args(&self.global_args)
                .arg("extract-events")
                .arg("--log")
                .arg(&self.log_path)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                // C-4 audit fix: inherit stderr to the parent
                // rather than piping it.  Piping without an
                // active drain causes the daemon to wedge once
                // the OS pipe buffer fills (~64 KiB on Linux):
                // subprocess blocks on stderr write, parent
                // blocks on stdout read, both stuck forever.
                .stderr(Stdio::inherit());
            let child = cmd
                .spawn()
                .map_err(|e| ExtractError::SubprocessUnavailable {
                    reason: format!("failed to spawn {}: {}", self.binary.display(), e),
                })?;
            // Zombie defence: on any error after spawn (even
            // the `take()` ones below), we must kill+wait the
            // child or it becomes a zombie.  Use a guard.
            let mut guard = SpawnGuard { child: Some(child) };
            let stdin = guard.child_mut().stdin.take().ok_or_else(|| {
                ExtractError::SubprocessUnavailable {
                    reason: "subprocess produced no stdin handle".to_string(),
                }
            })?;
            let stdout = guard.child_mut().stdout.take().ok_or_else(|| {
                ExtractError::SubprocessUnavailable {
                    reason: "subprocess produced no stdout handle".to_string(),
                }
            })?;
            let child = guard.disarm();
            Ok(SubprocessState {
                child,
                stdin,
                stdout: BufReader::new(stdout),
            })
        }

        /// Issue one extract request to the subprocess.
        /// `state` is the borrowed live subprocess.
        fn extract_via(
            state: &mut SubprocessState,
            seq: u64,
            payload: &[u8],
        ) -> Result<Vec<CachedEvent>, ExtractError> {
            // 1. Write request: BE u64 seq + BE u32 len + payload.
            let len_u32 =
                u32::try_from(payload.len()).map_err(|_| ExtractError::MalformedResponse {
                    reason: format!("payload {} bytes exceeds u32::MAX", payload.len()),
                })?;
            state.stdin.write_all(&seq.to_be_bytes())?;
            state.stdin.write_all(&len_u32.to_be_bytes())?;
            state.stdin.write_all(payload)?;
            state.stdin.flush()?;
            // 2. Read response header: BE u64 seq + BE u32 count.
            let mut header = [0u8; 12];
            read_exact(&mut state.stdout, &mut header)?;
            let mut seq_buf = [0u8; 8];
            seq_buf.copy_from_slice(&header[0..8]);
            let got_seq = u64::from_be_bytes(seq_buf);
            if got_seq != seq {
                return Err(ExtractError::SequenceMismatch {
                    sent: seq,
                    got: got_seq,
                });
            }
            let mut count_buf = [0u8; 4];
            count_buf.copy_from_slice(&header[8..12]);
            let count = u32::from_be_bytes(count_buf);
            if count > HARD_MAX_EVENT_COUNT {
                return Err(ExtractError::TooManyEvents {
                    count,
                    max: HARD_MAX_EVENT_COUNT,
                });
            }
            // 3. Read each event payload.  Reserve a bounded amount
            //    up front (the validated `count` may be large); the
            //    Vec grows as events arrive.
            let mut events = Vec::with_capacity((count as usize).min(EVENT_BATCH_PREALLOC));
            for _ in 0..count {
                let mut elen_buf = [0u8; 4];
                read_exact(&mut state.stdout, &mut elen_buf)?;
                let elen = u32::from_be_bytes(elen_buf);
                let elen_usize = elen as usize;
                if elen_usize > HARD_MAX_EVENT_PAYLOAD {
                    return Err(ExtractError::EventPayloadOversize {
                        payload_len: elen,
                        max: HARD_MAX_EVENT_PAYLOAD,
                    });
                }
                let mut event_payload = vec![0u8; elen_usize];
                read_exact(&mut state.stdout, &mut event_payload)?;
                events.push(CachedEvent {
                    seq,
                    payload: event_payload,
                });
            }
            Ok(events)
        }
    }

    /// RAII guard that ensures a `Child` is killed-and-reaped on
    /// drop if not disarmed.  Used by `SubprocessExtractor::spawn`
    /// so that any error path between `Command::spawn` and the
    /// `Ok(SubprocessState)` return doesn't leak a zombie process.
    struct SpawnGuard {
        child: Option<Child>,
    }

    impl SpawnGuard {
        fn child_mut(&mut self) -> &mut Child {
            self.child.as_mut().expect("SpawnGuard: child slot armed")
        }

        /// Disarm the guard and return the child.  The caller is
        /// now responsible for lifecycle.
        fn disarm(mut self) -> Child {
            self.child.take().expect("SpawnGuard: child slot armed")
        }
    }

    impl Drop for SpawnGuard {
        fn drop(&mut self) {
            if let Some(mut child) = self.child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    /// `Read::read_exact` with `ExtractError::Io` conversion.
    fn read_exact<R: Read>(reader: &mut R, buf: &mut [u8]) -> Result<(), ExtractError> {
        reader.read_exact(buf).map_err(ExtractError::from)
    }

    impl Drop for SubprocessExtractor {
        fn drop(&mut self) {
            // Best-effort kill of the subprocess.  Operators can
            // observe the subprocess in their own monitoring; we
            // do not block on join here (would defeat Drop's
            // contract).
            let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
            if let Some(mut s) = state.take() {
                let _ = s.child.kill();
                let _ = s.child.wait();
            }
        }
    }

    impl Extractor for SubprocessExtractor {
        fn extract(&self, seq: u64, payload: &[u8]) -> Result<Vec<CachedEvent>, ExtractError> {
            let mut state_slot = self.state.lock().unwrap_or_else(|p| p.into_inner());
            // Lazily spawn on first call.  M-3 audit: apply
            // exponential backoff if previous spawn(s) failed.
            if state_slot.is_none() {
                let backoff = self.backoff_duration();
                if backoff.is_zero() {
                    // No backoff needed; try spawn now.
                    self.try_spawn_into(&mut state_slot)?;
                } else {
                    tracing::warn!(
                        backoff_ms = backoff.as_millis() as u64,
                        consecutive_failures = self
                            .consecutive_spawn_failures
                            .load(std::sync::atomic::Ordering::Acquire),
                        "subprocess spawn backoff"
                    );
                    // Release the mutex during sleep so other
                    // callers (if any) don't pile up.
                    drop(state_slot);
                    std::thread::sleep(backoff);
                    state_slot = self.state.lock().unwrap_or_else(|p| p.into_inner());
                    // Re-check in case another thread spawned
                    // while we slept.
                    if state_slot.is_none() {
                        self.try_spawn_into(&mut state_slot)?;
                    }
                }
            }
            let state = state_slot.as_mut().expect("just spawned");
            // Try extract; on I/O failure, drop the state so the
            // next call respawns.
            match Self::extract_via(state, seq, payload) {
                Ok(events) => Ok(events),
                Err(e) => {
                    let mut bad = state_slot.take().expect("just present");
                    let _ = bad.child.kill();
                    let _ = bad.child.wait();
                    // M-NEW-2 audit fix: increment the
                    // consecutive-failure counter on
                    // extract-time errors too, not just
                    // spawn-time.  Without this, a subprocess
                    // that crashes on every input would
                    // respawn-immediately in a tight loop with
                    // no backoff.  The extractor_loop's H-5 halt
                    // catches this in production (any
                    // ExtractError halts the daemon), but
                    // defence-in-depth is cheap here.
                    self.consecutive_spawn_failures
                        .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
                    Err(e)
                }
            }
        }

        fn identifier(&self) -> &str {
            &self.identifier
        }
    }
}

#[cfg(test)]
mod tests {
    use super::mock::{MockError, MockExtractor, MockResponse};
    use super::subprocess::SubprocessExtractor;
    use super::{ExtractError, Extractor, HARD_MAX_EVENT_COUNT, HARD_MAX_EVENT_PAYLOAD};
    use std::path::PathBuf;

    /// Hard limits are documented values.
    #[test]
    fn hard_limits_stable() {
        // GP.6.3 review: raised from 1024 to accommodate the
        // multi-actor laws (one event per affected actor).
        assert_eq!(HARD_MAX_EVENT_COUNT, 1 << 20);
        assert_eq!(HARD_MAX_EVENT_PAYLOAD, 1024 * 1024);
    }

    /// Default MockExtractor returns empty event list.
    #[test]
    fn mock_default_returns_empty() {
        let mock = MockExtractor::new();
        let events = mock.extract(1, b"some payload").unwrap();
        assert!(events.is_empty());
        assert_eq!(mock.call_count(), 1);
    }

    /// MockExtractor::set_responses returns programmed events.
    #[test]
    fn mock_returns_programmed_events() {
        let mock = MockExtractor::new();
        mock.set_responses(vec![
            MockResponse::Ok(vec![b"event-a".to_vec(), b"event-b".to_vec()]),
            MockResponse::Ok(vec![b"event-c".to_vec()]),
        ]);
        let r1 = mock.extract(1, b"frame1").unwrap();
        assert_eq!(r1.len(), 2);
        assert_eq!(r1[0].seq, 1);
        assert_eq!(r1[0].payload, b"event-a");
        assert_eq!(r1[1].seq, 1);
        assert_eq!(r1[1].payload, b"event-b");
        let r2 = mock.extract(2, b"frame2").unwrap();
        assert_eq!(r2.len(), 1);
        assert_eq!(r2[0].seq, 2);
        assert_eq!(r2[0].payload, b"event-c");
        // Cycles when exhausted.
        let r3 = mock.extract(3, b"frame3").unwrap();
        assert_eq!(r3.len(), 2); // back to response 0
        assert_eq!(r3[0].seq, 3); // but with seq=3
    }

    /// MockExtractor records every call.
    #[test]
    fn mock_records_calls() {
        let mock = MockExtractor::new();
        mock.extract(1, b"a").unwrap();
        mock.extract(2, b"bb").unwrap();
        mock.extract(3, b"ccc").unwrap();
        let recorded = mock.recorded();
        assert_eq!(recorded.len(), 3);
        assert_eq!(recorded[0], (1, b"a".to_vec()));
        assert_eq!(recorded[1], (2, b"bb".to_vec()));
        assert_eq!(recorded[2], (3, b"ccc".to_vec()));
    }

    /// MockExtractor::push_response queues new responses.
    #[test]
    fn mock_push_response_queues() {
        let mock = MockExtractor::new();
        mock.push_response(MockResponse::Ok(vec![b"first".to_vec()]));
        mock.push_response(MockResponse::Ok(vec![b"second".to_vec()]));
        let r1 = mock.extract(1, b"x").unwrap();
        let r2 = mock.extract(2, b"y").unwrap();
        assert_eq!(r1[0].payload, b"first");
        assert_eq!(r2[0].payload, b"second");
    }

    /// MockExtractor returns programmed errors.
    #[test]
    fn mock_returns_programmed_errors() {
        let mock = MockExtractor::new();
        mock.set_responses(vec![MockResponse::Err(MockError::Malformed(
            "bad subprocess data".to_string(),
        ))]);
        match mock.extract(1, b"x") {
            Err(ExtractError::MalformedResponse { reason }) => {
                assert_eq!(reason, "bad subprocess data");
            }
            other => panic!("expected MalformedResponse, got {other:?}"),
        }
    }

    /// MockExtractor::Unavailable surfaces.
    #[test]
    fn mock_returns_unavailable() {
        let mock = MockExtractor::new();
        mock.set_responses(vec![MockResponse::Err(MockError::Unavailable(
            "no knomosis binary".to_string(),
        ))]);
        match mock.extract(1, b"x") {
            Err(ExtractError::SubprocessUnavailable { reason }) => {
                assert_eq!(reason, "no knomosis binary");
            }
            other => panic!("expected SubprocessUnavailable, got {other:?}"),
        }
    }

    /// MockExtractor identifier is documented.
    #[test]
    fn mock_identifier() {
        let mock = MockExtractor::new();
        assert_eq!(mock.identifier(), "mock");
    }

    /// SubprocessExtractor identifier includes the binary path.
    #[test]
    fn subprocess_identifier() {
        let ext = SubprocessExtractor::new(
            PathBuf::from("/usr/bin/knomosis"),
            PathBuf::from("/var/log/knomosis.bin"),
        );
        assert!(ext.identifier().contains("/usr/bin/knomosis"));
        assert!(ext.identifier().starts_with("subprocess["));
    }

    /// SubprocessExtractor: missing binary → SubprocessUnavailable.
    #[test]
    fn subprocess_missing_binary_returns_error() {
        let ext = SubprocessExtractor::new(
            PathBuf::from("/tmp/knomosis-event-subscribe-nonexistent-binary"),
            PathBuf::from("/tmp/log"),
        );
        match ext.extract(1, b"payload") {
            Err(ExtractError::SubprocessUnavailable { .. }) => {}
            other => panic!("expected SubprocessUnavailable, got {other:?}"),
        }
    }

    /// `Extractor` is object-safe (usable as `Box<dyn Extractor>`).
    #[test]
    fn extractor_is_object_safe() {
        let mock = MockExtractor::new();
        let boxed: Box<dyn Extractor> = Box::new(mock);
        let _ = boxed.extract(1, b"x").unwrap();
        let _ = boxed.identifier();
    }

    /// MockExtractor + ExtractError are `Send + Sync`.
    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<MockExtractor>();
        assert_send_sync::<SubprocessExtractor>();
        assert_send_sync::<ExtractError>();
        assert_send_sync::<MockResponse>();
        assert_send_sync::<MockError>();
    }

    /// Subprocess returns SubprocessUnavailable when /bin/false
    /// exits before reading anything.  /bin/false is widely
    /// available on Unix; this verifies the spawn-then-broken-pipe
    /// path.
    #[cfg(unix)]
    #[test]
    fn subprocess_broken_pipe_returns_error() {
        let ext = SubprocessExtractor::new(PathBuf::from("/bin/false"), PathBuf::from("/tmp/log"));
        // /bin/false exits immediately with status 1.  When we
        // try to write to its stdin, we either get a broken pipe
        // or the spawn succeeds but the stdout read fails.
        match ext.extract(1, b"payload") {
            Err(ExtractError::Io(_)) | Err(ExtractError::SubprocessUnavailable { .. }) => {}
            other => panic!("expected Io or SubprocessUnavailable, got {other:?}"),
        }
    }

    /// GP.6.3: the global args supplied via `with_global_args` are
    /// spawned BEFORE the `extract-events` subcommand (the documented
    /// `knomosis [GLOBAL_FLAGS] extract-events --log LOG` argv).
    /// Verified directly: a fake binary records its argv; the
    /// extractor's protocol read then fails (the fake doesn't speak
    /// the wire format), but the recorded argv proves the forwarding.
    #[cfg(unix)]
    #[test]
    fn subprocess_forwards_global_args_before_subcommand() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let argfile = dir.path().join("argv.txt");
        let script = dir.path().join("fake-knomosis.sh");
        // Record each received arg on its own line, then exit 0.
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nexit 0\n",
                argfile.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let ext = SubprocessExtractor::new(script.clone(), PathBuf::from("/tmp/knomosis-test.log"))
            .with_global_args(vec!["--deployment-id".into(), "deadbeef".into()]);
        // `extract` spawns the fake, which exits 0 without a valid
        // response; the extractor errors (and kill+waits the child).
        let _ = ext.extract(1, b"payload");

        // The fake's argv-recording (`printf ... > argfile`) runs
        // CONCURRENTLY with the parent's stdin-write / stdout-read; the
        // parent's `read_exact` can observe EOF and return — dropping
        // (and killing) the child — before the shell has flushed
        // `argfile`.  So we must NOT assume the file exists the instant
        // `extract` returns.  Poll for it with a bounded timeout
        // instead of reading immediately (the previous unconditional
        // `read_to_string(...).expect(...)` raced the child and flaked
        // intermittently on loaded CI runners with a `NotFound`).
        let recorded = {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            loop {
                match std::fs::read_to_string(&argfile) {
                    // A non-empty read means the redirection completed
                    // (the shell writes all args in one `printf`, so a
                    // partial-then-empty read is not a concern here).
                    Ok(s) if !s.is_empty() => break s,
                    _ if std::time::Instant::now() >= deadline =>
                        panic!("fake never recorded its argv within 5s (file: {})",
                               argfile.display()),
                    _ => std::thread::sleep(std::time::Duration::from_millis(10)),
                }
            }
        };
        let argv: Vec<&str> = recorded.lines().collect();
        assert_eq!(
            argv,
            vec![
                "--deployment-id",
                "deadbeef",
                "extract-events",
                "--log",
                "/tmp/knomosis-test.log",
            ],
            "global args must precede the extract-events subcommand"
        );
    }
}
