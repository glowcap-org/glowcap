//! Interactive CapTP lab in line mode or libvaxis TUI, an alias of `dial --repl`.
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const log = @import("../operability/log.zig");
const Parsed = @import("../cmd/types.zig").Parsed;
const ocapn = @import("../ocapn/mod.zig");
const teach = @import("teach.zig");
const complete = @import("complete.zig");
const blocks = @import("blocks.zig");
const exec = @import("exec.zig");
const tui = @import("tui.zig");

pub fn splitLine(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |tok| try list.append(gpa, tok);
    return try list.toOwnedSlice(gpa);
}

fn stdinIsTty(ctx: *Ctx) bool {
    return std.Io.File.stdin().isTty(ctx.io) catch false;
}

/// REPL after a session may already be open (from `ocapn dial --repl`).
pub fn runAttached(ctx: *Ctx) !u8 {
    ctx.front = .repl;
    if (stdinIsTty(ctx)) {
        return tui.run(ctx);
    }
    return runAttachedLine(ctx);
}

fn runAttachedLine(ctx: *Ctx) !u8 {
    ctx.front = .repl;
    log.info(ctx.io, "repl: type help, quit, or an ocapn verb (line mode)", .{});

    var progress = teach.Progress.fromEnv(ctx.environ);
    progress.syncFromCtx(ctx);
    var store = blocks.Store.init(ctx.gpa);
    defer store.deinit();
    var complete_state = complete.State.init(ctx.gpa);
    defer complete_state.deinit();

    if (!progress.quiet) {
        try exec.appendWorkbenchReady(&store);
        try flushNewBlocks(ctx, &store, 0);
    }

    var printed: usize = store.items.items.len;
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(ctx.io, &read_buf);
    while (true) {
        const prompt = if (ctx.activeSession() != null) "glowcap> " else "glowcap. ";
        try std.Io.File.stdout().writeStreamingAll(ctx.io, prompt);
        const line_raw = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                log.err(ctx.io, "repl read: {s}", .{@errorName(err)});
                return exit_codes.internal;
            },
        };
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const turn = try exec.handleLine(ctx, line, &store, &progress, &complete_state, null);
        try flushNewBlocks(ctx, &store, printed);
        printed = store.items.items.len;
        if (turn.quit) break;
    }
    if (ctx.closeOwned(.cancel)) |failure| {
        ctx.logCloseFailure("repl close", failure);
        return ctx.mapCloseErr(failure.cause);
    }
    return exit_codes.ok;
}

fn flushNewBlocks(ctx: *Ctx, store: *const blocks.Store, from: usize) !void {
    var i = from;
    while (i < store.items.items.len) : (i += 1) {
        const b = store.items.items[i];
        const text = if (b.expanded) b.body else b.summary;
        try std.Io.File.stdout().writeStreamingAll(ctx.io, text);
        try std.Io.File.stdout().writeStreamingAll(ctx.io, "\n");
    }
}

/// Command-tree entry for `glowcap repl [locator]`.
pub fn runParsed(ctx: *Ctx, parsed: *Parsed) !u8 {
    ctx.front = .repl;
    if (parsed.positionals.len > 0) {
        try parsed.setBool("repl", true);
        return ocapn.cmdDial(ctx, parsed);
    }
    // Optional locator: sessionless lab (dial or listen inside).
    return runAttached(ctx);
}
