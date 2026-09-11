//! Raw native WebRTC companion ABI (`webrtc` feature).
//!
//! Native bindings intentionally expose this archive at its multiplexed
//! readiness and try-I/O boundary. The Rust browser adapter lives in
//! `browser::RtcPeer` and calls the browser's WebRTC implementation. Applications
//! supply their signaling authority to either backend. All functions here are unsafe C calls and return
//! glowcap result codes exactly as declared in `glowcap_net_transport_webrtc.h`.

pub use crate::sys::webrtc::*;
pub use crate::sys::GlowcapTransportProvider;
