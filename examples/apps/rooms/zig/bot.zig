//! The persistent pancake rooms bot, native Zig — a self-contained CapTP peer an
//! agent runs to be present in a room while it works. This is the all-Zig
//! replacement for the `.agents/skills/rooms-bot` Python scripts, and it
//! dogfoods pancake from an agent's seat on the same core every binding wraps.
//!
//!   rooms-bot start  --dir DIR --nick NICK [--room ROOM] [--locator LOC]
//!   rooms-bot tick   --dir DIR [--wait SECONDS]
//!   rooms-bot reply  --dir DIR [--id ID] --text '...'
//!   rooms-bot stop   --dir DIR
//!   rooms-bot status --dir DIR
//!   rooms-bot peer   --dir DIR --nick NICK --room ROOM --locator LOC   (internal)
//!
//! `start` launches the background daemon (`peer`) detached, so it outlives the
//! launching shell, and waits until it reports `"joined"`. `peer` never runs on
//! its own: it refuses to start unless `start` set `ROOMS_BOT_SUPERVISED`, so an
//! agent cannot hand-roll an undetached `peer &` that dies when its shell is
//! reaped. `stop` reaps it cleanly with SIGTERM. `tick`/`reply`/`status` are pure
//! file operations over the harness dir, so an agent drives the bot without
//! touching the wire.
//!
//! The daemon runs on the completion loop, not the blocking session, and that is
//! the whole point. A blocking iroh session has no pollable socket to select on,
//! so its `step` parks inside the sidecar read and only wakes when the partner
//! sends something. A bot that must speak first on a quiet room — post a queued
//! line while nobody is talking — cannot live there. `driver.Bridge` over
//! `net.completion.Loop` serves inbound and acts outbound on one thread, and the
//! iroh backend's poll returns on a timeout, so the loop wakes on its own cadence
//! (ADR-0057, ADR-0076). The bot drives `runUntil` against a wake flag a small
//! timer future flips, and drains the outbox each time the loop hands control
//! back — so a post goes out whether or not the room ever said a word.
//!
//! Scope: room chat both ways, plus the file harness and its supervision. Direct
//! messages by introduction are the remaining milestone: they need a second iroh
//! endpoint so the directory's dial-back does not collide with the room dial on
//! the same node (crossed hellos). A `reply --dm` is held in the outbox rather
//! than posted into the public room.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const IrohLoop = net.completion.Loop(iroh.Backend, iroh.DialResolver);
const IrohBridge = driver.Bridge(IrohLoop);

const Io = std.Io;
const Allocator = std.mem.Allocator;
const frame_cap: usize = 1 << 16;
const timer_ms: u64 = 150;
/// Wake ticks (~2s at timer_ms) to wait between redials, so a down room is
/// retried steadily rather than thrashed every tick.
const redial_cooldown_wakes: u32 = 13;
/// The dial establishment deadline (ADR-0081 contract 2). A redial to a down
/// room otherwise rides the sidecar's far longer built-in fallback, and
/// `closeAndDrain` parks teardown on that in-flight connect — so a stop landing
/// mid-dial cannot finish before `stop`'s 6s SIGTERM grace escalates to SIGKILL.
/// Bounding the dial keeps teardown well under that grace while leaving headroom
/// for a healthy discovery/relay establishment.
const dial_timeout_ms: u64 = 4000;
const file_cap = Io.Limit.limited(1 << 24);
const default_locator = "http://pancake-rooms:8000/locator";
const reply_placeholder = "YOUR REPLY HERE";
const replied_cap: usize = 1200;

/// Set by the SIGTERM/SIGINT handler; the daemon's loop and timer both watch it
/// and stop promptly, so `stop` reaps the peer without escalating to SIGKILL.
var g_stop = std.atomic.Value(bool).init(false);
// These outlive an iroh-stack rebuild: the supervisor tears the per-attempt
// stack (and its BotState) down on a fatal loop error and builds a fresh one, so
// the wake flag, the outbox drain offset, and the "did we ever join this attempt"
// signal live at process scope.
var g_wake = std.atomic.Value(bool).init(false);
var g_offset: usize = 0;
var g_ever_joined: bool = false;

fn handleStopSignal(_: std.posix.SIG) callconv(.c) void {
    g_stop.store(true, .release);
}

// --- flags ------------------------------------------------------------------

const Flags = struct {
    dir: []const u8 = "",
    nick: []const u8 = "",
    room: []const u8 = "general",
    locator: []const u8 = "",
    text: []const u8 = "",
    dm: []const u8 = "",
    id: []const u8 = "",
    wait: u64 = 0,
    all: bool = false,

    fn parse(args: *std.process.Args.Iterator) Flags {
        var f = Flags{};
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--dir")) {
                f.dir = args.next() orelse "";
            } else if (std.mem.eql(u8, a, "--nick")) {
                f.nick = args.next() orelse "";
            } else if (std.mem.eql(u8, a, "--room")) {
                f.room = args.next() orelse "general";
            } else if (std.mem.eql(u8, a, "--locator")) {
                f.locator = args.next() orelse "";
            } else if (std.mem.eql(u8, a, "--text")) {
                f.text = args.next() orelse "";
            } else if (std.mem.eql(u8, a, "--dm")) {
                f.dm = args.next() orelse "";
            } else if (std.mem.eql(u8, a, "--id")) {
                f.id = args.next() orelse "";
            } else if (std.mem.eql(u8, a, "--wait")) {
                f.wait = std.fmt.parseInt(u64, args.next() orelse "0", 10) catch 0;
            } else if (std.mem.eql(u8, a, "--all")) {
                f.all = true;
            }
        }
        return f;
    }
};

// --- harness files ----------------------------------------------------------

fn pathIn(buf: []u8, dir: []const u8, leaf: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, leaf }) catch leaf;
}

/// Read DIR/leaf, or an empty (owned) slice if it does not exist.
fn readFile(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8) ![]u8 {
    var pbuf: [512]u8 = undefined;
    const path = pathIn(&pbuf, dir, leaf);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, file_cap) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
}

fn overwriteFile(io: Io, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
    var pbuf: [512]u8 = undefined;
    const path = pathIn(&pbuf, dir, leaf);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn removeFile(io: Io, dir: []const u8, leaf: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const path = pathIn(&pbuf, dir, leaf);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Append a line to DIR/leaf. There is no seek in std.Io.File, so this is
/// read-modify-write — fine for the small, session-bounded harness files.
fn appendLine(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
    const old = try readFile(io, gpa, dir, leaf);
    defer gpa.free(old);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, old);
    try list.appendSlice(gpa, bytes);
    try list.append(gpa, '\n');
    try overwriteFile(io, dir, leaf, list.items);
}

/// Write a JSON string literal (quotes + escaping) into an ArrayList.
fn writeJsonString(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var buf: [8]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "");
        } else try list.append(gpa, c),
    };
    try list.append(gpa, '"');
}

/// Append one inbound/outbound record to inbox.jsonl. `channel` is "room" or
/// "dm"; `peer` names the dm partner (empty on the room arm).
fn recordInbox(io: Io, gpa: Allocator, dir: []const u8, kind: []const u8, channel: []const u8, author: []const u8, text: []const u8, peer: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "{\"kind\":");
    try writeJsonString(&list, gpa, kind);
    try list.appendSlice(gpa, ",\"channel\":");
    try writeJsonString(&list, gpa, channel);
    try list.appendSlice(gpa, ",\"author\":");
    try writeJsonString(&list, gpa, author);
    try list.appendSlice(gpa, ",\"text\":");
    try writeJsonString(&list, gpa, text);
    if (peer.len > 0) {
        try list.appendSlice(gpa, ",\"peer\":");
        try writeJsonString(&list, gpa, peer);
    }
    try list.append(gpa, '}');
    try appendLine(io, gpa, dir, "inbox.jsonl", list.items);
}

fn writeState(io: Io, gpa: Allocator, dir: []const u8, status: []const u8, nick: []const u8, room: []const u8, locator: []const u8) void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    list.appendSlice(gpa, "{\"status\":") catch return;
    writeJsonString(&list, gpa, status) catch return;
    list.appendSlice(gpa, ",\"nick\":") catch return;
    writeJsonString(&list, gpa, nick) catch return;
    list.appendSlice(gpa, ",\"room\":") catch return;
    writeJsonString(&list, gpa, room) catch return;
    list.appendSlice(gpa, ",\"locator\":") catch return;
    writeJsonString(&list, gpa, locator) catch return;
    list.append(gpa, '}') catch return;
    overwriteFile(io, dir, "state.json", list.items) catch return;
}

/// One string field out of state.json, owned; empty when absent.
fn stateField(io: Io, gpa: Allocator, dir: []const u8, key: []const u8) []u8 {
    const raw = readFile(io, gpa, dir, "state.json") catch return gpa.dupe(u8, "") catch unreachable;
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return gpa.dupe(u8, "") catch unreachable;
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get(key)) |v| {
            if (v == .string) return gpa.dupe(u8, v.string) catch "";
        }
    }
    return gpa.dupe(u8, "") catch "";
}

// --- replied ledger + pending scan ------------------------------------------

/// A stable id for one inbound line: its byte offset in inbox.jsonl (append-only,
/// so it never shifts) folded with the content. Two identical messages at
/// different offsets stay distinct, and re-scanning the same file reproduces the
/// same id, which is what lets `reply --id` mark it answered.
fn lineId(gpa: Allocator, offset: usize, author: []const u8, text: []const u8, channel: []const u8, peer: []const u8) []u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&offset));
    h.update(author);
    h.update("\x00");
    h.update(text);
    h.update("\x00");
    h.update(channel);
    h.update("\x00");
    h.update(peer);
    return std.fmt.allocPrint(gpa, "{x:0>16}", .{h.final()}) catch "";
}

/// One unanswered inbound line, as `tick` surfaces it.
const Pending = struct {
    id: []const u8,
    channel: []const u8,
    author: []const u8,
    text: []const u8,
    peer: []const u8,
    mention: bool,
};

/// Scan inbox.jsonl for inbound lines from someone else (`kind == "msg"`),
/// tagging each with its stable id. Our own `sent` echoes and `system` lines
/// fall out on the kind check. Everything is allocated in `arena`.
fn scanInbox(arena: Allocator, io: Io, dir: []const u8, nick: []const u8) std.ArrayList(Pending) {
    var items: std.ArrayList(Pending) = .empty;
    const contents = readFile(io, arena, dir, "inbox.jsonl") catch return items;
    const self_lower = std.ascii.allocLowerString(arena, nick) catch nick;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line_offset = offset;
        offset += raw.len + 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        if (!std.mem.eql(u8, strField(obj, "kind"), "msg")) continue;
        const author = std.mem.trim(u8, strField(obj, "author"), " ");
        const text = std.mem.trim(u8, strField(obj, "text"), " ");
        if (author.len == 0 or text.len == 0) continue;
        const author_lower = std.ascii.allocLowerString(arena, author) catch author;
        if (std.mem.eql(u8, author_lower, self_lower)) continue;
        var channel = strField(obj, "channel");
        if (channel.len == 0) channel = "room";
        const peer = if (std.mem.eql(u8, channel, "dm")) blk: {
            const p = strField(obj, "peer");
            break :blk if (p.len > 0) p else author;
        } else "";
        const mention = blk: {
            const needle = std.fmt.allocPrint(arena, "@{s}", .{self_lower}) catch break :blk false;
            const tl = std.ascii.allocLowerString(arena, text) catch break :blk false;
            break :blk std.mem.indexOf(u8, tl, needle) != null;
        };
        items.append(arena, .{
            .id = lineId(arena, line_offset, author, text, channel, peer),
            .channel = arena.dupe(u8, channel) catch channel,
            .author = arena.dupe(u8, author) catch author,
            .text = arena.dupe(u8, text) catch text,
            .peer = arena.dupe(u8, peer) catch peer,
            .mention = mention,
        }) catch {};
    }
    return items;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// The answered-id ledger (replied.json, a JSON array of strings). Returns an
/// arena-backed set for membership tests.
fn loadReplied(arena: Allocator, io: Io, dir: []const u8) std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .{};
    const raw = readFile(io, arena, dir, "replied.json") catch return set;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return set;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |v| {
            if (v == .string) set.put(arena, v.string, {}) catch {};
        }
    }
    return set;
}

/// Fold `ids` into replied.json (dedup, newest last, capped). The one door that
/// writes the ledger. Returns how many were newly added.
fn markReplied(io: Io, gpa: Allocator, dir: []const u8, ids: []const []const u8) usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var order: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .{};
    const raw = readFile(io, arena, dir, "replied.json") catch "";
    if (std.json.parseFromSlice(std.json.Value, arena, raw, .{})) |parsed| {
        if (parsed.value == .array) {
            for (parsed.value.array.items) |v| {
                if (v == .string and !seen.contains(v.string)) {
                    seen.put(arena, v.string, {}) catch {};
                    order.append(arena, v.string) catch {};
                }
            }
        }
    } else |_| {}

    var added: usize = 0;
    for (ids) |id| {
        if (id.len == 0) continue;
        if (seen.contains(id)) continue;
        seen.put(arena, id, {}) catch {};
        order.append(arena, id) catch {};
        added += 1;
    }

    const start = if (order.items.len > replied_cap) order.items.len - replied_cap else 0;
    var out: std.ArrayList(u8) = .empty;
    out.append(arena, '[') catch {};
    for (order.items[start..], 0..) |id, i| {
        if (i > 0) out.append(arena, ',') catch {};
        writeJsonString(&out, arena, id) catch {};
    }
    out.append(arena, ']') catch {};
    overwriteFile(io, dir, "replied.json", out.items) catch {};
    return added;
}

// --- the peer daemon --------------------------------------------------------

/// Everything the loop thread, the timer future, and the inbox actor share. The
/// wire-facing fields are touched only on the loop-owner thread — inside a
/// serve/vow callback or between two `runUntil` returns — so they need no
/// synchronization. The one cross-thread word is the process-global `g_stop`,
/// which the signal handler sets and both the loop and the timer read.
const BotState = struct {
    io: Io,
    gpa: Allocator,
    host: *Host,
    bridge: *IrohBridge,

    dir: []const u8,
    nick: []const u8,
    room_name: []const u8,
    locator_str: []const u8,
    transport: []const u8,
    designator: []const u8,
    hint: []const u8,

    session: ?*HostSession = null,
    directory: ?model.Reference = null,
    room: ?model.Reference = null,
    joined: bool = false,
    dialing: bool = false,
    redial_cooldown: u32 = 0,

    fn stopRequested() bool {
        return g_stop.load(.acquire);
    }

    fn writeStateNow(self: *BotState, status: []const u8) void {
        writeState(self.io, self.gpa, self.dir, status, self.nick, self.room_name, self.locator_str);
    }
};

/// The room calls `notify(from, text, ...)` back on this exported inbox. A
/// presence line carries a string kind at args[2]; a plain chat line does not.
/// We record only chat lines from another member.
const RoomInbox = struct {
    state: *BotState,

    pub fn handle(self: *RoomInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "notify")) return error.NoSuchMethod;
        const from = if (msg.args.len > 0 and msg.args[0] == .string) msg.args[0].string else "";
        const text = if (msg.args.len > 1 and msg.args[1] == .string) msg.args[1].string else "";
        const is_presence = msg.args.len >= 3 and msg.args[2] == .string;
        if (!is_presence and from.len > 0 and !std.mem.eql(u8, from, "room") and !std.mem.eql(u8, from, self.state.nick)) {
            recordInbox(self.state.io, self.state.gpa, self.state.dir, "msg", "room", from, text, "") catch {};
        }
        return .{ .void = {} };
    }
};

fn refOf(resolution: actors.Resolution) ?model.Reference {
    return switch (resolution) {
        .fulfilled => |value| if (value == .reference) value.reference else null,
        .broken, .give => null,
    };
}

/// Bridge `on_open`: the dialed room session opened. Fetch the directory; the
/// enter/open/subscribe chain runs from the settle callbacks.
fn onOpen(ctx: ?*anyopaque, bridge: *IrohBridge, slot: *IrohBridge.Slot) anyerror!void {
    _ = bridge;
    const state: *BotState = @ptrCast(@alignCast(ctx.?));
    state.session = slot.session;
    state.dialing = false;
    const vow = try state.host.fetch(slot.session, "directory");
    try state.host.vowOn(vow, .{ .ctx = state, .func = onDirectory });
}

fn onDirectory(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *BotState = @ptrCast(@alignCast(ctx.?));
    const directory = refOf(resolution) orelse {
        std.debug.print("rooms-bot: directory fetch did not fulfill\n", .{});
        return;
    };
    state.directory = directory;
    // The wire stays strict: `enter` breaks if the room is absent, `open` breaks
    // if the name is taken. Try enter, fall back to open, then enter once more on
    // a creation race — the same leniency the blocking client applies.
    sendDirectoryVerb(state, "enter", onEntered);
}

fn onEntered(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *BotState = @ptrCast(@alignCast(ctx.?));
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "open", onOpened);
    }
}

fn onOpened(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *BotState = @ptrCast(@alignCast(ctx.?));
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        sendDirectoryVerb(state, "enter", onEnteredAgain);
    }
}

fn onEnteredAgain(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *BotState = @ptrCast(@alignCast(ctx.?));
    if (refOf(resolution)) |room| {
        subscribeRoom(state, room);
    } else {
        std.debug.print("rooms-bot: could not enter or open room \"{s}\"\n", .{state.room_name});
    }
}

/// Eventual-send a directory verb naming the room, and wait on its answer.
fn sendDirectoryVerb(state: *BotState, verb: []const u8, cb: *const fn (?*anyopaque, actors.Resolution) void) void {
    const directory = state.directory orelse return;
    const session = state.session orelse return;
    const vow = state.host.send(session, directory, .{
        .verb = verb,
        .args = &.{.{ .string = state.room_name }},
    }) catch |err| {
        std.debug.print("rooms-bot: {s} send failed: {s}\n", .{ verb, @errorName(err) });
        return;
    };
    state.host.vowOn(vow, .{ .ctx = state, .func = cb }) catch |err| {
        std.debug.print("rooms-bot: {s} vowOn failed: {s}\n", .{ verb, @errorName(err) });
        return;
    };
    state.bridge.drainActions() catch {};
}

/// Spawn our room inbox, hand it to the room in `subscribe`, and mark joined.
fn subscribeRoom(state: *BotState, room: model.Reference) void {
    const session = state.session orelse return;
    const inbox = session.served.spawn(RoomInbox, .{ .state = state }) catch |err| {
        std.debug.print("rooms-bot: inbox spawn failed: {s}\n", .{@errorName(err)});
        return;
    };
    state.room = room;
    _ = state.host.send(session, room, .{
        .verb = "subscribe",
        .args = &.{ .{ .string = state.nick }, inbox.arg() },
    }) catch |err| {
        std.debug.print("rooms-bot: subscribe failed: {s}\n", .{@errorName(err)});
        return;
    };
    state.bridge.drainActions() catch {};
    state.joined = true;
    g_ever_joined = true;
    state.writeStateNow("joined");
}

/// Loop `on_close`: run the bridge's release, then clear the wire fields so the
/// next maintenance pass sees a null `session` and redials.
fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: net.completion.CloseReason) void {
    IrohBridge.onClose(ctx, slot, conn_ctx, opened, reason);
    const bridge: *IrohBridge = @ptrCast(@alignCast(ctx.?));
    const state: *BotState = @ptrCast(@alignCast(bridge.on_open_ctx.?));
    state.session = null;
    state.directory = null;
    state.room = null;
    state.joined = false;
    state.dialing = false;
}

// --- outbox -----------------------------------------------------------------

const OutboxLine = struct { text: []u8, is_dm: bool };

fn parseOutboxLine(gpa: Allocator, line: []const u8) ?OutboxLine {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const t = parsed.value.object.get("text") orelse return null;
    if (t != .string) return null;
    const text = gpa.dupe(u8, t.string) catch return null;
    var is_dm = false;
    if (parsed.value.object.get("channel")) |c| {
        if (c == .string and std.mem.eql(u8, c.string, "dm")) is_dm = true;
    }
    return .{ .text = text, .is_dm = is_dm };
}

/// Post every outbox line past `offset` to the room, advancing the offset to the
/// file's end. Runs on the loop thread between two `runUntil` returns, so posts
/// leave on the loop's own cadence — the quiet-connection guarantee.
fn drainOutbox(state: *BotState) void {
    const room = state.room orelse return;
    const session = state.session orelse return;
    const contents = readFile(state.io, state.gpa, state.dir, "outbox.jsonl") catch return;
    defer state.gpa.free(contents);
    if (contents.len <= g_offset) return;

    var posted = false;
    var it = std.mem.splitScalar(u8, contents[g_offset..], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        var owned: ?[]u8 = null;
        var text: []const u8 = line;
        if (parseOutboxLine(state.gpa, line)) |parsed| {
            if (parsed.is_dm) {
                // Direct messages ride the introduction path, not the room; that
                // endpoint is the remaining milestone, so a dm line is held.
                state.gpa.free(parsed.text);
                continue;
            }
            owned = parsed.text;
            text = parsed.text;
        }
        state.host.tell(session, room, .{ .verb = "post", .args = &.{.{ .string = text }} }) catch |err| {
            std.debug.print("rooms-bot: post failed: {s}\n", .{@errorName(err)});
        };
        recordInbox(state.io, state.gpa, state.dir, "sent", "room", state.nick, text, "") catch {};
        if (owned) |o| state.gpa.free(o);
        posted = true;
    }
    g_offset = contents.len;
    if (posted) state.bridge.drainActions() catch {};
}

// --- loop maintenance -------------------------------------------------------

fn maintain(state: *BotState) void {
    if (state.session == null) {
        // Back off between redials so a down room is retried steadily, not
        // thrashed every wake tick.
        if (state.redial_cooldown > 0) {
            state.redial_cooldown -= 1;
            return;
        }
        if (!state.dialing and !BotState.stopRequested()) {
            state.dialing = true;
            state.bridge.dialOutbound(state.transport, state.designator, state.hint) catch |err| {
                state.dialing = false;
                std.debug.print("rooms-bot: redial failed: {s}\n", .{@errorName(err)});
            };
            state.writeStateNow("reconnecting");
            state.redial_cooldown = redial_cooldown_wakes;
        }
        return;
    }
    if (!state.joined) return;
    drainOutbox(state);
}

fn wakePacer(io: Io) void {
    while (!BotState.stopRequested()) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(timer_ms), .real) catch {};
        g_wake.store(true, .release);
    }
}

/// Sleep up to `total_ms`, waking promptly on a stop. A `Threaded` sleep
/// swallows the SIGTERM `EINTR` and re-waits, so one long sleep is signal-deaf;
/// chunking it at the tick cadence lets the supervisor observe `g_stop` during a
/// reconnect backoff instead of parking past `stop`'s SIGTERM grace.
fn sleepUntilStop(io: Io, total_ms: i64) void {
    var slept: i64 = 0;
    while (slept < total_ms and !BotState.stopRequested()) {
        const chunk = @min(@as(i64, @intCast(timer_ms)), total_ms - slept);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(chunk), .real) catch {};
        slept += chunk;
    }
}

// --- peer daemon entry ------------------------------------------------------

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn seedRepliedBacklog(io: Io, gpa: Allocator, dir: []const u8, nick: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = scanInbox(arena, io, dir, nick);
    if (items.items.len == 0) return;
    var ids: std.ArrayList([]const u8) = .empty;
    for (items.items) |item| ids.append(arena, item.id) catch {};
    _ = markReplied(io, gpa, dir, ids.items);
}

fn runPeer(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (init.environ_map.get("ROOMS_BOT_SUPERVISED") == null) {
        std.debug.print(
            "rooms-bot: `peer` is the internal daemon and must not be run directly — a bare " ++
                "`peer &` dies when your shell is reaped.\n  start it with: rooms-bot start --dir <DIR> --nick <NICK>\n",
            .{},
        );
        return error.Unsupervised;
    }
    if (flags.dir.len == 0 or flags.nick.len == 0 or flags.locator.len == 0) return error.MissingFlags;

    // Detach into our own session so a reaped launcher shell cannot SIGHUP us.
    _ = std.os.linux.setsid();
    installSignalHandlers();

    Io.Dir.cwd().createDirPath(io, flags.dir) catch {};
    var pid_buf: [24]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "0\n";
    overwriteFile(io, flags.dir, "peer.pid", pid_text) catch {};
    // Mark the existing scrollback answered once, so a restart never re-answers
    // lines from before we joined.
    seedRepliedBacklog(io, gpa, flags.dir, flags.nick);

    const loc = try model.uri.parsePeer(gpa, flags.locator);
    defer model.freePeerLocator(gpa, loc);
    if (!std.mem.eql(u8, loc.transport, model.transport.iroh)) return error.NotIroh;
    const hint = net.netlayer.directAddrHint(loc.hints) orelse "";
    const reachability: iroh.Reachability = if (hint.len > 0) .direct else .discovery;

    // Seed the outbox drain offset to the file's end so a restart never re-posts
    // an already-drained queue.
    const seed_outbox = readFile(io, gpa, flags.dir, "outbox.jsonl") catch try gpa.dupe(u8, "");
    g_offset = seed_outbox.len;
    gpa.free(seed_outbox);

    // The wake pacer runs for the whole daemon life, flipping g_wake so each
    // stack's loop hands control back on its own cadence.
    var pacer = try io.concurrent(wakePacer, .{io});
    defer {
        g_stop.store(true, .release);
        pacer.await(io);
    }

    // Supervisor. Keep a functional iroh stack up until a stop signal. A
    // connection drop is recovered inside runStack (maintain redials in place); a
    // fatal loop error — the endpoint or backend itself failing — returns out of
    // runStack, and we build a fresh stack and reconnect. Back off when the
    // environment stays broken, and snap back to a fast retry once a stack has
    // actually joined. Only a stop signal ends the daemon.
    var backoff_ms: i64 = 500;
    while (!BotState.stopRequested()) {
        g_ever_joined = false;
        runStack(io, gpa, flags, loc, hint, reachability) catch |err| {
            std.debug.print("rooms-bot: iroh stack failed: {s}; rebuilding\n", .{@errorName(err)});
        };
        if (BotState.stopRequested()) break;
        writeState(io, gpa, flags.dir, "reconnecting", flags.nick, flags.room, flags.locator);
        sleepUntilStop(io, backoff_ms);
        backoff_ms = if (g_ever_joined) 500 else @min(backoff_ms * 2, 30_000);
    }

    writeState(io, gpa, flags.dir, "closed", flags.nick, flags.room, flags.locator);
    removeFile(io, flags.dir, "peer.pid");
}

/// Build a fresh iroh stack (endpoint, host, bridge, completion loop), dial the
/// room, and run the loop. Returns normally when a stop is requested, or returns
/// the error when the loop fails fatally so the supervisor can rebuild. A
/// per-connection drop is recovered here without a rebuild: `on_close` nulls the
/// session and `maintain` redials it.
fn runStack(io: Io, gpa: Allocator, flags: Flags, loc: model.PeerLocator, hint: []const u8, reachability: iroh.Reachability) !void {
    var resident = try iroh.Resident.init(io, null, .{
        .reachability = reachability,
        .connect_timeout_ms = dial_timeout_ms,
    });
    defer resident.deinit();

    var seed: [32]u8 = undefined;
    io.randomSecure(&seed) catch return error.EntropyFailed;

    var host = Host.init(gpa, seed, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
    });
    defer host.deinit();

    var loop: IrohLoop = undefined;
    var state = BotState{
        .io = io,
        .gpa = gpa,
        .host = &host,
        .bridge = undefined,
        .dir = flags.dir,
        .nick = flags.nick,
        .room_name = flags.room,
        .locator_str = flags.locator,
        .transport = loc.transport,
        .designator = loc.designator,
        .hint = hint,
    };
    var bridge = IrohBridge.init(gpa, &host, io, &loop, .{
        .on_open = onOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try iroh.Backend.initBound(gpa, &resident, 256, 256, read_buffer_bytes);
    loop = try IrohLoop.initWithBackend(gpa, backend, IrohBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = IrohBridge.makeConnCtx,
        .serve = IrohBridge.serve,
        .free_conn_ctx = IrohBridge.freeConnCtx,
        .on_close = onClose,
    });
    defer loop.deinit();

    state.dialing = true;
    bridge.dialOutbound(loc.transport, loc.designator, hint) catch |err| {
        std.debug.print("rooms-bot: dial failed: {s}\n", .{@errorName(err)});
        state.dialing = false;
    };

    while (!BotState.stopRequested()) {
        loop.runUntil(&g_wake, 0) catch |err| {
            loop.closeAndDrain() catch {};
            return err;
        };
        g_wake.store(false, .release);
        maintain(&state);
    }
    loop.closeAndDrain() catch {};
}

// --- start ------------------------------------------------------------------

/// Whether `pid` names a live process. A zombie (state `Z` — exited but not yet
/// reaped) reads as dead: under a non-reaping container init (`sleep infinity` as
/// PID 1) a cleanly-stopped daemon lingers as a zombie table entry, and treating
/// that as "up" would make `stop` escalate to SIGKILL against an already-dead
/// process and `status` misreport it. A reaping init (tini/systemd) clears the
/// entry outright, so this only matters in the bare-container case.
fn pidAlive(io: Io, gpa: Allocator, pid: i32) bool {
    _ = gpa;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
    // /proc/<pid>/stat is a synthetic file that reports size 0, so a size-based
    // read gets nothing — read into a fixed buffer instead. Opening at all means
    // a table entry exists; the state token distinguishes live from zombie.
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var data_buf: [512]u8 = undefined;
    const n = fr.interface.readSliceShort(&data_buf) catch return true;
    const data = data_buf[0..n];
    // `comm` can hold spaces and parens, so the state is the token after the
    // last ')'.
    const rp = std.mem.lastIndexOfScalar(u8, data, ')') orelse return true;
    var i = rp + 1;
    while (i < data.len and data[i] == ' ') i += 1;
    if (i >= data.len) return true;
    const st = data[i];
    return st != 'Z' and st != 'X' and st != 'x';
}

/// The absolute path to this running binary, so a command we print for the
/// agent is copy-pasteable from any working directory. Falls back to the bare
/// name if `/proc/self/exe` cannot be read.
fn selfExePath(io: Io, buf: []u8) []const u8 {
    const n = Io.Dir.readLinkAbsolute(io, "/proc/self/exe", buf) catch return "rooms-bot";
    return buf[0..n];
}

fn readPid(io: Io, gpa: Allocator, dir: []const u8) ?i32 {
    const text = readFile(io, gpa, dir, "peer.pid") catch return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

/// Resolve a CapTP dial target. An `http(s)://…/locator` bootstrap is fetched
/// and its first line taken as the `ocapn://` URI (the rooms web UI serves it);
/// an `ocapn://` URI or bare designator passes through. Returns an owned string.
fn resolveLocator(io: Io, gpa: Allocator, locator: []const u8) ![]u8 {
    const is_http = std.mem.startsWith(u8, locator, "http://") or std.mem.startsWith(u8, locator, "https://");
    if (!is_http) return gpa.dupe(u8, locator);

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    const result = client.fetch(.{ .location = .{ .url = locator }, .response_writer = &body.writer }) catch {
        return error.BootstrapFailed;
    };
    if (result.status != .ok) return error.BootstrapFailed;
    const text = body.writer.buffered();
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", " \t\r\n");
    if (first.len == 0) return error.BootstrapEmpty;
    return gpa.dupe(u8, first);
}

fn absDir(io: Io, gpa: Allocator, dir: []const u8) []u8 {
    if (dir.len > 0 and dir[0] == '/') return gpa.dupe(u8, dir) catch @constCast(dir);
    var buf: [4096]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return gpa.dupe(u8, dir) catch @constCast(dir);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..n], dir }) catch gpa.dupe(u8, dir) catch @constCast(dir);
}

fn runStart(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.nick.len == 0 or flags.dir.len == 0) {
        std.debug.print("{{\"ok\":false,\"error\":\"usage\",\"detail\":\"start needs --dir and --nick\"}}\n", .{});
        return;
    }
    const dir = absDir(io, gpa, flags.dir);
    defer gpa.free(dir);
    const bootstrap = if (flags.locator.len > 0) flags.locator else default_locator;
    const locator = resolveLocator(io, gpa, bootstrap) catch |err| {
        std.debug.print("{{\"ok\":false,\"error\":\"locator\",\"detail\":\"could not resolve {s}: {s}\"}}\n", .{ bootstrap, @errorName(err) });
        return;
    };
    defer gpa.free(locator);
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    var exe_buf: [4096]u8 = undefined;
    const exe = selfExePath(io, &exe_buf);

    // Idempotent: never launch a second peer for a live dir.
    if (readPid(io, gpa, dir)) |pid| {
        if (pidAlive(io, gpa, pid)) {
            waitJoinedAndReport(io, gpa, exe, dir, flags.nick, flags.room, pid, false);
            return;
        }
    }

    // Raw daemon stdout/stderr (a startup crash before state.json) land here.
    var out_path_buf: [512]u8 = undefined;
    const out_path = pathIn(&out_path_buf, dir, "peer.out");
    const out_file = Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch {
        std.debug.print("{{\"ok\":false,\"error\":\"peer-out\",\"detail\":\"could not open peer.out\"}}\n", .{});
        return;
    };

    var child_env = try init.environ_map.clone(gpa);
    defer child_env.deinit();
    // ROOMS_BOT_SUPERVISED is set only on this detached child, so `peer` refuses
    // any other launch path.
    try child_env.put("ROOMS_BOT_SUPERVISED", "1");

    const argv = [_][]const u8{ exe, "peer", "--dir", dir, "--nick", flags.nick, "--room", flags.room, "--locator", locator };
    const child = std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = out_file },
    }) catch |err| {
        out_file.close(io);
        std.debug.print("{{\"ok\":false,\"error\":\"spawn\",\"detail\":\"{s}\"}}\n", .{@errorName(err)});
        return;
    };
    out_file.close(io);
    // Do not wait: the peer detached (setsid) and reparents to init. A reaping
    // init (tini/systemd) collects it on exit; under a bare-container PID 1 it
    // lingers as a harmless zombie table entry until container teardown.
    const pid: i32 = @intCast(child.id orelse 0);
    waitJoinedAndReport(io, gpa, exe, dir, flags.nick, flags.room, pid, true);
}

fn waitJoinedAndReport(io: Io, gpa: Allocator, exe: []const u8, dir: []const u8, nick: []const u8, room: []const u8, pid: i32, started: bool) void {
    var waited: u64 = 0;
    const deadline_ms: u64 = 45_000;
    while (waited < deadline_ms) {
        const status = stateField(io, gpa, dir, "status");
        defer gpa.free(status);
        if (std.mem.eql(u8, status, "joined")) {
            const locator = stateField(io, gpa, dir, "locator");
            defer gpa.free(locator);
            reportStarted(gpa, exe, dir, nick, room, pid, started, locator);
            return;
        }
        if (!pidAlive(io, gpa, pid)) {
            const tail = readFile(io, gpa, dir, "peer.out") catch gpa.dupe(u8, "") catch "";
            defer gpa.free(tail);
            std.debug.print("{{\"ok\":false,\"error\":\"peer-exited\",\"detail\":\"peer exited during startup\",\"peer_out\":", .{});
            var esc: std.ArrayList(u8) = .empty;
            defer esc.deinit(gpa);
            writeJsonString(&esc, gpa, tailOf(tail, 600)) catch {};
            std.debug.print("{s}}}\n", .{esc.items});
            return;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .real) catch {};
        waited += 300;
    }
    std.debug.print("{{\"ok\":false,\"error\":\"join-timeout\",\"detail\":\"peer did not report joined in time; check the locator and that the room is reachable\"}}\n", .{});
}

fn tailOf(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[s.len - n ..] else s;
}

fn reportStarted(gpa: Allocator, exe: []const u8, dir: []const u8, nick: []const u8, room: []const u8, pid: i32, started: bool, locator: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"started\":") catch {};
    out.appendSlice(gpa, if (started) "true" else "false") catch {};
    out.appendSlice(gpa, ",\"pid\":") catch {};
    var pb: [16]u8 = undefined;
    out.appendSlice(gpa, std.fmt.bufPrint(&pb, "{d}", .{pid}) catch "0") catch {};
    out.appendSlice(gpa, ",\"nick\":") catch {};
    writeJsonString(&out, gpa, nick) catch {};
    out.appendSlice(gpa, ",\"room\":") catch {};
    writeJsonString(&out, gpa, room) catch {};
    out.appendSlice(gpa, ",\"locator\":") catch {};
    writeJsonString(&out, gpa, locator) catch {};
    out.appendSlice(gpa, ",\"dir\":") catch {};
    writeJsonString(&out, gpa, dir) catch {};
    var cb: [4608]u8 = undefined;
    out.appendSlice(gpa, ",\"loop_cmd\":") catch {};
    writeJsonString(&out, gpa, std.fmt.bufPrint(&cb, "{s} tick --dir {s} --wait 20", .{ exe, dir }) catch "") catch {};
    out.appendSlice(gpa, ",\"reply_cmd\":") catch {};
    writeJsonString(&out, gpa, std.fmt.bufPrint(&cb, "{s} reply --dir {s} --id <ID> --text '…'", .{ exe, dir }) catch "") catch {};
    out.appendSlice(gpa, ",\"stop_cmd\":") catch {};
    writeJsonString(&out, gpa, std.fmt.bufPrint(&cb, "{s} stop --dir {s}", .{ exe, dir }) catch "") catch {};
    out.appendSlice(gpa, ",\"next\":") catch {};
    writeJsonString(&out, gpa, "Run loop_cmd repeatedly: it returns pending messages (waits up to 20s); reply to each with its prefilled reply command, then loop. Do your own work between ticks. Run stop_cmd when done.") catch {};
    out.append(gpa, '}') catch {};
    std.debug.print("{s}\n", .{out.items});
}

// --- stop -------------------------------------------------------------------

fn runStop(init: std.process.Init, flags: Flags) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (flags.dir.len == 0) {
        std.debug.print("{{\"ok\":false,\"error\":\"usage\",\"detail\":\"stop needs --dir\"}}\n", .{});
        return;
    }
    const pid = readPid(io, gpa, flags.dir);
    if (pid == null or !pidAlive(io, gpa, pid.?)) {
        removeFile(io, flags.dir, "peer.pid");
        std.debug.print("{{\"ok\":true,\"stopped\":false,\"detail\":\"no peer running for this dir\"}}\n", .{});
        return;
    }
    const target = pid.?;
    std.posix.kill(target, std.posix.SIG.TERM) catch {};
    // Give the clean SIGTERM path a few seconds before escalating.
    var waited: u64 = 0;
    while (waited < 6000 and pidAlive(io, gpa, target)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
        waited += 100;
    }
    var sigkill = false;
    if (pidAlive(io, gpa, target)) {
        sigkill = true;
        std.posix.kill(target, std.posix.SIG.KILL) catch {};
        var w2: u64 = 0;
        while (w2 < 3000 and pidAlive(io, gpa, target)) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
            w2 += 100;
        }
    }
    removeFile(io, flags.dir, "peer.pid");
    std.debug.print("{{\"ok\":true,\"stopped\":true,\"pid\":{d},\"sigkill\":{s}}}\n", .{ target, if (sigkill) "true" else "false" });
}

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
/// so the bot stays a full participant and never silently drops a message
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
        std.debug.print("{{\"ok\":false,\"error\":\"usage\",\"detail\":\"tick needs --dir\"}}\n", .{});
        return;
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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"peer\":") catch {};
    writeJsonString(&out, gpa, if (peer_up) "up" else "down") catch {};
    var nb: [16]u8 = undefined;
    out.appendSlice(gpa, ",\"n\":") catch {};
    out.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d}", .{pending.items.len}) catch "0") catch {};
    out.appendSlice(gpa, ",\"pending\":[") catch {};
    for (pending.items, 0..) |item, i| {
        if (i > 0) out.append(gpa, ',') catch {};
        out.appendSlice(gpa, "{\"id\":") catch {};
        writeJsonString(&out, gpa, item.id) catch {};
        out.appendSlice(gpa, ",\"channel\":") catch {};
        writeJsonString(&out, gpa, item.channel) catch {};
        out.appendSlice(gpa, ",\"author\":") catch {};
        writeJsonString(&out, gpa, item.author) catch {};
        out.appendSlice(gpa, ",\"text\":") catch {};
        writeJsonString(&out, gpa, item.text) catch {};
        out.appendSlice(gpa, ",\"reply\":") catch {};
        writeJsonString(&out, gpa, replyCommand(arena_state.allocator(), exe, flags.dir, item)) catch {};
        out.append(gpa, '}') catch {};
    }
    out.appendSlice(gpa, "],\"hint\":") catch {};
    const hint = if (!peer_up)
        (std.fmt.allocPrint(arena_state.allocator(), "peer is down — restart it: {s} start --dir {s} --nick {s}", .{ exe, flags.dir, if (nick.len > 0) nick else "<NICK>" }) catch "peer is down — run `start` again")
    else if (pending.items.len > 0)
        "answer each one: run its 'reply' command with your words in place of 'YOUR REPLY HERE', then arm the next background tick. dismiss any you don't want to answer."
    else
        "nothing pending — do your own work, then arm the next background tick";
    writeJsonString(&out, gpa, hint) catch {};
    out.append(gpa, '}') catch {};
    std.debug.print("{s}\n", .{out.items});
}

fn replyCommand(gpa: Allocator, exe: []const u8, dir: []const u8, item: Pending) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(gpa, exe) catch {};
    b.appendSlice(gpa, " reply --dir ") catch {};
    b.appendSlice(gpa, dir) catch {};
    b.appendSlice(gpa, " --id ") catch {};
    b.appendSlice(gpa, item.id) catch {};
    b.appendSlice(gpa, " --text '" ++ reply_placeholder ++ "'") catch {};
    return b.items;
}

// --- reply ------------------------------------------------------------------

fn runReply(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0 or flags.text.len == 0) {
        std.debug.print("{{\"ok\":false,\"error\":\"usage\",\"detail\":\"reply needs --dir and --text\"}}\n", .{});
        return;
    }
    if (std.mem.eql(u8, flags.text, reply_placeholder)) {
        std.debug.print("{{\"ok\":false,\"error\":\"placeholder\",\"detail\":\"replace 'YOUR REPLY HERE' with your actual message\"}}\n", .{});
        return;
    }
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    if (flags.dm.len > 0) {
        try list.appendSlice(gpa, "{\"channel\":\"dm\",\"peer\":");
        try writeJsonString(&list, gpa, flags.dm);
        try list.appendSlice(gpa, ",\"text\":");
    } else {
        try list.appendSlice(gpa, "{\"channel\":\"room\",\"text\":");
    }
    try writeJsonString(&list, gpa, flags.text);
    try list.append(gpa, '}');
    try appendLine(io, gpa, flags.dir, "outbox.jsonl", list.items);
    // --id folds the mark into the reply, so there is no separate done step.
    var marked = false;
    if (flags.id.len > 0) marked = markReplied(io, gpa, flags.dir, &.{flags.id}) > 0;
    std.debug.print("{{\"ok\":true,\"answered_id\":", .{});
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(gpa);
    if (flags.id.len > 0) writeJsonString(&esc, gpa, flags.id) catch {} else esc.appendSlice(gpa, "null") catch {};
    std.debug.print("{s},\"marked\":{s}}}\n", .{ esc.items, if (marked) "true" else "false" });
}

// --- dismiss ----------------------------------------------------------------

/// Mark messages answered WITHOUT posting to the room — the silent counterpart
/// to `reply`. `--id ID` clears one; `--all` clears every currently-pending
/// message. Use it to drop chatter, duplicates, or another bot's noise without
/// speaking. It writes the same `replied.json` ledger `reply` marks, so a
/// dismissed message never resurfaces in `tick`.
fn runDismiss(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0 or (flags.id.len == 0 and !flags.all)) {
        std.debug.print("{{\"ok\":false,\"error\":\"usage\",\"detail\":\"dismiss needs --dir and either --id ID or --all\"}}\n", .{});
        return;
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
        count = markReplied(io, gpa, flags.dir, ids.items);
    } else {
        count = markReplied(io, gpa, flags.dir, &.{flags.id});
    }
    var nb: [16]u8 = undefined;
    std.debug.print("{{\"ok\":true,\"dismissed\":{s}}}\n", .{std.fmt.bufPrint(&nb, "{d}", .{count}) catch "0"});
}

// --- status -----------------------------------------------------------------

fn runStatus(io: Io, gpa: Allocator, flags: Flags) !void {
    if (flags.dir.len == 0) {
        std.debug.print("{{\"ok\":false,\"error\":\"usage\",\"detail\":\"status needs --dir\"}}\n", .{});
        return;
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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":") catch {};
    out.appendSlice(gpa, if (up) "true" else "false") catch {};
    out.appendSlice(gpa, ",\"peer\":") catch {};
    writeJsonString(&out, gpa, if (up) "up" else "down") catch {};
    out.appendSlice(gpa, ",\"pid\":") catch {};
    if (pid) |p| {
        var pb: [16]u8 = undefined;
        out.appendSlice(gpa, std.fmt.bufPrint(&pb, "{d}", .{p}) catch "null") catch {};
    } else out.appendSlice(gpa, "null") catch {};
    out.appendSlice(gpa, ",\"pending\":") catch {};
    var nb: [16]u8 = undefined;
    out.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d}", .{pending.items.len}) catch "0") catch {};
    out.appendSlice(gpa, ",\"state\":") catch {};
    if (state.len > 0) out.appendSlice(gpa, state) catch {} else out.appendSlice(gpa, "null") catch {};
    out.append(gpa, '}') catch {};
    std.debug.print("{s}\n", .{out.items});
}

// --- main -------------------------------------------------------------------

const usage_text =
    \\rooms-bot — join a pancake chat room as a background peer and answer messages.
    \\
    \\Usage: rooms-bot <verb> [flags]   (run from the repo root)
    \\
    \\  start   --nick NICK --dir DIR [--room ROOM] [--locator LOC]   connect and run
    \\  tick    --dir DIR [--wait N]                                  unanswered room messages to answer
    \\  reply   --dir DIR --id ID --text '...'                        answer one message
    \\  dismiss --dir DIR (--id ID | --all)                          clear message(s) without posting
    \\  stop    --dir DIR                                             leave and stop
    \\  status  --dir DIR                                             show state
    \\
    \\Example:
    \\  rooms-bot start --nick Alice --dir /tmp/rooms-bot-alice --room general
    \\
;

fn usageExit(code: u8) noreturn {
    std.debug.print("{s}", .{usage_text});
    std.process.exit(code);
}

/// Never leak a Zig error (and its stack trace) to an agent: any unexpected
/// error becomes one clean line and a nonzero exit.
pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        std.debug.print("rooms-bot: unexpected error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    const verb = args.next() orelse usageExit(2);
    if (std.mem.eql(u8, verb, "help") or std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h")) {
        std.debug.print("{s}", .{usage_text});
        return;
    }
    const flags = Flags.parse(&args);

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
        std.debug.print("rooms-bot: unknown verb \"{s}\"\n\n", .{verb});
        usageExit(2);
    }
}
