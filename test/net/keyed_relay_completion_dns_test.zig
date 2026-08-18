//! Async relay DNS and pre-admission dial-lifecycle evidence.

const std = @import("std");
const pancake = @import("pancake");
const admission = @import("../support/keyed_relay_admission.zig");

const net = pancake.net;

test "completion relay retries refused loser close admission without parking" {
    var backend = try admission.admissionBackend(std.testing.allocator);
    defer admission.deinitAdmissionBackend(&backend);
    const designator = [_]u8{'a'} ** 64;

    _ = try backend.startDial(8, .{ .keyed_relay = .{
        .designator = &designator,
        .relay = null,
    } });
    const addresses = [_]std.Io.net.IpAddress{
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 8000 } },
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 8000 } },
    };
    admission.AdmissionBackend.white_box.replacePendingWithAddresses(&backend, 1, &addresses);
    backend.platform.fail_close = true;
    var batch: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&batch, 0));
    try std.testing.expectEqual(@as(usize, 1), backend.dial_close_retry_count);

    backend.platform.fail_close = false;
    var turns: usize = 0;
    while (backend.pending_dials.count() != 0) : (turns += 1) {
        try std.testing.expect(turns < 8);
        _ = try backend.poll(&batch, -1);
    }
    try std.testing.expectEqual(@as(usize, 0), backend.dial_close_retry_count);
    try std.testing.expectEqual(@as(usize, 1), backend.conns.count());
}

test "completion relay survives a refused resolver wake arm through bounded polling" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var backend = try admission.AdmissionBackend.initWithRelay(
        std.testing.allocator,
        8,
        1,
        64,
        .{
            .url = "ws://localhost:9/relay",
            .entropy_seed = [_]u8{0x72} ** std.Random.DefaultCsprng.secret_seed_length,
            .resolver_io = threaded.io(),
            .send_staging_bytes = admission.frame_cap,
        },
    );
    defer admission.deinitAdmissionBackend(&backend);
    backend.platform.fail_recv = true;

    const designator = [_]u8{'a'} ** 64;
    _ = try backend.startDial(9, .{ .keyed_relay = .{
        .designator = &designator,
        .relay = null,
    } });
    var batch: [4]net.completion.Completion = undefined;
    var turns: usize = 0;
    while (backend.conns.count() == 0) : (turns += 1) {
        try std.testing.expect(turns < 1_000);
        std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(1), .real) catch unreachable;
        _ = try backend.poll(&batch, 50);
    }
    backend.platform.fail_recv = false;
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
    try std.testing.expectEqual(@as(usize, 1), backend.platform.recv_attempts);
}

test "completion relay resolves a hostname off-loop and cancellation joins it" {
    if (@import("builtin").os.tag != .linux and !@import("builtin").os.tag.isDarwin()) return;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var backend = try net.KeyedRelayBackend.initWithRelay(
        std.testing.allocator,
        32,
        8,
        1024,
        .{
            .url = "ws://localhost:9/relay",
            .entropy_seed = [_]u8{0x71} ** std.Random.DefaultCsprng.secret_seed_length,
            .resolver_io = threaded.io(),
        },
    );
    defer backend.deinit();

    const designator = [_]u8{'a'} ** 64;
    const fd = try backend.startDial(10, .{ .keyed_relay = .{
        .designator = &designator,
        .relay = null,
    } });
    backend.shutdownFd(fd);
    try backend.submitClose(11, fd);

    var saw_connect = false;
    var saw_close = false;
    var turns: usize = 0;
    var batch: [8]net.completion.Completion = undefined;
    while (!saw_connect or !saw_close) : (turns += 1) {
        try std.testing.expect(turns < 100);
        const n = try backend.poll(&batch, 100);
        for (batch[0..n]) |result| switch (result.user_data) {
            10 => {
                try std.testing.expect(result.result < 0);
                const failure = result.borrowed.carrierFailureValue() orelse
                    return error.MissingResolverCancellation;
                try std.testing.expectEqual(error.Canceled, failure.chain.cause);
                try std.testing.expectEqual(net.carrier_failure.Phase.shutdown, failure.phase);
                backend.recycleBorrowed(result);
                saw_connect = true;
            },
            11 => {
                try std.testing.expectEqual(@as(i32, 0), result.result);
                saw_close = true;
            },
            else => return error.UnexpectedCompletion,
        };
    }
    backend.closeFd(fd);
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
}
