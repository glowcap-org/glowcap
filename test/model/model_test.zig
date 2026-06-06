const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;

test "CapTP versions parse and render wire strings" {
    try std.testing.expectEqualStrings("1.0", model.CaptpVersion.v1_0.wireString());
    try std.testing.expectEqualStrings("pancake-pre-spec", model.CaptpVersion.pre_spec.wireString());

    try std.testing.expectEqual(model.CaptpVersion.v1_0, model.CaptpVersion.fromWireString("1.0").?);
    try std.testing.expectEqual(model.CaptpVersion.v1_0, model.CaptpVersion.fromWireString("ocapn-1.0").?);
    try std.testing.expectEqual(model.CaptpVersion.pre_spec, model.CaptpVersion.fromWireString("pancake-pre-spec").?);
    try std.testing.expectEqual(@as(?model.CaptpVersion, null), model.CaptpVersion.fromWireString("2.0"));
}

test "wire profile constants carry CapTP version, canonical flag, and name" {
    const goblins = model.WireProfile.v1_0;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, goblins.captp_version);
    try std.testing.expect(goblins.flags.goblins_canonical);
    try std.testing.expectEqualStrings("ocapn-v1.0", goblins.name());

    const pre_spec = model.WireProfile.pre_spec;
    try std.testing.expectEqual(model.CaptpVersion.pre_spec, pre_spec.captp_version);
    try std.testing.expect(!pre_spec.flags.goblins_canonical);
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

test "parseV1_0 splits a typed abort prefix into kind + message and falls back to other" {
    const typed = model.AbortReason.parseV1_0("VersionMismatch: expected ocapn-1.0");
    try std.testing.expectEqual(model.AbortKind.version_mismatch, typed.kind);
    try std.testing.expectEqualStrings("expected ocapn-1.0", typed.message);

    // An unrecognized label, or no "<label>: " prefix at all, is `other` carrying
    // the whole string verbatim.
    const freeform = model.AbortReason.parseV1_0("free-form");
    try std.testing.expectEqual(model.AbortKind.other, freeform.kind);
    try std.testing.expectEqualStrings("free-form", freeform.message);
}

test "near and far ref constructors set the wire-tag kind discriminant" {
    try std.testing.expectEqual(model.NearKind.object, model.NearRef.object(1).kind);
    try std.testing.expectEqual(model.NearKind.promise, model.NearRef.promise(1).kind);
    try std.testing.expectEqual(model.ImportKind.object, model.FarRef.object(2).kind);
    try std.testing.expectEqual(model.ImportKind.promise, model.FarRef.promise(2).kind);
}

test "protocol model arms map one-to-one onto Zig Message tags" {
    const oracle = @import("../oracle/protocol_oracle.zig");

    try std.testing.expectEqual(oracle.message_arms.len, model.message_kinds.len);
    for (oracle.message_arms, model.message_kinds) |oracle_arm, model_kind| {
        try std.testing.expectEqualStrings(oracle_arm.name, model_kind.model_name);
    }
}
