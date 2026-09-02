const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;

/// Counts fresh `alloc` and growing `remap` traffic for the wire-path budget.
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

// No-answer (`#f` answer position) deliver: re-applied to one peer across the
// measured turns, so a live-answer position would be refused on the second apply.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// Steady-state heap traffic for one inbound `op:deliver` to a live local export.
/// Mirrors `test/engine/alloc_budget_test.zig`.
fn reportWirePathBudget(backing: std.mem.Allocator) !void {
    var counter = TotalCountingAllocator{ .backing = backing };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.exportObject(7);

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

/// In-memory size of codec-neutral value-tree types. The rare `handoff` arm is
/// boxed (`*Handoff`) so common args pay the `Reference` arm size, not ~160 B.
/// The borrowed `view.*` twins print beside them: the borrowed shape keeps its
/// handoff inline (it borrows wire bytes and may not allocate a box), so it is
/// the wide one, and the inbound set-uniqueness fold parks arrays of it.
fn reportModelLayout() void {
    std.debug.print(
        "model_layout Argument={d} Message={d} Reference={d} Resolution={d} view.Argument={d} view.Reference={d} view.Handoff={d}\n",
        .{
            @sizeOf(model.Argument),
            @sizeOf(model.Message),
            @sizeOf(model.Reference),
            @sizeOf(model.Resolution),
            @sizeOf(model.view.Argument),
            @sizeOf(model.view.Reference),
            @sizeOf(model.view.Handoff),
        },
    );
}

fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const iterations: usize = 1_000_000;
    const payload = "glowcap-frame-view-baseline";

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
