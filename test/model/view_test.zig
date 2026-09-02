//! Codec-neutral view round-trips: owned message through `view.Body.fromOwned`
//! and back through `toOwned`.
//!
//! These exercise the owned-fallback (slice) backings of `Args` and
//! `PositionList` and the full materialization tree. The
//! testing allocator's leak detection guards `toOwned`'s fail-loud cleanup.
//! Codec-wire backings are exercised by the per-codec view tests.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const view = model.view;
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;

/// Round-trip one owned message through the neutral view and assert the
/// materialized copy is structurally equal, with no leak.
fn expectRoundTrip(message: model.Message) !void {
    const allocator = std.testing.allocator;
    const body = view.Body.fromOwned(&message);
    try std.testing.expectEqualStrings(@tagName(message), @tagName(body));

    const owned = try body.toOwned(allocator);
    defer model.freeMessage(allocator, owned);

    try std.testing.expect(messagesEqual(message, owned));
}

test "deliver with nested args, promise target, and resolve_me_desc round-trips" {
    const inner = [_]model.Argument{ .{ .integer = 7 }, .{ .boolean = true } };
    const args = [_]model.Argument{
        .{ .bytes = "raw" },
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.object(3) } },
        .{ .list = &inner },
        .{ .tagged = .{ .tag = "rec", .value = &inner } },
    };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(9) } },
        .args = &args,
        .answer = .from(11),
        .resolve_me_desc = .{ .near = model.NearRef.promise(4) },
    } });
}

test "resolve fulfill with a reference payload round-trips" {
    try expectRoundTrip(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(5) } } },
    } });
}

test "resolve break round-trips" {
    try expectRoundTrip(.{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .@"break" = .{ .message = "boom" } },
    } });
}

test "gc_export and gc_answer position lists round-trip" {
    const positions = [_]u64{ 5, 6, 7 };
    const deltas = [_]u64{ 1, 1, 2 };
    try expectRoundTrip(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
    try expectRoundTrip(.{ .gc_answer = .{ .positions = &positions } });
}

test "abort view round-trips with typed kind and message" {
    try expectRoundTrip(.{ .abort = .{ .kind = .protocol_error, .message = "bye" } });
}

test "listen, get, index round-trip" {
    try expectRoundTrip(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(7) },
        .listener = .{ .near = model.NearRef.object(9) },
        .mode = .shortening_or_settling,
    } });
    try expectRoundTrip(.{ .get = .{ .receiver = .{ .far = model.FarRef.object(2) }, .field = "name", .answer = .from(3) } });
    try expectRoundTrip(.{ .index = .{ .receiver = .{ .far = model.FarRef.object(2) }, .index = .{ .integer = 5 }, .answer = .from(4) } });
}

test "start_session round-trips" {
    try expectRoundTrip(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = "pubkey-bytes" },
        .acceptable_location = .{ .transport = "memory", .designator = "host" },
        .acceptable_location_sig = .{ .bytes = "sig-bytes" },
    } });
}

test "deliver with nested handoff give and receive round-trips" {
    const give = model.HandoffGive{
        .recipient_key = "rk",
        .exporter = .{ .transport = "memory", .designator = "el" },
        .gifter_exporter_session = "ges",
        .gifter_side = "gs",
        .gift_id = "gid",
        .signature = "sig",
    };
    var give_handoff = model.Handoff{ .give = give };
    var receive_handoff = model.Handoff{ .receive = .{
        .receiving_session = "rs",
        .receiving_side = "rside",
        .handoff_count = 2,
        .signed_give = give,
        .signature = "rsig",
    } };
    const args = [_]model.Argument{ .{ .handoff = &give_handoff }, .{ .handoff = &receive_handoff } };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &args,
    } });
}

test "Args slice backing reports len and projects each element" {
    const args = [_]model.Argument{ .{ .integer = 1 }, .{ .symbol = "x" } };
    const a = view.Args.fromOwnedSlice(&args);
    try std.testing.expectEqual(@as(usize, 2), try a.len());
    try std.testing.expectEqual(@as(i64, 1), (try a.at(0)).integer);
    try std.testing.expectEqualStrings("x", (try a.at(1)).symbol);
}

test "view.PeerLocator.toOwned clones transport and designator" {
    const loc = view.PeerLocator{
        .transport = "tcp",
        .designator = "host:9045",
    };
    const owned = try loc.toOwned(std.testing.allocator);
    defer model.freePeerLocator(std.testing.allocator, owned);
    try std.testing.expectEqualStrings("tcp", owned.transport);
    try std.testing.expectEqualStrings("host:9045", owned.designator);
}
