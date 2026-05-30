#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis — SessionStart hook for Claude Code on the web.
#
# Purpose: ensure the Lean toolchain (`lake`, `lean`) and the Solidity
# toolchain (`forge`, `cast`, `anvil`, `solc`, OpenZeppelin + forge-std
# vendored deps) are installed and on `$PATH` before the agent starts
# answering tool calls.
#
# Cost profile:
#   * Lean fast-path  ~50 ms (everything already on disk)
#   * Lean slow-path  ~30-60 s (toolchain download + extract)
#   * Solidity fast-path  ~50 ms (forge / solc already installed)
#   * Solidity slow-path  ~3 s (Foundry tarball download + extract +
#                                 vendor-deps git clone)
#
# Synchronous mode: the agent blocks on this hook so subsequent
# `lake build` / `forge test` calls don't race against an in-flight
# install.  See `.claude/settings.json` for registration.
#
# Idempotency: every step inside `scripts/setup.sh` short-circuits
# when the artefact is already present and content-hash-verified, so
# re-running the hook on a warm cache is cheap.
#
# Environment:
#   $CLAUDE_PROJECT_DIR — repository root (Knomosis).
#   $CLAUDE_ENV_FILE    — file to which `export VAR=...` lines are
#                          appended for session-wide PATH overrides.
#   $CLAUDE_CODE_REMOTE — set to "true" only inside the web sandbox.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/home/user/Knomosis}"

# Run the canonical setup script in --quiet mode.  Uses the project's
# pinned SHA-256 audit log for both Lean and Solidity artefacts.
if [ -x "${PROJECT_DIR}/scripts/setup.sh" ]; then
  "${PROJECT_DIR}/scripts/setup.sh" --quiet
else
  echo "[session-start] error: ${PROJECT_DIR}/scripts/setup.sh not found or not executable" >&2
  exit 1
fi

# Persist PATH overrides so the agent's subsequent `Bash` invocations
# pick up the toolchains.  `lake` is sourced via elan's env file;
# Foundry's `forge` is at /usr/local/foundry/bin (matches the
# pinned location in `solidity/README.md`).
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  cat >> "${CLAUDE_ENV_FILE}" <<EOF
export PATH="/usr/local/foundry/bin:\$PATH"
if [ -f "\$HOME/.elan/env" ]; then
  source "\$HOME/.elan/env"
fi
EOF
fi
