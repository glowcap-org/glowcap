//! Raw FFI for `libpancake_net_transport_relay`.
//!
//! The archive owns one provider runtime for both `keyed-relay` and
//! `noise-relay`. It exposes no connection handles: the generic driver owns
//! multiplexed readiness and session lifetime after provider installation.
#![allow(dead_code)]

#[repr(C)]
pub struct PancakeRelayRuntime {
	_private: [u8; 0],
}

/// Configuration copied by the relay archive during construction.
#[repr(C)]
#[derive(Default)]
pub struct PancakeRelayConfig {
	pub relay_url: *const u8,
	pub relay_url_len: usize,
	pub register_url: *const u8,
	pub register_url_len: usize,
}

// The raw extern block is generated (`relay_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`) and re-exported here so the archive boundary remains
// visible as `sys::relay::pancake_relay_*`.
pub use super::relay_fns_gen::*;
