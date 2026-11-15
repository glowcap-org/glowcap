//! `HostSession.inboundResumable`: whether `resumeFeed` has input it can move.
//! A stepped runtime posts its wake on this answer, so it is true exactly
//! when a resume dispatches or refuses something, and false for the front of
//! a frame whose rest the transport has yet to deliver.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const sealed_pair = @import("../../support/sealed_pair.zig");

const driver = glowcap.driver;
const Host = driver.core.Host;

const frame_cap = 4096;

const Held = struct {
    /// What `inboundResumable` answered.
    resumable: bool,
    /// Whether `resumeFeed` consumed tail bytes or refused them.
    moved: bool,
};

/// Hold `bytes` in a fresh session's tail, ask the question, then resume.
fn hold(bytes: []const u8) !Held {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x31)), Host.Options.init(.unchecked, frame_cap));
    defer host.deinit();
    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7171",
        .hints = glowcap.ocapn.model.Hints.emptyFalse(),
    });
    try session.feed_tail.absorbBytes(allocator, bytes);
    const resumable = session.inboundResumable();
    var refusal: ?anyerror = null;
    session.resumeFeed() catch |err| {
        refusal = err;
    };
    return .{ .resumable = resumable, .moved = refusal != null or session.feed_tail.len != bytes.len };
}

test "a tail is resumable exactly when a resume consumes or refuses its front" {
    const cases = [_]struct { bytes: []const u8, resumable: bool }{
        .{ .bytes = "", .resumable = false },
        // The front of a frame whose rest has not arrived.
        .{ .bytes = "3", .resumable = false },
        .{ .bytes = "3:", .resumable = false },
        .{ .bytes = "3:ab", .resumable = false },
        // A whole frame, alone and ahead of a partial one.
        .{ .bytes = "3:abc", .resumable = true },
        .{ .bytes = "3:abc4:de", .resumable = true },
        // A malformed prefix, an overflowing length, and an oversize frame.
        .{ .bytes = "x", .resumable = true },
        .{ .bytes = "03:abc", .resumable = true },
        .{ .bytes = "99999999999999999999:", .resumable = true },
        .{ .bytes = "4097:", .resumable = true },
    };
    for (cases) |case| {
        const held = try hold(case.bytes);
        errdefer std.debug.print("tail {s}\n", .{case.bytes});
        try std.testing.expectEqual(case.resumable, held.resumable);
        try std.testing.expectEqual(held.resumable, held.moved);
    }
}

test "a sealed session is resumable for a whole staged record and not for part of one" {
    const allocator = std.testing.allocator;
    const seed_a: [32]u8 = @splat(0x41);
    const seed_b: [32]u8 = @splat(0x42);
    var a = sealed_pair.sealedHost(allocator, seed_a, 0x43, Host.Options.init(.unchecked, frame_cap));
    defer a.deinit();
    var b = sealed_pair.sealedHost(allocator, seed_b, 0x44, Host.Options.init(.unchecked, frame_cap));
    defer b.deinit();
    const pair = try sealed_pair.openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, "one record");
    const record_len = wire.items.len;
    try pair.a.sealed.?.sealBytes(allocator, &wire, "another record");

    const channel = pair.b.sealed.?;
    try std.testing.expect(!pair.b.inboundResumable());
    // Every cut inside the first record leaves only its front.
    for (1..record_len) |cut| {
        try channel.park(allocator, wire.items[0..cut]);
        try std.testing.expect(!pair.b.inboundResumable());
        channel.staged.truncate(0);
    }
    try channel.park(allocator, wire.items[0..record_len]);
    try std.testing.expect(pair.b.inboundResumable());
    channel.staged.truncate(0);
    try channel.park(allocator, wire.items[0 .. record_len + 3]);
    try std.testing.expect(pair.b.inboundResumable());
    channel.staged.truncate(0);
    try std.testing.expect(!pair.b.inboundResumable());
}
