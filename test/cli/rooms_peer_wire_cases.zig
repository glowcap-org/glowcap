//! Pure room-wire goldens for `glowcap app rooms-peer`: notification parsing
//! and subscribe-settlement classification, with no iroh or CapTP wire.
const std = @import("std");
const cli = @import("cli");

const model = cli.rooms_peer_common.model;
const wire = cli.rooms_peer_wire;

fn farRef(n: u64) model.Reference {
    return .{ .far = model.FarRef.object(n) };
}

test "rooms-peer named line notification reaches the room inbox parser" {
    const args = [_]model.Argument{
        .{ .string = "tree2" },
        .{ .string = "hello tree1" },
        .{ .string = "line" },
        .{ .integer = 42 },
    };
    const line = wire.roomLine(&args, "tree1").?;
    try std.testing.expectEqualStrings("tree2", line.from);
    try std.testing.expectEqualStrings("hello tree1", line.text);
}

test "rooms-peer room-owned presence and typing are not chat lines" {
    const presence = [_]model.Argument{
        .{ .string = "room" },
        .{ .string = "tree2 joined" },
        .{ .string = "join" },
        .{ .string = "tree2" },
    };
    try std.testing.expect(wire.roomLine(&presence, "tree1") == null);

    const typing = [_]model.Argument{
        .{ .string = "room" },
        .{ .string = "" },
        .{ .string = "typing" },
        .{ .string = "tree2" },
        .{ .boolean = true },
    };
    try std.testing.expect(wire.roomLine(&typing, "tree1") == null);
}

test "rooms-peer untagged lines remain chat and self lines stay excluded" {
    const untagged = [_]model.Argument{
        .{ .string = "tree2" },
        .{ .string = "plain hello" },
    };
    const line = wire.roomLine(&untagged, "tree1").?;
    try std.testing.expectEqualStrings("plain hello", line.text);

    const own = [_]model.Argument{
        .{ .string = "tree1" },
        .{ .string = "echo" },
        .{ .string = "line" },
        .{ .integer = 43 },
    };
    try std.testing.expect(wire.roomLine(&own, "tree1") == null);
}

test "rooms-peer subscribe fulfillment accepts topic authority or intentional none" {
    try std.testing.expectEqual(
        wire.SubscribeSettlement.fulfilled,
        wire.classifySubscribeSettlement(.{ .fulfilled = .{ .reference = farRef(9) } }),
    );
    try std.testing.expectEqual(
        wire.SubscribeSettlement.fulfilled,
        wire.classifySubscribeSettlement(.{ .fulfilled = .{ .void = {} } }),
    );
}

test "rooms-peer subscribe refusal and malformed fulfillment stay failures" {
    try std.testing.expectEqual(
        wire.SubscribeSettlement.refused,
        wire.classifySubscribeSettlement(.{ .broken = "nick-taken" }),
    );
    try std.testing.expectEqual(
        wire.SubscribeSettlement.malformed,
        wire.classifySubscribeSettlement(.{ .fulfilled = .{ .string = "invalid settlement" } }),
    );
}

test "rooms-peer inbox persistence failure reaches process diagnostics" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    cli.log.test_capture.reset();
    _ = wire.recordReceived(threaded.io(), failing.allocator(), "unused", "room", "tree2", "lost", "");
    const diagnostic = cli.log.test_capture.captured();
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "recording room line from \"tree2\" failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "OutOfMemory") != null);
}
