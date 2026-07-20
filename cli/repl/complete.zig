//! CapTP lab completion candidates (pure; hermetic tests).
const std = @import("std");
const registry = @import("../registry.zig");
const builtins = @import("../ocapn/builtins.zig");
const copy = @import("copy.zig");
const meta = @import("meta.zig");

pub const Candidate = struct {
    token: []const u8,
    detail: []const u8,
};

pub const State = struct {
    /// Names observed via successful fetch/call/publish in this REPL process.
    known_names: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator = undefined,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .gpa = gpa, .known_names = .empty };
    }

    pub fn deinit(self: *State) void {
        for (self.known_names.items) |n| self.gpa.free(n);
        self.known_names.deinit(self.gpa);
    }

    pub fn rememberName(self: *State, name: []const u8) !void {
        for (self.known_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return;
        }
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.known_names.append(self.gpa, owned);
    }
};

/// Fill `out` with candidates for `line` (cursor at end). Returns count written.
pub fn candidates(state: *const State, line: []const u8, out: []Candidate) usize {
    const trimmed = std.mem.trim(u8, line, " \t");
    var parts_buf: [16][]const u8 = undefined;
    var nparts: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |tok| {
        if (nparts >= parts_buf.len) break;
        parts_buf[nparts] = tok;
        nparts += 1;
    }
    const trailing_space = line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t');
    const prefix: []const u8 = if (nparts == 0 or trailing_space) "" else parts_buf[nparts - 1];
    const completing_verb = nparts == 0 or (nparts == 1 and !trailing_space);

    var written: usize = 0;
    if (completing_verb) {
        for (registry.commands) |cmd| {
            if (!registry.leafVisible(&cmd, .repl)) continue;
            written = pushIfPrefix(out, written, prefix, cmd.name, copy.gloss(cmd.name));
        }
        for (meta.entries) |e| {
            written = pushIfPrefix(out, written, prefix, e.name, e.gloss);
        }
        return written;
    }

    const verb = parts_buf[0];
    // Token index being completed: nparts when trailing space, else nparts-1.
    const slot: usize = if (trailing_space) nparts else nparts - 1;

    if (std.mem.eql(u8, verb, "publish") or std.mem.eql(u8, verb, "fetch")) {
        if (slot == 1) {
            written = pushNames(state, out, written, prefix);
        }
    } else if (std.mem.eql(u8, verb, "call") or std.mem.eql(u8, verb, "tell")) {
        if (slot == 1) {
            written = pushNames(state, out, written, prefix);
        } else if (slot == 2) {
            // One owner for the demo verb set: the actors' own table.
            for (builtins.demo_verbs) |v| {
                written = pushIfPrefix(out, written, prefix, v.name, v.blurb);
            }
        }
    } else if (std.mem.eql(u8, verb, "tour")) {
        if (slot == 1) {
            written = pushIfPrefix(out, written, prefix, "exports", copy.tourBlurb("exports"));
            written = pushIfPrefix(out, written, prefix, "imports", copy.tourBlurb("imports"));
            written = pushIfPrefix(out, written, prefix, "answers", copy.tourBlurb("answers"));
        }
    } else if (std.mem.eql(u8, verb, "help")) {
        if (slot == 1) {
            written = pushIfPrefix(out, written, prefix, "captp", "CapTP noun map");
        }
    }
    return written;
}

fn pushNames(state: *const State, out: []Candidate, written0: usize, prefix: []const u8) usize {
    var written = written0;
    for (builtins.names) |b| {
        written = pushIfPrefix(out, written, prefix, b, "CLI demo actor name");
    }
    for (state.known_names.items) |n| {
        written = pushIfPrefix(out, written, prefix, n, "Session-known published name");
    }
    return written;
}

fn pushIfPrefix(out: []Candidate, written: usize, prefix: []const u8, token: []const u8, detail: []const u8) usize {
    if (written >= out.len) return written;
    if (prefix.len > 0 and !std.mem.startsWith(u8, token, prefix)) return written;
    for (out[0..written]) |c| {
        if (std.mem.eql(u8, c.token, token)) return written;
    }
    out[written] = .{ .token = token, .detail = detail };
    return written + 1;
}

/// Wrap menu selection by `delta` (+1 Tab, -1 Shift-Tab). Pure; hermetic tests.
pub fn cycleSel(sel: usize, n: usize, delta: i8) usize {
    if (n == 0) return 0;
    if (delta >= 0) return (sel + 1) % n;
    return if (sel == 0) n - 1 else sel - 1;
}

/// First visible menu row so `sel` stays on-screen in a viewport of `visible` rows.
pub fn menuScrollStart(sel: usize, n: usize, visible: usize) usize {
    if (visible == 0 or n == 0) return 0;
    if (sel < visible) return 0;
    const max_start = if (n > visible) n - visible else 0;
    const want = sel + 1 - visible;
    return @min(want, max_start);
}
