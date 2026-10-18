//! Host route preparation borrows until Node retains one independent snapshot.
//! Warmed replacement excludes catalog growth. Failure injection covers every
//! allocation in replacement, including hint scratch beyond its inline budget.
const std = @import("std");
const glowcap = @import("glowcap");
const support = @import("../../support/core_host.zig");
const model = glowcap.ocapn.model;
const Host = glowcap.driver.core.Host;

const hints = [_]model.HintEntry{
    .{ .name = "route-a", .value = .{ .string = "one" } },
    .{ .name = "route-b", .value = .{ .string = "two" } },
    .{ .name = "route-c", .value = .{ .string = "three" } },
    .{ .name = "route-d", .value = .{ .string = "four" } },
};
fn options() Host.Options {
    var result = Host.Options{};
    result.captp_version = .next;
    result.codec = .capnp;
    return result;
}
fn locator(carried: []const model.HintEntry) model.PeerLocator {
    return .{ .transport = "tcp", .designator = "127.0.0.1:7088", .hints = .{ .entries = carried } };
}
fn replacementBudget(carried: []const model.HintEntry, expected: usize) !void {
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = support.init(measured.allocator(), @splat(0x82), options());
    defer host.deinit();
    try host.setAdvertisedLocator(locator(carried));
    const retained = host.acceptableLocator().?;
    var byte_budget = retained.transport.len + retained.designator.len + retained.hints.entries.len * @sizeOf(model.HintEntry);
    for (retained.hints.entries) |entry| {
        byte_budget += entry.name.len;
        byte_budget += switch (entry.value) {
            .string => |value| value.len,
            .bytes => |value| value.len,
            .boolean, .integer => 0,
        };
    }
    const scratch: glowcap.ocapn.engine.Peer.HelloHints = .{};
    if (retained.hints.entries.len > scratch.inline_entries.len)
        byte_budget += retained.hints.entries.len * @sizeOf(model.HintEntry);
    inline for (.{ Host.setAdvertisedLocator, Host.retainAdvertisedLocator }) |replace| {
        const before_count = measured.alloc_index;
        const before_bytes = measured.allocated_bytes;
        for (0..100) |_| try replace(&host, locator(carried));
        const count = measured.alloc_index - before_count;
        const bytes = measured.allocated_bytes - before_bytes;
        // Permit the one retained snapshot and extended scratch. Derive bytes
        // from actual fields and target layout; future improvements fit below.
        try std.testing.expect(bytes <= 100 * byte_budget);
        try std.testing.expect(count <= 100 * expected);
    }
}
test "core host locator budget: inline preparation retains one snapshot" {
    try replacementBudget(&.{}, 9);
}
test "core host locator budget: extended hints retain one snapshot plus scratch" {
    try replacementBudget(&hints, 18);
}
test "core host locator budget: repeated accept fallback allocates nothing" {
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = support.init(measured.allocator(), @splat(0x83), options());
    defer host.deinit();
    try host.ensureAcceptAdvertisedLocator(.address, "127.0.0.1:7088", "127.0.0.1:7088", "tcp");
    const before_count = measured.alloc_index;
    const before_bytes = measured.allocated_bytes;
    for (0..100) |_| try host.ensureAcceptAdvertisedLocator(.address, "127.0.0.1:7088", "127.0.0.1:7088", "tcp");
    try std.testing.expectEqual(before_count, measured.alloc_index);
    try std.testing.expectEqual(before_bytes, measured.allocated_bytes);
}

test "core host locator owned preparation outlives hint scratch and Host" {
    const prepared = blk: {
        var host = support.init(std.testing.allocator, @splat(0x85), options());
        defer host.deinit();
        break :blk try host.prepareAdvertisedLocator(std.testing.allocator, locator(&hints));
    };
    defer model.freePeerLocator(std.testing.allocator, prepared);
    try std.testing.expectEqualStrings("127.0.0.1:7088", prepared.designator);
    try std.testing.expectEqual(@as(usize, 6), prepared.hints.entries.len);
    try std.testing.expectEqualStrings("four", prepared.hints.entries[3].value.string);
    try std.testing.expectEqualStrings(model.transport.hint_captp_version, prepared.hints.entries[4].name);
    try std.testing.expectEqualStrings(options().captp_version.hintToken(), prepared.hints.entries[4].value.string);
    try std.testing.expectEqualStrings(model.transport.hint_codec, prepared.hints.entries[5].name);
    const codec_token = options().codec.hintToken();
    try std.testing.expectEqualStrings(codec_token.slice(), prepared.hints.entries[5].value.string);
}

test "core host locator preparation preserves borrowed inputs and allocation rollback" {
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var host = support.init(failing.allocator(), @splat(0x84), options());
        defer host.deinit();
        try host.setAdvertisedLocator(locator(&hints));
        const stored = host.acceptableLocator().?;
        // Transport, designator and carried hints alias the row being replaced.
        const candidate: model.PeerLocator = .{ .transport = stored.transport, .designator = stored.designator, .hints = .{ .entries = stored.hints.entries[0..hints.len] } };
        failing.fail_index = failing.alloc_index + offset;
        host.setAdvertisedLocator(candidate) catch |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            const unchanged = host.acceptableLocator().?;
            try std.testing.expectEqual(stored.designator.ptr, unchanged.designator.ptr);
            try std.testing.expectEqual(stored.hints.entries.ptr, unchanged.hints.entries.ptr);
            continue;
        };
        const retained = host.acceptableLocator().?;
        try std.testing.expectEqualStrings("127.0.0.1:7088", retained.designator);
        try std.testing.expectEqualStrings("four", retained.hints.entries[3].value.string);
        break;
    }
}
