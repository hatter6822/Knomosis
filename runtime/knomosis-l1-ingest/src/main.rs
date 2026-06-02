// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-l1-ingest` — RH-B entry point binary.
//!
//! Production deployments invoke this binary with the
//! configuration flags documented in §RH-B.1 of the engineering
//! plan.  The watcher loop runs synchronously until it reaches
//! the configured `--until-block` (or, by default, runs
//! indefinitely until killed).
//!
//! ## Graceful shutdown
//!
//! The current entry point does NOT install custom SIGINT /
//! SIGTERM handlers — Ctrl-C delivers the default libc
//! behaviour (immediate process termination).  Because every
//! state mutation is durable on disk via the atomic `Submitted`
//! record (see [`knomosis_l1_ingest::state`]), an interrupt at
//! ANY point produces a consistent state file: either the
//! submission completed and was recorded, or the submission was
//! never attempted and the watcher resumes from the
//! `last_confirmed_block` checkpoint.
//!
//! Operators wanting cooperative shutdown should wrap this
//! binary in a supervisor (systemd, runit, etc.) that monitors
//! the exit code and restarts on transient failures.  A
//! follow-up work unit could land a `signal-hook`-backed
//! handler that flips the `stop` `AtomicBool`; the watcher
//! loop already polls the flag at the top of each iteration.
//!
//! ## CLI flags
//!
//! | Flag                            | Required | Description                                                          |
//! |---------------------------------|----------|----------------------------------------------------------------------|
//! | `--l1-rpc <URL>`                | yes      | Ethereum JSON-RPC endpoint (e.g. `http://localhost:8545`)           |
//! | `--bridge-actor-keystore <PATH>`| yes      | Raw 32-byte secp256k1 private key file                              |
//! | `--knomosis-host-url <URL>`     | one of   | `knomosis-host` HTTP POST endpoint (placeholder transport)          |
//! | `--knomosis-host-tcp <ADDR>`    | one of   | `knomosis-host` raw-TCP listener (`host:port`; canonical wire format, FQ.13a) |
//! | `--bridge-contract <HEX>`       | yes      | 20-byte hex address of the L1 `KnomosisBridge.sol` instance            |
//! | `--identity-registry <HEX>`     | yes      | 20-byte hex address of the L1 `KnomosisIdentityRegistry.sol` instance  |
//! | `--state-file <PATH>`           | yes      | Watcher persistent-state file (JSONL)                                |
//! | `--emit-signer-hints`           | no       | Emit Rung-1 `KNH2` signer hints (raw-TCP only; default off, FQ.13a)  |
//! | `--deployment-id <HEX>`         | no       | 32-byte deployment id for signing input (default: empty)            |
//! | `--confirmation-depth <N>`      | no       | L1 confirmations before forwarding (default: 12)                    |
//! | `--poll-interval-ms <N>`        | no       | Polling interval in milliseconds (default: 12000)                   |
//! | `--until-block <N>`             | no       | Exit cleanly once `last_confirmed_block >= N`                       |
//! | `--help` / `-h`                 |          | Print this usage block                                              |
//! | `--version` / `-v`              |          | Print the crate version                                             |
//!
//! ## Exit codes
//!
//! Per `knomosis-cli-common::exit::OperatorExitCode`:
//!
//!   * `0` — clean exit (reached `--until-block` or stop signal).
//!   * `1` — general failure (CLI / config parse, file I/O).
//!   * `2` — operator-actionable failure (deep re-org,
//!     `NotAdmissible` verdict, `ParseError` verdict).
//!   * `75` — transient (network / RPC errors that may resolve).

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use knomosis_cli_common::exit::OperatorExitCode;
use knomosis_cli_common::paths::DEFAULT_L1_CONFIRMATION_DEPTH;
use knomosis_l1_ingest::action::EthAddress;
use knomosis_l1_ingest::key::BridgeActorKey;
use knomosis_l1_ingest::source::json_rpc::JsonRpcL1Source;
use knomosis_l1_ingest::submitter::http::HttpSubmitter;
use knomosis_l1_ingest::submitter::raw_tcp::RawTcpSubmitter;
use knomosis_l1_ingest::submitter::{SubmitError, Submitter};
use knomosis_l1_ingest::watcher::{WatcherConfig, WatcherError, WatcherLoop};
use knomosis_l1_ingest::INGEST_IDENTIFIER;
use tracing::{error, info, Level};

fn main() -> ExitCode {
    // Parse CLI args from `std::env::args` (no `clap` dependency
    // — the flag set is small and stable).
    let args: Vec<String> = std::env::args().collect();
    let parsed = match parse_args(&args) {
        Ok(p) => p,
        Err(ParseExit::Help) => {
            print_help(&args[0]);
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(ParseExit::Version) => {
            println!("{} v{}", INGEST_IDENTIFIER, env!("CARGO_PKG_VERSION"));
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(ParseExit::Error(msg)) => {
            eprintln!("knomosis-l1-ingest: {msg}");
            eprintln!("Use --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };

    // Initialise structured logging.
    if let Err(e) = knomosis_cli_common::logging::init(Level::INFO) {
        eprintln!("knomosis-l1-ingest: logging init failed: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }

    // Load the bridge-actor keystore.
    let key = match BridgeActorKey::from_file(&parsed.keystore_path) {
        Ok(k) => k,
        Err(e) => {
            error!(error = %e, "failed to load bridge-actor keystore");
            return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
        }
    };
    info!(
        "loaded bridge-actor key (pk: 0x{})",
        hex_encode(&key.public_key_compressed())
    );

    // Wire up source.
    let source = match JsonRpcL1Source::new(parsed.l1_rpc) {
        Ok(s) => s,
        Err(e) => {
            error!(error = %e, "invalid --l1-rpc URL");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };

    // Wire up submitter (FQ.13a).  The canonical raw-TCP submitter when
    // `--knomosis-host-tcp` is given (optionally emitting Rung-1 signer
    // hints), else the HTTP placeholder.  Boxed as `dyn Submitter` so the
    // generic `WatcherLoop` is monomorphised once for either transport.
    let submitter: Box<dyn Submitter> = if let Some(tcp_addr) = parsed.knomosis_host_tcp {
        match RawTcpSubmitter::new(tcp_addr) {
            Ok(s) => {
                let s = s.with_emit_hints(parsed.emit_signer_hints);
                info!(
                    addr = s.addr(),
                    emit_signer_hints = s.emits_hints(),
                    "using raw-TCP knomosis-host submitter"
                );
                Box::new(s)
            }
            Err(e) => {
                error!(error = %e, "invalid --knomosis-host-tcp");
                return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
            }
        }
    } else {
        let url = parsed
            .knomosis_host_url
            .expect("parse validation guarantees exactly one of --knomosis-host-url / -tcp");
        match HttpSubmitter::new(url) {
            Ok(s) => Box::new(s),
            Err(e) => {
                error!(error = %e, "invalid --knomosis-host-url");
                return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
            }
        }
    };

    // Build config.
    let mut config = WatcherConfig::new(
        parsed.bridge_contract,
        parsed.identity_registry,
        parsed.deployment_id,
    );
    config.confirmation_depth = parsed.confirmation_depth;
    config.poll_interval = Duration::from_millis(parsed.poll_interval_ms);
    // Default reorg-window capacity to confirmation_depth + 4 unless the user opts in differently.
    config.reorg_window_capacity = (config.confirmation_depth as usize) + 4;

    // Construct watcher.
    let mut watcher = match WatcherLoop::new(config, source, submitter, key, &parsed.state_file) {
        Ok(w) => w,
        Err(e) => {
            error!(error = %e, "watcher construction failed");
            return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
        }
    };

    info!(
        last_confirmed = watcher.last_confirmed_block(),
        identifier = INGEST_IDENTIFIER,
        "knomosis-l1-ingest started"
    );

    let stop = Arc::new(AtomicBool::new(false));
    let until_block = parsed.until_block.unwrap_or(u64::MAX);
    match watcher.run_until(until_block, stop) {
        Ok(processed) => {
            info!(processed = processed, "watcher exited cleanly");
            ExitCode::from(OperatorExitCode::Success.as_i32() as u8)
        }
        Err(e) => {
            error!(error = %e, "watcher exited with error");
            let code = classify_error(&e);
            ExitCode::from(code.as_i32() as u8)
        }
    }
}

/// Map a `WatcherError` to an operator-facing exit code.
fn classify_error(e: &WatcherError) -> OperatorExitCode {
    // Match on the variants that map to `Transient` first; every
    // other variant maps to `OperatorAction`.  Splitting this way
    // avoids three identical-bodied match arms (clippy's
    // `match_same_arms` lint).
    match e {
        WatcherError::Submit(SubmitError::NotAdmissible | SubmitError::ParseError) => {
            OperatorExitCode::OperatorAction
        }
        WatcherError::Source(_) | WatcherError::Submit(_) => OperatorExitCode::Transient,
        _ => OperatorExitCode::OperatorAction,
    }
}

/// Parsed CLI flags.
struct ParsedArgs {
    l1_rpc: String,
    keystore_path: PathBuf,
    /// `--knomosis-host-url <URL>`: the HTTP/1.1 submitter endpoint
    /// (placeholder transport).  Mutually exclusive with
    /// `knomosis_host_tcp`; exactly one is required.
    knomosis_host_url: Option<String>,
    /// `--knomosis-host-tcp <ADDR>` (FQ.13a): the canonical raw-TCP
    /// `knomosis-host` listener endpoint (`host:port`).  Mutually
    /// exclusive with `knomosis_host_url`.
    knomosis_host_tcp: Option<String>,
    /// `--emit-signer-hints` (FQ.13a): emit Rung-1 `KNH2` preamble +
    /// per-frame signer hints on the raw-TCP submitter (requires
    /// `knomosis_host_tcp`).
    emit_signer_hints: bool,
    bridge_contract: EthAddress,
    identity_registry: EthAddress,
    state_file: PathBuf,
    deployment_id: Vec<u8>,
    confirmation_depth: u32,
    poll_interval_ms: u64,
    until_block: Option<u64>,
}

/// Result of CLI parsing.  `Help` / `Version` exit cleanly;
/// `Error` carries a diagnostic.
#[derive(Debug)]
enum ParseExit {
    Help,
    Version,
    Error(String),
}

/// Parse the CLI arguments.  Returns `Ok(parsed)` on success or
/// `Err(ParseExit::*)` to direct the caller's exit path.
fn parse_args(args: &[String]) -> Result<ParsedArgs, ParseExit> {
    let mut iter = args.iter().skip(1);
    let mut l1_rpc = None;
    let mut keystore_path = None;
    let mut knomosis_host_url = None;
    let mut knomosis_host_tcp = None;
    let mut emit_signer_hints = false;
    let mut bridge_contract = None;
    let mut identity_registry = None;
    let mut state_file = None;
    let mut deployment_id = Vec::new();
    let mut confirmation_depth = DEFAULT_L1_CONFIRMATION_DEPTH;
    let mut poll_interval_ms = 12_000u64;
    let mut until_block = None;
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--help" | "-h" => return Err(ParseExit::Help),
            "--version" | "-v" => return Err(ParseExit::Version),
            "--l1-rpc" => l1_rpc = Some(iter.next().ok_or_else(|| missing("--l1-rpc"))?.clone()),
            "--bridge-actor-keystore" => {
                keystore_path = Some(PathBuf::from(
                    iter.next()
                        .ok_or_else(|| missing("--bridge-actor-keystore"))?,
                ));
            }
            "--knomosis-host-url" => {
                knomosis_host_url = Some(
                    iter.next()
                        .ok_or_else(|| missing("--knomosis-host-url"))?
                        .clone(),
                );
            }
            "--knomosis-host-tcp" => {
                knomosis_host_tcp = Some(
                    iter.next()
                        .ok_or_else(|| missing("--knomosis-host-tcp"))?
                        .clone(),
                );
            }
            "--emit-signer-hints" => emit_signer_hints = true,
            "--bridge-contract" => {
                let hex = iter.next().ok_or_else(|| missing("--bridge-contract"))?;
                bridge_contract = Some(parse_address(hex).map_err(ParseExit::Error)?);
            }
            "--identity-registry" => {
                let hex = iter.next().ok_or_else(|| missing("--identity-registry"))?;
                identity_registry = Some(parse_address(hex).map_err(ParseExit::Error)?);
            }
            "--state-file" => {
                state_file = Some(PathBuf::from(
                    iter.next().ok_or_else(|| missing("--state-file"))?,
                ));
            }
            "--deployment-id" => {
                let hex = iter.next().ok_or_else(|| missing("--deployment-id"))?;
                deployment_id = parse_hex_bytes(hex).map_err(ParseExit::Error)?;
            }
            "--confirmation-depth" => {
                let n = iter.next().ok_or_else(|| missing("--confirmation-depth"))?;
                confirmation_depth = n.parse().map_err(|e| {
                    ParseExit::Error(format!("--confirmation-depth: invalid u32: {e}"))
                })?;
            }
            "--poll-interval-ms" => {
                let n = iter.next().ok_or_else(|| missing("--poll-interval-ms"))?;
                poll_interval_ms = n.parse().map_err(|e| {
                    ParseExit::Error(format!("--poll-interval-ms: invalid u64: {e}"))
                })?;
            }
            "--until-block" => {
                let n = iter.next().ok_or_else(|| missing("--until-block"))?;
                until_block =
                    Some(n.parse().map_err(|e| {
                        ParseExit::Error(format!("--until-block: invalid u64: {e}"))
                    })?);
            }
            other => {
                return Err(ParseExit::Error(format!("unknown argument: {other}")));
            }
        }
    }
    // FQ.13a: exactly one submitter endpoint is required.
    match (&knomosis_host_url, &knomosis_host_tcp) {
        (None, None) => {
            return Err(ParseExit::Error(
                "one of --knomosis-host-url or --knomosis-host-tcp is required".into(),
            ))
        }
        (Some(_), Some(_)) => {
            return Err(ParseExit::Error(
                "--knomosis-host-url and --knomosis-host-tcp are mutually exclusive".into(),
            ))
        }
        _ => {}
    }
    // Signer hints are a raw-TCP-only feature: the HTTP placeholder does
    // not speak the canonical knomosis-host wire format.
    if emit_signer_hints && knomosis_host_tcp.is_none() {
        return Err(ParseExit::Error(
            "--emit-signer-hints requires --knomosis-host-tcp (the HTTP submitter \
             does not speak the canonical wire format)"
                .into(),
        ));
    }
    Ok(ParsedArgs {
        l1_rpc: l1_rpc.ok_or_else(|| ParseExit::Error("--l1-rpc is required".into()))?,
        keystore_path: keystore_path
            .ok_or_else(|| ParseExit::Error("--bridge-actor-keystore is required".into()))?,
        knomosis_host_url,
        knomosis_host_tcp,
        emit_signer_hints,
        bridge_contract: bridge_contract
            .ok_or_else(|| ParseExit::Error("--bridge-contract is required".into()))?,
        identity_registry: identity_registry
            .ok_or_else(|| ParseExit::Error("--identity-registry is required".into()))?,
        state_file: state_file
            .ok_or_else(|| ParseExit::Error("--state-file is required".into()))?,
        deployment_id,
        confirmation_depth,
        poll_interval_ms,
        until_block,
    })
}

fn missing(flag: &str) -> ParseExit {
    ParseExit::Error(format!("{flag} requires a value"))
}

fn parse_address(s: &str) -> Result<EthAddress, String> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    if stripped.len() != 40 {
        return Err(format!(
            "address '{s}' expected 40 hex chars (20 bytes), got {}",
            stripped.len()
        ));
    }
    let bytes = parse_hex_bytes(s)?;
    EthAddress::from_bytes(&bytes).ok_or_else(|| format!("address '{s}' parse failed"))
}

fn parse_hex_bytes(s: &str) -> Result<Vec<u8>, String> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    if stripped.len() % 2 != 0 {
        return Err(format!("hex '{s}' has odd length"));
    }
    let mut out = Vec::with_capacity(stripped.len() / 2);
    for chunk in stripped.as_bytes().chunks(2) {
        let hi = hex_digit(chunk[0])?;
        let lo = hex_digit(chunk[1])?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn hex_digit(b: u8) -> Result<u8, String> {
    match b {
        b'0'..=b'9' => Ok(b - b'0'),
        b'a'..=b'f' => Ok(10 + b - b'a'),
        b'A'..=b'F' => Ok(10 + b - b'A'),
        _ => Err(format!("invalid hex character '{}'", b as char)),
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(hex_char(b >> 4));
        s.push(hex_char(b & 0x0f));
    }
    s
}

fn hex_char(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'a' + (n - 10)) as char,
        _ => '?',
    }
}

fn print_help(prog: &str) {
    println!("Usage: {prog} [OPTIONS]");
    println!();
    println!("Knomosis L1 event ingest daemon (RH-B).");
    println!();
    println!("Required options:");
    println!("  --l1-rpc <URL>                  Ethereum JSON-RPC endpoint");
    println!("  --bridge-actor-keystore <PATH>  Raw 32-byte secp256k1 private key file");
    println!("  --bridge-contract <HEX>         L1 KnomosisBridge address (20-byte hex)");
    println!("  --identity-registry <HEX>       L1 KnomosisIdentityRegistry address (20-byte hex)");
    println!("  --state-file <PATH>             Watcher persistent state file");
    println!();
    println!("Submitter (exactly one required):");
    println!("  --knomosis-host-url <URL>       knomosis-host HTTP POST endpoint (placeholder transport)");
    println!("  --knomosis-host-tcp <ADDR>      knomosis-host raw-TCP listener (host:port; canonical wire format)");
    println!();
    println!("Optional options:");
    println!("  --emit-signer-hints             Emit Rung-1 KNH2 signer hints (requires --knomosis-host-tcp; default off)");
    println!("  --deployment-id <HEX>           Deployment id for signing input (default: empty)");
    println!("  --confirmation-depth <N>        L1 confirmations before forwarding (default: 12)");
    println!("  --poll-interval-ms <N>          Polling interval in ms (default: 12000)");
    println!("  --until-block <N>               Exit once last_confirmed_block >= N");
    println!("  -h, --help                      Print this help");
    println!("  -v, --version                   Print version and exit");
}

#[cfg(test)]
mod tests {
    use super::{parse_args, ParseExit};

    fn argv(extra: &[&str]) -> Vec<String> {
        let mut v = vec!["knomosis-l1-ingest".to_string()];
        v.extend(extra.iter().map(|s| (*s).to_string()));
        v
    }

    /// Everything required EXCEPT a submitter endpoint, so submitter
    /// flags can be appended.  (The submitter-endpoint validation runs
    /// before the other `required` checks, so the error tests need only
    /// these to reach it; the OK tests need the full set.)
    fn base() -> Vec<&'static str> {
        vec![
            "--l1-rpc",
            "http://localhost:8545",
            "--bridge-actor-keystore",
            "/dev/null",
            "--bridge-contract",
            "0x1111111111111111111111111111111111111111",
            "--identity-registry",
            "0x2222222222222222222222222222222222222222",
            "--state-file",
            "/tmp/knomosis-ingest-state.jsonl",
        ]
    }

    fn err_message(args: &[&str]) -> String {
        match parse_args(&argv(args)) {
            Err(ParseExit::Error(e)) => e,
            Err(ParseExit::Help) => "HELP".into(),
            Err(ParseExit::Version) => "VERSION".into(),
            Ok(_) => "OK".into(),
        }
    }

    /// FQ.13a: neither submitter endpoint → a clear "one of" error.
    #[test]
    fn neither_submitter_endpoint_is_error() {
        assert!(err_message(&base()).contains("one of --knomosis-host-url"));
    }

    /// FQ.13a: both endpoints → "mutually exclusive".
    #[test]
    fn both_submitter_endpoints_is_error() {
        let mut args = base();
        args.extend_from_slice(&[
            "--knomosis-host-url",
            "http://localhost:9000",
            "--knomosis-host-tcp",
            "127.0.0.1:7654",
        ]);
        assert!(err_message(&args).contains("mutually exclusive"));
    }

    /// FQ.13a: `--emit-signer-hints` without `--knomosis-host-tcp` is
    /// rejected (the HTTP path can't speak the canonical wire format).
    #[test]
    fn emit_hints_without_tcp_is_error() {
        let mut args = base();
        args.extend_from_slice(&[
            "--knomosis-host-url",
            "http://localhost:9000",
            "--emit-signer-hints",
        ]);
        assert!(err_message(&args).contains("--emit-signer-hints requires --knomosis-host-tcp"));
    }

    /// FQ.13a: the HTTP endpoint alone parses cleanly (no hints).
    #[test]
    fn http_endpoint_alone_parses() {
        let mut args = base();
        args.extend_from_slice(&["--knomosis-host-url", "http://localhost:9000"]);
        let parsed = parse_args(&argv(&args)).expect("parses");
        assert_eq!(
            parsed.knomosis_host_url.as_deref(),
            Some("http://localhost:9000")
        );
        assert!(parsed.knomosis_host_tcp.is_none());
        assert!(!parsed.emit_signer_hints);
    }

    /// FQ.13a: the raw-TCP endpoint with hints parses and sets the flag.
    #[test]
    fn tcp_endpoint_with_hints_parses() {
        let mut args = base();
        args.extend_from_slice(&[
            "--knomosis-host-tcp",
            "127.0.0.1:7654",
            "--emit-signer-hints",
        ]);
        let parsed = parse_args(&argv(&args)).expect("parses");
        assert_eq!(parsed.knomosis_host_tcp.as_deref(), Some("127.0.0.1:7654"));
        assert!(parsed.knomosis_host_url.is_none());
        assert!(parsed.emit_signer_hints);
    }
}
