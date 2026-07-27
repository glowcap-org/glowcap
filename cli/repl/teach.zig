//! CapTP lab pedagogy: stages, gloss keys, coach triggers, tour targets.
const std = @import("std");
const pancake = @import("pancake");
const session_mod = pancake.ocapn.session;
const copy = @import("copy.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub const Stage = enum {
    identity,
    connect,
    session,
    fetch,
    deliver,
    tables,

    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .identity => copy.stage_identity,
            .connect => copy.stage_connect,
            .session => copy.stage_session,
            .fetch => copy.stage_fetch,
            .deliver => copy.stage_deliver,
            .tables => copy.stage_tables,
        };
    }
};

pub const Progress = struct {
    has_identity: bool = false,
    has_connect: bool = false,
    has_session: bool = false,
    has_fetch: bool = false,
    has_deliver: bool = false,
    has_tables: bool = false,
    /// Optional CapTP walkthrough (stage strip + coach tips). Off by default.
    guide_active: bool = false,
    /// Suppress the one-line workbench greeting (`PANCAKE_REPL_QUIET=1`).
    quiet: bool = false,
    /// Hashes of the verbs whose gloss has already been shown, so a lesson the
    /// user has read once does not repeat on every later turn. Bounded: a full
    /// table simply stops suppressing, which is the harmless direction.
    glossed: [32]u64 = @splat(0),
    glossed_len: u8 = 0,

    pub fn fromEnv(environ: *const std.process.Environ.Map) Progress {
        return .{ .quiet = environ.get("PANCAKE_REPL_QUIET") != null };
    }

    pub fn enterGuide(self: *Progress) void {
        self.guide_active = true;
    }

    pub fn exitGuide(self: *Progress) void {
        self.guide_active = false;
    }

    /// The one-line gloss to print after `verb` succeeded, or null when this
    /// session has already shown it. A workbench teaches a verb the first time
    /// it works; the opt-in walkthrough (`guide`) repeats it every time.
    pub fn glossOnce(self: *Progress, verb: []const u8) ?[]const u8 {
        const text = gloss(verb);
        if (self.guide_active) return text;
        const h = std.hash.Wyhash.hash(0, verb);
        for (self.glossed[0..self.glossed_len]) |seen| {
            if (seen == h) return null;
        }
        if (self.glossed_len < self.glossed.len) {
            self.glossed[self.glossed_len] = h;
            self.glossed_len += 1;
        }
        return text;
    }

    pub fn noteVerb(self: *Progress, verb: []const u8, ctx: *Ctx) void {
        if (std.mem.eql(u8, verb, "dial") or std.mem.eql(u8, verb, "probe")) {
            self.has_connect = true;
        }
        if (ctx.session != null) self.has_session = true;
        if (std.mem.eql(u8, verb, "fetch")) self.has_fetch = true;
        if (std.mem.eql(u8, verb, "call") or std.mem.eql(u8, verb, "tell")) self.has_deliver = true;
        if (std.mem.eql(u8, verb, "publish") or std.mem.eql(u8, verb, "fetch") or std.mem.eql(u8, verb, "call")) {
            if (ctx.session) |s| {
                const st = &s.peer.session_state;
                if (session_mod.inspect.exportCount(st) + session_mod.inspect.importCount(st) + session_mod.inspect.inboundAnswerCount(st) + session_mod.inspect.outboundAnswerCount(st) > 0) {
                    self.has_tables = true;
                }
            }
        }
    }

    /// Lab `tour …` — user engaged the CapTP instrument.
    pub fn noteTour(self: *Progress) void {
        self.has_tables = true;
    }

    pub fn syncFromCtx(self: *Progress, ctx: *Ctx) void {
        self.has_identity = ctx.secret != null or ctx.identity_path.len > 0;
        if (ctx.session != null) {
            self.has_session = true;
            self.has_connect = true;
            const st = &ctx.session.?.peer.session_state;
            if (session_mod.inspect.importCount(st) > 0) self.has_fetch = true;
            if (session_mod.inspect.inboundAnswerCount(st) + session_mod.inspect.outboundAnswerCount(st) > 0) self.has_deliver = true;
            if (session_mod.inspect.exportCount(st) + session_mod.inspect.importCount(st) + session_mod.inspect.inboundAnswerCount(st) + session_mod.inspect.outboundAnswerCount(st) > 0) {
                self.has_tables = true;
            }
        }
    }

    pub fn current(self: *const Progress) Stage {
        if (!self.has_identity) return .identity;
        if (!self.has_connect) return .connect;
        if (!self.has_session) return .session;
        if (!self.has_fetch) return .fetch;
        if (!self.has_deliver) return .deliver;
        return .tables;
    }

    pub fn completed(self: *const Progress, stage: Stage) bool {
        return switch (stage) {
            .identity => self.has_identity,
            .connect => self.has_connect,
            .session => self.has_session,
            .fetch => self.has_fetch,
            .deliver => self.has_deliver,
            .tables => self.has_tables,
        };
    }

    /// Walkthrough next-step (stage path). Used while `guide` is active.
    pub fn nextStep(self: *const Progress) []const u8 {
        return switch (self.current()) {
            .identity => copy.next_identity,
            .connect => copy.next_connect,
            .session => copy.next_session,
            .fetch => copy.next_fetch,
            .deliver => copy.next_deliver,
            .tables => if (self.has_tables) copy.next_done else copy.next_tables,
        };
    }

    /// Prompt dock footer: stage tip while guided, else a light workbench nudge.
    pub fn promptFooter(self: *const Progress) []const u8 {
        if (self.guide_active) return self.nextStep();
        return copy.workbench_footer;
    }
};

pub const Pane = enum { exports, imports, answers };

pub fn parseTourPane(name: []const u8) ?Pane {
    if (std.mem.eql(u8, name, "exports") or std.mem.eql(u8, name, "export")) return .exports;
    if (std.mem.eql(u8, name, "imports") or std.mem.eql(u8, name, "import")) return .imports;
    if (std.mem.eql(u8, name, "answers") or std.mem.eql(u8, name, "answer")) return .answers;
    return null;
}

pub fn gloss(verb: []const u8) []const u8 {
    return copy.gloss(verb);
}
