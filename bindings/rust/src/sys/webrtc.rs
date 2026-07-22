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

/// One WebRTC peer: its `RTCPeerConnection` and single reliable, ordered data
/// channel. Opaque; the C ABI hands back a pointer to it, released with
/// `pancake_webrtc_peer_release`.
#[repr(C)]
pub struct PancakeWebrtcPeer {
	_private: [u8; 0],
}

// The raw extern block is generated (`webrtc_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`), reflected from the archive's symbol inventory and
// signatures, so it cannot drift from the C ABI.
pub use super::webrtc_fns_gen::*;
