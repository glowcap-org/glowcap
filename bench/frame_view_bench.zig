const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const CountingAllocator = @import("alloc_metrics").CountingAllocator;
const driveOneTurn = @import("warm_turn").driveOneTurn;

/// Steady-state heap traffic for one inbound `op:deliver` to a live local export.
/// Mirrors `test/engine/alloc_budget_test.zig`.
fn reportWirePathBudget(backing: std.mem.Allocator) !void {
    var counter = CountingAllocator{ .backing = backing };
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
