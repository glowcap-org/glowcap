//! Sparse index edits stage changed mappings only. Store proposals and allocator
//! counts establish the cost. Owner scenarios establish resource semantics.
const std = @import("std");
const f = @import("owner_fixture.zig");
const storage = f.storage;
const a = std.testing.allocator;

test "access populated directory edits allocate and stage only the changed leaf" {
    var counter = std.testing.FailingAllocator.init(a, .{});
    var fixture = try f.Fixture.init(counter.allocator(), f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    _ = try f.resource(store, backend, owner, null);
    var read: storage.Read = undefined;
    try read.init(store.allocator, store, owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var append = try storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    _ = try f.pump(&append, backend);
    // This test isolates the generic index participant. Reusing a real target
    // tests only its mapping/ownership, not the resource identity lookup.
    const target = append.directory.frames[3].page.get(0).?;
    try store.begin();
    const allocations = counter.alloc_index;
    const root = try append.stageDirectory(target);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqual(@as(usize, 2), counter.alloc_index - allocations);
    try std.testing.expect(root.eql(read.header.resources.?));
    for (append.directory.frames[0..3]) |frame| {
        try std.testing.expect(try store.proposed(frame.object.?) == null);
    }
    const page = try f.loam.access.records.DirectoryPage.decode((try store.proposed(append.directory.frames[3].object.?)).?.view);
    try std.testing.expect(page.get(0).?.eql(target));
    try std.testing.expect(page.get(1).?.eql(target));
    try store.abort();
    try std.testing.expectEqual(@as(usize, 0), store.staged_bytes);
}

test "access unchanged directory membership stages no records" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    _ = try f.resource(&fixture.store, &fixture.backend, owner, null);
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    var append = try storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    append.directory.slot = 0;
    _ = try f.pump(&append, &fixture.backend);
    const target = append.directory.cursor.?;
    try fixture.store.begin();
    const root = (try append.directory.stage(target)).?;
    try std.testing.expect(root.eql(read.header.resources.?));
    try std.testing.expectEqual(@as(usize, 0), fixture.store.count);
    try fixture.store.abort();
}

test "access a resident owner index binds a repeat demand at its leaf and yields to a staged owner" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const first = try f.resource(store, backend, owner, null);
    var index: storage.OwnerIndex = .{ .allocator = a };
    defer index.deinit();
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, &index);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expect(try read.binding(.{ .resource = first }) == null);
        _ = try f.pump(&read, backend);
        const bound = (try read.binding(.{ .resource = first })).?;
        const resident = index.find(owner, read.header_revision.?).?;
        try std.testing.expect(resident.resolve(.{ .resource = first }).?.node.?.eql(bound.object.?));
        // The reply a Read decodes from the leaf stays with the index entry.
        try std.testing.expect(resident.resolve(.{ .resource = first }).?.resource == null);
        var resources = try read.resourceView();
        _ = try resources.get(first);
        try std.testing.expect(resident.resolve(.{ .resource = first }).?.resource.? == .present);
    }
    // Cold, the walk loads four directory pages before the leaf. The index
    // seeds the walk at the leaf, so the same demand loads the leaf alone.
    store.evict();
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expect(try read.binding(.{ .resource = first }) == null);
        try std.testing.expectEqual(@as(usize, 5), try f.pump(&read, backend));
    }
    store.evict();
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, &index);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expect(try read.binding(.{ .resource = first }) == null);
        try std.testing.expectEqual(@as(usize, 1), try f.pump(&read, backend));
        // The seeded binding carries the decoded reply before any resource read.
        try std.testing.expect((try read.binding(.{ .resource = first })).?.resource.? == .present);
    }
    // A transaction that stages the owner resolves its new slot through the
    // proposed directory and teaches the index nothing.
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, &index);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        var append = try storage.Append.init(&read, .resource);
        defer append.deinit() catch unreachable;
        _ = try f.pump(&append, backend);
        try store.begin();
        defer if (store.phase == .staging) store.abort() catch unreachable;
        const second = try f.stageResource(&append, &read, backend, f.vocabulary.kind, null);
        try std.testing.expect(try read.binding(.{ .resource = second }) == null);
        _ = try f.pump(&read, backend);
        try std.testing.expect((try read.binding(.{ .resource = second })).?.object != null);
        try std.testing.expect(index.find(owner, read.header_revision.?).?.resolve(.{ .resource = second }) == null);
        // A staged owner's bindings take no seed: the index may be stale for it.
        try std.testing.expect(try read.binding(.{ .resource = first }) == null);
        _ = try f.pump(&read, backend);
        try std.testing.expect((try read.binding(.{ .resource = first })).?.resource == null);
    }
}

test "access a resident owner index keeps a lent grant for a repeat Read and drops it with the revision" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const root = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .objects = &.{root} }, &.{f.vocabulary.read}, null);
    const issued = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 2) })).?;
    var index: storage.OwnerIndex = .{ .allocator = a };
    defer index.deinit();
    const grant_target: storage.Target = .{ .grant = issued.grant };
    store.evict();
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, &index);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try f.require(&read, backend, issued.grant, root, .{ .permissions = &.{f.vocabulary.read} });
        const resident = index.find(owner, read.header_revision.?).?;
        const memo = resident.resolve(grant_target).?.grant.?;
        try std.testing.expectEqual(issued.grant.slot, memo.record.grant.id.slot);
        try std.testing.expectEqual(@as(usize, 1), memo.record.grant.configured.scope.objects.len);
        try std.testing.expect(memo.record.grant.configured.scope.objects.ptr != read.grant_row.grant.configured.scope.objects.ptr);
    }
    // A repeat Read at the same revision lends the memo as its own cached row
    // with no row acquired after the binding's leaf.
    store.evict();
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, &index);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expect(try read.binding(grant_target) == null);
        try std.testing.expectEqual(@as(usize, 1), try f.pump(&read, backend));
        var grants = try read.grantView();
        const lent = try grants.borrow(issued.grant);
        try std.testing.expectEqual(issued.grant.slot, lent.id.slot);
        try std.testing.expect(read.grant_cached != null);
        grants.release();
        try std.testing.expectEqual(@as(usize, 0), try f.pump(&read, backend));
    }
    // A change re-proposes the owner, so the next committed revision admits
    // the owner afresh and the memo goes with the old resolutions. status-allow: replacement state identity
    _ = try f.change(store, backend, owner, .{ .pause = issued.grant });
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, &index);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expect(index.find(owner, read.header_revision.?).?.resolve(grant_target) == null);
    }
}
