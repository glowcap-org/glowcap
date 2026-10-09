//! Held controls narrow independently while grants remain the use authority.
const std = @import("std");
const m = @import("management_fixture.zig");
const c = m.c;
const f = m.f;
const h = m.h;

pub fn native(store: *h.loam.core.Store, backend: anytype) !void {
    var caps = try c.storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(73));
    const resource = try f.resource(store, backend, owner, null);
    const wide = try f.vocabulary.terms(.{ .object = resource }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const narrow = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(wide, 1) })).?.grant;
    const use = try c.use(&caps, backend, try c.descriptor(&caps, backend, owner, grant, null, true));
    defer use.release();
    const root = try c.control(&caps, backend, try c.descriptor(&caps, backend, owner, grant, .{ .delegate_control = true, .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = wide }, true));
    defer root.release();
    const id = try m.attenuation(&caps, backend, root, .{ .delegate_control = true, .pause = true, .policy_ceiling = narrow });
    const child = try c.control(&caps, backend, id);
    defer child.release();
    {
        const op = try child.begin(8);
        defer op.deinit() catch unreachable;
        _ = try f.pump(op, backend);
        const description = try op.describeControl();
        try std.testing.expect(description.available and description.powers.pause and !description.powers.revoke);
        try std.testing.expectError(error.Denied, op.prepareAttenuationCopying(.{ .revoke = true }));
        try std.testing.expectError(error.Denied, c.edit(op, backend, .revoke));
        try std.testing.expectError(error.CeilingExceeded, c.edit(op, backend, .{ .set_policy = wide }));
    }
    const grandchild = try c.control(&caps, backend, try m.attenuation(&caps, backend, child, .{ .pause = true }));
    defer grandchild.release();
    try m.revoke(&caps, backend, child);
    for ([_]*c.storage.Control{ child, grandchild }) |control| {
        const op = try control.begin(8);
        defer op.deinit() catch unreachable;
        _ = try f.pump(op, backend);
        const description = try op.describeControl();
        try std.testing.expect(!description.available and !description.powers.pause and description.powers.policy_ceiling == null);
        try std.testing.expectError(error.ControlRevoked, c.edit(op, backend, .pause));
    }
    {
        const op = try use.begin(8);
        defer op.deinit() catch unreachable;
        try c.require(op, backend, resource, .{ .permissions = &.{ f.vocabulary.read, f.vocabulary.post } });
    }
    // The independent root control survives child-control retirement.
    const sibling = try c.control(&caps, backend, try m.attenuation(&caps, backend, root, .{ .pause = true }));
    defer sibling.release();
    try m.revoke(&caps, backend, root);
    const stopped = try sibling.begin(8);
    defer stopped.deinit() catch unreachable;
    _ = try f.pump(stopped, backend);
    try std.testing.expectError(error.ControlRevoked, c.edit(stopped, backend, .pause));
}

pub fn composed(store: *h.loam.core.Store, backend: anytype) !void {
    for ([_]bool{ false, true }) |committed| try composedOutcome(store, backend, committed);
    try descriptorBeforeHeader(store, backend);
}

fn descriptorBeforeHeader(store: *h.loam.core.Store, backend: anytype) !void {
    var caps = try c.storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(76));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    const root = try c.control(&caps, backend, try c.descriptor(&caps, backend, owner, grant, .{ .delegate_control = true, .pause = true }, true));
    defer root.release();
    const late = try root.begin(8);
    defer late.deinit() catch unreachable;
    store.evict();
    var header_completed = false;
    for (0..128) |_| switch (try late.advance()) {
        .read => |request| {
            try late.completeRead(request.ticket, backend.read(request));
            if (request.id.eql(owner)) {
                header_completed = true;
                break;
            }
        },
        .waiting => {},
        .ready => return error.ExpectedColdHeader,
    };
    try std.testing.expect(header_completed);
    const revoking = try root.begin(8);
    defer revoking.deinit() catch unreachable;
    _ = try f.pump(revoking, backend);
    try std.testing.expect(try m.prepareRevocation(revoking, backend));
    try store.begin();
    defer if (store.phase == .staging) store.abort() catch unreachable;
    try std.testing.expect(try revoking.stageControlRevocation());
    _ = try f.pump(late, backend);
    try std.testing.expect(!(try late.describeControl()).available);
    try std.testing.expectError(error.ControlRevoked, late.prepareEditCopying(.pause));
    try store.abort();
    try std.testing.expectError(error.RevisionConflict, late.describeControl());
}

fn composedOutcome(store: *h.loam.core.Store, backend: anytype, committed: bool) !void {
    var caps = try c.storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    const owner = try f.create(store, backend, @fromBackingInt(74 + @as(u64, @intFromBool(committed))));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?.grant;
    const root = try c.control(&caps, backend, try c.descriptor(&caps, backend, owner, grant, .{ .delegate_control = true, .pause = true }, true));
    defer root.release();
    const child = try c.control(&caps, backend, try m.attenuation(&caps, backend, root, .{ .pause = true }));
    defer child.release();
    const prepared = try child.begin(8);
    defer prepared.deinit() catch unreachable;
    try std.testing.expect(try c.edit(prepared, backend, .pause));
    const revoking = try root.begin(8);
    defer revoking.deinit() catch unreachable;
    _ = try f.pump(revoking, backend);
    try std.testing.expect(try m.prepareRevocation(revoking, backend));
    try store.begin();
    defer if (store.phase == .staging) store.abort() catch unreachable;
    try std.testing.expect(try revoking.stageControlRevocation());
    try std.testing.expectError(error.RevisionConflict, caps.stage(prepared, false));
    try store.abort();
    // A refused independent preparation aborts through the batch owner. Start
    // a fresh batch to inspect revocation's composed state and final outcome.
    const current = try root.begin(8);
    defer current.deinit() catch unreachable;
    _ = try f.pump(current, backend);
    try std.testing.expect(try m.prepareRevocation(current, backend));
    try store.begin();
    try std.testing.expect(try current.stageControlRevocation());
    for ([_]*c.storage.Control{ root, child }) |control| {
        const fresh = try control.begin(8);
        defer fresh.deinit() catch unreachable;
        _ = try f.pump(fresh, backend);
        try std.testing.expect(!(try fresh.describeControl()).available);
        try std.testing.expectError(error.ControlRevoked, fresh.prepareEditCopying(.pause));
        try std.testing.expectError(error.ControlRevoked, fresh.prepareAttenuationCopying(.{ .pause = true }));
    }
    const repeated = try root.begin(8);
    defer repeated.deinit() catch unreachable;
    _ = try f.pump(repeated, backend);
    try std.testing.expect(!try m.prepareRevocation(repeated, backend));
    try std.testing.expect(!try repeated.stageControlRevocation());
    const observed = try child.begin(8);
    defer observed.deinit() catch unreachable;
    _ = try f.pump(observed, backend);
    try std.testing.expect(!(try observed.describeControl()).available);
    if (committed) try f.commit(store, backend) else try store.abort();
    try std.testing.expectError(error.RevisionConflict, observed.describeControl());
    const reopened = try child.begin(8);
    defer reopened.deinit() catch unreachable;
    _ = try f.pump(reopened, backend);
    try std.testing.expectEqual(!committed, (try reopened.describeControl()).available);
}
