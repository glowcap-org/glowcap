//! The Darwin kqueue completion backend for `completion.Loop`.
//!
//! This file implements the completion-backend interface documented in
//! `completion.Loop` (`loop.zig`). The portable connection orchestration lives
//! there. This file provides only the platform completion primitive and native
//! TCP socket primitives. Linux selects between the io_uring and
//! epoll siblings through `linux.zig`. The server logic does not change between
//! them.
//!
//! kqueue is a *readiness* interface, not a completion one: `kevent` reports that
//! an fd is ready to read or write, not that a transfer finished. This backend
//! adapts readiness to the completion-shaped interface. `submit*` registers a
//! one-shot interest and records the pending operation. `poll` performs the
//! actual `accept`, `recv`, `send`, or connect completion check once the fd is
//! ready, then returns a
//! synthesized completion with the syscall's result. `close` needs no readiness,
//! so it runs immediately and its completion is queued for the next `poll`.
//!
//! The shared read-buffer pool (ADR-0054) is a `BufferPool` owned here: a
//! readiness backend reads at poll time, so `poll` acquires a scratch buffer,
//! performs the `recv` into it and lends it to the loop on the completion.
//! `recycleBorrowed` reclaims it. Buffers are allocated lazily up to the pool size,
//! and a read-ready fd that finds the pool empty completes with
//! `Completion.recv_no_buffer`: pool contention, never a connection error.
//!
//! `zig build check` runs `cross-check`, which compiles the whole library for
//! `aarch64-macos`. This catches type errors from a Linux host, but it cannot run
//! the backend. Runtime proof requires a macOS machine or CI runner. Review this
//! backend against the same completion contract as both Linux backends, then run
//! it on macOS before trusting a behavior change in production.

const std = @import("std");
const builtin = @import("builtin");

const completion = @import("loop.zig");
const model = @import("model");
const BufferPool = @import("buffer_pool.zig").BufferPool;
const socket_tcp = @import("socket_tcp.zig");
const tcp_keepalive = @import("tcp_keepalive.zig");

comptime {
    if (!builtin.os.tag.isDarwin()) @compileError("the kqueue completion backend is for Darwin");
}

const c = std.c;
const tcp_os = socket_tcp.Os.darwin;

// close(2) is not re-exported as public from std.c; declare it. Socket open /
// bind / listen / nonblocking live in `socket_tcp`.
extern "c" fn close(fd: c_int) c_int;

const EV_ERROR: u16 = 0x4000;

const sockaddr_in = socket_tcp.SockaddrIn(tcp_os);

/// What a registered fd is waiting to do, so `poll` can complete it on readiness.
/// Read and write are tracked separately because one connection can have a recv
/// and a send outstanding at the same time. Tagged unions carry the op kind so
/// poll sites cannot misread a recv as an accept or a send as a connect.
const Pending = struct {
    read: union(enum) {
        idle,
        recv: u64,
        accept: u64,
    } = .idle,
    write: union(enum) {
        idle,
        send: struct { ud: u64, bytes: []const u8 },
        connect: u64,
    } = .idle,
};

pub const Backend = struct {
    pub const Fd = c.fd_t;
    pub const adapter_depth = 0;
    /// Platform dial target: a resolved `IpAddress`. OCapN locator resolve
    /// lives on `tcp.DialResolver`, not on this platform Backend.
    pub const ConnectTarget = std.Io.net.IpAddress;
    pub const ListenerAddress = socket_tcp.Ip4;

    allocator: std.mem.Allocator,
    kq: c.fd_t,
    /// One row per descriptor with an armed direction. The map grows only when
    /// concurrent armed descriptors reach a new peak, then retains capacity so
    /// steady re-arm is allocation-free. A readiness event names an fd, and
    /// one fd may carry both a read and a write operation, so the backend needs
    /// this join from kernel identity to the two exact completion identities.
    pending: std.AutoHashMap(c.fd_t, Pending),
    /// Completions that need no readiness (closes), drained before blocking.
    ready: completion.ReadyQueue,
    /// The shared recv scratch pool (ADR-0054).
    buffer_pool: BufferPool,
    /// The local IPv4 address used by the one listener. The port remains loop
    /// policy and arrives later through `openListener`.
    listener_ip4: [4]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        return initWithListenerIp4(
            allocator,
            queue_entries,
            read_buffers,
            read_buffer_bytes,
            .{ 127, 0, 0, 1 },
        );
    }

    /// Build a backend whose listener binds `listener_ip4`. The ordinary
    /// constructor keeps the least-exposed default, `127.0.0.1`; a service
    /// intended for other hosts can opt into an interface address or
    /// `0.0.0.0` before moving the backend into `Loop.initWithBackend`.
    pub fn initWithListenerIp4(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
        listener_ip4: [4]u8,
    ) !Backend {
        // kqueue has no submission ring to size: `queue_entries` is the
        // io_uring backend's ring-depth hint, taken here only because both
        // backends share the one `init` signature.
        _ = queue_entries;
        const kq = c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        errdefer _ = close(kq);

        var buffer_pool = try BufferPool.init(allocator, read_buffers, read_buffer_bytes);
        errdefer buffer_pool.deinit();

        return .{
            .allocator = allocator,
            .kq = kq,
            .pending = std.AutoHashMap(c.fd_t, Pending).init(allocator),
            .ready = .{},
            .buffer_pool = buffer_pool,
            .listener_ip4 = listener_ip4,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.buffer_pool.deinit();
        self.pending.deinit();
        self.ready.deinit(self.allocator);
        _ = close(self.kq);
    }

    /// Reclaim a recv completion's scratch buffer. This base backend creates
    /// only receive borrows; wrappers consume their own richer borrows.
    /// Sockets carry no lower-layer peer identity: the total Backend
    /// contract's `verifiedChannelKey` member (ADR-0097) always answers null.
    pub fn verifiedChannelKey(self: *Backend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn applyKeepalive(_: *Backend, fd: Fd, keepalive: completion.Keepalive) tcp_keepalive.ApplyError!void {
        return tcp_keepalive.apply(@intCast(fd), keepalive);
    }

    pub fn wireFraming(_: *Backend, _: Fd) model.transport.WireFraming {
        return .byte_stream;
    }

    pub fn recycleBorrowed(self: *Backend, comp: completion.Completion) void {
        std.debug.assert(comp.borrowed.kind == .recv);
        self.buffer_pool.release(@intCast(comp.borrowed.token));
    }

    const ReservedSlot = struct {
        pending: *Pending,
        inserted: bool,
    };

    fn reserveSlot(self: *Backend, fd: c.fd_t) !ReservedSlot {
        const gop = try self.pending.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return .{ .pending = gop.value_ptr, .inserted = !gop.found_existing };
    }

    fn rollbackSlot(self: *Backend, fd: c.fd_t, reserved: ReservedSlot) void {
        if (!reserved.inserted) return;
        std.debug.assert(reserved.pending.read == .idle and reserved.pending.write == .idle);
        std.debug.assert(self.pending.remove(fd));
    }

    fn register(self: *Backend, fd: c.fd_t, filter: i16) !void {
        var change: c.Kevent = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = c.EV.ADD | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        // nchanges = 1, nevents = 0: process the change and return at once.
        while (true) {
            const rc = c.kevent(self.kq, @ptrCast(&change), 1, @ptrCast(&change), 0, null);
            if (rc >= 0) return;
            if (std.posix.errno(rc) == .INTR) continue;
            return error.KeventFailed;
        }
    }

    fn unregister(self: *Backend, fd: c.fd_t, filter: i16) !void {
        var change: c.Kevent = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        while (true) {
            const rc = c.kevent(self.kq, @ptrCast(&change), 1, @ptrCast(&change), 0, null);
            if (rc >= 0) return;
            switch (std.posix.errno(rc)) {
                .INTR => continue,
                // A one-shot event may already have left the kernel queue. Its
                // request is still represented by `pending` and is retired by
                // the synthetic target completion below.
                .NOENT => return,
                else => return error.KeventFailed,
            }
        }
    }

    // Reserve the map row before installing the one-shot filter, but publish the
    // operation only after registration succeeds. This makes both failure halves
    // transactional: allocation failure installs no kernel state, while kevent
    // failure rolls back a newly-created idle row.

    pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void {
        const reserved = try self.reserveSlot(listen_fd);
        errdefer self.rollbackSlot(listen_fd, reserved);
        try self.register(listen_fd, c.EVFILT.READ);
        reserved.pending.read = .{ .accept = user_data };
    }

    /// Start an outbound TCP connect: open a nonblocking socket, submit connect,
    /// return the fd. On submit failure the socket is closed here.
    pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd {
        const fd = try openSocket();
        errdefer self.closeFd(fd);
        if (!socket_tcp.setNodelay(tcp_os, fd)) return error.SocketConfigurationFailed;
        try self.submitConnect(user_data, fd, target);
        return fd;
    }

    fn submitConnect(self: *Backend, user_data: u64, fd: Fd, target: ConnectTarget) !void {
        const ip4 = try socket_tcp.ip4FromTarget(target);
        var addr = socket_tcp.sockaddrIn4(tcp_os, ip4);
        const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_in));
        if (rc == 0) {
            try self.ready.append(self.allocator, .{ .user_data = user_data, .result = 0 });
            return;
        }
        switch (std.posix.errno(rc)) {
            .INPROGRESS, .ALREADY => {},
            else => {
                try self.ready.append(self.allocator, .{ .user_data = user_data, .result = -1 });
                return;
            },
        }
        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        try self.register(fd, c.EVFILT.WRITE);
        reserved.pending.write = .{ .connect = user_data };
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        try self.register(fd, c.EVFILT.READ);
        reserved.pending.read = .{ .recv = user_data };
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const reserved = try self.reserveSlot(fd);
        errdefer self.rollbackSlot(fd, reserved);
        try self.register(fd, c.EVFILT.WRITE);
        reserved.pending.write = .{ .send = .{ .ud = user_data, .bytes = bytes } };
    }

    pub fn submitCancel(
        self: *Backend,
        cancel_user_data: u64,
        target_user_data: u64,
        fd: Fd,
    ) !void {
        const pending = self.pending.getPtr(fd) orelse return error.InvalidCancelTarget;
        switch (pending.read) {
            .recv => |ud| if (ud != target_user_data) return error.InvalidCancelTarget,
            .idle, .accept => return error.InvalidCancelTarget,
        }
        // Reserve both publications before changing the filter or pending row.
        // Once the delete succeeds, this backend owns retirement of the target.
        try self.ready.ensureUnusedCapacity(self.allocator, 2);
        try self.unregister(fd, c.EVFILT.READ);
        pending.read = .idle;
        self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
        self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
        if (pending.write == .idle) std.debug.assert(self.pending.remove(fd));
    }

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        // The completion loop counts ops in flight and defers a connection's
        // teardown until each one retires, so every submitted op must eventually
        // yield a completion. io_uring posts a cancellation completion for a recv
        // or send still pending when its fd closes; kqueue drops the fd from the
        // kernel filter set, so synthesize those completions by hand before
        // removing the slot, otherwise a close while a recv is armed strands the
        // connection slot forever (its ops-in-flight never reaches zero).
        // Reserve every completion slot before touching any state: a failed
        // append after the fd closes (or after only one synthetic completion
        // lands) would strand the slot with ops still counted in flight.
        try self.ready.ensureUnusedCapacity(self.allocator, 3);
        if (self.pending.getPtr(fd)) |p| {
            switch (p.read) {
                .idle => {},
                .recv, .accept => |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 }),
            }
            switch (p.write) {
                .idle => {},
                .send => |s| self.ready.appendAssumeCapacity(.{ .user_data = s.ud, .result = -1 }),
                .connect => |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 }),
            }
        }
        // tolerant: an fd with no pending op was never inserted, so the guard
        // above may have found nothing and this removal need not be present.
        _ = self.pending.remove(fd);
        _ = close(fd);
        self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        // Drain readiness-free completions (closes) first; never block if any.
        if (self.ready.len() > 0) return self.ready.drain(out);

        var events: [256]c.Kevent = undefined;
        const want: c_int = @intCast(@min(out.len, events.len));
        var ts: c.timespec = undefined;
        const timeout_ptr: ?*const c.timespec = if (timeout_ms >= 0) blk: {
            ts = .{
                .sec = @divTrunc(timeout_ms, 1000),
                .nsec = @as(c_long, @mod(timeout_ms, 1000)) * std.time.ns_per_ms,
            };
            break :blk &ts;
        } else null;
        const got = while (true) {
            const rc = c.kevent(self.kq, @ptrCast(&events), 0, @ptrCast(&events), want, timeout_ptr);
            if (rc >= 0) break rc;
            // The loop owns the deadline. An empty turn lets it recompute the
            // remaining time. Retrying the full timespec here can extend a
            // finite wait after every signal.
            if (std.posix.errno(rc) == .INTR) return 0;
            return error.KeventFailed;
        };
        if (got == 0) return 0;

        var produced: usize = 0;
        for (events[0..@intCast(got)]) |ev| {
            const fd: c.fd_t = @intCast(ev.ident);
            const p = self.pending.getPtr(fd) orelse continue;

            if (ev.filter == c.EVFILT.READ) {
                switch (p.read) {
                    .idle => continue,
                    .recv => |ud| {
                        var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
                        if (ev.flags & EV_ERROR != 0) {
                            comp.failure = completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data)))));
                        } else if (self.buffer_pool.acquire()) |idx| {
                            const buf = self.buffer_pool.buffer(idx);
                            const r = c.recv(fd, buf.ptr, buf.len, 0);
                            if (r < 0) switch (std.posix.errno(r)) {
                                // Readiness is a hint, not a promise, and a
                                // signal can land between the wakeup and the
                                // syscall. Neither is a connection failure, but
                                // both return -1, and the loop reads a negative
                                // result as fatal. Re-arm and produce nothing:
                                // the operation is still outstanding, so the
                                // contract that every submitted op eventually
                                // yields a completion still holds.
                                .AGAIN, .INTR => {
                                    self.buffer_pool.release(idx);
                                    self.register(fd, c.EVFILT.READ) catch {
                                        // The re-arm is the only way this op
                                        // can ever complete, so a failure here
                                        // does have to end the connection.
                                        p.read = .idle;
                                        comp.failure = error.KeventFailed;
                                        out[produced] = comp;
                                        produced += 1;
                                    };
                                    continue;
                                },
                                else => comp.failure = completion.failureFromErrno(std.posix.errno(r)),
                            };
                            comp.result = @intCast(r);
                            if (r > 0) {
                                comp.borrowed = .recv(buf[0..@intCast(r)], idx);
                            } else {
                                // EOF or error: nothing for the loop to consume,
                                // so the buffer goes straight back to the pool.
                                self.buffer_pool.release(idx);
                            }
                        } else {
                            // Pool exhausted: surface starvation. The one-shot
                            // interest is spent; the loop's re-arm registers a
                            // fresh one once a buffer recycles.
                            comp.recv_no_buffer = true;
                        }
                        p.read = .idle;
                        out[produced] = comp;
                        produced += 1;
                    },
                    .accept => |ud| {
                        var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
                        if (ev.flags & EV_ERROR != 0) {
                            comp.failure = completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data)))));
                        } else {
                            const accepted = accept(fd, null, null);
                            if (accepted < 0) switch (std.posix.errno(accepted)) {
                                // Readiness can be spent by another kernel event,
                                // and a signal can interrupt before accept makes
                                // progress. Preserve the outstanding operation;
                                // only a failed re-arm is terminal.
                                .AGAIN, .INTR => {
                                    self.register(fd, c.EVFILT.READ) catch {
                                        p.read = .idle;
                                        comp.failure = error.KeventFailed;
                                        out[produced] = comp;
                                        produced += 1;
                                    };
                                    continue;
                                },
                                else => comp.failure = completion.failureFromErrno(std.posix.errno(accepted)),
                            };
                            // Darwin does not inherit nonblocking across
                            // accept(2), and a blocking send at write-readiness
                            // would park the whole loop (ADR-0042). The accepted
                            // fd also needs SO_NOSIGPIPE before any send, so a
                            // torn-down peer becomes a completion error rather
                            // than a process signal. If either socket option
                            // cannot be set, refuse the connection; the loop's
                            // re-arm recovers.
                            if (accepted >= 0 and (!socket_tcp.setNonblocking(accepted) or !socket_tcp.setNoSigpipe(accepted) or !socket_tcp.setNodelay(tcp_os, accepted))) {
                                _ = close(accepted);
                                comp.result = -1;
                                comp.failure = error.SocketConfigurationFailed;
                            } else {
                                comp.result = accepted;
                            }
                        }
                        p.read = .idle;
                        out[produced] = comp;
                        produced += 1;
                    },
                }
            } else if (ev.filter == c.EVFILT.WRITE) {
                switch (p.write) {
                    .idle => continue,
                    .connect => |ud| {
                        const failure: ?anyerror = if (ev.flags & EV_ERROR != 0)
                            completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data)))))
                        else
                            connectFailure(fd);
                        p.write = .idle;
                        out[produced] = .{
                            .user_data = ud,
                            .result = if (failure == null) 0 else -1,
                            .failure = failure,
                        };
                        produced += 1;
                    },
                    .send => |s| {
                        if (ev.flags & EV_ERROR == 0) {
                            const sent = c.send(fd, s.bytes.ptr, s.bytes.len, 0);
                            if (sent < 0) switch (std.posix.errno(sent)) {
                                // kqueue reports readiness, not completion.
                                // A stale edge can find the socket not writable
                                // anymore, and a signal can interrupt before
                                // progress. Keep the op outstanding and wait
                                // for the next write edge.
                                .AGAIN, .INTR => {
                                    self.register(fd, c.EVFILT.WRITE) catch {
                                        p.write = .idle;
                                        out[produced] = .{ .user_data = s.ud, .result = -1, .failure = error.KeventFailed };
                                        produced += 1;
                                    };
                                    continue;
                                },
                                else => {
                                    p.write = .idle;
                                    out[produced] = .{
                                        .user_data = s.ud,
                                        .result = -1,
                                        .failure = completion.failureFromErrno(std.posix.errno(sent)),
                                    };
                                    produced += 1;
                                    continue;
                                },
                            };
                            p.write = .idle;
                            out[produced] = .{ .user_data = s.ud, .result = @intCast(sent) };
                            produced += 1;
                            continue;
                        }
                        p.write = .idle;
                        out[produced] = .{
                            .user_data = s.ud,
                            .result = -1,
                            .failure = completion.failureFromErrno(@fromBackingInt(@intCast(@as(c_int, @intCast(ev.data))))),
                        };
                        produced += 1;
                    },
                }
            }
        }
        return produced;
    }

    pub fn openListener(self: *Backend, port: u16) !Fd {
        return socket_tcp.openListener(tcp_os, .{
            .bytes = self.listener_ip4,
            .port = port,
        });
    }

    pub fn openSocket() !Fd {
        return socket_tcp.openSocket(tcp_os);
    }

    pub fn listenerAddress(_: *Backend, fd: Fd) !ListenerAddress {
        const address = try socket_tcp.boundIp4(tcp_os, fd);
        return .{
            .bytes = address.bytes,
            .port = address.port,
        };
    }

    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address.port;
    }

    pub fn closeFd(self: *Backend, fd: Fd) void {
        _ = self;
        _ = close(fd);
    }

    /// Unblock an armed recv so `Loop.closeAndDrain` does not wait on a quiet peer.
    pub fn shutdownFd(self: *Backend, fd: Fd) void {
        _ = self;
        _ = c.shutdown(fd, c.SHUT.RDWR);
    }
};

/// Narrow runtime proof for the transactional registration rule above. Kept
/// test-only so backend bookkeeping does not become public API.
pub const white_box = if (builtin.is_test) struct {
    pub fn failedRegistrationLeavesNoPending(allocator: std.mem.Allocator) !bool {
        var backend = try Backend.init(allocator, 1, 1, 64);
        defer backend.deinit();

        const fd = try Backend.openSocket();
        backend.closeFd(fd);
        const before = backend.pending.count();
        backend.submitRecv(1, fd) catch |err| {
            return err == error.KeventFailed and before == backend.pending.count();
        };
        return false;
    }
} else struct {};

// accept(2) is `pub extern` in std.c, but reference it through a thin alias so the
// call sites read the same as the other socket calls.
fn accept(sockfd: c.fd_t, addr: ?*c.sockaddr, addrlen: ?*c.socklen_t) i32 {
    return c.accept(sockfd, addr, addrlen);
}

fn connectFailure(fd: c.fd_t) ?anyerror {
    var so_error: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len) < 0)
        return error.GetsockoptFailed;
    return if (so_error == 0) null else completion.failureFromErrno(@fromBackingInt(@intCast(so_error)));
}
