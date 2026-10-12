//! Raw FFI for the WebRTC transport archive
//! (`libglowcap_net_transport_webrtc`).
//!
//! Linked only with the `webrtc` feature (ADR-0089/ADR-0059). Like the iroh
//! companion this is a dynamic library that links a Rust sidecar. It exports
//! only the `glowcap_webrtc_*` family and its own thread-local last-error
//! (`glowcap_webrtc_last_error`), sharing no core symbol. The shared vocabulary
//! it speaks is reused by layout from [`crate::sys`].
//!
//! `unused_imports` is allowed on the re-export below: the `glowcap_webrtc_*`
//! externs are this transport's public surface, unused inside the binding until
//! a consumer drives them, the same as any not-yet-called FFI family.
#![allow(dead_code, unused_imports)]

use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapWebrtcNetlayer {
	_private: [u8; 0],
}

/// One WebRTC peer: its `RTCPeerConnection` and single reliable, ordered data
/// channel. Opaque. The C ABI hands back a pointer to it, released with
/// `glowcap_webrtc_peer_release`.
#[repr(C)]
pub struct GlowcapWebrtcPeer {
	_private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcStringView {
	pub ptr: *const u8,
	pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcIceServer {
	pub urls: *const GlowcapWebrtcStringView,
	pub url_count: usize,
	pub username: GlowcapWebrtcStringView,
	pub credential: GlowcapWebrtcStringView,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcConfig {
	pub ice_servers: *const GlowcapWebrtcIceServer,
	pub ice_server_count: usize,
	pub include_loopback_candidates: u32,
	pub worker_threads: u32,
}

pub const GLOWCAP_WEBRTC_EV_OPEN: u32 = crate::abi_constants_gen::WEBRTC_EV_OPEN;
pub const GLOWCAP_WEBRTC_EV_CANDIDATE: u32 = crate::abi_constants_gen::WEBRTC_EV_CANDIDATE;
pub const GLOWCAP_WEBRTC_EV_READABLE: u32 = crate::abi_constants_gen::WEBRTC_EV_READABLE;
pub const GLOWCAP_WEBRTC_EV_WRITABLE: u32 = crate::abi_constants_gen::WEBRTC_EV_WRITABLE;
pub const GLOWCAP_WEBRTC_EV_CLOSED: u32 = crate::abi_constants_gen::WEBRTC_EV_CLOSED;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcReadyEvent {
	pub subject: usize,
	pub events: u32,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapWebrtcStringView>() == GLOWCAP_WEBRTC_STRING_VIEW_SIZE);
	assert!(offset_of!(GlowcapWebrtcStringView, ptr) == GLOWCAP_WEBRTC_STRING_VIEW_PTR_OFF);
	assert!(offset_of!(GlowcapWebrtcStringView, len) == GLOWCAP_WEBRTC_STRING_VIEW_LEN_OFF);
	assert!(size_of::<GlowcapWebrtcIceServer>() == GLOWCAP_WEBRTC_ICE_SERVER_SIZE);
	assert!(offset_of!(GlowcapWebrtcIceServer, urls) == GLOWCAP_WEBRTC_ICE_SERVER_URLS_OFF);
	assert!(offset_of!(GlowcapWebrtcIceServer, url_count) == GLOWCAP_WEBRTC_ICE_SERVER_URL_COUNT_OFF);
	assert!(offset_of!(GlowcapWebrtcIceServer, username) == GLOWCAP_WEBRTC_ICE_SERVER_USERNAME_OFF);
	assert!(offset_of!(GlowcapWebrtcIceServer, credential) == GLOWCAP_WEBRTC_ICE_SERVER_CREDENTIAL_OFF);
	assert!(size_of::<GlowcapWebrtcConfig>() == GLOWCAP_WEBRTC_CONFIG_SIZE);
	assert!(offset_of!(GlowcapWebrtcConfig, ice_servers) == GLOWCAP_WEBRTC_CONFIG_ICE_SERVERS_OFF);
	assert!(offset_of!(GlowcapWebrtcConfig, ice_server_count) == GLOWCAP_WEBRTC_CONFIG_ICE_SERVER_COUNT_OFF);
	assert!(
		offset_of!(GlowcapWebrtcConfig, include_loopback_candidates)
			== GLOWCAP_WEBRTC_CONFIG_INCLUDE_LOOPBACK_CANDIDATES_OFF
	);
	assert!(offset_of!(GlowcapWebrtcConfig, worker_threads) == GLOWCAP_WEBRTC_CONFIG_WORKER_THREADS_OFF);
	assert!(size_of::<GlowcapWebrtcReadyEvent>() == GLOWCAP_WEBRTC_READY_EVENT_SIZE);
	assert!(offset_of!(GlowcapWebrtcReadyEvent, subject) == GLOWCAP_WEBRTC_READY_EVENT_SUBJECT_OFF);
	assert!(offset_of!(GlowcapWebrtcReadyEvent, events) == GLOWCAP_WEBRTC_READY_EVENT_EVENTS_OFF);
};

// The raw extern block is generated (`webrtc_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`), reflected from the archive's symbol inventory and
// signatures, so it cannot drift from the C ABI.
pub use super::webrtc_fns_gen::*;
