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
//! cursor registry + last-complete-group watermark); the upstream
//! multiplexer (G3.4b), per-client dispatch + eviction (G3.4c), and resume
//! semantics (G3.4d) build on it.

pub mod ring;
