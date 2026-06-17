// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Gateway CLI / environment configuration.
//!
//! **Surface (the read-only slice, through G1.3):** the HTTP listen
//! address (`--listen`) + bounded handler-pool size
//! (`--handler-threads`); the read backend (`--indexer-db`); the
//! budget-policy echo (`--free-tier` / `--action-cost` /
//! `--epoch-length` / `--gas-pool-actor`); the `/v1/info` + `/readyz`
//! metadata (`--deployment-id`, `--ok-admission-stage`, `--host-addr`,
//! `--event-subscribe-addr`); the fail-closed auth token file
//! (`--auth-token-file`, G1.4); the per-credential rate cap
//! (`--rate-limit-rps`, G1.3); the submit governors (`--host-addr`,
//! `--host-pool-size`, `--host-max-inflight`, `--request-deadline-ms`,
//! `--max-frame-size`, `--idempotency-ttl-secs`); and native HTTPS / mTLS
//! (`--tls-listen` / `--tls-cert` / `--tls-key` / `--mtls-client-ca` /
//! `--tls-max-connections`, G4.2; see [`TlsConfig`]).  The only remaining
//! §9.2 surface is the per-knob `--sse-*` tuning (today compile-time
//! [`SseConfig`] defaults).  Every knob follows this module's fail-fast
//! discipline (a typed [`ConfigError`] naming the offending flag).

use std::net::SocketAddr;
use std::path::PathBuf;

/// Default HTTP listen address — loopback-safe per §9.2 (the gateway
/// sits behind the BFF / an L7 edge; it is not bound to `0.0.0.0` by
/// default).
pub const DEFAULT_LISTEN: &str = "127.0.0.1:8080";

/// Environment variable mirroring `--listen` (§9.2).  The CLI flag
/// takes precedence over the environment.
pub const LISTEN_ENV: &str = "KNX_GW_LISTEN";

/// Default size of the bounded request-handler thread pool (G1.2d).
/// The gateway is a synchronous server: this many worker threads each
/// block on `tiny_http::Server::recv`, so the pool caps concurrent
/// request *processing* — the practical resource governor.
pub const DEFAULT_HANDLER_THREADS: usize = 16;

/// Sanity ceiling on `--handler-threads` (far above any reasonable
/// single-host deployment; rejects a fat-finger that would exhaust
/// the thread table).
pub const MAX_HANDLER_THREADS: usize = 4096;

/// Environment variable mirroring `--handler-threads`.  The CLI flag
/// takes precedence over the environment.
pub const HANDLER_THREADS_ENV: &str = "KNX_GW_HANDLER_THREADS";

/// Environment variable mirroring `--indexer-db`.  The CLI flag takes
/// precedence over the environment.
pub const INDEXER_DB_ENV: &str = "KNX_GW_INDEXER_DB";

/// Environment variable mirroring `--free-tier`.
pub const FREE_TIER_ENV: &str = "KNX_GW_FREE_TIER";

/// Environment variable mirroring `--action-cost`.
pub const ACTION_COST_ENV: &str = "KNX_GW_ACTION_COST";

/// Environment variable mirroring `--epoch-length`.
pub const EPOCH_LENGTH_ENV: &str = "KNX_GW_EPOCH_LENGTH";

/// Environment variable mirroring `--gas-pool-actor`.
pub const GAS_POOL_ACTOR_ENV: &str = "KNX_GW_GAS_POOL_ACTOR";

/// Environment variable mirroring `--deployment-id`.
pub const DEPLOYMENT_ID_ENV: &str = "KNX_GW_DEPLOYMENT_ID";

/// Environment variable mirroring `--ok-admission-stage`.
pub const OK_ADMISSION_STAGE_ENV: &str = "KNX_GW_OK_ADMISSION_STAGE";

/// Environment variable mirroring `--host-addr`.
pub const HOST_ADDR_ENV: &str = "KNX_GW_HOST_ADDR";

/// Environment variable mirroring `--event-subscribe-addr`.
pub const EVENT_SUBSCRIBE_ADDR_ENV: &str = "KNX_GW_EVENT_SUBSCRIBE_ADDR";

/// Environment variable mirroring `--auth-token-file`.  Only the file
/// *path* comes from the flag / env; the token *values* live in the file
/// (never in argv / an env value), per §9.2.
pub const AUTH_TOKEN_FILE_ENV: &str = "KNX_GW_AUTH_TOKEN_FILE";

/// Environment variable mirroring `--rate-limit-rps`.
pub const RATE_LIMIT_RPS_ENV: &str = "KNX_GW_RATE_LIMIT_RPS";

/// Default per-credential request-rate cap (requests/second).  A
/// conservative default (§9.2); tune it up for a high-throughput BFF.
pub const DEFAULT_RATE_LIMIT_RPS: u32 = 100;

/// Environment variable mirroring `--host-pool-size`.
pub const HOST_POOL_SIZE_ENV: &str = "KNX_GW_HOST_POOL_SIZE";

/// Default number of persistent host connections (§9.2 / G2.1b).
pub const DEFAULT_HOST_POOL_SIZE: usize = 8;

/// Ceiling on `--host-pool-size` (rejects a fat-finger that would
/// exhaust the fd table; far above any single-host deployment).
pub const MAX_HOST_POOL_SIZE: usize = 4096;

/// Environment variable mirroring `--host-max-inflight`.
pub const HOST_MAX_INFLIGHT_ENV: &str = "KNX_GW_HOST_MAX_INFLIGHT";

/// Environment variable mirroring `--request-deadline-ms`.
pub const REQUEST_DEADLINE_MS_ENV: &str = "KNX_GW_REQUEST_DEADLINE_MS";

/// Default end-to-end submit deadline in milliseconds (§9.2 / G2.1b).
pub const DEFAULT_REQUEST_DEADLINE_MS: u64 = 5000;

/// Environment variable mirroring `--max-frame-size`.
pub const MAX_FRAME_SIZE_ENV: &str = "KNX_GW_MAX_FRAME_SIZE";

/// Default `POST /v1/actions` body cap (1 MiB) — the host's default
/// frame size (`knomosis_host::frame::DEFAULT_MAX_FRAME_SIZE`).
pub const DEFAULT_MAX_FRAME_SIZE: usize = 1024 * 1024;

/// Hard ceiling on `--max-frame-size` (16 MiB) — the host's hard frame
/// cap (`knomosis_host::frame::HARD_MAX_FRAME_SIZE`); a larger body could
/// never be framed anyway.
pub const MAX_FRAME_SIZE_CEILING: usize = 16 * 1024 * 1024;

/// Environment variable mirroring `--idempotency-ttl-secs`.
pub const IDEMPOTENCY_TTL_SECS_ENV: &str = "KNX_GW_IDEMPOTENCY_TTL_SECS";

/// Default `Idempotency-Key` response-cache TTL in seconds (§9.2); `0`
/// disables the cache.
pub const DEFAULT_IDEMPOTENCY_TTL_SECS: u64 = 120;

/// Maximum retained idempotency entries (LRU-evicted at capacity) — a
/// fixed bound on the cache's memory; not separately configurable.
pub const IDEMPOTENCY_MAX_ENTRIES: usize = 8192;

/// Environment variable mirroring `--tls-listen` (G4.2).  Setting it (or the
/// flag) enables the native in-process HTTPS listener; cert + key are then
/// required.
pub const TLS_LISTEN_ENV: &str = "KNX_GW_TLS_LISTEN";

/// Environment variable mirroring `--tls-cert`.  Only the file *path* comes
/// from the flag / env; the certificate bytes live in the file.
pub const TLS_CERT_ENV: &str = "KNX_GW_TLS_CERT";

/// Environment variable mirroring `--tls-key`.  Only the file *path* comes
/// from the flag / env; the private-key bytes live in the file (never argv /
/// an env value), per §8.1.
pub const TLS_KEY_ENV: &str = "KNX_GW_TLS_KEY";

/// Environment variable mirroring `--mtls-client-ca`.  Presence enables mTLS:
/// the TLS listener then *requires* a client certificate chaining to this CA.
pub const MTLS_CLIENT_CA_ENV: &str = "KNX_GW_MTLS_CLIENT_CA";

/// Environment variable mirroring `--tls-max-connections`.
pub const TLS_MAX_CONNECTIONS_ENV: &str = "KNX_GW_TLS_MAX_CONNECTIONS";

/// Default cap on simultaneously-active TLS connections (G4.2) — each runs on
/// its own thread, so this is the native-TLS spawn-storm DoS bound (the peer
/// of `knomosis-host`'s `DEFAULT_MAX_CONCURRENT_CONNECTIONS`).
pub const DEFAULT_TLS_MAX_CONNECTIONS: usize = 1024;

/// Hard ceiling on `--tls-max-connections` (rejects a fat-finger that would
/// exhaust the thread / fd table).
pub const MAX_TLS_MAX_CONNECTIONS: usize = 65_536;

/// `--help` text for the scaffold surface (expanded in G1.3).
pub const HELP_TEXT: &str = "\
knomosis-gateway — HTTP/JSON + SSE gateway for the Knomosis runtime

USAGE:
    knomosis-gateway [OPTIONS]

OPTIONS:
    --listen <ADDR>    HTTP listen address (env KNX_GW_LISTEN)
                       [default: 127.0.0.1:8080]
    --handler-threads <N>
                       Bounded request-handler pool size; caps
                       concurrent request processing
                       (env KNX_GW_HANDLER_THREADS) [default: 16]
    --indexer-db <PATH>
                       Path to the knomosis-indexer SQLite database,
                       opened READ-ONLY for balance/budget/pool reads
                       (env KNX_GW_INDEXER_DB) [default: reads disabled]
    --free-tier <N>    Per-epoch free budget units echoed in the budget
                       view; MUST match the deployment policy
                       (env KNX_GW_FREE_TIER) [default: 0]
    --action-cost <N>  Per-action budget cost echoed in the budget view
                       (env KNX_GW_ACTION_COST) [default: 0]
    --epoch-length <N> Budget-epoch length echoed in /v1/info; MUST match
                       the indexer's --epoch-length
                       (env KNX_GW_EPOCH_LENGTH) [default: 0]
    --gas-pool-actor <ID>
                       Gas-pool actor id (GP.6.4) whose pool view the
                       indexer drains; MUST match the indexer's
                       --gas-pool-actor.  A pool view for THIS id is
                       reported net of drains (net=true); any other id
                       is gross inflows (net=false)
                       (env KNX_GW_GAS_POOL_ACTOR) [default: unset]
    --deployment-id <ID>
                       Deployment identifier echoed in /v1/info
                       (env KNX_GW_DEPLOYMENT_ID) [default: empty]
    --ok-admission-stage <STAGE>
                       Kernel Verdict::Ok admission stage echoed in
                       /v1/info; one of Received|LocallyAdmitted|
                       Sequenced|Finalized
                       (env KNX_GW_OK_ADMISSION_STAGE) [default: Finalized]
    --host-addr <ADDR> Binary host upstream address, probed by /readyz
                       (env KNX_GW_HOST_ADDR) [default: unset]
    --event-subscribe-addr <ADDR>
                       Event-subscribe upstream address, probed by /readyz
                       (env KNX_GW_EVENT_SUBSCRIBE_ADDR) [default: unset]
    --auth-token-file <PATH>
                       File of bearer service tokens (one per line) for
                       the fail-closed auth gate; when unset, every
                       non-exempt request is denied (/healthz + /readyz
                       stay open).  MUST NOT be readable by 'other'
                       (the gateway refuses a world-accessible token file)
                       (env KNX_GW_AUTH_TOKEN_FILE) [default: unset]
    --rate-limit-rps <N>
                       Per-credential request-rate cap (requests/second);
                       an exhausted token bucket returns 429.  0 disables
                       rate limiting
                       (env KNX_GW_RATE_LIMIT_RPS) [default: 100]
    --host-pool-size <N>
                       Persistent host connections for the submit pool
                       (env KNX_GW_HOST_POOL_SIZE) [default: 8]
    --host-max-inflight <N>
                       Cap on concurrent in-flight host checkouts (clamped
                       to the pool size); over-cap submits return 503
                       (env KNX_GW_HOST_MAX_INFLIGHT) [default: pool size]
    --request-deadline-ms <N>
                       Per-operation host connect/read/write timeout (ms)
                       (env KNX_GW_REQUEST_DEADLINE_MS) [default: 5000]
    --max-frame-size <N>
                       POST /v1/actions body cap in bytes; a larger body
                       is rejected 413 (ceiling 16 MiB)
                       (env KNX_GW_MAX_FRAME_SIZE) [default: 1048576]
    --idempotency-ttl-secs <N>
                       Idempotency-Key response-cache TTL in seconds; a
                       duplicate key within the TTL returns the cached
                       response.  0 disables the cache
                       (env KNX_GW_IDEMPOTENCY_TTL_SECS) [default: 120]
    --tls-listen <ADDR>
                       Enable the native in-process HTTPS listener on ADDR
                       (rustls 0.23, TLS 1.3); requires --tls-cert + --tls-key.
                       Runs ALONGSIDE the plaintext --listen socket
                       (env KNX_GW_TLS_LISTEN) [default: disabled]
    --tls-cert <PATH>  PEM certificate chain (leaf first) for --tls-listen
                       (env KNX_GW_TLS_CERT) [required with --tls-listen]
    --tls-key <PATH>   PEM private key (PKCS#8 / RSA / SEC1) for --tls-listen
                       (env KNX_GW_TLS_KEY) [required with --tls-listen]
    --mtls-client-ca <PATH>
                       PEM CA bundle that client certificates must chain to;
                       presence enables mTLS (the TLS listener then REQUIRES a
                       valid client certificate)
                       (env KNX_GW_MTLS_CLIENT_CA) [default: no client auth]
    --tls-max-connections <N>
                       Cap on simultaneously-active TLS connections (each on
                       its own thread); over-cap connects are closed
                       (env KNX_GW_TLS_MAX_CONNECTIONS) [default: 1024]
    -h, --help         Print this help and exit
    -V, --version      Print version and exit

NOTE: native HTTPS (--tls-listen) terminates TLS in-process with the
workspace's rustls 0.23 (TLS 1.3, ring), reusing the exact gate -> route ->
dispatch core as the plaintext path.  TLS may also be terminated at a
co-located edge (the gateway then stays plaintext behind it); see the runbook.
";

/// Errors from parsing the gateway's CLI / environment configuration.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// `-h` / `--help` was requested.  Not a failure: `main` prints
    /// [`HELP_TEXT`] and exits `Success`.
    #[error("help requested")]
    HelpRequested,
    /// `-V` / `--version` was requested.
    #[error("version requested")]
    VersionRequested,
    /// A flag that requires a value was given none.
    #[error("flag {flag} requires a value")]
    MissingValue {
        /// The flag missing its argument.
        flag: String,
    },
    /// A flag value failed to parse.
    #[error("invalid value for {flag}: {value:?} ({reason})")]
    InvalidValue {
        /// The flag whose value was invalid.
        flag: String,
        /// The offending value.
        value: String,
        /// The parser's diagnostic.
        reason: String,
    },
    /// An unrecognised argument was supplied.
    #[error("unknown argument: {0:?}")]
    UnknownArgument(String),
}

/// The kernel's declared `Verdict::Ok` admission stage (abi.md §10.2.1),
/// echoed in `/v1/info`.  The gateway cannot introspect the host's
/// configured stage over the wire (that is a G6-era host metadata
/// operation), so it is an operator-supplied config echo defaulting to
/// the strongest stage (`Finalized`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionStage {
    /// Received by the sequencer (weakest assurance).
    Received,
    /// Locally admitted — passed the kernel's admission gate.
    LocallyAdmitted,
    /// Sequenced into the L2 ordering.
    Sequenced,
    /// Finalized on L1 (strongest assurance).
    Finalized,
}

impl AdmissionStage {
    /// The contract wire token (the OpenAPI `Info.okAdmissionStage`
    /// enum value).
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            AdmissionStage::Received => "Received",
            AdmissionStage::LocallyAdmitted => "LocallyAdmitted",
            AdmissionStage::Sequenced => "Sequenced",
            AdmissionStage::Finalized => "Finalized",
        }
    }
}

impl std::str::FromStr for AdmissionStage {
    type Err = ();

    /// Parse a contract wire token; any other string is rejected (the
    /// caller maps the unit error to a typed [`ConfigError::InvalidValue`]).
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "Received" => Ok(AdmissionStage::Received),
            "LocallyAdmitted" => Ok(AdmissionStage::LocallyAdmitted),
            "Sequenced" => Ok(AdmissionStage::Sequenced),
            "Finalized" => Ok(AdmissionStage::Finalized),
            _ => Err(()),
        }
    }
}

/// SSE fan-out tunables (Workstream G3.4 / G3.5).  Sensible defaults wire
/// the live `GET /v1/events/stream` endpoint without operator action;
/// per-knob `--sse-*` flags are an additive follow-up (§9.2).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SseConfig {
    /// Shared fan-out ring capacity (records retained for replay / resume).
    pub ring_capacity: usize,
    /// Maximum concurrent SSE streams; an over-cap connect is `503`.
    pub max_streams: usize,
    /// Per-client lag bound in records before a `lag_exceeded` eviction
    /// (kept below `ring_capacity` so the eviction fires before the ring
    /// drops the client's unseen records).
    pub max_client_lag: usize,
    /// SSE heartbeat-comment interval (seconds) when a stream is idle.
    pub heartbeat_secs: u64,
    /// Upstream-read staleness timeout (seconds) for the single fan-out
    /// subscription (a quiet live-tail reconnects from the watermark after
    /// this; also bounds the mux's shutdown latency).
    pub stale_secs: u64,
}

impl Default for SseConfig {
    fn default() -> Self {
        Self {
            ring_capacity: 4096,
            max_streams: 256,
            max_client_lag: 2048,
            heartbeat_secs: 15,
            stale_secs: 55,
        }
    }
}

/// Native in-process HTTPS configuration (G4.2), present iff `--tls-listen`
/// is set.  The TLS listener runs **alongside** the plaintext `--listen`
/// socket, sharing the same [`crate::state::AppState`] and the exact same
/// gate → route → dispatch core; only the wire transport (rustls 0.23, TLS
/// 1.3, the `ring` backend) differs.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TlsConfig {
    /// The HTTPS listen address (`--tls-listen`).
    pub listen: SocketAddr,
    /// PEM certificate-chain path (`--tls-cert`), leaf first.
    pub cert: PathBuf,
    /// PEM private-key path (`--tls-key`): PKCS#8, RSA, or SEC1.
    pub key: PathBuf,
    /// PEM client-CA bundle path (`--mtls-client-ca`).  `Some` enables mTLS:
    /// the listener requires a client certificate chaining to this CA;
    /// `None` (the default) is server-auth only.
    pub client_ca: Option<PathBuf>,
    /// Cap on simultaneously-active TLS connections (`--tls-max-connections`),
    /// the native-TLS spawn-storm DoS bound.  Always in
    /// `1..=MAX_TLS_MAX_CONNECTIONS`.  Default [`DEFAULT_TLS_MAX_CONNECTIONS`].
    pub max_connections: usize,
}

/// Validated gateway configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    /// HTTP listen address.
    pub listen: SocketAddr,
    /// Bounded request-handler thread-pool size (G1.2d): the number of
    /// worker threads each blocking on `Server::recv`, capping
    /// concurrent request processing.  Always in `1..=MAX_HANDLER_THREADS`.
    pub handler_threads: usize,
    /// Path to the indexer SQLite database, opened READ-ONLY for the
    /// balance / budget / pool reads (G1.6b).  `None` disables the read
    /// endpoints (they answer `503`); set via `--indexer-db`.
    pub indexer_db: Option<PathBuf>,
    /// Per-epoch free budget units, echoed in the `BudgetView` and used
    /// in `remaining = freeTier + grants − consumed` (G1.7).  MUST match
    /// the deployment's budget policy (the gateway cannot self-check
    /// this — an operator obligation, §9.2).  Default `0`.
    pub free_tier: u128,
    /// Per-action budget cost, echoed in the `BudgetView` (G1.7).
    /// Default `0`.
    pub action_cost: u128,
    /// The budget-epoch length (`--epoch-length`), echoed in `/v1/info`'s
    /// budget-policy block so an operator can diff it against the
    /// indexer's `--epoch-length` (drift observability; the gateway does
    /// not itself reset epochs — the indexer does).  Default `0`.
    pub epoch_length: u64,
    /// The gas-pool actor id whose pool view the indexer drains
    /// (GP.6.4); `Some(id)` makes `GET /v1/pools/{id}` report `net =
    /// true` (net of drains) and every other pool id `net = false`
    /// (gross inflows).  MUST match the indexer's `--gas-pool-actor`:
    /// the indexer does not persist this in the database, so the
    /// gateway cannot self-verify the match (an operator obligation,
    /// §9.2, exactly as for the budget echo).  `None` (the default)
    /// reports every pool view as `net = false`.
    pub gas_pool_actor: Option<u64>,
    /// The deployment identifier echoed in `/v1/info` (`--deployment-id`).
    /// Operator-supplied metadata; defaults to the empty string.
    pub deployment_id: String,
    /// The kernel's declared `Verdict::Ok` admission stage echoed in
    /// `/v1/info` (`--ok-admission-stage`).  An operator config echo
    /// (the gateway cannot introspect the host's stage), defaulting to
    /// [`AdmissionStage::Finalized`].
    pub ok_admission_stage: AdmissionStage,
    /// The binary host upstream address (`--host-addr`), probed by
    /// `/readyz` (a bare TCP connect) and used by the submit path (G2).
    /// `None` (the default) means "not configured": `/readyz` treats the
    /// host as not-blocking and the submit path is unavailable.
    pub host_addr: Option<SocketAddr>,
    /// The event-subscribe upstream address (`--event-subscribe-addr`),
    /// probed by `/readyz` and used by the SSE fan-out (G3).  `None`
    /// (the default) means "not configured" (not-blocking in `/readyz`).
    pub event_subscribe_addr: Option<SocketAddr>,
    /// Path to the bearer-token file (`--auth-token-file`), one service
    /// token per line.  `None` (the default) configures **no** tokens,
    /// which is **fail-closed**: every non-exempt request is then denied
    /// (`/healthz` + `/readyz` stay open).  The token *values* are never
    /// read from argv / an env value, only from this file (§8.1 / §9.2).
    pub auth_token_file: Option<PathBuf>,
    /// Per-credential request-rate cap in requests/second
    /// (`--rate-limit-rps`).  A token bucket of this capacity, refilling
    /// at this rate, governs each authenticated credential; an exhausted
    /// bucket is a `429`.  `0` disables rate limiting.  Default
    /// [`DEFAULT_RATE_LIMIT_RPS`].
    pub rate_limit_rps: u32,
    /// Number of persistent host connections in the submit pool
    /// (`--host-pool-size`, G2.1b).  Always in
    /// `1..=MAX_HOST_POOL_SIZE`.  Default [`DEFAULT_HOST_POOL_SIZE`].
    pub host_pool_size: usize,
    /// Cap on concurrent in-flight host checkouts (`--host-max-inflight`);
    /// a request over the cap is a `503`.  Defaults to `host_pool_size`
    /// and is clamped to it (more in-flight than connections is
    /// meaningless — one in-flight per connection).
    pub host_max_inflight: usize,
    /// End-to-end submit deadline in milliseconds (`--request-deadline-ms`,
    /// G2.1b): the per-operation connect / write / read timeout for a host
    /// round-trip.  Default [`DEFAULT_REQUEST_DEADLINE_MS`].
    pub request_deadline_ms: u64,
    /// `POST /v1/actions` request-body cap in bytes (`--max-frame-size`,
    /// G2.2): a larger body is rejected with `413` while reading.  Always
    /// in `1..=MAX_FRAME_SIZE_CEILING`.  Default [`DEFAULT_MAX_FRAME_SIZE`].
    pub max_frame_size: usize,
    /// `Idempotency-Key` response-cache TTL in seconds
    /// (`--idempotency-ttl-secs`, G2.4); `0` disables the cache.  Default
    /// [`DEFAULT_IDEMPOTENCY_TTL_SECS`].
    pub idempotency_ttl_secs: u64,
    /// SSE fan-out tunables (G3.4 / G3.5); see [`SseConfig`].  Defaulted
    /// today (no per-knob flags yet).
    pub sse: SseConfig,
    /// Native in-process HTTPS configuration (G4.2), present iff
    /// `--tls-listen` is set; see [`TlsConfig`].  `None` (the default) runs
    /// the plaintext `--listen` socket only (TLS terminated at an edge).
    pub tls: Option<TlsConfig>,
}

impl Config {
    /// Parse configuration from the full process argument vector
    /// (`args[0]` is the program name, parsing starts at `args[1]`),
    /// with an environment-variable fallback for `--listen`.
    ///
    /// # Errors
    ///
    /// Returns [`ConfigError::HelpRequested`] /
    /// [`ConfigError::VersionRequested`] for the respective flags (the
    /// caller treats these as a clean exit), or a parse error
    /// ([`ConfigError::MissingValue`] / [`ConfigError::InvalidValue`] /
    /// [`ConfigError::UnknownArgument`]) the caller surfaces as
    /// `OperatorAction`.
    pub fn parse(args: &[String]) -> Result<Self, ConfigError> {
        let raw = RawArgs::scan(args)?;

        // Precedence (applied here): CLI flag > environment > default.
        let listen_str = raw
            .listen
            .or_else(|| std::env::var(LISTEN_ENV).ok())
            .unwrap_or_else(|| DEFAULT_LISTEN.to_string());
        let listen = listen_str
            .parse::<SocketAddr>()
            .map_err(|e| ConfigError::InvalidValue {
                flag: "--listen".to_string(),
                value: listen_str.clone(),
                reason: e.to_string(),
            })?;

        let handler_threads = resolve_handler_threads(raw.handler_threads)?;

        let indexer_db = raw
            .indexer_db
            .or_else(|| std::env::var(INDEXER_DB_ENV).ok())
            .map(PathBuf::from);

        let free_tier = parse_u128_flag("--free-tier", raw.free_tier, FREE_TIER_ENV)?;
        let action_cost = parse_u128_flag("--action-cost", raw.action_cost, ACTION_COST_ENV)?;
        let epoch_length = parse_u64_flag("--epoch-length", raw.epoch_length, EPOCH_LENGTH_ENV)?;
        let gas_pool_actor =
            parse_optional_u64_flag("--gas-pool-actor", raw.gas_pool_actor, GAS_POOL_ACTOR_ENV)?;

        let deployment_id = raw
            .deployment_id
            .or_else(|| std::env::var(DEPLOYMENT_ID_ENV).ok())
            .unwrap_or_default();
        let ok_admission_stage = resolve_admission_stage(raw.ok_admission_stage)?;
        let host_addr =
            parse_optional_socket_addr_flag("--host-addr", raw.host_addr, HOST_ADDR_ENV)?;
        let event_subscribe_addr = parse_optional_socket_addr_flag(
            "--event-subscribe-addr",
            raw.event_subscribe_addr,
            EVENT_SUBSCRIBE_ADDR_ENV,
        )?;
        let auth_token_file = raw
            .auth_token_file
            .or_else(|| std::env::var(AUTH_TOKEN_FILE_ENV).ok())
            .map(PathBuf::from);
        let rate_limit_rps = resolve_rate_limit_rps(raw.rate_limit_rps)?;
        let host_pool_size = resolve_host_pool_size(raw.host_pool_size)?;
        let host_max_inflight = resolve_host_max_inflight(raw.host_max_inflight, host_pool_size)?;
        let request_deadline_ms = match parse_optional_u64_flag(
            "--request-deadline-ms",
            raw.request_deadline_ms,
            REQUEST_DEADLINE_MS_ENV,
        )? {
            None => DEFAULT_REQUEST_DEADLINE_MS,
            Some(0) => {
                return Err(ConfigError::InvalidValue {
                    flag: "--request-deadline-ms".to_string(),
                    value: "0".to_string(),
                    reason: "must be at least 1 (a zero deadline never completes)".to_string(),
                })
            }
            Some(n) => n,
        };
        let max_frame_size = resolve_max_frame_size(raw.max_frame_size)?;
        // `--idempotency-ttl-secs` defaults to 120; `0` is valid (disables
        // the cache).
        let idempotency_ttl_secs = parse_optional_u64_flag(
            "--idempotency-ttl-secs",
            raw.idempotency_ttl_secs,
            IDEMPOTENCY_TTL_SECS_ENV,
        )?
        .unwrap_or(DEFAULT_IDEMPOTENCY_TTL_SECS);
        let tls = resolve_tls(
            raw.tls_listen,
            raw.tls_cert,
            raw.tls_key,
            raw.mtls_client_ca,
            raw.tls_max_connections,
        )?;

        Ok(Self {
            listen,
            handler_threads,
            indexer_db,
            free_tier,
            action_cost,
            epoch_length,
            gas_pool_actor,
            deployment_id,
            ok_admission_stage,
            host_addr,
            event_subscribe_addr,
            auth_token_file,
            rate_limit_rps,
            host_pool_size,
            host_max_inflight,
            request_deadline_ms,
            max_frame_size,
            idempotency_ttl_secs,
            // SSE tunables are defaulted today (no per-knob flags yet, §9.2).
            sse: SseConfig::default(),
            tls,
        })
    }
}

/// Resolve the optional native-TLS configuration (G4.2): CLI value > env var.
///
/// TLS is enabled iff `--tls-listen` (or its env var) is present, in which
/// case `--tls-cert` + `--tls-key` are **required** (fail-fast otherwise) and
/// `--mtls-client-ca` / `--tls-max-connections` are optional.  Supplying any
/// `--tls-*` / `--mtls-*` knob *without* `--tls-listen` is a hard error rather
/// than a silently-ignored flag — a cert with no listener is a misconfig.
fn resolve_tls(
    listen_raw: Option<String>,
    cert_raw: Option<String>,
    key_raw: Option<String>,
    client_ca_raw: Option<String>,
    max_connections_raw: Option<String>,
) -> Result<Option<TlsConfig>, ConfigError> {
    let listen_str = listen_raw.or_else(|| std::env::var(TLS_LISTEN_ENV).ok());
    let cert = cert_raw.or_else(|| std::env::var(TLS_CERT_ENV).ok());
    let key = key_raw.or_else(|| std::env::var(TLS_KEY_ENV).ok());
    let client_ca = client_ca_raw.or_else(|| std::env::var(MTLS_CLIENT_CA_ENV).ok());
    let max_connections_raw =
        max_connections_raw.or_else(|| std::env::var(TLS_MAX_CONNECTIONS_ENV).ok());

    let Some(listen_str) = listen_str else {
        // TLS disabled: reject any dependent knob supplied without a listener
        // (fail-fast, never a silent no-op).
        for (value, flag) in [
            (&cert, "--tls-cert"),
            (&key, "--tls-key"),
            (&client_ca, "--mtls-client-ca"),
            (&max_connections_raw, "--tls-max-connections"),
        ] {
            if let Some(value) = value {
                return Err(ConfigError::InvalidValue {
                    flag: flag.to_string(),
                    value: value.clone(),
                    reason: "requires --tls-listen (native TLS is enabled only by --tls-listen)"
                        .to_string(),
                });
            }
        }
        return Ok(None);
    };

    let listen = listen_str
        .parse::<SocketAddr>()
        .map_err(|e| ConfigError::InvalidValue {
            flag: "--tls-listen".to_string(),
            value: listen_str.clone(),
            reason: e.to_string(),
        })?;
    let cert = cert.ok_or_else(|| ConfigError::InvalidValue {
        flag: "--tls-cert".to_string(),
        value: "(unset)".to_string(),
        reason: "--tls-listen requires both --tls-cert and --tls-key".to_string(),
    })?;
    let key = key.ok_or_else(|| ConfigError::InvalidValue {
        flag: "--tls-key".to_string(),
        value: "(unset)".to_string(),
        reason: "--tls-listen requires both --tls-cert and --tls-key".to_string(),
    })?;
    let max_connections = resolve_tls_max_connections(max_connections_raw)?;
    Ok(Some(TlsConfig {
        listen,
        cert: PathBuf::from(cert),
        key: PathBuf::from(key),
        client_ca: client_ca.map(PathBuf::from),
        max_connections,
    }))
}

/// Resolve `--host-max-inflight`: it defaults to (and is clamped down to) the
/// pool size — one in-flight request per persistent connection — and rejects an
/// explicit `0`.
fn resolve_host_max_inflight(
    raw: Option<String>,
    host_pool_size: usize,
) -> Result<usize, ConfigError> {
    match parse_optional_usize_flag("--host-max-inflight", raw, HOST_MAX_INFLIGHT_ENV)? {
        None => Ok(host_pool_size),
        Some(0) => Err(ConfigError::InvalidValue {
            flag: "--host-max-inflight".to_string(),
            value: "0".to_string(),
            reason: "must be at least 1".to_string(),
        }),
        Some(n) => Ok(n.min(host_pool_size)),
    }
}

/// Resolve `--tls-max-connections`: the default, or a value validated against
/// the `1..=MAX_TLS_MAX_CONNECTIONS` range.
fn resolve_tls_max_connections(raw: Option<String>) -> Result<usize, ConfigError> {
    let Some(raw) = raw else {
        return Ok(DEFAULT_TLS_MAX_CONNECTIONS);
    };
    let n = raw
        .parse::<usize>()
        .map_err(|e| ConfigError::InvalidValue {
            flag: "--tls-max-connections".to_string(),
            value: raw.clone(),
            reason: e.to_string(),
        })?;
    if n == 0 || n > MAX_TLS_MAX_CONNECTIONS {
        return Err(ConfigError::InvalidValue {
            flag: "--tls-max-connections".to_string(),
            value: raw,
            reason: format!("must be in 1..={MAX_TLS_MAX_CONNECTIONS}"),
        });
    }
    Ok(n)
}

/// Resolve `--max-frame-size`: CLI value > env var > the default,
/// validating the `1..=MAX_FRAME_SIZE_CEILING` range.
fn resolve_max_frame_size(cli_raw: Option<String>) -> Result<usize, ConfigError> {
    match cli_raw.or_else(|| std::env::var(MAX_FRAME_SIZE_ENV).ok()) {
        None => Ok(DEFAULT_MAX_FRAME_SIZE),
        Some(raw) => {
            let n = raw
                .parse::<usize>()
                .map_err(|e| ConfigError::InvalidValue {
                    flag: "--max-frame-size".to_string(),
                    value: raw.clone(),
                    reason: e.to_string(),
                })?;
            if n == 0 || n > MAX_FRAME_SIZE_CEILING {
                return Err(ConfigError::InvalidValue {
                    flag: "--max-frame-size".to_string(),
                    value: raw,
                    reason: format!("must be in 1..={MAX_FRAME_SIZE_CEILING}"),
                });
            }
            Ok(n)
        }
    }
}

/// Resolve `--host-pool-size`: CLI value > env var > the default,
/// validating the `1..=MAX_HOST_POOL_SIZE` range.
fn resolve_host_pool_size(cli_raw: Option<String>) -> Result<usize, ConfigError> {
    match cli_raw.or_else(|| std::env::var(HOST_POOL_SIZE_ENV).ok()) {
        None => Ok(DEFAULT_HOST_POOL_SIZE),
        Some(raw) => {
            let n = raw
                .parse::<usize>()
                .map_err(|e| ConfigError::InvalidValue {
                    flag: "--host-pool-size".to_string(),
                    value: raw.clone(),
                    reason: e.to_string(),
                })?;
            if n == 0 || n > MAX_HOST_POOL_SIZE {
                return Err(ConfigError::InvalidValue {
                    flag: "--host-pool-size".to_string(),
                    value: raw,
                    reason: format!("must be in 1..={MAX_HOST_POOL_SIZE}"),
                });
            }
            Ok(n)
        }
    }
}

/// Resolve an OPTIONAL `usize` flag: CLI value > env var > `None`.  A
/// present-but-non-numeric value is a hard [`ConfigError::InvalidValue`].
fn parse_optional_usize_flag(
    flag: &str,
    cli_raw: Option<String>,
    env_var: &str,
) -> Result<Option<usize>, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(None),
        Some(raw) => raw
            .parse::<usize>()
            .map(Some)
            .map_err(|e| ConfigError::InvalidValue {
                flag: flag.to_string(),
                value: raw,
                reason: e.to_string(),
            }),
    }
}

/// Resolve `--rate-limit-rps`: CLI value > env var > the default
/// [`DEFAULT_RATE_LIMIT_RPS`].  A non-numeric value is a typed
/// [`ConfigError::InvalidValue`]; `0` is valid (disables the limiter).
fn resolve_rate_limit_rps(cli_raw: Option<String>) -> Result<u32, ConfigError> {
    match cli_raw.or_else(|| std::env::var(RATE_LIMIT_RPS_ENV).ok()) {
        None => Ok(DEFAULT_RATE_LIMIT_RPS),
        Some(raw) => raw.parse::<u32>().map_err(|e| ConfigError::InvalidValue {
            flag: "--rate-limit-rps".to_string(),
            value: raw,
            reason: e.to_string(),
        }),
    }
}

/// Resolve `--ok-admission-stage`: CLI value > env var > the default
/// [`AdmissionStage::Finalized`].  An unrecognised stage is a typed
/// [`ConfigError::InvalidValue`].
fn resolve_admission_stage(cli_raw: Option<String>) -> Result<AdmissionStage, ConfigError> {
    match cli_raw.or_else(|| std::env::var(OK_ADMISSION_STAGE_ENV).ok()) {
        None => Ok(AdmissionStage::Finalized),
        Some(raw) => raw
            .parse::<AdmissionStage>()
            .map_err(|()| ConfigError::InvalidValue {
                flag: "--ok-admission-stage".to_string(),
                value: raw,
                reason: "expected one of Received|LocallyAdmitted|Sequenced|Finalized".to_string(),
            }),
    }
}

/// Resolve an OPTIONAL `SocketAddr` flag: CLI value > env var > `None`.
/// A present-but-malformed address is a hard [`ConfigError::InvalidValue`].
fn parse_optional_socket_addr_flag(
    flag: &str,
    cli_raw: Option<String>,
    env_var: &str,
) -> Result<Option<SocketAddr>, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(None),
        Some(raw) => raw
            .parse::<SocketAddr>()
            .map(Some)
            .map_err(|e| ConfigError::InvalidValue {
                flag: flag.to_string(),
                value: raw,
                reason: e.to_string(),
            }),
    }
}

/// The raw, unresolved CLI strings collected from argv, before the
/// environment fallback + type validation that [`Config::parse`]
/// applies.  Splitting the argv scan out of `parse` keeps each step a
/// single, reviewable concern (and each function within the linter's
/// length budget).
#[derive(Default)]
struct RawArgs {
    listen: Option<String>,
    handler_threads: Option<String>,
    indexer_db: Option<String>,
    free_tier: Option<String>,
    action_cost: Option<String>,
    epoch_length: Option<String>,
    gas_pool_actor: Option<String>,
    deployment_id: Option<String>,
    ok_admission_stage: Option<String>,
    host_addr: Option<String>,
    event_subscribe_addr: Option<String>,
    auth_token_file: Option<String>,
    rate_limit_rps: Option<String>,
    host_pool_size: Option<String>,
    host_max_inflight: Option<String>,
    request_deadline_ms: Option<String>,
    max_frame_size: Option<String>,
    idempotency_ttl_secs: Option<String>,
    tls_listen: Option<String>,
    tls_cert: Option<String>,
    tls_key: Option<String>,
    mtls_client_ca: Option<String>,
    tls_max_connections: Option<String>,
}

impl RawArgs {
    /// Scan argv (`args[0]` is the program name; parsing starts at
    /// `args[1]`) into the raw option strings.  `-h`/`--help` and
    /// `-V`/`--version` short-circuit as their typed sentinels.
    fn scan(args: &[String]) -> Result<Self, ConfigError> {
        let mut raw = RawArgs::default();
        let mut i = 1;
        while let Some(arg) = args.get(i) {
            match arg.as_str() {
                "-h" | "--help" => return Err(ConfigError::HelpRequested),
                "-V" | "--version" => return Err(ConfigError::VersionRequested),
                "--listen" => raw.listen = Some(take_value(args, &mut i, "--listen")?),
                "--handler-threads" => {
                    raw.handler_threads = Some(take_value(args, &mut i, "--handler-threads")?);
                }
                "--indexer-db" => raw.indexer_db = Some(take_value(args, &mut i, "--indexer-db")?),
                "--free-tier" => raw.free_tier = Some(take_value(args, &mut i, "--free-tier")?),
                "--action-cost" => {
                    raw.action_cost = Some(take_value(args, &mut i, "--action-cost")?);
                }
                "--epoch-length" => {
                    raw.epoch_length = Some(take_value(args, &mut i, "--epoch-length")?);
                }
                "--gas-pool-actor" => {
                    raw.gas_pool_actor = Some(take_value(args, &mut i, "--gas-pool-actor")?);
                }
                "--deployment-id" => {
                    raw.deployment_id = Some(take_value(args, &mut i, "--deployment-id")?);
                }
                "--ok-admission-stage" => {
                    raw.ok_admission_stage =
                        Some(take_value(args, &mut i, "--ok-admission-stage")?);
                }
                "--host-addr" => raw.host_addr = Some(take_value(args, &mut i, "--host-addr")?),
                "--event-subscribe-addr" => {
                    raw.event_subscribe_addr =
                        Some(take_value(args, &mut i, "--event-subscribe-addr")?);
                }
                "--auth-token-file" => {
                    raw.auth_token_file = Some(take_value(args, &mut i, "--auth-token-file")?);
                }
                "--rate-limit-rps" => {
                    raw.rate_limit_rps = Some(take_value(args, &mut i, "--rate-limit-rps")?);
                }
                "--host-pool-size" => {
                    raw.host_pool_size = Some(take_value(args, &mut i, "--host-pool-size")?);
                }
                "--host-max-inflight" => {
                    raw.host_max_inflight = Some(take_value(args, &mut i, "--host-max-inflight")?);
                }
                "--request-deadline-ms" => {
                    raw.request_deadline_ms =
                        Some(take_value(args, &mut i, "--request-deadline-ms")?);
                }
                "--max-frame-size" => {
                    raw.max_frame_size = Some(take_value(args, &mut i, "--max-frame-size")?);
                }
                "--idempotency-ttl-secs" => {
                    raw.idempotency_ttl_secs =
                        Some(take_value(args, &mut i, "--idempotency-ttl-secs")?);
                }
                "--tls-listen" => raw.tls_listen = Some(take_value(args, &mut i, "--tls-listen")?),
                "--tls-cert" => raw.tls_cert = Some(take_value(args, &mut i, "--tls-cert")?),
                "--tls-key" => raw.tls_key = Some(take_value(args, &mut i, "--tls-key")?),
                "--mtls-client-ca" => {
                    raw.mtls_client_ca = Some(take_value(args, &mut i, "--mtls-client-ca")?);
                }
                "--tls-max-connections" => {
                    raw.tls_max_connections =
                        Some(take_value(args, &mut i, "--tls-max-connections")?);
                }
                other => return Err(ConfigError::UnknownArgument(other.to_string())),
            }
            i += 1;
        }
        Ok(raw)
    }
}

/// Take the value argument that follows the flag at index `*i`,
/// advancing `*i` past it.  Returns [`ConfigError::MissingValue`] if the
/// flag is the last token.
fn take_value(args: &[String], i: &mut usize, flag: &str) -> Result<String, ConfigError> {
    let value = args.get(*i + 1).ok_or_else(|| ConfigError::MissingValue {
        flag: flag.to_string(),
    })?;
    *i += 1;
    Ok(value.clone())
}

/// Resolve `--handler-threads`: CLI value > env var > the compiled
/// default, validating the `1..=MAX_HANDLER_THREADS` range.
fn resolve_handler_threads(cli_raw: Option<String>) -> Result<usize, ConfigError> {
    match cli_raw.or_else(|| std::env::var(HANDLER_THREADS_ENV).ok()) {
        None => Ok(DEFAULT_HANDLER_THREADS),
        Some(raw) => {
            let n = raw
                .parse::<usize>()
                .map_err(|e| ConfigError::InvalidValue {
                    flag: "--handler-threads".to_string(),
                    value: raw.clone(),
                    reason: e.to_string(),
                })?;
            if n == 0 || n > MAX_HANDLER_THREADS {
                return Err(ConfigError::InvalidValue {
                    flag: "--handler-threads".to_string(),
                    value: raw,
                    reason: format!("must be in 1..={MAX_HANDLER_THREADS}"),
                });
            }
            Ok(n)
        }
    }
}

/// Resolve a `u128` flag: CLI value > env var > `0`.  Returns a typed
/// [`ConfigError::InvalidValue`] on a non-numeric value.
fn parse_u128_flag(
    flag: &str,
    cli_raw: Option<String>,
    env_var: &str,
) -> Result<u128, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(0),
        Some(raw) => raw.parse::<u128>().map_err(|e| ConfigError::InvalidValue {
            flag: flag.to_string(),
            value: raw,
            reason: e.to_string(),
        }),
    }
}

/// Resolve a `u64` flag: CLI value > env var > `0`.  Returns a typed
/// [`ConfigError::InvalidValue`] on a non-numeric value.
fn parse_u64_flag(flag: &str, cli_raw: Option<String>, env_var: &str) -> Result<u64, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(0),
        Some(raw) => raw.parse::<u64>().map_err(|e| ConfigError::InvalidValue {
            flag: flag.to_string(),
            value: raw,
            reason: e.to_string(),
        }),
    }
}

/// Resolve an OPTIONAL `u64` flag: CLI value > env var > `None`
/// (absent).  A present-but-non-numeric value is a hard
/// [`ConfigError::InvalidValue`] rather than a silent `None`, so a
/// fat-fingered id is never mistaken for "feature disabled".
fn parse_optional_u64_flag(
    flag: &str,
    cli_raw: Option<String>,
    env_var: &str,
) -> Result<Option<u64>, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(None),
        Some(raw) => raw
            .parse::<u64>()
            .map(Some)
            .map_err(|e| ConfigError::InvalidValue {
                flag: flag.to_string(),
                value: raw,
                reason: e.to_string(),
            }),
    }
}

#[cfg(test)]
mod tests {
    use super::{Config, ConfigError, DEFAULT_LISTEN};

    fn argv(extra: &[&str]) -> Vec<String> {
        let mut v = vec!["knomosis-gateway".to_string()];
        v.extend(extra.iter().map(|s| (*s).to_string()));
        v
    }

    /// No args → the loopback default listen address.
    #[test]
    fn defaults_to_loopback() {
        // Ensure the env override is absent for a deterministic test.
        std::env::remove_var(super::LISTEN_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.listen.to_string(), DEFAULT_LISTEN);
    }

    /// `--listen` overrides the default and parses a SocketAddr.
    #[test]
    fn listen_flag_parsed() {
        let cfg = Config::parse(&argv(&["--listen", "127.0.0.1:9999"])).unwrap();
        assert_eq!(cfg.listen.to_string(), "127.0.0.1:9999");
    }

    /// `--help` / `--version` surface as their typed sentinels.
    #[test]
    fn help_and_version_sentinels() {
        assert!(matches!(
            Config::parse(&argv(&["--help"])),
            Err(ConfigError::HelpRequested)
        ));
        assert!(matches!(
            Config::parse(&argv(&["-h"])),
            Err(ConfigError::HelpRequested)
        ));
        assert!(matches!(
            Config::parse(&argv(&["--version"])),
            Err(ConfigError::VersionRequested)
        ));
        assert!(matches!(
            Config::parse(&argv(&["-V"])),
            Err(ConfigError::VersionRequested)
        ));
    }

    /// `--listen` with no value → `MissingValue`.
    #[test]
    fn listen_missing_value() {
        assert!(matches!(
            Config::parse(&argv(&["--listen"])),
            Err(ConfigError::MissingValue { .. })
        ));
    }

    /// A malformed listen address → `InvalidValue`.
    #[test]
    fn listen_invalid_value() {
        assert!(matches!(
            Config::parse(&argv(&["--listen", "not-an-addr"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// An unknown flag → `UnknownArgument`.
    #[test]
    fn unknown_argument_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--nope"])),
            Err(ConfigError::UnknownArgument(_))
        ));
    }

    /// `--handler-threads` defaults to [`super::DEFAULT_HANDLER_THREADS`]
    /// and is overridable on the CLI.
    #[test]
    fn handler_threads_default_and_override() {
        std::env::remove_var(super::HANDLER_THREADS_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.handler_threads, super::DEFAULT_HANDLER_THREADS);
        let cfg = Config::parse(&argv(&["--handler-threads", "4"])).unwrap();
        assert_eq!(cfg.handler_threads, 4);
    }

    /// `--handler-threads 0` is rejected (the pool must be non-empty).
    #[test]
    fn handler_threads_zero_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--handler-threads", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--handler-threads` above the ceiling is rejected.
    #[test]
    fn handler_threads_above_ceiling_rejected() {
        let too_many = (super::MAX_HANDLER_THREADS + 1).to_string();
        assert!(matches!(
            Config::parse(&argv(&["--handler-threads", &too_many])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// A non-numeric `--handler-threads` value is rejected.
    #[test]
    fn handler_threads_non_numeric_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--handler-threads", "lots"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--indexer-db` is parsed to a path; absent → `None`.
    #[test]
    fn indexer_db_optional() {
        std::env::remove_var(super::INDEXER_DB_ENV);
        assert_eq!(Config::parse(&argv(&[])).unwrap().indexer_db, None);
        let cfg = Config::parse(&argv(&["--indexer-db", "/var/lib/knomosis/index.db"])).unwrap();
        assert_eq!(
            cfg.indexer_db,
            Some(std::path::PathBuf::from("/var/lib/knomosis/index.db"))
        );
    }

    /// `--free-tier` / `--action-cost` / `--epoch-length` default to 0
    /// and parse as integers.
    #[test]
    fn budget_knobs_default_and_parse() {
        std::env::remove_var(super::FREE_TIER_ENV);
        std::env::remove_var(super::ACTION_COST_ENV);
        std::env::remove_var(super::EPOCH_LENGTH_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.free_tier, 0);
        assert_eq!(cfg.action_cost, 0);
        assert_eq!(cfg.epoch_length, 0);
        let cfg = Config::parse(&argv(&[
            "--free-tier",
            "1000",
            "--action-cost",
            "5",
            "--epoch-length",
            "7200",
        ]))
        .unwrap();
        assert_eq!(cfg.free_tier, 1000);
        assert_eq!(cfg.action_cost, 5);
        assert_eq!(cfg.epoch_length, 7200);
    }

    /// A non-numeric budget knob → `InvalidValue`.
    #[test]
    fn budget_knob_non_numeric_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--free-tier", "lots"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--gas-pool-actor` is optional (`None` by default) and parses to
    /// `Some(id)` when supplied.
    #[test]
    fn gas_pool_actor_optional_and_parsed() {
        std::env::remove_var(super::GAS_POOL_ACTOR_ENV);
        assert_eq!(Config::parse(&argv(&[])).unwrap().gas_pool_actor, None);
        let cfg = Config::parse(&argv(&["--gas-pool-actor", "161"])).unwrap();
        assert_eq!(cfg.gas_pool_actor, Some(161));
    }

    /// A present-but-non-numeric `--gas-pool-actor` is a hard error, not
    /// a silent disable.
    #[test]
    fn gas_pool_actor_non_numeric_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--gas-pool-actor", "pool"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--deployment-id` defaults to empty and is overridable.
    #[test]
    fn deployment_id_default_and_override() {
        std::env::remove_var(super::DEPLOYMENT_ID_ENV);
        assert_eq!(Config::parse(&argv(&[])).unwrap().deployment_id, "");
        let cfg = Config::parse(&argv(&["--deployment-id", "knx-devnet-1"])).unwrap();
        assert_eq!(cfg.deployment_id, "knx-devnet-1");
    }

    /// `--ok-admission-stage` defaults to `Finalized`, parses every
    /// contract token, and rejects an unknown stage.
    #[test]
    fn ok_admission_stage_default_parse_and_reject() {
        use super::AdmissionStage;
        std::env::remove_var(super::OK_ADMISSION_STAGE_ENV);
        assert_eq!(
            Config::parse(&argv(&[])).unwrap().ok_admission_stage,
            AdmissionStage::Finalized
        );
        let cfg = Config::parse(&argv(&["--ok-admission-stage", "Sequenced"])).unwrap();
        assert_eq!(cfg.ok_admission_stage, AdmissionStage::Sequenced);
        assert!(matches!(
            Config::parse(&argv(&["--ok-admission-stage", "Pending"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--host-addr` / `--event-subscribe-addr` are optional `SocketAddr`s;
    /// a malformed address is rejected.
    #[test]
    fn upstream_addrs_optional_and_validated() {
        std::env::remove_var(super::HOST_ADDR_ENV);
        std::env::remove_var(super::EVENT_SUBSCRIBE_ADDR_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.host_addr, None);
        assert_eq!(cfg.event_subscribe_addr, None);
        let cfg = Config::parse(&argv(&[
            "--host-addr",
            "127.0.0.1:9101",
            "--event-subscribe-addr",
            "127.0.0.1:9102",
        ]))
        .unwrap();
        assert_eq!(cfg.host_addr.unwrap().to_string(), "127.0.0.1:9101");
        assert_eq!(
            cfg.event_subscribe_addr.unwrap().to_string(),
            "127.0.0.1:9102"
        );
        assert!(matches!(
            Config::parse(&argv(&["--host-addr", "not-an-addr"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--rate-limit-rps` defaults to [`super::DEFAULT_RATE_LIMIT_RPS`],
    /// accepts `0` (disabled), and rejects a non-numeric value.
    #[test]
    fn rate_limit_rps_default_parse_and_reject() {
        std::env::remove_var(super::RATE_LIMIT_RPS_ENV);
        assert_eq!(
            Config::parse(&argv(&[])).unwrap().rate_limit_rps,
            super::DEFAULT_RATE_LIMIT_RPS
        );
        assert_eq!(
            Config::parse(&argv(&["--rate-limit-rps", "0"]))
                .unwrap()
                .rate_limit_rps,
            0
        );
        assert_eq!(
            Config::parse(&argv(&["--rate-limit-rps", "250"]))
                .unwrap()
                .rate_limit_rps,
            250
        );
        assert!(matches!(
            Config::parse(&argv(&["--rate-limit-rps", "fast"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// The submit-pool knobs default sensibly, clamp `--host-max-inflight`
    /// to the pool size, and reject out-of-range / zero values.
    #[test]
    fn host_pool_knobs() {
        for var in [
            super::HOST_POOL_SIZE_ENV,
            super::HOST_MAX_INFLIGHT_ENV,
            super::REQUEST_DEADLINE_MS_ENV,
            super::MAX_FRAME_SIZE_ENV,
        ] {
            std::env::remove_var(var);
        }
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.host_pool_size, super::DEFAULT_HOST_POOL_SIZE);
        assert_eq!(cfg.host_max_inflight, super::DEFAULT_HOST_POOL_SIZE); // defaults to pool size
        assert_eq!(cfg.request_deadline_ms, super::DEFAULT_REQUEST_DEADLINE_MS);
        assert_eq!(cfg.max_frame_size, super::DEFAULT_MAX_FRAME_SIZE);
        // `--max-frame-size` is range-checked (0 and over-ceiling rejected).
        assert!(matches!(
            Config::parse(&argv(&["--max-frame-size", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        let over = (super::MAX_FRAME_SIZE_CEILING + 1).to_string();
        assert!(matches!(
            Config::parse(&argv(&["--max-frame-size", &over])),
            Err(ConfigError::InvalidValue { .. })
        ));
        // `--host-max-inflight` is clamped down to the pool size.
        let cfg = Config::parse(&argv(&[
            "--host-pool-size",
            "4",
            "--host-max-inflight",
            "100",
        ]))
        .unwrap();
        assert_eq!(cfg.host_pool_size, 4);
        assert_eq!(cfg.host_max_inflight, 4);
        // Zero / out-of-range are rejected.
        assert!(matches!(
            Config::parse(&argv(&["--host-pool-size", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        assert!(matches!(
            Config::parse(&argv(&["--host-max-inflight", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        assert!(matches!(
            Config::parse(&argv(&["--request-deadline-ms", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--idempotency-ttl-secs` defaults to 120, accepts `0` (disabled),
    /// and rejects a non-numeric value.
    #[test]
    fn idempotency_ttl_default_and_parse() {
        std::env::remove_var(super::IDEMPOTENCY_TTL_SECS_ENV);
        assert_eq!(
            Config::parse(&argv(&[])).unwrap().idempotency_ttl_secs,
            super::DEFAULT_IDEMPOTENCY_TTL_SECS
        );
        assert_eq!(
            Config::parse(&argv(&["--idempotency-ttl-secs", "0"]))
                .unwrap()
                .idempotency_ttl_secs,
            0
        );
        assert!(matches!(
            Config::parse(&argv(&["--idempotency-ttl-secs", "soon"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--auth-token-file` is an optional path; absent → `None`.
    #[test]
    fn auth_token_file_optional() {
        std::env::remove_var(super::AUTH_TOKEN_FILE_ENV);
        assert_eq!(Config::parse(&argv(&[])).unwrap().auth_token_file, None);
        let cfg = Config::parse(&argv(&["--auth-token-file", "/etc/knomosis/tokens"])).unwrap();
        assert_eq!(
            cfg.auth_token_file,
            Some(std::path::PathBuf::from("/etc/knomosis/tokens"))
        );
    }

    /// `AdmissionStage::as_str` round-trips through `FromStr` for every
    /// variant (the `/v1/info` wire tokens match the config tokens).
    #[test]
    fn admission_stage_str_roundtrip() {
        use super::AdmissionStage::{Finalized, LocallyAdmitted, Received, Sequenced};
        for stage in [Received, LocallyAdmitted, Sequenced, Finalized] {
            assert_eq!(stage.as_str().parse::<super::AdmissionStage>(), Ok(stage));
        }
    }

    /// Clear every TLS-related env var so the TLS-parsing tests are
    /// deterministic regardless of the ambient environment.
    fn clear_tls_env() {
        for var in [
            super::TLS_LISTEN_ENV,
            super::TLS_CERT_ENV,
            super::TLS_KEY_ENV,
            super::MTLS_CLIENT_CA_ENV,
            super::TLS_MAX_CONNECTIONS_ENV,
        ] {
            std::env::remove_var(var);
        }
    }

    /// No `--tls-listen` → native TLS disabled (`tls` is `None`).
    #[test]
    fn tls_disabled_by_default() {
        clear_tls_env();
        assert!(Config::parse(&argv(&[])).unwrap().tls.is_none());
    }

    /// `--tls-listen` with cert + key parses into a full [`super::TlsConfig`]
    /// (no mTLS, the default connection cap).
    #[test]
    fn tls_full_config_parsed() {
        clear_tls_env();
        let cfg = Config::parse(&argv(&[
            "--tls-listen",
            "127.0.0.1:8443",
            "--tls-cert",
            "/etc/knomosis/tls/cert.pem",
            "--tls-key",
            "/etc/knomosis/tls/key.pem",
        ]))
        .unwrap();
        let tls = cfg.tls.expect("TLS enabled");
        assert_eq!(tls.listen.to_string(), "127.0.0.1:8443");
        assert_eq!(
            tls.cert,
            std::path::PathBuf::from("/etc/knomosis/tls/cert.pem")
        );
        assert_eq!(
            tls.key,
            std::path::PathBuf::from("/etc/knomosis/tls/key.pem")
        );
        assert_eq!(tls.client_ca, None);
        assert_eq!(tls.max_connections, super::DEFAULT_TLS_MAX_CONNECTIONS);
    }

    /// `--mtls-client-ca` enables mTLS; `--tls-max-connections` is honoured.
    #[test]
    fn tls_mtls_and_max_connections_parsed() {
        clear_tls_env();
        let cfg = Config::parse(&argv(&[
            "--tls-listen",
            "0.0.0.0:8443",
            "--tls-cert",
            "/c.pem",
            "--tls-key",
            "/k.pem",
            "--mtls-client-ca",
            "/ca.pem",
            "--tls-max-connections",
            "32",
        ]))
        .unwrap();
        let tls = cfg.tls.expect("TLS enabled");
        assert_eq!(tls.client_ca, Some(std::path::PathBuf::from("/ca.pem")));
        assert_eq!(tls.max_connections, 32);
    }

    /// `--tls-listen` without cert/key fails fast.
    #[test]
    fn tls_listen_requires_cert_and_key() {
        clear_tls_env();
        assert!(matches!(
            Config::parse(&argv(&["--tls-listen", "127.0.0.1:8443"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        // Cert without key is still incomplete.
        assert!(matches!(
            Config::parse(&argv(&[
                "--tls-listen",
                "127.0.0.1:8443",
                "--tls-cert",
                "/c.pem"
            ])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// A TLS knob supplied *without* `--tls-listen` is a hard error (never a
    /// silently-ignored flag).
    #[test]
    fn tls_knob_without_listen_rejected() {
        clear_tls_env();
        for extra in [
            vec!["--tls-cert", "/c.pem"],
            vec!["--tls-key", "/k.pem"],
            vec!["--mtls-client-ca", "/ca.pem"],
            vec!["--tls-max-connections", "10"],
        ] {
            assert!(
                matches!(
                    Config::parse(&argv(&extra)),
                    Err(ConfigError::InvalidValue { .. })
                ),
                "a {extra:?} without --tls-listen must be rejected"
            );
        }
    }

    /// A malformed TLS listen address / out-of-range connection cap is
    /// rejected.
    #[test]
    fn tls_invalid_values_rejected() {
        clear_tls_env();
        assert!(matches!(
            Config::parse(&argv(&[
                "--tls-listen",
                "not-an-addr",
                "--tls-cert",
                "/c.pem",
                "--tls-key",
                "/k.pem"
            ])),
            Err(ConfigError::InvalidValue { .. })
        ));
        let over = (super::MAX_TLS_MAX_CONNECTIONS + 1).to_string();
        for bad in ["0", over.as_str()] {
            assert!(matches!(
                Config::parse(&argv(&[
                    "--tls-listen",
                    "127.0.0.1:8443",
                    "--tls-cert",
                    "/c.pem",
                    "--tls-key",
                    "/k.pem",
                    "--tls-max-connections",
                    bad,
                ])),
                Err(ConfigError::InvalidValue { .. })
            ));
        }
    }
}
