//! The Rust application's generated projection of the core Rooms wire
//! vocabulary. Policy modules re-export these values under any local semantic
//! names they need without owning their spellings.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try p.writeHeader(&out, gpa, "//!");
    try out.appendSlice(gpa, "//! Core Rooms methods and notification words for Rust application policy.\n\n");
    for (std.enums.values(p.Token)) |token| {
        try out.appendSlice(gpa, "pub const ");
        try p.writeUpper(&out, gpa, @tagName(token), '_');
        try out.print(gpa, ": &str = \"{s}\";\n", .{token.wire()});
    }
    return out.toOwnedSlice(gpa);
}
