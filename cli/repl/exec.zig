//! Shared CapTP lab turn execution (TUI + line mode).
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const registry = @import("../registry.zig");
const copy = @import("copy.zig");
const teach = @import("teach.zig");
const complete = @import("complete.zig");
const blocks = @import("blocks.zig");
const splitLine = @import("mod.zig").splitLine;
const await_queue = @import("await_queue.zig");

const flash_mod = @import("flash.zig");
pub const Flash = flash_mod.Flash;

pub const TurnResult = struct {
    quit: bool = false,
    flash: Flash = .none,
    focus_pane: ?teach.Pane = null,
    toggle_quiet: bool = false,
    /// When set, the TUI must enqueue this CapTP line (nonblocking path).
    enqueue_captp: ?[]const u8 = null,
};

pub fn appendGuideCoach(store: *blocks.Store) !void {
    var it = std.mem.splitScalar(u8, copy.coach_guide, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try store.appendLine(.coach, line);
    }
}

pub fn appendWorkbenchReady(store: *blocks.Store) !void {
    try store.appendLine(.system, copy.workbench_ready);
}

pub fn appendDivertLine(store: *blocks.Store, line: []const u8) !void {
    const err_prefix = "pancake: error: ";
    const info_prefix = "pancake: ";
    if (std.mem.startsWith(u8, line, err_prefix)) {
        var buf: [600]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "! {s}", .{line[err_prefix.len..]}) catch line;
        try store.appendLine(.error_line, msg);
        return;
    }
    if (std.mem.startsWith(u8, line, info_prefix)) {
        try store.appendLine(.result, line[info_prefix.len..]);
        return;
    }
    try store.appendLine(blocks.kindFromLabLine(line), line);
}

pub fn handleLine(
    ctx: *Ctx,
    line: []const u8,
    store: *blocks.Store,
    progress: *teach.Progress,
    complete_state: *complete.State,
    /// Non-null in the TUI: CapTP session verbs return `enqueue_captp` instead of blocking.
    captp_queue: ?*await_queue.Queue,
) !TurnResult {
    var result: TurnResult = .{};
    var ubuf: [4200]u8 = undefined;
    const uline = std.fmt.bufPrint(&ubuf, "› {s}", .{line}) catch line;
    try store.appendLine(.user, uline);

    if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) {
        result.quit = true;
        return result;
    }

    if (std.mem.eql(u8, line, "focus")) {
        result.toggle_quiet = true;
        try store.appendLine(.system, "Toggled quiet/focus view (rail collapses to counts).");
        return result;
    }

    if (std.mem.eql(u8, line, "?") or std.mem.eql(u8, line, "help")) {
        if (std.mem.eql(u8, line, "?")) {
            if (progress.guide_active) {
                try appendGuideCoach(store);
            } else {
                try store.appendLine(.system, copy.workbench_ready);
                try store.appendLine(.tip, "tip: guide enters the optional CapTP walkthrough");
            }
        } else {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(ctx.gpa);
            const HelpW = struct {
                list: *std.ArrayList(u8),
                gpa: std.mem.Allocator,
                pub fn writeAll(self: @This(), bytes: []const u8) !void {
                    try self.list.appendSlice(self.gpa, bytes);
                }
                pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
                    try self.list.print(self.gpa, fmt, args);
                }
            };
            const hw = HelpW{ .list = &list, .gpa = ctx.gpa };
            try registry.helpEveryday(hw, .repl);
            try hw.writeAll("REPL-only: help, help captp, guide, tour, focus, ?, quit\n");
            try hw.writeAll("Keys: Tab · Ctrl-O transcript · F1 help · Ctrl-p panels · wheel scroll\n");
            var it = std.mem.splitScalar(u8, list.items, '\n');
            while (it.next()) |l| {
                if (l.len == 0) continue;
                try store.appendLine(.system, l);
            }
        }
        return result;
    }

    if (std.mem.startsWith(u8, line, "help ")) {
        const rest = std.mem.trim(u8, line["help ".len..], " \t");
        if (std.mem.eql(u8, rest, "captp")) {
            var it = std.mem.splitScalar(u8, copy.help_captp_map, '\n');
            while (it.next()) |l| {
                if (l.len == 0) continue;
                try store.appendLine(.system, l);
            }
            try store.appendLine(.tip, "tip: guide — optional CapTP walkthrough");
            return result;
        }
    }

    // Optional walkthrough: bare `guide` toggles; `guide on` / `guide exit`.
    if (std.mem.eql(u8, line, "guide") or std.mem.startsWith(u8, line, "guide ")) {
        const rest = std.mem.trim(u8, line[@min(line.len, 5)..], " \t");
        const want_exit = std.mem.eql(u8, rest, "exit") or
            std.mem.eql(u8, rest, "off") or
            std.mem.eql(u8, rest, "done") or
            std.mem.eql(u8, rest, "stop") or
            (rest.len == 0 and progress.guide_active);
        const want_enter = std.mem.eql(u8, rest, "on") or
            std.mem.eql(u8, rest, "start") or
            (rest.len == 0 and !progress.guide_active);
        if (want_exit) {
            progress.exitGuide();
            try store.appendLine(.system, "Walkthrough off — workbench mode.");
        } else if (want_enter) {
            progress.enterGuide();
            try store.appendLine(.system, "Walkthrough on — stage strip + next-step tips. guide exit to leave.");
            try appendGuideCoach(store);
            try store.appendLine(.tip, progress.nextStep());
        } else {
            try store.appendLine(.error_line, "! guide | guide exit");
        }
        return result;
    }

    if (std.mem.startsWith(u8, line, "tour")) {
        const rest = std.mem.trim(u8, line[@min(line.len, 4)..], " \t");
        const name = if (rest.len == 0) "exports" else rest;
        if (teach.parseTourPane(name)) |pane| {
            result.focus_pane = pane;
            progress.noteTour();
            try store.appendLine(.system, copy.tourBlurb(@tagName(pane)));
            if (progress.guide_active) {
                try store.appendLine(.tip, progress.nextStep());
            }
            result.flash = switch (pane) {
                .exports => .exports,
                .imports => .imports,
                .answers => .answers,
            };
        } else {
            try store.appendLine(.error_line, "! Unknown pane. Try tour exports, tour imports, or tour answers.");
        }
        return result;
    }

    const tokens = try splitLine(ctx.gpa, line);
    defer ctx.gpa.free(tokens);
    if (tokens.len == 0) return result;

    const verb = tokens[0];
    // TUI path: CapTP session verbs enqueue and settle cooperatively so the
    // prompt stays live. Line mode passes `queue == null` and stays blocking.
    if (captp_queue != null and await_queue.isSessionVerb(verb)) {
        result.enqueue_captp = line;
        return result;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    const prev_sink = ctx.sink;
    ctx.sink = .{ .buffer = &out };
    defer ctx.sink = prev_sink;

    const code = registry.dispatch(ctx, verb, tokens[1..]) catch |err| {
        var ebuf: [128]u8 = undefined;
        const em = std.fmt.bufPrint(&ebuf, "! {s}", .{@errorName(err)}) catch "! error";
        try store.appendLine(.error_line, em);
        if (copy.tipForErrorDetail(@errorName(err))) |tip| {
            var tbuf: [256]u8 = undefined;
            const tm = std.fmt.bufPrint(&tbuf, "tip: {s}", .{tip}) catch tip;
            try store.appendLine(.tip, tm);
        }
        return result;
    };

    if (out.items.len > 0) {
        try store.appendMultiline(.result, std.mem.trimEnd(u8, out.items, "\n"));
    } else if (code != exit_codes.ok) {
        const items = store.items.items;
        const already = items.len > 0 and items[items.len - 1].kind == .error_line;
        if (!already) {
            var ebuf: [32]u8 = undefined;
            const em = std.fmt.bufPrint(&ebuf, "! exit {d}", .{code}) catch "! exit";
            try store.appendLine(.error_line, em);
        }
    }

    if (code == exit_codes.ok) {
        var gbuf: [256]u8 = undefined;
        const gm = std.fmt.bufPrint(&gbuf, "↳ {s}", .{teach.gloss(verb)}) catch "↳ ok";
        try store.appendLine(.gloss, gm);
        progress.noteVerb(verb, ctx);
        if ((std.mem.eql(u8, verb, "fetch") or std.mem.eql(u8, verb, "call") or std.mem.eql(u8, verb, "tell") or std.mem.eql(u8, verb, "publish")) and tokens.len >= 2) {
            complete_state.rememberName(tokens[1]) catch {};
        }
        result.flash = flashForVerb(verb);
    } else if (copy.tipForErrorDetail(out.items)) |tip| {
        var tbuf: [256]u8 = undefined;
        const tm = std.fmt.bufPrint(&tbuf, "tip: {s}", .{tip}) catch tip;
        try store.appendLine(.tip, tm);
    } else {
        tipFromRecent(store);
    }
    return result;
}

fn tipFromRecent(store: *blocks.Store) void {
    var i = store.items.items.len;
    var checked: usize = 0;
    while (i > 0 and checked < 8) {
        i -= 1;
        checked += 1;
        if (copy.tipForErrorDetail(store.items.items[i].body)) |tip| {
            var tbuf: [256]u8 = undefined;
            const tm = std.fmt.bufPrint(&tbuf, "tip: {s}", .{tip}) catch return;
            store.appendLine(.tip, tm) catch {};
            return;
        }
    }
}

const flashForVerb = flash_mod.flashForVerb;
