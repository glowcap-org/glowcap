//! Try-I/O completion over a readiness hint, shared by the multiplexed
//! sidecar backends.
//!
//! iroh and WebRTC both reach glowcap through a sidecar that reports
//! readiness edges on one descriptor and offers non-blocking try-read and
//! try-write verbs. Turning that into the completion contract is the same
//! machine for both: a submitted read or write waits on the hint its last
//! edge left, one attempt runs when the hint is up, a would-block outcome
//! keeps the seat and drops the hint, and a terminal failure latches on the
//! entry so every later operation settles with the same first cause. This
//! module owns that machine. The backend supplies the sidecar verbs, the
//! seat accounting its ready queue uses, and the borrow token its buffer pool
//! lends under.

const contract = @import("contract.zig");

/// Seats and hints for one open sidecar connection.
pub const HintedPending = struct {
    read_ud: ?u64 = null,
    write_ud: ?u64 = null,
    write_bytes: ?[]const u8 = null,
    /// The first terminal cause discovered while open: a signaling refusal,
    /// a candidate the sidecar rejected, or an I/O fault. Once set, every
    /// pending and later read or write completes with it instead of touching
    /// the sidecar again.
    terminal_failure: ?anyerror = null,
    readable_hint: bool = false,
    writable_hint: bool = false,
};

/// One non-blocking read attempt.
pub const TryRead = union(enum) {
    transferred: usize,
    would_block,
    closed,
    failed: anyerror,
};

/// One non-blocking write attempt.
pub const TryWrite = union(enum) {
    transferred: usize,
    would_block,
    failed: anyerror,
};

/// `Ops` binds the machine to one backend:
///
///   * `Entry`, the connection row, with a `pending: HintedPending` field.
///   * `tryRead(entry, buf) TryRead` and `tryWrite(entry, bytes) TryWrite`,
///     the sidecar verbs;
///   * `closeOnFailure(entry) void`, run once when a failure latches.
///   * `borrowToken(index) u32`, the token a lent pool buffer carries.
///   * `reserveSeats(backend, count) !void` and `publish(backend, completion)
///     void`, the ready queue's admission and its infallible append;
///   * `holds_admission_seat`, whether an admitted read or write keeps its
///     seat until it completes (iroh) or reserves one per publication
///     (WebRTC). It decides how many seats a cancellation must add.
///
/// The backend keeps `conns`, keyed by `Backend.Fd`, and a `buffer_pool`.
pub fn HintedTryIo(comptime Backend: type, comptime Ops: type) type {
    return struct {
        const Entry = Ops.Entry;
        const Fd = Backend.Fd;

        pub fn entryPtr(backend: *Backend, fd: Fd) !*Entry {
            return backend.conns.getPtr(fd) orelse error.InvalidFd;
        }

        /// Requires one seat for the completion it may publish. A would-block
        /// attempt publishes nothing and keeps the caller's read pending.
        pub fn completeRecv(backend: *Backend, entry: *Entry) void {
            const ud = entry.pending.read_ud orelse return;
            var comp: contract.Completion = .{ .user_data = ud, .result = -1 };
            if (entry.pending.terminal_failure) |err| {
                comp.failure = err;
                entry.pending.read_ud = null;
                Ops.publish(backend, comp);
                return;
            }
            if (backend.buffer_pool.acquire()) |idx| {
                const buf = backend.buffer_pool.buffer(idx);
                switch (Ops.tryRead(entry, buf)) {
                    .transferred => |n| {
                        comp.result = @intCast(n);
                        comp.borrowed = .recv(buf[0..n], Ops.borrowToken(idx));
                        // More may still be buffered: leave the hint so the next
                        // submitRecv completes without waiting for another edge.
                        entry.pending.readable_hint = true;
                    },
                    .would_block => {
                        // Edge spent without bytes: keep the pending recv; a
                        // later readable (or a left-over hint) will retry.
                        backend.buffer_pool.release(idx);
                        entry.pending.readable_hint = false;
                        return;
                    },
                    .closed => {
                        comp.result = 0;
                        backend.buffer_pool.release(idx);
                        entry.pending.readable_hint = false;
                    },
                    .failed => |err| {
                        backend.buffer_pool.release(idx);
                        entry.pending.readable_hint = false;
                        comp.failure = err;
                        latch(entry, err);
                    },
                }
            } else {
                comp.recv_no_buffer = true;
                // Keep the hint: the loop re-arms once a buffer recycles.
            }
            entry.pending.read_ud = null;
            Ops.publish(backend, comp);
        }

        /// Requires one seat for the completion it may publish. A would-block
        /// attempt publishes nothing and keeps the caller's write pending.
        pub fn completeSend(backend: *Backend, entry: *Entry) void {
            const ud = entry.pending.write_ud orelse return;
            const bytes = entry.pending.write_bytes orelse return;
            if (entry.pending.terminal_failure) |err| {
                entry.pending.write_ud = null;
                entry.pending.write_bytes = null;
                Ops.publish(backend, .{ .user_data = ud, .result = -1, .failure = err });
                return;
            }
            var result: i32 = -1;
            var failure: ?anyerror = null;
            switch (Ops.tryWrite(entry, bytes)) {
                .transferred => |n| {
                    result = @intCast(n);
                    entry.pending.writable_hint = true;
                },
                .would_block => {
                    entry.pending.writable_hint = false;
                    return;
                },
                .failed => |err| {
                    entry.pending.writable_hint = false;
                    failure = err;
                    latch(entry, err);
                },
            }
            entry.pending.write_ud = null;
            entry.pending.write_bytes = null;
            Ops.publish(backend, .{ .user_data = ud, .result = result, .failure = failure });
        }

        pub fn submitRecv(backend: *Backend, user_data: u64, fd: Fd) !void {
            const entry = try entryPtr(backend, fd);
            if (entry.pending.read_ud != null) return error.AlreadyReading;
            try Ops.reserveSeats(backend, 1);
            entry.pending.read_ud = user_data;
            if (entry.pending.readable_hint or entry.pending.terminal_failure != null)
                completeRecv(backend, entry);
        }

        pub fn submitSend(backend: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
            const entry = try entryPtr(backend, fd);
            if (entry.pending.write_ud != null) return error.AlreadyWriting;
            try Ops.reserveSeats(backend, 1);
            entry.pending.write_ud = user_data;
            entry.pending.write_bytes = bytes;
            // Always attempt once: a seeded writable hint or a live edge may
            // already allow the write; a would-block parks until the next edge.
            completeSend(backend, entry);
        }

        pub fn submitCancel(
            backend: *Backend,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            const entry = try entryPtr(backend, fd);
            const target_pending = if (entry.pending.read_ud) |ud| blk: {
                if (ud != target_user_data) return error.InvalidCancelTarget;
                break :blk true;
            } else false;
            // The target's record rides the seat its admission holds where the
            // backend keeps one; otherwise it is reserved here beside the
            // cancellation's own record.
            const target_seats: usize = if (Ops.holds_admission_seat) 0 else @intFromBool(target_pending);
            try Ops.reserveSeats(backend, 1 + target_seats);
            if (target_pending) {
                entry.pending.read_ud = null;
                Ops.publish(backend, .{ .user_data = target_user_data, .result = -1 });
            }
            // With no pending seat, completeRecv already queued the target
            // before the loop could request cancellation.
            Ops.publish(backend, .{ .user_data = cancel_user_data, .result = 0 });
        }

        /// Mark an open connection terminal and settle every seat already
        /// parked on it. Later submissions observe the same originating cause.
        pub fn failOpenConnection(backend: *Backend, entry: *Entry, cause: anyerror) void {
            latch(entry, cause);
            if (entry.pending.read_ud != null) completeRecv(backend, entry);
            if (entry.pending.write_ud != null) completeSend(backend, entry);
        }

        fn latch(entry: *Entry, cause: anyerror) void {
            if (entry.pending.terminal_failure != null) return;
            entry.pending.terminal_failure = cause;
            Ops.closeOnFailure(entry);
        }
    };
}
