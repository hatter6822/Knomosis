// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Canonical exit-code discipline for the Knomosis Rust binaries.
//!
//! Every Knomosis Rust binary returns one of the documented exit codes
//! enumerated by [`OperatorExitCode`].  Operators consume the exit
//! code to drive supervisor decisions (restart on `Transient`,
//! escalate on `Permanent`, leave alone on `Success`); CI consumes
//! it to distinguish "test failure" from "harness misconfiguration".
//!
//! The codes are stable across the workspace: changing a code is a
//! workspace-level PR per the engineering-plan §7 risk register.

/// Stable exit-code enumeration for Knomosis Rust binaries.
///
/// The numeric values mirror the documented operator runbook
/// discipline: `0` is success; `2` is "operator must intervene"
/// (this binary cannot make progress without external action); `3`
/// is "skeleton, not yet implemented" (the binary's work unit is on
/// the roadmap but hasn't shipped); `64` and above are reserved for
/// transient / recoverable failures (per `sysexits.h` convention).
///
/// Per the standard Unix convention, `1` is reserved for "general
/// failure" (the default when a binary panics through to libc).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum OperatorExitCode {
    /// Normal completion.
    Success = 0,
    /// General failure (caller-side issue; matches the libc default
    /// when a program exits without an explicit code).
    GeneralFailure = 1,
    /// Operator-actionable failure: a runtime condition the binary
    /// cannot resolve itself.  Examples: keystore not found,
    /// configuration invalid, fault-proof watcher's L1 RPC
    /// unreachable beyond the retry budget.
    OperatorAction = 2,
    /// The binary is a skeleton; the implementing work unit (per
    /// `docs/planning/rust_host_runtime_plan.md` §4) has not yet
    /// landed.  This code is distinct from `GeneralFailure` so
    /// supervisors do not retry an unimplemented binary in a loop.
    NotImplemented = 3,
    /// Transient failure: caller is expected to retry with backoff.
    /// Maps to the `EX_TEMPFAIL` family in `sysexits.h` (75).
    Transient = 75,
    /// Permanent failure of an external service the binary depends
    /// on (e.g. an L1 RPC endpoint has returned malformed data).
    /// Maps to the `EX_UNAVAILABLE` family (69).
    Unavailable = 69,
}

impl OperatorExitCode {
    /// Return the numeric code as an `i32`, suitable for
    /// `std::process::exit`.
    #[must_use]
    pub const fn as_i32(self) -> i32 {
        self as i32
    }

    /// Terminate the current process with this exit code.
    ///
    /// Wraps `std::process::exit` so call sites read like
    /// `OperatorExitCode::NotImplemented.terminate()`.  The function
    /// is `-> !` (diverging) which lets it appear in any
    /// position cargo's flow analysis expects a fall-through.
    pub fn terminate(self) -> ! {
        std::process::exit(self.as_i32())
    }
}

#[cfg(test)]
mod tests {
    use super::OperatorExitCode;

    /// Numeric codes are stable.  These constants are part of the
    /// operator-facing contract; changing one is a workspace-level
    /// PR.
    #[test]
    fn numeric_codes_stable() {
        assert_eq!(OperatorExitCode::Success.as_i32(), 0);
        assert_eq!(OperatorExitCode::GeneralFailure.as_i32(), 1);
        assert_eq!(OperatorExitCode::OperatorAction.as_i32(), 2);
        assert_eq!(OperatorExitCode::NotImplemented.as_i32(), 3);
        assert_eq!(OperatorExitCode::Transient.as_i32(), 75);
        assert_eq!(OperatorExitCode::Unavailable.as_i32(), 69);
    }

    /// Codes are distinct (no aliasing between variants).
    #[test]
    fn codes_distinct() {
        let mut codes = vec![
            OperatorExitCode::Success.as_i32(),
            OperatorExitCode::GeneralFailure.as_i32(),
            OperatorExitCode::OperatorAction.as_i32(),
            OperatorExitCode::NotImplemented.as_i32(),
            OperatorExitCode::Transient.as_i32(),
            OperatorExitCode::Unavailable.as_i32(),
        ];
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), 6, "exit codes must be pairwise distinct");
    }
}
