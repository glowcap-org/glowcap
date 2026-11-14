//! What a byte-fed Host session keeps in `feed_tail`: the front of one
//! incomplete frame, or every byte behind the opening hello. These tests feed
//! fetch streams in chunks that cut frames at every kind of position and hold
//! the tail, the dispatch order, and the retry contract of a refused chunk.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;

const driver = glowcap.driver;
const stream_framing = glowcap.foundation.stream_framing;

const Host = driver.core.Host;
const harness = @import("harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const ParkedDial = harness.ParkedDial;
const Pair = harness.Pair;

/// Frames the server queues in answer to one fetch of a published name.
const frames_per_fetch = 2;

/// A client and a server host with one open session, and the server's replies.
const Rig = struct {
    client: Host,
    server: Host,
    dials: std.ArrayList(ParkedDial) = .empty,
    pair: Pair,
    allocator: std.mem.Allocator,

    fn init(rig: *Rig, client_allocator: std.mem.Allocator, server_allocator: std.mem.Allocator) !void {
        rig.allocator = client_allocator;
        rig.dials = .empty;
        rig.client = test_host.init(client_allocator, @as([32]u8, @splat(0x71)), Host.Options.init(.unchecked, frame_cap));
        rig.server = test_host.init(server_allocator, @as([32]u8, @splat(0x72)), Host.Options.init(.unchecked, frame_cap));
        rig.pair = try harness.openPair(client_allocator, &rig.client, &rig.server, "127.0.0.1:7171", &rig.dials);
        _ = try rig.pair.b.served.publish(&rig.server.vat, "widget", Widget, .{});
    }

    /// A client and a server with a dialed and an accepted session whose
    /// hellos have not crossed.
    fn initUnopened(rig: *Rig, allocator: std.mem.Allocator) !void {
        rig.allocator = allocator;
        rig.dials = .empty;
        rig.client = test_host.init(allocator, @as([32]u8, @splat(0x71)), Host.Options.init(.unchecked, frame_cap));
        rig.server = test_host.init(allocator, @as([32]u8, @splat(0x72)), Host.Options.init(.unchecked, frame_cap));
        try rig.client.ensureAdvertisedLocator("tcp");
        try rig.server.setAdvertisedLocator(harness.tcpLocator("127.0.0.1:7171"));
        const accepted = try rig.server.openAcceptedAdvertised("tcp");
        const dialed = try rig.client.openDialedLocator(harness.tcpLocator("127.0.0.1:7171"));
        rig.pair = .{ .ah = &rig.client, .a = dialed, .bh = &rig.server, .b = accepted };
    }

    fn deinit(rig: *Rig) void {
        rig.dials.deinit(rig.allocator);
        rig.server.deinit();
        rig.client.deinit();
    }

    /// One outer-framed fetch of `name`, appended to `stream`. Returns the
    /// length of the whole frame, prefix included.
    fn appendFetch(rig: *Rig, stream: *std.ArrayList(u8), name: []const u8) !usize {
        _ = try rig.client.fetch(rig.pair.a, name);
        var frame = (try rig.pair.a.takeOutbound()) orelse return error.MissingFetch;
        defer frame.deinit();
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        const prefix = stream_framing.renderPrefix(&prefix_buf, frame.bytes().len);
        try stream.appendSlice(rig.allocator, prefix);
        try stream.appendSlice(rig.allocator, frame.bytes());
        return prefix.len + frame.bytes().len;
    }

    /// Append every frame the server queued onto `sink`, and count them.
    fn takeReplies(rig: *Rig, sink: ?*std.ArrayList(u8)) !usize {
        var count: usize = 0;
        while (try rig.pair.b.takeOutbound()) |frame_value| {
            var frame = frame_value;
            defer frame.deinit();
            if (sink) |s| try s.appendSlice(rig.allocator, frame.bytes());
            count += 1;
        }
        return count;
    }
};

/// A fresh rig, a stream of `count` fetches fed in `chunk_len` pieces, and the
/// replies it drew. After every call the tail holds less than one frame.
fn replies(allocator: std.mem.Allocator, count: usize, chunk_len: usize, sink: *std.ArrayList(u8)) !void {
    var rig: Rig = undefined;
    try rig.init(allocator, allocator);
    defer rig.deinit();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    var max_frame: usize = 0;
    for (0..count) |_| max_frame = @max(max_frame, try rig.appendFetch(&stream, "widget"));
    // 0 feeds the whole stream in one call.
    const step = if (chunk_len == 0) stream.items.len else chunk_len;
    var offset: usize = 0;
    while (offset < stream.items.len) {
        const end = @min(offset + step, stream.items.len);
        try rig.server.feedBytes(rig.pair.b, stream.items[offset..end]);
        offset = end;
        try std.testing.expect(rig.pair.b.feed_tail.len < max_frame);
        // A chunk wider than two frames does not grow the tail to its width.
        if (chunk_len > 2 * max_frame) try std.testing.expect(rig.pair.b.feed_tail.buf.len <= 2 * max_frame);
    }
    try std.testing.expectEqual(@as(usize, 0), rig.pair.b.feed_tail.len);
    try std.testing.expectEqual(frames_per_fetch * count, try rig.takeReplies(sink));
}

test "feedBytes: chunks that never land on a frame boundary keep the tail under one frame" {
    const allocator = std.testing.allocator;
    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try replies(allocator, 10, 0, &whole);
    try std.testing.expect(whole.items.len > 0);

    // The fetch frames are a few dozen bytes, so these widths run from far
    // under a frame to several frames, none aligned with a boundary.
    for ([_]usize{ 1, 7, 23, 61, 97, 301, 509 }) |chunk_len| {
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(allocator);
        try replies(allocator, 10, chunk_len, &got);
        try std.testing.expectEqualSlices(u8, whole.items, got.items);
    }
}

test "feedBytes: a stream cut in two at any offset dispatches what the whole stream does" {
    const allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(allocator, allocator);
    defer rig.deinit();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    for (0..3) |_| _ = try rig.appendFetch(&stream, "widget");

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try replies(allocator, 3, 0, &whole);

    for (1..stream.items.len) |cut| {
        var fresh: Rig = undefined;
        try fresh.init(allocator, allocator);
        defer fresh.deinit();
        var again: std.ArrayList(u8) = .empty;
        defer again.deinit(allocator);
        for (0..3) |_| _ = try fresh.appendFetch(&again, "widget");
        try std.testing.expectEqualSlices(u8, stream.items, again.items);

        try fresh.server.feedBytes(fresh.pair.b, again.items[0..cut]);
        try fresh.server.feedBytes(fresh.pair.b, again.items[cut..]);
        try std.testing.expectEqual(@as(usize, 0), fresh.pair.b.feed_tail.len);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(allocator);
        try std.testing.expectEqual(3 * frames_per_fetch, try fresh.takeReplies(&got));
        try std.testing.expectEqualSlices(u8, whole.items, got.items);
    }
}

test "feedBytes: a refused completion leaves the pending frame so the same chunk retries once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(allocator, failing.allocator());
    defer rig.deinit();

    // Warm the tail: one frame wider than the ones under test arrives in two
    // pieces, so the tail's capacity already holds everything the refused
    // call would append and only the frame's own copy can fail.
    var warm: std.ArrayList(u8) = .empty;
    defer warm.deinit(allocator);
    const long_name = try allocator.alloc(u8, 900);
    defer allocator.free(long_name);
    @memset(long_name, 'n');
    _ = try rig.appendFetch(&warm, long_name);
    try rig.server.feedBytes(rig.pair.b, warm.items[0 .. warm.items.len / 2]);
    try rig.server.feedBytes(rig.pair.b, warm.items[warm.items.len / 2 ..]);
    try std.testing.expectEqual(@as(usize, frames_per_fetch), try rig.takeReplies(null));

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    const first_len = try rig.appendFetch(&stream, "widget");
    _ = try rig.appendFetch(&stream, "widget");
    const cut = first_len / 2;
    try rig.server.feedBytes(rig.pair.b, stream.items[0..cut]);
    try std.testing.expectEqual(cut, rig.pair.b.feed_tail.len);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, rig.server.feedBytes(rig.pair.b, stream.items[cut..]));
    failing.fail_index = std.math.maxInt(usize);
    // The refusal came from the injected failure, not from anything else.
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(cut, rig.pair.b.feed_tail.len);
    try std.testing.expectEqual(@as(usize, 0), try rig.takeReplies(null));

    try rig.server.feedBytes(rig.pair.b, stream.items[cut..]);
    try std.testing.expectEqual(@as(usize, 0), rig.pair.b.feed_tail.len);
    try std.testing.expectEqual(@as(usize, 2 * frames_per_fetch), try rig.takeReplies(null));
}

/// Everything the server queued, including what a parked tail resumes into.
/// A verb that fails here has closed the session, which the caller treats as
/// an accepted outcome.
fn drainAll(rig: *Rig, saw_retention_abort: ?*bool) usize {
    var count: usize = 0;
    while (rig.pair.b.takeStreamOutbound() catch return count) |outbound| {
        var payload = outbound.payload;
        defer payload.deinit();
        // The condemnation queues an `op:abort` frame carrying its message.
        if (saw_retention_abort) |seen| {
            if (std.mem.find(u8, payload.bytes(), retention_abort_message) != null) seen.* = true;
        }
        count += 1;
    }
    return count;
}

/// The verdict message the host sends when a stream suffix cannot be retained.
const retention_abort_message = "stream input could not be retained under memory pressure";

test "feedBytes: a lasting shortage at any allocation retries exactly or retires the session" {
    try sweepRefusals(false);
}

test "feedBytes: one refused allocation at any site retries exactly or retires the session" {
    try sweepRefusals(true);
}

/// Refuse the k-th allocation of the server from the second chunk on, for every
/// k. `once` refuses that one allocation and serves the rest, so a retiring
/// session can still encode its verdict. Otherwise every allocation from k on
/// is refused, and the verdict cannot be encoded.
fn sweepRefusals(comptime once: bool) !void {
    const Failing = if (once) FailingOnce else std.testing.FailingAllocator;
    const allocator = std.testing.allocator;
    const expected = 3 * frames_per_fetch;
    var retired_after_dispatch: usize = 0;
    var open_retries: usize = 0;
    var retention_aborts: usize = 0;
    var k: usize = 0;
    while (k < 400) : (k += 1) {
        // In-place growth is refused so every growth is one counted allocation.
        var failing = if (once)
            Failing.init(allocator, std.math.maxInt(usize))
        else
            Failing.init(allocator, .{ .resize_fail_index = 0 });
        var rig: Rig = undefined;
        try rig.init(allocator, failing.allocator());
        defer rig.deinit();

        // The third frame carries a long name so its unread suffix is larger
        // than the capacity the tail retained for the first.
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(allocator);
        const long_name = try allocator.alloc(u8, 900);
        defer allocator.free(long_name);
        @memset(long_name, 'n');
        const first_len = try rig.appendFetch(&stream, "widget");
        _ = try rig.appendFetch(&stream, "widget");
        _ = try rig.appendFetch(&stream, long_name);
        const cut = first_len / 2;
        const final_piece = 5;
        const rest = stream.items[cut .. stream.items.len - final_piece];

        try rig.server.feedBytes(rig.pair.b, stream.items[0..cut]);
        try std.testing.expectEqual(cut, rig.pair.b.feed_tail.len);

        failing.fail_index = failing.alloc_index + k;
        const result = rig.server.feedBytes(rig.pair.b, rest);
        failing.fail_index = std.math.maxInt(usize);
        const injected = if (once) failing.induced else failing.has_induced_failure;

        const session = rig.pair.b;
        const open = !session.sessionClosed() and !session.isTerminating();
        if (result) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);

        var total: usize = undefined;
        if (!open) {
            // Retired: an accepted outcome. Count how many replies it kept.
            var retention_abort = false;
            total = drainAll(&rig, &retention_abort);
            if (!std.meta.isError(result) and total > 0) retired_after_dispatch += 1;
            if (!std.meta.isError(result) and retention_abort) retention_aborts += 1;
        } else if (std.meta.isError(result)) {
            // A retryable refusal committed nothing, so the same bytes feed again.
            open_retries += 1;
            try std.testing.expectEqual(cut, session.feed_tail.len);
            try rig.server.feedBytes(session, rest);
            try rig.server.feedBytes(session, stream.items[stream.items.len - final_piece ..]);
            total = drainAll(&rig, null);
            try std.testing.expectEqual(expected, total);
        } else {
            try rig.server.feedBytes(session, stream.items[stream.items.len - final_piece ..]);
            total = drainAll(&rig, null);
            try std.testing.expectEqual(expected, total);
        }
        try std.testing.expect(total <= expected);
        if (!injected) break;
    } else return error.SweepDidNotEnd;
    // The sweep reached a refusal before any frame dispatched and one after.
    try std.testing.expect(open_retries > 0);
    try std.testing.expect(retired_after_dispatch > 0);
    // The retirement came from the retention path, not from another failure.
    if (once) try std.testing.expect(retention_aborts > 0);
}

test "feedBytes: frames behind the opening hello wait in the tail until the session resumes them" {
    const allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.initUnopened(allocator);
    defer rig.deinit();

    // The client's hello, outer-framed, then the client opens on the server's.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    {
        var hello = (try rig.pair.a.takeOutbound()) orelse return error.MissingHello;
        defer hello.deinit();
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        try stream.appendSlice(allocator, stream_framing.renderPrefix(&prefix_buf, hello.bytes().len));
        try stream.appendSlice(allocator, hello.bytes());
    }
    const hello_len = stream.items.len;
    {
        var server_hello = (try rig.pair.b.takeOutbound()) orelse return error.MissingHello;
        defer server_hello.deinit();
        try rig.client.feed(rig.pair.a, server_hello.view());
    }
    try std.testing.expect(rig.pair.a.sessionOpen());
    _ = try rig.pair.b.served.publish(&rig.server.vat, "widget", Widget, .{});
    _ = try rig.appendFetch(&stream, "widget");
    _ = try rig.appendFetch(&stream, "widget");

    const cut = hello_len / 2;
    try rig.server.feedBytes(rig.pair.b, stream.items[0..cut]);
    try std.testing.expect(!rig.pair.b.sessionOpen());
    try std.testing.expectEqual(cut, rig.pair.b.feed_tail.len);

    try rig.server.feedBytes(rig.pair.b, stream.items[cut..]);
    try std.testing.expect(rig.pair.b.sessionOpen());
    // The pause at the opening hello keeps every byte behind it.
    try std.testing.expectEqual(stream.items.len - hello_len, rig.pair.b.feed_tail.len);
    try std.testing.expectEqual(@as(usize, 0), try rig.takeReplies(null));

    try rig.server.feedBytes(rig.pair.b, &.{});
    try std.testing.expectEqual(@as(usize, 0), rig.pair.b.feed_tail.len);
    try std.testing.expectEqual(2 * frames_per_fetch, try rig.takeReplies(null));
}
