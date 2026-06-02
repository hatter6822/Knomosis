// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Fair-sequencing scheduler (Workstream GP.8, Track A / FQ).
//!
//! The optional per-actor fair scheduler that bounds, under
//! contention for the single serial worker, the share any one actor
//! can take — so a short-burst flood delays only itself while honest
//! actors keep their share and their enqueue capacity. It ships behind
//! the default-OFF `--scheduler drr` flag (FIFO stays the baseline);
//! the deployment opts in.
//!
//! Rung 0 (this milestone) keys fairness by the transport-
//! authenticated connection id (`ConnId`), requires no wire-format
//! change, and does zero CBE parsing on the host. The Rung-1
//! signer-hint extension (FQ.9–FQ.15) layers a second tier on top of
//! the same core.
//!
//!   * [`drr`] — the pure, I/O-free Deficit-Round-Robin core
//!     ([`drr::DrrState`] / [`drr::Caps`] / [`drr::DrrStats`]). The
//!     concurrency wrapper ([`crate::queue::FairQueue`]) and the
//!     server wiring ([`crate::server`]) build on it.
//!
//! See `docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md` §2.3–§2.8
//! for the design and §2.6 for the trust/safety invariants every WU
//! preserves (most importantly: the routing key influences order and
//! drop only, **never** admissibility).

pub mod drr;
