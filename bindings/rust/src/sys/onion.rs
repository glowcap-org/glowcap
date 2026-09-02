//! Raw FFI for the onion transport archive
//! (`libglowcap_net_transport_onion`).
//!
//! Linked only with the `onion` feature (ADR-0059). It exports the
//! `glowcap_onion_*` family and its own thread-local last-error
//! (`glowcap_onion_last_error`), symbol-disjoint from the core archive; the
//! shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapOnionNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapOnionConn {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapOnionListener {
	_private: [u8; 0],
}

/// How the netlayer reaches Tor, and what it asks for when hosting.
///
/// The layout mirrors `GlowcapOnionConfig` in
/// `src/c_abi/net_transport/onion/contract.zig`, whose declaration documents every
/// field. Zero-initialize and set what you use: [`Default`] gives the
/// all-zero form, so a field added later reads as absent rather than as
/// stack contents.
///
/// Every pointer is borrowed for the constructor call only. The netlayer copies
/// the text it needs, so the caller may free its own buffers afterwards.
#[repr(C)]
#[derive(Default)]
pub struct GlowcapOnionConfig {
	pub socks: *const u8,
	pub socks_len: usize,
	pub control_endpoint: *const u8,
	pub control_endpoint_len: usize,
	pub auth_kind: core::ffi::c_uint,
	pub auth_secret: *const u8,
	pub auth_secret_len: usize,
	pub service_key: *const u8,
	pub service_key_len: usize,
	pub forward: *const u8,
	pub forward_len: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapOnionConfig>() == GLOWCAP_ONION_CONFIG_SIZE);
	assert!(offset_of!(GlowcapOnionConfig, socks) == GLOWCAP_ONION_CONFIG_SOCKS_OFF);
	assert!(offset_of!(GlowcapOnionConfig, socks_len) == GLOWCAP_ONION_CONFIG_SOCKS_LEN_OFF);
	assert!(offset_of!(GlowcapOnionConfig, control_endpoint) == GLOWCAP_ONION_CONFIG_CONTROL_ENDPOINT_OFF);
	assert!(offset_of!(GlowcapOnionConfig, control_endpoint_len) == GLOWCAP_ONION_CONFIG_CONTROL_ENDPOINT_LEN_OFF);
	assert!(offset_of!(GlowcapOnionConfig, auth_kind) == GLOWCAP_ONION_CONFIG_AUTH_KIND_OFF);
	assert!(offset_of!(GlowcapOnionConfig, auth_secret) == GLOWCAP_ONION_CONFIG_AUTH_SECRET_OFF);
	assert!(offset_of!(GlowcapOnionConfig, auth_secret_len) == GLOWCAP_ONION_CONFIG_AUTH_SECRET_LEN_OFF);
	assert!(offset_of!(GlowcapOnionConfig, service_key) == GLOWCAP_ONION_CONFIG_SERVICE_KEY_OFF);
	assert!(offset_of!(GlowcapOnionConfig, service_key_len) == GLOWCAP_ONION_CONFIG_SERVICE_KEY_LEN_OFF);
	assert!(offset_of!(GlowcapOnionConfig, forward) == GLOWCAP_ONION_CONFIG_FORWARD_OFF);
	assert!(offset_of!(GlowcapOnionConfig, forward_len) == GLOWCAP_ONION_CONFIG_FORWARD_LEN_OFF);
};

/// An unauthenticated control endpoint, the form a Unix control socket with no
/// authentication gives and the one upstream Goblins assumes.
pub const ONION_AUTH_NONE: core::ffi::c_uint = crate::abi_constants_gen::ONION_AUTH_NONE;
/// Authenticate with the bytes of the file `CookieAuthFile` names, sent as
/// hexadecimal. The common default on a distribution's Tor package.
pub const ONION_AUTH_COOKIE: core::ffi::c_uint = crate::abi_constants_gen::ONION_AUTH_COOKIE;
/// Authenticate with the cleartext of a `HashedControlPassword` setup.
pub const ONION_AUTH_PASSWORD: core::ffi::c_uint = crate::abi_constants_gen::ONION_AUTH_PASSWORD;

/// A version 3 onion service id is always exactly this many characters.
pub const ONION_SERVICE_ID_LEN: usize = crate::abi_constants_gen::ONION_SERVICE_ID_LEN;
/// An upper bound on the private-key blob Tor returns for a fresh service.
pub const ONION_SERVICE_KEY_CAP: usize = crate::abi_constants_gen::ONION_SERVICE_KEY_CAP;

// The raw extern block is generated (`onion_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::onion::glowcap_onion_*` paths.
pub use super::onion_fns_gen::*;
