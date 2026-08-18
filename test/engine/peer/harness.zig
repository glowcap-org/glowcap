//! Allocator fixtures for the Peer suite: fail-after-N and counting
//! allocators, so an OOM path is driven at an exact allocation and a copy
//! claim is a counted fact.

const std = @import("std");

pub const FailAfterAllocator = struct {
    backing: std.mem.Allocator,
    fail_after: usize,
    allocation_count: usize = 0,

    pub fn allocator(self: *FailAfterAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        if (self.allocation_count >= self.fail_after) return null;
        self.allocation_count += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    pub fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    pub fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.allocation_count >= self.fail_after) return null;
        if (new_len > memory.len) self.allocation_count += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    pub fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailAfterAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count_size: usize = 0,
    matching_allocs: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (len == self.count_size) self.matching_allocs += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    pub fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    pub fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    pub fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
