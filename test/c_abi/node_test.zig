//! C ABI proof for the cross-connection handoff node (`pancake_node_*`,
//! ADR-0066/ADR-0067). The headline test runs a complete three-party handoff —
//! an exporter node, a recipient node, and a gifter — hermetically, in memory,
//! through the C surface alone: the recipient host feeds what it saw into the
//! serve step (`accept_give`, `claim_resolve`) and executes the actions
//! `next_action` hands back, and the settled token routes to the exporter with
//! the real reference swapped in. No Zig types cross the boundary. The live
//! counterpart of the same choreography is `zig build goblins-handoff`.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

const Node = pancake.ocapn.engine.Node;
const SEED_BYTES = pancake.foundation.crypto.SEED_BYTES;

/// Move every queued outbound frame from one peer into the other, dispatching
/// synchronously through the borrowed-frame path.
fn drainInto(from: ?*c.PancakePeer, to: ?*c.PancakePeer) !void {
    while (true) {
        var frame: c.PancakeManagedFrame = undefined;
        const rc = c.pancake_peer_take_outbound(from, &frame);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try std.testing.expectEqual(c.PANCAKE_OK, rc);
        const borrowed = c.PancakeFrame{ .bytes = frame.bytes, .len = frame.len, .shape = frame.shape };
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(to, &borrowed));
        c.pancake_managed_frame_release(&frame);
    }
}

/// Open a keyed session between two peers by signing each side's
/// `op:start-session` from its seed and shuttling frames until both report open.
fn openKeyedPair(
    a: ?*c.PancakePeer,
    a_loc: []const u8,
    seed_a: *const [32]u8,
    b: ?*c.PancakePeer,
    b_loc: []const u8,
    seed_b: *const [32]u8,
) !void {
    const transport = "tcp";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(a, transport, transport.len, a_loc.ptr, a_loc.len, c.PANCAKE_HINTS_EMPTY_FALSE, seed_a, seed_a.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(b, transport, transport.len, b_loc.ptr, b_loc.len, c.PANCAKE_HINTS_EMPTY_FALSE, seed_b, seed_b.len));
    var i: usize = 0;
    while (i < 8 and !(c.pancake_peer_session_is_open(a) == 1 and c.pancake_peer_session_is_open(b) == 1)) : (i += 1) {
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(a));
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(b));
        try drainInto(a, b);
        try drainInto(b, a);
    }
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(a));
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(b));
}

/// Take events off `peer` until one projects as a resolve, releasing everything
/// before it (the handshake `START_SESSION` frame rides ahead of the answer).
fn nextResolve(peer: ?*c.PancakePeer, out: *c.PancakeAnyEvent) !void {
    while (true) {
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_event(peer, out));
        if (out.projection == c.PANCAKE_PROJECTION_RESOLVE) return;
        c.pancake_any_event_release(out);
    }
}

test "node ABI: two nodes and a gifter run a three-party handoff hermetically" {
    const crypto = pancake.foundation.crypto;
    const exporter_seed = [_]u8{0x22} ** SEED_BYTES;
    const gifter_seed = [_]u8{0x33} ** SEED_BYTES;
    const recipient_seed = [_]u8{0x11} ** SEED_BYTES;

    // The exporter node hosts the gifted object behind one swissnum on both of
    // its connections; registering the peers on one node shares its registry.
    var exporter_node: ?*c.PancakeNode = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_new(&exporter_seed, exporter_seed.len, &exporter_node));
    defer c.pancake_node_free(exporter_node);
    var conn_to_gifter: u64 = 0;
    var conn_to_recipient: u64 = 0;
    var exp_to_gifter: ?*c.PancakePeer = null;
    var exp_to_recipient: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(exporter_node, &conn_to_gifter, &exp_to_gifter));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(exporter_node, &conn_to_recipient, &exp_to_recipient));
    var dm_pos_gifter: u64 = 0;
    var dm_pos_recipient: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_bootstrap_cap(exp_to_gifter, "dm", 2, &dm_pos_gifter));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_bootstrap_cap(exp_to_recipient, "dm", 2, &dm_pos_recipient));

    // The recipient node: one app-facing connection the give "arrives" on
    // (never opened; only its answer table matters here), and later the dialed
    // exporter connection the serve step asks for.
    var recipient_node: ?*c.PancakeNode = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_new(&recipient_seed, recipient_seed.len, &recipient_node));
    defer c.pancake_node_free(recipient_node);
    var conn_up: u64 = 0;
    var recipient_up: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(recipient_node, &conn_up, &recipient_up));

    // Gifter session to the exporter opens first; the gifter learns the
    // exporter's verbatim location record from it.
    var gifter: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&gifter));
    defer c.pancake_peer_release(gifter);
    try openKeyedPair(exp_to_gifter, "127.0.0.1:2", &exporter_seed, gifter, "127.0.0.1:3", &gifter_seed);

    var loc_ptr: ?[*]const u8 = null;
    var loc_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_partner_locator_raw(gifter, &loc_ptr, &loc_len));
    const exporter_loc = loc_ptr.?[0..loc_len];

    // The gifter mints a genuine signed give addressed to the recipient node's
    // key and deposits the gifted capability with the exporter.
    const recipient_key = crypto.SecretKey.fromSeed(recipient_seed).publicKey().asBytes();
    const exporter_key = crypto.SecretKey.fromSeed(exporter_seed).publicKey().asBytes();
    const gift_id = [_]u8{0x5a} ** 32;
    var give_ptr: ?[*]u8 = null;
    var give_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_build_handoff_give(
        &gifter_seed,
        gifter_seed.len,
        recipient_key.ptr,
        recipient_key.len,
        exporter_loc.ptr,
        exporter_loc.len,
        exporter_key.ptr,
        exporter_key.len,
        &gift_id,
        gift_id.len,
        &give_ptr,
        &give_len,
    ));
    defer c.pancake_handoff_give_bytes_release(give_ptr, give_len);
    const give = give_ptr.?[0..give_len];

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(gifter, dm_pos_gifter));
    const gifted = c.PancakeReference{ .kind = c.PANCAKE_REF_FAR, .sub_kind = c.PANCAKE_REF_SUB_OBJECT, .id = dm_pos_gifter };
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_deposit_gift(gifter, &gift_id, gift_id.len, &gifted));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(gifter));
    try drainInto(gifter, exp_to_gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(exp_to_gifter));

    // The recipient host saw answer 31 on its app connection resolve to this
    // give. It feeds the serve step and executes what comes back.
    const dial_uri = "ocapn://127.0.0.1%3A9060.tcp";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_accept_give(recipient_node, conn_up, 31, give.ptr, give.len, dial_uri.ptr, dial_uri.len));
    var action: c.PancakeNodeAction = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(recipient_node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_DIAL, action.kind);
    try std.testing.expectEqualStrings(dial_uri, action.locator.?[0..action.locator_len]);

    // Execute the dial: register the exporter connection and open the keyed
    // session under the node identity, then report it.
    var conn_x: u64 = 0;
    var recipient_x: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(recipient_node, &conn_x, &recipient_x));
    try openKeyedPair(recipient_x, "127.0.0.1:4", &recipient_seed, exp_to_recipient, "127.0.0.1:2", &exporter_seed);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_exporter_dialed(recipient_node, action.pending, conn_x));

    // The node queued the withdraw; execute the flush and shuttle the reply.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(recipient_node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_FLUSH, action.kind);
    try std.testing.expectEqual(conn_x, action.conn_id);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_x));
    try drainInto(recipient_x, exp_to_recipient);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(exp_to_recipient));
    try drainInto(exp_to_recipient, recipient_x);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_x));

    // The exporter answered the withdraw with the gifted capability. The host
    // offers every polled resolve to the node; this one is claimed.
    var polled: c.PancakeAnyEvent = undefined;
    try nextResolve(recipient_x, &polled);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, polled.resolve.resolution_kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, polled.resolve.fulfill.kind);
    const withdraw_answer = polled.resolve.answer;
    const redeemed_far = polled.resolve.fulfill.reference.id;
    c.pancake_any_event_release(&polled);

    var claimed: u32 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_claim_resolve(recipient_node, conn_x, withdraw_answer, c.PANCAKE_REDEEM_OUTCOME_FAR, redeemed_far, null, 0, &claimed));
    try std.testing.expectEqual(@as(u32, 1), claimed);

    // The claimed withdraw settles the application answer with a routable token.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(recipient_node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_SETTLE, action.kind);
    try std.testing.expectEqual(conn_up, action.conn_id);
    try std.testing.expectEqual(@as(u64, 31), action.answer);
    const token = action.token;
    try std.testing.expect(token >= Node.REDEEMED_TOKEN_BASE);

    // A send to the token rides the exporter connection with the real far id;
    // an ordinary far id rides the connection the application addressed.
    var route_conn: u64 = 0;
    var route_far: u64 = 0;
    var routed: u32 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_route(recipient_node, conn_up, token, &route_conn, &route_far, &routed));
    try std.testing.expectEqual(@as(u32, 1), routed);
    try std.testing.expectEqual(conn_x, route_conn);
    try std.testing.expectEqual(redeemed_far, route_far);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_route(recipient_node, conn_up, 7, &route_conn, &route_far, &routed));
    try std.testing.expectEqual(@as(u32, 1), routed);
    try std.testing.expectEqual(conn_up, route_conn);
    try std.testing.expectEqual(@as(u64, 7), route_far);

    // The shared foreign-argument verdict: a far fetched on another connection
    // and a redeemed token are both foreign to any other connection's encoder.
    var foreign: u32 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_record_foreign_home(recipient_node, 5, conn_up));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_arg_is_foreign(recipient_node, conn_x, 5, &foreign));
    try std.testing.expectEqual(@as(u32, 1), foreign);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_arg_is_foreign(recipient_node, conn_up, 5, &foreign));
    try std.testing.expectEqual(@as(u32, 0), foreign);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_arg_is_foreign(recipient_node, conn_up, token, &foreign));
    try std.testing.expectEqual(@as(u32, 1), foreign);

    // Removing the exporter connection retires the token: the route fails
    // closed (drop, not send) and nothing is left stranded in the serve step.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_remove_conn(recipient_node, conn_x));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_route(recipient_node, conn_up, token, &route_conn, &route_far, &routed));
    try std.testing.expectEqual(@as(u32, 0), routed);
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_node_next_action(recipient_node, &action));
}

test "node ABI: context-backed constructor allocates through the caller's allocator" {
    const counting = struct {
        var allocs: usize = 0;
        var frees: usize = 0;
        fn alloc(user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
            _ = user_data;
            allocs += 1;
            const a = std.mem.Alignment.fromByteUnits(alignment);
            const bytes = std.heap.smp_allocator.rawAlloc(size, a, @returnAddress()) orelse return null;
            return @ptrCast(bytes);
        }
        fn free(user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
            _ = user_data;
            const p = ptr orelse return;
            frees += 1;
            const a = std.mem.Alignment.fromByteUnits(alignment);
            std.heap.smp_allocator.rawFree(@as([*]u8, @ptrCast(p))[0..size], a, @returnAddress());
        }
    };
    const spec = c.PancakeAllocator{ .alloc = counting.alloc, .free = counting.free, .user_data = null };
    var context: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &context));
    defer c.pancake_context_release(context);

    // The context handle itself frees at release, after this test's asserts,
    // so the node family's balance is measured from here.
    const base_allocs = counting.allocs;
    const base_frees = counting.frees;

    const seed = [_]u8{4} ** SEED_BYTES;
    var node: ?*c.PancakeNode = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_new_in(context, &seed, seed.len, &node));

    var conn: u64 = 0;
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(node, &conn, &peer));
    c.pancake_node_free(node);

    // Everything the node family allocated came back through the same policy.
    try std.testing.expect(counting.allocs > base_allocs);
    try std.testing.expectEqual(counting.allocs - base_allocs, counting.frees - base_frees);
}

test "node ABI: argument validation" {
    var node: ?*c.PancakeNode = null;
    const seed = [_]u8{1} ** SEED_BYTES;

    // A wrong-width seed is rejected, not silently truncated.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_node_new(&seed, seed.len - 1, &node));
    // A null out-slot and a null seed are null-pointer errors.
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_node_new(&seed, seed.len, null));
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_node_new(null, seed.len, &node));

    // Calls on a null node fail closed; a null free is a no-op.
    var conn: u64 = 0;
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_node_register_conn(null, &conn, &peer));
    c.pancake_node_free(null);
}

test "node ABI: the serve step feeds a give and drains actions" {
    var node: ?*c.PancakeNode = null;
    const seed = [_]u8{6} ** SEED_BYTES;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_new(&seed, seed.len, &node));
    defer c.pancake_node_free(node);

    var recipient: u64 = 0;
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(node, &recipient, &peer));

    // No action pending yet.
    var action: c.PancakeNodeAction = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_node_next_action(node, &action));

    // A give with no dialable locator fails the answer closed.
    const give = "give-bytes";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_accept_give(node, recipient, 7, give.ptr, give.len, null, 0));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_FAIL, action.kind);
    try std.testing.expectEqual(@as(u64, 7), action.answer);
    try std.testing.expectEqualStrings(
        "handoff give names no dialable exporter locator",
        action.reason.?[0..action.reason_len],
    );

    // An unknown exporter becomes one dial action; its failure breaks the answer.
    const locator = "ocapn://127.0.0.1%3A9060.tcp";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_accept_give(node, recipient, 8, give.ptr, give.len, locator.ptr, locator.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_DIAL, action.kind);
    try std.testing.expectEqualStrings(locator, action.locator.?[0..action.locator_len]);
    const pending = action.pending;
    const refused = "connection refused";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_dial_failed(node, pending, refused.ptr, refused.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_FAIL, action.kind);
    try std.testing.expectEqual(@as(u64, 8), action.answer);
    try std.testing.expectEqualStrings(
        "handoff redeem failed: connection refused",
        action.reason.?[0..action.reason_len],
    );
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, c.pancake_node_next_action(node, &action));

    // A resolve with no pending withdraw is the application's, unclaimed.
    var claimed: u32 = 9;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_claim_resolve(node, recipient, 99, c.PANCAKE_REDEEM_OUTCOME_FAR, 5, null, 0, &claimed));
    try std.testing.expectEqual(@as(u32, 0), claimed);

    // A plain reply with no recorded foreign home stays the host's to resolve.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_intercept_fulfilled_ref(node, recipient, 10, 5, &claimed));
    try std.testing.expectEqual(@as(u32, 0), claimed);

    // A foreign-home reply is claimed: the node asks for gift-id entropy and
    // the host answers the ticket. (Sessions here are closed, so the
    // origination fails closed into a broken answer — the decision path is
    // what this pins; the live positive proof is the *-goblins-gift matrix.)
    var elsewhere: u64 = 0;
    var elsewhere_peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(node, &elsewhere, &elsewhere_peer));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_record_foreign_home(node, 6, elsewhere));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_set_exporter_location(node, elsewhere, null, 0));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_intercept_fulfilled_ref(node, recipient, 11, 6, &claimed));
    try std.testing.expectEqual(@as(u32, 1), claimed);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_NEED_GIFT_ID, action.kind);
    const gift_id = [_]u8{0xEE} ** 32;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_provide_gift_id(node, action.pending, &gift_id, gift_id.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_next_action(node, &action));
    try std.testing.expectEqual(c.PANCAKE_NODE_ACTION_FAIL, action.kind);
    try std.testing.expectEqual(@as(u64, 11), action.answer);
}
