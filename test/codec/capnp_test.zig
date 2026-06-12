const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const capnp = pancake.ocapn.codec.capnp;
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
        .target = .{ .far = .{ .import_position = 9 } },
        .args = &args,
        .answer = 5,
        .resolve_me_desc = null,
    } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const body = try capnp.decodeBody(frame.view());
    // Wire `far` (sender's import) flips to a `near` export on decode (ADR-0010).
    try std.testing.expectEqual(@as(u64, 9), body.deliver.target.near.export_position);
    try std.testing.expectEqual(@as(?u64, 5), body.deliver.answer);

    try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
    try std.testing.expectEqualSlices(u8, "ping", (try body.deliver.args.at(0)).bytes);

    const inner = (try body.deliver.args.at(1)).list;
    try std.testing.expectEqual(@as(usize, 2), try inner.len());
    try std.testing.expectEqualSlices(u8, "sym", (try inner.at(0)).symbol);
    try std.testing.expectEqual(@as(i64, 7), (try inner.at(1)).integer);
}

test "a Struct argument round-trips through the Cap'n Proto codec" {
    const allocator = std.testing.allocator;

    // Two heterogeneous entries built in non-canonical order; the codec carries a
    // struct as a composite list of (key text, value Argument) entry structs and
    // emits them in canonical key order (ADR-0046).
    const entries = [_]model.StructEntry{
        .{ .key = "name", .value = .{ .string = "tabby" } },
        .{ .key = "age", .value = .{ .integer = 12 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    const original = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = 7 } },
        .args = &args,
        .answer = 3,
        .resolve_me_desc = null,
    } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    // Owned round-trip: decode and compare with order-independent struct equality.
    const decoded = try capnp.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);
    try std.testing.expect(decoded.deliver.args[0] == .@"struct");
    try std.testing.expect(model.equality.argumentsEqual(args[0], decoded.deliver.args[0]));

    // Borrowed view: the lazy StructEntries backing walks (key, value) pairs.
    const body = try capnp.decodeBody(frame.view());
    const arg = try body.deliver.args.at(0);
    try std.testing.expect(arg == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), try arg.@"struct".len());
    // Canonical order: "age" sorts before "name".
    const first = try arg.@"struct".at(0);
    try std.testing.expectEqualStrings("age", first.key);
    try std.testing.expectEqual(@as(i64, 12), first.value.integer);
}

test "a Struct with duplicate keys is refused on the live view path" {
    const allocator = std.testing.allocator;

    // Encode a well-formed two-key struct, then patch the second key's bytes to
    // repeat the first — the duplicate-key frame a hostile peer would send,
    // word-shaped like every Cap'n Proto frame. Each key must be non-Equal to
    // every other within a Struct (ADR-0046 / Model.md § Struct), so the codec
    // refuses the frame at the parse boundary, on the same projection the
    // engine dispatches (`decodeBody`) — not only in an owned re-walk.
    const entries = [_]model.StructEntry{
        .{ .key = "k1", .value = .{ .integer = 1 } },
        .{ .key = "k2", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = 3,
        .resolve_me_desc = null,
    } });
    defer frame.deinit();

    const buf = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(buf);
    const second_key = std.mem.indexOf(u8, buf, "k2") orelse return error.TestUnexpectedResult;
    @memcpy(buf[second_key .. second_key + 2], "k1");
    const view = pancake.foundation.FrameView{ .bytes = buf, .shape = .word };

    // Framing stays lazy (the header delimits the frame), so the body projects;
    // the refusal fires the moment the struct argument itself is projected.
    const body = try capnp.decodeBody(view);
    try std.testing.expectError(error.MalformedView, body.deliver.args.at(0));
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, view));
}

test "a big integer argument round-trips through the Cap'n Proto codec" {
    const allocator = std.testing.allocator;

    // 2^128: sign on the discriminant word's bit 16, canonical decimal digits
    // as the data field (ADR-0049).
    const big = model.Argument{ .big_integer = .{
        .negative = true,
        .digits = "340282366920938463463374607431768211456",
    } };
    const args = [_]model.Argument{big};
    const original = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = 7 } },
        .args = &args,
        .answer = 3,
        .resolve_me_desc = null,
    } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const decoded = try capnp.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);
    try std.testing.expect(model.equality.argumentsEqual(big, decoded.deliver.args[0]));

    // Borrowed view: the digits borrow the frame's data bytes.
    const body = try capnp.decodeBody(frame.view());
    const arg = try body.deliver.args.at(0);
    try std.testing.expect(arg == .big_integer);
    try std.testing.expect(arg.big_integer.negative);
    try std.testing.expectEqualStrings("340282366920938463463374607431768211456", arg.big_integer.digits);

    // Symmetric refusal: a magnitude that belongs to the `integer` arm is
    // refused at encode, never rendered.
    const small = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = 7 } },
        .args = &.{.{ .big_integer = .{ .negative = false, .digits = "7" } }},
        .answer = 3,
        .resolve_me_desc = null,
    } };
    try std.testing.expectError(error.UnsupportedArgument, capnp.encodeMessage(allocator, small));
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

test "decodeMessageView projects the body over borrowed frame bytes; toOwned materializes" {
    const allocator = std.testing.allocator;

    const original = model.Message{ .gc_answer = .{ .positions = &.{ 7, 11, 13 } } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const view = try capnp.decodeMessageView(frame.view());
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
/// involution, so two encode-decode crossings restore the original
/// perspective — the bytes after the second crossing equal the first encoding
/// exactly when every field `decodeOwned` touches survived both crossings. Because the
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

test "Cap'n Proto refuses to encode a locator carrying hint entries instead of dropping them" {
    // The layout carries only the two empty hint spellings. Dropping entries
    // silently would put a different locator on the wire than the caller named,
    // so a hint-carrying locator must fail loud.
    const pubkey = [_]u8{0xaa} ** 32;
    const sig = [_]u8{0xcc} ** 64;
    const entries = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
    };

    try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(std.testing.allocator, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = pubkey[0..] },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "127.0.0.1:9001",
                .hints = .{ .entries = &entries },
            },
            .acceptable_location_sig = .{ .bytes = sig[0..] },
        },
    }));
}

test "gc-export round-trips parallel position/delta lists" {
    try expectRoundTrip(.{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } });
}

test "resolve round-trips fulfill and break" {
    try expectRoundTrip(.{ .resolve = .{ .answer = 42, .resolution = .{ .fulfill = .{ .integer = -7 } } } });
    try expectRoundTrip(.{ .resolve = .{ .answer = 9, .resolution = .{ .@"break" = .{ .message = "boom" } } } });
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
        .target = .{ .promise = .{ .answer_position = 1, .path = .{ .ops = &path_ops } } },
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
    try expectRoundTrip(.{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = 8 } });
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

// Every byte of an inbound frame is attacker-controlled. Union discriminants,
// pointer words, and list tags decode through bounded helpers, so a corrupted
// frame must resolve to a typed `Error` (or a well-formed message) and never
// trip illegal behavior (an out-of-range `@enumFromInt`, an unchecked slice).
// This walks representative frames — every union arm, a pipeline path, a handoff
// — flipping each byte to boundary values and asserting both decode paths stay
// total. A regression here (e.g. a raw `@enumFromInt` on a wire discriminant)
// surfaces as a panic that aborts the test binary.
test "corrupting any byte of a frame stays total: typed error or message, never a panic" {
    const allocator = std.testing.allocator;

    const call_args = [_]model.Argument{.{ .string = "ping" }};
    const path_ops = [_]model.PipelineOp{ .{ .field = "field" }, .{ .call = &call_args } };
    const give = model.HandoffGive{
        .recipient_key = &([_]u8{0x01} ** 32),
        .exporter_location = "tcp:host",
        .gifter_exporter_session = &([_]u8{0x02} ** 32),
        .gifter_side = &([_]u8{0x03} ** 32),
        .gift_id = &([_]u8{0x04} ** 32),
        .signature = &([_]u8{0x05} ** 64),
    };
    var handoff_arg = model.Handoff{ .give = give };
    // Cover every union arm and argument kind so each errdefer in the owned
    // decode path is actually unwound by some corruption: deliver (far + every
    // arg kind, including a nested reference/error/handoff/tagged), deliver
    // (promise with a pipeline path), deliver (sturdy target), resolve
    // (fulfill + break), gc-export (two parallel lists), abort, the get/index/
    // listen receiver-bearing ops, start-session, and both handoff arms.
    const messages = [_]model.Message{
        .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(4) },
            .args = &.{
                .{ .bytes = &.{ 1, 2, 3 } },
                .{ .symbol = "run" },
                .{ .string = "hello" },
                .{ .keyword = "kw" },
                .{ .integer = -99 },
                .{ .boolean = true },
                .{ .float64 = 1.5 },
                .{ .void = {} },
                .{ .reference = .{ .far = model.FarRef.promise(2) } },
                .{ .@"error" = .{ .message = "bad" } },
                .{ .list = &call_args },
                .{ .set = &call_args },
                .{ .tagged = .{ .tag = "point", .value = &call_args } },
                .{ .handoff = &handoff_arg },
            },
            .answer = 7,
            .resolve_me_desc = .{ .near = model.NearRef.promise(3) },
        } },
        .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = 1, .path = .{ .ops = &path_ops } } },
            .args = &.{},
        } },
        .{ .deliver = .{
            .target = .{ .sturdy = .{
                .peer = .{ .transport = "tcp", .designator = "host:9000" },
                .swissnum = &.{ 0xde, 0xad },
            } },
            .args = &.{},
        } },
        .{ .resolve = .{ .answer = 9, .resolution = .{ .@"break" = .{ .message = "boom" } } } },
        .{ .resolve = .{ .answer = 2, .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } } } },
        .{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } },
        .{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } },
        .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .near = model.NearRef.object(2) },
            .wants_partial = true,
        } },
        .{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = 8 } },
        .{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = -3, .answer = 9 } },
        .{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = 8 } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &([_]u8{0xab} ** 32) },
            .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
            .acceptable_location_sig = .{ .bytes = &([_]u8{0xcd} ** 64) },
        } },
        .{ .handoff = .{ .give = give } },
        .{ .handoff = .{ .receive = .{
            .receiving_session = &([_]u8{0x06} ** 32),
            .receiving_side = &([_]u8{0x07} ** 32),
            .handoff_count = 11,
            .signed_give = give,
            .signature = &([_]u8{0x08} ** 64),
        } } },
    };

    for (messages) |message| {
        var frame = try capnp.encodeMessage(allocator, message);
        defer frame.deinit();

        const original = try allocator.dupe(u8, frame.bytes());
        defer allocator.free(original);

        for (0..original.len) |i| {
            for ([_]u8{ 0xFF, 0x7F, 0x01 }) |corruption| {
                if (original[i] == corruption) continue;
                const buf = try allocator.dupe(u8, original);
                defer allocator.free(buf);
                buf[i] = corruption;
                const view = pancake.foundation.FrameView{ .bytes = buf, .shape = .word };

                if (capnp.decodeOwned(allocator, view)) |decoded| {
                    model.freeMessage(allocator, decoded);
                } else |_| {}

                if (capnp.decodeMessageView(view)) |v| {
                    if (v.toOwned(allocator)) |owned| {
                        model.freeMessage(allocator, owned);
                    } else |_| {}
                } else |_| {}
            }
        }
    }
}

test "Cap'n Proto encodes a Set in canonical order, not model order" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = model.FarRef.object(7) };

    // The same three-element set, built in two different model orders.
    const set_a = [_]model.Argument{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    const set_b = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const args_a = [_]model.Argument{.{ .set = set_a[0..] }};
    const args_b = [_]model.Argument{.{ .set = set_b[0..] }};

    var frame_a = try capnp.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args_a[0..] } });
    defer frame_a.deinit();
    var frame_b = try capnp.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args_b[0..] } });
    defer frame_b.deinit();

    // Canonical ordering means both encode to identical bytes regardless of the
    // order the model held the set in — each codec sorts a set by its own encoded
    // bytes, the Cap'n Proto partner of the same canonicalization Syrup applies.
    try std.testing.expectEqualSlices(u8, frame_a.bytes(), frame_b.bytes());

    // And it still round-trips back to the same multiset.
    const owned = try capnp.decodeOwned(allocator, frame_a.view());
    defer model.freeMessage(allocator, owned);
    try std.testing.expect(owned == .deliver);
    try std.testing.expectEqual(@as(usize, 1), owned.deliver.args.len);
    try std.testing.expect(owned.deliver.args[0] == .set);
    try std.testing.expectEqual(@as(usize, 3), owned.deliver.args[0].set.len);
}

test "decodeOwned bounds nesting depth: an over-deep frame fails loud, never overflows the stack" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build one argument nested in single-element lists `depth` deep — the shape a
    // hostile peer would craft to drive the decoder's recursion off the stack. The
    // encoder has no depth limit, so it produces exactly the over-deep frame the
    // decoder must reject. 260 sits just past the shared view materializer's bound
    // (`model.view.max_owned_depth`, 256), which is the one owned path now that
    // `decodeOwned` is `decodeBody` + `toOwned`.
    var arg: model.Argument = .{ .void = {} };
    var i: usize = 0;
    while (i < 260) : (i += 1) {
        const slice = try arena.alloc(model.Argument, 1);
        slice[0] = arg;
        arg = .{ .list = slice };
    }
    const args = [_]model.Argument{arg};
    const message = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &args,
    } };

    const frame = try capnp.encodeMessageForProfile(arena, .pre_spec, message);
    // The bound fires with a typed error; the testing allocator also proves the
    // rejection path freed every partial allocation (no leak on the error path).
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, frame.view()));
}
