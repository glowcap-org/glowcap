const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;
const wire = capnp.wire;
const messagesEqual = @import("../support/message_equality.zig").messagesEqual;

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
    try std.testing.expectEqual(glowcap.foundation.FrameShape.word, frame.view().shape);
    try std.testing.expectEqual(@as(usize, 0), frame.bytes().len % wire.WORD_BYTES);

    const decoded = try capnp.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);

    try std.testing.expectEqualSlices(u64, original.gc_answer.positions, decoded.gc_answer.positions);
}

test "Cap'n Proto refuses an unlowered Node capability route" {
    try std.testing.expectError(capnp.Error.UnsupportedReference, capnp.encodeMessage(std.testing.allocator, .{
        .deliver = .{
            .target = .{ .routed = .{ .id = .from(7) } },
            .args = &.{},
        },
    }));
}

test "decodeBody projects the neutral view with lazy capnp backings (nested args, positions)" {
    const allocator = std.testing.allocator;

    // A deliver whose args exercise the lazy Args backing and a nested list
    // (itself another backing): [ "ping"(bytes), [ 'sym, 7 ] ].
    const nested = [_]model.Argument{ .{ .symbol = "sym" }, .{ .integer = 7 } };
    const args = [_]model.Argument{ .{ .bytes = "ping" }, .{ .list = &nested } };
    const original = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(9) } },
        .args = &args,
        .answer = .from(5),
        .resolve_me_desc = null,
    } };

    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    const body = try capnp.decodeBody(frame.view());
    // Wire `far` (sender's import) flips to a `near` export on decode (ADR-0010).
    try std.testing.expectEqual(@as(u64, 9), body.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(5)), body.deliver.answer);

    try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
    try std.testing.expectEqualSlices(u8, "ping", (try body.deliver.args.at(0)).bytes);

    const inner = (try body.deliver.args.at(1)).list;
    try std.testing.expectEqual(@as(usize, 2), try inner.len());
    try std.testing.expectEqualSlices(u8, "sym", (try inner.at(0)).symbol);
    try std.testing.expectEqual(@as(i64, 7), (try inner.at(1)).integer);
}

test "decodeBodyInto parses a deliver's argument tree once into lent views, nested lists included" {
    const allocator = std.testing.allocator;
    const nested = [_]model.Argument{ .{ .symbol = "sym" }, .{ .integer = 7 }, .{ .integer = 8 } };
    const args = [_]model.Argument{ .{ .bytes = "ping" }, .{ .list = &nested }, .{ .boolean = true } };
    const original = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(9) } },
        .args = &args,
        .answer = .from(5),
        .resolve_me_desc = null,
    } };
    var frame = try capnp.encodeMessage(allocator, original);
    defer frame.deinit();

    // Room for the whole tree: the outer list claims three, the inner three.
    var views: [8]model.view.Argument = undefined;
    var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(&views));
    const body = try capnp.decodeBodyInto(.v1_0, frame.view(), &slab);
    try std.testing.expectEqual(@as(usize, 6) * @sizeOf(model.view.Argument), slab.used);
    try std.testing.expect(body.deliver.args.backingViews() != null);
    const inner = (try body.deliver.args.at(1)).list;
    try std.testing.expect(inner.backingViews() != null);
    try std.testing.expectEqualSlices(u8, "sym", (try inner.at(0)).symbol);
    try std.testing.expectEqual(@as(i64, 8), (try inner.at(2)).integer);
    try std.testing.expect((try body.deliver.args.at(2)).boolean);

    // Room for the outer list alone: the inner list stays segment-backed and
    // reads the same.
    var few: [4]model.view.Argument = undefined;
    var short = model.view.ValueSlab.init(std.mem.sliceAsBytes(&few));
    const partial = try capnp.decodeBodyInto(.v1_0, frame.view(), &short);
    try std.testing.expectEqual(@as(usize, 3) * @sizeOf(model.view.Argument), short.used);
    try std.testing.expect(partial.deliver.args.backingViews() != null);
    const backed = (try partial.deliver.args.at(1)).list;
    try std.testing.expect(backed.backingViews() == null);
    try std.testing.expectEqual(@as(i64, 7), (try backed.at(1)).integer);

    // The views and the segment backing materialize the same message.
    const owned = try body.toOwned(allocator);
    defer model.freeMessage(allocator, owned);
    const again = try partial.toOwned(allocator);
    defer model.freeMessage(allocator, again);
    try std.testing.expect(messagesEqual(owned, again));
    try std.testing.expectEqual(@as(usize, 3), owned.deliver.args.len);
    try std.testing.expectEqualSlices(u8, "ping", owned.deliver.args[0].bytes);
    try std.testing.expectEqual(@as(i64, 8), owned.deliver.args[1].list[2].integer);
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
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &args,
        .answer = .from(3),
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
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &args,
        .answer = .from(3),
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
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .big_integer = .{ .negative = false, .digits = "7" } }},
        .answer = .from(3),
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
/// perspective, the bytes after the second crossing equal the first encoding
/// exactly when every field `decodeOwned` touches survived both crossings. Because the
/// encoder renders every model field, that byte-equality proves faithful
/// reconstruction.
fn expectRoundTrip(message: model.Message) !void {
    const allocator = std.testing.allocator;
    var frame0 = try capnp.encodeMessage(allocator, message);
    defer frame0.deinit();
    try std.testing.expectEqual(glowcap.foundation.FrameShape.word, frame0.view().shape);
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

test "Cap'n Proto encodes op:start-session locator hint entries" {
    // `op:start-session`'s `acceptable_location` carries hint entries on the
    // wire (mirrors Syrup's `writePeerLocatorRecord`, the encoder Syrup's own
    // `op:start-session` path calls) instead of refusing them the way a
    // sturdyref locator still does below.
    const allocator = std.testing.allocator;
    const pubkey = @as([32]u8, @splat(0xaa));
    const sig = @as([64]u8, @splat(0xcc));
    const entries = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
    };

    var frame = try capnp.encodeMessage(allocator, .{
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
    });
    defer frame.deinit();

    // Decode materializes the same hint entries encode wrote (Cap'n Proto
    // has no Syrup-style `acceptable_location_raw` capture; the composite
    // list is the recoverable form).
    const decoded = try capnp.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);
    try std.testing.expectEqualStrings("tcp", decoded.start_session.acceptable_location.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9001", decoded.start_session.acceptable_location.designator);
    try std.testing.expectEqual(@as(usize, 1), decoded.start_session.acceptable_location.hints.entries.len);
    try std.testing.expectEqualStrings("host", decoded.start_session.acceptable_location.hints.entries[0].name);
    try std.testing.expectEqualStrings("127.0.0.1", decoded.start_session.acceptable_location.hints.entries[0].value.string);
}

test "Cap'n Proto round-trips a sturdyref locator carrying hint entries" {
    const entries = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
    };

    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .sturdy = &.{
            .peer = .{
                .transport = "tcp",
                .designator = "127.0.0.1:9001",
                .hints = .{ .entries = &entries },
            },
            .swissnum = &.{0xde},
        } },
        .args = &.{},
    } });
}

test "gc-export round-trips parallel position/delta lists" {
    try expectRoundTrip(.{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } });
}

test "resolve round-trips fulfill and break" {
    try expectRoundTrip(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{ .integer = -7 } } } });
    try expectRoundTrip(.{ .resolve = .{ .answer = .from(9), .resolution = .{ .@"break" = .{ .message = "boom" } } } });
}

test "reference arms round-trip through deliver target" {
    try expectRoundTrip(.{ .deliver = .{ .target = .{ .near = model.NearRef.promise(3) }, .args = &.{} } });
    try expectRoundTrip(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(4) }, .args = &.{} } });
    try expectRoundTrip(.{ .deliver = .{ .target = .{ .sturdy = &.{
        .peer = .{ .transport = "tcp", .designator = "host:9000" },
        .swissnum = &.{ 0xde, 0xad },
    } }, .args = &.{} } });
}

test "deliver round-trips args, answer, and a promise target" {
    const call_args = [_]model.Argument{.{ .string = "ping" }};
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(1) } },
        .args = &.{
            .{ .bytes = &.{ 1, 2, 3 } },
            .{ .symbol = "run" },
            .{ .boolean = true },
            .{ .integer = -99 },
            .{ .void = {} },
            .{ .list = &call_args },
            .{ .tagged = .{ .tag = "point", .value = &call_args } },
        },
        .answer = .from(7),
    } });
}

test "listen, get, and index round-trip" {
    try expectRoundTrip(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(1) },
        .listener = .{ .near = model.NearRef.object(2) },
        .mode = .shortening_or_settling,
    } });
    try expectRoundTrip(.{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } });
    try expectRoundTrip(.{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = .{ .integer = -3 }, .answer = .from(9) } });
    try expectRoundTrip(.{ .index = .{
        .receiver = .{ .far = model.FarRef.object(6) },
        .index = .{ .big_integer = .{ .negative = false, .digits = "9223372036854775808" } },
        .answer = .from(10),
    } });
    try expectRoundTrip(.{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } });
}

test "a next listen mode is refused under v1.0 and projected under next" {
    // Semantic decode stays v1.0 by default and profile-aware when a session
    // applies the frame.
    const allocator = std.testing.allocator;
    for ([_]model.ListenMode{ .settling_only, .shortening_or_settling }) |mode| {
        var frame = try capnp.encodeMessageForProfile(allocator, .next, .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .near = model.NearRef.object(2) },
            .mode = mode,
        } });
        defer frame.deinit();

        try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(frame.view()));
        const next_body = try capnp.decodeBodyForProfile(.next, frame.view());
        try std.testing.expectEqual(mode, next_body.listen.mode);
    }
}

test "Cap'n Proto framing does not choose between the two meanings of listen mode one" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = model.FarRef.promise(1) };
    const listener = model.Reference{ .near = model.NearRef.object(2) };
    var v1 = try capnp.encodeMessageForProfile(allocator, .v1_0, .{ .listen = .{
        .target = target,
        .listener = listener,
        .mode = .shortening_or_settling,
    } });
    defer v1.deinit();
    var next = try capnp.encodeMessageForProfile(allocator, .next, .{ .listen = .{
        .target = target,
        .listener = listener,
        .mode = .shortening_only,
    } });
    defer next.deinit();

    try std.testing.expectEqualSlices(u8, v1.bytes(), next.bytes());

    const v1_body = try capnp.decodeBodyForProfile(.v1_0, v1.view());
    try std.testing.expectEqual(model.ListenMode.shortening_or_settling, v1_body.listen.mode);
    const next_body = try capnp.decodeBodyForProfile(.next, next.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, next_body.listen.mode);
}

test "start-session round-trips the four-operand handshake" {
    try expectRoundTrip(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0xab))) },
        .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
        .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0xcd))) },
    } });
}

test "nested handoff give and receive round-trip" {
    const give = model.HandoffGive{
        .recipient_key = &(@as([32]u8, @splat(0x01))),
        .exporter = .{ .transport = "tcp", .designator = "host" },
        .gifter_exporter_session = &(@as([32]u8, @splat(0x02))),
        .gifter_side = &(@as([32]u8, @splat(0x03))),
        .gift_id = &(@as([32]u8, @splat(0x04))),
        .signature = &(@as([64]u8, @splat(0x05))),
    };
    var give_handoff = model.Handoff{ .give = give };
    var receive_handoff = model.Handoff{ .receive = .{
        .receiving_session = &(@as([32]u8, @splat(0x06))),
        .receiving_side = &(@as([32]u8, @splat(0x07))),
        .handoff_count = 11,
        .signed_give = give,
        .signature = &(@as([64]u8, @splat(0x08))),
    } };
    const args = [_]model.Argument{ .{ .handoff = &give_handoff }, .{ .handoff = &receive_handoff } };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &args,
    } });
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
    // order the model held the set in, each codec sorts a set by its own encoded
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

test "Cap'n Proto set of scalars keeps each element's pointer word null (canonical bytes)" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = model.FarRef.object(7) };

    // A set of scalar integers: every element is an `Argument` struct (2 data
    // words, 1 pointer word) whose lone pointer word is null, a scalar arm names
    // no sub-object. The set-graft encode path copies each standalone-encoded
    // element into the composite-list slot and relocates its pointer words; a null
    // pointer must stay null. Grafting it as a struct pointer offset by the graft
    // delta would ship a spurious non-null pointer, non-canonical bytes the
    // model round-trip cannot see because the decoder never reads a scalar's
    // pointer word.
    const set = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const args = [_]model.Argument{.{ .set = set[0..] }};
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args[0..] } });
    defer frame.deinit();

    const data_words: u16 = 2;
    const ptr_words: u16 = 1;
    const stride: usize = data_words + ptr_words;
    const tag = wire.Builder.compositeTag(@intCast(set.len), data_words, ptr_words);

    // Scan the frame's little-endian words for the set's composite-list tag, then
    // assert each element's pointer word (data_words past the element start) is 0.
    const bytes = frame.bytes();
    const word_count = bytes.len / 8;
    var tag_idx: ?usize = null;
    for (0..word_count) |w| {
        if (std.mem.readInt(u64, bytes[w * 8 ..][0..8], .little) == tag) {
            tag_idx = w;
            break;
        }
    }
    try std.testing.expect(tag_idx != null);
    for (0..set.len) |i| {
        const ptr_idx = tag_idx.? + 1 + i * stride + data_words;
        const ptr_word = std.mem.readInt(u64, bytes[ptr_idx * 8 ..][0..8], .little);
        try std.testing.expectEqual(@as(u64, 0), ptr_word);
    }
}
