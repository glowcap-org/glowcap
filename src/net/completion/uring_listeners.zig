//! The io_uring backend's listener rows.
//!
//! A listening socket cannot rely on `shutdown(2)` to cancel an io_uring
//! accept, so a listener close first cancels its armed accept by exact
//! user_data and closes the descriptor only once that accept has retired. The
//! close then completes synthetically, through `close_ready`. Every table is
//! reserved when the listener opens, so neither an accept, a close, nor a CQE
//! allocates.

const std = @import("std");

/// `std.os.linux.fd_t`. `uring.zig` owns the platform calls.
const Fd = i32;

pub const Listeners = struct {
    rows: std.AutoHashMapUnmanaged(Fd, Row) = .empty,
    /// The armed accept's user_data to its listener, so a CQE finds its row.
    accepts: std.AutoHashMapUnmanaged(u64, Fd) = .empty,
    /// Synthetic close completions waiting for room in a `poll` result. One
    /// slot per open listener is reserved.
    close_ready: std.ArrayListUnmanaged(u64) = .empty,

    const Row = struct {
        accept_ud: ?u64 = null,
        cancel: ?Cancel = null,
    };

    const Cancel = struct {
        close_ud: u64,
        phase: enum { cancel_pending, waiting_target } = .cancel_pending,
    };

    /// Backend-private completion identity for a listener's accept cancel.
    /// Loop user_data always carries a three-bit `Op` tag of 0...5 in its top
    /// bits, so tag 7 is never emitted by the Loop or by an adapter preserving
    /// that payload.
    const cancel_tag: u64 = 0b111 << 61;

    pub fn deinit(self: *Listeners, allocator: std.mem.Allocator) void {
        var rows = self.rows.valueIterator();
        while (rows.next()) |row| std.debug.assert(row.cancel == null);
        std.debug.assert(self.close_ready.items.len == 0);
        self.rows.deinit(allocator);
        self.accepts.deinit(allocator);
        self.close_ready.deinit(allocator);
    }

    pub fn reserve(self: *Listeners, allocator: std.mem.Allocator) !void {
        try self.rows.ensureUnusedCapacity(allocator, 1);
        try self.accepts.ensureUnusedCapacity(allocator, 1);
        try self.close_ready.ensureTotalCapacity(allocator, self.rows.count() + 1);
    }

    /// After `reserve`.
    pub fn open(self: *Listeners, fd: Fd) void {
        self.rows.putAssumeCapacityNoClobber(fd, .{});
    }

    pub fn noteAccept(self: *Listeners, fd: Fd, user_data: u64) void {
        const row = self.rows.getPtr(fd).?;
        std.debug.assert(row.accept_ud == null);
        row.accept_ud = user_data;
        self.accepts.putAssumeCapacityNoClobber(user_data, fd);
    }

    /// The accept a close must cancel first, or null when the listener can
    /// close at once. A null answer forgets the row.
    pub fn beginClose(self: *Listeners, fd: Fd, close_ud: u64) ?u64 {
        const row = self.rows.getPtr(fd) orelse return null;
        const accept_ud = row.accept_ud orelse {
            std.debug.assert(self.rows.remove(fd));
            return null;
        };
        std.debug.assert(row.cancel == null);
        row.cancel = .{ .close_ud = close_ud };
        return accept_ud;
    }

    /// A descriptor closed outside the cancel protocol. Its armed accept, if
    /// any, still retires through `retireAccept`.
    pub fn forget(self: *Listeners, fd: Fd) void {
        // idempotent: most closed descriptors were never listeners.
        _ = self.rows.remove(fd);
    }

    pub fn cancelUd(fd: Fd) u64 {
        return cancel_tag | @as(u32, @bitCast(fd));
    }

    pub fn cancelTarget(user_data: u64) ?Fd {
        if (user_data & cancel_tag != cancel_tag) return null;
        return @bitCast(@as(u32, @truncate(user_data)));
    }

    /// The listener whose accept this CQE retires, if any, with whether that
    /// listener's close was waiting on it.
    pub fn retireAccept(self: *Listeners, user_data: u64) ?struct { fd: Fd, close_due: bool } {
        if (self.accepts.count() == 0) return null;
        const entry = self.accepts.fetchRemove(user_data) orelse return null;
        const row = self.rows.getPtr(entry.value) orelse return .{ .fd = entry.value, .close_due = false };
        row.accept_ud = null;
        const due = if (row.cancel) |cancel| cancel.phase == .waiting_target else false;
        return .{ .fd = entry.value, .close_due = due };
    }

    /// The cancel CQE's verdict. True when the listener may close now.
    pub fn cancelSettled(self: *Listeners, fd: Fd, resolved: bool) bool {
        const row = self.rows.getPtr(fd).?;
        if (resolved) return true;
        row.cancel.?.phase = .waiting_target;
        // The accept CQE may have won the race and appeared earlier in this
        // same batch.
        return row.accept_ud == null;
    }

    /// Forget a listener whose descriptor the backend has just closed, and
    /// queue its synthetic close completion.
    pub fn finishClose(self: *Listeners, fd: Fd) void {
        const row = self.rows.fetchRemove(fd).?.value;
        self.close_ready.appendAssumeCapacity(row.cancel.?.close_ud);
    }

    /// Move queued close completions into `out[produced.*..]`.
    pub fn emitClosed(self: *Listeners, out: anytype, produced: *usize) void {
        const take = @min(self.close_ready.items.len, out.len - produced.*);
        for (self.close_ready.items[0..take]) |close_ud| {
            out[produced.*] = .{ .user_data = close_ud, .result = 0 };
            produced.* += 1;
        }
        self.close_ready.replaceRangeAssumeCapacity(0, take, &.{});
    }
};
