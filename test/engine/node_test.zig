//! `engine.Node` routing-core proof (ADR-0066).
//!
//! Hermetic, no-I/O: exercises the sans-io router's connection table, the
//! redeemed-token model, and foreign-home recording directly, without a socket.
//! The live three-party proof that the same router drives a real Goblins handoff
//! is `zig build goblins-handoff`.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;

const Node = engine.Node;

test "registerConn yields stable, non-reused ids and node-owned peers" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{7} ** crypto.SEED_BYTES);
    defer node.deinit();

    const a = try node.registerConn();
    const b = try node.registerConn();
    try std.testing.expect(a != b);
    try std.testing.expect(node.peer(a) != null);
    try std.testing.expect(node.peer(b) != null);
    // Every registered peer shares the node's one gift registry.
    try std.testing.expectEqual(&node.gifts, node.peer(a).?.giftRegistry());
    try std.testing.expectEqual(&node.gifts, node.peer(b).?.giftRegistry());

    node.removeConn(a);
    try std.testing.expect(node.peer(a) == null);
    // A removed id is not reused: the next registration gets a fresh id past it.
    const c = try node.registerConn();
    try std.testing.expect(c != a);
    try std.testing.expect(c != b);
}

test "redeemed token routes to its exporter with the real reference swapped in" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{9} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient_conn = try node.registerConn();
    const exporter_conn = try node.registerConn();

    // The real exporter-side reference the redeemed token stands in for.
    const real: model.Reference = .{ .far = model.FarRef.object(42) };
    const token_ref = try node.enrollRedeemed(exporter_conn, real);
    // The application receives an opaque far token in the reserved range.
    try std.testing.expect(token_ref.far.import_position.int() >= Node.REDEEMED_TOKEN_BASE);

    // A send to the token routes to the exporter connection with the real ref.
    const routed = node.routeReference(recipient_conn, token_ref).?;
    try std.testing.expectEqual(exporter_conn, routed.conn_id);
    try std.testing.expectEqual(@as(u64, 42), routed.target.far.import_position.int());

    // An ordinary far import rides the connection the app addressed, unchanged.
    const plain: model.Reference = .{ .far = model.FarRef.object(3) };
    const plain_routed = node.routeReference(recipient_conn, plain).?;
    try std.testing.expectEqual(recipient_conn, plain_routed.conn_id);
    try std.testing.expectEqual(@as(u64, 3), plain_routed.target.far.import_position.int());

    // A token whose exporter connection is gone fails closed.
    node.removeConn(exporter_conn);
    try std.testing.expect(node.routeReference(recipient_conn, token_ref) == null);
}

test "send-argument routability: a capability on another connection is foreign, its home native" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{3} ** crypto.SEED_BYTES);
    defer node.deinit();

    const here = try node.registerConn();
    const elsewhere = try node.registerConn();

    // The verdict every binding's send-argument guard computes from the node: a
    // far is foreign in argument position when it is a redeemed token (reserved
    // range) or its recorded home is a connection other than the one sending.
    // `Node.argIsForeign` is the one definition; every binding's fail-closed
    // guard projects it through `pancake_node_arg_is_foreign` rather than
    // hand-rolling a copy (ADR-0009 gifter half; argument-position origination is
    // the lift that retires the guard).
    const import: model.Reference = .{ .far = model.FarRef.object(8) };
    try node.recordForeignHome(import, elsewhere);
    // Foreign when sent from `here` (it lives on `elsewhere`)…
    try std.testing.expect(node.argIsForeign(here, import));
    // …native when sent from its own home.
    try std.testing.expect(!node.argIsForeign(elsewhere, import));

    // An unrecorded far rides its own connection: not foreign.
    const unknown: model.Reference = .{ .far = model.FarRef.object(9) };
    try std.testing.expect(!node.argIsForeign(here, unknown));

    // A redeemed token is foreign from any connection of the node.
    const token = try node.enrollRedeemed(elsewhere, .{ .far = model.FarRef.object(1) });
    try std.testing.expect(node.argIsForeign(here, token));
    try std.testing.expect(node.argIsForeign(elsewhere, token));
}

test "originateGive fails closed on unknown connections and before sessions open" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{5} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerConn();
    const exporter = try node.registerConn();
    const gifted: model.Reference = .{ .far = model.FarRef.object(4) };
    const gift_id = [_]u8{0xAB} ** 32;

    // An unknown connection on either side fails closed before any wire work.
    try std.testing.expectError(error.UnknownConnection, node.originateGive(999, exporter, gifted, &gift_id, 1, ""));
    try std.testing.expectError(error.UnknownConnection, node.originateGive(recipient, 999, gifted, &gift_id, 1, ""));

    // Both peers are still negotiating (no handshake), so neither partner session
    // key is known: origination needs open keyed sessions to both ends. The live
    // positive proof that the same recipe drives a real handoff is the
    // `*-goblins-gift` gates.
    try std.testing.expectError(error.NoRecipientKey, node.originateGive(recipient, exporter, gifted, &gift_id, 1, ""));
}

test "foreign homes record wire imports only, never redeemed tokens" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{1} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerConn();
    const import: model.Reference = .{ .far = model.FarRef.object(5) };
    try node.recordForeignHome(import, home);
    try std.testing.expectEqual(home, node.foreignHome(import).?);

    // A synthetic redeemed token is never a wire import: recording is a no-op.
    const token: model.Reference = .{ .far = model.FarRef.object(Node.REDEEMED_TOKEN_BASE + 1) };
    try node.recordForeignHome(token, home);
    try std.testing.expect(node.foreignHome(token) == null);
}
