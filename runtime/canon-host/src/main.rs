// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-host` — RH-C entry-point binary.
//!
//! See [`canon_host::lib`] for the architectural overview.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use canon_cli_common::exit::OperatorExitCode;
use canon_host::config::{help_text, parse_args, Config, ConfigError, ParseError};
use canon_host::kernel::command::{CommandKernel, CommandKernelError};
use canon_host::kernel::mock::MockKernel;
use canon_host::kernel::Kernel;
use canon_host::listener::tcp::TcpListener;
use canon_host::listener::tls::TlsListener;
use canon_host::listener::HandlerConfig;
use canon_host::server::{Server, ServerConfigBuilder};
use canon_host::tls::TlsConfigBuilder;
use canon_host::{HOST_IDENTIFIER, PROTOCOL_VERSION};
use tracing::{error, info, Level};

#[cfg(unix)]
use canon_host::listener::unix::UnixListener;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let program_name = args.first().cloned().unwrap_or_else(|| "canon-host".into());

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
            eprintln!("canon-host: {e}");
            eprintln!("Use --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };

    // 2. Validate.  Surface ConfigError as a clear operator
    //    message; refuse to start up.
    if let Err(e) = cfg.validate() {
        eprintln!("canon-host: invalid configuration: {e}");
        return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
    }

    // 3. Initialise tracing.  All logging downstream uses
    //    `tracing::*` macros; the subscriber here decides what
    //    reaches the operator console.
    if let Err(e) = canon_cli_common::logging::init(Level::INFO) {
        eprintln!("canon-host: failed to initialise tracing: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }

    info!(
        identifier = HOST_IDENTIFIER,
        version = env!("CARGO_PKG_VERSION"),
        protocol = PROTOCOL_VERSION,
        "canon-host starting"
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
    //    Like `canon-l1-ingest`, the canonical operator pattern
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
/// (MockKernel) or `canon_binary` + `canon_log` are both set
/// (CommandKernel).  The validation step has already gated out
/// the inconsistent cases.
fn build_kernel(cfg: &Config) -> Result<Box<dyn Kernel>, KernelBuildError> {
    if cfg.use_mock_kernel {
        info!("constructing MockKernel (test / dev mode)");
        Ok(Box::new(MockKernel::new()))
    } else {
        let binary = cfg
            .canon_binary
            .clone()
            .ok_or(KernelBuildError::MissingCanonBinary)?;
        let log = cfg
            .canon_log
            .clone()
            .ok_or(KernelBuildError::MissingCanonLog)?;
        let work_dir = cfg
            .canon_work_dir
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
        Ok(Box::new(kernel))
    }
}

/// Default work directory derivation: alongside the log file
/// (same parent directory), with the suffix `-host-work`.
fn default_work_dir(log: &std::path::Path) -> PathBuf {
    if let Some(parent) = log.parent() {
        parent.join("canon-host-work")
    } else {
        PathBuf::from("canon-host-work")
    }
}

/// Errors during kernel construction.
#[derive(Debug, thiserror::Error)]
enum KernelBuildError {
    #[error("--canon-binary missing (validation bug)")]
    MissingCanonBinary,
    #[error("--canon-log missing (validation bug)")]
    MissingCanonLog,
    #[error("CommandKernel construction failed: {0}")]
    CommandKernel(#[from] CommandKernelError),
}

// Silence: validation should ensure ConfigError isn't reached.
#[allow(dead_code)]
fn _silence(_: ConfigError) {}
