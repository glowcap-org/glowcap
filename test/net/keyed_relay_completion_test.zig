//! The keyed-relay completion adapter's seats, buffers, and lifecycle, driven
//! against the scriptable platform in `test/support/keyed_relay_admission.zig`:
//! the measured per-connection footprint, refusals that leave construction
//! retryable, recv-buffer recycling and starvation accounting, upgrade byte
//! bounds, and release idempotence. The close and control-frame choreography
//! lives beside this file in `keyed_relay_completion_wire_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../support/keyed_relay_admission.zig");

const net = glowcap.net;
const keyed_relay = net.relay;

const Io = std.Io;

const frame_cap = admission.frame_cap;
const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;
const startUpgradeRelay = admission.startUpgradeRelay;
const openAdmissionRelay = admission.openAdmissionRelay;

/// Stated under runtime safety, where each of the three `std.ArrayList(u8)`
/// headers (`upgrade_buf`, `raw_in`, `ws_out`) carries std's one-word
/// `pointer_stability` lock.
const keyed_relay_connection_state_bytes: usize = 272;
const keyed_relay_pending_dial_state_bytes: usize = 3896;
const keyed_relay_resolver_job_state_bytes: usize = 1136;

test "keyed-relay completion connection state has a measured footprint" {
    try std.testing.expectEqual(@as(usize, 8), AdmissionBackend.parallel_address_attempts);
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    try std.testing.expectEqual(keyed_relay_connection_state_bytes, AdmissionBackend.connection_state_bytes);
    try std.testing.expectEqual(
        keyed_relay_pending_dial_state_bytes,
        AdmissionBackend.pending_dial_state_bytes,
    );
    try std.testing.expectEqual(
        keyed_relay_resolver_job_state_bytes,
        AdmissionBackend.resolver_job_state_bytes,
    );
}

test "keyed-relay completion rejects send staging too small for control frames" {
    try std.testing.expectError(
        error.InvalidSendStagingBytes,
        AdmissionBackend.initWithRelay(std.testing.allocator, 8, 1, 64, .{
            .url = "ws://127.0.0.1:1/relay",
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x91)),
            .send_staging_bytes = 0,
        }),
    );
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

test "keyed-relay refused send submission restores the frame queue and user-data seat" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.fail_send = true;
    try std.testing.expectError(error.SubmitFailed, backend.submitSend(17, fd, "payload"));
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
    try std.testing.expectEqual(@as(usize, 0), conn.ws_out.items.len);

    backend.platform.fail_send = false;
    try backend.submitSend(17, fd, "payload");
    try std.testing.expectEqual(@as(?u64, 17), conn.external_send_ud);
    try std.testing.expect(conn.ws_out.items.len > 0);
}

test "keyed-relay refused recv admission consumes no payload and installs no seat" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x03, 'a', 'b', 'c' });

    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    const original = backend.allocator;
    backend.allocator = fixed.allocator();
    try std.testing.expectError(error.OutOfMemory, backend.submitRecv(23, fd));
    backend.allocator = original;

    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(u64, 0), conn.data_remaining);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x03, 'a', 'b', 'c' }, conn.raw_in.items);

    try backend.submitRecv(23, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 23), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "abc", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay buffered work still services delegated platform completions" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'a' });
    try backend.submitRecv(24, fd);
    backend.platform.pending_send = .{ .user_data = 25, .result = 1 };

    // The owed record takes the one slot, and the platform is still polled,
    // with no room, so its submissions flush. Its record lands next pass.
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 24), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.poll_calls);
    try std.testing.expect(backend.platform.pending_send != null);
    backend.recycleBorrowed(completions[0]);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 25), completions[0].user_data);
    try std.testing.expect(backend.platform.pending_send == null);
}

test "keyed-relay allocator pressure does not hide earned completions" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'a' });
    try backend.submitRecv(26, fd);
    backend.platform.pending_send = .{ .user_data = 27, .result = 1 };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var completions: [1]net.completion.Completion = undefined;
    {
        const original = backend.allocator;
        backend.allocator = failing.allocator();
        defer backend.allocator = original;
        try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    }

    try std.testing.expectEqual(@as(u64, 26), completions[0].user_data);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.poll_calls);
    try std.testing.expect(backend.platform.pending_send != null);
    backend.recycleBorrowed(completions[0]);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 27), completions[0].user_data);
}

test "keyed-relay accepted close retries wrapped close refusal" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    conn.external_recv_ud = 31;
    conn.external_send_ud = 32;
    conn.external_send_len = 9;

    backend.platform.fail_close = true;
    try backend.submitClose(33, fd);

    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
    try std.testing.expectEqual(@as(?u64, 33), conn.external_close_ud);
    try std.testing.expect(conn.close.wire.hasSent());
    try std.testing.expectEqual(@as(usize, 2), backend.ready.len());

    var completions: [3]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.close_retries.contains(conn));
    try std.testing.expectEqual(@as(usize, 1), backend.close_retries.count);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.shutdown_calls);

    backend.platform.fail_close = false;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 33), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay direct release retires a refused wrapped close" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.fail_close = true;
    try backend.submitClose(33, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expect(backend.close_retries.contains(conn));
    try std.testing.expectEqual(@as(u32, 1), backend.close_retries.head);

    // The direct release contract has no caller completion to publish. Model
    // that owner handoff after proving the public close path queued the retry.
    conn.external_close_ud = null;
    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.close_retries.count);
    try std.testing.expectEqual(@as(u32, 0), backend.close_retries.head);
    try std.testing.expectEqual(@as(u32, 0), backend.close_retries.tail);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());
}

test "keyed-relay reserves user completions before consuming a platform send" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try backend.submitSend(41, fd, "payload");

    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    const original = backend.allocator;
    backend.allocator = fixed.allocator();
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectError(error.OutOfMemory, backend.poll(&completions, 0));
    backend.allocator = original;

    // Allocation refusal happened before `platform.poll`, so the terminal send
    // record and the caller's seat are both still available for an exact retry.
    try std.testing.expectEqual(@as(usize, 0), backend.platform.poll_calls);
    try std.testing.expectEqual(@as(?u64, 41), conn.external_send_ud);
    try std.testing.expect(backend.platform.pending_send != null);

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 41), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 7), completions[0].result);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
}

test "keyed-relay records recv-buffer starvation without allocating" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.platform.emit_recv_no_buffer = true;
    try backend.submitRecv(42, fd);
    try backend.ready.ensureUnusedCapacity(backend.allocator, 256 * 3);

    var tiny: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny);
    const original = backend.allocator;
    backend.allocator = fixed.allocator();
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    backend.allocator = original;

    try std.testing.expectEqual(@as(usize, 1), backend.platform.poll_calls);
    try std.testing.expectEqual(@as(u32, 1), backend.recv_retries.head);
}

test "keyed-relay recycles delegated and relayed recv buffers to their owning pools" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);

    var delegated_bytes = [_]u8{0xaa};
    backend.recycleBorrowed(.{
        .user_data = 1,
        .result = 1,
        .borrowed = .recv(&delegated_bytes, 7),
    });
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(u32, 7), backend.platform.last_recycled_token);

    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'a' });
    try backend.submitRecv(2, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);

    // The relay pool has one seat. Reusing it proves the tagged completion was
    // returned there rather than forwarded to the wrapped platform pool.
    try conn.raw_in.appendSlice(backend.allocator, &.{ 0x82, 0x01, 'b' });
    try backend.submitRecv(3, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "b", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay lends platform payload directly and copies only a coalesced tail" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    // Two complete server frames arrive in one wrapped-platform buffer. The
    // first payload can borrow that buffer directly; the second frame must move
    // to the spill before the outer Loop recycles the original token.
    var wire = [_]u8{ 0x82, 0x01, 'a', 0x82, 0x01, 'b' };
    backend.platform.recv_payload = &wire;
    backend.platform.recv_token = 29;

    try backend.submitRecv(81, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    try std.testing.expectEqual(@intFromPtr(&wire[2]), @intFromPtr(completions[0].borrowed.recvBytes().?.ptr));
    try std.testing.expectEqual(@as(u32, 29), completions[0].borrowed.token);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x01, 'b' }, conn.raw_in.items);
    try std.testing.expectEqual(@as(usize, 0), backend.platform.recycle_calls);

    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(u32, 29), backend.platform.last_recycled_token);

    try backend.submitRecv(82, fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "b", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
    // The copied tail belongs to the adapter scratch pool, not the wrapped
    // platform whose token was already returned exactly once.
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recycle_calls);
    try std.testing.expectEqual(@as(usize, 0), conn.raw_in.items.len);
}

test "keyed-relay releases burst spill capacity around a partial next header" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try conn.raw_in.ensureTotalCapacityPrecise(backend.allocator, 4096);
    conn.raw_in.appendSliceAssumeCapacity(&.{ 0x82, 0x01, 'a', 0x82 });
    try backend.submitRecv(83, fd);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqualSlices(u8, "a", completions[0].borrowed.recvBytes().?);
    try std.testing.expectEqualSlices(u8, &.{0x82}, conn.raw_in.items[conn.raw_in_head..]);
    try std.testing.expect(conn.raw_in.capacity <= keyed_relay.max_header_len + keyed_relay.max_control_payload);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay header-only platform read waits for payload instead of reporting EOF" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    backend.platform.recv_payload = @constCast(&[_]u8{ 0x82, 0x01 });
    try backend.submitRecv(30, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(?u64, 30), conn.external_recv_ud);
    try std.testing.expectEqual(@as(u64, 1), conn.data_remaining);
    try std.testing.expect(conn.pending.get(.recv));

    backend.platform.pending_recv = .{
        .user_data = backend.platform.armed_recv_ud.?,
        .result = 1,
        .borrowed = .recv("x", 0),
    };
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 30), completions[0].user_data);
    try std.testing.expectEqualSlices(u8, "x", completions[0].borrowed.recvBytes().?);
    backend.recycleBorrowed(completions[0]);
}

test "keyed-relay reports wrapped transport EOF without turning it into failure" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;

    try backend.submitRecv(31, fd);
    backend.platform.pending_recv = .{
        .user_data = backend.platform.armed_recv_ud.?,
        .result = 0,
    };

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 31), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(.closing, conn.state);
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.shutdown_calls);
}

test "keyed-relay upgrade bounds only HTTP bytes and preserves coalesced frame residue" {
    var backend = try AdmissionBackend.initWithRelay(
        std.testing.allocator,
        8,
        1,
        8192,
        .{
            .url = "ws://127.0.0.1:1/relay",
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x92)),
            .send_staging_bytes = frame_cap,
        },
    );
    defer deinitAdmissionBackend(&backend);
    _ = try startUpgradeRelay(&backend);
    const conn = backend.conns.get(1).?;

    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{conn.expected_accept[0..]},
    );
    const payload_len = 5000;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);
    try wire.appendSlice(std.testing.allocator, response);
    try wire.appendSlice(std.testing.allocator, &.{ 0x82, 126, 0x13, 0x88 });
    try wire.appendNTimes(std.testing.allocator, 0x5a, payload_len);
    // The coalesced read is larger than the completion adapter's 4 KiB HTTP
    // header cap, while the HTTP response itself remains well below it.
    try std.testing.expect(wire.items.len > 4096);

    try backend.platform.completeRecv(wire.items);

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 7), completions[0].user_data);
    try std.testing.expectEqual(.open, conn.state);
    try std.testing.expectEqual(@as(usize, 0), conn.upgrade_buf.capacity);
    try std.testing.expectEqual(@as(usize, payload_len + 4), conn.raw_in.items.len - conn.raw_in_head);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 126, 0x13, 0x88 }, conn.raw_in.items[conn.raw_in_head..][0..4]);
}

test "keyed-relay upgrade retention has no geometric capacity above received bytes" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    _ = try startUpgradeRelay(&backend);
    const conn = backend.conns.get(1).?;
    const fragment = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n";

    try backend.platform.completeRecv(@constCast(fragment));

    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));
    try std.testing.expectEqual(fragment.len, conn.upgrade_buf.items.len);
    try std.testing.expectEqual(fragment.len, conn.upgrade_buf.capacity);
}

test "keyed-relay repeated direct release and late close stay idempotent" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);

    backend.closeFd(fd);
    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
    try std.testing.expectEqual(@as(usize, 0), backend.conns.count());

    try backend.submitClose(41, fd);
    var completions: [1]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 41), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[0].result);
    try std.testing.expectEqual(@as(usize, 1), backend.platform.close_calls);
}

test "keyed-relay closing state refuses new recv and send seats" {
    var backend = try admissionBackend(std.testing.allocator);
    defer deinitAdmissionBackend(&backend);
    const fd = try openAdmissionRelay(&backend);
    const conn = backend.conns.get(1).?;
    conn.state = .closing;

    try std.testing.expectError(error.ConnectionLost, backend.submitRecv(1, fd));
    try std.testing.expectError(error.ConnectionLost, backend.submitSend(2, fd, "x"));
    try std.testing.expectEqual(@as(?u64, null), conn.external_recv_ud);
    try std.testing.expectEqual(@as(?u64, null), conn.external_send_ud);
}
