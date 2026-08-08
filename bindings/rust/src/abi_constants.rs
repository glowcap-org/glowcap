//! Private ABI constants for the Rust binding.
//!
//! The reflected integer families (return codes, reference and argument kinds,
//! codec, abort domains, the dial plan, and the caps) are generated into
//! `abi_constants_gen` from the C ABI and re-exported here, so a value is
//! mirrored once and `zig build gen-binding-constants-check` rejects a stale
//! copy. This module adds the transport string symbols, which mirror
//! `model.transport` (a different authority, guarded by `meta-check`
//! name-presence) rather than a `pancake_*.h` value.

#![allow(dead_code)]

pub use crate::abi_constants_gen::*;

/// Locator hint name; mirrors `model.transport.hint_direct_addresses`.
pub const HINT_DIRECT_ADDRESSES: &str = "direct-addresses";

/// Cycle break message when a local Forward chain exceeds the hop cap.
pub const FORWARD_CYCLE_MESSAGE: &str = "forward cycle: the local forward chain never terminates";

/// OCapN transport symbols; mirrors `model.transport.*`.
pub const TRANSPORT_TCP: &str = "tcp";
pub const TRANSPORT_KEYED_TCP: &str = "keyed-tcp";
pub const TRANSPORT_INPROC: &str = "inproc";
pub const TRANSPORT_IROH: &str = "iroh";
pub const TRANSPORT_KEYED_RELAY: &str = "keyed-relay";
pub const TRANSPORT_WEBRTC: &str = "webrtc";
