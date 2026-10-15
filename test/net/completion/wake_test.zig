//! The completion loop's wake seam: an initial submission failure is
//! transactional and exact, a rearm failure escapes the loop with its cause,
//! and shutdown cancels an idle armed recv, or a racing ready wake, before
//! backend teardown, running no handler.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const Loop = glowcap.net.TcpLoop;
const completion = glowcap.net.completion;
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const no_dial = @import("../../support/no_dial_locator.zig");

const backend_support = @import("cross_arm_backend.zig");
const CrossArmBackend = backend_support.CrossArmBackend;
const startSession = backend_support.startSession;
const makeServerPeer = backend_support.makeServerPeer;
const drainOutboundBytes = backend_support.drainOutboundBytes;
const drainOutboundStreamBytes = backend_support.drainOutboundStreamBytes;

fn countWake(ctx: ?*anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(ctx.?));
    count.* += 1;
}

test "completion wake: initial submission failure is transactional and exact" {
    const allocator = std.testing.allocator;
    CrossArmBackend.chunks = &.{};
    CrossArmBackend.eof_when_exhausted = false;
    CrossArmBackend.fail_wake_submit_at = 1;
    defer CrossArmBackend.fail_wake_submit_at = null;

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(
        allocator,
        makeServerPeer,
        null,
        .{ .max_conns = 1 },
    );
    defer loop.deinit();

    var wake_count: usize = 0;
    try std.testing.expectError(error.WakeSubmitRefused, loop.armWake(99, &wake_count, countWake));
    try loop.closeAndDrain();
    try std.testing.expectEqual(@as(usize, 0), wake_count);
}

const WakeRunProbe = struct {
    count: usize = 0,
    done: std.atomic.Value(bool) = .init(false),

    fn wake(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        self.done.store(true, .release);
    }
};

test "completion wake: rearm failure escapes the loop with its exact cause" {
    const allocator = std.testing.allocator;
    const nudge = [_]u8{1};
    CrossArmBackend.chunks = &.{&nudge};
    defer CrossArmBackend.chunks = &.{};
    CrossArmBackend.eof_when_exhausted = false;
    CrossArmBackend.fail_wake_submit_at = 2;
    defer CrossArmBackend.fail_wake_submit_at = null;

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(
        allocator,
        makeServerPeer,
        null,
        .{ .max_conns = 1 },
    );
    defer loop.deinit();

    var probe: WakeRunProbe = .{};
    try loop.armWake(99, &probe, WakeRunProbe.wake);
    try std.testing.expectError(error.WakeSubmitRefused, loop.runUntil(&probe.done, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try loop.closeAndDrain();
}

test "completion wake: shutdown cancels an idle armed recv before backend teardown" {
    const allocator = std.testing.allocator;
    CrossArmBackend.chunks = &.{};
    CrossArmBackend.eof_when_exhausted = false;

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(
        allocator,
        makeServerPeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    var wake_count: usize = 0;
    try loop.armWake(99, &wake_count, countWake);
    try loop.closeAndDrain();

    try std.testing.expectEqual(@as(usize, 0), wake_count);
    try std.testing.expect(loop.backend.pending_recv == null);
}

test "completion wake: a ready wake racing shutdown runs no handler and does not rearm" {
    const allocator = std.testing.allocator;
    const nudge = [_]u8{1};
    CrossArmBackend.chunks = &.{&nudge};
    defer CrossArmBackend.chunks = &.{};
    CrossArmBackend.eof_when_exhausted = false;
    CrossArmBackend.refuse_cancel = true;
    defer CrossArmBackend.refuse_cancel = false;

    var loop = try completion.Loop(CrossArmBackend, no_dial.Unsupported).init(
        allocator,
        makeServerPeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    var wake_count: usize = 0;
    try loop.armWake(99, &wake_count, countWake);
    try std.testing.expectError(error.SubmissionQueueFull, loop.closeAndDrain());
    try loop.closeAndDrain();

    try std.testing.expectEqual(@as(usize, 0), wake_count);
    try std.testing.expect(loop.backend.pending_recv == null);
}
