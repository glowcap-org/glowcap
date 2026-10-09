//! Non-chat storage scenarios for independent administration and sparse pages.
const std = @import("std");
const m = @import("management_fixture.zig");
const c = m.c;
const f = m.f;

pub fn run(store: *m.h.loam.core.Store, backend: anytype) !void {
    var caps = try c.storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(193));
    const resource = try f.resource(store, backend, owner, null);
    const wide = try f.vocabulary.terms(.{ .object = resource }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const selected = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const narrow = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const root = (try f.change(store, backend, owner, .{ .issue_root = .{ .ceiling = wide, .configured = narrow } })).?.grant;
    const powers: c.core.Control.Powers = .{ .inspect = true, .issue_ceiling = wide, .policy_ceiling = wide, .pause = true, .resume_access = true };
    const control = try c.control(&caps, backend, try c.descriptor(&caps, backend, owner, root, powers, true));
    defer control.release();
    _ = try f.change(store, backend, owner, .{ .pause = root });
    var child_id: m.h.loam.core.ObjectId = undefined;
    var first_child: ?c.core.GrantId = null;
    for (0..35) |index| {
        const operation = try control.begin(8);
        defer operation.deinit() catch unreachable;
        _ = try f.pump(operation, backend);
        const revision = (try operation.describeControl()).revision;
        var request = f.vocabulary.issue(if (index % 2 == 0) selected else wide, 0);
        request.label = try c.core.GrantLedger.Label.init("terminal viewer");
        for (0..128) |_| {
            operation.prepareIssueCopying(request, .{}, revision) catch |err| {
                if (err != error.RecordUnloaded) return err;
                _ = try f.pump(operation, backend);
                continue;
            };
            break;
        } else return error.NoProgress;
        _ = try f.pump(operation, backend);
        try store.begin();
        const result = try caps.stage(operation, true);
        try f.commit(store, backend);
        if (index == 0) {
            child_id = result.derived_use.?;
            first_child = result.change.grant;
        }
    }
    const use = try c.use(&caps, backend, child_id);
    defer use.release();
    {
        const operation = try use.begin(8);
        defer operation.deinit() catch unreachable;
        try std.testing.expectError(error.Paused, c.require(operation, backend, resource, .{ .permissions = &.{f.vocabulary.read} }));
    }
    _ = try f.change(store, backend, owner, .{ .resume_access = root });
    {
        const operation = try use.begin(8);
        defer operation.deinit() catch unreachable;
        try c.require(operation, backend, resource, .{ .permissions = &.{f.vocabulary.read} });
        try std.testing.expectError(error.Denied, operation.require(resource, .{ .permissions = &.{f.vocabulary.post} }));
    }
    store.evict();
    {
        const operation = try control.begin(8);
        defer operation.deinit() catch unreachable;
        _ = try f.pump(operation, backend);
        const revision = (try operation.describeControl()).revision;
        try std.testing.expectError(error.RevisionConflict, operation.expectRevision(@fromBackingInt(@backingInt(revision) - 1)));
        try std.testing.expectError(error.Denied, operation.prepareAttenuationCopying(.{}));
        try std.testing.expectError(error.Denied, operation.prepareIssueCopying(f.vocabulary.issue(wide, 0), .{ .inspect = true }, revision));
        for (0..128) |_| {
            operation.expectRevision(revision) catch |err| {
                if (err != error.RecordUnloaded) return err;
                _ = try f.pump(operation, backend);
                continue;
            };
            const changed = operation.prepareEditCopying(.{ .set_label = try c.core.GrantLedger.Label.init("inventory owner") }) catch |err| {
                if (err != error.RecordUnloaded) return err;
                _ = try f.pump(operation, backend);
                continue;
            };
            try std.testing.expect(changed);
            break;
        } else return error.NoProgress;
        _ = try f.pump(operation, backend);
        try store.begin();
        _ = try caps.stage(operation, false);
        try f.commit(store, backend);
    }
    store.evict();
    try page(control, backend, 0, 32, first_child.?.slot);
    try page(control, backend, @as(u64, first_child.?.slot) + 32, 3, first_child.?.slot + 32);
    const inspectors = [_]c.core.Control.Powers{ .{ .inspect = true }, .{ .issue_ceiling = wide }, .{ .policy_ceiling = wide } };
    for (inspectors, 0..) |permission, index| {
        const ref = try c.control(&caps, backend, try c.descriptor(&caps, backend, owner, root, permission, true));
        defer ref.release();
        const operation = try ref.begin(8);
        defer operation.deinit() catch unreachable;
        _ = try f.pump(operation, backend);
        if (index == 0) {
            _ = try operation.inspectGrant(null);
            try std.testing.expectError(error.Denied, operation.prepareEditCopying(.{ .set_policy = narrow }));
            const revision = (try operation.describeControl()).revision;
            try std.testing.expectError(error.Denied, operation.prepareIssueCopying(f.vocabulary.issue(wide, 0), .{}, revision));
        } else try std.testing.expectError(error.Denied, operation.inspectGrant(null));
    }
    try std.testing.expectError(error.InvalidLabel, c.core.GrantLedger.Label.init(&@as([121]u8, @splat('a'))));
    try std.testing.expectError(error.InvalidLabel, c.core.GrantLedger.Label.init(&.{0xff}));
}

fn page(control: *c.storage.Control, backend: anytype, floor: u64, count: usize, first: u32) !void {
    const operation = try control.begin(8);
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, backend);
    var cursor = try c.storage.GrantInventory.init(operation, floor);
    defer cursor.deinit();
    var received: usize = 0;
    for (0..512) |_| {
        switch (try cursor.advance()) {
            .read => |request| try cursor.completeRead(request.ticket, backend.read(request)),
            .waiting => {},
            .ready => if (try cursor.take()) |item| {
                try std.testing.expectEqual(first + @as(u32, @intCast(received)), item.id.slot);
                try std.testing.expectEqualStrings("terminal viewer", item.label.slice());
                const own = try operation.inspectGrant(null);
                try std.testing.expect(!own.id.eql(item.id));
                try std.testing.expectEqualStrings("inventory owner", own.label.slice());
                received += 1;
                if (received == count) return;
            } else if (cursor.done) return error.MissingInventory,
        }
    }
    return error.NoProgress;
}
