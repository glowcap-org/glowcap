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

fn expectPartition(comptime prefix: []const u8, comptime body: []const u8, cuts: usize) !void {
    const allocator = std.testing.allocator;
    const input = prefix ++ body ++ "3:abc";
    const boundary = prefix.len + body.len;
    if (cuts == 0) {
        const result = stream_framing.parsePrefix(input, body.len);
        try std.testing.expectEqual(.decoded, std.meta.activeTag(result));
        try std.testing.expectEqualStrings(body, result.decoded.body);
        try std.testing.expectEqual(boundary, result.decoded.consumed);
        try std.testing.expect(result.decoded.body.ptr == input[prefix.len..].ptr);
        return;
    }
    var spill: Spill = .{};
    defer spill.deinit(allocator);

    var start: usize = 0;
    var pending_cuts = cuts;
    for (1..boundary + 1) |end| {
        const cut = pending_cuts & 1 != 0;
        pending_cuts >>= 1;
        if (!cut and end != boundary) continue;
        if (end != boundary) {
            const chunk = input[start..end];
            if (start == 0) {
                try std.testing.expectEqual(.incomplete, std.meta.activeTag(stream_framing.parsePrefix(chunk, body.len)));
                try spill.absorbBytes(allocator, chunk);
            } else {
                try std.testing.expectEqual(.waiting, try stream_framing.completeFirstFrame(&spill, allocator, chunk, body.len));
            }
            try std.testing.expectEqual(.waiting, try stream_framing.completeFirstFrame(&spill, allocator, "", body.len));
            try std.testing.expectEqualStrings(input[0..end], spill.bytes());
            start = end;
            continue;
        }

        const result = try stream_framing.completeFirstFrame(&spill, allocator, input[start..], body.len);
        try std.testing.expectEqual(.frame, std.meta.activeTag(result));
        try std.testing.expectEqualStrings(body, result.frame.body);
        try std.testing.expectEqual(boundary - start, result.frame.used);
        if (start <= prefix.len) {
            try std.testing.expect(result.frame.body.ptr == input[prefix.len..].ptr);
            try std.testing.expectEqualStrings(prefix, spill.bytes());
        } else {
            try std.testing.expect(result.frame.body.ptr == spill.bytes()[prefix.len..].ptr);
            try std.testing.expectEqualStrings(input[0..boundary], spill.bytes());
        }
    }
}

test "stream partitions preserve the body boundary and borrowing" {
    inline for (.{ .{ "0:", "" }, .{ "3:", "abc" }, .{ "11:", "hello world" } }) |sample| {
        const gaps = sample[0].len + sample[1].len - 1;
        for (0..1 << gaps) |cuts| try expectPartition(sample[0], sample[1], cuts);
    }
    const wide: [123]u8 = @splat('x');
    try expectPartition("123:", &wide, 0b11);
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

test "a stream stops inside a frame only in a prefix or short of a promised body" {
    const max = 64;
    const Case = struct { parts: []const []const u8, cut: bool };
    const cases = [_]Case{
        .{ .parts = &.{}, .cut = false },
        .{ .parts = &.{""}, .cut = false },
        .{ .parts = &.{"3:abc"}, .cut = false },
        .{ .parts = &.{"3:abc0:2:xy"}, .cut = false },
        // The boundary between the parts falls anywhere in a frame.
        .{ .parts = &.{ "3:a", "bc" }, .cut = false },
        .{ .parts = &.{ "1", "0:0123456789" }, .cut = false },
        .{ .parts = &.{ "3:abc", "", "2:xy" }, .cut = false },
        .{ .parts = &.{"3"}, .cut = true },
        .{ .parts = &.{"3:"}, .cut = true },
        .{ .parts = &.{"3:ab"}, .cut = true },
        .{ .parts = &.{ "3:abc", "2:x" }, .cut = true },
        .{ .parts = &.{ "3:abc1", "" }, .cut = true },
        // A prefix the parse refuses is not a frame cut short.
        .{ .parts = &.{"x"}, .cut = false },
        .{ .parts = &.{":"}, .cut = false },
        .{ .parts = &.{"03:abc"}, .cut = false },
        .{ .parts = &.{"65:"}, .cut = false },
        .{ .parts = &.{ "3:abc", "9x" }, .cut = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.cut, stream_framing.endsMidFrame(case.parts, max));
    }
}
