//! The keyed-relay completion adapter's dials, driven against the scriptable
//! platform in `test/support/keyed_relay_admission.zig`: a dial refused before
//! construction leaves nothing behind, a relay hint needs a backend built with
//! relay options, a connect failure keeps its cause and carrier phase, and the
//! bounded address race stays full, retires losers in resolver order, and rolls
//! a winner back when retirement fails. Seats, buffers, and lifecycle live in
//! `keyed_relay_completion_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../support/keyed_relay_admission.zig");

const net = glowcap.net;
const keyed_relay = net.relay;

const Io = std.Io;

const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;

test "keyed-relay completion built without relay options refuses a dial that carries a relay hint" {
    var backend = try AdmissionBackend.init(std.testing.allocator, 8, 1, 64);
    defer deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));
    const hint = try keyed_relay.RelayUrl.parse("ws://127.0.0.1:1/relay");
    try std.testing.expectError(
        error.NoRendezvousConfigured,
        backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = hint } }),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
}

test "keyed-relay refused dial releases construction state and reuses its handle" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));

    backend.platform.fail_dial = true;
    try std.testing.expectError(
        error.SubmitFailed,
        backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = null } }),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    try std.testing.expectEqual(@as(u32, 1), backend.next_id);

    backend.platform.fail_dial = false;
    const fd = try backend.startDial(7, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8000_0001))), fd);
    try std.testing.expectEqual(@as(usize, 1), backend.pending_dials.count());
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());
}

test "keyed-relay completion preserves clear connect cause and carrier phase" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));

    _ = try backend.startDial(8, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    const internal_ud = backend.platform.pending_connect.?.user_data;
    var chain = glowcap.foundation.FailureChain.init(error.NetworkUnreachable);
    chain.note(error.ResolverCleanupFailed);
    backend.platform.pending_connect = .{
        .user_data = internal_ud,
        .result = -1,
        .failure = error.ConnectFailed,
        .borrowed = .failure(&chain, 37),
    };

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 8), completions[0].user_data);
    try std.testing.expectEqual(error.NetworkUnreachable, completions[0].borrowed.failureChain().?.cause);
    try std.testing.expectEqual(
        error.ResolverCleanupFailed,
        completions[0].borrowed.failureChain().?.secondary_cause.?,
    );
    try std.testing.expectEqual(
        net.carrier_failure.Phase.connect,
        completions[0].borrowed.carrierPhase().?,
    );
    // The race copies the bounded failure chain, then immediately returns the
    // losing platform's borrow. The caller receives adapter-owned storage.
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(u32, 37), backend.platform.last_recycled_token);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
}

test "keyed-relay completion keeps its bounded address race full and joins losers" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));

    _ = try backend.startDial(9, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    var addresses: [10]std.Io.net.IpAddress = undefined;
    for (&addresses, 0..) |*address, index| address.* = .{ .ip4 = .{
        .bytes = .{ 127, 0, 0, @intCast(index + 1) },
        .port = 8000,
    } };
    AdmissionBackend.white_box.replacePendingWithAddresses(&backend, 1, &addresses);
    try std.testing.expectEqual(@as(usize, 8), backend.platform.dial_submits);
    backend.platform.race_connects[0].result = -1;
    backend.platform.race_connects[0].failure = error.NetworkUnreachable;

    var completions: [4]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 9), backend.platform.dial_submits);
    var turns: usize = 0;
    while (backend.pending_dials.count() != 0) : (turns += 1) {
        try std.testing.expect(turns < 32);
        _ = try backend.poll(&completions, 0);
    }
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());
    try std.testing.expectEqual(@as(usize, 7), backend.platform.close_submits);
    try std.testing.expectEqual(@as(usize, 9), backend.platform.dial_submits);
}

test "keyed-relay completion retains address failures in resolver order" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));

    _ = try backend.startDial(12, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    const addresses = [_]std.Io.net.IpAddress{
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 8000 } },
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 8000 } },
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 3 }, .port = 8000 } },
    };
    AdmissionBackend.white_box.replacePendingWithAddresses(&backend, 1, &addresses);
    var first = backend.platform.race_connects[0];
    var second = backend.platform.race_connects[1];
    var third = backend.platform.race_connects[2];
    first.result = -1;
    first.failure = error.NetworkUnreachable;
    second.result = -1;
    second.failure = error.ConnectionRefused;
    third.result = -1;
    third.failure = error.HostUnreachable;
    // Complete the third address first. The diagnostic order remains the
    // resolver's preference order, not scheduler timing.
    backend.platform.race_connects[0] = third;
    backend.platform.race_connects[1] = first;
    backend.platform.race_connects[2] = second;

    var result: ?net.completion.Completion = null;
    defer if (result) |pending_result| if (pending_result.borrowed.active())
        backend.recycleBorrowed(pending_result);
    var batch: [1]net.completion.Completion = undefined;
    var turns: usize = 0;
    while (result == null) : (turns += 1) {
        try std.testing.expect(turns < 8);
        if (try backend.poll(&batch, 0) == 1) result = batch[0];
    }
    const failure = result.?.borrowed.failureChain() orelse return error.MissingAddressFailure;
    try std.testing.expectEqual(error.NetworkUnreachable, failure.cause);
    try std.testing.expectEqual(error.ConnectionRefused, failure.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 2), failure.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), backend.pending_dials.count());
    backend.recycleBorrowed(result.?);
    result = null;
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
}

test "keyed-relay completion rolls back a winner when loser retirement fails" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));

    _ = try backend.startDial(13, .{ .keyed_relay = .{ .designator = &designator, .relay = null } });
    const addresses = [_]std.Io.net.IpAddress{
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 8000 } },
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 8000 } },
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 3 }, .port = 8000 } },
    };
    AdmissionBackend.white_box.replacePendingWithAddresses(&backend, 1, &addresses);
    backend.platform.close_result = -1;
    var batch: [1]net.completion.Completion = undefined;
    // The first address wins and queues retirement for both losers. Make only
    // those first close completions fail; their retries and winner rollback
    // can then complete successfully.
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&batch, 0));
    backend.platform.close_result = 0;

    var result: ?net.completion.Completion = null;
    defer if (result) |pending_result| if (pending_result.borrowed.active())
        backend.recycleBorrowed(pending_result);
    var turns: usize = 0;
    while (result == null) : (turns += 1) {
        try std.testing.expect(turns < 24);
        if (try backend.poll(&batch, 0) == 1) result = batch[0];
    }
    const failure = result.?.borrowed.carrierFailureValue() orelse
        return error.MissingLoserCleanupFailure;
    try std.testing.expectEqual(error.CloseFailed, failure.chain.cause);
    try std.testing.expectEqual(net.carrier_failure.Phase.shutdown, failure.phase);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
    backend.recycleBorrowed(result.?);
    result = null;
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
}
