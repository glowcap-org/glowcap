//! The nesting ceiling on every session entry path: one test per path, each
//! swept across `model.max_value_depth` at one below, at, and one past, over
//! every shape the path can carry. The authority is the session's count: a
//! container's items sit one level deeper than it, an empty container
//! included, so a leaf may sit at the ceiling and an empty container may not.
//! A failure means a path counts depth another way than the session does.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../support/depth_shapes.zig");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const view = model.view;
const NoMeter = session.inventory.NoMeter;
const allocator = std.testing.allocator;

fn expectOutcome(shape: shapes.Shape, depth: usize, result: anytype) !void {
    if (shapes.admitted(shape, depth)) {
        try result;
    } else {
        try std.testing.expectError(session.Error.NestingTooDeep, result);
    }
}

/// An admitted send retains the export it names. A refused one retains nothing,
/// even though the shallow reference sits before the subtree that refuses it.
fn expectRetain(shape: shapes.Shape, depth: usize, before: anytype, after: anytype) !void {
    const retained = if (shapes.admitted(shape, depth)) before + 1 else before;
    try std.testing.expectEqual(retained, after);
}

fn inboundSession() !session.Session {
    var s = session.Session.init(allocator);
    errdefer s.deinit();
    try s.registerExport(.from(7));
    return s;
}

test "inbound deliver admits a leaf at the ceiling and an empty container one level short" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var s = try inboundSession();
        defer s.deinit();
        const args = try shapes.ownedArgs(arena.allocator(), depth, shape);
        try expectOutcome(shape, depth, s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = .from(7) } },
            .args = args,
            .answer = null,
        } }));
    };
}

test "inbound deliver of borrowed views counts the same, an integer run included" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var s = try inboundSession();
        defer s.deinit();
        const target = model.Reference{ .near = .{ .export_position = .from(7) } };
        const body: view.Body = .{ .deliver = .{
            .target = view.Reference.fromOwned(&target),
            .args = try shapes.viewArgs(arena.allocator(), depth, shape),
        } };
        try expectOutcome(shape, depth, s.recordRecvView(body));
    };
}

test "inbound fulfill counts as a deliver's arguments do" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var s = session.Session.initWith(allocator, .{ .captp_version = model.CaptpVersion.next });
        defer s.deinit();
        try s.registerImport(.from(7));
        try s.recordSend(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{},
            .answer = .from(11),
        } });
        const args = try shapes.viewArgs(arena.allocator(), depth, shape);
        const body: view.Body = .{ .resolve = .{
            .answer = .from(11),
            .resolution = .{ .fulfill = try args.at(0) },
        } };
        try expectOutcome(shape, depth, s.recordRecvView(body));
    };
}

test "send-side deliver refuses at the same depth, before any export retain" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerImport(.from(2));
        try s.registerExport(.from(1));
        const before = s.exportRefcount(.from(1));
        const nested = try shapes.ownedArgs(arena.allocator(), depth, shape);
        const args = try arena.allocator().alloc(model.Argument, 2);
        args[0] = .{ .reference = .{ .near = .{ .export_position = .from(1) } } };
        args[1] = nested[0];
        const result = s.recordSend(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(2) }, .args = args, .answer = null } });
        try expectOutcome(shape, depth, result);
        try expectRetain(shape, depth, before, s.exportRefcount(.from(1)));
    };
}

test "send-side fulfill refuses at the same depth, before any export retain" {
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var s = session.Session.init(allocator);
        defer s.deinit();
        try s.registerExport(.from(1));
        // The payload names a second export, so the question's own target
        // release does not mix into the count.
        try s.registerExport(.from(2));
        try s.recordRecv(.{ .deliver = .{
            .target = .{ .near = .{ .export_position = .from(1) } },
            .args = &.{},
            .answer = .from(11),
        } });
        try s.installInboundResolver(.fromWire(.from(11)), .from(3));
        // A V1 resolver callback makes the resolution a wire mention, which
        // retains each local export it names.
        try std.testing.expect(s.resolverForInboundAnswer(.fromWire(.from(11))) != null);
        const before = s.exportRefcount(.from(2));
        // `recordSend` consumes a resolution: it moves into the store on
        // success and is freed on refusal, so every slice is the allocator's.
        // The payload is a list holding a real export before the subtree, so
        // its innermost node sits `depth` levels down, as in the deliver.
        const items = try allocator.alloc(model.Argument, 2);
        items[0] = .{ .reference = .{ .near = .{ .export_position = .from(2) } } };
        items[1] = shapes.ownedHeap(allocator, depth - 1, shape) catch |err| {
            allocator.free(items);
            return err;
        };
        const result = s.recordSend(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .list = items } } } });
        try expectOutcome(shape, depth, result);
        try expectRetain(shape, depth, before, s.exportRefcount(.from(2)));
    };
}

test "a send inventory and freight certification agree with the owned measure at every depth" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var s = session.Session.init(allocator);
        defer s.deinit();
        const args = try shapes.ownedArgs(arena.allocator(), depth, shape);
        if (shapes.admitted(shape, depth)) {
            const inventory = try s.inventoryArguments(args, NoMeter);
            inventory.deinit(allocator);
            const freight = try s.certifyFreight(view.Args.fromOwnedSlice(args), NoMeter);
            try std.testing.expectEqual(try model.measureArgumentSliceOwnedBytes(args), freight.owned_bytes);
        } else {
            try std.testing.expectError(session.Error.NestingTooDeep, s.inventoryArguments(args, NoMeter));
            try std.testing.expectError(session.Error.NestingTooDeep, s.certifyFreight(view.Args.fromOwnedSlice(args), NoMeter));
            try std.testing.expectError(error.MalformedView, model.measureArgumentSliceOwnedBytes(args));
        }
    };
}

test "freight of a borrowed integer run refuses where the run's items would sit past the ceiling" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]shapes.Shape{ .empty_run, .run }) |shape| for (shapes.sweep) |depth| {
        var s = session.Session.init(allocator);
        defer s.deinit();
        const args = try shapes.viewArgs(arena.allocator(), depth, shape);
        const result = s.certifyFreight(args, NoMeter);
        if (shapes.admitted(shape, depth)) _ = try result else try std.testing.expectError(session.Error.NestingTooDeep, result);
    };
}
