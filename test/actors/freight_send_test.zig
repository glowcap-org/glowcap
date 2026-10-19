//! A Port sends a delivery lent as views to a far target as freight
//! (ADR-0064): the verb rides the same stack spine as an owned send, the
//! wire frame is the only allocation, and a sequence whose walk and length
//! disagree is refused before anything reaches the peer.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const view = model.view;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

fn drain(peer: *engine.Peer) !void {
    while (true) {
        _ = try peer.step();
        var frame = peer.takeOutbound() orelse break;
        frame.deinit();
    }
}

test "a far freight send allocates its frame and nothing else" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var pair = try engine.pairing.paired(counter.allocator());
    defer pair.deinit();
    try pair.p1.importObject(5);

    var vat = actors.Vat.init(counter.allocator());
    defer vat.deinit();
    var port = actors.Port.init(counter.allocator(), &pair.p1);
    defer port.deinit(&vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    // Seven views, the widest arity the stack spine carries with a verb.
    const views = [7]view.Argument{
        .{ .bytes = "payload" }, .{ .integer = 1 }, .{ .integer = 2 },
        .{ .integer = 3 },       .{ .integer = 4 }, .{ .integer = 5 },
        .{ .integer = 6 },
    };
    const delivery: actors.Delivery = .{ .verb = "poke", .args = .fromViews(&views), .reference_slots = 0 };

    // Warm the queue's steady backing and the encode buffers, as the owned
    // budget does (`vat_alloc_budget_test.zig`).
    try port.tellDelivery(&vat, remote, delivery);
    try drain(&pair.p1);

    const sends = 4;
    var send_allocs: usize = 0;
    for (0..sends) |_| {
        counter.allocs = 0;
        try port.tellDelivery(&vat, remote, delivery);
        send_allocs += counter.allocs;
        try drain(&pair.p1);
    }
    try std.testing.expectEqual(@as(usize, 1 * sends), send_allocs);
}

/// A backing whose `len` promises three elements and whose walk yields one.
const Lying = struct {
    const vtable: view.Args.VTable = .{ .len = len, .at = at, .next = next, .tail = tail };
    fn len(_: view.Args.Ctx) view.ProjectError!usize {
        return 3;
    }
    fn at(_: view.Args.Ctx, _: usize) view.ProjectError!view.Argument {
        return error.MalformedView;
    }
    fn next(_: view.Args.Ctx, cursor: *u64, out: *view.Argument) view.ProjectError!bool {
        if (cursor.* != 0) return false;
        cursor.* = 1;
        out.* = .{ .integer = 1 };
        return true;
    }
    fn tail(_: view.Args.Ctx, _: usize) view.ProjectError!view.Args.Ctx {
        return error.MalformedView;
    }
};

test "a freight sequence whose walk and length disagree is refused" {
    var pair = try engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    try pair.p1.importObject(5);
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var port = actors.Port.init(std.testing.allocator, &pair.p1);
    defer port.deinit(&vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };
    const delivery: actors.Delivery = .{ .verb = "poke", .args = .fromBacking(.{}, &Lying.vtable), .reference_slots = 0 };
    try std.testing.expectError(actors.Error.MalformedView, port.tellDelivery(&vat, remote, delivery));
    try std.testing.expect(pair.p1.pending_send.isEmpty());
}
