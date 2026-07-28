#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Vendor OpenZeppelin contracts v5.0.2 + forge-std v1.9.4 into ./lib/.
# Idempotent — re-running with the deps already installed is a no-op.
#
# **Pinned by commit, not by tag.**  This script runs before every CI
# `forge build` / `forge test` AND before the live Sepolia deploy
# target, so whatever it fetches ends up compiled into deployed
# bytecode.  It previously downloaded GitHub's generated tarball for a
# TAG, with no verification of any kind.  A git tag is a mutable
# pointer: whoever controls the upstream repository can repoint it at
# different content, and the next CI run — or the next deploy — would
# silently compile that instead.
#
# The pin is a commit SHA, which is content-addressed: `git` verifies
# on checkout that the object graph hashes to the requested id, so a
# repointed tag or a substituted object cannot pass.  A tarball
# SHA-256 would be the other option, but GitHub's generated archives
# are not contractually byte-stable (compression and metadata can
# change), so a digest pin there risks breaking CI and deploys for a
# reason unrelated to security.
#
# Updating a dependency: change both the TAG and the SHA below, in the
# same commit, and note the pair in the PR description.  Resolve the
# SHA with:
#     git ls-remote https://github.com/<org>/<repo> refs/tags/<tag>
# (and `refs/tags/<tag>^{}` if the tag is annotated — use the peeled
# value, which is the commit).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

OZ_REPO="https://github.com/OpenZeppelin/openzeppelin-contracts"
OZ_TAG="v5.0.2"
OZ_SHA="dbb6104ce834628e473d2173bbc9d47f81a9eec3"

FS_REPO="https://github.com/foundry-rs/forge-std"
FS_TAG="v1.9.4"
FS_SHA="1eea5bae12ae557d589f9f0f0edae2faa47cb262"

mkdir -p "${LIB_DIR}"

# Fetch exactly one commit by id and check it out detached.
#
# `--filter=blob:none` keeps the clone cheap (blobs arrive on
# checkout).  `git fetch <sha>` requires the server to allow
# fetch-by-sha (`uploadpack.allowReachableSHA1InWant`), which GitHub
# does; if a mirror does not, the fallback below fetches the tag and
# then VERIFIES the resolved commit against the pin, so an
# unverified checkout is never produced either way.
vendor_commit() {
    local repo="$1" tag="$2" sha="$3" dest="$4" name="$5"

    echo "Vendoring ${name} ${tag} (${sha})..."
    rm -rf "${dest}.tmp"
    git init --quiet "${dest}.tmp"
    git -C "${dest}.tmp" remote add origin "${repo}"

    if ! git -C "${dest}.tmp" fetch --quiet --depth 1 --filter=blob:none \
            origin "${sha}" 2>/dev/null; then
        echo "  fetch-by-sha unavailable; falling back to tag fetch + verify"
        git -C "${dest}.tmp" fetch --quiet --depth 1 --filter=blob:none \
            origin "refs/tags/${tag}"
    fi

    git -C "${dest}.tmp" checkout --quiet --detach "${sha}"

    # Belt and braces: assert the checked-out commit IS the pin.  On
    # the fetch-by-sha path git has already verified this; on the tag
    # fallback this is what turns a mutable tag into a fixed pin.
    local got
    got="$(git -C "${dest}.tmp" rev-parse HEAD)"
    if [[ "${got}" != "${sha}" ]]; then
        echo "ERROR: ${name} ${tag} resolved to ${got}, expected ${sha}." >&2
        echo "       The upstream tag has been repointed, or the fetch was" >&2
        echo "       tampered with.  Refusing to vendor unverified sources." >&2
        rm -rf "${dest}.tmp"
        exit 1
    fi

    # Submodules are deliberately NOT initialised.  Neither pinned
    # dependency needs one for this build: `foundry.toml`'s remappings
    # reach only `lib/openzeppelin-contracts/contracts/` and
    # `lib/forge-std/src/`, OpenZeppelin's submodules are test-only
    # fixtures outside that path, and forge-std v1.9.4 vendors its
    # assertions directly rather than depending on `ds-test`.  Should a
    # future bump need one, the gitlink SHA is recorded IN the commit
    # pinned above, so it is content-addressed by the same pin and
    # needs no separate constant.
    #
    # Drop the .git directories: `lib/` is a vendored source tree, not
    # a submodule of this repository, and a nested repository confuses
    # `forge` and `git status`.
    find "${dest}.tmp" -name .git -maxdepth 3 -exec rm -rf {} + 2>/dev/null || true
    mv "${dest}.tmp" "${dest}"
}

if [[ ! -d "${LIB_DIR}/openzeppelin-contracts" ]]; then
    vendor_commit "${OZ_REPO}" "${OZ_TAG}" "${OZ_SHA}" \
        "${LIB_DIR}/openzeppelin-contracts" "OpenZeppelin contracts"
fi

if [[ ! -d "${LIB_DIR}/forge-std" ]]; then
    vendor_commit "${FS_REPO}" "${FS_TAG}" "${FS_SHA}" \
        "${LIB_DIR}/forge-std" "forge-std"
fi

echo "Vendored dependencies are up to date."
echo "  ${LIB_DIR}/openzeppelin-contracts (${OZ_TAG} @ ${OZ_SHA})"
echo "  ${LIB_DIR}/forge-std (${FS_TAG} @ ${FS_SHA})"
