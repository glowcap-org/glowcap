//! Stdio MCP front — curated tools from the CapTP registry (ADR-0084).
const std = @import("std");
const build_options = @import("build_options");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const log = @import("../operability/log.zig");
const registry = @import("../registry.zig");
const signals = @import("../operability/signals.zig");
const argv = @import("../argv.zig");
const schema = @import("schema.zig");
const Parsed = @import("../cmd/types.zig").Parsed;

const McpCatalog = registry.McpCatalog;

/// MCP stdio transport: one JSON-RPC message per line (newline-delimited).
/// Cursor/Claude speak NDJSON; LSP-style length headers leave them stalled.
fn writeMessage(io: std.Io, body: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, body);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn readMessage(gpa: std.mem.Allocator, reader: anytype) !?[]u8 {
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        return try gpa.dupe(u8, trimmed);
    }
}

fn catalogFromArg(s: []const u8) ?McpCatalog {
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "full")) return .full;
    if (std.mem.eql(u8, s, "readonly")) return .readonly;
    return null;
}

fn appendToolSchema(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cmd: *const registry.Command, first: *bool) !void {
    if (!first.*) try out.append(gpa, ',');
    first.* = false;
    try out.appendSlice(gpa, "{\"name\":\"");
    try out.appendSlice(gpa, cmd.name);
    try out.appendSlice(gpa, "\",\"description\":\"");
    try out.appendSlice(gpa, cmd.help);
    try out.appendSlice(gpa, "\",\"inputSchema\":");
    try schema.appendInputSchema(out, gpa, cmd);
    try out.append(gpa, '}');
}

fn handleInitialize(io: std.Io, gpa: std.mem.Allocator, id_json: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var ver_buf: [32]u8 = undefined;
    const ver = try std.fmt.bufPrint(&ver_buf, "{d}.{d}.{d}", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
    });
    try body.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"pancake\",\"version\":\"{s}\"}}}}}}", .{ id_json, ver });
    try writeMessage(io, body.items);
}

/// Build a `tools/list` JSON-RPC result body (no framing). Hermetic goldens parse this.
pub fn appendToolsListBody(out: *std.ArrayList(u8), gpa: std.mem.Allocator, id_json: []const u8, catalog: McpCatalog) !void {
    try out.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[", .{id_json});
    var first = true;
    for (&registry.commands) |*cmd| {
        if (!registry.mcpVisible(cmd, catalog)) continue;
        try appendToolSchema(out, gpa, cmd, &first);
    }
    try out.appendSlice(gpa, "]}}");
}

fn handleToolsList(io: std.Io, gpa: std.mem.Allocator, id_json: []const u8, catalog: McpCatalog) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendToolsListBody(&body, gpa, id_json, catalog);
    try writeMessage(io, body.items);
}

fn idToJson(gpa: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    if (id) |v| {
        return switch (v) {
            .integer => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
            .float => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
            .string => |s| blk: {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(gpa);
                try argv.writeJsonString(&out, gpa, s);
                break :blk try out.toOwnedSlice(gpa);
            },
            .null => try gpa.dupe(u8, "null"),
            else => try gpa.dupe(u8, "null"),
        };
    }
    return try gpa.dupe(u8, "null");
}

fn jsonGet(obj: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (obj) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn handleToolsCall(ctx: *Ctx, id_json: []const u8, root: std.json.Value, catalog: McpCatalog) !void {
    const params = jsonGet(root, "params") orelse {
        try writeError(ctx.io, ctx.gpa, id_json, -32602, "missing params");
        return;
    };
    const name_val = jsonGet(params, "name") orelse {
        try writeError(ctx.io, ctx.gpa, id_json, -32602, "missing tool name");
        return;
    };
    const name = switch (name_val) {
        .string => |s| s,
        else => {
            try writeError(ctx.io, ctx.gpa, id_json, -32602, "tool name must be a string");
            return;
        },
    };
    const cmd = registry.find(name) orelse {
        try writeError(ctx.io, ctx.gpa, id_json, -32601, "unknown tool");
        return;
    };
    if (!registry.mcpVisible(cmd, catalog)) {
        try writeError(ctx.io, ctx.gpa, id_json, -32601, "tool not in catalog");
        return;
    }

    var tool_parsed: Parsed = undefined;
    try schema.fillParsed(ctx.gpa, cmd, jsonGet(params, "arguments"), &tool_parsed);
    defer tool_parsed.deinit();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(ctx.gpa);
    const prev_sink = ctx.sink;
    ctx.sink = .{ .buffer = &capture };
    defer ctx.sink = prev_sink;

    const code = cmd.run(ctx, &tool_parsed) catch |err| {
        try writeError(ctx.io, ctx.gpa, id_json, -32000, @errorName(err));
        return;
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(ctx.gpa);
    // Tool text is argv `--json` outcome (success or failure JSON); `isError` ⇔ exit.
    const is_error = code != 0;
    const text = if (is_error and capture.items.len == 0)
        "{\"ok\":false,\"error\":\"tool failed without a JSON body\"}\n"
    else
        capture.items;
    try appendToolsCallResult(&resp, ctx.gpa, id_json, text, is_error);
    try writeMessage(ctx.io, resp.items);
}

/// Build a `tools/call` JSON-RPC result body (no framing). Hermetic goldens parse this.
/// Zig `print` treats `}}` as one literal `}`, so the two closing braces after
/// `isError` are appended — a missing root `}` is what made Cursor drop the MCP
/// connection on the first tool call.
pub fn appendToolsCallResult(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    id_json: []const u8,
    text: []const u8,
    is_error: bool,
) !void {
    try out.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try out.appendSlice(gpa, id_json);
    try out.appendSlice(gpa, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try argv.writeJsonString(out, gpa, text);
    try out.print(gpa, "}}],\"isError\":{s}", .{if (is_error) "true" else "false"});
    try out.appendSlice(gpa, "}}");
}

fn writeError(io: std.Io, gpa: std.mem.Allocator, id_json: []const u8, code: i32, message: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_json, code, message });
    try writeMessage(io, body.items);
}

fn closeStdin(io: *std.Io) void {
    std.Io.File.stdin().close(io.*);
}

/// Default MCP idle (no message) and max session lifetimes. Zero disables a cap.
pub const default_idle_ms: u64 = 30 * 60 * 1000;
pub const default_max_session_ms: u64 = 8 * 60 * 60 * 1000;

const CapsWatch = struct {
    io: std.Io,
    io_box: *std.Io,
    last_activity_ms: *std.atomic.Value(u64),
    started_ms: u64,
    idle_ms: u64,
    max_session_ms: u64,
    closed: std.atomic.Value(bool) = .init(false),

    fn closeOnce(self: *CapsWatch) void {
        if (self.closed.swap(true, .acq_rel)) return;
        closeStdin(self.io_box);
    }

    fn nowMs() u64 {
        var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
        switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts))) {
            .SUCCESS => {},
            else => return 0,
        }
        const ms = @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
            @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
        return @intCast(@max(ms, 0));
    }

    pub fn run(self: *CapsWatch) void {
        while (!signals.stopRequested()) {
            const now = nowMs();
            if (self.max_session_ms != 0 and now -% self.started_ms >= self.max_session_ms) {
                log.info(self.io, "mcp max session reached; draining", .{});
                signals.requestStop();
                self.closeOnce();
                return;
            }
            if (self.idle_ms != 0) {
                const last = self.last_activity_ms.load(.acquire);
                if (now -% last >= self.idle_ms) {
                    log.info(self.io, "mcp idle timeout; draining", .{});
                    signals.requestStop();
                    self.closeOnce();
                    return;
                }
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
        }
        self.closeOnce();
    }
};

fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// Command-tree entry for `pancake mcp …`.
pub fn runParsed(ctx: *Ctx, parsed: *Parsed) !u8 {
    ctx.front = .mcp;
    // Same CapTP body shape as argv `--json` so agents parse one contract.
    ctx.json = .json;
    var catalog: McpCatalog = .default;
    var idle_ms: u64 = default_idle_ms;
    var max_session_ms: u64 = default_max_session_ms;
    if (ctx.environ.get("PANCAKE_MCP_IDLE_MS")) |v| {
        if (parseU64(v)) |n| idle_ms = n;
    }
    if (ctx.environ.get("PANCAKE_MCP_MAX_SESSION_MS")) |v| {
        if (parseU64(v)) |n| max_session_ms = n;
    }
    if (parsed.flagString("tools")) |v| {
        catalog = catalogFromArg(v) orelse {
            log.err(ctx.io, "unknown --tools {s}", .{v});
            return exit_codes.usage;
        };
    }
    if (parsed.flagString("idle-ms")) |v| {
        idle_ms = parseU64(v) orelse {
            log.err(ctx.io, "invalid --idle-ms {s}", .{v});
            return exit_codes.usage;
        };
    }
    if (parsed.flagString("max-session-ms")) |v| {
        max_session_ms = parseU64(v) orelse {
            log.err(ctx.io, "invalid --max-session-ms {s}", .{v});
            return exit_codes.usage;
        };
    }
    return serveMcp(ctx, catalog, idle_ms, max_session_ms);
}

fn serveMcp(ctx: *Ctx, catalog: McpCatalog, idle_ms: u64, max_session_ms: u64) !u8 {
    signals.install();
    var io_box = ctx.io;
    var last_activity = std.atomic.Value(u64).init(CapsWatch.nowMs());
    const started_ms = last_activity.load(.unordered);
    var caps = CapsWatch{
        .io = ctx.io,
        .io_box = &io_box,
        .last_activity_ms = &last_activity,
        .started_ms = started_ms,
        .idle_ms = idle_ms,
        .max_session_ms = max_session_ms,
    };
    var caps_future = try ctx.io.concurrent(CapsWatch.run, .{&caps});
    defer {
        signals.requestStop();
        caps_future.await(ctx.io);
        ctx.closeSession();
    }

    var read_buf: [65536]u8 = undefined;
    var reader = std.Io.File.stdin().reader(ctx.io, &read_buf);

    while (!signals.stopRequested()) {
        const body = readMessage(ctx.gpa, &reader) catch |err| {
            if (signals.stopRequested()) break;
            return err;
        } orelse break;
        defer ctx.gpa.free(body);
        last_activity.store(CapsWatch.nowMs(), .release);

        const msg = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
            try writeError(ctx.io, ctx.gpa, "null", -32700, "parse error");
            continue;
        };
        defer msg.deinit();
        const root = msg.value;

        const method_val = jsonGet(root, "method") orelse continue;
        const method = switch (method_val) {
            .string => |s| s,
            else => continue,
        };
        const id_json = try idToJson(ctx.gpa, jsonGet(root, "id"));
        defer ctx.gpa.free(id_json);

        if (std.mem.eql(u8, method, "initialize")) {
            try handleInitialize(ctx.io, ctx.gpa, id_json);
        } else if (std.mem.eql(u8, method, "notifications/initialized") or std.mem.eql(u8, method, "initialized")) {
            // no-op
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try handleToolsList(ctx.io, ctx.gpa, id_json, catalog);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try handleToolsCall(ctx, id_json, root, catalog);
        } else if (std.mem.eql(u8, method, "ping")) {
            var resp: std.ArrayList(u8) = .empty;
            defer resp.deinit(ctx.gpa);
            try resp.print(ctx.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_json});
            try writeMessage(ctx.io, resp.items);
        } else {
            try writeError(ctx.io, ctx.gpa, id_json, -32601, "method not found");
        }
    }
    return exit_codes.ok;
}
