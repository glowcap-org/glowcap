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
//! node adds no second framing path. To redeem a give it dials the exporter,
//! registers it, calls `pancake_node_send_withdraw`, and on the resolved
//! reference `pancake_node_enroll_redeemed`s it under a token; a later
//! `pancake_node_route` of that token resolves to the exporter connection with
//! the real reference swapped in. The vat (turn loop, dispatch) stays in the
//! binding; only the router lives here.

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
/// entropy). Release with `pancake_node_free`. `seed` is borrowed; `seed_len`
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
/// finished pumping every connection's peer first, those peers are node-owned
/// and freed here, so a live connection still borrowing one would dereference
/// freed memory. NULL is a no-op.
pub export fn pancake_node_free(node: ?*PancakeNode) void {
    const ptr = nodeFromOpaque(node) orelse return;
    const alloc = ptr.allocator;
    ptr.deinit();
    alloc.destroy(ptr);
}

/// Register a fresh connection, writing its `conn_id` into `out_conn_id` and the
/// node-owned negotiating peer into `out_peer`. The binding builds its socket
/// pump over `out_peer` and drives it with the ordinary `pancake_peer_*` surface
/// (the peer is already bound to the node's shared gift registry, and signs its
/// keyed `op:start-session` with the node `seed`). Do **not** free `out_peer`:
/// the node owns it and frees it on `pancake_node_remove_conn` / `pancake_node_free`.
pub export fn pancake_node_register_conn(node: ?*PancakeNode, out_conn_id: ?*u64, out_peer: ?*?*PancakePeer) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const id_slot = out_conn_id orelse return PANCAKE_ERR_NULL_POINTER;
    const peer_slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    const conn_id = ptr.registerConn() catch return PANCAKE_ERR_INTERNAL;
    const peer = ptr.peer(conn_id) orelse return PANCAKE_ERR_INTERNAL;
    id_slot.* = conn_id;
    peer_slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

/// Remove a registered connection: free its node-owned peer and retire the
/// `conn_id` (never reused). A later route to a redeemed token whose exporter was
/// this connection fails closed. The caller must have stopped pumping this
/// connection's peer. An unknown `conn_id` is a no-op.
pub export fn pancake_node_remove_conn(node: ?*PancakeNode, conn_id: u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.removeConn(conn_id);
    return PANCAKE_OK;
}

/// Mint and queue the recipient half of a three-party handoff on the dialed
/// exporter connection: sign a `desc:handoff-receive` over the verbatim signed
/// `give` bytes keyed by the node identity, mint the monotonic handoff-count from
/// the shared registry, and queue `withdraw-gift` to the exporter's bootstrap
/// under `answer`. The binding flushes it by pumping `exporter_conn`'s peer; the
/// withdrawn reference arrives as a resolve keyed on `answer`, which the binding
/// then `pancake_node_enroll_redeemed`s. The exporter session must be open
/// (`PANCAKE_ERR_SESSION` otherwise). `give` is borrowed.
pub export fn pancake_node_send_withdraw(node: ?*PancakeNode, exporter_conn: u64, give: ?[*]const u8, give_len: usize, answer: u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const give_ptr = give orelse return PANCAKE_ERR_NULL_POINTER;
    if (give_len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    ptr.sendWithdraw(exporter_conn, give_ptr[0..give_len], answer) catch |err| switch (err) {
        error.UnknownConnection => return PANCAKE_ERR_INVALID_ARGUMENT,
        error.NoExporterKey => return PANCAKE_ERR_SESSION,
        error.MalformedKey => return PANCAKE_ERR_INVALID_ARGUMENT,
        else => return feedErrorToCode(err),
    };
    return PANCAKE_OK;
}

/// Gifter half of a three-party handoff (ADR-0009), the mirror of
/// `pancake_node_send_withdraw`: queue a `deposit-gift` of `gifted_ref` on
/// `exporter_conn`, build a `desc:handoff-give` signed by the node identity and
/// addressed to `recipient_conn`'s partner, and queue it as the fulfillment of
/// `answer` on `recipient_conn`. The binding flushes both connections (exporter
/// first) so the deposit lands before the recipient dials in to withdraw.
///
/// `gift_id` keys the deposit and the give (host-drawn — the node never generates
/// entropy). `exporter_location`, when non-NULL and non-empty, is the verbatim
/// exporter locator embedded in the give (an iroh exporter reachable only by a
/// Direct dial hint); NULL or empty uses the exporter session's own location
/// record. Both sessions must be open keyed sessions (`PANCAKE_ERR_SESSION`
/// otherwise). `gifted_ref`, `gift_id`, and `exporter_location` are borrowed.
pub export fn pancake_node_originate_give(
    node: ?*PancakeNode,
    recipient_conn: u64,
    exporter_conn: u64,
    gifted_ref: ?*const PancakeReference,
    gift_id: ?[*]const u8,
    gift_id_len: usize,
    answer: u64,
    exporter_location: ?[*]const u8,
    exporter_location_len: usize,
) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const gref = gifted_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const gift = sliceFromC(gift_id, gift_id_len) catch |err| return marshalErrorToCode(err);
    if (gift.len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    const gifted = referenceFromC(gref.*) catch |err| return marshalErrorToCode(err);
    const location = sliceFromC(exporter_location, exporter_location_len) catch |err| return marshalErrorToCode(err);
    ptr.originateGive(recipient_conn, exporter_conn, gifted, gift, answer, location) catch |err| switch (err) {
        error.UnknownConnection => return PANCAKE_ERR_INVALID_ARGUMENT,
        error.NoRecipientKey, error.NoExporterKey, error.NoExporterLocator => return PANCAKE_ERR_SESSION,
        else => return feedErrorToCode(err),
    };
    return PANCAKE_OK;
}

/// Enroll a redeemed far-object capability `far_id` (the reference a withdraw
/// resolved to, hosted on `exporter_conn`) under a fresh synthetic token, writing
/// the token's far id into `out_token`. The binding hands the token to the
/// application as an ordinary far capability; a later `pancake_node_route` of it
/// forwards to `exporter_conn` with `far_id` swapped back in. The token is drawn
/// from a reserved high range disjoint from any wire import, so it can never
/// alias a partner's import.
pub export fn pancake_node_enroll_redeemed(node: ?*PancakeNode, exporter_conn: u64, far_id: u64, out_token: ?*u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const token_slot = out_token orelse return PANCAKE_ERR_NULL_POINTER;
    const real: model.Reference = .{ .far = model.FarRef.object(far_id) };
    const token = ptr.enrollRedeemed(exporter_conn, real) catch return PANCAKE_ERR_INTERNAL;
    token_slot.* = token.far.import_position.int();
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
    const routed = ptr.routeReference(default_conn, target) orelse {
        routed_slot.* = 0;
        return PANCAKE_OK;
    };
    const resolved_id = switch (routed.target) {
        .far => |f| f.import_position.int(),
        else => return PANCAKE_ERR_INTERNAL,
    };
    conn_slot.* = routed.conn_id;
    far_slot.* = resolved_id;
    routed_slot.* = 1;
    return PANCAKE_OK;
}

/// Record that the fetched far import `far_id` lives on connection `home`: a
/// `fetch` stamps every far import it returns so a later foreign-home return can
/// be recognized and re-gifted (ADR-0009 gifter half) instead of mis-encoding a
/// cross-connection reference. A synthetic redeemed token (a high far id) is
/// never a wire import, so recording it is a no-op.
pub export fn pancake_node_record_foreign_home(node: ?*PancakeNode, far_id: u64, home: u64) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const import: model.Reference = .{ .far = model.FarRef.object(far_id) };
    ptr.recordForeignHome(import, home) catch return PANCAKE_ERR_INTERNAL;
    return PANCAKE_OK;
}

/// The connection a fetched far import `far_id` lives on. Writes the home
/// `conn_id` into `out_conn_id` and 1/0 into `out_found` — 0 for any far id that
/// was never recorded (including a redeemed token).
pub export fn pancake_node_foreign_home(node: ?*PancakeNode, far_id: u64, out_conn_id: ?*u64, out_found: ?*u32) i32 {
    const ptr = nodeFromOpaque(node) orelse return PANCAKE_ERR_NULL_POINTER;
    const conn_slot = out_conn_id orelse return PANCAKE_ERR_NULL_POINTER;
    const found_slot = out_found orelse return PANCAKE_ERR_NULL_POINTER;
    const import: model.Reference = .{ .far = model.FarRef.object(far_id) };
    if (ptr.foreignHome(import)) |home| {
        conn_slot.* = home;
        found_slot.* = 1;
    } else {
        found_slot.* = 0;
    }
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
    foreign_slot.* = if (ptr.argIsForeign(default_conn, reference)) 1 else 0;
    return PANCAKE_OK;
}
