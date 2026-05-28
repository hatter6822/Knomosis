// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Top-level error type for the observer crate.
//!
//! The observer accumulates errors from many subsystems (L1
//! source, game state machine, honest strategy, persistence,
//! transaction submitter).  This module consolidates them into a
//! single [`ObserverError`] so callers can pattern-match against a
//! flat enum without juggling layered `From` impls.
//!
//! ## Error severity
//!
//! Each variant carries an implicit severity that maps to the
//! `OperatorExitCode` discipline (`knomosis-cli-common::exit`):
//!
//!   * **Transient** — recoverable; caller retries with backoff.
//!     Examples: L1 RPC unreachable, transient submitter
//!     failures.  Maps to `OperatorExitCode::Transient (75)`.
//!   * **`OperatorAction`** — manual intervention required.
//!     Examples: deep re-org, persistent state corruption,
//!     keystore missing.  Maps to
//!     `OperatorExitCode::OperatorAction (2)`.
//!   * **Unavailable** — external service permanently failed
//!     (or the observer was misconfigured to talk to it).
//!     Examples: malformed L1 RPC responses across all retries.
//!     Maps to `OperatorExitCode::Unavailable (69)`.

use knomosis_cli_common::exit::OperatorExitCode;
use knomosis_l1_ingest::reorg::ReorgError;
use knomosis_l1_ingest::source::SourceError;
use knomosis_storage::storage::StorageError;

use crate::events::EventDecodeError;
use crate::game::GameError;
use crate::strategy::HonestMoveError;

/// Top-level observer error.
#[derive(Debug, thiserror::Error)]
#[allow(clippy::module_name_repetitions)]
pub enum ObserverError {
    /// L1 source / JSON-RPC transport error.
    #[error(transparent)]
    Source(#[from] SourceError),

    /// L1 re-org error.  Some variants (`DeepReorg`,
    /// `OrphanedParent`) are fatal — the operator must
    /// intervene.
    #[error(transparent)]
    Reorg(#[from] ReorgError),

    /// L1 event decoding error.
    #[error(transparent)]
    EventDecode(#[from] EventDecodeError),

    /// Game state machine error.
    #[error(transparent)]
    Game(#[from] GameError),

    /// Honest-strategy computation error.
    #[error(transparent)]
    Strategy(#[from] HonestMoveError),

    /// Storage layer error.
    #[error(transparent)]
    Storage(#[from] StorageError),

    /// Submitter / transaction error.
    #[error("submitter error: {0}")]
    Submitter(String),

    /// Cryptographic / key-management error.
    #[error("cryptographic error: {0}")]
    Crypto(String),

    /// Configuration error — invalid CLI flag combinations,
    /// missing files, etc.
    #[error("configuration error: {0}")]
    Config(String),

    /// Logical invariant violation — indicates a bug in the
    /// observer (e.g., an unknown game id reported by L1).  The
    /// daemon halts.
    #[error("invariant violation: {0}")]
    Invariant(String),
}

impl ObserverError {
    /// Map an `ObserverError` to its corresponding
    /// `OperatorExitCode`.  Used by `main.rs` to drive the
    /// process's exit status.
    #[must_use]
    pub fn exit_code(&self) -> OperatorExitCode {
        match self {
            // Transient: retry with backoff.
            //
            // `ReorgError::NonMonotone` is a transient
            // upstream-RPC bug: the L1 source returned a
            // block-number gap, which the watcher recovers from
            // by re-fetching.  Per `knomosis-l1-ingest::reorg`'s
            // docstring, "the watcher must back off and retry".
            Self::Source(SourceError::Transport(_) | SourceError::BlockNotFound(_))
            | Self::Reorg(ReorgError::NonMonotone { .. }) => OperatorExitCode::Transient,

            // OperatorAction: manual intervention.  Deep re-orgs
            // and orphaned-parent inconsistencies signal an L1
            // chain reorganisation deeper than the observer's
            // sliding window — the operator must intervene
            // (replay window expansion, manual cursor reset).
            Self::Reorg(ReorgError::DeepReorg { .. } | ReorgError::OrphanedParent { .. })
            | Self::Config(_)
            | Self::Crypto(_)
            | Self::Invariant(_) => OperatorExitCode::OperatorAction,

            // Unavailable: external service permanently broken.
            Self::Source(SourceError::Malformed(_)) | Self::EventDecode(_) => {
                OperatorExitCode::Unavailable
            }

            // The remaining variants are inconclusive — default
            // to OperatorAction (the most conservative response
            // is "halt and let a human look").  The arms are kept
            // separate from the explicitly-listed OperatorAction
            // category above for readability; clippy's
            // match_same_arms is allowed locally.
            #[allow(clippy::match_same_arms)]
            Self::Game(_) | Self::Strategy(_) | Self::Storage(_) | Self::Submitter(_) => {
                OperatorExitCode::OperatorAction
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ObserverError;
    use knomosis_cli_common::exit::OperatorExitCode;
    use knomosis_l1_ingest::reorg::ReorgError;
    use knomosis_l1_ingest::source::SourceError;

    /// `Transport` errors map to `Transient`.
    #[test]
    fn transport_error_is_transient() {
        let err = ObserverError::Source(SourceError::Transport("connection refused".into()));
        assert_eq!(err.exit_code(), OperatorExitCode::Transient);
    }

    /// `DeepReorg` maps to `OperatorAction`.
    #[test]
    fn deep_reorg_is_operator_action() {
        let err = ObserverError::Reorg(ReorgError::DeepReorg {
            incoming_number: 1,
            window_floor: 100,
        });
        assert_eq!(err.exit_code(), OperatorExitCode::OperatorAction);
    }

    /// `OrphanedParent` maps to `OperatorAction`.
    #[test]
    fn orphaned_parent_is_operator_action() {
        let err = ObserverError::Reorg(ReorgError::OrphanedParent { incoming_number: 1 });
        assert_eq!(err.exit_code(), OperatorExitCode::OperatorAction);
    }

    /// `NonMonotone` reorg maps to `Transient` (recoverable via
    /// back-off + retry, per the `knomosis-l1-ingest::reorg` docstring).
    #[test]
    fn non_monotone_reorg_is_transient() {
        let err = ObserverError::Reorg(ReorgError::NonMonotone {
            incoming_number: 105,
            last_seen: 100,
        });
        assert_eq!(err.exit_code(), OperatorExitCode::Transient);
    }

    /// `Malformed` source response maps to `Unavailable`.
    #[test]
    fn malformed_source_is_unavailable() {
        let err = ObserverError::Source(SourceError::Malformed("bad JSON".into()));
        assert_eq!(err.exit_code(), OperatorExitCode::Unavailable);
    }

    /// `Config` errors map to `OperatorAction`.
    #[test]
    fn config_error_is_operator_action() {
        let err = ObserverError::Config("missing flag".into());
        assert_eq!(err.exit_code(), OperatorExitCode::OperatorAction);
    }

    /// `Crypto` errors map to `OperatorAction`.
    #[test]
    fn crypto_error_is_operator_action() {
        let err = ObserverError::Crypto("bad keystore".into());
        assert_eq!(err.exit_code(), OperatorExitCode::OperatorAction);
    }

    /// `Invariant` errors map to `OperatorAction`.
    #[test]
    fn invariant_error_is_operator_action() {
        let err = ObserverError::Invariant("impossible".into());
        assert_eq!(err.exit_code(), OperatorExitCode::OperatorAction);
    }

    /// `Submitter` errors map to `OperatorAction`.
    #[test]
    fn submitter_error_is_operator_action() {
        let err = ObserverError::Submitter("dropped tx".into());
        assert_eq!(err.exit_code(), OperatorExitCode::OperatorAction);
    }
}
