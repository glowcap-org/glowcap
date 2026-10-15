//! Host full SessionLimits mint (ADR-0082) and Loop fan-in / park-kill Options.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../support/core_host.zig");

const Host = glowcap.driver.core.Host;
const engine = glowcap.ocapn.engine;
const publishAndOpenAcceptedOver = @import("../support/host_pair.zig").publishAndOpenAcceptedOver;

test "Host.Options projects full SessionLimits into minted peers" {
    const allocator = std.testing.allocator;
    var limits = engine.SessionLimits{};
    limits.max_frame_bytes = 4096;
    limits.queue_cap = 17;
    limits.max_imports = 42;
    var host = test_host.init(allocator, @as([32]u8, @splat(0xab)), .{ .limits = limits });
    defer host.deinit();

    try std.testing.expectEqual(@as(usize, 4096), host.opts.frameCap());
    try std.testing.expectEqual(@as(usize, 17), host.opts.limits.queue_cap);
    try std.testing.expectEqual(@as(usize, 42), host.opts.limits.max_imports);

    // Mint path uses negotiatingOptions → full limits, not frame-only.
    const opts = host.opts;
    try std.testing.expectEqual(limits.queue_cap, opts.limits.queue_cap);
    try std.testing.expectEqual(limits.max_imports, opts.limits.max_imports);
    try std.testing.expectEqual(limits.max_frame_bytes, opts.limits.max_frame_bytes);
}

test "Host.Options.withFrameCap only overrides admission" {
    const o = Host.Options.withFrameCap(8192);
    try std.testing.expectEqual(@as(usize, 8192), o.frameCap());
    try std.testing.expectEqual((engine.SessionLimits{}).queue_cap, o.limits.queue_cap);
}

test "Loop.Options fan_in_throttle and park_kill_ms default off" {
    const opts = glowcap.net.completion.Options{};
    try std.testing.expect(!opts.fan_in_throttle);
    try std.testing.expect(opts.park_kill_ms == null);
    try std.testing.expect(opts.on_park == null);
}

test "Host initialization returns invalid option failures before publication" {
    try std.testing.expectError(
        error.InvalidHostWorkQuantum,
        Host.init(std.testing.allocator, @as([32]u8, @splat(0x33)), @as([32]u8, @splat(0x34)), .{
            .host_work_quantum = 0,
        }),
    );
}

test "Host mint projects full SessionLimits onto an adopted peer" {
    const allocator = std.testing.allocator;
    var limits = engine.SessionLimits{};
    limits.max_frame_bytes = 4096;
    limits.queue_cap = 17;
    limits.max_imports = 42;

    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), .{ .limits = limits });
    defer server.deinit();

    var pinned = engine.Peer.initNegotiating(allocator);
    defer pinned.deinit();
    const adopted = try publishAndOpenAcceptedOver(&server, &pinned, "tcp", "127.0.0.1:7001", &.{});
    defer server.releaseSession(adopted) catch unreachable;

    try std.testing.expectEqual(@as(usize, 4096), pinned.session_state.limits.max_frame_bytes);
    try std.testing.expectEqual(@as(usize, 17), pinned.session_state.limits.queue_cap);
    try std.testing.expectEqual(@as(usize, 42), pinned.session_state.limits.max_imports);
}

test "Host refuses a full session operation counter before commit" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x4a)), .{});
    defer host.deinit();

    var pinned = engine.Peer.initNegotiating(allocator);
    defer pinned.deinit();
    const session = try publishAndOpenAcceptedOver(&host, &pinned, "tcp", "127.0.0.1:7002", &.{});
    defer host.releaseSession(session) catch unreachable;

    const pending_before = session.control.pending_operations;
    session.control.pending_operations = std.math.maxInt(u24);
    defer session.control.pending_operations = pending_before;
    try std.testing.expectError(error.SessionOperationLimitReached, host.admitSessionOperation(session));
}
