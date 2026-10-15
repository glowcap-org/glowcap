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
            const want = try std.fmt.bufPrint(&want_buf, "{d}:", .{length});
            try std.testing.expectEqualStrings(want, stream_framing.renderPrefix(&buf, length));
        }
        power = std.math.mul(usize, power, 10) catch break;
    }
    const widest = try std.fmt.bufPrint(&want_buf, "{d}:", .{std.math.maxInt(usize)});
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
