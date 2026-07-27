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
//!
//! **Scoping.**  Cache entries are namespaced by the *credential* that
//! wrote them ([`crate::auth::credential_key`], the same identity the
//! per-credential rate limiter buckets on).  The `Idempotency-Key` header
//! is client-chosen and the gateway accepts a whole token *file*, so two
//! clients independently picking `1` — or any shared value — must not
//! collide: an unscoped cache would hand the second client the first
//! client's verdict and silently never submit its action.  Keys are built
//! by [`scoped_key`], whose fixed-width credential prefix makes the
//! namespace boundary unambiguous no matter what the client-supplied
//! suffix contains.

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

/// Namespace a client-supplied `Idempotency-Key` by the credential that
/// presented it, so one client's cached verdict can never be replayed to
/// another.
///
/// The credential is rendered as exactly 16 hex digits followed by `:`.
/// Because that prefix is fixed-width, no client-supplied suffix — even
/// one containing `:` or a 16-hex-looking run — can shift the boundary and
/// land in another credential's namespace.  `None` (no bearer credential;
/// unreachable on the authenticated submit path, but reachable from
/// `RequestPayload::EMPTY` and the unit tests) gets its own `anon:`
/// namespace rather than sharing one with a real credential.
#[must_use]
fn scoped_key(credential: Option<u64>, key: &str) -> String {
    match credential {
        Some(c) => format!("{c:016x}:{key}"),
        None => format!("anon.............:{key}"),
    }
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

    /// The cached response `credential` previously stored under `key`, if
    /// present and unexpired (refreshing its LRU recency).  An expired
    /// entry is dropped and returns `None`.  Entries written by a
    /// *different* credential are invisible here — see [`scoped_key`].
    #[must_use]
    pub fn get(&self, credential: Option<u64>, key: &str) -> Option<RouteOutcome> {
        if !self.is_enabled() {
            return None;
        }
        let key = &scoped_key(credential, key);
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

    /// Cache `outcome` under `key`, in `credential`'s namespace (no-op
    /// when disabled or `outcome` is not cacheable).  Evicts expired
    /// entries and, at capacity, the least-recently-used entry.
    pub fn put(&self, credential: Option<u64>, key: &str, outcome: &RouteOutcome) {
        if !self.is_enabled() || !is_cacheable(outcome) {
            return;
        }
        // Owned: it is moved into the map below, so building it once here
        // avoids re-allocating for the insert.
        let key = scoped_key(credential, key);
        let now = Instant::now();
        let access = self.tick.fetch_add(1, Ordering::Relaxed);
        let mut entries = self.lock();
        // Sweep expired entries first (keeps the cap meaningful + bounds
        // memory under churn).
        entries.retain(|_, e| e.expires_at > now);
        // Evict the LRU entry if inserting a NEW key would exceed the cap.
        if entries.len() >= self.max_entries && !entries.contains_key(&key) {
            if let Some(lru) = entries
                .iter()
                .min_by_key(|(_, e)| e.last_access)
                .map(|(k, _)| k.clone())
            {
                entries.remove(&lru);
            }
        }
        entries.insert(
            key,
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
    use super::{scoped_key, IdempotencyCache};
    use crate::http::RouteOutcome;

    /// Two distinct credentials, as `credential_key` would produce them.
    const CRED_A: Option<u64> = Some(0xAAAA_AAAA_AAAA_AAAA);
    const CRED_B: Option<u64> = Some(0xBBBB_BBBB_BBBB_BBBB);

    fn ok(body: &str) -> RouteOutcome {
        RouteOutcome::json(200, body.to_string())
    }

    /// The security property: an `Idempotency-Key` is scoped to the
    /// credential that presented it.  Without this, client B reusing a key
    /// client A had already used would receive A's verdict — and B's own
    /// action would silently never be submitted to the host.
    #[test]
    fn key_is_scoped_per_credential() {
        let cache = IdempotencyCache::new(60, 16);
        cache.put(CRED_A, "shared-key", &ok("A-verdict"));

        // B chose the same key: it must MISS, not see A's response.
        assert!(
            cache.get(CRED_B, "shared-key").is_none(),
            "credential B must not observe credential A's cached verdict"
        );
        // An unauthenticated caller likewise gets its own namespace.
        assert!(cache.get(None, "shared-key").is_none());

        // B's own entry is independent and does not disturb A's.
        cache.put(CRED_B, "shared-key", &ok("B-verdict"));
        assert_eq!(
            cache.get(CRED_A, "shared-key").expect("A hit").body,
            "A-verdict"
        );
        assert_eq!(
            cache.get(CRED_B, "shared-key").expect("B hit").body,
            "B-verdict"
        );
    }

    /// The credential prefix is fixed-width, so no client-supplied suffix
    /// can shift the namespace boundary and collide with another
    /// credential's entries.
    #[test]
    fn scoped_key_namespaces_cannot_be_forged_by_the_suffix() {
        // A key that itself looks like a credential prefix must not land in
        // that credential's namespace.
        assert_ne!(
            scoped_key(CRED_A, "bbbbbbbbbbbbbbbb:k"),
            scoped_key(CRED_B, "k")
        );
        // Distinct credentials never share a namespace for the same key.
        assert_ne!(scoped_key(CRED_A, "k"), scoped_key(CRED_B, "k"));
        // The anonymous namespace is distinct from every credentialed one.
        assert_ne!(scoped_key(None, "k"), scoped_key(CRED_A, "k"));
        // Same credential + same key is stable (the cache must still hit).
        assert_eq!(scoped_key(CRED_A, "k"), scoped_key(CRED_A, "k"));
    }

    #[test]
    fn hit_returns_cached_response() {
        let cache = IdempotencyCache::new(60, 16);
        assert!(cache.get(CRED_A, "k").is_none()); // miss
        cache.put(CRED_A, "k", &ok("first"));
        let hit = cache.get(CRED_A, "k").expect("hit");
        assert_eq!(hit.body, "first");
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn disabled_cache_never_stores() {
        let cache = IdempotencyCache::new(0, 16);
        assert!(!cache.is_enabled());
        cache.put(CRED_A, "k", &ok("x"));
        assert!(cache.get(CRED_A, "k").is_none());
        assert!(cache.is_empty());
    }

    #[test]
    fn transient_5xx_is_not_cached() {
        let cache = IdempotencyCache::new(60, 16);
        cache.put(CRED_A, "k", &RouteOutcome::problem(503, "{}".to_string()));
        assert!(cache.get(CRED_A, "k").is_none(), "5xx must not be cached");
        // A 4xx client error IS cacheable (deterministic).
        cache.put(CRED_A, "k4", &RouteOutcome::problem(400, "{}".to_string()));
        assert!(cache.get(CRED_A, "k4").is_some());
    }

    #[test]
    fn entries_expire_after_ttl() {
        use std::time::Duration;
        let cache = IdempotencyCache::from_ttl(Duration::from_millis(40), 16);
        cache.put(CRED_A, "k", &ok("v"));
        assert!(cache.get(CRED_A, "k").is_some(), "live before the TTL");
        std::thread::sleep(Duration::from_millis(60));
        assert!(cache.get(CRED_A, "k").is_none(), "expired after the TTL");
        // The expired entry was swept on the miss.
        assert!(cache.is_empty());
    }

    #[test]
    fn bounded_with_lru_eviction() {
        let cache = IdempotencyCache::new(60, 2);
        cache.put(CRED_A, "a", &ok("a"));
        cache.put(CRED_A, "b", &ok("b"));
        // Touch "a" so "b" becomes the least-recently-used.
        assert!(cache.get(CRED_A, "a").is_some());
        // Inserting "c" at capacity evicts the LRU ("b").
        cache.put(CRED_A, "c", &ok("c"));
        assert_eq!(cache.len(), 2);
        assert!(cache.get(CRED_A, "a").is_some(), "recently-used kept");
        assert!(cache.get(CRED_A, "c").is_some(), "newest kept");
        assert!(cache.get(CRED_A, "b").is_none(), "LRU evicted");
    }

    #[test]
    fn unique_keys_do_not_grow_past_cap() {
        let cache = IdempotencyCache::new(60, 8);
        for i in 0..1000 {
            cache.put(CRED_A, &format!("key-{i}"), &ok("v"));
        }
        assert!(cache.len() <= 8, "cache stayed bounded: {}", cache.len());
    }
}
