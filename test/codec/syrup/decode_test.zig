//! What Syrup decode admits and refuses: invalid UTF-8, duplicate keys,
//! malformed and non-canonical bytes, oversized collections, start-session
//! fields, and single-byte corruption anywhere in a frame failing loudly.

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
        const view = pancake.foundation.FrameView{ .bytes = bytes, .shape = .byte };
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

test "Syrup decodes an unrecognised captp-version rather than calling the frame malformed" {
    // `fromWireString` matches only `wireString` spellings (`1.0`,
    // `pancake-next`), so the former lenient `ocapn-1.0` alias is not one.
    //
    // But an unrecognised token is a well-formed frame naming a version this
    // build does not speak, and saying "malformed frame" about it both misleads
    // whoever reads the abort and puts the judgement in two decoders instead of
    // the one validator that owns it. The codec reports what the bytes say; the
    // session decides. `session.validate` refuses this as `CaptpVersionMismatch`
    // — the upstream suite's `invalid-version` probe reads that abort.
    //
    // The length prefix here is 9, matching `ocapn-1.0`. An earlier spelling of
    // this test declared 8, so the frame was malformed for a length reason and
    // the assertion passed without ever reaching the version.
    const frame_bytes: []const u8 =
        "<16'op:start-session9\"ocapn-1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1f>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    const body = try syrup.decodeBody(view);
    try std.testing.expectEqual(
        @as(?pancake.ocapn.model.CaptpVersion, null),
        body.start_session.captp_version,
    );
}

test "a session refuses an unrecognised captp-version as a version mismatch" {
    // The other half of the split above: the decoder reported, this decides.
    const allocator = std.testing.allocator;
    var peer = pancake.ocapn.engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.verify_partner_handshake = false;

    const frame_bytes: []const u8 =
        "<16'op:start-session9\"ocapn-1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1f>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(
        pancake.ocapn.session.Error.CaptpVersionMismatch,
        peer.recvBorrowed(view),
    );
}

test "Syrup decode refuses duplicate feature hints as a noncanonical dictionary" {
    const allocator = std.testing.allocator;
    var peer = pancake.ocapn.engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.verify_partner_handshake = false;

    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{16\"pancake/features0\"16\"pancake/features10\"pipelining}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(view),
    );
    try std.testing.expectError(syrup.Error.MalformedFrame, peer.recvBorrowed(view));
    try std.testing.expect(!peer.session_state.handshake_remote_received);
}

test "a session refuses malformed reserved profile hints on the borrowed start-session path" {
    const allocator = std.testing.allocator;
    const hint_maps = [_][]const u8{
        "{21\"pancake/captp-version7\"ocapn-2}",
        "{13\"pancake/codec3:bad}",
        "{16\"pancake/features[1+]}",
    };
    inline for (hint_maps) |hint_map| {
        var peer = pancake.ocapn.engine.Peer.initNegotiating(allocator);
        defer peer.deinit();
        peer.verify_partner_handshake = false;

        const frame_bytes: []const u8 =
            "<16'op:start-session3\"1.0" ++
            "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
            "<10'ocapn-peer3'tcp9\"127.0.0.1" ++ hint_map ++ ">" ++
            "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
        const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
        try std.testing.expectError(
            pancake.ocapn.session.Error.MalformedMessage,
            peer.recvBorrowed(view),
        );
        try std.testing.expect(!peer.session_state.handshake_remote_received);
    }
}

test "Syrup decodes a start-session whose location carries non-empty hints" {
    // A real netlayer (the OCapN conformance suite's `tcp-testing-only`) puts the
    // address in the locator's hints map `{host …, port …}`. The decoder must
    // consume it so the whole frame decodes, and borrowed decode must expose the
    // entries through `BorrowedHints.lazy` (Cap'n Proto parity) so a Host can
    // dial without a separate re-parse. Goblins uses `#f` hints, so this shape
    // was unexercised until an external peer sent a hinted locator.
    const allocator = std.testing.allocator;
    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{4\"host9\"127.0.0.14\"port5\"52833}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    const body = try syrup.decodeBody(view);
    try std.testing.expect(body == .start_session);
    try std.testing.expectEqualStrings("127.0.0.1", body.start_session.acceptable_location.designator);
    try std.testing.expect(body.start_session.acceptable_location.hints == .lazy);

    const owned = try body.toOwned(allocator);
    defer {
        allocator.free(owned.start_session.session_pubkey.bytes);
        allocator.free(owned.start_session.acceptable_location.transport);
        allocator.free(owned.start_session.acceptable_location.designator);
        model.freeHints(allocator, owned.start_session.acceptable_location.hints);
        allocator.free(owned.start_session.acceptable_location_sig.bytes);
    }
    try std.testing.expectEqual(@as(usize, 2), owned.start_session.acceptable_location.hints.entries.len);
    try std.testing.expectEqualStrings("host", owned.start_session.acceptable_location.hints.entries[0].name);
    try std.testing.expectEqualStrings("52833", owned.start_session.acceptable_location.hints.entries[1].value.string);
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
    // Collection width is attacker-controlled, and every later walk over a
    // collection — the lazy view's len/at, session validation, owned
    // materialization — is linear in the element count. The codec caps a
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

test "decodeBody exposes borrowed views for start-session and nested handoff" {
    {
        const fixture = protocol_oracle.fixtureByName("op_start_session_v1_0.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(model.CaptpVersion.v1_0, decoded.start_session.captp_version);
        try std.testing.expectEqual(@as(usize, 32), decoded.start_session.session_pubkey.len);
        try std.testing.expectEqualStrings("memory", decoded.start_session.acceptable_location.transport);
        try std.testing.expectEqualStrings("exporter", decoded.start_session.acceptable_location.designator);
        const sig = decoded.start_session.acceptable_location_sig.halves;
        try std.testing.expectEqual(@as(usize, 64), sig.r.len + sig.s.len);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_deliver_withdraw_gift.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });
        const handoff = (try decoded.deliver.args.at(1)).handoff;
        try std.testing.expect(handoff == .receive);
        try std.testing.expect(handoff.receive.signed_give.raw_signed != null);
    }
}

test "standalone signed handoff-give decode refuses trailing bytes" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("desc_handoff_give_signed.bin").?;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    try bytes.appendSlice(allocator, fixture.bytes());
    try bytes.append(allocator, 'x');
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeSignedHandoffGiveOwned(allocator, bytes.items),
    );
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

test "borrowed start-session decode refuses noncanonical hint order" {
    const entries = [_]model.HintEntry{
        .{ .name = "a", .value = .{ .string = "x" } },
        .{ .name = "b", .value = .{ .string = "y" } },
    };
    var frame = try syrup.encodeMessageForProfile(std.testing.allocator, .v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &repeatedByte(32, 0xaa) },
            .acceptable_location = .{
                .transport = "tcp",
                .designator = "x",
                .hints = .{ .entries = &entries },
            },
            .acceptable_location_sig = .{ .bytes = &repeatedByte(64, 0xbb) },
        },
    });
    defer frame.deinit();

    const canonical = "{1\"a1\"x1\"b1\"y}";
    const reversed = "{1\"b1\"y1\"a1\"x}";
    const at = std.mem.indexOf(u8, frame.bytes(), canonical) orelse return error.MissingHintMap;
    @memcpy(@constCast(frame.bytes())[at..][0..reversed.len], reversed);
    try std.testing.expectError(syrup.Error.MalformedFrame, syrup.decodeBody(frame.view()));
}

test "Syrup decode rejects non-byte frame shape" {
    const frame = pancake.foundation.FrameView{
        .bytes = "<8'op:abort13\"shutting down>",
        .shape = .word,
    };

    try std.testing.expectError(syrup.Error.InvalidFrameShape, syrup.decodeBody(frame));
}

test "Syrup decodes a foreign record argument as Tagged, so a Goblins break payload survives" {
    // The exact shape a live Goblins peer answers a refused withdraw with: a
    // resolver-callback deliver whose break payload is a bare exception
    // record. The record's label lands as the tag — the reason text
    // `engine.events.breakReasonFromPayload` reads — instead of the whole
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

// The Syrup owned decoder is the second attacker-facing surface. Like the
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
                const view = pancake.foundation.FrameView{ .bytes = buf, .shape = .byte };

                if (syrup.decodeOwned(allocator, view)) |decoded| {
                    model.freeMessage(allocator, decoded);
                } else |_| {}
            }
        }
    }
}

test "profile-less Syrup framing accepts next listen modes without projecting semantics" {
    const allocator = std.testing.allocator;
    for ([_]model.ListenMode{ .settling_only, .shortening_or_settling }) |mode| {
        var frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(7) },
            .listener = .{ .near = model.NearRef.object(9) },
            .mode = mode,
        } });
        defer frame.deinit();

        const boundary = syrup.framePrefix(frame.bytes(), frame.bytes().len);
        try std.testing.expect(boundary == .complete);
        try std.testing.expectEqual(frame.bytes().len, boundary.complete);

        try std.testing.expect(syrup.decodePrefix(frame.bytes(), frame.bytes().len) == .malformed);
        try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(frame.view()));
        const next_body = try syrup.decodeBodyForProfile(.next, frame.view());
        try std.testing.expectEqual(mode, next_body.listen.mode);
    }
}

test "profile-less Syrup framing accepts the next deliver arity" {
    const allocator = std.testing.allocator;
    var frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(4) },
        .args = &.{.{ .string = "next" }},
        .answer = .from(6),
    } });
    defer frame.deinit();

    const boundary = syrup.framePrefix(frame.bytes(), frame.bytes().len);
    try std.testing.expect(boundary == .complete);
    try std.testing.expectEqual(frame.bytes().len, boundary.complete);

    try std.testing.expect(syrup.decodePrefix(frame.bytes(), frame.bytes().len) == .malformed);
    const next_body = try syrup.decodeBodyForProfile(.next, frame.view());
    try std.testing.expectEqual(model.AnswerPosition.from(6), next_body.deliver.answer.?);
}

test "Syrup decode refuses non-canonical digit spellings" {
    // Canonical Syrup has exactly one wire spelling per value: `0+` is the only
    // zero, and no digit run carries a superfluous leading zero. A lenient read
    // would let one message arrive as several different byte strings, voiding
    // the byte-level canonicality that signed records and byte-keyed tables
    // lean on.
    const cases = [_][]const u8{
        "<8'op:abort013\"shutting down>", // leading-zero string length
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
