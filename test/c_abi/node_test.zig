//! C ABI proof for the cross-connection handoff router (`pancake_node_*`,
//! ADR-0066). A C consumer drives the router's pure-data surface — register
//! connections, enroll a redeemed capability under a token, route a send to it,
//! record and read foreign homes, and watch a removed exporter fail closed —
//! entirely through the boring `ptr + len` / return-code ABI, with no Zig types
//! crossing the boundary. This is the hermetic dogfood for the surface the
//! bindings consume in place of their per-runtime `Machine`; the live three-party
//! proof is `zig build goblins-handoff`.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

const Node = pancake.ocapn.engine.Node;
const SEED_BYTES = pancake.foundation.crypto.SEED_BYTES;

test "node ABI: register, enroll, route, foreign-home, fail-closed" {
    const seed = [_]u8{3} ** SEED_BYTES;
    var node: ?*c.PancakeNode = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_new(&seed, seed.len, &node));
    defer c.pancake_node_free(node);
    try std.testing.expect(node != null);

    // Two registered connections hand back distinct ids and real, non-null peers.
    var recipient_conn: u64 = 0;
    var recipient_peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(node, &recipient_conn, &recipient_peer));
    try std.testing.expect(recipient_peer != null);

    var exporter_conn: u64 = 0;
    var exporter_peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_register_conn(node, &exporter_conn, &exporter_peer));
    try std.testing.expect(exporter_peer != null);
    try std.testing.expect(recipient_conn != exporter_conn);

    // Enroll a redeemed far-object cap; the token lands in the reserved range.
    var token: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_enroll_redeemed(node, exporter_conn, 42, &token));
    try std.testing.expect(token >= Node.REDEEMED_TOKEN_BASE);

    // A send to the token routes to the exporter connection with the real far id.
    var route_conn: u64 = 0;
    var route_far: u64 = 0;
    var routed: u32 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_route(node, recipient_conn, token, &route_conn, &route_far, &routed));
    try std.testing.expectEqual(@as(u32, 1), routed);
    try std.testing.expectEqual(exporter_conn, route_conn);
    try std.testing.expectEqual(@as(u64, 42), route_far);

    // An ordinary far id rides the connection the app addressed, unchanged.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_route(node, recipient_conn, 7, &route_conn, &route_far, &routed));
    try std.testing.expectEqual(@as(u32, 1), routed);
    try std.testing.expectEqual(recipient_conn, route_conn);
    try std.testing.expectEqual(@as(u64, 7), route_far);

    // Foreign homes record wire imports; a redeemed token is never one.
    var home_conn: u64 = 0;
    var found: u32 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_record_foreign_home(node, 5, recipient_conn));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_foreign_home(node, 5, &home_conn, &found));
    try std.testing.expectEqual(@as(u32, 1), found);
    try std.testing.expectEqual(recipient_conn, home_conn);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_foreign_home(node, token, &home_conn, &found));
    try std.testing.expectEqual(@as(u32, 0), found);

    // Removing the exporter makes a route to its token fail closed (drop, not send).
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_remove_conn(node, exporter_conn));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_node_route(node, recipient_conn, token, &route_conn, &route_far, &routed));
    try std.testing.expectEqual(@as(u32, 0), routed);
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
