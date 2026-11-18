//! A short stream write across a stepped runtime's wait (ADR-0018). A foreign
//! provider's `try_write` hands the kernel fewer bytes than it was offered,
//! and the external completion backend queues the number of bytes written.
//! No descriptor reports that completion, so the resident must report it
//! through `ready_pending`: the runtime then services it before it parks, or
//! raises the embedder's readiness descriptor. The full write is the matched
//! healthy control, where nothing is held and the runtime stays quiet.
//!
//! The connection comes from `startDial` through a real provider and
//! `Resident.adopt`, and the bytes cross a real socketpair. Every public call
//! is a stepped `stepAny`, driven only by the readiness descriptor.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const fixtures = @import("residents.zig");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const external = net.external_completion;

const ExternalBackend = external.CompletionBackend(net.Backend);
const ExternalResident = net.completion_resident.Resident(ExternalBackend, external.ResidentPolicy(ExternalBackend, external.PlatformRefused(net.Backend)));

const frame_cap = 4096;
const payload = "ABCDEFGH";
/// The longest the test waits for a wake that must come. A wake that never
/// comes costs this once, then fails.
const wake_bound_ms = 2_000;
/// How long a quiet runtime must stay quiet.
const quiet_ms = 150;

/// A stream provider over a real socketpair. One `try_write` hands the kernel
/// at most `cap` bytes and reports the count the kernel took.
const Provider = struct {
    pair: net.wake_channel.WakeChannel,
    cap: usize,
    write_calls: usize = 0,
    short_calls: usize = 0,

    fn of(ctx: *anyopaque) *Provider {
        return @ptrCast(@alignCast(ctx));
    }

    fn startConnect(ctx: *anyopaque, _: model.PeerLocator) external.Started {
        return .{ .ready = .{ .ptr = ctx, .fd = of(ctx).pair.write } };
    }

    fn finishConnect(_: *anyopaque, _: *anyopaque) external.Finished {
        return .{ .failed = error.Unexpected };
    }

    fn cancelConnect(_: *anyopaque, _: *anyopaque) void {}

    fn tryRead(ctx: *anyopaque, _: *anyopaque, buf: []u8) net.completion.TryRead {
        const rc = std.c.read(of(ctx).pair.write, buf.ptr, buf.len);
        if (rc > 0) return .{ .transferred = @intCast(rc) };
        if (rc == 0) return .closed;
        return if (std.posix.errno(rc) == .AGAIN) .would_block else .{ .failed = error.ReadFailed };
    }

    fn tryWrite(ctx: *anyopaque, _: *anyopaque, bytes: []const u8) net.completion.TryWrite {
        const self = of(ctx);
        const rc = std.c.write(self.pair.write, bytes.ptr, @min(bytes.len, self.cap));
        if (rc < 0) return if (std.posix.errno(rc) == .AGAIN) .would_block else .{ .failed = error.WriteFailed };
        const taken: usize = @intCast(rc);
        self.write_calls += 1;
        if (taken < bytes.len) self.short_calls += 1;
        return .{ .transferred = taken };
    }

    fn connClose(_: *anyopaque, _: *anyopaque) void {}

    const vtable: external.VTable = .{
        .start_connect = startConnect,
        .finish_connect = finishConnect,
        .cancel_connect = cancelConnect,
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = .{ .plain = connClose },
    };

    fn provider(self: *Provider) external.Provider {
        return .{ .transport = model.transport.tcp, .ctx = self, .vtable = &vtable };
    }

    /// Move what the peer end holds into `got`.
    fn drainPeer(self: *const Provider, got: *[payload.len]u8, have: *usize) !void {
        while (have.* < got.len) {
            const rc = std.c.read(self.pair.read, got[have.*..].ptr, got.len - have.*);
            if (rc == 0) return error.PeerClosed;
            if (rc < 0) switch (std.posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => return,
                else => return error.PeerReadFailed,
            };
            have.* += @intCast(rc);
        }
    }
};

fn readable(fd: i32, timeout_ms: i32) !bool {
    var rows = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&rows, timeout_ms);
    return rows[0].revents & std.posix.POLL.IN != 0;
}

const Shape = struct {
    /// Bytes one provider write may hand the kernel.
    cap: usize,
    /// Register the nonparking sibling, so the runtime waits on descriptors
    /// without a parking resident.
    sibling: bool,
    /// The first step's wait: zero is nonblocking, positive is a bounded wait.
    first_step_ms: i32,
};

fn run(shape: Shape) !void {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var prov: Provider = .{ .pair = try net.wake_channel.WakeChannel.open(), .cap = shape.cap };
    defer prov.pair.deinit();
    const providers = [_]external.Provider{prov.provider()};
    var ext = try ExternalResident.init(allocator, try ExternalBackend.initWithPlatform(allocator, .{ .providers = &providers }, try net.Backend.init(allocator, 64, 16, frame_cap), 16, frame_cap), .{});
    defer {
        ext.closeAndDrain(2_000) catch |err| std.debug.panic("external resident drain failed: {t}", .{err});
        ext.deinit();
    }
    const fd = try ext.backend.startDial(1, .{ .external = .{
        .transport = model.transport.tcp,
        .designator = "short-write",
        .hints = model.Hints.emptyFalse(),
    } });
    var dialed: [4]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try ext.backend.poll(&dialed, 0));
    try std.testing.expectEqual(@as(i32, 0), dialed[0].result);
    const conn = try ext.adopt(fd);

    // The sibling outlives the runtime that borrows it: defers run last in,
    // first out, so it is declared before the runtime.
    var sibling: fixtures.ExternalAdoptionResident = .{ .wake = try net.wake_channel.WakeChannel.open() };
    defer sibling.deinit();
    var observed: fixtures.ObservedOpen = .{};
    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, observed.steppedOpts());
    defer runtime.deinit();
    _ = try runtime.addResident(model.transport.Known.tcp.metadata(), ext.resident());
    if (shape.sibling) _ = try runtime.addResident(.{ .symbol = fixtures.ExternalAdoptionResident.transport, .designator_scheme = .address }, sibling.multiplexedResident());
    const rfd = try runtime.readinessDescriptor();

    // Settle the adopt: its armed receive parks on the provider descriptor.
    for (0..3) |_| _ = try runtime.stepAny(0);
    try std.testing.expect(!try readable(rfd, 0));
    try std.testing.expect(!ext.resident().readyPending());

    var got: [payload.len]u8 = undefined;
    var have: usize = 0;
    try std.testing.expectEqual(@as(isize, payload.len), ext.resident().tryWrite(conn, payload));
    ext.resident().flushWrites(conn);

    // The first normal stepped turn, under a script with no errnos: it
    // records the timeout of every raw descriptor poll the turn makes and
    // leaves the kernel's answer alone. A held completion is serviced before
    // the park, so the turn never enters a poll that can sleep.
    var script: net.poll.testing.Script = .{ .errnos = &.{} };
    {
        const guard = net.poll.testing.inject(&script);
        defer guard.deinit();
        _ = try runtime.stepAny(shape.first_step_ms);
    }
    try std.testing.expect(script.calls <= script.timeouts.len);
    for (script.timeouts[0..script.calls]) |timeout_ms| try std.testing.expectEqual(@as(i32, 0), timeout_ms);
    try prov.drainPeer(&got, &have);
    if (have == payload.len) {
        try std.testing.expect(!ext.conns.getPtr(conn).?.sending);
        try std.testing.expectEqual(@as(usize, 0), ext.backend.ready.len());
    } else {
        try std.testing.expect(shape.cap < payload.len);
    }

    // Every further turn waits for the descriptor to wake. The loop runs
    // until the peer holds every byte and the backend holds no completion and
    // the connection no send in flight: moved bytes do not prove the last
    // completion was consumed.
    var turns: usize = 0;
    while (have < payload.len or ext.conns.getPtr(conn).?.sending or ext.backend.ready.len() != 0) : (turns += 1) {
        try std.testing.expect(turns < 2 * payload.len);
        try std.testing.expect(try readable(rfd, wake_bound_ms));
        _ = try runtime.stepAny(0);
        try prov.drainPeer(&got, &have);
    }
    try std.testing.expectEqualStrings(payload, got[0..have]);

    // Quiet once the work settled, with no extra turn. A wake posted before
    // the last turn consumed it is consumed by a turn only when observed.
    if (try readable(rfd, 0)) _ = try runtime.stepAny(0);
    try std.testing.expect(!ext.resident().readyPending());
    try std.testing.expect(!try readable(rfd, quiet_ms));
    try std.testing.expectEqual(@as(i32, -1), runtime.stepWaitMs());
    if (shape.cap >= payload.len) {
        try std.testing.expectEqual(@as(usize, 1), prov.write_calls);
        try std.testing.expectEqual(@as(usize, 0), prov.short_calls);
    } else {
        try std.testing.expect(prov.short_calls > 1);
    }
}

test "a full stream write leaves nothing held and the runtime quiet" {
    try run(.{ .cap = 1 << 20, .sibling = true, .first_step_ms = 0 });
}

test "a short stream write is serviced across a mixed positive wait" {
    try run(.{ .cap = 1, .sibling = true, .first_step_ms = 250 });
}

test "a short stream write is serviced by a parking resident alone" {
    try run(.{ .cap = 1, .sibling = false, .first_step_ms = 0 });
}
