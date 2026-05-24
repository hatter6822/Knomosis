// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Kernel abstraction for the knomosis-host network adaptor.
//!
//! ## What this module provides
//!
//!   * [`Kernel`] — the synchronous trait the network adaptor
//!     consumes.  Submitting a CBE-encoded `SignedAction` yields
//!     a [`KernelResponse`]; the kernel also declares its
//!     `ok_admission_stage` so callers know what `Verdict::Ok`
//!     means under this deployment.
//!   * [`SubscribableKernel`] — an optional extension trait for
//!     kernels that emit per-action stage transitions
//!     asynchronously (consensus kernels, observer-aware
//!     kernels).  Returns a [`Subscription`] carrying the current
//!     stage plus a receiver of future monotonic stage
//!     transitions.
//!   * [`mock::MockKernel`] — a configurable in-memory kernel for
//!     tests and dev mode.  Records every submission; returns
//!     verdicts from a configurable sequence (defaults to `Ok`).
//!     Declares `Finalized` (centralized synchronous semantics).
//!   * [`command::CommandKernel`] — a per-request subprocess
//!     kernel.  Spawns the Lean `knomosis` binary's `process`
//!     subcommand for each request, parses the exit code, and
//!     returns the resulting verdict.  Heavy (O(log size) per
//!     request) but correct.  Declares `Finalized`.  The future
//!     optimization is a `knomosis serve` Lean-side subcommand
//!     reading CBE frames from stdin.
//!
//! ## Why the abstraction
//!
//! The host's network surface is independently testable: the
//! `MockKernel` lets integration tests exercise the full TCP /
//! Unix socket / TLS / queueing paths without a Lean toolchain in
//! the test environment.  The `CommandKernel` is the production
//! wiring; it can be swapped for a future async-IPC kernel without
//! touching the network layer.
//!
//! ## Forward compatibility with decentralized sequencing
//!
//! The trait split (`Kernel` + `SubscribableKernel`) is designed
//! so a future `ConsensusKernel` — fronting a sequencer set that
//! commits ordering via consensus and finalizes via L1 — slots in
//! without disrupting existing kernels.  Such a kernel would:
//!
//!   1. Implement `Kernel::submit` synchronously, returning
//!      `Verdict::Ok` once consensus has committed (or
//!      `Verdict::Busy` if consensus is still in flight at the
//!      configured timeout).
//!   2. Override `Kernel::ok_admission_stage` to return
//!      `Sequenced` (or `LocallyAdmitted` for an even-eagerer
//!      kernel that returns `Ok` before consensus completes).
//!   3. Implement `SubscribableKernel::subscribe` so clients
//!      (via the future RH-D event-subscription protocol) can
//!      track the action through later stages — most notably
//!      the `Sequenced → Finalized` transition that follows L1
//!      finalization minutes after consensus.
//!
//! The wire format the host speaks to clients does NOT change
//! across this transition; only the kernel-API surface grows.

use crate::admission::{AdmissionReceipt, AdmissionStage};
use crate::verdict::VerdictResponse;

/// The response the host returns to the client.  Mirrors
/// [`VerdictResponse`] but kept distinct so the kernel doesn't
/// have to import the wire-format encoder.
pub type KernelResponse = VerdictResponse;

/// The kernel abstraction.  Implementations decide admissibility
/// for incoming CBE-encoded `SignedAction` bytes.
///
/// ## Trait requirements
///
///   * **`Send + Sync`.**  The kernel is shared across the worker
///     thread; trait objects (`Box<dyn Kernel>`) require these
///     bounds for `std::thread::spawn` to accept the closure that
///     owns the kernel.
///   * **Interior mutability via `&self`.**  The kernel may hold
///     mutable state (e.g. a connection pool, a log file handle)
///     but exposes only `&self` to the worker.  Implementations
///     use `Mutex`, `RwLock`, or atomic types as needed.
///   * **Synchronous.**  Submissions block until the verdict is
///     ready.  The worker is single-threaded so back-pressure
///     propagates upstream via the bounded queue.
///
/// ## Stage commitment via `ok_admission_stage`
///
/// Every kernel declares which [`AdmissionStage`] its `Verdict::Ok`
/// response corresponds to.  Centralized kernels (the current
/// `MockKernel` and `CommandKernel`) declare `Finalized` because
/// synchronous admission collapses every stage: by the time the
/// kernel returns `Ok`, the local log is canonical.  Future
/// consensus-aware kernels declare a weaker stage (typically
/// `Sequenced` for a kernel that waits for consensus, or
/// `LocallyAdmitted` for one that does not).
///
/// This method is **invariant** for a given kernel instance — it
/// reflects the kernel's design, not per-request data.  Clients
/// can query it once at handshake time (RH-D will document the
/// `getInfo` preamble); operators see it in the host's startup
/// log line.
pub trait Kernel: Send + Sync {
    /// Submit one CBE-encoded `SignedAction`.  Returns the
    /// resulting verdict + optional human-readable reason.
    ///
    /// Implementations must not panic on any input; malformed
    /// CBE bytes should produce `Verdict::ParseError` rather than
    /// a Rust panic.
    fn submit(&self, signed_action_bytes: &[u8]) -> KernelResponse;

    /// A diagnostic identifier the host emits at startup (the
    /// equivalent of `knomosis-l1-ingest::INGEST_IDENTIFIER`).  Used
    /// for operator visibility — e.g. `"mock/v1"` or
    /// `"command-subprocess/v1"`.
    fn identifier(&self) -> &str;

    /// Admission stage corresponding to this kernel's
    /// `Verdict::Ok` response byte.
    ///
    /// **Default**: [`AdmissionStage::Finalized`].  This is the
    /// strongest claim and is correct for any kernel where
    /// synchronous admission is canonical (centralized
    /// deployments, including the present `MockKernel` and
    /// `CommandKernel`).
    ///
    /// Consensus-aware kernels OVERRIDE this to return a weaker
    /// stage (`Sequenced` or `LocallyAdmitted`) so clients know
    /// that further stage transitions may follow asynchronously.
    /// They also (typically) implement [`SubscribableKernel`] so
    /// clients can watch for those transitions.
    fn ok_admission_stage(&self) -> AdmissionStage {
        AdmissionStage::Finalized
    }
}

/// A subscription handle returned by [`SubscribableKernel::subscribe`].
///
/// Carries the **current** stage (the latest known stage at
/// subscription time) plus a `Receiver` that emits **future**
/// stage transitions in strict-increasing order.  The receiver
/// closes (sender dropped) when the action reaches a terminal
/// stage (typically `Finalized`) or when the kernel determines no
/// further transitions are possible.  Once closed,
/// `events.try_recv()` returns `Err(TryRecvError::Disconnected)`
/// after any still-buffered events are drained.
///
/// The split between `current` and `events` avoids a race: a
/// caller that subscribes after the action has already progressed
/// to `Sequenced` is told the current stage atomically with
/// obtaining the receiver, so no transition is silently missed.
///
/// ## Monotonicity contract
///
/// For any subscription `s`, the sequence of stages observed via
/// `s` is `current` followed by the events emitted on
/// `s.events`.  This sequence MUST be **strictly increasing**
/// (each event stage `> current` at subscribe time; each
/// subsequent event `>` the previous).  The trait's
/// implementations MUST guarantee this; subscribers can rely on
/// it (e.g., they can `assert!(prev < next)` rather than
/// `assert!(prev <= next)`).
///
/// ## Implementation requirements — the "atomic snapshot" rule
///
/// To honour strict-increasing monotonicity in the presence of
/// concurrent stage-advance, implementations of
/// `SubscribableKernel::subscribe` MUST satisfy the **atomic
/// snapshot rule**:
///
/// > Under whatever synchronization primitive guards the action's
/// > internal `current_stage` field, `subscribe` must read
/// > `current_stage` AND drain any channel-buffered events
/// > already `≤ current_stage` while holding that primitive.
///
/// In practice this means the canonical implementation holds a
/// single `Mutex` (or equivalent) across BOTH operations that
/// advance an action's stage:
///
///   1. `slot.current_stage = next_stage;`
///   2. `slot.tx.send(next_stage).unwrap();`
///
/// AND across both operations in `subscribe`:
///
///   1. let snapshot = `slot.current_stage`;
///   2. let receiver = `slot.tx.subscribe()` (or equivalent);
///
/// Holding the mutex across both pairs guarantees that the
/// snapshot read by `subscribe` is consistent with the channel's
/// buffered contents: any event already-sent at the moment of
/// snapshot is reflected in the snapshot (so it won't be
/// re-emitted); any event sent after the snapshot is strictly
/// greater than the snapshot (so it can be safely emitted).
///
/// A naive implementation that bumps `current_stage` and `send`s
/// the channel WITHOUT holding the mutex across both can lead to
/// the subscriber observing duplicate stages (e.g., `current =
/// Sequenced` followed by `events.recv() = Sequenced` again).
/// This violates strict-increasing monotonicity and is a
/// correctness bug.
///
/// ## Consumption discipline
///
/// `std::sync::mpsc::Receiver` has no non-destructive peek API,
/// so this struct deliberately does NOT provide an `is_closed`
/// helper: any such helper would either consume a buffered event
/// or fail to distinguish "alive with pending event" from "dead
/// with pending event."  Callers should use `events.recv`,
/// `events.recv_timeout`, or `events.try_recv` directly and
/// handle the three `TryRecvError` cases explicitly.
pub struct Subscription {
    /// Latest stage known to the kernel at the moment
    /// `subscribe` returned.
    pub current: AdmissionStage,
    /// Receiver of future stage transitions.  Each emitted stage
    /// is strictly greater than the previous (`current` for the
    /// first emission, the previous emission otherwise).  See the
    /// struct-level "atomic snapshot" rule for the implementation
    /// constraint that makes this guarantee sound.
    pub events: std::sync::mpsc::Receiver<AdmissionStage>,
}

/// Optional extension trait for kernels that emit per-action
/// stage transitions asynchronously.
///
/// Implementing this trait is **not required** for inclusion in
/// knomosis-host: the worker dispatches via `Kernel::submit` and
/// uses the trait's response for the wire byte.  Implement
/// `SubscribableKernel` only if the kernel has stage transitions
/// to emit beyond `ok_admission_stage()` — typically a consensus
/// kernel awaiting L1 finalization, or a kernel that surfaces
/// later events via an observer.
///
/// Future RH-D (`knomosis-event-subscribe`) integration will fan
/// subscriptions out to clients via a separate wire-format
/// protocol.  Until then, `SubscribableKernel` is the
/// design-stable seam that lets that work proceed without
/// breaking the existing `Kernel` trait.
///
/// ## Action identifiers
///
/// Subscription is keyed by an opaque kernel-defined `action_id`
/// — typically the bytes carried in
/// [`AdmissionReceipt::action_id`] for the corresponding
/// submission.  Kernels that don't issue ids cannot meaningfully
/// implement this trait.
pub trait SubscribableKernel: Kernel {
    /// Subscribe to admission-stage transitions for the action
    /// identified by `action_id`.  Returns `Some(Subscription)`
    /// if the kernel knows about the action; `None` if not.
    ///
    /// The returned subscription's `current` stage MUST be
    /// `>= self.ok_admission_stage()` for any action this kernel
    /// has previously admitted (returned `Verdict::Ok` for) — the
    /// stage ladder is monotonic across the kernel's lifetime
    /// for any given action.
    fn subscribe(&self, action_id: &[u8]) -> Option<Subscription>;

    /// Generate a stable identifier for the supplied
    /// CBE-encoded signed action.  Returned as part of the
    /// receipt in [`receipt_for`].
    ///
    /// Default uses a tag-free placeholder; real kernels should
    /// override (typically keccak-256 of the signed-action
    /// bytes, matching the L1 contract conventions).
    fn action_id_for(&self, signed_action_bytes: &[u8]) -> Vec<u8> {
        // Default: empty byte string.  Indicates "no subscription
        // possible" to downstream callers.
        let _ = signed_action_bytes;
        Vec::new()
    }

    /// Build an [`AdmissionReceipt`] for an action that just
    /// reached the kernel's `ok_admission_stage`.  Convenience
    /// helper for kernels that always return Ok at a fixed
    /// stage; consensus kernels with variable per-action
    /// staging override this.
    fn receipt_for(&self, signed_action_bytes: &[u8]) -> AdmissionReceipt {
        AdmissionReceipt::with_id(
            self.ok_admission_stage(),
            self.action_id_for(signed_action_bytes),
        )
    }
}

/// In-memory mock kernel for tests and dev mode.
pub mod mock {
    use std::sync::Mutex;

    use crate::admission::AdmissionStage;
    use crate::verdict::Verdict;

    use super::{Kernel, KernelResponse};

    /// A configurable in-memory kernel.  Records every submission
    /// and returns verdicts from a configurable response sequence.
    ///
    /// Default behaviour: returns `Verdict::Ok` for every
    /// submission.  Tests configure custom response sequences via
    /// [`MockKernel::set_responses`].
    ///
    /// Declares [`AdmissionStage::Finalized`] for `Verdict::Ok` by
    /// default (matching `CommandKernel`'s centralized semantics).
    /// Tests targeting consensus-style flows can override via
    /// [`MockKernel::set_ok_stage`].
    #[derive(Debug)]
    pub struct MockKernel {
        inner: Mutex<MockInner>,
    }

    impl Default for MockKernel {
        fn default() -> Self {
            Self {
                inner: Mutex::new(MockInner::default()),
            }
        }
    }

    /// The mock kernel's mutable interior.
    #[derive(Debug)]
    struct MockInner {
        /// Every submission recorded in arrival order.
        recorded: Vec<Vec<u8>>,
        /// Response sequence; cycles when exhausted.  Empty
        /// sequence means "always Ok".
        responses: Vec<KernelResponse>,
        /// Index into `responses` for the next submission.
        next_response: usize,
        /// Stage corresponding to `Verdict::Ok` for this mock.
        /// Defaults to `Finalized` (centralized semantics).
        ok_stage: AdmissionStage,
    }

    impl Default for MockInner {
        fn default() -> Self {
            Self {
                recorded: Vec::new(),
                responses: Vec::new(),
                next_response: 0,
                ok_stage: AdmissionStage::Finalized,
            }
        }
    }

    impl MockKernel {
        /// Construct a mock kernel that returns `Verdict::Ok` for
        /// every submission.
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }

        /// Replace the response sequence.  Each `submit` returns
        /// the next element of `responses`, cycling when
        /// exhausted.  Passing an empty `Vec` reverts to "always
        /// Ok".
        pub fn set_responses(&self, responses: Vec<KernelResponse>) {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            inner.responses = responses;
            inner.next_response = 0;
        }

        /// Override the admission stage this mock reports for
        /// `Verdict::Ok`.  Default is
        /// [`AdmissionStage::Finalized`]; tests targeting
        /// consensus-style staging set `Sequenced` or
        /// `LocallyAdmitted` to verify downstream code handles
        /// weaker-stage claims correctly.
        ///
        /// This method affects only the value reported by
        /// [`Kernel::ok_admission_stage`]; the wire byte returned
        /// by `submit` is unchanged.
        pub fn set_ok_stage(&self, stage: AdmissionStage) {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            inner.ok_stage = stage;
        }

        /// Clone the recorded submissions.  Order-preserving.
        #[must_use]
        pub fn recorded(&self) -> Vec<Vec<u8>> {
            self.inner
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .recorded
                .clone()
        }

        /// Number of recorded submissions.
        #[must_use]
        pub fn len(&self) -> usize {
            self.inner
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .recorded
                .len()
        }

        /// `true` iff nothing has been submitted yet.
        #[must_use]
        pub fn is_empty(&self) -> bool {
            self.len() == 0
        }
    }

    impl Kernel for MockKernel {
        fn submit(&self, signed_action_bytes: &[u8]) -> KernelResponse {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            inner.recorded.push(signed_action_bytes.to_vec());
            if inner.responses.is_empty() {
                return KernelResponse::from_verdict(Verdict::Ok);
            }
            let response_count = inner.responses.len();
            let idx = inner.next_response % response_count;
            let response = inner.responses[idx].clone();
            inner.next_response = inner.next_response.wrapping_add(1);
            response
        }

        fn identifier(&self) -> &str {
            "knomosis-host-mock/v1"
        }

        fn ok_admission_stage(&self) -> AdmissionStage {
            self.inner
                .lock()
                .map(|i| i.ok_stage)
                .unwrap_or(AdmissionStage::Finalized)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::MockKernel;
        use crate::admission::AdmissionStage;
        use crate::kernel::Kernel;
        use crate::verdict::{Verdict, VerdictResponse};

        /// Default mock declares `Finalized` (centralized
        /// synchronous semantics).
        #[test]
        fn default_ok_stage_is_finalized() {
            let k = MockKernel::new();
            assert_eq!(k.ok_admission_stage(), AdmissionStage::Finalized);
        }

        /// `set_ok_stage` overrides the reported stage.
        #[test]
        fn set_ok_stage_overrides() {
            let k = MockKernel::new();
            k.set_ok_stage(AdmissionStage::Sequenced);
            assert_eq!(k.ok_admission_stage(), AdmissionStage::Sequenced);
            k.set_ok_stage(AdmissionStage::LocallyAdmitted);
            assert_eq!(k.ok_admission_stage(), AdmissionStage::LocallyAdmitted);
            k.set_ok_stage(AdmissionStage::Finalized);
            assert_eq!(k.ok_admission_stage(), AdmissionStage::Finalized);
        }

        /// Setting `ok_stage` does NOT change the wire-format
        /// verdict byte.  This is the invariant the trait
        /// promises: wire format is independent of stage
        /// commitment.
        #[test]
        fn set_ok_stage_doesnt_change_wire_verdict() {
            let k = MockKernel::new();
            k.set_ok_stage(AdmissionStage::LocallyAdmitted);
            let r = k.submit(b"x");
            assert_eq!(r.verdict, Verdict::Ok);
            assert_eq!(r.verdict.to_byte(), 0);
        }

        /// Default mock returns `Ok` for every submission.
        #[test]
        fn default_always_ok() {
            let k = MockKernel::new();
            let r1 = k.submit(b"first");
            let r2 = k.submit(b"second");
            assert_eq!(r1.verdict, Verdict::Ok);
            assert_eq!(r2.verdict, Verdict::Ok);
            assert_eq!(k.len(), 2);
        }

        /// Mock records every submission in arrival order.
        #[test]
        fn records_in_order() {
            let k = MockKernel::new();
            k.submit(b"a");
            k.submit(b"b");
            k.submit(b"c");
            assert_eq!(
                k.recorded(),
                vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()]
            );
        }

        /// Response sequence cycles when exhausted.
        #[test]
        fn responses_cycle() {
            let k = MockKernel::new();
            k.set_responses(vec![
                VerdictResponse::from_verdict(Verdict::NotAdmissible),
                VerdictResponse::from_verdict(Verdict::Ok),
            ]);
            let r1 = k.submit(b"a");
            let r2 = k.submit(b"b");
            let r3 = k.submit(b"c"); // wraps
            let r4 = k.submit(b"d");
            assert_eq!(r1.verdict, Verdict::NotAdmissible);
            assert_eq!(r2.verdict, Verdict::Ok);
            assert_eq!(r3.verdict, Verdict::NotAdmissible);
            assert_eq!(r4.verdict, Verdict::Ok);
        }

        /// Reasons survive through `submit` → response.
        #[test]
        fn reason_survives() {
            let k = MockKernel::new();
            k.set_responses(vec![VerdictResponse::with_reason(
                Verdict::NotAdmissible,
                "nonce mismatch",
            )]);
            let r = k.submit(b"x");
            assert_eq!(r.verdict, Verdict::NotAdmissible);
            assert_eq!(r.reason, "nonce mismatch");
        }

        /// Setting an empty response Vec reverts to default Ok
        /// behaviour.
        #[test]
        fn empty_responses_reverts_to_ok() {
            let k = MockKernel::new();
            k.set_responses(vec![VerdictResponse::from_verdict(Verdict::Busy)]);
            assert_eq!(k.submit(b"x").verdict, Verdict::Busy);
            k.set_responses(vec![]);
            assert_eq!(k.submit(b"y").verdict, Verdict::Ok);
        }

        /// `is_empty` flips after a single submission.
        #[test]
        fn is_empty_flips() {
            let k = MockKernel::new();
            assert!(k.is_empty());
            k.submit(b"x");
            assert!(!k.is_empty());
        }

        /// Identifier is the documented v1 string.
        #[test]
        fn identifier_constant() {
            let k = MockKernel::new();
            assert_eq!(k.identifier(), "knomosis-host-mock/v1");
        }

        /// MockKernel is `Send + Sync` for the worker thread.
        #[test]
        fn is_send_sync() {
            fn assert_send_sync<T: Send + Sync>() {}
            assert_send_sync::<MockKernel>();
        }

        /// Records preserve raw bytes (including zero bytes and
        /// non-UTF-8 sequences).
        #[test]
        fn raw_bytes_preserved() {
            let k = MockKernel::new();
            let payload = vec![0x00u8, 0xff, 0xaa, 0x55, 0xc3, 0x28]; // includes invalid UTF-8
            k.submit(&payload);
            assert_eq!(k.recorded()[0], payload);
        }
    }
}

/// Per-request subprocess kernel.  Spawns the `knomosis` binary's
/// `process` subcommand for each submitted SignedAction.
pub mod command {
    use std::io::{Read, Write};
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    use crate::verdict::Verdict;

    use super::{Kernel, KernelResponse};

    /// Maximum stderr / stdout bytes the kernel will read from the
    /// subprocess before truncating.  Defends against a misbehaving
    /// `knomosis` binary that emits megabytes of diagnostic output.
    pub const MAX_SUBPROCESS_OUTPUT: usize = 64 * 1024;

    /// Default per-request subprocess timeout.  Per-request
    /// spawning is heavy (each call re-loads the log), so the
    /// timeout is generous; production tuning may bump it.
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

    /// Polling interval for `try_wait` in the timeout loop.
    /// Trade-off: smaller = more responsive timeout but more CPU
    /// overhead; larger = bounded responsiveness but cheaper.
    /// 10 ms is a reasonable balance for a per-request kernel
    /// already in the ms range.
    const WAIT_POLL_INTERVAL: Duration = Duration::from_millis(10);

    /// A per-request subprocess kernel.  Each `submit` call:
    ///
    ///   1. Writes the CBE bytes to a temp file under the host's
    ///      configured work directory.
    ///   2. Spawns `knomosis process <log-path> <temp-file>`.
    ///   3. Parses the exit code (0 = Ok, anything else =
    ///      NotAdmissible) and captures stderr as the reason.
    ///   4. Removes the temp file.
    ///
    /// The persistent log file is shared across requests.  The
    /// worker is single-threaded so the log file accesses are
    /// serial; no file locking required.
    ///
    /// ## Performance
    ///
    /// Each call spawns a process AND re-loads the log file.
    /// This is O(log size) per request.  For a production
    /// deployment, the canonical optimization is a future
    /// `knomosis serve` Lean-side subcommand that reads CBE frames
    /// from stdin and writes verdicts to stdout, eliminating the
    /// per-request bootstrap cost.  See the engineering plan
    /// §RH-C closeout.
    ///
    /// ## Verdict semantics
    ///
    /// `knomosis process` exits with:
    ///   * `0` — bootstrap succeeded AND every action was admitted.
    ///   * `1` — bootstrap failed OR at least one action failed
    ///     (NotAdmissible) OR parse error.
    ///
    /// We collapse non-zero exits to `Verdict::NotAdmissible`
    /// because:
    ///   1. Distinguishing NotAdmissible from ParseError from a
    ///      bootstrap failure requires stdout/stderr parsing,
    ///      which is fragile.
    ///   2. From the client's perspective, all three are "the
    ///      kernel didn't admit my action and the host can't
    ///      help"; the operator-actionable distinction lives in
    ///      the host's logs (which capture the full stderr).
    ///
    /// The stderr is captured as the response's `reason` field so
    /// operators can grep the host's `tracing` output for failure
    /// modes.
    #[derive(Debug)]
    pub struct CommandKernel {
        /// Path to the `knomosis` binary.
        knomosis_binary: PathBuf,
        /// Path to the persistent log file shared across requests.
        log_path: PathBuf,
        /// Path to the directory under which per-request temp
        /// files are created.
        work_dir: PathBuf,
        /// Optional deployment-id hex to pass via
        /// `--deployment-id`.  Empty string means no deployment-id
        /// flag is passed (so the knomosis binary's default sentinel
        /// applies).
        deployment_id_hex: String,
        /// Mutex guarding sequential subprocess access.  The
        /// worker is single-threaded today but the mutex
        /// future-proofs against an accidental parallel worker.
        spawn_lock: Mutex<()>,
        /// Per-request timeout.  Default
        /// [`DEFAULT_TIMEOUT`]; configurable via
        /// [`CommandKernel::with_timeout`].
        timeout: Duration,
    }

    /// Errors during `CommandKernel` construction.
    #[derive(Debug, thiserror::Error)]
    pub enum CommandKernelError {
        /// The `knomosis` binary path doesn't exist or isn't a file.
        #[error("knomosis binary path {0:?} does not exist or is not a file")]
        BinaryNotFound(PathBuf),
        /// The work directory could not be created.
        #[error("could not create work directory {path:?}: {source}")]
        WorkDirCreate {
            /// The path the kernel tried to create.
            path: PathBuf,
            /// Underlying I/O error.
            source: std::io::Error,
        },
    }

    impl CommandKernel {
        /// Construct a `CommandKernel`.
        ///
        /// Validates that the `knomosis` binary path exists and is a
        /// file; creates the work directory if it doesn't exist.
        ///
        /// # Errors
        ///
        /// Returns `CommandKernelError::BinaryNotFound` if
        /// `knomosis_binary` is missing.  Returns
        /// `CommandKernelError::WorkDirCreate` if the work
        /// directory cannot be created.
        pub fn new(
            knomosis_binary: PathBuf,
            log_path: PathBuf,
            work_dir: PathBuf,
        ) -> Result<Self, CommandKernelError> {
            // Verify the binary exists.  We don't verify it's
            // executable — that's a permission check we'd race
            // against anyway, and `Command::spawn` surfaces a
            // clear error if it can't be exec'd.
            if !knomosis_binary.is_file() {
                return Err(CommandKernelError::BinaryNotFound(knomosis_binary));
            }
            // Create the work directory if needed.
            if let Err(source) = std::fs::create_dir_all(&work_dir) {
                return Err(CommandKernelError::WorkDirCreate {
                    path: work_dir,
                    source,
                });
            }
            Ok(Self {
                knomosis_binary,
                log_path,
                work_dir,
                deployment_id_hex: String::new(),
                spawn_lock: Mutex::new(()),
                timeout: DEFAULT_TIMEOUT,
            })
        }

        /// Set the deployment-id hex string passed via
        /// `--deployment-id` on every subprocess invocation.
        /// Empty string disables the flag (knomosis binary defaults
        /// to empty sentinel; emits a dev-mode warning).
        #[must_use]
        pub fn with_deployment_id(mut self, hex: impl Into<String>) -> Self {
            self.deployment_id_hex = hex.into();
            self
        }

        /// Override the default per-request timeout.
        #[must_use]
        pub fn with_timeout(mut self, timeout: Duration) -> Self {
            self.timeout = timeout;
            self
        }

        /// Path to the knomosis binary.  Diagnostic only.
        #[must_use]
        pub fn knomosis_binary(&self) -> &Path {
            &self.knomosis_binary
        }

        /// Path to the persistent log file.  Diagnostic only.
        #[must_use]
        pub fn log_path(&self) -> &Path {
            &self.log_path
        }

        /// Path to the per-request temp work directory.
        /// Diagnostic only.
        #[must_use]
        pub fn work_dir(&self) -> &Path {
            &self.work_dir
        }

        /// Format a single CBE record into a "stream of one"
        /// suitable for `knomosis process`'s input file format.
        /// `knomosis process` reads concatenated CBE-encoded
        /// SignedAction records, so a single-record file is just
        /// the bytes themselves.
        fn frame_input(signed_action_bytes: &[u8]) -> Vec<u8> {
            signed_action_bytes.to_vec()
        }
    }

    impl Kernel for CommandKernel {
        fn submit(&self, signed_action_bytes: &[u8]) -> KernelResponse {
            // 1. Acquire the spawn lock.  Sequentialises all
            //    subprocess work — even if the worker pool were
            //    expanded.  Recover from poisoning rather than
            //    panicking the worker thread: a poisoned mutex
            //    means a previous lock holder panicked, but the
            //    protected data is just a guard token (no state
            //    to corrupt).
            let _guard = match self.spawn_lock.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };

            // 2. Allocate a unique temp file under the work dir.
            //    `tempfile::NamedTempFile::new_in` creates with
            //    `O_CREAT | O_EXCL` + a random suffix, defending
            //    against symlink-attack TOCTOU on multi-tenant
            //    work directories.
            let input_bytes = Self::frame_input(signed_action_bytes);
            let temp_file = match tempfile::Builder::new()
                .prefix("knomosis-host-req-")
                .suffix(".cbe")
                .tempfile_in(&self.work_dir)
            {
                Ok(f) => f,
                Err(e) => {
                    return KernelResponse::with_reason(
                        Verdict::NotAdmissible,
                        format!("create temp file in {:?}: {e}", self.work_dir),
                    );
                }
            };
            let temp_path = temp_file.path().to_path_buf();
            // Disarm the auto-delete-on-drop behaviour of
            // `NamedTempFile` so the file persists long enough for
            // the subprocess to read it.  `keep()` consumes the
            // `NamedTempFile` and returns `(File, PathBuf)`; the
            // `PathBuf`'s Drop is just deallocation, so the file
            // is NOT auto-deleted.  We own deletion explicitly at
            // step 5 below.
            //
            // If `keep()` returns `Err`, the inner `NamedTempFile`
            // is preserved on the `PersistError` value; dropping
            // the error (when we early-return) re-arms the inner
            // `NamedTempFile`'s auto-delete, so the
            // partially-created file is cleaned up.
            {
                let (mut file, _kept_path) = match temp_file.keep() {
                    Ok((f, p)) => (f, p),
                    Err(e) => {
                        return KernelResponse::with_reason(
                            Verdict::NotAdmissible,
                            format!("persist temp file: {}", e.error),
                        );
                    }
                };
                if let Err(e) = file.write_all(&input_bytes) {
                    let _ = std::fs::remove_file(&temp_path);
                    return KernelResponse::with_reason(
                        Verdict::NotAdmissible,
                        format!("write temp file {temp_path:?}: {e}"),
                    );
                }
                // Use `sync_data` rather than `flush`: `std::fs::File`'s
                // `Write::flush` is a documented no-op (the File has no
                // userspace buffer to flush), so calling it conveys no
                // durability guarantee.  `sync_data` issues fdatasync(2),
                // which forces the dirty pages backing this file out to
                // disk.  This matters on filesystems with weaker
                // cache-coherence than local ext4/xfs — most notably
                // NFS-mounted work directories and some FUSE drivers —
                // where the subprocess might otherwise `open` the file
                // before the writeback has propagated and observe an
                // empty or truncated payload.  Cost: one fdatasync per
                // request; negligible for the CommandKernel which is
                // already O(log size) per request.
                if let Err(e) = file.sync_data() {
                    let _ = std::fs::remove_file(&temp_path);
                    return KernelResponse::with_reason(
                        Verdict::NotAdmissible,
                        format!("sync temp file {temp_path:?}: {e}"),
                    );
                }
                // Drop closes the file handle.
            }

            // 3. Build the subprocess command.  Use `--allow-fallback-hash`
            //    to suppress the warning the knomosis binary emits on a
            //    non-production hash build — the host has its own
            //    diagnostic surface and the warning would bloat
            //    stderr capture for every request.
            let mut cmd = Command::new(&self.knomosis_binary);
            cmd.arg("--allow-fallback-hash");
            if !self.deployment_id_hex.is_empty() {
                cmd.arg("--deployment-id").arg(&self.deployment_id_hex);
            }
            cmd.arg("process").arg(&self.log_path).arg(&temp_path);
            cmd.stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped());

            // 4. Spawn + bounded wait (per AR-RHC #1).  The previous
            //    implementation used `cmd.output()` which blocks
            //    unconditionally; a wedged knomosis binary would hang
            //    the worker forever.  We now spawn and poll
            //    `try_wait` with `WAIT_POLL_INTERVAL` until either
            //    the process exits or the configured timeout
            //    elapses, at which point we SIGKILL the child.
            let response = match cmd.spawn() {
                Ok(mut child) => {
                    let exit_status = wait_with_timeout(&mut child, self.timeout);
                    // Collect stderr regardless of how the wait
                    // resolved — operator wants the diagnostic
                    // output for failure analysis.  Bounded by
                    // `MAX_SUBPROCESS_OUTPUT`.
                    let stderr_text = match child.stderr.take() {
                        Some(mut s) => {
                            let mut buf = Vec::with_capacity(1024);
                            let _ = take_with_limit(&mut s, &mut buf, MAX_SUBPROCESS_OUTPUT);
                            String::from_utf8_lossy(&buf).to_string()
                        }
                        None => String::new(),
                    };
                    match exit_status {
                        WaitOutcome::Exited(status) => {
                            if status.success() {
                                KernelResponse::from_verdict(Verdict::Ok)
                            } else {
                                KernelResponse::with_reason(
                                    Verdict::NotAdmissible,
                                    if stderr_text.is_empty() {
                                        format!("knomosis exited with status {status}")
                                    } else {
                                        stderr_text
                                    },
                                )
                            }
                        }
                        WaitOutcome::TimedOut => KernelResponse::with_reason(
                            Verdict::NotAdmissible,
                            if stderr_text.is_empty() {
                                format!(
                                    "knomosis subprocess exceeded {:?} timeout; SIGKILLed",
                                    self.timeout
                                )
                            } else {
                                format!(
                                    "knomosis subprocess exceeded {:?} timeout (SIGKILLed); stderr: {}",
                                    self.timeout, stderr_text
                                )
                            },
                        ),
                        WaitOutcome::WaitError(e) => KernelResponse::with_reason(
                            Verdict::NotAdmissible,
                            format!("subprocess wait error: {e}"),
                        ),
                    }
                }
                Err(e) => KernelResponse::with_reason(
                    Verdict::NotAdmissible,
                    format!("subprocess spawn error: {e}"),
                ),
            };

            // 5. Clean up temp file.  We don't propagate the
            //    cleanup error — a leaked temp file is debug-logged
            //    but doesn't block the response.
            if let Err(e) = std::fs::remove_file(&temp_path) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    tracing::debug!(path = ?temp_path, error = ?e, "temp-file cleanup failed");
                }
            }

            response
        }

        fn identifier(&self) -> &str {
            "knomosis-host-command/v1"
        }
    }

    /// Outcome of [`wait_with_timeout`].
    enum WaitOutcome {
        /// The child exited within the deadline with the supplied
        /// status.
        Exited(std::process::ExitStatus),
        /// The deadline elapsed before the child exited; the child
        /// was SIGKILLed.
        TimedOut,
        /// The wait itself failed (typically EINTR or a kernel
        /// bug); the child may or may not have exited.
        WaitError(std::io::Error),
    }

    /// Wait for `child` to exit, bounded by `timeout`.  If the
    /// deadline elapses, the child is SIGKILLed and reaped.
    fn wait_with_timeout(child: &mut std::process::Child, timeout: Duration) -> WaitOutcome {
        let deadline = Instant::now() + timeout;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return WaitOutcome::Exited(status),
                Ok(None) => {
                    if Instant::now() >= deadline {
                        // Timeout — escalate to SIGKILL + reap.
                        let _ = child.kill();
                        // Drain after the kill so the child entry
                        // doesn't leak as a zombie.
                        let _ = child.wait();
                        return WaitOutcome::TimedOut;
                    }
                    std::thread::sleep(WAIT_POLL_INTERVAL);
                }
                Err(e) => {
                    // try_wait failure is rare (EINTR, etc.).
                    // Surface as WaitError so the caller logs +
                    // reports NotAdmissible.  Attempt to reap.
                    let _ = child.kill();
                    let _ = child.wait();
                    return WaitOutcome::WaitError(e);
                }
            }
        }
    }

    /// Read up to `limit` bytes from `reader` into `out`.  Returns
    /// the number of bytes read.  Discards any further bytes
    /// (does not error).  Mirrors `std::io::Read::take` but
    /// preserves the underlying reader for cleanup.
    fn take_with_limit<R: Read>(reader: &mut R, out: &mut Vec<u8>, limit: usize) -> usize {
        let mut buf = [0u8; 4096];
        let mut total = 0usize;
        while total < limit {
            let want = (limit - total).min(buf.len());
            match reader.read(&mut buf[..want]) {
                // Any error or EOF (Ok(0)) ends the read.  We don't
                // distinguish — both mean "no more bytes" for the
                // diagnostic-stderr-capture use case.
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    out.extend_from_slice(&buf[..n]);
                    total = total.saturating_add(n);
                }
            }
        }
        total
    }

    #[cfg(test)]
    mod tests {
        use super::{CommandKernel, CommandKernelError, MAX_SUBPROCESS_OUTPUT};
        use crate::kernel::Kernel;
        use crate::verdict::Verdict;
        use std::path::PathBuf;
        use std::time::Duration;

        /// Constants are stable.
        #[test]
        fn constants_stable() {
            assert_eq!(MAX_SUBPROCESS_OUTPUT, 64 * 1024);
        }

        /// Missing binary returns `BinaryNotFound`.
        #[test]
        fn missing_binary_returns_error() {
            let temp = tempfile::tempdir().unwrap();
            let bogus = PathBuf::from("/nonexistent/knomosis");
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            match CommandKernel::new(bogus.clone(), log, work) {
                Err(CommandKernelError::BinaryNotFound(p)) => {
                    assert_eq!(p, bogus);
                }
                other => panic!("expected BinaryNotFound, got {other:?}"),
            }
        }

        /// Construct with an existing binary path (use `/bin/true`
        /// as a stand-in).
        #[test]
        fn construct_with_existing_binary() {
            let temp = tempfile::tempdir().unwrap();
            // /bin/true exists on every Linux test host.
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                eprintln!("skipping: /bin/true not present");
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(knomosis.clone(), log.clone(), work.clone()).unwrap();
            assert_eq!(kernel.knomosis_binary(), knomosis);
            assert_eq!(kernel.log_path(), log);
            assert_eq!(kernel.work_dir(), work);
        }

        /// Work directory is created if it doesn't exist.
        #[test]
        fn work_dir_created() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("nested").join("work");
            assert!(!work.exists());
            let _kernel = CommandKernel::new(knomosis, log, work.clone()).unwrap();
            assert!(work.is_dir());
        }

        /// `submit` with `/bin/true` returns `Ok` (exit code 0).
        #[test]
        fn submit_with_true_returns_ok() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(knomosis, log, work).unwrap();
            let response = kernel.submit(b"some bytes");
            assert_eq!(response.verdict, Verdict::Ok);
        }

        /// `submit` with `/bin/false` returns `NotAdmissible` (exit code 1).
        #[test]
        fn submit_with_false_returns_not_admissible() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/false");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(knomosis, log, work).unwrap();
            let response = kernel.submit(b"some bytes");
            assert_eq!(response.verdict, Verdict::NotAdmissible);
        }

        /// `submit` cleans up the temp file after the subprocess
        /// completes.  Counts files in the work dir before / after.
        #[test]
        fn submit_cleans_up_temp_file() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(knomosis, log, work.clone()).unwrap();
            kernel.submit(b"a");
            kernel.submit(b"b");
            kernel.submit(b"c");
            // Work dir should be empty (all temp files cleaned).
            let entries: Vec<_> = std::fs::read_dir(&work).unwrap().collect();
            assert!(entries.is_empty(), "work dir not cleaned: {entries:?}");
        }

        /// `with_deployment_id` carries the hex into the kernel
        /// state.  We can't easily test the resulting subprocess
        /// invocation without parsing argv, but the construction
        /// path is exercised.
        #[test]
        fn with_deployment_id_succeeds() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(knomosis, log, work)
                .unwrap()
                .with_deployment_id("0123456789abcdef");
            assert_eq!(kernel.submit(b"x").verdict, Verdict::Ok);
        }

        /// `with_timeout` adjusts the timeout field.
        #[test]
        fn with_timeout_succeeds() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let _kernel = CommandKernel::new(knomosis, log, work)
                .unwrap()
                .with_timeout(Duration::from_secs(5));
        }

        /// Identifier is the documented v1 string.
        #[test]
        fn identifier_constant() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(knomosis, log, work).unwrap();
            assert_eq!(kernel.identifier(), "knomosis-host-command/v1");
        }

        /// `CommandKernel` is `Send + Sync` for the worker thread.
        #[test]
        fn is_send_sync() {
            fn assert_send_sync<T: Send + Sync>() {}
            assert_send_sync::<CommandKernel>();
        }

        /// `CommandKernelError::BinaryNotFound` is `Send + Sync`
        /// (carried up by `?` from the constructor).
        #[test]
        fn error_is_send_sync() {
            fn assert_send_sync<T: Send + Sync>() {}
            assert_send_sync::<CommandKernelError>();
        }

        /// AR-RHC #1: `with_timeout` actually bounds subprocess
        /// wall-time.  Previously `cmd.output()` blocked
        /// unconditionally so a wedged subprocess would hang the
        /// worker forever.
        ///
        /// We model the production knomosis binary's
        /// single-process-no-children shape by using
        /// `exec sleep 10` (the shell replaces itself with sleep,
        /// so there's exactly one process to kill — no orphan
        /// grandchild keeping the stderr pipe alive).
        #[test]
        fn timeout_bounds_subprocess_wall_time() {
            use std::os::unix::fs::PermissionsExt;
            let temp = tempfile::tempdir().unwrap();
            if !PathBuf::from("/bin/sleep").exists() {
                eprintln!("skipping: /bin/sleep not present");
                return;
            }
            // Single-process script: `exec sleep` replaces the
            // shell with sleep itself.  When we SIGKILL the
            // resulting process, the stderr pipe immediately
            // closes (no orphaned grandchild).  This mirrors the
            // production knomosis binary, which is a single Rust
            // process with no shell wrapper.
            let script_path = temp.path().join("slow.sh");
            std::fs::write(&script_path, "#!/bin/sh\nexec sleep 10\n").unwrap();
            std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755)).unwrap();
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = CommandKernel::new(script_path, log, work)
                .unwrap()
                .with_timeout(Duration::from_millis(200));
            let start = std::time::Instant::now();
            let response = kernel.submit(b"some bytes");
            let elapsed = start.elapsed();
            assert!(
                elapsed < Duration::from_secs(3),
                "submit took {elapsed:?}, expected <3s with 200ms timeout"
            );
            assert_eq!(response.verdict, Verdict::NotAdmissible);
            assert!(
                response.reason.contains("timeout") || response.reason.contains("SIGKILL"),
                "reason was: {}",
                response.reason
            );
        }

        /// AR-RHC #3: tempfile-based input file defends against
        /// pre-existing-symlink TOCTOU.  Previously `File::create`
        /// would follow a symlink, allowing a local attacker to
        /// pre-create the predictable temp path as a symlink to
        /// `/etc/passwd` (or a victim file) and have the kernel
        /// truncate + overwrite the target.  With
        /// `tempfile::NamedTempFile`, the temp name is random and
        /// `O_CREAT | O_EXCL` is set — neither pre-creation nor
        /// symlink-following is possible.  This test verifies a
        /// witness file is NOT clobbered when an attacker has
        /// write access to the work directory.
        #[test]
        fn temp_file_creation_doesnt_follow_symlinks() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            std::fs::create_dir_all(&work).unwrap();
            // Pre-create a "victim" file in another directory.
            let victim = temp.path().join("victim.txt");
            std::fs::write(&victim, b"protected operator data").unwrap();
            // Pre-create a symlink in the work directory that
            // SHOULD point at the victim.  With the predictable
            // temp-naming scheme (PID + counter), an attacker
            // could pre-create exactly the predicted path.  With
            // tempfile's random naming + O_EXCL, this can't
            // happen — but we simulate the strongest form of the
            // attack by pre-creating a sea of symlinks covering
            // the entire `knomosis-host-req-*` namespace.  The
            // attacker can't predict the random suffix.
            //
            // Construct kernel + invoke.  Even if the attacker
            // created many symlinks, tempfile's O_EXCL retries
            // with new random suffixes until one succeeds.
            let kernel = CommandKernel::new(knomosis, log, work.clone()).unwrap();
            // Pre-poison the work dir with one symlink at a
            // hand-picked path.  tempfile's random name will not
            // collide.
            #[cfg(unix)]
            std::os::unix::fs::symlink(&victim, work.join("knomosis-host-req-attacker.cbe"))
                .unwrap();
            kernel.submit(b"hello");
            // Victim file must be intact.
            let after = std::fs::read(&victim).unwrap();
            assert_eq!(
                after, b"protected operator data",
                "symlink attack succeeded: victim file was clobbered"
            );
        }

        /// Mutex poisoning in `spawn_lock` recovers gracefully
        /// (returns the inner guard) rather than panicking the
        /// worker.  This addresses AR-RHC #12: mutex `expect`
        /// previously crashed the worker on a poisoned mutex.
        #[test]
        fn spawn_lock_poisoning_recovers() {
            use std::sync::Arc;

            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = Arc::new(CommandKernel::new(knomosis, log, work).unwrap());
            let kernel_clone = Arc::clone(&kernel);
            // Spawn a thread that acquires the lock and panics
            // while holding it.  This poisons the mutex.
            let handle = std::thread::spawn(move || {
                let _guard = kernel_clone.spawn_lock.lock().unwrap();
                panic!("intentional panic to poison the mutex");
            });
            let _ = handle.join(); // poison delivered

            // Now a fresh submit should still succeed.  Pre-fix
            // (`.expect()`) would panic the test thread here.
            let response = kernel.submit(b"x");
            assert_eq!(response.verdict, Verdict::Ok);
        }

        /// Multiple concurrent calls (via threads) all complete
        /// without deadlock.  The spawn lock serialises them.
        #[test]
        fn concurrent_calls_serialise() {
            let temp = tempfile::tempdir().unwrap();
            let knomosis = PathBuf::from("/bin/true");
            if !knomosis.exists() {
                return;
            }
            let log = temp.path().join("log");
            let work = temp.path().join("work");
            let kernel = std::sync::Arc::new(CommandKernel::new(knomosis, log, work).unwrap());
            let mut handles = Vec::new();
            for _ in 0..8 {
                let k = std::sync::Arc::clone(&kernel);
                handles.push(std::thread::spawn(move || k.submit(b"x").verdict));
            }
            for h in handles {
                assert_eq!(h.join().unwrap(), Verdict::Ok);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Kernel, KernelResponse, SubscribableKernel, Subscription};
    use crate::admission::{AdmissionReceipt, AdmissionStage};

    /// The trait is object-safe (we use `Box<dyn Kernel>`).
    #[test]
    fn kernel_trait_is_object_safe() {
        struct Stub;
        impl Kernel for Stub {
            fn submit(&self, _: &[u8]) -> KernelResponse {
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "stub"
            }
        }
        // If trait isn't object-safe this fails to compile.
        let _k: Box<dyn Kernel> = Box::new(Stub);
    }

    /// Default `ok_admission_stage` on a stub kernel is
    /// `Finalized` — the conservative default for centralized
    /// synchronous kernels.
    #[test]
    fn default_ok_stage_is_finalized() {
        struct Stub;
        impl Kernel for Stub {
            fn submit(&self, _: &[u8]) -> KernelResponse {
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "stub"
            }
        }
        let k = Stub;
        assert_eq!(k.ok_admission_stage(), AdmissionStage::Finalized);
    }

    /// `SubscribableKernel` is `?Sized`-compatible — usable as a
    /// trait object via `Box<dyn SubscribableKernel>`.
    #[test]
    fn subscribable_kernel_is_object_safe() {
        struct Stub;
        impl Kernel for Stub {
            fn submit(&self, _: &[u8]) -> KernelResponse {
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "stub"
            }
        }
        impl SubscribableKernel for Stub {
            fn subscribe(&self, _: &[u8]) -> Option<Subscription> {
                None
            }
        }
        let _k: Box<dyn SubscribableKernel> = Box::new(Stub);
    }

    /// Default `SubscribableKernel::action_id_for` returns empty
    /// bytes (the "no subscription" signal).
    #[test]
    fn default_action_id_is_empty() {
        struct Stub;
        impl Kernel for Stub {
            fn submit(&self, _: &[u8]) -> KernelResponse {
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "stub"
            }
        }
        impl SubscribableKernel for Stub {
            fn subscribe(&self, _: &[u8]) -> Option<Subscription> {
                None
            }
        }
        let k = Stub;
        assert!(k.action_id_for(b"x").is_empty());
    }

    /// Default `SubscribableKernel::receipt_for` produces a
    /// receipt at the kernel's declared `ok_admission_stage`
    /// with the kernel's `action_id_for` bytes.
    #[test]
    fn default_receipt_matches_ok_stage_and_action_id() {
        struct Stub;
        impl Kernel for Stub {
            fn submit(&self, _: &[u8]) -> KernelResponse {
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "stub"
            }
            fn ok_admission_stage(&self) -> AdmissionStage {
                AdmissionStage::Sequenced
            }
        }
        impl SubscribableKernel for Stub {
            fn subscribe(&self, _: &[u8]) -> Option<Subscription> {
                None
            }
            fn action_id_for(&self, bytes: &[u8]) -> Vec<u8> {
                bytes.to_vec()
            }
        }
        let k = Stub;
        let receipt = k.receipt_for(b"hello");
        assert_eq!(receipt.stage, AdmissionStage::Sequenced);
        assert_eq!(receipt.action_id, b"hello".to_vec());
    }

    /// Subscription event-stream semantics: caller observes
    /// stages via `try_recv`/`recv_timeout` exhaustively until
    /// `TryRecvError::Disconnected` indicates the kernel has
    /// concluded the action.  This test exercises the three
    /// `TryRecvError` arms explicitly.
    #[test]
    fn subscription_try_recv_arm_semantics() {
        use std::sync::mpsc::{channel, TryRecvError};
        let (tx, rx) = channel::<AdmissionStage>();
        let sub = Subscription {
            current: AdmissionStage::LocallyAdmitted,
            events: rx,
        };
        // Empty + sender alive → Empty arm.
        assert!(matches!(sub.events.try_recv(), Err(TryRecvError::Empty)));
        // Send one event; try_recv yields it.
        tx.send(AdmissionStage::Sequenced).unwrap();
        assert_eq!(sub.events.try_recv().unwrap(), AdmissionStage::Sequenced);
        // After draining the pending event, still Empty.
        assert!(matches!(sub.events.try_recv(), Err(TryRecvError::Empty)));
        // Drop the sender; try_recv now reports Disconnected.
        drop(tx);
        assert!(matches!(
            sub.events.try_recv(),
            Err(TryRecvError::Disconnected)
        ));
    }

    /// Sender-drop ordering with buffered events: try_recv
    /// drains buffered events FIRST, then reports
    /// `Disconnected` once empty.  This is the std::sync::mpsc
    /// contract; callers writing drain loops can rely on it.
    #[test]
    fn subscription_drains_before_reporting_disconnected() {
        use std::sync::mpsc::{channel, TryRecvError};
        let (tx, rx) = channel::<AdmissionStage>();
        tx.send(AdmissionStage::Sequenced).unwrap();
        tx.send(AdmissionStage::Finalized).unwrap();
        drop(tx);
        let sub = Subscription {
            current: AdmissionStage::LocallyAdmitted,
            events: rx,
        };
        assert_eq!(sub.events.try_recv().unwrap(), AdmissionStage::Sequenced);
        assert_eq!(sub.events.try_recv().unwrap(), AdmissionStage::Finalized);
        assert!(matches!(
            sub.events.try_recv(),
            Err(TryRecvError::Disconnected)
        ));
    }

    /// **Worked example**: a `StagingKernel` test fixture that
    /// emits a `LocallyAdmitted → Sequenced → Finalized` chain
    /// for every submitted action, demonstrating the canonical
    /// staging flow a future `ConsensusKernel` would follow.
    ///
    /// The fixture follows the [`Subscription`] atomic-snapshot
    /// rule: a single `Mutex` guards each action slot, and BOTH
    /// the driver-side advance (`current = X; tx.send(X)`) AND
    /// the subscriber-side snapshot (`let cur = current; let rx
    /// = tx_clone_or_take`) are performed while holding it.
    /// This eliminates the duplicate-event race the audit flagged
    /// in finding #8.
    ///
    /// **Strict-monotonicity check.**  The subscriber asserts
    /// `prev < next` (strict) rather than `prev <= next`,
    /// witnessing that the trait's contract holds for this
    /// implementation.
    #[test]
    fn staging_kernel_emits_strictly_monotonic_chain() {
        use std::collections::HashMap;
        use std::sync::mpsc::{channel, Receiver, Sender};
        use std::sync::Mutex;
        use std::time::Duration;

        /// Per-action state.  The single `Mutex<ActionSlot>`
        /// guarding it is the synchronisation primitive whose
        /// scope satisfies the atomic-snapshot rule.
        struct ActionSlot {
            current: AdmissionStage,
            tx: Sender<AdmissionStage>,
            /// Single-subscriber fixture: the receiver moves into
            /// the first `Subscription`; subsequent `subscribe`
            /// calls return None.
            rx: Option<Receiver<AdmissionStage>>,
        }

        struct StagingKernel {
            actions: Mutex<HashMap<Vec<u8>, ActionSlot>>,
        }

        impl StagingKernel {
            /// Canonical driver: advances an action's stage AND
            /// emits the corresponding event while holding the
            /// slot's mutex.  This is the pattern the contract
            /// requires of production implementations.
            fn advance(&self, action_id: &[u8], next: AdmissionStage) {
                let mut guard = self.actions.lock().unwrap();
                let slot = guard.get_mut(action_id).expect("known action");
                assert!(
                    next > slot.current,
                    "advance must be strictly increasing: {:?} -> {:?}",
                    slot.current,
                    next
                );
                slot.current = next;
                slot.tx.send(next).expect("subscriber alive");
            }
        }

        impl Kernel for StagingKernel {
            fn submit(&self, bytes: &[u8]) -> KernelResponse {
                let action_id = bytes.to_vec();
                let (tx, rx) = channel();
                self.actions.lock().unwrap().insert(
                    action_id,
                    ActionSlot {
                        current: AdmissionStage::LocallyAdmitted,
                        tx,
                        rx: Some(rx),
                    },
                );
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "staging/v1"
            }
            fn ok_admission_stage(&self) -> AdmissionStage {
                AdmissionStage::LocallyAdmitted
            }
        }

        impl SubscribableKernel for StagingKernel {
            fn subscribe(&self, action_id: &[u8]) -> Option<Subscription> {
                // Hold the mutex across BOTH the snapshot of
                // `current` and the take of `rx`.  Any concurrent
                // `advance()` is blocked on the same mutex, so
                // the snapshot is consistent: events buffered
                // before this point are all `≤ current`; events
                // sent after will be `> current`.
                let mut guard = self.actions.lock().unwrap();
                let slot = guard.get_mut(action_id)?;
                let rx = slot.rx.take()?;
                Some(Subscription {
                    current: slot.current,
                    events: rx,
                })
            }
            fn action_id_for(&self, bytes: &[u8]) -> Vec<u8> {
                bytes.to_vec()
            }
        }

        let kernel = StagingKernel {
            actions: Mutex::new(HashMap::new()),
        };
        let r = kernel.submit(b"action-1");
        assert_eq!(r.verdict, crate::verdict::Verdict::Ok);
        assert_eq!(kernel.ok_admission_stage(), AdmissionStage::LocallyAdmitted);

        let sub = kernel.subscribe(b"action-1").expect("subscription");
        assert_eq!(sub.current, AdmissionStage::LocallyAdmitted);

        // Drive subsequent stages via the canonical advance() helper.
        kernel.advance(b"action-1", AdmissionStage::Sequenced);
        kernel.advance(b"action-1", AdmissionStage::Finalized);

        // Observe.  STRICT monotonicity (each event > previous).
        let mut prev = sub.current;
        let mut observed = vec![prev];
        while let Ok(s) = sub.events.recv_timeout(Duration::from_millis(50)) {
            assert!(prev < s, "strict monotonicity violated: {prev:?} -> {s:?}");
            observed.push(s);
            prev = s;
        }
        assert_eq!(
            observed,
            vec![
                AdmissionStage::LocallyAdmitted,
                AdmissionStage::Sequenced,
                AdmissionStage::Finalized,
            ]
        );

        // Second subscribe returns None (receiver claimed).
        assert!(kernel.subscribe(b"action-1").is_none());

        // Unknown action returns None.
        assert!(kernel.subscribe(b"never-submitted").is_none());

        // `receipt_for` builds a stage receipt with the kernel's
        // declared stage + the test-defined action_id.
        let receipt = kernel.receipt_for(b"action-2");
        assert_eq!(receipt.stage, AdmissionStage::LocallyAdmitted);
        assert_eq!(receipt.action_id, b"action-2".to_vec());

        // `AdmissionReceipt::finalized` is the canonical
        // centralized-kernel constructor.
        let centralized = AdmissionReceipt::finalized();
        assert_eq!(centralized.stage, AdmissionStage::Finalized);
    }

    /// AR-RHC-audit-2 #8 / audit-3 #1: subscribe-during-advance
    /// race.  This test demonstrates that a correctly-implemented
    /// `SubscribableKernel` satisfies strict-increasing
    /// monotonicity under BOTH possible race orderings:
    ///
    ///   1. **subscribe-before-advance**: subscriber registers
    ///      before any advance() runs.  Observes
    ///      `[LocallyAdmitted, Sequenced, Finalized]`.
    ///   2. **subscribe-after-advance**: subscriber registers
    ///      AFTER the advancer has driven the action all the way
    ///      to Finalized.  Observes `[Finalized]` ONLY — the
    ///      buffered `Sequenced` event was drained inside
    ///      `subscribe()` (because it's ≤ current=Finalized).
    ///
    /// The fixture's `subscribe()` follows the canonical
    /// "atomic snapshot rule" by draining the channel under the
    /// mutex AFTER reading `current`: every buffered event is ≤
    /// current (since the advance held the same mutex), so
    /// discarding them all leaves the channel empty.  Future
    /// advances send strictly-greater events, satisfying the
    /// strict-increasing contract.
    ///
    /// Without the drain, the subscribe-after-advance scenario
    /// would observe `[Finalized, Sequenced, Finalized]` —
    /// strict-monotonicity violation.  Audit-3 #1 found this
    /// bug in the original fixture.
    #[test]
    fn subscribe_during_advance_no_duplicate_events() {
        use std::collections::HashMap;
        use std::sync::mpsc::{channel, Receiver, Sender};
        use std::sync::Mutex;
        use std::time::Duration;

        struct ActionSlot {
            current: AdmissionStage,
            tx: Sender<AdmissionStage>,
            rx: Option<Receiver<AdmissionStage>>,
        }
        struct StagingKernel {
            actions: Mutex<HashMap<Vec<u8>, ActionSlot>>,
        }
        impl StagingKernel {
            fn advance(&self, action_id: &[u8], next: AdmissionStage) {
                let mut guard = self.actions.lock().unwrap();
                let slot = guard.get_mut(action_id).expect("known action");
                if next > slot.current {
                    slot.current = next;
                    let _ = slot.tx.send(next);
                }
            }
        }
        impl Kernel for StagingKernel {
            fn submit(&self, bytes: &[u8]) -> KernelResponse {
                let (tx, rx) = channel();
                self.actions.lock().unwrap().insert(
                    bytes.to_vec(),
                    ActionSlot {
                        current: AdmissionStage::LocallyAdmitted,
                        tx,
                        rx: Some(rx),
                    },
                );
                KernelResponse::from_verdict(crate::verdict::Verdict::Ok)
            }
            fn identifier(&self) -> &str {
                "racy-stage/v1"
            }
            fn ok_admission_stage(&self) -> AdmissionStage {
                AdmissionStage::LocallyAdmitted
            }
        }
        impl SubscribableKernel for StagingKernel {
            fn subscribe(&self, action_id: &[u8]) -> Option<Subscription> {
                // Hold the mutex across BOTH:
                //   (a) reading `slot.current`
                //   (b) draining any channel-buffered events ≤
                //       current that were sent before subscribe.
                // Step (b) is the load-bearing fix audit-3 #1
                // identified: without it, a late subscriber would
                // see `current = Finalized` AND a buffered
                // `Sequenced` event still in the channel,
                // violating strict-monotonicity.
                let mut guard = self.actions.lock().unwrap();
                let slot = guard.get_mut(action_id)?;
                let current = slot.current;
                let rx = slot.rx.take()?;
                // Drain buffered events.  Under the mutex, no
                // concurrent advance can send; after this loop
                // returns Empty, the channel is empty.  Every
                // drained event satisfies `event <= current`
                // because advance() is monotonically increasing
                // and updates `current` under this same mutex.
                while rx.try_recv().is_ok() {}
                Some(Subscription {
                    current,
                    events: rx,
                })
            }
        }

        // --- Scenario 1: subscribe-before-advance ---
        let kernel = std::sync::Arc::new(StagingKernel {
            actions: Mutex::new(HashMap::new()),
        });
        kernel.submit(b"a1");
        let sub1 = kernel.subscribe(b"a1").expect("sub1");
        assert_eq!(sub1.current, AdmissionStage::LocallyAdmitted);
        kernel.advance(b"a1", AdmissionStage::Sequenced);
        kernel.advance(b"a1", AdmissionStage::Finalized);

        let mut observed1 = vec![sub1.current];
        while let Ok(s) = sub1.events.recv_timeout(Duration::from_millis(50)) {
            observed1.push(s);
        }
        // STRICT monotonicity: each event > previous.
        for window in observed1.windows(2) {
            assert!(
                window[0] < window[1],
                "scenario 1: duplicate / regressing stage at {observed1:?}"
            );
        }
        assert_eq!(
            observed1,
            vec![
                AdmissionStage::LocallyAdmitted,
                AdmissionStage::Sequenced,
                AdmissionStage::Finalized,
            ],
            "scenario 1: subscribe-before-advance must observe full chain"
        );

        // --- Scenario 2: subscribe-AFTER-advance (the bug case) ---
        kernel.submit(b"a2");
        // Drive the advancer fully BEFORE subscribing.  This is
        // the ordering the original audit-3 test missed.
        kernel.advance(b"a2", AdmissionStage::Sequenced);
        kernel.advance(b"a2", AdmissionStage::Finalized);

        let sub2 = kernel.subscribe(b"a2").expect("sub2");
        // With the drain in subscribe(), buffered Sequenced and
        // Finalized events are discarded under the mutex.
        // Subscriber observes only the snapshot current = Finalized.
        assert_eq!(sub2.current, AdmissionStage::Finalized);
        let mut observed2 = vec![sub2.current];
        while let Ok(s) = sub2.events.recv_timeout(Duration::from_millis(50)) {
            observed2.push(s);
        }
        // STRICT monotonicity: each event > previous (vacuously
        // true if observed2.len() == 1).
        for window in observed2.windows(2) {
            assert!(
                window[0] < window[1],
                "scenario 2: duplicate / regressing stage at {observed2:?}"
            );
        }
        // The observed sequence MUST be exactly [Finalized] —
        // no buffered events leak through.
        assert_eq!(
            observed2,
            vec![AdmissionStage::Finalized],
            "scenario 2: subscribe-after-advance must drain buffered events"
        );

        // --- Scenario 3: concurrent advancer + subscriber ---
        // The previous version of this test had a 5ms sleep in
        // the advancer that always let the subscriber win the
        // race.  We now run both orderings deterministically via
        // scenarios 1 and 2; the concurrent case below confirms
        // strict monotonicity under genuine race conditions
        // without making any timing assumption.
        let kernel_c = std::sync::Arc::clone(&kernel);
        kernel.submit(b"a3");
        let advancer = std::thread::spawn(move || {
            kernel_c.advance(b"a3", AdmissionStage::Sequenced);
            kernel_c.advance(b"a3", AdmissionStage::Finalized);
        });
        let sub3 = kernel.subscribe(b"a3").expect("sub3");
        advancer.join().unwrap();

        let mut observed3 = vec![sub3.current];
        while let Ok(s) = sub3.events.recv_timeout(Duration::from_millis(50)) {
            observed3.push(s);
        }
        // STRICT monotonicity holds regardless of race ordering.
        for window in observed3.windows(2) {
            assert!(
                window[0] < window[1],
                "scenario 3: duplicate / regressing stage at {observed3:?}"
            );
        }
        assert_eq!(
            *observed3.last().unwrap(),
            AdmissionStage::Finalized,
            "scenario 3: subscriber must eventually reach Finalized"
        );
        assert!(
            observed3[0] >= AdmissionStage::LocallyAdmitted,
            "scenario 3: initial stage must be at least LocallyAdmitted"
        );
    }
}
