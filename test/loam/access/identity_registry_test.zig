//! Weak membership preserves collection while composing all minted identities.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const f = h.f;
const c = h.c;
const storage = c.storage;

test "access identity registry retains pages without retaining descriptor payload" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    var caps = try storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    _ = try c.descriptor(&caps, backend, owner, grant, null, false);
    const before = store.metadata.objects;
    try @import("../core/fixture.zig").collect(store, backend);
    try std.testing.expectEqual(before - 1, store.metadata.objects);
    var read = try storage.Read.init(h.a, store, owner, 1);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try std.testing.expectEqual(@as(u64, 1), read.header.next_identity);
    try std.testing.expect(read.header.identities != null);
}

test "access identity registry composes descriptor and endpoint membership in one owner batch" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const data = try h.seed(&fixture.store, &fixture.backend);
    var read = try storage.Read.init(h.a, &fixture.store, data.owner, 1);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 6), read.header.next_identity);
    for (0..read.header.next_identity) |slot| {
        var lookup = try storage.Read.init(h.a, &fixture.store, data.owner, 1);
        defer lookup.deinit() catch unreachable;
        _ = try f.pump(&lookup, &fixture.backend);
        try std.testing.expect(try lookup.binding(.{ .identity = .{ .owner = read.header.owner, .slot = @intCast(slot) } }) == null);
        _ = try f.pump(&lookup, &fixture.backend);
        const binding = (try lookup.binding(.{ .identity = .{ .owner = read.header.owner, .slot = @intCast(slot) } })).?;
        try std.testing.expect(binding.lease != null);
    }
}
