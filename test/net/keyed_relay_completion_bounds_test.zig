//! The keyed-relay completion adapter's input bounds, driven against the
//! scriptable platform in `test/support/keyed_relay_admission.zig`. The HTTP
//! upgrade reader refuses a response one byte past `max_upgrade_response_bytes`
//! with `UpgradeResponseTooLarge`, and the retained read buffer refuses bytes
//! past `raw_in_limit` (one platform read buffer plus the largest header and
//! control prefix) with `RelayInputOverflow`. Every refusal sits beside the
//! last admitted length, so an off-by-one cannot hide behind either side.

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../support/keyed_relay_admission.zig");

const net = glowcap.net;
const keyed_relay = net.relay;
const protocol = net.websocket.client_protocol;

const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;
const openAdmissionRelay = admission.openAdmissionRelay;
const startUpgradeRelay = admission.startUpgradeRelay;

const upgrade_cap = protocol.max_upgrade_response_bytes;

/// Read buffers twice the upgrade cap, so one platform read can carry a
/// response past the cap while `raw_in_limit` stays out of the way.
fn upgradeBackend() !AdmissionBackend {
    return AdmissionBackend.initWithRelay(std.testing.allocator, 8, 1, 2 * upgrade_cap, .{
        .url = "ws://127.0.0.1:1/relay",
        .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x93)),
        .send_staging_bytes = admission.frame_cap,
    });
}

fn expectFailed(
    completion: net.completion.Completion,
    user_data: u64,
    cause: anyerror,
    phase: net.carrier_failure.Phase,
) !void {
    try std.testing.expectEqual(user_data, completion.user_data);
    try std.testing.expectEqual(@as(i32, -1), completion.result);
    try std.testing.expectEqual(cause, completion.failure.?);
    try std.testing.expectEqual(phase, completion.borrowed.carrierPhase().?);
}

const UpgradeCase = struct {
    /// Bytes the relay sends before the dial settles.
    len: usize,
    /// Whether the last four bytes are the header terminator.
    terminated: bool,
    /// Where the first platform read ends. `len` is one read for the whole response.
    split: usize,
    /// The cause the connect completion carries, or null while the reader
    /// keeps waiting for the terminator.
    want: ?anyerror,
};

// A response of exactly the cap is admitted: unterminated it keeps reading,
// terminated it reaches validation and fails there as a malformed upgrade
// (the filler is not a status line). One byte more is refused before any
// validation, whether it arrives in one read, behind a full read, or with the
// terminator split across reads.
const upgrade_cases = [_]UpgradeCase{
    .{ .len = upgrade_cap, .terminated = false, .split = upgrade_cap, .want = null },
    .{
        .len = upgrade_cap + 1,
        .terminated = false,
        .split = upgrade_cap + 1,
        .want = error.UpgradeResponseTooLarge,
    },
    .{
        .len = upgrade_cap + 1,
        .terminated = false,
        .split = upgrade_cap,
        .want = error.UpgradeResponseTooLarge,
    },
    .{
        .len = upgrade_cap,
        .terminated = true,
        .split = upgrade_cap,
        .want = error.InvalidWebSocketUpgrade,
    },
    .{
        .len = upgrade_cap + 1,
        .terminated = true,
        .split = upgrade_cap + 1,
        .want = error.UpgradeResponseTooLarge,
    },
    .{
        .len = upgrade_cap,
        .terminated = true,
        .split = upgrade_cap - 2,
        .want = error.InvalidWebSocketUpgrade,
    },
    .{
        .len = upgrade_cap + 1,
        .terminated = true,
        .split = upgrade_cap - 1,
        .want = error.UpgradeResponseTooLarge,
    },
};

test "keyed-relay upgrade refuses a response one byte past the cap and admits the cap" {
    for (upgrade_cases) |case| try expectUpgradeCase(case);
}

fn expectUpgradeCase(case: UpgradeCase) !void {
    var backend = try upgradeBackend();
    defer deinitAdmissionBackend(&backend);
    _ = try startUpgradeRelay(&backend);
    const conn = backend.conns.get(1).?;

    const wire = try std.testing.allocator.alloc(u8, case.len);
    defer std.testing.allocator.free(wire);
    @memset(wire, 'a');
    if (case.terminated) @memcpy(wire[case.len - 4 ..], "\r\n\r\n");

    var completions: [1]net.completion.Completion = undefined;
    if (case.split < case.len) {
        try backend.platform.completeRecv(wire[0..case.split]);
        try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
        try std.testing.expectEqual(case.split, conn.upgrade_buf.items.len);
        try std.testing.expectEqual(.reading_upgrade, conn.state);
        try backend.platform.completeRecv(wire[case.split..]);
    } else {
        // An empty read is the relay closing, so one read carries it all.
        try backend.platform.completeRecv(wire);
    }
    const count = try backend.poll(&completions, 0);
    if (case.want) |cause| {
        try std.testing.expectEqual(@as(usize, 1), count);
        try expectFailed(completions[0], 7, cause, .websocket_upgrade);
        try std.testing.expectEqual(.closing, conn.state);
    } else {
        try std.testing.expectEqual(@as(usize, 0), count);
        try std.testing.expectEqual(case.len, conn.upgrade_buf.items.len);
        try std.testing.expectEqual(.reading_upgrade, conn.state);
    }
}

/// One server frame carrying "a", followed by `tail_len` bytes the adapter has
/// to retain once the frame's payload is lent out.
fn coalescedWire(tail_len: usize) ![]u8 {
    const wire = try std.testing.allocator.alloc(u8, 3 + tail_len);
    @memcpy(wire[0..3], &[_]u8{ 0x82, 0x01, 'a' });
    @memset(wire[3..], 0x5a);
    return wire;
}

test "keyed-relay retained input is the read buffer plus the largest header and control prefix" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    // `admissionBackend` sizes its single read buffer at 64 bytes.
    try std.testing.expectEqual(
        @as(usize, 64) + keyed_relay.max_header_len + keyed_relay.max_control_payload,
        backend.raw_in_limit,
    );
}

test "keyed-relay lent platform read keeps a coalesced tail of exactly the retained-input limit" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    const wire = try coalescedWire(backend.raw_in_limit);
    defer std.testing.allocator.free(wire);
    backend.platform.recv_payload = wire;
    try backend.submitRecv(60, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 60), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    try std.testing.expectEqual(backend.raw_in_limit, conn.raw_in.items.len - conn.raw_in_head);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay lent platform read refuses a coalesced tail one byte past the limit" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    const wire = try coalescedWire(backend.raw_in_limit + 1);
    defer std.testing.allocator.free(wire);
    backend.platform.recv_payload = wire;
    const recycled_before = backend.platform.recycle_calls;
    try backend.submitRecv(60, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try expectFailed(completions[0], 60, error.RelayInputOverflow, .receive);
    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    // The refused platform buffer goes back to its pool exactly once.
    try std.testing.expectEqual(recycled_before + 1, backend.platform.recycle_calls);
}

test "keyed-relay later read counts retained bytes against the limit and admits the last byte" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const limit = backend.raw_in_limit;

    // One retained header byte leaves `limit - 1` bytes of room. The read that
    // fills it exactly carries the rest of a one-byte frame, so the completion
    // proves the byte at the limit was admitted and parsed.
    try conn.raw_in.appendSlice(backend.allocator, &.{0x82});
    try backend.submitRecv(62, fd);
    try std.testing.expectEqual(@as(?u64, 62), conn.external_recv_ud);
    try std.testing.expect(conn.pending.get(.recv));

    const wire = try std.testing.allocator.alloc(u8, limit - 1);
    defer std.testing.allocator.free(wire);
    @memset(wire, 0x5a);
    @memcpy(wire[0..2], &[_]u8{ 0x01, 'a' });
    try backend.platform.completeRecv(wire);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 62), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay later read refuses a byte past the limit once a header byte is retained" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const limit = backend.raw_in_limit;

    try conn.raw_in.appendSlice(backend.allocator, &.{0x82});
    try backend.submitRecv(62, fd);
    try std.testing.expect(conn.pending.get(.recv));

    // `limit` bytes alone fit an empty buffer. Behind the retained byte they
    // are one past it.
    const wire = try std.testing.allocator.alloc(u8, limit);
    defer std.testing.allocator.free(wire);
    @memset(wire, 0x5a);
    const recycled_before = backend.platform.recycle_calls;
    try backend.platform.completeRecv(wire);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try expectFailed(completions[0], 62, error.RelayInputOverflow, .receive);
    try std.testing.expectEqual(.closing, conn.state);
    // The refused platform buffer goes back to its pool exactly once.
    try std.testing.expectEqual(recycled_before + 1, backend.platform.recycle_calls);
}
