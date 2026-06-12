//! Instrumented allocators the budget tests measure through.
//!
//! Two budgets live on the wire path and the session path, and each needs a
//! different lens on the same allocator traffic. `CountingAllocator` counts
//! allocation events, so a test can pin how many heap allocations one turn costs.
//! `LiveBytesAllocator` tracks outstanding bytes, so a test can weigh the steady
//! heap a set of warmed sessions holds. Both wrap a backing allocator and forward
//! every call; they add the instrumentation and nothing else.

const std = @import("std");

/// Counts every backing allocation — a fresh `alloc`, plus a `remap`/`resize`
/// that grows an existing block — so a measurement reflects real heap traffic,
/// not just same-size churn. Reset `allocs` to zero to start a measurement
/// window.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.allocs += 1;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.allocs += 1;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// Tracks live (outstanding) heap bytes and the peak by accumulating the signed
/// delta of every allocator operation. The live count after a set of peers is
/// built and warmed, with every transient frame already freed, is the steady
/// heap those peers hold.
pub const LiveBytesAllocator = struct {
    backing: std.mem.Allocator,
    live: i128 = 0,
    peak: i128 = 0,

    pub fn allocator(self: *LiveBytesAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn note(self: *LiveBytesAllocator, delta: i128) void {
        self.live += delta;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.note(@intCast(len));
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.note(@as(i128, @intCast(new_len)) - @as(i128, @intCast(memory.len)));
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) self.note(@as(i128, @intCast(new_len)) - @as(i128, @intCast(memory.len)));
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveBytesAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.note(-@as(i128, @intCast(memory.len)));
    }

    pub fn liveBytes(self: *const LiveBytesAllocator) u64 {
        return if (self.live < 0) 0 else @intCast(self.live);
    }
};
