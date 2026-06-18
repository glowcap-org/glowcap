//! Raw FFI for the TCP transport archive (`libpancake_net_transport_tcp`).
//!
//! Linked only with the `tcp` feature (ADR-0059). It exports the
//! `pancake_tcp_*` family and its own thread-local last-error
//! (`pancake_tcp_last_error`), symbol-disjoint from the core archive; the
//! shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

use core::ffi::{c_int, c_uchar, c_uint};

use crate::sys::{PancakeContext, PancakeFrame, PancakeManagedFrame};

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

extern "C" {
	// The TCP transport archive carries its own thread-local last-error: a tcp
	// call's diagnostic is read through `pancake_tcp_last_error`, never the
	// ocapn family's `pancake_last_error`.
	pub fn pancake_tcp_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
	pub fn pancake_tcp_clear_last_error();
	pub fn pancake_tcp_netlayer_new(out: *mut *mut PancakeTcpNetlayer) -> c_int;
	pub fn pancake_tcp_netlayer_new_in(
		context: *mut PancakeContext,
		out: *mut *mut PancakeTcpNetlayer,
	) -> c_int;
	pub fn pancake_tcp_netlayer_release(netlayer: *mut PancakeTcpNetlayer);
	pub fn pancake_tcp_connect(
		netlayer: *mut PancakeTcpNetlayer,
		host: *const c_uchar,
		host_len: usize,
		port: u16,
		codec: c_uint,
		max_frame_bytes: usize,
		out: *mut *mut PancakeTcpConn,
	) -> c_int;
	pub fn pancake_tcp_listen(
		netlayer: *mut PancakeTcpNetlayer,
		host: *const c_uchar,
		host_len: usize,
		port: u16,
		out: *mut *mut PancakeTcpListener,
	) -> c_int;
	pub fn pancake_tcp_listener_port(
		listener: *mut PancakeTcpListener,
		out_port: *mut u16,
	) -> c_int;
	pub fn pancake_tcp_accept(
		listener: *mut PancakeTcpListener,
		codec: c_uint,
		max_frame_bytes: usize,
		out: *mut *mut PancakeTcpConn,
	) -> c_int;
	pub fn pancake_tcp_conn_read_frame(
		conn: *mut PancakeTcpConn,
		out: *mut PancakeManagedFrame,
	) -> c_int;
	pub fn pancake_tcp_conn_write_frame(
		conn: *mut PancakeTcpConn,
		frame: *const PancakeFrame,
	) -> c_int;
	pub fn pancake_tcp_conn_release(conn: *mut PancakeTcpConn);
	pub fn pancake_tcp_listener_release(listener: *mut PancakeTcpListener);
}
