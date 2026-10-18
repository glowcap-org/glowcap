//! Resource structure, authority and index effects use one persistent model.
const std = @import("std");
const r = @import("resource_fixture.zig");
const f = r.f;

pub fn composedTraversal(store: *r.h.loam.core.Store, backend: anytype) !void {
    const seeded = try r.seed(store, backend);
    const destination = try f.resource(store, backend, seeded.data.owner, seeded.root);
    var caps = try r.storage.Capabilities.init(r.a, store, .{});
    defer caps.deinit() catch unreachable;
    const descriptor = try r.h.c.descriptor(&caps, backend, seeded.data.owner, seeded.data.grant, null, .reachable);
    try store.begin();
    defer if (store.phase == .staging) store.abort() catch unreachable;
    var child: r.core.ResourceId = undefined;
    {
        var read: r.storage.Read = undefined;
        try read.init(r.a, store, seeded.data.owner, 8, null);
        defer read.deinit() catch unreachable;
        _ = try r.pump(&read, backend);
        var append = try r.storage.Append.init(&read, .resource);
        defer append.deinit() catch unreachable;
        _ = try r.pump(&append, backend);
        child = try f.stageResource(&append, &read, backend, f.vocabulary.kind, seeded.leaf);
    }
    {
        var read: r.storage.Read = undefined;
        try read.init(r.a, store, seeded.data.owner, 8, null);
        defer read.deinit() catch unreachable;
        _ = try r.pump(&read, backend);
        var move = try r.prepare(&read, backend, seeded.leaf, .{ .move = destination });
        defer move.deinit() catch unreachable;
        _ = try r.pump(&move, backend);
        try std.testing.expect(try move.stage());
    }
    try r.children(&caps, backend, descriptor, seeded.leaf, &.{child});
    try r.children(&caps, backend, descriptor, destination, &.{seeded.leaf});
    try f.commit(store, backend);
    store.evict();
    try r.children(&caps, backend, descriptor, seeded.leaf, &.{child});
    try r.children(&caps, backend, descriptor, destination, &.{seeded.leaf});
}

pub fn independentPreparations(store: *r.h.loam.core.Store, backend: anytype) !void {
    const seeded = try r.seed(store, backend);
    const sibling = try f.resource(store, backend, seeded.data.owner, seeded.root);
    var first: r.storage.Read = undefined;
    try first.init(r.a, store, seeded.data.owner, 8, null);
    defer first.deinit() catch unreachable;
    var second: r.storage.Read = undefined;
    try second.init(r.a, store, seeded.data.owner, 8, null);
    defer second.deinit() catch unreachable;
    _ = try r.pump(&first, backend);
    _ = try r.pump(&second, backend);
    var deletion = try r.prepare(&first, backend, seeded.leaf, .delete_leaf);
    defer deletion.deinit() catch unreachable;
    var stale = try r.prepare(&second, backend, sibling, .delete_leaf);
    defer stale.deinit() catch unreachable;
    _ = try r.pump(&deletion, backend);
    _ = try r.pump(&stale, backend);
    const revision = store.metadata.revision;
    try store.begin();
    defer if (store.phase == .staging) store.abort() catch unreachable;
    try std.testing.expect(try deletion.stage());
    try std.testing.expectError(error.RevisionConflict, stale.stage());
    try store.abort();
    try std.testing.expectError(error.RevisionConflict, first.advance());
    try std.testing.expectEqual(revision, store.metadata.revision);
    var caps = try r.storage.Capabilities.init(r.a, store, .{});
    defer caps.deinit() catch unreachable;
    const descriptor = try r.h.c.descriptor(&caps, backend, seeded.data.owner, seeded.data.grant, null, .reachable);
    try r.children(&caps, backend, descriptor, seeded.root, &.{ seeded.leaf, sibling });
    const use = try r.h.c.use(&caps, backend, descriptor);
    defer use.release();
    {
        const one = try use.begin(8);
        defer one.deinit() catch unreachable;
        const two = try use.begin(8);
        defer two.deinit() catch unreachable;
        _ = try prepareZig(one, backend, seeded.leaf);
        _ = try prepareZig(two, backend, sibling);
        try store.begin();
        try std.testing.expect(try one.stageResource());
        try std.testing.expectError(error.RevisionConflict, two.stageResource());
        try store.abort();
    }
    // Preparations made after the preceding stage do compose on its header,
    // parent row and child index, including through independent native handles.
    {
        try store.begin();
        const one = try use.begin(8);
        defer one.deinit() catch unreachable;
        _ = try prepareZig(one, backend, seeded.leaf);
        try std.testing.expect(try one.stageResource());
        const two = try use.begin(8);
        defer two.deinit() catch unreachable;
        _ = try prepareZig(two, backend, sibling);
        try std.testing.expect(try two.stageResource());
        try f.commit(store, backend);
    }
    try r.children(&caps, backend, descriptor, seeded.root, &.{});
}

fn prepareZig(operation: *r.storage.Operation, backend: anytype, target: r.core.ResourceId) !bool {
    for (0..128) |_| {
        const changed = operation.prepareResourceCopying(target, .delete_leaf, .{ .permissions = &.{f.vocabulary.read} }) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try r.pump(operation, backend);
            continue;
        };
        _ = try r.pump(operation, backend);
        return changed;
    }
    return error.NoProgress;
}

pub fn cursorCustody(store: *r.h.loam.core.Store, backend: anytype) !void {
    return cursorReads(store, backend, false);
}

pub fn cursorCancellation(store: *r.h.loam.core.Store, backend: anytype) !void {
    return cursorReads(store, backend, true);
}

fn cursorReads(store: *r.h.loam.core.Store, backend: anytype, cancel: bool) !void {
    const seeded = try r.seed(store, backend);
    _ = try f.resource(store, backend, seeded.data.owner, seeded.root);
    var caps = try r.storage.Capabilities.init(r.a, store, .{});
    defer caps.deinit() catch unreachable;
    const descriptor = try r.h.c.descriptor(&caps, backend, seeded.data.owner, seeded.data.grant, null, .reachable);
    const use = try r.h.c.use(&caps, backend, descriptor);
    defer use.release();
    const header_lease = try r.h.c.load(store, backend, seeded.data.owner);
    const header = try f.loam.access.records.OwnerRecord.decode(try store.currentView(header_lease));
    try store.release(header_lease);
    const operation = try use.begin(8);
    defer operation.deinit() catch unreachable;
    try r.h.c.require(operation, backend, seeded.root, .{ .permissions = &.{f.vocabulary.read} });
    const query = try operation.children(seeded.root, .{ .permissions = &.{f.vocabulary.read} });
    defer query.deinit() catch unreachable;
    store.evict();
    var items: usize = 0;
    for (0..512) |_| switch (try query.advance()) {
        .read => |request| {
            var wrong = request.ticket;
            wrong.sequence += 1000;
            try std.testing.expectError(error.StaleCompletion, query.completeRead(wrong, .missing));
            if (cancel and request.id.eql(header.resources.?)) {
                try query.cancel();
                try std.testing.expectError(error.Busy, query.deinit());
                try std.testing.expectError(error.Cancelled, query.advance());
                try std.testing.expectError(error.StaleCompletion, query.completeRead(wrong, .missing));
                try std.testing.expectError(error.Canceled, query.completeRead(request.ticket, backend.read(request)));
                try std.testing.expectError(error.StaleCompletion, query.completeRead(request.ticket, .missing));
                return;
            }
            query.completeRead(request.ticket, backend.read(request)) catch |err| {
                // Preserve cleanup on the unfixed path that lost the route.
                if (err == error.StaleCompletion) try operation.completeRead(request.ticket, backend.read(request));
                return err;
            };
        },
        .waiting => {},
        .item => {
            items += 1;
            store.evict();
        },
        .done => {
            try std.testing.expect(!cancel);
            try std.testing.expectEqual(@as(usize, 2), items);
            return;
        },
    };
    return error.NoProgress;
}

pub fn structure(store: *r.h.loam.core.Store, backend: anytype) !void {
    const seeded = try r.seed(store, backend);
    const data = seeded.data;
    const child = try f.resource(store, backend, data.owner, seeded.leaf);
    var caps = try r.storage.Capabilities.init(r.a, store, .{});
    defer caps.deinit() catch unreachable;
    var read: r.storage.Read = undefined;
    try read.init(r.a, store, data.owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    const descriptor = try r.h.c.descriptor(&caps, backend, data.owner, data.grant, null, .reachable);
    try r.children(&caps, backend, descriptor, seeded.root, &.{seeded.leaf});
    try std.testing.expectError(error.ContainmentCycle, r.change(store, backend, data.owner, seeded.leaf, .{ .move = child }));
    try std.testing.expectError(error.HasChildren, r.change(store, backend, data.owner, seeded.leaf, .delete_leaf));
    try std.testing.expect(try r.change(store, backend, data.owner, seeded.leaf, .{ .move = seeded.other }));
    try r.children(&caps, backend, descriptor, seeded.root, &.{});
    var host: r.h.Hosted = undefined;
    try host.init(store, backend, data);
    defer host.deinit();
    var denied: r.h.Answer = .{};
    try host.send(host.use, "get", &.{}, &denied);
    try host.drain(backend);
    try std.testing.expectEqualStrings("OutOfScope", denied.reason());
    try std.testing.expect(try r.change(store, backend, data.owner, seeded.leaf, .{ .move = seeded.root }));
    var allowed: r.h.Answer = .{};
    try host.send(host.use, "get", &.{}, &allowed);
    try host.drain(backend);
    try std.testing.expectEqual(@as(?i64, 0), allowed.number);
    try std.testing.expect(try r.change(store, backend, data.owner, child, .delete_leaf));
    try std.testing.expect(try r.change(store, backend, data.owner, seeded.leaf, .delete_leaf));
    var gone: r.h.Answer = .{};
    try host.send(host.use, "get", &.{}, &gone);
    try host.drain(backend);
    try std.testing.expectEqualStrings("Gone", gone.reason());
    const lease = try r.h.c.load(store, backend, data.content);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqual(@as(usize, 8), (try store.currentView(lease)).payload.len);
}

pub fn visibility(store: *r.h.loam.core.Store, backend: anytype) !void {
    const seeded = try r.seed(store, backend);
    const visible = try f.resource(store, backend, seeded.data.owner, seeded.root);
    _ = try f.resource(store, backend, seeded.data.owner, seeded.root);
    const terms = try f.vocabulary.terms(.{ .objects = &.{ seeded.root, visible } }, &.{f.vocabulary.read}, null);
    const limited = (try f.change(store, backend, seeded.data.owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    var caps = try r.storage.Capabilities.init(r.a, store, .{});
    defer caps.deinit() catch unreachable;
    const descriptor = try r.h.c.descriptor(&caps, backend, seeded.data.owner, limited, null, .reachable);
    try r.children(&caps, backend, descriptor, seeded.root, &.{visible});
    // A continuation keeps an exact snapshot; an intervening mutation requires
    // fresh admission, never a raw owner revision passed back as authority.
    const lease = try r.h.c.load(store, backend, descriptor);
    const use = try caps.restoreUse(lease);
    try store.release(lease);
    defer use.release();
    const operation = try use.begin(8);
    defer operation.deinit() catch unreachable;
    _ = try r.pump(operation, backend);
    var cursor: ?*r.storage.Children = null;
    for (0..128) |_| {
        cursor = operation.children(seeded.root, .{ .permissions = &.{f.vocabulary.read} }) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try r.pump(operation, backend);
            continue;
        };
        break;
    }
    const query = cursor orelse return error.NoProgress;
    defer query.deinit() catch unreachable;
    _ = try f.resource(store, backend, seeded.data.owner, seeded.root);
    try std.testing.expectError(error.RevisionConflict, query.advance());
}

pub fn rollback(store: *r.h.loam.core.Store, backend: anytype) !void {
    try store.begin();
    const owner = try r.storage.stage.createOwner(store, @fromBackingInt(71), try r.core.Policy.init(f.vocabulary.descriptor), .{ .max_resource_depth = 2 });
    try f.commit(store, backend);
    const root = try f.resource(store, backend, owner, null);
    const branch = try f.resource(store, backend, owner, root);
    const leaf = try f.resource(store, backend, owner, branch);
    const other = try f.resource(store, backend, owner, null);
    const destination = try f.resource(store, backend, owner, other);
    try std.testing.expectError(error.DepthLimit, r.change(store, backend, owner, branch, .{ .move = destination }));
    var read: r.storage.Read = undefined;
    try read.init(r.a, store, owner, 8, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var edit = try r.prepare(&read, backend, leaf, .{ .move = other });
    defer edit.deinit() catch unreachable;
    _ = try r.pump(&edit, backend);
    try store.begin();
    try std.testing.expect(try edit.stage());
    const content = try store.allocateId();
    try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = "abort" }, null);
    try store.abort();
    var fresh: r.storage.Read = undefined;
    try fresh.init(r.a, store, owner, 8, null);
    defer fresh.deinit() catch unreachable;
    _ = try f.pump(&fresh, backend);
    var resources = try fresh.resourceView();
    for (0..128) |_| {
        const record = resources.get(leaf) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(&fresh, backend);
            continue;
        };
        try std.testing.expect(record.parent.?.eql(branch));
        return;
    }
    return error.NoProgress;
}

pub fn queued(store: *r.h.loam.core.Store, backend: anytype) !void {
    for ([_]bool{ false, true }) |cold| {
        const seeded = try r.seed(store, backend);
        var host: r.h.Hosted = undefined;
        try host.init(store, backend, seeded.data);
        defer host.deinit();
        store.evict();
        var answer: r.h.Answer = .{};
        try host.mutate(host.use, 1, "add", &.{.{ .integer = 1 }}, &answer);
        _ = try host.host.vat.driveIngressBudgeted(.local, 64);
        var held: ?r.h.loam.core.Read = null;
        for (0..128) |_| {
            try host.attached.advance();
            if (host.attached.operations[0].phase == .scheduled) break;
            const work = (try host.attached.nextWork()) orelse return error.NoProgress;
            try std.testing.expect(work == .read);
            if (cold and host.attached.operations[0].pending_read) {
                held = work.read;
                break;
            }
            try host.attached.completeRead(work.read.ticket, backend.read(work.read));
        }
        if (cold) try std.testing.expect(held != null) else try std.testing.expect(host.attached.operations[0].phase == .scheduled);
        const result = if (held) |read| backend.read(read) else null;
        try std.testing.expect(try r.change(store, backend, seeded.data.owner, seeded.leaf, .{ .move = seeded.other }));
        if (held) |read| try host.attached.completeRead(read.ticket, result.?);
        try host.drain(backend);
        try std.testing.expectEqualStrings("OutOfScope", answer.reason());
        try std.testing.expectEqual(@as(u64, 0), host.attached.stats.invocations);
        try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    }
}
