//! File harness for `pancake app rooms-peer` (state, inbox, replied ledger).
const std = @import("std");
const common = @import("common.zig");
const argv = @import("../../argv.zig");

const Io = common.Io;
const Allocator = common.Allocator;
const file_cap = common.file_cap;
const replied_cap = common.replied_cap;
const reply_placeholder = common.reply_placeholder;

// --- harness files ----------------------------------------------------------

pub fn pathIn(buf: []u8, dir: []const u8, leaf: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, leaf }) catch leaf;
}

/// Read DIR/leaf, or an empty (owned) slice if it does not exist.
pub fn readFile(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8) ![]u8 {
    var pbuf: [512]u8 = undefined;
    const path = pathIn(&pbuf, dir, leaf);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, file_cap) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
}

pub fn overwriteFile(io: Io, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
    var pbuf: [512]u8 = undefined;
    const path = pathIn(&pbuf, dir, leaf);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn removeFile(io: Io, dir: []const u8, leaf: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const path = pathIn(&pbuf, dir, leaf);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Append a line to DIR/leaf under an exclusive sidecar lock.
///
/// std.Io.File has no append/seek, so the body is still read-modify-write.
/// Without the lock, two concurrent `reply` processes each read the same
/// prefix and the later write drops the earlier line — and when the dropped
/// write was longer, `outbox.offset` can land mid-line and the drain stalls
/// on garbage forever. Lock lives on `leaf.lock` so `overwriteFile` can
/// replace the body inode without dropping the advisory lock.
pub fn appendLine(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
    var lock_leaf_buf: [160]u8 = undefined;
    const lock_leaf = std.fmt.bufPrint(&lock_leaf_buf, "{s}.lock", .{leaf}) catch unreachable;
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = pathIn(&lock_path_buf, dir, lock_leaf);
    const lock_file = try Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer {
        lock_file.unlock(io);
        lock_file.close(io);
    }
    const old = try readFile(io, gpa, dir, leaf);
    defer gpa.free(old);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, old);
    try list.appendSlice(gpa, bytes);
    try list.append(gpa, '\n');
    try overwriteFile(io, dir, leaf, list.items);
}

/// One outbox.jsonl record the peer drains (room post or DM-by-introduction).
pub const OutboxLine = struct {
    text: []u8,
    is_dm: bool,
    /// Target nick when `is_dm`; empty owned slice otherwise.
    peer: []u8,

    pub fn deinit(self: OutboxLine, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.peer);
    }
};

/// Parse one outbox JSON object. Returns null when the line is not JSON with a
/// string `text` — the peer skips those lines (reply always writes JSON).
pub fn parseOutboxLine(gpa: Allocator, line: []const u8) ?OutboxLine {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const t = parsed.value.object.get("text") orelse return null;
    if (t != .string) return null;
    const text = gpa.dupe(u8, t.string) catch return null;
    errdefer gpa.free(text);
    var is_dm = false;
    if (parsed.value.object.get("channel")) |c| {
        if (c == .string and std.mem.eql(u8, c.string, "dm")) is_dm = true;
    }
    var peer: []u8 = gpa.dupe(u8, "") catch {
        gpa.free(text);
        return null;
    };
    errdefer gpa.free(peer);
    if (is_dm) {
        if (parsed.value.object.get("peer")) |p| {
            if (p == .string and p.string.len > 0) {
                gpa.free(peer);
                peer = gpa.dupe(u8, p.string) catch {
                    gpa.free(text);
                    return null;
                };
            }
        }
    }
    return .{ .text = text, .is_dm = is_dm, .peer = peer };
}

/// Write a JSON string literal (quotes and escaping) into an ArrayList.
///
/// This is the CLI's one escaper, reached from here so the inbox records and
/// the JSON the CLI prints agree about what a string is. A room member's nick
/// and line arrive over the wire, so they can be any bytes at all, and the
/// escaper is what keeps `inbox.jsonl` parseable when they are not text.
pub const writeJsonString = argv.writeJsonString;

/// Append one inbound/outbound record to inbox.jsonl. `channel` is "room" or
/// "dm"; `peer` names the dm partner (empty on the room arm). Each line carries
/// `ts` (monotonic ms) so wake-loop latency is measurable without peer.out.
pub fn recordInbox(io: Io, gpa: Allocator, dir: []const u8, kind: []const u8, channel: []const u8, author: []const u8, text: []const u8, peer: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var ts_buf: [24]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{common.net.clock.nowMs(io)}) catch "0";
    try list.appendSlice(gpa, "{\"ts\":");
    try list.appendSlice(gpa, ts);
    try list.appendSlice(gpa, ",\"kind\":");
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

/// Persist the outbox drain cursor. Only call after tell + drainActions both
/// succeeded for every line up to `offset`.
///
/// Reports whether it persisted. The write used to be swallowed, which made
/// the fail-closed contract above unenforceable in the one case it is for: a
/// read-only or full state directory left the cursor on disk behind the one in
/// memory, so a restart resent every line since.
pub fn saveOutboxOffset(io: Io, dir: []const u8, offset: usize) error{PersistFailed}!void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{offset}) catch return error.PersistFailed;
    overwriteFile(io, dir, "outbox.offset", text) catch return error.PersistFailed;
}

/// Load a persisted outbox offset (unclamped). Missing or corrupt → 0 so a
/// restart resumes from the start of undrained history. Never invent EOF.
pub fn loadOutboxOffset(io: Io, gpa: Allocator, dir: []const u8) usize {
    const raw = readFile(io, gpa, dir, "outbox.offset") catch return 0;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10) catch 0;
}

/// Clamp an in-memory outbox cursor to the current file length.
pub fn clampOutboxOffset(offset: usize, outbox_len: usize) usize {
    return @min(offset, outbox_len);
}

/// Bytes still waiting in outbox.jsonl past the persisted drain offset.
pub fn outboxBacklogBytes(io: Io, gpa: Allocator, dir: []const u8) usize {
    const contents = readFile(io, gpa, dir, "outbox.jsonl") catch return 0;
    defer gpa.free(contents);
    const offset = clampOutboxOffset(loadOutboxOffset(io, gpa, dir), contents.len);
    return contents.len - offset;
}

/// Leaf name for the peer-written map of nicks with an ADR-0088 reply-cap
/// (`dm_back`). `reply --dm` reads this so a bot-first DM cannot look locally
/// sent when introduce would be the only route (browser false-sent class).
pub const dm_backchannels_leaf = "dm_backchannels.json";

/// Persist the set of nicks that currently hold a reply-cap back-channel.
/// Shape: `{"armed":["Jim","Bob"]}`. Best-effort — a failed write leaves the
/// previous file; `reply --dm` then fails closed until the next persist.
pub fn persistDmBackchannels(io: Io, gpa: Allocator, dir: []const u8, armed: []const []const u8) void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    list.appendSlice(gpa, "{\"armed\":[") catch return;
    for (armed, 0..) |nick, i| {
        if (i > 0) list.append(gpa, ',') catch return;
        writeJsonString(&list, gpa, nick) catch return;
    }
    list.appendSlice(gpa, "]}\n") catch return;
    overwriteFile(io, dir, dm_backchannels_leaf, list.items) catch {};
}

/// True when `peer` appears in DIR/dm_backchannels.json's `armed` list.
/// Missing or corrupt file → false (fail closed: no false-sent --dm).
pub fn dmBackchannelArmed(io: Io, gpa: Allocator, dir: []const u8, peer: []const u8) bool {
    if (peer.len == 0) return false;
    const raw = readFile(io, gpa, dir, dm_backchannels_leaf) catch return false;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return false;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return false;
    const armed_val = root.object.get("armed") orelse return false;
    if (armed_val != .array) return false;
    for (armed_val.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, peer)) return true;
    }
    return false;
}

/// Leaf name for optional team roster used to distinguish human room lines from
/// peer chatter. Shape: `{"nicks":["agentic-lead","fresh-eyes"]}`. Missing file
/// → `human_room_pending` stays false (no false-positive stuck_human_room).
pub const roster_leaf = "roster.json";

/// Load roster nicks from DIR/roster.json into `arena`. Empty slice if missing
/// or corrupt — callers then treat every non-self room author as unknown, and
/// `humanRoomPending` returns false rather than claiming humans.
pub fn loadRosterNicks(arena: Allocator, io: Io, gpa: Allocator, dir: []const u8) []const []const u8 {
    const raw = readFile(io, gpa, dir, roster_leaf) catch return &.{};
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return &.{};
    const nicks_val = parsed.value.object.get("nicks") orelse return &.{};
    if (nicks_val != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (nicks_val.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        const dup = arena.dupe(u8, item.string) catch continue;
        out.append(arena, dup) catch {};
    }
    return out.items;
}

fn nickEqualsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

/// True when `author` is listed in the team roster (case-insensitive).
pub fn authorOnRoster(roster: []const []const u8, author: []const u8) bool {
    for (roster) |nick| {
        if (nickEqualsIgnoreCase(nick, author)) return true;
    }
    return false;
}

/// Room lines from authors not on the roster (and not already filtered as self
/// by scanInbox). Requires a roster file; without one, returns false so health
/// never classifies peer chatter as stuck_human_room.
pub fn humanRoomPending(pending: []const Pending, roster: []const []const u8) bool {
    if (roster.len == 0) return false;
    for (pending) |item| {
        if (!std.mem.eql(u8, item.channel, "room")) continue;
        if (authorOnRoster(roster, item.author)) continue;
        return true;
    }
    return false;
}

/// Byte offset into inbox.jsonl: lines before this are already considered
/// answered for tick (peer-start scrollback). Avoids stuffing replied.json past
/// replied_cap and resurfacing ancient ids after a restart.
pub fn saveInboxWatermark(io: Io, dir: []const u8, offset: usize) void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{offset}) catch return;
    overwriteFile(io, dir, "inbox.watermark", text) catch {};
}

pub fn loadInboxWatermark(io: Io, gpa: Allocator, dir: []const u8) usize {
    const raw = readFile(io, gpa, dir, "inbox.watermark") catch return 0;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10) catch 0;
}

/// Advance the inbox watermark to `file_len` (peer start: treat current
/// scrollback as answered without bloating replied.json).
pub fn advanceInboxWatermark(io: Io, gpa: Allocator, dir: []const u8) void {
    const contents = readFile(io, gpa, dir, "inbox.jsonl") catch {
        saveInboxWatermark(io, dir, 0);
        return;
    };
    defer gpa.free(contents);
    saveInboxWatermark(io, dir, contents.len);
}

pub fn writeState(
    io: Io,
    gpa: Allocator,
    dir: []const u8,
    status: []const u8,
    nick: []const u8,
    room: []const u8,
    locator: []const u8,
    registered: bool,
    join_attempts: u32,
) void {
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
    list.appendSlice(gpa, ",\"registered\":") catch return;
    list.appendSlice(gpa, if (registered) "true" else "false") catch return;
    list.appendSlice(gpa, ",\"join_attempts\":") catch return;
    var jb: [12]u8 = undefined;
    list.appendSlice(gpa, std.fmt.bufPrint(&jb, "{d}", .{join_attempts}) catch "0") catch return;
    list.append(gpa, '}') catch return;
    overwriteFile(io, dir, "state.json", list.items) catch return;
}

/// One string field out of state.json, owned; empty when absent. The empty
/// answer is a static slice rather than a zero-length allocation, which the
/// caller's `free` handles either way.
/// Booleans stringify as `"true"` / `"false"` so callers can compare without a
/// second helper (`registered` is written as a JSON bool). Extracts strings
/// and bools only: numeric fields (`join_attempts`) surface through the raw
/// state.json splice in `status`, or a caller's own JSON parse.
pub fn stateField(io: Io, gpa: Allocator, dir: []const u8, key: []const u8) []u8 {
    const raw = readFile(io, gpa, dir, "state.json") catch return "";
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return "";
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get(key)) |v| {
            if (v == .string) return gpa.dupe(u8, v.string) catch "";
            if (v == .bool) return gpa.dupe(u8, if (v.bool) "true" else "false") catch "";
        }
    }
    return "";
}

// --- replied ledger + pending scan ------------------------------------------

/// A stable id for one inbound line: its byte offset in inbox.jsonl (append-only,
/// so it never shifts) folded with the content. Two identical messages at
/// different offsets stay distinct, and re-scanning the same file reproduces the
/// same id, which is what lets `reply --id` mark it answered.
pub fn lineId(gpa: Allocator, offset: usize, author: []const u8, text: []const u8, channel: []const u8, peer: []const u8) []u8 {
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
pub const Pending = struct {
    id: []const u8,
    channel: []const u8,
    author: []const u8,
    text: []const u8,
    peer: []const u8,
    mention: bool,
};

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

/// Sort unanswered lines the way a present person answers: DMs first, then
/// `@you` mentions, then the rest of the room. Shared by `tick` and hermetic
/// one-wake goldens so the order cannot drift from the skill's multi-surface
/// drain rule.
pub fn sortPending(pending: []Pending) void {
    std.mem.sort(Pending, pending, {}, pendingLess);
}

/// Scan inbox.jsonl for inbound lines from someone else (`kind == "msg"`),
/// tagging each with its stable id. Our own `sent` echoes and `system` lines
/// fall out on the kind check. Everything is allocated in `arena`.
pub fn scanInbox(arena: Allocator, io: Io, dir: []const u8, nick: []const u8) std.ArrayList(Pending) {
    var items: std.ArrayList(Pending) = .empty;
    const contents = readFile(io, arena, dir, "inbox.jsonl") catch return items;
    const watermark = loadInboxWatermark(io, arena, dir);
    const self_lower = std.ascii.allocLowerString(arena, nick) catch nick;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line_offset = offset;
        offset += raw.len + 1;
        if (line_offset < watermark) continue;
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
pub fn loadReplied(arena: Allocator, io: Io, dir: []const u8) std.StringHashMapUnmanaged(void) {
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
///
/// Fallible, because the count alone was a lie under a read-only or full state
/// directory: it is computed from the in-memory fold, the write was swallowed,
/// and the caller printed `"marked":true` while the ledger was unchanged — so
/// the next tick surfaced the same message and the agent answered it again, on
/// every cycle.
pub fn markReplied(io: Io, gpa: Allocator, dir: []const u8, ids: []const []const u8) !usize {
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
    // Built with `try`, so a half-written document is never handed to the
    // writer. Swallowing these produced `["a","b` — unparseable, so the next
    // load read an empty ledger and every answered message resurfaced.
    try out.append(arena, '[');
    for (order.items[start..], 0..) |id, i| {
        if (i > 0) try out.append(arena, ',');
        try writeJsonString(&out, arena, id);
    }
    try out.append(arena, ']');
    overwriteFile(io, dir, "replied.json", out.items) catch return error.PersistFailed;
    return added;
}
