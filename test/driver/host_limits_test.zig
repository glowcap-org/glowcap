//! Host full SessionLimits mint (ADR-0082) and Loop fan-in / park-kill Options.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");

const Host = pancake.driver.core.Host;
const engine = pancake.ocapn.engine;
const publishAndOpenAcceptedOver = @import("../support/host_pair.zig").publishAndOpenAcceptedOver;

test "Host.Options projects full SessionLimits into minted peers" {
    const allocator = std.testing.allocator;
    var limits = engine.SessionLimits{};
    limits.max_frame_bytes = 4096;
    limits.queue_cap = 17;
    limits.max_imports = 42;
    var host = test_host.init(allocator, [_]u8{0xab} ** 32, .{ .limits = limits });
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
    const opts = pancake.net.completion.Options{};
    try std.testing.expect(!opts.fan_in_throttle);
    try std.testing.expect(opts.park_kill_ms == null);
    try std.testing.expect(opts.on_park == null);
}

test "Host.Options names bootstrap_durability posture" {
    const o = Host.Options{};
    try std.testing.expectEqual(Host.BootstrapDurability.ephemeral, o.bootstrap_durability);
    // `.durable_bootstrap` remains a named arm for the embedder-store contract;
    // `Host.init` panics if selected until that store lands (no silent ephemeral twin).
    var durable = Host.Options{};
    durable.bootstrap_durability = .durable_bootstrap;
    try std.testing.expectEqual(Host.BootstrapDurability.durable_bootstrap, durable.bootstrap_durability);
}

test "Host mint projects full SessionLimits onto an adopted peer" {
    const allocator = std.testing.allocator;
    var limits = engine.SessionLimits{};
    limits.max_frame_bytes = 4096;
    limits.queue_cap = 17;
    limits.max_imports = 42;

    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, .{ .limits = limits });
    defer server.deinit();

    var pinned = engine.Peer.initNegotiating(allocator);
    defer pinned.deinit();
    const adopted = try publishAndOpenAcceptedOver(&server, &pinned, "tcp", "127.0.0.1:7001", &.{});
    defer server.releaseSession(adopted) catch {};

    try std.testing.expectEqual(@as(usize, 4096), pinned.session_state.limits.max_frame_bytes);
    try std.testing.expectEqual(@as(usize, 17), pinned.session_state.limits.queue_cap);
    try std.testing.expectEqual(@as(usize, 42), pinned.session_state.limits.max_imports);
}
