//! Cap'n Proto golden-byte lock: encode must match committed frames byte-for-
//! byte, and decode must accept them. Round-trip alone cannot catch encode and
//! decode drifting together (ADR-0026).
//!
//! Regenerate fixtures: `zig build gen-capnp-fixtures`.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const capnp = pancake.ocapn.codec.capnp;
const handoff_fixtures = @import("../support/handoff_fixtures.zig");

const Fixture = struct {
    name: []const u8,
    message: model.Message,
    bytes: []const u8,
};

fn fixtures() [13]Fixture {
    return .{
        .{ .name = "op_abort.bin", .message = .{ .abort = .{ .kind = .protocol_error, .message = "nope" } }, .bytes = @embedFile("capnp_fixtures/op_abort.bin") },
        .{ .name = "op_gc_answer.bin", .message = .{ .gc_answer = .{ .positions = &.{ 1, 4, 9 } } }, .bytes = @embedFile("capnp_fixtures/op_gc_answer.bin") },
        .{ .name = "op_gc_export.bin", .message = .{ .gc_export = .{ .positions = &.{ 2, 3 }, .deltas = &.{ 1, 1 } } }, .bytes = @embedFile("capnp_fixtures/op_gc_export.bin") },
        .{ .name = "op_deliver.bin", .message = .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = .from(42),
            .resolve_me_desc = null,
        } }, .bytes = @embedFile("capnp_fixtures/op_deliver.bin") },
        .{ .name = "op_resolve_fulfill.bin", .message = .{ .resolve = .{
            .answer = .from(42),
            .resolution = .{ .fulfill = .{ .bytes = "pong" } },
        } }, .bytes = @embedFile("capnp_fixtures/op_resolve_fulfill.bin") },
        .{ .name = "op_resolve_break.bin", .message = .{ .resolve = .{
            .answer = .from(7),
            .resolution = .{ .@"break" = .{ .message = "fail" } },
        } }, .bytes = @embedFile("capnp_fixtures/op_resolve_break.bin") },
        .{ .name = "op_listen.bin", .message = .{ .listen = .{
            .target = .{ .far = .{ .import_position = .from(3) } },
            .listener = .{ .far = .{ .import_position = .from(9) } },
            .wants_partial = true,
        } }, .bytes = @embedFile("capnp_fixtures/op_listen.bin") },
        .{ .name = "op_get.bin", .message = .{ .get = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .field = "x",
            .answer = .from(5),
        } }, .bytes = @embedFile("capnp_fixtures/op_get.bin") },
        .{ .name = "op_index.bin", .message = .{ .index = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .index = 2,
            .answer = .from(6),
        } }, .bytes = @embedFile("capnp_fixtures/op_index.bin") },
        .{ .name = "op_untag.bin", .message = .{ .untag = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .tag = "t",
            .answer = .from(8),
        } }, .bytes = @embedFile("capnp_fixtures/op_untag.bin") },
        .{ .name = "op_start_session.bin", .message = .{ .start_session = .{
            .captp_version = .next,
            .session_pubkey = .{ .bytes = &([_]u8{0x11} ** 32) },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "127.0.0.1:9",
                .hints = model.Hints.emptyFalse(),
            },
            .acceptable_location_sig = .{ .bytes = &([_]u8{0x22} ** 64) },
        } }, .bytes = @embedFile("capnp_fixtures/op_start_session.bin") },
        .{ .name = "op_handoff_give.bin", .message = .{ .handoff = .{ .give = handoff_fixtures.give() } }, .bytes = @embedFile("capnp_fixtures/op_handoff_give.bin") },
        .{ .name = "op_handoff_receive.bin", .message = .{ .handoff = .{ .receive = handoff_fixtures.receive() } }, .bytes = @embedFile("capnp_fixtures/op_handoff_receive.bin") },
    };
}

test "Cap'n Proto golden fixtures: encode matches committed bytes" {
    const allocator = std.testing.allocator;
    for (fixtures()) |f| {
        var frame = try capnp.encodeMessage(allocator, f.message);
        defer frame.deinit();
        try std.testing.expectEqualSlices(u8, f.bytes, frame.bytes());
    }
}

test "Cap'n Proto golden fixtures: decode accepts committed bytes" {
    const allocator = std.testing.allocator;
    for (fixtures()) |f| {
        const storage = try allocator.alignedAlloc(u8, .fromByteUnits(8), f.bytes.len);
        @memcpy(storage, f.bytes);
        var frame = try pancake.foundation.Frame.initOwned(
            allocator,
            storage,
            .word,
            .fromByteUnits(8),
        );
        defer frame.deinit();
        const decoded = try capnp.decodeOwned(allocator, frame.view());
        defer model.freeMessage(allocator, decoded);
    }
}
