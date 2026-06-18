//! Raw FFI for the core archive (`libpancake_ocapn`).
//!
//! This is the universal base every build links: the context, peer, frame,
//! value/event, and URI/locator vocabulary `pancake_ocapn.h` declares, plus
//! `pancake_abi_version` and the ocapn-family `pancake_last_error`. The shared
//! frame and context types live here because the transport archives agree on
//! their *layout* (ADR-0059); a transport's own `sys/<t>.rs` declares only its
//! handle types and `pancake_<t>_*` family.
//!
//! It declares the full core surface, so not every constant or extern is used
//! by the safe wrapper yet (e.g. `ERR_CLOSED`, `REF_BROKEN` round out their
//! enums). Dead code is expected of a `sys` layer and allowed only here.
#![allow(dead_code)]

use core::ffi::{c_int, c_uchar, c_uint, c_void};

#[repr(C)]
pub struct PancakePeer {
	_private: [u8; 0],
}

#[repr(C)]
pub struct PancakeContext {
	_private: [u8; 0],
}

/// A parsed OCapN locator — one opaque handle carrying a peer or a sturdyref,
/// minted by `pancake_uri_parse_*` and read by the `pancake_locator_*`
/// accessors.
#[repr(C)]
pub struct PancakeLocator {
	_private: [u8; 0],
}

/// A vat-scoped deposited-gift table a node shares across the peers of one node
/// (ADR-0009/ADR-0056), minted by `pancake_gift_registry_new` and bound onto a
/// peer with `pancake_peer_set_gift_registry`. Borrowed by every peer it is set
/// on; it must outlive all of them.
#[repr(C)]
pub struct PancakeGiftRegistry {
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
pub struct PancakeEvent {
	pub kind: c_uint,
	pub frame: PancakeManagedFrame,
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
pub struct PancakeDeliver {
	pub target: PancakeReference,
	pub args: *const PancakeArgument,
	pub args_len: usize,
	pub has_answer: c_uint,
	pub answer: u64,
	pub owner: *mut c_void,
}

#[repr(C)]
pub struct PancakeHandoffGive {
	pub give: *const c_uchar,
	pub give_len: usize,
	pub exporter_locator: *const c_uchar,
	pub exporter_locator_len: usize,
	pub recipient_key: *const c_uchar,
	pub recipient_key_len: usize,
}

#[repr(C)]
pub struct PancakeResolve {
	pub answer: u64,
	pub resolution_kind: c_uint,
	pub fulfill: PancakeArgument,
	pub break_message: *const c_uchar,
	pub break_message_len: usize,
	// Carried by value inside PancakeResolve even when the binding never reads a
	// handoff; omitting it makes the struct too small and
	// pancake_peer_poll_event_resolve writes past it.
	pub handoff: PancakeHandoffGive,
	pub owner: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeEnlivenStart {
	/// A `ENLIVEN_*` status selecting the live fields.
	pub status: c_uint,
	/// `_CACHED` far reference kind: a `REF_SUB_*` value.
	pub kind: c_uint,
	/// `_FRESH`/`_IN_FLIGHT` question id to drive.
	pub answer: u64,
	/// `_CACHED` far import position.
	pub import_position: u64,
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

	pub fn pancake_peer_new(peer: *mut *mut PancakePeer) -> c_int;
	pub fn pancake_peer_new_in(context: *mut PancakeContext, peer: *mut *mut PancakePeer) -> c_int;
	pub fn pancake_peer_new_negotiated(
		captp_version: c_uint,
		codec: c_uint,
		peer: *mut *mut PancakePeer,
	) -> c_int;
	pub fn pancake_peer_new_negotiated_in(
		context: *mut PancakeContext,
		captp_version: c_uint,
		codec: c_uint,
		peer: *mut *mut PancakePeer,
	) -> c_int;
	pub fn pancake_peer_new_raw_open(peer: *mut *mut PancakePeer) -> c_int;
	pub fn pancake_peer_new_raw_open_in(
		context: *mut PancakeContext,
		peer: *mut *mut PancakePeer,
	) -> c_int;
	pub fn pancake_peer_release(peer: *mut PancakePeer);
	pub fn pancake_peer_feed_borrowed(peer: *mut PancakePeer, frame: *const PancakeFrame) -> c_int;
	pub fn pancake_peer_feed_owned(
		peer: *mut PancakePeer,
		frame: *mut PancakeManagedFrame,
	) -> c_int;
	pub fn pancake_peer_recv_stream(
		peer: *mut PancakePeer,
		bytes: *const c_uchar,
		len: usize,
		out_consumed: *mut usize,
	) -> c_int;
	pub fn pancake_peer_step(peer: *mut PancakePeer) -> c_int;
	pub fn pancake_peer_step_to_idle(peer: *mut PancakePeer) -> c_int;
	pub fn pancake_peer_take_outbound(
		peer: *mut PancakePeer,
		frame: *mut PancakeManagedFrame,
	) -> c_int;
	pub fn pancake_peer_poll_event(peer: *mut PancakePeer, event: *mut PancakeEvent) -> c_int;
	pub fn pancake_event_release(event: *mut PancakeEvent);
	pub fn pancake_managed_frame_release(frame: *mut PancakeManagedFrame);
	pub fn pancake_peer_register_export(peer: *mut PancakePeer, export_position: u64) -> c_int;
	pub fn pancake_peer_next_export(peer: *mut PancakePeer, out_export_position: *mut u64)
		-> c_int;
	pub fn pancake_peer_next_answer(peer: *mut PancakePeer, out_answer: *mut u64) -> c_int;
	pub fn pancake_peer_register_import(peer: *mut PancakePeer, import_position: u64) -> c_int;
	pub fn pancake_peer_peek_event(peer: *mut PancakePeer) -> c_int;
	pub fn pancake_peer_send_deliver(
		peer: *mut PancakePeer,
		target: *const PancakeReference,
		args: *const PancakeArgument,
		args_len: usize,
		has_answer: c_uint,
		answer: u64,
	) -> c_int;
	pub fn pancake_peer_send_resolve(
		peer: *mut PancakePeer,
		answer: u64,
		resolution_kind: c_uint,
		fulfill: *const PancakeArgument,
		break_message: *const c_uchar,
		break_message_len: usize,
	) -> c_int;
	pub fn pancake_peer_poll_event_deliver(
		peer: *mut PancakePeer,
		out: *mut PancakeDeliver,
	) -> c_int;
	pub fn pancake_peer_poll_event_resolve(
		peer: *mut PancakePeer,
		out: *mut PancakeResolve,
	) -> c_int;
	pub fn pancake_deliver_release(deliver: *mut PancakeDeliver);
	pub fn pancake_resolve_release(resolve: *mut PancakeResolve);
	pub fn pancake_peer_register_bootstrap_cap(
		peer: *mut PancakePeer,
		swissnum: *const c_uchar,
		swissnum_len: usize,
		out_export_position: *mut u64,
	) -> c_int;
	pub fn pancake_peer_last_abort(peer: *mut PancakePeer, out: *mut PancakeLastAbort) -> c_int;
	pub fn pancake_peer_start_session(
		peer: *mut PancakePeer,
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		hints: c_uint,
		seed: *const c_uchar,
		seed_len: usize,
	) -> c_int;
	pub fn pancake_peer_session_is_open(peer: *mut PancakePeer) -> c_int;
	pub fn pancake_peer_codec(peer: *const PancakePeer, out_codec: *mut c_uint) -> c_int;
	pub fn pancake_peer_send_bootstrap_fetch(
		peer: *mut PancakePeer,
		name: *const c_uchar,
		name_len: usize,
		out_answer: *mut u64,
	) -> c_int;
	// Sturdyref enliven (ADR-0012): the requester half over bootstrap-fetch with
	// the dedup cache threaded in. `prepare` resolves cache/in-flight/fresh;
	// `record` settles a fresh enliven's resolution into the cache.
	pub fn pancake_peer_prepare_enliven(
		peer: *mut PancakePeer,
		swissnum: *const c_uchar,
		swissnum_len: usize,
		out: *mut PancakeEnlivenStart,
	) -> c_int;
	pub fn pancake_peer_record_enlivenment(
		peer: *mut PancakePeer,
		swissnum: *const c_uchar,
		swissnum_len: usize,
		outcome: c_uint,
		import_position: u64,
		kind: c_uint,
	) -> c_int;
	// Recipient half of a three-party handoff: sign a desc:handoff-receive over
	// the verbatim give bytes (keyed by the 32-byte seed) and queue a
	// withdraw-gift deliver to the exporter's bootstrap under `answer`.
	pub fn pancake_peer_send_withdraw_gift(
		peer: *mut PancakePeer,
		give: *const c_uchar,
		give_len: usize,
		seed: *const c_uchar,
		seed_len: usize,
		handoff_count: u64,
		answer: u64,
	) -> c_int;
	// Gifter half of a three-party handoff (ADR-0009/ADR-0056). A gifter that
	// returns a capability whose home is another connection deposits it with the
	// exporter and resolves the recipient's question with a signed
	// `desc:handoff-give` the recipient redeems directly.
	//
	// Borrow the partner's session public key from its `op:start-session` (NULL +
	// 0 before the handshake): the recipient key off the to-recipient session,
	// the exporter key off the to-exporter session. The view is only valid until
	// the next peer call; copy it out immediately.
	pub fn pancake_peer_partner_session_key(
		peer: *mut PancakePeer,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	// Borrow the partner's verbatim `<ocapn-peer …>` location-record bytes from
	// its `op:start-session` (NULL + 0 when none were captured), for the give's
	// exporter locator. Same borrow lifetime as the session key.
	pub fn pancake_peer_partner_locator_raw(
		peer: *mut PancakePeer,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	// Deposit a gift with this (exporter) session: queue a fire-and-forget
	// `deposit-gift` `op:deliver` to the exporter's bootstrap carrying the gift
	// id and the gifted reference. `gift_id` is borrowed; `gifted_ref` is
	// borrowed and cloned by the send.
	pub fn pancake_peer_send_deposit_gift(
		peer: *mut PancakePeer,
		gift_id: *const c_uchar,
		gift_id_len: usize,
		gifted_ref: *const PancakeReference,
	) -> c_int;
	// Resolve the recipient's question with the verbatim signed `desc:handoff-give`
	// built by `pancake_build_handoff_give`. `give` is borrowed and copied by the
	// send.
	pub fn pancake_peer_send_resolve_handoff_give(
		peer: *mut PancakePeer,
		answer: u64,
		give: *const c_uchar,
		give_len: usize,
	) -> c_int;
	// Author the signed `desc:handoff-give` a gifter returns to a recipient,
	// writing owned bytes into `out_give`/`out_give_len` (release with
	// `pancake_handoff_give_bytes_release`). `seed` is the gifter's 32-byte
	// identity seed (must be 32). The recipient key, exporter locator bytes, and
	// exporter session key are read off the gifter's two sessions; `gift_id` is
	// the deposited gift's id.
	pub fn pancake_build_handoff_give(
		seed: *const c_uchar,
		seed_len: usize,
		recipient_key: *const c_uchar,
		recipient_key_len: usize,
		exporter_locator_raw: *const c_uchar,
		exporter_locator_raw_len: usize,
		exporter_session_key: *const c_uchar,
		exporter_session_key_len: usize,
		gift_id: *const c_uchar,
		gift_id_len: usize,
		out_give: *mut *mut c_uchar,
		out_give_len: *mut usize,
	) -> c_int;
	// Release the owned give bytes `pancake_build_handoff_give` returned.
	pub fn pancake_handoff_give_bytes_release(give: *mut c_uchar, give_len: usize);
	// Create a shared gift registry (the library allocator backs it). Bind it on
	// every peer of a node with `pancake_peer_set_gift_registry` before they
	// exchange handoff traffic, and free it last with
	// `pancake_gift_registry_free` once every peer that referenced it is released.
	pub fn pancake_gift_registry_new(out_registry: *mut *mut PancakeGiftRegistry) -> c_int;
	// Release a shared gift registry and every gift row it still owns. Every peer
	// it was set on must already be released. NULL is a no-op.
	pub fn pancake_gift_registry_free(registry: *mut PancakeGiftRegistry);
	// Bind `registry` as `peer`'s shared gift registry, so the peer's inbound
	// deposit/withdraw resolve against the shared table. The registry must
	// outlive the peer; a NULL registry detaches the peer back to its own table.
	pub fn pancake_peer_set_gift_registry(
		peer: *mut PancakePeer,
		registry: *mut PancakeGiftRegistry,
	) -> c_int;
	pub fn pancake_peer_send_gc_export(
		peer: *mut PancakePeer,
		positions: *const u64,
		deltas: *const u64,
		len: usize,
	) -> c_int;
	pub fn pancake_peer_send_gc_answer(peer: *mut PancakePeer, answer: u64) -> c_int;
	// Pipelined projections (ADR-0050/ADR-0052): an op:get / op:index / op:untag
	// against `receiver` (a desc:answer of an earlier far send), resolving the
	// freshly-allocated `answer` with the projected field / element / payload.
	pub fn pancake_peer_send_get(
		peer: *mut PancakePeer,
		receiver: *const PancakeReference,
		field: *const c_uchar,
		field_len: usize,
		answer: u64,
	) -> c_int;
	pub fn pancake_peer_send_index(
		peer: *mut PancakePeer,
		receiver: *const PancakeReference,
		index: i64,
		answer: u64,
	) -> c_int;
	pub fn pancake_peer_send_untag(
		peer: *mut PancakePeer,
		receiver: *const PancakeReference,
		tag: *const c_uchar,
		tag_len: usize,
		answer: u64,
	) -> c_int;

	// OCapN locator URIs — core `libpancake_ocapn` vocabulary, so a TCP-only or
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
	pub fn pancake_uri_format_sturdyref(
		transport: *const c_uchar,
		transport_len: usize,
		designator: *const c_uchar,
		designator_len: usize,
		swissnum: *const c_uchar,
		swissnum_len: usize,
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
