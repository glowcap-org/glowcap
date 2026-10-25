//! An allocator that refuses one allocation, the `fail_index`th, and serves
//! every other. A test lands one refusal at every site a program reaches and
//! lets the program run on, the way a process under a brief shortage does.
//! `std.testing.FailingAllocator` refuses every allocation from its index on,
//! the lasting shortage, and a test that needs both runs them side by side.
//! The byte counters say whether the program returned everything it took, and
//! the captured trace says where the refusal landed.

const std = @import("std");

pub const FailingOnce = struct {
    backing: std.mem.Allocator,
    fail_index: usize,
    alloc_index: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    induced: bool = false,
    return_addresses: [frame_count]usize = @splat(0),

    const frame_count = 16;

    pub fn init(backing: std.mem.Allocator, fail_index: usize) FailingOnce {
        return .{ .backing = backing, .fail_index = fail_index };
    }

    pub fn allocator(self: *FailingOnce) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Whether every byte the program took came back.
    pub fn balanced(self: *const FailingOnce) bool {
        return self.allocated_bytes == self.freed_bytes;
    }

    /// Where the refusal landed. Valid once `induced` is set.
    pub fn stackTrace(self: *FailingOnce) std.debug.StackTrace {
        std.debug.assert(self.induced);
        var len: usize = 0;
        while (len < frame_count and self.return_addresses[len] != 0) len += 1;
        return .{
            .return_addresses = self.return_addresses[0..len],
            .skipped = if (len == frame_count) .unknown else .none,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailingOnce = @ptrCast(@alignCast(ctx));
        const index = self.alloc_index;
        self.alloc_index += 1;
        if (index == self.fail_index) {
            const trace = std.debug.captureCurrentStackTrace(.{ .first_address = return_address }, &self.return_addresses);
            @memset(self.return_addresses[@min(trace.return_addresses.len, frame_count)..], 0);
            self.induced = true;
            return null;
        }
        const pointer = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocated_bytes += len;
        return pointer;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *FailingOnce = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, return_address)) return false;
        self.account(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *FailingOnce = @ptrCast(@alignCast(ctx));
        const pointer = self.backing.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.account(memory.len, new_len);
        return pointer;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailingOnce = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, return_address);
        self.freed_bytes += memory.len;
    }

    fn account(self: *FailingOnce, old_len: usize, new_len: usize) void {
        if (new_len < old_len) {
            self.freed_bytes += old_len - new_len;
        } else {
            self.allocated_bytes += new_len - old_len;
        }
    }
};

test "the indexed allocation is refused once and the rest are served" {
    var failing = FailingOnce.init(std.testing.allocator, 1);
    const gpa = failing.allocator();
    const first = try gpa.alloc(u8, 8);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 8));
    try std.testing.expect(failing.induced);
    const third = try gpa.alloc(u8, 8);
    gpa.free(third);
    try std.testing.expect(!failing.balanced());
    gpa.free(first);
    try std.testing.expect(failing.balanced());
}
