//! Stored references restore exact roles and retain current shared authority rules.
const std = @import("std");
const c = @import("capability_fixture.zig");
const f = c.f;
const a = c.a;
const req: c.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };

test "access stored capabilities separate roles and enforce management ceilings" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    var caps = try c.storage.Capabilities.init(a, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const wide = try f.vocabulary.terms(.{ .object = resource }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const narrow = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, 100);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(wide, 1) })).?.grant;
    const use_id = try c.descriptor(&caps, backend, owner, grant, null, true);
    const control_id = try c.descriptor(&caps, backend, owner, grant, .{ .pause = true, .resume_access = true, .policy_ceiling = narrow }, true);
    const wrong_role = c.control(&caps, backend, use_id);
    if (wrong_role) |unexpected| unexpected.release() else |_| {}
    try std.testing.expectError(error.WrongRole, wrong_role);
    try std.testing.expectError(error.WrongRole, c.use(&caps, backend, control_id));
    const use = try c.use(&caps, backend, use_id);
    defer use.release();
    const control = try c.control(&caps, backend, control_id);
    defer control.release();
    const current = try use.begin(4);
    defer current.deinit() catch unreachable;
    try c.require(current, backend, resource, req);
    try std.testing.expectError(error.WrongRole, current.prepareEditCopying(.revoke));
    {
        const op = try control.begin(4);
        defer op.deinit() catch unreachable;
        try std.testing.expectError(error.WrongRole, op.require(resource, req));
        try std.testing.expectError(error.WrongRole, op.prepareDeriveCopying(f.vocabulary.issue(narrow, 0)));
        try std.testing.expectError(error.Denied, c.edit(op, backend, .revoke));
        try std.testing.expectError(error.CeilingExceeded, c.edit(op, backend, .{ .set_policy = wide }));
        try std.testing.expect(try c.edit(op, backend, .pause));
        try store.begin();
        _ = try caps.stage(op, false);
        try f.commit(store, backend);
    }
    try std.testing.expectError(error.RevisionConflict, current.require(resource, req));
    {
        const op = try use.begin(4);
        defer op.deinit() catch unreachable;
        try std.testing.expectError(error.Paused, c.require(op, backend, resource, req));
    }
    {
        const op = try control.begin(4);
        defer op.deinit() catch unreachable;
        try std.testing.expect(try c.edit(op, backend, .resume_access));
        try store.begin();
        _ = try caps.stage(op, false);
        try f.commit(store, backend);
    }
    {
        const op = try control.begin(4);
        defer op.deinit() catch unreachable;
        try std.testing.expect(try c.edit(op, backend, .{ .set_policy = narrow }));
        try store.begin();
        _ = try caps.stage(op, false);
        try f.commit(store, backend);
    }
    const checked = try use.begin(4);
    defer checked.deinit() catch unreachable;
    try std.testing.expectError(error.Denied, c.require(checked, backend, resource, .{ .permissions = &.{f.vocabulary.post} }));
    try c.require(checked, backend, resource, .{ .permissions = req.permissions, .facts = &.{.{ .key = f.vocabulary.history, .value = 100 }} });
}

test "access stored derivation atomically creates its exact use descriptor and preserves ancestors" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    var caps = try c.storage.Capabilities.init(a, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
    const root = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?.grant;
    const use = try c.use(&caps, backend, try c.descriptor(&caps, backend, owner, root, null, true));
    defer use.release();
    for ([_]bool{ false, true }) |commit| {
        var proposed: f.loam.core.ObjectId = undefined;
        {
            const operation = try use.begin(4);
            defer operation.deinit() catch unreachable;
            try c.derive(operation, backend, f.vocabulary.issue(terms, 0));
            try store.begin();
            proposed = (try caps.stage(operation, true)).derived_use.?;
            if (commit) try f.commit(store, backend) else try store.abort();
        }
        if (!commit) {
            try std.testing.expectError(error.Gone, c.use(&caps, backend, proposed));
        } else {
            const child = try c.use(&caps, backend, proposed);
            defer child.release();
            {
                const check = try child.begin(4);
                defer check.deinit() catch unreachable;
                try c.require(check, backend, resource, req);
                try std.testing.expectError(error.DelegationDenied, c.derive(check, backend, f.vocabulary.issue(terms, 0)));
            }
            _ = try f.change(store, backend, owner, .{ .revoke = root });
            const check = try child.begin(4);
            defer check.deinit() catch unreachable;
            try std.testing.expectError(error.Revoked, c.require(check, backend, resource, req));
        }
    }
}

test "access stored operation owns custody and pending buffers after its holder releases" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    const resource = try f.resource(&fixture.store, &fixture.backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(&fixture.store, &fixture.backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    var caps = try c.storage.Capabilities.init(a, &fixture.store, .{ .max_references = 1, .max_operations = 1 });
    defer caps.deinit() catch unreachable;
    const id = try c.descriptor(&caps, &fixture.backend, owner, grant, null, true);
    const use = try c.use(&caps, &fixture.backend, id);
    try std.testing.expectError(error.CapabilityCapacity, c.use(&caps, &fixture.backend, id));
    const alias = try use.retain();
    alias.release();
    fixture.store.evict();
    const operation = try use.begin(4);
    try std.testing.expectError(error.OperationCapacity, use.begin(4));
    use.release();
    try std.testing.expectError(error.Busy, caps.deinit());
    const request = (try operation.advance()).read;
    try std.testing.expectError(error.Busy, operation.deinit());
    try operation.cancel();
    try std.testing.expectError(error.Canceled, operation.completeRead(request.ticket, fixture.backend.read(request)));
    try operation.deinit();
    try std.testing.expectEqual(@as(usize, 0), caps.references);
    try std.testing.expectEqual(@as(usize, 0), caps.operations);
    fixture.store.evict();
    try std.testing.expectEqual(@as(usize, 0), fixture.store.cache.allocated_bytes);
}
