//! Raw FFI for the in-process transport archive
//! (`libglowcap_net_transport_inproc`).
//!
//! Linked only with the `inproc` feature (ADR-0059). It exports the
//! `glowcap_inproc_*` family and its own thread-local last-error
//! (`glowcap_inproc_last_error`), symbol-disjoint from the core archive. The
//! shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

#[repr(C)]
pub struct GlowcapInprocNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapInprocConn {
	_private: [u8; 0],
}
#[repr(C)]
pub struct GlowcapInprocListener {
	_private: [u8; 0],
}

// The raw extern block is generated (`inproc_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::inproc::glowcap_inproc_*` paths.
pub use super::inproc_fns_gen::*;
