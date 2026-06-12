// SPDX-License-Identifier: MIT
//! ABI-export / constructor-introspection bin target.
//!
//! This file exists for one reason: `cargo stylus deploy` (and `cargo stylus export-abi` /
//! `cargo stylus constructor`) shell out to `cargo run --features export-abi` to introspect the
//! contract's Solidity ABI and constructor. `cargo run` requires a bin target, but the deployed
//! artifact is a `cdylib` (the on-chain WASM) plus a `lib` (for `cargo test`). Without a bin, the
//! deploy aborts with "a bin target must be available for `cargo run`".
//!
//! The bin is inert in every build except `--features export-abi`:
//! - plain `cargo test` (no features): `no_main`, empty `main` body never referenced.
//! - `--features stylus` (the cdylib WASM build): `no_main`; the on-chain entrypoint is the
//!   SDK-generated `user_entrypoint` in the cdylib, not this `main`.
//! - `--features export-abi`: a real `main` that calls the `#[entrypoint]`-generated
//!   `print_from_args` associated fn on the contract struct, printing the Solidity ABI.
//!
//! Because this only adds a bin under `export-abi`, it cannot change the deployed WASM (verified by
//! `cargo stylus check --features stylus` still reporting the same 17.3 KB artifact) and cannot
//! affect `cargo test` (which builds neither this bin's real body nor the stylus-sdk).

#![cfg_attr(not(feature = "export-abi"), no_main)]

#[cfg(feature = "export-abi")]
fn main() {
    // `print_from_args` is a free fn the `#[public]` macro emits into the `stylus_entrypoint`
    // module (under `export-abi`); it prints the contract's Solidity ABI.
    stratum_stylus::stylus_entrypoint::print_from_args();
}
