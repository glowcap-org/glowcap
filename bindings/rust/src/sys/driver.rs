//! Raw FFI for the byte-fed host archive (`libpancake_driver`, ADR-0072).
//!
//! The archive is a companion of `libpancake_ocapn`: it exports only the
//! `pancake_host_*` family and shares the frame, argument, reference, and
//! last-abort layouts declared in [`super::ocapn`] by *layout*, so this module
//! declares no core symbol. The host surface over it lives in `crate::host`,
//! `crate::trampoline`, and `crate::session`.
//!
//! Callback discipline: the ONE native *behavior* callback in the whole
//! binding — the shared trampoline (`crate::trampoline`) — fires synchronously
//! on the thread executing the enclosing `pancake_host_*` call. Settlements
//! carry no callback at all: they ride the action queue as SETTLE/FAIL and the
//! drain routes them by vow id (`crate::host`). Sync park arms for
//! `pancake_host_pump_drain` are a separate, short-lived callback family owned
//! by `crate::action` for the duration of each C drain. `fetch`/`enliven`/
//! `send` and the `vow_*` verbs each mint a host vow whose id lands in the
//! trailing out-param; the outcome arrives as that vow's SETTLE/FAIL action.
use core::ffi::{c_int, c_uchar, c_uint, c_void};

use super::layouts_gen::*;
use crate::sys::{
	PancakeArgument, PancakeContext, PancakeLastAbort, PancakeManagedFrame, PancakeReference,
};

/// A byte-fed multi-session CapTP host: one identity, one routing and
/// redeem authority, many sessions (`pancake_driver.h`, ADR-0072).
#[repr(C)]
pub struct PancakeHost {
	_private: [u8; 0],
}

/// One byte-fed CapTP session a host minted. Released by
/// `pancake_host_session_release`, always before the host.
#[repr(C)]
pub struct PancakeHostSession {
	_private: [u8; 0],
}

/// The current turn, passed to a behavior callback so it can forward, spawn,
/// and break while handling a deliver. Valid only for that callback's
/// duration.
#[repr(C)]
pub struct PancakeHostTurn {
	_private: [u8; 0],
}

/// A hosted object's behavior (`PancakeHostBehavior` in `pancake_driver.h`):
/// verb/args are borrowed for the call, and the vat copies `out_reply`'s
/// payload the instant the callback returns, so the reply's bytes must stay
/// valid across the return.
pub type PancakeHostBehavior = unsafe extern "C" fn(
	ctx: *mut c_void,
	turn: *mut PancakeHostTurn,
	verb: *const c_uchar,
	verb_len: usize,
	args: *const PancakeArgument,
	args_len: usize,
	out_reply: *mut PancakeArgument,
) -> c_int;

/// Release a hosted object's ctx when the object is torn down
/// (`PancakeHostCtxFree`). Runs exactly once per registration that took
/// ownership; must call no `pancake_host_*` function.
pub type PancakeHostCtxFree = unsafe extern "C" fn(ctx: *mut c_void);

/// One embedder effect popped from `pancake_host_next_action` — hand-mirrored
/// field-for-field from `PancakeHostAction` in `include/pancake_driver.h`, the
/// same standing gap the Racket and Python FFIs carry: Rust has no layout
/// generator, so a C-side struct change must be swept here by hand (the const
/// assert block below fails the build when this mirror and its documented
/// layout disagree). `kind` selects the live fields; every popped byte view
/// and `value`'s sub-structure are host-owned and valid until the NEXT
/// `pancake_host_next_action` call.
#[repr(C)]
pub struct PancakeHostAction {
	/// A `PANCAKE_HOST_ACTION_*` value.
	pub kind: c_uint,
	/// DIAL: the report-back handle; SETTLE/FAIL: the vow that settled.
	pub ticket: u64,
	pub conn: *mut PancakeHostSession,
	pub locator: *const c_uchar,
	pub locator_len: usize,
	pub transport: *const c_uchar,
	pub transport_len: usize,
	pub designator: *const c_uchar,
	pub designator_len: usize,
	pub direct_addresses_hint: *const c_uchar,
	pub direct_addresses_hint_len: usize,
	/// SETTLE: the fulfilled value; zeroed otherwise.
	pub value: PancakeArgument,
	/// FAIL: the break reason; NULL otherwise.
	pub message: *const c_uchar,
	pub message_len: usize,
}

// Pin the hand-mirrored layout on LP64 (the linux x86_64/aarch64 targets the
// gates run): a field added or reordered on either side moves an offset and
// fails the build loudly instead of misrouting the first popped action.
// Expected values come from `layouts_gen` (`zig build gen-binding-ffi-layouts`),
// reflected off the real Zig C ABI types, so this pin cannot drift from them.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeReference>() == PANCAKE_REFERENCE_SIZE);
	assert!(size_of::<PancakeArgument>() == PANCAKE_ARGUMENT_SIZE);
	assert!(size_of::<PancakeHostAction>() == PANCAKE_HOST_ACTION_SIZE);
	assert!(offset_of!(PancakeHostAction, kind) == PANCAKE_HOST_ACTION_KIND_OFF);
	assert!(offset_of!(PancakeHostAction, ticket) == PANCAKE_HOST_ACTION_TICKET_OFF);
	assert!(offset_of!(PancakeHostAction, conn) == PANCAKE_HOST_ACTION_SESSION_OFF);
	assert!(offset_of!(PancakeHostAction, locator) == PANCAKE_HOST_ACTION_LOCATOR_OFF);
	assert!(offset_of!(PancakeHostAction, locator_len) == PANCAKE_HOST_ACTION_LOCATOR_LEN_OFF);
	assert!(offset_of!(PancakeHostAction, transport) == PANCAKE_HOST_ACTION_TRANSPORT_OFF);
	assert!(offset_of!(PancakeHostAction, transport_len) == PANCAKE_HOST_ACTION_TRANSPORT_LEN_OFF);
	assert!(offset_of!(PancakeHostAction, designator) == PANCAKE_HOST_ACTION_DESIGNATOR_OFF);
	assert!(
		offset_of!(PancakeHostAction, designator_len) == PANCAKE_HOST_ACTION_DESIGNATOR_LEN_OFF
	);
	assert!(
		offset_of!(PancakeHostAction, direct_addresses_hint)
			== PANCAKE_HOST_ACTION_DIRECT_ADDRESSES_HINT_OFF
	);
	assert!(
		offset_of!(PancakeHostAction, direct_addresses_hint_len)
			== PANCAKE_HOST_ACTION_DIRECT_ADDRESSES_HINT_LEN_OFF
	);
	assert!(offset_of!(PancakeHostAction, value) == PANCAKE_HOST_ACTION_VALUE_OFF);
	assert!(offset_of!(PancakeHostAction, message) == PANCAKE_HOST_ACTION_MESSAGE_OFF);
	assert!(offset_of!(PancakeHostAction, message_len) == PANCAKE_HOST_ACTION_MESSAGE_LEN_OFF);
};

/// One shared arm callback for `PancakeHostPumpHooks` (flush, close,
/// need_gift_id, complete for SETTLE/FAIL, dial). Sync only — bindings park
/// decoded actions and await after `pancake_host_pump_drain` returns.
pub type PancakeHostPumpArmFn = unsafe extern "C" fn(
	ctx: *mut c_void,
	host: *mut PancakeHost,
	action: *const PancakeHostAction,
	out_progressed: *mut u32,
) -> c_int;

/// Opt-in embedder hooks for `pancake_host_pump_drain` (ADR-0072 fifth
/// amendment). NULL arm pointers skip that kind. Hand-mirrored from
/// `pancake_driver.h`; the const assert block below pins the LP64 layout.
#[repr(C)]
pub struct PancakeHostPumpHooks {
	pub ctx: *mut c_void,
	pub flush: Option<PancakeHostPumpArmFn>,
	pub close: Option<PancakeHostPumpArmFn>,
	pub need_gift_id: Option<PancakeHostPumpArmFn>,
	pub complete: Option<PancakeHostPumpArmFn>,
	pub dial: Option<PancakeHostPumpArmFn>,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeHostPumpHooks>() == PANCAKE_HOST_PUMP_HOOKS_SIZE);
	assert!(offset_of!(PancakeHostPumpHooks, ctx) == PANCAKE_HOST_PUMP_HOOKS_CTX_OFF);
	assert!(offset_of!(PancakeHostPumpHooks, flush) == PANCAKE_HOST_PUMP_HOOKS_FLUSH_OFF);
	assert!(offset_of!(PancakeHostPumpHooks, close) == PANCAKE_HOST_PUMP_HOOKS_CLOSE_OFF);
	assert!(
		offset_of!(PancakeHostPumpHooks, need_gift_id) == PANCAKE_HOST_PUMP_HOOKS_NEED_GIFT_ID_OFF
	);
	assert!(offset_of!(PancakeHostPumpHooks, complete) == PANCAKE_HOST_PUMP_HOOKS_COMPLETE_OFF);
	assert!(offset_of!(PancakeHostPumpHooks, dial) == PANCAKE_HOST_PUMP_HOOKS_DIAL_OFF);
};

/// The resolved dial `pancake_host_plan_dial` hands back: `shape` selects the
/// live fields (HOST_PORT fills host/port, IROH fills addresses/reach). host and
/// addresses borrow the caller's transport/designator/hint input buffers.
#[repr(C)]
pub struct PancakeDialPlan {
	pub shape: c_uint,
	pub host: *const c_uchar,
	pub host_len: usize,
	pub port: u16,
	pub addresses: *const c_uchar,
	pub addresses_len: usize,
	pub reach_kind: c_uint,
	pub reach_value: c_uint,
}

// Pin the hand-mirrored layout on LP64, against `layouts_gen`
// (`zig build gen-binding-ffi-layouts`), reflected off the real Zig
// `PancakeDialPlan`.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeDialPlan>() == PANCAKE_DIAL_PLAN_SIZE);
	assert!(offset_of!(PancakeDialPlan, shape) == PANCAKE_DIAL_PLAN_SHAPE_OFF);
	assert!(offset_of!(PancakeDialPlan, host) == PANCAKE_DIAL_PLAN_HOST_OFF);
	assert!(offset_of!(PancakeDialPlan, host_len) == PANCAKE_DIAL_PLAN_HOST_LEN_OFF);
	assert!(offset_of!(PancakeDialPlan, port) == PANCAKE_DIAL_PLAN_PORT_OFF);
	assert!(offset_of!(PancakeDialPlan, addresses) == PANCAKE_DIAL_PLAN_ADDRESSES_OFF);
	assert!(offset_of!(PancakeDialPlan, addresses_len) == PANCAKE_DIAL_PLAN_ADDRESSES_LEN_OFF);
	assert!(offset_of!(PancakeDialPlan, reach_kind) == PANCAKE_DIAL_PLAN_REACH_KIND_OFF);
	assert!(offset_of!(PancakeDialPlan, reach_value) == PANCAKE_DIAL_PLAN_REACH_VALUE_OFF);
};

extern "C" {
	// Lifecycle.
	pub fn pancake_host_new(
		seed: *const c_uchar,
		seed_len: usize,
		frame_cap: usize,
		verify_partner: c_uint,
		codec: c_uint,
		local_turn_budget: c_uint,
		out_host: *mut *mut PancakeHost,
	) -> c_int;
	pub fn pancake_host_new_in(
		context: *mut PancakeContext,
		seed: *const c_uchar,
		seed_len: usize,
		frame_cap: usize,
		verify_partner: c_uint,
		codec: c_uint,
		local_turn_budget: c_uint,
		out_host: *mut *mut PancakeHost,
	) -> c_int;
	pub fn pancake_host_release(host: *mut PancakeHost);
	pub fn pancake_host_designator_from_seed(
		seed: *const c_uchar,
		seed_len: usize,
		out: *mut c_uchar,
		out_len: usize,
	) -> c_int;
	pub fn pancake_host_set_self_designator(
		host: *mut PancakeHost,
		designator: *const c_uchar,
		len: usize,
	) -> c_int;
	pub fn pancake_host_set_session_limits(
		host: *mut PancakeHost,
		max_frame_bytes: usize,
		queue_cap: usize,
	) -> c_int;
	pub fn pancake_host_session_open_dialed_locator(
		host: *mut PancakeHost,
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		out_conn: *mut *mut PancakeHostSession,
	) -> c_int;
	/// Resolve a dial to a `PancakeDialPlan` (grammar + hint + iroh posture); a
	/// free function, no host handle. The one call every binding's dial funnels
	/// through so no dial dispatch/grammar/reachability lives in the binding.
	pub fn pancake_host_plan_dial(
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		direct_addresses_hint: *const c_uchar,
		direct_addresses_hint_len: usize,
		posture_policy: c_uint,
		posture_value: c_uint,
		out_plan: *mut PancakeDialPlan,
	) -> c_int;
	pub fn pancake_host_session_open_accepted(
		host: *mut PancakeHost,
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		direct_addresses_hint: *const c_uchar,
		direct_addresses_hint_len: usize,
		out_conn: *mut *mut PancakeHostSession,
	) -> c_int;
	pub fn pancake_host_session_release(conn: *mut PancakeHostSession);
	pub fn pancake_host_session_session_open(conn: *mut PancakeHostSession) -> c_int;

	// The byte pump and action queue.
	pub fn pancake_host_session_feed_bytes(
		conn: *mut PancakeHostSession,
		bytes: *const c_uchar,
		len: usize,
		out_consumed: *mut usize,
	) -> c_int;
	pub fn pancake_host_session_take_outbound(
		conn: *mut PancakeHostSession,
		out_frame: *mut PancakeManagedFrame,
	) -> c_int;
	pub fn pancake_host_pump_drain(
		host: *mut PancakeHost,
		hooks: *const PancakeHostPumpHooks,
		out_acted: *mut u32,
	) -> c_int;
	pub fn pancake_host_dialed(
		host: *mut PancakeHost,
		ticket: u64,
		conn: *mut PancakeHostSession,
	) -> c_int;
	pub fn pancake_host_dial_failed(
		host: *mut PancakeHost,
		ticket: u64,
		reason: *const c_uchar,
		reason_len: usize,
	) -> c_int;
	pub fn pancake_host_provide_gift_id(
		host: *mut PancakeHost,
		ticket: u64,
		gift_id: *const c_uchar,
		gift_id_len: usize,
	) -> c_int;

	// Publish and spawn (behavior = the shared trampoline, ctx = a
	// `Box<ActorCell>` raw pointer, free = the ctx-free sibling, so teardown is
	// exactly-once and host-driven).
	pub fn pancake_host_session_publish(
		conn: *mut PancakeHostSession,
		name: *const c_uchar,
		name_len: usize,
		behavior: PancakeHostBehavior,
		ctx: *mut c_void,
		free: PancakeHostCtxFree,
		out_export_position: *mut u64,
	) -> c_int;
	pub fn pancake_host_session_spawn(
		conn: *mut PancakeHostSession,
		behavior: PancakeHostBehavior,
		ctx: *mut c_void,
		free: PancakeHostCtxFree,
		out_export_position: *mut u64,
	) -> c_int;
	pub fn pancake_host_publish(
		host: *mut PancakeHost,
		name: *const c_uchar,
		name_len: usize,
		behavior: PancakeHostBehavior,
		ctx: *mut c_void,
		free: PancakeHostCtxFree,
	) -> c_int;

	// Fetch and enliven — each mints a host vow (out param).
	pub fn pancake_host_session_fetch(
		conn: *mut PancakeHostSession,
		name: *const c_uchar,
		name_len: usize,
		out_vow: *mut u64,
	) -> c_int;
	pub fn pancake_host_session_enliven(
		conn: *mut PancakeHostSession,
		swissnum: *const c_uchar,
		swissnum_len: usize,
		out_vow: *mut u64,
	) -> c_int;

	// Send, tell, vows, projections.
	pub fn pancake_host_session_send(
		conn: *mut PancakeHostSession,
		target: *const PancakeReference,
		verb: *const c_uchar,
		verb_len: usize,
		args: *const PancakeArgument,
		args_len: usize,
		out_vow: *mut u64,
	) -> c_int;
	pub fn pancake_host_session_tell(
		conn: *mut PancakeHostSession,
		target: *const PancakeReference,
		verb: *const c_uchar,
		verb_len: usize,
		args: *const PancakeArgument,
		args_len: usize,
	) -> c_int;
	pub fn pancake_host_vow_send(
		host: *mut PancakeHost,
		vow: u64,
		verb: *const c_uchar,
		verb_len: usize,
		args: *const PancakeArgument,
		args_len: usize,
		out_vow: *mut u64,
	) -> c_int;
	pub fn pancake_host_vow_index(
		host: *mut PancakeHost,
		vow: u64,
		index: u64,
		out_vow: *mut u64,
	) -> c_int;
	pub fn pancake_host_vow_untag(
		host: *mut PancakeHost,
		vow: u64,
		tag: *const c_uchar,
		tag_len: usize,
		out_vow: *mut u64,
	) -> c_int;

	// Turn verbs (legal only inside a behavior callback). `turn_forward`'s
	// out-reply is the raw pointer the trampoline was handed.
	pub fn pancake_host_turn_forward(
		turn: *mut PancakeHostTurn,
		target: *const PancakeReference,
		verb: *const c_uchar,
		verb_len: usize,
		args: *const PancakeArgument,
		args_len: usize,
		out_reply: *mut PancakeArgument,
	) -> c_int;
	pub fn pancake_host_turn_spawn(
		turn: *mut PancakeHostTurn,
		behavior: PancakeHostBehavior,
		ctx: *mut c_void,
		free: PancakeHostCtxFree,
		out_export_position: *mut u64,
	) -> c_int;
	pub fn pancake_host_turn_break(
		turn: *mut PancakeHostTurn,
		message: *const c_uchar,
		message_len: usize,
	) -> c_int;

	// GC, teardown, diagnostics.
	pub fn pancake_host_gc_release(host: *mut PancakeHost, token: u64, delta: u64) -> c_int;
	pub fn pancake_host_session_break_far_vows(
		conn: *mut PancakeHostSession,
		message: *const c_uchar,
		message_len: usize,
	) -> c_int;
	pub fn pancake_host_session_set_exporter_location(
		conn: *mut PancakeHostSession,
		locator: *const c_uchar,
		locator_len: usize,
	) -> c_int;
	pub fn pancake_host_session_last_abort(
		conn: *mut PancakeHostSession,
		out: *mut PancakeLastAbort,
	) -> c_int;
	pub fn pancake_host_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
}
