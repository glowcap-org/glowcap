//! The hermetic multiplexed residents the ADR-0024 hosting proofs drive:
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

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
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
    /// The introducer the most recent `startConnect` was given, copied out of
    /// the borrowed origin, so a proof can read who introduced a redeem dial.
    last_introducer: ?[128]u8 = null,
    last_introducer_len: usize = 0,
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
        origin: net.netlayer.DialOrigin,
    ) net.netlayer.DialError!void {
        const self = of(ctx);
        self.start_calls += 1;
        self.last_introducer = null;
        self.last_introducer_len = 0;
        if (origin.introducer) |introducer| {
            if (introducer.len > 128) return error.InvalidAddress;
            var copy: [128]u8 = undefined;
            @memcpy(copy[0..introducer.len], introducer);
            self.last_introducer = copy;
            self.last_introducer_len = introducer.len;
        }
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
        origin: net.netlayer.DialOrigin,
    ) net.MultiplexedDialRawStartOutcome {
        startConnectFallible(ctx, request_id, locator, options, origin) catch |err|
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
const accept_ownership = @import("residents/accept_ownership.zig");
pub const AcceptOwnershipResident = accept_ownership.AcceptOwnershipResident;
pub const IgnoreSessionOpen = accept_ownership.IgnoreSessionOpen;
pub const prepareAcceptOwnershipRuntime = accept_ownership.prepareAcceptOwnershipRuntime;
