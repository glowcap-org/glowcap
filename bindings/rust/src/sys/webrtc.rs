//! Raw FFI for the WebRTC transport archive
//! (`libpancake_net_transport_webrtc`).
//!
//! Linked only with the `webrtc` feature (ADR-0089/ADR-0059). Like the iroh
//! companion this is a dynamic library that links a Rust sidecar; it exports
//! only the `pancake_webrtc_*` family and its own thread-local last-error
//! (`pancake_webrtc_last_error`), sharing no core symbol. The shared vocabulary
//! it speaks is reused by layout from [`crate::sys`].
//!
//! `unused_imports` is allowed on the re-export below: the `pancake_webrtc_*`
//! externs are this transport's public surface, unused inside the binding until
//! a consumer drives them, the same as any not-yet-called FFI family.
#![allow(dead_code, unused_imports)]

use super::layouts_gen::*;

#[repr(C)]
pub struct PancakeWebrtcNetlayer {
	_private: [u8; 0],
}

/// One WebRTC peer: its `RTCPeerConnection` and single reliable, ordered data
/// channel. Opaque; the C ABI hands back a pointer to it, released with
/// `pancake_webrtc_peer_release`.
#[repr(C)]
pub struct PancakeWebrtcPeer {
	_private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeWebrtcConfig {
	pub ice_servers: *const u8,
	pub ice_servers_len: usize,
	pub include_loopback_candidates: u32,
	pub worker_threads: u32,
}

pub const PANCAKE_WEBRTC_EV_OPEN: u32 = crate::abi_constants_gen::WEBRTC_EV_OPEN;
pub const PANCAKE_WEBRTC_EV_CANDIDATE: u32 = crate::abi_constants_gen::WEBRTC_EV_CANDIDATE;
pub const PANCAKE_WEBRTC_EV_READABLE: u32 = crate::abi_constants_gen::WEBRTC_EV_READABLE;
pub const PANCAKE_WEBRTC_EV_WRITABLE: u32 = crate::abi_constants_gen::WEBRTC_EV_WRITABLE;
pub const PANCAKE_WEBRTC_EV_CLOSED: u32 = crate::abi_constants_gen::WEBRTC_EV_CLOSED;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeWebrtcReadyEvent {
	pub subject: usize,
	pub events: u32,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeWebrtcConfig>() == PANCAKE_WEBRTC_CONFIG_SIZE);
	assert!(offset_of!(PancakeWebrtcConfig, ice_servers) == PANCAKE_WEBRTC_CONFIG_ICE_SERVERS_OFF);
	assert!(
		offset_of!(PancakeWebrtcConfig, ice_servers_len)
			== PANCAKE_WEBRTC_CONFIG_ICE_SERVERS_LEN_OFF
	);
	assert!(
		offset_of!(PancakeWebrtcConfig, include_loopback_candidates)
			== PANCAKE_WEBRTC_CONFIG_INCLUDE_LOOPBACK_CANDIDATES_OFF
	);
	assert!(
		offset_of!(PancakeWebrtcConfig, worker_threads) == PANCAKE_WEBRTC_CONFIG_WORKER_THREADS_OFF
	);
	assert!(size_of::<PancakeWebrtcReadyEvent>() == PANCAKE_WEBRTC_READY_EVENT_SIZE);
	assert!(offset_of!(PancakeWebrtcReadyEvent, subject) == PANCAKE_WEBRTC_READY_EVENT_SUBJECT_OFF);
	assert!(offset_of!(PancakeWebrtcReadyEvent, events) == PANCAKE_WEBRTC_READY_EVENT_EVENTS_OFF);
};

// The raw extern block is generated (`webrtc_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`), reflected from the archive's symbol inventory and
// signatures, so it cannot drift from the C ABI.
pub use super::webrtc_fns_gen::*;
