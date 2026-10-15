//! Cap'n Proto golden-byte lock: encode must match committed frames byte-for-
//! byte, and decode must accept them. Round-trip alone cannot catch encode and
//! decode drifting together (ADR-0026).
//!
//! Regenerate fixtures: `zig build gen-capnp-fixtures`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;

const Fixture = struct {
    name: []const u8,
    message: model.Message,
    bytes: []const u8,
};

/// The gifter's deposit leg: the one argument list here that carries a symbol,
/// a bytestring, and a reference together. `engine.Peer.sendDepositGift` is the
/// shape this mirrors.
///
/// A container-level constant, not a `&.{…}` literal inside `fixtures()`. An
/// argument list built from function calls is not comptime-known, so a literal
/// there would be a temporary in that function's frame and the returned slice
/// would dangle. Nothing about the deposit shape asks for the separate
/// declaration. The lifetime does.
const deposit_gift_args = [_]model.Argument{
    .{ .symbol = "deposit-gift" },
    .{ .bytes = "gift-1" },
    .{ .reference = .{ .far = .{ .import_position = .from(5) } } },
};

/// A list of integers, which rides as a run of words (ADR-0243).
const integer_samples = [_]model.Argument{ .{ .integer = 100 }, .{ .integer = -200 }, .{ .integer = 300 } };
const integer_list_args = [_]model.Argument{ .{ .symbol = "report" }, .{ .list = &integer_samples } };

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
        .{ .name = "op_deliver_deposit_gift.bin", .message = .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &deposit_gift_args,
            .answer = null,
            .resolve_me_desc = null,
        } }, .bytes = @embedFile("capnp_fixtures/op_deliver_deposit_gift.bin") },
        .{ .name = "op_deliver_integers.bin", .message = .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &integer_list_args,
            .answer = .from(43),
            .resolve_me_desc = null,
        } }, .bytes = @embedFile("capnp_fixtures/op_deliver_integers.bin") },
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
            .mode = .shortening_or_settling,
        } }, .bytes = @embedFile("capnp_fixtures/op_listen.bin") },
        .{ .name = "op_get.bin", .message = .{ .get = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .field = "x",
            .answer = .from(5),
        } }, .bytes = @embedFile("capnp_fixtures/op_get.bin") },
        .{ .name = "op_index.bin", .message = .{ .index = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .index = .{ .integer = 2 },
            .answer = .from(6),
        } }, .bytes = @embedFile("capnp_fixtures/op_index.bin") },
        .{ .name = "op_untag.bin", .message = .{ .untag = .{
            .receiver = .{ .far = .{ .import_position = .from(1) } },
            .tag = "t",
            .answer = .from(8),
        } }, .bytes = @embedFile("capnp_fixtures/op_untag.bin") },
        .{ .name = "op_start_session.bin", .message = .{ .start_session = .{
            .captp_version = .next,
            .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0x11))) },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "127.0.0.1:9",
                .hints = model.Hints.emptyFalse(),
            },
            .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0x22))) },
        } }, .bytes = @embedFile("capnp_fixtures/op_start_session.bin") },
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
        var frame = try glowcap.foundation.Frame.initOwned(
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
