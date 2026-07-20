//! Raw FFI for the TCP transport archive (`libpancake_net_transport_tcp`).
//!
//! Linked only with the `tcp` feature (ADR-0059). It exports the
//! `pancake_tcp_*` family and its own thread-local last-error
//! (`pancake_tcp_last_error`), symbol-disjoint from the core archive; the
//! shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

#[repr(C)]
pub struct PancakeTcpNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct PancakeTcpConn {
	_private: [u8; 0],
}
#[repr(C)]
pub struct PancakeTcpListener {
	_private: [u8; 0],
}

// The raw extern block is generated (`tcp_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::tcp::pancake_tcp_*` paths.
pub use super::tcp_fns_gen::*;
