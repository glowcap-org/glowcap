//! What Syrup decode admits and refuses: invalid UTF-8, duplicate keys,
//! malformed and non-canonical bytes, oversized collections, start-session
//! fields, and single-byte corruption anywhere in a frame failing loudly.
//! Locator hints have their own file, `decode_hints_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");
const handoff_fixtures = @import("../../support/handoff_fixtures.zig");

const harness = @import("harness.zig");
const repeatedByte = harness.repeatedByte;

test "Syrup rejects invalid UTF-8 String and Symbol values without allocating" {
    const invalid = &.{@as(u8, 0xff)};
    const arguments = [_]model.Argument{
        .{ .string = invalid },
        .{ .symbol = invalid },
    };

    for (arguments) |argument| {
        const args = [_]model.Argument{argument};
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const before = failing.alloc_index;
        try std.testing.expectError(syrup.Error.UnsupportedArgument, syrup.encodeMessage(failing.allocator(), .{
            .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &args,
            },
        }));
        try std.testing.expectEqual(before, failing.alloc_index);
    }

    const malformed_frames = [_][]const u8{
        "<10'op:deliver<11'desc:export7+>[1\"\xff]ff>",
        "<10'op:deliver<11'desc:export7+>[1'\xff]ff>",
    };
    for (malformed_frames) |bytes| {
        const view = glowcap.foundation.FrameView{ .bytes = bytes, .shape = .byte };
        try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeBody(view));
        try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeOwned(std.testing.allocator, view));
    }

    const binary_frame = "<10'op:deliver<11'desc:export7+>[1:\xff]ff>";
    const binary_body = try syrup.decodeBody(.{ .bytes = binary_frame, .shape = .byte });
    try std.testing.expectEqualSlices(u8, invalid, (try binary_body.deliver.args.at(0)).bytes);

    const unicode_frame = "<10'op:deliver<11'desc:export7+>[2\"\xc3\xa94'\xf0\x9f\x98\x80]ff>";
    const unicode_body = try syrup.decodeBody(.{ .bytes = unicode_frame, .shape = .byte });
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", (try unicode_body.deliver.args.at(0)).string);
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", (try unicode_body.deliver.args.at(1)).symbol);
}

test "text validity holds at every length and every position of a non-ASCII byte" {
    // The validator reads a word at a time and then a short tail without a
    // loop, so a byte with its top bit set must be seen wherever it lands:
    // a stray continuation byte refuses the text, and a two-byte character
    // is accepted, at every position of every short length.
    var buf: [24]u8 = undefined;
    var len: usize = 0;
    while (len <= buf.len) : (len += 1) {
        @memset(buf[0..len], 'a');
        try std.testing.expect(syrup.shared.textValid(buf[0..len]));
        var pos: usize = 0;
        while (pos < len) : (pos += 1) {
            @memset(buf[0..len], 'a');
            buf[pos] = 0xff;
            try std.testing.expect(!syrup.shared.textValid(buf[0..len]));
            if (pos + 1 < len) {
                buf[pos] = 0xc3;
                buf[pos + 1] = 0xa9;
                try std.testing.expect(syrup.shared.textValid(buf[0..len]));
            }
        }
    }
}

test "Syrup decodes an unrecognised captp-version rather than calling the frame malformed" {
    // `fromWireString` matches only `wireString` spellings (`1.0`,
    // `glowcap-next`), so the former lenient `ocapn-1.0` alias is not one.
    //
    // But an unrecognised token is a well-formed frame naming a version this
    // build does not speak, and saying "malformed frame" about it both misleads
    // whoever reads the abort and puts the judgement in two decoders instead of
    // the one validator that owns it. The codec reports what the bytes say; the
    // session decides. `session.validate` refuses this as `CaptpVersionMismatch`
    // (the upstream suite's `invalid-version` probe reads that abort).
    //
    // The length prefix here is 9, matching `ocapn-1.0`. An earlier spelling of
    // this test declared 8, so the frame was malformed for a length reason and
    // the assertion passed without ever reaching the version.
    const frame_bytes: []const u8 =
        "<16'op:start-session9\"ocapn-1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1f>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    const body = try syrup.decodeBody(view);
    try std.testing.expectEqual(
        @as(?glowcap.ocapn.model.CaptpVersion, null),
        body.start_session.captp_version,
    );
}

test "a session refuses an unrecognised captp-version as a version mismatch" {
    // The other half of the split above: the decoder reported, this decides.
    const allocator = std.testing.allocator;
    var peer = glowcap.ocapn.engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.verify_partner_handshake = false;

    const frame_bytes: []const u8 =
        "<16'op:start-session9\"ocapn-1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1f>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(
        glowcap.ocapn.session.Error.CaptpVersionMismatch,
        peer.recvBorrowed(view),
    );
}

test "a deliver carrying a Struct (dictionary) argument decodes to the struct arm" {
    // OCapN's Struct passable rides Syrup as a dictionary `{ key value … }`
    // (ADR-0046). `{1"a1"b}` is the one-entry struct {"a": "b"}.
    const frame = "<10'op:deliver<11'desc:export7+>[{1\"a1\"b}]42+f>";
    const body = try syrup.decodeBody(.{ .bytes = frame, .shape = .byte });
    try std.testing.expect(body == .deliver);
    const arg = try body.deliver.args.at(0);
    try std.testing.expect(arg == .@"struct");
    try std.testing.expectEqual(@as(usize, 1), try arg.@"struct".len());
    const entry = try arg.@"struct".at(0);
    try std.testing.expectEqualStrings("a", entry.key);
    try std.testing.expect(entry.value == .string);
    try std.testing.expectEqualStrings("b", entry.value.string);
}

test "Syrup decode refuses a Set whose elements are out of canonical order" {
    // A set's wire form is canonical only in strictly-ascending encoded-element
    // order (the encode-side partner of writeCanonicalSet). `#3+1+2+$` spells the
    // same set as `#1+2+3+$`, so a lenient read would admit a second spelling of
    // one set; it is refused like a non-canonical struct key.
    const frame = "<10'op:deliver<11'desc:export7+>[#3+1+2+$]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = frame, .shape = .byte }),
    );
}

test "Syrup decode refuses a Set carrying a duplicate element" {
    // Set elements are unique. `#1+1+$` repeats `1+`; an equal element is never
    // strictly ascending, so the same ordering check that rejects a non-canonical
    // set also rejects a duplicate, fail-closed.
    const frame = "<10'op:deliver<11'desc:export7+>[#1+1+$]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = frame, .shape = .byte }),
    );
}

test "a single collection wider than the decode element cap is refused" {
    // Collection width is untrusted, and every later walk over a
    // collection, the lazy view's len/at, session validation, owned
    // materialization, is linear in the element count. The codec caps a
    // single list / set / struct at 1 << 20 elements
    // (`max_collection_elements` in syrup/decode/syntax.zig, the width sibling of
    // `max_decode_nesting`) and refuses past it during the slice walk, before
    // any of those walks run. The cap sits just above what the default
    // streaming byte cap can carry, so it binds the uncapped whole-frame
    // entry points exercised here; on the streaming path with default limits
    // the byte cap's FRAME_TOO_LARGE fires first (ADR-0041, pinned by the
    // C ABI recv_stream tests). Ordinary CapTP traffic carries a handful of
    // arguments per deliver, so a compliant frame never sees the cap.
    const allocator = std.testing.allocator;
    const cap = 1 << 20;
    const prefix = "<10'op:deliver<11'desc:export7+>[";
    const suffix = "]42+f>";

    // A list one past the cap is refused…
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, prefix);
        try bytes.append(allocator, '[');
        for (0..cap + 1) |_| try bytes.appendSlice(allocator, "0+");
        try bytes.append(allocator, ']');
        try bytes.appendSlice(allocator, suffix);
        try std.testing.expectError(
            syrup.Error.MalformedFrame,
            syrup.decodeBody(.{ .bytes = bytes.items, .shape = .byte }),
        );
    }
    // …and a list exactly at the cap still decodes.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, prefix);
        try bytes.append(allocator, '[');
        for (0..cap) |_| try bytes.appendSlice(allocator, "0+");
        try bytes.append(allocator, ']');
        try bytes.appendSlice(allocator, suffix);
        const body = try syrup.decodeBody(.{ .bytes = bytes.items, .shape = .byte });
        const arg = try body.deliver.args.at(0);
        try std.testing.expect(arg == .list);
    }
    // A set one past the cap is refused.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, prefix);
        try bytes.append(allocator, '#');
        for (0..cap + 1) |_| try bytes.appendSlice(allocator, "0+");
        try bytes.append(allocator, '$');
        try bytes.appendSlice(allocator, suffix);
        try std.testing.expectError(
            syrup.Error.MalformedFrame,
            syrup.decodeBody(.{ .bytes = bytes.items, .shape = .byte }),
        );
    }
    // A struct one past the cap is refused even with canonically sorted keys.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, prefix);
        try bytes.append(allocator, '{');
        var key_buf: [16]u8 = undefined;
        for (0..cap + 1) |i| {
            // Fixed-width decimal keys: raw ascending order is encoded
            // ascending order, so only the entry count trips the refusal.
            const entry = try std.fmt.bufPrint(&key_buf, "8\"k{d:0>7}0+", .{i});
            try bytes.appendSlice(allocator, entry);
        }
        try bytes.append(allocator, '}');
        try bytes.appendSlice(allocator, suffix);
        try std.testing.expectError(
            syrup.Error.MalformedFrame,
            syrup.decodeBody(.{ .bytes = bytes.items, .shape = .byte }),
        );
    }
}

test "decodeOwned materializes start-session fields" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("op_start_session_v1_0.bin").?;
    const bytes = try allocator.dupe(u8, fixture.bytes());
    defer allocator.free(bytes);

    const decoded = try syrup.decodeOwned(allocator, .{ .bytes = bytes, .shape = .byte });
    defer {
        allocator.free(decoded.start_session.session_pubkey.bytes);
        allocator.free(decoded.start_session.acceptable_location.transport);
        allocator.free(decoded.start_session.acceptable_location.designator);
        allocator.free(decoded.start_session.acceptable_location.hints.entries);
        allocator.free(decoded.start_session.acceptable_location_sig.bytes);
    }
    @memset(bytes, '!');

    try std.testing.expectEqual(model.CaptpVersion.v1_0, decoded.start_session.captp_version);
    try std.testing.expectEqual(@as(usize, 32), decoded.start_session.session_pubkey.bytes.len);
    try std.testing.expectEqualStrings("memory", decoded.start_session.acceptable_location.transport);
    try std.testing.expectEqualStrings("exporter", decoded.start_session.acceptable_location.designator);
    try std.testing.expectEqual(@as(usize, 0), decoded.start_session.acceptable_location.hints.entries.len);
    try std.testing.expectEqual(@as(usize, 64), decoded.start_session.acceptable_location_sig.bytes.len);
}

test "Syrup decode rejects non-byte frame shape" {
    const frame = glowcap.foundation.FrameView{
        .bytes = "<8'op:abort13\"shutting down>",
        .shape = .word,
    };

    try std.testing.expectError(syrup.Error.InvalidFrameShape, syrup.decodeBody(frame));
}

test "a record label the decoder matches is never read as a symbol, and one it keeps as data is" {
    // A label that equals no known spelling is refused by the reader that
    // matched it, whatever its bytes, so the UTF-8 check is skipped there.
    // The message op, a resolution, a reference and an error all refuse.
    const unmatched_labels = [_]struct { frame: []const u8, err: syrup.Error }{
        .{ .frame = "<10'op:deli\xff\xff<11'desc:export7+>[]ff>", .err = syrup.Error.UnsupportedMessage },
        .{ .frame = "<10'op:deliver<11'desc:ex\xff\xff\xff7+>[]ff>", .err = syrup.Error.UnsupportedReference },
        .{ .frame = "<10'op:resolve<11'desc:export7+><15'resolve:ful\xff\xff\xff1+>>", .err = syrup.Error.MalformedFrame },
    };
    for (unmatched_labels) |case| {
        const view = glowcap.foundation.FrameView{ .bytes = case.frame, .shape = .byte };
        try std.testing.expectError(case.err, syrup.decodeBody(view));
    }
    // A foreign record's label becomes the tag the application reads, so it
    // is checked where it becomes data, and a bad one is malformed.
    const foreign = "<10'op:deliver<11'desc:export1+>[5'break<16'exn:fail:my\xff\xffery>]ff>";
    const foreign_view = glowcap.foundation.FrameView{ .bytes = foreign, .shape = .byte };
    try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeBody(foreign_view));
    try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeOwned(std.testing.allocator, foreign_view));
}

test "Syrup decodes a foreign record argument as Tagged, so a Goblins break payload survives" {
    // The exact shape a live Goblins peer answers a refused withdraw with: a
    // resolver-callback deliver whose break payload is a bare exception
    // record. The record's label lands as the tag, the reason text
    // `engine.events.breakReasonFromPayload` reads, instead of the whole
    // frame dying as malformed.
    const frame = "<10'op:deliver<11'desc:export1+>[5'break<16'exn:fail:mystery>]ff>";
    const body = try syrup.decodeBody(.{ .bytes = frame, .shape = .byte });
    const deliver = body.deliver;
    const tag_arg = try deliver.args.at(0);
    try std.testing.expectEqualStrings("break", tag_arg.symbol);
    const payload = try deliver.args.at(1);
    try std.testing.expect(payload == .tagged);
    try std.testing.expectEqualStrings("exn:fail:mystery", payload.tagged.tag);
    try std.testing.expectEqual(@as(usize, 0), try payload.tagged.value.len());
}

test "Syrup decode rejects malformed parser boundary cases" {
    const Case = struct {
        bytes: []const u8,
        expected: anyerror,
    };
    const cases = [_]Case{
        .{ .bytes = "<8'op:abort4\"bye>", .expected = syrup.Error.MalformedFrame },
        .{ .bytes = "<8'op:abort5\"bye>", .expected = syrup.Error.MalformedFrame },
        .{ .bytes = "<10'op:deliver<11'desc:unknown7+>[]11+f>", .expected = syrup.Error.UnsupportedReference },
        .{ .bytes = "<8'op:abort3\"bye>trailing", .expected = syrup.Error.MalformedFrame },
        .{ .bytes = "<13'op:gc-answers[11+13+>", .expected = syrup.Error.MalformedFrame },
    };

    for (cases) |bytes| {
        try std.testing.expectError(
            bytes.expected,
            syrup.decodeBody(.{ .bytes = bytes.bytes, .shape = .byte }),
        );
    }
}

// The Syrup owned decoder is the second inbound surface. Like the
// Cap'n Proto fuzz, this corrupts every byte of representative frames and
// asserts `decodeOwned` stays total, a typed error or a well-formed message,
// never a panic, a leak, or a double-free. It exercises the multi-allocation
// arms whose partial-failure cleanup is easy to get wrong: gc-export's two
// parallel lists, start-session, and both handoff envelopes.
test "Syrup: corrupting any byte of a frame stays total: typed error or message, never a panic" {
    const allocator = std.testing.allocator;
    var handoff_arg = model.Handoff{ .give = handoff_fixtures.give() };

    const messages = [_]model.Message{
        .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(4) },
            .args = &.{
                .{ .bytes = &.{ 1, 2, 3 } },
                .{ .reference = .{ .far = model.FarRef.promise(2) } },
                .{ .handoff = &handoff_arg },
            },
            .answer = .from(7),
        } },
        .{ .resolve = .{ .answer = .from(9), .resolution = .{ .@"break" = .{ .message = "boom" } } } },
        .{ .resolve = .{ .answer = .from(2), .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } } } },
        .{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } },
        .{ .gc_answer = .{ .positions = &.{ 1, 4, 9 } } },
        .{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } },
        .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .far = model.FarRef.object(2) },
            .mode = .shortening_or_settling,
        } },
        .{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } },
        .{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = .{ .integer = -3 }, .answer = .from(9) } },
        .{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &(@as([32]u8, @splat(0xab))) },
            .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
            .acceptable_location_sig = .{ .bytes = &(@as([64]u8, @splat(0xcd))) },
        } },
    };

    for (messages) |message| {
        const profile = model.CaptpVersion.v1_0;
        var frame = try syrup.encodeMessageForProfile(allocator, profile, message);
        defer frame.deinit();

        const original = try allocator.dupe(u8, frame.bytes());
        defer allocator.free(original);

        for (0..original.len) |i| {
            for ([_]u8{ 0xFF, 0x7F, 0x01 }) |corruption| {
                if (original[i] == corruption) continue;
                const buf = try allocator.dupe(u8, original);
                defer allocator.free(buf);
                buf[i] = corruption;
                const view = glowcap.foundation.FrameView{ .bytes = buf, .shape = .byte };

                if (syrup.decodeOwned(allocator, view)) |decoded| {
                    model.freeMessage(allocator, decoded);
                } else |_| {}
            }
        }
    }
}

test "a next listen mode is refused under v1.0 and projected under next" {
    const allocator = std.testing.allocator;
    for ([_]model.ListenMode{ .settling_only, .shortening_or_settling }) |mode| {
        var frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(7) },
            .listener = .{ .near = model.NearRef.object(9) },
            .mode = mode,
        } });
        defer frame.deinit();

        try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(frame.view()));
        const next_body = try syrup.decodeBodyForProfile(.next, frame.view());
        try std.testing.expectEqual(mode, next_body.listen.mode);
    }
}

test "the next deliver arity is refused under v1.0 and projected under next" {
    const allocator = std.testing.allocator;
    var frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &.{.{ .string = "next" }},
        .answer = .from(6),
        .resolve_me_desc = .{ .near = model.NearRef.object(9) },
        .listen_mode = .shortening_only,
    } });
    defer frame.deinit();

    try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(frame.view()));
    const next_body = try syrup.decodeBodyForProfile(.next, frame.view());
    try std.testing.expectEqual(model.AnswerPosition.from(6), next_body.deliver.answer.?);
    try std.testing.expectEqual(model.ListenMode.shortening_only, next_body.deliver.listen_mode);
}

test "a known label matches only its canonical form" {
    // The op and reference readers match a label they know as one
    // comparison against its canonical form. A match must admit exactly
    // what the general reader would: the same label, in bounds, with no
    // other spelling.
    const frame = "<13'op:gc-answers[7+]>";
    _ = try syrup.decodeBody(.{ .bytes = frame, .shape = .byte });
    // A frame that ends inside the label is malformed, not unsupported.
    try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(.{ .bytes = frame[0..10], .shape = .byte }));
    // A known label with a wrong width, or one byte off at its end, is no
    // match, and the general reader then refuses the label it does not know.
    const unsupported_ops = [_][]const u8{ "<14'op:gc-answers![7+]>", "<13'op:gc-answerz[7+]>" };
    for (unsupported_ops) |bytes| {
        try std.testing.expectError(
            syrup.Error.UnsupportedMessage,
            syrup.decodeBody(.{ .bytes = bytes, .shape = .byte }),
        );
    }
    const unsupported_references = [_][]const u8{
        "<10'op:deliver<12'desc:export!7+>[]ff>",
        "<10'op:deliver<11'desc:exporz7+>[]ff>",
    };
    for (unsupported_references) |bytes| {
        try std.testing.expectError(
            syrup.Error.UnsupportedReference,
            syrup.decodeBody(.{ .bytes = bytes, .shape = .byte }),
        );
    }
}

test "Syrup decode refuses non-canonical digit spellings" {
    // Canonical Syrup has exactly one wire spelling per value: `0+` is the only
    // zero, and no digit run carries a superfluous leading zero. A lenient read
    // would let one message arrive as several different byte strings, voiding
    // the byte-level canonicality that signed records and byte-keyed tables
    // lean on.
    const cases = [_][]const u8{
        "<8'op:abort013\"shutting down>", // leading-zero string length
        "<010'op:deliver<11'desc:export7+>[]42+f>", // leading-zero op label width
        "<10'op:deliver<011'desc:export7+>[]42+f>", // leading-zero reference label width
        "<10'op:deliver<11'desc:export07+>[]42+f>", // leading-zero position
        "<10'op:deliver<11'desc:export7+>[00+]42+f>", // leading-zero integer magnitude
        "<10'op:deliver<11'desc:export7+>[0-]42+f>", // negative zero
    };
    for (cases) |bytes| {
        try std.testing.expectError(
            syrup.Error.MalformedFrame,
            syrup.decodeBody(.{ .bytes = bytes, .shape = .byte }),
        );
    }

    // The canonical zero still decodes.
    const decoded = try syrup.decodeBody(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[0+]42+f>",
        .shape = .byte,
    });
    try std.testing.expectEqual(@as(i64, 0), (try decoded.deliver.args.at(0)).integer);
}
