//! Bounded shared byte-buffer pool for completion backends and adapters.
//!
//! Buffers grow lazily to a fixed count and remain pool-owned for its lifetime.
//! A borrower holds an index until the operation that lent the bytes is
//! explicitly recycled. Exhaustion is ordinary bounded pressure, never a
//! connection failure and never permission to allocate outside the pool.

const std = @import("std");

pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    /// Every allocated buffer, indexed by the token returned from `acquire`.
    items: std.ArrayList([]u8),
    /// Indices not currently leased. Reserved to `cap` during initialization,
    /// so releasing a lease cannot fail.
    free: std.ArrayList(u16),
    cap: u16,
    bytes: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        buffer_count: u16,
        buffer_bytes: u32,
    ) !BufferPool {
        if (buffer_bytes == 0) return error.InvalidBufferBytes;
        const cap: u16 = @max(buffer_count, 1);
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
            .bytes = buffer_bytes,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        std.debug.assert(self.leasedCount() == 0);
        for (self.items.items) |buf| self.allocator.free(buf);
        self.items.deinit(self.allocator);
        self.free.deinit(self.allocator);
    }

    /// Take one buffer, allocating lazily up to the configured count. Returns
    /// null while every buffer is leased or when lazy allocation is refused.
    pub fn acquire(self: *BufferPool) ?u16 {
        if (self.free.pop()) |idx| return idx;
        if (self.items.items.len >= self.cap) return null;
        const buf = self.allocator.alloc(u8, self.bytes) catch return null;
        self.items.appendAssumeCapacity(buf);
        return @intCast(self.items.items.len - 1);
    }

    pub fn release(self: *BufferPool, idx: u16) void {
        std.debug.assert(idx < self.items.items.len);
        std.debug.assert(!contains(self.free.items, idx));
        self.free.appendAssumeCapacity(idx);
    }

    pub fn buffer(self: *const BufferPool, idx: u16) []u8 {
        return self.items.items[idx];
    }

    pub fn leasedCount(self: *const BufferPool) usize {
        return self.items.items.len - self.free.items.len;
    }
};

fn contains(indices: []const u16, wanted: u16) bool {
    for (indices) |idx| if (idx == wanted) return true;
    return false;
}
