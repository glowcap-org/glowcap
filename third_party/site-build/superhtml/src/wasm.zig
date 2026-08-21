const std = @import("std");
const builtin = @import("builtin");
const lsp_exe = @import("cli/lsp.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try lsp_exe.run(init.io, init.gpa, args[1..]);
}
