//! Raw FFI for the core archive (`libpancake_ocapn`).
//!
//! This is the universal base every build links: the context, peer, frame,
//! value/event, and URI/locator vocabulary `pancake_ocapn.h` declares, plus
//! `pancake_abi_version` and the ocapn-family `pancake_last_error`. The shared
//! frame and context types live here because the transport archives agree on
//! their *layout* (ADR-0059); a transport's own `sys/<t>.rs` declares only its
//! handle types and `pancake_<t>_*` family.
//!
//! It declares the part of the core surface the safe wrappers consume, and not
//! every constant or extern is used by the safe wrapper (e.g. `ERR_CLOSED`,
//! `REF_BROKEN` round out their enums). Dead code is expected of a `sys` layer
//! and allowed only here.
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

/// A parsed OCapN locator, one opaque handle carrying a peer or a sturdyref,
/// minted by `pancake_uri_parse_*` and read by the `pancake_locator_*`
/// accessors.
#[repr(C)]
pub struct PancakeLocator {
	_private: [u8; 0],
}

/// The sans-io cross-connection handoff router (`engine.Node`, ADR-0066): the
/// thing distinct from a per-partner connection. Minted by `pancake_node_new`,
/// it owns the retained node identity, the shared gift registry, one node-owned
/// `PancakePeer` per registered connection, and the redeemed-token / foreign-home
/// routing tables that make three-party handoff transparent.
#[repr(C)]
pub struct PancakeNode {
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
	// handoff; omitting it makes the struct too small and the poll writes past
	// it.
	pub handoff: PancakeHandoffGive,
	pub owner: *mut c_void,
}

#[repr(C)]
pub struct PancakeAnyEvent {
	pub kind: c_uint,
	pub projection: c_uint,
	pub deliver: PancakeDeliver,
	pub resolve: PancakeResolve,
	pub frame: PancakeManagedFrame,
}

/// One serve-step action from the node (ADR-0067). `kind` selects the live
/// fields; the `locator`/`reason` views are node-owned and valid until the
/// next `pancake_node_next_action`.
#[repr(C)]
pub struct PancakeNodeAction {
	pub kind: c_uint,
	pub pending: u64,
	pub locator: *const c_uchar,
	pub locator_len: usize,
	pub conn_id: u64,
	pub answer: u64,
	pub token: u64,
	pub reason: *const c_uchar,
	pub reason_len: usize,
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
	pub fn pancake_managed_frame_release(frame: *mut PancakeManagedFrame);
	pub fn pancake_peer_register_export(peer: *mut PancakePeer, export_position: u64) -> c_int;
	pub fn pancake_peer_next_export(peer: *mut PancakePeer, out_export_position: *mut u64)
		-> c_int;
	pub fn pancake_peer_next_answer(peer: *mut PancakePeer, out_answer: *mut u64) -> c_int;
	pub fn pancake_peer_register_import(peer: *mut PancakePeer, import_position: u64) -> c_int;
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
	pub fn pancake_peer_next_event(peer: *mut PancakePeer, out: *mut PancakeAnyEvent) -> c_int;
	pub fn pancake_any_event_release(event: *mut PancakeAnyEvent);
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
	// withdraw-gift deliver to the exporter's bootstrap under `answer`. The
	// binding's node serve step drives this path in the core; the extern rounds
	// out the mirrored C family.
	pub fn pancake_peer_send_withdraw_gift(
		peer: *mut PancakePeer,
		give: *const c_uchar,
		give_len: usize,
		seed: *const c_uchar,
		seed_len: usize,
		answer: u64,
	) -> c_int;
	// Borrow the partner's session public key from its `op:start-session` (NULL +
	// 0 before the handshake). The view is only valid until the next peer call;
	// copy it out immediately.
	pub fn pancake_peer_partner_session_key(
		peer: *mut PancakePeer,
		out_ptr: *mut *const c_uchar,
		out_len: *mut usize,
	) -> c_int;
	// Borrow the partner's verbatim `<ocapn-peer …>` location-record bytes from
	// its `op:start-session` (NULL + 0 when none were captured). Same borrow
	// lifetime as the session key.
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

	// Cross-connection handoff router (PancakeNode, ADR-0066). A binding creates
	// one node, registers each connection's node-owned peer, pumps it with the
	// ordinary pancake_peer_* surface, and asks the node to route sends. Every
	// route value is an integer conn_id or far id, so the router is pure data.
	pub fn pancake_node_new(
		seed: *const c_uchar,
		seed_len: usize,
		out_node: *mut *mut PancakeNode,
	) -> c_int;
	pub fn pancake_node_free(node: *mut PancakeNode);
	// Register a fresh connection: write its conn_id and the node-owned
	// negotiating peer (already bound to the shared registry and node identity).
	// Do not release the peer — the node owns it.
	pub fn pancake_node_register_conn(
		node: *mut PancakeNode,
		out_conn_id: *mut u64,
		out_peer: *mut *mut PancakePeer,
	) -> c_int;
	// Remove a registered connection: free its node-owned peer and retire the
	// conn_id (never reused). The caller must have stopped pumping the peer.
	pub fn pancake_node_remove_conn(node: *mut PancakeNode, conn_id: u64) -> c_int;
	// Recipient half: sign a desc:handoff-receive over the give keyed by the node
	// identity, mint the handoff-count from the shared registry, and queue
	// withdraw-gift on the exporter connection under `answer`.
	pub fn pancake_node_accept_give(
		node: *mut PancakeNode,
		recipient_conn: u64,
		answer: u64,
		give: *const c_uchar,
		give_len: usize,
		exporter_locator: *const c_uchar,
		exporter_locator_len: usize,
	) -> c_int;
	pub fn pancake_node_exporter_dialed(
		node: *mut PancakeNode,
		pending: u64,
		exporter_conn: u64,
	) -> c_int;
	pub fn pancake_node_dial_failed(
		node: *mut PancakeNode,
		pending: u64,
		reason: *const c_uchar,
		reason_len: usize,
	) -> c_int;
	pub fn pancake_node_claim_resolve(
		node: *mut PancakeNode,
		conn_id: u64,
		answer: u64,
		outcome: c_uint,
		far_id: u64,
		reason: *const c_uchar,
		reason_len: usize,
		out_claimed: *mut c_uint,
	) -> c_int;
	pub fn pancake_node_intercept_fulfilled_ref(
		node: *mut PancakeNode,
		conn_id: u64,
		answer: u64,
		far_id: u64,
		out_claimed: *mut c_uint,
	) -> c_int;
	pub fn pancake_node_provide_gift_id(
		node: *mut PancakeNode,
		ticket: u64,
		gift_id: *const c_uchar,
		gift_id_len: usize,
	) -> c_int;
	pub fn pancake_node_set_exporter_location(
		node: *mut PancakeNode,
		conn_id: u64,
		location: *const c_uchar,
		location_len: usize,
	) -> c_int;
	pub fn pancake_node_next_action(node: *mut PancakeNode, out: *mut PancakeNodeAction) -> c_int;
	// Resolve where a deliver to far_id rides: a redeemed token routes to its
	// exporter (with the real far id), any other far id rides default_conn. Writes
	// the destination conn_id/far_id and 1/0 into out_routed (0 when a redeemed
	// token's exporter is gone — drop the deliver).
	pub fn pancake_node_route(
		node: *mut PancakeNode,
		default_conn: u64,
		far_id: u64,
		out_conn_id: *mut u64,
		out_far_id: *mut u64,
		out_routed: *mut c_uint,
	) -> c_int;
	// Record that the fetched far import far_id lives on connection `home`, so a
	// later foreign-home return can be re-gifted (ADR-0009 gifter half).
	pub fn pancake_node_record_foreign_home(
		node: *mut PancakeNode,
		far_id: u64,
		home: u64,
	) -> c_int;
	// Whether far_id, used as a send/tell argument from default_conn, names a
	// capability foreign to that connection (a redeemed token or a far recorded
	// as living elsewhere): writes 1/0 into out_foreign.
	pub fn pancake_node_arg_is_foreign(
		node: *mut PancakeNode,
		default_conn: u64,
		far_id: u64,
		out_foreign: *mut c_uint,
	) -> c_int;
}
