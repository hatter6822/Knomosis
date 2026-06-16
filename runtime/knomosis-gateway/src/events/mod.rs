// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The events track (Workstream G3): the gateway tails the
//! `knomosis-event-subscribe` upstream (§11) and exposes it to a browser
//! as cursor-paginated backfill (`GET /v1/events`) and a live
//! Server-Sent-Events stream (`GET /v1/events/stream`).
//!
//! G3.1 ships the resilient upstream client ([`subscribe`]); G3.2 the
//! event decode → JSON renderer ([`decode`]); the bounded backfill page
//! (G3.3) and the SSE fan-out (G3.4) build on them.

pub mod decode;
pub mod subscribe;
