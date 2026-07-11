//! The `PancakeNode` surface: the sans-io cross-connection handoff router
//! (`engine.Node`, ADR-0066) projected to C. A node is the thing distinct from a
//! per-partner connection — it owns the retained node identity (`seed`), the
//! shared gift registry, one node-owned `PancakePeer` per registered connection,
//! and the redeemed-token / foreign-home routing tables that make three-party
//! handoff transparent.
//!
//! A binding creates one node, then for each connection calls
//! `pancake_node_register_conn` to get a `conn_id` and the node-owned peer it
//! pumps over its own socket with the ordinary `pancake_peer_*` surface — the
//! node adds no second framing path. Redeeming and originating handoffs is the
//! serve step (ADR-0067): the host feeds what it saw
//! (`pancake_node_accept_give`, `pancake_node_claim_resolve`,
//! `pancake_node_intercept_fulfilled_ref`) and executes the actions
//! `pancake_node_next_action` hands back; the node decides everything in
//! between, and a later `pancake_node_route` of a settled token resolves to the
//! exporter connection with the real reference swapped in. The vat (turn loop,
//! dispatch) stays in the binding; only the decisions live here.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

const abi = @import("c_abi_shared");

const c = @import("mod.zig");
const ctx = @import("context.zig");

const PancakeNode = c.PancakeNode;
const PancakePeer = c.PancakePeer;
const PancakeReference = c.PancakeReference;

const sliceFromC = abi.sliceFromC;
const referenceFromC = abi.referenceFromC;
const marshalErrorToCode = abi.marshalErrorToCode;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_SESSION = c.PANCAKE_ERR_SESSION;

const feedErrorToCode = c.feedErrorToCode;

fn nodeFromOpaque(node: ?*PancakeNode) ?*engine.Node {
    const ptr = node orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Create a node bound to the 32-byte identity `seed`, writing the handle into
/// `out_node`. The seed is the node's stable session identity, reused for every
/// connection it opens so an exporter verifies a `desc:handoff-receive` against
/// one key; draw it at the host's I/O boundary (the sans-io node never generates
/// entropy). Release with `pancake_node_release`. `seed` is borrowed; `seed_len`
/// must be 32.
pub export fn pancake_node_new(seed: ?[*]const u8, seed_len: usize, out_node: ?*?*PancakeNode) i32 {
    return nodeNewIn(ctx.library_allocator, seed, seed_len, out_node);
}

/// Context-backed counterpart of `pancake_node_new`: the node, its per-connection
/// peers, and the shared gift registry all allocate and free through `context`'s
/// allocator (ADR-0059). The context must outlive the node.
pub export fn pancake_node_new_in(context: ?*c.PancakeContext, seed: ?[*]const u8, seed_len: usize, out_node: ?*?*PancakeNode) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    return nodeNewIn(c_ctx.allocator, seed, seed_len, out_node);
}

fn nodeNewIn(alloc: std.mem.Allocator, seed: ?[*]const u8, seed_len: usize, out_node: ?*?*PancakeNode) i32 {
    const slot = out_node orelse return PANCAKE_ERR_NULL_POINTER;
    const seed_ptr = seed orelse return PANCAKE_ERR_NULL_POINTER;
    if (seed_len != foundation.crypto.SEED_BYTES) return PANCAKE_ERR_INVALID_ARGUMENT;
    const seed_bytes: [foundation.crypto.SEED_BYTES]u8 = seed_ptr[0..foundation.crypto.SEED_BYTES].*;
    const node = alloc.create(engine.Node) catch return PANCAKE_ERR_INTERNAL;
    node.* = engine.Node.init(alloc, seed_bytes);
    slot.* = @ptrCast(node);
    return PANCAKE_OK;
}

/// Release a node: free every registered peer, the routing tables and the
/// references they own, and the shared gift registry. The caller must have
/// finished pumping every connection's peer first. Those peers are node-owned
/// and freed here, so a live connection still borrowing one would dereference
/// freed memory. NULL is a no-op.
pub export fn pancake_node_release(node: ?*PancakeNode) void {
    const ptr = nodeFromOpaque(node) orelse return;
    const alloc = ptr.allocator;
    ptr.deinit();
    alloc.destroy(ptr);
}

/// Register a fresh connection, writing its `conn_id` into `out_conn_id` and the
/// node-owned negotiating peer into `out_peer`. The binding builds its socket
/// pump over `out_peer` and drives it with the ordinary `pancake_peer_*` surface;
/// the peer is already bound to the node's shared gift registry. The *host*
/// completes the keyed `op:start-session` (it owns the socket and the entropy)
/// and must sign with the same 32-byte seed it gave `pancake_node_new` — a
/// different key silently breaks give verification at the exporter. Do **not**
/// free `out_peer`: the node owns it and frees it on `pancake_node_remove_conn`
/// / `pancake_node_release`.
pub export fn pancake_node_register_conn(node: ?*PancakeNode, out_conn_id: ?*u64, out_peer: ?*?*PancakePeer) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const id_slot = out_conn_id orelse return PANCAKE_ERR_NULL_POINTER;
    const peer_slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    const conn_id = ptr.registerConn(.{}) catch return PANCAKE_ERR_INTERNAL;
    const peer = ptr.peer(conn_id) orelse return PANCAKE_ERR_INTERNAL;
    id_slot.* = conn_id.int();
    peer_slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

/// Remove a registered connection: free its node-owned peer and retire the
/// `conn_id` (never reused). A later route to a redeemed token whose exporter was
/// this connection fails closed. The caller must have stopped pumping this
/// connection's peer. An unknown `conn_id` is a no-op.
pub export fn pancake_node_remove_conn(node: ?*PancakeNode, conn_id: u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.removeConn(.from(conn_id));
    return PANCAKE_OK;
}

/// Resolve where a deliver to far-object `far_id` rides. A redeemed token routes
/// to its exporter connection with the real exporter-side far id; any other far
/// id rides `default_conn` (the connection the application is addressing)
/// unchanged. Writes the destination `conn_id` and far id into `out_conn_id` /
/// `out_far_id`, and 1/0 into `out_routed` — 0 when a redeemed token names an
/// exporter connection that is gone (the deliver must be dropped, not sent).
pub export fn pancake_node_route(node: ?*PancakeNode, default_conn: u64, far_id: u64, out_conn_id: ?*u64, out_far_id: ?*u64, out_routed: ?*u32) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const conn_slot = out_conn_id orelse return PANCAKE_ERR_NULL_POINTER;
    const far_slot = out_far_id orelse return PANCAKE_ERR_NULL_POINTER;
    const routed_slot = out_routed orelse return PANCAKE_ERR_NULL_POINTER;
    const target: model.Reference = .{ .far = model.FarRef.object(far_id) };
    const routed = ptr.routeReference(.from(default_conn), target) orelse {
        routed_slot.* = 0;
        return PANCAKE_OK;
    };
    const resolved_id = switch (routed.target) {
        .far => |f| f.import_position.int(),
        else => return PANCAKE_ERR_INTERNAL,
    };
    conn_slot.* = routed.conn_id.int();
    far_slot.* = resolved_id;
    routed_slot.* = 1;
    return PANCAKE_OK;
}

/// Enroll the fetched far import `far_id` (a wire position on connection `home`)
/// under a node-unique token and write the token into `out_token` (ADR-0069). The
/// binding holds the token as the capability's identity instead of the wire
/// position, so two capabilities fetched at the same wire position on different
/// connections get distinct tokens and never collide in the node's routing
/// tables. A send to the token routes to `home` with the real wire reference
/// swapped back in; returning it to another connection re-gifts the right home.
/// Every binding holds a fetched capability's identity this way (ADR-0069); a
/// `fetch` calls this on the far reference the partner returns.
pub export fn pancake_node_enroll_foreign(node: ?*PancakeNode, home: u64, far_id: u64, out_token: ?*u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const token_slot = out_token orelse return PANCAKE_ERR_NULL_POINTER;
    const wire: model.Reference = .{ .far = model.FarRef.object(far_id) };
    const token = ptr.enrollForeign(.from(home), wire) catch return PANCAKE_ERR_INTERNAL;
    token_slot.* = token.far.import_position.int();
    return PANCAKE_OK;
}

/// Whether far-object `far_id`, used as a `send`/`tell` argument from
/// `default_conn`, names a capability foreign to that connection: a redeemed
/// handoff token (the node routes it to a different exporter) or a far the node
/// recorded as fetched on another connection. Writes 1/0 into `out_foreign`. A
/// binding fails closed on 1 rather than mis-encoding the reference for this
/// partner; the gifter half re-gifts such a capability when it is *returned*
/// (ADR-0009), and argument-position origination is the lift that retires the
/// guard. This is the one definition of that verdict the bindings share.
pub export fn pancake_node_arg_is_foreign(node: ?*PancakeNode, default_conn: u64, far_id: u64, out_foreign: ?*u32) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const foreign_slot = out_foreign orelse return PANCAKE_ERR_NULL_POINTER;
    const reference: model.Reference = .{ .far = model.FarRef.object(far_id) };
    foreign_slot.* = if (ptr.argIsForeign(.from(default_conn), reference)) 1 else 0;
    return PANCAKE_OK;
}

// ── The serve step: the sans-io redeem state machine (`engine.Node`) ─────────

/// Recipient intercept: the application answer `answer` on `recipient_conn`
/// resolved to a handoff give instead of a value (the host saw
/// `PANCAKE_RESOLUTION_HANDOFF` and must not surface it). The node decides what
/// happens next — a live exporter for `exporter_locator` withdraws immediately,
/// a dial already in flight is joined, an unknown exporter becomes a `_DIAL`
/// action, an empty locator fails the answer closed — and queues the actions;
/// drain them with `pancake_node_next_action`. `give` is the verbatim signed
/// envelope; both byte inputs are borrowed (the node copies what it keeps).
pub export fn pancake_node_accept_give(
    node: ?*PancakeNode,
    recipient_conn: u64,
    answer: u64,
    give: ?[*]const u8,
    give_len: usize,
    exporter_locator: ?[*]const u8,
    exporter_locator_len: usize,
) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const give_ptr = give orelse return PANCAKE_ERR_NULL_POINTER;
    if (give_len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    const locator = sliceFromC(exporter_locator, exporter_locator_len) catch |err| return marshalErrorToCode(err);
    ptr.acceptGive(.from(recipient_conn), answer, give_ptr[0..give_len], locator) catch return PANCAKE_ERR_INTERNAL;
    return PANCAKE_OK;
}

/// Report a `_DIAL` action's success: the exporter is registered as
/// `exporter_conn` with an open keyed session under the node identity. The node
/// caches the exporter and withdraws every give waiting on the ticket (a
/// `_FLUSH` action follows per withdraw). An already-settled `pending` is a
/// no-op.
pub export fn pancake_node_exporter_dialed(node: ?*PancakeNode, pending: u64, exporter_conn: u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.exporterDialed(pending, .from(exporter_conn)) catch return PANCAKE_ERR_INTERNAL;
    return PANCAKE_OK;
}

/// Report a `_DIAL` action's failure: every redeem waiting on the ticket breaks
/// with `reason` (borrowed). An already-settled `pending` is a no-op.
pub export fn pancake_node_dial_failed(node: ?*PancakeNode, pending: u64, reason: ?[*]const u8, reason_len: usize) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const message = sliceFromC(reason, reason_len) catch |err| return marshalErrorToCode(err);
    ptr.dialFailed(pending, message) catch return PANCAKE_ERR_INTERNAL;
    return PANCAKE_OK;
}

/// Offer a resolve the host polled on `conn_id` to the node. Writes 1 into
/// `out_claimed` when it settles a pending withdraw — the node consumes it
/// (enrolling the redeemed capability under a token and queueing `_SETTLE`, or
/// queueing `_FAIL`), and the host must not surface it to the application; 0
/// means the resolve is the application's, untouched. `outcome` is a
/// `PANCAKE_REDEEM_OUTCOME_*`: `_FAR` carries the fulfilled far id in `far_id`,
/// `_BROKEN` the break reason in `reason` (borrowed), `_NOT_CAPABILITY` a
/// fulfillment that is not a capability.
pub export fn pancake_node_claim_resolve(
    node: ?*PancakeNode,
    conn_id: u64,
    answer: u64,
    outcome: u32,
    far_id: u64,
    reason: ?[*]const u8,
    reason_len: usize,
    out_claimed: ?*u32,
) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const claimed_slot = out_claimed orelse return PANCAKE_ERR_NULL_POINTER;
    const message = sliceFromC(reason, reason_len) catch |err| return marshalErrorToCode(err);
    const withdraw_outcome: engine.Node.RedeemOutcome = switch (outcome) {
        c.PANCAKE_REDEEM_OUTCOME_FAR => .{ .far = far_id },
        c.PANCAKE_REDEEM_OUTCOME_BROKEN => .{ .broken = message },
        c.PANCAKE_REDEEM_OUTCOME_NOT_CAPABILITY => .not_capability,
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };
    const claimed = ptr.claimResolve(.from(conn_id), answer, withdraw_outcome) catch return PANCAKE_ERR_INTERNAL;
    claimed_slot.* = if (claimed) 1 else 0;
    return PANCAKE_OK;
}

/// Gifter intercept: the application answer `answer` on `conn_id` fulfilled to
/// the far capability `far_id`. When that capability's recorded home is another
/// connection, the node claims the reply and queues a `_NEED_GIFT_ID` action —
/// entropy is a host effect, requested only when a reply actually becomes a
/// gift — and writes 1 into `out_claimed` (the host must not also send a plain
/// resolve; it draws 32 bytes and answers with `pancake_node_provide_gift_id`).
/// 0 means the reply is ordinary and the host resolves it itself.
pub export fn pancake_node_intercept_fulfilled_ref(
    node: ?*PancakeNode,
    conn_id: u64,
    answer: u64,
    far_id: u64,
    out_claimed: ?*u32,
) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const claimed_slot = out_claimed orelse return PANCAKE_ERR_NULL_POINTER;
    const claimed = ptr.interceptFulfilledRef(.from(conn_id), answer, far_id) catch return PANCAKE_ERR_INTERNAL;
    claimed_slot.* = if (claimed) 1 else 0;
    return PANCAKE_OK;
}

/// Answer a `_NEED_GIFT_ID` action with the host-drawn `gift_id`: the node
/// originates the claimed handoff (deposit on the exporter, signed give
/// resolving the claimed answer, using any recorded
/// `pancake_node_set_exporter_location` override) and queues the two `_FLUSH`
/// actions — exporter first, so the deposit is on the wire before the
/// recipient dials in. A failed origination breaks the claimed answer instead.
/// An already-settled `ticket` is a no-op. `gift_id` is borrowed and must be
/// non-empty.
pub export fn pancake_node_provide_gift_id(node: ?*PancakeNode, ticket: u64, gift_id: ?[*]const u8, gift_id_len: usize) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const gift = sliceFromC(gift_id, gift_id_len) catch |err| return marshalErrorToCode(err);
    if (gift.len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    ptr.provideGiftId(ticket, gift) catch return PANCAKE_ERR_INTERNAL;
    return PANCAKE_OK;
}

/// Record the exporter locator to embed in gives whose exporter is
/// `conn_id` — an exporter reachable only by a dial hint (an iroh endpoint's
/// direct addresses), where the session's own signed location record is not
/// dialable. `location` is borrowed: it must be a Syrup `<ocapn-peer …>`
/// record; NULL or empty clears the override. A URI or other non-record
/// spelling fails with `PANCAKE_ERR_INVALID_ARGUMENT`.
pub export fn pancake_node_set_exporter_location(node: ?*PancakeNode, conn_id: u64, location: ?[*]const u8, location_len: usize) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = sliceFromC(location, location_len) catch |err| return marshalErrorToCode(err);
    if (bytes.len == 0) {
        ptr.setExporterLocation(.from(conn_id), null) catch return PANCAKE_ERR_INTERNAL;
        return PANCAKE_OK;
    }
    var cursor: usize = 0;
    const parsed = engine.readLocatorOwned(ptr.allocator, bytes, &cursor) catch {
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    defer model.freePeerLocator(ptr.allocator, parsed);
    if (cursor != bytes.len) return PANCAKE_ERR_INVALID_ARGUMENT;
    ptr.setExporterLocation(.from(conn_id), parsed) catch return PANCAKE_ERR_INTERNAL;
    return PANCAKE_OK;
}

/// Pop the next serve-step action into `out`. The previous action's byte views
/// are freed by this call, so a popped action's `locator`/`reason` views are
/// valid until the next `pancake_node_next_action` (or `pancake_node_release`);
/// copy what outlives that. Returns `PANCAKE_ERR_WOULD_BLOCK` when no action is
/// pending.
pub export fn pancake_node_next_action(node: ?*PancakeNode, out: ?*c.PancakeNodeAction) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const action = ptr.nextAction() orelse return c.PANCAKE_ERR_WOULD_BLOCK;
    slot.* = .{
        .kind = c.PANCAKE_NODE_ACTION_NONE,
        .pending = 0,
        .locator = null,
        .locator_len = 0,
        .conn_id = 0,
        .answer = 0,
        .token = 0,
        .reason = null,
        .reason_len = 0,
    };
    switch (action) {
        .dial => |d| {
            slot.kind = c.PANCAKE_NODE_ACTION_DIAL;
            slot.pending = d.pending;
            slot.locator = if (d.locator.len == 0) null else d.locator.ptr;
            slot.locator_len = d.locator.len;
        },
        .flush => |conn_id| {
            slot.kind = c.PANCAKE_NODE_ACTION_FLUSH;
            slot.conn_id = conn_id.int();
        },
        .settle => |s| {
            slot.kind = c.PANCAKE_NODE_ACTION_SETTLE;
            slot.conn_id = s.conn_id.int();
            slot.answer = s.answer;
            slot.token = s.token;
        },
        .fail => |f| {
            slot.kind = c.PANCAKE_NODE_ACTION_FAIL;
            slot.conn_id = f.conn_id.int();
            slot.answer = f.answer;
            slot.reason = if (f.reason.len == 0) null else f.reason.ptr;
            slot.reason_len = f.reason.len;
        },
        .need_gift_id => |g| {
            slot.kind = c.PANCAKE_NODE_ACTION_NEED_GIFT_ID;
            slot.pending = g.ticket;
        },
    }
    return PANCAKE_OK;
}
