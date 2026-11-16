//! A partner's argument at the session's nesting ceiling reaches a hosted
//! mutation and its intent encodes. The intent is the list `[verb, dependent,
//! args...]`, but its envelope is not part of the value, so each argument is
//! counted from depth 0 as the session counted it. A failure means the
//! mutation refuses an argument the session admitted, after the partner's
//! call was accepted.

const std = @import("std");
const f = @import("sharing_fixture.zig");
const h = f.h;
const shapes = @import("../../support/depth_shapes.zig");

const Content = struct {
    invoked: usize = 0,
    fn requirement(_: ?*anyopaque, _: std.mem.Allocator, _: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        return .{ .permissions = &.{h.f.vocabulary.read} };
    }
    fn retry(_: ?*anyopaque, _: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
        return .receipt;
    }
    fn invoke(context: ?*anyopaque, _: *h.access.ContentCall, _: h.access.ContentInvocation) !h.driver.Value {
        const self: *Content = @ptrCast(@alignCast(context.?));
        self.invoked += 1;
        return .{ .integer = 41 };
    }
};

/// `depth` single-element lists around `innermost`, which sits at `depth`.
fn chain(arena: std.mem.Allocator, depth: usize, innermost: f.model.Argument) !f.model.Argument {
    var node = innermost;
    for (0..depth) |_| {
        const wrap = try arena.alloc(f.model.Argument, 1);
        wrap[0] = node;
        node = .{ .list = wrap };
    }
    return node;
}

test "a hosted mutation encodes a partner's argument at the ceiling, with a capability or without" {
    var arena = std.heap.ArenaAllocator.init(h.a);
    defer arena.deinit();
    const ceiling = f.model.max_value_depth;
    // The deepest the session admits: a leaf at the ceiling, an empty
    // container one level short, and a capability at the ceiling.
    const cases = [_]struct { depth: usize, capability: bool, empty: bool }{
        .{ .depth = ceiling, .capability = false, .empty = false },
        .{ .depth = ceiling - 1, .capability = false, .empty = true },
        .{ .depth = ceiling, .capability = true, .empty = false },
    };
    for (cases) |case| {
        var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seed(&store, &backend);
        var server: h.Hosted = undefined;
        try server.init(&store, &backend, data);
        defer server.deinit();
        var app: Content = .{};
        const contents = [_]h.access.ContentBehavior{.{ .schema = 7, .context = &app, .requirement = Content.requirement, .retry = Content.retry, .invoke = Content.invoke }};
        server.service.contents = &contents;
        var client: f.Client = undefined;
        try client.init(&server);
        defer client.deinit();
        const innermost: f.model.Argument = if (case.capability)
            .{ .reference = client.parent }
        else if (case.empty) .{ .list = &.{} } else .{ .void = {} };
        const args = [_]f.model.Argument{ .{ .integer = 1 }, .{ .string = "depth" }, try chain(arena.allocator(), case.depth, innermost) };
        var answer: h.Answer = .{};
        try client.send(client.parent, "mutate", &args, &answer);
        try server.drain(&backend);
        try client.pump();
        // The content ran, so the intent encoded and its capabilities were
        // captured before the call was committed.
        try std.testing.expectEqual(@as(usize, 1), app.invoked);
        try std.testing.expectEqual(@as(?i64, 41), answer.number);
        // The receipt keeps the intent for retry matching.
        const endpoint = try h.c.load(&store, &backend, data.use);
        defer store.release(endpoint) catch unreachable;
        const row = try h.loam.access.records.EndpointRecord.decode(try store.currentView(endpoint));
        try std.testing.expect((try row.mutations.lookup(1)) != null);
    }
}

test "forward work measures a value at the ceiling and refuses a container past it" {
    var arena = std.heap.ArenaAllocator.init(h.a);
    defer arena.deinit();
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        const args = try shapes.valueArgs(arena.allocator(), depth, shape);
        const measured = h.access.ForwardWork.measure("sel", .{ .verb = "poke", .args = args });
        if (shapes.admitted(shape, depth)) {
            try std.testing.expectEqual(@as(usize, 0), (try measured).material_bytes);
        } else {
            try std.testing.expectError(error.ValueTooDeep, measured);
        }
    };
}
