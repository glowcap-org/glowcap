//! A counting C allocator over `std.testing.allocator`, for proving a C ABI
//! handle family returns every byte it took: build a `PancakeContext` from
//! `spec()`, drive the `*_new_in` twins through it, and assert `balanced()`
//! after the releases. The testing allocator underneath catches
//! use-after-free and size/alignment mismatches; the counters catch a leak
//! that never crossed back.

const std = @import("std");

const c = @import("c_abi");

pub const CountingHost = struct {
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    live_bytes: usize = 0,
    fail_allocations: bool = false,
    allocations_before_failure: ?usize = null,

    pub fn spec(self: *CountingHost) c.PancakeAllocator {
        return .{ .alloc = hostAlloc, .free = hostFree, .user_data = self };
    }

    pub fn balanced(self: *const CountingHost) bool {
        return self.alloc_calls == self.free_calls and self.live_bytes == 0;
    }

    fn hostAlloc(user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *CountingHost = @ptrCast(@alignCast(user_data.?));
        if (self.fail_allocations) return null;
        if (self.allocations_before_failure) |remaining| {
            if (remaining == 0) return null;
            self.allocations_before_failure = remaining - 1;
        }
        const al = std.mem.Alignment.fromByteUnits(alignment);
        const ptr = std.testing.allocator.rawAlloc(size, al, @returnAddress()) orelse return null;
        _ = @atomicRmw(usize, &self.alloc_calls, .Add, 1, .monotonic);
        _ = @atomicRmw(usize, &self.live_bytes, .Add, size, .monotonic);
        return @ptrCast(ptr);
    }

    fn hostFree(user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self: *CountingHost = @ptrCast(@alignCast(user_data.?));
        const al = std.mem.Alignment.fromByteUnits(alignment);
        const slice = @as([*]u8, @ptrCast(ptr.?))[0..size];
        std.testing.allocator.rawFree(slice, al, @returnAddress());
        _ = @atomicRmw(usize, &self.free_calls, .Add, 1, .monotonic);
        _ = @atomicRmw(usize, &self.live_bytes, .Sub, size, .monotonic);
    }
};
