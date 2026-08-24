//! Engine Node action vocabulary and driver Host executor lockstep.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;

const tags = [_][]const u8{
    "dial",
    "cancel_dial",
    "flush",
    "settle",
    "fail",
    "retire_exporter",
    "need_gift_id",
    "release_capability",
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "pub const FailureDestination = node_actions.FailureDestination;",
        "pub const FailureReason = node_actions.FailureReason;",
        "pub const Action = node_actions.Action;",
        "pub const hasAction = node_actions.hasAction;",
        "pub const peekAction = node_actions.peekAction;",
        "pub const consumePeekedAction = node_actions.consumePeekedAction;",
        "pub const nextAction = node_actions.nextAction;",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node/actions.zig", &.{
        "pub const Action = union(enum)",
        "dial: struct {",
        "pending: redeem_dials.PendingId",
        "route_index: usize",
        "cancel_dial: struct {",
        "flush: PeerHandle",
        "dest: redeem.Destination",
        "route_id: model.CapabilityRouteId",
        "dest: FailureDestination",
        "reason: FailureReason",
        "retire_exporter: PeerHandle",
        "need_gift_id: struct { ticket: u64 }",
        "release_capability: u64",
        "pub fn claimTicketRange",
    });
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node/actions.zig", "action_locator"))
        try appendViolation(gpa, violations, "src/ocapn/engine/node/actions.zig: action_locator must stay deleted — pending row owns dial parts", .{});
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node/actions.zig", "dial: struct { pending: redeem_dials.PendingId, locator:"))
        try appendViolation(gpa, violations, "src/ocapn/engine/node/actions.zig: Action.dial must not carry locator — use pendingDial", .{});

    const action_src = root.readFileAlloc(
        io,
        "src/ocapn/engine/node/actions.zig",
        gpa,
        .limited(1 << 20),
    ) catch |err| {
        try appendViolation(gpa, violations, "src/ocapn/engine/node/actions.zig: failed to read for Node.Action parity with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(action_src);
    const pump_src = root.readFileAlloc(
        io,
        "src/driver/core/host/pump.zig",
        gpa,
        .limited(1 << 20),
    ) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host/pump.zig: failed to read for Node.Action parity with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pump_src);
    try compare(gpa, action_src, pump_src, violations);
}

fn compare(
    gpa: std.mem.Allocator,
    action_src: []const u8,
    pump_src: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const action_at = std.mem.indexOf(u8, action_src, "pub const Action = union(enum)") orelse {
        try appendViolation(gpa, violations, "src/ocapn/engine/node/actions.zig: Node.Action union missing", .{});
        return;
    };
    const action_body = action_src[action_at..];
    const action_end = std.mem.indexOf(u8, action_body, "\n};") orelse action_body.len;
    var actual_count: usize = 0;
    var action_lines = std.mem.splitScalar(u8, action_body[0..action_end], '\n');
    while (action_lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    ") or
            std.mem.startsWith(u8, line, "        ") or
            std.mem.startsWith(u8, line, "    ///")) continue;
        if (std.mem.indexOfScalar(u8, line, ':') != null) actual_count += 1;
    }
    if (actual_count != tags.len)
        try appendViolation(gpa, violations, "src/ocapn/engine/node/actions.zig: Node.Action has {d} tags; exact supported inventory has {d}", .{ actual_count, tags.len });
    const exec_at = std.mem.indexOf(u8, pump_src, "fn execNodeAction") orelse {
        try appendViolation(gpa, violations, "src/driver/core/host/pump.zig: execNodeAction missing", .{});
        return;
    };
    const exec_body = pump_src[exec_at..];
    const exec_end = std.mem.indexOf(u8, exec_body, "\n}") orelse exec_body.len;
    for (tags) |tag| {
        var declaration_buf: [64]u8 = undefined;
        const declaration = std.fmt.bufPrint(&declaration_buf, "\n    {s}:", .{tag}) catch unreachable;
        var arm_buf: [64]u8 = undefined;
        const arm = std.fmt.bufPrint(&arm_buf, ".{s} =>", .{tag}) catch unreachable;
        if (std.mem.indexOf(u8, action_body[0..action_end], declaration) == null)
            try appendViolation(gpa, violations, "src/ocapn/engine/node/actions.zig: Node.Action missing tag `{s}`", .{tag});
        if (std.mem.indexOf(u8, exec_body[0..exec_end], arm) == null)
            try appendViolation(gpa, violations, "src/driver/core/host/pump.zig: execNodeAction missing arm for Node.Action.{s}", .{tag});
    }
}

test "missing Node action executor arm is rejected" {
    const action_src =
        \\pub const Action = union(enum) {
        \\    dial: void,
        \\    cancel_dial: void,
        \\    flush: void,
        \\    settle: void,
        \\    fail: void,
        \\    retire_exporter: void,
        \\    need_gift_id: void,
        \\    release_capability: void,
        \\};
    ;
    const pump_src =
        \\fn execNodeAction() void {
        \\    .dial => {}; .cancel_dial => {}; .flush => {}; .settle => {}; .fail => {};
        \\    .retire_exporter => {}; .need_gift_id => {};
        \\}
    ;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |violation| std.testing.allocator.free(violation);
        violations.deinit(std.testing.allocator);
    }
    try compare(std.testing.allocator, action_src, pump_src, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "release_capability") != null);
}

test "extra Node action tag is rejected" {
    const action_src =
        \\pub const Action = union(enum) {
        \\    dial: void,
        \\    cancel_dial: void,
        \\    flush: void,
        \\    settle: void,
        \\    fail: void,
        \\    retire_exporter: void,
        \\    need_gift_id: void,
        \\    release_capability: void,
        \\    hidden: void,
        \\};
    ;
    const pump_src =
        \\fn execNodeAction() void {
        \\    .dial => {}; .cancel_dial => {}; .flush => {}; .settle => {}; .fail => {};
        \\    .retire_exporter => {}; .need_gift_id => {};
        \\    .release_capability => {};
        \\}
    ;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |violation| std.testing.allocator.free(violation);
        violations.deinit(std.testing.allocator);
    }
    try compare(std.testing.allocator, action_src, pump_src, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "exact supported inventory") != null);
}
