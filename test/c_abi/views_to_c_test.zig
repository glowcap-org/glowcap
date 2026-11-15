//! The views walk of `viewsToC`, with no Host: it projects a wire frame's
//! borrowed views onto the C argument layout, one array per container, and
//! refuses a reference, a view that does not project, nesting past
//! `model.max_value_depth`, and an allocation the arena refuses. The tests that
//! need a Host, a session, or a delivery are in `host/capability_free_deliver_test.zig`.

const std = @import("std");
const shared = @import("c_abi_shared");
const glowcap = @import("glowcap");
const FailingOnce = @import("../support/failing_once.zig").FailingOnce;
const fixtures = @import("../support/view_fixtures.zig");

const model = glowcap.ocapn.model;
const Nested = fixtures.Nested;
const Lying = fixtures.Lying;

test "the views projection admits the deepest level and refuses one past it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at_limit = try Nested.build(arena, model.max_value_depth, .{ .void = {} });
    _ = try shared.viewsToC(arena, at_limit.args());
    const past_limit = try Nested.build(arena, model.max_value_depth + 1, .{ .void = {} });
    try std.testing.expectError(error.NestingTooDeep, shared.viewsToC(arena, past_limit.args()));
}

test "a view whose count and cursor disagree or whose cursor fails refuses with MalformedView" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ([_]model.view.Args.Ctx{ Lying.shorter, Lying.longer, Lying.failing }) |ctx| {
        const args = model.view.Args.fromBacking(ctx, &Lying.table);
        try std.testing.expectError(error.MalformedView, shared.viewsToC(arena_state.allocator(), args));
    }
}

test "the views projection refuses a reference with UnsupportedValue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inner = [_]model.Argument{.{ .reference = .{ .near = model.NearRef.object(9) } }};
    const args = [_]model.Argument{.{ .list = &inner }};
    try std.testing.expectError(error.UnsupportedValue, shared.viewsToC(arena, .fromOwnedSlice(&args)));
}

test "the views projection returns OutOfMemory at every allocation index and succeeds past the last" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nested = try Nested.build(arena, 3, .{ .void = {} });
    const items = [_]model.Argument{
        .{ .list = &nested.backing[0] },
        .{ .tagged = .{ .tag = "t", .value = &nested.backing[1] } },
        .{ .@"struct" = &.{.{ .key = "k", .value = .{ .list = &nested.backing[2] } }} },
        .{ .set = &nested.backing[3] },
    };
    var total: ?usize = null;
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        var failing = FailingOnce.init(scratch.allocator(), index);
        if (shared.viewsToC(failing.allocator(), .fromOwnedSlice(&items))) |_| {
            try std.testing.expect(!failing.induced);
            total = index;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.induced);
        }
    }
    // The walk allocates one array per container, so the sweep ends only past several indices.
    try std.testing.expect(total != null and total.? >= 4);
}
