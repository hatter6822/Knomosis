#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Vendor OpenZeppelin contracts v5.0.2 + forge-std v1.9.4 into ./lib/.
# Idempotent — re-running with the deps already installed is a no-op.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

mkdir -p "${LIB_DIR}"

if [[ ! -d "${LIB_DIR}/openzeppelin-contracts" ]]; then
    echo "Vendoring OpenZeppelin contracts v5.0.2..."
    curl -sSfL "https://github.com/OpenZeppelin/openzeppelin-contracts/archive/refs/tags/v5.0.2.tar.gz" \
      -o /tmp/oz.tar.gz
    tar xzf /tmp/oz.tar.gz -C "${LIB_DIR}/"
    mv "${LIB_DIR}/openzeppelin-contracts-5.0.2" "${LIB_DIR}/openzeppelin-contracts"
    rm /tmp/oz.tar.gz
fi

if [[ ! -d "${LIB_DIR}/forge-std" ]]; then
    echo "Vendoring forge-std v1.9.4..."
    curl -sSfL "https://github.com/foundry-rs/forge-std/archive/refs/tags/v1.9.4.tar.gz" \
      -o /tmp/fs.tar.gz
    tar xzf /tmp/fs.tar.gz -C "${LIB_DIR}/"
    mv "${LIB_DIR}/forge-std-1.9.4" "${LIB_DIR}/forge-std"
    rm /tmp/fs.tar.gz
fi

echo "Vendored dependencies are up to date."
echo "  ${LIB_DIR}/openzeppelin-contracts (v5.0.2)"
echo "  ${LIB_DIR}/forge-std (v1.9.4)"
