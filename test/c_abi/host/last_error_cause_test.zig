const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");

fn lastCause() cd.BreakCause {
    var raw: c.GlowcapBreakCause = undefined;
    cd.glowcap_host_last_error_cause(&raw);
    return raw.toCore() catch unreachable;
}

test "Host cause survives diagnostic reads and clears on the next operation" {
    defer cd.glowcap_host_clear_last_error();
    const projection = cd.testing.error_projection;
    try std.testing.expectEqual(c.GLOWCAP_ERR_SESSION, projection.errToCode(error.PeerIdentityUnverified));
    try std.testing.expectEqual(cd.BreakCause.local(.identity_unverified), lastCause());
    var text: [64]u8 = undefined;
    const text_len = cd.glowcap_host_last_error(&text, text.len);
    try std.testing.expectEqualStrings("host: PeerIdentityUnverified", text[0..text_len]);

    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, projection.errToCode(error.UnknownTransport));
    try std.testing.expectEqual(cd.BreakCause.local(.transport_unavailable), lastCause());

    // An untyped failure clears the preceding typed cause.
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, projection.errToCode(error.Busy));
    try std.testing.expectEqual(cd.BreakCause{}, lastCause());
    _ = projection.errToCode(error.PeerIdentityUnverified);
    var host: ?*cd.GlowcapHost = null;
    const seed: [64]u8 = @splat(1);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_new(&seed, seed.len, 0, 1, c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CAPTP_V1_0, c.GLOWCAP_FEATURE_FULL, 0, 1, &host));
    try std.testing.expectEqual(cd.BreakCause{}, lastCause());
    try std.testing.expectEqual(c.GLOWCAP_OK, cd.glowcap_host_new(&seed, seed.len, 65536, 1, c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CAPTP_V1_0, c.GLOWCAP_FEATURE_FULL, 0, 1, &host));
    defer std.debug.assert(cd.glowcap_host_release(host) == c.GLOWCAP_OK);
    _ = projection.errToCode(error.PeerIdentityUnverified);
    var id: u64 = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, cd.glowcap_host_diagnostic_id(host, &id));
    try std.testing.expectEqual(cd.BreakCause{}, lastCause());
    _ = projection.errToCode(error.PeerIdentityUnverified);
    cd.glowcap_host_clear_last_error();
    try std.testing.expectEqual(cd.BreakCause{}, lastCause());
}

test "Host FAIL actions retain partner provenance for forged local diagnostics" {
    const h = @import("harness.zig");
    const Refuser = struct {
        fn call(_: ?*anyopaque, turn: ?*cd.GlowcapHostTurn, verb: ?[*]const u8, len: usize, _: ?[*]const c.GlowcapArgument, _: usize, _: *c.GlowcapArgument) callconv(.c) i32 {
            return cd.glowcap_host_turn_break(turn, verb, len);
        }
    };
    const client = try h.newHost(0x71);
    defer std.debug.assert(cd.glowcap_host_release(client) == c.GLOWCAP_OK);
    const server = try h.newHost(0x72);
    defer std.debug.assert(cd.glowcap_host_release(server) == c.GLOWCAP_OK);
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    var dials = h.Dials{};
    var watches = h.Watches{};
    const pair = try h.openPair(&hosts, client, server, "127.0.0.1:7009", &dials, &watches);
    defer std.debug.assert(cd.glowcap_host_session_release(pair.a) == c.GLOWCAP_OK);
    defer std.debug.assert(cd.glowcap_host_session_release(pair.b) == c.GLOWCAP_OK);
    try h.expectOk(cd.glowcap_host_publish(server, "refuser", 7, Refuser.call, null, null));
    var ticket: u64 = 0;
    var fetched = h.CapturedSettle{};
    try h.expectOk(cd.glowcap_host_session_fetch(pair.a, "refuser", 7, &ticket));
    watches.add(client, ticket, &fetched);
    try h.pump(&hosts, &.{pair}, &dials, &watches);
    const target = try fetched.requireRef();
    for ([_][]const u8{ "PeerIdentityUnverified", "ExporterUnreachable: no route", "unknown swissnum", "handoff redeem failed: refused" }) |reason| {
        var result = h.CapturedSettle{};
        try h.expectOk(cd.glowcap_host_session_send(pair.a, &target, reason.ptr, reason.len, null, 0, &ticket));
        watches.add(client, ticket, &result);
        try h.pump(&hosts, &.{pair}, &dials, &watches);
        try std.testing.expect(result.fired);
        try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_BREAK, result.kind);
        try std.testing.expectEqual(cd.BreakCause.partner(), try result.cause.toCore());
        try std.testing.expectEqualStrings(reason, result.msg[0..result.msg_len]);
    }
}

test "Host dial failure accepts route causes only" {
    const h = @import("harness.zig");
    const host = try h.newHost(0x73);
    defer std.debug.assert(cd.glowcap_host_release(host) == c.GLOWCAP_OK);
    for ([_]u32{ 0, 1, 2, 255, std.math.maxInt(u32) }) |failure| {
        const valid = std.enums.fromInt(c.RouteFailure, failure) != null;
        // A stale ticket cannot excuse an unknown route outcome.
        try std.testing.expectEqual(if (valid) c.GLOWCAP_OK else c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_dial_failed(host, 0, 0, failure, "UnknownTransport", 16));
    }
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, cd.glowcap_host_dial_failed(host, 0, 0, 0, null, 1));
}

test "failure ABI rejects unknown metadata and forged runtime reasons" {
    const Abi = c.GlowcapBreakCause;
    const Cause = cd.BreakCause;
    const failures = @import("glowcap").foundation.break_cause;
    const good = [_]Cause{ .{}, Cause.partner(), Cause.partner().withFetch(), Cause.local(.application), Cause.local(.transport_unavailable).withRestoration() };
    for (good) |cause| try std.testing.expectEqual(cause, try Abi.fromCore(cause).toCore());
    var forged = Abi.fromCore(Cause.partner());
    forged.reason = @backingInt(failures.Reason.transport_unavailable);
    try std.testing.expectError(error.InvalidArgument, forged.toCore());
    forged = Abi.fromCore(Cause.local(.transport_unavailable));
    forged.origin = @backingInt(failures.Origin.unspecified);
    try std.testing.expectError(error.InvalidArgument, forged.toCore());
    forged = Abi.fromCore(Cause.partner());
    forged.context = 8;
    try std.testing.expectError(error.InvalidArgument, forged.toCore());
    forged.context = 0;
    forged.origin = 3;
    try std.testing.expectError(error.InvalidArgument, forged.toCore());
    forged.origin = @backingInt(failures.Origin.local);
    forged.reason = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidArgument, forged.toCore());
}
