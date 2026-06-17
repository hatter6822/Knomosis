// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G4.2 native in-process HTTPS — the TLS listener on `--tls-listen`.
//!
//! This is the **TLS-specific** half: the `rustls 0.23` (TLS 1.3, `ring`)
//! `ServerConfig` (optional mTLS), a SIGHUP zero-downtime certificate reload,
//! and the accept loop / handshake.  Once the handshake completes, every
//! connection is served by the **transport-neutral** [`crate::http::conn`]
//! handler — the exact same strict reader + writer + keep-alive loop the
//! plaintext [`crate::http::plain`] listener uses — so the two transports
//! cannot diverge in security behaviour.  The TLS stack is the workspace's own
//! `rustls 0.23` (the same `knomosis-host` uses); PEM cert/key/CA loading
//! reuses `knomosis_host::tls`'s vetted loaders.

use std::io::BufReader;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};

use rustls::{ServerConfig, ServerConnection, StreamOwned};

use crate::config::{Config, TlsConfig};
use crate::http::conn::{self, DeadlineStream};
use crate::state::AppState;

/// The **hot-swappable** server config.  The accept loop clones the current
/// `Arc<ServerConfig>` under a brief lock for each new connection; a `SIGHUP`
/// reload ([`reload_server_config`]) swaps in a freshly-loaded one, so a
/// certificate can be rotated **without dropping the listener or any existing
/// session** (G4.2 zero-downtime rotation).
type SharedConfig = Arc<Mutex<Arc<ServerConfig>>>;

/// Errors standing up the native-TLS listener at startup (surfaced by
/// [`crate::http::serve`] as a fatal `ServeError`, so a misconfigured TLS
/// surface fails fast before the gateway announces readiness).
#[derive(Debug, thiserror::Error)]
pub enum TlsSetupError {
    /// The server certificate chain (`--tls-cert`) could not be loaded.
    #[error("loading the TLS certificate ({0}) failed")]
    Cert(#[source] knomosis_host::tls::TlsConfigError),
    /// The server private key (`--tls-key`) could not be loaded.
    #[error("loading the TLS private key ({0}) failed")]
    Key(#[source] knomosis_host::tls::TlsConfigError),
    /// The mTLS client-CA bundle (`--mtls-client-ca`) could not be loaded.
    #[error("loading the mTLS client CA ({0}) failed")]
    ClientCa(#[source] knomosis_host::tls::TlsConfigError),
    /// The mTLS client-revocation list (`--mtls-crl`) could not be loaded.
    #[error("loading the mTLS CRL failed: {0}")]
    Crl(String),
    /// `rustls` rejected the assembled server configuration (e.g. the key
    /// does not match the certificate, or a client-CA cert is not a valid
    /// trust anchor).
    #[error("building the rustls server config failed: {0}")]
    Build(String),
    /// Binding the TLS listen socket failed (address in use, permission …).
    #[error("failed to bind the TLS listener on {addr}: {reason}")]
    Bind {
        /// The address that could not be bound.
        addr: String,
        /// The OS diagnostic.
        reason: String,
    },
    /// The TLS accept thread could not be spawned.
    #[error("failed to spawn the TLS accept thread: {0}")]
    Spawn(String),
}

/// Start the native-TLS accept loop on its own thread **iff** `--tls-listen`
/// is configured.  Returns `Ok(None)` when TLS is disabled, or the accept
/// thread's join handle (the caller joins it on drain).
///
/// The `rustls` `ServerConfig` is built and the socket bound **here**, before
/// returning, so a bad cert / key / CA / CRL / address is a fatal startup error
/// rather than a per-connection fault.
///
/// # Errors
///
/// Returns a [`TlsSetupError`] if the certificate / key / client-CA / CRL
/// cannot be loaded, `rustls` rejects the configuration, the socket cannot be
/// bound, or the accept thread cannot be spawned.
pub(crate) fn spawn_tls_listener(
    config: &Config,
    state: &Arc<AppState>,
) -> Result<Option<JoinHandle<()>>, TlsSetupError> {
    let Some(tls) = &config.tls else {
        return Ok(None);
    };
    // Built + bound up front so a bad cert / key / CA / CRL is a fatal startup
    // error; then wrapped for hot-swap on SIGHUP.
    let server_config: SharedConfig = Arc::new(Mutex::new(build_server_config(tls)?));
    let listener = TcpListener::bind(tls.listen).map_err(|e| TlsSetupError::Bind {
        addr: tls.listen.to_string(),
        reason: e.to_string(),
    })?;
    listener
        .set_nonblocking(true)
        .map_err(|e| TlsSetupError::Bind {
            addr: tls.listen.to_string(),
            reason: e.to_string(),
        })?;
    // SIGHUP triggers a zero-downtime certificate reload (handled between
    // accepts in the loop below).
    let reload = Arc::new(AtomicBool::new(false));
    register_reload_signal(&reload);
    tracing::info!(
        listen = %tls.listen,
        mtls = tls.client_ca.is_some(),
        mtls_crl = tls.mtls_crl.is_some(),
        max_connections = tls.max_connections,
        "knomosis-gateway native TLS listener started (SIGHUP reloads the certificate)"
    );
    let state = Arc::clone(state);
    let shutdown = Arc::clone(&state.shutdown);
    let tls = tls.clone();
    let handle = thread::Builder::new()
        .name("knx-gw-tls-accept".to_string())
        .spawn(move || {
            accept_loop(&listener, &server_config, &reload, &tls, &state, &shutdown);
        })
        .map_err(|e| TlsSetupError::Spawn(e.to_string()))?;
    Ok(Some(handle))
}

/// Register `SIGHUP` as the certificate-reload trigger (zero-downtime
/// rotation): each `SIGHUP` sets the shared `reload` flag, which the accept
/// loop observes and acts on between accepts.  A registration failure is
/// logged, not fatal — the gateway keeps serving with the loaded certificate.
fn register_reload_signal(reload: &Arc<AtomicBool>) {
    #[cfg(unix)]
    if let Err(error) = signal_hook::flag::register(signal_hook::consts::SIGHUP, Arc::clone(reload))
    {
        tracing::warn!(%error, "failed to register the SIGHUP certificate-reload handler");
    }
    #[cfg(not(unix))]
    let _ = reload; // no SIGHUP off Unix; the certificate is reloaded on restart
}

/// Reload the certificate / key / client-CA / CRL from disk and **hot-swap**
/// the shared `ServerConfig` (the `SIGHUP` rotation).  On any load / build
/// error the **current** certificate is kept, so a fat-fingered rotation never
/// breaks serving; the swap is atomic from a new connection's view (existing
/// sessions keep their old config).
fn reload_server_config(current: &SharedConfig, tls: &TlsConfig) {
    match build_server_config(tls) {
        Ok(new_config) => {
            *current.lock().unwrap_or_else(PoisonError::into_inner) = new_config;
            tracing::info!(cert = %tls.cert.display(), "TLS certificate hot-reloaded (SIGHUP)");
        }
        Err(error) => {
            tracing::error!(
                %error,
                "TLS certificate reload failed; keeping the current certificate"
            );
        }
    }
}

/// Build the `rustls 0.23` `ServerConfig`: TLS 1.3 only, the `ring` backend
/// (pinned per-config so any process-global default is irrelevant), the
/// gateway's server cert + key, and — iff `--mtls-client-ca` is set — a WebPKI
/// client-certificate verifier **requiring** a chain to that CA, optionally
/// **checking revocation** against the `--mtls-crl` CRL bundle.
fn build_server_config(tls: &TlsConfig) -> Result<Arc<ServerConfig>, TlsSetupError> {
    use knomosis_host::tls::{load_certs, load_private_key};

    let certs = load_certs(&tls.cert).map_err(TlsSetupError::Cert)?;
    let key = load_private_key(&tls.key).map_err(TlsSetupError::Key)?;

    // Per-config crypto-provider pinning (mirrors `knomosis_host::tls`): the
    // resulting config always uses `ring`, regardless of any process default a
    // downstream consumer may have installed.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let provider = Arc::new(rustls::crypto::ring::default_provider());

    let builder = ServerConfig::builder_with_provider(Arc::clone(&provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| TlsSetupError::Build(e.to_string()))?;

    let config = match &tls.client_ca {
        None => builder
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .map_err(|e| TlsSetupError::Build(e.to_string()))?,
        Some(ca_path) => {
            let mut roots = rustls::RootCertStore::empty();
            for cert in load_certs(ca_path).map_err(TlsSetupError::ClientCa)? {
                roots
                    .add(cert)
                    .map_err(|e| TlsSetupError::Build(format!("client CA rejected: {e}")))?;
            }
            let mut verifier_builder = rustls::server::WebPkiClientVerifier::builder_with_provider(
                Arc::new(roots),
                provider,
            );
            // mTLS revocation (best practice): a revoked-but-unexpired client
            // certificate is rejected once a CRL is configured.
            if let Some(crl_path) = &tls.mtls_crl {
                verifier_builder = verifier_builder.with_crls(load_crls(crl_path)?);
            }
            let verifier = verifier_builder
                .build()
                .map_err(|e| TlsSetupError::Build(format!("client verifier: {e}")))?;
            builder
                .with_client_cert_verifier(verifier)
                .with_single_cert(certs, key)
                .map_err(|e| TlsSetupError::Build(e.to_string()))?
        }
    };
    Ok(Arc::new(config))
}

/// Load the PEM-encoded certificate-revocation lists from `path` (one or more
/// `X509 CRL` blocks) into the rustls vocabulary.
fn load_crls(
    path: &std::path::Path,
) -> Result<Vec<rustls::pki_types::CertificateRevocationListDer<'static>>, TlsSetupError> {
    let file = std::fs::File::open(path)
        .map_err(|e| TlsSetupError::Crl(format!("opening {}: {e}", path.display())))?;
    let mut reader = std::io::BufReader::new(file);
    let mut crls = Vec::new();
    for crl in rustls_pemfile::crls(&mut reader) {
        crls.push(crl.map_err(|e| TlsSetupError::Crl(format!("parsing {}: {e}", path.display())))?);
    }
    if crls.is_empty() {
        return Err(TlsSetupError::Crl(format!(
            "no CRL blocks found in {}",
            path.display()
        )));
    }
    Ok(crls)
}

/// The TLS accept loop: reuses the shared [`conn::accept_loop`] with a
/// `pre_accept` hook that performs the SIGHUP certificate reload between
/// accepts, and a per-connection handler that completes the handshake then
/// hands off to [`conn::run_connection`].  Bounded by `--tls-max-connections`,
/// counting toward the shared drain gauge.
fn accept_loop(
    listener: &TcpListener,
    current_config: &SharedConfig,
    reload: &Arc<AtomicBool>,
    tls: &TlsConfig,
    state: &Arc<AppState>,
    shutdown: &Arc<AtomicBool>,
) {
    conn::accept_loop(
        listener,
        shutdown,
        tls.max_connections,
        &state.active_connections,
        || {
            // A SIGHUP since the last iteration → hot-reload the certificate,
            // here (between accepts) so no in-flight handshake is disturbed.
            if reload.swap(false, Ordering::Relaxed) {
                reload_server_config(current_config, tls);
            }
        },
        |stream, guard| {
            // Clone the CURRENT config under a brief lock — a SIGHUP reload
            // swaps it, but an in-flight connection keeps the one it took.
            let server_config = current_config
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone();
            let state = Arc::clone(state);
            let shutdown = Arc::clone(shutdown);
            let spawned = thread::Builder::new()
                .name("knx-gw-tls-conn".to_string())
                .spawn(move || {
                    // The guard rides the connection thread; its `Drop` releases
                    // the slot + decrements the drain gauge on every exit path.
                    let _guard = guard;
                    handle_connection(stream, server_config, &state, &shutdown);
                });
            if spawned.is_err() {
                tracing::error!("failed to spawn a TLS connection thread");
            }
        },
    );
}

/// Complete the TLS handshake and run the keep-alive request loop on one
/// accepted connection.  Consumes `stream` (moved into the `rustls`
/// `StreamOwned`, then the per-request read-deadline wrapper); the socket
/// closes when this returns.
fn handle_connection(
    stream: TcpStream,
    server_config: Arc<ServerConfig>,
    state: &AppState,
    shutdown: &AtomicBool,
) {
    conn::arm_socket(&stream);
    // A second handle on the same underlying socket, used only to tune the SSE
    // write timeout (`--sse-write-timeout-ms`); cloned before the `TcpStream` is
    // moved into the `rustls` `StreamOwned`.  A clone failure leaves the
    // `arm_socket` default in force.
    let control = stream.try_clone().ok();
    let connection = match ServerConnection::new(server_config) {
        Ok(c) => c,
        Err(e) => {
            // Only a rustls mis-configuration reaches here (impossible once the
            // config was built by `build_server_config`); a *handshake* failure
            // (e.g. a missing / revoked client cert under mTLS) surfaces later,
            // on first read, and closes the connection.
            tracing::warn!(error = %e, "TLS session setup failed");
            return;
        }
    };
    let mut reader = BufReader::new(DeadlineStream::new(StreamOwned::new(connection, stream)));
    conn::run_connection(&mut reader, control.as_ref(), state, shutdown);
}

/// End-to-end TLS handshake tests: a real `rustls 0.23` client drives the real
/// accept loop + `build_server_config` over openssl-generated certificates.
/// These exercise the wire path the pure-parser tests cannot — the handshake,
/// the response framing over `rustls`, keep-alive, mTLS, and cert hot-reload.
/// Skipped (with a notice) where `openssl` is unavailable; CI always has it.
#[cfg(test)]
mod handshake_tests {
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use super::{accept_loop, build_server_config, reload_server_config, SharedConfig};
    use crate::config::{AdmissionStage, Config, SseConfig, TlsConfig};
    use crate::state::AppState;

    /// The bearer token the test `AppState` accepts.
    const TOKEN: &str = "tls-token";

    /// Run an `openssl` command; `true` iff it exists and succeeded.
    fn openssl(args: &[&str]) -> bool {
        match Command::new("openssl").args(args).output() {
            Ok(out) if out.status.success() => true,
            Ok(out) => {
                eprintln!(
                    "openssl {args:?} failed: {}",
                    String::from_utf8_lossy(&out.stderr)
                );
                false
            }
            Err(_) => false, // openssl not installed
        }
    }

    /// A path inside `dir`, as an owned `String` (for openssl argv).
    fn at(dir: &Path, name: &str) -> String {
        dir.join(name).to_string_lossy().into_owned()
    }

    /// Generate a test PKI into `dir`: a self-signed **v3** CA, a server
    /// certificate (SAN `IP:127.0.0.1`, `serverAuth`) signed by it, and a
    /// client certificate (`clientAuth`) signed by it (for mTLS).  webpki
    /// requires v3 certificates (a CA must carry `basicConstraints=CA:TRUE`),
    /// so every cert gets explicit extensions.  Returns `false` (skip) if
    /// openssl is unavailable.
    fn gen_pki(dir: &Path) -> bool {
        std::fs::write(
            dir.join("server.ext"),
            "subjectAltName=IP:127.0.0.1\n\
             basicConstraints=CA:FALSE\n\
             keyUsage=digitalSignature,keyEncipherment\n\
             extendedKeyUsage=serverAuth\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("client.ext"),
            "basicConstraints=CA:FALSE\n\
             keyUsage=digitalSignature\n\
             extendedKeyUsage=clientAuth\n",
        )
        .unwrap();
        // Self-signed CA — v3, with basicConstraints=CA:TRUE (a webpki trust
        // anchor cannot be a v1 / non-CA certificate).
        if !openssl(&[
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &at(dir, "ca.key"),
            "-out",
            &at(dir, "ca.crt"),
            "-days",
            "3650",
            "-subj",
            "/CN=Knomosis Test CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            // A Subject Key Identifier so a generated CRL's Authority Key
            // Identifier can reference it (webpki requires a conforming v2 CRL).
            "-addext",
            "subjectKeyIdentifier=hash",
        ]) {
            return false;
        }
        // Server leaf (CSR → CA-signed cert with the IP SAN + serverAuth).
        let ok = openssl(&[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &at(dir, "server.key"),
            "-out",
            &at(dir, "server.csr"),
            "-subj",
            "/CN=knomosis-gateway",
        ]) && openssl(&[
            "x509",
            "-req",
            "-in",
            &at(dir, "server.csr"),
            "-CA",
            &at(dir, "ca.crt"),
            "-CAkey",
            &at(dir, "ca.key"),
            "-CAcreateserial",
            "-out",
            &at(dir, "server.crt"),
            "-days",
            "3650",
            "-extfile",
            &at(dir, "server.ext"),
        ]);
        if !ok {
            return false;
        }
        // Client leaf (CSR → CA-signed cert with clientAuth) for the mTLS path.
        openssl(&[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &at(dir, "client.key"),
            "-out",
            &at(dir, "client.csr"),
            "-subj",
            "/CN=knomosis-client",
        ]) && openssl(&[
            "x509",
            "-req",
            "-in",
            &at(dir, "client.csr"),
            "-CA",
            &at(dir, "ca.crt"),
            "-CAkey",
            &at(dir, "ca.key"),
            "-CAcreateserial",
            "-out",
            &at(dir, "client.crt"),
            "-days",
            "3650",
            "-extfile",
            &at(dir, "client.ext"),
        ])
    }

    /// Build a minimal authenticated `AppState` (a token file, no indexer / host
    /// / events — so reads/submit/SSE answer their disabled statuses, which is
    /// exactly what the TLS-path assertions check).
    fn make_state(dir: &Path) -> Arc<AppState> {
        let token_path = dir.join("tokens");
        std::fs::write(&token_path, TOKEN).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let config = Config {
            listen: "127.0.0.1:0".parse().unwrap(),
            max_connections: 64,
            indexer_db: None,
            free_tier: 0,
            action_cost: 0,
            epoch_length: 0,
            gas_pool_actor: None,
            deployment_id: "knx-tls".to_string(),
            ok_admission_stage: AdmissionStage::Finalized,
            host_addr: None,
            event_subscribe_addr: None,
            auth_token_file: Some(token_path),
            rate_limit_rps: 0,
            host_pool_size: 8,
            host_max_inflight: 8,
            request_deadline_ms: 5000,
            max_frame_size: 1024 * 1024,
            idempotency_ttl_secs: 0,
            cors_origin: None,
            log_format: crate::config::LogFormat::Json,
            dev: false,
            upstream_subscriptions: 1,
            sse: SseConfig::default(),
            tls: None,
        };
        Arc::new(AppState::new(config).expect("build AppState"))
    }

    /// A running TLS test listener; dropping it stops the accept loop.
    struct TlsServer {
        addr: SocketAddr,
        shutdown: Arc<AtomicBool>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for TlsServer {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::SeqCst);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    /// Bind an ephemeral TLS listener serving `state` with `tls` config, and run
    /// the real `accept_loop` on its own thread.  Returns the running server
    /// **and** the hot-swappable [`SharedConfig`] so a test can rotate the
    /// certificate via [`reload_server_config`].
    fn serve(tls: &TlsConfig, state: &Arc<AppState>) -> (TlsServer, SharedConfig) {
        let shared: SharedConfig = Arc::new(Mutex::new(
            build_server_config(tls).expect("build rustls server config"),
        ));
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let reload = Arc::new(AtomicBool::new(false));
        let (cfg, state, sd, tls_owned) = (
            Arc::clone(&shared),
            Arc::clone(state),
            Arc::clone(&shutdown),
            tls.clone(),
        );
        let handle = std::thread::spawn(move || {
            accept_loop(&listener, &cfg, &reload, &tls_owned, &state, &sd);
        });
        (
            TlsServer {
                addr,
                shutdown,
                handle: Some(handle),
            },
            shared,
        )
    }

    /// Load a PEM file into a fresh `RootCertStore`.
    fn roots(path: &Path) -> rustls::RootCertStore {
        let mut store = rustls::RootCertStore::empty();
        for cert in knomosis_host::tls::load_certs(path).expect("load CA") {
            store.add(cert).expect("add CA");
        }
        store
    }

    /// Connect a `rustls 0.23` client (trusting `ca`, optionally presenting a
    /// client certificate for mTLS), send `request`, and return the raw HTTP
    /// response bytes.  A handshake failure (e.g. mTLS with no client cert)
    /// surfaces as `Err`.
    fn request(
        addr: SocketAddr,
        ca: &Path,
        client_auth: Option<(&Path, &Path)>,
        req: &[u8],
    ) -> std::io::Result<Vec<u8>> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let builder = rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_root_certificates(roots(ca));
        let config = match client_auth {
            None => builder.with_no_client_auth(),
            Some((cert, key)) => builder
                .with_client_auth_cert(
                    knomosis_host::tls::load_certs(cert).unwrap(),
                    knomosis_host::tls::load_private_key(key).unwrap(),
                )
                .unwrap(),
        };
        let name = rustls::pki_types::ServerName::try_from("127.0.0.1").unwrap();
        let conn = rustls::ClientConnection::new(Arc::new(config), name)
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        let sock = TcpStream::connect(addr)?;
        sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
        sock.set_write_timeout(Some(Duration::from_secs(5))).ok();
        let mut tls = rustls::StreamOwned::new(conn, sock);
        // The handshake completes on first write; an mTLS rejection errors here.
        tls.write_all(req)?;
        tls.flush()?;
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            match tls.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                // A clean response followed by an unclean close (the server
                // drops without close_notify) ends the read; an error *before*
                // any byte is a real failure (propagate it).
                Err(e) => {
                    if buf.is_empty() {
                        return Err(e);
                    }
                    break;
                }
            }
        }
        Ok(buf)
    }

    fn text(bytes: &std::io::Result<Vec<u8>>) -> String {
        String::from_utf8_lossy(bytes.as_ref().expect("response")).into_owned()
    }

    /// A server-auth-only `TlsConfig` over the generated `dir` PKI.
    fn server_tls(dir: &Path) -> TlsConfig {
        TlsConfig {
            listen: "127.0.0.1:0".parse().unwrap(),
            cert: PathBuf::from(at(dir, "server.crt")),
            key: PathBuf::from(at(dir, "server.key")),
            client_ca: None,
            mtls_crl: None,
            max_connections: 64,
        }
    }

    /// The native-TLS **request/auth** surface end-to-end over a real
    /// handshake: the shared gate → route → dispatch core answers correctly
    /// over `rustls` — `/healthz` `200`, an authed `/v1/info` `200`, an
    /// unauthed `401`, and a strict-framing bad-version `505`.
    #[test]
    fn native_tls_server_auth_surface() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!("skipping native_tls_server_auth_surface: openssl unavailable");
            return;
        }
        let state = make_state(dir.path());
        let (server, _shared) = serve(&server_tls(dir.path()), &state);
        let ca = dir.path().join("ca.crt");
        let authed = format!("Authorization: Bearer {TOKEN}\r\n");

        // /healthz is exempt → 200 over TLS.
        let health = request(
            server.addr,
            &ca,
            None,
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            text(&health).starts_with("HTTP/1.1 200 OK"),
            "{}",
            text(&health)
        );
        assert!(text(&health).trim_end().ends_with("ok"));

        // /v1/info with the bearer token → 200 JSON over TLS (full gate→dispatch).
        let info = request(
            server.addr,
            &ca,
            None,
            format!("GET /v1/info HTTP/1.1\r\nHost: x\r\n{authed}Connection: close\r\n\r\n")
                .as_bytes(),
        );
        assert!(text(&info).contains("HTTP/1.1 200 OK"));
        assert!(text(&info).contains("\"submitProtocolVersion\""));

        // /v1/info with NO credential → fail-closed 401 over TLS.
        let unauth = request(
            server.addr,
            &ca,
            None,
            b"GET /v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(text(&unauth).contains("HTTP/1.1 401"));
        assert!(text(&unauth).contains("WWW-Authenticate: Bearer"));

        // A bad HTTP version is a strict-framing reject (505) — the connection
        // closes without desync.
        let bad = request(server.addr, &ca, None, b"GET / HTTP/2.0\r\nHost: x\r\n\r\n");
        assert!(text(&bad).contains("HTTP/1.1 505"));
        drop(server);
    }

    /// The native-TLS **body + streaming** surface end-to-end over a real
    /// handshake: a framed POST body, `Expect: 100-continue`, the SSE `503`,
    /// and keep-alive — including a body-framed pipelined pair (the
    /// smuggling-resistance crux).
    #[test]
    fn native_tls_body_and_stream_surface() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!("skipping native_tls_body_and_stream_surface: openssl unavailable");
            return;
        }
        let state = make_state(dir.path());
        let (server, _shared) = serve(&server_tls(dir.path()), &state);
        let ca = dir.path().join("ca.crt");
        let authed = format!("Authorization: Bearer {TOKEN}\r\n");

        // A POST body is read off the wire (exact framing); submit is disabled
        // (no --host-addr) → 503 over TLS.
        let submit = request(
            server.addr,
            &ca,
            None,
            format!(
                "POST /v1/actions HTTP/1.1\r\nHost: x\r\n{authed}\
                 Content-Type: application/octet-stream\r\nContent-Length: 4\r\n\
                 Connection: close\r\n\r\nbody"
            )
            .as_bytes(),
        );
        assert!(text(&submit).contains("HTTP/1.1 503"));

        // `Expect: 100-continue` (RFC 7231 §5.1.1): the server emits the interim
        // `100 Continue` BEFORE the final response.
        let expect = request(
            server.addr,
            &ca,
            None,
            format!(
                "POST /v1/actions HTTP/1.1\r\nHost: x\r\n{authed}\
                 Expect: 100-continue\r\nContent-Type: application/octet-stream\r\n\
                 Content-Length: 4\r\nConnection: close\r\n\r\nbody"
            )
            .as_bytes(),
        );
        let et = text(&expect);
        let cont_at = et
            .find("HTTP/1.1 100 Continue")
            .expect("an interim 100 Continue");
        let final_at = et.find("HTTP/1.1 503").expect("the final 503");
        assert!(
            cont_at < final_at,
            "100 Continue precedes the final response:\n{et}"
        );

        // An SSE stream with no fan-out configured → 503 events-unavailable.
        let stream = request(
            server.addr,
            &ca,
            None,
            format!(
                "GET /v1/events/stream HTTP/1.1\r\nHost: x\r\n{authed}Connection: close\r\n\r\n"
            )
            .as_bytes(),
        );
        assert!(text(&stream).contains("HTTP/1.1 503"));
        assert!(text(&stream).contains("events-unavailable"));

        // Keep-alive: two pipelined requests on ONE connection (the first
        // without `Connection: close`) → two framed 200s, exact framing.
        let pipelined = request(
            server.addr,
            &ca,
            None,
            b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n\
              GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert_eq!(
            text(&pipelined).matches("HTTP/1.1 200 OK").count(),
            2,
            "keep-alive served both pipelined requests"
        );

        // Keep-alive WITH a body: a POST whose exact Content-Length body is
        // consumed, then a GET on the SAME connection — the smuggling-resistance
        // crux (a single-byte under/over-read would desync the GET).
        let body_pipelined = request(
            server.addr,
            &ca,
            None,
            format!(
                "POST /v1/actions HTTP/1.1\r\nHost: x\r\n{authed}\
                 Content-Type: application/octet-stream\r\nContent-Length: 4\r\n\r\nbody\
                 GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
            )
            .as_bytes(),
        );
        let bt = text(&body_pipelined);
        let submit_at = bt.find("HTTP/1.1 503").expect("submit 503 after the body");
        let health_at = bt
            .find("HTTP/1.1 200 OK")
            .expect("health 200 after the body");
        assert!(
            submit_at < health_at,
            "the body was consumed exactly: submit 503 then health 200:\n{bt}"
        );
        drop(server);
    }

    /// mTLS enforcement over a real handshake: a client with no certificate is
    /// rejected at the handshake, and a CA-signed client certificate is
    /// accepted.
    #[test]
    fn native_tls_mutual_auth_enforced() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!("skipping native_tls_mutual_auth_enforced: openssl unavailable");
            return;
        }
        let state = make_state(dir.path());
        let mtls = TlsConfig {
            client_ca: Some(PathBuf::from(at(dir.path(), "ca.crt"))),
            ..server_tls(dir.path())
        };
        let (server, _shared) = serve(&mtls, &state);
        let ca = dir.path().join("ca.crt");

        // No client certificate → the handshake is rejected (Err, no response).
        let rejected = request(
            server.addr,
            &ca,
            None,
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            rejected.is_err(),
            "mTLS must reject a client with no certificate"
        );

        // The CA-signed client certificate → the handshake completes, 200.
        let client_crt = dir.path().join("client.crt");
        let client_key = dir.path().join("client.key");
        let accepted = request(
            server.addr,
            &ca,
            Some((&client_crt, &client_key)),
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            text(&accepted).starts_with("HTTP/1.1 200 OK"),
            "mTLS must accept a CA-signed client certificate: {}",
            text(&accepted)
        );
        drop(server);
    }

    /// mTLS **revocation**: a client whose (otherwise valid, CA-signed)
    /// certificate appears on the configured CRL is rejected.
    #[test]
    fn native_tls_revoked_client_cert_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!("skipping native_tls_revoked_client_cert_is_rejected: openssl unavailable");
            return;
        }
        // Revoke the client cert + generate a CRL (openssl `ca` needs a config +
        // a database; use the simpler `-gencrl` flow via a minimal CA setup).
        let crl_ok = make_crl_revoking_client(dir.path());
        if !crl_ok {
            eprintln!("skipping native_tls_revoked_client_cert_is_rejected: CRL generation failed");
            return;
        }
        let state = make_state(dir.path());
        let mtls = TlsConfig {
            client_ca: Some(PathBuf::from(at(dir.path(), "ca.crt"))),
            mtls_crl: Some(PathBuf::from(at(dir.path(), "crl.pem"))),
            ..server_tls(dir.path())
        };
        let (server, _shared) = serve(&mtls, &state);
        let ca = dir.path().join("ca.crt");
        let client_crt = dir.path().join("client.crt");
        let client_key = dir.path().join("client.key");

        // The revoked client certificate → the handshake is rejected.
        let rejected = request(
            server.addr,
            &ca,
            Some((&client_crt, &client_key)),
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            rejected.is_err(),
            "mTLS must reject a revoked client certificate"
        );
        drop(server);
    }

    /// Revoke `client.crt` against the CA and write `crl.pem`.  Uses an
    /// openssl CA database (`index.txt` / `serial`) + `ca -gencrl`.  Returns
    /// `false` if any step fails (the caller skips).
    fn make_crl_revoking_client(dir: &Path) -> bool {
        // Minimal openssl CA config.  `crlnumber` + a `crl_extensions` section
        // carrying the Authority Key Identifier make `ca -gencrl` emit a
        // **conforming v2 CRL** (CRL number + AKI), which webpki requires.
        std::fs::write(
            dir.join("ca.cnf"),
            format!(
                "[ca]\ndefault_ca = CA_default\n\
                 [CA_default]\n\
                 dir = {d}\n\
                 database = {d}/index.txt\n\
                 serial = {d}/serial\n\
                 crlnumber = {d}/crlnumber\n\
                 certificate = {d}/ca.crt\n\
                 private_key = {d}/ca.key\n\
                 default_md = sha256\n\
                 default_crl_days = 30\n\
                 crl_extensions = crl_ext\n\
                 policy = pol\n\
                 [pol]\n\
                 commonName = supplied\n\
                 [crl_ext]\n\
                 authorityKeyIdentifier = keyid:always\n",
                d = dir.to_string_lossy()
            ),
        )
        .unwrap();
        std::fs::write(dir.join("index.txt"), "").unwrap();
        std::fs::write(dir.join("serial"), "01\n").unwrap();
        std::fs::write(dir.join("crlnumber"), "1000\n").unwrap();
        openssl(&[
            "ca",
            "-config",
            &at(dir, "ca.cnf"),
            "-revoke",
            &at(dir, "client.crt"),
            "-keyfile",
            &at(dir, "ca.key"),
            "-cert",
            &at(dir, "ca.crt"),
        ]) && openssl(&[
            "ca",
            "-config",
            &at(dir, "ca.cnf"),
            "-gencrl",
            "-out",
            &at(dir, "crl.pem"),
            "-keyfile",
            &at(dir, "ca.key"),
            "-cert",
            &at(dir, "ca.crt"),
        ])
    }

    /// The hot-reload mechanism in isolation: a successful reload swaps in a
    /// new `Arc<ServerConfig>` (pointer changes), and a failing reload (a bad
    /// path) keeps the current one — so a fat-fingered rotation never breaks
    /// serving.
    #[test]
    fn cert_reload_swaps_on_success_keeps_on_failure() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!(
                "skipping cert_reload_swaps_on_success_keeps_on_failure: openssl unavailable"
            );
            return;
        }
        let tls = server_tls(dir.path());
        let initial = build_server_config(&tls).expect("initial config");
        let shared: SharedConfig = Arc::new(Mutex::new(Arc::clone(&initial)));

        reload_server_config(&shared, &tls);
        let after_ok = shared.lock().unwrap().clone();
        assert!(
            !Arc::ptr_eq(&initial, &after_ok),
            "a successful reload swaps in a new config"
        );

        let bad = TlsConfig {
            cert: dir.path().join("does-not-exist.crt"),
            ..tls
        };
        reload_server_config(&shared, &bad);
        let after_err = shared.lock().unwrap().clone();
        assert!(
            Arc::ptr_eq(&after_ok, &after_err),
            "a failed reload keeps the current config (serving never breaks)"
        );
    }

    /// End-to-end zero-downtime rotation: a live listener serving cert A is
    /// hot-reloaded to a cert from a *different* CA (B); a new connection then
    /// presents B (a CA-B client succeeds) and the old CA-A no longer validates.
    #[test]
    fn cert_hot_reload_serves_the_new_certificate() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        if !gen_pki(dir_a.path()) || !gen_pki(dir_b.path()) {
            eprintln!("skipping cert_hot_reload_serves_the_new_certificate: openssl unavailable");
            return;
        }
        let state = make_state(dir_a.path());
        let (server, shared) = serve(&server_tls(dir_a.path()), &state);
        let ca_a = dir_a.path().join("ca.crt");
        let ca_b = dir_b.path().join("ca.crt");
        let health = b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";

        assert!(text(&request(server.addr, &ca_a, None, health)).starts_with("HTTP/1.1 200 OK"));
        reload_server_config(&shared, &server_tls(dir_b.path()));
        let rb = request(server.addr, &ca_b, None, health);
        assert!(
            text(&rb).starts_with("HTTP/1.1 200 OK"),
            "the reloaded cert B is served: {}",
            text(&rb)
        );
        assert!(
            request(server.addr, &ca_a, None, health).is_err(),
            "after the hot-reload, a CA-A-only client must fail to validate cert B"
        );
        drop(server);
    }
}
