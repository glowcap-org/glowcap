//! Raw FFI for the byte-fed host archive (`libglowcap_host`, ADR-0072).
//!
//! The archive is a companion of `libglowcap_ocapn`: it exports only the
//! `glowcap_host_*` family and shares the frame, argument, reference, and
//! last-abort layouts declared in [`super::ocapn`] by *layout*, so this module
//! declares no core symbol. The host surface over it lives in `crate::host`,
//! `crate::trampoline`, and `crate::session`.
//!
//! Callback discipline: the ONE native *behavior* callback in the whole
//! binding, the shared trampoline (`crate::trampoline`), fires synchronously
//! on the thread executing the enclosing `glowcap_host_*` call. Settlements
//! carry no callback at all: they ride the action queue as SETTLE/FAIL and the
//! drain routes them by vow id (`crate::host`). Sync park arms for
//! `glowcap_host_pump_drain` are a separate, short-lived callback family owned
//! by `crate::action` for the duration of each C drain. `fetch`/`enliven`/
//! `send` and the `vow_*` verbs each mint a host vow whose id lands in the
//! trailing out-param. The outcome arrives as that vow's SETTLE/FAIL action.
use core::ffi::{c_int, c_uchar, c_uint, c_void};

use super::layouts_gen::*;
// The trace record's digest is a fixed-width array, so its width is the
// reflected constant rather than a number retyped here.
use crate::abi_constants::TRACE_DIGEST_BYTES;
use crate::sys::{GlowcapArgument, GlowcapReference};

/// A byte-fed multi-session CapTP host: one identity, one routing and
/// redeem authority, many sessions (`glowcap_host.h`, ADR-0072).
#[repr(C)]
pub struct GlowcapHost {
	_private: [u8; 0],
}

/// One byte-fed CapTP session a host minted. Released by
/// `glowcap_host_session_release`, always before the host.
#[repr(C)]
pub struct GlowcapHostSession {
	_private: [u8; 0],
}

/// Terminal owner-close policy shared by byte-fed Hosts and native drivers.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapCloseOptions {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub pending: c_uint,
	pub grace_mode: c_uint,
	pub grace_ms: c_uint,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapCloseOptions>() == GLOWCAP_CLOSE_OPTIONS_SIZE);
	assert!(offset_of!(GlowcapCloseOptions, abi_version) == GLOWCAP_CLOSE_OPTIONS_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapCloseOptions, struct_size) == GLOWCAP_CLOSE_OPTIONS_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapCloseOptions, pending) == GLOWCAP_CLOSE_OPTIONS_PENDING_OFF);
	assert!(offset_of!(GlowcapCloseOptions, grace_mode) == GLOWCAP_CLOSE_OPTIONS_GRACE_MODE_OFF);
	assert!(offset_of!(GlowcapCloseOptions, grace_ms) == GLOWCAP_CLOSE_OPTIONS_GRACE_MS_OFF);
};

/// Versioned selective overrides for limits copied into future sessions.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapSessionLimitOptions {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub max_frame_bytes: usize,
	pub queue_cap: usize,
	pub outbound_high_water_bytes: usize,
	pub max_retained_sent_answer_bytes: usize,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapSessionLimitOptions>() == GLOWCAP_SESSION_LIMIT_OPTIONS_SIZE);
	assert!(offset_of!(GlowcapSessionLimitOptions, abi_version) == GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapSessionLimitOptions, struct_size) == GLOWCAP_SESSION_LIMIT_OPTIONS_STRUCT_SIZE_OFF);
	assert!(
		offset_of!(GlowcapSessionLimitOptions, max_frame_bytes) == GLOWCAP_SESSION_LIMIT_OPTIONS_MAX_FRAME_BYTES_OFF
	);
	assert!(offset_of!(GlowcapSessionLimitOptions, queue_cap) == GLOWCAP_SESSION_LIMIT_OPTIONS_QUEUE_CAP_OFF);
	assert!(
		offset_of!(GlowcapSessionLimitOptions, outbound_high_water_bytes)
			== GLOWCAP_SESSION_LIMIT_OPTIONS_OUTBOUND_HIGH_WATER_BYTES_OFF
	);
	assert!(
		offset_of!(GlowcapSessionLimitOptions, max_retained_sent_answer_bytes)
			== GLOWCAP_SESSION_LIMIT_OPTIONS_MAX_RETAINED_SENT_ANSWER_BYTES_OFF
	);
};

/// The current turn, passed to a behavior callback so it can forward, spawn,
/// and break while handling a deliver. Valid only for that callback's
/// duration.
#[repr(C)]
pub struct GlowcapHostTurn {
	_private: [u8; 0],
}

/// A hosted object's behavior (`GlowcapHostBehavior` in `glowcap_host.h`):
/// verb/args are borrowed for the call, and the vat copies `out_reply`'s
/// payload the instant the callback returns, so the reply's bytes must stay
/// valid across the return.
pub type GlowcapHostBehavior = unsafe extern "C" fn(
	ctx: *mut c_void,
	turn: *mut GlowcapHostTurn,
	verb: *const c_uchar,
	verb_len: usize,
	args: *const GlowcapArgument,
	args_len: usize,
	out_reply: *mut GlowcapArgument,
) -> c_int;

/// Release a hosted object's ctx when the object is torn down
/// (`GlowcapHostCtxFree`). Runs exactly once per registration that took
/// ownership. Must call no `glowcap_host_*` function.
pub type GlowcapHostCtxFree = unsafe extern "C" fn(ctx: *mut c_void);

/// One embedder effect popped from `glowcap_host_next_action`: hand-mirrored
/// field-for-field from `GlowcapHostAction` in `include/glowcap_host.h`, the
/// same standing gap the Racket and Python FFIs carry: Rust has no layout
/// generator, so a C-side struct change must be swept here by hand (the const
/// assert block below fails the build when this mirror and its documented
/// layout disagree). `kind` selects the live fields. Every popped byte view
/// and `value`'s sub-structure are host-owned and valid until the NEXT
/// `glowcap_host_next_action` call.
#[repr(C)]
pub struct GlowcapHostAction {
	/// A `GLOWCAP_HOST_ACTION_*` value.
	pub kind: c_uint,
	/// DIAL: the report-back handle. SETTLE/FAIL: the vow that settled.
	pub ticket: u64,
	/// DIAL/CANCEL_DIAL: the concrete route within the logical dial.
	pub route_index: usize,
	pub session: *mut GlowcapHostSession,
	/// SETTLE: the fulfilled value. Zeroed otherwise.
	pub value: GlowcapArgument,
	/// FAIL: the break reason. NULL otherwise.
	pub message: *const c_uchar,
	pub message_len: usize,
	/// CLOSE: `OK` or `TIMEOUT`. FAIL: `BROKEN` or `CLOSED`.
	pub result: c_int,
}

// Pin the hand-mirrored layout on LP64 (the linux x86_64/aarch64 targets the
// gates run): a field added or reordered on either side moves an offset and
// fails the build loudly instead of misrouting the first popped action.
// Expected values come from `layouts_gen` (`zig build gen-binding-ffi-layouts`),
// reflected off the real Zig C ABI types, so this pin cannot drift from them.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapReference>() == GLOWCAP_REFERENCE_SIZE);
	assert!(size_of::<GlowcapArgument>() == GLOWCAP_ARGUMENT_SIZE);
	assert!(size_of::<GlowcapHostAction>() == GLOWCAP_HOST_ACTION_SIZE);
	assert!(offset_of!(GlowcapHostAction, kind) == GLOWCAP_HOST_ACTION_KIND_OFF);
	assert!(offset_of!(GlowcapHostAction, ticket) == GLOWCAP_HOST_ACTION_TICKET_OFF);
	assert!(offset_of!(GlowcapHostAction, route_index) == GLOWCAP_HOST_ACTION_ROUTE_INDEX_OFF);
	assert!(offset_of!(GlowcapHostAction, session) == GLOWCAP_HOST_ACTION_SESSION_OFF);
	assert!(offset_of!(GlowcapHostAction, value) == GLOWCAP_HOST_ACTION_VALUE_OFF);
	assert!(offset_of!(GlowcapHostAction, message) == GLOWCAP_HOST_ACTION_MESSAGE_OFF);
	assert!(offset_of!(GlowcapHostAction, message_len) == GLOWCAP_HOST_ACTION_MESSAGE_LEN_OFF);
	assert!(offset_of!(GlowcapHostAction, result) == GLOWCAP_HOST_ACTION_RESULT_OFF);
};

/// One shared arm callback for `GlowcapHostPumpHooks` (flush, close,
/// need_gift_id, complete for SETTLE/FAIL, dial). Sync only: bindings park
/// decoded actions and await after `glowcap_host_pump_drain` returns.
pub type GlowcapHostPumpArmFn = unsafe extern "C" fn(
	ctx: *mut c_void,
	host: *mut GlowcapHost,
	action: *const GlowcapHostAction,
	out_progressed: *mut u32,
) -> c_int;

/// Opt-in embedder hooks for `glowcap_host_pump_drain` (ADR-0072 fifth
/// amendment). NULL arm pointers skip that kind. Hand-mirrored from
/// `glowcap_host.h`. The const assert block below pins the LP64 layout.
#[repr(C)]
pub struct GlowcapHostPumpHooks {
	pub ctx: *mut c_void,
	pub flush: Option<GlowcapHostPumpArmFn>,
	pub close: Option<GlowcapHostPumpArmFn>,
	pub need_gift_id: Option<GlowcapHostPumpArmFn>,
	pub complete: Option<GlowcapHostPumpArmFn>,
	pub dial: Option<GlowcapHostPumpArmFn>,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapHostPumpHooks>() == GLOWCAP_HOST_PUMP_HOOKS_SIZE);
	assert!(offset_of!(GlowcapHostPumpHooks, ctx) == GLOWCAP_HOST_PUMP_HOOKS_CTX_OFF);
	assert!(offset_of!(GlowcapHostPumpHooks, flush) == GLOWCAP_HOST_PUMP_HOOKS_FLUSH_OFF);
	assert!(offset_of!(GlowcapHostPumpHooks, close) == GLOWCAP_HOST_PUMP_HOOKS_CLOSE_OFF);
	assert!(offset_of!(GlowcapHostPumpHooks, need_gift_id) == GLOWCAP_HOST_PUMP_HOOKS_NEED_GIFT_ID_OFF);
	assert!(offset_of!(GlowcapHostPumpHooks, complete) == GLOWCAP_HOST_PUMP_HOOKS_COMPLETE_OFF);
	assert!(offset_of!(GlowcapHostPumpHooks, dial) == GLOWCAP_HOST_PUMP_HOOKS_DIAL_OFF);
};

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapPartnerIdentity>() == GLOWCAP_PARTNER_IDENTITY_SIZE);
	assert!(offset_of!(GlowcapPartnerIdentity, session_key) == GLOWCAP_PARTNER_IDENTITY_SESSION_KEY_OFF);
	assert!(offset_of!(GlowcapPartnerIdentity, session_key_len) == GLOWCAP_PARTNER_IDENTITY_SESSION_KEY_LEN_OFF);
	assert!(offset_of!(GlowcapPartnerIdentity, designator) == GLOWCAP_PARTNER_IDENTITY_DESIGNATOR_OFF);
	assert!(offset_of!(GlowcapPartnerIdentity, designator_len) == GLOWCAP_PARTNER_IDENTITY_DESIGNATOR_LEN_OFF);
	assert!(offset_of!(GlowcapPartnerIdentity, locator_record) == GLOWCAP_PARTNER_IDENTITY_LOCATOR_RECORD_OFF);
	assert!(offset_of!(GlowcapPartnerIdentity, locator_record_len) == GLOWCAP_PARTNER_IDENTITY_LOCATOR_RECORD_LEN_OFF);
	assert!(offset_of!(GlowcapPartnerIdentity, provenance) == GLOWCAP_PARTNER_IDENTITY_PROVENANCE_OFF);
};

/// Borrowed verified partner identity from
/// `glowcap_host_session_partner_identity`: the partner's session public key,
/// the location designator it signed, and the verbatim `<ocapn-peer>` record
/// those came from. The engine checks the handshake signature before it writes
/// any of these bytes, so a success means the whole record was proved. Views
/// are session-owned and live until the session is released. `designator` and
/// `locator_record` are null when the partner's location carried none.
#[repr(C)]
pub struct GlowcapPartnerIdentity {
	pub session_key: *const c_uchar,
	pub session_key_len: usize,
	pub designator: *const c_uchar,
	pub designator_len: usize,
	pub locator_record: *const c_uchar,
	pub locator_record_len: usize,
	/// How the durable identity in `designator` was authenticated, one of the
	/// `DURABLE_PROVENANCE_*` constants (ADR-0097).
	pub provenance: c_uint,
}

/// One live-trace fact (`glowcap_host_set_trace`). `kind` selects the live
/// fields. String views are borrowed for the callback only.
#[repr(C)]
pub struct GlowcapTraceEvent {
	pub kind: u32,
	pub session: u64,
	pub outbound: u8,
	/// SESSION_OPEN: what proved the partner's durable name, as a
	/// `GLOWCAP_DURABLE_PROVENANCE_*` value.
	pub provenance: u32,
	pub codec: u32,
	pub captp_version: u32,
	/// SESSION_OPEN: the partner's OCapN Designator. Half a name on its own:
	/// the spec needs a designator and a transport together to tell two
	/// locations apart, so `transport` travels beside it.
	pub designator: *const c_uchar,
	pub designator_len: usize,
	/// SESSION_OPEN: the locator's OCapN Transport, the netlayer symbol this
	/// session runs over.
	pub transport: *const c_uchar,
	pub transport_len: usize,
	/// SESSION_OPEN: the OCapN Session ID, which both peers of this session
	/// derive to the same value. Not `session` above, which is this host's
	/// own handle and means nothing to anyone else.
	pub session_id: *const c_uchar,
	pub session_id_len: usize,
	pub verb: *const c_uchar,
	pub verb_len: usize,
	pub frame: *const c_uchar,
	pub frame_len: usize,
	pub frame_total_len: usize,
	pub dropped: u64,
	/// A tag over the frame's bytes, naming one message across the two peers
	/// that carried it. Zero on the non-message kinds.
	pub digest: [c_uchar; TRACE_DIGEST_BYTES as usize],
}

// Layout assertions guard this struct as they guard its siblings above. A
// declaration that drifts from the C field set (designator, transport,
// provenance, session_id) still compiles and silently misreads every trace
// fact. Rust cannot check a declaration it is never told to check, so these
// assertions are that instruction.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapTraceEvent>() == GLOWCAP_TRACE_EVENT_SIZE);
	assert!(offset_of!(GlowcapTraceEvent, kind) == GLOWCAP_TRACE_EVENT_KIND_OFF);
	assert!(offset_of!(GlowcapTraceEvent, session) == GLOWCAP_TRACE_EVENT_SESSION_OFF);
	assert!(offset_of!(GlowcapTraceEvent, outbound) == GLOWCAP_TRACE_EVENT_OUTBOUND_OFF);
	assert!(offset_of!(GlowcapTraceEvent, provenance) == GLOWCAP_TRACE_EVENT_PROVENANCE_OFF);
	assert!(offset_of!(GlowcapTraceEvent, codec) == GLOWCAP_TRACE_EVENT_CODEC_OFF);
	assert!(offset_of!(GlowcapTraceEvent, captp_version) == GLOWCAP_TRACE_EVENT_CAPTP_VERSION_OFF);
	assert!(offset_of!(GlowcapTraceEvent, designator) == GLOWCAP_TRACE_EVENT_DESIGNATOR_OFF);
	assert!(offset_of!(GlowcapTraceEvent, designator_len) == GLOWCAP_TRACE_EVENT_DESIGNATOR_LEN_OFF);
	assert!(offset_of!(GlowcapTraceEvent, transport) == GLOWCAP_TRACE_EVENT_TRANSPORT_OFF);
	assert!(offset_of!(GlowcapTraceEvent, transport_len) == GLOWCAP_TRACE_EVENT_TRANSPORT_LEN_OFF);
	assert!(offset_of!(GlowcapTraceEvent, session_id) == GLOWCAP_TRACE_EVENT_SESSION_ID_OFF);
	assert!(offset_of!(GlowcapTraceEvent, session_id_len) == GLOWCAP_TRACE_EVENT_SESSION_ID_LEN_OFF);
	assert!(offset_of!(GlowcapTraceEvent, verb) == GLOWCAP_TRACE_EVENT_VERB_OFF);
	assert!(offset_of!(GlowcapTraceEvent, verb_len) == GLOWCAP_TRACE_EVENT_VERB_LEN_OFF);
	assert!(offset_of!(GlowcapTraceEvent, frame) == GLOWCAP_TRACE_EVENT_FRAME_OFF);
	assert!(offset_of!(GlowcapTraceEvent, frame_len) == GLOWCAP_TRACE_EVENT_FRAME_LEN_OFF);
	assert!(offset_of!(GlowcapTraceEvent, frame_total_len) == GLOWCAP_TRACE_EVENT_FRAME_TOTAL_LEN_OFF);
	assert!(offset_of!(GlowcapTraceEvent, dropped) == GLOWCAP_TRACE_EVENT_DROPPED_OFF);
	assert!(offset_of!(GlowcapTraceEvent, digest) == GLOWCAP_TRACE_EVENT_DIGEST_OFF);
};

/// The trace callback: called synchronously at the fact site, on the host's
/// one thread, with `event` and its views borrowed for the call.
pub type GlowcapTraceCallback = Option<unsafe extern "C" fn(ctx: *mut c_void, event: *const GlowcapTraceEvent)>;

// The raw extern block is generated (`host_fns_gen.rs`, `zig build
// gen-binding-rust-ffi`): types reflected from the Zig exports, parameter
// names from the generated C header. Re-exported here so consumers keep
// their `sys::host::glowcap_host_*` paths.
pub use super::host_fns_gen::*;
