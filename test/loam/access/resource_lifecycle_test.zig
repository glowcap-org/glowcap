//! Resource structure, authority and index effects use one persistent model.
const std = @import("std");
const r = @import("resource_fixture.zig");
const f = r.f;

test "loam resource lifecycle scans and iterates composed descendant rows" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").composedTraversal(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle refuses independently prepared stale changes in one batch" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").independentPreparations(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle cursor preserves exact read custody after a stale completion" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").cursorCustody(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle indexes bounded children and preserves scope across moves and deletion" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").structure(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle child iteration filters hidden siblings and refuses stale continuation" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").visibility(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle refuses descendant depth overflow and rolls back all participant indexes" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").rollback(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle rechecks queued and cold calls after movement out of scope" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").queued(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle retires cancelled index reads and partial move allocations" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    const seed = try r.seed(&fixture.store, &fixture.backend);
    var server: r.h.Hosted = undefined;
    try server.init(&fixture.store, &fixture.backend, seed.data);
    defer server.deinit();
    var succeeded = false;
    for (0..64) |index| {
        var failing = std.testing.FailingAllocator.init(r.a, .{ .fail_index = index });
        server.caps.allocator = failing.allocator();
        defer server.caps.allocator = r.a;
        var answer: r.h.Answer = .{};
        try server.mutate(server.use, 1, "move-resource", &.{.{ .integer = -1 }}, &answer);
        try server.drain(&fixture.backend);
        try std.testing.expectEqual(@as(usize, 0), server.caps.operations);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        // This move leaves the grant's scope only after its own committed act.
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(@as(?bool, true), answer.changed);
            succeeded = true;
            break;
        }
        try std.testing.expect(answer.broken);
    }
    try std.testing.expect(succeeded);
    var read = try r.storage.Read.init(r.a, &fixture.store, seed.data.owner, 6);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    var change = try r.prepare(&read, &fixture.backend, seed.leaf, .{ .move = seed.root });
    defer change.deinit() catch unreachable;
    try std.testing.expectError(error.Busy, read.deinit());
    try std.testing.expectError(error.Busy, read.forgetResources());
    try std.testing.expectError(error.Busy, r.storage.Append.init(&read, .resource));
    fixture.store.evict();
    const pending = (try change.advance()).read;
    try std.testing.expectError(error.Busy, change.deinit());
    try change.cancel();
    try std.testing.expectError(error.Canceled, change.completeRead(pending.ticket, fixture.backend.read(pending)));
    try std.testing.expectError(error.Cancelled, change.advance());
    try std.testing.expectError(error.StaleCompletion, change.completeRead(pending.ticket, .missing));
}

test "loam resource lifecycle refuses a second prepared effect on one native operation" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    const seed = try r.seed(&fixture.store, &fixture.backend);
    var caps = try r.storage.Capabilities.init(r.a, &fixture.store, .{});
    defer caps.deinit() catch unreachable;
    const id = try r.h.c.descriptor(&caps, &fixture.backend, seed.data.owner, seed.data.grant, null, false);
    const use = try r.h.c.use(&caps, &fixture.backend, id);
    defer use.release();
    const operation = try use.begin(8);
    defer operation.deinit() catch unreachable;
    try r.h.c.require(operation, &fixture.backend, seed.leaf, .{ .permissions = &.{f.vocabulary.read} });
    try r.h.c.require(operation, &fixture.backend, seed.root, .{ .permissions = &.{f.vocabulary.read} });
    try std.testing.expect(!try operation.prepareResourceCopying(seed.leaf, .{ .move = seed.root }, .{ .permissions = &.{f.vocabulary.read} }));
    const terms = try f.vocabulary.terms(.{ .object = seed.leaf }, &.{f.vocabulary.read}, null);
    const request = f.vocabulary.issue(terms, 0);
    try std.testing.expectError(error.WrongPhase, operation.prepareDeriveCopying(request));
    try std.testing.expectError(error.WrongPhase, operation.prepareManagedDeriveCopying(request, .{ .pause = true }));
    try std.testing.expectError(error.WrongPhase, operation.prepareResourceCopying(seed.leaf, .delete_leaf, .{ .permissions = &.{f.vocabulary.read} }));

    const deriving = try use.begin(8);
    defer deriving.deinit() catch unreachable;
    try r.h.c.require(deriving, &fixture.backend, seed.leaf, .{ .permissions = &.{f.vocabulary.read} });
    try r.h.c.require(deriving, &fixture.backend, seed.root, .{ .permissions = &.{f.vocabulary.read} });
    try r.h.c.derive(deriving, &fixture.backend, request);
    try std.testing.expectError(error.WrongPhase, deriving.prepareResourceCopying(seed.leaf, .delete_leaf, .{ .permissions = &.{f.vocabulary.read} }));
}

test "loam resource lifecycle cursor cancellation joins the exact authority read" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    try @import("resource_cases.zig").cursorCancellation(&fixture.store, &fixture.backend);
}

test "loam resource lifecycle iteration and prepared changes have exclusive lease custody" {
    var fixture = try f.Fixture.init(r.a, r.h.limits);
    defer fixture.deinit();
    const seed = try r.seed(&fixture.store, &fixture.backend);
    var caps = try r.storage.Capabilities.init(r.a, &fixture.store, .{});
    defer caps.deinit() catch unreachable;
    const id = try r.h.c.descriptor(&caps, &fixture.backend, seed.data.owner, seed.data.grant, null, false);
    const use = try r.h.c.use(&caps, &fixture.backend, id);
    defer use.release();
    const operation = try use.begin(8);
    defer operation.deinit() catch unreachable;
    const requirement: r.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };
    try r.h.c.require(operation, &fixture.backend, seed.root, requirement);
    const terms = try f.vocabulary.terms(.{ .object = seed.root }, requirement.permissions, null);
    const request = f.vocabulary.issue(terms, 0);
    {
        const query = try operation.children(seed.root, requirement);
        defer query.deinit() catch unreachable;
        try std.testing.expectError(error.Busy, operation.children(seed.root, requirement));
        try std.testing.expectError(error.Busy, operation.prepareResourceCopying(seed.root, .{ .move = null }, requirement));
        try std.testing.expectError(error.Busy, operation.prepareDeriveCopying(request));
        try std.testing.expectError(error.Busy, operation.prepareManagedDeriveCopying(request, .{ .pause = true }));
    }
    try std.testing.expect(!try operation.prepareResourceCopying(seed.root, .{ .move = null }, requirement));
    try std.testing.expectError(error.WrongPhase, operation.children(seed.root, requirement));
}
