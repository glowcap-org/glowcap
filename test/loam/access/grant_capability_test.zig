//! Native capability possession selects one grant. These tests exercise the
//! local API; actor dispatch, publication, and content effects are not hosted.
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access held use references carry one grant without another credential" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    const other = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const grant = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    const use = try ledger.createUse(grant);
    defer use.release();
    const alias = try use.retain();
    defer alias.release();
    try std.testing.expect(use == alias);
    try alias.require(resource, .{ .permissions = &.{f.read} });
    try std.testing.expectEqual(@as(u64, 1), (try alias.describe(resource)).active.effective.permissions);
    try std.testing.expectEqual(.out_of_scope, try alias.describe(other));
    try std.testing.expectError(error.OutOfScope, alias.require(other, .{ .permissions = &.{f.read} }));
    try std.testing.expectError(error.Denied, alias.require(resource, .{ .permissions = &.{f.post} }));
    // Knowing another grant's ID cannot change the target of a held reference.
    const stronger = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    _ = try ledger.issueRootCopying(ledger.version(), f.issue(stronger, 0));
    try std.testing.expectError(error.Denied, alias.require(resource, .{ .permissions = &.{f.post} }));
    _ = try ledger.revoke(ledger.version(), grant);
    try std.testing.expectError(error.Revoked, use.require(resource, .{ .permissions = &.{f.read} }));
    try std.testing.expectEqual(.revoked, try use.describe(resource));
    try std.testing.expectError(error.Busy, ledger.deinit());
    try std.testing.expect(@typeInfo(core.GrantUse) == .@"opaque");
    try std.testing.expect(@typeInfo(core.GrantControl) == .@"opaque");
    try std.testing.expect(!@hasDecl(core.GrantUse, "prepareCopying"));
    try std.testing.expect(!@hasDecl(core.GrantUse, "createControlCopying"));
    try std.testing.expect(!@hasDecl(core.GrantControl, "require"));
}

test "access control possession edits only its grant with explicit powers" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    const child = (try ledger.deriveCopying(ledger.version(), root, f.issue(terms, 0))).grant;
    const use = try ledger.createUse(child);
    defer use.release();
    const pause = try ledger.createControlCopying(child, .{ .pause = true });
    defer pause.release();
    const resume_access = try ledger.createControlCopying(child, .{ .resume_access = true });
    defer resume_access.release();
    try std.testing.expectError(error.Denied, pause.prepareCopying(ledger.version(), .resume_access));
    try std.testing.expectError(error.Denied, pause.prepareCopying(ledger.version(), .revoke));
    try std.testing.expectError(error.Denied, pause.prepareCopying(ledger.version(), .{ .set_policy = terms }));
    const ticket = (try pause.prepareCopying(ledger.version(), .pause)).?;
    try use.require(resource, .{ .permissions = &.{f.read} });
    const event = try ledger.commitVolatile(ticket);
    try std.testing.expect(event.grant.eql(child));
    try std.testing.expectEqual(.paused, event.kind.status_changed.after);
    try std.testing.expectEqual(.active, try ledger.effectiveStatus(root));
    try std.testing.expectError(error.Paused, use.require(resource, .{ .permissions = &.{f.read} }));
    try std.testing.expect(try pause.prepareCopying(ledger.version(), .pause) == null);
    _ = try ledger.commitVolatile((try resume_access.prepareCopying(ledger.version(), .resume_access)).?);
    try use.require(resource, .{ .permissions = &.{f.read} });
    _ = try ledger.pause(ledger.version(), root);
    _ = try ledger.commitVolatile((try pause.prepareCopying(ledger.version(), .pause)).?);
    _ = try ledger.commitVolatile((try resume_access.prepareCopying(ledger.version(), .resume_access)).?);
    try std.testing.expectError(error.Paused, use.require(resource, .{ .permissions = &.{f.read} }));
}

test "access control policy ceiling bounds promotion independently of use" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const wide = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    const limited = try f.terms(wide.scope, &.{f.read}, 100);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(wide, 0))).grant;
    const use = try ledger.createUse(root);
    defer use.release();
    const control = try ledger.createControlCopying(root, .{ .policy_ceiling = limited });
    defer control.release();
    const alias = try control.retain();
    defer alias.release();
    const before = ledger.version();
    try std.testing.expectError(error.CeilingExceeded, alias.prepareCopying(before, .{ .set_policy = wide }));
    try std.testing.expectError(error.CeilingExceeded, alias.prepareCopying(before, .{
        .set_policy = try f.terms(wide.scope, &.{f.read}, 99),
    }));
    try std.testing.expectEqualDeep(before, ledger.version());
    try std.testing.expect(ledger.pending == null);
    _ = try ledger.commitVolatile((try alias.prepareCopying(before, .{ .set_policy = limited })).?);
    try std.testing.expectError(error.Denied, use.require(resource, .{ .permissions = &.{f.post} }));
    try std.testing.expectError(error.Denied, use.require(resource, .{
        .permissions = &.{f.read},
        .facts = &.{.{ .key = f.history, .value = 99 }},
    }));
    try use.require(resource, .{ .permissions = &.{f.read}, .facts = &.{.{ .key = f.history, .value = 100 }} });
}

test "access held delegation yields no child reference until committed" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    const use = try ledger.createUse(root);
    defer use.release();
    const ticket = try use.prepareDeriveCopying(ledger.version(), f.issue(terms, 0));
    const write = try ledger.beginWrite(ticket);
    try std.testing.expectError(error.UnknownGrant, ledger.createUse(write.record.id));
    try std.testing.expectError(error.UnknownGrant, ledger.createControlCopying(write.record.id, .{ .revoke = true }));
    const event = (try ledger.finishWrite(ticket, .committed)).committed;
    const child = try ledger.createUse(event.grant);
    defer child.release();
    const control = try ledger.createControlCopying(event.grant, .{ .revoke = true });
    try child.require(resource, .{ .permissions = &.{f.read} });
    try std.testing.expectError(error.DelegationDenied, child.prepareDeriveCopying(ledger.version(), f.issue(terms, 0)));
    // Dropping management possession does not revoke the use grant.
    control.release();
    try child.require(resource, .{ .permissions = &.{f.read} });
    _ = try ledger.revoke(ledger.version(), root);
    try std.testing.expectError(error.Revoked, child.require(resource, .{ .permissions = &.{f.read} }));
}

test "access capability calls preserve uncertainty fences and terminal revocation" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    const use = try ledger.createUse(root);
    defer use.release();
    const control = try ledger.createControlCopying(root, .{ .revoke = true, .resume_access = true });
    defer control.release();
    const ticket = (try control.prepareCopying(ledger.version(), .revoke)).?;
    _ = try ledger.beginWrite(ticket);
    _ = try ledger.finishWrite(ticket, .unknown);
    try std.testing.expectError(error.RecoveryRequired, use.require(resource, .{ .permissions = &.{f.read} }));
    try std.testing.expectError(error.RecoveryRequired, use.prepareDeriveCopying(ledger.version(), f.issue(terms, 0)));
    try std.testing.expectError(error.RecoveryRequired, control.prepareCopying(ledger.version(), .resume_access));
    try std.testing.expectError(error.RecoveryRequired, ledger.createUse(root));
    _ = try ledger.resolveWrite(ticket, .committed);
    try std.testing.expectError(error.Revoked, use.require(resource, .{ .permissions = &.{f.read} }));
    try std.testing.expectError(error.Revoked, control.prepareCopying(ledger.version(), .resume_access));
    try std.testing.expect(try control.prepareCopying(ledger.version(), .revoke) == null);
}
