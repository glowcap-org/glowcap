//! The Linux io_uring completion backend for `completion.Loop`.
//!
//! This file is one implementation of the completion-backend interface documented
//! in [`completion`](completion.zig): it provides the platform completion
//! primitive (io_uring) and the loopback socket primitives, and nothing else. All
//! the portable connection orchestration lives in `completion.Loop`, which is
//! generic over this backend. The kqueue (macOS/BSD) sibling is a separate file
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

comptime {
    if (builtin.os.tag != .linux) @compileError("the io_uring completion backend is Linux-only");
}

pub const Backend = struct {
    pub const Fd = linux.fd_t;

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

    pub fn init(
        allocator: std.mem.Allocator,
        queue_entries: u16,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
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
        const sqe = try self.getSqe();
        sqe.prep_accept(listen_fd, null, null, 0);
        sqe.user_data = user_data;
    }

    pub fn submitConnect(self: *Backend, user_data: u64, fd: Fd, address: std.Io.net.IpAddress) !void {
        const ip4 = switch (address) {
            .ip4 => |ip4| ip4,
            .ip6 => return error.AddressFamilyUnsupported,
        };
        var addr: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, ip4.port),
            .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &ip4.bytes, .big)),
        };
        const sqe = try self.getSqe();
        sqe.prep_connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
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

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        const sqe = try self.getSqe();
        sqe.prep_close(fd);
        sqe.user_data = user_data;
    }

    /// Return a recv completion's pool buffer to the kernel ring. The loop
    /// calls this exactly once per completion that carried `recv_bytes`.
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

    /// Flush queued submissions, wait for at least one completion, and copy up to
    /// `out.len` completions back to the server, surfacing each selected pool
    /// buffer as a borrowed view.
    pub fn poll(self: *Backend, out: []completion.Completion) !usize {
        _ = self.ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => return 0,
            else => return err,
        };
        var cqes: [256]linux.io_uring_cqe = undefined;
        const want = @min(out.len, cqes.len);
        const n = try self.ring.copy_cqes(cqes[0..want], 0);
        for (cqes[0..n], 0..) |cqe, i| {
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
            out[i] = comp;
        }
        return n;
    }

    fn bufferSlice(self: *Backend, buffer_id: u16) []u8 {
        const pos = @as(usize, self.buf_bytes) * buffer_id;
        return self.buffers[pos .. pos + self.buf_bytes];
    }

    const enobufs_res: i32 = -@as(i32, @intFromEnum(linux.E.NOBUFS));

    pub fn openListener(port: u16) !Fd {
        const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        try check(fd_rc);
        const fd: Fd = @intCast(fd_rc);
        errdefer _ = linux.close(fd);

        // Allow rebinding a port still in TIME_WAIT, matching the blocking
        // `tcp.Listener` (which passes `reuse_address = true`). A loop restarted
        // on a pinned port (`-Dport=N`) would otherwise fail to bind for the
        // TIME_WAIT window where the blocking listener succeeds.
        const enable: u32 = 1;
        try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&enable), @sizeOf(u32)));

        var addr: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f00_0001), // 127.0.0.1
        };
        try check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
        try check(linux.listen(fd, completion.listen_backlog));
        return fd;
    }

    pub fn openSocket() !Fd {
        const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        try check(fd_rc);
        return @intCast(fd_rc);
    }

    pub fn boundPort(fd: Fd) !u16 {
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        try check(linux.getsockname(fd, @ptrCast(&addr), &len));
        return std.mem.bigToNative(u16, addr.port);
    }

    pub fn closeFd(fd: Fd) void {
        _ = linux.close(fd);
    }
};

fn check(rc: usize) !void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => error.SyscallFailed,
    };
}
