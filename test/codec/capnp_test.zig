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

test "Cap'n Proto rejects invalid UTF-8 String and Symbol values without allocating" {
    const invalid = &.{@as(u8, 0xff)};
    const invalid_arguments = [_]model.Argument{
        .{ .string = invalid },
        .{ .symbol = invalid },
    };

    for (invalid_arguments) |argument| {
        const args = [_]model.Argument{argument};
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const before = failing.alloc_index;
        try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(failing.allocator(), .{
            .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &args,
            },
        }));
        try std.testing.expectEqual(before, failing.alloc_index);
    }

    const valid_args = [_]model.Argument{
        .{ .string = "\xc3\xa9" },
        .{ .symbol = "\xf0\x9f\x98\x80" },
        .{ .bytes = invalid },
    };
    var frame = try capnp.encodeMessage(std.testing.allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &valid_args,
    } });
    defer frame.deinit();

    const valid_body = try capnp.decodeBody(frame.view());
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", (try valid_body.deliver.args.at(0)).string);
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", (try valid_body.deliver.args.at(1)).symbol);
    try std.testing.expectEqualSlices(u8, invalid, (try valid_body.deliver.args.at(2)).bytes);

    for ([_][]const u8{ "\xc3\xa9", "\xf0\x9f\x98\x80" }) |needle| {
        const bytes = try std.testing.allocator.dupe(u8, frame.bytes());
        defer std.testing.allocator.free(bytes);
        const offset = std.mem.indexOf(u8, bytes, needle) orelse return error.TestUnexpectedResult;
        bytes[offset] = 0xff;
        const view = pancake.foundation.FrameView{ .bytes = bytes, .shape = .word };
        try std.testing.expectError(capnp.Error.MalformedFrame, capnp.decodeBody(view));
        try std.testing.expectError(capnp.Error.MalformedFrame, capnp.decodeOwned(std.testing.allocator, view));
    }
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
        .answer = .from(3),
        .resolve_me_desc = null,
    } });
    defer frame.deinit();

    const buf = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(buf);
    const second_key = std.mem.indexOf(u8, buf, "k2") orelse return error.TestUnexpectedResult;
    @memcpy(buf[second_key .. second_key + 2], "k1");
    const view = pancake.foundation.FrameView{ .bytes = buf, .shape = .word };

    // `decodeBody` runs the eager traversal-budget charge pass (the remote-DoS
    // bound), which walks every argument once to spend the per-frame budget —
    // and that walk reads each struct through the same `neutralStructBacking`
    // the lazy path uses, so the ascending-key rule is enforced at the parse
    // boundary. A duplicate key is thus refused the instant the frame decodes,
    // before any borrowed view escapes, not only on a later owned re-walk.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(view));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, view));
}

test "the Cap'n Proto encoder refuses a Set carrying a duplicate element" {
    // Symmetric with the Syrup codec and the duplicate-key struct: a set's
    // elements are unique, so a model with two equal elements is refused at
    // encode with UnsupportedArgument rather than emitted.
    const allocator = std.testing.allocator;
    const dup = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 1 } };
    const args = [_]model.Argument{.{ .set = dup[0..] }};
    try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } }));
}

test "the Cap'n Proto encoder refuses a Struct carrying a duplicate key" {
    // Symmetric refusal (ADR-0003): the decoder rejects a duplicate-key struct,
    // so the encoder must not emit one. A model built with two "a" entries is
    // refused at encode with UnsupportedArgument rather than shipped as a frame
    // the partner would reject remotely.
    const allocator = std.testing.allocator;
    const entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "a", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    try std.testing.expectError(capnp.Error.UnsupportedArgument, capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } }));
}

test "a Struct with descending keys is refused: decode requires the encoder's ascending order" {
    const allocator = std.testing.allocator;

    // pancake's capnp encoder emits struct keys sorted ascending by raw bytes
    // (`canonicalStructOrder`), so decode requires strictly ascending keys —
    // one comparison per key, not an all-pairs scan an attacker could drive to
    // n². A distinct-but-descending pair is non-canonical and refused, exactly
    // as a duplicate is (equal is also not strictly ascending). Here the
    // encoder produces [k1, k2]; patching k1 -> k3 leaves [k3, k2], descending.
    const entries = [_]model.StructEntry{
        .{ .key = "k1", .value = .{ .integer = 1 } },
        .{ .key = "k2", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var frame = try capnp.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &args,
        .answer = .from(3),
        .resolve_me_desc = null,
    } });
    defer frame.deinit();

    const buf = try allocator.dupe(u8, frame.bytes());
    defer allocator.free(buf);
    const first_key = std.mem.indexOf(u8, buf, "k1") orelse return error.TestUnexpectedResult;
    @memcpy(buf[first_key .. first_key + 2], "k3");
    const view = pancake.foundation.FrameView{ .bytes = buf, .shape = .word };

    // As with the duplicate-key case, the eager charge pass in `decodeBody`
    // enforces the strictly-ascending-key rule at the parse boundary, so a
    // descending pair is refused the moment the frame decodes.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(view));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, view));
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

test "Cap'n Proto encodes op:start-session locator hint entries" {
    // `op:start-session`'s `acceptable_location` carries hint entries on the
    // wire (mirrors Syrup's `writePeerLocatorRecord`, the encoder Syrup's own
    // `op:start-session` path calls) instead of refusing them the way a
    // sturdyref locator still does below.
    const allocator = std.testing.allocator;
    const pubkey = [_]u8{0xaa} ** 32;
    const sig = [_]u8{0xcc} ** 64;
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

test "deliver round-trips args, answer, and a promise target with pipeline path" {
    const call_args = [_]model.Argument{.{ .string = "ping" }};
    const path_ops = [_]model.PipelineOp{ .{ .field = "field" }, .{ .call = &call_args } };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(1), .path = .{ .ops = &path_ops } } },
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

test "profile-less Cap'n Proto framing accepts next listen modes without projecting semantics" {
    // FrameStream has no CaptpVersion. It must accept modes 2/3 structurally
    // and return only their boundary; semantic decode stays V1 by default and
    // profile-aware when a session applies the frame.
    const allocator = std.testing.allocator;
    for ([_]model.ListenMode{ .settling_only, .shortening_or_settling }) |mode| {
        var frame = try capnp.encodeMessageForProfile(allocator, .next, .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .near = model.NearRef.object(2) },
            .mode = mode,
        } });
        defer frame.deinit();

        const boundary = capnp.framePrefix(frame.bytes(), frame.bytes().len);
        try std.testing.expect(boundary == .complete);
        try std.testing.expectEqual(frame.bytes().len, boundary.complete);

        try std.testing.expect(capnp.decodePrefix(frame.bytes(), frame.bytes().len) == .malformed);
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
    const boundary = capnp.framePrefix(v1.bytes(), v1.bytes().len);
    try std.testing.expect(boundary == .complete);
    try std.testing.expectEqual(v1.bytes().len, boundary.complete);

    const v1_body = try capnp.decodeBodyForProfile(.v1_0, v1.view());
    try std.testing.expectEqual(model.ListenMode.shortening_or_settling, v1_body.listen.mode);
    const next_body = try capnp.decodeBodyForProfile(.next, next.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, next_body.listen.mode);
}

test "start-session round-trips the four-operand handshake" {
    try expectRoundTrip(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &([_]u8{0xab} ** 32) },
        .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
        .acceptable_location_sig = .{ .bytes = &([_]u8{0xcd} ** 64) },
    } });
}

test "nested handoff give and receive round-trip" {
    const give = model.HandoffGive{
        .recipient_key = &([_]u8{0x01} ** 32),
        .exporter = .{ .transport = "tcp", .designator = "host" },
        .gifter_exporter_session = &([_]u8{0x02} ** 32),
        .gifter_side = &([_]u8{0x03} ** 32),
        .gift_id = &([_]u8{0x04} ** 32),
        .signature = &([_]u8{0x05} ** 64),
    };
    var give_handoff = model.Handoff{ .give = give };
    var receive_handoff = model.Handoff{ .receive = .{
        .receiving_session = &([_]u8{0x06} ** 32),
        .receiving_side = &([_]u8{0x07} ** 32),
        .handoff_count = 11,
        .signed_give = give,
        .signature = &([_]u8{0x08} ** 64),
    } };
    const args = [_]model.Argument{ .{ .handoff = &give_handoff }, .{ .handoff = &receive_handoff } };
    try expectRoundTrip(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &args,
    } });
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
        .exporter = .{ .transport = "tcp", .designator = "host" },
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
            .answer = .from(7),
            .resolve_me_desc = .{ .near = model.NearRef.promise(3) },
        } },
        .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(1), .path = .{ .ops = &path_ops } } },
            .args = &.{},
        } },
        .{ .deliver = .{
            .target = .{ .sturdy = &.{
                .peer = .{ .transport = "tcp", .designator = "host:9000" },
                .swissnum = &.{ 0xde, 0xad },
            } },
            .args = &.{},
        } },
        .{ .resolve = .{ .answer = .from(9), .resolution = .{ .@"break" = .{ .message = "boom" } } } },
        .{ .resolve = .{ .answer = .from(2), .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } } } },
        .{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } },
        .{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } },
        .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .near = model.NearRef.object(2) },
            .mode = .shortening_or_settling,
        } },
        .{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } },
        .{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = .{ .integer = -3 }, .answer = .from(9) } },
        .{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &([_]u8{0xab} ** 32) },
            .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
            .acceptable_location_sig = .{ .bytes = &([_]u8{0xcd} ** 64) },
        } },
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
    // words, 1 pointer word) whose lone pointer word is null — a scalar arm names
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

test "decodeOwned bounds nesting depth: an over-deep frame fails loud, never overflows the stack" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build one argument nested in single-element lists `depth` deep, the shape a
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

    const frame = try capnp.encodeMessageForProfile(arena, .next, message);
    // The bound fires with a typed error; the testing allocator also proves the
    // rejection path freed every partial allocation (no leak on the error path).
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, frame.view()));
}

test "an aliasing composite DAG exhausts the traversal budget instead of amplifying" {
    const allocator = std.testing.allocator;

    // Hand-build the amplification shape the encoder can never emit: a chain of
    // D composite lists where BOTH elements of level i point at the ONE shared
    // level i+1 list. The frame holds only D+1 lists (~1.3 KB), but a naive
    // walk visits 2^i nodes at level i — 2^31 total for D=30 — because Cap'n
    // Proto pointers may alias. The single-byte-flip corruption tests mutate
    // valid tree frames and can never synthesize these converging offsets, so
    // this construction is the only pressure on the traversal budget
    // (`shared.traversalBudget`, seeded from the segment word count), which
    // must refuse the frame in bounded time with the malformed-frame error.
    const levels_deep: usize = 30;
    const list_arg: u64 = @intFromEnum(capnp.shared.ArgKind.list);
    const void_arg: u64 = @intFromEnum(capnp.shared.ArgKind.void);
    // Each level: composite tag + 2 elements of stride 2 (1 data word for the
    // ArgKind discriminant, 1 pointer word to the next level).
    const list_body_words: u29 = 4;

    var b = wire.Builder{};
    defer b.deinit(allocator);

    // Pre-allocate every word so forward pointers (root -> envelope -> deliver
    // body, level i -> level i+1) target known indices.
    const root = try b.allocWords(allocator, 1);
    const env = try b.allocWords(allocator, 2); // Kind data word + body pointer
    const body = try b.allocWords(allocator, 3); // flags + target ptr + args ptr
    const target = try b.allocWords(allocator, 2); // RefTag + scalar
    var levels: [levels_deep + 1]usize = undefined;
    for (0..levels_deep + 1) |i| {
        levels[i] = try b.allocWords(allocator, 1 + list_body_words);
    }

    b.set(root, wire.encodeStructPointer(wire.Builder.offsetTo(root, env), 1, 1));
    b.set(env, @intFromEnum(capnp.shared.Kind.deliver));
    b.set(env + 1, wire.encodeStructPointer(wire.Builder.offsetTo(env + 1, body), 1, 2));
    b.set(body, 0); // flags: no answer, no resolve-me
    b.set(body + 1, wire.encodeStructPointer(wire.Builder.offsetTo(body + 1, target), 2, 0));
    b.set(body + 2, wire.encodeListPointer(wire.Builder.offsetTo(body + 2, levels[0]), .composite, list_body_words));
    b.set(target, @intFromEnum(capnp.shared.RefTag.far));
    b.set(target + 1, 0);

    for (0..levels_deep + 1) |i| {
        const tag = levels[i];
        b.set(tag, wire.Builder.compositeTag(2, 1, 1));
        const leaf = i == levels_deep;
        const disc: u64 = if (leaf) void_arg else list_arg;
        b.set(tag + 1, disc); // element 0 data
        b.set(tag + 3, disc); // element 1 data
        if (!leaf) {
            const child = levels[i + 1];
            // Both element pointers converge on the same child list: the DAG edge.
            b.set(tag + 2, wire.encodeListPointer(wire.Builder.offsetTo(tag + 2, child), .composite, list_body_words));
            b.set(tag + 4, wire.encodeListPointer(wire.Builder.offsetTo(tag + 4, child), .composite, list_body_words));
        }
    }

    var frame = try b.finish(allocator);
    defer frame.deinit();

    // The test completing at all is the time bound: without the budget this
    // walk performs ~2^31 element resolutions.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(frame.view()));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, frame.view()));
}

test "an aliasing hint list is charged against the traversal budget" {
    const allocator = std.testing.allocator;

    // The hint list is the one composite list the charge pass never enumerated.
    // `neutralPeerLocator` reads the list header and packs a *lazy* view, so a
    // list of N entries cost O(1) to charge, and `capnpMaterializeHintList`
    // then built its own unmetered reader and duped a name and a value per
    // entry. Every entry here aliases one blob, which Cap'n Proto pointers
    // permit and every individual read bounds-checks cleanly, so nothing but a
    // budget can refuse it.
    //
    // Every other field is deliberately valid and small, so the frame reaches
    // hint materialization rather than being turned away for an unrelated
    // reason, and so the hints are the only pressure on the budget.
    //
    // It rides an `op:start-session`, which is the worst placement: the
    // handshake materializes the locator hints to rebuild the signing domain,
    // so this runs before the partner signature is verified.
    const entry_count: usize = 1024;
    const blob_words: usize = 512; // 4 KiB, aliased by every entry, twice
    const data_words: u16 = 2;
    const ptr_words: u16 = 2;
    const stride: usize = data_words + ptr_words;

    var b = wire.Builder{};
    defer b.deinit(allocator);

    const root = try b.allocWords(allocator, 1);
    const env = try b.allocWords(allocator, 2);
    const body = try b.allocWords(allocator, 4); // start-session: 0 data, 4 ptrs
    const loc = try b.allocWords(allocator, 4); // locator: 1 data, 3 ptrs
    const ver = try b.allocWords(allocator, 1);
    const small = try b.allocWords(allocator, 4);
    const blob = try b.allocWords(allocator, blob_words);
    const tag = try b.allocWords(allocator, 1);
    const block = try b.allocWords(allocator, entry_count * stride);

    b.setBytes(ver, "1.0");
    b.setBytes(small, "aaaaaaaa");

    b.set(root, wire.encodeStructPointer(wire.Builder.offsetTo(root, env), 1, 1));
    b.set(env, @intFromEnum(capnp.shared.Kind.start_session));
    b.set(env + 1, wire.encodeStructPointer(wire.Builder.offsetTo(env + 1, body), 0, 4));

    b.set(body, wire.encodeListPointer(wire.Builder.offsetTo(body, ver), .byte, 3));
    b.set(body + 1, wire.encodeListPointer(wire.Builder.offsetTo(body + 1, small), .byte, 8));
    b.set(body + 2, wire.encodeStructPointer(wire.Builder.offsetTo(body + 2, loc), 1, 3));
    b.set(body + 3, wire.encodeListPointer(wire.Builder.offsetTo(body + 3, small), .byte, 8));

    b.set(loc, 0); // hints present, map form
    b.set(loc + 1, wire.encodeListPointer(wire.Builder.offsetTo(loc + 1, small), .byte, 8));
    b.set(loc + 2, wire.encodeListPointer(wire.Builder.offsetTo(loc + 2, small), .byte, 8));
    b.set(loc + 3, wire.encodeListPointer(wire.Builder.offsetTo(loc + 3, tag), .composite, @intCast(entry_count * stride)));

    b.set(tag, wire.Builder.compositeTag(@intCast(entry_count), data_words, ptr_words));
    for (0..entry_count) |i| {
        const e = block + i * stride;
        b.set(e, @intFromEnum(capnp.shared.HintValueKind.string));
        b.set(e + 1, 0);
        // Name and value both point at the one shared blob: the aliasing edge.
        b.set(e + 2, wire.encodeListPointer(wire.Builder.offsetTo(e + 2, blob), .byte, @intCast(blob_words * 8)));
        b.set(e + 3, wire.encodeListPointer(wire.Builder.offsetTo(e + 3, blob), .byte, @intCast(blob_words * 8)));
    }

    var frame = try b.finish(allocator);
    defer frame.deinit();

    // Materializing this unbudgeted dupes entry_count * 2 * 4 KiB from a frame
    // a fraction of that size. The budget refuses it instead.
    try std.testing.expectError(error.MalformedFrame, capnp.decodeBody(frame.view()));
    try std.testing.expectError(error.MalformedFrame, capnp.decodeOwned(allocator, frame.view()));
}

test "a decoded frame must be exactly the length its header declares" {
    const allocator = std.testing.allocator;
    var frame = try capnp.encodeMessage(allocator, .{ .gc_answer = .{ .positions = &.{7} } });
    defer frame.deinit();

    // The frame itself decodes.
    _ = try capnp.decodeBody(frame.view());

    // The same bytes with anything appended do not. Syrup refuses trailing
    // bytes too; without the rule these two byte strings name one message, and
    // anything treating a frame's bytes as its identity sees two of it.
    const padded = try allocator.alloc(u8, frame.bytes().len + 8);
    defer allocator.free(padded);
    @memcpy(padded[0..frame.bytes().len], frame.bytes());
    @memset(padded[frame.bytes().len..], 0);
    const aligned = try allocator.alignedAlloc(u8, .@"8", padded.len);
    defer allocator.free(aligned);
    @memcpy(aligned, padded);
    try std.testing.expectError(
        error.MalformedFrame,
        capnp.decodeBody(.{ .bytes = aligned, .shape = .word }),
    );
}

test "a locator carrying the same hint name twice is refused" {
    // Hints are a dictionary, so a repeated name is malformed. It matters more
    // than tidiness: the encoder emits hint entries in model order with no
    // uniqueness pass, so a duplicate admitted here would be re-emitted, as
    // part of a handoff give's exporter location, into a dictionary pancake's
    // own decoder rejects.
    const allocator = std.testing.allocator;
    const entries = [_]model.HintEntry{
        .{ .name = "direct-addresses", .value = .{ .string = "10.0.0.1:9000" } },
        .{ .name = "direct-addresses", .value = .{ .string = "10.0.0.2:9000" } },
    };
    var frame = try capnp.encodeMessage(allocator, .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = &([_]u8{0x11} ** 32) },
        .acceptable_location = .{
            .transport = "tcp",
            .designator = "127.0.0.1:9000",
            .hints = .{ .entries = entries[0..] },
        },
        .acceptable_location_sig = .{ .bytes = &([_]u8{0x22} ** 64) },
    } });
    defer frame.deinit();

    // Borrowed decode leaves the list lazy, so the refusal lands where the
    // entries are actually materialized.
    try std.testing.expectError(error.MalformedView, capnp.decodeOwned(allocator, frame.view()));
}
