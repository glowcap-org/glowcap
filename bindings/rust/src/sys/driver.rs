//! Raw FFI for the `glowcap_driver_*` driver loop family.
//!
//! Transport archives expose a small provider package header. The driver
//! copies the package's private implementation tables, so this binding does
//! not mirror stream or multiplexed execution-model vtables.

use core::ffi::{c_int, c_uchar, c_uint, c_void};

use super::host::{GlowcapHostAction, GlowcapHostSession};
use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapDriverLoop {
	_private: [u8; 0],
}

#[repr(C)]
pub struct GlowcapDriverOptions {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub wire_buffer_bytes: usize,
	pub max_pending_opens: usize,
	pub handshake_ms: c_uint,
	pub listener_setup_ms: c_uint,
	pub settle_ms: c_uint,
	pub busy_poll_ns: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapDriverFailure {
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
	assert!(size_of::<GlowcapDriverOptions>() == GLOWCAP_DRIVER_OPTIONS_SIZE);
	assert!(offset_of!(GlowcapDriverOptions, abi_version) == GLOWCAP_DRIVER_OPTIONS_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapDriverOptions, struct_size) == GLOWCAP_DRIVER_OPTIONS_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapDriverOptions, wire_buffer_bytes) == GLOWCAP_DRIVER_OPTIONS_WIRE_BUFFER_BYTES_OFF);
	assert!(offset_of!(GlowcapDriverOptions, max_pending_opens) == GLOWCAP_DRIVER_OPTIONS_MAX_PENDING_OPENS_OFF);
	assert!(offset_of!(GlowcapDriverOptions, handshake_ms) == GLOWCAP_DRIVER_OPTIONS_HANDSHAKE_MS_OFF);
	assert!(offset_of!(GlowcapDriverOptions, listener_setup_ms) == GLOWCAP_DRIVER_OPTIONS_LISTENER_SETUP_MS_OFF);
	assert!(offset_of!(GlowcapDriverOptions, settle_ms) == GLOWCAP_DRIVER_OPTIONS_SETTLE_MS_OFF);
	assert!(offset_of!(GlowcapDriverOptions, busy_poll_ns) == GLOWCAP_DRIVER_OPTIONS_BUSY_POLL_NS_OFF);
};

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapDriverFailure>() == GLOWCAP_DRIVER_FAILURE_SIZE);
	assert!(offset_of!(GlowcapDriverFailure, abi_version) == GLOWCAP_DRIVER_FAILURE_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapDriverFailure, struct_size) == GLOWCAP_DRIVER_FAILURE_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapDriverFailure, primary_result) == GLOWCAP_DRIVER_FAILURE_PRIMARY_RESULT_OFF);
	assert!(offset_of!(GlowcapDriverFailure, secondary_result) == GLOWCAP_DRIVER_FAILURE_SECONDARY_RESULT_OFF);
	assert!(offset_of!(GlowcapDriverFailure, secondary_count) == GLOWCAP_DRIVER_FAILURE_SECONDARY_COUNT_OFF);
	assert!(offset_of!(GlowcapDriverFailure, carrier_phase) == GLOWCAP_DRIVER_FAILURE_CARRIER_PHASE_OFF);
	assert!(offset_of!(GlowcapDriverFailure, carrier_detail_flags) == GLOWCAP_DRIVER_FAILURE_CARRIER_DETAIL_FLAGS_OFF);
	assert!(
		offset_of!(GlowcapDriverFailure, carrier_verification_flags)
			== GLOWCAP_DRIVER_FAILURE_CARRIER_VERIFICATION_FLAGS_OFF
	);
	assert!(offset_of!(GlowcapDriverFailure, carrier_peer_alert) == GLOWCAP_DRIVER_FAILURE_CARRIER_PEER_ALERT_OFF);
	assert!(offset_of!(GlowcapDriverFailure, carrier_engine_code) == GLOWCAP_DRIVER_FAILURE_CARRIER_ENGINE_CODE_OFF);
	assert!(offset_of!(GlowcapDriverFailure, primary_name) == GLOWCAP_DRIVER_FAILURE_PRIMARY_NAME_OFF);
	assert!(offset_of!(GlowcapDriverFailure, primary_name_len) == GLOWCAP_DRIVER_FAILURE_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapDriverFailure, secondary_name) == GLOWCAP_DRIVER_FAILURE_SECONDARY_NAME_OFF);
	assert!(offset_of!(GlowcapDriverFailure, secondary_name_len) == GLOWCAP_DRIVER_FAILURE_SECONDARY_NAME_LEN_OFF);
};

#[repr(C)]
pub struct GlowcapDriverEvent {
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
	pub session: *mut GlowcapHostSession,
	pub action: GlowcapHostAction,
	pub primary_name: *const c_uchar,
	pub primary_name_len: usize,
	pub secondary_name: *const c_uchar,
	pub secondary_name_len: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapDriverEvent>() == GLOWCAP_DRIVER_EVENT_SIZE);
	assert!(offset_of!(GlowcapDriverEvent, kind) == GLOWCAP_DRIVER_EVENT_KIND_OFF);
	assert!(offset_of!(GlowcapDriverEvent, primary_result) == GLOWCAP_DRIVER_EVENT_PRIMARY_RESULT_OFF);
	assert!(offset_of!(GlowcapDriverEvent, secondary_result) == GLOWCAP_DRIVER_EVENT_SECONDARY_RESULT_OFF);
	assert!(offset_of!(GlowcapDriverEvent, secondary_count) == GLOWCAP_DRIVER_EVENT_SECONDARY_COUNT_OFF);
	assert!(offset_of!(GlowcapDriverEvent, carrier_phase) == GLOWCAP_DRIVER_EVENT_CARRIER_PHASE_OFF);
	assert!(offset_of!(GlowcapDriverEvent, carrier_detail_flags) == GLOWCAP_DRIVER_EVENT_CARRIER_DETAIL_FLAGS_OFF);
	assert!(
		offset_of!(GlowcapDriverEvent, carrier_verification_flags)
			== GLOWCAP_DRIVER_EVENT_CARRIER_VERIFICATION_FLAGS_OFF
	);
	assert!(offset_of!(GlowcapDriverEvent, carrier_peer_alert) == GLOWCAP_DRIVER_EVENT_CARRIER_PEER_ALERT_OFF);
	assert!(offset_of!(GlowcapDriverEvent, carrier_engine_code) == GLOWCAP_DRIVER_EVENT_CARRIER_ENGINE_CODE_OFF);
	assert!(offset_of!(GlowcapDriverEvent, operation_id) == GLOWCAP_DRIVER_EVENT_OPERATION_ID_OFF);
	assert!(offset_of!(GlowcapDriverEvent, listener_id) == GLOWCAP_DRIVER_EVENT_LISTENER_ID_OFF);
	assert!(offset_of!(GlowcapDriverEvent, session) == GLOWCAP_DRIVER_EVENT_SESSION_OFF);
	assert!(offset_of!(GlowcapDriverEvent, action) == GLOWCAP_DRIVER_EVENT_ACTION_OFF);
	assert!(offset_of!(GlowcapDriverEvent, primary_name) == GLOWCAP_DRIVER_EVENT_PRIMARY_NAME_OFF);
	assert!(offset_of!(GlowcapDriverEvent, primary_name_len) == GLOWCAP_DRIVER_EVENT_PRIMARY_NAME_LEN_OFF);
	assert!(offset_of!(GlowcapDriverEvent, secondary_name) == GLOWCAP_DRIVER_EVENT_SECONDARY_NAME_OFF);
	assert!(offset_of!(GlowcapDriverEvent, secondary_name_len) == GLOWCAP_DRIVER_EVENT_SECONDARY_NAME_LEN_OFF);
};

#[repr(C)]
pub struct GlowcapTransportOperationOptions {
	pub data: *const c_void,
	pub size: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapTransportOperationOptions>() == GLOWCAP_TRANSPORT_OPERATION_OPTIONS_SIZE);
	assert!(offset_of!(GlowcapTransportOperationOptions, data) == GLOWCAP_TRANSPORT_OPERATION_OPTIONS_DATA_OFF);
	assert!(offset_of!(GlowcapTransportOperationOptions, size) == GLOWCAP_TRANSPORT_OPERATION_OPTIONS_SIZE_OFF);
};

pub use super::driver_fns_gen::*;
