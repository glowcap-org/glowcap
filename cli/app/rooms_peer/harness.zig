//! File harness for `pancake app rooms-peer` (state, inbox, replied ledger).
const std = @import("std");
const common = @import("common.zig");

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

/// Append a line to DIR/leaf. There is no seek in std.Io.File, so this is
/// read-modify-write — fine for the small, session-bounded harness files.
pub fn appendLine(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
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
/// string `text` (legacy bare-text lines stay the peer's fallback path).
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

/// Write a JSON string literal (quotes + escaping) into an ArrayList.
pub fn writeJsonString(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
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
pub fn recordInbox(io: Io, gpa: Allocator, dir: []const u8, kind: []const u8, channel: []const u8, author: []const u8, text: []const u8, peer: []const u8) !void {
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

pub fn writeState(io: Io, gpa: Allocator, dir: []const u8, status: []const u8, nick: []const u8, room: []const u8, locator: []const u8) void {
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
pub fn stateField(io: Io, gpa: Allocator, dir: []const u8, key: []const u8) []u8 {
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

/// Scan inbox.jsonl for inbound lines from someone else (`kind == "msg"`),
/// tagging each with its stable id. Our own `sent` echoes and `system` lines
/// fall out on the kind check. Everything is allocated in `arena`.
pub fn scanInbox(arena: Allocator, io: Io, dir: []const u8, nick: []const u8) std.ArrayList(Pending) {
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
pub fn markReplied(io: Io, gpa: Allocator, dir: []const u8, ids: []const []const u8) usize {
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
