const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const syrup = pancake.ocapn.codec.syrup;
const protocol_oracle = @import("../oracle/protocol_oracle.zig");
const handoff_fixtures = @import("../support/handoff_fixtures.zig");

fn expectFixtureBytes(name: []const u8, frame: pancake.foundation.Frame) !void {
    const fixture = protocol_oracle.fixtureByName(name).?;
    try std.testing.expectEqualSlices(u8, fixture.bytes(), frame.bytes());
}

fn repeatedByte(comptime len: usize, byte: u8) [len]u8 {
    return [_]u8{byte} ** len;
}

fn hexToOwned(allocator: std.mem.Allocator, comptime hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
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

    const decoded = try syrup.decodeBody(.{ .bytes = raw_receive, .shape = .byte });
    const handoff = try decoded.handoff.toOwned(allocator);
    defer pancake.ocapn.model.owned.freeHandoff(allocator, handoff);
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
        "<10'ocapn-peer3'tcp9\"127.0.0.1{4\"host9\"127.0.0.15'extra3'bad4\"port5\"52833}>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
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

test "Syrup refuses start-session captp_version ocapn-1.0 as malformed" {
    // Deliberate tightening: `fromWireString` matches only `wireString` spellings
    // (`1.0`, `pancake-next`). The former lenient `ocapn-1.0` alias is gone.
    const frame_bytes: []const u8 =
        "<16'op:start-session8\"ocapn-1.0" ++
        "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA]]]" ++
        "<10'ocapn-peer3'tcp9\"127.0.0.1f>" ++
        "[7'sig-val[5'eddsa[1'r32:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB][1's32:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC]]]>";
    const view = pancake.foundation.FrameView{ .bytes = frame_bytes, .shape = .byte };
    try std.testing.expectError(error.MalformedFrame, syrup.decodeBody(view));
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

test "a Struct argument round-trips through Syrup in canonical key order" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };

    // Two entries built in non-canonical order; canonical encode sorts by the
    // fully-encoded key, so "a" precedes "bb" on the wire regardless of input order.
    const entries = [_]model.StructEntry{
        .{ .key = "bb", .value = .{ .integer = 2 } },
        .{ .key = "a", .value = .{ .string = "x" } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args[0..] } });
    defer frame.deinit();

    // Canonical order puts the shorter-encoded key first: 1"a"… before 2"bb"….
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "{1\"a") != null);

    const decoded = try syrup.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, decoded);
    const decoded_arg = decoded.deliver.args[0];
    try std.testing.expect(decoded_arg == .@"struct");
    try std.testing.expect(model.equality.argumentsEqual(args[0], decoded_arg));
}

test "a Struct with a non-String key is refused" {
    // OCapN Struct keys must be Strings (Model.md § Struct). An integer key
    // (`42+`) is refused at the codec boundary, fail-closed.
    const frame = "<10'op:deliver<11'desc:export7+>[{42+1\"b}]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = frame, .shape = .byte }),
    );
}

test "a Struct with duplicate keys is refused" {
    // Each key must be non-Equal to every other within a Struct. `{"a":"b","a":"c"}`
    // repeats "a" and is refused at decode.
    const frame = "<10'op:deliver<11'desc:export7+>[{1\"a1\"b1\"a1\"c}]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = frame, .shape = .byte }),
    );
}

test "a Struct with keys out of canonical order is refused" {
    // Canonical Syrup orders dictionary entries by the fully-encoded key,
    // lowest octets first (conformance/syrup/upstream/draft-specification.md
    // § Sorting Algorithm), and every encoder pancake faces emits that order:
    // the upstream Racket Syrup encoder Goblins and the fixture generator use
    // (impls/racket/syrup/syrup.rkt), the upstream conformance suite's Python
    // encoder (contrib/syrup.py), and pancake's own writeStruct (ADR-0046).
    // `{1"b…1"a…}` spells the same struct as `{1"a…1"b…}`, so a lenient read
    // would admit two wire spellings of one message, refused like a
    // non-canonical length digit. The ascending-key check is also what refuses
    // duplicates in O(1) per key: a repeated key is never strictly ascending.
    const frame = "<10'op:deliver<11'desc:export7+>[{1\"b2+1\"a1+}]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = frame, .shape = .byte }),
    );
}

test "Struct key order compares the fully-encoded key, not the raw key bytes" {
    // "b" encodes as `1"b` and "aa" as `2"aa`; bytewise `1"b` < `2"aa`, so the
    // canonical wire order is "b" before "aa" even though the raw key bytes
    // sort the other way. The committed fixture corpus is generated by the
    // upstream Racket encoder, which sorts exactly this way
    // (conformance/syrup/upstream/impls/racket/syrup/syrup.rkt: "We sort by
    // the key being fully encoded").
    const canonical = "<10'op:deliver<11'desc:export7+>[{1\"b1+2\"aa2+}]42+f>";
    const body = try syrup.decodeBody(.{ .bytes = canonical, .shape = .byte });
    try std.testing.expect(body == .deliver);
    const arg = try body.deliver.args.at(0);
    try std.testing.expect(arg == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), try arg.@"struct".len());

    const raw_byte_order = "<10'op:deliver<11'desc:export7+>[{2\"aa2+1\"b1+}]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = raw_byte_order, .shape = .byte }),
    );
}

test "Syrup refuses to encode a Struct carrying a duplicate key" {
    // Symmetric refusal (ADR-0003): the decoder rejects a duplicate-key struct as
    // malformed, so the encoder must not emit one, or it would ship a frame the
    // partner rejects with no local signal. A model built with two "a" entries is
    // refused at encode, the same shape a non-canonical big integer is.
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const entries = [_]model.StructEntry{
        .{ .key = "a", .value = .{ .integer = 1 } },
        .{ .key = "a", .value = .{ .integer = 2 } },
    };
    const args = [_]model.Argument{.{ .@"struct" = entries[0..] }};
    try std.testing.expectError(
        syrup.Error.UnsupportedArgument,
        syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args[0..] } }),
    );
}

test "Syrup refuses to encode a Set carrying a duplicate element" {
    // Symmetric refusal (ADR-0003): the decoder rejects a set with a duplicate
    // element, so the encoder must not emit one — otherwise a model with a
    // duplicate-element set would encode locally and pancake's own decoder would
    // reject it. Refused at encode with UnsupportedArgument, like a duplicate key.
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_position = .from(7) } };
    const dup = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 1 } };
    const args = [_]model.Argument{.{ .set = dup[0..] }};
    try std.testing.expectError(
        syrup.Error.UnsupportedArgument,
        syrup.encodeMessage(allocator, .{ .deliver = .{ .target = target, .args = args[0..] } }),
    );
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
    // (`max_collection_elements` in syrup/decode.zig, the width sibling of
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

test "an integer argument outside i64 decodes as a canonical big_integer" {
    // The OCapN Integer is arbitrary-precision (Model.md § Integer). A magnitude
    // one past i64 max / min decodes as the `big_integer` arm carrying the
    // canonical decimal digits, with the sign on the arm, never truncated and
    // never refused.
    const allocator = std.testing.allocator;
    // 9223372036854775808 = 2^63, one past i64 max (max is …807).
    const over_max = "<10'op:deliver<11'desc:export7+>[9223372036854775808+]42+f>";
    const over = try syrup.decodeOwned(allocator, .{ .bytes = over_max, .shape = .byte });
    defer model.freeMessage(allocator, over);
    {
        const arg = over.deliver.args[0];
        try std.testing.expect(arg == .big_integer);
        try std.testing.expect(!arg.big_integer.negative);
        try std.testing.expectEqualStrings("9223372036854775808", arg.big_integer.digits);
    }
    // 9223372036854775809 with a minus is one past i64 min (min is -…808).
    const under_min = "<10'op:deliver<11'desc:export7+>[9223372036854775809-]42+f>";
    const under = try syrup.decodeOwned(allocator, .{ .bytes = under_min, .shape = .byte });
    defer model.freeMessage(allocator, under);
    {
        const arg = under.deliver.args[0];
        try std.testing.expect(arg == .big_integer);
        try std.testing.expect(arg.big_integer.negative);
        try std.testing.expectEqualStrings("9223372036854775809", arg.big_integer.digits);
    }
}

test "the i64 boundary values stay on the integer fast path" {
    // The arm split is canonical: a value representable as i64 — including both
    // exact bounds — decodes as `integer`, so the two arms never spell one
    // arithmetic value and big-integer equality stays bytewise.
    const max_frame = "<10'op:deliver<11'desc:export7+>[9223372036854775807+]42+f>";
    const max_body = try syrup.decodeBody(.{ .bytes = max_frame, .shape = .byte });
    const max_arg = try max_body.deliver.args.at(0);
    try std.testing.expect(max_arg == .integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), max_arg.integer);

    const min_frame = "<10'op:deliver<11'desc:export7+>[9223372036854775808-]42+f>";
    const min_body = try syrup.decodeBody(.{ .bytes = min_frame, .shape = .byte });
    const min_arg = try min_body.deliver.args.at(0);
    try std.testing.expect(min_arg == .integer);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), min_arg.integer);
}

test "a big integer round-trips through encode and non-canonical forms are refused" {
    const allocator = std.testing.allocator;
    // Round-trip: model -> wire -> model, negative sign, magnitude past u64 too.
    const big = model.Argument{
        .big_integer = .{
            .negative = true,
            .digits = "340282366920938463463374607431768211456", // 2^128
        },
    };
    const message = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{big},
        .answer = .from(42),
    } };
    var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, message);
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "340282366920938463463374607431768211456-") != null);
    const round = try syrup.decodeOwned(allocator, frame.view());
    defer model.freeMessage(allocator, round);
    try std.testing.expect(model.argumentsEqual(big, round.deliver.args[0]));

    // A leading zero is non-canonical Syrup whatever the magnitude; refused.
    const padded = "<10'op:deliver<11'desc:export7+>[09223372036854775808+]42+f>";
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeOwned(allocator, .{ .bytes = padded, .shape = .byte }),
    );

    // Encode refuses a hand-built non-canonical value symmetrically (ADR-0003):
    // this magnitude belongs to the `integer` arm, so it never reaches the wire.
    const small = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{.{ .big_integer = .{ .negative = false, .digits = "7" } }},
        .answer = .from(42),
    } };
    try std.testing.expectError(
        syrup.Error.UnsupportedArgument,
        syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, small),
    );
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

test "neutral Args iterator walks the codec backing in one forward pass" {
    const allocator = std.testing.allocator;
    // A multi-arg deliver whose args include a nested list, so the walk exercises
    // both the top-level sequence and a nested backed sub-`Args`.
    const nested = [_]model.Argument{ .{ .integer = 1 }, .{ .integer = 2 } };
    const args = [_]model.Argument{
        .{ .bytes = "hello" },
        .{ .symbol = "sym" },
        .{ .list = nested[0..] },
        .{ .boolean = true },
    };
    const message = model.Message{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = args[0..],
        .answer = .from(42),
    } };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    const body = try syrup.decodeBody(frame.view());
    const decoded_args = body.deliver.args;

    // The forward iterator yields exactly the same sequence as random access,
    // and the same count as `len()` — proving the cursor advances correctly
    // without the per-element re-walk that `at(i)` performs.
    const count = try decoded_args.len();
    try std.testing.expectEqual(@as(usize, 4), count);

    var it = decoded_args.iterator();
    var index: usize = 0;
    while (try it.next()) |arg| : (index += 1) {
        const expected = try decoded_args.at(index);
        try std.testing.expectEqualStrings(@tagName(expected), @tagName(arg));
        switch (arg) {
            .bytes => |b| try std.testing.expectEqualStrings("hello", b),
            .symbol => |s| try std.testing.expectEqualStrings("sym", s),
            .boolean => |v| try std.testing.expect(v),
            .list => |items| {
                var inner = items.iterator();
                var inner_count: usize = 0;
                while (try inner.next()) |inner_arg| : (inner_count += 1) {
                    try std.testing.expectEqual(@as(i64, @intCast(inner_count + 1)), inner_arg.integer);
                }
                try std.testing.expectEqual(@as(usize, 2), inner_count);
            },
            else => return error.TestUnexpectedArgument,
        }
    }
    try std.testing.expectEqual(count, index);
}

test "op:abort fixture decodes as a borrowed view" {
    const frame = pancake.foundation.FrameView{
        .bytes = "<8'op:abort13\"shutting down>",
        .shape = .byte,
    };

    const decoded = try syrup.decodeBody(frame);

    try std.testing.expectEqual(model.AbortKind.other, decoded.abort.kind);
    try std.testing.expectEqualStrings("shutting down", decoded.abort.message);
    try std.testing.expectEqual(@intFromPtr(frame.bytes.ptr) + 14, @intFromPtr(decoded.abort.message.ptr));
}

test "typed op:abort fixture decodes without copying message bytes" {
    const fixture = protocol_oracle.fixtureByName("op_abort_typed.bin").?;
    const frame = pancake.foundation.FrameView{
        .bytes = fixture.bytes(),
        .shape = .byte,
    };

    const decoded = try syrup.decodeBody(frame);

    try std.testing.expectEqual(model.AbortKind.version_mismatch, decoded.abort.kind);
    try std.testing.expectEqualStrings("peer requested 2.0", decoded.abort.message);
}

test "op:abort with an unrecognized label prefix stays other, message verbatim" {
    // The decoder recovers a kind only from labels the model names; a peer's
    // free-form "<Word>: ..." message must not lose its prefix to a label that
    // matches nothing.
    const frame = pancake.foundation.FrameView{
        .bytes = "<8'op:abort14\"Bogus: message>",
        .shape = .byte,
    };

    const decoded = try syrup.decodeBody(frame);

    try std.testing.expectEqual(model.AbortKind.other, decoded.abort.kind);
    try std.testing.expectEqualStrings("Bogus: message", decoded.abort.message);
}

test "decodeBody exposes borrowed GC position lists" {
    {
        const fixture = protocol_oracle.fixtureByName("op_gc_exports.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(usize, 2), try decoded.gc_export.positions.len());
        try std.testing.expectEqual(@as(u64, 3), try decoded.gc_export.positions.at(0));
        try std.testing.expectEqual(@as(u64, 7), try decoded.gc_export.positions.at(1));
        try std.testing.expectEqual(@as(u64, 1), try decoded.gc_export.deltas.at(0));
        try std.testing.expectEqual(@as(u64, 2), try decoded.gc_export.deltas.at(1));
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_gc_answers.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(usize, 2), try decoded.gc_answer.positions.len());
        try std.testing.expectEqual(@as(u64, 11), try decoded.gc_answer.positions.at(0));
        try std.testing.expectEqual(@as(u64, 13), try decoded.gc_answer.positions.at(1));
    }
}

test "decodeBody exposes borrowed views for deliver, get, index, listen, and resolve" {
    // The decoder lifts each payload/target descriptor into the receiver's
    // perspective (ADR-0010 flip): `<desc:export N>` → `.near{export_position=N}` and
    // `<desc:import-object N>` → `.far{import_position=N}`. The fixture-name `_far` /
    // `_near` labels predate the flip and now describe the wire descriptor's
    // historical model arm, not the decoded one.
    {
        const fixture = protocol_oracle.fixtureByName("op_deliver.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.deliver.target.near.export_position.int());
        try std.testing.expectEqual(@as(usize, 1), try decoded.deliver.args.len());
        try std.testing.expectEqualStrings("hello", (try decoded.deliver.args.at(0)).bytes);
        try std.testing.expectEqual(@as(u64, 42), decoded.deliver.answer.?.int());
        try std.testing.expect(decoded.deliver.resolve_me_desc == null);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_get.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.get.receiver.near.export_position.int());
        try std.testing.expectEqualStrings("name", decoded.get.field);
        try std.testing.expectEqual(@as(u64, 11), decoded.get.answer.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_index.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.index.receiver.near.export_position.int());
        try std.testing.expectEqual(@as(i64, 5), decoded.index.index);
        try std.testing.expectEqual(@as(u64, 11), decoded.index.answer.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_untag.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.untag.receiver.near.export_position.int());
        try std.testing.expectEqualStrings("cm", decoded.untag.tag);
        try std.testing.expectEqual(@as(u64, 11), decoded.untag.answer.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_listen_promise_target.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.listen.target.promise.answer_position.int());
        try std.testing.expectEqual(@as(u64, 9), decoded.listen.listener.far.import_position.int());
        try std.testing.expect(!decoded.listen.wants_partial);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_break.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 42), decoded.resolve.answer.int());
        try std.testing.expectEqualStrings("target unreachable", decoded.resolve.resolution.@"break".message);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_far.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.resolve.answer.int());
        // `<desc:export 5>` lifts to `.near` post-flip (fixture name predates it).
        try std.testing.expectEqual(@as(u64, 5), decoded.resolve.resolution.fulfill.reference.near.export_position.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_near.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        // `<desc:import-object 9>` lifts to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), decoded.resolve.resolution.fulfill.reference.far.import_position.int());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_promise.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 11), decoded.resolve.resolution.fulfill.reference.promise.answer_position.int());
    }
}

test "decodeBody exposes borrowed views for start-session and handoff" {
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
        const fixture = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        // A top-level give decodes to the `.give` arm, with `raw_signed`
        // spanning the exact envelope bytes a verifier checks.
        try std.testing.expectEqual(
            @as(usize, fixture.bytes().len),
            decoded.handoff.give.raw_signed.?.len,
        );
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_receive.bin").?;
        const decoded = try syrup.decodeBody(.{ .bytes = fixture.bytes(), .shape = .byte });

        // A receive nests its signed give, whose raw envelope bytes are kept
        // for signature verification.
        try std.testing.expect(decoded.handoff == .receive);
        try std.testing.expect(decoded.handoff.receive.signed_give.raw_signed != null);
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

test "decodeOwned materializes handoff give and receive fixtures" {
    const allocator = std.testing.allocator;

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
        const decoded = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
        defer model.freeHandoff(allocator, decoded.handoff);

        try std.testing.expectEqualStrings(handoff_fixtures.recipient_key[0..], decoded.handoff.give.recipient_key);
        try std.testing.expectEqualStrings("memory", decoded.handoff.give.exporter.transport);
        try std.testing.expectEqualStrings("exporter", decoded.handoff.give.exporter.designator);
        try std.testing.expectEqualStrings(handoff_fixtures.gifter_session[0..], decoded.handoff.give.gifter_exporter_session);
        try std.testing.expectEqualStrings(handoff_fixtures.gifter_side[0..], decoded.handoff.give.gifter_side);
        try std.testing.expectEqualStrings(handoff_fixtures.gift_id[0..], decoded.handoff.give.gift_id);
        try std.testing.expectEqualStrings(handoff_fixtures.give_signature[0..], decoded.handoff.give.signature);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_receive.bin").?;
        const decoded = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
        defer model.freeHandoff(allocator, decoded.handoff);

        try std.testing.expectEqualStrings(handoff_fixtures.receiving_session[0..], decoded.handoff.receive.receiving_session);
        try std.testing.expectEqualStrings(handoff_fixtures.receiving_side[0..], decoded.handoff.receive.receiving_side);
        try std.testing.expectEqual(@as(u64, 1), decoded.handoff.receive.handoff_count);
        try std.testing.expectEqualStrings(handoff_fixtures.recipient_key[0..], decoded.handoff.receive.signed_give.recipient_key);
        try std.testing.expectEqualStrings(handoff_fixtures.receive_signature[0..], decoded.handoff.receive.signature);
    }
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

    // Pin against the pancake-authored reference frame (serialized by the
    // upstream Syrup encoder) rather than a hand-typed duplicate, so the corpus
    // fixture is actually load-bearing.
    try expectFixtureBytes("op_deliver_arg_float64.bin", frame);
}

test "Syrup carries a big integer argument byte-identical to the upstream Racket encoder" {
    const allocator = std.testing.allocator;
    // The fixture is a Racket bignum (2^100) serialized by the upstream Syrup
    // encoder; pancake's `big_integer` arm must produce the same frame, and
    // decode the fixture back to the same model value (ADR-0049).
    const big = model.Argument{ .big_integer = .{
        .negative = false,
        .digits = "1267650600228229401496703205376",
    } };
    const args = [_]model.Argument{big};
    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = args[0..],
        .answer = .from(42),
    } });
    defer frame.deinit();
    try expectFixtureBytes("op_deliver_arg_big_integer.bin", frame);

    const fixture = protocol_oracle.fixtureByName("op_deliver_arg_big_integer.bin").?;
    const round = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
    defer model.freeMessage(allocator, round);
    try std.testing.expect(model.argumentsEqual(big, round.deliver.args[0]));
}

test "Syrup encodes bare primitives byte-for-byte against the upstream Syrup-encoded reference fixtures" {
    const allocator = std.testing.allocator;
    // Each `prim_*.bin` is a bare pancake-authored Syrup value serialized by the
    // upstream Syrup encoder. The
    // pancake encoder only emits whole op-records, so encode each as the sole
    // argument of an `op:deliver` and slice the primitive sub-bytes back out:
    // the framing around the argument list is the fixed prefix and suffix below.
    const prefix = "<10'op:deliver<11'desc:export7+>[";
    const suffix = "]42+f>";
    const cases = .{
        .{ "prim_integer_pos_42.bin", model.Argument{ .integer = 42 } },
        .{ "prim_integer_neg_7.bin", model.Argument{ .integer = -7 } },
        // 2^100 negated: a Racket bignum on the upstream side, pancake's
        // `big_integer` arm on this side (ADR-0049).
        .{ "prim_integer_big_neg.bin", model.Argument{ .big_integer = .{
            .negative = true,
            .digits = "1267650600228229401496703205376",
        } } },
        .{ "prim_string_hello.bin", model.Argument{ .string = "hello" } },
        .{ "prim_list_of_ints.bin", model.Argument{ .list = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } } } },
        .{ "prim_set_of_ints.bin", model.Argument{ .set = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } } } },
        // Racket `(hash "a" 1 "b" 2)` upstream, pancake's Struct arm here,
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

test "Syrup round-trips float64 through decode, including NaN and signed zero" {
    const allocator = std.testing.allocator;
    // `Object.is` bit-fidelity (ADR-0021): a NaN and a -0.0 must survive the wire
    // bit-for-bit, not be normalized. Round-trip each through encode → decodeBody.
    const cases = [_]f64{ 1.5, -0.0, 0.0, 3.141592653589793, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) };
    for (cases) |value| {
        const args = [_]model.Argument{.{ .float64 = value }};
        var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = args[0..],
            .answer = .from(42),
        } });
        defer frame.deinit();

        const body = try syrup.decodeBody(frame.view());
        const decoded = try body.deliver.args.at(0);
        // Compare raw bits so NaN and signed zero are exact, not IEEE `==`.
        try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(decoded.float64)));
    }
}

test "Syrup decode rejects a handoff with an unsupported payload tag" {
    const allocator = std.testing.allocator;
    const original = protocol_oracle.fixtureByName("op_handoff_give.bin").?.bytes();
    const buffer = try allocator.dupe(u8, original);
    defer allocator.free(buffer);

    // Corrupt the payload tag in place, keeping its length so the envelope stays
    // structurally valid. One decode vocabulary: the borrowed view and the owned
    // materializer refuse the unknown payload identically.
    const tag = "desc:handoff-give";
    const idx = std.mem.indexOf(u8, buffer, tag).?;
    buffer[idx + tag.len - 1] = 'X';

    try std.testing.expectError(
        syrup.Error.UnsupportedMessage,
        syrup.decodeBody(.{ .bytes = buffer, .shape = .byte }),
    );
    try std.testing.expectError(
        syrup.Error.UnsupportedMessage,
        syrup.decodeOwned(allocator, .{ .bytes = buffer, .shape = .byte }),
    );
}

test "Syrup decode rejects a truncated handoff envelope" {
    const allocator = std.testing.allocator;
    const original = protocol_oracle.fixtureByName("op_handoff_give.bin").?.bytes();
    const truncated = original[0 .. original.len - 1];

    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeBody(.{ .bytes = truncated, .shape = .byte }),
    );
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeOwned(allocator, .{ .bytes = truncated, .shape = .byte }),
    );
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
            .wants_partial = true,
        } },
        .{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = .from(8) } },
        .{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = -3, .answer = .from(9) } },
        .{ .untag = .{ .receiver = .{ .far = model.FarRef.object(5) }, .tag = "cm", .answer = .from(8) } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &([_]u8{0xab} ** 32) },
            .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
            .acceptable_location_sig = .{ .bytes = &([_]u8{0xcd} ** 64) },
        } },
        .{ .handoff = .{ .give = handoff_fixtures.give() } },
        .{ .handoff = .{ .receive = handoff_fixtures.receive() } },
    };

    for (messages) |message| {
        const profile = if (message == .resolve) model.CaptpVersion.next else model.CaptpVersion.v1_0;
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

test "Syrup typed abort encode matches Goblins prefix fixture" {
    const allocator = std.testing.allocator;
    const message = model.Message{
        .abort = .{ .kind = .version_mismatch, .message = "peer requested 2.0" },
    };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    try expectFixtureBytes("op_abort_typed.bin", frame);
}

test "Syrup encoder matches core Goblins operation fixtures" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .abort = .{ .kind = .other, .message = "shutting down" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .bytes = "hello" }};
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
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
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .gc_export = .{
                .positions = &.{ 3, 7 },
                .deltas = &.{ 1, 2 },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_gc_exports.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
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
                .index = 5,
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
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
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
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .resolve = .{
                .answer = .from(7),
                .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_position = .from(5) } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_far.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .resolve = .{
                .answer = .from(7),
                .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_near.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .resolve = .{
                .answer = .from(7),
                .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(11) } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_promise.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .listen = .{
                .target = .{ .promise = .{ .answer_position = .from(7) } },
                .listener = .{ .near = .{ .export_position = .from(9) } },
                .wants_partial = false,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_promise_target.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.CaptpVersion.next, .{
            .listen = .{
                .target = .{ .far = .{ .import_position = .from(5) } },
                .listener = .{ .near = .{ .export_position = .from(9) } },
                .wants_partial = false,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_export_target.bin", frame);
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
                .wants_partial = false,
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
                .wants_partial = true,
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

test "Syrup encoder matches handoff fixture batch" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .handoff = .{ .give = handoff_fixtures.give() },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_handoff_give.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .handoff = .{ .receive = handoff_fixtures.receive() },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_handoff_receive.bin", frame);
    }

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

// ── Codec-neutral view projection round-trips ────────────────────────────────
//
// Encode → `decodeBody` (neutral view) → `toOwned` → re-encode, asserting the
// bytes survive the round trip. This is the strongest fidelity check: any arm
// the projection drops or mis-shapes diverges on re-encode.

fn expectBodyByteRoundTrip(profile: model.CaptpVersion, message: model.Message) !void {
    const allocator = std.testing.allocator;
    // The codec flips reference perspective on every wire crossing (ADR-0010),
    // so a single encode→decode→encode is NOT byte-stable: a payload `Near`
    // becomes `<desc:import-object>` becomes a decoded `Far`, which re-encodes as
    // `<desc:export>`. Two crossings restore the original perspective (the flip
    // is an involution), so the bytes after the second crossing equal the first
    // encoding, any arm `decodeBody`/`toOwned` drops or mangles diverges.
    //
    // Deliver/get/index/listen targets must therefore be promise-shaped here: a
    // `Far` target decodes to a `Near` target, which the target encoder rejects
    // by design (a `Near` target is a runtime-bug signal, never sent on the
    // wire). Far-receiver *decoding* is covered by the oracle-fixture tests.
    var frame0 = try syrup.encodeMessageForProfile(allocator, profile, message);
    defer frame0.deinit();

    const owned1 = try (try syrup.decodeBody(frame0.view())).toOwned(allocator);
    defer model.freeMessage(allocator, owned1);
    var frame1 = try syrup.encodeMessageForProfile(allocator, profile, owned1);
    defer frame1.deinit();

    const owned2 = try (try syrup.decodeBody(frame1.view())).toOwned(allocator);
    defer model.freeMessage(allocator, owned2);
    var frame2 = try syrup.encodeMessageForProfile(allocator, profile, owned2);
    defer frame2.deinit();

    try std.testing.expectEqualSlices(u8, frame0.bytes(), frame2.bytes());
}

test "neutral view projects every Syrup-encodable argument arm" {
    const nested = [_]model.Argument{ .{ .integer = -3 }, .{ .boolean = false }, .{ .void = {} } };
    const args = [_]model.Argument{
        .{ .bytes = "raw" },
        .{ .symbol = "sym" },
        .{ .string = "str" },
        .{ .integer = 9 },
        .{ .integer = -9 },
        .{ .boolean = true },
        .{ .void = {} },
        .{ .reference = .{ .near = model.NearRef.object(1) } },
        .{ .reference = .{ .far = model.FarRef.object(2) } },
        .{ .list = nested[0..] },
        .{ .set = nested[0..] },
        .{ .tagged = .{ .tag = "rec", .value = nested[0..] } },
        .{ .keyword = "kw" },
    };
    // Promise target: a `Far` target would decode to an un-re-encodable `Near`
    // target (see `expectBodyByteRoundTrip`). Object-kind refs only: the far/
    // import promise-kind is intentionally not on the wire (`Far`→`<desc:export>`
    // drops it), covered separately by the desc:import-promise kind test above.
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .args = args[0..],
        .answer = .from(42),
    } });
}

test "neutral view round-trips deliver with promise target and resolver-callback" {
    const args = [_]model.Argument{ .{ .symbol = "fulfill" }, .{ .reference = .{ .near = model.NearRef.object(3) } } };
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{
        .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(5) } },
            .args = args[0..],
            .answer = .from(8),
            // Object-kind resolver desc: the promise-kind on a decoded `Far` import
            // is not wire-preserved (`Far`→`<desc:export>`), so it would not survive
            // the second crossing, kind preservation is tested via near→far above.
            .resolve_me_desc = .{ .near = model.NearRef.object(4) },
        },
    });
}

test "neutral view round-trips resolve, gc, abort, listen, get, index" {
    try expectBodyByteRoundTrip(model.CaptpVersion.next, .{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(2) } } },
    } });
    try expectBodyByteRoundTrip(model.CaptpVersion.next, .{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .@"break" = .{ .message = "boom" } },
    } });
    const positions = [_]u64{ 5, 6, 7 };
    const deltas = [_]u64{ 1, 1, 2 };
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .gc_export = .{ .positions = positions[0..], .deltas = deltas[0..] } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .gc_answer = .{ .positions = positions[0..] } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .abort = .{ .kind = .protocol_error, .message = "bye" } });
    // Promise targets/receivers: a `Far` target decodes to an un-re-encodable
    // `Near` target (see `expectBodyByteRoundTrip`). Far-receiver decoding for
    // listen/get/index is covered by the oracle-fixture tests.
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(7) } },
        .listener = .{ .near = model.NearRef.object(9) },
        .wants_partial = true,
    } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .get = .{ .receiver = .{ .promise = .{ .answer_position = .from(2) } }, .field = "name", .answer = .from(3) } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .index = .{ .receiver = .{ .promise = .{ .answer_position = .from(2) } }, .index = 5, .answer = .from(4) } });
}

test "neutral view round-trips start_session and handoff (deferred sig/locator joins)" {
    const pubkey = repeatedByte(32, 0xaa);
    const sig = repeatedByte(64, 0xcc);
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = pubkey[0..] },
        .acceptable_location = .{ .transport = "memory", .designator = "exporter" },
        .acceptable_location_sig = .{ .bytes = sig[0..] },
    } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .handoff = .{ .give = handoff_fixtures.give() } });
    try expectBodyByteRoundTrip(model.CaptpVersion.v1_0, .{ .handoff = .{ .receive = handoff_fixtures.receive() } });
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
