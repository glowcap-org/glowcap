//! Raw FFI for the byte-fed host archive (`libpancake_driver`, ADR-0072).
//!
//! The archive is a companion of `libpancake_ocapn`: it exports only the
//! `pancake_host_*` family and shares the frame, argument, reference, and
//! last-abort layouts declared in [`super::ocapn`] by *layout*, so this module
//! declares no core symbol. The host surface over it lives in `crate::host`,
//! `crate::trampoline`, and `crate::session`.
//!
//! Callback discipline: the ONE native callback in the whole binding — the
//! shared behavior trampoline (`crate::trampoline`) — fires synchronously on
//! the thread executing the enclosing `pancake_host_*` call. Settlements carry
//! no callback at all: they ride the action queue as SETTLE/FAIL and the drain
//! routes them by vow id (`crate::host`). `fetch`/`enliven`/`send` and the
//! `vow_*` verbs each mint a host vow whose id lands in the trailing
//! out-param; the outcome arrives as that vow's SETTLE/FAIL action.
use core::ffi::{c_int, c_uchar, c_uint, c_void};

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
// Provenance: include/pancake_driver.h `PancakeHostAction`, whose C layout on
// LP64 is kind@0 (4 pad), ticket@8, conn@16, four ptr+len view pairs from 24,
// the 72-byte PancakeArgument by value @88, and message/message_len @160/@168.
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeReference>() == 16);
	assert!(size_of::<PancakeArgument>() == 72);
	assert!(size_of::<PancakeHostAction>() == 176);
	assert!(offset_of!(PancakeHostAction, kind) == 0);
	assert!(offset_of!(PancakeHostAction, ticket) == 8);
	assert!(offset_of!(PancakeHostAction, conn) == 16);
	assert!(offset_of!(PancakeHostAction, locator) == 24);
	assert!(offset_of!(PancakeHostAction, locator_len) == 32);
	assert!(offset_of!(PancakeHostAction, transport) == 40);
	assert!(offset_of!(PancakeHostAction, transport_len) == 48);
	assert!(offset_of!(PancakeHostAction, designator) == 56);
	assert!(offset_of!(PancakeHostAction, designator_len) == 64);
	assert!(offset_of!(PancakeHostAction, direct_addresses_hint) == 72);
	assert!(offset_of!(PancakeHostAction, direct_addresses_hint_len) == 80);
	assert!(offset_of!(PancakeHostAction, value) == 88);
	assert!(offset_of!(PancakeHostAction, message) == 160);
	assert!(offset_of!(PancakeHostAction, message_len) == 168);
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

// Pin the hand-mirrored layout on LP64 (include/pancake_driver.h `PancakeDialPlan`).
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<PancakeDialPlan>() == 56);
	assert!(offset_of!(PancakeDialPlan, shape) == 0);
	assert!(offset_of!(PancakeDialPlan, host) == 8);
	assert!(offset_of!(PancakeDialPlan, host_len) == 16);
	assert!(offset_of!(PancakeDialPlan, port) == 24);
	assert!(offset_of!(PancakeDialPlan, addresses) == 32);
	assert!(offset_of!(PancakeDialPlan, addresses_len) == 40);
	assert!(offset_of!(PancakeDialPlan, reach_kind) == 48);
	assert!(offset_of!(PancakeDialPlan, reach_value) == 52);
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
	pub fn pancake_host_next_action(
		host: *mut PancakeHost,
		out_action: *mut PancakeHostAction,
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
