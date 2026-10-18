//! The resident owner index keeps headers and directory answers for one
//! committed revision per owner, bounded by its two constants.
const std = @import("std");
const a = std.testing.allocator;
const f = @import("owner_fixture.zig");
const storage = f.storage;
const loam = f.loam.core;
const records = f.loam.access.records;
const Target = storage.Target;

test "a newer revision of the same owner replaces its resolutions" {
    const store: loam.StoreId = @fromBackingInt(1);
    const owner_object: loam.ObjectId = .{ .store = store, .incarnation = 1, .sequence = 7 };
    const page: loam.ObjectId = .{ .store = store, .incarnation = 1, .sequence = 9 };
    const header: records.OwnerRecord = .{ .owner = @fromBackingInt(3), .policy = undefined };
    const target: Target = .{ .resource = .{ .owner = header.owner, .slot = 5, .generation = 1 } };
    var index: storage.OwnerIndex = .{ .allocator = a };
    defer index.deinit();
    try std.testing.expect(index.find(owner_object, 1) == null);
    index.admit(owner_object, 1, &header);
    const resident = index.find(owner_object, 1).?;
    try std.testing.expect(resident.resolve(target) == null);
    resident.record(a, target, page);
    try std.testing.expect(resident.resolve(target).?.node.?.eql(page));
    try std.testing.expect(index.find(owner_object, 2) == null);
    index.admit(owner_object, 2, &header);
    try std.testing.expectEqual(@as(usize, 1), index.count);
    try std.testing.expect(index.find(owner_object, 2).?.resolve(target) == null);
}

test "resident bounds replace the oldest owner and the oldest target" {
    const store: loam.StoreId = @fromBackingInt(1);
    const header: records.OwnerRecord = .{ .owner = @fromBackingInt(3), .policy = undefined };
    var index: storage.OwnerIndex = .{ .allocator = a };
    defer index.deinit();
    for (0..storage.OwnerIndex.resident_owners + 1) |sequence| {
        index.admit(.{ .store = store, .incarnation = 1, .sequence = sequence + 1 }, 1, &header);
    }
    try std.testing.expect(index.find(.{ .store = store, .incarnation = 1, .sequence = 1 }, 1) == null);
    const newest = index.find(.{ .store = store, .incarnation = 1, .sequence = storage.OwnerIndex.resident_owners + 1 }, 1).?;
    for (0..storage.OwnerIndex.resident_targets + 1) |slot| {
        newest.record(a, .{ .resource = .{ .owner = header.owner, .slot = @intCast(slot), .generation = 1 } }, null);
    }
    try std.testing.expect(newest.resolve(.{ .resource = .{ .owner = header.owner, .slot = 0, .generation = 1 } }) == null);
    try std.testing.expect(newest.resolve(.{ .resource = .{ .owner = header.owner, .slot = storage.OwnerIndex.resident_targets, .generation = 1 } }) != null);
}
