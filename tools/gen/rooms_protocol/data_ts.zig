//! The TypeScript application's generated projection of the core Rooms wire
//! vocabulary. `protocol.ts` supplies the human explanation and re-exports
//! these values without owning their spellings.

const std = @import("std");
const p = @import("../rooms_protocol.zig");

pub fn generate(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try p.writeHeader(&out, gpa, "//");
    try out.appendSlice(gpa, "// Core Rooms methods and notification words for the documented TypeScript surface.\n\n");
    for (std.enums.values(p.Token)) |token| {
        try out.appendSlice(gpa, "export const ");
        try p.writeUpper(&out, gpa, @tagName(token), '_');
        try out.print(gpa, " = \"{s}\";\n", .{token.wire()});
    }
    return out.toOwnedSlice(gpa);
}
