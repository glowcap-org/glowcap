//! Word and tail UTF-8 validation agrees with the standard decoder.

const std = @import("std");
const utf8 = @import("glowcap").foundation.utf8;

test "UTF-8 word validation preserves every two-byte refusal across boundaries" {
    var storage: [33]u8 = undefined;
    const bytes = storage[1..];
    for ([_]usize{ 0, 3, 7, 8, 15 }) |offset| {
        for (0..65536) |pair| {
            @memset(bytes, 'a');
            bytes[offset] = @truncate(pair);
            bytes[offset + 1] = @truncate(pair >> 8);
            for ([_]usize{ offset + 1, offset + 2, bytes.len }) |length| {
                try std.testing.expectEqual(std.unicode.utf8ValidateSlice(bytes[0..length]), utf8.valid(bytes[0..length]));
            }
        }
    }
}

test "UTF-8 word validation preserves multibyte sequences and truncated tails" {
    const cases = [_][]const u8{ "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80" };
    for (cases) |sequence| {
        for (0..17) |offset| {
            var bytes: [24]u8 = @splat('a');
            @memcpy(bytes[offset..][0..sequence.len], sequence);
            for (0..bytes.len + 1) |length| {
                try std.testing.expectEqual(std.unicode.utf8ValidateSlice(bytes[0..length]), utf8.valid(bytes[0..length]));
            }
        }
    }
}
