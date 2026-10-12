//! Raw FFI for `libglowcap_net_transport_relay`.
//!
//! The archive owns one provider runtime for both `keyed-relay` and
//! `noise-relay`. It exposes no connection handles: the generic driver owns
//! multiplexed readiness and session lifetime after provider installation.
#![allow(dead_code)]

use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapRelayRuntime {
	_private: [u8; 0],
}

pub const GLOWCAP_RELAY_CONFIG_ABI_VERSION: u32 = crate::abi_constants_gen::RELAY_CONFIG_ABI_VERSION;
pub const GLOWCAP_RELAY_TRUST_SYSTEM: u32 = crate::abi_constants_gen::RELAY_TRUST_SYSTEM;
pub const GLOWCAP_RELAY_TRUST_COPIED_PEM: u32 = crate::abi_constants_gen::RELAY_TRUST_COPIED_PEM;

/// Configuration copied by the relay archive during construction.
#[repr(C)]
pub struct GlowcapRelayConfig {
	pub abi_version: u32,
	pub struct_size: usize,
	pub relay_url: *const u8,
	pub relay_url_len: usize,
	pub register_url: *const u8,
	pub register_url_len: usize,
	pub trust: u32,
	pub trust_pem: *const u8,
	pub trust_pem_len: usize,
	pub relay_alias_url: *const u8,
	pub relay_alias_url_len: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapRelayConfig>() == GLOWCAP_RELAY_CONFIG_SIZE);
	assert!(offset_of!(GlowcapRelayConfig, abi_version) == GLOWCAP_RELAY_CONFIG_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapRelayConfig, struct_size) == GLOWCAP_RELAY_CONFIG_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapRelayConfig, relay_url) == GLOWCAP_RELAY_CONFIG_RELAY_URL_OFF);
	assert!(offset_of!(GlowcapRelayConfig, relay_url_len) == GLOWCAP_RELAY_CONFIG_RELAY_URL_LEN_OFF);
	assert!(offset_of!(GlowcapRelayConfig, register_url) == GLOWCAP_RELAY_CONFIG_REGISTER_URL_OFF);
	assert!(offset_of!(GlowcapRelayConfig, register_url_len) == GLOWCAP_RELAY_CONFIG_REGISTER_URL_LEN_OFF);
	assert!(offset_of!(GlowcapRelayConfig, trust) == GLOWCAP_RELAY_CONFIG_TRUST_OFF);
	assert!(offset_of!(GlowcapRelayConfig, trust_pem) == GLOWCAP_RELAY_CONFIG_TRUST_PEM_OFF);
	assert!(offset_of!(GlowcapRelayConfig, trust_pem_len) == GLOWCAP_RELAY_CONFIG_TRUST_PEM_LEN_OFF);
	assert!(offset_of!(GlowcapRelayConfig, relay_alias_url) == GLOWCAP_RELAY_CONFIG_RELAY_ALIAS_URL_OFF);
	assert!(offset_of!(GlowcapRelayConfig, relay_alias_url_len) == GLOWCAP_RELAY_CONFIG_RELAY_ALIAS_URL_LEN_OFF);
};

// The raw extern block is generated (`relay_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`) and re-exported here so the archive boundary remains
// visible as `sys::relay::glowcap_relay_*`.
pub use super::relay_fns_gen::*;
