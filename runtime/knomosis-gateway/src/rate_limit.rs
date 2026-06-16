// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G1.3 per-credential rate limiting: a token-bucket governor keyed on
//! the (already-authenticated) bearer credential.
//!
//! Each credential gets a bucket of capacity `rps` that refills at `rps`
//! tokens/second; a request consumes one token, and an empty bucket is a
//! `429` with a `Retry-After` hint.  Per-credential (not global) keying
//! means one noisy credential cannot starve the others.
//!
//! **Bounded memory.**  Only *authenticated* requests reach the limiter
//! (the auth gate runs first), so the bucket map holds at most one entry
//! per configured token — there is no unauthenticated-growth vector.
//!
//! `--rate-limit-rps 0` disables the limiter (every request allowed).

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// One credential's token bucket.
struct TokenBucket {
    /// Current whole-or-fractional tokens available.
    tokens: f64,
    /// When `tokens` was last refilled.
    last_refill: Instant,
}

/// A per-credential token-bucket rate limiter (thread-safe).
pub struct RateLimiter {
    /// Refill rate (tokens/second) = the sustained request cap.  `0`
    /// disables the limiter entirely.
    rps: u32,
    /// Bucket capacity (the instantaneous burst allowance), in tokens.
    burst: f64,
    /// Per-credential buckets, keyed on a hash of the bearer token.
    buckets: Mutex<HashMap<u64, TokenBucket>>,
}

impl std::fmt::Debug for RateLimiter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The bucket map is keyed on opaque credential hashes; print the
        // configured rate only.
        f.debug_struct("RateLimiter")
            .field("rps", &self.rps)
            .field("burst", &self.burst)
            .finish_non_exhaustive()
    }
}

impl RateLimiter {
    /// A limiter capping each credential at `rps` requests/second with a
    /// one-second burst (`capacity = rps`).  `rps == 0` disables it.
    #[must_use]
    pub fn new(rps: u32) -> Self {
        Self {
            rps,
            // A full second of burst; at least one token so a 1-rps
            // limiter can ever admit a request.
            burst: f64::from(rps.max(1)),
            buckets: Mutex::new(HashMap::new()),
        }
    }

    /// Whether the limiter is disabled (`--rate-limit-rps 0`).
    #[must_use]
    pub fn is_disabled(&self) -> bool {
        self.rps == 0
    }

    /// Charge one request to the credential identified by `key`.  Returns
    /// `Ok(())` when admitted (a token was consumed), or
    /// `Err(retry_after)` when the bucket is empty — the suggested wait
    /// until one token refills.
    ///
    /// # Errors
    ///
    /// Returns `Err(Duration)` when the credential's bucket is exhausted.
    pub fn check(&self, key: u64) -> Result<(), Duration> {
        if self.rps == 0 {
            return Ok(()); // disabled
        }
        let now = Instant::now();
        // A poisoned lock means a handler panicked mid-update; recover the
        // guard rather than propagate (the bucket state is still usable).
        let mut buckets = self
            .buckets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let bucket = buckets.entry(key).or_insert(TokenBucket {
            tokens: self.burst,
            last_refill: now,
        });
        // Refill for the elapsed time, capped at the burst capacity.
        let elapsed = now.duration_since(bucket.last_refill).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * f64::from(self.rps)).min(self.burst);
        bucket.last_refill = now;
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            Ok(())
        } else {
            // Time until one whole token refills.
            let deficit = 1.0 - bucket.tokens;
            Err(Duration::from_secs_f64(deficit / f64::from(self.rps)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::RateLimiter;

    #[test]
    fn disabled_limiter_always_admits() {
        let limiter = RateLimiter::new(0);
        assert!(limiter.is_disabled());
        for _ in 0..1000 {
            assert!(limiter.check(7).is_ok());
        }
    }

    #[test]
    fn burst_then_throttle() {
        // rps = 5 → a 5-token burst, then the 6th in the same instant is
        // rejected.
        let limiter = RateLimiter::new(5);
        for _ in 0..5 {
            assert!(limiter.check(1).is_ok());
        }
        let retry = limiter.check(1).expect_err("6th is throttled");
        // The retry hint is positive and under a second (one token at
        // 5 rps refills in 0.2s).
        assert!(retry.as_secs_f64() > 0.0);
        assert!(retry.as_secs_f64() <= 0.2 + 1e-6);
    }

    #[test]
    fn per_credential_isolation() {
        // One credential exhausting its bucket does not affect another.
        let limiter = RateLimiter::new(2);
        assert!(limiter.check(1).is_ok());
        assert!(limiter.check(1).is_ok());
        assert!(limiter.check(1).is_err()); // credential 1 exhausted
                                            // Credential 2 has its own fresh bucket.
        assert!(limiter.check(2).is_ok());
        assert!(limiter.check(2).is_ok());
    }

    #[test]
    fn refill_admits_after_wait() {
        let limiter = RateLimiter::new(100); // 10ms per token
        for _ in 0..100 {
            assert!(limiter.check(9).is_ok());
        }
        assert!(limiter.check(9).is_err());
        // After 50ms, ~5 tokens have refilled.
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(limiter.check(9).is_ok());
    }
}
