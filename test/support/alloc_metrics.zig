//! Instrumented allocators the budget tests measure through.
//!
//! Two budgets live on the wire path and the session path, and each needs a
//! different lens on the same allocator traffic. `CountingAllocator` counts
//! allocation events, so a test can pin how many heap allocations one turn costs.
//! `LiveBytesAllocator` tracks outstanding bytes, so a test can weigh the steady
//! heap a set of warmed sessions holds. Both wrap a backing allocator and forward
//! every call. They add the instrumentation and nothing else.

const std = @import("std");

/// Observe positive request demand with in-place growth unavailable. Bound is
/// the owner's checked demand accumulator. No private growth formula is copied.
pub fn AllocationTraffic(comptime Bound: type) type {
    return struct {
        backing: std.mem.Allocator,
        demand: Bound = .{},
        const Self = @This();
        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const pointer = self.backing.rawAlloc(len, alignment, address) orelse return null;
            self.demand.include(len, alignment.toByteUnits(), 1) catch {
                self.backing.rawFree(pointer[0..len], alignment, address);
                return null;
            };
            return pointer;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(memory, alignment, address);
        }
    };
}

/// Counts every backing allocation, a fresh `alloc`, plus a `remap`/`resize`
/// that grows an existing block, so a measurement reflects real heap traffic,
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
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok and new_len > memory.len) self.allocs += 1;
        return ok;
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

/// Tracks live (outstanding) heap bytes by accumulating the signed delta of
/// every allocator operation. The live count after a set of peers is built and
/// warmed, with every transient frame already freed, is the steady heap those
/// peers hold.
pub const LiveBytesAllocator = struct {
    backing: std.mem.Allocator,
    live: i128 = 0,

    pub fn allocator(self: *LiveBytesAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn note(self: *LiveBytesAllocator, delta: i128) void {
        self.live += delta;
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
