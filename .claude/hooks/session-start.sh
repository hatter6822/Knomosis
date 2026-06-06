#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis — SessionStart hook for Claude Code on the web.
#
# Purpose: ensure ALL THREE first-party toolchains AND their
# dependencies are installed and on $PATH before the agent starts, so
# `lake build` / `lake test`, `forge build` / `forge test`, and
# `cargo build` / `cargo test` / `cargo clippy` all run immediately
# without an in-flight install racing the first tool call:
#
#   * Lean      — elan + the pinned Lean toolchain (`lean-toolchain`),
#                 installed by `scripts/setup.sh` (SHA-256-verified).
#                 The kernel has ZERO external Lean-package deps, so the
#                 toolchain itself is the whole dependency set.
#   * Solidity  — Foundry (`forge`/`cast`/`anvil`) + `solc` + the
#                 vendored OpenZeppelin / forge-std libraries, installed
#                 by `scripts/setup.sh` (it runs `vendor-deps.sh`).
#   * Rust      — the pinned stable-1.83 toolchain with `clippy` +
#                 `rustfmt` (`runtime/rust-toolchain.toml`) + the
#                 workspace crate dependencies warmed into the registry
#                 cache via `cargo fetch --locked`.
#
# Cost profile (cold install -> warm idempotent re-run):
#   * Lean       ~30-60 s download+extract  ->  ~50 ms (hash-verified hit)
#   * Solidity   ~3 s tarball + git clone   ->  ~50 ms
#   * Rust       ~1-3 min crate fetch       ->  ~1 s (registry cache hit)
#
# Synchronous mode: the agent blocks on this hook so the first
# `lake build` / `forge test` / `cargo test` does NOT race an in-flight
# install.  See `.claude/settings.json` for registration.  (To trade the
# guarantee for a faster session start, switch to async mode — emit
# `echo '{"async": true, "asyncTimeout": 300000}'` as the first line.)
#
# Idempotency: every step short-circuits on a warm cache — `setup.sh`
# content-hash-verifies each artefact and skips it when present;
# `cargo fetch` is a registry cache hit — so re-running on a warm
# container is cheap.
#
# Network: the web environment's policy must permit the toolchain hosts.
#   * Lean / Foundry / solc / OZ : raw.githubusercontent.com + github.com
#                                  (+ objects.githubusercontent.com).
#   * Rust crates                : index.crates.io + static.crates.io.
#   * A missing 1.83 toolchain   : static.rust-lang.org (pre-installed in
#                                  the base image, so normally not hit).
#
# Environment:
#   $CLAUDE_PROJECT_DIR — repository root (Knomosis); falls back to the
#                          known mount when the hook is invoked without it.
#   $CLAUDE_ENV_FILE    — file to which `export VAR=...` lines are
#                          appended for session-wide PATH overrides.
#   $CLAUDE_CODE_REMOTE — "true" inside the web sandbox (this hook runs
#                          in every environment; it is a fast no-op on a
#                          warm local checkout).

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/home/user/Knomosis}"

# Make the base-image rustup/cargo reachable from THIS hook shell (the
# session-wide PATH is persisted separately, below).
export PATH="${HOME}/.cargo/bin:${PATH}"

# ---- Lean + Solidity -------------------------------------------------
# The canonical SHA-256-verified installer: elan + the pinned Lean
# toolchain AND Foundry + solc + the vendored OpenZeppelin / forge-std
# deps.  Idempotent — fast-paths every already-present, hash-verified
# artefact.
if [ -x "${PROJECT_DIR}/scripts/setup.sh" ]; then
  "${PROJECT_DIR}/scripts/setup.sh" --quiet
else
  echo "[session-start] error: ${PROJECT_DIR}/scripts/setup.sh not found or not executable" >&2
  exit 1
fi

# ---- Persist PATH for the session ------------------------------------
# Done BEFORE the network-dependent Rust fetch so every toolchain is on
# the agent's $PATH even if `cargo fetch` later fails on a transient
# network issue (the agent can re-fetch on demand).  `lake` / `lean`
# come from elan's env file; `forge` is at /usr/local/foundry/bin (the
# pinned location in `solidity/README.md`); `cargo` / `rustup` are at
# $HOME/.cargo/bin.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  cat >> "${CLAUDE_ENV_FILE}" <<EOF
export PATH="/usr/local/foundry/bin:\${HOME}/.cargo/bin:\$PATH"
if [ -f "\${HOME}/.elan/env" ]; then
  source "\${HOME}/.elan/env"
fi
EOF
fi

# ---- Rust ------------------------------------------------------------
# `cargo` inside runtime/ honours runtime/rust-toolchain.toml (stable
# 1.83 + clippy + rustfmt), auto-installing the toolchain if absent, then
# `--locked` fetches EXACTLY the committed Cargo.lock dependency set into
# the registry cache, so subsequent `cargo build` / `test` / `clippy`
# run without a network round-trip.  Mirrors the way `setup.sh` vendors
# the Solidity libraries — fetch deps, do not pre-build.
if command -v cargo >/dev/null 2>&1; then
  (cd "${PROJECT_DIR}/runtime" && cargo fetch --locked)
else
  echo "[session-start] error: cargo not found on PATH (expected base-image rustup at \$HOME/.cargo/bin)" >&2
  exit 1
fi
