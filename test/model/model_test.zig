const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

test "value-tree types stay within their documented size budget" {
    // The owned `Argument`/`Resolution`/`Reference` ceilings are comptime
    // asserts beside the types in `src/ocapn/model/mod.zig`; un-boxing the
    // handoff arm fails the build there, not this test.
    // The borrowed twins get their gate here. `view.Argument` keeps its handoff
    // arm inline — it borrows wire bytes and may not allocate a box — so it is
    // roughly eight times its owned twin, and the inbound set-uniqueness fold
    // parks one per set element (stack for small sets, `recv_scratch` above
    // that). That spend is deliberate, but it must not grow silently: a new
    // field on any record under the handoff arm moves these numbers. Both
    // bounds rose by one pointer (312 → 320, 120 → 128) when `view.HintList`
    // gained its allocation-free borrowed `find` fn pointer, carried under
    // every borrowed locator's hints.
    try std.testing.expect(@sizeOf(model.view.Argument) <= 320);
    try std.testing.expect(@sizeOf(model.view.Reference) <= 128);
}

test "owned argument measurement matches the clone payload shape" {
    const nested = [_]model.Argument{.{ .string = "xy" }};
    const args = [_]model.Argument{
        .{ .bytes = "abc" },
        .{ .list = &nested },
    };
    const expected = args.len * @sizeOf(model.Argument) + "abc".len +
        nested.len * @sizeOf(model.Argument) + "xy".len;
    try std.testing.expectEqual(expected, try model.measureArgumentSliceOwnedBytes(&args));
}

test "owned message measurement counts only heap-carrying listener fields" {
    const message: model.Message = .{ .listen = .{
        .target = .{ .broken = .{ .message = "target" } },
        .listener = .{ .broken = .{ .message = "listener" } },
        .mode = .settling_only,
    } };
    try std.testing.expectEqual(
        @sizeOf(model.Message) + "target".len + "listener".len,
        try model.measureMessageOwnedBytes(message),
    );
}

test "owned message measurement counts a big integer index payload" {
    const message: model.Message = .{ .index = .{
        .receiver = .{ .near = model.NearRef.object(7) },
        .index = .{ .big_integer = .{ .negative = false, .digits = "12345678901234567890" } },
        .answer = .from(11),
    } };
    try std.testing.expectEqual(
        @sizeOf(model.Message) + "12345678901234567890".len,
        try model.measureMessageOwnedBytes(message),
    );
}

test "CapTP versions parse and render wire strings" {
    try std.testing.expectEqualStrings("1.0", model.CaptpVersion.v1_0.wireString());
    try std.testing.expectEqualStrings("pancake-next", model.CaptpVersion.next.wireString());

    try std.testing.expectEqual(model.CaptpVersion.v1_0, model.CaptpVersion.fromWireString("1.0").?);
    try std.testing.expectEqual(model.CaptpVersion.next, model.CaptpVersion.fromWireString("pancake-next").?);
    try std.testing.expectEqual(@as(?model.CaptpVersion, null), model.CaptpVersion.fromWireString("ocapn-1.0"));
    try std.testing.expectEqual(@as(?model.CaptpVersion, null), model.CaptpVersion.fromWireString("2.0"));
}

test "CaptpVersion diagnostic names" {
    try std.testing.expectEqualStrings("ocapn-v1.0", model.CaptpVersion.v1_0.name());
    try std.testing.expectEqualStrings("pancake-next", model.CaptpVersion.next.name());
}

test "abort kinds round-trip every variant through their wire names" {
    const expected = [_]struct { model.AbortKind, []const u8 }{
        .{ .normal_shutdown, "NormalShutdown" },
        .{ .version_mismatch, "VersionMismatch" },
        .{ .protocol_error, "ProtocolError" },
        .{ .timeout, "Timeout" },
        .{ .unauthorized, "Unauthorized" },
        .{ .invalid_handoff_signature, "InvalidHandoffSignature" },
        .{ .handoff_replay, "HandoffReplay" },
        .{ .queue_cap_exceeded, "QueueCapExceeded" },
        .{ .pipelining_not_negotiated, "PipeliningNotNegotiated" },
        .{ .wire_delta_not_negotiated, "WireDeltaNotNegotiated" },
        .{ .handoffs_not_negotiated, "HandoffsNotNegotiated" },
        .{ .sturdyrefs_not_negotiated, "SturdyrefsNotNegotiated" },
        .{ .invalid_start_session_signature, "InvalidStartSessionSignature" },
        .{ .crossed_hellos, "CrossedHellos" },
        .{ .connection_lost, "ConnectionLost" },
        .{ .graceful_shutdown, "GracefulShutdown" },
        .{ .malformed_frame, "MalformedFrame" },
        .{ .resource_exhausted, "ResourceExhausted" },
        .{ .other, "Other" },
    };

    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry[1], entry[0].wireName());
        try std.testing.expectEqual(entry[0], model.AbortKind.fromWireName(entry[1]).?);
    }
}

test "reserved-band sums classify exactly at their base (ADR-0091)" {
    // `classify` is the one seam where an integer becomes a name, so the band
    // boundary lives here and nowhere else. Both spaces share the contract:
    // strictly below the base is the partner's, at and above is this node's.
    try std.testing.expect(model.ImportName.classify(model.REDEEMED_TOKEN_BASE - 1) == .wire);
    try std.testing.expect(model.ImportName.classify(model.REDEEMED_TOKEN_BASE) == .token);
    try std.testing.expect(model.AnswerName.classify(model.VIRTUAL_INBOUND_ANSWER_BASE - 1) == .wire);
    try std.testing.expect(model.AnswerName.classify(model.VIRTUAL_INBOUND_ANSWER_BASE) == .virtual);
    // The named crossings preserve the integer: a token lowered to the wire and
    // a virtual answer seated in the answer table keep their identity.
    const token = model.ImportName.classify(model.REDEEMED_TOKEN_BASE).token;
    try std.testing.expectEqual(model.REDEEMED_TOKEN_BASE, token.wirePosition().int());
    const virtual = model.AnswerName.classify(model.VIRTUAL_INBOUND_ANSWER_BASE).virtual;
    try std.testing.expectEqual(model.VIRTUAL_INBOUND_ANSWER_BASE, virtual.answerPosition().int());
}

test "near and far ref constructors set the wire-tag kind discriminant" {
    try std.testing.expectEqual(model.RefKind.object, model.NearRef.object(1).kind);
    try std.testing.expectEqual(model.RefKind.promise, model.NearRef.promise(1).kind);
    try std.testing.expectEqual(model.RefKind.object, model.FarRef.object(2).kind);
    try std.testing.expectEqual(model.RefKind.promise, model.FarRef.promise(2).kind);
}

test "protocol model arms map one-to-one onto Zig Message tags" {
    const oracle = @import("../oracle/protocol_oracle.zig");

    // Truth derives from the `model.Message` union itself, not from a second
    // hand list: a new union arm fails here until `message_kinds` carries its
    // row, and a kinds row fails until the oracle registry carries its arm,
    // so new protocol vocabulary cannot land without oracle pressure.
    const fields = @typeInfo(model.Message).@"union".fields;
    try std.testing.expectEqual(fields.len, model.message_kinds.len);
    try std.testing.expectEqual(fields.len, oracle.message_arms.len);
    inline for (fields, 0..) |field, i| {
        if (comptime (i < model.message_kinds.len and i < oracle.message_arms.len)) {
            try std.testing.expectEqualStrings(field.name, model.message_kinds[i].tag_name);
            try std.testing.expectEqualStrings(model.message_kinds[i].model_name, oracle.message_arms[i].name);
        }
    }
}
