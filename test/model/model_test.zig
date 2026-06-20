const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;

test "value-tree types stay within their documented size budget" {
    // The handoff arm of `Argument`/`Resolution` is boxed (`*Handoff`) precisely
    // so the common arm sets the struct size; un-boxing it would balloon every
    // element of a deliver's args (the memory rule's load-bearing-allocations
    // budget). These bounds turn that budget into a gate, a regression here is
    // the bench's printed `model_layout` numbers drifting silently.
    try std.testing.expect(@sizeOf(model.Argument) <= 88);
    try std.testing.expect(@sizeOf(model.Resolution) <= 96);
    try std.testing.expect(@sizeOf(model.Reference) <= 80);
}

test "CapTP versions parse and render wire strings" {
    try std.testing.expectEqualStrings("1.0", model.CaptpVersion.v1_0.wireString());
    try std.testing.expectEqualStrings("pancake-pre-spec", model.CaptpVersion.pre_spec.wireString());

    try std.testing.expectEqual(model.CaptpVersion.v1_0, model.CaptpVersion.fromWireString("1.0").?);
    try std.testing.expectEqual(model.CaptpVersion.v1_0, model.CaptpVersion.fromWireString("ocapn-1.0").?);
    try std.testing.expectEqual(model.CaptpVersion.pre_spec, model.CaptpVersion.fromWireString("pancake-pre-spec").?);
    try std.testing.expectEqual(@as(?model.CaptpVersion, null), model.CaptpVersion.fromWireString("2.0"));
}

test "wire profile constants carry only protocol profile semantics" {
    try std.testing.expect(!@hasField(model.WireProfile, "flags"));

    const v1_0 = model.WireProfile.v1_0;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, v1_0.captp_version);
    try std.testing.expectEqualStrings("ocapn-v1.0", v1_0.name());

    const pre_spec = model.WireProfile.pre_spec;
    try std.testing.expectEqual(model.CaptpVersion.pre_spec, pre_spec.captp_version);
    try std.testing.expectEqualStrings("pancake-pre-spec", pre_spec.name());
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
