const std = @import("std");
const arch_check = @import("arch_check");
const arch_check_table = @import("arch_check_table");

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 2) {
        std.debug.print("usage: arch-check-tool <repo-root>\n", .{});
        std.process.exit(2);
    }

    const io = init.io;
    const root_path = std.mem.span(args[1]);
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.debug.print("arch-check: cannot open repository root `{s}`: {s}\n", .{ root_path, @errorName(err) });
        std.process.exit(2);
    };
    defer root.close(io);

    const count = try arch_check.check(io, init.arena.allocator(), root, &arch_check_table.layer_table);
    if (count != 0) {
        std.debug.print("arch-check found {d} violation(s)\n", .{count});
        std.process.exit(1);
    }
}
