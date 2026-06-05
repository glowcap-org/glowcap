const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const runtime = pancake.runtime;
const model = pancake.model;

/// Counts every backing allocation (fresh `alloc`, plus a growing
/// `remap`/`resize`) so the wire-path measurement reflects real heap traffic.
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

const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>";

/// Print the steady-state heap traffic of one inbound `op:deliver` to a live
/// local export. Mirrors `test/runtime/alloc_budget_test.zig`; the rewrite
/// drives this number down (Phase 5 removes the validation materialization).
fn reportWirePathBudget(backing: std.mem.Allocator) !void {
    var counter = TotalCountingAllocator{ .backing = backing };
    var peer = runtime.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    const warmup = 8;
    const turns = 1024;
    for (0..warmup) |_| try driveOneTurn(&peer);
    counter.allocs = 0;
    for (0..turns) |_| try driveOneTurn(&peer);

    std.debug.print(
        "wire_path turns={d} total_allocs={d} per_turn={d}\n",
        .{ turns, counter.allocs, counter.allocs / turns },
    );
}

/// Print the in-memory footprint of the value-tree types. `Argument` is a
/// 14-arm recursive `union(enum)`, so it pays the size of its largest arm
/// everywhere; this is the layout anchor for the codec-neutral hot path (read
/// the number deliberately rather than discover it under a profiler).
fn reportModelLayout() void {
    std.debug.print(
        "model_layout Argument={d} Message={d} Reference={d} Resolution={d}\n",
        .{
            @sizeOf(model.Argument),
            @sizeOf(model.Message),
            @sizeOf(model.Reference),
            @sizeOf(model.Resolution),
        },
    );
}

fn driveOneTurn(peer: *runtime.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const iterations: usize = 1_000_000;
    const payload = "pancake-frame-view-baseline";

    const storage = try allocator.dupe(u8, payload);
    var frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();

    var checksum: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const view = frame.view();
        checksum +%= view.bytes.len;
        checksum +%= @intFromPtr(view.bytes.ptr) & 0xff;
    }

    std.debug.print(
        "frame_view iterations={d} bytes={d} checksum={d}\n",
        .{ iterations, frame.bytes().len, checksum },
    );

    reportModelLayout();
    try reportWirePathBudget(allocator);
}
