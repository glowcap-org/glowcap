//! Shared CapTP lab turn execution (TUI + line mode).
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const registry = @import("../registry.zig");
const copy = @import("copy.zig");
const teach = @import("teach.zig");
const complete = @import("complete.zig");
const meta = @import("meta.zig");
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

    // Meta commands resolve through the one table in `meta.zig`; the switch is
    // exhaustive, so a new entry without an arm here is a compile error. A
    // trailing argument on a command that takes none falls through to ordinary
    // dispatch (which reports it), exactly as an unknown verb does.
    const meta_first_len = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const meta_rest = std.mem.trim(u8, line[meta_first_len..], " \t");
    if (meta.resolve(line[0..meta_first_len])) |m| meta_arm: {
        switch (m) {
            .quit => {
                if (meta_rest.len != 0) break :meta_arm;
                result.quit = true;
                return result;
            },
            .focus => {
                if (meta_rest.len != 0) break :meta_arm;
                result.toggle_quiet = true;
                try store.appendLine(.system, "Toggled quiet/focus view (rail collapses to counts).");
                return result;
            },
            .question => {
                if (meta_rest.len != 0) break :meta_arm;
                if (progress.guide_active) {
                    try appendGuideCoach(store);
                } else {
                    try store.appendLine(.system, copy.workbench_ready);
                    try store.appendLine(.tip, "tip: guide enters the optional CapTP walkthrough");
                }
                return result;
            },
            .help => {
                if (std.mem.eql(u8, meta_rest, "captp")) {
                    var it = std.mem.splitScalar(u8, copy.help_captp_map, '\n');
                    while (it.next()) |l| {
                        if (l.len == 0) continue;
                        try store.appendLine(.system, l);
                    }
                    try store.appendLine(.tip, "tip: guide — optional CapTP walkthrough");
                    return result;
                }
                if (meta_rest.len != 0) break :meta_arm;
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
                try hw.writeAll(meta.footer);
                try hw.writeAll("Keys: Tab · Ctrl-O transcript · F1 help · Ctrl-p panels · wheel scroll\n");
                var it = std.mem.splitScalar(u8, list.items, '\n');
                while (it.next()) |l| {
                    if (l.len == 0) continue;
                    try store.appendLine(.system, l);
                }
                return result;
            },
            .guide => {
                // Optional walkthrough: bare `guide` toggles; `guide on` / `guide exit`.
                const want_exit = std.mem.eql(u8, meta_rest, "exit") or
                    std.mem.eql(u8, meta_rest, "off") or
                    std.mem.eql(u8, meta_rest, "done") or
                    std.mem.eql(u8, meta_rest, "stop") or
                    (meta_rest.len == 0 and progress.guide_active);
                const want_enter = std.mem.eql(u8, meta_rest, "on") or
                    std.mem.eql(u8, meta_rest, "start") or
                    (meta_rest.len == 0 and !progress.guide_active);
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
            },
            .tour => {
                const name = if (meta_rest.len == 0) "exports" else meta_rest;
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
            },
        }
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
        if (progress.glossOnce(verb)) |g| {
            var gbuf: [256]u8 = undefined;
            const gm = std.fmt.bufPrint(&gbuf, "↳ {s}", .{g}) catch "↳ ok";
            try store.appendLine(.gloss, gm);
        }
        progress.noteVerb(verb, ctx);
        if (await_queue.isSessionVerb(verb) and tokens.len >= 2) {
            // best-effort: name completion just misses this name.
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
            // best-effort: a tip is decoration; drop it when it cannot render
            // or the store refuses it.
            const tm = std.fmt.bufPrint(&tbuf, "tip: {s}", .{tip}) catch return;
            store.appendLine(.tip, tm) catch {};
            return;
        }
    }
}

const flashForVerb = flash_mod.flashForVerb;
