//! Outbox compaction and process-state serialization for rooms-peer.
const std = @import("std");
const common = @import("common.zig");
const argv = @import("../../argv.zig");
const files = @import("harness/files.zig");

const Io = common.Io;
const Allocator = common.Allocator;
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

/// Parse one outbox JSON object. Malformed lines are data errors that the
/// compactor may intentionally skip; allocation failure is returned so the
/// compactor can retain the line and its tail.
pub fn parseOutboxLine(gpa: Allocator, line: []const u8) !OutboxLine {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedOutbox,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedOutbox;
    const t = parsed.value.object.get("text") orelse return error.MalformedOutbox;
    if (t != .string) return error.MalformedOutbox;
    const text = gpa.dupe(u8, t.string) catch |err| return err;
    errdefer gpa.free(text);
    var is_dm = false;
    if (parsed.value.object.get("channel")) |c| {
        if (c == .string and std.mem.eql(u8, c.string, "dm")) is_dm = true;
    }
    var peer: []u8 = gpa.dupe(u8, "") catch |err| {
        gpa.free(text);
        return err;
    };
    errdefer gpa.free(peer);
    if (is_dm) {
        if (parsed.value.object.get("peer")) |p| {
            if (p == .string and p.string.len > 0) {
                gpa.free(peer);
                peer = gpa.dupe(u8, p.string) catch |err| {
                    gpa.free(text);
                    return err;
                };
            }
        }
    }
    return .{ .text = text, .is_dm = is_dm, .peer = peer };
}

/// What the outbox drain does with one complete remainder line.
pub const OutboxLineFate = enum {
    /// Omit from the rewritten remainder (sent, empty, or invalid).
    drop,
    /// Keep this line and keep scanning later lines (blocked DM).
    hold,
    /// Keep this line and every later byte. Stop scanning.
    stop,
};

/// Rewrite outbox remainder so sent lines vanish and blocked DMs stay, without
/// inventing EOF. Incomplete trailing bytes (no newline) are always kept.
/// `decide` sees one parsed JSON line; empty and non-JSON lines are dropped
/// the same way the drain used to skip them.
pub fn compactOutboxRemainder(
    gpa: Allocator,
    remainder: []const u8,
    context: anytype,
    comptime decide: anytype,
) Allocator.Error![]u8 {
    var kept: std.ArrayList(u8) = .empty;
    errdefer kept.deinit(gpa);
    var pos: usize = 0;
    while (pos < remainder.len) {
        const rel_nl = std.mem.indexOfScalar(u8, remainder[pos..], '\n') orelse {
            try kept.appendSlice(gpa, remainder[pos..]);
            break;
        };
        const line_end = pos + rel_nl;
        const record = remainder[pos .. line_end + 1];
        const trimmed = std.mem.trim(u8, remainder[pos..line_end], " \t\r");
        const next = line_end + 1;
        if (trimmed.len == 0) {
            pos = next;
            continue;
        }
        const fate = blk: {
            const parsed = parseOutboxLine(gpa, trimmed) catch |err| switch (err) {
                error.MalformedOutbox => {
                    pos = next;
                    break :blk null;
                },
                error.OutOfMemory => {
                    try kept.appendSlice(gpa, remainder[pos..]);
                    break :blk null;
                },
            };
            defer parsed.deinit(gpa);
            break :blk decide(context, parsed);
        };
        if (fate == null) {
            if (pos != next) break;
            continue;
        }
        switch (fate.?) {
            .drop => {},
            .hold => try kept.appendSlice(gpa, record),
            .stop => {
                try kept.appendSlice(gpa, remainder[pos..]);
                break;
            },
        }
        pos = next;
    }
    return kept.toOwnedSlice(gpa);
}

/// Append one durable room post or direct message to the peer's outbox. A DM
/// names its introduction target; the daemon resolves or opens that route
/// before dropping that line. A blocked DM is held; later room posts still send.
pub fn appendOutbox(io: Io, gpa: Allocator, dir: []const u8, text: []const u8, peer: ?[]const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    if (peer) |nick| {
        try list.appendSlice(gpa, "{\"channel\":\"dm\",\"peer\":");
        try writeJsonString(&list, gpa, nick);
    } else {
        try list.appendSlice(gpa, "{\"channel\":\"room\"");
    }
    try list.appendSlice(gpa, ",\"text\":");
    try writeJsonString(&list, gpa, text);
    try list.append(gpa, '}');
    try files.appendLine(io, gpa, dir, "outbox.jsonl", list.items);
}

/// Write a JSON string literal (quotes and escaping) into an ArrayList.
///
/// This is the CLI's one escaper, reached from here so the inbox records and
/// the JSON the CLI prints agree about what a string is. A room member's nick
/// and line arrive over the wire, so they can be any bytes at all, and the
/// escaper is what keeps `inbox.jsonl` parseable when they are not text.
pub const writeJsonString = argv.writeJsonString;

/// Write `outbox.offset`. The drain compacts sent lines out of the file
/// instead of advancing this mark, so nothing in the peer calls this anymore;
/// tests use it to fabricate a state dir whose scrollback the drain must not
/// resend.
pub fn saveOutboxOffset(io: Io, dir: []const u8, offset: usize) error{PersistFailed}!void {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{offset}) catch return error.PersistFailed;
    files.overwriteFile(io, dir, "outbox.offset", text) catch return error.PersistFailed;
}

/// Load the persisted already-sent mark (unclamped). The drain treats bytes
/// before it as sent scrollback and compacts only past it. Missing means zero;
/// corrupt data is reported so a restart cannot silently duplicate or skip
/// records. Never invent EOF.
pub fn loadOutboxOffset(io: Io, gpa: Allocator, dir: []const u8) !usize {
    const raw = try files.readFile(io, gpa, dir, "outbox.offset");
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(usize, trimmed, 10) catch error.OutboxOffsetCorrupt;
}

/// Clamp an in-memory outbox cursor to the current file length.
pub fn clampOutboxOffset(offset: usize, outbox_len: usize) usize {
    return @min(offset, outbox_len);
}

/// Bytes still waiting in outbox.jsonl past the persisted drain offset.
pub fn outboxBacklogBytes(io: Io, gpa: Allocator, dir: []const u8) !usize {
    const contents = try files.readFile(io, gpa, dir, "outbox.jsonl");
    defer gpa.free(contents);
    const offset = clampOutboxOffset(try loadOutboxOffset(io, gpa, dir), contents.len);
    return contents.len - offset;
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
) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "{\"status\":");
    try writeJsonString(&list, gpa, status);
    try list.appendSlice(gpa, ",\"nick\":");
    try writeJsonString(&list, gpa, nick);
    try list.appendSlice(gpa, ",\"room\":");
    try writeJsonString(&list, gpa, room);
    try list.appendSlice(gpa, ",\"locator\":");
    try writeJsonString(&list, gpa, locator);
    try list.appendSlice(gpa, ",\"registered\":");
    try list.appendSlice(gpa, if (registered) "true" else "false");
    try list.appendSlice(gpa, ",\"join_attempts\":");
    var jb: [12]u8 = undefined;
    const attempts = std.fmt.bufPrint(&jb, "{d}", .{join_attempts}) catch return error.PersistFailed;
    try list.appendSlice(gpa, attempts);
    try list.append(gpa, '}');
    try files.overwriteFile(io, dir, "state.json", list.items);
}

/// One string field out of state.json, owned; empty when absent. The empty
/// answer is a static slice rather than a zero-length allocation, which the
/// caller's `free` handles either way.
/// Booleans stringify as `"true"` / `"false"` so callers can compare without a
/// second helper (`registered` is written as a JSON bool). Extracts strings
/// and bools only: numeric fields (`join_attempts`) surface through the raw
/// state.json splice in `status`, or a caller's own JSON parse.
pub fn stateField(io: Io, gpa: Allocator, dir: []const u8, key: []const u8) ![]u8 {
    const raw = try files.readFile(io, gpa, dir, "state.json");
    defer gpa.free(raw);
    if (raw.len == 0) return &.{};
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StateCorrupt,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.StateCorrupt;
    if (parsed.value.object.get(key)) |v| {
        if (v == .string) return gpa.dupe(u8, v.string);
        if (v == .bool) return gpa.dupe(u8, if (v.bool) "true" else "false");
    }
    return &.{};
}
