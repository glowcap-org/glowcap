//! Raw FFI for the core archive (`libpancake_ocapn`).
//!
//! This is the universal base every build links: the context, frame, value,
//! and URI/locator vocabulary `pancake_ocapn.h` declares, plus
//! `pancake_abi_version` and the ocapn-family `pancake_last_error`. The shared
//! frame, context, and value types live here because the driver and transport
//! archives agree on their *layout* (ADR-0059); the host archive's own
//! `pancake_host_*` family lives in [`super::host`], and a transport's own
//! `sys/<t>.rs` declares only its handle types and `pancake_<t>_*` family.
//!
//! It declares the part of the core surface the safe wrappers consume. Dead
//! code is expected of a `sys` layer and allowed only here.
#![allow(dead_code)]

use core::ffi::{c_uchar, c_uint, c_void};

use super::layouts_gen::*;

#[repr(C)]
pub struct PancakeContext {
	_private: [u8; 0],
}

/// An owned OCapN peer locator.
#[repr(C)]
pub struct PancakeLocator {
	_private: [u8; 0],
}

/// An owned OCapN sturdyref: an embedded peer locator plus its swissnum.
#[repr(C)]
pub struct PancakeSturdyRef {
	_private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeLocatorHintView {
	pub name: *const c_uchar,
	pub name_len: usize,
	pub kind: c_uint,
	pub bytes: *const c_uchar,
	pub bytes_len: usize,
	pub boolean_value: u8,
	pub integer_value: i64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeLocatorView {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub transport: *const c_uchar,
	pub transport_len: usize,
	pub designator: *const c_uchar,
	pub designator_len: usize,
	pub hints: *const PancakeLocatorHintView,
	pub hint_count: usize,
	pub hint_wire_form: c_uint,
}

pub type PancakeAllocFn = unsafe extern "C" fn(user_data: *mut c_void, size: usize, alignment: usize) -> *mut c_void;
pub type PancakeFreeFn = unsafe extern "C" fn(user_data: *mut c_void, ptr: *mut c_void, size: usize, alignment: usize);

#[repr(C)]
pub struct PancakeAllocator {
	pub alloc: PancakeAllocFn,
	pub free: PancakeFreeFn,
	pub user_data: *mut c_void,
}

#[repr(C)]
pub struct PancakeFailureReport {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub layer: c_uint,
	pub scope_kind: c_uint,
	pub scope_id: u64,
	pub operation_id: u64,
	pub primary_result: i32,
	pub secondary_result: i32,
	pub secondary_count: c_uint,
	pub operation: *const c_uchar,
	pub operation_len: usize,
	pub primary_name: *const c_uchar,
	pub primary_name_len: usize,
	pub primary_message: *const c_uchar,
	pub primary_message_len: usize,
	pub secondary_name: *const c_uchar,
	pub secondary_name_len: usize,
	pub secondary_message: *const c_uchar,
	pub secondary_message_len: usize,
}

#[repr(C)]
pub struct PancakeFailureEvent {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub sequence: u64,
	pub dropped_before: u64,
	pub layer: c_uint,
	pub scope_kind: c_uint,
	pub scope_id: u64,
	pub operation_id: u64,
	pub primary_result: i32,
	pub secondary_result: i32,
	pub secondary_count: c_uint,
	pub flags: c_uint,
	pub operation: *const c_uchar,
	pub operation_len: usize,
	pub primary_name: *const c_uchar,
	pub primary_name_len: usize,
	pub primary_message: *const c_uchar,
	pub primary_message_len: usize,
	pub secondary_name: *const c_uchar,
	pub secondary_name_len: usize,
	pub secondary_message: *const c_uchar,
	pub secondary_message_len: usize,
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
	/// Failure publishing the projected abort, when present (process-static).
	pub abort_delivery_error_name: *const c_uchar,
	pub abort_delivery_error_name_len: usize,
	/// First cleanup or consequence failure, when present (process-static).
	pub secondary_error_name: *const c_uchar,
	pub secondary_error_name_len: usize,
	/// Number of secondary failures observed; the first name is retained.
	pub secondary_error_count: c_uint,
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
	assert!(offset_of!(PancakeManagedFrame, private_data) == PANCAKE_MANAGED_FRAME_PRIVATE_DATA_OFF);

	assert!(size_of::<PancakeAllocator>() == PANCAKE_ALLOCATOR_SIZE);
	assert!(offset_of!(PancakeAllocator, alloc) == PANCAKE_ALLOCATOR_ALLOC_OFF);
	assert!(offset_of!(PancakeAllocator, free) == PANCAKE_ALLOCATOR_FREE_OFF);
	assert!(offset_of!(PancakeAllocator, user_data) == PANCAKE_ALLOCATOR_USER_DATA_OFF);

	assert!(size_of::<PancakeFailureReport>() == PANCAKE_FAILURE_REPORT_SIZE);
	assert!(offset_of!(PancakeFailureReport, abi_version) == PANCAKE_FAILURE_REPORT_ABI_VERSION_OFF);
	assert!(offset_of!(PancakeFailureReport, struct_size) == PANCAKE_FAILURE_REPORT_STRUCT_SIZE_OFF);
	assert!(offset_of!(PancakeFailureReport, layer) == PANCAKE_FAILURE_REPORT_LAYER_OFF);
	assert!(offset_of!(PancakeFailureReport, scope_kind) == PANCAKE_FAILURE_REPORT_SCOPE_KIND_OFF);
	assert!(offset_of!(PancakeFailureReport, scope_id) == PANCAKE_FAILURE_REPORT_SCOPE_ID_OFF);
	assert!(offset_of!(PancakeFailureReport, operation_id) == PANCAKE_FAILURE_REPORT_OPERATION_ID_OFF);
	assert!(offset_of!(PancakeFailureReport, primary_result) == PANCAKE_FAILURE_REPORT_PRIMARY_RESULT_OFF);
	assert!(offset_of!(PancakeFailureReport, secondary_result) == PANCAKE_FAILURE_REPORT_SECONDARY_RESULT_OFF);
	assert!(offset_of!(PancakeFailureReport, secondary_count) == PANCAKE_FAILURE_REPORT_SECONDARY_COUNT_OFF);
	assert!(offset_of!(PancakeFailureReport, operation) == PANCAKE_FAILURE_REPORT_OPERATION_OFF);
	assert!(offset_of!(PancakeFailureReport, operation_len) == PANCAKE_FAILURE_REPORT_OPERATION_LEN_OFF);
	assert!(offset_of!(PancakeFailureReport, primary_name) == PANCAKE_FAILURE_REPORT_PRIMARY_NAME_OFF);
	assert!(offset_of!(PancakeFailureReport, primary_name_len) == PANCAKE_FAILURE_REPORT_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(PancakeFailureReport, primary_message) == PANCAKE_FAILURE_REPORT_PRIMARY_MESSAGE_OFF);
	assert!(offset_of!(PancakeFailureReport, primary_message_len) == PANCAKE_FAILURE_REPORT_PRIMARY_MESSAGE_LEN_OFF);
	assert!(offset_of!(PancakeFailureReport, secondary_name) == PANCAKE_FAILURE_REPORT_SECONDARY_NAME_OFF);
	assert!(offset_of!(PancakeFailureReport, secondary_name_len) == PANCAKE_FAILURE_REPORT_SECONDARY_NAME_LEN_OFF);
	assert!(offset_of!(PancakeFailureReport, secondary_message) == PANCAKE_FAILURE_REPORT_SECONDARY_MESSAGE_OFF);
	assert!(
		offset_of!(PancakeFailureReport, secondary_message_len) == PANCAKE_FAILURE_REPORT_SECONDARY_MESSAGE_LEN_OFF
	);

	assert!(size_of::<PancakeFailureEvent>() == PANCAKE_FAILURE_EVENT_SIZE);
	assert!(offset_of!(PancakeFailureEvent, abi_version) == PANCAKE_FAILURE_EVENT_ABI_VERSION_OFF);
	assert!(offset_of!(PancakeFailureEvent, struct_size) == PANCAKE_FAILURE_EVENT_STRUCT_SIZE_OFF);
	assert!(offset_of!(PancakeFailureEvent, sequence) == PANCAKE_FAILURE_EVENT_SEQUENCE_OFF);
	assert!(offset_of!(PancakeFailureEvent, dropped_before) == PANCAKE_FAILURE_EVENT_DROPPED_BEFORE_OFF);
	assert!(offset_of!(PancakeFailureEvent, layer) == PANCAKE_FAILURE_EVENT_LAYER_OFF);
	assert!(offset_of!(PancakeFailureEvent, scope_kind) == PANCAKE_FAILURE_EVENT_SCOPE_KIND_OFF);
	assert!(offset_of!(PancakeFailureEvent, scope_id) == PANCAKE_FAILURE_EVENT_SCOPE_ID_OFF);
	assert!(offset_of!(PancakeFailureEvent, operation_id) == PANCAKE_FAILURE_EVENT_OPERATION_ID_OFF);
	assert!(offset_of!(PancakeFailureEvent, primary_result) == PANCAKE_FAILURE_EVENT_PRIMARY_RESULT_OFF);
	assert!(offset_of!(PancakeFailureEvent, secondary_result) == PANCAKE_FAILURE_EVENT_SECONDARY_RESULT_OFF);
	assert!(offset_of!(PancakeFailureEvent, secondary_count) == PANCAKE_FAILURE_EVENT_SECONDARY_COUNT_OFF);
	assert!(offset_of!(PancakeFailureEvent, flags) == PANCAKE_FAILURE_EVENT_FLAGS_OFF);
	assert!(offset_of!(PancakeFailureEvent, operation) == PANCAKE_FAILURE_EVENT_OPERATION_OFF);
	assert!(offset_of!(PancakeFailureEvent, operation_len) == PANCAKE_FAILURE_EVENT_OPERATION_LEN_OFF);
	assert!(offset_of!(PancakeFailureEvent, primary_name) == PANCAKE_FAILURE_EVENT_PRIMARY_NAME_OFF);
	assert!(offset_of!(PancakeFailureEvent, primary_name_len) == PANCAKE_FAILURE_EVENT_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(PancakeFailureEvent, primary_message) == PANCAKE_FAILURE_EVENT_PRIMARY_MESSAGE_OFF);
	assert!(offset_of!(PancakeFailureEvent, primary_message_len) == PANCAKE_FAILURE_EVENT_PRIMARY_MESSAGE_LEN_OFF);
	assert!(offset_of!(PancakeFailureEvent, secondary_name) == PANCAKE_FAILURE_EVENT_SECONDARY_NAME_OFF);
	assert!(offset_of!(PancakeFailureEvent, secondary_name_len) == PANCAKE_FAILURE_EVENT_SECONDARY_NAME_LEN_OFF);
	assert!(offset_of!(PancakeFailureEvent, secondary_message) == PANCAKE_FAILURE_EVENT_SECONDARY_MESSAGE_OFF);
	assert!(offset_of!(PancakeFailureEvent, secondary_message_len) == PANCAKE_FAILURE_EVENT_SECONDARY_MESSAGE_LEN_OFF);

	assert!(size_of::<PancakeLastAbort>() == PANCAKE_LAST_ABORT_SIZE);
	assert!(offset_of!(PancakeLastAbort, domain) == PANCAKE_LAST_ABORT_DOMAIN_OFF);
	assert!(offset_of!(PancakeLastAbort, has_kind) == PANCAKE_LAST_ABORT_HAS_KIND_OFF);
	assert!(offset_of!(PancakeLastAbort, kind_name) == PANCAKE_LAST_ABORT_KIND_NAME_OFF);
	assert!(offset_of!(PancakeLastAbort, kind_name_len) == PANCAKE_LAST_ABORT_KIND_NAME_LEN_OFF);
	assert!(offset_of!(PancakeLastAbort, message) == PANCAKE_LAST_ABORT_MESSAGE_OFF);
	assert!(offset_of!(PancakeLastAbort, message_len) == PANCAKE_LAST_ABORT_MESSAGE_LEN_OFF);
	assert!(offset_of!(PancakeLastAbort, error_name) == PANCAKE_LAST_ABORT_ERROR_NAME_OFF);
	assert!(offset_of!(PancakeLastAbort, error_name_len) == PANCAKE_LAST_ABORT_ERROR_NAME_LEN_OFF);
	assert!(
		offset_of!(PancakeLastAbort, abort_delivery_error_name) == PANCAKE_LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_OFF
	);
	assert!(
		offset_of!(PancakeLastAbort, abort_delivery_error_name_len)
			== PANCAKE_LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_LEN_OFF
	);
	assert!(offset_of!(PancakeLastAbort, secondary_error_name) == PANCAKE_LAST_ABORT_SECONDARY_ERROR_NAME_OFF);
	assert!(offset_of!(PancakeLastAbort, secondary_error_name_len) == PANCAKE_LAST_ABORT_SECONDARY_ERROR_NAME_LEN_OFF);
	assert!(offset_of!(PancakeLastAbort, secondary_error_count) == PANCAKE_LAST_ABORT_SECONDARY_ERROR_COUNT_OFF);

	assert!(size_of::<PancakeLocatorHintView>() == PANCAKE_LOCATOR_HINT_VIEW_SIZE);
	assert!(offset_of!(PancakeLocatorHintView, name) == PANCAKE_LOCATOR_HINT_VIEW_NAME_OFF);
	assert!(offset_of!(PancakeLocatorHintView, name_len) == PANCAKE_LOCATOR_HINT_VIEW_NAME_LEN_OFF);
	assert!(offset_of!(PancakeLocatorHintView, kind) == PANCAKE_LOCATOR_HINT_VIEW_KIND_OFF);
	assert!(offset_of!(PancakeLocatorHintView, bytes) == PANCAKE_LOCATOR_HINT_VIEW_BYTES_OFF);
	assert!(offset_of!(PancakeLocatorHintView, bytes_len) == PANCAKE_LOCATOR_HINT_VIEW_BYTES_LEN_OFF);
	assert!(offset_of!(PancakeLocatorHintView, boolean_value) == PANCAKE_LOCATOR_HINT_VIEW_BOOLEAN_VALUE_OFF);
	assert!(offset_of!(PancakeLocatorHintView, integer_value) == PANCAKE_LOCATOR_HINT_VIEW_INTEGER_VALUE_OFF);

	assert!(size_of::<PancakeLocatorView>() == PANCAKE_LOCATOR_VIEW_SIZE);
	assert!(offset_of!(PancakeLocatorView, abi_version) == PANCAKE_LOCATOR_VIEW_ABI_VERSION_OFF);
	assert!(offset_of!(PancakeLocatorView, struct_size) == PANCAKE_LOCATOR_VIEW_STRUCT_SIZE_OFF);
	assert!(offset_of!(PancakeLocatorView, transport) == PANCAKE_LOCATOR_VIEW_TRANSPORT_OFF);
	assert!(offset_of!(PancakeLocatorView, transport_len) == PANCAKE_LOCATOR_VIEW_TRANSPORT_LEN_OFF);
	assert!(offset_of!(PancakeLocatorView, designator) == PANCAKE_LOCATOR_VIEW_DESIGNATOR_OFF);
	assert!(offset_of!(PancakeLocatorView, designator_len) == PANCAKE_LOCATOR_VIEW_DESIGNATOR_LEN_OFF);
	assert!(offset_of!(PancakeLocatorView, hints) == PANCAKE_LOCATOR_VIEW_HINTS_OFF);
	assert!(offset_of!(PancakeLocatorView, hint_count) == PANCAKE_LOCATOR_VIEW_HINT_COUNT_OFF);
	assert!(offset_of!(PancakeLocatorView, hint_wire_form) == PANCAKE_LOCATOR_VIEW_HINT_WIRE_FORM_OFF);
};

// The raw extern block is generated (`ocapn_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::pancake_*` paths.
pub use super::ocapn_fns_gen::*;
