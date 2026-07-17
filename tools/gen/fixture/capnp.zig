//! One-shot writer for `test/codec/capnp_fixtures/*.bin`.
//! Run via `zig build gen-capnp-fixtures`.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const capnp = pancake.ocapn.codec.capnp;
const handoff_fixtures = @import("handoff_fixtures");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct { []const u8, model.Message }{
        .{ "op_abort.bin", .{ .abort = .{ .kind = .protocol_error, .message = "nope" } } },
        .{ "op_gc_answer.bin", .{ .gc_answer = .{ .positions = &.{ 1, 4, 9 } } } },
        .{ "op_gc_export.bin", .{ .gc_export = .{ .positions = &.{ 2, 3 }, .deltas = &.{ 1, 1 } } } },
        .{ "op_deliver.bin", .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = .from(42),
            .resolve_me_desc = null,
        } } },
        .{ "op_resolve_fulfill.bin", .{ .resolve = .{
            .answer = .from(42),
            .resolution = .{ .fulfill = .{ .bytes = "pong" } },
        } } },
        .{ "op_resolve_break.bin", .{ .resolve = .{
            .answer = .from(7),
            .resolution = .{ .@"break" = .{ .message = "fail" } },
        } } },
        .{ "op_listen.bin", .{ .listen = .{
            .target = .{ .far = .{ .import_position = .from(3) } },
            .listener = .{ .far = .{ .import_position = .from(9) } },
            .wants_partial = true,
        } } },
        .{ "op_get.bin", .{ .get = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .field = "x",
            .answer = .from(5),
        } } },
        .{ "op_index.bin", .{ .index = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .index = 2,
            .answer = .from(6),
        } } },
        .{ "op_untag.bin", .{ .untag = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .tag = "t",
            .answer = .from(8),
        } } },
        .{ "op_start_session.bin", .{ .start_session = .{
            .captp_version = .next,
            .session_pubkey = .{ .bytes = &([_]u8{0x11} ** 32) },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "127.0.0.1:9",
                .hints = model.Hints.emptyFalse(),
            },
            .acceptable_location_sig = .{ .bytes = &([_]u8{0x22} ** 64) },
        } } },
        .{ "op_handoff_give.bin", .{ .handoff = .{ .give = handoff_fixtures.give() } } },
        .{ "op_handoff_receive.bin", .{ .handoff = .{ .receive = handoff_fixtures.receive() } } },
    };

    for (cases) |c| {
        var frame = try capnp.encodeMessage(allocator, c[1]);
        defer frame.deinit();
        const path = try std.fmt.allocPrint(allocator, "test/codec/capnp_fixtures/{s}", .{c[0]});
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = frame.bytes() });
        std.debug.print("wrote {s} ({d} bytes)\n", .{ path, frame.bytes().len });
    }
}
