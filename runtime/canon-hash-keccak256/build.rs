// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Build script for `canon-hash-keccak256`.
//!
//! Mirrors `canon-verify-secp256k1/build.rs`: compiles the Lean
//! C ABI shim if `lean.h` is locatable.  Discovery order:
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
    println!("cargo:rerun-if-env-changed=LEAN_INCLUDE_DIR");
    println!("cargo:rerun-if-env-changed=LEAN_SYSROOT");
    println!("cargo:rerun-if-changed=c/lean_shim.c");
    println!("cargo:rerun-if-changed=build.rs");

    let include_dir = locate_lean_include();
    let force_ffi = env::var("CARGO_FEATURE_LEAN_FFI").is_ok();

    if let Some(include) = include_dir {
        // Build the C shim into a static archive.  See the
        // verify crate's `build.rs` for the rationale on why
        // the Lean ABI entry points live in Rust rather than
        // C (cdylib export discipline).
        cc::Build::new()
            .file("c/lean_shim.c")
            .include(&include)
            .flag_if_supported("-fPIC")
            // See `canon-verify-secp256k1/build.rs` for the
            // rationale on excluding `-Wpedantic`: Lean's
            // `lean.h` uses gcc/clang-flavoured extensions
            // that fail ISO-pedantic.
            .flag_if_supported("-Wall")
            .flag_if_supported("-Wextra")
            .flag_if_supported("-Werror")
            .compile("canon_hash_keccak256_shim");

        println!("cargo:rustc-cfg=canon_lean_ffi");
        println!("cargo:rustc-check-cfg=cfg(canon_lean_ffi)");
    } else {
        assert!(
            !force_ffi,
            "canon-hash-keccak256: `lean-ffi` feature requested but Lean's \
             include directory could not be located.  Set LEAN_INCLUDE_DIR or \
             ensure `lean` is on PATH so `lean --print-prefix` resolves."
        );
        println!(
            "cargo:warning=canon-hash-keccak256: Lean include dir not found; \
             C ABI shim NOT built.  Set LEAN_INCLUDE_DIR to enable the cdylib's \
             `canon_hash_bytes` / `canon_hash_stream` / `canon_hash_identifier` \
             symbol exports."
        );
        println!("cargo:rustc-check-cfg=cfg(canon_lean_ffi)");
    }
}

/// Locate Lean's C header include directory.  See
/// `canon-verify-secp256k1/build.rs::locate_lean_include` for the
/// full rationale; this mirror is kept identical so the two
/// adaptor crates discover `lean.h` identically.
fn locate_lean_include() -> Option<PathBuf> {
    fn validate(p: PathBuf) -> Option<PathBuf> {
        if p.join("lean").join("lean.h").is_file() {
            return Some(p);
        }
        if p.join("lean.h").is_file() {
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
