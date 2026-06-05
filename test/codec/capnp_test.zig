const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const capnp = pancake.codec.capnp;
const wire = capnp.wire;

test "struct pointer round-trips offset and section sizes (both signs)" {
    for ([_]i32{ 0, 1, 7, -1, -3, 100, -100 }) |offset| {
        const word = wire.encodeStructPointer(offset, 2, 1);
        try std.testing.expectEqual(wire.PointerKind.@"struct", wire.pointerKind(word));
        const decoded = wire.decodeStructPointer(word);
        try std.testing.expectEqual(offset, decoded.offset);
        try std.testing.expectEqual(@as(u16, 2), decoded.data_words);
        try std.testing.expectEqual(@as(u16, 1), decoded.ptr_words);
    }
}

test "list pointer round-trips offset, element size, and count" {
    const word = wire.encodeListPointer(-5, .eight_bytes, 42);
    try std.testing.expectEqual(wire.PointerKind.list, wire.pointerKind(word));
    const decoded = wire.decodeListPointer(word);
    try std.testing.expectEqual(@as(i32, -5), decoded.offset);
    try std.testing.expectEqual(wire.ElementSize.eight_bytes, decoded.elem);
    try std.testing.expectEqual(@as(u29, 42), decoded.count);
}

test "op:gc-answers round-trips through the Cap'n Proto codec" {
    const allocator = std.testing.allocator;

    const original = model.Message{ .gc_answer = .{ .positions = &.{ 1, 4, 9, 16 } } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    // A Cap'n Proto frame is word-shaped and a whole number of 8-byte words.
    try std.testing.expectEqual(pancake.foundation.FrameShape.word, frame.view().shape);
    try std.testing.expectEqual(@as(usize, 0), frame.bytes().len % wire.WORD_BYTES);

    const decoded = try capnp.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);

    try std.testing.expectEqualSlices(u64, original.gc_answer.positions, decoded.gc_answer.positions);
}

test "decodeBody projects the neutral view with lazy capnp backings (nested args, positions)" {
    const allocator = std.testing.allocator;

    // A deliver whose args exercise the lazy Args backing and a nested list
    // (itself another backing): [ "ping"(bytes), [ 'sym, 7 ] ].
    const nested = [_]model.Argument{ .{ .symbol = "sym" }, .{ .integer = 7 } };
    const args = [_]model.Argument{ .{ .bytes = "ping" }, .{ .list = &nested } };
    const original = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_id = 9 } },
        .args = &args,
        .answer = 5,
        .resolve_me_desc = null,
    } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const body = try capnp.decodeBody(frame.view());
    // Wire `far` (sender's import) flips to a `near` export on decode (ADR-0010).
    try std.testing.expectEqual(@as(u64, 9), body.deliver.target.near.export_id);
    try std.testing.expectEqual(@as(?u64, 5), body.deliver.answer);

    try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
    try std.testing.expectEqualSlices(u8, "ping", (try body.deliver.args.at(0)).bytes);

    const inner = (try body.deliver.args.at(1)).list;
    try std.testing.expectEqual(@as(usize, 2), try inner.len());
    try std.testing.expectEqualSlices(u8, "sym", (try inner.at(0)).symbol);
    try std.testing.expectEqual(@as(i64, 7), (try inner.at(1)).integer);
}

test "decodeBody projects a PositionList backing for gc-exports" {
    const allocator = std.testing.allocator;

    const original = model.Message{ .gc_export = .{ .positions = &.{ 3, 5, 8 }, .deltas = &.{ 1, 1, 2 } } };
    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const body = try capnp.decodeBody(frame.view());
    try std.testing.expectEqual(@as(usize, 3), try body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 8), try body.gc_export.positions.at(2));
    try std.testing.expectEqual(@as(u64, 2), try body.gc_export.deltas.at(2));
}

test "decodeView projects the body over borrowed frame bytes; toOwned materializes" {
    const allocator = std.testing.allocator;

    const original = model.Message{ .gc_answer = .{ .positions = &.{ 7, 11, 13 } } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const view = try capnp.decodeView(frame.view());
    try std.testing.expectEqual(capnp.Kind.gc_answer, view.kind);

    const decoded = try view.toOwned(allocator);
    defer model.freeMessage(allocator, decoded);
    try std.testing.expectEqualSlices(u64, original.gc_answer.positions, decoded.gc_answer.positions);
}

test "empty position list round-trips" {
    const allocator = std.testing.allocator;

    const original = model.Message{ .gc_answer = .{ .positions = &.{} } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const decoded = try capnp.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.gc_answer.positions.len);
}

/// Verify a message survives the wire intact. The codec flips reference
/// perspective on every crossing (ADR-0010): an encoded model `near` (our
/// export) decodes to a `far` import, and vice versa. The flip is an
/// involution, so two encode→decode crossings restore the original
/// perspective — the bytes after the second crossing equal the first encoding
/// iff every field `decodeOwned` touches survived both crossings. Because the
/// encoder renders every model field, that byte-equality proves faithful
/// reconstruction.
fn expectRoundTrip(message: model.Message) !void {
    const allocator = std.testing.allocator;
    var frame0 = try capnp.encodeMessage(allocator, message);
    defer frame0.deinit();
    try std.testing.expectEqual(pancake.foundation.FrameShape.word, frame0.view().shape);
    try std.testing.expectEqual(@as(usize, 0), frame0.bytes().len % wire.WORD_BYTES);

    const owned1 = try capnp.decodeOwned(allocator, frame0.view());
    defer model.freeMessage(allocator, owned1);
    var frame1 = try capnp.encodeMessage(allocator, owned1);
    defer frame1.deinit();

    const owned2 = try capnp.decodeOwned(allocator, frame1.view());
    defer model.freeMessage(allocator, owned2);
    var frame2 = try capnp.encodeMessage(allocator, owned2);
    defer frame2.deinit();

    try std.testing.expectEqualSlices(u8, frame0.bytes(), frame2.bytes());
}

test "abort round-trips with typed kind and message" {
    try expectRoundTrip(.{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } });
    try expectRoundTrip(.{ .abort = .{ .kind = .normal_shutdown, .message = "" } });
}

test "gc-export round-trips parallel position/delta lists" {
    try expectRoundTrip(.{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } });
}

test "resolve round-trips fulfill and break" {
    try expectRoundTrip(.{ .resolve = .{ .answer = 42, .resolution = .{ .fulfill = .{ .integer = -7 } } } });
    try expectRoundTrip(.{ .resolve = .{ .answer = 9, .resolution = .{ .break_ = .{ .message = "boom" } } } });
}

test "reference arms round-trip through deliver target" {
    try expectRoundTrip(.{ .deliver = .{ .target = .{ .near = model.NearRef.promise(3) }, .args = &.{} } });
    try expectRoundTrip(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(4) }, .args = &.{} } });
    try expectRoundTrip(.{ .deliver = .{ .target = .{ .sturdy = .{
        .peer = .{ .transport = "tcp", .designator = "host:9000" },
        .swissnum = &.{ 0xde, 0xad },
    } }, .args = &.{} } });
}

test "deliver round-trips args, answer, and a promise target with pipeline path" {
    const call_args = [_]model.Argument{.{ .string = "ping" }};
    const path_ops = [_]model.PipelineOp{ .{ .field = "field" }, .{ .call = &call_args } };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_id = 1, .path = .{ .ops = &path_ops } } },
        .args = &.{
            .{ .bytes = &.{ 1, 2, 3 } },
            .{ .symbol = "run" },
            .{ .boolean = true },
            .{ .integer = -99 },
            .{ .void = {} },
            .{ .list = &call_args },
            .{ .tagged = .{ .tag = "point", .value = &call_args } },
        },
        .answer = 7,
    } });
}

test "listen, get, and index round-trip" {
    try expectRoundTrip(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .listener = .{ .near = model.NearRef.object(2) },
        .wants_partial = true,
    } });
    try expectRoundTrip(.{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = 8 } });
    try expectRoundTrip(.{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = -3, .answer = 9 } });
}

test "start-session round-trips the four-operand handshake" {
    try expectRoundTrip(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &([_]u8{0xab} ** 32) },
        .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
        .acceptable_location_sig = .{ .bytes = &([_]u8{0xcd} ** 64) },
    } });
}

test "handoff give and receive round-trip" {
    const give = model.HandoffGive{
        .recipient_key = &([_]u8{0x01} ** 32),
        .exporter_location = "tcp:host",
        .gifter_exporter_session = &([_]u8{0x02} ** 32),
        .gifter_side = &([_]u8{0x03} ** 32),
        .gift_id = &([_]u8{0x04} ** 32),
        .signature = &([_]u8{0x05} ** 64),
    };
    try expectRoundTrip(.{ .handoff = .{ .give = give } });
    try expectRoundTrip(.{ .handoff = .{ .receive = .{
        .receiving_session = &([_]u8{0x06} ** 32),
        .receiving_side = &([_]u8{0x07} ** 32),
        .handoff_count = 11,
        .signed_give = give,
        .signature = &([_]u8{0x08} ** 64),
    } } });
}

test "decode rejects a byte-shaped frame" {
    const allocator = std.testing.allocator;
    const view = pancake.foundation.FrameView{ .bytes = "not capnp", .shape = .byte };
    try std.testing.expectError(error.InvalidFrameShape, capnp.decodeOwned(allocator, view));
}

test "decode rejects a truncated frame" {
    const allocator = std.testing.allocator;
    // Header claims a 4-word segment, but no segment words follow.
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @as(u64, 4) << 32, .little);
    const view = pancake.foundation.FrameView{ .bytes = &bytes, .shape = .word };
    try std.testing.expectError(error.Truncated, capnp.decodeOwned(allocator, view));
}

test "decode rejects a multi-segment frame" {
    const allocator = std.testing.allocator;
    // segment-count − 1 = 1 (i.e. two segments) in the low u32.
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, 1, .little);
    const view = pancake.foundation.FrameView{ .bytes = &bytes, .shape = .word };
    try std.testing.expectError(error.UnsupportedSegmentCount, capnp.decodeOwned(allocator, view));
}
