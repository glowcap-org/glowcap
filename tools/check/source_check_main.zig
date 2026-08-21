const std = @import("std");
const source_check = @import("source_check.zig");

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 3) {
        std.debug.print("usage: source-check-tool <repo-root> <zig-lib-dir>\n", .{});
        std.process.exit(2);
    }

    const io = init.io;
    const gpa = init.arena.allocator();
    const root_path = std.mem.span(args[1]);
    const zig_lib_path = std.mem.span(args[2]);
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.debug.print("source-check: cannot open repository root `{s}`: {s}\n", .{ root_path, @errorName(err) });
        std.process.exit(2);
    };
    defer root.close(io);

    const count = try source_check.check(io, gpa, root, root_path, zig_lib_path);
    if (count != 0) {
        std.debug.print("source-check found {d} source contract violation(s)\n", .{count});
        std.process.exit(1);
    }
}
