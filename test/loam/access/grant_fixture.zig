//! Shared local resource and policy vocabulary for grant model tests.
const std = @import("std");
pub const core = @import("glowcap").loam.access.core;
pub const read: core.Policy.Key = @fromBackingInt(10);
pub const post: core.Policy.Key = @fromBackingInt(20);
pub const history: core.Policy.Key = @fromBackingInt(100);
pub const descriptor: core.Policy.Descriptor = .{
    .id = @fromBackingInt(11),
    .permissions = &.{ read, post },
    .constraints = &.{.{ .key = history, .operator = .lower_bound }},
};
pub const structural_policy = core.Policy.init(.{ .id = @fromBackingInt(0), .permissions = &.{} }) catch unreachable;
pub const kind: core.KindId = @fromBackingInt(1);

pub fn graphInit(allocator: std.mem.Allocator) !core.Graph {
    return core.Graph.init(allocator, @fromBackingInt(1), .{ .capacity = 16 });
}

pub fn terms(scope: core.Scope, permissions: []const core.Policy.Key, after: ?u64) !core.Terms {
    const policy = try core.Policy.init(descriptor);
    const bounds: []const core.Policy.Bound = if (after) |value| &.{.{ .key = history, .value = value }} else &.{};
    return .{ .scope = scope, .policy = try policy.value(permissions, bounds) };
}

pub fn issue(terms_: core.Terms, depth: u16) core.GrantLedger.Issue {
    return .{ .ceiling = terms_, .configured = terms_, .delegation_depth = depth };
}

/// These tests own a fake storage boundary with no outstanding I/O. Retire
/// pending writes on assertion failure so cleanup cannot hide the first error.
pub fn deinitLedger(ledger: *core.GrantLedger) void {
    if (ledger.pending) |pending| switch (pending.phase) {
        .prepared => ledger.cancel(pending.ticket) catch unreachable,
        .writing => _ = ledger.finishWrite(pending.ticket, .unchanged) catch unreachable,
        .uncertain => _ = ledger.resolveWrite(pending.ticket, .unchanged) catch unreachable,
    };
    ledger.deinit() catch unreachable;
}
