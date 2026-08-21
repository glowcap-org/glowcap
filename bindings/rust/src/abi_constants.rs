//! Private ABI constants for the Rust binding.
//!
//! Reflected ABI constants, model-owned transport vocabulary, and shared
//! binding policy are generated into `abi_constants_gen` and re-exported here.
//! `zig build gen-binding-constants-check` rejects stale mirrors.

#![allow(dead_code)]

pub use crate::abi_constants_gen::*;

/// Cycle break message when a local Forward chain exceeds the hop cap.
pub const FORWARD_CYCLE_MESSAGE: &str = "forward cycle: the local forward chain never terminates";
