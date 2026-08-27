//! Shared fixtures for the ADR-0112 host-wide step proofs: the greeter and
//! its step-serve pump, the close and failure observers, the recording
//! completion sink, and the dial recorder every staged-dial scenario reads.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../../support/actors.zig");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const driver_core = driver.core;
const net = pancake.net;
const tcp = net.tcp;

const frame_cap = 8192;

pub const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

pub const FailureCapture = struct {
    failure: ?driver.OperationFailure = null,

    pub fn report(ctx: *anyopaque, failure: driver.OperationFailure) void {
        const self: *FailureCapture = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.failure == null);
        self.failure = failure;
    }
};

pub const Treasure = support_actors.StaticReplyValueActor("greet", "hello from the step server");

/// Serve entirely step-shaped: accept one session, publish, then pump
/// nothing but poll(readiness) + `stepAny(0)` until told to stop. The
/// descriptor and the step are the whole loop, exactly the loop-archive
/// contract.
pub fn stepServe(
    server: *driver.Server,
    ready_fd: i32,
    closed_flag: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),
) anyerror!void {
    var observer_ctx = CloseFlag{ .flag = closed_flag };
    try server.runtime.setCloseObserver(.{ .ctx = &observer_ctx, .closed = CloseFlag.notify });
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("treasure", Treasure, .{});
    while (!stop.load(.acquire)) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 50) catch return error.PollFailed;
        if (fds[0].revents & std.posix.POLL.IN == 0) continue;
        // Drain to quiet: level-shaped members keep the descriptor readable
        // while anything is pending, so quiet means genuinely serviced.
        while (true) {
            const progress = server.runtime.stepAny(0) catch |err| switch (err) {
                error.ConnectionClosed, error.ProtocolAbort => break,
                else => |e| return e,
            };
            if (progress == null) break;
        }
    }
}

pub const CloseFlag = struct {
    flag: *std.atomic.Value(bool),
    pub fn notify(ctx: *anyopaque, session: *driver_core.HostSession, _: ?driver.OperationFailure) void {
        const self: *CloseFlag = @ptrCast(@alignCast(ctx));
        // A transport observer sees the physical completion only after the
        // core has retired session authority.
        if (session.isTerminating()) self.flag.store(true, .release);
    }
};

pub const DropSessionOnClose = struct {
    owned: *?*driver.Session,
    runtime: *driver.HostRuntime,
    dropped: bool = false,
    blocking_reentry_refused: bool = false,

    pub fn notify(ctx: *anyopaque, session: *driver_core.HostSession, _: ?driver.OperationFailure) void {
        const self: *DropSessionOnClose = @ptrCast(@alignCast(ctx));
        const owned = self.owned.* orelse return;
        std.debug.assert(owned.hs == session);
        self.blocking_reentry_refused = blk: {
            _ = self.runtime.stepAny(0) catch |err| break :blk err == error.ReenteredHost;
            break :blk false;
        };
        self.owned.* = null;
        owned.deinit();
        self.dropped = true;
    }
};

pub fn connectAndHold(
    allocator: std.mem.Allocator,
    io: std.Io,
    netlayer: net.netlayer.Netlayer,
    address: std.Io.net.IpAddress,
    stop: *const std.atomic.Value(bool),
) !void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(
        allocator,
        &.{netlayer},
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        opts,
    );
    defer session.deinit();
    while (!stop.load(.acquire))
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .real) catch {};
}

/// A sink that takes exactly the settled/failed completions and remembers
/// what it saw; it owns each taken action and frees it through the core.
pub const RecordingSink = struct {
    core: *driver_core.Host,
    settled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn take(ctx: *anyopaque, action: driver_core.HostAction) bool {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        switch (action) {
            .settled => |s| self.settled.store(s.vow_id, .release),
            .failed => |f| self.settled.store(f.vow_id, .release),
            else => return false,
        }
        self.core.freeAction(action);
        return true;
    }
};

/// Records a staged dial's or accept's outcome (`HostRuntime.SessionOpenObserver`).
pub const DialRecorder = struct {
    opened_session: ?*driver_core.HostSession = null,
    opened_tag: u64 = 0,
    opened_count: usize = 0,
    refuse_open: bool = false,
    failed_tag: u64 = 0,
    failed_err: ?anyerror = null,
    failure: ?driver.OperationFailure = null,

    pub fn opened(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) !void {
        const self: *DialRecorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_open) return error.ObserverRefused;
        self.opened_session = session;
        self.opened_tag = tag;
        self.opened_count += 1;
    }
    pub fn failed(ctx: *anyopaque, tag: u64, failure: driver.OperationFailure) void {
        const self: *DialRecorder = @ptrCast(@alignCast(ctx));
        self.failed_tag = tag;
        self.failed_err = failure.cause;
        self.failure = failure;
    }
};
