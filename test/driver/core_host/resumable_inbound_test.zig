//! `HostSession.inboundResumable`: whether the session holds input whole
//! enough for `resumeFeed` to move. It is true exactly when a resume
//! dispatches or refuses something, and false for the front of a frame whose
//! rest the transport has yet to deliver. It disregards the waterline: while
//! the session is pressured (`outboundPressured`) it stays true and a resume
//! refuses `OutboundBackpressure` before moving anything.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const sealed_pair = @import("../../support/sealed_pair.zig");
const harness = @import("harness.zig");

const driver = glowcap.driver;
const Host = driver.core.Host;
const stream_framing = glowcap.foundation.stream_framing;

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

/// An open pair whose acceptor holds one whole fetch frame in its tail and
/// has queued outbound past a one-byte waterline.
const PressuredPair = struct {
    client: Host,
    server: Host,
    dials: std.ArrayList(harness.ParkedDial) = .empty,
    pair: harness.Pair = undefined,

    fn open(self: *PressuredPair, allocator: std.mem.Allocator) !void {
        self.client = test_host.init(allocator, @as([32]u8, @splat(0x51)), Host.Options.init(.unchecked, frame_cap));
        errdefer self.client.deinit();
        self.server = test_host.init(allocator, @as([32]u8, @splat(0x52)), Host.Options.init(.unchecked, frame_cap));
        errdefer self.server.deinit();
        errdefer self.dials.deinit(allocator);
        self.pair = try harness.openPair(allocator, &self.client, &self.server, "127.0.0.1:7172", &self.dials);
        // The acceptor's own fetch leaves a frame queued, and a waterline of
        // one byte puts it at the line.
        _ = try self.server.fetch(self.pair.b, "nothing");
        self.pair.b.outbound_high_water_bytes = 1;
        try std.testing.expect(self.pair.b.outboundPressured());
        // The dialer's fetch is the whole frame the acceptor holds.
        _ = try self.client.fetch(self.pair.a, "nothing");
        var frame = (try self.pair.a.takeOutbound()) orelse return error.NoFrame;
        defer frame.deinit();
        var prefix: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        try self.pair.b.feed_tail.absorbBytes(allocator, stream_framing.renderPrefix(&prefix, frame.bytes().len));
        try self.pair.b.feed_tail.absorbBytes(allocator, frame.bytes());
    }

    fn deinit(self: *PressuredPair, allocator: std.mem.Allocator) void {
        self.dials.deinit(allocator);
        self.server.deinit();
        self.client.deinit();
    }

    /// Take every queued outbound frame and lift the waterline.
    fn drain(self: *PressuredPair) !void {
        while (try self.pair.b.takeOutbound()) |frame| {
            var owned = frame;
            owned.deinit();
        }
        self.pair.b.outbound_high_water_bytes = 1 << 20;
    }
};

test "a pressured session holds a whole frame in its tail and resumes it once the outbound drains" {
    const allocator = std.testing.allocator;
    var held: PressuredPair = .{ .client = undefined, .server = undefined };
    try held.open(allocator);
    defer held.deinit(allocator);
    const session = held.pair.b;
    const tail = session.feed_tail.len;
    const queued = session.served.queuedOutboundBytes();
    try std.testing.expect(tail != 0);

    try std.testing.expect(session.inboundResumable());
    try std.testing.expect(session.outboundPressured());
    try std.testing.expectError(error.OutboundBackpressure, session.resumeFeed());
    try std.testing.expectEqual(tail, session.feed_tail.len);
    try std.testing.expectEqual(queued, session.served.queuedOutboundBytes());
    try std.testing.expect(session.sessionOpen());

    try held.drain();
    try std.testing.expect(session.inboundResumable());
    try std.testing.expect(!session.outboundPressured());
    try session.resumeFeed();
    try std.testing.expectEqual(@as(usize, 0), session.feed_tail.len);
}

test "a pressured session with nothing held resumes as a no-op" {
    const allocator = std.testing.allocator;
    var held: PressuredPair = .{ .client = undefined, .server = undefined };
    try held.open(allocator);
    defer held.deinit(allocator);
    held.pair.b.feed_tail.truncate(0);
    try std.testing.expect(!held.pair.b.inboundResumable());
    try held.pair.b.resumeFeed();
}

test "a pressured session holding only part of a frame resumes as a no-op that moves nothing" {
    const allocator = std.testing.allocator;
    var held: PressuredPair = .{ .client = undefined, .server = undefined };
    try held.open(allocator);
    defer held.deinit(allocator);
    const session = held.pair.b;
    session.feed_tail.truncate(0);
    var prefix: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    try session.feed_tail.absorbBytes(allocator, stream_framing.renderPrefix(&prefix, 64));
    const tail = session.feed_tail.len;
    const queued = session.served.queuedOutboundBytes();
    try std.testing.expect(session.outboundPressured());
    try std.testing.expect(!session.inboundResumable());
    try session.resumeFeed();
    try std.testing.expectEqual(tail, session.feed_tail.len);
    try std.testing.expectEqual(queued, session.served.queuedOutboundBytes());
}

test "a pressured sealed session holds a staged record until the outbound drains and then dispatches it" {
    const allocator = std.testing.allocator;
    const seed_a: [32]u8 = @splat(0x41);
    const seed_b: [32]u8 = @splat(0x42);
    var a = sealed_pair.sealedHost(allocator, seed_a, 0x43, Host.Options.init(.unchecked, frame_cap));
    defer a.deinit();
    var b = sealed_pair.sealedHost(allocator, seed_b, 0x44, Host.Options.init(.unchecked, frame_cap));
    defer b.deinit();
    const pair = try sealed_pair.openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    // The record carries one whole fetch frame, cut from a plain pair, which
    // has the same bytes once open.
    var plain: PressuredPair = .{ .client = undefined, .server = undefined };
    try plain.open(allocator);
    defer plain.deinit(allocator);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, plain.pair.b.feed_tail.bytes());
    const channel = pair.b.sealed.?;
    try channel.park(allocator, wire.items);
    try std.testing.expect(pair.b.inboundResumable());

    _ = try b.fetch(pair.b, "nothing");
    pair.b.outbound_high_water_bytes = 1;
    try std.testing.expect(pair.b.outboundPressured());
    try std.testing.expect(pair.b.inboundResumable());
    try std.testing.expectError(error.OutboundBackpressure, pair.b.resumeFeed());
    try std.testing.expect(channel.hasStagedInbound());

    while (try pair.b.takeOutbound()) |frame| {
        var owned = frame;
        owned.deinit();
    }
    pair.b.outbound_high_water_bytes = 1 << 20;
    try std.testing.expect(!pair.b.outboundPressured());
    try std.testing.expect(pair.b.inboundResumable());
    try std.testing.expectEqual(@as(usize, 0), pair.b.served.queuedOutboundBytes());

    // The resume dispatches the fetch, whose answer is queued outbound.
    try pair.b.resumeFeed();
    try std.testing.expect(!channel.hasStagedInbound());
    try std.testing.expect(pair.b.served.queuedOutboundBytes() != 0);
}

test "a sealed session whose tail resume reaches the waterline succeeds and holds its staged record" {
    const allocator = std.testing.allocator;
    const seed_a: [32]u8 = @splat(0x45);
    const seed_b: [32]u8 = @splat(0x46);
    var a = sealed_pair.sealedHost(allocator, seed_a, 0x47, Host.Options.init(.unchecked, frame_cap));
    defer a.deinit();
    var b = sealed_pair.sealedHost(allocator, seed_b, 0x48, Host.Options.init(.unchecked, frame_cap));
    defer b.deinit();
    const pair = try sealed_pair.openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    // The acceptor holds one whole fetch frame in its tail and one staged
    // record behind it. Answering the fetch brings its outbound to the
    // one-byte waterline, which it was below on entry.
    // The frame is a plain pair's fetch, which has the same bytes once open.
    var plain: PressuredPair = .{ .client = undefined, .server = undefined };
    try plain.open(allocator);
    defer plain.deinit(allocator);
    try pair.b.feed_tail.absorbBytes(allocator, plain.pair.b.feed_tail.bytes());
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, "one record");
    const channel = pair.b.sealed.?;
    try channel.park(allocator, wire.items);
    pair.b.outbound_high_water_bytes = 1;
    try std.testing.expect(!pair.b.outboundPressured());
    try std.testing.expect(pair.b.inboundResumable());

    try pair.b.resumeFeed();
    try std.testing.expect(pair.b.outboundPressured());
    try std.testing.expect(channel.hasStagedInbound());
    try std.testing.expect(pair.b.inboundResumable());
    try std.testing.expectError(error.OutboundBackpressure, pair.b.resumeFeed());
}

test "a pressured sealed session holding only part of a staged record resumes as a no-op" {
    const allocator = std.testing.allocator;
    const seed_a: [32]u8 = @splat(0x49);
    const seed_b: [32]u8 = @splat(0x4a);
    var a = sealed_pair.sealedHost(allocator, seed_a, 0x4b, Host.Options.init(.unchecked, frame_cap));
    defer a.deinit();
    var b = sealed_pair.sealedHost(allocator, seed_b, 0x4c, Host.Options.init(.unchecked, frame_cap));
    defer b.deinit();
    const pair = try sealed_pair.openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, "one record");
    const channel = pair.b.sealed.?;
    try channel.park(allocator, wire.items[0 .. wire.items.len - 1]);
    try std.testing.expect(channel.hasStagedInbound());
    try std.testing.expect(!pair.b.inboundResumable());
    _ = try b.fetch(pair.b, "nothing");
    pair.b.outbound_high_water_bytes = 1;
    try std.testing.expect(pair.b.outboundPressured());

    // Nothing resumable is held, so the entry check passes. Feeding the
    // partial record would refuse as backpressure, so the call must not.
    const staged = channel.staged.len;
    try pair.b.resumeFeed();
    try std.testing.expectEqual(staged, channel.staged.len);
}

test "a sealed session whose staged feed reaches the waterline leaves the whole frames in its tail for the next call to refuse" {
    const allocator = std.testing.allocator;
    const seed_a: [32]u8 = @splat(0x4d);
    const seed_b: [32]u8 = @splat(0x4e);
    var a = sealed_pair.sealedHost(allocator, seed_a, 0x4f, Host.Options.init(.unchecked, frame_cap));
    defer a.deinit();
    var b = sealed_pair.sealedHost(allocator, seed_b, 0x50, Host.Options.init(.unchecked, frame_cap));
    defer b.deinit();
    const pair = try sealed_pair.openSealedPair(allocator, &a, seed_a, &b, seed_b, null, null);

    // Two whole fetch frames from a plain pair, which have the same bytes
    // once open, ride one sealed record.
    var plain: PressuredPair = .{ .client = undefined, .server = undefined };
    try plain.open(allocator);
    defer plain.deinit(allocator);
    var plaintext: std.ArrayList(u8) = .empty;
    defer plaintext.deinit(allocator);
    try plaintext.appendSlice(allocator, plain.pair.b.feed_tail.bytes());
    _ = try plain.client.fetch(plain.pair.a, "nothing");
    var frame = (try plain.pair.a.takeOutbound()) orelse return error.NoFrame;
    defer frame.deinit();
    var prefix: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    try plaintext.appendSlice(allocator, stream_framing.renderPrefix(&prefix, frame.bytes().len));
    try plaintext.appendSlice(allocator, frame.bytes());

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try pair.a.sealed.?.sealBytes(allocator, &wire, plaintext.items);
    const channel = pair.b.sealed.?;
    try channel.park(allocator, wire.items);
    pair.b.outbound_high_water_bytes = 1;
    try std.testing.expect(!pair.b.outboundPressured());
    try std.testing.expectEqual(@as(usize, 0), pair.b.feed_tail.len);

    // The record's first frame answers into the waterline, so the second
    // waits in the tail, and this call does not resume it.
    try pair.b.resumeFeed();
    try std.testing.expect(pair.b.outboundPressured());
    try std.testing.expect(!channel.hasStagedInbound());
    const tail = pair.b.feed_tail.len;
    try std.testing.expect(tail != 0);
    try std.testing.expectError(error.OutboundBackpressure, pair.b.resumeFeed());
    try std.testing.expectEqual(tail, pair.b.feed_tail.len);
}
