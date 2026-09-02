//! What the Syrup encoder writes: exact-measure rendering, locators and
//! their hints, hellos, aborts, sets in canonical order, floats and bare
//! primitives, and the near-promise payload, each pinned to fixture bytes.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;
const render = @import("syrup").render;
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");
const handoff_fixtures = @import("../../support/handoff_fixtures.zig");

const harness = @import("harness.zig");
const expectFixtureBytes = harness.expectFixtureBytes;
const repeatedByte = harness.repeatedByte;
const hexToOwned = harness.hexToOwned;

test "exact renderer contains measure-fill divergence" {
    const DivergentWriter = struct {
        fn overfill(sink: anytype, pass: *usize) !void {
            pass.* += 1;
            for (0..pass.*) |_| try sink.append('x');
        }

        fn underfill(sink: anytype, pass: *usize) !void {
            pass.* += 1;
            const count: usize = if (pass.* == 1) 2 else 1;
            for (0..count) |_| try sink.append('x');
        }
    };

    var overfill_pass: usize = 0;
    try std.testing.expectError(
        error.EncoderInvariantViolation,
        render.renderRecordExact(std.testing.allocator, DivergentWriter.overfill, .{&overfill_pass}),
    );

    var underfill_pass: usize = 0;
    try std.testing.expectError(
        error.EncoderInvariantViolation,
        render.renderRecordExact(std.testing.allocator, DivergentWriter.underfill, .{&underfill_pass}),
    );
}

test "Syrup locator encoding uses typed locator and preserves empty false hints" {
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
                .hints = model.Hints.emptyFalse(),
            },
            .acceptable_location_sig = .{ .bytes = sig[0..] },
        },
    });
    defer frame.deinit();

    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "exporter") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "f>") != null);

    const decoded = try syrup.decodeBody(frame.view());
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, decoded.start_session.acceptable_location.hints.wireForm());
}

test "Syrup start-session carries hint entries canonically and signs over the same bytes" {
    // A keyed-tcp responder's location names its socket address in a
    // `direct-addresses` hint (ADR-0075), so the start-session encoder renders
    // hint entries as a canonical `{…}` dict — never dropping them, which
    // would put a different locator on the wire than the caller named — and
    // the location-signature domain embeds the identical bytes, so signer and
    // wire cannot disagree.
    const allocator = std.testing.allocator;
    const pubkey = repeatedByte(32, 0xaa);
    const sig = repeatedByte(64, 0xcc);
    const entries = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
    };
    const location: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:9001",
        .hints = .{ .entries = &entries },
    };
    const locator_bytes = "<10'ocapn-peer3'tcp14\"127.0.0.1:9001{4\"host9\"127.0.0.1}>";

    var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = pubkey[0..] },
            .acceptable_location = location,
            .acceptable_location_sig = .{ .bytes = sig[0..] },
        },
    });
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), locator_bytes) != null);

    const signed = try syrup.canonicalLocationSignedBytes(allocator, location);
    defer allocator.free(signed);
    const expected_signed = "<11'my-location" ++ locator_bytes ++ ">";
    try std.testing.expectEqualSlices(u8, expected_signed, signed);
}

test "op:abort encodes to the Goblins-aligned Syrup byte shape" {
    const allocator = std.testing.allocator;
    const message = model.Message{
        .abort = .{ .kind = .other, .message = "shutting down" },
    };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    try std.testing.expectEqualSlices(u8, "<8'op:abort13\"shutting down>", frame.bytes());
}

test "signed handoff give keeps original signed payload bytes through decode" {
    const allocator = std.testing.allocator;
    const raw_payload = try hexToOwned(
        allocator,
        "3c313727646573633a68616e646f66662d676976655b3130277075626c69632d6b65795b33276563635b352763757276653727456432353531395d5b3527666c616773352765646473615d5b31277133323a8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c5d5d5d3c3130276f6361706e2d706565723136277463702d74657374696e672d6f6e6c7933226162637b3422686f737439223132372e302e302e313422706f7274352232323035357d3e33323a030303030303030303030303030303030303030303030303030303030303030333323a0606060606060606060606060606060606060606060606060606060606060606373a6d792d676966743e",
    );
    defer allocator.free(raw_payload);
    const raw_receive = try hexToOwned(
        allocator,
        "3c313727646573633a7369672d656e76656c6f70653c323027646573633a68616e646f66662d7265636569766533323a040404040404040404040404040404040404040404040404040404040404040433323a0505050505050505050505050505050505050505050505050505050505050505302b3c313727646573633a7369672d656e76656c6f70653c313727646573633a68616e646f66662d676976655b3130277075626c69632d6b65795b33276563635b352763757276653727456432353531395d5b3527666c616773352765646473615d5b31277133323a8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c5d5d5d3c3130276f6361706e2d706565723136277463702d74657374696e672d6f6e6c7933226162637b3422686f737439223132372e302e302e313422706f7274352232323035357d3e33323a030303030303030303030303030303030303030303030303030303030303030333323a0606060606060606060606060606060606060606060606060606060606060606373a6d792d676966743e5b37277369672d76616c5b352765646473615b31277233323a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f5d5b31277333323a202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f5d5d5d3e3e5b37277369672d76616c5b352765646473615b31277233323a3f3e3d3c3b3a393837363534333231302f2e2d2c2b2a292827262524232221205d5b31277333323a1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a090807060504030201005d5d5d3e",
    );
    defer allocator.free(raw_receive);

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);
    try frame.appendSlice(allocator, "<10'op:deliver<11'desc:export0+>[13'withdraw-gift");
    try frame.appendSlice(allocator, raw_receive);
    try frame.appendSlice(allocator, "]99+f>");
    const decoded = try syrup.decodeBody(.{ .bytes = frame.items, .shape = .byte });
    const handoff_arg = try decoded.deliver.args.at(1);
    const handoff = try handoff_arg.handoff.toOwned(allocator);
    defer glowcap.ocapn.model.owned.freeHandoff(allocator, handoff);
    const give = handoff.receive.signed_give;

    try std.testing.expect(give.raw_signed != null);
    const signed_payload = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(signed_payload);
    try std.testing.expectEqualSlices(u8, raw_payload, signed_payload);
}

test "op:abort with a typed kind encodes the wire label prefix" {
    const allocator = std.testing.allocator;
    const message = model.Message{
        .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" },
    };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    // The encoder derives the label from the kind discriminant (kind.wireName())
    // and builds "<label>: <message>" at encode time, general across kinds and
    // symmetric with the decoder's abort-prefix parse, with no per-message
    // special case.
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "VersionMismatch: expected ocapn-1.0") != null);
}

test "minimal op:deliver encodes to the next Syrup byte shape" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const args = [_]model.Argument{.{ .bytes = "hello" }};
    const message = model.Message{
        .deliver = .{
            .target = target,
            .args = args[0..],
            .answer = .from(42),
        },
    };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[5:hello]42+f>",
        frame.bytes(),
    );
}

test "Syrup encodes a Set in canonical encoded-byte order, not model order" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };

    // The same three-element set, built in two different model orders.
    const set_a = [_]model.Argument{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } };
    const set_b = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const args_a = [_]model.Argument{.{ .set = set_a[0..] }};
    const args_b = [_]model.Argument{.{ .set = set_b[0..] }};

    var frame_a = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args_a[0..] } });
    defer frame_a.deinit();
    var frame_b = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args_b[0..] } });
    defer frame_b.deinit();

    // Canonical ordering means both encode to identical bytes regardless of the
    // order the model held the set in, the encode-side partner of the
    // order-agnostic set equality in model.equality.
    try std.testing.expectEqualSlices(u8, frame_a.bytes(), frame_b.bytes());

    // The items come out sorted by their encoded bytes (1, 2, 3), not insertion order.
    try std.testing.expect(std.mem.indexOf(u8, frame_a.bytes(), "#1+2+3+$") != null);
}

test "Syrup encodes an empty Set as the bare #$ markers and the neutral decode accepts it" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const empty: [0]model.Argument = .{};
    const args = [_]model.Argument{.{ .set = empty[0..] }};

    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args[0..] } });
    defer frame.deinit();
    // An empty set is the open/close markers with nothing between them.
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "#$") != null);

    // The codec-neutral decode (the production inbound path) reads it back as a
    // single empty-set argument.
    const body = try syrup.decodeBody(frame.view());
    try std.testing.expect(body == .deliver);
    try std.testing.expectEqual(@as(usize, 1), try body.deliver.args.len());
    const arg = try body.deliver.args.at(0);
    try std.testing.expect(arg == .set);
    try std.testing.expectEqual(@as(usize, 0), try arg.set.len());
}

test "Syrup materializes hints by skipping exotic values Cap'n Proto cannot express" {
    // Hints are advisory. A symbol (or nested dict/list/double) inside a
    // locator hints map is legal Syrup but outside `HintValueKind`; materialize
    // skips it so a retained path (`toOwned`, pipelined deliver) still applies.
    const allocator = std.testing.allocator;
    const frame_bytes: []const u8 =
        "<16'op:start-session3\"1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1{4\"host9\"127.0.0.14\"port5\"528335\"extra3'bad}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = glowcap.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    const body = try syrup.decodeBody(view);
    try std.testing.expect(body.start_session.acceptable_location.hints == .lazy);
    // Materialize keeps only the known-shaped entries (host, port) — not `extra`.
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
    try std.testing.expectEqualStrings("port", owned.start_session.acceptable_location.hints.entries[1].name);
}

test "Syrup encodes an error in argument position and the neutral decode reads it back" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    // A Goblins V1.0 resolver-callback `break` ships its `model.BreakReason` as a
    // deliver argument (`['break <error msg>]`); the encoder must be able to
    // write what the decoder already reads, without this arm the refusal path
    // could not cross the wire.
    const args = [_]model.Argument{ .{ .symbol = "break" }, .{ .@"error" = .{ .message = "UnattestedCaller" } } };

    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args[0..], .answer = null } });
    defer frame.deinit();

    const body = try syrup.decodeBody(frame.view());
    try std.testing.expect(body == .deliver);
    try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
    const tag = try body.deliver.args.at(0);
    try std.testing.expect(tag == .symbol);
    try std.testing.expectEqualStrings("break", tag.symbol);
    const err = try body.deliver.args.at(1);
    try std.testing.expect(err == .@"error");
    try std.testing.expectEqualStrings("UnattestedCaller", err.@"error".message);
}

test "Syrup canonicalizes nested Sets recursively, not just the outer one" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };

    // The set { {1,2}, {3,4} } built two ways: the outer elements in different
    // order, and each inner set in different order. Canonical encoding has to
    // sort at every level, so both must produce identical bytes.
    const inner1_rev = [_]model.Argument{ .{ .integer = 2 }, .{ .integer = 1 } };
    const inner2_rev = [_]model.Argument{ .{ .integer = 4 }, .{ .integer = 3 } };
    const inner1 = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const inner2 = [_]model.Argument{ .{ .integer = 3 }, .{ .integer = 4 } };

    const outer_a = [_]model.Argument{ .{ .set = inner1_rev[0..] }, .{ .set = inner2_rev[0..] } };
    const outer_b = [_]model.Argument{ .{ .set = inner2[0..] }, .{ .set = inner1[0..] } };
    const args_a = [_]model.Argument{.{ .set = outer_a[0..] }};
    const args_b = [_]model.Argument{.{ .set = outer_b[0..] }};

    var frame_a = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args_a[0..] } });
    defer frame_a.deinit();
    var frame_b = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args_b[0..] } });
    defer frame_b.deinit();
    try std.testing.expectEqualSlices(u8, frame_a.bytes(), frame_b.bytes());
}

test "a no-answer deliver encodes as a single op:deliver, never op:deliver-only" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const args = [_]model.Argument{.{ .bytes = "hello" }};
    const message = model.Message{ .deliver = .{ .target = target, .args = args[0..], .answer = null } };

    // A one-way (no-answer) send is a single op:deliver with a #f answer position
    // on every profile, including the Goblins-canonical V1.0 one. OCapN 1.0 has no
    // separate one-way record.
    var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, message);
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "op:deliver-only") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "op:deliver") != null);

    // It round-trips to a deliver with no answer, the shape the engine and
    // session handle for a one-way send.
    const body = try syrup.decodeBody(frame.view());
    try std.testing.expect(body == .deliver);
    try std.testing.expect(body.deliver.answer == null);
}

test "v1.0 listen emits the Goblins boolean and accepts the legacy omitted false" {
    const allocator = std.testing.allocator;
    const message: model.Message = .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } };
    var canonical = try syrup.encodeMessageForProfile(allocator, .v1_0, message);
    defer canonical.deinit();
    try expectFixtureBytes("op_listen_v1_0_wants_partial_false.bin", canonical);

    const legacy = protocol_oracle.fixtureByName("op_listen_promise_target.bin").?;
    const decoded = try syrup.decodeBodyForProfile(.v1_0, .{ .bytes = legacy.bytes(), .shape = .byte });
    try std.testing.expectEqual(model.ListenMode.settling_only, decoded.listen.mode);
}

test "op:index preserves an arbitrary-precision Integer" {
    const wire = "<8'op:index<11'desc:export7+>9223372036854775808+11+>";
    const decoded = try syrup.decodeBody(.{ .bytes = wire, .shape = .byte });
    try std.testing.expect(decoded.index.index == .big_integer);
    try std.testing.expect(!decoded.index.index.big_integer.negative);
    try std.testing.expectEqualStrings("9223372036854775808", decoded.index.index.big_integer.digits);

    const allocator = std.testing.allocator;
    var encoded = try syrup.encodeMessage(allocator, .{ .index = .{
        .receiver = .{ .far = model.FarRef.object(7) },
        .index = decoded.index.index,
        .answer = .from(11),
    } });
    defer encoded.deinit();
    try std.testing.expectEqualStrings(wire, encoded.bytes());
}

test "encodePeerLocatorRecord round-trips a direct-addresses hint for cross-process redeem" {
    const allocator = std.testing.allocator;

    // A gifter naming an iroh exporter reachable only by direct address encodes
    // the dial hint into the give's exporter-location record; the recipient
    // re-parses it to dial. An empty hint set keeps the bare `#f` spelling.
    const addrs = "127.0.0.1:4242,127.0.0.1:4243";
    var entries = [_]model.HintEntry{.{ .name = "direct-addresses", .value = .{ .string = addrs } }};
    const record = try syrup.encodePeerLocatorRecord(allocator, .{
        .transport = "iroh",
        .designator = "abcd",
        .hints = .{ .entries = entries[0..], .wire_form = .map },
    });
    defer allocator.free(record);

    var cursor: usize = 0;
    const parsed = try syrup.readLocatorOwned(allocator, record, &cursor);
    defer {
        allocator.free(parsed.transport);
        allocator.free(parsed.designator);
        model.freeHints(allocator, parsed.hints);
    }

    try std.testing.expectEqual(record.len, cursor);
    try std.testing.expectEqualStrings("iroh", parsed.transport);
    try std.testing.expectEqualStrings("abcd", parsed.designator);
    try std.testing.expectEqual(@as(usize, 1), parsed.hints.entries.len);
    try std.testing.expectEqualStrings("direct-addresses", parsed.hints.entries[0].name);
    try std.testing.expectEqualStrings(addrs, parsed.hints.entries[0].value.string);
}

test "Syrup locator records enforce model invariants on encode and owned decode" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        syrup.Error.UnsupportedArgument,
        syrup.encodePeerLocatorRecord(allocator, .{
            .transport = "tcp",
            .designator = "",
            .hints = model.Hints.emptyFalse(),
        }),
    );

    const invalid_transport = "<10'ocapn-peer3'a.b1\"xf>";
    var cursor: usize = 0;
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.readLocatorOwned(allocator, invalid_transport, &cursor),
    );
}

test "Syrup locator hints require canonical strictly ascending keys" {
    const reversed = "<10'ocapn-peer3'tcp1\"x{1\"b1\"x1\"a1\"y}>";
    var reversed_cursor: usize = 0;
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.readLocatorOwned(std.testing.allocator, reversed, &reversed_cursor),
    );

    const duplicate = "<10'ocapn-peer3'tcp1\"x{1\"a1\"x1\"a1\"y}>";
    var duplicate_cursor: usize = 0;
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.readLocatorOwned(std.testing.allocator, duplicate, &duplicate_cursor),
    );

    const oversized_integer = "<10'ocapn-peer3'tcp1\"x{1\"a9223372036854775808+}>";
    var integer_cursor: usize = 0;
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.readLocatorOwned(std.testing.allocator, oversized_integer, &integer_cursor),
    );
}

test "Syrup encodes float64 as the canonical 'D' + big-endian binary64 wire shape" {
    const allocator = std.testing.allocator;
    // Syrup renders a double as `'D'` then 8 bytes IEEE-754 big-endian. 1.5 is
    // 0x3FF8000000000000, so the frame pins the exact spec bytes, the wire
    // contract a Goblins peer emitting a float over Syrup expects.
    const args = [_]model.Argument{.{ .float64 = 1.5 }};
    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = args[0..],
        .answer = .from(42),
    } });
    defer frame.deinit();

    // Pin against the glowcap-authored reference frame (serialized by the
    // upstream Syrup encoder) rather than a hand-typed duplicate, so the corpus
    // fixture is actually load-bearing.
    try expectFixtureBytes("op_deliver_arg_float64.bin", frame);
}

test "Syrup encodes bare primitives byte-for-byte against the upstream Syrup-encoded reference fixtures" {
    const allocator = std.testing.allocator;
    // Each `prim_*.bin` is a bare glowcap-authored Syrup value serialized by the
    // upstream Syrup encoder. The
    // glowcap encoder only emits whole op-records, so encode each as the sole
    // argument of an `op:deliver` and slice the primitive sub-bytes back out:
    // the framing around the argument list is the fixed prefix and suffix below.
    const prefix = "<10'op:deliver<11'desc:export7+>[";
    const suffix = "]42+f>";
    const cases = .{
        .{ "prim_integer_pos_42.bin", model.Argument{ .integer = 42 } },
        .{ "prim_integer_neg_7.bin", model.Argument{ .integer = -7 } },
        // 2^100 negated: a Racket bignum on the upstream side, glowcap's
        // `big_integer` arm on this side (ADR-0049).
        .{ "prim_integer_big_neg.bin", model.Argument{ .big_integer = .{
            .negative = true,
            .digits = "1267650600228229401496703205376",
        } } },
        .{ "prim_string_hello.bin", model.Argument{ .string = "hello" } },
        .{ "prim_list_of_ints.bin", model.Argument{ .list = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } } } },
        .{ "prim_set_of_ints.bin", model.Argument{ .set = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } } } },
        // Racket `(hash "a" 1 "b" 2)` upstream, glowcap's Struct arm here,
        // canonical key order on encode makes the bytes deterministic (ADR-0046).
        .{ "prim_dict_str_to_int.bin", model.Argument{ .@"struct" = &.{
            .{ .key = "a", .value = .{ .integer = 1 } },
            .{ .key = "b", .value = .{ .integer = 2 } },
        } } },
    };
    inline for (cases) |case| {
        const args = [_]model.Argument{case[1]};
        var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        } });
        defer frame.deinit();
        const bytes = frame.bytes();
        const inner = bytes[prefix.len .. bytes.len - suffix.len];
        const fixture = protocol_oracle.fixtureByName(case[0]).?;
        try std.testing.expectEqualSlices(u8, fixture.bytes(), inner);
    }
}

test "Syrup typed abort encode matches Goblins prefix fixture" {
    const allocator = std.testing.allocator;
    const message = model.Message{
        .abort = .{ .kind = .version_mismatch, .message = "peer requested 2.0" },
    };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    try expectFixtureBytes("op_abort_typed.bin", frame);
}

test "next-profile Syrup encodes integer listen modes" {
    const allocator = std.testing.allocator;
    var frame = try syrup.encodeMessageForProfile(allocator, .next, .{
        .listen = .{
            .target = .{ .promise = .{ .answer_position = .from(7) } },
            .listener = .{ .near = .{ .export_position = .from(9) } },
            .mode = .settling_only,
        },
    });
    defer frame.deinit();
    try std.testing.expectEqualStrings(
        "<9'op:listen<11'desc:answer7+><18'desc:import-object9+>2+>",
        frame.bytes(),
    );
}

test "Syrup near-promise payload encodes desc:import-promise and round-trips kind" {
    const allocator = std.testing.allocator;
    const args = [_]model.Argument{.{ .reference = .{ .near = model.NearRef.promise(7) } }};
    var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(1) } },
            .args = args[0..],
            .answer = null,
        },
    });
    defer frame.deinit();

    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "desc:import-promise") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "desc:import-object") == null);

    // A sender's promise-shaped `Near` export encodes `<desc:import-promise>` and
    // decodes on the receiver as a promise-shaped `Far` import (ADR-0010 flip);
    // the object/promise kind rides the wire tag and survives into `RefKind`.
    const decoded = try syrup.decodeOwned(allocator, frame.view());
    defer allocator.free(decoded.deliver.args);
    try std.testing.expectEqual(model.RefKind.promise, decoded.deliver.args[0].reference.far.kind);
    try std.testing.expectEqual(@as(u64, 7), decoded.deliver.args[0].reference.far.import_position.int());
}

// R1 apex: the keyed self-locator hint spelling is a wire invariant Goblins
// signs, so `model.Hints.forDirectAddresses` — the one place the empty-vs-entry
// decision lives — must reproduce the exact `#f` empty spelling. A future edit
// that spells empty hints as `{}` (or drifts the entry) fails loud here.
test "forDirectAddresses signs #f for empty, an entry for present — the exact Goblins-signed spelling" {
    const allocator = std.testing.allocator;

    // Empty → the `#f` spelling, structurally `emptyFalse`.
    var buf_empty: [1]model.HintEntry = undefined;
    const empty = model.Hints.forDirectAddresses("", &buf_empty);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, empty.wire_form);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);

    // The exact bytes a partner verifies the location signature over: the
    // trailing `f` is `#f`, never `{}`.
    const loc_empty: model.PeerLocator = .{ .transport = "keyed-tcp", .designator = "abc", .hints = empty };
    const bytes_empty = try syrup.encodePeerLocatorRecord(allocator, loc_empty);
    defer allocator.free(bytes_empty);
    try std.testing.expectEqualStrings("<10'ocapn-peer9'keyed-tcp3\"abcf>", bytes_empty);

    // Byte-identical to a hand-written `emptyFalse` locator — the helper
    // reproduces the signed spelling exactly, not a lookalike.
    const loc_false: model.PeerLocator = .{ .transport = "keyed-tcp", .designator = "abc", .hints = model.Hints.emptyFalse() };
    const bytes_false = try syrup.encodePeerLocatorRecord(allocator, loc_false);
    defer allocator.free(bytes_false);
    try std.testing.expectEqualStrings(bytes_empty, bytes_false);

    // A present hint rides exactly one `direct-addresses` entry.
    var buf_hint: [1]model.HintEntry = undefined;
    const hinted = model.Hints.forDirectAddresses("1.2.3.4:5", &buf_hint);
    try std.testing.expectEqual(@as(usize, 1), hinted.entries.len);
    try std.testing.expectEqualStrings("direct-addresses", hinted.entries[0].name);
    try std.testing.expectEqualStrings("1.2.3.4:5", hinted.entries[0].value.string);

    const loc_hinted: model.PeerLocator = .{ .transport = "keyed-tcp", .designator = "abc", .hints = hinted };
    const bytes_hinted = try syrup.encodePeerLocatorRecord(allocator, loc_hinted);
    defer allocator.free(bytes_hinted);
    try std.testing.expect(std.mem.indexOf(u8, bytes_hinted, "direct-addresses") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes_hinted, "1.2.3.4:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes_hinted, "{") != null);
}
