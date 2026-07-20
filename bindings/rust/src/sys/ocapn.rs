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

use core::ffi::{c_uchar, c_uint, c_void};

use super::layouts_gen::*;

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
// added or reordered on either side moves a size or offset and fails the
// build loudly instead of misparsing the first drained frame or abort.
// Expected values come from `layouts_gen` (`zig build gen-binding-ffi-layouts`),
// reflected off the real Zig C ABI types, so this pin cannot drift from them.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeReference>() == PANCAKE_REFERENCE_SIZE);
	assert!(offset_of!(PancakeReference, kind) == PANCAKE_REFERENCE_KIND_OFF);
	assert!(offset_of!(PancakeReference, sub_kind) == PANCAKE_REFERENCE_SUB_KIND_OFF);
	assert!(offset_of!(PancakeReference, id) == PANCAKE_REFERENCE_ID_OFF);

	assert!(size_of::<PancakeArgument>() == PANCAKE_ARGUMENT_SIZE);
	assert!(offset_of!(PancakeArgument, kind) == PANCAKE_ARGUMENT_KIND_OFF);
	assert!(offset_of!(PancakeArgument, boolean) == PANCAKE_ARGUMENT_BOOLEAN_OFF);
	assert!(offset_of!(PancakeArgument, integer) == PANCAKE_ARGUMENT_INTEGER_OFF);
	assert!(offset_of!(PancakeArgument, float64) == PANCAKE_ARGUMENT_FLOAT64_OFF);
	assert!(offset_of!(PancakeArgument, bytes) == PANCAKE_ARGUMENT_BYTES_OFF);
	assert!(offset_of!(PancakeArgument, bytes_len) == PANCAKE_ARGUMENT_BYTES_LEN_OFF);
	assert!(offset_of!(PancakeArgument, reference) == PANCAKE_ARGUMENT_REFERENCE_OFF);
	assert!(offset_of!(PancakeArgument, items) == PANCAKE_ARGUMENT_ITEMS_OFF);
	assert!(offset_of!(PancakeArgument, items_len) == PANCAKE_ARGUMENT_ITEMS_LEN_OFF);

	assert!(size_of::<PancakeFrame>() == PANCAKE_FRAME_SIZE);
	assert!(offset_of!(PancakeFrame, bytes) == PANCAKE_FRAME_BYTES_OFF);
	assert!(offset_of!(PancakeFrame, len) == PANCAKE_FRAME_LEN_OFF);
	assert!(offset_of!(PancakeFrame, shape) == PANCAKE_FRAME_SHAPE_OFF);

	assert!(size_of::<PancakeManagedFrame>() == PANCAKE_MANAGED_FRAME_SIZE);
	assert!(offset_of!(PancakeManagedFrame, bytes) == PANCAKE_MANAGED_FRAME_BYTES_OFF);
	assert!(offset_of!(PancakeManagedFrame, len) == PANCAKE_MANAGED_FRAME_LEN_OFF);
	assert!(offset_of!(PancakeManagedFrame, shape) == PANCAKE_MANAGED_FRAME_SHAPE_OFF);
	assert!(offset_of!(PancakeManagedFrame, release) == PANCAKE_MANAGED_FRAME_RELEASE_OFF);
	assert!(
		offset_of!(PancakeManagedFrame, private_data) == PANCAKE_MANAGED_FRAME_PRIVATE_DATA_OFF
	);

	assert!(size_of::<PancakeAllocator>() == PANCAKE_ALLOCATOR_SIZE);
	assert!(offset_of!(PancakeAllocator, alloc) == PANCAKE_ALLOCATOR_ALLOC_OFF);
	assert!(offset_of!(PancakeAllocator, free) == PANCAKE_ALLOCATOR_FREE_OFF);
	assert!(offset_of!(PancakeAllocator, user_data) == PANCAKE_ALLOCATOR_USER_DATA_OFF);

	assert!(size_of::<PancakeLastAbort>() == PANCAKE_LAST_ABORT_SIZE);
	assert!(offset_of!(PancakeLastAbort, domain) == PANCAKE_LAST_ABORT_DOMAIN_OFF);
	assert!(offset_of!(PancakeLastAbort, has_kind) == PANCAKE_LAST_ABORT_HAS_KIND_OFF);
	assert!(offset_of!(PancakeLastAbort, kind_name) == PANCAKE_LAST_ABORT_KIND_NAME_OFF);
	assert!(offset_of!(PancakeLastAbort, kind_name_len) == PANCAKE_LAST_ABORT_KIND_NAME_LEN_OFF);
	assert!(offset_of!(PancakeLastAbort, message) == PANCAKE_LAST_ABORT_MESSAGE_OFF);
	assert!(offset_of!(PancakeLastAbort, message_len) == PANCAKE_LAST_ABORT_MESSAGE_LEN_OFF);
	assert!(offset_of!(PancakeLastAbort, error_name) == PANCAKE_LAST_ABORT_ERROR_NAME_OFF);
	assert!(offset_of!(PancakeLastAbort, error_name_len) == PANCAKE_LAST_ABORT_ERROR_NAME_LEN_OFF);
};

// The raw extern block is generated (`ocapn_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::pancake_*` paths.
pub use super::ocapn_fns_gen::*;
