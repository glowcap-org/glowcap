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

const receive_frame = [_]u8{ 0x82, 0x01, 'a' };

/// One server frame followed by the bytes the adapter has to retain.
fn coalescedWire(tail_len: usize) ![]u8 {
    const wire = try std.testing.allocator.alloc(u8, receive_frame.len + tail_len);
    @memcpy(wire[0..receive_frame.len], &receive_frame);
    @memset(wire[receive_frame.len..], 0x5a);
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

const ReadShape = enum { lent, split, consumed_prefix };

fn expectRetainedInput(shape: ReadShape, over_limit: bool) !void {
    const allocator = std.testing.allocator;
    var backend = try admissionBackend(allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    const limit = backend.raw_in_limit;

    // A lent frame leaves only its tail in the buffer. A later read appends
    // the whole chunk and charges the live header byte already buffered.
    const tail_len = limit - (if (shape == .lent) @as(usize, 0) else receive_frame.len) + @intFromBool(over_limit);
    const wire = try coalescedWire(tail_len);
    defer allocator.free(wire);
    switch (shape) {
        .lent => backend.platform.recv_payload = wire,
        .split => try conn.raw_in.append(backend.allocator, wire[0]),
        .consumed_prefix => {
            try conn.raw_in.appendSlice(backend.allocator, &.{ 0, wire[0] });
            conn.raw_in_head = 1;
        },
    }

    const user_data = 60;
    const recycled_before = backend.platform.recycle_calls;
    try backend.submitRecv(user_data, fd);
    if (shape != .lent) {
        try std.testing.expectEqual(@as(?u64, user_data), conn.external_recv_ud);
        try std.testing.expect(conn.pending.get(.recv));
        try backend.platform.completeRecv(wire[1..]);
    }

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    if (over_limit) {
        try expectFailed(completions[0], user_data, error.RelayInputOverflow, .receive);
        try std.testing.expectEqual(.closing, conn.state);
        try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
        try std.testing.expectEqual(recycled_before + 1, backend.platform.recycle_calls);
    } else {
        try std.testing.expectEqual(@as(u64, user_data), completions[0].user_data);
        try std.testing.expectEqual(@as(?anyerror, null), completions[0].failure);
        try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
        try std.testing.expectEqual(tail_len, conn.raw_in.items.len - conn.raw_in_head);
        try std.testing.expect(conn.raw_in.items.len <= limit);
        backend.recycleBorrowed(completions[0]);
    }
}

test "keyed-relay admits the retained-input limit and refuses one byte more" {
    for ([_]ReadShape{ .lent, .split, .consumed_prefix }) |shape| {
        try expectRetainedInput(shape, false);
        try expectRetainedInput(shape, true);
    }
}
