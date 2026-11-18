//! A valid cleanup failure from a foreign stream provider's `conn_close`, run
//! while an ordinary live session closes, reaches the session's one surviving
//! recipient exactly once: the client's SESSION_CLOSED event. A healthy close
//! reports nothing, and a consuming release still owns the failure of the
//! close it runs.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const ctcp = @import("c_abi_net_transport_tcp");
const glowcap = @import("glowcap");

const harness = @import("harness.zig");
const expectOk = harness.expectOk;

const CloseFn = @TypeOf(@as(cdrv.GlowcapStreamTransport, undefined).conn_close);
var real_close: CloseFn = null;
var arm_failure: bool = false;
var close_calls: usize = 0;
var failing_returns: usize = 0;

const WriteFn = @TypeOf(@as(cdrv.GlowcapStreamTransport, undefined).try_write);
var real_write: WriteFn = null;
/// Write attempts the provider refuses before it takes bytes again.
var held_writes: usize = 0;
var refused_writes: usize = 0;

fn shimWrite(ctx: ?*anyopaque, conn: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    if (held_writes != 0) {
        held_writes -= 1;
        refused_writes += 1;
        return cshared.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }
    return real_write.?(ctx, conn, bytes, len);
}

fn shimClose(ctx: ?*anyopaque, conn: ?*anyopaque, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
    close_calls += 1;
    const rc = real_close.?(ctx, conn, out);
    if (rc != c.GLOWCAP_OK or !arm_failure) return rc;
    failing_returns += 1;
    _ = harness.providerFailure(out, c.GLOWCAP_ERR_IO, "LiveCloseCleanupFailed");
    const report = out orelse return c.GLOWCAP_ERR_IO;
    const secondary = "LiveCloseSecondary";
    report.carrier_phase = cshared.transport_provider.GLOWCAP_CARRIER_PHASE_SHUTDOWN;
    report.carrier_detail_flags = cshared.transport_provider.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
    report.carrier_engine_code = -0x2701;
    report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
    report.secondary_name = secondary.ptr;
    report.secondary_name_len = secondary.len;
    report.secondary_count = 1;
    return c.GLOWCAP_ERR_IO;
}

const Shim = struct {
    netlayer: ?*ctcp.GlowcapTcpNetlayer = null,
    table: cdrv.GlowcapStreamTransport = undefined,
    entry: cdrv.GlowcapTransportProviderEntry = undefined,
    provider: cdrv.GlowcapTransportProvider = undefined,

    fn install(self: *Shim, loop: ?*cdrv.GlowcapDriverLoop) !void {
        try expectOk(ctcp.glowcap_tcp_netlayer_new(&harness.default_tcp_config, &self.netlayer));
        defer ctcp.glowcap_tcp_netlayer_release(self.netlayer);
        var real: cdrv.GlowcapTransportProvider = undefined;
        try expectOk(ctcp.glowcap_tcp_transport_provider(self.netlayer, &real));
        var found: ?cdrv.GlowcapTransportProviderEntry = null;
        for (real.entries.?[0..real.entry_count]) |e| {
            const p = e.profile.?;
            if (std.mem.eql(u8, p.transport_name.?[0..p.transport_name_len], "tcp")) found = e;
        }
        const e = found orelse return error.NoTcpEntry;
        const real_table: *const cdrv.GlowcapStreamTransport = @ptrCast(@alignCast(e.implementation.?));
        self.table = real_table.*;
        real_close = self.table.conn_close;
        self.table.conn_close = shimClose;
        real_write = self.table.try_write;
        self.table.try_write = shimWrite;
        self.entry = e;
        self.entry.implementation = &self.table;
        self.provider = real;
        self.provider.entries = @ptrCast(&self.entry);
        self.provider.entry_count = 1;
        try expectOk(harness.addProvider(loop, &self.provider));
    }
};

fn name(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

const Mode = enum { healthy, ordinary_close_fails, release_owned_fails, release_after_queued_close, release_with_admitted_bytes };

fn journalRecords(ctx: ?*c.GlowcapContext) !usize {
    var n: usize = 0;
    while (true) {
        var ev: c.GlowcapFailureEvent = undefined;
        var buf: [1024]u8 = undefined;
        var req: usize = 0;
        const rc = c.glowcap_context_next_failure(ctx, &ev, &buf, buf.len, &req);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) return n;
        try expectOk(rc);
        n += 1;
    }
}

/// The provider's whole report as the consuming release returns it.
fn expectReleaseFailure(failure: cdrv.GlowcapDriverFailure) !void {
    try std.testing.expectEqual(@as(i32, c.GLOWCAP_ERR_IO), failure.primary_result);
    try std.testing.expectEqualStrings("LiveCloseCleanupFailed", name(failure.primary_name, failure.primary_name_len));
    try std.testing.expectEqual(cshared.transport_provider.GLOWCAP_CARRIER_PHASE_SHUTDOWN, failure.carrier_phase);
    try std.testing.expectEqual(@as(i32, -0x2701), failure.carrier_engine_code);
    try std.testing.expectEqual(@as(u32, 1), failure.secondary_count);
    try std.testing.expectEqual(@as(i32, c.GLOWCAP_ERR_INTERNAL), failure.secondary_result);
    try std.testing.expectEqualStrings("LiveCloseSecondary", name(failure.secondary_name, failure.secondary_name_len));
}

fn scenario(mode: Mode, seed: u8) !void {
    arm_failure = mode != .healthy;
    close_calls = 0;
    failing_returns = 0;
    held_writes = 0;
    refused_writes = 0;

    const server = try harness.newLoop(seed);
    defer server.deinit();
    const listener = try harness.listenReady(server.raw, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server.raw, listener));
    const locator = try harness.readListenerLocator(server.raw, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var ctx: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new(&ctx));
    defer c.glowcap_context_release(ctx);
    const hseed = harness.hostSeed(seed +% 1);
    var host: ?*cd.GlowcapHost = null;
    try expectOk(cd.glowcap_host_new_in(ctx, &hseed, hseed.len, harness.frame_cap, 1, c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CAPTP_V1_0, c.GLOWCAP_FEATURE_FULL, 0, 1, &host));
    var client: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &harness.driver_options_10s, &client));
    var shim: Shim = .{};
    try shim.install(client);

    var op: u64 = 0;
    try expectOk(try harness.dialParts(client, "tcp", locator.designator, "", &op));
    var cs = harness.Drained{};
    var ss = harness.Drained{};
    for (0..2_000) |_| {
        try harness.expectStep(cdrv.glowcap_driver_step(client, 5));
        try harness.drainEvents(client, &cs);
        try harness.expectStep(cdrv.glowcap_driver_step(server.raw, 5));
        try harness.drainEvents(server.raw, &ss);
        if (cs.dialed_session != null and ss.accepted_session != null) break;
    }
    const csess = cs.dialed_session orelse return error.NoDial;
    const ssess = ss.accepted_session orelse return error.NoAccept;
    try harness.serveBoth(client, csess, server.raw, ssess);
    try std.testing.expectEqual(@as(usize, 0), close_calls);

    var release_failure = cdrv.GlowcapDriverFailure.init();
    const consuming = mode == .release_owned_fails or mode == .release_after_queued_close or mode == .release_with_admitted_bytes;
    if (mode == .release_with_admitted_bytes) {
        // The session stages a request the provider keeps refusing, so the
        // consuming release finds bytes admitted when it submits the close:
        // the provider's close cannot run until they drain inside the release.
        held_writes = 50;
        var vow: u64 = 0;
        try expectOk(cd.glowcap_host_session_fetch(csess, "widget", 6, &vow));
        try harness.expectStep(cdrv.glowcap_driver_step(client, 0));
        // The step admitted the request and the provider still refuses it.
        try std.testing.expect(refused_writes != 0 and held_writes != 0);
        try std.testing.expectEqual(@as(usize, 0), close_calls);
    }
    if (mode == .release_after_queued_close) {
        // Control for a distinct case: the close is queued and the release
        // consumes the loop before any step submits a physical close, so the
        // release itself runs the close. A close already submitted when the
        // session is dropped is proven through `HostRuntime` in
        // `test/driver/host_runtime_multiplexed/external_close_failure_test.zig`.
        try expectOk(cdrv.glowcap_driver_session_close(client, csess, &harness.close_cancel));
    }
    if (!consuming) {
        try expectOk(cdrv.glowcap_driver_session_close(client, csess, &harness.close_cancel));
        var state: u32 = 0;
        for (0..200) |_| {
            try harness.expectStep(cdrv.glowcap_driver_step(client, 5));
            try harness.drainEvents(client, &cs);
            try harness.drainEvents(server.raw, &ss);
            try harness.expectStep(cdrv.glowcap_driver_step(server.raw, 5));
            try harness.drainEvents(server.raw, &ss);
            try expectOk(cdrv.glowcap_driver_session_lifecycle_state(client, csess, &state));
            if (state == cd.GLOWCAP_LIFECYCLE_CLOSED and cs.closed_count != 0) break;
        }
        try std.testing.expectEqual(@as(u32, cd.GLOWCAP_LIFECYCLE_CLOSED), state);
        // Further steps neither repeat the report nor call the provider again.
        for (0..5) |_| {
            try harness.expectStep(cdrv.glowcap_driver_step(client, 0));
            try harness.drainEvents(client, &cs);
            try harness.drainEvents(server.raw, &ss);
        }
        try std.testing.expectEqual(@as(usize, 1), cs.closed_count);
        if (mode == .healthy) {
            try std.testing.expectEqual(@as(i32, c.GLOWCAP_OK), cs.closed_result);
            try std.testing.expectEqual(@as(u32, 0), cs.closed_secondary_count);
        } else {
            try std.testing.expectEqual(@as(i32, c.GLOWCAP_ERR_IO), cs.closed_result);
            try std.testing.expectEqualStrings("LiveCloseCleanupFailed", cs.closed_message[0..cs.closed_message_len]);
            try std.testing.expectEqual(@as(u32, 1), cs.closed_secondary_count);
            try std.testing.expectEqual(@as(i32, c.GLOWCAP_ERR_INTERNAL), cs.closed_secondary_result);
            try std.testing.expectEqualStrings("LiveCloseSecondary", cs.closed_secondary_message[0..cs.closed_secondary_message_len]);
            try std.testing.expectEqual(cshared.transport_provider.GLOWCAP_CARRIER_PHASE_SHUTDOWN, cs.closed_carrier.phase);
            try std.testing.expectEqual(@as(i32, -0x2701), cs.closed_carrier.engine_code);
        }
        // The journal holds no second copy for a failure that had a recipient.
        try std.testing.expectEqual(@as(usize, 0), try journalRecords(ctx));
        try expectOk(cdrv.glowcap_driver_session_release(client, csess));
    }
    const rc = cdrv.glowcap_driver_release(client, &release_failure);
    if (consuming) {
        try std.testing.expect(rc != c.GLOWCAP_OK);
        try expectReleaseFailure(release_failure);
        if (mode == .release_with_admitted_bytes) try std.testing.expect(refused_writes != 0);
    } else {
        try expectOk(rc);
        try std.testing.expectEqual(@as(i32, c.GLOWCAP_OK), release_failure.primary_result);
    }
    try std.testing.expectEqual(@as(usize, 0), try journalRecords(ctx));
    try expectOk(cdrv.glowcap_driver_session_release(server.raw, ssess));
    try std.testing.expectEqual(@as(usize, if (mode == .healthy) 0 else 1), failing_returns);
    try std.testing.expectEqual(@as(usize, 1), close_calls);
}

test "live stream close: a healthy provider close reports nothing" {
    try scenario(.healthy, 0x90);
}

test "live stream close: a failing provider close reaches the closing session once" {
    try scenario(.ordinary_close_fails, 0x92);
}

test "live stream close: a consuming release keeps the failure of the close it runs" {
    try scenario(.release_owned_fails, 0x94);
}

test "live stream close: a release after a queued close owns its failure once" {
    try scenario(.release_after_queued_close, 0x96);
}

test "live stream close: a release that finds admitted bytes owns the close failure once" {
    try scenario(.release_with_admitted_bytes, 0x98);
}
