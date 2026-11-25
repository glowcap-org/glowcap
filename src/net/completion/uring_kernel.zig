//! The io_uring backend's kernel-facing pieces that hold no backend state:
//! naming the setup refusals the Linux selector falls back on, the one bounded
//! wait in the ring, and what a completion queue entry means.

const std = @import("std");
const linux = std.os.linux;

const completion = @import("loop.zig");

pub fn classifyInitFailure(err: anyerror) anyerror {
    return switch (err) {
        error.SystemOutdated => error.IoUringSystemOutdated,
        error.PermissionDenied => error.IoUringInitDenied,
        else => err,
    };
}

pub fn classifyBufferRingFailure(err: anyerror) anyerror {
    return switch (err) {
        error.ArgumentsInvalid => error.ProvidedBufferRingUnsupported,
        else => err,
    };
}

/// Wait inside the ring for one completion or `timeout_ms` (negative waits
/// without limit). A signal or the timeout is an empty turn, not a failure.
pub fn waitInRing(ring_fd: linux.fd_t, timeout_ms: i32) !void {
    var ts: linux.kernel_timespec = .{
        .sec = @divTrunc(timeout_ms, 1000),
        .nsec = @as(i64, @mod(timeout_ms, 1000)) * std.time.ns_per_ms,
    };
    const arg: linux.io_uring_getevents_arg = .{
        .sigmask = 0,
        .sigmask_sz = 0,
        .pad = 0,
        .ts = if (timeout_ms < 0) 0 else @intFromPtr(&ts),
    };
    const res = linux.syscall6(
        .io_uring_enter,
        @as(u32, @bitCast(ring_fd)),
        0,
        1,
        linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG,
        @intFromPtr(&arg),
        @sizeOf(linux.io_uring_getevents_arg),
    );
    switch (linux.errno(res)) {
        .SUCCESS, .TIME, .INTR => {},
        .BUSY => return error.CompletionQueueOvercommitted,
        else => return error.IoUringWaitFailed,
    }
}

const enobufs_res: i32 = -@as(i32, @backingInt(linux.E.NOBUFS));

/// The pool buffer `buffer_id` of `buffers`, which hold `buf_bytes` each.
pub fn bufferSlice(buffers: []u8, buf_bytes: u32, buffer_id: u16) []u8 {
    const pos = @as(usize, buf_bytes) * buffer_id;
    return buffers[pos .. pos + buf_bytes];
}

/// The completion one non-watch CQE reports.
pub fn completionFromCqe(cqe: linux.io_uring_cqe, buffers: []u8, buf_bytes: u32) completion.Completion {
    var comp: completion.Completion = .{ .user_data = cqe.user_data, .result = cqe.res };
    // A CQE carries the negated errno itself. `std.posix.errno` would read the
    // thread's libc `errno` instead whenever libc is linked.
    if (cqe.res < 0 and cqe.res != enobufs_res) {
        const errno = linux.errno(@as(usize, @bitCast(@as(isize, cqe.res))));
        comp.failure = completion.failureFromErrno(errno);
    }
    if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
        // A recv that selected a pool buffer (possibly zero bytes on EOF):
        // borrow it to the loop, which recycles it after consuming.
        const buffer_id: u16 = @intCast(cqe.flags >> linux.IORING_CQE_BUFFER_SHIFT);
        const used: usize = if (cqe.res > 0) @intCast(cqe.res) else 0;
        comp.borrowed = .recv(bufferSlice(buffers, buf_bytes, buffer_id)[0..used], buffer_id);
    } else if (cqe.res == enobufs_res) {
        // Data arrived while the pool was empty: not a connection error; the
        // loop parks the read buffer-starved and re-arms it when a buffer
        // recycles.
        comp.recv_no_buffer = true;
    }
    return comp;
}

/// The completion identity of the ring's watch on the inner epoll descriptor.
/// Its top three bits are 7. The Loop's `Op` tags stay in 0...5, and the
/// resident's `Kind` sits at bit 56 with a value of at most 8, so neither
/// emits it.
pub const watch_user_data: u64 = 0b111 << 61;

/// Prepare the one multishot poll that watches `epoll_fd`.
pub fn prepWatch(sqe: *linux.io_uring_sqe, epoll_fd: linux.fd_t) void {
    sqe.prep_poll_add(epoll_fd, linux.POLL.IN);
    sqe.len = linux.IORING_POLL_ADD_MULTI;
    sqe.user_data = watch_user_data;
}

/// How a watch completion left the watch. It is `live` while the kernel
/// promises more. Only the ring's teardown or an explicit cancel ends one
/// without error, and that one may be queued again. Any other refusal would
/// repeat on every re-arm, so it is `failed` with its cause.
pub const WatchEnd = union(enum) { live, ended, failed: anyerror };

pub fn watchEnd(cqe: linux.io_uring_cqe) WatchEnd {
    if (cqe.flags & linux.IORING_CQE_F_MORE != 0) return .live;
    const canceled = -@as(i32, @backingInt(linux.E.CANCELED));
    if (cqe.res >= 0 or cqe.res == canceled) return .ended;
    return .{ .failed = completion.failureFromErrno(linux.errno(@as(usize, @bitCast(@as(isize, cqe.res))))) };
}

/// Return pool buffer `buffer_id` to the kernel's buffer ring.
pub fn returnBuffer(
    buf_ring: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    buffers: []u8,
    buf_bytes: u32,
    buf_count: u16,
    buffer_id: u16,
) void {
    const IoUring = linux.IoUring;
    IoUring.buf_ring_add(buf_ring, bufferSlice(buffers, buf_bytes, buffer_id), buffer_id, IoUring.buf_ring_mask(buf_count), 0);
    IoUring.buf_ring_advance(buf_ring, 1);
}
