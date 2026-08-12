//! Shared recv scratch pool for readiness-based completion backends (ADR-0054).
//!
//! kqueue and iroh both read at poll/harvest time into a borrowed buffer, then
//! lend that buffer on the completion until `recycleRecv` reclaims it. The pool
//! grows lazily to a fixed capacity; exhaustion completes with
//! `Completion.recv_no_buffer` rather than a connection error.

const std = @import("std");

pub const ScratchPool = struct {
    allocator: std.mem.Allocator,
    /// Every allocated buffer, indexed by the `recv_token` the loop hands back
    /// through `recycleRecv`. Grows lazily to `cap` and keeps them for life.
    items: std.ArrayList([]u8),
    /// Indices not currently lent out. Reserved to `cap` at init so reclaim
    /// cannot fail.
    free: std.ArrayList(u16),
    cap: u16,
    bytes: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !ScratchPool {
        if (read_buffer_bytes == 0) return error.InvalidReadBufferBytes;
        const cap: u16 = @max(read_buffers, 1);
        var items: std.ArrayList([]u8) = .empty;
        errdefer items.deinit(allocator);
        try items.ensureTotalCapacity(allocator, cap);
        var free: std.ArrayList(u16) = .empty;
        errdefer free.deinit(allocator);
        try free.ensureTotalCapacity(allocator, cap);

        return .{
            .allocator = allocator,
            .items = items,
            .free = free,
            .cap = cap,
            .bytes = read_buffer_bytes,
        };
    }

    pub fn deinit(self: *ScratchPool) void {
        for (self.items.items) |buf| self.allocator.free(buf);
        self.items.deinit(self.allocator);
        self.free.deinit(self.allocator);
    }

    /// Take a free scratch buffer, allocating lazily up to the pool size; null
    /// when every buffer is lent out on a completion.
    pub fn acquire(self: *ScratchPool) ?u16 {
        if (self.free.pop()) |idx| return idx;
        if (self.items.items.len >= self.cap) return null;
        const buf = self.allocator.alloc(u8, self.bytes) catch return null;
        self.items.appendAssumeCapacity(buf);
        return @intCast(self.items.items.len - 1);
    }

    pub fn release(self: *ScratchPool, idx: u16) void {
        self.free.appendAssumeCapacity(idx);
    }

    pub fn buffer(self: *const ScratchPool, idx: u16) []u8 {
        return self.items.items[idx];
    }
};
