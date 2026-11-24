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
