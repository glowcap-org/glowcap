//! The Cap'n Proto encoder over a borrowed body: a decoded frame re-encodes
//! through `encodeBodyForProfile` to the bytes its owned source produced,
//! including a word run, a set, a struct, a signed give and receive, and a
//! hinted sturdyref, and a body decoded from Syrup (whose signatures arrive
//! in halves) encodes on Cap'n Proto as its owned copy does. A list a
//! caller lends as a run of words encodes on both codecs as its owned list.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;
const syrup = glowcap.ocapn.codec.syrup;
const handoff_fixtures = @import("../support/handoff_fixtures.zig");

/// Encode a deliver carrying `arg` on a promise target (a far target decodes
/// to a near one, which the encoder refuses), decode it to views, and
/// re-encode the views.
fn expectArgumentViewRoundTrip(arg: model.Argument) !void {
    const allocator = std.testing.allocator;
    const args = [_]model.Argument{ .{ .symbol = "deposit" }, arg };
    var frame = try capnp.encodeMessageForProfile(allocator, .v1_0, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3) } },
        .args = &args,
        .answer = .from(9),
    } });
    defer frame.deinit();

    const body = try capnp.decodeBodyForProfile(.v1_0, frame.view());
    var again = try capnp.encodeBodyForProfile(allocator, .v1_0, &body);
    defer again.deinit();
    try std.testing.expectEqualSlices(u8, frame.bytes(), again.bytes());
}

test "decoded argument arms re-encode from their views byte for byte" {
    const samples = [_]model.Argument{ .{ .integer = 100 }, .{ .integer = -200 }, .{ .integer = 1 << 40 } };
    const members = [_]model.Argument{ .{ .integer = 3 }, .{ .string = "one" }, .{ .boolean = false } };
    const entries = [_]model.StructEntry{
        .{ .key = "b", .value = .{ .integer = 2 } },
        .{ .key = "a", .value = .{ .list = &samples } },
    };
    try expectArgumentViewRoundTrip(.{ .list = &samples });
    try expectArgumentViewRoundTrip(.{ .list = &members });
    try expectArgumentViewRoundTrip(.{ .list = &.{} });
    try expectArgumentViewRoundTrip(.{ .set = &members });
    try expectArgumentViewRoundTrip(.{ .@"struct" = &entries });
    try expectArgumentViewRoundTrip(.{ .tagged = .{ .tag = "t", .value = &samples } });
    try expectArgumentViewRoundTrip(.{ .keyword = "kw" });
    try expectArgumentViewRoundTrip(.{ .@"error" = .{ .message = "why" } });
    try expectArgumentViewRoundTrip(.{ .big_integer = .{ .negative = true, .digits = "123456789012345678901234567890" } });
}

test "decoded signed give, receive, and hinted sturdyref re-encode from their views" {
    var give: model.Handoff = .{ .give = handoff_fixtures.give() };
    try expectArgumentViewRoundTrip(.{ .handoff = &give });
    var receive: model.Handoff = .{ .receive = handoff_fixtures.receive() };
    try expectArgumentViewRoundTrip(.{ .handoff = &receive });

    const hints = [_]model.HintEntry{
        .{ .name = "relay", .value = .{ .string = "relay.example" } },
        .{ .name = "ttl", .value = .{ .integer = 30 } },
    };
    const sturdy: model.SturdyRef = .{
        .peer = .{ .transport = "tcp", .designator = "exporter.example", .hints = .{ .entries = &hints } },
        .swissnum = "swiss-number",
    };
    try expectArgumentViewRoundTrip(.{ .reference = .{ .sturdy = &sturdy } });
}

test "decoded gc and start-session bodies re-encode from their views" {
    const allocator = std.testing.allocator;
    const pubkey: [32]u8 = @splat(0xaa);
    const sig: [64]u8 = @splat(0xcc);
    const positions = [_]u64{ 5, 6, 7 };
    const deltas = [_]u64{ 1, 1, 2 };
    for ([_]model.Message{
        .{ .gc_export = .{ .positions = &positions, .deltas = &deltas } },
        .{ .gc_answer = .{ .positions = &positions } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &pubkey },
            .acceptable_location = .{ .transport = "memory", .designator = "exporter" },
            .acceptable_location_sig = .{ .bytes = &sig },
        } },
        .{ .abort = .{ .kind = .protocol_error, .message = "bye" } },
    }) |message| {
        var frame = try capnp.encodeMessageForProfile(allocator, .v1_0, message);
        defer frame.deinit();
        const body = try capnp.decodeBodyForProfile(.v1_0, frame.view());
        var again = try capnp.encodeBodyForProfile(allocator, .v1_0, &body);
        defer again.deinit();
        try std.testing.expectEqualSlices(u8, frame.bytes(), again.bytes());
    }
}

test "a body decoded from Syrup encodes on Cap'n Proto as its owned copy does" {
    const allocator = std.testing.allocator;
    var give: model.Handoff = .{ .give = handoff_fixtures.give() };
    const samples = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const args = [_]model.Argument{ .{ .symbol = "deposit" }, .{ .handoff = &give }, .{ .list = &samples } };
    var syrup_frame = try syrup.encodeMessageForProfile(allocator, .v1_0, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3) } },
        .args = &args,
        .answer = .from(9),
    } });
    defer syrup_frame.deinit();

    const body = try syrup.decodeBodyForProfile(.v1_0, syrup_frame.view());
    var via_view = try capnp.encodeBodyForProfile(allocator, .v1_0, &body);
    defer via_view.deinit();
    const owned = try body.toOwned(allocator);
    defer model.freeMessage(allocator, owned);
    var via_owned = try capnp.encodeMessageForProfile(allocator, .v1_0, owned);
    defer via_owned.deinit();
    try std.testing.expectEqualSlices(u8, via_owned.bytes(), via_view.bytes());
}

test "malformed text refuses the encode on a borrowed body as on an owned one" {
    const allocator = std.testing.allocator;
    const args = [_]model.Argument{ .{ .symbol = "deposit" }, .{ .string = "\xff\xfe" } };
    const message: model.Message = .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(3) } },
        .args = &args,
        .answer = .from(9),
    } };
    try std.testing.expectError(error.UnsupportedArgument, capnp.encodeMessageForProfile(allocator, .v1_0, message));
    const body = model.view.Body.fromOwned(&message);
    try std.testing.expectError(error.UnsupportedArgument, capnp.encodeBodyForProfile(allocator, .v1_0, &body));
}

test "a list lent as a run of words encodes on both codecs as its owned list does" {
    const allocator = std.testing.allocator;
    const words = [_]i64{ 100_000, -7, 1 << 40, 0, std.math.minInt(i64), std.math.maxInt(i64) };
    var owned_samples: [words.len]model.Argument = undefined;
    // Run bytes are little-endian even on a big-endian host, and a borrowed
    // frame need not align them for native loads.
    var storage: [1 + words.len * 8]u8 align(8) = undefined;
    const run = storage[1..];
    for (words, &owned_samples, 0..) |word, *item, i| {
        item.* = .{ .integer = word };
        std.mem.writeInt(i64, run[i * 8 ..][0..8], word, .little);
    }
    for (0..words.len + 1) |count| {
        const owned_args = [_]model.Argument{ .{ .symbol = "report" }, .{ .list = owned_samples[0..count] } };
        const message: model.Message = .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(3) } },
            .args = &owned_args,
            .answer = .from(9),
        } };
        const lent = [_]model.view.Argument{ .{ .symbol = "report" }, .{ .list = .fromRun(run[0 .. count * 8]) } };
        var body = model.view.Body.fromOwned(&message);
        body.deliver.args = .fromViews(&lent);

        var capnp_owned = try capnp.encodeMessageForProfile(allocator, .v1_0, message);
        defer capnp_owned.deinit();
        var capnp_lent = try capnp.encodeBodyForProfile(allocator, .v1_0, &body);
        defer capnp_lent.deinit();
        try std.testing.expectEqualSlices(u8, capnp_owned.bytes(), capnp_lent.bytes());

        var syrup_owned = try syrup.encodeMessageForProfile(allocator, .v1_0, message);
        defer syrup_owned.deinit();
        var syrup_lent = try syrup.encodeBodyForProfile(allocator, .v1_0, &body);
        defer syrup_lent.deinit();
        try std.testing.expectEqualSlices(u8, syrup_owned.bytes(), syrup_lent.bytes());
    }
}
