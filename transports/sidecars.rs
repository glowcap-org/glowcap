//! Retain the selected C entry points in one Rust static library. Cargo unifies
//! their dependency features and links a single copy of the Rust runtime.

#[cfg(feature = "iroh")]
pub use iroh_sidecar::*;
#[cfg(feature = "webrtc")]
pub use webrtc_sidecar::*;
