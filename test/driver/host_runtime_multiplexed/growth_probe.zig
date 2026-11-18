//! The allocator probe the multiplexed-runtime proofs share. It wraps the
//! testing allocator and counts or refuses growth requests, so a proof can
//! show which request a runtime made, or that it made none.

const std = @import("std");

/// No target length.
pub const none = std.math.maxInt(usize);

/// Wraps the testing allocator. Armed with `refuse_all`, it refuses every
/// growth. Armed with `target_len`, it refuses every growth request of exactly
/// that size and records which request, by position, was the first refused.
pub const Probe = struct {
    backing: std.mem.Allocator,
    refuse_all: bool = false,
    refused_all: usize = 0,
    target_len: usize = none,
    hits: usize = 0,
    /// Growth requests granted before the first refused target.
    granted_before_hit: usize = 0,
    granted: usize = 0,
    count_a_len: usize = none,
    count_a: usize = 0,
    count_b_len: usize = none,
    count_b: usize = 0,

    pub fn allocator(self: *Probe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn refuses(self: *Probe, len: usize) bool {
        if (len == self.count_a_len) self.count_a += 1;
        if (len == self.count_b_len) self.count_b += 1;
        if (self.refuse_all) {
            self.refused_all += 1;
            return true;
        }
        if (len == self.target_len) {
            if (self.hits == 0) self.granted_before_hit = self.granted;
            self.hits += 1;
            return true;
        }
        self.granted += 1;
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        if (self.refuses(len)) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.refuses(new_len)) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.refuses(new_len)) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
