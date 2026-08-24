//! Raw native WebRTC companion ABI (`webrtc` feature).
//!
//! Native bindings intentionally expose this archive at its multiplexed
//! readiness and try-I/O boundary; the browser TypeScript package owns the
//! application-level adapter. All functions here are unsafe C calls and return
//! pancake result codes exactly as declared in `pancake_net_transport_webrtc.h`.

pub use crate::sys::webrtc::*;
pub use crate::sys::PancakeTransportProvider;
