//! The macOS / BSD kqueue completion backend for `completion.Loop`.
//!
//! One implementation of the completion-backend interface documented in
//! [`completion`](completion.zig). The portable connection orchestration lives in
//! `completion.Loop`; this file provides only the platform completion primitive
//! and the loopback socket primitives. The io_uring (Linux) sibling is
//! [`uring`](uring.zig); the server logic does not change between them.
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
//! The shared read-buffer pool (ADR-0054) is a `ScratchPool` owned here: a
//! readiness backend reads at poll time, so `poll` acquires a scratch buffer,
//! performs the `recv` into it, and lends it to the loop on the completion;
//! `recycleRecv` reclaims it. Buffers are allocated lazily up to the pool size,
//! and a read-ready fd that finds the pool empty completes with
//! `Completion.recv_no_buffer` — pool contention, never a connection error.
//!
//! Type-checked on every `zig build check` by the `cross-check` gate, which
//! cross-compiles the whole library to `aarch64-macos` (compile-only), so this
//! backend cannot regress unnoticed from a Linux host. What that gate cannot do
//! is *run* it — that needs a macOS machine or CI runner. So this backend is
//! type-correct and reviewed against the io_uring sibling's contract, but its
//! runtime behavior is unproven here; treat a change to it as needing a macOS run
//! before it is trusted in production.

const std = @import("std");
const builtin = @import("builtin");

const completion = @import("loop.zig");
const ScratchPool = @import("scratch_pool.zig").ScratchPool;
const socket_tcp = @import("socket_tcp.zig");

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
    /// Platform dial target: a resolved `IpAddress`. OCapN locator resolve
    /// lives on `tcp.DialResolver`, not on this platform Backend.
    pub const ConnectTarget = std.Io.net.IpAddress;

    allocator: std.mem.Allocator,
    kq: c.fd_t,
    pending: std.AutoHashMap(c.fd_t, Pending),
    /// Completions that need no readiness (closes), drained before blocking.
    ready: std.ArrayList(completion.Completion),
    /// The shared recv scratch pool (ADR-0054).
    scratch_pool: ScratchPool,

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        // kqueue has no submission ring to size: `queue_entries` is the
        // io_uring backend's ring-depth hint, taken here only because both
        // backends share the one `init` signature.
        _ = queue_entries;
        const kq = c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        errdefer _ = close(kq);

        var scratch_pool = try ScratchPool.init(allocator, read_buffers, read_buffer_bytes);
        errdefer scratch_pool.deinit();

        return .{
            .allocator = allocator,
            .kq = kq,
            .pending = std.AutoHashMap(c.fd_t, Pending).init(allocator),
            .ready = .empty,
            .scratch_pool = scratch_pool,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.scratch_pool.deinit();
        self.pending.deinit();
        self.ready.deinit(self.allocator);
        _ = close(self.kq);
    }

    /// Reclaim a recv completion's scratch buffer. The loop calls this exactly
    /// once per completion that carried `recv_bytes`.
    pub fn recycleRecv(self: *Backend, comp: completion.Completion) void {
        self.scratch_pool.release(@intCast(comp.recv_token));
    }

    fn slot(self: *Backend, fd: c.fd_t) !*Pending {
        const gop = try self.pending.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
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
        const rc = c.kevent(self.kq, @ptrCast(&change), 1, @ptrCast(&change), 0, null);
        if (rc < 0) return error.KeventFailed;
    }

    // Each submit* registers the kernel filter *before* recording the pending
    // operation. The other order is not failure-safe: a `Pending` mutated ahead
    // of a failed `register` would leave a stale user_data behind a propagated
    // error, and a later registration on the same fd would resurrect it as a
    // synthesized completion, landing on a reused slot and tearing down an
    // unrelated connection. A registered one-shot filter with no pending record
    // is benign: `poll`'s `getPtr(fd) orelse continue` drops it.

    pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void {
        const p = try self.slot(listen_fd);
        try self.register(listen_fd, c.EVFILT.READ);
        p.read = .{ .accept = user_data };
    }

    /// Start an outbound TCP connect: open a nonblocking socket, submit connect,
    /// return the fd. On submit failure the socket is closed here.
    pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd {
        const fd = try openSocket();
        errdefer self.closeFd(fd);
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
        const p = try self.slot(fd);
        try self.register(fd, c.EVFILT.WRITE);
        p.write = .{ .connect = user_data };
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const p = try self.slot(fd);
        try self.register(fd, c.EVFILT.READ);
        p.read = .{ .recv = user_data };
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const p = try self.slot(fd);
        try self.register(fd, c.EVFILT.WRITE);
        p.write = .{ .send = .{ .ud = user_data, .bytes = bytes } };
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
        if (self.ready.items.len > 0) return completion.drainReady(&self.ready, out);

        var events: [256]c.Kevent = undefined;
        const want: c_int = @intCast(@min(out.len, events.len));
        var ts: c.timespec = undefined;
        const timeout_ptr: ?*const c.timespec = if (timeout_ms >= 0) blk: {
            ts = .{
                .tv_sec = @divTrunc(timeout_ms, 1000),
                .tv_nsec = @as(c_long, @mod(timeout_ms, 1000)) * std.time.ns_per_ms,
            };
            break :blk &ts;
        } else null;
        const got = c.kevent(self.kq, @ptrCast(&events), 0, @ptrCast(&events), want, timeout_ptr);
        if (got < 0) return error.KeventFailed;
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
                            // result stays -1
                        } else if (self.scratch_pool.acquire()) |idx| {
                            const buf = self.scratch_pool.buffer(idx);
                            const r: i32 = @intCast(c.recv(fd, buf.ptr, buf.len, 0));
                            comp.result = r;
                            if (r > 0) {
                                comp.recv_bytes = buf[0..@intCast(r)];
                                comp.recv_token = idx;
                            } else {
                                // EOF or error: nothing for the loop to consume,
                                // so the buffer goes straight back to the pool.
                                self.scratch_pool.release(idx);
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
                            // result stays -1
                        } else {
                            const accepted = accept(fd, null, null);
                            // Darwin does not inherit nonblocking across accept(2), and
                            // a blocking send at write-readiness would park the whole
                            // loop (ADR-0042), so the accepted fd must be nonblocking
                            // before the loop ever submits on it. If it cannot be,
                            // refuse the connection; the loop's re-arm recovers.
                            if (accepted >= 0 and !socket_tcp.setNonblocking(accepted)) {
                                _ = close(accepted);
                                comp.result = -1;
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
                        const result: i32 = if (ev.flags & EV_ERROR != 0) -1 else connectResult(fd);
                        p.write = .idle;
                        out[produced] = .{ .user_data = ud, .result = result };
                        produced += 1;
                    },
                    .send => |s| {
                        const result: i32 = if (ev.flags & EV_ERROR != 0)
                            -1
                        else
                            @intCast(c.send(fd, s.bytes.ptr, s.bytes.len, 0));
                        p.write = .idle;
                        out[produced] = .{ .user_data = s.ud, .result = result };
                        produced += 1;
                    },
                }
            }
        }
        return produced;
    }

    pub fn openListener(self: *Backend, port: u16) !Fd {
        _ = self;
        return socket_tcp.openListener(tcp_os, port);
    }

    pub fn openSocket() !Fd {
        return socket_tcp.openSocket(tcp_os);
    }

    pub fn boundPort(fd: Fd) !u16 {
        var addr: sockaddr_in = .{ .port = 0, .addr = 0 };
        var len: c.socklen_t = @sizeOf(sockaddr_in);
        if (c.getsockname(fd, @ptrCast(&addr), &len) < 0) return error.GetsocknameFailed;
        return std.mem.bigToNative(u16, addr.port);
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

// accept(2) is `pub extern` in std.c, but reference it through a thin alias so the
// call sites read the same as the other socket calls.
fn accept(sockfd: c.fd_t, addr: ?*c.sockaddr, addrlen: ?*c.socklen_t) i32 {
    return c.accept(sockfd, addr, addrlen);
}

fn connectResult(fd: c.fd_t) i32 {
    var so_error: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len) < 0) return -1;
    return if (so_error == 0) 0 else -1;
}
