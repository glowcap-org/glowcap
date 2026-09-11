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

test "rooms-peer subscribe fulfillment yields the membership seat, with or without topic authority" {
    const with_topic = wire.classifySubscribeSettlement(.{ .fulfilled = .{ .list = &.{
        .{ .reference = farRef(9) },
        .{ .string = "participant" },
        .{ .reference = farRef(10) },
    } } });
    try std.testing.expect(with_topic == .fulfilled);
    try std.testing.expectEqual(@as(u64, 9), with_topic.fulfilled.far.import_position.int());
    const no_topic = wire.classifySubscribeSettlement(.{ .fulfilled = .{ .list = &.{
        .{ .reference = farRef(9) },
        .{ .string = "observer" },
        .{ .void = {} },
    } } });
    try std.testing.expect(no_topic == .fulfilled);
    try std.testing.expectEqual(@as(u64, 9), no_topic.fulfilled.far.import_position.int());
}

test "rooms-peer subscribe refusal and malformed fulfillment stay failures" {
    try std.testing.expect(wire.classifySubscribeSettlement(.{ .broken = "nick-taken" }) == .refused);
    try std.testing.expect(
        wire.classifySubscribeSettlement(.{ .fulfilled = .{ .string = "invalid settlement" } }) == .malformed,
    );
    // The old contract answered the topic authority alone; a bare reference or
    // void is no longer a seat and must not publish a joined state.
    try std.testing.expect(wire.classifySubscribeSettlement(.{ .fulfilled = .{ .reference = farRef(9) } }) == .malformed);
    try std.testing.expect(wire.classifySubscribeSettlement(.{ .fulfilled = .{ .void = {} } }) == .malformed);
    try std.testing.expect(
        wire.classifySubscribeSettlement(.{ .fulfilled = .{ .list = &.{.{ .string = "no seat" }} } }) == .malformed,
    );
    try std.testing.expect(wire.classifySubscribeSettlement(.{ .fulfilled = .{ .list = &.{
        .{ .reference = farRef(9) },
        .{ .string = "speaker" },
        .{ .void = {} },
    } } }) == .malformed);
    try std.testing.expect(wire.classifySubscribeSettlement(.{ .fulfilled = .{ .list = &.{
        .{ .reference = farRef(9) },
        .{ .string = "participant" },
        .{ .string = "no topic capability" },
    } } }) == .malformed);
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
