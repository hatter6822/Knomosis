// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-host` — RH-C entry-point binary.
//!
//! See [`knomosis_host::lib`] for the architectural overview.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use knomosis_cli_common::exit::OperatorExitCode;
use knomosis_host::config::{help_text, parse_args, Config, ConfigError, ParseError};
use knomosis_host::kernel::command::{CommandKernel, CommandKernelError};
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::kernel::Kernel;
use knomosis_host::listener::tcp::TcpListener;
use knomosis_host::listener::tls::TlsListener;
use knomosis_host::listener::HandlerConfig;
use knomosis_host::server::{Server, ServerConfigBuilder};
use knomosis_host::tls::TlsConfigBuilder;
use knomosis_host::{HOST_IDENTIFIER, PROTOCOL_VERSION};
use tracing::{error, info, Level};

#[cfg(unix)]
use knomosis_host::listener::unix::UnixListener;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let program_name = args
        .first()
        .cloned()
        .unwrap_or_else(|| "knomosis-host".into());

    // 1. Parse args.  Help / version cases short-circuit with a
    //    clean exit.
    let cfg = match parse_args(&args) {
        Ok(c) => c,
        Err(ParseError::HelpRequested) => {
            println!("{}", help_text(&program_name));
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(ParseError::VersionRequested) => {
            println!(
                "{HOST_IDENTIFIER} v{} (protocol v{PROTOCOL_VERSION})",
                env!("CARGO_PKG_VERSION")
            );
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(e) => {
            eprintln!("knomosis-host: {e}");
            eprintln!("Use --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };

    // 2. Validate.  Surface ConfigError as a clear operator
    //    message; refuse to start up.
    if let Err(e) = cfg.validate() {
        eprintln!("knomosis-host: invalid configuration: {e}");
        return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
    }

    // 3. Initialise tracing.  All logging downstream uses
    //    `tracing::*` macros; the subscriber here decides what
    //    reaches the operator console.
    if let Err(e) = knomosis_cli_common::logging::init(Level::INFO) {
        eprintln!("knomosis-host: failed to initialise tracing: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }

    info!(
        identifier = HOST_IDENTIFIER,
        version = env!("CARGO_PKG_VERSION"),
        protocol = PROTOCOL_VERSION,
        "knomosis-host starting"
    );

    // 4. Construct kernel.
    let kernel: Box<dyn Kernel> = match build_kernel(&cfg) {
        Ok(k) => k,
        Err(e) => {
            error!(error = ?e, "kernel construction failed");
            return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
        }
    };

    // 5. Construct listeners.
    let mut builder = ServerConfigBuilder::new()
        .max_queue_depth(cfg.max_queue_depth)
        .handler(HandlerConfig {
            max_frame_size: cfg.max_frame_size,
            max_concurrent_connections: cfg.max_concurrent_connections,
            ..HandlerConfig::default()
        });

    if let Some(addr) = cfg.tcp_listen {
        match TcpListener::bind(addr) {
            Ok(l) => builder = builder.tcp(l),
            Err(e) => {
                error!(addr = %addr, error = ?e, "TCP bind failed");
                return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
            }
        }
    }

    if let Some(addr) = cfg.tls_listen {
        let tls_config = match (cfg.tls_cert.as_deref(), cfg.tls_key.as_deref()) {
            (Some(cert), Some(key)) => match TlsConfigBuilder::new().load_pem_files(cert, key) {
                Ok(c) => c,
                Err(e) => {
                    error!(error = ?e, "TLS config load failed");
                    return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
                }
            },
            _ => {
                // Validation should have caught this.
                error!("--tls-listen without --tls-cert / --tls-key (validation bug)");
                return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
            }
        };
        match TlsListener::bind(addr, tls_config) {
            Ok(l) => builder = builder.tls(l),
            Err(e) => {
                error!(addr = %addr, error = ?e, "TLS bind failed");
                return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
            }
        }
    }

    #[cfg(unix)]
    if let Some(ref path) = cfg.unix_socket {
        match UnixListener::bind(path) {
            Ok(l) => builder = builder.unix(l),
            Err(e) => {
                error!(path = ?path, error = ?e, "Unix bind failed");
                return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
            }
        }
    }

    let server_config = match builder.build(kernel) {
        Ok(c) => c,
        Err(e) => {
            error!(error = ?e, "server config build failed");
            return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
        }
    };

    // 6. Run.  No custom signal handlers — Ctrl-C delivers the
    //    default libc behaviour (immediate process termination).
    //    Like `knomosis-l1-ingest`, the canonical operator pattern
    //    is to wrap with a supervisor (systemd / runit / etc.)
    //    that handles signals and restart policy.  The internal
    //    `stop` flag is plumbed throughout so a future
    //    `signal-hook`-backed handler can flip it for cooperative
    //    shutdown.
    let stop = Arc::new(AtomicBool::new(false));
    Server::new(server_config).run(stop);

    ExitCode::from(OperatorExitCode::Success.as_i32() as u8)
}

/// Build the kernel implementation from the validated config.
///
/// Per the validation rules: either `use_mock_kernel = true`
/// (MockKernel) or `knomosis_binary` + `knomosis_log` are both set
/// (CommandKernel).  The validation step has already gated out
/// the inconsistent cases.
fn build_kernel(cfg: &Config) -> Result<Box<dyn Kernel>, KernelBuildError> {
    if cfg.use_mock_kernel {
        info!("constructing MockKernel (test / dev mode)");
        let kernel = MockKernel::new();
        // GP.6.2: a dev-mode mock can opt into the in-memory budget
        // gate so operators can smoke-test the InsufficientBudget
        // path without a Lean toolchain.
        if let Some(policy) = cfg.budget_policy() {
            info!(?policy, "enabling MockKernel budget gate");
            kernel.set_budget_policy(policy);
        }
        Ok(Box::new(kernel))
    } else {
        let binary = cfg
            .knomosis_binary
            .clone()
            .ok_or(KernelBuildError::MissingKnomosisBinary)?;
        let log = cfg
            .knomosis_log
            .clone()
            .ok_or(KernelBuildError::MissingKnomosisLog)?;
        let work_dir = cfg
            .knomosis_work_dir
            .clone()
            .unwrap_or_else(|| default_work_dir(&log));
        info!(
            binary = ?binary,
            log = ?log,
            work_dir = ?work_dir,
            "constructing CommandKernel"
        );
        let mut kernel = CommandKernel::new(binary, log, work_dir)?;
        if let Some(hex) = cfg.deployment_id.as_ref() {
            kernel = kernel.with_deployment_id(hex.clone());
        }
        // GP.6.2: forward the budget policy so the Lean admission
        // gate enforces it (see `CommandKernel::with_budget_policy`).
        if let Some(policy) = cfg.budget_policy() {
            info!(?policy, "forwarding budget policy to CommandKernel");
            kernel = kernel.with_budget_policy(policy);
        }
        Ok(Box::new(kernel))
    }
}

/// Default work directory derivation: alongside the log file
/// (same parent directory), with the suffix `-host-work`.
fn default_work_dir(log: &std::path::Path) -> PathBuf {
    if let Some(parent) = log.parent() {
        parent.join("knomosis-host-work")
    } else {
        PathBuf::from("knomosis-host-work")
    }
}

/// Errors during kernel construction.
#[derive(Debug, thiserror::Error)]
enum KernelBuildError {
    #[error("--knomosis-binary missing (validation bug)")]
    MissingKnomosisBinary,
    #[error("--knomosis-log missing (validation bug)")]
    MissingKnomosisLog,
    #[error("CommandKernel construction failed: {0}")]
    CommandKernel(#[from] CommandKernelError),
}

// Silence: validation should ensure ConfigError isn't reached.
#[allow(dead_code)]
fn _silence(_: ConfigError) {}

#[cfg(test)]
mod tests {
    use super::build_kernel;
    use knomosis_host::config::Config;
    use knomosis_host::verdict::Verdict;

    /// A CBE uint head (`[0x00] ++ LE`).
    fn cbe_uint(n: u64) -> Vec<u8> {
        let mut v = vec![0x00u8];
        v.extend_from_slice(&n.to_le_bytes());
        v
    }

    /// A CBE byte-string field.
    fn cbe_bytes(payload: &[u8]) -> Vec<u8> {
        let mut v = vec![0x02u8];
        v.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        v.extend_from_slice(payload);
        v
    }

    /// A `transfer` `SignedAction` (tag 0) signed by `signer`.
    fn transfer_signed_action(signer: u64) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&cbe_uint(0)); // tag
        v.extend_from_slice(&cbe_uint(1)); // r
        v.extend_from_slice(&cbe_uint(signer)); // sender
        v.extend_from_slice(&cbe_uint(99)); // receiver
        v.extend_from_slice(&cbe_uint(10)); // amount
        v.extend_from_slice(&cbe_uint(signer)); // SignedAction.signer
        v.extend_from_slice(&cbe_uint(0)); // nonce
        v.extend_from_slice(&cbe_bytes(&[0xAB; 4])); // sig
        v
    }

    fn mock_budget_config() -> Config {
        let mut cfg = Config::defaults();
        cfg.tcp_listen = Some("127.0.0.1:0".parse().unwrap());
        cfg.use_mock_kernel = true;
        cfg.budget_mode = Some("bounded".into());
        cfg.budget_free_tier = Some(1);
        cfg.budget_action_cost = Some(1);
        cfg.budget_current_epoch = Some(1);
        cfg
    }

    /// GP.6.2: `build_kernel` actually wires the configured budget
    /// policy into the MockKernel — a fresh actor's first action is
    /// admitted and the second is InsufficientBudget.
    #[test]
    fn build_kernel_mock_with_budget_enforces_gate() {
        let cfg = mock_budget_config();
        cfg.validate().unwrap();
        let kernel = build_kernel(&cfg).unwrap();
        let sa = transfer_signed_action(10);
        assert_eq!(kernel.submit(&sa).verdict, Verdict::Ok);
        let r = kernel.submit(&sa);
        assert_eq!(r.verdict, Verdict::NotAdmissible);
        assert_eq!(r.reason, "InsufficientBudget");
    }

    /// Without budget flags the MockKernel applies no gate (back-compat).
    #[test]
    fn build_kernel_mock_without_budget_always_ok() {
        let mut cfg = Config::defaults();
        cfg.tcp_listen = Some("127.0.0.1:0".parse().unwrap());
        cfg.use_mock_kernel = true;
        cfg.validate().unwrap();
        assert!(cfg.budget_policy().is_none());
        let kernel = build_kernel(&cfg).unwrap();
        let sa = transfer_signed_action(10);
        assert_eq!(kernel.submit(&sa).verdict, Verdict::Ok);
        assert_eq!(kernel.submit(&sa).verdict, Verdict::Ok);
    }
}
