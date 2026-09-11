//! Private ABI constants for the Rust binding.
//!
//! Reflected ABI constants, model-owned transport vocabulary, and shared
//! binding policy are generated into `abi_constants_gen` and re-exported here.
//! `zig build gen-binding-constants-check` rejects stale mirrors.

#![allow(dead_code)]

pub use crate::abi_constants_gen::*;

#[cfg(target_arch = "wasm32")]
pub use crate::sys::layouts_gen::OCAPN_ARCHIVE_FINGERPRINT;

/// Cycle break message when a local Forward chain exceeds the hop cap.
pub const FORWARD_CYCLE_MESSAGE: &str = "forward cycle: the local forward chain never terminates";

#[cfg(all(target_arch = "wasm32", feature = "async"))]
pub use crate::sys::layouts_gen::HOST_ARCHIVE_FINGERPRINT;
