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
const codec = glowcap.ocapn.codec;
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

test "view-backed args read, checkpoint, and materialize like a slice" {
    const allocator = std.testing.allocator;
    const views = [_]view.Argument{ .{ .symbol = "greet" }, .{ .string = "world" }, .{ .integer = 3 } };
    const args = view.Args.fromViews(&views);
    try std.testing.expectEqual(@as(usize, 3), try args.len());
    try std.testing.expectEqualStrings("world", (try args.at(1)).string);
    try std.testing.expectError(error.MalformedView, args.at(3));

    var it = args.iterator();
    _ = try it.next();
    const second = it.checkpoint();
    try std.testing.expectEqualStrings("world", (try it.next()).?.string);
    try std.testing.expectEqual(@as(i64, 3), (try it.next()).?.integer);
    try std.testing.expectEqual(@as(?view.Argument, null), try it.next());
    try std.testing.expectEqualStrings("world", (try args.atCheckpoint(second)).string);

    const owned = try args.toOwnedSlice(allocator);
    defer model.freeArgumentSlice(allocator, owned);
    try std.testing.expectEqual(@as(usize, 3), owned.len);
    try std.testing.expectEqualStrings("greet", owned[0].symbol);
}

test "run-backed args read the words in place and materialize like a slice" {
    const allocator = std.testing.allocator;
    const values = [_]i64{ 5, -7, 1 << 40 };
    var words: [values.len * 8]u8 align(8) = undefined;
    for (values, 0..) |value, i| std.mem.writeInt(i64, words[i * 8 ..][0..8], value, .little);
    const args = view.Args.fromRun(&words);
    try std.testing.expectEqual(@as(usize, 3), try args.len());
    try std.testing.expectEqual(@as(i64, -7), (try args.at(1)).integer);
    try std.testing.expectError(error.MalformedView, args.at(3));
    try std.testing.expect(args.backingViews() == null);
    try std.testing.expectEqualSlices(u8, &words, args.wordRun().?);
    try std.testing.expectEqualSlices(i64, &values, args.typedRun().?);

    var it = args.iterator();
    _ = try it.next();
    const second = it.checkpoint();
    try std.testing.expectEqual(@as(i64, -7), (try it.next()).?.integer);
    try std.testing.expectEqual(@as(i64, 1 << 40), (try it.next()).?.integer);
    try std.testing.expectEqual(@as(?view.Argument, null), try it.next());
    try std.testing.expectEqual(@as(i64, -7), (try args.atCheckpoint(second)).integer);

    const owned = try args.toOwnedSlice(allocator);
    defer model.freeArgumentSlice(allocator, owned);
    try std.testing.expectEqual(@as(usize, 3), owned.len);
    try std.testing.expectEqual(@as(i64, 1 << 40), owned[2].integer);

    // A run the host cannot read as it lies (here, one off word alignment)
    // still reads element by element, and no typed slice is lent.
    var shifted: [values.len * 8 + 8]u8 align(8) = undefined;
    @memcpy(shifted[1 .. words.len + 1], &words);
    const unaligned = view.Args.fromRun(shifted[1 .. words.len + 1]);
    try std.testing.expect(unaligned.typedRun() == null);
    try std.testing.expectEqual(@as(i64, 5), (try unaligned.at(0)).integer);

    const positions = view.PositionList.fromRun(words[0..16]);
    try std.testing.expectEqual(@as(usize, 2), try positions.len());
    try std.testing.expectEqual(@as(u64, 5), try positions.at(0));
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

fn expectCheckpoints(args: view.Args) !void {
    var it = args.iterator();
    var saved: [3]view.Args.Checkpoint = undefined;
    for (&saved, 0..) |*checkpoint, index| {
        checkpoint.* = it.checkpoint();
        const element = (try it.next()).?;
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), element.integer);
    }
    try std.testing.expectError(error.MalformedView, args.atCheckpoint(it.checkpoint()));
    try std.testing.expect((try it.next()) == null);
    // Revisit in reverse order: the checkpoint is a saved cursor, not a
    // request to replay a prefix from the start of the sequence.
    for (0..saved.len) |offset| {
        const index = saved.len - 1 - offset;
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), (try args.atCheckpoint(saved[index])).integer);
    }
    try std.testing.expectError(error.MalformedView, args.atCheckpoint(@fromBackingInt(@intCast(std.math.maxInt(u64)))));
}

test "iterator checkpoints revisit slice and both codec backings and refuse the end" {
    const elements = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    try expectCheckpoints(view.Args.fromOwnedSlice(&elements));
    for ([_]model.CodecId{ .syrup, .capnp }) |encoding| {
        var frame = try codec.dispatch.encodeMessageForProfile(encoding, std.testing.allocator, .v1_0, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &elements,
        } });
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(encoding, .v1_0, frame.view());
        try expectCheckpoints(body.deliver.args);
    }
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

test "a Syrup sequence length is the count the framing walk recorded, not a second walk" {
    const allocator = std.testing.allocator;
    const inner = [_]model.Argument{ .{ .integer = 7 }, .{ .string = "seven" } };
    const args = [_]model.Argument{ .{ .string = "hello" }, .{ .list = &inner }, .{ .tagged = .{ .tag = "rec", .value = &inner } } };
    var frame = try codec.syrup.encodeMessageForProfile(allocator, .v1_0, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &args,
    } });
    defer frame.deinit();
    const decoded = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
    try std.testing.expectEqual(@as(usize, args.len), try decoded.deliver.args.len());
    const nested = try decoded.deliver.args.at(1);
    try std.testing.expectEqual(@as(usize, inner.len), try nested.list.len());
    const tagged = try decoded.deliver.args.at(2);
    try std.testing.expectEqual(@as(usize, inner.len), try tagged.tagged.value.len());
}

test "a settle whose claim overlaps the stack keeps push order" {
    var views: [10]model.view.Argument = undefined;
    var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    const claimed = slab.claim(model.view.Argument, 3).?;
    for (claimed, 0..) |*slot, i| slot.* = .{ .integer = @intCast(100 + i) };
    // Five pushes land at 9 down to 5, and the claim at 3 to 8 overlaps the
    // stack's three latest pushes.
    for (0..5) |i| (slab.reserve(model.view.Argument) orelse return error.TestUnexpectedResult).* = .{ .integer = @intCast(i) };
    try std.testing.expectEqual(@as(usize, 5) * @sizeOf(model.view.Argument), slab.open);
    const settled = slab.settle(model.view.Argument, 5);
    try std.testing.expectEqual(@as(usize, 8) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expectEqual(@as(usize, 10) * @sizeOf(model.view.Argument), slab.open);
    for (settled, 0..) |item, i| try std.testing.expectEqual(@as(i64, @intCast(i)), item.integer);
    for (claimed, 0..) |item, i| try std.testing.expectEqual(@as(i64, @intCast(100 + i)), item.integer);
    try std.testing.expect(slab.claim(model.view.Argument, 3) == null);
    try std.testing.expect(slab.claim(model.view.Argument, 2) != null);
}

fn expectTail(args: view.Args) !void {
    const rest = try args.from(1);
    try std.testing.expectEqual(@as(usize, 2), try rest.len());
    try std.testing.expectEqual(@as(i64, 2), (try rest.at(0)).integer);
    var it = rest.iterator();
    try std.testing.expectEqual(@as(i64, 2), (try it.next()).?.integer);
    try std.testing.expectEqual(@as(i64, 3), (try it.next()).?.integer);
    try std.testing.expect((try it.next()) == null);
    // A tail of a tail skips from the new start, not the original one.
    try std.testing.expectEqual(@as(i64, 3), (try (try rest.from(1)).at(0)).integer);
    try std.testing.expectEqual(@as(usize, 0), try (try args.from(3)).len());
    try std.testing.expectError(error.MalformedView, args.from(4));
}

test "from skips a prefix on slice, view, run, and both codec backings and refuses past the end" {
    const elements = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    try expectTail(view.Args.fromOwnedSlice(&elements));
    const views = [_]view.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    try expectTail(view.Args.fromViews(&views));
    var words: [24]u8 align(8) = undefined;
    for (elements, 0..) |element, i| std.mem.writeInt(i64, words[i * 8 ..][0..8], element.integer, .little);
    try expectTail(view.Args.fromRun(&words));
    for ([_]model.CodecId{ .syrup, .capnp }) |encoding| {
        var frame = try codec.dispatch.encodeMessageForProfile(encoding, std.testing.allocator, .v1_0, .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{ .{ .list = &elements }, .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } },
        } });
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(encoding, .v1_0, frame.view());
        try expectTail(try body.deliver.args.from(1));
        try expectTail((try body.deliver.args.at(0)).list);
    }
}
