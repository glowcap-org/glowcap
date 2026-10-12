//! An allocator wrapper that overwrites every block it frees.
//!
//! Lifetime tests want to prove that a value is *not* read after its owner
//! released it. Comparing the value's contents cannot show that on its own: a
//! freed block often still holds its old bytes, so a genuine
//! read-after-free reads exactly what a correct program would and the test
//! passes for the wrong reason. This wrapper removes that coincidence by
//! scribbling a fixed byte over each block before passing the free through, so a
//! dangling read yields the scribble and the assertion fails where the defect
//! is.
//!
//! Wrap whatever allocator the test would otherwise use, normally
//! `std.testing.allocator`, so leak and double-free detection still apply.

const std = @import("std");

/// The byte written over freed memory. Chosen to differ from the `0xaa` that
/// safe builds already write into undefined memory, so a failure message tells
//  you which mechanism caught it.
pub const poison_byte: u8 = 0x5a;

pub const PoisonOnFree = struct {
    inner: std.mem.Allocator,

    pub fn allocator(self: *PoisonOnFree) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        // A shrink leaves the tail unreachable, so poison it like a free.
        if (new_len < memory.len and self.inner.rawResize(memory, alignment, new_len, ret_addr)) {
            @memset(memory[new_len..], poison_byte);
            return true;
        }
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonOnFree = @ptrCast(@alignCast(ctx));
        @memset(memory, poison_byte);
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

test "freeing a block scribbles over its bytes" {
    // Backed by a buffer this test owns, so the freed bytes can be inspected
    // through the buffer rather than through the dangling pointer, reading
    // that pointer is the very thing this helper exists to catch.
    var backing: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var wrapper: PoisonOnFree = .{ .inner = fixed.allocator() };
    const gpa = wrapper.allocator();

    const block = try gpa.alloc(u8, 16);
    @memset(block, 'x');
    const offset = @intFromPtr(block.ptr) - @intFromPtr(&backing);
    gpa.free(block);

    for (backing[offset..][0..16]) |byte| try std.testing.expectEqual(poison_byte, byte);
}
