//! The Linux io_uring completion backend for `completion.Loop`.
//!
//! This file is one implementation of the completion-backend interface documented
//! in `completion.Loop` (`loop.zig`): it provides the platform completion
//! primitive (io_uring) and the loopback socket primitives, and nothing else. All
//! the portable connection orchestration lives in `completion.Loop`, which is
//! generic over this backend. The kqueue (Darwin) sibling is a separate file
//! implementing the same interface (a Windows IOCP backend is not implemented);
//! the portable server does not change when a backend is added.
//!
//! io_uring is a true completion (proactor) model: operations are submitted to a
//! ring and the kernel posts a completion when each finishes. `submit*` queues an
//! SQE; `poll` flushes the queue, waits for at least one completion, and hands the
//! results back to the server.
//!
//! The shared read-buffer pool (ADR-0054) is a kernel provided-buffer ring: one
//! buffer group is registered at init, recvs are submitted with buffer select
//! (no caller buffer), the kernel picks a buffer when data arrives and names it
//! on the CQE, and `recycleRecv` returns it to the ring. A recv that finds the
//! ring empty completes with `ENOBUFS`, which surfaces to the loop as
//! `Completion.recv_no_buffer` — pool contention, never a connection error.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = linux.IoUring;

const completion = @import("loop.zig");
const poll_wait = @import("../poll.zig");
const socket_tcp = @import("socket_tcp.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("the io_uring completion backend is Linux-only");
}

const tcp_os = socket_tcp.Os.linux;

pub const Backend = struct {
    pub const Fd = linux.fd_t;
    pub const adapter_depth = 0;
    /// Platform dial target: a resolved `IpAddress`. OCapN locator resolve
    /// lives on `tcp.DialResolver`, not on this platform Backend.
    pub const ConnectTarget = std.Io.net.IpAddress;
    pub const ListenerAddress = u16;

    /// The one buffer group registered on the ring; group ids only need to be
    /// unique per ring.
    const buf_group_id: u16 = 0;

    allocator: std.mem.Allocator,
    ring: IoUring,
    /// The kernel-shared provided-buffer ring. The mmap is owned here and is
    /// address-stable, so the backend struct itself can move by value.
    buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    /// Backing storage for the pool: `buf_count` buffers of `buf_bytes` each.
    buffers: []u8,
    buf_bytes: u32,
    buf_count: u16,
    /// The one listener and accept request this backend may own. A listening
    /// socket cannot rely on `shutdown(2)` to cancel an io_uring accept, so
    /// listener close targets the request by its exact user_data instead.
    listener_fd: ?Fd = null,
    listener_accept_ud: ?u64 = null,
    listener_cancel: ?struct {
        fd: Fd,
        close_ud: u64,
        phase: enum { cancel_pending, waiting_target } = .cancel_pending,
    } = null,
    /// A synthetic listener-close completion that did not fit beside the
    /// accept CQE which made an `-EALREADY` cancellation safe to finish.
    listener_close_ready: ?u64 = null,

    /// Backend-private completion identity. Loop user_data always has a valid
    /// three-bit `Op` tag (0...5), so an all-one value cannot be emitted by the
    /// Loop or by an adapter preserving that payload.
    const listener_cancel_ud = std.math.maxInt(u64);

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        if (read_buffer_bytes == 0) return error.InvalidReadBufferBytes;
        var ring = try IoUring.init(queue_entries, 0);
        errdefer ring.deinit();

        // The kernel requires a power-of-two ring; round the requested pool up.
        const count = try std.math.ceilPowerOfTwo(u16, @max(read_buffers, 1));
        const buffers = try allocator.alloc(u8, @as(usize, count) * read_buffer_bytes);
        errdefer allocator.free(buffers);

        const buf_ring = try IoUring.setup_buf_ring(ring.fd, count, buf_group_id, .{ .inc = false });
        IoUring.buf_ring_init(buf_ring);
        const mask = IoUring.buf_ring_mask(count);
        var id: u16 = 0;
        while (id < count) : (id += 1) {
            const pos = @as(usize, read_buffer_bytes) * id;
            IoUring.buf_ring_add(buf_ring, buffers[pos .. pos + read_buffer_bytes], id, mask, id);
        }
        IoUring.buf_ring_advance(buf_ring, count);

        return .{
            .allocator = allocator,
            .ring = ring,
            .buf_ring = buf_ring,
            .buffers = buffers,
            .buf_bytes = read_buffer_bytes,
            .buf_count = count,
        };
    }

    pub fn deinit(self: *Backend) void {
        std.debug.assert(self.listener_cancel == null);
        std.debug.assert(self.listener_close_ready == null);
        IoUring.free_buf_ring(self.ring.fd, self.buf_ring, self.buf_count, buf_group_id);
        self.allocator.free(self.buffers);
        self.ring.deinit();
    }

    /// Take a free SQE, flushing the submission queue to the kernel when it is
    /// full. A dispatch batch can arm more operations than the ring has SQ
    /// entries (each of up to 256 completions may arm a recv and a send), and
    /// SQEs otherwise flush only in `poll`, so without this a busy batch would
    /// fail healthy submissions, closing live connections or, on the accept
    /// re-arm, killing the whole loop. The mid-batch flush is safe: the kernel
    /// buffers completion overflow, and `poll` still reaps everything.
    fn getSqe(self: *Backend) !*linux.io_uring_sqe {
        return self.ring.get_sqe() catch {
            _ = try self.ring.submit();
            return self.ring.get_sqe();
        };
    }

    pub fn submitAccept(self: *Backend, user_data: u64, listen_fd: Fd) !void {
        std.debug.assert(self.listener_fd == listen_fd);
        std.debug.assert(self.listener_accept_ud == null);
        const sqe = try self.getSqe();
        sqe.prep_accept(listen_fd, null, null, 0);
        sqe.user_data = user_data;
        self.listener_accept_ud = user_data;
    }

    /// Start an outbound TCP connect: open a socket, submit connect, return the
    /// fd. On submit failure the socket is closed here — the Loop never sees it.
    pub fn startDial(self: *Backend, user_data: u64, target: ConnectTarget) !Fd {
        const fd = try openSocket();
        errdefer self.closeFd(fd);
        try self.submitConnect(user_data, fd, target);
        return fd;
    }

    fn submitConnect(self: *Backend, user_data: u64, fd: Fd, target: ConnectTarget) !void {
        const ip4 = try socket_tcp.ip4FromTarget(target);
        var addr = socket_tcp.sockaddrIn4(tcp_os, ip4);
        const sqe = try self.getSqe();
        sqe.prep_connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        sqe.user_data = user_data;
        // io_uring stores the sockaddr pointer in the SQE. Submit immediately so
        // the kernel copies it before this stack frame goes away.
        _ = try self.ring.submit();
    }

    /// Arm a buffer-select recv: the kernel picks a pool buffer when data
    /// arrives and names it on the CQE.
    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const sqe = try self.getSqe();
        sqe.prep_rw(.RECV, fd, 0, 0, 0);
        sqe.rw_flags = 0;
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = buf_group_id;
        sqe.user_data = user_data;
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const sqe = try self.getSqe();
        sqe.prep_send(fd, bytes, 0);
        sqe.user_data = user_data;
    }

    pub fn submitCancel(
        self: *Backend,
        cancel_user_data: u64,
        target_user_data: u64,
        fd: Fd,
    ) !void {
        _ = fd; // io_uring cancellation identifies the exact request by user_data.
        const sqe = try self.getSqe();
        sqe.prep_cancel(target_user_data, 0);
        sqe.user_data = cancel_user_data;
    }

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        if (self.listener_fd == fd) {
            if (self.listener_accept_ud) |accept_ud| {
                std.debug.assert(self.listener_cancel == null);
                const sqe = try self.getSqe();
                sqe.prep_cancel(accept_ud, 0);
                sqe.user_data = listener_cancel_ud;
                self.listener_cancel = .{ .fd = fd, .close_ud = user_data };
                return;
            }
        }
        const sqe = try self.getSqe();
        sqe.prep_close(fd);
        sqe.user_data = user_data;
    }

    /// Return a recv completion's pool buffer to the kernel ring. The loop
    /// calls this exactly once per completion that carried `recv_bytes`.
    /// Sockets carry no lower-layer peer identity: the total Backend
    /// contract's `verifiedChannelKey` member (ADR-0097) always answers null.
    pub fn verifiedChannelKey(self: *Backend, fd: Fd) ?[32]u8 {
        _ = self;
        _ = fd;
        return null;
    }

    pub fn recycleRecv(self: *Backend, comp: completion.Completion) void {
        const buffer_id: u16 = @intCast(comp.recv_token);
        IoUring.buf_ring_add(
            self.buf_ring,
            self.bufferSlice(buffer_id),
            buffer_id,
            IoUring.buf_ring_mask(self.buf_count),
            0,
        );
        IoUring.buf_ring_advance(self.buf_ring, 1);
    }

    /// Flush queued submissions, wait for completions, and copy up to `out.len`
    /// completions back to the server, surfacing each selected pool buffer as a
    /// borrowed view. A negative `timeout_ms` blocks until at least one
    /// completion; a non-negative value waits at most that many milliseconds and
    /// returns 0 when nothing completes in time.
    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        if (self.listener_close_ready) |user_data| {
            if (out.len == 0) return 0;
            self.listener_close_ready = null;
            out[0] = .{ .user_data = user_data, .result = 0 };
            return 1;
        }
        if (timeout_ms >= 0) {
            _ = self.ring.submit() catch |err| switch (err) {
                error.SignalInterrupt => return 0,
                else => return err,
            };
            if (try self.drainCompletions(out)) |n| return n;
            var fds = [_]std.posix.pollfd{.{
                .fd = self.ring.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = poll_wait.wait(&fds, timeout_ms) catch |err| return err;
            if (ready == 0) return 0;
        } else {
            _ = self.ring.submit_and_wait(1) catch |err| switch (err) {
                error.SignalInterrupt => return 0,
                else => return err,
            };
        }
        return (try self.drainCompletions(out)) orelse 0;
    }

    fn drainCompletions(self: *Backend, out: []completion.Completion) !?usize {
        var cqes: [256]linux.io_uring_cqe = undefined;
        const want = @min(out.len, cqes.len);
        const n = try self.ring.copy_cqes(cqes[0..want], 0);
        if (n == 0) return null;
        var produced: usize = 0;
        for (cqes[0..n]) |cqe| {
            if (cqe.user_data == listener_cancel_ud) {
                const disposition = classifyListenerCancel(cqe.res);
                switch (disposition) {
                    .resolved => self.finishListenerClose(out, &produced),
                    .wait_for_target => {
                        const pending = &(self.listener_cancel orelse unreachable);
                        pending.phase = .waiting_target;
                        // The accept CQE may have won the race and appeared
                        // earlier in this same batch. In that order both halves
                        // are now retired, so finish without another poll.
                        if (self.listener_accept_ud == null)
                            self.finishListenerClose(out, &produced);
                    },
                }
                continue;
            }
            const listener_accept = self.listener_accept_ud == cqe.user_data;
            if (listener_accept)
                self.listener_accept_ud = null;
            var comp: completion.Completion = .{ .user_data = cqe.user_data, .result = cqe.res };
            if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                // A recv that selected a pool buffer (possibly zero bytes on
                // EOF): borrow it to the loop, which recycles it after
                // consuming.
                const buffer_id: u16 = @intCast(cqe.flags >> linux.IORING_CQE_BUFFER_SHIFT);
                const used: usize = if (cqe.res > 0) @intCast(cqe.res) else 0;
                comp.recv_bytes = self.bufferSlice(buffer_id)[0..used];
                comp.recv_token = buffer_id;
            } else if (cqe.res == enobufs_res) {
                // Data arrived while the pool was empty: not a connection
                // error; the loop parks the read buffer-starved and re-arms it
                // when a buffer recycles.
                comp.recv_no_buffer = true;
            }
            out[produced] = comp;
            produced += 1;
            if (listener_accept) {
                if (self.listener_cancel) |pending| {
                    if (pending.phase == .waiting_target)
                        self.finishListenerClose(out, &produced);
                }
            }
        }
        return produced;
    }

    fn finishListenerClose(self: *Backend, out: []completion.Completion, produced: *usize) void {
        const pending = self.listener_cancel orelse unreachable;
        self.listener_cancel = null;
        _ = linux.close(pending.fd);
        self.listener_fd = null;
        if (produced.* < out.len) {
            out[produced.*] = .{ .user_data = pending.close_ud, .result = 0 };
            produced.* += 1;
        } else {
            std.debug.assert(self.listener_close_ready == null);
            self.listener_close_ready = pending.close_ud;
        }
    }

    fn bufferSlice(self: *Backend, buffer_id: u16) []u8 {
        const pos = @as(usize, self.buf_bytes) * buffer_id;
        return self.buffers[pos .. pos + self.buf_bytes];
    }

    const enobufs_res: i32 = -@as(i32, @intFromEnum(linux.E.NOBUFS));

    pub fn openListener(self: *Backend, port: u16) !Fd {
        std.debug.assert(self.listener_fd == null);
        const fd = try socket_tcp.openListener(tcp_os, port);
        self.listener_fd = fd;
        return fd;
    }

    pub fn openSocket() !Fd {
        return socket_tcp.openSocket(tcp_os);
    }

    pub fn listenerAddress(_: *Backend, fd: Fd) !ListenerAddress {
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        try check(linux.getsockname(fd, @ptrCast(&addr), &len));
        return std.mem.bigToNative(u16, addr.port);
    }

    pub fn listenerPort(address: ListenerAddress) ?u16 {
        return address;
    }

    pub fn closeFd(self: *Backend, fd: Fd) void {
        if (self.listener_fd == fd) self.listener_fd = null;
        _ = linux.close(fd);
    }

    /// Unblock an armed recv so `Loop.closeAndDrain` does not wait on a quiet peer.
    pub fn shutdownFd(self: *Backend, fd: Fd) void {
        _ = self;
        _ = linux.shutdown(fd, linux.SHUT.RDWR);
    }
};

const ListenerCancelDisposition = enum { resolved, wait_for_target };

/// An exact async-cancel either retires the target, finds it already retired,
/// or loses a race to an operation already proceeding toward its CQE. Only the
/// first two make descriptor close immediately safe. Any other result says
/// nothing about whether the target will complete, so the backend conservatively
/// keeps draining rather than freeing beneath a live accept.
fn classifyListenerCancel(result: i32) ListenerCancelDisposition {
    const not_found = -@as(i32, @intFromEnum(linux.E.NOENT));
    if (result >= 0 or result == not_found) return .resolved;
    return .wait_for_target;
}

/// Narrow test seam for the listener-cancel race classifier. Empty in every
/// production build so platform internals do not become library surface.
pub const white_box = if (builtin.is_test) struct {
    pub fn cancelResolved(result: i32) bool {
        return classifyListenerCancel(result) == .resolved;
    }
} else struct {};

// `openListener`/`openSocket` delegate their socket/bind/listen naming to
// `socket_tcp`, so the one syscall this backend checks itself is `getsockname`
// (the kernel-chosen port after a port-0 bind). Name it rather than collapse it
// to a generic syscall fault (ADR-0081, contract 1).
fn check(rc: usize) error{GetSockNameFailed}!void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => error.GetSockNameFailed,
    };
}
