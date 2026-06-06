const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const syrup = pancake.codec.syrup;
const protocol_oracle = @import("../oracle/protocol_oracle.zig");

fn expectFixtureBytes(name: []const u8, frame: pancake.foundation.Frame) !void {
    const fixture = protocol_oracle.fixtureByName(name).?;
    try std.testing.expectEqualSlices(u8, fixture.bytes(), frame.bytes());
}

fn repeatedByte(comptime len: usize, byte: u8) [len]u8 {
    return [_]u8{byte} ** len;
}

const fixture_recipient_key = repeatedByte(32, 0x42);
const fixture_gifter_session = repeatedByte(32, 0xcc);
const fixture_gifter_side = repeatedByte(32, 0x11);
const fixture_gift_id = repeatedByte(32, 0x01);
const fixture_give_signature = repeatedByte(64, 0xaa);
const fixture_receiving_session = repeatedByte(32, 0xdd);
const fixture_receiving_side = repeatedByte(32, 0x22);
const fixture_receive_signature = repeatedByte(64, 0xbb);

test "Syrup exposes codec descriptor and admitted messages by profile" {
    const descriptor = syrup.descriptor;

    try std.testing.expectEqualStrings("syrup", descriptor.name);
    try std.testing.expectEqual(pancake.foundation.FrameShape.byte, descriptor.frame_shape);
    try std.testing.expect(descriptor.supportsProfile(model.WireProfile.pre_spec));
    try std.testing.expect(descriptor.supportsProfile(model.WireProfile.v1_0));
    try std.testing.expect(!descriptor.supportsProfile(.{ .captp_version = .v1_0 }));

    const pre_spec = descriptor.admittedMessages(model.WireProfile.pre_spec);
    try std.testing.expect(syrup.admits(pre_spec, .deliver));
    try std.testing.expect(syrup.admits(pre_spec, .resolve));
    try std.testing.expect(!syrup.admits(pre_spec, .start_session));

    const v1_0 = descriptor.admittedMessages(model.WireProfile.v1_0);
    try std.testing.expect(syrup.admits(v1_0, .start_session));
    try std.testing.expect(syrup.admits(v1_0, .handoff));
}

test "Syrup locator encoding uses typed locator and preserves empty false hints" {
    const allocator = std.testing.allocator;
    const pubkey = repeatedByte(32, 0xaa);
    const sig = repeatedByte(64, 0xcc);

    var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
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

    const decoded = try syrup.decodeView(frame.view());
    try std.testing.expect(decoded.start_session.acceptable_location.hints.empty_wire_was_false);
}

fn fixtureGive() model.HandoffGive {
    return .{
        .recipient_key = fixture_recipient_key[0..],
        .exporter_location = "memory:exporter",
        .gifter_exporter_session = fixture_gifter_session[0..],
        .gifter_side = fixture_gifter_side[0..],
        .gift_id = fixture_gift_id[0..],
        .signature = fixture_give_signature[0..],
    };
}

fn fixtureReceive() model.HandoffReceive {
    return .{
        .receiving_session = fixture_receiving_session[0..],
        .receiving_side = fixture_receiving_side[0..],
        .handoff_count = 1,
        .signed_give = fixtureGive(),
        .signature = fixture_receive_signature[0..],
    };
}

fn freeTestHandoff(allocator: std.mem.Allocator, handoff: model.Handoff) void {
    switch (handoff) {
        .give => |give| freeTestHandoffGive(allocator, give),
        .receive => |receive| {
            allocator.free(receive.receiving_session);
            allocator.free(receive.receiving_side);
            freeTestHandoffGive(allocator, receive.signed_give);
            allocator.free(receive.signature);
        },
    }
}

fn freeTestHandoffGive(allocator: std.mem.Allocator, give: model.HandoffGive) void {
    allocator.free(give.recipient_key);
    allocator.free(give.exporter_location);
    allocator.free(give.gifter_exporter_session);
    allocator.free(give.gifter_side);
    allocator.free(give.gift_id);
    allocator.free(give.signature);
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

test "op:abort with a typed kind encodes the wire label prefix" {
    const allocator = std.testing.allocator;
    const message = model.Message{
        .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" },
    };

    var frame = try syrup.encodeMessage(allocator, message);
    defer frame.deinit();

    // The encoder derives the label from the kind discriminant (kind.wireName())
    // and builds "<label>: <message>" at encode time — general across kinds and
    // symmetric with parseV1_0, with no per-message special case.
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "VersionMismatch: expected ocapn-1.0") != null);
}

test "minimal op:deliver encodes to the PreSpec Syrup byte shape" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_id = 7 } };
    const args = [_]model.Argument{.{ .bytes = "hello" }};
    const message = model.Message{
        .deliver = .{
            .target = target,
            .args = args[0..],
            .answer = 42,
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
    const target = model.Reference{ .far = .{ .import_id = 7 } };

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
    // order the model held the set in — the encode-side partner of the
    // order-agnostic set equality in model.equality.
    try std.testing.expectEqualSlices(u8, frame_a.bytes(), frame_b.bytes());

    // The items come out sorted by their encoded bytes (1, 2, 3), not insertion order.
    try std.testing.expect(std.mem.indexOf(u8, frame_a.bytes(), "#1+2+3+$") != null);
}

test "Syrup encodes an empty Set as the bare #$ markers and the neutral decode accepts it" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_id = 7 } };
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

test "Syrup canonicalizes nested Sets recursively, not just the outer one" {
    const allocator = std.testing.allocator;
    const target = model.Reference{ .far = .{ .import_id = 7 } };

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
    const target = model.Reference{ .far = .{ .import_id = 7 } };
    const args = [_]model.Argument{.{ .bytes = "hello" }};
    const message = model.Message{ .deliver = .{ .target = target, .args = args[0..], .answer = null } };

    // A one-way (no-answer) send is a single op:deliver with a #f answer position
    // on every profile, including the Goblins-canonical V1.0 one. OCapN 1.0 has no
    // separate one-way record.
    var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, message);
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "op:deliver-only") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "op:deliver") != null);

    // It round-trips to a deliver with no answer — the shape the engine and
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
        .target = .{ .far = .{ .import_id = 7 } },
        .args = args[0..],
        .answer = 42,
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

    const decoded = try syrup.decodeView(frame);

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

    const decoded = try syrup.decodeView(frame);

    try std.testing.expectEqual(model.AbortKind.version_mismatch, decoded.abort.kind);
    try std.testing.expectEqualStrings("peer requested 2.0", decoded.abort.message);
}

test "decodeView exposes borrowed GC position lists" {
    {
        const fixture = protocol_oracle.fixtureByName("op_gc_exports.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(usize, 2), try decoded.gc_export.positions.count());
        try std.testing.expectEqual(@as(u64, 3), try decoded.gc_export.positions.at(0));
        try std.testing.expectEqual(@as(u64, 7), try decoded.gc_export.positions.at(1));
        try std.testing.expectEqual(@as(u64, 1), try decoded.gc_export.deltas.at(0));
        try std.testing.expectEqual(@as(u64, 2), try decoded.gc_export.deltas.at(1));
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_gc_answers.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(usize, 2), try decoded.gc_answer.positions.count());
        try std.testing.expectEqual(@as(u64, 11), try decoded.gc_answer.positions.at(0));
        try std.testing.expectEqual(@as(u64, 13), try decoded.gc_answer.positions.at(1));
    }
}

test "decodeView exposes borrowed views for deliver, get, index, listen, and resolve" {
    // The decoder lifts each payload/target descriptor into the receiver's
    // perspective (ADR-0010 flip): `<desc:export N>` → `.near{export_id=N}` and
    // `<desc:import-object N>` → `.far{import_id=N}`. The fixture-name `_far` /
    // `_near` labels predate the flip and now describe the wire descriptor's
    // historical model arm, not the decoded one.
    {
        const fixture = protocol_oracle.fixtureByName("op_deliver.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.deliver.target.near.export_id);
        try std.testing.expectEqual(@as(usize, 1), try decoded.deliver.args.count());
        try std.testing.expectEqualStrings("hello", (try decoded.deliver.args.at(0)).bytes);
        try std.testing.expectEqual(@as(u64, 42), decoded.deliver.answer.?);
        try std.testing.expect(decoded.deliver.resolve_me_desc == null);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_get.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.get.receiver.near.export_id);
        try std.testing.expectEqualStrings("name", decoded.get.field);
        try std.testing.expectEqual(@as(u64, 11), decoded.get.answer);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_index.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.index.receiver.near.export_id);
        try std.testing.expectEqual(@as(i64, 5), decoded.index.index);
        try std.testing.expectEqual(@as(u64, 11), decoded.index.answer);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_listen_promise_target.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.listen.target.promise.answer_id);
        try std.testing.expectEqual(@as(u64, 9), decoded.listen.listener.far.import_id);
        try std.testing.expect(!decoded.listen.wants_partial);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_break.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 42), decoded.resolve.answer);
        try std.testing.expectEqualStrings("target unreachable", decoded.resolve.resolution.break_.message);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_far.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 7), decoded.resolve.answer);
        // `<desc:export 5>` lifts to `.near` post-flip (fixture name predates it).
        try std.testing.expectEqual(@as(u64, 5), decoded.resolve.resolution.fulfill.reference.near.export_id);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_near.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        // `<desc:import-object 9>` lifts to `.far` post-flip.
        try std.testing.expectEqual(@as(u64, 9), decoded.resolve.resolution.fulfill.reference.far.import_id);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_resolve_fulfill_promise.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(@as(u64, 11), decoded.resolve.resolution.fulfill.reference.promise.answer_id);
    }
}

test "decodeView exposes borrowed views for start-session and handoff" {
    {
        const fixture = protocol_oracle.fixtureByName("op_start_session_v1_0.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqual(model.CaptpVersion.v1_0, decoded.start_session.captp_version);
        try std.testing.expectEqual(@as(usize, 32), decoded.start_session.session_pubkey.bytes.len);
        try std.testing.expectEqualStrings("memory", decoded.start_session.acceptable_location.transport);
        try std.testing.expectEqualStrings("exporter", decoded.start_session.acceptable_location.designator);
        try std.testing.expectEqual(@as(usize, 64), decoded.start_session.acceptable_location_sig.len());
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqualStrings("desc:sig-envelope", decoded.handoff.envelope_tag);
        try std.testing.expectEqualStrings("desc:handoff-give", decoded.handoff.payload_tag);
        try std.testing.expectEqual(@as(usize, fixture.bytes().len), decoded.handoff.bytes.len);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_receive.bin").?;
        const decoded = try syrup.decodeView(.{ .bytes = fixture.bytes(), .shape = .byte });

        try std.testing.expectEqualStrings("desc:sig-envelope", decoded.handoff.envelope_tag);
        try std.testing.expectEqualStrings("desc:handoff-receive", decoded.handoff.payload_tag);
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

test "decodeOwned materializes handoff give and receive fixtures" {
    const allocator = std.testing.allocator;

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
        const decoded = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
        defer freeTestHandoff(allocator, decoded.handoff);

        try std.testing.expectEqualStrings(fixture_recipient_key[0..], decoded.handoff.give.recipient_key);
        try std.testing.expectEqualStrings("memory:exporter", decoded.handoff.give.exporter_location);
        try std.testing.expectEqualStrings(fixture_gifter_session[0..], decoded.handoff.give.gifter_exporter_session);
        try std.testing.expectEqualStrings(fixture_gifter_side[0..], decoded.handoff.give.gifter_side);
        try std.testing.expectEqualStrings(fixture_gift_id[0..], decoded.handoff.give.gift_id);
        try std.testing.expectEqualStrings(fixture_give_signature[0..], decoded.handoff.give.signature);
    }

    {
        const fixture = protocol_oracle.fixtureByName("op_handoff_receive.bin").?;
        const decoded = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
        defer freeTestHandoff(allocator, decoded.handoff);

        try std.testing.expectEqualStrings(fixture_receiving_session[0..], decoded.handoff.receive.receiving_session);
        try std.testing.expectEqualStrings(fixture_receiving_side[0..], decoded.handoff.receive.receiving_side);
        try std.testing.expectEqual(@as(u64, 1), decoded.handoff.receive.handoff_count);
        try std.testing.expectEqualStrings(fixture_recipient_key[0..], decoded.handoff.receive.signed_give.recipient_key);
        try std.testing.expectEqualStrings(fixture_receive_signature[0..], decoded.handoff.receive.signature);
    }
}

test "Syrup decode rejects non-byte frame shape" {
    const frame = pancake.foundation.FrameView{
        .bytes = "<8'op:abort13\"shutting down>",
        .shape = .word,
    };

    try std.testing.expectError(syrup.Error.InvalidFrameShape, syrup.decodeView(frame));
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
        .{ .bytes = "<10'op:deliver<11'desc:export7+>[<7'unknown>]11+f>", .expected = syrup.Error.UnsupportedArgument },
        .{ .bytes = "<8'op:abort3\"bye>trailing", .expected = syrup.Error.MalformedFrame },
        .{ .bytes = "<13'op:gc-answers[11+13+>", .expected = syrup.Error.MalformedFrame },
    };

    for (cases) |bytes| {
        try std.testing.expectError(
            bytes.expected,
            syrup.decodeView(.{ .bytes = bytes.bytes, .shape = .byte }),
        );
    }
}

test "Syrup encodes float64 as the canonical 'D' + big-endian binary64 wire shape" {
    const allocator = std.testing.allocator;
    // Syrup renders a double as `'D'` then 8 bytes IEEE-754 big-endian. 1.5 is
    // 0x3FF8000000000000, so the frame pins the exact spec bytes — the wire
    // contract a Goblins peer emitting a float over Syrup expects.
    const args = [_]model.Argument{.{ .float64 = 1.5 }};
    var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = .{ .import_id = 7 } },
        .args = args[0..],
        .answer = 42,
    } });
    defer frame.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "<10'op:deliver<11'desc:export7+>[D\x3f\xf8\x00\x00\x00\x00\x00\x00]42+f>",
        frame.bytes(),
    );
}

test "Syrup round-trips float64 through decode, including NaN and signed zero" {
    const allocator = std.testing.allocator;
    // `Object.is` bit-fidelity (ADR-0027): a NaN and a -0.0 must survive the wire
    // bit-for-bit, not be normalized. Round-trip each through encode → decodeBody.
    const cases = [_]f64{ 1.5, -0.0, 0.0, 3.141592653589793, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) };
    for (cases) |value| {
        const args = [_]model.Argument{.{ .float64 = value }};
        var frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
            .target = .{ .far = .{ .import_id = 7 } },
            .args = args[0..],
            .answer = 42,
        } });
        defer frame.deinit();

        const body = try syrup.decodeBody(frame.view());
        const decoded = try body.deliver.args.at(0);
        // Compare raw bits so NaN and signed zero are exact, not IEEE `==`.
        try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(decoded.float64)));
    }
}

test "Syrup decodeOwned rejects a handoff with an unsupported payload tag" {
    const allocator = std.testing.allocator;
    const original = protocol_oracle.fixtureByName("op_handoff_give.bin").?.bytes();
    const buffer = try allocator.dupe(u8, original);
    defer allocator.free(buffer);

    // Corrupt the payload tag in place, keeping its length so the envelope stays
    // structurally valid: decodeView accepts it, but the handoff materializer
    // must refuse an unknown payload.
    const tag = "desc:handoff-give";
    const idx = std.mem.indexOf(u8, buffer, tag).?;
    buffer[idx + tag.len - 1] = 'X';

    _ = try syrup.decodeView(.{ .bytes = buffer, .shape = .byte });
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
        syrup.decodeView(.{ .bytes = truncated, .shape = .byte }),
    );
    try std.testing.expectError(
        syrup.Error.MalformedFrame,
        syrup.decodeOwned(allocator, .{ .bytes = truncated, .shape = .byte }),
    );
}

// The Syrup owned decoder is the second attacker-facing surface. Like the
// Cap'n Proto fuzz, this corrupts every byte of representative frames and
// asserts `decodeOwned` stays total — a typed error or a well-formed message,
// never a panic, a leak, or a double-free. It exercises the multi-allocation
// arms whose partial-failure cleanup is easy to get wrong: gc-export's two
// parallel lists, start-session, and both handoff envelopes.
test "Syrup: corrupting any byte of a frame stays total: typed error or message, never a panic" {
    const allocator = std.testing.allocator;
    var handoff_arg = model.Handoff{ .give = fixtureGive() };

    const messages = [_]model.Message{
        .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(4) },
            .args = &.{
                .{ .bytes = &.{ 1, 2, 3 } },
                .{ .reference = .{ .far = model.FarRef.promise(2) } },
                .{ .handoff = &handoff_arg },
            },
            .answer = 7,
        } },
        .{ .resolve = .{ .answer = 9, .resolution = .{ .break_ = .{ .message = "boom" } } } },
        .{ .resolve = .{ .answer = 2, .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(6) } } } } },
        .{ .gc_export = .{ .positions = &.{ 2, 5, 8 }, .deltas = &.{ 1, 1, 3 } } },
        .{ .gc_answer = .{ .positions = &.{ 1, 4, 9 } } },
        .{ .abort = .{ .kind = .version_mismatch, .message = "expected ocapn-1.0" } },
        .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(1) },
            .listener = .{ .far = model.FarRef.object(2) },
            .wants_partial = true,
        } },
        .{ .get = .{ .receiver = .{ .far = model.FarRef.object(5) }, .field = "value", .answer = 8 } },
        .{ .index = .{ .receiver = .{ .far = model.FarRef.object(6) }, .index = -3, .answer = 9 } },
        .{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &([_]u8{0xab} ** 32) },
            .acceptable_location = .{ .transport = "tcp", .designator = "1.2.3.4:5" },
            .acceptable_location_sig = .{ .bytes = &([_]u8{0xcd} ** 64) },
        } },
        .{ .handoff = .{ .give = fixtureGive() } },
        .{ .handoff = .{ .receive = fixtureReceive() } },
    };

    for (messages) |message| {
        var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, message);
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
        var frame = try syrup.encodeMessage(allocator, .{
            .abort = .{ .kind = .other, .message = "shutting down" },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_abort.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .bytes = "hello" }};
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_id = 7 } },
                .args = args[0..],
                .answer = 42,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .gc_export = .{
                .positions = &.{ 3, 7 },
                .deltas = &.{ 1, 2 },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_gc_exports.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .gc_answer = .{ .positions = &.{ 11, 13 } },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_gc_answers.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .get = .{
                .receiver = .{ .far = .{ .import_id = 7 } },
                .field = "name",
                .answer = 11,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_get.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .index = .{
                .receiver = .{ .far = .{ .import_id = 7 } },
                .index = 5,
                .answer = 11,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_index.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .resolve = .{
                .answer = 42,
                .resolution = .{ .break_ = .{ .message = "target unreachable" } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_break.bin", frame);
    }
}

test "Syrup encoder matches reference and rich argument fixtures" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .resolve = .{
                .answer = 7,
                .resolution = .{ .fulfill = .{ .reference = .{ .far = .{ .import_id = 5 } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_far.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .resolve = .{
                .answer = 7,
                .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_id = 9 } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_near.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .resolve = .{
                .answer = 7,
                .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_id = 11 } } } },
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_resolve_fulfill_promise.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .listen = .{
                .target = .{ .promise = .{ .answer_id = 7 } },
                .listener = .{ .near = .{ .export_id = 9 } },
                .wants_partial = false,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_promise_target.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .listen = .{
                .target = .{ .far = .{ .import_id = 5 } },
                .listener = .{ .near = .{ .export_id = 9 } },
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
                .target = .{ .far = .{ .import_id = 7 } },
                .args = args[0..],
                .answer = 42,
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
                .target = .{ .far = .{ .import_id = 7 } },
                .args = args[0..],
                .answer = 42,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_deliver_arg_tagged.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .keyword = "name" }};
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_id = 7 } },
                .args = args[0..],
                .answer = 42,
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
                .target = .{ .far = .{ .import_id = 7 } },
                .args = args[0..],
                .answer = 42,
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
        var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
            .listen = .{
                .target = .{ .promise = .{ .answer_id = 7 } },
                .listener = .{ .near = .{ .export_id = 9 } },
                .wants_partial = false,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_v1_0_wants_partial_false.bin", frame);
    }

    {
        var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
            .listen = .{
                .target = .{ .promise = .{ .answer_id = 7 } },
                .listener = .{ .near = .{ .export_id = 9 } },
                .wants_partial = true,
            },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_listen_v1_0_wants_partial_true.bin", frame);
    }

    {
        const args = [_]model.Argument{.{ .bytes = "hello" }};
        var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
            .deliver = .{
                .target = .{ .far = .{ .import_id = 7 } },
                .args = args[0..],
                .answer = 42,
                .resolve_me_desc = .{ .near = .{ .export_id = 99 } },
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

    var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
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
            .handoff = .{ .give = fixtureGive() },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_handoff_give.bin", frame);
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .handoff = .{ .receive = fixtureReceive() },
        });
        defer frame.deinit();
        try expectFixtureBytes("op_handoff_receive.bin", frame);
    }

    {
        var handoff_arg = model.Handoff{ .receive = fixtureReceive() };
        const args = [_]model.Argument{
            .{ .symbol = "withdraw-gift" },
            .{ .handoff = &handoff_arg },
        };
        var frame = try syrup.encodeMessage(allocator, .{
            .deliver = .{
                .target = .{ .far = .{ .import_id = 0 } },
                .args = args[0..],
                .answer = 99,
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
    var frame = try syrup.encodeMessageForProfile(allocator, model.WireProfile.v1_0, .{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 1 } },
            .args = args[0..],
            .answer = null,
        },
    });
    defer frame.deinit();

    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "desc:import-promise") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "desc:import-object") == null);

    // A sender's promise-shaped `Near` export encodes `<desc:import-promise>` and
    // decodes on the receiver as a promise-shaped `Far` import (ADR-0010 flip);
    // the object/promise kind rides the wire tag and survives into `ImportKind`.
    const decoded = try syrup.decodeOwned(allocator, frame.view());
    defer allocator.free(decoded.deliver.args);
    try std.testing.expectEqual(model.ImportKind.promise, decoded.deliver.args[0].reference.far.kind);
    try std.testing.expectEqual(@as(u64, 7), decoded.deliver.args[0].reference.far.import_id);
}

// ── Codec-neutral view projection round-trips ────────────────────────────────
//
// Encode → `decodeBody` (neutral view) → `toOwned` → re-encode, asserting the
// bytes survive the round trip. This is the strongest fidelity check: any arm
// the projection drops or mis-shapes diverges on re-encode.

fn expectBodyByteRoundTrip(profile: model.WireProfile, message: model.Message) !void {
    const allocator = std.testing.allocator;
    // The codec flips reference perspective on every wire crossing (ADR-0010),
    // so a single encode→decode→encode is NOT byte-stable: a payload `Near`
    // becomes `<desc:import-object>` becomes a decoded `Far`, which re-encodes as
    // `<desc:export>`. Two crossings restore the original perspective (the flip
    // is an involution), so the bytes after the second crossing equal the first
    // encoding — any arm `decodeBody`/`toOwned` drops or mangles diverges.
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
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_id = 7 } },
        .args = args[0..],
        .answer = 42,
    } });
}

test "neutral view round-trips deliver with promise target and resolver-callback" {
    const args = [_]model.Argument{ .{ .symbol = "fulfill" }, .{ .reference = .{ .near = model.NearRef.object(3) } } };
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{
        .deliver = .{
            .target = .{ .promise = .{ .answer_id = 5 } },
            .args = args[0..],
            .answer = 8,
            // Object-kind resolver desc: the promise-kind on a decoded `Far` import
            // is not wire-preserved (`Far`→`<desc:export>`), so it would not survive
            // the second crossing — kind preservation is tested via near→far above.
            .resolve_me_desc = .{ .near = model.NearRef.object(4) },
        },
    });
}

test "neutral view round-trips resolve, gc, abort, listen, get, index" {
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .resolve = .{
        .answer = 1,
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(2) } } },
    } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .resolve = .{
        .answer = 1,
        .resolution = .{ .break_ = .{ .message = "boom" } },
    } });
    const positions = [_]u64{ 5, 6, 7 };
    const deltas = [_]u64{ 1, 1, 2 };
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .gc_export = .{ .positions = positions[0..], .deltas = deltas[0..] } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .gc_answer = .{ .positions = positions[0..] } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .abort = .{ .kind = .protocol_error, .message = "bye" } });
    // Promise targets/receivers: a `Far` target decodes to an un-re-encodable
    // `Near` target (see `expectBodyByteRoundTrip`). Far-receiver decoding for
    // listen/get/index is covered by the oracle-fixture tests.
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .listen = .{
        .target = .{ .promise = .{ .answer_id = 7 } },
        .listener = .{ .near = model.NearRef.object(9) },
        .wants_partial = true,
    } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .get = .{ .receiver = .{ .promise = .{ .answer_id = 2 } }, .field = "name", .answer = 3 } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .index = .{ .receiver = .{ .promise = .{ .answer_id = 2 } }, .index = 5, .answer = 4 } });
}

test "neutral view round-trips start_session and handoff (deferred sig/locator joins)" {
    const pubkey = repeatedByte(32, 0xaa);
    const sig = repeatedByte(64, 0xcc);
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = pubkey[0..] },
        .acceptable_location = .{ .transport = "memory", .designator = "exporter" },
        .acceptable_location_sig = .{ .bytes = sig[0..] },
    } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .handoff = .{ .give = fixtureGive() } });
    try expectBodyByteRoundTrip(model.WireProfile.v1_0, .{ .handoff = .{ .receive = fixtureReceive() } });
}
