//! Raw FFI for the in-process transport archive
//! (`libpancake_net_transport_inproc`).
//!
//! Linked only with the `inproc` feature (ADR-0059). It exports the
//! `pancake_inproc_*` family and its own thread-local last-error
//! (`pancake_inproc_last_error`), symbol-disjoint from the core archive; the
//! shared frame and context types it speaks are reused by layout from
//! [`crate::sys`].
#![allow(dead_code)]

use core::ffi::{c_int, c_uchar, c_uint};

use crate::sys::{PancakeContext, PancakeFrame, PancakeManagedFrame};

#[repr(C)]
pub struct PancakeInprocNetlayer {
	_private: [u8; 0],
}
#[repr(C)]
pub struct PancakeInprocConn {
	_private: [u8; 0],
}
#[repr(C)]
pub struct PancakeInprocListener {
	_private: [u8; 0],
}

extern "C" {
	// The in-process transport archive carries its own thread-local last-error,
	// read through `pancake_inproc_last_error` rather than the ocapn family's
	// `pancake_last_error`.
	pub fn pancake_inproc_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
	pub fn pancake_inproc_clear_last_error();
	pub fn pancake_inproc_netlayer_new(out: *mut *mut PancakeInprocNetlayer) -> c_int;
	pub fn pancake_inproc_netlayer_new_in(
		context: *mut PancakeContext,
		out: *mut *mut PancakeInprocNetlayer,
	) -> c_int;
	pub fn pancake_inproc_netlayer_release(netlayer: *mut PancakeInprocNetlayer);
	pub fn pancake_inproc_connect(
		netlayer: *mut PancakeInprocNetlayer,
		designator: *const c_uchar,
		designator_len: usize,
		codec: c_uint,
		max_frame_bytes: usize,
		out: *mut *mut PancakeInprocConn,
	) -> c_int;
	pub fn pancake_inproc_listen(
		netlayer: *mut PancakeInprocNetlayer,
		designator: *const c_uchar,
		designator_len: usize,
		out: *mut *mut PancakeInprocListener,
	) -> c_int;
	pub fn pancake_inproc_accept(
		listener: *mut PancakeInprocListener,
		codec: c_uint,
		max_frame_bytes: usize,
		out: *mut *mut PancakeInprocConn,
	) -> c_int;
	pub fn pancake_inproc_conn_read_frame(
		conn: *mut PancakeInprocConn,
		out: *mut PancakeManagedFrame,
	) -> c_int;
	pub fn pancake_inproc_conn_write_frame(
		conn: *mut PancakeInprocConn,
		frame: *const PancakeFrame,
	) -> c_int;
	pub fn pancake_inproc_conn_release(conn: *mut PancakeInprocConn);
	pub fn pancake_inproc_listener_release(listener: *mut PancakeInprocListener);
}
