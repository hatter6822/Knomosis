// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Bridge-actor key management.
//!
//! ## Discipline
//!
//!   * The bridge-actor's secp256k1 private key is held behind
//!     [`zeroize::Zeroizing`] so it scrubs the underlying memory
//!     on drop.  The constructor takes a `[u8; 32]` and the
//!     internal [`BridgeActorKey`] wraps a `Zeroizing<[u8; 32]>`.
//!   * Public accessors return *signatures* and the *public
//!     key*, never the raw private bytes.
//!   * The keystore file format is the simplest possible:
//!     32-byte raw private key in a file owned by the operator.
//!     Production deployments should layer their own KMS /
//!     encrypted-keystore on top — the API takes a constructor
//!     that accepts raw bytes, so wrapping is straightforward.
//!
//! ## What this is **not**
//!
//!   * Not a key generator.  Operators generate keys via their
//!     own KMS / `geth account new` and hand the resulting
//!     32-byte secp256k1 private key to the ingestor.
//!   * Not a password decryption layer.  The plan §RH-B.1 lists
//!     `--keystore-password-file` as a CLI flag; that flag plumbs
//!     to an operator-side wrapper that decrypts an EIP-2335-
//!     style keystore.  This crate accepts the decrypted 32-byte
//!     scalar.
//!
//! ## Signing
//!
//! `BridgeActorKey::sign` takes a *pre-hashed* 32-byte message
//! (the keccak256 of the signing-input bytes) and produces a
//! 64-byte `(r || s)` low-s ECDSA signature.  The output format
//! matches `knomosis-verify-secp256k1`'s expected input.

use k256::ecdsa::signature::hazmat::PrehashSigner;
use k256::ecdsa::{Signature, SigningKey, VerifyingKey};
use sha3::{Digest, Keccak256};
use zeroize::Zeroizing;

/// Length of a secp256k1 private key, in bytes.
pub const PRIVATE_KEY_LEN: usize = 32;

/// Length of a SEC1-compressed secp256k1 public key, in bytes.
pub const COMPRESSED_PUBKEY_LEN: usize = 33;

/// Length of an Ethereum-style raw `(r || s)` ECDSA signature.
pub const SIGNATURE_LEN: usize = 64;

/// Length of a pre-hashed message (always 32 bytes).
pub const PREHASH_LEN: usize = 32;

/// Defensive bound on the keystore file size accepted by
/// [`BridgeActorKey::from_file`].  A legitimate raw-scalar
/// keystore is exactly [`PRIVATE_KEY_LEN`] = 32 bytes.  Anything
/// larger than this threshold is a misconfigured path (e.g.
/// operator pointed at a PEM, a JSON keystore, or `/dev/zero`)
/// and we fail loudly rather than silently consuming the first
/// 32 bytes (which would likely be header bytes of a structured
/// format and either produce an `InvalidScalar` error or — worse
/// — a valid-looking-but-wrong key).  4 KiB is generous: even
/// EIP-2335 keystores are ≤ 1 KiB.
pub const MAX_KEYSTORE_FILE_BYTES: usize = 4096;

/// The bridge-actor's secp256k1 keypair.  The private bytes live
/// behind `Zeroizing<[u8; 32]>` so they are erased on drop.
///
/// ## Construction
///
/// The constructor takes a 32-byte scalar.  It does **not**
/// validate that the scalar is in the curve order; `k256`'s
/// `SigningKey::from_bytes` performs the check and the
/// constructor surfaces the resulting error to the caller.
///
/// ## Why hold the raw bytes
///
/// `k256::ecdsa::SigningKey` does not implement `Zeroize` by
/// default at the byte-buffer level — its internal representation
/// is a `Scalar` whose memory layout is `k256`'s concern.  By
/// keeping the raw 32-byte buffer here (zeroized on drop) and
/// re-deriving the `SigningKey` on each sign call, we keep the
/// secret material's memory under our explicit control.
///
/// The re-derivation cost is negligible (one scalar
/// canonicalisation per sign).
pub struct BridgeActorKey {
    /// The raw 32-byte private scalar, scrubbed on drop.
    private_bytes: Zeroizing<[u8; PRIVATE_KEY_LEN]>,
    /// The corresponding SEC1-compressed public key.  Cached so
    /// callers don't pay re-derivation on every accessor.  The
    /// public key is *not* secret; no zeroization required.
    public_key: [u8; COMPRESSED_PUBKEY_LEN],
}

impl core::fmt::Debug for BridgeActorKey {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        // Do NOT include the private key in Debug output, even
        // by accident.
        f.debug_struct("BridgeActorKey")
            .field("public_key", &"<redacted>")
            .field("private_bytes", &"<redacted>")
            .finish()
    }
}

/// Errors surfaced by [`BridgeActorKey`] construction / signing.
#[derive(Debug, thiserror::Error)]
pub enum KeyError {
    /// The supplied bytes had the wrong length (expected 32).
    #[error("invalid private-key length {got}, expected {expected}")]
    InvalidLength {
        /// What was provided.
        got: usize,
        /// What was expected.
        expected: usize,
    },
    /// The supplied bytes did not represent a valid secp256k1
    /// scalar (zero or `≥ curve order`).
    #[error("invalid secp256k1 scalar (zero or out of range)")]
    InvalidScalar,
    /// A keystore file at the indicated path could not be read.
    #[error("keystore I/O error at {path}: {source}")]
    Io {
        /// The path that failed.
        path: String,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
}

impl BridgeActorKey {
    /// Construct from a 32-byte private scalar.  Returns
    /// `KeyError::InvalidScalar` if the bytes don't represent a
    /// valid secp256k1 scalar.
    ///
    /// # Errors
    ///
    /// See [`KeyError`].
    pub fn from_private_bytes(bytes: &[u8]) -> Result<Self, KeyError> {
        if bytes.len() != PRIVATE_KEY_LEN {
            return Err(KeyError::InvalidLength {
                got: bytes.len(),
                expected: PRIVATE_KEY_LEN,
            });
        }
        let mut buf = [0u8; PRIVATE_KEY_LEN];
        buf.copy_from_slice(bytes);
        // Validate by attempting to construct a SigningKey.  `k256`
        // expects `&FieldBytes`, which is `&GenericArray<u8, U32>`;
        // we use the `From<&[u8; 32]>` adapter via slice coercion.
        let signing_key = SigningKey::from_slice(&buf).map_err(|_| KeyError::InvalidScalar)?;
        // Cache the SEC1-compressed public key.
        let verifying = VerifyingKey::from(&signing_key);
        let pk_bytes = verifying.to_encoded_point(true);
        if pk_bytes.as_bytes().len() != COMPRESSED_PUBKEY_LEN {
            // k256 invariant — would only fire if k256 changed
            // the compressed encoding length.
            return Err(KeyError::InvalidScalar);
        }
        let mut public_key = [0u8; COMPRESSED_PUBKEY_LEN];
        public_key.copy_from_slice(pk_bytes.as_bytes());
        Ok(Self {
            private_bytes: Zeroizing::new(buf),
            public_key,
        })
    }

    /// Load the private key from a file path.  The file's first
    /// 32 bytes are interpreted as the raw scalar (no PEM, no
    /// JSON).  This is the simplest possible storage format; the
    /// CLI layer may wrap it with EIP-2335 decryption / KMS
    /// integration.
    ///
    /// Reads at most [`PRIVATE_KEY_LEN`] bytes — does NOT load
    /// the entire file into memory.  This bounds the memory
    /// allocation regardless of the file's actual size (e.g. a
    /// misconfigured operator pointing at `/dev/zero` or a
    /// large arbitrary file would otherwise exhaust memory).
    ///
    /// # Errors
    ///
    /// Returns `KeyError::Io` if the file cannot be opened or
    /// read, `KeyError::InvalidLength` if the file is too short,
    /// and `KeyError::InvalidScalar` if the scalar is invalid.
    pub fn from_file(path: &std::path::Path) -> Result<Self, KeyError> {
        use std::io::Read;
        let mut file = std::fs::File::open(path).map_err(|source| KeyError::Io {
            path: path.display().to_string(),
            source,
        })?;
        // Read exactly PRIVATE_KEY_LEN bytes.  `read_exact`
        // returns `UnexpectedEof` if the file is shorter than
        // 32 bytes, which we map to `InvalidLength`.
        let mut bytes = [0u8; PRIVATE_KEY_LEN];
        match file.read_exact(&mut bytes) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                // Determine actual file length for the error.
                let actual = std::fs::metadata(path)
                    .map(|m| m.len() as usize)
                    .unwrap_or(0);
                return Err(KeyError::InvalidLength {
                    got: actual,
                    expected: PRIVATE_KEY_LEN,
                });
            }
            Err(source) => {
                return Err(KeyError::Io {
                    path: path.display().to_string(),
                    source,
                });
            }
        }
        // Sanity bound: refuse to load if file is unreasonably
        // large.  A legitimate raw-scalar keystore is exactly
        // 32 bytes.  Larger files indicate the operator pointed
        // at the wrong file (e.g. a PEM, a database, etc.) and
        // should fail loudly rather than silently consuming
        // only the first 32 bytes (which would likely be header
        // bytes from a structured format and produce an invalid
        // scalar).
        if let Ok(meta) = std::fs::metadata(path) {
            if meta.len() > MAX_KEYSTORE_FILE_BYTES as u64 {
                return Err(KeyError::InvalidLength {
                    got: meta.len() as usize,
                    expected: PRIVATE_KEY_LEN,
                });
            }
        }
        Self::from_private_bytes(&bytes)
    }

    /// Return the SEC1-compressed public key bytes (33 bytes).
    #[must_use]
    pub fn public_key_compressed(&self) -> [u8; COMPRESSED_PUBKEY_LEN] {
        self.public_key
    }

    /// Sign a *pre-hashed* 32-byte message and return a 64-byte
    /// `(r || s)` low-s signature.  The pre-hashing is the
    /// caller's responsibility — typically `keccak256(signing_input(...))`.
    ///
    /// Low-s canonicalisation matches the cross-stack contract
    /// with `knomosis-verify-secp256k1` (RH-A.1): signatures with
    /// `s > n/2` are rejected by the verifier, so this signer
    /// emits the low-s form to begin with.  `k256`'s `sign_prehash`
    /// produces low-s by default since v0.13.
    ///
    /// # Errors
    ///
    /// Returns `KeyError::InvalidLength` if `prehash.len() != 32`.
    /// Returns `KeyError::InvalidScalar` only if the cached
    /// private bytes have been corrupted in memory — this is a
    /// programming error rather than an attacker-controllable
    /// failure mode.
    pub fn sign_prehash(&self, prehash: &[u8]) -> Result<[u8; SIGNATURE_LEN], KeyError> {
        if prehash.len() != PREHASH_LEN {
            return Err(KeyError::InvalidLength {
                got: prehash.len(),
                expected: PREHASH_LEN,
            });
        }
        let signing_key = SigningKey::from_slice(self.private_bytes.as_ref())
            .map_err(|_| KeyError::InvalidScalar)?;
        // `k256` >= 0.13 normalises to low-s in sign_prehash by
        // default — see the docs at `k256::ecdsa::signature::
        // hazmat::PrehashSigner`.  We rely on this contract.
        let sig: Signature = signing_key
            .sign_prehash(prehash)
            .map_err(|_| KeyError::InvalidScalar)?;
        // Belt-and-suspenders: explicitly normalise to low-s.
        // `k256::ecdsa::Signature::normalize_s` returns `Some`
        // iff the input was high-s; we always normalise to
        // ensure determinism even on `k256` revs that drop the
        // sign-time normalisation.
        let normalised = sig.normalize_s().unwrap_or(sig);
        let bytes = normalised.to_bytes();
        if bytes.len() != SIGNATURE_LEN {
            return Err(KeyError::InvalidScalar);
        }
        let mut out = [0u8; SIGNATURE_LEN];
        out.copy_from_slice(&bytes);
        Ok(out)
    }

    /// Convenience wrapper that pre-hashes `message` with
    /// keccak256 then signs.
    ///
    /// # Errors
    ///
    /// Inherits the failure modes of [`Self::sign_prehash`];
    /// `KeyError::InvalidLength` is unreachable here (keccak256
    /// always emits 32 bytes).
    pub fn sign_keccak256(&self, message: &[u8]) -> Result<[u8; SIGNATURE_LEN], KeyError> {
        let mut hasher = Keccak256::new();
        hasher.update(message);
        let digest = hasher.finalize();
        // `digest` is always 32 bytes; `sign_prehash` returns
        // success unconditionally on a valid key.
        self.sign_prehash(&digest)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BridgeActorKey, KeyError, COMPRESSED_PUBKEY_LEN, PREHASH_LEN, PRIVATE_KEY_LEN,
        SIGNATURE_LEN,
    };

    /// Constants are stable.
    #[test]
    fn constants_stable() {
        assert_eq!(PRIVATE_KEY_LEN, 32);
        assert_eq!(COMPRESSED_PUBKEY_LEN, 33);
        assert_eq!(SIGNATURE_LEN, 64);
        assert_eq!(PREHASH_LEN, 32);
    }

    /// A specific known-good 32-byte scalar produces a valid
    /// BridgeActorKey with a 33-byte SEC1-compressed pubkey.
    #[test]
    fn from_bytes_known_good_scalar() {
        // The scalar 1 (a famously-known valid scalar).
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 1;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        let pk = key.public_key_compressed();
        assert_eq!(pk.len(), COMPRESSED_PUBKEY_LEN);
        // First byte is 0x02 or 0x03 (compressed format prefix).
        assert!(
            pk[0] == 0x02 || pk[0] == 0x03,
            "first byte {} must be 0x02 or 0x03",
            pk[0]
        );
    }

    /// From bytes rejects wrong-length input.
    #[test]
    fn from_bytes_rejects_wrong_length() {
        let too_short = [0u8; 31];
        let too_long = [0u8; 33];
        assert!(matches!(
            BridgeActorKey::from_private_bytes(&too_short),
            Err(KeyError::InvalidLength {
                got: 31,
                expected: 32
            })
        ));
        assert!(matches!(
            BridgeActorKey::from_private_bytes(&too_long),
            Err(KeyError::InvalidLength {
                got: 33,
                expected: 32
            })
        ));
    }

    /// From bytes rejects the zero scalar.
    #[test]
    fn from_bytes_rejects_zero_scalar() {
        let zero = [0u8; PRIVATE_KEY_LEN];
        assert!(matches!(
            BridgeActorKey::from_private_bytes(&zero),
            Err(KeyError::InvalidScalar)
        ));
    }

    /// `sign_prehash` produces a 64-byte signature.
    #[test]
    fn sign_prehash_length() {
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 7;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        let sig = key.sign_prehash(&[0u8; 32]).unwrap();
        assert_eq!(sig.len(), SIGNATURE_LEN);
    }

    /// `sign_prehash` rejects wrong-length prehash.
    #[test]
    fn sign_prehash_rejects_wrong_length() {
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 7;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        assert!(matches!(
            key.sign_prehash(&[0u8; 31]),
            Err(KeyError::InvalidLength {
                got: 31,
                expected: 32
            })
        ));
        assert!(matches!(
            key.sign_prehash(&[0u8; 33]),
            Err(KeyError::InvalidLength {
                got: 33,
                expected: 32
            })
        ));
    }

    /// `sign_prehash` produces the same signature for the same
    /// `(key, prehash)` — k256's RFC-6979 deterministic ECDSA.
    #[test]
    fn sign_prehash_deterministic() {
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 7;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        let prehash = [0x42u8; 32];
        let sig1 = key.sign_prehash(&prehash).unwrap();
        let sig2 = key.sign_prehash(&prehash).unwrap();
        assert_eq!(sig1, sig2);
    }

    /// `sign_prehash` always emits low-s signatures — `s ≤ n/2`.
    /// We verify by parsing the lower 32 bytes of the signature
    /// as a big-endian integer and asserting it is less than
    /// `n/2`.  The half-order constant comes from the secp256k1
    /// spec: `n/2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`.
    #[test]
    fn sign_prehash_emits_low_s() {
        // The secp256k1 half-order constant.
        const HALF_ORDER: [u8; 32] = [
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D, 0xDF, 0xE9, 0x2F, 0x46,
            0x68, 0x1B, 0x20, 0xA0,
        ];
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 13;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        for nonce in 0..16u8 {
            let mut prehash = [0u8; 32];
            prehash[31] = nonce;
            let sig = key.sign_prehash(&prehash).unwrap();
            // s is the second 32 bytes; compare BE-lex to HALF_ORDER.
            let s = &sig[32..64];
            // `s <= HALF_ORDER` is the low-s contract.
            let is_low_s = s <= &HALF_ORDER[..];
            assert!(is_low_s, "signature {} is not low-s", hex::encode(sig));
        }
    }

    /// `sign_keccak256` produces a deterministic signature for a
    /// given message.
    #[test]
    fn sign_keccak256_deterministic() {
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 99;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        let msg = b"hello world";
        let s1 = key.sign_keccak256(msg).unwrap();
        let s2 = key.sign_keccak256(msg).unwrap();
        assert_eq!(s1, s2);
    }

    /// Different messages produce different signatures.
    #[test]
    fn sign_keccak256_different_messages() {
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 99;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        let s1 = key.sign_keccak256(b"message 1").unwrap();
        let s2 = key.sign_keccak256(b"message 2").unwrap();
        assert_ne!(s1, s2);
    }

    /// Loading from a file round-trips via `from_private_bytes`.
    #[test]
    fn from_file_round_trip() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("key.bin");
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 42;
        std::fs::write(&path, scalar).unwrap();
        let key = BridgeActorKey::from_file(&path).unwrap();
        let direct = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        assert_eq!(key.public_key_compressed(), direct.public_key_compressed());
    }

    /// File too short returns `InvalidLength`.
    #[test]
    fn from_file_too_short() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("key.bin");
        std::fs::write(&path, [0u8; 16]).unwrap();
        assert!(matches!(
            BridgeActorKey::from_file(&path),
            Err(KeyError::InvalidLength {
                got: 16,
                expected: 32
            })
        ));
    }

    /// Non-existent file path returns `Io`.
    #[test]
    fn from_file_missing() {
        let result = BridgeActorKey::from_file(std::path::Path::new("/non/existent/path"));
        assert!(matches!(result, Err(KeyError::Io { .. })));
    }

    /// REGRESSION: `from_file` refuses to load keystores larger
    /// than `MAX_KEYSTORE_FILE_BYTES`.  Without this bound, an
    /// operator misconfiguration (pointing at a huge file like
    /// `/dev/zero` or a database) would either consume the
    /// first 32 bytes blindly or exhaust memory.
    #[test]
    fn from_file_rejects_oversized_file() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("oversize.bin");
        // Write 5 KiB (above the 4 KiB threshold).
        let oversize_bytes = vec![0x11u8; 5 * 1024];
        std::fs::write(&path, &oversize_bytes).unwrap();
        let result = BridgeActorKey::from_file(&path);
        match result {
            Err(KeyError::InvalidLength { got, expected }) => {
                assert_eq!(got, oversize_bytes.len());
                assert_eq!(expected, PRIVATE_KEY_LEN);
            }
            other => panic!("expected InvalidLength, got {other:?}"),
        }
    }

    /// `from_file` accepts a file with exactly `PRIVATE_KEY_LEN`
    /// bytes — the canonical raw-scalar format.
    #[test]
    fn from_file_accepts_exact_length() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ok.bin");
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 9;
        std::fs::write(&path, scalar).unwrap();
        let key = BridgeActorKey::from_file(&path).unwrap();
        assert!(matches!(key.public_key_compressed()[0], 0x02 | 0x03));
    }

    /// `from_file` accepts a file with more than 32 bytes but
    /// under the threshold, reading only the first 32 bytes.
    /// Documents the relaxed parsing semantic: extra bytes after
    /// the scalar are silently ignored.  (The threshold itself
    /// is the upper bound to prevent abuse.)
    #[test]
    fn from_file_accepts_under_threshold() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ok.bin");
        let mut data = vec![0u8; PRIVATE_KEY_LEN + 100];
        data[31] = 13; // valid scalar
        std::fs::write(&path, &data).unwrap();
        let key = BridgeActorKey::from_file(&path).unwrap();
        // Sanity: pubkey is from the first-32-bytes scalar.
        let direct = BridgeActorKey::from_private_bytes(&data[..PRIVATE_KEY_LEN]).unwrap();
        assert_eq!(key.public_key_compressed(), direct.public_key_compressed());
    }

    /// `Debug` impl does NOT expose private bytes.
    #[test]
    fn debug_redacts_secret() {
        let mut scalar = [0u8; PRIVATE_KEY_LEN];
        scalar[31] = 1;
        let key = BridgeActorKey::from_private_bytes(&scalar).unwrap();
        let dbg = format!("{key:?}");
        assert!(dbg.contains("<redacted>"));
        // Ensure no hex / ASCII of the private bytes appears.
        // The scalar's only non-zero byte is `0x01` at the end,
        // which is a common substring; instead we check that
        // multiple bytes of the scalar do not appear in sequence
        // by looking for a hex representation that would only
        // appear if the bytes were leaked.  A 30-byte chunk of
        // zeros could conceivably appear in debug formatting,
        // but the redaction text is what matters.
        assert!(!dbg.contains("\"01\""));
    }
}
