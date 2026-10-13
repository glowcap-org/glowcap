//! The hermetic multiplexed residents the ADR-0112 hosting proofs drive:
//! a TCP-backed fake speaking the `net.MultiplexedResident` contract exactly
//! (real loopback sockets behind one epoll descriptor, the shape the iroh
//! sidecar exposes), and an accept-capable sibling whose bookkeeping the
//! lifecycle and provider scenarios interrogate. Linux-only, like the other
//! epoll-shaped suites. `test/all_test.zig` gates the imports.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../../support/actors.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const driver_core = driver.core;
const net = glowcap.net;
const tcp = net.tcp;
const linux = std.os.linux;

pub const frame_cap = 8192;

pub const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .wire_buffer_bytes = 1024,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

pub const Treasure = support_actors.StaticReplyValueActor("greet", "hello from the exporter");

pub const Introducer = struct {
    treasure: driver.Capability,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "introduce")) return error.NoSuchMethod;
        return .{ .capability = self.treasure };
    }
};

/// A TCP multiplexed resident: loopback stream sockets behind one epoll
/// descriptor, speaking the `net.MultiplexedResident` contract exactly. The
/// `throttle` knob makes every other `try_write` refuse after arming
/// `EPOLLOUT`, so the retention path runs deterministically.
pub const FakeResident = struct {
    allocator: std.mem.Allocator,
    epfd: i32,
    next_conn: usize = 1,
    conns: std.AutoHashMapUnmanaged(usize, Conn) = .{},
    connecting: std.AutoHashMapUnmanaged(usize, i32) = .{},
    throttle: bool = false,
    fail_remote_key: bool = false,
    /// When set, every `try_read` delivers these bytes in place of the
    /// socket's and then ends the stream as `after` says, so a settle-path
    /// fault is pinned by exact bytes rather than timing. The socket's own
    /// bytes stay unread, which keeps the descriptor readable.
    scripted_inbound: ?ScriptedInbound = null,
    /// Fail this many `finishConnect` calls with `error.NetworkUnreachable`,
    /// then connect: a transient dial fault for the retry seam.
    fail_dial_transient: u32 = 0,
    /// Fail every `finishConnect` with `error.ConnectionRefused`: a permanent
    /// dial fault the retry policy must never re-issue.
    fail_dial_permanent: bool = false,
    /// Fail the `startConnect` call with this 1-based number using
    /// `error.NetworkUnreachable`, so a re-issued dial can fault at start.
    fail_start_on_call: u32 = 0,
    start_calls: u32 = 0,
    write_calls: usize = 0,
    write_blocks: usize = 0,

    pub const ScriptedInbound = struct {
        bytes: []const u8,
        after: enum { end_of_stream, fault },
        offset: usize = 0,
    };

    const Conn = struct { fd: i32, want_write: bool = false };
    /// Epoll user-data tag telling a connect-in-flight row from a live conn.
    const connect_tag: u64 = 1 << 63;
    const throttle_chunk: usize = 1024;

    const SockaddrIn = extern struct {
        family: linux.sa_family_t = linux.AF.INET,
        port: u16,
        addr: u32,
        zero: [8]u8 = @splat(0),
    };

    pub fn init(allocator: std.mem.Allocator) !FakeResident {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        return .{ .allocator = allocator, .epfd = @intCast(rc) };
    }

    pub fn deinit(self: *FakeResident) void {
        var conn_it = self.conns.valueIterator();
        while (conn_it.next()) |conn| _ = linux.close(conn.fd);
        self.conns.deinit(self.allocator);
        var dial_it = self.connecting.valueIterator();
        while (dial_it.next()) |fd| _ = linux.close(fd.*);
        self.connecting.deinit(self.allocator);
        _ = linux.close(self.epfd);
    }

    pub fn multiplexedResident(self: *FakeResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .dial = .{
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
        },
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_remote_key = connRemoteKey,
    };

    fn of(ctx: *anyopaque) *FakeResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn ctlEpoll(self: *FakeResident, op: u32, fd: i32, events: u32, data: u64) void {
        var ev = linux.epoll_event{ .events = events, .data = .{ .ptr = data } };
        _ = linux.epoll_ctl(self.epfd, op, fd, &ev);
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).epfd;
    }

    fn drainReady(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        var kernel: [32]linux.epoll_event = undefined;
        const cap = @min(out.len, kernel.len);
        const rc = linux.epoll_wait(self.epfd, &kernel, @intCast(cap), 0);
        if (linux.errno(rc) != .SUCCESS) return 0;
        const n: usize = rc;
        var written: usize = 0;
        for (kernel[0..n]) |ev| {
            if (ev.data.ptr & connect_tag != 0) {
                const request_id: usize = @intCast(ev.data.ptr & ~connect_tag);
                // One report per dial: deregister so the level-shaped
                // writable state cannot re-announce a connect already
                // claimed (or already abandoned).
                if (self.connecting.get(request_id)) |fd| {
                    self.ctlEpoll(linux.EPOLL.CTL_DEL, fd, 0, 0);
                }
                out[written] = .{ .subject = request_id, .events = net.multiplexed_resident.ev_connect };
                written += 1;
                continue;
            }
            const conn_id: usize = ev.data.ptr;
            const conn = self.conns.getPtr(conn_id) orelse continue;
            var bits: u32 = 0;
            if (ev.events & linux.EPOLL.IN != 0) {
                bits |= net.multiplexed_resident.ev_readable;
            }
            if (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
                // Real pollers coalesce final readable bytes and closure. The
                // host must drain progress and still apply the terminal bit.
                bits |= net.multiplexed_resident.ev_readable | net.multiplexed_resident.ev_closed;
            }
            if (ev.events & linux.EPOLL.OUT != 0 and conn.want_write) {
                bits |= net.multiplexed_resident.ev_writable;
                conn.want_write = false;
                self.ctlEpoll(linux.EPOLL.CTL_MOD, conn.fd, linux.EPOLL.IN, conn_id);
            }
            if (bits == 0) continue;
            out[written] = .{ .subject = conn_id, .events = bits };
            written += 1;
        }
        return written;
    }

    fn startConnectFallible(
        ctx: *anyopaque,
        request_id: usize,
        locator: model.PeerLocator,
        _: net.netlayer.OperationOptions,
    ) net.netlayer.DialError!void {
        const self = of(ctx);
        self.start_calls += 1;
        if (self.fail_start_on_call == self.start_calls) return error.NetworkUnreachable;
        const colon = std.mem.lastIndexOfScalar(u8, locator.designator, ':') orelse return error.InvalidAddress;
        const port = std.fmt.parseInt(u16, locator.designator[colon + 1 ..], 10) catch return error.InvalidAddress;
        var octets: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, locator.designator[0..colon], '.');
        for (&octets) |*octet| {
            const part = it.next() orelse return error.InvalidAddress;
            octet.* = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        }
        if (it.next() != null) return error.InvalidAddress;

        const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.ConnectionRefused;
        const fd: i32 = @intCast(sock_rc);
        errdefer _ = linux.close(fd);

        var addr = SockaddrIn{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &octets, .big)),
        };
        const conn_rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn));
        switch (linux.errno(conn_rc)) {
            .SUCCESS, .INPROGRESS => {},
            else => return error.ConnectionRefused,
        }
        try self.connecting.put(self.allocator, request_id, fd);
        self.ctlEpoll(linux.EPOLL.CTL_ADD, fd, linux.EPOLL.OUT, connect_tag | @as(u64, request_id));
    }

    fn finishConnectFallible(ctx: *anyopaque, request_id: usize) net.netlayer.DialError!usize {
        const self = of(ctx);
        const row = self.connecting.fetchRemove(request_id) orelse return error.ConnectionLost;
        const fd = row.value;
        if (self.fail_dial_permanent) {
            _ = linux.close(fd);
            return error.ConnectionRefused;
        }
        if (self.fail_dial_transient > 0) {
            self.fail_dial_transient -= 1;
            _ = linux.close(fd);
            return error.NetworkUnreachable;
        }
        var so_error: i32 = 0;
        var opt_len: linux.socklen_t = @sizeOf(i32);
        const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &opt_len);
        if (linux.errno(rc) != .SUCCESS or so_error != 0) {
            _ = linux.close(fd);
            return error.ConnectionRefused;
        }
        const conn_id = self.next_conn;
        self.next_conn += 1;
        self.conns.put(self.allocator, conn_id, .{ .fd = fd }) catch {
            _ = linux.close(fd);
            return error.OutOfMemory;
        };
        self.ctlEpoll(linux.EPOLL.CTL_ADD, fd, linux.EPOLL.IN, conn_id);
        return conn_id;
    }

    fn startConnect(
        ctx: *anyopaque,
        request_id: usize,
        locator: model.PeerLocator,
        options: net.netlayer.OperationOptions,
    ) net.MultiplexedDialRawStartOutcome {
        startConnectFallible(ctx, request_id, locator, options) catch |err|
            return .{ .failed = .init(err) };
        return .admitted;
    }

    fn finishConnect(ctx: *anyopaque, request_id: usize) net.MultiplexedDialRawFinishOutcome {
        const conn = finishConnectFallible(ctx, request_id) catch |err|
            return .{ .failed = .init(err) };
        return .{ .connected = conn };
    }

    fn cancelConnect(ctx: *anyopaque, request_id: usize) ?glowcap.foundation.FailureChain {
        const self = of(ctx);
        const row = self.connecting.fetchRemove(request_id) orelse return null;
        self.ctlEpoll(linux.EPOLL.CTL_DEL, row.value, 0, 0);
        _ = linux.close(row.value);
        return null;
    }

    fn tryRead(ctx: *anyopaque, conn_id: usize, buf: []u8) isize {
        const self = of(ctx);
        const conn = self.conns.get(conn_id) orelse return -1;
        if (self.scripted_inbound) |*script| {
            const remaining = script.bytes[script.offset..];
            if (remaining.len == 0) return switch (script.after) {
                .end_of_stream => 0,
                .fault => -1,
            };
            const n = @min(buf.len, remaining.len);
            @memcpy(buf[0..n], remaining[0..n]);
            script.offset += n;
            return @intCast(n);
        }
        const rc = linux.read(conn.fd, buf.ptr, buf.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => net.multiplexed_resident.would_block,
            else => -1,
        };
    }

    fn tryWrite(ctx: *anyopaque, conn_id: usize, bytes: []const u8) isize {
        const self = of(ctx);
        const conn = self.conns.getPtr(conn_id) orelse return -1;
        self.write_calls += 1;
        if (self.throttle and self.write_calls % 2 == 0) {
            self.write_blocks += 1;
            conn.want_write = true;
            self.ctlEpoll(linux.EPOLL.CTL_MOD, conn.fd, linux.EPOLL.IN | linux.EPOLL.OUT, conn_id);
            return net.multiplexed_resident.would_block;
        }
        const len = if (self.throttle) @min(bytes.len, throttle_chunk) else bytes.len;
        const rc = linux.write(conn.fd, bytes.ptr, len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => {
                self.write_blocks += 1;
                conn.want_write = true;
                self.ctlEpoll(linux.EPOLL.CTL_MOD, conn.fd, linux.EPOLL.IN | linux.EPOLL.OUT, conn_id);
                return net.multiplexed_resident.would_block;
            },
            else => return -1,
        }
    }

    fn connClose(ctx: *anyopaque, conn_id: usize) net.multiplexed_resident.TeardownOutcome {
        const self = of(ctx);
        const row = self.conns.fetchRemove(conn_id) orelse return .complete;
        self.ctlEpoll(linux.EPOLL.CTL_DEL, row.value.fd, 0, 0);
        _ = linux.close(row.value.fd);
        return .complete;
    }

    fn connRemoteKey(ctx: *anyopaque, conn_id: usize) net.multiplexed_resident.ContractError!?glowcap.foundation.crypto.PeerKey {
        if (of(ctx).fail_remote_key) return error.ProviderContract;
        _ = conn_id;
        return null;
    }
};

/// A listener-only resident for ownership injection. `announceAccept` makes
/// its readiness descriptor readable. `finishAccept` claims exactly one stable
/// id, and `connClose` counts the one terminal release that id must receive.
pub const AcceptOwnershipResident = struct {
    wake: net.wake_channel.WakeChannel,
    accept_ready: bool = false,
    claimed: bool = false,
    close_calls: usize = 0,
    drain_calls: usize = 0,
    listen_calls: usize = 0,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    accept_route: ?usize = null,
    dialed: [2]bool = @splat(false),
    hold_connect: bool = false,
    pending_connect: ?usize = null,
    pending_listener: ?usize = null,
    fail_drain: bool = false,
    fail_listener_finish: bool = false,
    cancel_connect_calls: usize = 0,
    cancel_listen_calls: usize = 0,
    fail_cancel_connect: bool = false,
    /// When set, draining leaves the readiness descriptor readable, so the
    /// resident reports ready on every wait.
    keep_ready: bool = false,
    /// When set, every dial start refuses with exactly this failure.
    dial_failure: ?net.netlayer.DialFailure = null,

    pub const transport = "x-accept-ownership";
    pub const alternate_transport = "x-accept-ownership-alt";
    const conn_id: usize = 41;

    const Listener = struct {
        resident: *AcceptOwnershipResident,
        transport: []const u8,
        route: usize,
        active: bool = true,
    };

    pub fn init() !AcceptOwnershipResident {
        return .{ .wake = try net.wake_channel.WakeChannel.open() };
    }

    pub fn deinit(self: *AcceptOwnershipResident) void {
        self.wake.deinit();
    }

    pub fn announceAccept(self: *AcceptOwnershipResident) void {
        for (self.listeners[0..self.listener_count]) |listener| {
            if (listener.active) return self.announceAcceptFor(listener.transport);
        }
        unreachable;
    }

    pub fn announceAcceptFor(self: *AcceptOwnershipResident, selected: []const u8) void {
        std.debug.assert(!self.accept_ready and !self.claimed);
        for (self.listeners[0..self.listener_count]) |listener| {
            if (listener.active and std.mem.eql(u8, listener.transport, selected)) {
                self.accept_route = listener.route;
                break;
            }
        }
        std.debug.assert(self.accept_route != null);
        self.accept_ready = true;
        _ = self.wake.nudge() catch unreachable;
    }

    pub fn multiplexedResident(self: *AcceptOwnershipResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .dial = .{
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
        },
        .listen = .{
            .listen = listen,
            .completion = .{
                .finish = finishListen,
                .cancel = cancelListen,
            },
            .local_locator = net.MultiplexedResident.adaptListenerLocator(localLocator),
            .canonicalize_locator = net.MultiplexedResident.adaptListenerCanonicalize(canonicalizeLocator),
            .finish_accept = net.MultiplexedResident.adaptFinishAccept(finishAccept),
            .stop_listen = stopListen,
        },
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_remote_key = connRemoteKey,
    };

    fn of(ctx: *anyopaque) *AcceptOwnershipResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).wake.read;
    }

    fn drainReady(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        self.drain_calls += 1;
        if (!self.keep_ready) self.wake.drain() catch unreachable;
        if (self.fail_drain) return error.ProviderContract;
        if (out.len == 0) return 0;
        if (self.pending_listener != null) {
            out[0] = .{ .subject = self.pending_listener.?, .events = net.multiplexed_resident.ev_listen };
            return 1;
        }
        if (!self.accept_ready) return 0;
        self.accept_ready = false;
        out[0] = .{
            .subject = self.accept_route orelse return 0,
            .events = net.multiplexed_resident.ev_accept,
        };
        return 1;
    }

    fn transportIndex(selected: []const u8) ?usize {
        if (std.mem.eql(u8, selected, transport)) return 0;
        if (std.mem.eql(u8, selected, alternate_transport)) return 1;
        return null;
    }

    fn canonicalTransport(selected: []const u8) ?[]const u8 {
        return switch (transportIndex(selected) orelse return null) {
            0 => transport,
            1 => alternate_transport,
            else => unreachable,
        };
    }

    fn startConnect(ctx: *anyopaque, request_id: usize, locator: model.PeerLocator, _: net.netlayer.OperationOptions) net.MultiplexedDialRawStartOutcome {
        const index = transportIndex(locator.transport) orelse
            return .{ .failed = .init(error.InvalidAddress) };
        const self = of(ctx);
        if (self.dial_failure) |failure| return .{ .failed = failure };
        self.dialed[index] = true;
        if (self.hold_connect) {
            self.pending_connect = request_id;
            return .admitted;
        }
        return .{ .failed = .init(error.InvalidAddress) };
    }

    fn finishConnect(_: *anyopaque, _: usize) net.MultiplexedDialRawFinishOutcome {
        return .{ .failed = .init(error.ConnectionLost) };
    }

    fn cancelConnect(ctx: *anyopaque, request_id: usize) ?glowcap.foundation.FailureChain {
        const self = of(ctx);
        self.cancel_connect_calls += 1;
        if (self.pending_connect == request_id) self.pending_connect = null;
        if (self.fail_cancel_connect) {
            var failure = glowcap.foundation.FailureChain.initNamed(error.ConnectionLost, "ResidentCancelFailed");
            failure.noteNamed(error.OutOfMemory, "ResidentCancelCleanupFailed");
            return failure;
        }
        return null;
    }

    fn listen(
        ctx: *anyopaque,
        route_id: usize,
        selected: []const u8,
        _: net.netlayer.ListenConfig,
    ) net.MultiplexedResident.RawListenStartOutcome {
        const self = of(ctx);
        const transport_name = canonicalTransport(selected) orelse
            return .{ .failed = .init(error.InvalidAddress) };
        self.listen_calls += 1;
        if (self.fail_drain or self.fail_listener_finish) {
            self.pending_listener = route_id;
            _ = self.wake.nudge() catch unreachable;
            return .{ .admitted = .pending };
        }
        if (self.listener_count == self.listeners.len)
            return .{ .failed = .init(error.BindFailed) };
        const listener = &self.listeners[self.listener_count];
        self.listener_count += 1;
        listener.* = .{
            .resident = self,
            .transport = transport_name,
            .route = route_id,
        };
        return .{ .admitted = .{ .ready = listener } };
    }

    fn finishListen(ctx: *anyopaque, route_id: usize) net.MultiplexedResident.RawListenFinishOutcome {
        const self = of(ctx);
        if (self.pending_listener == route_id) self.pending_listener = null;
        return .{ .failed = .init(error.BindFailed) };
    }

    fn cancelListen(ctx: *anyopaque, route_id: usize) ?glowcap.foundation.FailureChain {
        const self = of(ctx);
        self.cancel_listen_calls += 1;
        if (self.pending_listener != route_id) return null;
        self.pending_listener = null;
        return null;
    }

    fn localLocator(
        _: *anyopaque,
        listener_ctx: *anyopaque,
        selected: []const u8,
        allocator: std.mem.Allocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        const canonical = canonicalTransport(selected) orelse return error.InvalidAddress;
        if (!listener.active or !std.mem.eql(u8, canonical, listener.transport)) return error.InvalidAddress;
        return model.clonePeerLocator(allocator, .{
            .transport = canonical,
            .designator = "resident.test:1",
            .hints = model.Hints.emptyFalse(),
        });
    }

    fn canonicalizeLocator(
        _: *anyopaque,
        listener_ctx: *anyopaque,
        selected: []const u8,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        const canonical = canonicalTransport(selected) orelse return error.InvalidAddress;
        if (!listener.active or !std.mem.eql(u8, canonical, listener.transport) or
            !std.mem.eql(u8, locator.transport, canonical) or
            !std.mem.eql(u8, locator.designator, "resident.test:1")) return error.InvalidAddress;
        return model.clonePeerLocator(allocator, locator);
    }

    fn finishAccept(_: *anyopaque, listener_ctx: *anyopaque) net.netlayer.AcceptError!?usize {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        const self = listener.resident;
        if (!listener.active or self.accept_route != listener.route) return null;
        if (self.claimed) return null;
        self.claimed = true;
        return conn_id;
    }

    fn stopListen(_: *anyopaque, listener_ctx: *anyopaque) net.multiplexed_resident.TeardownOutcome {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        listener.active = false;
        if (listener.resident.accept_route == listener.route) listener.resident.accept_route = null;
        return .complete;
    }

    fn tryRead(_: *anyopaque, _: usize, _: []u8) isize {
        return net.multiplexed_resident.would_block;
    }

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) net.multiplexed_resident.TeardownOutcome {
        const self = of(ctx);
        std.debug.assert(conn == conn_id);
        self.close_calls += 1;
        return .complete;
    }

    fn connRemoteKey(_: *anyopaque, _: usize) net.multiplexed_resident.ContractError!?glowcap.foundation.crypto.PeerKey {
        return null;
    }
};

pub const IgnoreSessionOpen = struct {
    pub fn opened(_: *anyopaque, _: u64, _: *driver_core.HostSession) !void {}
    pub fn failed(_: *anyopaque, _: u64, _: driver.OperationFailure) void {}
};

pub fn prepareAcceptOwnershipRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    resident: *AcceptOwnershipResident,
) !driver.HostRuntime {
    var runtime = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    errdefer runtime.deinit();
    _ = try runtime.addResident(
        .{ .symbol = AcceptOwnershipResident.transport, .designator_scheme = .address },
        resident.multiplexedResident(),
    );
    var listener = try runtime.bindListener(AcceptOwnershipResident.transport, "", .inherit);
    errdefer if (runtime.closeListener(&listener)) |failure|
        runtime.noteTerminalOperationFailure(failure);
    try runtime.core.setAdvertisedLocator(.{
        .transport = AcceptOwnershipResident.transport,
        .designator = "resident.test:1",
        .hints = model.Hints.emptyFalse(),
    });
    try runtime.activateListener(&listener, 7, .{
        .ctx = resident,
        .opened = IgnoreSessionOpen.opened,
        .failed = IgnoreSessionOpen.failed,
    });
    _ = try runtime.stepAny(0); // Warm readiness scratch before injection.
    return runtime;
}
