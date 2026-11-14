//! The byte-stream prefix around a frame: its rendered form at every width.

const std = @import("std");
const glowcap = @import("glowcap");

const stream_framing = glowcap.foundation.stream_framing;

test "a rendered prefix is the canonical decimal and colon at every width" {
    // The prefix is written digit by digit from the frame's length. Every
    // width from one digit to the widest a usize takes, and both sides of
    // each power of ten, must match the formatted form, since a prefix one
    // digit off desynchronizes the whole stream after it.
    var buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    var want_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    var power: usize = 1;
    while (true) {
        for ([_]usize{ power - 1, power, power + 1 }) |length| {
            const want = try std.mem.print(&want_buf, "{d}:", .{length});
            try std.testing.expectEqualStrings(want, stream_framing.renderPrefix(&buf, length));
        }
        power = std.math.mul(usize, power, 10) catch break;
    }
    const widest = try std.mem.print(&want_buf, "{d}:", .{std.math.maxInt(usize)});
    try std.testing.expectEqualStrings(widest, stream_framing.renderPrefix(&buf, std.math.maxInt(usize)));
    // A rendered prefix parses back to the length it was rendered from.
    const body = "abc";
    const prefix = stream_framing.renderPrefix(&buf, body.len);
    var framed: [8]u8 = undefined;
    @memcpy(framed[0..prefix.len], prefix);
    @memcpy(framed[prefix.len..][0..body.len], body);
    const parsed = stream_framing.parsePrefix(framed[0 .. prefix.len + body.len], 64);
    try std.testing.expectEqualStrings(body, parsed.decoded.body);
}

const Spill = glowcap.foundation.Spill;
const frame = "11:hello world";

test "a frame cut at every offset completes from the chunk that carries its rest" {
    const allocator = std.testing.allocator;
    const behind = frame ++ "3:abc";
    for (1..frame.len) |cut| {
        var spill: Spill = .{};
        defer spill.deinit(allocator);
        try spill.absorbBytes(allocator, frame[0..cut]);
        const done = try stream_framing.completeFirstFrame(&spill, allocator, behind[cut..], 64);
        // Exactly the frame's missing bytes are taken, never the frame behind.
        const prefix_len = 3;
        try std.testing.expectEqualStrings("hello world", done.frame.body);
        try std.testing.expectEqual(frame.len - cut, done.frame.used);
        if (cut <= prefix_len) {
            // The spill ends at the prefix: its missing digits are absorbed and
            // the body is lent from the chunk.
            try std.testing.expect(done.frame.body.ptr == behind[prefix_len..].ptr);
            try std.testing.expectEqualStrings("11:", spill.bytes());
        } else {
            try std.testing.expect(done.frame.body.ptr == spill.bytes()[prefix_len..].ptr);
            try std.testing.expectEqualStrings(frame, spill.bytes());
        }
    }
}

test "a prefix split across chunks completes one byte at a time" {
    const allocator = std.testing.allocator;
    const wide = "123:".* ++ @as([123]u8, @splat('x'));
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "1");
    // "2" arrives alone, then the colon and the body.
    try std.testing.expectEqual(stream_framing.Completed.waiting, try stream_framing.completeFirstFrame(&spill, allocator, "2", 4096));
    try std.testing.expectEqualStrings("12", spill.bytes());
    const done = try stream_framing.completeFirstFrame(&spill, allocator, wide[2..], 4096);
    // The digit and the colon absorbed, then the 123 body bytes lent.
    try std.testing.expectEqual(@as(usize, 2 + 123), done.frame.used);
    try std.testing.expectEqual(@as(usize, 123), done.frame.body.len);
    try std.testing.expectEqualStrings("123:", spill.bytes());
}

test "an empty frame whose colon arrives late completes with the bytes it took counted" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "0");
    const done = try stream_framing.completeFirstFrame(&spill, allocator, ":3:abc", 64);
    try std.testing.expectEqual(@as(usize, 0), done.frame.body.len);
    try std.testing.expectEqual(@as(usize, 1), done.frame.used);
}

test "a chunk that ends before the frame does is absorbed whole" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "11:he");
    try std.testing.expectEqual(stream_framing.Completed.waiting, try stream_framing.completeFirstFrame(&spill, allocator, "llo", 64));
    try std.testing.expectEqualStrings("11:hello", spill.bytes());
    // A prefix-only spill with a short chunk absorbs the chunk too.
    var bare: Spill = .{};
    defer bare.deinit(allocator);
    try bare.absorbBytes(allocator, "11:");
    try std.testing.expectEqual(stream_framing.Completed.waiting, try stream_framing.completeFirstFrame(&bare, allocator, "hel", 64));
    try std.testing.expectEqualStrings("11:hel", bare.bytes());
}

test "a malformed, oversize, or whole waiting frame is left to the caller's parse" {
    const allocator = std.testing.allocator;
    const Case = struct { held: []const u8, rest: []const u8 };
    // A non-digit, an over-cap length, and a leading zero.
    for ([_]Case{ .{ .held = "1", .rest = "x:abc" }, .{ .held = "6", .rest = "5:abc" }, .{ .held = "0", .rest = "5:abc" } }) |c| {
        var spill: Spill = .{};
        defer spill.deinit(allocator);
        try spill.absorbBytes(allocator, c.held);
        // The one byte that exposed the refusal is in the spill and counted.
        try std.testing.expectEqual(stream_framing.Completed{ .parse = 1 }, try stream_framing.completeFirstFrame(&spill, allocator, c.rest, 64));
        try std.testing.expectEqual(@as(usize, 2), spill.len);
    }
    // A whole frame on entry is not read past, and nothing is absorbed.
    var whole: Spill = .{};
    defer whole.deinit(allocator);
    try whole.absorbBytes(allocator, "3:abc2:");
    try std.testing.expectEqual(stream_framing.Completed{ .parse = 0 }, try stream_framing.completeFirstFrame(&whole, allocator, "de", 64));
    try std.testing.expectEqualStrings("3:abc2:", whole.bytes());
}

test "a refused absorb leaves the spill as it was on entry" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "11:he");
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, stream_framing.completeFirstFrame(&spill, failing.allocator(), "llo world", 64));
    try std.testing.expectEqualStrings("11:he", spill.bytes());
}

test "a refusal after the prefix bytes were absorbed rolls the spill back to its entry" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "1");
    // The prefix reservation is the first allocation and succeeds. The body
    // then needs more room than the reservation and its growth is refused.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const chunk = "00:".* ++ @as([30]u8, @splat('x'));
    try std.testing.expectError(error.OutOfMemory, stream_framing.completeFirstFrame(&spill, failing.allocator(), &chunk, 4096));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualStrings("1", spill.bytes());
}

test "a frame completed by one chunk grows the spill exactly" {
    const allocator = std.testing.allocator;
    var spill: Spill = .{};
    defer spill.deinit(allocator);
    try spill.absorbBytes(allocator, "11:he");
    var counting = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const done = try stream_framing.completeFirstFrame(&spill, counting.allocator(), "llo world", 64);
    try std.testing.expectEqualStrings("hello world", done.frame.body);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(frame.len, spill.buf.len);
}
