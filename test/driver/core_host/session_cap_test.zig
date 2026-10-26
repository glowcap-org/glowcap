//! The Host-wide cap on live sessions: a mint at the cap is refused and
//! reserves nothing, a released session frees its seat, the setter moves the
//! cap for the next mint, and a zero cap is refused at construction.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const harness = @import("harness.zig");

const driver = glowcap.driver;
const Host = driver.core.Host;
const frame_cap = harness.frame_cap;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;

test "host refuses a session past max_sessions and admits one after a release" {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.max_sessions = 2;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x71)), options);
    defer host.deinit();

    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7201", &.{});
    _ = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7202", &.{});
    try std.testing.expectError(error.SessionLimitReached, publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7203", &.{}));
    try std.testing.expectEqual(@as(usize, 2), host.sessions.count());

    try host.releaseSession(first);
    try std.testing.expectEqual(@as(usize, 1), host.sessions.count());
    _ = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7203", &.{});
}

test "the session-limit setter moves the cap and refuses zero" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x72)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    try std.testing.expectError(error.InvalidSessionLimit, host.setSessionLimits(null, null, null, null, 0));
    try host.setSessionLimits(null, null, null, null, 1);
    _ = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7211", &.{});
    try std.testing.expectError(error.SessionLimitReached, publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7212", &.{}));
}

test "a null cap leaves the session count unbounded and a zero cap is refused at construction" {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.max_sessions = 0;
    try std.testing.expectError(error.InvalidSessionLimit, Host.init(allocator, @splat(0x73), @splat(0x74), options));

    options.max_sessions = null;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x75)), options);
    defer host.deinit();
    for (0..3) |i| {
        var designator: [16]u8 = undefined;
        _ = try publishAndOpenAccepted(&host, "tcp", try std.fmt.bufPrint(&designator, "127.0.0.1:72{d:0>2}", .{20 + i}), &.{});
    }
    try std.testing.expectEqual(@as(usize, 3), host.sessions.count());
}
