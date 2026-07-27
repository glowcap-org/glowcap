//! Agent file verbs and dispatch for `pancake app rooms-peer`.
const std = @import("std");
const exit_codes = @import("../../exit_codes.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const peer = @import("peer.zig");
const supervise = @import("supervise.zig");
const Flags = @import("flags.zig").Flags;

const Io = common.Io;
const Allocator = common.Allocator;
const emitStdout = common.emitStdout;
const emitStdoutFmt = common.emitStdoutFmt;
const reply_placeholder = common.reply_placeholder;

const Pending = harness.Pending;
const appendLine = harness.appendLine;
const loadReplied = harness.loadReplied;
const markReplied = harness.markReplied;
const readFile = harness.readFile;
const scanInbox = harness.scanInbox;
const stateField = harness.stateField;
const writeJsonString = harness.writeJsonString;

const Json = supervise.Json;
const emitInternalError = supervise.emitInternalError;
const runPeer = peer.runPeer;
const peerCliPrefix = supervise.peerCliPrefix;
const pidAlive = supervise.pidAlive;
const readPid = supervise.readPid;
const runStart = supervise.runStart;
const runStop = supervise.runStop;
const selfExePath = supervise.selfExePath;

// --- tick -------------------------------------------------------------------

fn inboxSize(io: Io, gpa: Allocator, dir: []const u8) usize {
    const c = readFile(io, gpa, dir, "inbox.jsonl") catch return 0;
    defer gpa.free(c);
    return c.len;
}

/// The unanswered inbound lines, deduped against replied.json and sorted the way
/// a present person answers: DMs first, then `@you` mentions, then the room.
/// Every unanswered message from someone else, `@`-mentions of this nick sorted
/// first. There is no relevance gate: `tick` hands the agent the room as it is,
/// so the peer stays a full participant and never silently drops a message
/// because it lacked an exact `@nick`. The agent decides what to say back.
fn computePending(arena: Allocator, io: Io, dir: []const u8, nick: []const u8) std.ArrayList(Pending) {
    const replied = loadReplied(arena, io, dir);
    const scanned = scanInbox(arena, io, dir, nick);
    var out: std.ArrayList(Pending) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .{};
    for (scanned.items) |item| {
        if (replied.contains(item.id) or seen.contains(item.id)) continue;
        seen.put(arena, item.id, {}) catch {};
        out.append(arena, item) catch {};
    }
    std.mem.sort(Pending, out.items, {}, pendingLess);
    return out;
}

fn pendingRank(p: Pending) u8 {
    if (std.mem.eql(u8, p.channel, "dm")) return 0;
    return if (p.mention) 1 else 2;
}

fn pendingLess(_: void, a: Pending, b: Pending) bool {
    const ra = pendingRank(a);
    const rb = pendingRank(b);
    if (ra != rb) return ra < rb;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn runTick(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.dir.len == 0) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"tick needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const nick = stateField(io, gpa, flags.dir, "nick");
    defer gpa.free(nick);
    var exe_buf: [4096]u8 = undefined;
    const exe = selfExePath(io, &exe_buf);

    const pid = readPid(io, gpa, flags.dir);
    const peer_up = pid != null and pidAlive(io, gpa, pid.?);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var pending = computePending(arena_state.allocator(), io, flags.dir, nick);

    // Block up to --wait seconds only when nothing is pending yet.
    if (pending.items.len == 0 and flags.wait > 0 and peer_up) {
        var last = inboxSize(io, gpa, flags.dir);
        var waited: u64 = 0;
        const budget = flags.wait * 1000;
        while (waited < budget) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .real) catch {};
            waited += 200;
            const cur = inboxSize(io, gpa, flags.dir);
            if (cur != last) {
                last = cur;
                arena_state.deinit();
                arena_state = std.heap.ArenaAllocator.init(gpa);
                pending = computePending(arena_state.allocator(), io, flags.dir, nick);
                if (pending.items.len > 0) break;
            }
        }
    }

    const hint = if (!peer_up)
        (std.fmt.allocPrint(arena_state.allocator(), "peer is down — restart it: {s} {s}start --dir {s} --nick {s}", .{ exe, peerCliPrefix(exe), flags.dir, if (nick.len > 0) nick else "<NICK>" }) catch "peer is down — run `start` again")
    else if (pending.items.len > 0)
        "answer each one: run its 'reply' command with your words in place of 'YOUR REPLY HERE', then arm the next background tick. dismiss any you don't want to answer."
    else
        "nothing pending — do your own work, then arm the next background tick";

    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildTick(&doc, arena_state.allocator(), exe, flags.dir, peer_up, pending.items, hint) catch
        return emitInternalError(io);
    emitStdout(io, bytes);
}

fn buildTick(
    doc: *Json,
    arena: Allocator,
    exe: []const u8,
    dir: []const u8,
    peer_up: bool,
    pending: []const Pending,
    hint: []const u8,
) ![]const u8 {
    try doc.beginObject();
    try doc.string("peer", if (peer_up) "up" else "down");
    try doc.number("n", pending.len);
    try doc.arrayMember("pending");
    for (pending) |item| {
        try doc.beginObject();
        try doc.string("id", item.id);
        try doc.string("channel", item.channel);
        try doc.string("author", item.author);
        try doc.string("text", item.text);
        if (item.peer.len > 0) try doc.string("peer", item.peer);
        try doc.string("reply", try replyCommand(arena, exe, dir, item));
        try doc.end();
    }
    try doc.end();
    try doc.string("hint", hint);
    try doc.end();
    return doc.line();
}

fn replyCommand(gpa: Allocator, exe: []const u8, dir: []const u8, item: Pending) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(gpa, exe);
    try b.appendSlice(gpa, " ");
    try b.appendSlice(gpa, peerCliPrefix(exe));
    try b.appendSlice(gpa, "reply --dir ");
    try b.appendSlice(gpa, dir);
    try b.appendSlice(gpa, " --id ");
    try b.appendSlice(gpa, item.id);
    if (std.mem.eql(u8, item.channel, "dm") and item.peer.len > 0) {
        try b.appendSlice(gpa, " --dm ");
        try b.appendSlice(gpa, item.peer);
    }
    try b.appendSlice(gpa, " --text '" ++ reply_placeholder ++ "'");
    return b.items;
}

// --- reply ------------------------------------------------------------------

fn runReply(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0 or flags.text.len == 0) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"reply needs --dir and --text\"}}\n", .{});
        return error.UsageFailed;
    }
    if (std.mem.eql(u8, flags.text, reply_placeholder)) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"placeholder\",\"detail\":\"replace 'YOUR REPLY HERE' with your actual message\"}}\n", .{});
        return error.UsageFailed;
    }
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    if (flags.dm.len > 0) {
        try list.appendSlice(gpa, "{\"channel\":\"dm\",\"peer\":");
        try writeJsonString(&list, gpa, flags.dm);
        try list.appendSlice(gpa, ",\"text\":");
        try writeJsonString(&list, gpa, flags.text);
        try list.append(gpa, '}');
    } else {
        try list.appendSlice(gpa, "{\"channel\":\"room\",\"text\":");
        try writeJsonString(&list, gpa, flags.text);
        try list.append(gpa, '}');
    }
    try appendLine(io, gpa, flags.dir, "outbox.jsonl", list.items);
    // --id folds the mark into the reply, so there is no separate done step.
    var marked = false;
    // A ledger write that failed is reported, not counted: the caller acts on
    // `marked` to decide whether the message is answered.
    if (flags.id.len > 0) marked = (markReplied(io, gpa, flags.dir, &.{flags.id}) catch 0) > 0;
    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildReplied(&doc, flags.id, marked) catch return emitInternalError(io);
    emitStdout(io, bytes);
}

fn buildReplied(doc: *Json, id: []const u8, marked: bool) ![]const u8 {
    try doc.beginObject();
    try doc.boolean("ok", true);
    if (id.len > 0) try doc.string("answered_id", id) else try doc.rawValue("answered_id", "null");
    try doc.boolean("marked", marked);
    try doc.end();
    return doc.line();
}

// --- dismiss ----------------------------------------------------------------

/// Mark messages answered WITHOUT posting to the room — the silent counterpart
/// to `reply`. `--id ID` clears one; `--all` clears every currently-pending
/// message. Use it to drop chatter, duplicates, or another peer's noise without
/// speaking. It writes the same `replied.json` ledger `reply` marks, so a
/// dismissed message never resurfaces in `tick`.
fn runDismiss(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0 or (flags.id.len == 0 and !flags.all)) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"dismiss needs --dir and either --id ID or --all\"}}\n", .{});
        return error.UsageFailed;
    }
    var count: usize = 0;
    if (flags.all) {
        const nick = stateField(io, gpa, flags.dir, "nick");
        defer gpa.free(nick);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const pending = computePending(arena_state.allocator(), io, flags.dir, nick);
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        for (pending.items) |item| ids.append(gpa, item.id) catch {};
        count = markReplied(io, gpa, flags.dir, ids.items) catch 0;
    } else {
        count = markReplied(io, gpa, flags.dir, &.{flags.id}) catch 0;
    }
    var nb: [16]u8 = undefined;
    emitStdoutFmt(io, "{{\"ok\":true,\"dismissed\":{s}}}\n", .{std.fmt.bufPrint(&nb, "{d}", .{count}) catch "0"});
}

// --- status -----------------------------------------------------------------

fn runStatus(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0) {
        emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"status needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const pid = readPid(io, gpa, flags.dir);
    const up = pid != null and pidAlive(io, gpa, pid.?);
    const state = try readFile(io, gpa, flags.dir, "state.json");
    defer gpa.free(state);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const nick = stateField(io, gpa, flags.dir, "nick");
    defer gpa.free(nick);
    const pending = computePending(arena_state.allocator(), io, flags.dir, nick);

    const backlog = harness.outboxBacklogBytes(io, gpa, flags.dir);

    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildStatus(&doc, up, pid, pending.items.len, backlog, state) catch
        return emitInternalError(io);
    emitStdout(io, bytes);
}

fn buildStatus(doc: *Json, up: bool, pid: ?i32, pending: usize, backlog: usize, state: []const u8) ![]const u8 {
    try doc.beginObject();
    try doc.boolean("ok", up);
    try doc.string("peer", if (up) "up" else "down");
    if (pid) |p| try doc.number("pid", p) else try doc.rawValue("pid", "null");
    try doc.number("pending", pending);
    try doc.number("outbox_backlog", backlog);
    // state.json is spliced whole: it is already a JSON document.
    try doc.rawValue("state", if (state.len > 0) state else "null");
    try doc.end();
    return doc.line();
}

// --- main -------------------------------------------------------------------

const usage_text =
    \\pancake app rooms-peer — join a pancake chat room as a background peer and answer messages.
    \\
    \\Usage: pancake app rooms-peer <verb> [flags]
    \\       rooms-peer <verb> [flags]          (install alias)
    \\
    \\  start   --nick NICK --dir DIR [--room ROOM] [--locator LOC] [--identity PATH]
    \\  tick    --dir DIR [--wait N]                                  unanswered room/DM messages
    \\  reply   --dir DIR --id ID --text '...' [--dm PEER]            answer in-room or by DM
    \\  dismiss --dir DIR (--id ID | --all)                          clear message(s) without posting
    \\  stop    --dir DIR                                             leave and stop
    \\  status  --dir DIR                                             show state
    \\
    \\Identity defaults to DIR/identity (minted on first start). Pass --identity to pin another seed.
    \\`--dm PEER` sends a direct message via directory introduction (not the room channel).
    \\Example:
    \\  pancake app rooms-peer start --nick Alice --dir /tmp/rooms-peer-alice --room general
    \\
;

/// Print usage and hand back the soft failure `verbExit` maps to the usage
/// code. Exiting the process here instead would skip `main`'s context
/// teardown, which is what releases the identity state lock.
fn usageFailed(io: Io) error{UsageFailed} {
    emitStdout(io, usage_text);
    return error.UsageFailed;
}

/// Map rooms-peer soft failures to product exit codes (usage vs internal).
pub fn verbExit(err: anyerror) ?u8 {
    return switch (err) {
        error.UsageFailed, error.Unsupervised, error.MissingFlags => exit_codes.usage,
        error.PeerFailed => exit_codes.internal,
        else => null,
    };
}

/// Tree-dispatch entry (`pancake app rooms-peer <verb>`). Usage JSON → 2; operational soft fail → 1.
pub fn runVerb(init: std.process.Init, verb: []const u8, flags: Flags) !u8 {
    dispatchVerb(init, verb, flags) catch |err| {
        if (verbExit(err)) |code| return code;
        return err;
    };
    return 0;
}

fn dispatchVerb(init: std.process.Init, verb: []const u8, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (std.mem.eql(u8, verb, "start")) {
        try runStart(init, flags);
    } else if (std.mem.eql(u8, verb, "peer")) {
        try runPeer(init, flags);
    } else if (std.mem.eql(u8, verb, "tick")) {
        try runTick(init, flags);
    } else if (std.mem.eql(u8, verb, "reply")) {
        try runReply(io, gpa, flags);
    } else if (std.mem.eql(u8, verb, "dismiss")) {
        try runDismiss(io, gpa, flags);
    } else if (std.mem.eql(u8, verb, "stop")) {
        try runStop(init, flags);
    } else if (std.mem.eql(u8, verb, "status")) {
        try runStatus(io, gpa, flags);
    } else {
        log.err(io, "unknown verb \"{s}\"", .{verb});
        return usageFailed(io);
    }
}
