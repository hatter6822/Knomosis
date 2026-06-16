// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The SSE fan-out (Workstream G3.4): multiplex a **single** shared
//! live-tail event-subscribe subscription (§11) to many browser SSE
//! clients, with the §6.1 composite-`(seq, index)`-id resume correctness.
//!
//! G3.4a ships the bounded [`ring`] (the shared record buffer + per-client
//! cursor registry + last-complete-group watermark); G3.4b the upstream
//! [`mux`] (the single subscription that feeds the ring, resubscribing from
//! the watermark on a drop); per-client dispatch + eviction (G3.4c) and
//! resume semantics (G3.4d) build on them.  [`FanoutState`] is the shared
//! seam between the mux (the writer) and the dispatchers (the readers).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use self::ring::EventRing;

pub mod dispatch;
pub mod mux;
pub mod ring;

/// The shared fan-out state: the bounded record ring (the mux writes it; the
/// per-client dispatchers read it) plus a fail-closed decode-fault cell.
///
/// Accessors recover a poisoned lock's guard (`PoisonError::into_inner`):
/// under the release `panic = "abort"` a poison can never occur, and under
/// the test `panic = "unwind"` recovering keeps a single panicking reader
/// from wedging every other client.
#[derive(Debug)]
pub struct FanoutState {
    ring: Mutex<EventRing>,
    fault: Mutex<Option<String>>,
}

impl FanoutState {
    /// A fresh shared state with a record ring of the given capacity.
    #[must_use]
    pub fn new(ring_capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            ring: Mutex::new(EventRing::new(ring_capacity)),
            fault: Mutex::new(None),
        })
    }

    /// Lock the shared ring (poison-recovering).
    pub fn ring(&self) -> MutexGuard<'_, EventRing> {
        self.ring.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Record a fail-closed decode fault (the first one wins; later faults
    /// do not overwrite the original diagnostic).  Dispatch surfaces it as
    /// the SSE `decode_error` and closes affected streams (§2 principle 7).
    pub fn set_fault(&self, diagnostic: String) {
        let mut guard = self.fault.lock().unwrap_or_else(PoisonError::into_inner);
        if guard.is_none() {
            *guard = Some(diagnostic);
        }
    }

    /// The recorded decode fault, if any (the stream is then compromised).
    #[must_use]
    pub fn fault(&self) -> Option<String> {
        self.fault
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}
