//! Run `zig build bench-uri -Doptimize=ReleaseFast` to measure URI rendering.
//! Each case reports time separately from allocation traffic. The instrumented
//! pass refuses in-place growth so allocator luck cannot hide output copies.
const std = @import("std");
const model = @import("glowcap").ocapn.model;

const Operation = enum { peer, baseline_sturdyref, next_sturdyref };
const turns = 4096;

fn render(allocator: std.mem.Allocator, operation: Operation, locator: model.PeerLocator) ![]u8 {
    return switch (operation) {
        .peer => model.uri.writePeer(allocator, locator),
        .baseline_sturdyref => model.uri.writeSturdyref(allocator, .{ .peer = locator, .swissnum = "a durable name / with escapes" }),
        .next_sturdyref => model.uri.writeSturdyrefForProfile(allocator, .next, .{ .peer = locator, .swissnum = "a durable name / with escapes" }),
    };
}

fn measure(io: std.Io, operation: Operation, locator: model.PeerLocator) !void {
    const allocator = std.heap.smp_allocator;
    var checksum: usize = 0;
    const start = std.Io.Clock.awake.now(io);
    for (0..turns) |_| {
        const bytes = try render(allocator, operation, locator);
        checksum +%= bytes.len;
        std.mem.doNotOptimizeAway(bytes);
        allocator.free(bytes);
    }
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start.nanoseconds;
    var traffic = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    for (0..turns) |_| {
        const bytes = try render(traffic.allocator(), operation, locator);
        traffic.allocator().free(bytes);
    }
    std.debug.print("uri operation={s} designator_bytes={d} ns_per_turn={d} allocations_per_turn={d} requested_bytes_per_turn={d} checksum={d}\n", .{
        @tagName(operation),         locator.designator.len,          @divTrunc(elapsed, turns),
        traffic.alloc_index / turns, traffic.allocated_bytes / turns, checksum,
    });
}

pub fn main(init: std.process.Init) !void {
    const hints = [_]model.HintEntry{.{ .name = "direct-addresses", .value = .{ .string = "127.0.0.1:7443" } }};
    const key: [64]u8 = @splat('a');
    const ordinary: model.PeerLocator = .{ .transport = "noise-tcp", .designator = &key, .hints = .{ .entries = &hints } };
    var escaped: [1024]u8 = @splat(0xff);
    const large: model.PeerLocator = .{ .transport = "onion", .designator = &escaped };
    for ([_]Operation{ .peer, .baseline_sturdyref, .next_sturdyref }) |operation| {
        try measure(init.io, operation, ordinary);
        try measure(init.io, operation, large);
    }
}
