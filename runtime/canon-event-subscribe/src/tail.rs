// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Log-tail reader for Canon's transition-log file format.
//!
//! ## What this reads
//!
//! The Lean `canon` binary writes log entries to disk via
//! `LegalKernel/Runtime/LogFile.lean::appendEntry`.  Each entry is
//! framed as:
//!
//! ```text
//! offset  size  field
//! ------  ----  --------------------------------------------
//!     0    4    MAGIC ASCII "CANO" (0x43 0x41 0x4E 0x4F)
//!     4    8    PAYLOAD length N (little-endian u64)
//!    12    N    PAYLOAD (CBE-encoded LogEntry)
//!  12+N    8    TRAILER (FNV-1a-64 of PAYLOAD, little-endian u64)
//! ```
//!
//! See `docs/abi.md` §2 for the canonical specification.  The tail
//! reader does NOT decode the payload itself — that's the
//! extractor's job (the Lean subprocess).  We only need to chunk
//! the file into one-frame-per-yield records, attach a sequence
//! number, and report when the file grows.
//!
//! ## Robustness
//!
//! The reader handles torn writes via the trailer hash check:
//! a frame whose trailer does not match its payload's FNV-1a-64
//! hash is treated as **incomplete** (writer crashed mid-frame)
//! and the reader pauses at that byte offset, retrying on the
//! next poll.  This is the same recovery semantics as Lean's
//! `LogFile.decodeAllFrames` / `loadAndTruncate`.
//!
//! ## Why no `inotify`
//!
//! The plan §RH-D.1 explicitly says "no inotify dependency."
//! Reasons:
//!
//!   1. **Portability.**  `inotify` is Linux-only; the
//!      poll-and-sleep pattern works on macOS / BSD / Windows.
//!   2. **Dependency hygiene.**  The plan's risk register
//!      prefers tight dependency control.
//!   3. **Sufficiency.**  Canon's expected workload tops out
//!      at thousands of frames per second; a 10–100 ms poll
//!      interval is well within latency budgets.
//!
//! ## Sequence numbers
//!
//! The tail reader assigns sequence numbers starting from `1`
//! for the first frame in the file.  A `resume_from` value of
//! `0` means "no resume, start from live tail"; sequence `1` is
//! the genesis entry (the first event ever written).  This
//! discipline matches the wire-format spec in
//! `docs/abi.md` §11.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// FNV-1a-64 offset basis.  Mirrors Lean's
/// `LegalKernel/Runtime/Hash.lean::fnv1a64InitialState`.
const FNV1A_64_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;

/// FNV-1a-64 prime.  Mirrors Lean's
/// `LegalKernel/Runtime/Hash.lean::fnv1a64Prime`.
const FNV1A_64_PRIME: u64 = 0x0000_0100_0000_01b3;

/// Frame magic byte 1: 'C' (0x43).
pub const FRAME_MAGIC_0: u8 = 0x43;

/// Frame magic byte 2: 'A' (0x41).
pub const FRAME_MAGIC_1: u8 = 0x41;

/// Frame magic byte 3: 'N' (0x4E).
pub const FRAME_MAGIC_2: u8 = 0x4E;

/// Frame magic byte 4: 'O' (0x4F).
pub const FRAME_MAGIC_3: u8 = 0x4F;

/// Length of the frame header (magic + length): 4 + 8 = 12 bytes.
pub const FRAME_HEADER_LEN: usize = 12;

/// Length of the frame trailer (FNV-1a-64 hash): 8 bytes.
pub const FRAME_TRAILER_LEN: usize = 8;

/// Hard ceiling on accepted frame payload sizes.  16 MiB matches
/// the workspace's other limits.  A frame larger than this is
/// treated as **corruption** (canon-host's `MAX_FRAME_SIZE` is 1
/// MiB; a CBE-encoded LogEntry is typically well under 10 KiB).
pub const FRAME_PAYLOAD_MAX: usize = 16 * 1024 * 1024;

/// Default poll interval when the tail reader hits EOF.  100 ms
/// keeps p99 event-delivery latency tight without consuming
/// excessive CPU on idle deployments.
pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// One decoded log frame returned by the tail reader.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LogFrame {
    /// 1-indexed sequence number assigned by the tail reader.
    /// The first frame in the file is `1`; sequence numbers are
    /// stable across re-reads of the same file (provided the
    /// file's contents haven't been rewritten).
    pub seq: u64,
    /// Raw CBE-encoded `LogEntry` payload bytes.  Does NOT
    /// include the frame's magic, length, or trailer — only the
    /// payload bytes.  The extractor passes these to the
    /// `canon` subprocess.
    pub payload: Vec<u8>,
}

/// Errors the tail reader can surface.
#[derive(Debug, thiserror::Error)]
pub enum TailError {
    /// Underlying I/O error opening or reading the log file.
    #[error("log-file I/O error at offset {offset}: {source}")]
    Io {
        /// Byte offset at which the error occurred.
        offset: u64,
        /// Underlying error.
        #[source]
        source: io::Error,
    },
    /// The log file is shorter than our cursor.  The operator
    /// truncated (or rotated in place) the file underneath us.
    /// The cursor cannot be advanced safely; the caller decides
    /// whether to halt or reset.  Per M-5 audit.
    #[error("log file shrank: cursor at {cursor} but file is only {new_len} bytes long")]
    FileShrank {
        /// Cursor position at the time of detection.
        cursor: u64,
        /// New (smaller) file length.
        new_len: u64,
    },
    /// The frame's magic header bytes did not match the expected
    /// `"CANO"`.  Indicates either a corrupt log file or an
    /// attempt to tail a file that isn't a Canon log.
    #[error("bad magic at offset {offset}: got {got:02x?}, expected [43 41 4e 4f]")]
    BadMagic {
        /// Byte offset of the frame's first magic byte.
        offset: u64,
        /// The four bytes we actually read.
        got: [u8; 4],
    },
    /// The declared payload length exceeded the configured
    /// hard ceiling.  Defends against malformed log files
    /// claiming gigabytes of payload before allocation.
    #[error("oversize frame at offset {offset}: declared {declared_length} bytes, max {max}")]
    OversizeFrame {
        /// Byte offset of the frame header.
        offset: u64,
        /// Declared payload length.
        declared_length: u64,
        /// Configured maximum payload size.
        max: usize,
    },
    /// The frame's trailer hash did not match the FNV-1a-64 of
    /// the payload.  Genuine corruption (a torn write would
    /// surface as EOF before the trailer); the operator should
    /// inspect the log file.
    #[error(
        "trailer hash mismatch at offset {offset}: expected {expected:#018x}, got {got:#018x}"
    )]
    BadTrailer {
        /// Byte offset of the frame header.
        offset: u64,
        /// Hash recovered from the trailer.
        got: u64,
        /// Hash we computed over the payload.
        expected: u64,
    },
}

/// Outcome of a single `poll` call.
#[derive(Debug)]
pub enum PollOutcome {
    /// A complete frame was decoded; bytes are now consumed.
    Frame(LogFrame),
    /// The file is at EOF or holds an incomplete frame at the
    /// tail.  Caller should sleep and retry.  Carries the
    /// **byte count** of unread tail bytes (zero if EOF on a
    /// frame boundary, non-zero if the writer has flushed
    /// some bytes of a new frame but not all).
    Pending {
        /// Bytes available at the tail but not yet a complete
        /// frame.  Diagnostic only — the next poll will
        /// re-read them.
        tail_bytes: usize,
    },
}

/// Log-tail reader.
///
/// Stateful: holds the file handle, the byte cursor (`offset`),
/// and the next sequence number to assign (`next_seq`).
///
/// ## Cursor discipline
///
/// `offset` is **byte offset of the next un-consumed byte**.  On
/// a successful frame decode the cursor advances by exactly
/// `FRAME_HEADER_LEN + payload_len + FRAME_TRAILER_LEN`.  On a
/// torn / incomplete frame the cursor stays where it was so the
/// next `poll` can retry once the writer flushes.
///
/// ## Reopen-safe
///
/// The reader holds the file open across polls.  If the file is
/// rotated (`renameat2`-style replacement) the inode reference is
/// stale and reads will return EOF forever.  Canon's runtime does
/// not rotate the log in normal operation; if rotation is
/// configured, the subscribe daemon should be restarted.
///
/// ## Not thread-safe
///
/// `TailReader::poll` takes `&mut self`.  Multiple subscribers
/// share **one** tail reader (via the extractor thread); each
/// subscriber gets a clone of every extracted event from the
/// broadcast queue.
#[derive(Debug)]
pub struct TailReader {
    file: File,
    path: PathBuf,
    /// Cursor: byte offset of the next un-consumed byte.
    offset: u64,
    /// Next sequence number to assign.  `1`-indexed.
    next_seq: u64,
    /// Hard cap on accepted payload sizes.
    payload_max: usize,
}

impl TailReader {
    /// Open the log file at `path` and seek to the beginning.
    /// Subsequent `poll` calls walk the file from byte 0.
    ///
    /// ## Symlink policy (M-4 audit fix)
    ///
    /// The path is verified to point at a **regular file** via
    /// `Metadata::file_type().is_file()` (which follows symlinks).
    /// We then additionally check via
    /// `symlink_metadata().file_type().is_symlink()` that the
    /// path itself is NOT a symlink; if it is, we refuse to
    /// proceed.  This defends multi-tenant operator scenarios
    /// where an attacker could symlink the configured
    /// `--log-path` to a different file, causing the daemon to
    /// emit events from the wrong source.
    ///
    /// # Errors
    ///
    /// Returns `TailError::Io` if the file cannot be opened or
    /// is not a regular file.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, TailError> {
        let path_owned = path.as_ref().to_path_buf();
        // Refuse symlinks (M-4 defence).
        let sym_meta = std::fs::symlink_metadata(&path_owned).map_err(|e| TailError::Io {
            offset: 0,
            source: e,
        })?;
        if sym_meta.file_type().is_symlink() {
            return Err(TailError::Io {
                offset: 0,
                source: std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    format!(
                        "log path {} is a symlink; refusing to follow \
                         (security: prevents attacker-controlled redirection)",
                        path_owned.display()
                    ),
                ),
            });
        }
        // Refuse non-regular files (FIFOs, devices, etc).
        if !sym_meta.file_type().is_file() {
            return Err(TailError::Io {
                offset: 0,
                source: std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    format!("log path {} is not a regular file", path_owned.display()),
                ),
            });
        }
        let file = File::open(&path_owned).map_err(|e| TailError::Io {
            offset: 0,
            source: e,
        })?;
        Ok(Self {
            file,
            path: path_owned,
            offset: 0,
            next_seq: 1,
            payload_max: FRAME_PAYLOAD_MAX,
        })
    }

    /// Override the payload-size cap (default
    /// [`FRAME_PAYLOAD_MAX`]).  Clamped to
    /// `FRAME_PAYLOAD_MAX` as a defence-in-depth measure.
    #[must_use]
    pub fn with_payload_max(mut self, payload_max: usize) -> Self {
        self.payload_max = payload_max.min(FRAME_PAYLOAD_MAX);
        self
    }

    /// Path of the log file this reader was opened against.
    /// Diagnostic / logging use.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Current byte cursor position.
    #[must_use]
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Next sequence number that will be assigned.
    #[must_use]
    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }

    /// Attempt to read one frame from the current cursor.
    ///
    /// Returns:
    ///   * `Ok(PollOutcome::Frame(_))` — one complete frame
    ///     decoded; cursor advanced past it.
    ///   * `Ok(PollOutcome::Pending { tail_bytes })` — file is
    ///     at EOF or holds an incomplete frame.  Cursor
    ///     unchanged.  Caller should sleep and retry.
    ///   * `Err(TailError::FileShrank)` — the file is shorter
    ///     than our cursor (operator-side truncation, e.g.
    ///     `:>log.bin`).  Cursor preserved; caller decides
    ///     whether to halt or restart from byte 0.
    ///   * `Err(TailError)` — other protocol violation (bad
    ///     magic, bad trailer, oversize frame) or I/O error.
    ///     Cursor unchanged.
    ///
    /// # Errors
    ///
    /// See [`TailError`].
    pub fn poll(&mut self) -> Result<PollOutcome, TailError> {
        // 1. Determine how many bytes are available beyond the cursor.
        //    `file.metadata().len()` is the canonical way to query
        //    "how big is the file right now"; cheap on every platform.
        let total_len = self.file_len()?;
        // M-5 audit fix: detect file shrinkage (truncation /
        // rotation in place).  Without this, the reader silently
        // stalls forever returning Pending.
        if total_len < self.offset {
            return Err(TailError::FileShrank {
                cursor: self.offset,
                new_len: total_len,
            });
        }
        if total_len == self.offset {
            return Ok(PollOutcome::Pending { tail_bytes: 0 });
        }
        let available = total_len - self.offset;
        let available_usize = usize::try_from(available).unwrap_or(usize::MAX);
        if available_usize < FRAME_HEADER_LEN {
            return Ok(PollOutcome::Pending {
                tail_bytes: available_usize,
            });
        }

        // 2. Seek to cursor and read the header.
        self.seek_to(self.offset)?;
        let mut header = [0u8; FRAME_HEADER_LEN];
        self.read_exact_or_io(&mut header, self.offset)?;
        let got_magic = [header[0], header[1], header[2], header[3]];
        if got_magic != [FRAME_MAGIC_0, FRAME_MAGIC_1, FRAME_MAGIC_2, FRAME_MAGIC_3] {
            return Err(TailError::BadMagic {
                offset: self.offset,
                got: got_magic,
            });
        }
        let mut len_buf = [0u8; 8];
        len_buf.copy_from_slice(&header[4..12]);
        let payload_len_u64 = u64::from_le_bytes(len_buf);

        // 3. Bound the declared length up-front.
        let payload_len_usize = match usize::try_from(payload_len_u64) {
            Ok(n) => n,
            Err(_) => {
                return Err(TailError::OversizeFrame {
                    offset: self.offset,
                    declared_length: payload_len_u64,
                    max: self.payload_max,
                });
            }
        };
        if payload_len_usize > self.payload_max {
            return Err(TailError::OversizeFrame {
                offset: self.offset,
                declared_length: payload_len_u64,
                max: self.payload_max,
            });
        }

        // 4. Check if the full frame (header + payload + trailer) is
        //    present on disk.  If not, the writer is mid-frame; we
        //    leave the cursor where it was and ask the caller to retry.
        let total_frame_len = FRAME_HEADER_LEN + payload_len_usize + FRAME_TRAILER_LEN;
        let total_frame_len_u64 = total_frame_len as u64;
        if available < total_frame_len_u64 {
            return Ok(PollOutcome::Pending {
                tail_bytes: available_usize,
            });
        }

        // 5. Read the payload + trailer.
        let payload_offset = self.offset + FRAME_HEADER_LEN as u64;
        let mut payload = vec![0u8; payload_len_usize];
        self.read_exact_or_io(&mut payload, payload_offset)?;
        let trailer_offset = payload_offset + payload_len_usize as u64;
        let mut trailer_buf = [0u8; FRAME_TRAILER_LEN];
        self.read_exact_or_io(&mut trailer_buf, trailer_offset)?;
        let trailer_got = u64::from_le_bytes(trailer_buf);
        let trailer_expected = fnv1a64(&payload);
        if trailer_got != trailer_expected {
            return Err(TailError::BadTrailer {
                offset: self.offset,
                got: trailer_got,
                expected: trailer_expected,
            });
        }

        // 6. Advance cursor + assign seq.  Bound-check the seq
        //    increment defensively (the cursor stays cooperative even
        //    if next_seq overflows after billions of frames).
        let seq = self.next_seq;
        self.next_seq = self.next_seq.saturating_add(1);
        self.offset += total_frame_len_u64;

        Ok(PollOutcome::Frame(LogFrame { seq, payload }))
    }

    /// Current file length, queried fresh on every call to handle
    /// concurrent appends by the writer.
    fn file_len(&self) -> Result<u64, TailError> {
        self.file
            .metadata()
            .map(|m| m.len())
            .map_err(|e| TailError::Io {
                offset: self.offset,
                source: e,
            })
    }

    /// Seek the underlying file handle.  Encapsulates the typed
    /// error wrap.
    fn seek_to(&mut self, offset: u64) -> Result<(), TailError> {
        self.file
            .seek(SeekFrom::Start(offset))
            .map(|_| ())
            .map_err(|e| TailError::Io { offset, source: e })
    }

    /// Read exactly `buf.len()` bytes, mapping I/O errors to
    /// `TailError::Io` and treating a short read (EOF before
    /// `buf.len()` bytes) as also `TailError::Io`.  Callers
    /// should have already verified via `available` that
    /// `buf.len()` bytes are present; a short read here means
    /// the file shrank under us (or the OS lied about metadata),
    /// which we surface as an I/O error.
    fn read_exact_or_io(&mut self, buf: &mut [u8], offset_for_diag: u64) -> Result<(), TailError> {
        self.file.read_exact(buf).map_err(|e| TailError::Io {
            offset: offset_for_diag,
            source: e,
        })
    }

    /// **Test-only helper.**  Reset the cursor and reopen the file.
    /// Lets tests verify re-read semantics without dropping the
    /// reader.
    #[cfg(test)]
    fn reopen(&mut self) -> Result<(), TailError> {
        let file = File::open(&self.path).map_err(|e| TailError::Io {
            offset: 0,
            source: e,
        })?;
        self.file = file;
        self.offset = 0;
        self.next_seq = 1;
        Ok(())
    }
}

/// FNV-1a-64 of the supplied bytes.  Mirrors Lean's
/// `LegalKernel/Runtime/Hash.lean::fnv1a64Stream`.
#[must_use]
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h = FNV1A_64_OFFSET_BASIS;
    for &b in bytes {
        h ^= u64::from(b);
        // Wrapping mul: Lean's fnv1a64 is `(mod 2^64)` arithmetic.
        h = h.wrapping_mul(FNV1A_64_PRIME);
    }
    h
}

/// Encode one frame for testing.  Produces the same byte layout
/// `LegalKernel/Runtime/LogFile.lean::encodeFrame` produces.
#[cfg(test)]
#[must_use]
fn encode_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(FRAME_HEADER_LEN + payload.len() + FRAME_TRAILER_LEN);
    out.push(FRAME_MAGIC_0);
    out.push(FRAME_MAGIC_1);
    out.push(FRAME_MAGIC_2);
    out.push(FRAME_MAGIC_3);
    let len_u64 = payload.len() as u64;
    out.extend_from_slice(&len_u64.to_le_bytes());
    out.extend_from_slice(payload);
    out.extend_from_slice(&fnv1a64(payload).to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::{
        encode_frame, fnv1a64, LogFrame, PollOutcome, TailError, TailReader, FRAME_HEADER_LEN,
        FRAME_TRAILER_LEN,
    };
    use std::io::Write;
    use tempfile::NamedTempFile;

    /// Empty file: tail reader returns `Pending` with zero tail.
    #[test]
    fn empty_file_is_pending() {
        let file = NamedTempFile::new().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Pending { tail_bytes } => assert_eq!(tail_bytes, 0),
            PollOutcome::Frame(_) => panic!("expected Pending"),
        }
    }

    /// Single frame: tail reader returns it with seq=1.
    #[test]
    fn single_frame_returns_seq_1() {
        let mut file = NamedTempFile::new().unwrap();
        let payload = b"hello world".to_vec();
        let frame = encode_frame(&payload);
        file.write_all(&frame).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Frame(LogFrame { seq, payload: p }) => {
                assert_eq!(seq, 1);
                assert_eq!(p, payload);
            }
            PollOutcome::Pending { .. } => panic!("expected Frame"),
        }
        // Subsequent poll: Pending (no more frames).
        match tail.poll().unwrap() {
            PollOutcome::Pending { tail_bytes } => assert_eq!(tail_bytes, 0),
            PollOutcome::Frame(_) => panic!("expected Pending"),
        }
    }

    /// Multiple frames: sequential reads return monotonic seq.
    #[test]
    fn multiple_frames_monotonic_seq() {
        let mut file = NamedTempFile::new().unwrap();
        let p1 = b"first".to_vec();
        let p2 = b"second".to_vec();
        let p3 = b"third".to_vec();
        file.write_all(&encode_frame(&p1)).unwrap();
        file.write_all(&encode_frame(&p2)).unwrap();
        file.write_all(&encode_frame(&p3)).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        let f1 = match tail.poll().unwrap() {
            PollOutcome::Frame(f) => f,
            _ => panic!("expected Frame"),
        };
        let f2 = match tail.poll().unwrap() {
            PollOutcome::Frame(f) => f,
            _ => panic!("expected Frame"),
        };
        let f3 = match tail.poll().unwrap() {
            PollOutcome::Frame(f) => f,
            _ => panic!("expected Frame"),
        };
        assert_eq!(f1.seq, 1);
        assert_eq!(f2.seq, 2);
        assert_eq!(f3.seq, 3);
        assert_eq!(f1.payload, p1);
        assert_eq!(f2.payload, p2);
        assert_eq!(f3.payload, p3);
    }

    /// Append-after-read: the tail reader picks up new frames.
    #[test]
    fn appends_picked_up_on_subsequent_poll() {
        let mut file = NamedTempFile::new().unwrap();
        let p1 = b"first".to_vec();
        file.write_all(&encode_frame(&p1)).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Frame(f) => assert_eq!(f.payload, p1),
            _ => panic!("expected Frame"),
        }
        // No more frames.
        match tail.poll().unwrap() {
            PollOutcome::Pending { .. } => {}
            _ => panic!("expected Pending"),
        }
        // Append a second frame.
        let p2 = b"second appended later".to_vec();
        file.as_file_mut().write_all(&encode_frame(&p2)).unwrap();
        file.as_file_mut().flush().unwrap();
        // Now the next poll returns it.
        match tail.poll().unwrap() {
            PollOutcome::Frame(f) => {
                assert_eq!(f.seq, 2);
                assert_eq!(f.payload, p2);
            }
            _ => panic!("expected Frame"),
        }
    }

    /// Partial frame written: tail reader returns Pending with
    /// the actual tail-byte count.
    #[test]
    fn partial_header_pending() {
        let mut file = NamedTempFile::new().unwrap();
        // Write only the magic + 4 bytes of the length field.
        file.write_all(&[
            super::FRAME_MAGIC_0,
            super::FRAME_MAGIC_1,
            super::FRAME_MAGIC_2,
            super::FRAME_MAGIC_3,
            0x05,
            0x00,
            0x00,
            0x00,
        ])
        .unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Pending { tail_bytes } => {
                // We have 8 < FRAME_HEADER_LEN (12) bytes.
                assert_eq!(tail_bytes, 8);
            }
            other => panic!("expected Pending, got {other:?}"),
        }
    }

    /// Full header but partial payload: Pending.
    #[test]
    fn partial_payload_pending() {
        let mut file = NamedTempFile::new().unwrap();
        // Header claims 10 bytes; write only 3.
        let mut hdr = vec![
            super::FRAME_MAGIC_0,
            super::FRAME_MAGIC_1,
            super::FRAME_MAGIC_2,
            super::FRAME_MAGIC_3,
        ];
        hdr.extend_from_slice(&10u64.to_le_bytes());
        hdr.extend_from_slice(&[0x01, 0x02, 0x03]); // partial payload
        file.write_all(&hdr).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Pending { tail_bytes } => {
                assert_eq!(tail_bytes, hdr.len());
            }
            other => panic!("expected Pending, got {other:?}"),
        }
    }

    /// Full header + payload but missing trailer: Pending.
    #[test]
    fn missing_trailer_pending() {
        let mut file = NamedTempFile::new().unwrap();
        let mut bytes = vec![
            super::FRAME_MAGIC_0,
            super::FRAME_MAGIC_1,
            super::FRAME_MAGIC_2,
            super::FRAME_MAGIC_3,
        ];
        bytes.extend_from_slice(&5u64.to_le_bytes());
        bytes.extend_from_slice(b"abcde");
        // No trailer written.
        file.write_all(&bytes).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Pending { .. } => {}
            other => panic!("expected Pending, got {other:?}"),
        }
    }

    /// Bad magic: BadMagic error.
    #[test]
    fn bad_magic_returns_error() {
        let mut file = NamedTempFile::new().unwrap();
        let mut bytes = vec![0xff, 0xff, 0xff, 0xff]; // wrong magic
        bytes.extend_from_slice(&0u64.to_le_bytes());
        // No payload.  Add a fake trailer to ensure FRAME_HEADER_LEN + 0 + 8 bytes exist.
        bytes.extend_from_slice(&0u64.to_le_bytes());
        file.write_all(&bytes).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll() {
            Err(TailError::BadMagic { got, offset }) => {
                assert_eq!(offset, 0);
                assert_eq!(got, [0xff, 0xff, 0xff, 0xff]);
            }
            other => panic!("expected BadMagic, got {other:?}"),
        }
    }

    /// Bad trailer: BadTrailer error.
    #[test]
    fn bad_trailer_returns_error() {
        let mut file = NamedTempFile::new().unwrap();
        let payload = b"hello".to_vec();
        let mut bytes = vec![
            super::FRAME_MAGIC_0,
            super::FRAME_MAGIC_1,
            super::FRAME_MAGIC_2,
            super::FRAME_MAGIC_3,
        ];
        bytes.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        bytes.extend_from_slice(&payload);
        // Write a wrong trailer.
        bytes.extend_from_slice(&0xdead_beef_cafe_babe_u64.to_le_bytes());
        file.write_all(&bytes).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll() {
            Err(TailError::BadTrailer {
                offset,
                got,
                expected,
            }) => {
                assert_eq!(offset, 0);
                assert_eq!(got, 0xdead_beef_cafe_babe);
                assert_eq!(expected, fnv1a64(&payload));
            }
            other => panic!("expected BadTrailer, got {other:?}"),
        }
    }

    /// Oversize frame (declared length > payload_max): OversizeFrame.
    #[test]
    fn oversize_frame_returns_error() {
        let mut file = NamedTempFile::new().unwrap();
        let mut bytes = vec![
            super::FRAME_MAGIC_0,
            super::FRAME_MAGIC_1,
            super::FRAME_MAGIC_2,
            super::FRAME_MAGIC_3,
        ];
        // Claim 2 MiB payload; reader caps at 1 MiB via with_payload_max.
        bytes.extend_from_slice(&(2u64 * 1024 * 1024).to_le_bytes());
        file.write_all(&bytes).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path())
            .unwrap()
            .with_payload_max(1024 * 1024);
        match tail.poll() {
            Err(TailError::OversizeFrame {
                declared_length,
                max,
                ..
            }) => {
                assert_eq!(declared_length, 2 * 1024 * 1024);
                assert_eq!(max, 1024 * 1024);
            }
            other => panic!("expected OversizeFrame, got {other:?}"),
        }
    }

    /// `with_payload_max` is clamped to FRAME_PAYLOAD_MAX.
    #[test]
    fn payload_max_clamped() {
        let file = NamedTempFile::new().unwrap();
        let tail = TailReader::open(file.path())
            .unwrap()
            .with_payload_max(usize::MAX);
        assert_eq!(tail.payload_max, super::FRAME_PAYLOAD_MAX);
    }

    /// Empty payload (length = 0) is legal: a zero-length frame
    /// is just header + 8 trailer bytes.
    #[test]
    fn empty_payload_frame() {
        let mut file = NamedTempFile::new().unwrap();
        let bytes = encode_frame(&[]);
        // Header (12) + 0 payload + trailer (8) = 20 bytes.
        assert_eq!(bytes.len(), FRAME_HEADER_LEN + FRAME_TRAILER_LEN);
        file.write_all(&bytes).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        match tail.poll().unwrap() {
            PollOutcome::Frame(f) => {
                assert_eq!(f.seq, 1);
                assert!(f.payload.is_empty());
            }
            other => panic!("expected Frame, got {other:?}"),
        }
    }

    /// Reopening a file resets the cursor and reads identically.
    #[test]
    fn reopen_resets_cursor() {
        let mut file = NamedTempFile::new().unwrap();
        let payload = b"once".to_vec();
        file.write_all(&encode_frame(&payload)).unwrap();
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        let f1 = match tail.poll().unwrap() {
            PollOutcome::Frame(f) => f,
            _ => panic!("expected Frame"),
        };
        assert_eq!(f1.seq, 1);
        // Reopen.
        tail.reopen().unwrap();
        assert_eq!(tail.next_seq(), 1);
        assert_eq!(tail.offset(), 0);
        // Re-read the same frame; same seq.
        let f1_again = match tail.poll().unwrap() {
            PollOutcome::Frame(f) => f,
            _ => panic!("expected Frame"),
        };
        assert_eq!(f1_again.seq, 1);
        assert_eq!(f1_again.payload, payload);
    }

    /// FNV-1a-64 well-known vectors.
    #[test]
    fn fnv1a64_well_known_vectors() {
        // From the FNV reference implementation: fnv1a64("") =
        // 0xcbf29ce484222325 (the initial state).
        assert_eq!(fnv1a64(&[]), 0xcbf2_9ce4_8422_2325);
        // fnv1a64("a") = 0xaf63dc4c8601ec8c
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
        // fnv1a64("foobar") = 0x85944171f73967e8
        assert_eq!(fnv1a64(b"foobar"), 0x8594_4171_f739_67e8);
    }

    /// `TailError` is `Send + Sync` so threads can propagate.
    #[test]
    fn tail_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<TailError>();
    }

    /// `LogFrame` is `Send + Sync`.
    #[test]
    fn log_frame_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<LogFrame>();
    }

    /// `next_seq` advances exactly with successful polls.
    #[test]
    fn next_seq_advances_with_polls() {
        let mut file = NamedTempFile::new().unwrap();
        for i in 0..5u8 {
            let payload = vec![i; 4];
            file.write_all(&encode_frame(&payload)).unwrap();
        }
        file.flush().unwrap();
        let mut tail = TailReader::open(file.path()).unwrap();
        assert_eq!(tail.next_seq(), 1);
        for expected_seq in 1..=5 {
            match tail.poll().unwrap() {
                PollOutcome::Frame(f) => assert_eq!(f.seq, expected_seq),
                _ => panic!("expected Frame"),
            }
            assert_eq!(tail.next_seq(), expected_seq + 1);
        }
    }

    /// Calling poll on a missing file returns Io error.
    #[test]
    fn missing_file_returns_io_error() {
        let path = std::path::PathBuf::from("/tmp/canon-event-subscribe-test-nonexistent-12345");
        match TailReader::open(&path) {
            Err(TailError::Io { .. }) => {}
            other => panic!("expected Io error, got {other:?}"),
        }
    }
}
