//! Sparse index edits stage changed mappings only. Store proposals and allocator
//! counts establish the cost; owner scenarios establish resource semantics.
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
    var read = try storage.Read.init(store.allocator, store, owner, 6);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 6);
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
