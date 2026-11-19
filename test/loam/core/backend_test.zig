//! The contract checks name the first operation an engine or backend lacks.
const std = @import("std");
const core = @import("fixture.zig").core;

test "loam engine check names the first absent operation" {
    const Whole = struct {
        pub const ReadTransaction = struct {
            pub fn get() void {}
            pub fn next() void {}
            pub fn end() void {}
        };
        pub const WriteTransaction = struct {
            pub fn get() void {}
            pub fn next() void {}
            pub fn put() void {}
            pub fn commit() void {}
            pub fn abort() void {}
        };
        pub fn beginRead() void {}
        pub fn beginWrite() void {}
        pub fn readerCapacity() void {}
    };
    try std.testing.expectEqualStrings("write transaction lacks remove", core.backend.missingOperation(Whole).?);
    try std.testing.expectEqualStrings("engine lacks beginRead", core.backend.missingOperation(struct {}).?);
    try std.testing.expectEqualStrings("engine lacks readerCapacity", core.backend.missingOperation(struct {
        pub fn beginRead() void {}
        pub fn beginWrite() void {}
    }).?);
}

test "loam backend check names the first absent operation" {
    const Partial = struct {
        pub fn read() void {}
        pub fn commit() void {}
        pub fn recover() void {}
    };
    try std.testing.expectEqualStrings("backend lacks lookup", core.backend.missingBackendOperation(Partial).?);
}

test "loam recovers a committed batch only under its exact ticket" {
    const last = std.math.maxInt(u64);
    var batch: core.Batch = .{
        .ticket = .{ .store = @fromBackingInt(1), .incarnation = 1, .sequence = 2, .revision = 0 },
        .changes = &.{},
        .limits = .{},
        .schemas = &.{},
    };
    var current: core.Metadata = .{ .store = @fromBackingInt(1), .incarnation = 1, .last_sequence = 2, .revision = 0 };
    const Case = struct { revision: enum { older, prior, current }, sequence: u64, expected: enum { committed, unchanged, refused } };
    const cases = [_]Case{
        .{ .revision = .older, .sequence = 2, .expected = .refused },
        .{ .revision = .prior, .sequence = 1, .expected = .refused },
        .{ .revision = .prior, .sequence = 2, .expected = .committed },
        .{ .revision = .prior, .sequence = 3, .expected = .refused },
        .{ .revision = .current, .sequence = 1, .expected = .refused },
        .{ .revision = .current, .sequence = 2, .expected = .refused },
        .{ .revision = .current, .sequence = 3, .expected = .unchanged },
    };

    for ([_]u64{ 1, last - 1 }) |prior| {
        current.revision = prior + 1;
        for (0..4) |foreign| {
            batch.ticket.store = @fromBackingInt(if (foreign & 1 == 0) @as(u64, 1) else 2);
            batch.ticket.incarnation = if (foreign & 2 == 0) 1 else 2;
            for (cases) |case| {
                batch.ticket.revision = switch (case.revision) {
                    .older => prior - 1,
                    .prior => prior,
                    .current => current.revision,
                };
                batch.ticket.sequence = case.sequence;
                const result = batch.resolve(current);
                if (foreign != 0) {
                    try std.testing.expectError(error.StaleWriter, result);
                    continue;
                }
                switch (case.expected) {
                    .committed => try std.testing.expectEqualDeep(core.Resolution{ .committed = current }, try result),
                    .unchanged => try std.testing.expectEqual(core.Resolution.unchanged, try result),
                    .refused => try std.testing.expectError(error.RecoveryRequired, result),
                }
            }
        }
    }

    batch.ticket = .{ .store = current.store, .incarnation = current.incarnation, .revision = last, .sequence = 2 };
    current.revision = 0;
    try std.testing.expectError(error.RecoveryRequired, batch.resolve(current));
}
