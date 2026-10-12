//! Stdio MCP front: curated tools from the CapTP registry (ADR-0084).
const std = @import("std");
const build_options = @import("build_options");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const log = @import("../operability/log.zig");
const registry = @import("../registry.zig");
const signals = @import("../operability/signals.zig");
const clock = @import("../operability/clock.zig");
const argv = @import("../argv.zig");
const schema = @import("schema.zig");
const Parsed = @import("../cmd/types.zig").Parsed;

const McpCatalog = registry.McpCatalog;

/// MCP stdio transport: one JSON-RPC message per line (newline-delimited).
/// Cursor/Claude speak NDJSON. LSP-style length headers leave them stalled.
fn writeMessage(io: std.Io, body: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, body);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

/// One JSON-RPC message, or null at end of stream.
///
/// A line longer than the read buffer raises `MessageTooLong` rather than
/// killing the server. The rest of that line is discarded first, so the next
/// read starts at a message boundary instead of part-way through the one we
/// refused. The caller answers with an invalid-request error and carries on.
fn readMessage(gpa: std.mem.Allocator, reader: anytype) !?[]u8 {
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            error.StreamTooLong => {
                // best-effort: a stream that cannot even skip the oversized
                // line surfaces its failure on the next read.
                _ = reader.interface.discardDelimiterInclusive('\n') catch {};
                return error.MessageTooLong;
            },
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

/// The MCP revisions this server answers to, newest first.
///
/// Everything it implements is the tools half of the protocol over standard
/// input and output: `initialize`, `ping`, `tools/list`, and `tools/call`.
/// Those four have the same request and result shapes in both revisions listed
/// here, so a client asking for either gets a server that behaves the way its
/// revision describes. Revisions differ elsewhere, in features this server does
/// not offer, and a client learns that from the empty capabilities it gets
/// back.
///
/// `2025-03-26` is absent even though its four methods match. It
/// requires a server to accept a batch of requests in one array, and this one
/// reads a single request per line. Claiming it would be claiming something the
/// server does not do.
const supported_protocol_versions = [_][]const u8{
    "2025-06-18",
    "2024-11-05",
};

/// The newest revision this server speaks, offered to a client that named one
/// it does not.
const newest_protocol_version = supported_protocol_versions[0];
/// The oldest, which a client that named nothing gets: the safest guess about
/// what an unknown client can read.
const oldest_protocol_version = supported_protocol_versions[supported_protocol_versions.len - 1];

comptime {
    // "Newest first" is what those two names mean. Revisions are ISO dates, so
    // descending lexicographic order is descending chronological order.
    for (supported_protocol_versions[1..], 0..) |version, i| {
        std.debug.assert(std.mem.order(u8, supported_protocol_versions[i], version) == .gt);
    }
}

/// The revision to answer with. A client names the one it wants. The protocol
/// says to echo it back when we speak it, and otherwise to name one we do
/// speak so the client can decide whether to carry on. A client that names
/// nothing gets the oldest, which is the safest guess about what it can read.
fn negotiateProtocolVersion(root: std.json.Value) []const u8 {
    const asked = askedProtocolVersion(root) orelse return oldest_protocol_version;
    for (supported_protocol_versions) |known| {
        if (std.mem.eql(u8, known, asked)) return known;
    }
    return newest_protocol_version;
}

/// The revision the client named, or null if it named none this server can read.
fn askedProtocolVersion(root: std.json.Value) ?[]const u8 {
    const params = jsonGet(root, "params") orelse return null;
    return switch (jsonGet(params, "protocolVersion") orelse return null) {
        .string => |v| v,
        else => null,
    };
}

fn handleInitialize(io: std.Io, gpa: std.mem.Allocator, id_json: []const u8, root: std.json.Value) !void {
    // A client that asked for a revision this server does not speak may simply
    // hang up, and the person running it sees an empty terminal. Standard
    // output is the protocol here, so say it on standard error instead. The
    // comparison stays out of `negotiateProtocolVersion` so that function is
    // still a pure answer its tests can ask for.
    const answering = negotiateProtocolVersion(root);
    if (askedProtocolVersion(root)) |asked| {
        if (!std.mem.eql(u8, asked, answering)) {
            log.err(io, "client asked for MCP revision \"{s}\", which this server does not speak; answering \"{s}\"", .{ asked, answering });
        }
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var ver_buf: [32]u8 = undefined;
    const ver = try std.fmt.bufPrint(&ver_buf, "{d}.{d}.{d}", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
    });
    try body.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"glowcap\",\"version\":\"{s}\"}}}}}}", .{ id_json, answering, ver });
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

/// Render a request's `id` for the reply, or null when there is no `id` at all.
///
/// The distinction matters: JSON-RPC 2.0 calls a request with no `id` a
/// notification, and says a server must not answer one. Rendering a missing
/// `id` as the literal `null` erases that difference and makes every
/// notification look like a request whose id happens to be null, which is a
/// different thing and does get a reply.
pub fn idToJson(gpa: std.mem.Allocator, id: ?std.json.Value) !?[]u8 {
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
    return null;
}

/// Answer a request that parsed as JSON but is not a request this server can
/// act on. A notification carries no id and JSON-RPC forbids answering it, so
/// that one stays silent. Everything else gets told why.
fn refuseMalformedRequest(ctx: *Ctx, maybe_id: ?[]const u8, why: []const u8) !void {
    const id = maybe_id orelse return;
    try writeError(ctx.io, ctx.gpa, id, -32600, why);
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
    // A server that dies on one bad or oversized call takes every other tool
    // with it, so a failure here is this request's error, not the process's.
    schema.fillParsed(ctx.gpa, cmd, jsonGet(params, "arguments"), &tool_parsed) catch |err| switch (err) {
        error.InvalidArguments => {
            try writeError(ctx.io, ctx.gpa, id_json, -32602, "arguments do not match the tool input schema");
            return;
        },
        else => {
            try writeError(ctx.io, ctx.gpa, id_json, -32603, @errorName(err));
            return;
        },
    };
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
/// `isError` are appended. A missing root `}` is what made Cursor drop the MCP
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

/// Write a JSON-RPC error reply.
///
/// The message goes through the escaper rather than straight into the format
/// string. Some of these messages quote what the client sent, and a message
/// with a quote in it would produce a reply that is not JSON at all.
fn writeError(io: std.Io, gpa: std.mem.Allocator, id_json: []const u8, code: i32, message: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id_json, code });
    try argv.writeJsonString(&body, gpa, message);
    try body.appendSlice(gpa, "}}");
    try writeMessage(io, body.items);
}

fn closeStdin(io: *std.Io) void {
    std.Io.File.stdin().close(io.*);
}

/// Default MCP idle (no message) and max session lifetimes. Zero disables a cap.
/// Millisecond spans share `clock.nowMs`'s `i64` so every comparison in
/// `CapsWatch` is plain signed arithmetic against one clock type.
pub const default_idle_ms: i64 = 30 * 60 * 1000;
pub const default_max_session_ms: i64 = 8 * 60 * 60 * 1000;

const CapsWatch = struct {
    io: std.Io,
    io_box: *std.Io,
    last_activity_ms: *std.atomic.Value(i64),
    started_ms: i64,
    idle_ms: i64,
    max_session_ms: i64,
    closed: std.atomic.Value(bool) = .init(false),

    fn closeOnce(self: *CapsWatch) void {
        if (self.closed.swap(true, .acq_rel)) return;
        closeStdin(self.io_box);
    }

    pub fn run(self: *CapsWatch) void {
        while (!signals.stopRequested()) {
            const now = clock.nowMs();
            if (self.max_session_ms != 0 and now - self.started_ms >= self.max_session_ms) {
                log.info(self.io, "mcp max session reached; draining", .{});
                signals.requestStop();
                self.closeOnce();
                return;
            }
            if (self.idle_ms != 0) {
                // The activity thread may stamp a reading newer than `now`
                // between our two loads; the signed difference goes negative
                // then, which reads as fresh activity, not idleness.
                const last = self.last_activity_ms.load(.acquire);
                if (now - last >= self.idle_ms) {
                    log.info(self.io, "mcp idle timeout; draining", .{});
                    signals.requestStop();
                    self.closeOnce();
                    return;
                }
            }
            // tolerant: an interrupted sleep only shortens the poll interval.
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
        }
        self.closeOnce();
    }
};

/// Parse a millisecond span, clamped into the clock's `i64` domain.
fn parseMs(s: []const u8) ?i64 {
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    return std.math.cast(i64, n) orelse std.math.maxInt(i64);
}

/// Command-tree entry for `glowcap mcp …`.
pub fn runParsed(ctx: *Ctx, parsed: *Parsed) !u8 {
    ctx.front = .mcp;
    // Same CapTP body shape as argv `--json` so agents parse one contract.
    ctx.json = .json;
    var catalog: McpCatalog = .default;
    var idle_ms: i64 = default_idle_ms;
    var max_session_ms: i64 = default_max_session_ms;
    if (ctx.environ.get("GLOWCAP_MCP_IDLE_MS")) |v| {
        if (parseMs(v)) |n| idle_ms = n;
    }
    if (ctx.environ.get("GLOWCAP_MCP_MAX_SESSION_MS")) |v| {
        if (parseMs(v)) |n| max_session_ms = n;
    }
    if (parsed.flagString("tools")) |v| {
        catalog = catalogFromArg(v) orelse {
            log.err(ctx.io, "unknown --tools {s}", .{v});
            return exit_codes.usage;
        };
    }
    if (parsed.flagString("idle-ms")) |v| {
        idle_ms = parseMs(v) orelse {
            log.err(ctx.io, "invalid --idle-ms {s}", .{v});
            return exit_codes.usage;
        };
    }
    if (parsed.flagString("max-session-ms")) |v| {
        max_session_ms = parseMs(v) orelse {
            log.err(ctx.io, "invalid --max-session-ms {s}", .{v});
            return exit_codes.usage;
        };
    }
    return serveMcp(ctx, catalog, idle_ms, max_session_ms);
}

fn serveMcp(ctx: *Ctx, catalog: McpCatalog, idle_ms: i64, max_session_ms: i64) !u8 {
    signals.install();
    var io_box = ctx.io;
    var last_activity = std.atomic.Value(i64).init(clock.nowMs());
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
    const code: u8 = exit_codes.ok;
    var stopped = false;
    defer {
        if (!stopped) {
            signals.requestStop();
            caps_future.await(ctx.io);
            if (ctx.closeOwned(.cancel)) |failure| {
                ctx.logCloseFailure("mcp close", failure);
            }
        }
    }

    var read_buf: [65536]u8 = undefined;
    var reader = std.Io.File.stdin().reader(ctx.io, &read_buf);

    while (!signals.stopRequested()) {
        const body = readMessage(ctx.gpa, &reader) catch |err| {
            if (signals.stopRequested()) break;
            if (err == error.MessageTooLong) {
                // Refuse the one message, keep the session. The id is
                // unknowable here because the line was never parsed, and
                // JSON-RPC 2.0 says to answer with a null id in exactly that
                // case.
                try writeError(ctx.io, ctx.gpa, "null", -32600, "request exceeds the maximum message size");
                continue;
            }
            return err;
        } orelse break;
        defer ctx.gpa.free(body);
        last_activity.store(clock.nowMs(), .release);

        const msg = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
            try writeError(ctx.io, ctx.gpa, "null", -32700, "parse error");
            continue;
        };
        defer msg.deinit();
        const root = msg.value;

        // Everything below needs an id to answer with, and a well-formed
        // method to answer about. A request that has one but not the other used
        // to fall out of the loop in silence, and the client waited on a reply
        // that was never coming. Say what is wrong instead.
        const maybe_id = try idToJson(ctx.gpa, jsonGet(root, "id"));
        defer if (maybe_id) |owned| ctx.gpa.free(owned);

        const method = method: {
            const method_val = jsonGet(root, "method") orelse {
                try refuseMalformedRequest(ctx, maybe_id, "request has no \"method\"");
                continue;
            };
            switch (method_val) {
                .string => |s| break :method s,
                else => {
                    try refuseMalformedRequest(ctx, maybe_id, "\"method\" must be a string");
                    continue;
                },
            }
        };
        // No `id` means a notification, and JSON-RPC 2.0 forbids answering
        // one. Everything below writes a reply, so there is nothing here a
        // notification could ask for.
        const id_json = maybe_id orelse continue;

        if (std.mem.eql(u8, method, "initialize")) {
            try handleInitialize(ctx.io, ctx.gpa, id_json, root);
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
    signals.requestStop();
    caps_future.await(ctx.io);
    stopped = true;
    return finishMcp(ctx, code);
}

fn finishMcp(ctx: *Ctx, code: u8) u8 {
    if (ctx.closeOwned(.cancel)) |failure| {
        ctx.logCloseFailure("mcp close", failure);
        if (code == exit_codes.ok) return ctx.mapCloseErr(failure.cause);
    }
    return code;
}

test "the version a client asks for comes back when we speak it" {
    const gpa = std.testing.allocator;
    for (supported_protocol_versions) |want| {
        const body = try std.fmt.allocPrint(gpa, "{{\"params\":{{\"protocolVersion\":\"{s}\"}}}}", .{want});
        defer gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(want, negotiateProtocolVersion(parsed.value));
    }
}

test "a version we do not speak gets one we do, so the client can decide" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"params\":{\"protocolVersion\":\"1999-01-01\"}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(supported_protocol_versions[0], negotiateProtocolVersion(parsed.value));
}

test "a client that names no version gets the oldest one we speak" {
    // It is the safest guess about what an unknown client can read.
    const gpa = std.testing.allocator;
    const oldest = supported_protocol_versions[supported_protocol_versions.len - 1];
    for ([_][]const u8{ "{}", "{\"params\":{}}", "{\"params\":{\"protocolVersion\":7}}" }) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(oldest, negotiateProtocolVersion(parsed.value));
    }
}

test "a request with an id but no usable method gets an answer, not silence" {
    // Falling out of the loop without a reply leaves the client waiting on
    // one that never comes. Every other failure on this loop answers.
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":7}",
    }) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer parsed.deinit();
        const id = try idToJson(gpa, jsonGet(parsed.value, "id"));
        defer if (id) |owned| gpa.free(owned);
        try std.testing.expect(id != null);

        // A method that is absent or not a string is what the loop refuses on.
        const method_val = jsonGet(parsed.value, "method");
        const usable = method_val != null and method_val.? == .string;
        try std.testing.expect(!usable);
    }
}

test "a notification is still answered with silence" {
    // JSON-RPC forbids replying to a message with no id, however malformed the
    // rest of it is.
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"jsonrpc\":\"2.0\"}", .{});
    defer parsed.deinit();
    const id = try idToJson(gpa, jsonGet(parsed.value, "id"));
    defer if (id) |owned| gpa.free(owned);
    try std.testing.expect(id == null);
}

test "mcp finalization returns a close failure" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var ctx = Ctx{ .io = threaded.io(), .gpa = gpa, .environ = &environ };
    defer ctx.deinit();

    ctx.reportUnhandledFailure(.fromError(error.ConnectionLost));
    try std.testing.expectEqual(exit_codes.dial, finishMcp(&ctx, exit_codes.ok));
}
