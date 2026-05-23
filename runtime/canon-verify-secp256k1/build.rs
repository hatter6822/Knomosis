// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Build script for `knomosis-verify-secp256k1`.
//!
//! Compiles the small C shim that bridges Lean's `lean_object *`
//! argument convention to the Rust verification core.  The shim
//! requires `lean.h` to be available on the build host; if not
//! found, the build prints a `cargo:warning=` line and skips the
//! shim — the rlib and staticlib still build, but the cdylib will
//! not export `canon_verify_ecdsa`.
//!
//! Discovery order (first hit wins):
//!
//!   1. `LEAN_INCLUDE_DIR` env var (explicit override).
//!   2. `LEAN_SYSROOT` env var with `include/` appended.
//!   3. `lean --print-prefix` shell-out, with `include/` appended.
//!   4. None — emit a warning and skip the shim build (unless
//!      the `lean-ffi` feature is enabled, in which case fail
//!      the build).

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    // Re-run if the discovery inputs change.
    println!("cargo:rerun-if-env-changed=LEAN_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=LEAN_SYSROOT");
    println!("cargo:rerun-if-changed=c/lean_shim.c");
    println!("cargo:rerun-if-changed=build.rs");

    let include_dir = locate_lean_include();
    let force_ffi = env::var("CARGO_FEATURE_LEAN_FFI").is_ok();

    if let Some(include) = include_dir {
        // Build the C shim into a static archive.  The shim
        // contains non-inline wrappers around `lean.h`'s
        // `static inline` API (so Rust can call them via
        // `extern "C"`); the actual Lean ABI entry point
        // `canon_verify_ecdsa` is defined in Rust
        // (`src/verify.rs`) so rustc's cdylib export discipline
        // keeps the symbol in the dynamic-symbol table.
        cc::Build::new()
            .file("c/lean_shim.c")
            .include(&include)
            // `-fPIC` is required for inclusion in a cdylib.
            // Most platforms default to PIC for libraries; this
            // is belt-and-suspenders for the few that don't.
            .flag_if_supported("-fPIC")
            // Strict warnings on the shim's own code; we do
            // NOT enable `-Wpedantic` because Lean's `lean.h`
            // legitimately uses gcc/clang-flavoured extensions
            // (e.g. trailing `;` after the `LEAN_CASSERT`
            // macro) that fail ISO-pedantic.  `-Wall -Wextra`
            // catches the relevant bug classes in the shim
            // (uninitialised reads, sign-mismatched casts,
            // missing-prototype calls) without bleeding into
            // the upstream header.
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror")
            .compile("canon_verify_ecdsa_shim");

        // Communicate the success back to `src/lib.rs` via a
        // cfg flag so the crate's module-level docstring and
        // any conditional code can react.
        println!("cargo:rustc-cfg=canon_lean_ffi");
        // Mark the cfg as known so rustc doesn't lint it as
        // unexpected on Rust ≥ 1.80.
        println!("cargo:rustc-check-cfg=cfg(canon_lean_ffi)");
    } else {
        assert!(
            !force_ffi,
            "knomosis-verify-secp256k1: `lean-ffi` feature requested but Lean's \
             include directory could not be located.  Set LEAN_INCLUDE_DIR or \
             ensure `lean` is on PATH so `lean --print-prefix` resolves."
        );
        println!(
            "cargo:warning=knomosis-verify-secp256k1: Lean include dir not found; \
             C ABI shim NOT built.  Set LEAN_INCLUDE_DIR to enable the cdylib's \
             `canon_verify_ecdsa` symbol export."
        );
        // Still mark the cfg name as known so #[cfg(canon_lean_ffi)] elsewhere
        // doesn't emit an unexpected-cfg warning on Rust ≥ 1.80.
        println!("cargo:rustc-check-cfg=cfg(canon_lean_ffi)");
    }
}

/// Locate Lean's C header include directory.
///
/// Returns `Some(path)` if any of the discovery strategies hits;
/// `None` otherwise.  The returned path is the directory the
/// C compiler should pass to `-I` so `#include <lean/lean.h>`
/// resolves: i.e. the parent of `lean/`, not `lean/` itself.
fn locate_lean_include() -> Option<PathBuf> {
    // Helper: given a candidate directory `p`, check whether
    // `lean.h` is reachable via either layout:
    //   * `<p>/lean/lean.h` — standard install (return `p`).
    //   * `<p>/lean.h` — user passed the inner `lean/` dir
    //     directly (return `p.parent()` so `<parent>/lean/lean.h`
    //     resolves `#include <lean/lean.h>`).
    //
    // Returns `None` if neither layout matches.
    fn validate(p: PathBuf) -> Option<PathBuf> {
        if p.join("lean").join("lean.h").is_file() {
            return Some(p);
        }
        if p.join("lean.h").is_file() {
            // User pointed at `.../include/lean/` directly; back
            // up one level so the compiler's include search
            // resolves `#include <lean/lean.h>` correctly.
            return p.parent().map(PathBuf::from);
        }
        None
    }

    if let Ok(dir) = env::var("LEAN_INCLUDE_DIR") {
        if let Some(p) = validate(PathBuf::from(dir)) {
            return Some(p);
        }
    }
    if let Ok(sysroot) = env::var("LEAN_SYSROOT") {
        let p = PathBuf::from(sysroot).join("include");
        if p.join("lean").join("lean.h").is_file() {
            return Some(p);
        }
    }
    // Shell out to `lean --print-prefix`.  Non-fatal if `lean` is
    // not on PATH or the command fails for any reason.
    if let Ok(out) = Command::new("lean").arg("--print-prefix").output() {
        if out.status.success() {
            if let Ok(s) = std::str::from_utf8(&out.stdout) {
                let prefix = s.trim();
                if !prefix.is_empty() {
                    let p = PathBuf::from(prefix).join("include");
                    if p.join("lean").join("lean.h").is_file() {
                        return Some(p);
                    }
                }
            }
        }
    }
    None
}
