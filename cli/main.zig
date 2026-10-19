//! Installable CapTP CLI for humans and agents.
//!
//! Sources live under repo-root `cli/` and consume the public `glowcap` module
//! (ADR-0032). Progressive `ocapn` commands, REPL, curated MCP, and `apps rooms session`
//! share one command tree for parse, scoped help, and shell completion.
const std = @import("std");
const vaxis = @import("vaxis");
const Ctx = @import("ctx.zig").Ctx;
const exit_codes = @import("exit_codes.zig");
const log = @import("operability/log.zig");
const cmd = @import("cmd/mod.zig");
const tree = @import("cmd/tree.zig");

/// Restore the terminal before dying. The REPL puts the tty in raw mode with the
/// alternate screen and mouse reporting on, and `defer` does not run on a panic,
/// so without this a crash leaves the user's shell unusable. vaxis ships the
/// handler. Installing it is our job.
pub const panic = std.debug.FullPanic(vaxisPanic);

fn vaxisPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}

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
    var ctx = Ctx{ .io = init.io, .gpa = init.gpa, .environ = init.environ_map };
    defer ctx.deinit();

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // program

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(ctx.gpa);
    while (args_iter.next()) |a| try argv_list.append(ctx.gpa, a);

    return cmd.dispatch(&tree.root, &ctx, argv_list.items);
}
