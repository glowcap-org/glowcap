//! One-shot writer for `test/codec/capnp_fixtures/*.bin`.
//! Run via `zig build gen-capnp-fixtures`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;

/// Held at container scope so the slice below points at static storage rather
/// than a temporary in `main`'s frame. `test/codec/capnp_golden_test.zig`
/// declares the same list for the same reason, and the golden bytes hold the
/// two in agreement.
const deposit_gift_args = [_]model.Argument{
    .{ .symbol = "deposit-gift" },
    .{ .bytes = "gift-1" },
    .{ .reference = .{ .far = .{ .import_position = .from(5) } } },
};

/// A list of integers, which rides as a run of words (ADR-0010).
const integer_samples = [_]model.Argument{ .{ .integer = 100 }, .{ .integer = -200 }, .{ .integer = 300 } };
const integer_list_args = [_]model.Argument{ .{ .symbol = "report" }, .{ .list = &integer_samples } };

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
        // The gifter's deposit leg of a three-party handoff, the one
        // deliver shape here that carries a symbol, a bytestring, and a
        // reference in one argument list. `engine.Peer.sendDepositGift`
        // is the definition this mirrors.
        .{ "op_deliver_deposit_gift.bin", .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &deposit_gift_args,
            .answer = null,
            .resolve_me_desc = null,
        } } },
        .{ "op_deliver_integers.bin", .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &integer_list_args,
            .answer = .from(43),
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
            .mode = .shortening_or_settling,
        } } },
        .{ "op_get.bin", .{ .get = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .field = "x",
            .answer = .from(5),
        } } },
        .{ "op_index.bin", .{ .index = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .index = .{ .integer = 2 },
            .answer = .from(6),
        } } },
        .{ "op_untag.bin", .{ .untag = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .tag = "t",
            .answer = .from(8),
        } } },
        .{ "op_start_session.bin", .{ .start_session = .{
            .captp_version = .next,
            .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0x11))) },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "127.0.0.1:9",
                .hints = model.Hints.emptyFalse(),
            },
            .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0x22))) },
        } } },
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
