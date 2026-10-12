//! Bounded terminal diagnostics shared by Host operations. This text survives
//! its producer without allocating at completion. It is not protocol data.
const std = @import("std");
const Failure = @This();

bytes: [256]u8 = undefined,
len: u16 = 0,

pub fn init(text: []const u8) Failure {
    var failure: Failure = .{};
    const limit = @min(text.len, failure.bytes.len);
    var end = limit;
    while (end != 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    @memcpy(failure.bytes[0..end], text[0..end]);
    failure.len = @intCast(end);
    return failure;
}

pub fn message(self: *const Failure) []const u8 {
    return self.bytes[0..self.len];
}
