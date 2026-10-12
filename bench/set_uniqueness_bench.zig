//! Run `zig build bench-set-uniqueness -Doptimize=ReleaseFast` to measure
//! borrowed set validation. Frame construction stays outside the measured
//! window. The collision case uses distinct nested values with equal hashes.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const session = glowcap.ocapn.session;

fn measure(io: std.Io, encoding: model.CodecId, name: []const u8, elements: []const model.Argument) !void {
    const allocator = std.heap.smp_allocator;
    var frame = try codec.dispatch.encodeMessageForProfile(encoding, allocator, .v1_0, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .set = elements }},
        .answer = null,
    } });
    defer frame.deinit();
    const body = try codec.dispatch.decodeBodyForProfile(encoding, .v1_0, frame.view());
    var traffic = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    var state = session.Session.init(traffic.allocator());
    defer state.deinit();
    try state.registerExport(.from(7));
    const cold_bytes = traffic.allocated_bytes;
    const cold_allocations = traffic.alloc_index;
    try state.recordRecvView(body);
    const requested = traffic.allocated_bytes - cold_bytes;
    const allocations = traffic.alloc_index - cold_allocations;
    const turns = 64;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..turns) |_| try state.recordRecvView(body);
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    std.debug.print("set_uniqueness codec={s} case={s} members={d} frame_bytes={d} ns_per_turn={d} cold_allocations={d} cold_requested_bytes={d}\n", .{
        @tagName(encoding), name, elements.len, frame.bytes().len, @divTrunc(elapsed, turns), allocations, requested,
    });
}

pub fn main(init: std.process.Init) !void {
    var distinct: [8192]model.Argument = undefined;
    for (&distinct, 0..) |*element, index| element.* = .{ .integer = @intCast(index) };
    // Hashing a sturdyref combines transport/designator bytes. Distinct splits
    // of the same bytes collide, but real equality keeps their identities apart.
    const identity: [9]u8 = @splat('a');
    var nested: [8][65]model.Argument = undefined;
    var collisions: [8]model.Argument = undefined;
    var references: [8]model.SturdyRef = undefined;
    for (&nested, &collisions, 0..) |*values, *element, index| {
        for (values[0..64], 0..) |*value, i| value.* = .{ .integer = @intCast(i) };
        references[index] = .{
            .peer = .{ .transport = identity[0 .. index + 1], .designator = identity[index + 1 ..] },
            .swissnum = "name",
        };
        values[64] = .{ .reference = .{ .sturdy = &references[index] } };
        element.* = .{ .list = values };
    }
    for ([_]model.CodecId{ .syrup, .capnp }) |encoding| {
        try measure(init.io, encoding, "distinct", &distinct);
        try measure(init.io, encoding, "nested_collisions", &collisions);
    }
}
