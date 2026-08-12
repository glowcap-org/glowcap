//! Private ABI constants for the Rust binding.
//!
//! The reflected integer families (return codes, reference and argument kinds,
//! codec, abort domains, the dial plan, and the caps) are generated into
//! `abi_constants_gen` from the C ABI and re-exported here, so a value is
//! mirrored once and `zig build gen-binding-constants-check` rejects a stale
//! copy. Transport and locator-hint strings are generated from
//! `model.transport` in the same file.

#![allow(dead_code)]

pub use crate::abi_constants_gen::*;

/// Cycle break message when a local Forward chain exceeds the hop cap.
pub const FORWARD_CYCLE_MESSAGE: &str = "forward cycle: the local forward chain never terminates";
