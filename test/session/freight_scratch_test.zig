//! Outbound freight set certification owns its spill scratch, including on
//! duplicate refusal and allocation failure. The session allocator has no
//! receive-turn reset to reclaim it.
const std = @import("std");
const g = @import("glowcap");
const view = g.ocapn.model.view;
const Session = g.ocapn.session.Session;

test "freight set certification releases spilled rows on success" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = Session.init(failing.allocator());
    defer session.deinit();
    var members: [9]view.Argument = undefined;
    for (&members, 0..) |*member, i| member.* = .{ .integer = @intCast(i) };
    const args = [_]view.Argument{.{ .set = .fromViews(&members) }};
    _ = try session.certifyFreight(.fromViews(&args));
    try std.testing.expect(failing.allocated_bytes > 0);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "freight set certification releases rows and collision views on refusal and allocation failure" {
    const members: [9]view.Argument = @splat(.{ .integer = 1 });
    const args = [_]view.Argument{.{ .set = .fromViews(&members) }};
    // One row spill, then one collision-view spill. Fail each allocation,
    // then reach the duplicate refusal with both allocations live.
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var session = Session.init(failing.allocator());
        defer session.deinit();
        const result = session.certifyFreight(.fromViews(&args));
        if (fail_index < 2) {
            try std.testing.expectError(error.OutOfMemory, result);
        } else {
            try std.testing.expectError(error.DuplicateSetElement, result);
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
