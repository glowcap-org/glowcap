//! Raw FFI for `libpancake_net_transport_relay`.
//!
//! The archive owns one provider runtime for both `keyed-relay` and
//! `noise-relay`. It exposes no connection handles: the generic driver owns
//! multiplexed readiness and session lifetime after provider installation.
#![allow(dead_code)]

use super::layouts_gen::*;

#[repr(C)]
pub struct PancakeRelayRuntime {
	_private: [u8; 0],
}

pub const PANCAKE_RELAY_CONFIG_ABI_VERSION: u32 = crate::abi_constants_gen::RELAY_CONFIG_ABI_VERSION;
pub const PANCAKE_RELAY_TRUST_SYSTEM: u32 = crate::abi_constants_gen::RELAY_TRUST_SYSTEM;
pub const PANCAKE_RELAY_TRUST_COPIED_PEM: u32 = crate::abi_constants_gen::RELAY_TRUST_COPIED_PEM;

/// Configuration copied by the relay archive during construction.
#[repr(C)]
pub struct PancakeRelayConfig {
	pub abi_version: u32,
	pub struct_size: usize,
	pub relay_url: *const u8,
	pub relay_url_len: usize,
	pub register_url: *const u8,
	pub register_url_len: usize,
	pub trust: u32,
	pub trust_pem: *const u8,
	pub trust_pem_len: usize,
}

#[repr(C)]
#[derive(Default)]
pub struct PancakeRelayTrustSummary {
	pub loaded: usize,
	pub skipped_by_engine: usize,
	pub first_skipped_engine_code: i32,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeRelayConfig>() == PANCAKE_RELAY_CONFIG_SIZE);
	assert!(offset_of!(PancakeRelayConfig, abi_version) == PANCAKE_RELAY_CONFIG_ABI_VERSION_OFF);
	assert!(offset_of!(PancakeRelayConfig, struct_size) == PANCAKE_RELAY_CONFIG_STRUCT_SIZE_OFF);
	assert!(offset_of!(PancakeRelayConfig, relay_url) == PANCAKE_RELAY_CONFIG_RELAY_URL_OFF);
	assert!(offset_of!(PancakeRelayConfig, relay_url_len) == PANCAKE_RELAY_CONFIG_RELAY_URL_LEN_OFF);
	assert!(offset_of!(PancakeRelayConfig, register_url) == PANCAKE_RELAY_CONFIG_REGISTER_URL_OFF);
	assert!(offset_of!(PancakeRelayConfig, register_url_len) == PANCAKE_RELAY_CONFIG_REGISTER_URL_LEN_OFF);
	assert!(offset_of!(PancakeRelayConfig, trust) == PANCAKE_RELAY_CONFIG_TRUST_OFF);
	assert!(offset_of!(PancakeRelayConfig, trust_pem) == PANCAKE_RELAY_CONFIG_TRUST_PEM_OFF);
	assert!(offset_of!(PancakeRelayConfig, trust_pem_len) == PANCAKE_RELAY_CONFIG_TRUST_PEM_LEN_OFF);
	assert!(size_of::<PancakeRelayTrustSummary>() == PANCAKE_RELAY_TRUST_SUMMARY_SIZE);
	assert!(offset_of!(PancakeRelayTrustSummary, loaded) == PANCAKE_RELAY_TRUST_SUMMARY_LOADED_OFF);
	assert!(
		offset_of!(PancakeRelayTrustSummary, skipped_by_engine) == PANCAKE_RELAY_TRUST_SUMMARY_SKIPPED_BY_ENGINE_OFF
	);
	assert!(
		offset_of!(PancakeRelayTrustSummary, first_skipped_engine_code)
			== PANCAKE_RELAY_TRUST_SUMMARY_FIRST_SKIPPED_ENGINE_CODE_OFF
	);
};

// The raw extern block is generated (`relay_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`) and re-exported here so the archive boundary remains
// visible as `sys::relay::pancake_relay_*`.
pub use super::relay_fns_gen::*;
