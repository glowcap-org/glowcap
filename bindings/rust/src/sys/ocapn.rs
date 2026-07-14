//! Raw FFI for the core archive (`libpancake_ocapn`).
//!
//! This is the universal base every build links: the context, frame, value,
//! and URI/locator vocabulary `pancake_ocapn.h` declares, plus
//! `pancake_abi_version` and the ocapn-family `pancake_last_error`. The shared
//! frame, context, and value types live here because the driver and transport
//! archives agree on their *layout* (ADR-0059); the host archive's own
//! `pancake_host_*` family lives in [`super::driver`], and a transport's own
//! `sys/<t>.rs` declares only its handle types and `pancake_<t>_*` family.
//!
//! It declares the part of the core surface the safe wrappers consume, and not
//! every constant or extern is used by the safe wrapper (e.g. `REF_BROKEN`
//! rounds out its enum). Dead code is expected of a `sys` layer and allowed
//! only here.
#![allow(dead_code)]

use core::ffi::{c_int, c_uchar, c_uint, c_void};

#[repr(C)]
pub struct PancakeContext {
	_private: [u8; 0],
}

/// A parsed OCapN locator, one opaque handle carrying a peer or a sturdyref,
/// minted by `pancake_uri_parse_*` and read by the `pancake_locator_*`
/// accessors.
#[repr(C)]
pub struct PancakeLocator {
	_private: [u8; 0],
}

pub type PancakeAllocFn =
	unsafe extern "C" fn(user_data: *mut c_void, size: usize, alignment: usize) -> *mut c_void;
pub type PancakeFreeFn =
	unsafe extern "C" fn(user_data: *mut c_void, ptr: *mut c_void, size: usize, alignment: usize);

#[repr(C)]
pub struct PancakeAllocator {
	pub alloc: PancakeAllocFn,
	pub free: PancakeFreeFn,
	pub user_data: *mut c_void,
}

#[repr(C)]
pub struct PancakeFrame {
	pub bytes: *const c_uchar,
	pub len: usize,
	pub shape: c_uint,
}

#[repr(C)]
pub struct PancakeManagedFrame {
	pub bytes: *mut c_uchar,
	pub len: usize,
	pub shape: c_uint,
	pub release: Option<unsafe extern "C" fn(*mut PancakeManagedFrame)>,
	pub private_data: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeReference {
	pub kind: c_uint,
	pub sub_kind: c_uint,
	pub id: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeArgument {
	pub kind: c_uint,
	pub boolean: c_uint,
	pub integer: i64,
	pub float64: f64,
	pub bytes: *const c_uchar,
	pub bytes_len: usize,
	pub reference: PancakeReference,
	pub items: *const PancakeArgument,
	pub items_len: usize,
}

#[repr(C)]
pub struct PancakeLastAbort {
	/// 0 codec, 1 session, 2 foreign.
	pub domain: c_uint,
	/// Nonzero when an `op:abort` kind was projected.
	pub has_kind: c_uint,
	/// Wire name of the abort kind (process-static).
	pub kind_name: *const c_uchar,
	pub kind_name_len: usize,
	/// Static diagnostic.
	pub message: *const c_uchar,
	pub message_len: usize,
	/// Originating error name (process-static).
	pub error_name: *const c_uchar,
	pub error_name_len: usize,
}

// The layout gate for the C-written out-structs this mirror hand-declares
// (the driver mirror pins its own `PancakeHostAction` the same way): a field
// added or reordered on either side moves a size and fails the build loudly
// instead of misparsing the first drained frame or abort. LP64 values from
// the headers' documented layouts.
const _: () = {
	use core::mem::size_of;
	assert!(size_of::<PancakeFrame>() == 24);
	assert!(size_of::<PancakeManagedFrame>() == 40);
	assert!(size_of::<PancakeLastAbort>() == 56);
};

extern "C" {
	pub fn pancake_abi_version(major: *mut c_uint, minor: *mut c_uint, patch: *mut c_uint);
	pub fn pancake_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
	pub fn pancake_clear_last_error();

	pub fn pancake_context_new(out: *mut *mut PancakeContext) -> c_int;
	pub fn pancake_context_new_with_allocator(
		allocator: *const PancakeAllocator,
		out: *mut *mut PancakeContext,
	) -> c_int;
	pub fn pancake_context_release(context: *mut PancakeContext);

	pub fn pancake_managed_frame_release(frame: *mut PancakeManagedFrame);

	// Build the verbatim exporter location-record bytes a give names, writing
	// owned bytes into `out`/`out_len` (release with
	// `pancake_peer_locator_bytes_release`). `transport`/`designator` name the
	// exporter; a non-empty `direct_addresses` adds the exporter's comma-separated
	// socket addresses as a `direct-addresses` hint (an iroh exporter reachable
	// only by address). All inputs are borrowed.
	pub fn pancake_encode_peer_locator(
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		direct_addresses: *const c_uchar,
		direct_addresses_len: usize,
		out: *mut *mut c_uchar,
		out_len: *mut usize,
	) -> c_int;
	// Release the owned locator bytes `pancake_encode_peer_locator` returned.
	pub fn pancake_peer_locator_bytes_release(locator: *mut c_uchar, locator_len: usize);

	// OCapN locator URIs, core `libpancake_ocapn` vocabulary, so a TCP-only or
	// even transport-free consumer reaches the grammar. One grammar, no
	// hand-rolled percent codec.
	pub fn pancake_uri_parse_peer(
		uri: *const c_uchar,
		uri_len: usize,
		out_locator: *mut *mut PancakeLocator,
	) -> c_int;
	pub fn pancake_uri_parse_sturdyref(
		uri: *const c_uchar,
		uri_len: usize,
		out_locator: *mut *mut PancakeLocator,
	) -> c_int;
	pub fn pancake_uri_format_peer(
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		hint_keys: *const *const c_uchar,
		hint_key_lens: *const usize,
		hint_vals: *const *const c_uchar,
		hint_val_lens: *const usize,
		hint_count: usize,
		out: *mut c_uchar,
		cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_locator_transport(
		loc: *mut PancakeLocator,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_locator_designator(
		loc: *mut PancakeLocator,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_locator_host_port(
		loc: *mut PancakeLocator,
		out_host: *mut *const c_uchar,
		out_host_len: *mut usize,
		out_port: *mut u16,
	) -> c_int;
	pub fn pancake_designator_host_port(
		designator: *const c_uchar,
		designator_len: usize,
		out_host: *mut *const c_uchar,
		out_host_len: *mut usize,
		out_port: *mut u16,
	) -> c_int;
	pub fn pancake_locator_swissnum(
		loc: *mut PancakeLocator,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_locator_hint(
		loc: *mut PancakeLocator,
		key: *const c_uchar,
		key_len: usize,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	pub fn pancake_locator_hint_count(loc: *mut PancakeLocator, out_count: *mut usize) -> c_int;
	pub fn pancake_locator_hint_at(
		loc: *mut PancakeLocator,
		idx: usize,
		out_key: *mut *const c_uchar,
		out_key_len: *mut usize,
		out_val: *mut *const c_uchar,
		out_val_len: *mut usize,
	) -> c_int;
	pub fn pancake_locator_release(loc: *mut PancakeLocator);
}
