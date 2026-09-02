//! Raw FFI for the core archive (`libglowcap_ocapn`).
//!
//! This is the universal base every build links: the context, frame, value,
//! and URI/locator vocabulary `glowcap_ocapn.h` declares, plus
//! `glowcap_abi_version` and the ocapn-family `glowcap_last_error`. The shared
//! frame, context, and value types live here because the driver and transport
//! archives agree on their *layout* (ADR-0059); the host archive's own
//! `glowcap_host_*` family lives in [`super::host`], and a transport's own
//! `sys/<t>.rs` declares only its handle types and `glowcap_<t>_*` family.
//!
//! It declares the part of the core surface the safe wrappers consume. Dead
//! code is expected of a `sys` layer and allowed only here.
#![allow(dead_code)]

use core::ffi::{c_uchar, c_uint, c_void};

use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapContext {
	_private: [u8; 0],
}

/// An owned OCapN peer locator.
#[repr(C)]
pub struct GlowcapLocator {
	_private: [u8; 0],
}

/// An owned OCapN sturdyref: an embedded peer locator plus its swissnum.
#[repr(C)]
pub struct GlowcapSturdyRef {
	_private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapLocatorHintView {
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
pub struct GlowcapLocatorView {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub transport: *const c_uchar,
	pub transport_len: usize,
	pub designator: *const c_uchar,
	pub designator_len: usize,
	pub hints: *const GlowcapLocatorHintView,
	pub hint_count: usize,
	pub hint_wire_form: c_uint,
}

pub type GlowcapAllocFn = unsafe extern "C" fn(user_data: *mut c_void, size: usize, alignment: usize) -> *mut c_void;
pub type GlowcapFreeFn = unsafe extern "C" fn(user_data: *mut c_void, ptr: *mut c_void, size: usize, alignment: usize);

#[repr(C)]
pub struct GlowcapAllocator {
	pub alloc: GlowcapAllocFn,
	pub free: GlowcapFreeFn,
	pub user_data: *mut c_void,
}

#[repr(C)]
pub struct GlowcapFailureReport {
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
pub struct GlowcapFailureEvent {
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
pub struct GlowcapFrame {
	pub bytes: *const c_uchar,
	pub len: usize,
	pub shape: c_uint,
}

#[repr(C)]
pub struct GlowcapManagedFrame {
	pub bytes: *mut c_uchar,
	pub len: usize,
	pub shape: c_uint,
	pub release: Option<unsafe extern "C" fn(*mut GlowcapManagedFrame)>,
	pub private_words: [usize; 8],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapReference {
	pub id: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapArgument {
	pub kind: c_uint,
	pub boolean: c_uint,
	pub integer: i64,
	pub float64: f64,
	pub bytes: *const c_uchar,
	pub bytes_len: usize,
	pub reference: GlowcapReference,
	pub items: *const GlowcapArgument,
	pub items_len: usize,
}

#[repr(C)]
pub struct GlowcapLastAbort {
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
// (the driver mirror pins its own `GlowcapHostAction` the same way): a field
// added or reordered on either side moves a size or offset and fails the
// build loudly instead of misparsing the first drained frame or abort.
// Expected values come from `layouts_gen` (`zig build gen-binding-ffi-layouts`),
// reflected off the real Zig C ABI types, so this pin cannot drift from them.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapReference>() == GLOWCAP_REFERENCE_SIZE);
	assert!(offset_of!(GlowcapReference, id) == GLOWCAP_REFERENCE_ID_OFF);

	assert!(size_of::<GlowcapArgument>() == GLOWCAP_ARGUMENT_SIZE);
	assert!(offset_of!(GlowcapArgument, kind) == GLOWCAP_ARGUMENT_KIND_OFF);
	assert!(offset_of!(GlowcapArgument, boolean) == GLOWCAP_ARGUMENT_BOOLEAN_OFF);
	assert!(offset_of!(GlowcapArgument, integer) == GLOWCAP_ARGUMENT_INTEGER_OFF);
	assert!(offset_of!(GlowcapArgument, float64) == GLOWCAP_ARGUMENT_FLOAT64_OFF);
	assert!(offset_of!(GlowcapArgument, bytes) == GLOWCAP_ARGUMENT_BYTES_OFF);
	assert!(offset_of!(GlowcapArgument, bytes_len) == GLOWCAP_ARGUMENT_BYTES_LEN_OFF);
	assert!(offset_of!(GlowcapArgument, reference) == GLOWCAP_ARGUMENT_REFERENCE_OFF);
	assert!(offset_of!(GlowcapArgument, items) == GLOWCAP_ARGUMENT_ITEMS_OFF);
	assert!(offset_of!(GlowcapArgument, items_len) == GLOWCAP_ARGUMENT_ITEMS_LEN_OFF);

	assert!(size_of::<GlowcapFrame>() == GLOWCAP_FRAME_SIZE);
	assert!(offset_of!(GlowcapFrame, bytes) == GLOWCAP_FRAME_BYTES_OFF);
	assert!(offset_of!(GlowcapFrame, len) == GLOWCAP_FRAME_LEN_OFF);
	assert!(offset_of!(GlowcapFrame, shape) == GLOWCAP_FRAME_SHAPE_OFF);

	assert!(size_of::<GlowcapManagedFrame>() == GLOWCAP_MANAGED_FRAME_SIZE);
	assert!(offset_of!(GlowcapManagedFrame, bytes) == GLOWCAP_MANAGED_FRAME_BYTES_OFF);
	assert!(offset_of!(GlowcapManagedFrame, len) == GLOWCAP_MANAGED_FRAME_LEN_OFF);
	assert!(offset_of!(GlowcapManagedFrame, shape) == GLOWCAP_MANAGED_FRAME_SHAPE_OFF);
	assert!(offset_of!(GlowcapManagedFrame, release) == GLOWCAP_MANAGED_FRAME_RELEASE_OFF);
	assert!(offset_of!(GlowcapManagedFrame, private_words) == GLOWCAP_MANAGED_FRAME_PRIVATE_WORDS_OFF);

	assert!(size_of::<GlowcapAllocator>() == GLOWCAP_ALLOCATOR_SIZE);
	assert!(offset_of!(GlowcapAllocator, alloc) == GLOWCAP_ALLOCATOR_ALLOC_OFF);
	assert!(offset_of!(GlowcapAllocator, free) == GLOWCAP_ALLOCATOR_FREE_OFF);
	assert!(offset_of!(GlowcapAllocator, user_data) == GLOWCAP_ALLOCATOR_USER_DATA_OFF);

	assert!(size_of::<GlowcapFailureReport>() == GLOWCAP_FAILURE_REPORT_SIZE);
	assert!(offset_of!(GlowcapFailureReport, abi_version) == GLOWCAP_FAILURE_REPORT_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapFailureReport, struct_size) == GLOWCAP_FAILURE_REPORT_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapFailureReport, layer) == GLOWCAP_FAILURE_REPORT_LAYER_OFF);
	assert!(offset_of!(GlowcapFailureReport, scope_kind) == GLOWCAP_FAILURE_REPORT_SCOPE_KIND_OFF);
	assert!(offset_of!(GlowcapFailureReport, scope_id) == GLOWCAP_FAILURE_REPORT_SCOPE_ID_OFF);
	assert!(offset_of!(GlowcapFailureReport, operation_id) == GLOWCAP_FAILURE_REPORT_OPERATION_ID_OFF);
	assert!(offset_of!(GlowcapFailureReport, primary_result) == GLOWCAP_FAILURE_REPORT_PRIMARY_RESULT_OFF);
	assert!(offset_of!(GlowcapFailureReport, secondary_result) == GLOWCAP_FAILURE_REPORT_SECONDARY_RESULT_OFF);
	assert!(offset_of!(GlowcapFailureReport, secondary_count) == GLOWCAP_FAILURE_REPORT_SECONDARY_COUNT_OFF);
	assert!(offset_of!(GlowcapFailureReport, operation) == GLOWCAP_FAILURE_REPORT_OPERATION_OFF);
	assert!(offset_of!(GlowcapFailureReport, operation_len) == GLOWCAP_FAILURE_REPORT_OPERATION_LEN_OFF);
	assert!(offset_of!(GlowcapFailureReport, primary_name) == GLOWCAP_FAILURE_REPORT_PRIMARY_NAME_OFF);
	assert!(offset_of!(GlowcapFailureReport, primary_name_len) == GLOWCAP_FAILURE_REPORT_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapFailureReport, primary_message) == GLOWCAP_FAILURE_REPORT_PRIMARY_MESSAGE_OFF);
	assert!(offset_of!(GlowcapFailureReport, primary_message_len) == GLOWCAP_FAILURE_REPORT_PRIMARY_MESSAGE_LEN_OFF);
	assert!(offset_of!(GlowcapFailureReport, secondary_name) == GLOWCAP_FAILURE_REPORT_SECONDARY_NAME_OFF);
	assert!(offset_of!(GlowcapFailureReport, secondary_name_len) == GLOWCAP_FAILURE_REPORT_SECONDARY_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapFailureReport, secondary_message) == GLOWCAP_FAILURE_REPORT_SECONDARY_MESSAGE_OFF);
	assert!(
		offset_of!(GlowcapFailureReport, secondary_message_len) == GLOWCAP_FAILURE_REPORT_SECONDARY_MESSAGE_LEN_OFF
	);

	assert!(size_of::<GlowcapFailureEvent>() == GLOWCAP_FAILURE_EVENT_SIZE);
	assert!(offset_of!(GlowcapFailureEvent, abi_version) == GLOWCAP_FAILURE_EVENT_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapFailureEvent, struct_size) == GLOWCAP_FAILURE_EVENT_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapFailureEvent, sequence) == GLOWCAP_FAILURE_EVENT_SEQUENCE_OFF);
	assert!(offset_of!(GlowcapFailureEvent, dropped_before) == GLOWCAP_FAILURE_EVENT_DROPPED_BEFORE_OFF);
	assert!(offset_of!(GlowcapFailureEvent, layer) == GLOWCAP_FAILURE_EVENT_LAYER_OFF);
	assert!(offset_of!(GlowcapFailureEvent, scope_kind) == GLOWCAP_FAILURE_EVENT_SCOPE_KIND_OFF);
	assert!(offset_of!(GlowcapFailureEvent, scope_id) == GLOWCAP_FAILURE_EVENT_SCOPE_ID_OFF);
	assert!(offset_of!(GlowcapFailureEvent, operation_id) == GLOWCAP_FAILURE_EVENT_OPERATION_ID_OFF);
	assert!(offset_of!(GlowcapFailureEvent, primary_result) == GLOWCAP_FAILURE_EVENT_PRIMARY_RESULT_OFF);
	assert!(offset_of!(GlowcapFailureEvent, secondary_result) == GLOWCAP_FAILURE_EVENT_SECONDARY_RESULT_OFF);
	assert!(offset_of!(GlowcapFailureEvent, secondary_count) == GLOWCAP_FAILURE_EVENT_SECONDARY_COUNT_OFF);
	assert!(offset_of!(GlowcapFailureEvent, flags) == GLOWCAP_FAILURE_EVENT_FLAGS_OFF);
	assert!(offset_of!(GlowcapFailureEvent, operation) == GLOWCAP_FAILURE_EVENT_OPERATION_OFF);
	assert!(offset_of!(GlowcapFailureEvent, operation_len) == GLOWCAP_FAILURE_EVENT_OPERATION_LEN_OFF);
	assert!(offset_of!(GlowcapFailureEvent, primary_name) == GLOWCAP_FAILURE_EVENT_PRIMARY_NAME_OFF);
	assert!(offset_of!(GlowcapFailureEvent, primary_name_len) == GLOWCAP_FAILURE_EVENT_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapFailureEvent, primary_message) == GLOWCAP_FAILURE_EVENT_PRIMARY_MESSAGE_OFF);
	assert!(offset_of!(GlowcapFailureEvent, primary_message_len) == GLOWCAP_FAILURE_EVENT_PRIMARY_MESSAGE_LEN_OFF);
	assert!(offset_of!(GlowcapFailureEvent, secondary_name) == GLOWCAP_FAILURE_EVENT_SECONDARY_NAME_OFF);
	assert!(offset_of!(GlowcapFailureEvent, secondary_name_len) == GLOWCAP_FAILURE_EVENT_SECONDARY_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapFailureEvent, secondary_message) == GLOWCAP_FAILURE_EVENT_SECONDARY_MESSAGE_OFF);
	assert!(offset_of!(GlowcapFailureEvent, secondary_message_len) == GLOWCAP_FAILURE_EVENT_SECONDARY_MESSAGE_LEN_OFF);

	assert!(size_of::<GlowcapLastAbort>() == GLOWCAP_LAST_ABORT_SIZE);
	assert!(offset_of!(GlowcapLastAbort, domain) == GLOWCAP_LAST_ABORT_DOMAIN_OFF);
	assert!(offset_of!(GlowcapLastAbort, has_kind) == GLOWCAP_LAST_ABORT_HAS_KIND_OFF);
	assert!(offset_of!(GlowcapLastAbort, kind_name) == GLOWCAP_LAST_ABORT_KIND_NAME_OFF);
	assert!(offset_of!(GlowcapLastAbort, kind_name_len) == GLOWCAP_LAST_ABORT_KIND_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapLastAbort, message) == GLOWCAP_LAST_ABORT_MESSAGE_OFF);
	assert!(offset_of!(GlowcapLastAbort, message_len) == GLOWCAP_LAST_ABORT_MESSAGE_LEN_OFF);
	assert!(offset_of!(GlowcapLastAbort, error_name) == GLOWCAP_LAST_ABORT_ERROR_NAME_OFF);
	assert!(offset_of!(GlowcapLastAbort, error_name_len) == GLOWCAP_LAST_ABORT_ERROR_NAME_LEN_OFF);
	assert!(
		offset_of!(GlowcapLastAbort, abort_delivery_error_name) == GLOWCAP_LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_OFF
	);
	assert!(
		offset_of!(GlowcapLastAbort, abort_delivery_error_name_len)
			== GLOWCAP_LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_LEN_OFF
	);
	assert!(offset_of!(GlowcapLastAbort, secondary_error_name) == GLOWCAP_LAST_ABORT_SECONDARY_ERROR_NAME_OFF);
	assert!(offset_of!(GlowcapLastAbort, secondary_error_name_len) == GLOWCAP_LAST_ABORT_SECONDARY_ERROR_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapLastAbort, secondary_error_count) == GLOWCAP_LAST_ABORT_SECONDARY_ERROR_COUNT_OFF);

	assert!(size_of::<GlowcapLocatorHintView>() == GLOWCAP_LOCATOR_HINT_VIEW_SIZE);
	assert!(offset_of!(GlowcapLocatorHintView, name) == GLOWCAP_LOCATOR_HINT_VIEW_NAME_OFF);
	assert!(offset_of!(GlowcapLocatorHintView, name_len) == GLOWCAP_LOCATOR_HINT_VIEW_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapLocatorHintView, kind) == GLOWCAP_LOCATOR_HINT_VIEW_KIND_OFF);
	assert!(offset_of!(GlowcapLocatorHintView, bytes) == GLOWCAP_LOCATOR_HINT_VIEW_BYTES_OFF);
	assert!(offset_of!(GlowcapLocatorHintView, bytes_len) == GLOWCAP_LOCATOR_HINT_VIEW_BYTES_LEN_OFF);
	assert!(offset_of!(GlowcapLocatorHintView, boolean_value) == GLOWCAP_LOCATOR_HINT_VIEW_BOOLEAN_VALUE_OFF);
	assert!(offset_of!(GlowcapLocatorHintView, integer_value) == GLOWCAP_LOCATOR_HINT_VIEW_INTEGER_VALUE_OFF);

	assert!(size_of::<GlowcapLocatorView>() == GLOWCAP_LOCATOR_VIEW_SIZE);
	assert!(offset_of!(GlowcapLocatorView, abi_version) == GLOWCAP_LOCATOR_VIEW_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapLocatorView, struct_size) == GLOWCAP_LOCATOR_VIEW_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapLocatorView, transport) == GLOWCAP_LOCATOR_VIEW_TRANSPORT_OFF);
	assert!(offset_of!(GlowcapLocatorView, transport_len) == GLOWCAP_LOCATOR_VIEW_TRANSPORT_LEN_OFF);
	assert!(offset_of!(GlowcapLocatorView, designator) == GLOWCAP_LOCATOR_VIEW_DESIGNATOR_OFF);
	assert!(offset_of!(GlowcapLocatorView, designator_len) == GLOWCAP_LOCATOR_VIEW_DESIGNATOR_LEN_OFF);
	assert!(offset_of!(GlowcapLocatorView, hints) == GLOWCAP_LOCATOR_VIEW_HINTS_OFF);
	assert!(offset_of!(GlowcapLocatorView, hint_count) == GLOWCAP_LOCATOR_VIEW_HINT_COUNT_OFF);
	assert!(offset_of!(GlowcapLocatorView, hint_wire_form) == GLOWCAP_LOCATOR_VIEW_HINT_WIRE_FORM_OFF);
};

// The raw extern block is generated (`ocapn_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::glowcap_*` paths.
pub use super::ocapn_fns_gen::*;
