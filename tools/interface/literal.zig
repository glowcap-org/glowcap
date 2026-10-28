//! UTF-8 string literals shared by the Zig and Rust emitters. These languages
//! accept the same escapes for ASCII controls and preserve UTF-8 source bytes.
const std = @import("std");

pub fn write(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidDescription;
    try out.append(a, '"');
    for (text) |byte| switch (byte) {
        '"', '\\' => {
            try out.append(a, '\\');
            try out.append(a, byte);
        },
        0...31, 127 => try out.print(a, "\\x{x:0>2}", .{byte}),
        else => try out.append(a, byte),
    };
    try out.append(a, '"');
}

test "literal encoding preserves controls quotes and unicode" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try write(&out, std.testing.allocator, "a\"\\\n\x00é");
    try std.testing.expectEqualStrings("\"a\\\"\\\\\\x0a\\x00é\"", out.items);
}
