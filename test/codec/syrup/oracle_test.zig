//! The encoder against the reference corpus: core, typed-abort, V1_0,
//! start-session, and nested fixtures byte-for-byte, and the unlowered
//! argument it must refuse.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const syrup = pancake.ocapn.codec.syrup;
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");
const handoff_fixtures = @import("../../support/handoff_fixtures.zig");

const harness = @import("harness.zig");
const expectFixtureBytes = harness.expectFixtureBytes;
const repeatedByte = harness.repeatedByte;
const hexToOwned = harness.hexToOwned;

test "Syrup encoder matches core Goblins operation fixtures" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .abort = .{ .kind = .other, .message = "shutting down" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .bytes = "hello" }};
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = args[0..],
                .answer = .from(42),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .gc_export = .{
                .positions = &.{ 3, 7 },
                .deltas = &.{ 1, 2 },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_gc_exports.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .gc_answer = .{ .positions = &.{ 11, 13 } },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_gc_answers.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .get = .{
                .receiver = .{ .far = .{ .import_position = .from(7) } },
                .field = "name",
                .answer = .from(11),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_get.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .index = .{
                .receiver = .{ .far = .{ .import_position = .from(7) } },
                .index = .{ .integer = 5 },
                .answer = .from(11),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_index.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .untag = .{
                .receiver = .{ .far = .{ .import_position = .from(7) } },
                .tag = "cm",
                .answer = .from(11),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_untag.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .resolve = .{
                .answer = .from(42),
                .resolution = .{ .@"break" = .{ .message = "target unreachable" } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_break.bin", frame);
    }
}

test "Syrup encoder matches reference and rich argument fixtures" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .resolve = .{
                .answer = .from(7),
                .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(5) } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_far.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .resolve = .{
                .answer = .from(7),
                .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_near.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .resolve = .{
                .answer = .from(7),
                .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(11) } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_promise.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .void = {} }};
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = args[0..],
                .answer = .from(42),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_arg_void.bin", frame);
    }

    {
        const values = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
        const args = [_]model.Argument{.{ .tagged = .{ .tag = "point", .value = values[0..] } }};
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = args[0..],
                .answer = .from(42),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_arg_tagged.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .keyword = "name" }};
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = args[0..],
                .answer = .from(42),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_arg_keyword.bin", frame);
    }

    {
        const values = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
        const args = [_]model.Argument{.{ .set = values[0..] }};
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = args[0..],
                .answer = .from(42),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_arg_set.bin", frame);
    }
}

test "Syrup refuses an unlowered Node capability route" {
    try std.testing.expectError(syrup.Error.UnsupportedReference, syrup.encodeMessage(std.testing.allocator, .{
        .deliver = .{
            .target = .{ .routed = .{ .id = .from(7) } },
            .args = &.{},
        },
    }));
}

test "Syrup encoder matches typed abort fixture batch" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .abort = .{ .kind = .resource_exhausted, .message = "ImportTable cap hit" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort_resource_exhausted.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .abort = .{ .kind = .crossed_hellos, .message = "byte-lower side closing" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort_crossed_hellos.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .abort = .{ .kind = .connection_lost, .message = "peer TCP RST" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort_connection_lost.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .abort = .{ .kind = .graceful_shutdown, .message = "SIGTERM drain complete" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort_graceful_shutdown.bin", frame);
    }
}

test "Syrup encoder matches V1_0 listen and deliver fixture batch" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .listen = .{
                .target = .{ .promise = .{ .answer_position = .from(7) } },
                .listener = .{ .near = .{ .export_position = .from(9) } },
                .mode = .settling_only,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_v1_0_wants_partial_false.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .listen = .{
                .target = .{ .promise = .{ .answer_position = .from(7) } },
                .listener = .{ .near = .{ .export_position = .from(9) } },
                .mode = .shortening_or_settling,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_v1_0_wants_partial_true.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .bytes = "hello" }};
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(7) } },
                .args = args[0..],
                .answer = .from(42),
                .resolve_me_desc = .{ .near = .{ .export_position = .from(99) } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_v1_0_with_resolve_me_desc.bin", frame);
    }
}

test "Syrup encoder matches start-session fixture" {
    const allocator = std.testing.allocator;
    const pubkey = repeatedByte(32, 0xaa);
    const sig = repeatedByte(64, 0xcc);

    var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = pubkey[0..] },
            .acceptable_location = .{
                .transport = "memory",
                .designator = "exporter",
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = sig[0..] },
        },
    });
    defer frame.deinit();

    try expectFixtureBytes("op_start_session_v1_0.bin", frame);
}

test "Syrup encoder matches nested handoff fixture" {
    const allocator = std.testing.allocator;

    {
        var handoff_arg = model.Handoff{ .receive = handoff_fixtures.receive() };
        const args = [_]model.Argument{
            .{ .symbol = "withdraw-gift" },
            .{ .handoff = &handoff_arg },
        };
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_position = .from(0) } },
                .args = args[0..],
                .answer = .from(99),
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_withdraw_gift.bin", frame);

        const body = try syrup.decodeBody(frame.view());
        try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
        const borrowed_arg = try body.deliver.args.at(1);
        try std.testing.expect(borrowed_arg == .handoff);
        try std.testing.expectEqual(@as(u64, 1), borrowed_arg.handoff.receive.handoff_count);

        const decoded = try syrup.decodeOwned(allocator, frame.view());
        defer model.freeMessage(allocator, decoded);
        try std.testing.expect(decoded.deliver.args[1] == .handoff);
        try std.testing.expectEqual(@as(u64, 1), decoded.deliver.args[1].handoff.*.receive.handoff_count);
    }
}
