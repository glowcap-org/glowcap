//! Inbox records, roster classification, watermarks, and replied-id ledger.

const std = @import("std");
const common = @import("../common.zig");
const files = @import("files.zig");
const argv = @import("../../../argv.zig");

const Io = common.Io;
const Allocator = common.Allocator;

pub fn recordInbox(io: Io, gpa: Allocator, dir: []const u8, kind: []const u8, channel: []const u8, author: []const u8, text: []const u8, peer: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var ts_buf: [24]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{common.net.clock.nowMs(io)}) catch "0";
    try list.appendSlice(gpa, "{\"ts\":");
    try list.appendSlice(gpa, ts);
    try list.appendSlice(gpa, ",\"kind\":");
    try argv.writeJsonString(&list, gpa, kind);
    try list.appendSlice(gpa, ",\"channel\":");
    try argv.writeJsonString(&list, gpa, channel);
    try list.appendSlice(gpa, ",\"author\":");
    try argv.writeJsonString(&list, gpa, author);
    try list.appendSlice(gpa, ",\"text\":");
    try argv.writeJsonString(&list, gpa, text);
    if (peer.len > 0) {
        try list.appendSlice(gpa, ",\"peer\":");
        try argv.writeJsonString(&list, gpa, peer);
    }
    try list.append(gpa, '}');
    try files.appendLine(io, gpa, dir, "inbox.jsonl", list.items);
}

pub const roster_leaf = "roster.json";

pub fn loadRosterNicks(arena: Allocator, io: Io, gpa: Allocator, dir: []const u8) ![]const []const u8 {
    const raw = try files.readFile(io, gpa, dir, roster_leaf);
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RosterCorrupt,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.RosterCorrupt;
    const nicks_val = parsed.value.object.get("nicks") orelse return error.RosterCorrupt;
    if (nicks_val != .array) return error.RosterCorrupt;
    var out: std.ArrayList([]const u8) = .empty;
    for (nicks_val.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.RosterCorrupt;
        try out.append(arena, try arena.dupe(u8, item.string));
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

pub fn authorOnRoster(roster: []const []const u8, author: []const u8) bool {
    for (roster) |nick| {
        if (nickEqualsIgnoreCase(nick, author)) return true;
    }
    return false;
}

pub fn humanRoomPending(pending: []const Pending, roster: []const []const u8) bool {
    if (roster.len == 0) return false;
    for (pending) |item| {
        if (!std.mem.eql(u8, item.channel, "room")) continue;
        if (!authorOnRoster(roster, item.author)) return true;
    }
    return false;
}

pub fn saveInboxWatermark(io: Io, dir: []const u8, offset: usize) !void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{offset}) catch return error.PersistFailed;
    try files.overwriteFile(io, dir, "inbox.watermark", text);
}

pub fn loadInboxWatermark(io: Io, gpa: Allocator, dir: []const u8) !usize {
    const raw = try files.readFile(io, gpa, dir, "inbox.watermark");
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10) catch error.WatermarkCorrupt;
}

pub fn advanceInboxWatermark(io: Io, gpa: Allocator, dir: []const u8) !void {
    const contents = try files.readFile(io, gpa, dir, "inbox.jsonl");
    defer gpa.free(contents);
    try saveInboxWatermark(io, dir, contents.len);
}

pub fn lineId(gpa: Allocator, offset: usize, author: []const u8, text: []const u8, channel: []const u8, peer: []const u8) ![]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&offset));
    h.update(author);
    h.update("\x00");
    h.update(text);
    h.update("\x00");
    h.update(channel);
    h.update("\x00");
    h.update(peer);
    return std.fmt.allocPrint(gpa, "{x:0>16}", .{h.final()});
}

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

pub fn sortPending(pending: []Pending) void {
    std.mem.sort(Pending, pending, {}, pendingLess);
}

pub fn scanInbox(arena: Allocator, io: Io, dir: []const u8, nick: []const u8) !std.ArrayList(Pending) {
    var items: std.ArrayList(Pending) = .empty;
    const contents = try files.readFile(io, arena, dir, "inbox.jsonl");
    const watermark = try loadInboxWatermark(io, arena, dir);
    const self_lower = try std.ascii.allocLowerString(arena, nick);
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line_offset = offset;
        offset += raw.len + 1;
        if (line_offset < watermark) continue;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        if (!std.mem.eql(u8, strField(obj, "kind"), "msg")) continue;
        const author = std.mem.trim(u8, strField(obj, "author"), " ");
        const text = std.mem.trim(u8, strField(obj, "text"), " ");
        if (author.len == 0 or text.len == 0) continue;
        const author_lower = try std.ascii.allocLowerString(arena, author);
        if (std.mem.eql(u8, author_lower, self_lower)) continue;
        var channel = strField(obj, "channel");
        if (channel.len == 0) channel = "room";
        const peer = if (std.mem.eql(u8, channel, "dm")) blk: {
            const value = strField(obj, "peer");
            break :blk if (value.len > 0) value else author;
        } else "";
        const needle = try std.fmt.allocPrint(arena, "@{s}", .{self_lower});
        const text_lower = try std.ascii.allocLowerString(arena, text);
        try items.append(arena, .{
            .id = try lineId(arena, line_offset, author, text, channel, peer),
            .channel = channel,
            .author = author,
            .text = text,
            .peer = peer,
            .mention = std.mem.indexOf(u8, text_lower, needle) != null,
        });
    }
    return items;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = obj.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

pub fn loadReplied(arena: Allocator, io: Io, dir: []const u8) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .{};
    const raw = try files.readFile(io, arena, dir, "replied.json");
    if (raw.len == 0) return set;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LedgerCorrupt,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.LedgerCorrupt;
    for (parsed.value.array.items) |value| {
        if (value != .string) return error.LedgerCorrupt;
        try set.put(arena, value.string, {});
    }
    return set;
}

pub fn markReplied(io: Io, gpa: Allocator, dir: []const u8, ids: []const []const u8) !usize {
    const lock = try files.lockLeaf(io, dir, "replied.json");
    defer lock.unlock();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var order: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .{};
    const raw = try files.readFile(io, arena, dir, "replied.json");
    const document = if (raw.len == 0) "[]" else raw;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, document, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LedgerCorrupt,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.LedgerCorrupt;
    for (parsed.value.array.items) |value| {
        if (value != .string) return error.LedgerCorrupt;
        if (seen.contains(value.string)) continue;
        try seen.put(arena, value.string, {});
        try order.append(arena, value.string);
    }

    var added: usize = 0;
    for (ids) |id| {
        if (id.len == 0 or seen.contains(id)) continue;
        try seen.put(arena, id, {});
        try order.append(arena, id);
        added += 1;
    }

    const start = order.items.len -| common.replied_cap;
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (order.items[start..], 0..) |id, index| {
        if (index > 0) try out.append(arena, ',');
        try argv.writeJsonString(&out, arena, id);
    }
    try out.append(arena, ']');
    files.overwriteFile(io, dir, "replied.json", out.items) catch return error.PersistFailed;
    return added;
}
