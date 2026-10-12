//! Outbound encode allocation budget.
//!
//! The wire-path contract is that every allocation and copy is forbidden,
//! intentional, or measured. The inbound steady-state path is pinned by
//! `test/engine/alloc_budget_test.zig`. This is the outbound counterpart. It
//! locks the number of heap allocations one `encodeMessage` of a fixed small
//! message costs, so a future change that doubles the encoder's allocation
//! traffic fails loudly instead of slipping past the gate.
//!
//! A regression in either direction fails: the budget is an exact contract, not
//! an upper bound.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const capnp = glowcap.ocapn.codec.capnp;
const syrup = glowcap.ocapn.codec.syrup;

/// Counts every backing allocation (fresh `alloc`, plus a `remap`/`resize` that
/// grows an existing block), matching the inbound budget test's accounting.
/// Growth events are also tallied separately (`grows`), so a test can pin
/// "zero reallocs" directly rather than inferring it from the total.
const TotalCountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,
    grows: usize = 0,
    shrinks: usize = 0,

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
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok and new_len > memory.len) self.grows += 1;
        if (ok and new_len < memory.len) self.shrinks += 1;
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) {
            self.allocs += 1;
            self.grows += 1;
        }
        if (result != null and new_len < memory.len) self.shrinks += 1;
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

    // This pins the per-encode allocation count so the outbound half of the
    // wire path is measured, not just timed by the codec benchmark.
    errdefer std.debug.print("{s} per_encode_allocs={d}\n", .{ name, per_encode });
    try std.testing.expectEqual(@as(usize, expected_budget), per_encode);
}

test "encoding a small deliver holds its outbound allocation budget" {
    // Syrup renders measure-then-fill into one exact allocation. Cap'n Proto
    // reserves one owned word buffer and transfers it into the Frame. Its
    // segment-table word is reserved ahead of the segment, so finishing copies
    // none of the encoded bytes, and `Builder.initial_words` covers an ordinary
    // control message so none of it is re-copied by a growth realloc either.
    try expectEncodeBudget("syrup", 1, syrup.encodeMessage);
    try expectEncodeBudget("capnp", 1, capnp.encodeMessage);
}

test "encoding a large deliver costs one exact allocation and zero reallocs" {
    // The measure-then-fill contract at scale: a payload far past any growable
    // buffer's initial capacity still costs exactly one allocation, where the
    // doubling policy would have paid O(log n) whole-buffer growth reallocs.
    var counter = TotalCountingAllocator{ .backing = std.testing.allocator };
    const gpa = counter.allocator();

    const payload = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0xab);

    const nested = [_]model.Argument{
        .{ .integer = -123456789 },
        .{ .string = "a nested string leaf" },
        .{ .boolean = true },
    };
    const args = [_]model.Argument{
        .{ .bytes = payload },
        .{ .list = nested[0..] },
    };
    const message = model.Message{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(0) } },
            .args = args[0..],
            .answer = .from(11),
        },
    };

    var frame = try syrup.encodeMessage(gpa, message);
    defer frame.deinit();

    try std.testing.expect(frame.bytes().len > payload.len);
    try std.testing.expectEqual(@as(usize, 1), counter.allocs);
    try std.testing.expectEqual(@as(usize, 0), counter.grows);
    try std.testing.expectEqual(@as(usize, 0), counter.shrinks);
}
