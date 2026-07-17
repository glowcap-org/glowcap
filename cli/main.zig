//! Installable CapTP CLI for humans and agents.
//!
//! Sources live under repo-root `cli/` and consume the public `pancake` module
//! (ADR-0084). Progressive `ocapn` commands, REPL, curated MCP, and `app rooms-peer`
//! share one command tree for parse, scoped help, and shell completion.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const exit_codes = @import("exit_codes.zig");
const log = @import("operability/log.zig");
const cmd = @import("cmd/mod.zig");
const tree = @import("cmd/tree.zig");

pub fn main(init: std.process.Init) !void {
    const code = run(init) catch |err| switch (err) {
        error.Usage => exit_codes.usage,
        error.Busy => exit_codes.busy,
        else => blk: {
            log.err(init.io, "unexpected error: {s}", .{@errorName(err)});
            break :blk exit_codes.internal;
        },
    };
    std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    var ctx = Ctx{ .io = init.io, .gpa = init.gpa, .environ = init.environ_map, .argv_init = &init };
    defer ctx.deinit();

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // program

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(ctx.gpa);
    while (args_iter.next()) |a| try argv_list.append(ctx.gpa, a);

    return cmd.dispatch(&tree.root, &ctx, argv_list.items);
}
