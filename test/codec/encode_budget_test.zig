//! Outbound encode allocation budget.
//!
//! The wire-path contract is that every allocation and copy is forbidden,
//! intentional, or measured. The inbound steady-state path is pinned by
//! `test/engine/alloc_budget_test.zig`; this is the outbound counterpart. It
//! locks the number of heap allocations one `encodeMessage` of a fixed small
//! message costs, so a future change that doubles the encoder's allocation
//! traffic fails loudly instead of slipping past the gate.
//!
//! A regression in either direction fails: the budget is an exact contract, not
//! an upper bound.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const capnp = pancake.ocapn.codec.capnp;
const syrup = pancake.ocapn.codec.syrup;

/// Counts every backing allocation (fresh `alloc`, plus a `remap`/`resize` that
/// grows an existing block), matching the inbound budget test's accounting.
const TotalCountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *TotalCountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.allocs += 1;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.allocs += 1;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn expectEncodeBudget(
    comptime name: []const u8,
    expected_budget: usize,
    encode: *const fn (std.mem.Allocator, model.Message) anyerror!foundation.Frame,
) !void {
    var counter = TotalCountingAllocator{ .backing = std.testing.allocator };
    const gpa = counter.allocator();

    // A `op:deliver` to the partner bootstrap carrying one inline bytes
    // argument, the outbound twin of the inbound budget test's frame.
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(11),
        },
    };

    // Warm up so any one-time backing growth is out of the measured window, then
    // measure a block of encodes.
    for (0..4) |_| {
        var frame = try encode(gpa, message);
        frame.deinit();
    }

    const turns = 16;
    counter.allocs = 0;
    for (0..turns) |_| {
        var frame = try encode(gpa, message);
        frame.deinit();
    }

    try std.testing.expectEqual(@as(usize, 0), counter.allocs % turns);
    const per_encode = counter.allocs / turns;

    // The encoder builds the record into a growable buffer and hands it to an
    // owned `Frame`. This pins the per-encode allocation count so the outbound
    // half of the wire path is measured, not just timed by the codec benchmark.
    errdefer std.debug.print("{s} per_encode_allocs={d}\n", .{ name, per_encode });
    try std.testing.expectEqual(@as(usize, expected_budget), per_encode);
}

test "encoding a small deliver holds its outbound allocation budget" {
    try expectEncodeBudget("syrup", 2, syrup.encodeMessage);
    try expectEncodeBudget("capnp", 2, capnp.encodeMessage);
}
