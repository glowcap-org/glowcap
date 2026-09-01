//! Agent file verbs and dispatch for `pancake app rooms-peer`.
const std = @import("std");
const exit_codes = @import("../../exit_codes.zig");
const log = @import("../../operability/log.zig");
const common = @import("common.zig");
const harness = @import("harness.zig");
const files = @import("harness/files.zig");
const ledger = @import("harness/ledger.zig");
const peer = @import("peer.zig");
const supervise = @import("supervise.zig");
const supervise_json = @import("supervise/json.zig");
const Flags = @import("flags.zig").Flags;

const Io = common.Io;
const Allocator = common.Allocator;
const emitStdout = common.emitStdout;
const emitStdoutFmt = common.emitStdoutFmt;
const reply_placeholder = common.reply_placeholder;

const Pending = ledger.Pending;
const loadReplied = ledger.loadReplied;
const markReplied = ledger.markReplied;
const readFile = files.readFile;
const scanInbox = ledger.scanInbox;
const stateField = harness.stateField;

const Json = supervise_json.Document;
const emitInternalError = supervise_json.emitInternalError;
const runPeer = peer.runPeer;
const peerCliPrefix = supervise.peerCliPrefix;
const observeProcess = supervise.observeProcess;
const runStart = supervise.runStart;
const runStop = supervise.runStop;
const selfExePath = supervise.selfExePath;

fn emitOperationFailure(io: Io, err: anyerror) error{PeerFailed} {
    // best-effort: the returned PeerFailed still carries the failure; only
    // the JSON detail line is lost if stdout refuses.
    emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"persistence\",\"detail\":\"{s}\"}}\n", .{@errorName(err)}) catch {};
    return error.PeerFailed;
}

// --- tick -------------------------------------------------------------------

fn inboxSize(io: Io, gpa: Allocator, dir: []const u8) !usize {
    const c = try readFile(io, gpa, dir, "inbox.jsonl");
    defer gpa.free(c);
    return c.len;
}

/// The unanswered inbound lines, deduped against replied.json and sorted the way
/// a present person answers: DMs first, then `@you` mentions, then the room.
/// Every unanswered message from someone else, `@`-mentions of this nick sorted
/// first. There is no relevance gate: `tick` hands the agent the room as it is,
/// so the peer stays a full participant and never silently drops a message
/// because it lacked an exact `@nick`. The agent decides what to say back.
fn computePending(arena: Allocator, io: Io, dir: []const u8, nick: []const u8) !std.ArrayList(Pending) {
    const replied = try loadReplied(arena, io, dir);
    const scanned = try scanInbox(arena, io, dir, nick);
    var out: std.ArrayList(Pending) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .{};
    for (scanned.items) |item| {
        if (replied.contains(item.id) or seen.contains(item.id)) continue;
        try seen.put(arena, item.id, {});
        try out.append(arena, item);
    }
    ledger.sortPending(out.items);
    return out;
}

fn runTick(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.dir.len == 0) {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"tick needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const nick = stateField(io, gpa, flags.dir, "nick") catch |err|
        return emitOperationFailure(io, err);
    defer gpa.free(nick);
    var exe_buf: [4096]u8 = undefined;
    const exe = selfExePath(io, &exe_buf) catch |err| return emitOperationFailure(io, err);

    const observation = observeProcess(io, gpa, flags.dir) catch |err| return emitOperationFailure(io, err);
    const peer_up = observation == .running;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var pending = computePending(arena_state.allocator(), io, flags.dir, nick) catch |err|
        return emitOperationFailure(io, err);

    // Block up to --wait seconds only when nothing is pending yet.
    if (pending.items.len == 0 and flags.wait > 0 and peer_up) {
        var last = inboxSize(io, gpa, flags.dir) catch |err|
            return emitOperationFailure(io, err);
        var waited: u64 = 0;
        const budget = flags.wait * 1000;
        while (waited < budget) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .real) catch |err|
                return emitOperationFailure(io, err);
            waited += 50;
            const cur = inboxSize(io, gpa, flags.dir) catch |err|
                return emitOperationFailure(io, err);
            if (cur != last) {
                last = cur;
                arena_state.deinit();
                arena_state = std.heap.ArenaAllocator.init(gpa);
                pending = computePending(arena_state.allocator(), io, flags.dir, nick) catch |err|
                    return emitOperationFailure(io, err);
                if (pending.items.len > 0) break;
            }
        }
    }

    const roster_final = ledger.loadRosterNicks(arena_state.allocator(), io, gpa, flags.dir) catch |err|
        return emitOperationFailure(io, err);

    // Hints steer agent harnesses: a Task subagent that final-answers after
    // background-arming tick orphans the wake loop (peer up, Task gone).
    const hint = if (!peer_up)
        (std.fmt.allocPrint(arena_state.allocator(), "peer is down — restart it: {s} {s}start --dir {s} --nick {s}", .{ exe, peerCliPrefix(exe), flags.dir, if (nick.len > 0) nick else "<NICK>" }) catch |err|
            return emitOperationFailure(io, err))
    else if (pending.items.len > 0)
        "answer each one: run its 'reply' command with your words in place of 'YOUR REPLY HERE', then run tick again and wait for it to return (do not end the agent Task / final-answer after arming). dismiss any you don't want to answer."
    else
        "nothing pending — do assigned work if any, then run tick again and wait for it (do not final-answer / complete the Task while the peer is up)";

    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildTick(&doc, arena_state.allocator(), exe, flags.dir, peer_up, pending.items, hint, roster_final) catch
        return emitInternalError(io);
    try emitStdout(io, bytes);
}

const PendingChannels = struct { dm: usize, room: usize };

fn countPendingChannels(pending: []const Pending) PendingChannels {
    var dm: usize = 0;
    var room: usize = 0;
    for (pending) |item| {
        if (std.mem.eql(u8, item.channel, "dm")) dm += 1 else room += 1;
    }
    return .{ .dm = dm, .room = room };
}

fn buildTick(
    doc: *Json,
    arena: Allocator,
    exe: []const u8,
    dir: []const u8,
    peer_up: bool,
    pending: []const Pending,
    hint: []const u8,
    roster: []const []const u8,
) ![]const u8 {
    const ch = countPendingChannels(pending);
    try doc.beginObject();
    try doc.string("peer", if (peer_up) "up" else "down");
    try doc.number("n", pending.len);
    var by_buf: [64]u8 = undefined;
    const by = try std.fmt.bufPrint(&by_buf, "{{\"dm\":{d},\"room\":{d}}}", .{ ch.dm, ch.room });
    try doc.rawValue("by_channel", by);
    // Honest room-surface flag (includes peer chatter).
    try doc.boolean("room_pending", ch.room > 0);
    // Human-only when DIR/roster.json lists bot nicks; else false (no FP).
    try doc.boolean("human_room_pending", ledger.humanRoomPending(pending, roster));
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
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"reply needs --dir and --text\"}}\n", .{});
        return error.UsageFailed;
    }
    if (std.mem.eql(u8, flags.text, reply_placeholder)) {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"placeholder\",\"detail\":\"replace 'YOUR REPLY HERE' with your actual message\"}}\n", .{});
        return error.UsageFailed;
    }
    harness.appendOutbox(io, gpa, flags.dir, flags.text, if (flags.dm.len > 0) flags.dm else null) catch |err|
        return emitOperationFailure(io, err);
    // --id folds the mark into the reply, so there is no separate done step.
    var marked = false;
    // A ledger write that failed is reported, not counted: the caller acts on
    // `marked` to decide whether the message is answered.
    if (flags.id.len > 0) {
        marked = (markReplied(io, gpa, flags.dir, &.{flags.id}) catch |err|
            return emitOperationFailure(io, err)) > 0;
    }
    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildReplied(&doc, flags.id, marked) catch return emitInternalError(io);
    try emitStdout(io, bytes);
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
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"dismiss needs --dir and either --id ID or --all\"}}\n", .{});
        return error.UsageFailed;
    }
    var count: usize = 0;
    if (flags.all) {
        const nick = stateField(io, gpa, flags.dir, "nick") catch |err|
            return emitOperationFailure(io, err);
        defer gpa.free(nick);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const pending = computePending(arena_state.allocator(), io, flags.dir, nick) catch |err|
            return emitOperationFailure(io, err);
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        for (pending.items) |item| ids.append(gpa, item.id) catch |err| return emitOperationFailure(io, err);
        count = markReplied(io, gpa, flags.dir, ids.items) catch |err| return emitOperationFailure(io, err);
    } else {
        count = markReplied(io, gpa, flags.dir, &.{flags.id}) catch |err| return emitOperationFailure(io, err);
    }
    var nb: [16]u8 = undefined;
    try emitStdoutFmt(io, "{{\"ok\":true,\"dismissed\":{s}}}\n", .{std.fmt.bufPrint(&nb, "{d}", .{count}) catch "0"});
}

// --- status -----------------------------------------------------------------

fn runStatus(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0) {
        try emitStdoutFmt(io, "{{\"ok\":false,\"error\":\"usage\",\"detail\":\"status needs --dir\"}}\n", .{});
        return error.UsageFailed;
    }
    const observation = try observeProcess(io, gpa, flags.dir);
    const pid: ?i32 = switch (observation) {
        .running => |value| value,
        .none, .unconfirmed => null,
    };
    const peer_status = switch (observation) {
        .running => "up",
        .none => "down",
        .unconfirmed => "unconfirmed",
    };
    const state = try readFile(io, gpa, flags.dir, "state.json");
    defer gpa.free(state);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const nick = stateField(io, gpa, flags.dir, "nick") catch |err|
        return emitOperationFailure(io, err);
    defer gpa.free(nick);
    const pending = computePending(arena_state.allocator(), io, flags.dir, nick) catch |err|
        return emitOperationFailure(io, err);

    const backlog = harness.outboxBacklogBytes(io, gpa, flags.dir) catch |err|
        return emitOperationFailure(io, err);
    const ch = countPendingChannels(pending.items);
    const roster = ledger.loadRosterNicks(arena_state.allocator(), io, gpa, flags.dir) catch |err|
        return emitOperationFailure(io, err);
    const human_room = ledger.humanRoomPending(pending.items, roster);

    var doc = Json.init(gpa);
    defer doc.deinit();
    const bytes = buildStatus(&doc, peer_status, pid, pending.items.len, ch, human_room, backlog, state) catch
        return emitInternalError(io);
    try emitStdout(io, bytes);
}

fn buildStatus(
    doc: *Json,
    peer_status: []const u8,
    pid: ?i32,
    pending: usize,
    ch: PendingChannels,
    human_room: bool,
    backlog: usize,
    state: []const u8,
) ![]const u8 {
    try doc.beginObject();
    try doc.boolean("ok", std.mem.eql(u8, peer_status, "up"));
    try doc.string("peer", peer_status);
    if (pid) |p| try doc.number("pid", p) else try doc.rawValue("pid", "null");
    try doc.number("pending", pending);
    var by_buf: [64]u8 = undefined;
    const by = try std.fmt.bufPrint(&by_buf, "{{\"dm\":{d},\"room\":{d}}}", .{ ch.dm, ch.room });
    try doc.rawValue("by_channel", by);
    try doc.boolean("room_pending", ch.room > 0);
    try doc.boolean("human_room_pending", human_room);
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
    \\`--dm PEER` sends a direct message off-room. The peer reuses a live reply
    \\capability or asks the room directory to introduce the target on first contact.
    \\Example:
    \\  pancake app rooms-peer start --nick Alice --dir /tmp/rooms-peer-alice --room general
    \\
;

/// Print usage and hand back the soft failure `verbExit` maps to the usage
/// code. Exiting the process here instead would skip `main`'s context
/// teardown, and the identity state lock is released there.
fn usageFailed(io: Io) error{UsageFailed} {
    emitStdout(io, usage_text) catch return error.UsageFailed;
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
