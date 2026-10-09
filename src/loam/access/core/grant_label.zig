//! Descriptive grant labels have no authority and own a fixed UTF-8 allowance.
const std = @import("std");

pub const Label = struct {
    pub const max_bytes = 120;
    bytes: [max_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(text: []const u8) error{InvalidLabel}!Label {
        if (text.len > max_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidLabel;
        var value: Label = .{ .len = @intCast(text.len) };
        @memcpy(value.bytes[0..text.len], text);
        return value;
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn validate(self: *const Label) error{InvalidLabel}!void {
        if (self.len > max_bytes or !std.unicode.utf8ValidateSlice(self.bytes[0..self.len])) return error.InvalidLabel;
    }

    pub fn eql(self: *const Label, other: *const Label) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};
