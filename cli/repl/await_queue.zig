//! Cooperative CapTP turn queue for the lab TUI (UI-thread only).
//!
//! Host ownership forbids a worker thread; waits use `send` / `beginFetch` +
//! `on` + `stepReadable` while the event loop keeps painting and accepting input.
//!
//! Rendering contract: drain with non-blocking `stepReadable(0)` until idle or
//! blocked on I/O; the TUI wakes on the session socket (or a frame timeout) —
//! never a blind sleep while CapTP is busy. Spinner glyphs appear only after
//! `spinner_show_after_ms` so same-turn settlement never flashes a wait.
const std = @import("std");
const pancake = @import("pancake");
const Ctx = @import("../ctx.zig").Ctx;
const ocapn = @import("../ocapn/mod.zig");
const registry = @import("../registry.zig");
const clock = @import("../operability/clock.zig");
const blocks = @import("blocks.zig");
const copy = @import("copy.zig");
const teach = @import("teach.zig");
const complete = @import("complete.zig");
const splitLine = @import("mod.zig").splitLine;

const driver = pancake.driver;
const model = pancake.ocapn.model;
const actors = pancake.actors;

pub const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
/// Frame budget while animating a wait (~60 Hz). Also the `stepReadable` cap so
/// a remote answer wakes the loop early instead of sitting out a blind sleep.
pub const frame_ms: i32 = 16;
/// Defer spinner glyphs until a wait is perceptible (local/flush settle stays clean).
pub const spinner_show_after_ms: i64 = 50;

fn sessionVerbOf(verb: []const u8) ?registry.SessionVerb {
    const cmd = registry.find(verb) orelse return null;
    return cmd.session_verb;
}

pub fn isSessionVerb(verb: []const u8) bool {
    return sessionVerbOf(verb) != null;
}

const flash_mod = @import("flash.zig");
pub const Flash = flash_mod.Flash;

const Queued = struct {
    line: []u8,
    block_idx: usize,
};

const StartResult = enum { waiting, finished };

const Active = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    capture: driver.SettleCapture,
    flag: driver.SettleFlag,
    block_idx: usize,
    label: []u8,
    started_ms: i64,
    timeout_ms: i32,
    /// The driver's cooperative fetch-then-deliver context, armed only for a
    /// name-target call/tell (`composed`); the driver owns the chaining, so
    /// this queue keeps no continuation state of its own.
    pending: driver.PendingSend = undefined,
    composed: bool = false,
    tokens_owned: [][]u8,
    tokens: []const []const u8,
    verb: []const u8,

    fn deinit(self: *Active) void {
        if (self.composed) self.pending.deinit();
        for (self.tokens_owned) |t| self.gpa.free(t);
        self.gpa.free(self.tokens_owned);
        self.gpa.free(self.tokens);
        self.gpa.free(self.label);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    fn resetListener(self: *Active) void {
        _ = self.arena.reset(.retain_capacity);
        self.capture = .{ .arena = self.arena.allocator() };
        self.flag = .{
            .inner = .{ .ctx = &self.capture, .func = driver.SettleCapture.fire },
            .done = false,
        };
    }
};

pub const Queue = struct {
    gpa: std.mem.Allocator,
    pending: std.ArrayList(Queued) = .empty,
    active: ?*Active = null,
    spin_i: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Queue {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Queue) void {
        if (self.active) |a| a.deinit();
        self.active = null;
        for (self.pending.items) |q| self.gpa.free(q.line);
        self.pending.deinit(self.gpa);
    }

    pub fn busy(self: *const Queue) bool {
        return self.active != null or self.pending.items.len > 0;
    }

    pub fn enqueue(self: *Queue, ctx: *Ctx, line: []const u8, store: *blocks.Store, progress: *teach.Progress) !void {
        const owned = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(owned);
        // Plain label until a wait outlives `spinner_show_after_ms`.
        try store.appendLine(.pending, line);
        const block_idx = store.items.items.len - 1;
        try self.pending.append(self.gpa, .{ .line = owned, .block_idx = block_idx });
        if (self.active == null) try self.startNext(ctx, store, progress);
    }

    pub fn cancelActive(
        self: *Queue,
        ctx: *Ctx,
        store: *blocks.Store,
        progress: *teach.Progress,
        complete_state: *complete.State,
    ) !Flash {
        if (self.active == null) return .none;
        if (ctx.session) |session| session.breakFarVows("cancelled");
        return self.pump(ctx, store, progress, complete_state);
    }

    pub fn tick(
        self: *Queue,
        ctx: *Ctx,
        store: *blocks.Store,
        progress: *teach.Progress,
        complete_state: *complete.State,
    ) !Flash {
        const flash = try self.pump(ctx, store, progress, complete_state);
        self.paintSpinnerIfDue(store);
        return flash;
    }

    fn paintSpinnerIfDue(self: *Queue, store: *blocks.Store) void {
        const a = self.active orelse return;
        if (clock.nowMs() - a.started_ms < spinner_show_after_ms) return;
        self.spin_i = (self.spin_i + 1) % spinner_frames.len;
        var buf: [520]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} {s}", .{ spinner_frames[self.spin_i], a.label }) catch a.label;
        store.setLine(a.block_idx, .pending, text) catch {};
    }

    /// Drain until the queue is idle or the active vow needs socket progress.
    /// One `stepReadable(0)` flushes (local settle) then polls without blocking.
    pub fn pump(
        self: *Queue,
        ctx: *Ctx,
        store: *blocks.Store,
        progress: *teach.Progress,
        complete_state: *complete.State,
    ) !Flash {
        var flash: Flash = .none;
        while (true) {
            const active = self.active orelse {
                try self.startNext(ctx, store, progress);
                if (self.active == null) return flash;
                continue;
            };
            const session = ctx.session orelse {
                try store.setLine(active.block_idx, .error_line, "! No open session.");
                self.clearActive();
                continue;
            };

            if (active.timeout_ms != 0) {
                const elapsed = clock.nowMs() - active.started_ms;
                if (elapsed >= active.timeout_ms) {
                    session.breakFarVows("wait timed out");
                }
            }

            _ = session.stepReadable(0) catch |err| {
                // A transport fault propagates raw (only a clean `.closed` pump
                // breaks far vows in `step`), so the vat still holds this
                // Active's listener; a listener has no `off` — break it off
                // before the Active it points into dies.
                session.breakFarVows("connection failed");
                try finishErr(store, active.block_idx, err);
                self.clearActive();
                continue;
            };

            if (!active.flag.done) return flash;

            const settled = active.capture.finish() catch |err| {
                try finishErr(store, active.block_idx, err);
                self.clearActive();
                continue;
            };

            const f = try self.finishTerminal(ctx, store, progress, complete_state, active, settled);
            if (f != .none) flash = f;
        }
    }

    fn finishTerminal(
        self: *Queue,
        ctx: *Ctx,
        store: *blocks.Store,
        progress: *teach.Progress,
        complete_state: *complete.State,
        active: *Active,
        settled: driver.Settled,
    ) !Flash {
        switch (settled) {
            .broken => |reason| {
                if (std.mem.eql(u8, reason, "cancelled")) {
                    try store.setLine(active.block_idx, .error_line, "! cancelled");
                    try store.appendLine(.tip, "tip: Esc cancels the active wait; queued CapTP turns still run");
                } else if (std.mem.eql(u8, reason, "wait timed out")) {
                    try store.setLine(active.block_idx, .error_line, "! WaitTimedOut");
                    try store.appendLine(.tip, "tip: #0 is bootstrap — fetch then call #<import> from the Imports rail");
                } else if (active.composed and active.pending.stage == .fetching) {
                    // The chain broke at the fetch leg: the name is not
                    // published on the peer, so say so and coach the fix.
                    var buf: [600]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "! fetch: {s}", .{reason}) catch "! fetch broken";
                    try store.setLine(active.block_idx, .error_line, msg);
                    try store.appendLine(.tip, "tip: publish that name on the peer, then fetch again");
                } else {
                    var buf: [600]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "broken: {s}", .{reason}) catch "broken";
                    try store.setLine(active.block_idx, .error_line, msg);
                }
                const flash = flashForVerb(active.verb);
                self.clearActive();
                try self.startNext(ctx, store, progress);
                return flash;
            },
            else => {},
        }

        if (std.mem.eql(u8, active.verb, "tell")) {
            // A composed tell settles `.void` once the fire-and-forget deliver
            // is queued; render it exactly as the direct-target tell does.
            try store.setLine(active.block_idx, .result, "told");
            if (progress.glossOnce("tell")) |g| {
                var gbuf: [256]u8 = undefined;
                const gm = std.fmt.bufPrint(&gbuf, "↳ {s}", .{g}) catch "↳ ok";
                try store.appendLine(.gloss, gm);
            }
            progress.noteVerb("tell", ctx);
            if (active.tokens.len >= 2) complete_state.rememberName(active.tokens[1]) catch {};
            self.clearActive();
            try self.startNext(ctx, store, progress);
            return .answers;
        }

        if (std.mem.eql(u8, active.verb, "fetch")) {
            const import_pos = importPosFromFetch(settled) catch |err| {
                try finishErr(store, active.block_idx, err);
                self.clearActive();
                try self.startNext(ctx, store, progress);
                return .none;
            };
            const name = active.tokens[1];
            var fbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&fbuf, ocapn.fetched_fmt, .{ name, import_pos }) catch "fetched";
            try store.setLine(active.block_idx, .result, msg);
            var nbuf: [256]u8 = undefined;
            const next = std.fmt.bufPrint(&nbuf, ocapn.fetch_next_fmt, .{ name, import_pos }) catch copy.next_deliver;
            try store.appendLine(.tip, next);
        } else {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            const prev = ctx.sink;
            ctx.sink = .{ .buffer = &out };
            defer ctx.sink = prev;
            try ocapn.printSettled(ctx, settled);
            const text = std.mem.trimEnd(u8, out.items, "\n");
            if (text.len == 0) {
                try store.setLine(active.block_idx, .result, "ok");
            } else {
                try store.setLine(active.block_idx, .result, text);
            }
        }

        if (progress.glossOnce(active.verb)) |g| {
            var gbuf: [256]u8 = undefined;
            const gm = std.fmt.bufPrint(&gbuf, "↳ {s}", .{g}) catch "↳ ok";
            try store.appendLine(.gloss, gm);
        }
        progress.noteVerb(active.verb, ctx);
        if (active.tokens.len >= 2) complete_state.rememberName(active.tokens[1]) catch {};
        const flash = flashForVerb(active.verb);
        self.clearActive();
        try self.startNext(ctx, store, progress);
        return flash;
    }

    fn clearActive(self: *Queue) void {
        if (self.active) |a| a.deinit();
        self.active = null;
    }

    fn startNext(self: *Queue, ctx: *Ctx, store: *blocks.Store, progress: *teach.Progress) !void {
        while (self.active == null and self.pending.items.len > 0) {
            const q = self.pending.orderedRemove(0);
            defer self.gpa.free(q.line);

            const session = ctx.session orelse {
                try store.setLine(q.block_idx, .error_line, "! No open session.");
                try store.appendLine(.tip, copy.tip_no_session);
                continue;
            };

            const raw_tokens = try splitLine(self.gpa, q.line);
            defer self.gpa.free(raw_tokens);
            if (raw_tokens.len == 0) continue;

            var owned_toks: std.ArrayList([]u8) = .empty;
            errdefer {
                for (owned_toks.items) |t| self.gpa.free(t);
                owned_toks.deinit(self.gpa);
            }
            for (raw_tokens) |t| try owned_toks.append(self.gpa, try self.gpa.dupe(u8, t));
            const tokens_owned = try owned_toks.toOwnedSlice(self.gpa);
            errdefer {
                for (tokens_owned) |t| self.gpa.free(t);
                self.gpa.free(tokens_owned);
            }
            const tokens = try self.gpa.alloc([]const u8, tokens_owned.len);
            errdefer self.gpa.free(tokens);
            for (tokens_owned, 0..) |t, i| tokens[i] = t;

            const verb = tokens[0];
            const label = try self.gpa.dupe(u8, q.line);
            errdefer self.gpa.free(label);

            const active = try self.gpa.create(Active);
            errdefer self.gpa.destroy(active);
            active.* = .{
                .gpa = self.gpa,
                .arena = std.heap.ArenaAllocator.init(self.gpa),
                .capture = undefined,
                .flag = undefined,
                .block_idx = q.block_idx,
                .label = label,
                .started_ms = clock.nowMs(),
                .timeout_ms = ocapn.default_settle_timeout_ms,
                .tokens_owned = tokens_owned,
                .tokens = tokens,
                .verb = verb,
            };
            active.resetListener();

            const result = self.beginVerb(session, active, store, progress) catch |err| {
                try finishErr(store, active.block_idx, err);
                if (err == error.Usage) try store.appendLine(.tip, copy.tip_missing_verb);
                active.deinit();
                continue;
            };
            switch (result) {
                .waiting => return,
                .finished => continue,
            }
        }
    }

    fn beginVerb(self: *Queue, session: *driver.Session, active: *Active, store: *blocks.Store, progress: *teach.Progress) !StartResult {
        const tokens = active.tokens;
        // Exhaustive on the registry's SessionVerb: a new member fails to
        // compile here instead of dying as a runtime usage error.
        const sverb = sessionVerbOf(tokens[0]) orelse return error.Usage;

        switch (sverb) {
            .publish => {
                try runPublish(session, tokens, active.block_idx, store, progress);
                active.deinit();
                return .finished;
            },
            .fetch => {
                if (tokens.len < 2) return error.Usage;
                const vow = try session.beginFetch(tokens[1]);
                try session.on(vow, .{ .ctx = &active.flag, .func = driver.SettleFlag.fire });
                _ = session.stepReadable(0) catch {};
                self.active = active;
                return .waiting;
            },
            .call, .tell => {
                if (tokens.len < 3) return error.Usage;
                const target_tok = tokens[1];
                // Borrowed for this call only: `send`/`tell` and the compose
                // primitive all clone the message before returning.
                const args = try ocapn.parseArgsList(active.gpa, tokens[3..]);
                defer active.gpa.free(args);

                if (try ocapn.parseImportTarget(target_tok)) |target| {
                    if (sverb == .tell) {
                        try session.tell(target, .{ .verb = active.tokens[2], .args = args });
                        try store.setLine(active.block_idx, .result, "told");
                        if (progress.glossOnce("tell")) |g| {
                            var gbuf: [256]u8 = undefined;
                            const gm = std.fmt.bufPrint(&gbuf, "↳ {s}", .{g}) catch "↳ ok";
                            try store.appendLine(.gloss, gm);
                        }
                        active.deinit();
                        return .finished;
                    }
                    const vow = try session.send(target, .{ .verb = active.tokens[2], .args = args });
                    try session.on(vow, .{ .ctx = &active.flag, .func = driver.SettleFlag.fire });
                    _ = session.stepReadable(0) catch {};
                    self.active = active;
                    return .waiting;
                }

                // A name target rides the driver's cooperative compose: one
                // begin chains fetch-then-deliver inside the driver, and this
                // queue just waits on the terminal listener.
                const listener = actors.Listener{ .ctx = &active.flag, .func = driver.SettleFlag.fire };
                const msg = actors.Message{ .verb = active.tokens[2], .args = args };
                // `begin*Named` owns `pending.msg_arena` from the moment it
                // initializes it, and its own errdefer frees it on any failure.
                // Only claim it here once the call has returned, or a refusal
                // frees the arena twice.
                if (sverb == .tell) {
                    try session.beginTellNamed(&active.pending, target_tok, msg, listener);
                } else {
                    try session.beginSendNamed(&active.pending, target_tok, msg, listener);
                }
                active.composed = true;
                _ = session.stepReadable(0) catch {};
                self.active = active;
                return .waiting;
            },
        }
    }
};

fn farRefFromFetch(settled: driver.Settled) !actors.Ref {
    return switch (settled) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far| .{ .far = far },
                else => driver.Error.FetchNotACapability,
            },
            else => driver.Error.FetchNotACapability,
        },
        .broken => error.FetchBroken,
        .give => driver.Error.FetchNotACapability,
    };
}

fn importPosFromFetch(settled: driver.Settled) !u64 {
    const ref = try farRefFromFetch(settled);
    return switch (ref) {
        .far => |far| far.import_position.int(),
        .local => driver.Error.FetchNotACapability,
    };
}

fn runPublish(session: *driver.Session, tokens: []const []const u8, block_idx: usize, store: *blocks.Store, progress: *teach.Progress) !void {
    if (tokens.len < 2) {
        try store.setLine(block_idx, .error_line, "! publish needs a built-in name (greeter|echo)");
        return;
    }
    ocapn.publishBuiltin(session, tokens[1]) catch |err| {
        try finishErr(store, block_idx, err);
        return;
    };
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "published {s}", .{tokens[1]}) catch "published";
    try store.setLine(block_idx, .result, msg);
    if (progress.glossOnce("publish")) |g| {
        var gbuf: [256]u8 = undefined;
        const gm = std.fmt.bufPrint(&gbuf, "↳ {s}", .{g}) catch "↳ ok";
        try store.appendLine(.gloss, gm);
    }
}

const flashForVerb = flash_mod.flashForVerb;

fn finishErr(store: *blocks.Store, block_idx: usize, err: anyerror) !void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "! {s}", .{@errorName(err)}) catch "! error";
    try store.setLine(block_idx, .error_line, msg);
    if (err == error.WaitTimedOut) {
        try store.appendLine(.tip, "tip: Esc cancels; #0 is bootstrap — fetch then call #<import> from the Imports rail");
        return;
    }
    if (copy.tipForErrorDetail(@errorName(err))) |tip| {
        var tbuf: [256]u8 = undefined;
        const tm = std.fmt.bufPrint(&tbuf, "tip: {s}", .{tip}) catch tip;
        try store.appendLine(.tip, tm);
    }
}
