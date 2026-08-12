//! The multiplexed-resident hosting proof (ADR-0112): `driver.HostRuntime` carries
//! a whole CapTP conversation over a transport it reaches only through the
//! `net.MultiplexedResident` vtable — one readiness descriptor, drained ready
//! records, and non-blocking try-I/O — beside nothing else in its dial table.
//!
//! The resident here is a hermetic TCP-backed fake: real loopback sockets
//! multiplexed behind one epoll descriptor, which is exactly the shape the
//! iroh sidecar exposes, so the far side is an ordinary stream-transport
//! server and every byte is identical to the stream path's. Linux-only, like
//! the other epoll-shaped suites; `test/all_test.zig` gates the import.
//!
//! The three-party test drives the seam's whole dial surface: the first
//! connect (`start_connect` through the awaiting pump), and the redeem dial a
//! give provokes *inside* a blocking call, which exercises the nested
//! connect wait. The throttled test drives the outbound retention contract:
//! a frame larger than the write window survives `would_block`, resumes on
//! `ev_writable`, and never reorders.
//!
//! Validated against injected defects: with `handleResidentEvent`'s
//! `ev_connect` arm dropped, the dial hangs to `HandshakeTimedOut` and both
//! tests fail; with `pushPendingResident` resuming from offset zero, the
//! throttled call dies on a corrupt frame. Restored, both pass.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const driver_core = driver.core;
const net = pancake.net;
const tcp = net.tcp;
const linux = std.os.linux;

const frame_cap = 8192;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .wire_buffer_bytes = 1024,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Treasure = support_actors.StaticReplyValueActor("greet", "hello from the exporter");

const Introducer = struct {
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
const FakeResident = struct {
    allocator: std.mem.Allocator,
    epfd: i32,
    next_conn: usize = 1,
    conns: std.AutoHashMapUnmanaged(usize, Conn) = .{},
    connecting: std.AutoHashMapUnmanaged(usize, i32) = .{},
    throttle: bool = false,
    write_calls: usize = 0,
    write_blocks: usize = 0,

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

    fn init(allocator: std.mem.Allocator) !FakeResident {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        return .{ .allocator = allocator, .epfd = @intCast(rc) };
    }

    fn deinit(self: *FakeResident) void {
        var conn_it = self.conns.valueIterator();
        while (conn_it.next()) |conn| _ = linux.close(conn.fd);
        self.conns.deinit(self.allocator);
        var dial_it = self.connecting.valueIterator();
        while (dial_it.next()) |fd| _ = linux.close(fd.*);
        self.connecting.deinit(self.allocator);
        _ = linux.close(self.epfd);
    }

    fn multiplexedResident(self: *FakeResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = net.MultiplexedResident.VTable{
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

    fn startConnect(
        ctx: *anyopaque,
        request_id: usize,
        locator: model.PeerLocator,
    ) net.netlayer.DialError!void {
        const self = of(ctx);
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

    fn finishConnect(ctx: *anyopaque, request_id: usize) net.netlayer.DialError!usize {
        const self = of(ctx);
        const row = self.connecting.fetchRemove(request_id) orelse return error.ConnectionLost;
        const fd = row.value;
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

    fn cancelConnect(ctx: *anyopaque, request_id: usize) void {
        const self = of(ctx);
        const row = self.connecting.fetchRemove(request_id) orelse return;
        self.ctlEpoll(linux.EPOLL.CTL_DEL, row.value, 0, 0);
        _ = linux.close(row.value);
    }

    fn tryRead(ctx: *anyopaque, conn_id: usize, buf: []u8) isize {
        const self = of(ctx);
        const conn = self.conns.get(conn_id) orelse return -1;
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

    fn connClose(ctx: *anyopaque, conn_id: usize) void {
        const self = of(ctx);
        const row = self.conns.fetchRemove(conn_id) orelse return;
        self.ctlEpoll(linux.EPOLL.CTL_DEL, row.value.fd, 0, 0);
        _ = linux.close(row.value.fd);
    }

    fn connRemoteKey(ctx: *anyopaque, conn_id: usize) net.multiplexed_resident.ContractError!?pancake.foundation.crypto.PeerKey {
        _ = ctx;
        _ = conn_id;
        return null;
    }
};

/// A listener-only resident for ownership injection. `announceAccept` makes
/// its readiness descriptor readable; `finishAccept` claims exactly one stable
/// id, and `connClose` counts the one terminal release that id must receive.
const AcceptOwnershipResident = struct {
    wake: net.wake_channel.WakeChannel,
    accept_ready: bool = false,
    claimed: bool = false,
    close_calls: usize = 0,
    drain_calls: usize = 0,
    start_listen_calls: usize = 0,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    accept_route: ?usize = null,
    dialed: [2]bool = @splat(false),

    const transport = "x-accept-ownership";
    const alternate_transport = "x-accept-ownership-alt";
    const conn_id: usize = 41;

    const Listener = struct {
        resident: *AcceptOwnershipResident,
        transport: []const u8,
        route: usize,
        active: bool = true,
    };

    fn init() !AcceptOwnershipResident {
        return .{ .wake = try net.wake_channel.WakeChannel.open() };
    }

    fn deinit(self: *AcceptOwnershipResident) void {
        self.wake.deinit();
    }

    fn announceAccept(self: *AcceptOwnershipResident) void {
        for (self.listeners[0..self.listener_count]) |listener| {
            if (listener.active) return self.announceAcceptFor(listener.transport);
        }
        unreachable;
    }

    fn announceAcceptFor(self: *AcceptOwnershipResident, selected: []const u8) void {
        std.debug.assert(!self.accept_ready and !self.claimed);
        for (self.listeners[0..self.listener_count]) |listener| {
            if (listener.active and std.mem.eql(u8, listener.transport, selected)) {
                self.accept_route = listener.route;
                break;
            }
        }
        std.debug.assert(self.accept_route != null);
        self.accept_ready = true;
        self.wake.nudge();
    }

    fn multiplexedResident(self: *AcceptOwnershipResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .dial = .{
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
        },
        .listen = .{
            .start_listen = startListen,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .finish_accept = finishAccept,
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
        self.wake.drain();
        if (!self.accept_ready or out.len == 0) return 0;
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

    fn startConnect(ctx: *anyopaque, _: usize, locator: model.PeerLocator) net.netlayer.DialError!void {
        const index = transportIndex(locator.transport) orelse return error.InvalidAddress;
        of(ctx).dialed[index] = true;
        return error.InvalidAddress;
    }

    fn finishConnect(_: *anyopaque, _: usize) net.netlayer.DialError!usize {
        return error.ConnectionLost;
    }

    fn cancelConnect(_: *anyopaque, _: usize) void {}

    fn startListen(
        ctx: *anyopaque,
        route_id: usize,
        selected: []const u8,
        _: []const u8,
    ) net.netlayer.ListenError!*anyopaque {
        const self = of(ctx);
        const transport_name = canonicalTransport(selected) orelse return error.InvalidAddress;
        if (self.listener_count == self.listeners.len) return error.BindFailed;
        const listener = &self.listeners[self.listener_count];
        self.listener_count += 1;
        listener.* = .{
            .resident = self,
            .transport = transport_name,
            .route = route_id,
        };
        self.start_listen_calls += 1;
        return listener;
    }

    fn listenerLocator(
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

    fn listenerAdvertise(
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

    fn stopListen(_: *anyopaque, listener_ctx: *anyopaque) void {
        const listener: *Listener = @ptrCast(@alignCast(listener_ctx));
        listener.active = false;
        if (listener.resident.accept_route == listener.route) listener.resident.accept_route = null;
    }

    fn tryRead(_: *anyopaque, _: usize, _: []u8) isize {
        return net.multiplexed_resident.would_block;
    }

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) void {
        const self = of(ctx);
        std.debug.assert(conn == conn_id);
        self.close_calls += 1;
    }

    fn connRemoteKey(_: *anyopaque, _: usize) net.multiplexed_resident.ContractError!?pancake.foundation.crypto.PeerKey {
        return null;
    }
};

const IgnoreSessionOpen = struct {
    fn opened(_: *anyopaque, _: u64, _: *driver_core.HostSession) void {}
    fn failed(_: *anyopaque, _: u64, _: anyerror) void {}
};

const ImmediateClosedExternalResident = struct {
    wake: net.wake_channel.WakeChannel,
    close_calls: usize = 0,

    const transport = "external-close";
    const conn_id: usize = 9;

    fn multiplexedResident(self: *ImmediateClosedExternalResident) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = net.MultiplexedResident.VTable{
        .readiness_fd = readinessFd,
        .drain_ready = drainReady,
        .external_claim = .{ .claim_external = claimExternal },
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_close = connClose,
        .conn_remote_key = connRemoteKey,
    };

    fn of(ctx: *anyopaque) *ImmediateClosedExternalResident {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        return of(ctx).wake.read;
    }

    fn drainReady(_: *anyopaque, _: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        return 0;
    }

    fn claimExternal(_: *anyopaque, subject: usize) net.netlayer.DialError!usize {
        if (subject != conn_id) return error.InvalidAddress;
        return conn_id;
    }

    fn tryRead(_: *anyopaque, _: usize, _: []u8) isize {
        return 0;
    }

    fn tryWrite(_: *anyopaque, _: usize, bytes: []const u8) isize {
        return @intCast(bytes.len);
    }

    fn connClose(ctx: *anyopaque, conn: usize) void {
        std.debug.assert(conn == conn_id);
        of(ctx).close_calls += 1;
    }

    fn connRemoteKey(_: *anyopaque, conn: usize) net.multiplexed_resident.ContractError!?pancake.foundation.crypto.PeerKey {
        std.debug.assert(conn == conn_id);
        return pancake.foundation.crypto.SecretKey.fromSeed([_]u8{0x5d} ** 32).publicKey();
    }
};

const ObservedOpen = struct {
    reservations: usize = 0,
    did_open: bool = false,
    failure: ?anyerror = null,
    close_events: usize = 0,

    fn of(ctx: *anyopaque) *ObservedOpen {
        return @ptrCast(@alignCast(ctx));
    }

    fn reserve(ctx: *anyopaque, _: u64) anyerror!void {
        of(ctx).reservations += 1;
    }

    fn release(ctx: *anyopaque, _: u64) void {
        const self = of(ctx);
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    fn opened(ctx: *anyopaque, _: u64, _: *driver_core.HostSession) void {
        const self = of(ctx);
        release(ctx, 0);
        self.did_open = true;
    }

    fn failed(ctx: *anyopaque, _: u64, err: anyerror) void {
        const self = of(ctx);
        release(ctx, 0);
        self.failure = err;
    }

    fn closed(ctx: *anyopaque, _: *driver_core.HostSession) void {
        of(ctx).close_events += 1;
    }
};

test "external adoption commits its pending-open owner before immediate EOF" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = ImmediateClosedExternalResident{
        .wake = try net.wake_channel.WakeChannel.open(),
    };
    defer resident.wake.deinit();

    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(.{
        .symbol = ImmediateClosedExternalResident.transport,
        .designator_scheme = .key,
    }, resident.multiplexedResident());

    var observed = ObservedOpen{};
    runtime.setCloseObserver(.{ .ctx = &observed, .closed = ObservedOpen.closed });
    try runtime.startAdoptExternal(
        ImmediateClosedExternalResident.transport,
        ImmediateClosedExternalResident.conn_id,
        .dialed,
        41,
        .{
            .ctx = &observed,
            .reserve = ObservedOpen.reserve,
            .release = ObservedOpen.release,
            .opened = ObservedOpen.opened,
            .failed = ObservedOpen.failed,
        },
    );

    try std.testing.expectEqual(@as(usize, 1), observed.reservations);
    try std.testing.expectEqual(@as(usize, 0), observed.close_events);
    try std.testing.expect(!observed.did_open);
    try std.testing.expect(observed.failure == null);

    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(@as(usize, 0), observed.reservations);
    try std.testing.expectEqual(driver.Error.ConnectionClosed, observed.failure.?);
    try std.testing.expectEqual(@as(usize, 0), observed.close_events);
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);
}

fn prepareAcceptOwnershipRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    resident: *AcceptOwnershipResident,
) !driver.HostRuntime {
    var runtime = try driver.HostRuntime.init(allocator, io, &.{}, .ephemeral, opts);
    errdefer runtime.deinit();
    _ = try runtime.addResident(
        .{ .symbol = AcceptOwnershipResident.transport, .designator_scheme = .address },
        resident.multiplexedResident(),
    );
    var listener = try runtime.bindListener(AcceptOwnershipResident.transport, "");
    errdefer runtime.closeListener(&listener);
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

fn exporterServe(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var first = try server.accept();
    defer first.deinit();
    _ = try first.publish("treasure", Treasure, .{});

    var second: ?*driver.Session = null;
    defer if (second) |s| s.deinit();

    while (!done.load(.acquire)) {
        if (second == null and try server.waitAcceptable(20)) {
            second = try server.accept();
        }
        _ = first.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

fn gifterServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    netlayers: []const net.netlayer.Netlayer,
    exporter_designator: []const u8,
    listener: net.netlayer.Listener,
    done: *std.atomic.Value(bool),
) anyerror!void {
    const local_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, local_locator);

    var runtime = try driver.HostRuntime.init(allocator, io, netlayers, .ephemeral, opts);
    defer runtime.deinit();

    try runtime.core.setAdvertisedLocator(local_locator);

    const treasure_session = try runtime.connectLocator(.{
        .transport = model.transport.tcp,
        .designator = exporter_designator,
        .hints = model.Hints.emptyFalse(),
    });
    var treasure_view = try driver.Session.view(&runtime, treasure_session);
    const treasure = try treasure_view.fetch("treasure");

    const hs = try runtime.acceptWire(listener, listener.transportName());
    var view = try driver.Session.view(&runtime, hs);
    _ = try view.publish("introducer", Introducer, .{ .treasure = treasure });
    while (!done.load(.acquire)) {
        _ = view.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

test "a resident-dialed session fetches, calls, and redeems a give through the resident (ADR-0112)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    var exporter = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer exporter.close() catch {};
    var exporter_addr_buf: [64]u8 = undefined;
    const exporter_designator = try allocator.dupe(u8, try exporter.localDesignator(&exporter_addr_buf));
    defer allocator.free(exporter_designator);

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var gifter_listener = try tcp_resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer gifter_listener.close();
    const gifter_locator = try gifter_listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, gifter_locator);

    var exporter_future = try io.concurrent(exporterServe, .{ &exporter, &done });
    var gifter_future = try io.concurrent(gifterServe, .{ allocator, io, &netlayers, exporter_designator, gifter_listener, &done });
    defer {
        done.store(true, .release);
        gifter_future.await(io) catch {};
        exporter_future.await(io) catch {};
    }

    // The recipient reaches everything through the fake resident: its dial
    // table holds no stream netlayer at all, so a stream fallback would fail
    // loudly with `UnknownTransport` instead of quietly rescuing the test.
    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    var recipient = try driver.HostRuntime.init(allocator, io, &.{}, .ephemeral, opts);
    defer recipient.deinit();
    _ = try recipient.addResident(
        model.transport.Known.tcp.metadata(),
        fake.multiplexedResident(),
    );

    const gifter_session = try recipient.connectLocator(gifter_locator);
    var view = try driver.Session.view(&recipient, gifter_session);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const introducer = try view.fetch("introducer");
    const introduced = try view.call(introducer, "introduce", &.{}, arena);
    if (introduced == .broken) std.debug.print("introduce broke: {s}\n", .{introduced.broken});
    try std.testing.expect(introduced == .fulfilled);
    try std.testing.expect(introduced.fulfilled == .capability);

    // The redeem dial the give provoked also went through the resident: two
    // live resident connections, none of any other kind.
    try std.testing.expectEqual(@as(usize, 2), fake.conns.count());

    const greeted = try view.call(introduced.fulfilled.capability, "greet", &.{}, arena);
    try std.testing.expect(greeted == .fulfilled and greeted.fulfilled == .string);
    try std.testing.expectEqualStrings("hello from the exporter", greeted.fulfilled.string);
}

test "a frame larger than the write window survives would_block and resumes in order (ADR-0112)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var done = std.atomic.Value(bool).init(false);

    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const designator = try allocator.dupe(u8, try server.localDesignator(&addr_buf));
    defer allocator.free(designator);

    const Sink = support_actors.StaticReplyValueActor("take", "took");
    const serveOne = struct {
        fn run(srv: *driver.Server, latch: *std.atomic.Value(bool)) anyerror!void {
            var session = try srv.accept();
            defer session.deinit();
            _ = try session.publish("sink", Sink, .{});
            while (!latch.load(.acquire)) {
                _ = session.stepReadable(20) catch |err| switch (err) {
                    error.ConnectionClosed, error.ProtocolAbort => break,
                    else => |e| return e,
                };
            }
        }
    }.run;
    var server_future = try io.concurrent(serveOne, .{ &server, &done });
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }

    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    var runtime = try driver.HostRuntime.init(allocator, io, &.{}, .ephemeral, opts);
    defer runtime.deinit();
    _ = try runtime.addResident(
        model.transport.Known.tcp.metadata(),
        fake.multiplexedResident(),
    );

    const session = try runtime.connectLocator(.{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    var foreign_runtime = try driver.HostRuntime.init(allocator, io, &.{}, .ephemeral, opts);
    defer foreign_runtime.deinit();
    try std.testing.expectError(
        driver.Error.SessionNotOwned,
        driver.Session.view(&foreign_runtime, session),
    );
    var view = try driver.Session.view(&runtime, session);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sink = try view.fetch("sink");

    // Throttle after the handshake so setup stays plain; the big-argument
    // call is what crosses the choked window.
    fake.throttle = true;
    const big = try arena.alloc(u8, 6000);
    @memset(big, 'x');
    const took = try view.call(sink, "take", &.{.{ .string = big }}, arena);
    try std.testing.expect(took == .fulfilled and took.fulfilled == .string);
    try std.testing.expectEqualStrings("took", took.fulfilled.string);

    // The window really refused mid-frame, and nothing stayed retained.
    try std.testing.expect(fake.write_blocks > 0);
    const wire = runtime.wires.get(session.peer_id).?;
    try std.testing.expect(wire.link.resident.pending == null);
}

test "HostRuntime refuses duplicate provider authority independent of provider shape" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tcp_resident = tcp.Resident{ .io = io };
    const nl = tcp_resident.netlayer();

    try std.testing.expectError(
        error.TransportAlreadyRegistered,
        driver.HostRuntime.init(allocator, io, &.{ nl, nl }, .ephemeral, opts),
    );

    var runtime = try driver.HostRuntime.init(allocator, io, &.{nl}, .ephemeral, opts);
    defer runtime.deinit();
    var fake = try FakeResident.init(allocator);
    defer fake.deinit();
    try std.testing.expectError(error.TransportAlreadyRegistered, runtime.addResident(
        model.transport.Known.tcp.metadata(),
        fake.multiplexedResident(),
    ));
}

test "failed provider batch preserves a shared live readiness descriptor" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try prepareAcceptOwnershipRuntime(std.testing.allocator, io, &resident);
    defer runtime.deinit();

    const multiplexed = resident.multiplexedResident();
    var indices = [_]?usize{ 97, 98 };

    try std.testing.expectError(
        error.TransportSemanticsConflict,
        runtime.addProviders(&.{
            .{ .multiplexed = .{
                .profile = .{ .symbol = "x-shared-readiness", .designator_scheme = .address },
                .resident = multiplexed,
            } },
            .{ .multiplexed = .{
                .profile = .{ .symbol = model.transport.tcp, .designator_scheme = .key },
                .resident = multiplexed,
            } },
        }, &indices),
    );
    try std.testing.expectEqual(@as(?usize, 97), indices[0]);
    try std.testing.expectEqual(@as(?usize, 98), indices[1]);
    try std.testing.expectError(error.UnknownTransport, runtime.core.transportProfile("x-shared-readiness"));

    resident.announceAccept();
    _ = try runtime.stepAny(1_000);
    try std.testing.expect(resident.claimed);
}

test "equal readiness descriptors do not merge distinct multiplexed residents" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, &.{}, .ephemeral, opts);
    defer runtime.deinit();

    var second_vtable = AcceptOwnershipResident.vtable;
    const first = resident.multiplexedResident();
    const second = net.MultiplexedResident{ .ctx = &resident, .vtable = &second_vtable };
    var indices = [_]?usize{ 97, 98 };
    try std.testing.expectError(
        error.ReadinessDescriptorConflict,
        runtime.addProviders(&.{
            .{ .multiplexed = .{
                .profile = .{ .symbol = "x-runtime-one", .designator_scheme = .address },
                .resident = first,
            } },
            .{ .multiplexed = .{
                .profile = .{ .symbol = "x-runtime-two", .designator_scheme = .address },
                .resident = second,
            } },
        }, &indices),
    );
    try std.testing.expectEqual(@as(?usize, 97), indices[0]);
    try std.testing.expectEqual(@as(?usize, 98), indices[1]);
    try std.testing.expectEqual(@as(usize, 0), runtime.residents.items.len);
}

test "two profiles share one multiplexed resident with independent listener lifecycles" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try driver.HostRuntime.init(std.testing.allocator, io, &.{}, .ephemeral, opts);
    defer runtime.deinit();

    const multiplexed = resident.multiplexedResident();
    var indices = [_]?usize{ null, null };
    try runtime.addProviders(&.{
        .{ .multiplexed = .{
            .profile = .{ .symbol = AcceptOwnershipResident.transport, .designator_scheme = .address },
            .resident = multiplexed,
        } },
        .{ .multiplexed = .{
            .profile = .{ .symbol = AcceptOwnershipResident.alternate_transport, .designator_scheme = .address },
            .resident = multiplexed,
        } },
    }, &indices);
    try std.testing.expectEqual(indices[0], indices[1]);
    try std.testing.expectEqual(@as(usize, 1), runtime.residents.items.len);

    inline for (.{ AcceptOwnershipResident.transport, AcceptOwnershipResident.alternate_transport }) |transport| {
        try runtime.core.setAdvertisedLocator(.{
            .transport = transport,
            .designator = "resident.test:1",
            .hints = model.Hints.emptyFalse(),
        });
        try std.testing.expectError(error.InvalidAddress, runtime.connectLocator(.{
            .transport = transport,
            .designator = "remote.test:1",
            .hints = model.Hints.emptyFalse(),
        }));
    }
    try std.testing.expectEqual([2]bool{ true, true }, resident.dialed);

    var listener = try runtime.bindListener(AcceptOwnershipResident.alternate_transport, "");
    var listener_open = true;
    defer if (listener_open) runtime.closeListener(&listener);
    var second_listener = try runtime.bindListener(AcceptOwnershipResident.transport, "");
    var second_listener_open = true;
    defer if (second_listener_open) runtime.closeListener(&second_listener);
    try std.testing.expectEqual(@as(usize, 2), resident.start_listen_calls);

    const locator = try runtime.listenerLocator(&listener);
    defer model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqualStrings(AcceptOwnershipResident.alternate_transport, locator.transport);
    try runtime.activateListener(&listener, 73, .{
        .ctx = &resident,
        .opened = IgnoreSessionOpen.opened,
        .failed = IgnoreSessionOpen.failed,
    });
    try runtime.activateListener(&second_listener, 74, .{
        .ctx = &resident,
        .opened = IgnoreSessionOpen.opened,
        .failed = IgnoreSessionOpen.failed,
    });

    resident.announceAcceptFor(AcceptOwnershipResident.alternate_transport);
    _ = try runtime.stepAny(1_000);
    try std.testing.expectEqual(@as(usize, 1), resident.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
    try std.testing.expectEqualStrings(
        AcceptOwnershipResident.alternate_transport,
        runtime.pending_opens.items[0].session.transport,
    );

    runtime.closeListener(&listener);
    listener_open = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);

    resident.claimed = false;
    resident.announceAcceptFor(AcceptOwnershipResident.transport);
    _ = try runtime.stepAny(1_000);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);
    try std.testing.expectEqualStrings(
        AcceptOwnershipResident.transport,
        runtime.pending_opens.items[0].session.transport,
    );
    runtime.closeListener(&second_listener);
    second_listener_open = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(usize, 2), resident.close_calls);
}

test "claimed resident accepts close exactly once across every adoption allocation failure" {
    var saw_claim_failure = false;
    var reached_success = false;

    for (0..64) |fail_offset| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = std.math.maxInt(usize);
        var resident = try AcceptOwnershipResident.init();
        defer resident.deinit();
        var runtime = try prepareAcceptOwnershipRuntime(failing.allocator(), io, &resident);

        failing.fail_index = failing.alloc_index + fail_offset;
        resident.announceAccept();
        const step_result = runtime.stepAny(1_000);
        failing.fail_index = std.math.maxInt(usize);

        if (step_result) |_| {
            reached_success = true;
            try std.testing.expect(resident.claimed);
            try std.testing.expectEqual(@as(usize, 0), resident.close_calls);
            try std.testing.expectEqual(@as(usize, 1), runtime.resident_wires.count());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (resident.claimed) saw_claim_failure = true;
            const wire_owns = runtime.resident_wires.count() == 1;
            try std.testing.expectEqual(
                @as(usize, 1),
                resident.close_calls + @intFromBool(wire_owns),
            );
        }

        runtime.deinit();
        if (resident.claimed) try std.testing.expectEqual(@as(usize, 1), resident.close_calls);
        if (reached_success) break;
    }

    try std.testing.expect(saw_claim_failure);
    try std.testing.expect(reached_success);
}

test "successful resident accept transfers close ownership to the wire" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try AcceptOwnershipResident.init();
    defer resident.deinit();
    var runtime = try prepareAcceptOwnershipRuntime(std.testing.allocator, io, &resident);

    resident.announceAccept();
    _ = try runtime.stepAny(1_000);
    try std.testing.expect(resident.claimed);
    try std.testing.expectEqual(@as(usize, 0), resident.close_calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.resident_wires.count());

    runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);
}
