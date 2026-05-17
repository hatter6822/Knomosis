// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-event-subscribe` — RH-D entry-point binary.
//!
//! See [`canon_event_subscribe::lib`] for the architectural
//! overview.

use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use canon_cli_common::exit::OperatorExitCode;
use canon_event_subscribe::config::{help_text, parse_args, Config, ConfigError, ParseError};
use canon_event_subscribe::event_cache::EventCache;
use canon_event_subscribe::extract::mock::MockExtractor;
use canon_event_subscribe::extract::subprocess::SubprocessExtractor;
use canon_event_subscribe::extract::Extractor;
use canon_event_subscribe::server::{Server, ServerBuildError, ServerConfig};
use canon_event_subscribe::subscription::SubscriberRegistry;
use canon_event_subscribe::tail::TailReader;
use canon_event_subscribe::{PROTOCOL_VERSION, SUBSCRIBE_IDENTIFIER};
use tracing::{error, info, Level};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let program_name = args
        .first()
        .cloned()
        .unwrap_or_else(|| "canon-event-subscribe".into());

    // 1. Parse args.
    let cfg = match parse_args(&args) {
        Ok(c) => c,
        Err(ParseError::HelpRequested) => {
            println!("{}", help_text(&program_name));
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(ParseError::VersionRequested) => {
            println!(
                "{SUBSCRIBE_IDENTIFIER} v{} (protocol v{PROTOCOL_VERSION})",
                env!("CARGO_PKG_VERSION")
            );
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(e) => {
            eprintln!("canon-event-subscribe: {e}");
            eprintln!("Use --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };

    // 2. Validate.
    if let Err(e) = cfg.validate() {
        eprintln!("canon-event-subscribe: invalid configuration: {e}");
        return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
    }

    // 3. Initialise tracing.
    if let Err(e) = canon_cli_common::logging::init(Level::INFO) {
        eprintln!("canon-event-subscribe: failed to initialise tracing: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }

    info!(
        identifier = SUBSCRIBE_IDENTIFIER,
        version = env!("CARGO_PKG_VERSION"),
        protocol = PROTOCOL_VERSION,
        "canon-event-subscribe starting"
    );

    // 4. Build server config.
    let server_cfg = match build_server_config(&cfg) {
        Ok(c) => c,
        Err(e) => {
            error!(error = ?e, "server config build failed");
            return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
        }
    };

    // 5. Run.
    let stop = Arc::new(AtomicBool::new(false));
    Server::new(server_cfg).run(stop);

    ExitCode::from(OperatorExitCode::Success.as_i32() as u8)
}

/// Build the [`ServerConfig`] from the validated [`Config`].
fn build_server_config(cfg: &Config) -> Result<ServerConfig, BuildError> {
    let log_path = cfg
        .log_path
        .as_ref()
        .ok_or(BuildError::Validation("--log-path missing".into()))?;
    let listen = cfg
        .listen
        .ok_or(BuildError::Validation("--listen missing".into()))?;

    // Build extractor.
    let extractor: Box<dyn Extractor> = if cfg.use_mock_extractor {
        info!("constructing MockExtractor (test / dev mode)");
        Box::new(MockExtractor::new())
    } else {
        let binary = cfg
            .canon_binary
            .clone()
            .ok_or(BuildError::Validation("--canon-binary missing".into()))?;
        info!(binary = ?binary, "constructing SubprocessExtractor");
        Box::new(SubprocessExtractor::new(binary, log_path.clone()))
    };

    // Bind listener.
    let listener = Server::bind(listen)?;

    // Open tail reader.
    let tail = TailReader::open(log_path)?.with_payload_max(cfg.max_frame_size);

    // Build cache.
    let cache_inner = EventCache::new(cfg.keep_history)?;
    let cache = Arc::new(Mutex::new(cache_inner));

    // Build registry.
    let registry = Arc::new(SubscriberRegistry::with_max_subscribers(
        cfg.max_subscribers,
    ));

    Ok(ServerConfig {
        listener,
        tail,
        extractor,
        registry,
        cache,
        send_queue_depth: cfg.send_queue_depth,
        max_subscriber_lag: cfg.max_subscriber_lag,
        max_frame_size: cfg.max_frame_size,
        poll_interval: cfg.poll_interval,
    })
}

/// Errors during server config construction.
#[derive(Debug, thiserror::Error)]
enum BuildError {
    #[error("validation: {0}")]
    Validation(String),
    #[error("server build: {0}")]
    Server(#[from] ServerBuildError),
    #[error("event cache: {0}")]
    Cache(#[from] canon_event_subscribe::event_cache::NewCacheError),
    #[error("tail: {0}")]
    Tail(#[from] canon_event_subscribe::tail::TailError),
}

// Silence: validation should ensure ConfigError isn't reached.
#[allow(dead_code)]
fn _silence(_: ConfigError) {}
