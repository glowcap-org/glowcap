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
//! The shared read-buffer pool (ADR-0054) is a scratch pool owned here: a
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

comptime {
    if (!builtin.os.tag.isDarwin()) @compileError("net.kqueue is for Darwin (kqueue)");
}

const c = std.c;

// socket(2) and close(2) are not re-exported as public from std.c; declare them.
extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const AF_INET: c_uint = 2;
const SOCK_STREAM: c_uint = 1;
const EV_ERROR: u16 = 0x4000;

/// Darwin `struct sockaddr_in` (note the leading `len` byte, which Linux lacks).
const sockaddr_in = extern struct {
    len: u8 = @sizeOf(sockaddr_in),
    family: u8 = @intCast(AF_INET),
    port: u16, // network byte order
    addr: u32, // network byte order
    zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// What a registered fd is waiting to do, so `poll` can complete it on readiness.
/// Read and write are tracked separately because one connection can have a recv
/// and a send outstanding at the same time.
const Pending = struct {
    read_ud: ?u64 = null,
    /// With `read_ud` set: a recv (read into a scratch-pool buffer at
    /// readiness) when true, an accept when false.
    read_is_recv: bool = false,
    write_ud: ?u64 = null,
    write_bytes: ?[]const u8 = null, // null with write_ud set => a connect
    connecting: bool = false,
};

pub const Backend = struct {
    pub const Fd = c.fd_t;

    allocator: std.mem.Allocator,
    kq: c.fd_t,
    pending: std.AutoHashMap(c.fd_t, Pending),
    /// Completions that need no readiness (closes), drained before blocking.
    ready: std.ArrayList(completion.Completion),
    /// The shared recv scratch pool (ADR-0054): every allocated buffer, indexed
    /// by the `recv_token` the loop hands back through `recycleRecv`. Grows
    /// lazily to `scratch_cap` buffers and keeps them for the backend's life.
    scratch: std.ArrayList([]u8),
    /// Indices of scratch buffers not currently lent out on a completion. Both
    /// lists reserve `scratch_cap` slots at init so the reclaim cannot fail.
    scratch_free: std.ArrayList(u16),
    scratch_cap: u16,
    scratch_bytes: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        _ = queue_entries;
        const kq = c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        errdefer _ = close(kq);

        const cap: u16 = @max(read_buffers, 1);
        var scratch: std.ArrayList([]u8) = .empty;
        errdefer scratch.deinit(allocator);
        try scratch.ensureTotalCapacity(allocator, cap);
        var scratch_free: std.ArrayList(u16) = .empty;
        errdefer scratch_free.deinit(allocator);
        try scratch_free.ensureTotalCapacity(allocator, cap);

        return .{
            .allocator = allocator,
            .kq = kq,
            .pending = std.AutoHashMap(c.fd_t, Pending).init(allocator),
            .ready = .empty,
            .scratch = scratch,
            .scratch_free = scratch_free,
            .scratch_cap = cap,
            .scratch_bytes = read_buffer_bytes,
        };
    }

    pub fn deinit(self: *Backend) void {
        for (self.scratch.items) |buf| self.allocator.free(buf);
        self.scratch.deinit(self.allocator);
        self.scratch_free.deinit(self.allocator);
        self.pending.deinit();
        self.ready.deinit(self.allocator);
        _ = close(self.kq);
    }

    /// Take a free scratch buffer, allocating lazily up to the pool size; null
    /// when the pool is exhausted (every buffer is lent out on a completion).
    fn acquireScratch(self: *Backend) ?u16 {
        if (self.scratch_free.pop()) |idx| return idx;
        if (self.scratch.items.len >= self.scratch_cap) return null;
        const buf = self.allocator.alloc(u8, self.scratch_bytes) catch return null;
        self.scratch.appendAssumeCapacity(buf);
        return @intCast(self.scratch.items.len - 1);
    }

    fn releaseScratch(self: *Backend, idx: u16) void {
        self.scratch_free.appendAssumeCapacity(idx);
    }

    /// Reclaim a recv completion's scratch buffer. The loop calls this exactly
    /// once per completion that carried `recv_bytes`.
    pub fn recycleRecv(self: *Backend, comp: completion.Completion) void {
        self.releaseScratch(@intCast(comp.recv_token));
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
        p.read_ud = user_data;
        p.read_is_recv = false;
    }

    pub fn submitConnect(self: *Backend, user_data: u64, fd: Fd, address: std.Io.net.IpAddress) !void {
        const ip4 = switch (address) {
            .ip4 => |ip4| ip4,
            .ip6 => return error.AddressFamilyUnsupported,
        };
        var addr: sockaddr_in = .{
            .port = std.mem.nativeToBig(u16, ip4.port),
            .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &ip4.bytes, .big)),
        };
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
        p.write_ud = user_data;
        p.write_bytes = null;
        p.connecting = true;
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const p = try self.slot(fd);
        try self.register(fd, c.EVFILT.READ);
        p.read_ud = user_data;
        p.read_is_recv = true;
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const p = try self.slot(fd);
        try self.register(fd, c.EVFILT.WRITE);
        p.write_ud = user_data;
        p.write_bytes = bytes;
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
            if (p.read_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
            if (p.write_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
        }
        _ = self.pending.remove(fd);
        _ = close(fd);
        self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
    }

    pub fn poll(self: *Backend, out: []completion.Completion) !usize {
        // Drain readiness-free completions (closes) first; never block if any.
        if (self.ready.items.len > 0) {
            const n = @min(self.ready.items.len, out.len);
            @memcpy(out[0..n], self.ready.items[0..n]);
            // Keep the remainder for the next poll.
            const rest = self.ready.items.len - n;
            std.mem.copyForwards(completion.Completion, self.ready.items[0..rest], self.ready.items[n..]);
            self.ready.shrinkRetainingCapacity(rest);
            return n;
        }

        var events: [256]c.Kevent = undefined;
        const want: c_int = @intCast(@min(out.len, events.len));
        const got = c.kevent(self.kq, @ptrCast(&events), 0, @ptrCast(&events), want, null);
        if (got < 0) return error.KeventFailed;

        var produced: usize = 0;
        for (events[0..@intCast(got)]) |ev| {
            const fd: c.fd_t = @intCast(ev.ident);
            const p = self.pending.getPtr(fd) orelse continue;

            if (ev.filter == c.EVFILT.READ and p.read_ud != null) {
                const ud = p.read_ud.?;
                var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
                if (ev.flags & EV_ERROR != 0) {
                    // result stays -1
                } else if (p.read_is_recv) {
                    if (self.acquireScratch()) |idx| {
                        const buf = self.scratch.items[idx];
                        const r: i32 = @intCast(c.recv(fd, buf.ptr, buf.len, 0));
                        comp.result = r;
                        if (r > 0) {
                            comp.recv_bytes = buf[0..@intCast(r)];
                            comp.recv_token = idx;
                        } else {
                            // EOF or error: nothing for the loop to consume,
                            // so the buffer goes straight back to the pool.
                            self.releaseScratch(idx);
                        }
                    } else {
                        // Pool exhausted: surface starvation. The one-shot
                        // interest is spent; the loop's re-arm registers a
                        // fresh one once a buffer recycles.
                        comp.recv_no_buffer = true;
                    }
                } else {
                    const accepted = accept(fd, null, null);
                    // Darwin does not inherit nonblocking across accept(2), and
                    // a blocking send at write-readiness would park the whole
                    // loop (ADR-0042), so the accepted fd must be nonblocking
                    // before the loop ever submits on it. If it cannot be,
                    // refuse the connection; the loop's re-arm recovers.
                    if (accepted >= 0 and !setNonblocking(accepted)) {
                        _ = close(accepted);
                        comp.result = -1;
                    } else {
                        comp.result = accepted;
                    }
                }
                p.read_ud = null;
                p.read_is_recv = false;
                out[produced] = comp;
                produced += 1;
            } else if (ev.filter == c.EVFILT.WRITE and p.write_ud != null) {
                const ud = p.write_ud.?;
                const result: i32 = if (ev.flags & EV_ERROR != 0)
                    -1
                else if (p.connecting)
                    connectResult(fd)
                else blk: {
                    const bytes = p.write_bytes.?;
                    break :blk @intCast(c.send(fd, bytes.ptr, bytes.len, 0));
                };
                p.write_ud = null;
                p.write_bytes = null;
                p.connecting = false;
                out[produced] = .{ .user_data = ud, .result = result };
                produced += 1;
            }
        }
        return produced;
    }

    pub fn openListener(port: u16) !Fd {
        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = close(fd);
        // Readiness can go stale (the peer can reset between kevent and
        // accept), so the listener must never block the loop in accept(2).
        if (!setNonblocking(fd)) return error.SocketFailed;

        var addr: sockaddr_in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f00_0001), // 127.0.0.1
        };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_in)) < 0) return error.BindFailed;
        if (c.listen(fd, 128) < 0) return error.ListenFailed;
        return fd;
    }

    pub fn openSocket() !Fd {
        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = close(fd);
        if (!setNonblocking(fd)) return error.SocketFailed;
        return fd;
    }

    pub fn boundPort(fd: Fd) !u16 {
        var addr: sockaddr_in = .{ .port = 0, .addr = 0 };
        var len: c.socklen_t = @sizeOf(sockaddr_in);
        if (c.getsockname(fd, @ptrCast(&addr), &len) < 0) return error.GetsocknameFailed;
        return std.mem.bigToNative(u16, addr.port);
    }

    pub fn closeFd(fd: Fd) void {
        _ = close(fd);
    }
};

// accept(2) is `pub extern` in std.c, but reference it through a thin alias so the
// call sites read the same as the other socket calls.
fn accept(sockfd: c.fd_t, addr: ?*c.sockaddr, addrlen: ?*c.socklen_t) i32 {
    return c.accept(sockfd, addr, addrlen);
}

/// Set `O_NONBLOCK` on `fd`, reporting success. Every fd the backend submits
/// on must be nonblocking: kqueue reports readiness, not completion, and a
/// blocking `send` or `accept` at stale readiness would park the entire loop —
/// the exact head-of-line blocking ADR-0042's bounded outbound queue exists to
/// prevent. Every fd the backend opens — dialed, listening, and each accepted
/// fd (Darwin does not inherit the flag across accept) — is flagged here:
/// Darwin's `socket(2)` does not accept the Linux `SOCK_NONBLOCK` type flag.
fn setNonblocking(fd: c.fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    return c.fcntl(fd, c.F.SETFL, flags | nonblock) >= 0;
}

fn connectResult(fd: c.fd_t) i32 {
    var so_error: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len) < 0) return -1;
    return if (so_error == 0) 0 else -1;
}
