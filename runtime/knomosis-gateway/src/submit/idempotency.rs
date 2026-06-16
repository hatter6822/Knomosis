// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G2.4 idempotency cache: a bounded, TTL'd `Idempotency-Key` → response
//! map that lets a client safely **retry** a submit without re-running
//! the action.
//!
//! Why it matters: a submit is **not** idempotent at the kernel.  If a
//! client's network drops the *response* (but the action reached the
//! host), a naive retry re-submits — and the kernel's nonce then declines
//! the replay, so the client sees a *different* verdict
//! (`NotAdmissible`) than the original (`Ok`).  With a client-supplied
//! `Idempotency-Key`, the gateway returns the **cached original
//! response** for a duplicate key, doing no second host round-trip.
//!
//! **What is cached.**  Only a *definitive* response (a host verdict or a
//! client-side `4xx`): status `200..500`.  Transient failures (`5xx` —
//! host unreached, busy, timed out) are **not** cached, so the client may
//! retry and actually reach the host.
//!
//! **Bounds.**  Entries expire after `ttl`; the map is capped at
//! `max_entries` with least-recently-used eviction, so a stream of unique
//! keys cannot grow it without bound.  `ttl = 0` disables the cache.
//!
//! The key is **opaque** and client-supplied; the client is responsible
//! for using a distinct key per distinct action (the cache does not
//! fingerprint the body).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::http::RouteOutcome;

/// One cached response with its expiry + last-access tick (for LRU).
struct Entry {
    outcome: RouteOutcome,
    expires_at: Instant,
    last_access: u64,
}

/// A bounded, TTL'd idempotency-key → response cache (thread-safe).
pub struct IdempotencyCache {
    /// Time-to-live; `Duration::ZERO` disables the cache.
    ttl: Duration,
    /// Maximum retained entries (LRU-evicted at capacity).
    max_entries: usize,
    /// Key → cached response.
    entries: Mutex<HashMap<String, Entry>>,
    /// Monotonic access counter feeding the LRU `last_access` stamps.
    tick: AtomicU64,
}

impl std::fmt::Debug for IdempotencyCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IdempotencyCache")
            .field("ttl_secs", &self.ttl.as_secs())
            .field("max_entries", &self.max_entries)
            .finish_non_exhaustive()
    }
}

/// Whether a submit response is safe to cache for replay: a *definitive*
/// outcome (a host verdict or a client `4xx`), never a transient `5xx`
/// (host unreached / busy / timed out — the client should be free to
/// retry those and actually reach the host).
#[must_use]
pub fn is_cacheable(outcome: &RouteOutcome) -> bool {
    (200..500).contains(&outcome.status)
}

impl IdempotencyCache {
    /// A cache with the given TTL (seconds; `0` disables it) and entry
    /// cap.
    #[must_use]
    pub fn new(ttl_secs: u64, max_entries: usize) -> Self {
        Self::from_ttl(Duration::from_secs(ttl_secs), max_entries)
    }

    /// A cache with a [`Duration`] TTL (`Duration::ZERO` disables it) —
    /// the constructor `new` delegates to, and the one tests use for
    /// sub-second expiry.
    #[must_use]
    pub fn from_ttl(ttl: Duration, max_entries: usize) -> Self {
        Self {
            ttl,
            max_entries: max_entries.max(1),
            entries: Mutex::new(HashMap::new()),
            tick: AtomicU64::new(0),
        }
    }

    /// Whether the cache is enabled (`--idempotency-ttl-secs > 0`).
    #[must_use]
    pub fn is_enabled(&self) -> bool {
        !self.ttl.is_zero()
    }

    /// The cached response for `key`, if present and unexpired (refreshing
    /// its LRU recency).  An expired entry is dropped and returns `None`.
    #[must_use]
    pub fn get(&self, key: &str) -> Option<RouteOutcome> {
        if !self.is_enabled() {
            return None;
        }
        let now = Instant::now();
        let access = self.tick.fetch_add(1, Ordering::Relaxed);
        let mut entries = self.lock();
        match entries.get_mut(key) {
            Some(entry) if entry.expires_at > now => {
                entry.last_access = access;
                Some(entry.outcome.clone())
            }
            Some(_) => {
                entries.remove(key);
                None
            }
            None => None,
        }
    }

    /// Cache `outcome` under `key` (no-op when disabled or `outcome` is
    /// not cacheable).  Evicts expired entries and, at capacity, the
    /// least-recently-used entry.
    pub fn put(&self, key: &str, outcome: &RouteOutcome) {
        if !self.is_enabled() || !is_cacheable(outcome) {
            return;
        }
        let now = Instant::now();
        let access = self.tick.fetch_add(1, Ordering::Relaxed);
        let mut entries = self.lock();
        // Sweep expired entries first (keeps the cap meaningful + bounds
        // memory under churn).
        entries.retain(|_, e| e.expires_at > now);
        // Evict the LRU entry if inserting a NEW key would exceed the cap.
        if entries.len() >= self.max_entries && !entries.contains_key(key) {
            if let Some(lru) = entries
                .iter()
                .min_by_key(|(_, e)| e.last_access)
                .map(|(k, _)| k.clone())
            {
                entries.remove(&lru);
            }
        }
        entries.insert(
            key.to_string(),
            Entry {
                outcome: outcome.clone(),
                expires_at: now + self.ttl,
                last_access: access,
            },
        );
    }

    /// Current entry count (for tests / metrics).
    #[must_use]
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    /// Whether the cache currently holds no entries.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Lock the entry map, recovering from a poisoned mutex (a handler
    /// panicked mid-update; the map is still usable).
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Entry>> {
        self.entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::IdempotencyCache;
    use crate::http::RouteOutcome;

    fn ok(body: &str) -> RouteOutcome {
        RouteOutcome::json(200, body.to_string())
    }

    #[test]
    fn hit_returns_cached_response() {
        let cache = IdempotencyCache::new(60, 16);
        assert!(cache.get("k").is_none()); // miss
        cache.put("k", &ok("first"));
        let hit = cache.get("k").expect("hit");
        assert_eq!(hit.body, "first");
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn disabled_cache_never_stores() {
        let cache = IdempotencyCache::new(0, 16);
        assert!(!cache.is_enabled());
        cache.put("k", &ok("x"));
        assert!(cache.get("k").is_none());
        assert!(cache.is_empty());
    }

    #[test]
    fn transient_5xx_is_not_cached() {
        let cache = IdempotencyCache::new(60, 16);
        cache.put("k", &RouteOutcome::problem(503, "{}".to_string()));
        assert!(cache.get("k").is_none(), "5xx must not be cached");
        // A 4xx client error IS cacheable (deterministic).
        cache.put("k4", &RouteOutcome::problem(400, "{}".to_string()));
        assert!(cache.get("k4").is_some());
    }

    #[test]
    fn entries_expire_after_ttl() {
        use std::time::Duration;
        let cache = IdempotencyCache::from_ttl(Duration::from_millis(40), 16);
        cache.put("k", &ok("v"));
        assert!(cache.get("k").is_some(), "live before the TTL");
        std::thread::sleep(Duration::from_millis(60));
        assert!(cache.get("k").is_none(), "expired after the TTL");
        // The expired entry was swept on the miss.
        assert!(cache.is_empty());
    }

    #[test]
    fn bounded_with_lru_eviction() {
        let cache = IdempotencyCache::new(60, 2);
        cache.put("a", &ok("a"));
        cache.put("b", &ok("b"));
        // Touch "a" so "b" becomes the least-recently-used.
        assert!(cache.get("a").is_some());
        // Inserting "c" at capacity evicts the LRU ("b").
        cache.put("c", &ok("c"));
        assert_eq!(cache.len(), 2);
        assert!(cache.get("a").is_some(), "recently-used kept");
        assert!(cache.get("c").is_some(), "newest kept");
        assert!(cache.get("b").is_none(), "LRU evicted");
    }

    #[test]
    fn unique_keys_do_not_grow_past_cap() {
        let cache = IdempotencyCache::new(60, 8);
        for i in 0..1000 {
            cache.put(&format!("key-{i}"), &ok("v"));
        }
        assert!(cache.len() <= 8, "cache stayed bounded: {}", cache.len());
    }
}
