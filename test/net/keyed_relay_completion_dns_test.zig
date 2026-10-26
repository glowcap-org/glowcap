//! Async relay DNS and pre-admission dial-lifecycle evidence, including the
//! cap on how many addresses one answer may seat.

const std = @import("std");
const glowcap = @import("glowcap");
const admission = @import("../support/keyed_relay_admission.zig");
const crowded_lookup = @import("../support/crowded_lookup.zig");

const net = glowcap.net;
const address_cap = net.relay.white_box.max_resolved_addresses;

test "completion relay retries refused loser close admission without parking" {
    var backend = try admission.admissionBackend(std.testing.allocator);
    defer admission.deinitAdmissionBackend(&backend);
    const designator = @as([64]u8, @splat('a'));

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
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x72)),
            .resolver_io = threaded.io(),
            .send_staging_bytes = admission.frame_cap,
        },
    );
    defer admission.deinitAdmissionBackend(&backend);
    backend.platform.fail_recv = true;

    const designator = @as([64]u8, @splat('a'));
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
    try std.testing.expect(backend.platform.recv_attempts >= 1);
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
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(0x71)),
            .resolver_io = threaded.io(),
        },
    );
    defer backend.deinit();

    const designator = @as([64]u8, @splat('a'));
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

/// Dial through a lookup that answers `answer_len` loopback addresses. An
/// answer within the cap reaches a relay leg on the platform. One past it
/// fails the dial at the resolve phase and retires the pending row.
fn expectCrowdedDial(comptime answer_len: usize, seed: u8, expect_too_many: bool) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var crowded = crowded_lookup.Lookup(answer_len).init(threaded.io());
    var backend = try admission.AdmissionBackend.initWithRelay(
        std.testing.allocator,
        8,
        1,
        64,
        .{
            .url = "ws://relay.test:9/relay",
            .entropy_seed = @as([std.Random.DefaultCsprng.secret_seed_length]u8, @splat(seed)),
            .resolver_io = crowded.io(),
            .send_staging_bytes = admission.frame_cap,
        },
    );
    defer admission.deinitAdmissionBackend(&backend);
    // The platform has one recv seat, so the resolver's wake is left unarmed
    // and its completions are collected on each poll instead.
    backend.platform.fail_recv = true;

    const designator = @as([64]u8, @splat('a'));
    _ = try backend.startDial(12, .{ .keyed_relay = .{
        .designator = &designator,
        .relay = null,
    } });

    var batch: [4]net.completion.Completion = undefined;
    var failed: ?net.completion.Completion = null;
    var turns: usize = 0;
    while (backend.conns.count() == 0 and failed == null) : (turns += 1) {
        try std.testing.expect(turns < 1_000);
        // A spinning poll starves the resolver's task of the shared locks
        // the test allocator and the thread pool take.
        std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(1), .real) catch unreachable;
        const n = try backend.poll(&batch, 50);
        for (batch[0..n]) |result| {
            try std.testing.expectEqual(@as(u64, 12), result.user_data);
            failed = result;
        }
    }
    backend.platform.fail_recv = false;
    if (failed) |result| {
        try std.testing.expect(expect_too_many);
        try std.testing.expect(result.result < 0);
        const failure = result.borrowed.carrierFailureValue() orelse return error.MissingResolverFailure;
        try std.testing.expectEqualStrings("TooManyAddresses", failure.chain.primaryName());
        try std.testing.expectEqual(net.carrier_failure.Phase.resolve, failure.phase);
        backend.recycleBorrowed(result);
    } else {
        try std.testing.expect(!expect_too_many);
    }
    try std.testing.expectEqual(@as(usize, 0), backend.pending_dials.count());
}

test "completion relay admits a DNS answer of exactly the address cap" {
    try expectCrowdedDial(address_cap, 0x73, false);
}

test "completion relay refuses a DNS answer one address past the cap" {
    try expectCrowdedDial(address_cap + 1, 0x74, true);
}
