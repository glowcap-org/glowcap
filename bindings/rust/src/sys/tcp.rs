//! Raw FFI for the TCP transport archive (`libglowcap_net_transport_tcp`).
//!
//! Linked only with the `tcp` feature (ADR-0059). It exports the
//! `glowcap_tcp_*` family and its own thread-local last-error
//! (`glowcap_tcp_last_error`), symbol-disjoint from the core archive. The
//! shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

use super::layouts_gen::*;
#[cfg(feature = "async")]
pub use super::layouts_gen::{GLOWCAP_TCP_OPERATION_OPTIONS_SIZE, GLOWCAP_TCP_OPERATION_OPTIONS_STREAM_OFF};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct GlowcapTcpStreamOptions {
	pub keepalive_idle_sec: u32,
	pub keepalive_interval_sec: u32,
	pub keepalive_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct GlowcapTcpConfig {
	pub stream: GlowcapTcpStreamOptions,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapTcpStreamOptions>() == GLOWCAP_TCP_STREAM_OPTIONS_SIZE);
	assert!(
		offset_of!(GlowcapTcpStreamOptions, keepalive_idle_sec) == GLOWCAP_TCP_STREAM_OPTIONS_KEEPALIVE_IDLE_SEC_OFF
	);
	assert!(
		offset_of!(GlowcapTcpStreamOptions, keepalive_interval_sec)
			== GLOWCAP_TCP_STREAM_OPTIONS_KEEPALIVE_INTERVAL_SEC_OFF
	);
	assert!(offset_of!(GlowcapTcpStreamOptions, keepalive_count) == GLOWCAP_TCP_STREAM_OPTIONS_KEEPALIVE_COUNT_OFF);
	assert!(size_of::<GlowcapTcpConfig>() == GLOWCAP_TCP_CONFIG_SIZE);
	assert!(offset_of!(GlowcapTcpConfig, stream) == GLOWCAP_TCP_CONFIG_STREAM_OFF);
};

#[repr(C)]
pub struct GlowcapTcpNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapTcpConn {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapTcpListener {
	_private: [u8; 0],
}

// The raw extern block is generated (`tcp_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::tcp::glowcap_tcp_*` paths.
pub use super::tcp_fns_gen::*;
