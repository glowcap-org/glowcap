//! Raw FFI for the `pancake_driver_*` native loop family.
//!
//! Transport archives expose a small provider package header. The driver
//! copies the package's private implementation tables, so this binding does
//! not mirror stream or multiplexed execution-model vtables.

use core::ffi::{c_int, c_uchar, c_uint, c_void};

use super::host::{PancakeHostAction, PancakeHostSession};
use super::layouts_gen::*;

#[repr(C)]
pub struct PancakeDriverLoop {
	_private: [u8; 0],
}

#[repr(C)]
pub struct PancakeDriverOptions {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub wire_buffer_bytes: usize,
	pub max_pending_opens: usize,
	pub handshake_ms: c_uint,
	pub listener_setup_ms: c_uint,
	pub settle_ms: c_uint,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeDriverFailure {
	pub abi_version: u32,
	pub struct_size: usize,
	pub primary_result: c_int,
	pub secondary_result: c_int,
	pub secondary_count: u32,
	pub carrier_phase: u32,
	pub carrier_detail_flags: u32,
	pub carrier_verification_flags: u32,
	pub carrier_peer_alert: u32,
	pub carrier_engine_code: i32,
	pub primary_name: *const u8,
	pub primary_name_len: usize,
	pub secondary_name: *const u8,
	pub secondary_name_len: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeDriverOptions>() == PANCAKE_DRIVER_OPTIONS_SIZE);
	assert!(offset_of!(PancakeDriverOptions, abi_version) == PANCAKE_DRIVER_OPTIONS_ABI_VERSION_OFF);
	assert!(offset_of!(PancakeDriverOptions, struct_size) == PANCAKE_DRIVER_OPTIONS_STRUCT_SIZE_OFF);
	assert!(offset_of!(PancakeDriverOptions, wire_buffer_bytes) == PANCAKE_DRIVER_OPTIONS_WIRE_BUFFER_BYTES_OFF);
	assert!(offset_of!(PancakeDriverOptions, max_pending_opens) == PANCAKE_DRIVER_OPTIONS_MAX_PENDING_OPENS_OFF);
	assert!(offset_of!(PancakeDriverOptions, handshake_ms) == PANCAKE_DRIVER_OPTIONS_HANDSHAKE_MS_OFF);
	assert!(offset_of!(PancakeDriverOptions, listener_setup_ms) == PANCAKE_DRIVER_OPTIONS_LISTENER_SETUP_MS_OFF);
	assert!(offset_of!(PancakeDriverOptions, settle_ms) == PANCAKE_DRIVER_OPTIONS_SETTLE_MS_OFF);
};

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeDriverFailure>() == PANCAKE_DRIVER_FAILURE_SIZE);
	assert!(offset_of!(PancakeDriverFailure, abi_version) == PANCAKE_DRIVER_FAILURE_ABI_VERSION_OFF);
	assert!(offset_of!(PancakeDriverFailure, struct_size) == PANCAKE_DRIVER_FAILURE_STRUCT_SIZE_OFF);
	assert!(offset_of!(PancakeDriverFailure, primary_result) == PANCAKE_DRIVER_FAILURE_PRIMARY_RESULT_OFF);
	assert!(offset_of!(PancakeDriverFailure, secondary_result) == PANCAKE_DRIVER_FAILURE_SECONDARY_RESULT_OFF);
	assert!(offset_of!(PancakeDriverFailure, secondary_count) == PANCAKE_DRIVER_FAILURE_SECONDARY_COUNT_OFF);
	assert!(offset_of!(PancakeDriverFailure, carrier_phase) == PANCAKE_DRIVER_FAILURE_CARRIER_PHASE_OFF);
	assert!(offset_of!(PancakeDriverFailure, carrier_detail_flags) == PANCAKE_DRIVER_FAILURE_CARRIER_DETAIL_FLAGS_OFF);
	assert!(
		offset_of!(PancakeDriverFailure, carrier_verification_flags)
			== PANCAKE_DRIVER_FAILURE_CARRIER_VERIFICATION_FLAGS_OFF
	);
	assert!(offset_of!(PancakeDriverFailure, carrier_peer_alert) == PANCAKE_DRIVER_FAILURE_CARRIER_PEER_ALERT_OFF);
	assert!(offset_of!(PancakeDriverFailure, carrier_engine_code) == PANCAKE_DRIVER_FAILURE_CARRIER_ENGINE_CODE_OFF);
	assert!(offset_of!(PancakeDriverFailure, primary_name) == PANCAKE_DRIVER_FAILURE_PRIMARY_NAME_OFF);
	assert!(offset_of!(PancakeDriverFailure, primary_name_len) == PANCAKE_DRIVER_FAILURE_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(PancakeDriverFailure, secondary_name) == PANCAKE_DRIVER_FAILURE_SECONDARY_NAME_OFF);
	assert!(offset_of!(PancakeDriverFailure, secondary_name_len) == PANCAKE_DRIVER_FAILURE_SECONDARY_NAME_LEN_OFF);
};

#[repr(C)]
pub struct PancakeDriverEvent {
	pub kind: c_uint,
	pub primary_result: c_int,
	pub secondary_result: c_int,
	pub secondary_count: c_uint,
	pub carrier_phase: c_uint,
	pub carrier_detail_flags: c_uint,
	pub carrier_verification_flags: c_uint,
	pub carrier_peer_alert: c_uint,
	pub carrier_engine_code: c_int,
	pub operation_id: u64,
	pub listener_id: u64,
	pub session: *mut PancakeHostSession,
	pub action: PancakeHostAction,
	pub primary_name: *const c_uchar,
	pub primary_name_len: usize,
	pub secondary_name: *const c_uchar,
	pub secondary_name_len: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeDriverEvent>() == PANCAKE_DRIVER_EVENT_SIZE);
	assert!(offset_of!(PancakeDriverEvent, kind) == PANCAKE_DRIVER_EVENT_KIND_OFF);
	assert!(offset_of!(PancakeDriverEvent, primary_result) == PANCAKE_DRIVER_EVENT_PRIMARY_RESULT_OFF);
	assert!(offset_of!(PancakeDriverEvent, secondary_result) == PANCAKE_DRIVER_EVENT_SECONDARY_RESULT_OFF);
	assert!(offset_of!(PancakeDriverEvent, secondary_count) == PANCAKE_DRIVER_EVENT_SECONDARY_COUNT_OFF);
	assert!(offset_of!(PancakeDriverEvent, carrier_phase) == PANCAKE_DRIVER_EVENT_CARRIER_PHASE_OFF);
	assert!(offset_of!(PancakeDriverEvent, carrier_detail_flags) == PANCAKE_DRIVER_EVENT_CARRIER_DETAIL_FLAGS_OFF);
	assert!(
		offset_of!(PancakeDriverEvent, carrier_verification_flags)
			== PANCAKE_DRIVER_EVENT_CARRIER_VERIFICATION_FLAGS_OFF
	);
	assert!(offset_of!(PancakeDriverEvent, carrier_peer_alert) == PANCAKE_DRIVER_EVENT_CARRIER_PEER_ALERT_OFF);
	assert!(offset_of!(PancakeDriverEvent, carrier_engine_code) == PANCAKE_DRIVER_EVENT_CARRIER_ENGINE_CODE_OFF);
	assert!(offset_of!(PancakeDriverEvent, operation_id) == PANCAKE_DRIVER_EVENT_OPERATION_ID_OFF);
	assert!(offset_of!(PancakeDriverEvent, listener_id) == PANCAKE_DRIVER_EVENT_LISTENER_ID_OFF);
	assert!(offset_of!(PancakeDriverEvent, session) == PANCAKE_DRIVER_EVENT_SESSION_OFF);
	assert!(offset_of!(PancakeDriverEvent, action) == PANCAKE_DRIVER_EVENT_ACTION_OFF);
	assert!(offset_of!(PancakeDriverEvent, primary_name) == PANCAKE_DRIVER_EVENT_PRIMARY_NAME_OFF);
	assert!(offset_of!(PancakeDriverEvent, primary_name_len) == PANCAKE_DRIVER_EVENT_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(PancakeDriverEvent, secondary_name) == PANCAKE_DRIVER_EVENT_SECONDARY_NAME_OFF);
	assert!(offset_of!(PancakeDriverEvent, secondary_name_len) == PANCAKE_DRIVER_EVENT_SECONDARY_NAME_LEN_OFF);
};

#[repr(C)]
pub struct PancakeTransportOperationOptions {
	pub data: *const c_void,
	pub size: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeTransportOperationOptions>() == PANCAKE_TRANSPORT_OPERATION_OPTIONS_SIZE);
	assert!(offset_of!(PancakeTransportOperationOptions, data) == PANCAKE_TRANSPORT_OPERATION_OPTIONS_DATA_OFF);
	assert!(offset_of!(PancakeTransportOperationOptions, size) == PANCAKE_TRANSPORT_OPERATION_OPTIONS_SIZE_OFF);
};

pub use super::driver_fns_gen::*;
