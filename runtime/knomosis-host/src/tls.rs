// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! TLS configuration loader for `knomosis-host`.
//!
//! Wraps `rustls` with the workspace's path / PEM conventions.
//! The host accepts a `--tls-cert <path>` + `--tls-key <path>`
//! pair on the CLI; this module turns those paths into a
//! `rustls::ServerConfig` ready for [`crate::listener`] to wrap a
//! `TcpStream` with.
//!
//! ## Backend choice
//!
//! `rustls` supports two cryptographic backends: `ring` and
//! `aws-lc-rs`.  We pin `ring` (the historic default) to avoid
//! pulling in `aws-lc-rs`'s build-time `cmake` + out-of-tree C
//! library dependencies.
//!
//! ## TLS version
//!
//! Default minimum TLS version is 1.3 (per the engineering plan
//! §RH-C.3 recommendation).  1.2 can be enabled by the operator
//! via [`TlsConfigBuilder::allow_tls12`] when interoperability
//! with older clients is required.

use std::fs::File;
use std::io::{self, BufReader};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rustls::{ServerConfig, SupportedProtocolVersion};
use rustls_pki_types::{CertificateDer, PrivateKeyDer};

/// Errors during TLS configuration loading.
#[derive(Debug, thiserror::Error)]
pub enum TlsConfigError {
    /// I/O error reading a certificate or key file.
    #[error("I/O error reading {path:?}: {source}")]
    Io {
        /// Path that the load attempt was issued against.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: io::Error,
    },
    /// The certificate file contained no PEM-encoded certificates.
    #[error("no certificates found in {0:?}")]
    NoCertificates(PathBuf),
    /// The key file contained no PEM-encoded private keys (looked
    /// for PKCS#8, RSA, and SEC1 keys).
    #[error("no private keys found in {0:?}")]
    NoPrivateKey(PathBuf),
    /// `rustls` rejected the supplied certificate + key pair.
    /// Common cause: the private key doesn't match the
    /// certificate's public key (operator wiring error).
    #[error("rustls rejected the certificate/key pair: {0}")]
    RustlsBuilderError(String),
    /// The cryptographic provider could not be installed (e.g.
    /// the process already installed a different provider).
    /// `rustls` requires a process-global crypto provider; if a
    /// downstream consumer of this crate has already installed
    /// `aws-lc-rs` (say), the `ring` install will be a no-op
    /// but the existing default is preserved.
    #[error("could not install crypto provider: {0}")]
    CryptoProviderInstall(String),
}

/// Builder for a `rustls::ServerConfig`.  Most operators use
/// [`TlsConfigBuilder::load_pem_files`] directly; the builder
/// surface exists for tests that want to inject pre-loaded
/// certificate / key buffers.
#[derive(Debug, Default)]
pub struct TlsConfigBuilder {
    allow_tls12: bool,
}

impl TlsConfigBuilder {
    /// Construct a default builder (TLS 1.3 only).
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Allow TLS 1.2 in addition to TLS 1.3.  Operators wanting
    /// interop with older clients call this; the default is 1.3
    /// only per the plan §RH-C.3.
    #[must_use]
    pub fn allow_tls12(mut self) -> Self {
        self.allow_tls12 = true;
        self
    }

    /// Load PEM-encoded certificate + private-key files and build
    /// a `rustls::ServerConfig`.
    ///
    /// `cert_path` may contain one or more certificates (the chain
    /// from leaf to root); `key_path` contains exactly one
    /// PKCS#8, RSA, or SEC1 private key.
    ///
    /// # Errors
    ///
    /// See [`TlsConfigError`].
    pub fn load_pem_files(
        self,
        cert_path: &Path,
        key_path: &Path,
    ) -> Result<Arc<ServerConfig>, TlsConfigError> {
        let certs = load_certs(cert_path)?;
        let key = load_private_key(key_path)?;
        self.build(certs, key)
    }

    /// Build a `rustls::ServerConfig` from pre-loaded
    /// certificate / key buffers.  Used by tests; production code
    /// goes through `load_pem_files`.
    ///
    /// # Errors
    ///
    /// See [`TlsConfigError`].
    pub fn build(
        self,
        certs: Vec<CertificateDer<'static>>,
        key: PrivateKeyDer<'static>,
    ) -> Result<Arc<ServerConfig>, TlsConfigError> {
        // Per-config crypto-provider pinning (audit-3 #4).
        // `builder_with_provider` takes the provider explicitly,
        // so the resulting `ServerConfig` always uses `ring`
        // regardless of any process-global default a downstream
        // consumer of this crate may have installed (e.g.
        // `aws-lc-rs` installed by a different test harness).  We
        // ALSO still call `install_default` (best-effort
        // idempotent) so callers that build a `rustls::ClientConfig`
        // via the global default path get the same provider; the
        // load-bearing pin for knomosis-host's server side is the
        // explicit `builder_with_provider` call below.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());

        // Pick the protocol versions.
        let versions: &[&SupportedProtocolVersion] = if self.allow_tls12 {
            rustls::DEFAULT_VERSIONS // 1.2 and 1.3
        } else {
            &[&rustls::version::TLS13]
        };

        let builder = ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(versions)
            .map_err(|e| TlsConfigError::RustlsBuilderError(e.to_string()))?;
        let server_config = builder
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .map_err(|e| TlsConfigError::RustlsBuilderError(e.to_string()))?;
        Ok(Arc::new(server_config))
    }
}

/// Load PEM-encoded certificates from a file.  Returns the
/// certificates in the order they appear in the file (leaf first,
/// per convention).
///
/// # Errors
///
/// Returns `TlsConfigError::Io` on filesystem error,
/// `TlsConfigError::NoCertificates` if the file is well-formed but
/// contains no `CERTIFICATE` blocks.
pub fn load_certs(path: &Path) -> Result<Vec<CertificateDer<'static>>, TlsConfigError> {
    let file = File::open(path).map_err(|source| TlsConfigError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let mut reader = BufReader::new(file);
    let mut certs: Vec<CertificateDer<'static>> = Vec::new();
    for cert_result in rustls_pemfile::certs(&mut reader) {
        let cert = cert_result.map_err(|source| TlsConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        certs.push(cert);
    }
    if certs.is_empty() {
        return Err(TlsConfigError::NoCertificates(path.to_path_buf()));
    }
    Ok(certs)
}

/// Load a single PEM-encoded private key from a file.  Tries
/// PKCS#8, RSA, and SEC1 formats in that order; returns the first
/// successfully parsed key.
///
/// # Errors
///
/// Returns `TlsConfigError::Io` on filesystem error,
/// `TlsConfigError::NoPrivateKey` if the file is well-formed but
/// contains no recognised key block.
pub fn load_private_key(path: &Path) -> Result<PrivateKeyDer<'static>, TlsConfigError> {
    let file = File::open(path).map_err(|source| TlsConfigError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let mut reader = BufReader::new(file);
    // `rustls_pemfile::private_key` tries every supported PEM key
    // type (PKCS#8, RSA, SEC1) and returns the first match.
    let key = rustls_pemfile::private_key(&mut reader)
        .map_err(|source| TlsConfigError::Io {
            path: path.to_path_buf(),
            source,
        })?
        .ok_or_else(|| TlsConfigError::NoPrivateKey(path.to_path_buf()))?;
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::{load_certs, load_private_key, TlsConfigBuilder, TlsConfigError};
    use std::io::Write;

    /// Default builder rejects TLS 1.2.
    #[test]
    fn default_builder_disallows_tls12() {
        let b = TlsConfigBuilder::new();
        assert!(!b.allow_tls12);
    }

    /// `allow_tls12()` flips the flag.
    #[test]
    fn allow_tls12_flips_flag() {
        let b = TlsConfigBuilder::new().allow_tls12();
        assert!(b.allow_tls12);
    }

    /// Missing cert file returns `Io`.
    #[test]
    fn missing_cert_file_returns_io() {
        let bogus = std::path::Path::new("/nonexistent/cert.pem");
        match load_certs(bogus) {
            Err(TlsConfigError::Io { path, .. }) => assert_eq!(path, bogus),
            other => panic!("expected Io, got {other:?}"),
        }
    }

    /// Missing key file returns `Io`.
    #[test]
    fn missing_key_file_returns_io() {
        let bogus = std::path::Path::new("/nonexistent/key.pem");
        match load_private_key(bogus) {
            Err(TlsConfigError::Io { path, .. }) => assert_eq!(path, bogus),
            other => panic!("expected Io, got {other:?}"),
        }
    }

    /// Empty cert file (no PEM blocks) returns `NoCertificates`.
    #[test]
    fn empty_cert_file_returns_no_certificates() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        match load_certs(temp.path()) {
            Err(TlsConfigError::NoCertificates(p)) => assert_eq!(p, temp.path()),
            other => panic!("expected NoCertificates, got {other:?}"),
        }
    }

    /// Empty key file (no PEM blocks) returns `NoPrivateKey`.
    #[test]
    fn empty_key_file_returns_no_private_key() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        match load_private_key(temp.path()) {
            Err(TlsConfigError::NoPrivateKey(p)) => assert_eq!(p, temp.path()),
            other => panic!("expected NoPrivateKey, got {other:?}"),
        }
    }

    /// `TlsConfigError` is `Send + Sync` (carried up via `?` from
    /// threaded loaders).
    #[test]
    fn tls_config_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<TlsConfigError>();
    }

    /// A garbage-only file with no PEM markers returns
    /// `NoCertificates` from `load_certs` (the parser is lenient
    /// about non-PEM content; it just finds no `CERTIFICATE`
    /// blocks).
    #[test]
    fn garbage_file_returns_no_certificates() {
        let mut temp = tempfile::NamedTempFile::new().unwrap();
        temp.write_all(b"this is not a PEM file\n").unwrap();
        temp.flush().unwrap();
        match load_certs(temp.path()) {
            Err(TlsConfigError::NoCertificates(_)) => {}
            other => panic!("expected NoCertificates, got {other:?}"),
        }
    }

    /// Same for `load_private_key` — garbage file returns
    /// `NoPrivateKey`.
    #[test]
    fn garbage_file_returns_no_private_key() {
        let mut temp = tempfile::NamedTempFile::new().unwrap();
        temp.write_all(b"this is not a PEM file\n").unwrap();
        temp.flush().unwrap();
        match load_private_key(temp.path()) {
            Err(TlsConfigError::NoPrivateKey(_)) => {}
            other => panic!("expected NoPrivateKey, got {other:?}"),
        }
    }
}
