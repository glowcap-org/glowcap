//! Raw FFI for the WebRTC transport archive
//! (`libglowcap_net_transport_webrtc`).
//!
//! Linked only with the `webrtc` feature (ADR-0035/ADR-0022). Like the iroh
//! companion this is a dynamic library that links a Rust sidecar. It exports
//! only the `glowcap_webrtc_*` family and its own thread-local last-error
//! (`glowcap_webrtc_last_error`), sharing no core symbol. The shared vocabulary
//! it speaks is reused by layout from [`crate::sys`].
//!
//! `unused_imports` is allowed on the re-export below: the `glowcap_webrtc_*`
//! externs are this transport's public surface, unused inside the binding until
//! a consumer drives them, the same as any not-yet-called FFI family. status-allow: pending state or quoted runtime label
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

/// Carry one SDP offer to the peer `designator` names, for the dial
/// `exchange`. `introducer` is the designator of the session that handed over
/// the reference this dial follows, or null with a zero length. Return 0 to
/// accept. Any other value refuses the dial.
pub type GlowcapWebrtcSendOfferFn = unsafe extern "C" fn(
	ctx: *mut core::ffi::c_void,
	exchange: u64,
	designator: *const u8,
	designator_len: usize,
	introducer: *const u8,
	introducer_len: usize,
	sdp: *const u8,
	sdp_len: usize,
) -> i32;

/// Carry one SDP answer back to the offerer `designator` names, for the
/// accept `exchange` that `glowcap_webrtc_netlayer_provide_offer` returned.
/// Return 0 to accept. Any other value refuses the accept.
pub type GlowcapWebrtcSendAnswerFn = unsafe extern "C" fn(
	ctx: *mut core::ffi::c_void,
	exchange: u64,
	designator: *const u8,
	designator_len: usize,
	sdp: *const u8,
	sdp_len: usize,
) -> i32;

/// Carry one local ICE candidate, as JSON, for the `exchange`. Return 0 to
/// accept. Any other value fails the exchange.
pub type GlowcapWebrtcSendCandidateFn =
	unsafe extern "C" fn(ctx: *mut core::ffi::c_void, exchange: u64, ice: *const u8, ice_len: usize) -> i32;

/// The `exchange` is over: connected, failed, or cancelled.
pub type GlowcapWebrtcExchangeDoneFn = unsafe extern "C" fn(ctx: *mut core::ffi::c_void, exchange: u64);

/// How the application carries signaling for the exchanges a netlayer runs
/// on the driver's behalf. `send_offer` lets it dial and `send_answer` lets
/// it accept. All `None` means the netlayer runs no exchange. See the
/// header's `GlowcapWebrtcSignaling`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcSignaling {
	pub ctx: *mut core::ffi::c_void,
	pub send_offer: Option<GlowcapWebrtcSendOfferFn>,
	pub send_answer: Option<GlowcapWebrtcSendAnswerFn>,
	pub send_candidate: Option<GlowcapWebrtcSendCandidateFn>,
	pub done: Option<GlowcapWebrtcExchangeDoneFn>,
}

impl GlowcapWebrtcSignaling {
	/// No callbacks: a netlayer that runs no exchange.
	pub const NONE: Self = Self {
		ctx: core::ptr::null_mut(),
		send_offer: None,
		send_answer: None,
		send_candidate: None,
		done: None,
	};
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcConfig {
	pub ice_servers: *const GlowcapWebrtcIceServer,
	pub ice_server_count: usize,
	pub include_loopback_candidates: u32,
	pub worker_threads: u32,
	pub signaling: GlowcapWebrtcSignaling,
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
	assert!(size_of::<GlowcapWebrtcSignaling>() == GLOWCAP_WEBRTC_SIGNALING_SIZE);
	assert!(offset_of!(GlowcapWebrtcSignaling, ctx) == GLOWCAP_WEBRTC_SIGNALING_CTX_OFF);
	assert!(offset_of!(GlowcapWebrtcSignaling, send_offer) == GLOWCAP_WEBRTC_SIGNALING_SEND_OFFER_OFF);
	assert!(offset_of!(GlowcapWebrtcSignaling, send_answer) == GLOWCAP_WEBRTC_SIGNALING_SEND_ANSWER_OFF);
	assert!(offset_of!(GlowcapWebrtcSignaling, send_candidate) == GLOWCAP_WEBRTC_SIGNALING_SEND_CANDIDATE_OFF);
	assert!(offset_of!(GlowcapWebrtcSignaling, done) == GLOWCAP_WEBRTC_SIGNALING_DONE_OFF);
	assert!(size_of::<GlowcapWebrtcConfig>() == GLOWCAP_WEBRTC_CONFIG_SIZE);
	assert!(offset_of!(GlowcapWebrtcConfig, ice_servers) == GLOWCAP_WEBRTC_CONFIG_ICE_SERVERS_OFF);
	assert!(offset_of!(GlowcapWebrtcConfig, ice_server_count) == GLOWCAP_WEBRTC_CONFIG_ICE_SERVER_COUNT_OFF);
	assert!(
		offset_of!(GlowcapWebrtcConfig, include_loopback_candidates)
			== GLOWCAP_WEBRTC_CONFIG_INCLUDE_LOOPBACK_CANDIDATES_OFF
	);
	assert!(offset_of!(GlowcapWebrtcConfig, worker_threads) == GLOWCAP_WEBRTC_CONFIG_WORKER_THREADS_OFF);
	assert!(offset_of!(GlowcapWebrtcConfig, signaling) == GLOWCAP_WEBRTC_CONFIG_SIGNALING_OFF);
	assert!(size_of::<GlowcapWebrtcReadyEvent>() == GLOWCAP_WEBRTC_READY_EVENT_SIZE);
	assert!(offset_of!(GlowcapWebrtcReadyEvent, subject) == GLOWCAP_WEBRTC_READY_EVENT_SUBJECT_OFF);
	assert!(offset_of!(GlowcapWebrtcReadyEvent, events) == GLOWCAP_WEBRTC_READY_EVENT_EVENTS_OFF);
};

// The raw extern block is generated (`webrtc_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`), reflected from the archive's symbol inventory and
// signatures, so it cannot drift from the C ABI.
pub use super::webrtc_fns_gen::*;
